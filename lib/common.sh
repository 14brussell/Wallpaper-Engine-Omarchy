#!/usr/bin/env bash
# Shared paths and helpers for Wallpaper Engine Omarchy plugin.
#
# Backend: Almamu linux-wallpaperengine (AUR: linux-wallpaperengine-git).
# Omarchy: keep omarchy.background enabled; run WE on --layer bottom so it
# covers the static Quickshell wallpaper without fighting WlrLayer.Background.

set -euo pipefail

WE_PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WE_CONFIG_DIR="${WE_CONFIG_DIR:-$HOME/.config/omarchy/wallpaper-engine}"
WE_CONFIG_FILE="${WE_CONFIG_FILE:-$WE_CONFIG_DIR/config.json}"
WE_CONFIG_LOCK="${WE_CONFIG_LOCK:-$WE_CONFIG_DIR/config.lock}"
WE_STATE_DIR="${WE_STATE_DIR:-$HOME/.local/state/omarchy/wallpaper-engine}"
WE_PID_DIR="$WE_STATE_DIR/pids"
WE_PID_FILE="$WE_STATE_DIR/engine.pid"
WE_LOG_FILE="$WE_STATE_DIR/engine.log"
WE_ACTIVE_FLAG="$WE_STATE_DIR/active"
WE_PLACEHOLDER="$WE_PLUGIN_ROOT/assets/we-placeholder.png"
WE_COMPOSE_PY="${WE_COMPOSE_PY:-$WE_PLUGIN_ROOT/lib/compose_desktop.py}"
WE_THEME_GENERATOR="${WE_THEME_GENERATOR:-$WE_PLUGIN_ROOT/lib/generate_theme.py}"
WE_AUTO_THEME_SLUG="${WE_AUTO_THEME_SLUG:-wallpaper-engine-auto-match}"
WE_USER_THEMES_DIR="${WE_USER_THEMES_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/themes}"
WE_AUTO_THEME_DIR="${WE_AUTO_THEME_DIR:-$WE_USER_THEMES_DIR/$WE_AUTO_THEME_SLUG}"
WE_BG_WAS_DISABLED_FLAG="$WE_STATE_DIR/disabled-omarchy-background"
WE_TRANSITION_DIR="${WE_TRANSITION_DIR:-$WE_STATE_DIR/transitions}"
WE_BG_QUEUE_LOCK="${WE_BG_QUEUE_LOCK:-$WE_STATE_DIR/transition.lock}"

WE_APPID="${WE_APPID:-431960}"
WE_ENGINE_BIN="${WE_ENGINE_BIN:-linux-wallpaperengine}"

we_ensure_dirs() {
  mkdir -p "$WE_CONFIG_DIR" "$WE_STATE_DIR" "$WE_PID_DIR" "$WE_TRANSITION_DIR"
  if [[ -n ${WE_WIPE_REQUEST:-} && ! -f $WE_WIPE_REQUEST ]]; then
    local request_tmp
    request_tmp=$(mktemp "$WE_STATE_DIR/wipe-request.tmp.XXXXXX")
    printf '%s\n' '{"id":"","phase":"idle","outputs":[]}' >"$request_tmp"
    mv -n "$request_tmp" "$WE_WIPE_REQUEST" 2>/dev/null || rm -f "$request_tmp"
  fi
}

we_atomic_line() {
  local file=$1 value=$2 dir base tmp
  dir=$(dirname -- "$file")
  base=$(basename -- "$file")
  mkdir -p "$dir"
  tmp=$(mktemp "$dir/.${base}.tmp.XXXXXX")
  printf '%s\n' "$value" >"$tmp"
  mv -f "$tmp" "$file"
}

we_set_active_flag() {
  we_ensure_dirs
  we_atomic_line "$WE_ACTIVE_FLAG" "${1:-false}"
}

we_default_config_json() {
  cat <<'EOF'
{
  "version": 1,
  "engine": "linux-wallpaperengine",
  "assets_dir": "",
  "workshop_dirs": [],
  "extra_wallpaper_dirs": [],
  "nvidia_workaround": false,
  "defaults": {
    "scaling": "fill",
    "fps": 30,
    "silent": true,
    "volume": 15,
    "layer": "bottom",
    "clamp": "border",
    "no_fullscreen_pause": false,
    "fullscreen_pause_only_active": false,
    "fullscreen_pause_ignore_appids": [],
    "noautomute": false,
    "no_audio_processing": false,
    "disable_particles": false,
    "disable_mouse": false,
    "disable_parallax": false
  },
  "displays": {},
  "active": false,
  "saved_theme_background": null,
  "last_applied": {
    "monitor": null,
    "wallpaper": null,
    "source_image": null
  },
  "auto_theme": {
    "active": false,
    "previous_theme": null,
    "source_monitor": null
  }
}
EOF
}

we_load_config() {
  we_ensure_dirs
  local lock_fd tmp
  exec {lock_fd}>"$WE_CONFIG_LOCK"
  flock -w 2 "$lock_fd" || { echo "Wallpaper Engine config is busy." >&2; return 1; }
  if [[ ! -s $WE_CONFIG_FILE ]] || ! jq -e 'type == "object"' "$WE_CONFIG_FILE" >/dev/null 2>&1; then
    if [[ -e $WE_CONFIG_FILE ]]; then
      cp -a "$WE_CONFIG_FILE" "$WE_CONFIG_FILE.invalid.$(date +%s)" 2>/dev/null || true
    fi
    tmp=$(mktemp "$WE_CONFIG_DIR/config.json.tmp.XXXXXX")
    we_default_config_json >"$tmp"
    mv -f "$tmp" "$WE_CONFIG_FILE"
  fi
  flock -u "$lock_fd"
  exec {lock_fd}>&-
  # Migrate older configs that defaulted layer to background (fights Omarchy).
  local layer
  layer=$(jq -r '.defaults.layer // empty' "$WE_CONFIG_FILE" 2>/dev/null || true)
  if [[ $layer == background ]]; then
    we_jq_write '.defaults.layer = "bottom"'
  fi
  # Older configs predate explicit apply recency. Recover it once from the
  # newest confirmed framebuffer whose monitor + wallpaper still match config.
  if declare -F we_ensure_last_applied >/dev/null 2>&1; then
    we_ensure_last_applied || true
  fi
}

we_jq() {
  jq "$@" "$WE_CONFIG_FILE"
}

we_jq_write() {
  local tmp lock_fd
  we_ensure_dirs
  exec {lock_fd}>"$WE_CONFIG_LOCK"
  flock -w 2 "$lock_fd" || { echo "Wallpaper Engine config is busy." >&2; return 1; }
  tmp=$(mktemp "$WE_CONFIG_DIR/config.json.tmp.XXXXXX")
  if jq "$@" "$WE_CONFIG_FILE" >"$tmp"; then
    mv -f "$tmp" "$WE_CONFIG_FILE"
  else
    rm -f "$tmp"
    flock -u "$lock_fd"
    exec {lock_fd}>&-
    return 1
  fi
  flock -u "$lock_fd"
  exec {lock_fd}>&-
}

we_notify() {
  local msg=$1
  if command -v omarchy-notification-send >/dev/null 2>&1; then
    omarchy-notification-send "$msg" -t 2500 >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send -a "Wallpaper Engine" "$msg" || true
  else
    printf '%s\n' "$msg"
  fi
}

we_current_theme_background() {
  readlink -f "$HOME/.local/state/omarchy/current/background" 2>/dev/null || true
}

we_current_theme_name() {
  cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null || true
}

we_is_placeholder() {
  local path=$1
  [[ -n $path && ( $path == "$WE_PLACEHOLDER" || $(basename "$path") == we-placeholder.png ) ]]
}

# Workshop thumbnails must never be the TO still (tiny stretch on a 1440p output).
we_is_preview_still() {
  local b
  b=$(basename "${1:-}" 2>/dev/null || true)
  b=${b,,}
  case "$b" in
    preview.jpg|preview.jpeg|preview.png|preview.webp|preview.gif|preview.bmp|preview_small.jpg|thumb.jpg|thumbnail.jpg)
      return 0
      ;;
  esac
  return 1
}

# Detected displays as JSON: [{name, width, height, x, y, scale}, ...].
# Geometry is always from hyprctl at call time — never cached or hardcoded.
# wlr-randr fallback omits x/y/size (null); the compositor helper packs those.
we_monitors_json() {
  if command -v hyprctl >/dev/null 2>&1; then
    local out
    out=$(timeout -k 1 "${WE_HYPRCTL_TIMEOUT_S:-2}" hyprctl monitors -j 2>/dev/null | jq -c '
      [.[] | {
        name: .name,
        width: (.width // null),
        height: (.height // null),
        x: (.x // 0),
        y: (.y // 0),
        scale: (.scale // 1),
        transform: (.transform // 0)
      }]
    ' 2>/dev/null) && {
      [[ -n $out ]] && printf '%s\n' "$out" && return 0
    }
  fi
  if command -v wlr-randr >/dev/null 2>&1; then
    wlr-randr 2>/dev/null | awk '/^[^ ]/ {print $1}' \
      | jq -R '{name: ., width: null, height: null, x: null, y: null, scale: null}' \
      | jq -cs .
    return 0
  fi
  echo '[]'
  return 1
}

we_list_monitors() {
  local json
  if json=$(we_monitors_json 2>/dev/null); then
    jq -r '.[].name' <<<"$json" 2>/dev/null && return 0
  fi
  return 1
}

we_default_workshop_dirs() {
  local candidates=(
    "$HOME/.steam/steam/steamapps/workshop/content/$WE_APPID"
    "$HOME/.local/share/Steam/steamapps/workshop/content/$WE_APPID"
    "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/workshop/content/$WE_APPID"
    "$HOME/snap/steam/common/.local/share/Steam/steamapps/workshop/content/$WE_APPID"
  )
  local d
  for d in "${candidates[@]}"; do
    [[ -d $d ]] && printf '%s\n' "$d"
  done
}

we_workshop_dirs() {
  we_load_config
  local configured
  configured=$(we_jq -r '.workshop_dirs // [] | .[]' 2>/dev/null || true)
  if [[ -n $configured ]]; then
    printf '%s\n' "$configured"
  else
    # No detected Steam roots is valid when every library is on another disk.
    # Do not let the probe's false status skip extra_wallpaper_dirs under set -e.
    we_default_workshop_dirs || true
  fi
  we_jq -r '.extra_wallpaper_dirs // [] | .[]' 2>/dev/null || true
}

# Resolve a user-selected folder to the Workshop content root. The GUI accepts
# either that exact directory or a Steam library / steamapps / workshop parent
# so users do not have to reconstruct Steam's nested path by hand.
we_normalize_wallpaper_dir() {
  local input=${1:-} candidate
  [[ -n $input ]] || return 1
  case "$input" in
    '~') input=$HOME ;;
    '~/'*) input="$HOME/${input#\~/}" ;;
  esac
  [[ $input == /* ]] || input="$PWD/$input"

  for candidate in \
    "$input/steamapps/workshop/content/$WE_APPID" \
    "$input/workshop/content/$WE_APPID" \
    "$input/content/$WE_APPID" \
    "$input"; do
    if [[ -d $candidate ]]; then
      realpath -- "$candidate"
      return 0
    fi
  done
  echo "Wallpaper folder does not exist: $input" >&2
  return 1
}

# Resolve a wallpaper id or path to an absolute directory (or numeric id string).
we_resolve_wallpaper() {
  local ref=$1
  if [[ -d $ref ]]; then
    realpath "$ref"
    return 0
  fi
  if [[ -f $ref ]]; then
    realpath "$(dirname "$ref")"
    return 0
  fi
  if [[ $ref =~ ^[0-9]+$ ]]; then
    local dir
    while IFS= read -r dir; do
      if [[ -d $dir/$ref ]]; then
        printf '%s\n' "$dir/$ref"
        return 0
      fi
    done < <(we_workshop_dirs)
    printf '%s\n' "$ref"
    return 0
  fi
  echo "Wallpaper not found: $ref" >&2
  return 1
}

we_wallpaper_title() {
  local path_or_id=$1
  local dir project
  dir=$(we_resolve_wallpaper "$path_or_id" 2>/dev/null || true)
  if [[ -n $dir && -d $dir ]]; then
    project="$dir/project.json"
    if [[ -f $project ]]; then
      jq -r '(.title // .name // empty) | select(type == "string")' \
        "$project" 2>/dev/null && return 0
    fi
    basename "$dir"
    return 0
  fi
  printf '%s\n' "$path_or_id"
}

# Print a canonical regular file only when it remains inside the canonical
# project directory. This rejects traversal and symlinks that escape the
# Workshop item even when the final target exists.
we_canonical_project_file() {
  local project_dir=${1:-} candidate=${2:-} root resolved
  [[ -n $project_dir && -n $candidate ]] || return 1
  root=$(realpath -e -- "$project_dir" 2>/dev/null) || return 1
  [[ -d $root ]] || return 1
  resolved=$(realpath -e -- "$candidate" 2>/dev/null) || return 1
  [[ -f $resolved ]] || return 1
  case "$resolved" in
    "$root"/*) printf '%s\n' "$resolved" ;;
    *) return 1 ;;
  esac
}

# Preview image from project.json, if it resolves inside the Workshop item.
# Absolute metadata paths are never accepted, even when they point back into
# the item; project.json must describe its assets relative to its own root.
we_wallpaper_preview() {
  local path=$1 project preview
  path=$(realpath -e -- "$path" 2>/dev/null) || return 0
  [[ -d $path ]] || return 0
  project="$path/project.json"
  [[ -f $project ]] || return 0
  preview=$(jq -r '(.preview // .preview_image // empty) | select(type == "string")' \
    "$project" 2>/dev/null || true)
  [[ -n $preview && $preview != /* ]] || return 0
  we_canonical_project_file "$path" "$path/$preview" 2>/dev/null || true
}

# linux-wallpaperengine requires an explicit Wallpaper Engine project type.
# Presets/dependency-only workshop entries omit it and terminate the entire
# engine process with "Project type missing". Never offer or save those items.
we_wallpaper_supported_dir() {
  local dir=${1:-} type
  [[ -d $dir && -f $dir/project.json ]] || return 1
  type=$(jq -r '(.type // "") | ascii_downcase' "$dir/project.json" 2>/dev/null || true)
  case "$type" in
    scene|video|web) return 0 ;;
    *) return 1 ;;
  esac
}

we_wallpaper_supported() {
  local dir
  dir=$(we_resolve_wallpaper "${1:-}" 2>/dev/null || true)
  [[ -n $dir ]] && we_wallpaper_supported_dir "$dir"
}

# Emit lines: id<TAB>title<TAB>path<TAB>preview  (scan workshop for project.json — no --list on binary)
we_list_wallpapers() {
  local dir id title path preview
  declare -A seen_ids=()
  while IFS= read -r dir; do
    [[ -d $dir ]] || continue
    for path in "$dir"/*; do
      [[ -d $path ]] || continue
      id=$(basename "$path")
      [[ $id =~ ^[0-9]+$ ]] || continue
      [[ -z ${seen_ids[$id]+x} ]] || continue
      [[ -f $path/project.json ]] || continue
      we_wallpaper_supported_dir "$path" || continue
      seen_ids[$id]=1
      title=$(we_wallpaper_title "$path")
      preview=$(we_wallpaper_preview "$path")
      # Keep the legacy TSV interface structurally safe when third-party
      # project metadata contains control characters. JSON consumers are
      # built from these records, so no field may introduce another record.
      title=${title//$'\t'/ }
      title=${title//$'\r'/ }
      title=${title//$'\n'/ }
      preview=${preview//$'\t'/ }
      preview=${preview//$'\r'/ }
      preview=${preview//$'\n'/ }
      printf '%s\t%s\t%s\t%s\n' "$id" "$title" "$path" "$preview"
    done
  done < <(we_workshop_dirs | awk 'NF && !seen[$0]++')
}

# JSON array of workshop wallpapers for the Quickshell GUI.
we_list_wallpapers_json() {
  we_list_wallpapers | sort -t$'\t' -k2,2 | jq -Rs '
    [ split("\n")[] | select(length > 0)
      | split("\t")
      | {id: .[0], title: .[1], path: .[2], preview: (.[3] // "")} ]
  '
}

# True if a directory/project likely produces wallpaper audio.
# Detection: audio-ish properties, audio files, scene.pkg sound refs, or video A/V tracks.
we_wallpaper_detect_audio() {
  local dir=$1
  local project=$dir/project.json
  local type="" reason=""

  if [[ -f $project ]]; then
    type=$(jq -r '(.type // "") | ascii_downcase' "$project" 2>/dev/null || true)
    if jq -e '
      (.general.properties // {}) | to_entries
      | map(.key + " " + ((.value.text // "") | tostring))
      | map(ascii_downcase)
      | any(test("audio|sound|music|(^|[^a-z])mute([^a-z]|$)|volume"))
    ' "$project" >/dev/null 2>&1; then
      printf '%s\n' "property"
      return 0
    fi
  fi

  if find "$dir" -maxdepth 2 -type f \
      \( -iname '*.mp3' -o -iname '*.ogg' -o -iname '*.wav' -o -iname '*.flac' -o -iname '*.m4a' \) \
      -print -quit 2>/dev/null | grep -q .; then
    printf '%s\n' "file"
    return 0
  fi

  if [[ -f $dir/scene.pkg ]]; then
    if grep -a -E -q -m1 'sounds/|\.mp3|\.ogg|\.wav|\.flac' "$dir/scene.pkg" 2>/dev/null; then
      printf '%s\n' "scene.pkg"
      return 0
    fi
  fi

  if [[ $type == video ]]; then
    local vid
    vid=$(find "$dir" -maxdepth 2 -type f \
      \( -iname '*.mp4' -o -iname '*.webm' -o -iname '*.mkv' -o -iname '*.avi' \) \
      -print -quit 2>/dev/null || true)
    if [[ -n $vid ]]; then
      if command -v ffprobe >/dev/null 2>&1; then
        if ffprobe -v error -select_streams a \
            -show_entries stream=codec_type -of csv=p=0 "$vid" 2>/dev/null \
            | grep -q audio; then
          printf '%s\n' "video-track"
          return 0
        fi
        printf '%s\n' ""
        return 1
      fi
      # No ffprobe: videos often carry a track — show audio controls.
      printf '%s\n' "video"
      return 0
    fi
  fi

  printf '%s\n' ""
  return 1
}

# Properties from project.json (preferred over crashing --list-properties).
# Skips scheme-color UI metadata. Emits a JSON array.
we_wallpaper_properties_from_project() {
  local project=$1
  [[ -f $project ]] || { echo '[]'; return 0; }
  jq '
    def label_of($k; $v):
      (($v.text // "") | tostring) as $t
      | if ($t | length) == 0 or ($t | startswith("ui_")) then $k else $t end;
    def opt_list($v):
      if ($v.options | type) == "array" then
        [ $v.options[] | {
            label: ((.label // .value // "") | tostring),
            value: ((.value // .label // "") | tostring)
          } ]
      else null end;
    [ ((.general.properties // {}) | to_entries[])
      | select(.key != "schemecolor")
      | select((.value.text // "") | tostring | startswith("ui_") | not)
      | {
          key: .key,
          type: ((.value.type // "text") | tostring | ascii_downcase),
          label: label_of(.key; .value),
          value: ((.value.value // "") | tostring),
          min: .value.min,
          max: .value.max,
          step: .value.step,
          order: (.value.order // .value.index // 0),
          options: opt_list(.value),
          editable: (if .value.editable == false then false else true end)
        }
    ] | sort_by(.order)
  ' "$project"
}

# Parse linux-wallpaperengine --list-properties text into JSON array (fallback).
we_parse_list_properties_text() {
  awk '
    BEGIN { print "[" ; n=0 }
    /^Running with:/ { next }
    /^[^ \t].* - / {
      if (n++) printf ",\n"
      key=$0; sub(/ - .*$/, "", key)
      typ=$0; sub(/^.* - /, "", typ)
      gsub(/"/, "\\\"", key); gsub(/"/, "\\\"", typ)
      printf "{\"key\":\"%s\",\"type\":\"%s\",\"label\":\"%s\",\"value\":\"\",\"min\":null,\"max\":null,\"step\":null,\"order\":%d,\"options\":null,\"editable\":true}", key, typ, key, n
      next
    }
    /^\tText: / {
      txt=$0; sub(/^\tText: /, "", txt)
      gsub(/"/, "\\\"", txt)
      # rewrite last object label — simplified: ignore (project.json preferred)
    }
    END { print "\n]" }
  '
}

# Full capability blob for one wallpaper (GUI conditional settings).
# Usage: we_wallpaper_capabilities_json <id|path>
we_wallpaper_capabilities_json() {
  local ref=${1:-}
  [[ -n $ref ]] || {
    echo "Usage: we_wallpaper_capabilities_json <id|path>" >&2
    return 1
  }

  local dir id title type path project props_json has_audio=false audio_reason=""
  local supports_mouse=false supports_parallax=false

  dir=$(we_resolve_wallpaper "$ref" 2>/dev/null || true)
  if [[ -z $dir || ! -d $dir ]]; then
    jq -n --arg ref "$ref" '{
      id: $ref, path: "", title: "", type: "",
      hasAudio: false, audioReason: "",
      supportsMouse: false, supportsParallax: false,
      properties: []
    }'
    return 0
  fi

  path=$(realpath "$dir")
  id=$(basename "$path")
  [[ $id =~ ^[0-9]+$ ]] || id=$ref
  title=$(we_wallpaper_title "$path")
  project="$path/project.json"
  type=""
  if [[ -f $project ]]; then
    type=$(jq -r '(.type // "") | ascii_downcase' "$project" 2>/dev/null || true)
  fi

  props_json=$(we_wallpaper_properties_from_project "$project")
  # Only invoke the engine when project.json is missing — --list-properties can
  # crash and often only re-lists scheme-color metadata.
  if [[ ! -f $project ]] && command -v "$WE_ENGINE_BIN" >/dev/null 2>&1; then
    local raw
    raw=$(timeout 8 "$WE_ENGINE_BIN" --list-properties "$path" 2>/dev/null || true)
    if [[ -n $raw ]]; then
      props_json=$(printf '%s\n' "$raw" | we_parse_list_properties_text \
        | jq '[.[] | select(.key != "schemecolor")]')
    fi
  fi
  [[ -n $props_json ]] || props_json='[]'

  audio_reason=$(we_wallpaper_detect_audio "$path" || true)
  if [[ -n $audio_reason ]]; then
    has_audio=true
  fi

  case "$type" in
    scene|web)
      supports_mouse=true
      supports_parallax=true
      ;;
  esac

  jq -n \
    --arg id "$id" \
    --arg path "$path" \
    --arg title "$title" \
    --arg type "$type" \
    --argjson hasAudio "$has_audio" \
    --arg audioReason "$audio_reason" \
    --argjson supportsMouse "$supports_mouse" \
    --argjson supportsParallax "$supports_parallax" \
    --argjson properties "$props_json" \
    '{
      id: $id,
      path: $path,
      title: $title,
      type: $type,
      hasAudio: $hasAudio,
      audioReason: $audioReason,
      supportsMouse: $supportsMouse,
      supportsParallax: $supportsParallax,
      properties: $properties
    }'
}

# Monitors that have a wallpaper assigned in config (order stable by key).
we_configured_monitors() {
  we_jq -r '.displays | to_entries[] | select(.value.wallpaper != null and (.value.wallpaper | tostring) != "") | .key'
}

# Effective settings for one display: display overrides merged over defaults.
# Used by GUI tabs (one tab = one monitor) and by status --json.
we_effective_display_json() {
  local monitor=${1:-}
  [[ -n $monitor ]] || {
    echo "Usage: we_effective_display_json <monitor>" >&2
    return 1
  }
  we_load_config

  local wallpaper wallpaper_path="" wallpaper_title=""
  wallpaper=$(we_jq -r --arg m "$monitor" \
    '.displays[$m].wallpaper // .defaults.wallpaper // empty')
  if [[ -n $wallpaper ]]; then
    wallpaper_path=$(we_resolve_wallpaper "$wallpaper" 2>/dev/null || true)
    wallpaper_title=$(we_wallpaper_title "${wallpaper_path:-$wallpaper}" 2>/dev/null || true)
  fi

  jq -n \
    --argjson config "$(cat "$WE_CONFIG_FILE")" \
    --arg m "$monitor" \
    --arg wallpaperPath "$wallpaper_path" \
    --arg wallpaperTitle "$wallpaper_title" \
    '
    ($config.defaults // {}) as $d |
    ($config.displays[$m] // {}) as $o |
    (if ($config.displays | has($m)) then true else false end) as $configured |
    ($o.wallpaper // $d.wallpaper // "") as $wp |
    ( ($o.layer // $d.layer // "bottom") as $layer0
      | if $layer0 == "background" then "bottom" else $layer0 end ) as $layer |
    def pick($o; $d; $k; $fallback):
      if ($o | has($k)) then $o[$k]
      elif ($d | has($k)) then $d[$k]
      else $fallback end;
    {
      monitor: $m,
      configured: $configured,
      hasWallpaper: ($wp != null and ($wp | tostring) != ""),
      wallpaper: (if $wp == null then "" else ($wp | tostring) end),
      wallpaperPath: $wallpaperPath,
      wallpaperTitle: $wallpaperTitle,
      scaling: ($o.scaling // $d.scaling // "fill"),
      fps: ($o.fps // $d.fps // 30),
      clamp: ($o.clamp // $d.clamp // "border"),
      silent: pick($o; $d; "silent"; true),
      volume: ($o.volume // $d.volume // 15),
      layer: $layer,
      noFullscreenPause: pick($o; $d; "no_fullscreen_pause"; false),
      fullscreenPauseOnlyActive: pick($o; $d; "fullscreen_pause_only_active"; false),
      fullscreenPauseIgnoreAppIds: pick($o; $d; "fullscreen_pause_ignore_appids"; []),
      noautomute: pick($o; $d; "noautomute"; false),
      noAudioProcessing: pick($o; $d; "no_audio_processing"; false),
      disableParticles: pick($o; $d; "disable_particles"; false),
      disableMouse: pick($o; $d; "disable_mouse"; false),
      disableParallax: pick($o; $d; "disable_parallax"; false),
      properties: (($d.properties // {}) + ($o.properties // {})),
      overrides: $o
    }
    '
}

# Map of monitor → effective settings for every detected + configured display.
we_effective_displays_json() {
  we_load_config
  local -a keys=()
  mapfile -t keys < <({
    we_list_monitors || true
    we_jq -r '.displays | keys[]' 2>/dev/null || true
  } | awk 'NF && !seen[$0]++')

  if ((${#keys[@]} == 0)); then
    echo '{}'
    return 0
  fi

  local m
  local -a objs=()
  for m in "${keys[@]}"; do
    [[ -n $m ]] || continue
    objs+=("$(we_effective_display_json "$m")")
  done
  printf '%s\n' "${objs[@]}" | jq -s 'map({(.monitor): .}) | add // {}'
}

# Machine-readable snapshot for the panel (status + monitors + displays + defaults).
# displays = raw overrides; effectiveDisplays = merged defaults+overrides per monitor.
# engineRunning is live PIDs only (truncated-comm + cmdline; see we_engine_pids).
# Do not key off the pid file / kill -0 shortcut — a reused PID would report
# running while enginePids is empty, which hides Panel Start.
we_status_json() {
  we_load_config
  local monitors_json effective_json pids_json engine_displays_json
  # we_monitors_json prints [] and returns false when no compositor probe is
  # available. Do not append a second fallback array to that valid output.
  monitors_json=$(we_monitors_json 2>/dev/null || true)
  [[ -n $monitors_json ]] || monitors_json='[]'
  effective_json=$(we_effective_displays_json)
  pids_json=$(we_engine_pids | jq -R . | jq -cs 'map(tonumber? // empty)')
  [[ -n $pids_json ]] || pids_json='[]'
  engine_displays_json=$(
    local f identity key
    shopt -s nullglob
    for f in "$WE_PID_DIR"/*.pid; do
      identity=$(we_owned_pid_identity "$f" 2>/dev/null || true)
      [[ -n $identity ]] || continue
      key=${f##*/}
      printf '%s\n' "${key%.pid}"
    done
    shopt -u nullglob
  )
  engine_displays_json=$(printf '%s\n' "$engine_displays_json" | awk 'NF && !seen[$0]++' | jq -R . | jq -cs '.')
  [[ -n $engine_displays_json ]] || engine_displays_json='[]'
  local engine=stopped
  [[ $pids_json != '[]' ]] && engine=running
  local configured_count
  configured_count=$(we_configured_monitors | awk 'NF' | wc -l)
  configured_count=${configured_count// /}
  # Parallel string arrays so Quickshell/QML can bind labels without
  # stringifying V4ReferenceObject wrappers around {name,width,height}.
  local monitor_names_json monitor_titles_json
  monitor_names_json=$(jq -c '[.[] | .name | tostring]' <<<"$monitors_json" 2>/dev/null || echo '[]')
  monitor_titles_json=$(jq -c '
    [.[] |
      if (.width != null and .height != null and .width > 0 and .height > 0)
      then "\(.name) · \(.width)×\(.height)"
      else (.name | tostring)
      end
    ]
  ' <<<"$monitors_json" 2>/dev/null || echo '[]')
  jq -n \
    --argjson config "$(cat "$WE_CONFIG_FILE")" \
    --arg engine "$engine" \
    --arg theme "$(we_current_theme_name)" \
    --argjson monitors "$monitors_json" \
    --argjson monitorNames "$monitor_names_json" \
    --argjson monitorTitles "$monitor_titles_json" \
    --argjson effectiveDisplays "$effective_json" \
    --argjson enginePids "$pids_json" \
    --argjson engineDisplays "$engine_displays_json" \
    --arg configPath "$WE_CONFIG_FILE" \
    --arg logPath "$WE_LOG_FILE" \
    --argjson engineRunning "$([[ $engine == running ]] && echo true || echo false)" \
    --argjson configuredDisplayCount "${configured_count:-0}" \
    --arg autoThemeSlug "$WE_AUTO_THEME_SLUG" \
    '{
      active: ($config.active // false),
      engine: $engine,
      engineRunning: $engineRunning,
      enginePids: $enginePids,
      engineDisplays: $engineDisplays,
      configuredDisplayCount: $configuredDisplayCount,
      hasConfiguredDisplays: ($configuredDisplayCount > 0),
      theme: $theme,
      configPath: $configPath,
      logPath: $logPath,
      defaults: ($config.defaults // {}),
      displays: ($config.displays // {}),
      effectiveDisplays: $effectiveDisplays,
      monitors: $monitors,
      monitorNames: $monitorNames,
      monitorTitles: $monitorTitles,
      workshopDirs: ($config.workshop_dirs // []),
      extraWallpaperDirs: ($config.extra_wallpaper_dirs // []),
      savedThemeBackground: ($config.saved_theme_background // null),
      lastAppliedMonitor: ($config.last_applied.monitor // null),
      lastAppliedWallpaper: ($config.last_applied.wallpaper // null),
      autoThemeActive: (($config.auto_theme.active // false) and ($theme == $autoThemeSlug)),
      autoThemePrevious: ($config.auto_theme.previous_theme // null),
      autoThemeSourceMonitor: ($config.auto_theme.source_monitor // null)
    }'
}

we_display_setting() {
  local monitor=$1 key=$2
  we_jq -r --arg m "$monitor" --arg k "$key" \
    '(.displays[$m][$k] // .defaults[$k] // empty)'
}

we_display_wallpaper() {
  local monitor=$1
  we_jq -r --arg m "$monitor" '.displays[$m].wallpaper // empty'
}

# linux-wallpaperengine is 21 chars; Linux TASK_COMM_LEN is 16 (15 usable), so
# /proc/*/comm is "linux-wallpaper". pgrep/pkill -x rejects patterns >15 chars
# and never matches the full binary name — always use the truncated comm (and/or -f).
WE_ENGINE_COMM="linux-wallpaper"

# A process belongs to this plugin only when its executable matches and its
# kernel start time matches the value captured at launch. PID reuse and other
# user-started Wallpaper Engine instances must never become kill targets.
we_proc_starttime() {
  local pid=${1:-}
  [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
  awk '{print $22}' "/proc/$pid/stat" 2>/dev/null
}

we_is_engine_pid() {
  local pid=${1:-} expected_start=${2:-} exe base expected_base current_start
  [[ $pid =~ ^[1-9][0-9]*$ ]] && (( pid > 1 )) || return 1
  exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
  base=${exe##*/}
  expected_base=${WE_ENGINE_BIN##*/}
  [[ $base == "$expected_base" || $base == linux-wallpaperengine || $base == .linux-wallpaperengine ]] || return 1
  if [[ -n $expected_start ]]; then
    current_start=$(we_proc_starttime "$pid")
    [[ -n $current_start && $current_start == "$expected_start" ]] || return 1
  fi
}

we_owned_pid_identity() {
  local file=$1 pid start extra
  [[ -f $file ]] || return 1
  read -r pid start extra <"$file" || return 1
  [[ -z ${extra:-} ]] || return 1
  if [[ -z ${start:-} ]]; then
    # One-time migration of legacy numeric pidfiles. It is still scoped to a
    # plugin-owned file; capture starttime now before any signal can be sent.
    we_is_engine_pid "$pid" || return 1
    start=$(we_proc_starttime "$pid")
  fi
  we_is_engine_pid "$pid" "$start" || return 1
  printf '%s %s\n' "$pid" "$start"
}

we_engine_identities() {
  local f identity
  local -a files=("$WE_PID_FILE")
  shopt -s nullglob
  files+=("$WE_PID_DIR"/*.pid)
  shopt -u nullglob
  for f in "${files[@]}"; do
    identity=$(we_owned_pid_identity "$f" 2>/dev/null || true)
    if [[ -n $identity ]]; then
      printf '%s\n' "$identity"
    else
      rm -f "$f"
    fi
  done | awk 'NF && !seen[$0]++'
}

we_engine_pids() {
  we_engine_identities | awk '{print $1}'
}

we_engine_running() {
  [[ -n $(we_engine_pids) ]]
}

# No IPC — change settings = kill + restart.
we_stop_engine() {
  local pid start identity f
  local -a identities=()
  mapfile -t identities < <(we_engine_identities)
  rm -f "$WE_PID_FILE"
  shopt -s nullglob
  for f in "$WE_PID_DIR"/*.pid; do rm -f "$f"; done
  shopt -u nullglob
  for identity in "${identities[@]}"; do
    read -r pid start <<<"$identity"
    we_is_engine_pid "$pid" "$start" && kill -TERM -- "$pid" 2>/dev/null || true
  done

  # Brief bounded wait so the compositor releases the layer surface.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    local alive=false
    for identity in "${identities[@]}"; do
      read -r pid start <<<"$identity"
      if we_is_engine_pid "$pid" "$start"; then alive=true; break; fi
    done
    $alive || break
    sleep 0.1
  done
  for identity in "${identities[@]}"; do
    read -r pid start <<<"$identity"
    we_is_engine_pid "$pid" "$start" && kill -KILL -- "$pid" 2>/dev/null || true
  done
}

we_save_theme_background_if_needed() {
  local current
  current=$(we_current_theme_background)
  [[ -n $current && -f $current ]] || return 0
  we_is_placeholder "$current" && return 0

  local existing
  existing=$(we_jq -r '.saved_theme_background // empty')
  if [[ -z $existing || ! -f $existing ]] || we_is_placeholder "$existing"; then
    we_jq_write --arg p "$current" '.saved_theme_background = $p'
  fi
}

# Plugin overlay owns the user-visible wipe (TransitionOverlay.qml).
# Omarchy Background.qml is ONE image with PreserveAspectCrop per screen —
# a spanning mosaic fed to omarchy-theme-bg-set is center-cropped independently
# on every output and cannot show two different wallpapers. Never use that as
# the apply/revert visual.
#
#   1. Stage FROM (last-reveal / LWE FBO / theme) and TO completely while the
#      desktop remains interactive. Grim is the final fallback only.
#   2. Map the transition on the Bottom layer so it never covers applications,
#      the bar, notifications, or input feedback.
#   3. Keep FROM until TO Image.Ready, then run the 420ms slant. Stop LWE
#      only after wipe-covered (FROM Ready on every head).
#   4. Overlay stays on TO. Start LWE under it (--layer bottom) with
#      --screenshot $STATE/lwe-ready.jpg (FBO dump; process keeps running).
#   5. Wait until LWE is mapped on every apply output, setInstant placeholder
#      under LWE, poll the FBO dump for structure (not grim, not mean luma),
#      THEN instant-hide. The sole exception is the exact upstream OpenGL
#      readback failure, guarded by replacement-PID layer ownership and grace.
#      Never infer readiness from an unexplained missing or clear dump.
# If overlay never covers, apply still stop+starts LWE (hard cut). Never no-op.
# Do not hide at wipe-done or at hyprctl map — both reveal black.
#
# WE_BG_REVEAL_MS is the QML animation duration. Overlay waits Image.Ready
# before starting the wipe. WE_BG_LAYER_WAIT_MS polls for the LWE bottom layer.
# WE_LWE_READY_MS is the max wait for a structured FBO (not a hide-anyway pad).
# Large Scene packages can spend several seconds loading assets and compiling
# shaders before the delayed screenshot is written. LWE has no ready IPC.
# linux-wallpaperengine r627 clamps --screenshot-delay to 0..5 frames. Some
# drivers also fail its FBO readback even while the compositor shows a healthy
# layer; WE_LWE_READBACK_GRACE_MS gates that narrowly detected fallback.
# WE_BG_CANVAS_WAIT_MS covers pre-map grim/ffmpeg still generation only.
WE_BG_REVEAL_MS="${WE_BG_REVEAL_MS:-420}"
WE_BG_REVEAL_LOAD_MS="${WE_BG_REVEAL_LOAD_MS:-160}"
WE_BG_REVEAL_PAD_MS="${WE_BG_REVEAL_PAD_MS:-80}"
WE_BG_PAINT_MS="${WE_BG_PAINT_MS:-150}"
WE_BG_FILE_WAIT_MS="${WE_BG_FILE_WAIT_MS:-2000}"
WE_BG_CANVAS_WAIT_MS="${WE_BG_CANVAS_WAIT_MS:-8000}"
WE_BG_OVERLAY_COVER_MS="${WE_BG_OVERLAY_COVER_MS:-2500}"
WE_BG_OVERLAY_DONE_MS="${WE_BG_OVERLAY_DONE_MS:-2500}"
WE_BG_LAYER_WAIT_MS="${WE_BG_LAYER_WAIT_MS:-1500}"
WE_LWE_READY_MS="${WE_LWE_READY_MS:-15000}"
WE_LWE_READBACK_GRACE_MS="${WE_LWE_READBACK_GRACE_MS:-1000}"
WE_LWE_SCREENSHOT="${WE_LWE_SCREENSHOT:-$WE_STATE_DIR/lwe-ready.jpg}"
# Upstream accepts the option but clamps it to five frames; mirror that limit.
WE_LWE_SCREENSHOT_DELAY="${WE_LWE_SCREENSHOT_DELAY:-5}"
WE_LWE_PAINT_EPS="${WE_LWE_PAINT_EPS:-8}"
WE_GRIM_TIMEOUT_S="${WE_GRIM_TIMEOUT_S:-8}"
WE_FFMPEG_TIMEOUT_S="${WE_FFMPEG_TIMEOUT_S:-6}"
WE_BG_QUEUE_WAIT_S="${WE_BG_QUEUE_WAIT_S:-5}"
WE_CURRENT_BACKGROUND_LINK="${WE_CURRENT_BACKGROUND_LINK:-$HOME/.local/state/omarchy/current/background}"
WE_LAST_REVEAL_FILE="${WE_LAST_REVEAL_FILE:-$WE_STATE_DIR/last-reveal}"
WE_TRANSITION_LOG="${WE_TRANSITION_LOG:-$WE_STATE_DIR/transition.log}"
WE_WIPE_REQUEST="${WE_WIPE_REQUEST:-$WE_STATE_DIR/wipe-request.json}"
WE_WIPE_COVERED="${WE_WIPE_COVERED:-$WE_STATE_DIR/wipe-covered}"
WE_WIPE_DONE="${WE_WIPE_DONE:-$WE_STATE_DIR/wipe-done}"

# Single-flight lock for apply / revert / stop / theme-set placeholder.
# linux-wallpaperengine must not inherit fd 9 (see we_start_engine). Never wait
# forever behind a crashed transition; callers receive a retryable busy error.
we_bg_queue_enter() {
  we_ensure_dirs
  if [[ ${WE_BG_QUEUE_HELD:-0} -eq 1 ]]; then
    return 0
  fi
  exec 9>"$WE_BG_QUEUE_LOCK"
  if ! flock -w "$WE_BG_QUEUE_WAIT_S" 9; then
    exec 9>&-
    echo "Wallpaper transition is busy; try again." >&2
    return 1
  fi
  WE_BG_QUEUE_HELD=1
}

we_bg_queue_leave() {
  if [[ ${WE_BG_QUEUE_HELD:-0} -ne 1 ]]; then
    return 0
  fi
  flock -u 9 2>/dev/null || true
  exec 9>&-
  WE_BG_QUEUE_HELD=0
}

we_transition_log() {
  we_ensure_dirs
  local ts
  ts=$(date '+%H:%M:%S.%3N')
  # stderr + log file only — never stdout (callers capture paths via $())
  printf '[we-transition %s] %s\n' "$ts" "$*" | tee -a "$WE_TRANSITION_LOG" >&2
}

# Animated path. Do not use omarchy-shell -q here: -q always exits 0.
we_omarchy_bg_set() {
  local path=$1 rc=0
  [[ -n $path && -f $path ]] || return 1
  path=$(realpath "$path")
  we_transition_log "background set $path"
  ln -nsf "$path" "$WE_CURRENT_BACKGROUND_LINK"
  if command -v omarchy-theme-bg-set >/dev/null 2>&1; then
    timeout -k 1 3 omarchy-theme-bg-set "$path" >/dev/null 2>&1
    rc=$?
  else
    rc=127
  fi
  if (( rc != 0 )); then
    we_transition_log "omarchy-theme-bg-set rc=$rc; trying omarchy-shell background set"
    if command -v omarchy-shell >/dev/null 2>&1; then
      timeout -k 1 3 omarchy-shell background set "$path" >/dev/null 2>&1 || {
        we_transition_log "omarchy-shell background set failed"
        return 1
      }
    else
      return 1
    fi
  fi
  we_transition_log "background set returned"
}

# Instant update (under LWE / after LWE maps) — no reveal wipe.
we_omarchy_bg_set_instant() {
  local path=$1
  [[ -n $path && -f $path ]] || return 1
  path=$(realpath "$path")
  we_transition_log "setInstant $path"
  ln -nsf "$path" "$WE_CURRENT_BACKGROUND_LINK"
  if command -v omarchy-shell >/dev/null 2>&1; then
    timeout -k 1 3 omarchy-shell background setInstant "$path" >/dev/null 2>&1 || {
      we_transition_log "setInstant IPC failed"
      return 1
    }
  fi
}

# Explicit FROM→TO wipe. Unique TO paths defeat Background.qml's
# `finalPath === currentBackground` skip. Prefer `transition` so oldBackground
# is the FROM still even if displayedBackground was not updated yet.
we_omarchy_bg_transition() {
  local from=${1:-} to=$2
  [[ -n $to && -f $to ]] || return 1
  to=$(realpath "$to")
  if [[ -n $from && -f $from ]]; then
    from=$(realpath "$from")
    we_transition_log "background transition from=$from to=$to"
    ln -nsf "$to" "$WE_CURRENT_BACKGROUND_LINK"
    if command -v omarchy-shell >/dev/null 2>&1 \
      && timeout -k 1 3 omarchy-shell background transition "$from" "$to" >/dev/null 2>&1; then
      we_transition_log "background transition returned"
      return 0
    fi
    we_transition_log "transition IPC failed; falling back to background set"
  fi
  we_omarchy_bg_set "$to"
}

we_now_ms() {
  local sec frac
  sec=${EPOCHREALTIME%.*}
  frac=${EPOCHREALTIME#*.}
  if [[ -z ${EPOCHREALTIME-} || $sec == "$EPOCHREALTIME" ]]; then
    date +%s%3N
    return
  fi
  frac=${frac}000
  printf '%d\n' $((10#$sec * 1000 + 10#${frac:0:3}))
}

we_wait_ms() {
  local ms=${1:-0}
  if [[ ! $ms =~ ^[0-9]+$ ]] || (( ms <= 0 )); then
    return 0
  fi
  sleep "$(awk -v ms="$ms" 'BEGIN { printf "%.3f", ms / 1000 }')" 2>/dev/null \
    || sleep 1
}

# Quiet time after kicking `background set`: QML wipe + Image.Ready + pad.
we_bg_reveal_wait_ms() {
  printf '%s\n' $((WE_BG_REVEAL_MS + WE_BG_REVEAL_LOAD_MS + WE_BG_REVEAL_PAD_MS))
}

we_wait_bg_reveal() {
  we_wait_ms "${1:-$(we_bg_reveal_wait_ms)}"
}

we_same_file() {
  local a=$1 b=$2
  [[ -n $a && -n $b && -f $a && -f $b ]] || return 1
  [[ $(realpath "$a") == $(realpath "$b") ]]
}

we_image_ext() {
  local f=$1
  local ext=${f##*.}
  ext=${ext,,}
  case "$ext" in
    jpg|jpeg|png|webp|gif|bmp) printf '%s\n' "$ext" ;;
    *) printf '%s\n' "png" ;;
  esac
}

we_file_is_image() {
  local path=$1 mime dims w h
  [[ -n $path && -f $path ]] || return 1
  local size
  size=$(stat -c%s "$path" 2>/dev/null || echo 0)
  [[ $size =~ ^[0-9]+$ ]] && (( size > 32 )) || return 1
  if command -v file >/dev/null 2>&1; then
    mime=$(file --mime-type -b "$path" 2>/dev/null || true)
    [[ $mime == image/* ]] || return 1
  fi
  dims=$(we_image_dimensions "$path")
  [[ $dims =~ ^[0-9]+[[:space:]]+[0-9]+$ ]] || return 1
  w=${dims%% *}
  h=${dims##* }
  (( w >= 2 && h >= 2 ))
}

# Wait until $1 exists, size is stable, and it is a real image (not empty/non-image).
we_wait_image_ready() {
  local path=$1
  local timeout=${2:-$WE_BG_FILE_WAIT_MS}
  local start now size prev=-1 stable=0
  [[ -n $path ]] || return 1
  start=$(we_now_ms)
  while true; do
    if [[ -f $path ]]; then
      size=$(stat -c%s "$path" 2>/dev/null || echo 0)
      if [[ $size =~ ^[0-9]+$ ]] && (( size > 32 )); then
        if (( size == prev )); then
          stable=$((stable + 1))
          if (( stable >= 2 )); then
            we_file_is_image "$path" && return 0
            stable=0
          fi
        else
          stable=0
          prev=$size
        fi
      fi
    fi
    now=$(we_now_ms)
    if (( now - start >= timeout )); then
      we_file_is_image "$path" && return 0
      return 1
    fi
    sleep 0.03
  done
}

# Copy $1 into WE_TRANSITION_DIR as a unique path, then wait until it is
# loadable. Prints the new path. Unique names make every `background set` a new
# currentBackground so Omarchy cannot skip the wipe. Always copy (never
# hardlink) so FROM/TO are distinct inodes even when they come from one source.
we_stage_transition_image() {
  local src=$1
  local tag=${2:-img}
  local ext dest
  [[ -n $src && -f $src ]] || return 1
  we_ensure_dirs
  we_wait_image_ready "$src" || return 1
  src=$(realpath "$src")
  ext=$(we_image_ext "$src")
  dest="$WE_TRANSITION_DIR/${tag}-$(we_now_ms)-$$.$ext"
  cp -f "$src" "$dest" || return 1
  we_wait_image_ready "$dest" || return 1
  we_transition_log "staged $tag $(stat -c%s "$dest" 2>/dev/null || echo 0)B inode=$(stat -c%i "$dest" 2>/dev/null || echo ?) → $dest"
  realpath "$dest"
}

# Drop staged stills except the paths passed as arguments.
we_prune_transitions() {
  local f k skip
  [[ -d $WE_TRANSITION_DIR ]] || return 0
  shopt -s nullglob
  for f in "$WE_TRANSITION_DIR"/*; do
    skip=false
    for k in "$@"; do
      [[ -n $k && -e $k ]] || continue
      if [[ $f == "$k" ]] || we_same_file "$f" "$k"; then
        skip=true
        break
      fi
    done
    $skip || rm -f "$f"
  done
  shopt -u nullglob
}

we_remember_reveal_image() {
  local p=${1:-} mon=${2:-}
  we_ensure_dirs
  [[ -n $p && -f $p ]] || return 0
  we_file_is_image "$p" || return 0
  p=$(realpath "$p")
  we_atomic_line "$WE_LAST_REVEAL_FILE" "$p"
  if [[ -n $mon ]]; then
    we_atomic_line "$WE_STATE_DIR/last-reveal.${mon}" "$p"
  fi
}

we_last_reveal_image() {
  local mon=${1:-} f p
  if [[ -n $mon ]]; then
    f="$WE_STATE_DIR/last-reveal.${mon}"
    if [[ -f $f ]]; then
      p=$(cat "$f" 2>/dev/null || true)
      if [[ -n $p && -f $p ]] && we_file_is_image "$p"; then
        printf '%s\n' "$p"
        return 0
      fi
      rm -f "$f"
    fi
    # Named lookup: do not fall through to another head's still.
    return 1
  fi
  [[ -f $WE_LAST_REVEAL_FILE ]] || return 1
  p=$(cat "$WE_LAST_REVEAL_FILE" 2>/dev/null || true)
  if [[ -z $p || ! -f $p ]] || ! we_file_is_image "$p"; then
    rm -f "$WE_LAST_REVEAL_FILE"
    return 1
  fi
  printf '%s\n' "$p"
}

we_remember_wipe_stills() {
  local json=${1:-} name path
  [[ -n $json && $json != '[]' ]] || return 0
  while IFS=$'\t' read -r name path; do
    [[ -n $path && -f $path ]] || continue
    we_file_is_image "$path" || continue
    we_is_placeholder "$path" && continue
    we_remember_reveal_image "$path" "$name"
  done < <(jq -r '.[] | [.name, (if ((.to // "") | length) > 0 then .to else (.from // "") end)] | @tsv' <<<"$json" 2>/dev/null || true)
}

we_clear_last_reveal() {
  rm -f "$WE_LAST_REVEAL_FILE"
  rm -f "$WE_STATE_DIR"/last-reveal.*
}

we_prune_transition_history() {
  local f p
  local -a keep=()
  shopt -s nullglob
  for f in "$WE_LAST_REVEAL_FILE" "$WE_STATE_DIR"/last-reveal.*; do
    [[ -f $f ]] || continue
    p=$(cat "$f" 2>/dev/null || true)
    [[ -n $p && -f $p ]] && we_file_is_image "$p" && keep+=("$p")
  done
  shopt -u nullglob
  p=$(readlink -f "$WE_CURRENT_BACKGROUND_LINK" 2>/dev/null || true)
  [[ -n $p && -f $p ]] && keep+=("$p")
  we_prune_transitions "${keep[@]}"
}

# True once Hyprland has mapped linux-wallpaperengine on a layer (usually bottom).
# With no args: any output. With names: every named output (live hyprctl keys).
we_engine_layer_mapped() {
  command -v hyprctl >/dev/null 2>&1 || return 1
  local json
  json=$(timeout -k 1 "${WE_HYPRCTL_TIMEOUT_S:-2}" hyprctl layers -j 2>/dev/null) || return 1
  if (($# == 0)); then
    jq -e '
      [.. | objects | select(.namespace == "linux-wallpaperengine" and ((.alpha // 0) > 0))]
      | length > 0
    ' >/dev/null 2>&1 <<<"$json"
    return
  fi
  local m
  for m in "$@"; do
    [[ -n $m ]] || continue
    jq -e --arg m "$m" '
      [(.[$m] // {}) | .. | objects
        | select(.namespace == "linux-wallpaperengine" and ((.alpha // 0) > 0))]
      | length > 0
    ' >/dev/null 2>&1 <<<"$json" || return 1
  done
  return 0
}

# True only when the specified process owns the LWE layer. During per-display
# replacement the old and new renderers overlap, so namespace alone can match
# the old wallpaper and is not a readiness signal for the replacement.
we_engine_pid_layer_mapped() {
  local pid=${1:-}
  shift || true
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  command -v hyprctl >/dev/null 2>&1 || return 1
  local json
  json=$(timeout -k 1 "${WE_HYPRCTL_TIMEOUT_S:-2}" hyprctl layers -j 2>/dev/null) || return 1
  if (($# == 0)); then
    jq -e --arg pid "$pid" '
      [.. | objects
        | select(.namespace == "linux-wallpaperengine"
          and ((.alpha // 0) > 0)
          and ((.pid // "") | tostring) == $pid)]
      | length > 0
    ' >/dev/null 2>&1 <<<"$json"
    return
  fi
  local m
  for m in "$@"; do
    [[ -n $m ]] || continue
    jq -e --arg m "$m" --arg pid "$pid" '
      [(.[$m] // {}) | .. | objects
        | select(.namespace == "linux-wallpaperengine"
          and ((.alpha // 0) > 0)
          and ((.pid // "") | tostring) == $pid)]
      | length > 0
    ' >/dev/null 2>&1 <<<"$json" || return 1
  done
  return 0
}

we_wait_engine_layer() {
  local timeout=${1:-$WE_BG_LAYER_WAIT_MS}
  shift || true
  local start now
  start=$(we_now_ms)
  while true; do
    if we_engine_layer_mapped "$@"; then
      return 0
    fi
    now=$(we_now_ms)
    if (( now - start >= timeout )); then
      return 1
    fi
    sleep 0.05
  done
}

# Decode the entire LWE FBO dump and print painted, clear, or incomplete.
# Header/dimension probes are insufficient while LWE is writing a JPEG in
# place: they can succeed before the compressed pixel stream is complete.
we_lwe_fbo_state() {
  local path=${1:-$WE_LWE_SCREENSHOT}
  local eps=${2:-$WE_LWE_PAINT_EPS}
  local state
  [[ -n $path && -f $path ]] || {
    printf '%s\n' incomplete
    return 0
  }
  state=$(we_compose_py paint-state "$path" --epsilon "$eps" 2>/dev/null) \
    || state=incomplete
  case $state in
    painted|clear|incomplete) printf '%s\n' "$state" ;;
    *) printf '%s\n' incomplete ;;
  esac
}

# LWE FBO dump (--screenshot) is painted when it is not a uniform ~0 clear.
# Do not use mean brightness (dark wallpapers) or compositor grim (sees TO).
we_lwe_fbo_painted() {
  [[ $(we_lwe_fbo_state "${1:-$WE_LWE_SCREENSHOT}" "${2:-$WE_LWE_PAINT_EPS}") == painted ]]
}

# True only for linux-wallpaperengine's known FBO readback failure. Keep this
# exact: a merely black screenshot must not be promoted to a successful apply.
we_lwe_fbo_readback_failed() {
  local log_file=${1:-} monitor=${2:-}
  [[ -n $log_file && -f $log_file && -n $monitor ]] || return 1
  grep -Fq -- "Cannot obtain pixel data for screen $monitor. OpenGL error: 1282" "$log_file"
}

# The screenshot is one-shot. If its readback failed but the replacement PID
# owns the target layer, keep the old renderer/overlay in place for a bounded
# grace period and require both process identity and layer ownership to remain
# stable. This handles an unavailable probe, never an arbitrary black frame.
we_wait_lwe_readback_grace() {
  local engine_pid=${1:-} engine_start=${2:-} monitor=${3:-} log_file=${4:-}
  local timeout=${5:-$WE_LWE_READBACK_GRACE_MS}
  local start now
  we_lwe_fbo_readback_failed "$log_file" "$monitor" || return 1
  we_is_engine_pid "$engine_pid" "$engine_start" || return 1
  we_engine_pid_layer_mapped "$engine_pid" "$monitor" || return 1
  start=$(we_now_ms)
  we_transition_log "LWE FBO readback unavailable on $monitor; holding PID $engine_pid for ${timeout}ms grace"
  while true; do
    we_is_engine_pid "$engine_pid" "$engine_start" || {
      we_transition_log "LWE exited during readback fallback grace"
      return 1
    }
    we_engine_pid_layer_mapped "$engine_pid" "$monitor" || {
      we_transition_log "LWE PID $engine_pid lost its $monitor layer during readback fallback grace"
      return 1
    }
    now=$(we_now_ms)
    if (( now - start >= timeout )); then
      we_transition_log "LWE ready via guarded readback fallback on $monitor (PID $engine_pid)"
      return 0
    fi
    sleep 0.05
  done
}

# Overlay still shows TO. hyprctl map/alpha is not a paint signal.
# Poll until the one-shot FBO screenshot exists and fully decodes. A structured
# image is confirmed paint. Before treating a fully decoded clear image as
# final, its size/mtime/inode must stay unchanged across polls and the tri-state
# probe must confirm clear again. A stable clear image fails unless the exact
# guarded readback fallback above succeeds. Return 1 at WE_LWE_READY_MS for a
# missing/incomplete image. Optional identity, monitor, and log arguments let
# per-display replacements use the fallback and fail if LWE exits.
we_wait_engine_first_paint() {
  local timeout=${1:-$WE_LWE_READY_MS}
  local engine_pid=${2:-} engine_start=${3:-} monitor=${4:-} log_file=${5:-}
  local start now state clear_signature="" signature confirmed_signature
  start=$(we_now_ms)
  we_transition_log "polling LWE FBO $WE_LWE_SCREENSHOT (max ${timeout}ms; require structure or guarded readback fallback)"
  while true; do
    state=$(we_lwe_fbo_state)
    case $state in
      painted)
        we_transition_log "LWE FBO painted"
        return 0
        ;;
      clear)
        signature=$(stat -Lc '%s:%y:%i' "$WE_LWE_SCREENSHOT" 2>/dev/null || true)
        if [[ -n $signature && $signature == "$clear_signature" ]]; then
          state=$(we_lwe_fbo_state)
          confirmed_signature=$(stat -Lc '%s:%y:%i' "$WE_LWE_SCREENSHOT" 2>/dev/null || true)
          if [[ $state == painted ]]; then
            we_transition_log "LWE FBO painted after stable-file confirmation"
            return 0
          fi
          if [[ $state == clear && $confirmed_signature == "$signature" ]]; then
            if [[ -n $engine_pid && -n $engine_start && -n $monitor && -n $log_file ]] \
              && we_wait_lwe_readback_grace \
                "$engine_pid" "$engine_start" "$monitor" "$log_file"; then
              return 0
            fi
            we_transition_log "LWE FBO is a complete stable clear image; one-shot readiness probe failed"
            return 1
          fi
        fi
        clear_signature=$signature
        ;;
      *)
        clear_signature=""
        ;;
    esac
    if [[ -n $engine_pid && -n $engine_start ]] \
      && ! we_is_engine_pid "$engine_pid" "$engine_start"; then
      we_transition_log "LWE exited before producing a painted FBO"
      return 1
    fi
    now=$(we_now_ms)
    if (( now - start >= timeout )); then
      if [[ ! -f $WE_LWE_SCREENSHOT ]]; then
        we_transition_log "LWE FBO missing after ${timeout}ms; keeping overlay"
      else
        we_transition_log "LWE FBO still clear after ${timeout}ms; keeping overlay"
      fi
      return 1
    fi
    sleep 0.04
  done
}

# --screenshot-delay is frames, but upstream r627 clamps it to 0..5. Keep the
# plugin value honest instead of implying that a larger configured delay works.
we_lwe_screenshot_delay() {
  local delay=${WE_LWE_SCREENSHOT_DELAY:-5}
  [[ $delay =~ ^[0-9]+$ ]] || delay=5
  (( delay > 5 )) && delay=5
  printf '%s\n' "$delay"
}

# Hyprland layersIn/Out fade the wipe surface through transparent → black LWE.
# Named rule so re-apply updates rather than stacking. Plugin-only (no hypr edit).
we_hypr_wipe_no_anim() {
  command -v hyprctl >/dev/null 2>&1 || return 0
  timeout -k 1 "${WE_HYPRCTL_TIMEOUT_S:-2}" hyprctl eval 'hl.layer_rule({ name = "we-wipe-no-anim", match = { namespace = "wallpaper-engine-wipe" }, no_anim = true, animation = "none" })' >/dev/null 2>&1 || true
}

# True once linux-wallpaperengine is gone from Hyprland layers and has no PIDs.
we_wait_engine_unmapped() {
  local timeout=${1:-$WE_BG_LAYER_WAIT_MS}
  local start now
  start=$(we_now_ms)
  while true; do
    if [[ -z $(we_engine_pids) ]] && ! we_engine_layer_mapped; then
      return 0
    fi
    now=$(we_now_ms)
    if (( now - start >= timeout )); then
      if [[ -z $(we_engine_pids) ]] && ! we_engine_layer_mapped; then
        return 0
      fi
      return 1
    fi
    sleep 0.05
  done
}

# Wait until the Omarchy background symlink points at $1 (FROM still on disk).
we_wait_omarchy_showing() {
  local want=$1
  local timeout=${2:-$WE_BG_FILE_WAIT_MS}
  local start now cur
  [[ -n $want && -f $want ]] || return 1
  want=$(realpath "$want")
  start=$(we_now_ms)
  while true; do
    cur=$(readlink -f "$WE_CURRENT_BACKGROUND_LINK" 2>/dev/null || true)
    if [[ $cur == "$want" ]]; then
      return 0
    fi
    now=$(we_now_ms)
    if (( now - start >= timeout )); then
      we_transition_log "FROM symlink wait timed out now=${cur:-none} want=$want"
      return 1
    fi
    sleep 0.05
  done
}

we_compose_py() {
  command -v python3 >/dev/null 2>&1 || return 1
  [[ -f $WE_COMPOSE_PY ]] || return 1
  python3 "$WE_COMPOSE_PY" "$@"
}

# Bounding-box canvas for whatever outputs hyprctl reports right now.
we_layout_json() {
  local monitors
  monitors=$(we_monitors_json 2>/dev/null || echo '[]')
  we_compose_py layout <<<"$monitors"
}

we_image_dimensions() {
  local path=$1
  we_compose_py dims "$path" 2>/dev/null || true
}

we_canvas_dims_match() {
  local path=$1 w=$2 h=$3
  [[ -n $path && -f $path && $w =~ ^[0-9]+$ && $h =~ ^[0-9]+$ ]] || return 1
  we_compose_py verify "$path" "$w" "$h" >/dev/null 2>&1
}

# Live pixels of one named output (name from hyprctl, never hardcoded).
we_capture_output_still() {
  local mon=${1:-} dest=${2:-} timeout_s=${WE_GRIM_TIMEOUT_S}
  command -v grim >/dev/null 2>&1 || return 1
  [[ -n $mon ]] || return 1
  we_ensure_dirs
  if [[ -z $dest ]]; then
    dest="$WE_TRANSITION_DIR/out-${mon}-$(we_now_ms)-$$.jpg"
  fi
  we_transition_log "grim -o $mon → $dest"
  if timeout "$timeout_s" grim -t jpeg -q 92 -o "$mon" "$dest" >/dev/null 2>&1 \
    && we_wait_image_ready "$dest" "$WE_BG_CANVAS_WAIT_MS"; then
    we_transition_log "grim -o $mon ok $(stat -c%s "$dest" 2>/dev/null || echo 0)B $(we_image_dimensions "$dest")"
    printf '%s\n' "$(realpath "$dest")"
    return 0
  fi
  rm -f "$dest"
  we_transition_log "grim -o $mon failed"
  return 1
}

we_compose_regions_to_canvas() {
  local layout_json=$1 regions_json=$2 dest=$3
  local layout_file regions_file w h
  [[ -n $layout_json && -n $regions_json && -n $dest ]] || return 1
  we_ensure_dirs
  layout_file=$(mktemp "$WE_TRANSITION_DIR/layout.XXXXXX.json")
  regions_file=$(mktemp "$WE_TRANSITION_DIR/regions.XXXXXX.json")
  printf '%s\n' "$layout_json" >"$layout_file"
  printf '%s\n' "$regions_json" >"$regions_file"
  if ! we_compose_py compose "$layout_file" "$regions_file" "$dest"; then
    rm -f "$layout_file" "$regions_file"
    return 1
  fi
  rm -f "$layout_file" "$regions_file"
  w=$(jq -r '.width' <<<"$layout_json")
  h=$(jq -r '.height' <<<"$layout_json")
  we_wait_image_ready "$dest" "$WE_BG_CANVAS_WAIT_MS" || return 1
  if ! we_canvas_dims_match "$dest" "$w" "$h"; then
    we_transition_log "compose dim mismatch want=${w}x${h} got=$(we_image_dimensions "$dest")"
    return 1
  fi
  we_transition_log "composed canvas ${w}x${h} $(stat -c%s "$dest" 2>/dev/null || echo 0)B → $dest"
  printf '%s\n' "$(realpath "$dest")"
}

# FROM: live pixels of every output. Prefer grim with no -o (full layout).
# If that size does not match the hyprctl bounding box, grim each output and
# composite onto the layout canvas. Never grim a single "main" / focused tab.
we_capture_from_canvas() {
  local layout dest w h dims got_w got_h name shot regions_json
  layout=$(we_layout_json 2>/dev/null || true)
  [[ -n $layout ]] || return 1
  w=$(jq -r '.width' <<<"$layout")
  h=$(jq -r '.height' <<<"$layout")
  [[ $w =~ ^[0-9]+$ && $h =~ ^[0-9]+$ ]] || return 1
  (( w > 0 && h > 0 )) || return 1
  we_ensure_dirs
  dest="$WE_TRANSITION_DIR/from-canvas-$(we_now_ms)-$$.jpg"
  we_transition_log "FROM layout ${w}x${h} outputs=$(jq -r '[.monitors[].name] | join(",")' <<<"$layout")"

  if command -v grim >/dev/null 2>&1; then
    we_transition_log "grim (full layout, no -o) → $dest"
    if timeout "$WE_GRIM_TIMEOUT_S" grim -t jpeg -q 92 "$dest" >/dev/null 2>&1 \
      && we_wait_image_ready "$dest" "$WE_BG_CANVAS_WAIT_MS"; then
      dims=$(we_image_dimensions "$dest")
      got_w=${dims%% *}
      got_h=${dims##* }
      if [[ $got_w == "$w" && $got_h == "$h" ]]; then
        we_transition_log "FROM grim-full ok ${got_w}x${got_h} $(stat -c%s "$dest" 2>/dev/null || echo 0)B"
        printf '%s\n' "$(realpath "$dest")"
        return 0
      fi
      we_transition_log "FROM grim-full ${got_w}x${got_h} != layout ${w}x${h}; compositing per output"
      rm -f "$dest"
    else
      we_transition_log "FROM grim-full failed; compositing per output"
      rm -f "$dest"
    fi
  fi

  regions_json='[]'
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    shot=$(we_capture_output_still "$name" "$WE_TRANSITION_DIR/from-${name}-$(we_now_ms)-$$.jpg" || true)
    if [[ -n $shot && -f $shot ]]; then
      regions_json=$(jq -c --arg n "$name" --arg p "$shot" '. + [{name: $n, path: $p}]' <<<"$regions_json")
    fi
  done < <(jq -r '.monitors[].name' <<<"$layout")

  if [[ $(jq 'length' <<<"$regions_json") -eq 0 ]]; then
    we_transition_log "FROM: no per-output grim succeeded"
    return 1
  fi
  we_compose_regions_to_canvas "$layout" "$regions_json" "$dest"
}

# Video file for a workshop dir (project.json file / type, else first media).
we_wallpaper_video_file() {
  local dir=$1
  local project=$dir/project.json file="" type=""
  [[ -d $dir ]] || return 1
  if [[ -f $project ]]; then
    file=$(jq -r '.file // empty' "$project" 2>/dev/null || true)
    type=$(jq -r '(.type // "") | ascii_downcase' "$project" 2>/dev/null || true)
    if [[ -n $file && -f $dir/$file ]]; then
      case "${file,,}" in
        *.mp4|*.webm|*.mkv|*.avi|*.mov|*.m4v)
          printf '%s\n' "$dir/$file"
          return 0
          ;;
      esac
      if [[ $type == video ]]; then
        printf '%s\n' "$dir/$file"
        return 0
      fi
    fi
  fi
  file=$(find "$dir" -maxdepth 2 -type f \
    \( -iname '*.mp4' -o -iname '*.webm' -o -iname '*.mkv' -o -iname '*.avi' -o -iname '*.mov' \) \
    -printf '%s\t%p\n' 2>/dev/null | sort -nr | head -n1 | cut -f2-)
  [[ -n $file && -f $file ]] || return 1
  printf '%s\n' "$file"
}

# Highest-res raster in a workshop folder. Never prefers preview.jpg.
# Gif is considered after larger jpg/png/webp (see compose_desktop.best_still).
we_wallpaper_best_still() {
  local dir=$1
  [[ -d $dir ]] || return 1
  we_compose_py best-still "$dir"
}

# Any on-disk preview.* (project.json first, then jpg/png/webp, then gif).
we_wallpaper_preview_file() {
  local dir=$1 f resolved
  dir=$(realpath -e -- "$dir" 2>/dev/null) || return 1
  [[ -d $dir ]] || return 1
  f=$(we_wallpaper_preview "$dir" 2>/dev/null || true)
  if [[ -n $f && -f $f ]]; then
    printf '%s\n' "$f"
    return 0
  fi
  for f in "$dir"/preview.jpg "$dir"/preview.jpeg "$dir"/preview.png \
           "$dir"/preview.webp "$dir"/preview.bmp "$dir"/preview.gif; do
    resolved=$(we_canonical_project_file "$dir" "$f" 2>/dev/null || true)
    if [[ -n $resolved ]]; then
      printf '%s\n' "$resolved"
      return 0
    fi
  done
  return 1
}

we_ffmpeg_fill_frame() {
  local vid=$1 w=$2 h=$3 dest=$4 mode=${5:-fill}
  local vf ss
  local -a seeks
  command -v ffmpeg >/dev/null 2>&1 || return 1
  [[ -f $vid && $w =~ ^[0-9]+$ && $h =~ ^[0-9]+$ ]] || return 1
  case "$mode" in
    stretch)
      vf="scale=${w}:${h}"
      ;;
    fit)
      vf="scale=${w}:${h}:force_original_aspect_ratio=decrease,pad=${w}:${h}:(ow-iw)/2:(oh-ih)/2:black"
      ;;
    *)
      vf="scale=${w}:${h}:force_original_aspect_ratio=increase,crop=${w}:${h}"
      ;;
  esac
  # Gif: first frame only. Video: skip ~1s of intro black, then try t=0.
  case "${vid,,}" in
    *.gif) seeks=(0) ;;
    *) seeks=(1 0) ;;
  esac
  for ss in "${seeks[@]}"; do
    if timeout -k 1 "$WE_FFMPEG_TIMEOUT_S" ffmpeg -y -hide_banner -loglevel error \
      -ss "$ss" -i "$vid" -an -frames:v 1 -vf "$vf" "$dest" >/dev/null 2>&1 \
      && we_wait_image_ready "$dest" "$WE_BG_CANVAS_WAIT_MS"; then
      if we_canvas_dims_match "$dest" "$w" "$h"; then
        return 0
      fi
      # Frame extracted but not exact WxH — cover-crop it.
      local tmp
      tmp="${dest}.raw.jpg"
      mv -f "$dest" "$tmp"
      if we_compose_py cover "$tmp" "$w" "$h" "$dest" --mode "$mode" \
        && we_canvas_dims_match "$dest" "$w" "$h"; then
        rm -f "$tmp"
        return 0
      fi
      rm -f "$tmp" "$dest"
    fi
    rm -f "$dest"
  done
  return 1
}

# Native WxH still of the wallpaper that will run on one output.
# Video → ffmpeg frame at monitor resolution. Scene/web → largest raster
# (never preview.jpg). No placeholder — a black TO is the apply fade-to-black.
we_render_output_still() {
  local ref=$1 w=$2 h=$3 dest=$4 mode=${5:-fill}
  local dir vid still still_ext preview
  [[ -n $ref && $w =~ ^[0-9]+$ && $h =~ ^[0-9]+$ && -n $dest ]] || return 1
  dir=$(we_resolve_wallpaper "$ref" 2>/dev/null || true)
  [[ -n $dir && -d $dir ]] || return 1
  we_ensure_dirs

  vid=$(we_wallpaper_video_file "$dir" 2>/dev/null || true)
  if [[ -n $vid && -f $vid ]]; then
    we_transition_log "TO still ffmpeg ${w}x${h} mode=$mode ← $vid"
    if we_ffmpeg_fill_frame "$vid" "$w" "$h" "$dest" "$mode"; then
      printf '%s\n' "$(realpath "$dest")"
      return 0
    fi
    we_transition_log "ffmpeg frame failed for $vid"
  fi

  still=$(we_wallpaper_best_still "$dir" 2>/dev/null || true)
  if we_is_preview_still "${still:-}"; then
    we_transition_log "TO still skipped preview $(basename "$still")"
    still=""
  fi
  if [[ -n $still && -f $still ]]; then
    still_ext=${still##*.}
    still_ext=${still_ext,,}
    if [[ $still_ext == gif ]]; then
      we_transition_log "TO still ffmpeg gif ${w}x${h} mode=$mode ← $still ($(we_image_dimensions "$still"))"
      if we_ffmpeg_fill_frame "$still" "$w" "$h" "$dest" "$mode"; then
        printf '%s\n' "$(realpath "$dest")"
        return 0
      fi
      we_transition_log "ffmpeg gif frame failed for $still"
      still=""
    fi
  fi
  if [[ -n $still && -f $still ]] && ! we_is_preview_still "$still"; then
    we_transition_log "TO still raster ${w}x${h} mode=$mode ← $still ($(we_image_dimensions "$still"))"
    if we_compose_py cover "$still" "$w" "$h" "$dest" --mode "$mode" \
      && we_wait_image_ready "$dest" "$WE_BG_CANVAS_WAIT_MS"; then
      printf '%s\n' "$(realpath "$dest")"
      return 0
    fi
  fi

  we_transition_log "TO still unavailable ${w}x${h} for $dir (no native raster/video)"
  return 1
}

we_theme_or_saved_image() {
  local candidate
  candidate=$(we_jq -r '.saved_theme_background // empty')
  if [[ -n $candidate && -f $candidate ]] && ! we_is_placeholder "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi
  candidate=$(we_current_theme_background)
  if [[ -n $candidate && -f $candidate ]] && ! we_is_placeholder "$candidate"; then
    printf '%s\n' "$candidate"
    return 0
  fi
  candidate=$(we_first_theme_background)
  if [[ -n $candidate && -f $candidate ]]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

# True if $1 is in the remaining positional names (changed apply-tab outputs).
we_name_in_list() {
  local want=$1
  shift
  local n
  for n in "$@"; do
    [[ $n == "$want" ]] && return 0
  done
  return 1
}

# TO canvas: every hyprctl output, native WxH region, same bounding box as FROM.
# Changed names (apply-tab args) get a rendered still of that output's *config*
# wallpaper. Other outputs keep live grim (or that output's current wallpaper
# still). Unconfigured outputs: grim, else theme image fill-cropped to that region.
# Pass --theme as the first arg to fill every region with the theme background.
we_build_to_canvas() {
  local fill_theme=false
  if [[ ${1:-} == --theme ]]; then
    fill_theme=true
    shift
  fi
  local -a changed=("$@")
  local layout dest w h name mw mh wp path scaling shot still regions_json theme
  layout=$(we_layout_json 2>/dev/null || true)
  [[ -n $layout ]] || return 1
  w=$(jq -r '.width' <<<"$layout")
  h=$(jq -r '.height' <<<"$layout")
  [[ $w =~ ^[0-9]+$ && $h =~ ^[0-9]+$ ]] || return 1
  we_ensure_dirs
  dest="$WE_TRANSITION_DIR/to-canvas-$(we_now_ms)-$$.jpg"
  regions_json='[]'
  theme=""
  if $fill_theme; then
    theme=$(we_theme_or_saved_image 2>/dev/null || true)
  fi
  we_transition_log "TO layout ${w}x${h} changed=${changed[*]:-all-configured} theme=$fill_theme"

  while IFS=$'\t' read -r name mw mh; do
    [[ -n $name ]] || continue
    shot=""
    still=""
    wp=$(we_display_wallpaper "$name" 2>/dev/null || true)
    scaling=$(we_display_setting "$name" scaling 2>/dev/null || true)
    [[ -n $scaling ]] || scaling=fill

    if $fill_theme && [[ -n $theme && -f $theme ]]; then
      still="$WE_TRANSITION_DIR/to-${name}-theme-$(we_now_ms)-$$.jpg"
      we_compose_py cover "$theme" "$mw" "$mh" "$still" --mode fill || still=""
    elif [[ -n $wp ]] && { ((${#changed[@]} == 0)) || we_name_in_list "$name" "${changed[@]}"; }; then
      still="$WE_TRANSITION_DIR/to-${name}-$(we_now_ms)-$$.jpg"
      we_render_output_still "$wp" "$mw" "$mh" "$still" "$scaling" >/dev/null || still=""
    else
      shot=$(we_capture_output_still "$name" "$WE_TRANSITION_DIR/to-${name}-live-$(we_now_ms)-$$.jpg" || true)
      if [[ -z $shot || ! -f $shot ]] && [[ -n $wp ]]; then
        still="$WE_TRANSITION_DIR/to-${name}-$(we_now_ms)-$$.jpg"
        we_render_output_still "$wp" "$mw" "$mh" "$still" "$scaling" >/dev/null || still=""
      elif [[ -z $shot || ! -f $shot ]]; then
        theme=$(we_theme_or_saved_image 2>/dev/null || true)
        if [[ -n $theme && -f $theme ]]; then
          still="$WE_TRANSITION_DIR/to-${name}-theme-$(we_now_ms)-$$.jpg"
          we_compose_py cover "$theme" "$mw" "$mh" "$still" --mode fill || still=""
        fi
      fi
    fi

    if [[ -n $still && -f $still ]]; then
      we_wait_image_ready "$still" "$WE_BG_CANVAS_WAIT_MS" || true
      regions_json=$(jq -c --arg n "$name" --arg p "$(realpath "$still")" '. + [{name: $n, path: $p}]' <<<"$regions_json")
      we_transition_log "TO region $name ${mw}x${mh} render"
    elif [[ -n $shot && -f $shot ]]; then
      regions_json=$(jq -c --arg n "$name" --arg p "$(realpath "$shot")" '. + [{name: $n, path: $p}]' <<<"$regions_json")
      we_transition_log "TO region $name ${mw}x${mh} grim"
    else
      we_transition_log "TO region $name ${mw}x${mh} MISSING"
    fi
  done < <(jq -r '.monitors[] | [.name, (.width|tostring), (.height|tostring)] | @tsv' <<<"$layout")

  if [[ $(jq 'length' <<<"$regions_json") -eq 0 ]]; then
    we_transition_log "TO: no regions produced"
    return 1
  fi
  we_compose_regions_to_canvas "$layout" "$regions_json" "$dest"
}

# FROM fallback if grim/compose fails: last canvas / current Omarchy bg / theme.
we_from_image_for_wipe() {
  local to=${1:-} candidate=""
  candidate=$(we_last_reveal_image 2>/dev/null || true)
  if [[ -n $candidate && -f $candidate ]] && ! we_same_file "$candidate" "$to"; then
    printf '%s\n' "$candidate"
    return 0
  fi
  candidate=$(we_current_theme_background)
  if [[ -n $candidate && -f $candidate ]] && ! we_is_placeholder "$candidate" \
    && ! we_same_file "$candidate" "$to"; then
    printf '%s\n' "$candidate"
    return 0
  fi
  candidate=$(we_jq -r '.saved_theme_background // empty')
  if [[ -n $candidate && -f $candidate ]] && ! we_is_placeholder "$candidate" \
    && ! we_same_file "$candidate" "$to"; then
    printf '%s\n' "$candidate"
    return 0
  fi
  candidate=$(we_first_theme_background)
  if [[ -n $candidate && -f $candidate ]] && ! we_same_file "$candidate" "$to"; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

# Instant FROM cover: last-reveal per head (QML lastFrame if path omitted).
# Grim only when that head has no still — never block on TO ffmpeg/compose.
we_build_from_cover_outputs() {
  local layout name mx my mw mh from_path candidate crop_path
  local min_x min_y canvas_w canvas_h crop_x crop_y
  local outputs_json='[]'
  layout=$(we_layout_json 2>/dev/null || true)
  [[ -n $layout ]] || return 1
  min_x=$(jq -r '.min_x' <<<"$layout")
  min_y=$(jq -r '.min_y' <<<"$layout")
  canvas_w=$(jq -r '.width' <<<"$layout")
  canvas_h=$(jq -r '.height' <<<"$layout")
  we_ensure_dirs
  we_transition_log "FROM cover first (last-reveal / LWE frame / theme; grim only if missing)"

  while IFS=$'\t' read -r name mx my mw mh; do
    [[ -n $name ]] || continue
    from_path=$(we_last_reveal_image "$name" 2>/dev/null || true)
    if [[ -n $from_path && -f $from_path ]] && ! we_file_is_image "$from_path"; then
      from_path=""
    fi
    if [[ -n $from_path && -f $from_path ]] && we_is_placeholder "$from_path"; then
      from_path=""
    fi
    # The engine's FBO dump contains wallpaper pixels only, unlike grim which
    # captures applications and makes a bottom-layer transition look ghosted.
    if [[ -z $from_path || ! -f $from_path ]] \
      && we_lwe_fbo_painted "$WE_LWE_SCREENSHOT" \
      && we_canvas_dims_match "$WE_LWE_SCREENSHOT" "$canvas_w" "$canvas_h"; then
      crop_x=$((mx - min_x))
      crop_y=$((my - min_y))
      crop_path="$WE_TRANSITION_DIR/from-${name}-lwe-$(we_now_ms)-$$.jpg"
      if we_compose_py crop "$WE_LWE_SCREENSHOT" "$crop_x" "$crop_y" "$mw" "$mh" "$crop_path" \
        && we_wait_image_ready "$crop_path" "$WE_BG_FILE_WAIT_MS"; then
        from_path=$crop_path
        we_transition_log "FROM cover $name cropped from LWE FBO"
      fi
    fi
    if [[ -z $from_path || ! -f $from_path ]]; then
      candidate=$(we_theme_or_saved_image 2>/dev/null || true)
      if [[ -n $candidate && -f $candidate ]] && we_file_is_image "$candidate" \
        && ! we_is_placeholder "$candidate"; then
        from_path=$candidate
      fi
    fi
    # Grim only on the lastFrame-miss fallback. Warm apply uses last-reveal.
    if [[ -z $from_path || ! -f $from_path ]] && [[ ${WE_FROM_COVER_ALLOW_GRIM:-0} == 1 ]]; then
      from_path=$(we_capture_output_still "$name" \
        "$WE_TRANSITION_DIR/from-${name}-cover-$(we_now_ms)-$$.jpg" || true)
    fi
    if [[ -n $from_path && -f $from_path ]]; then
      from_path=$(realpath "$from_path")
      # to=from so shownPath never falls through to empty while TO is staged.
      outputs_json=$(jq -c --arg n "$name" --arg f "$from_path" \
        '. + [{name: $n, from: $f, to: $f}]' <<<"$outputs_json")
      we_transition_log "FROM cover $name $(basename "$from_path")"
    else
      # QML lastFrame / holdPath can still paint this head.
      outputs_json=$(jq -c --arg n "$name" '. + [{name: $n, from: "", to: ""}]' <<<"$outputs_json")
      we_transition_log "FROM cover $name pending lastFrame"
    fi
  done < <(jq -r '.monitors[] | [.name, (.x|tostring), (.y|tostring), (.width|tostring), (.height|tostring)] | @tsv' <<<"$layout")

  if [[ $(jq 'length' <<<"$outputs_json") -eq 0 ]]; then
    we_transition_log "FROM cover: no outputs"
    return 1
  fi
  printf '%s\n' "$outputs_json"
}

# Per-output FROM/TO for the plugin overlay. Never a spanning mosaic.
# When WE_FROM_COVER_JSON is set, reuse those FROM paths (overlay already
# showing). Recapture grim only if a head still has no file.
we_build_wipe_outputs() {
  local fill_theme=false
  if [[ ${1:-} == --theme ]]; then
    fill_theme=true
    shift
  fi
  local -a changed=("$@")
  local layout name mw mh from_path to_path wp scaling shot still theme
  local to_json='[]' outputs_json='[]'
  layout=$(we_layout_json 2>/dev/null || true)
  [[ -n $layout ]] || return 1
  we_ensure_dirs
  theme=""
  if $fill_theme; then
    theme=$(we_theme_or_saved_image 2>/dev/null || true)
    if [[ -z $theme || ! -f $theme ]]; then
      we_transition_log "wipe TO: no theme image"
      return 1
    fi
    theme=$(we_stage_transition_image "$theme" "theme") || theme=""
    [[ -n $theme && -f $theme ]] || return 1
  fi
  local cover_json=${WE_FROM_COVER_JSON:-[]}
  [[ -n $cover_json && $cover_json != '[]' ]] || cover_json='[]'
  we_transition_log "wipe TO under FROM cover. changed=${changed[*]:-all-configured} theme=$fill_theme"

  while IFS=$'\t' read -r name mw mh; do
    [[ -n $name ]] || continue
    to_path=""
    shot=""
    still=""
    wp=$(we_display_wallpaper "$name" 2>/dev/null || true)
    scaling=$(we_display_setting "$name" scaling 2>/dev/null || true)
    [[ -n $scaling ]] || scaling=fill
    from_path=$(jq -r --arg n "$name" '.[] | select(.name == $n) | .from // empty' <<<"$cover_json" 2>/dev/null || true)

    if $fill_theme; then
      to_path=$theme
    elif [[ -n $wp ]] && { ((${#changed[@]} == 0)) || we_name_in_list "$name" "${changed[@]}"; }; then
      still="$WE_TRANSITION_DIR/to-${name}-$(we_now_ms)-$$.jpg"
      to_path=$(we_render_output_still "$wp" "$mw" "$mh" "$still" "$scaling" || true)
      if [[ -z $to_path || ! -f $to_path ]]; then
        we_transition_log "wipe TO $name has no native still — holding FROM cover (no black placeholder)"
        to_path=$from_path
      fi
    else
      # Unchanged head: TO is the FROM already on the overlay. No grim.
      if [[ -n $from_path && -f $from_path ]]; then
        to_path=$from_path
      else
        to_path=$(we_last_reveal_image "$name" 2>/dev/null || true)
      fi
      if [[ -z $to_path || ! -f $to_path ]] && [[ -n $wp ]]; then
        still="$WE_TRANSITION_DIR/to-${name}-$(we_now_ms)-$$.jpg"
        to_path=$(we_render_output_still "$wp" "$mw" "$mh" "$still" "$scaling" || true)
      fi
      if [[ -z $to_path || ! -f $to_path ]]; then
        to_path=$(we_capture_output_still "$name" \
          "$WE_TRANSITION_DIR/to-${name}-live-$(we_now_ms)-$$.jpg" || true)
      fi
    fi

    if [[ -z $to_path || ! -f $to_path ]]; then
      we_transition_log "wipe TO missing for $name — abort"
      return 1
    fi
    we_wait_image_ready "$to_path" "$WE_BG_CANVAS_WAIT_MS" || return 1
    to_path=$(realpath "$to_path")
    to_json=$(jq -c --arg n "$name" --arg t "$to_path" --argjson w "$mw" --argjson h "$mh" \
      '. + [{name: $n, to: $t, width: $w, height: $h}]' <<<"$to_json")
    we_transition_log "wipe TO $name $(basename "$to_path") ${mw}x${mh}"
  done < <(jq -r '.monitors[] | [.name, (.width|tostring), (.height|tostring)] | @tsv' <<<"$layout")

  # FROM: reuse cover. Grim only if that head still has no file (overlay is up).
  while IFS=$'\t' read -r name mw mh; do
    [[ -n $name ]] || continue
    to_path=$(jq -r --arg n "$name" '.[] | select(.name == $n) | .to' <<<"$to_json")
    from_path=$(jq -r --arg n "$name" '.[] | select(.name == $n) | .from // empty' <<<"$cover_json" 2>/dev/null || true)
    if [[ -z $from_path || ! -f $from_path ]]; then
      from_path=$(we_last_reveal_image "$name" 2>/dev/null || true)
    fi
    if [[ -z $from_path || ! -f $from_path ]]; then
      we_transition_log "FROM $name missing after cover; grim under overlay"
      from_path=$(we_capture_output_still "$name" \
        "$WE_TRANSITION_DIR/from-${name}-$(we_now_ms)-$$.jpg" || true)
    fi
    if [[ -z $from_path || ! -f $from_path ]]; then
      from_path=$(we_from_image_for_wipe "$to_path" || true)
    fi
    if [[ -z $from_path || ! -f $from_path ]]; then
      from_path=$to_path
    fi
    we_wait_image_ready "$from_path" "$WE_BG_CANVAS_WAIT_MS" || true
    from_path=$(realpath "$from_path")
    outputs_json=$(jq -c --arg n "$name" --arg f "$from_path" --arg t "$to_path" \
      '. + [{name: $n, from: $f, to: $t}]' <<<"$outputs_json")
    we_transition_log "wipe FROM $name $(basename "$from_path") (cover reuse)"
  done < <(jq -r '.monitors[] | [.name, (.width|tostring), (.height|tostring)] | @tsv' <<<"$layout")

  if [[ $(jq 'length' <<<"$outputs_json") -eq 0 ]]; then
    we_transition_log "wipe: no outputs"
    return 1
  fi
  printf '%s\n' "$outputs_json"
}

# omarchy-shell -q always exits 0 — never use it to probe we-wipe.
# timeout -k: omarchy-shell can ignore SIGTERM; without -k this stalls apply
# forever and the GUI's set-display+apply chain never restarts LWE.
we_wipe_ipc() {
  command -v omarchy-shell >/dev/null 2>&1 || return 1
  timeout -k 1 1 omarchy-shell "$@" >/dev/null 2>&1
}

we_wipe_available() {
  we_wipe_ipc we-wipe ping
}

we_wipe_nudge() {
  # FileView can miss an atomic replace; IpcHandler we-wipe is the backup.
  # Never rescanPlugins here — that call can ignore SIGTERM and wedge apply
  # after set-display has already written the new wallpaper ids.
  local phase=${1:-wipe} payload=""
  if [[ $phase == hide || $phase == idle ]]; then
    we_wipe_ipc we-wipe hide || true
    return 0
  fi
  payload=$(cat "$WE_WIPE_REQUEST" 2>/dev/null || true)
  [[ -n $payload ]] || return 0
  if we_wipe_ipc we-wipe play "$payload"; then
    return 0
  fi
  we_transition_log "we-wipe IPC missing; FileView may still cover"
  return 1
}

we_wipe_request_write() {
  local id=$1 phase=$2 outputs_json=${3:-[]}
  local tmp revision created expires previous revision_tmp revision_fd
  we_ensure_dirs
  created=$(we_now_ms)
  expires=$((created + 20000))
  exec {revision_fd}>"$WE_STATE_DIR/wipe-revision.lock"
  flock -w 1 "$revision_fd" || return 1
  previous=$(cat "$WE_STATE_DIR/wipe-revision" 2>/dev/null || echo 0)
  [[ $previous =~ ^[0-9]+$ ]] || previous=0
  revision=$created
  (( revision > previous )) || revision=$((previous + 1))
  revision_tmp=$(mktemp "$WE_STATE_DIR/wipe-revision.tmp.XXXXXX")
  printf '%s\n' "$revision" >"$revision_tmp"
  mv -f "$revision_tmp" "$WE_STATE_DIR/wipe-revision"
  flock -u "$revision_fd"
  exec {revision_fd}>&-
  tmp=$(mktemp "$WE_TRANSITION_DIR/wipe-req.XXXXXX.json")
  jq -n --arg id "$id" --arg phase "$phase" --argjson outputs "$outputs_json" \
    --argjson revision "$revision" --argjson created "$created" --argjson expires "$expires" \
    '{id:$id, phase:$phase, outputs:$outputs, force:true,
      revision:$revision, createdMs:$created, expiresMs:$expires}' >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv -f "$tmp" "$WE_WIPE_REQUEST"
  # One authoritative file plus IPC. The former overlay.json alias delivered
  # every transition twice and could replay older state after a later hide.
  # FileView is the primary load path. IPC miss must not abort the overlay wait.
  we_wipe_nudge "$phase" || true
}

we_wipe_wait_signal() {
  local file=$1 want=$2 timeout=${3:-$WE_BG_CANVAS_WAIT_MS}
  local start now got
  [[ -n $want ]] || return 1
  start=$(we_now_ms)
  while true; do
    got=$(cat "$file" 2>/dev/null || true)
    if [[ $got == "$want" ]]; then
      return 0
    fi
    now=$(we_now_ms)
    if (( now - start >= timeout )); then
      we_transition_log "overlay signal wait timed out file=$(basename "$file") want=$want now=${got:-none}"
      return 1
    fi
    sleep 0.04
  done
}

# Cover desktop with FROM stills, then wait. Does not stop LWE — caller stops
# after covered (wipe) or on cover timeout (hard-cut restart with current config).
# File queue + omarchy-shell we-wipe play '<json>' (FileView + IPC).
we_overlay_begin() {
  local outputs_json=$1
  local timeout=${2:-$WE_BG_OVERLAY_COVER_MS}
  local id
  [[ -n $outputs_json && $outputs_json != '[]' ]] || return 1
  we_hypr_wipe_no_anim
  id="wipe-$(we_now_ms)-$$"
  rm -f "$WE_WIPE_COVERED" "$WE_WIPE_DONE"
  we_wipe_request_write "$id" "wipe" "$outputs_json" || return 1
  WE_WIPE_ID=$id
  we_transition_log "overlay request $id outputs=$(jq -c '[.[].name]' <<<"$outputs_json" 2>/dev/null || echo '?')"
  if ! we_wipe_wait_signal "$WE_WIPE_COVERED" "$id" "$timeout"; then
    we_transition_log "overlay did not cover"
    we_overlay_end
    return 1
  fi
  we_transition_log "overlay covered"
}

# Wipe-done means TO is parked on the overlay — do NOT hide here.
we_overlay_wait_done() {
  local id=${WE_WIPE_ID:-}
  [[ -n $id ]] || return 1
  we_wipe_wait_signal "$WE_WIPE_DONE" "$id" "$WE_BG_OVERLAY_DONE_MS"
}

# Merge TO into the already-covering wipe. Same id — QML must not unmap FROM.
we_overlay_set_to() {
  local outputs_json=$1
  local id=${WE_WIPE_ID:-}
  [[ -n $id ]] || return 1
  [[ -n $outputs_json && $outputs_json != '[]' ]] || return 1
  rm -f "$WE_WIPE_DONE"
  we_wipe_request_write "$id" "to" "$outputs_json" || return 1
  we_transition_log "overlay TO update $id"
}

# FROM on screen first, then TO under that still. Returns 0 if overlay covered.
# Sets wipe_outputs for the caller. Stops LWE only after FROM Ready (covered).
we_overlay_cover_then_to() {
  local from_cover="" cover_ms=$WE_BG_OVERLAY_COVER_MS
  wipe_outputs=""

  # Stage every potentially slow destination frame before mapping a full-screen
  # layer. Video decoding/ffmpeg may take seconds; the desktop must remain live
  # throughout that work. Once mapped, the overlay only performs image decode
  # plus the short reveal animation.
  from_cover=$(we_build_from_cover_outputs || true)
  if [[ -n $from_cover && $from_cover != '[]' ]]; then
    WE_FROM_COVER_JSON=$from_cover
    wipe_outputs=$(we_build_wipe_outputs "$@" || true)
    unset WE_FROM_COVER_JSON
    if [[ -n $wipe_outputs && $wipe_outputs != '[]' ]]; then
      if [[ $(jq '[.[] | select((.from // "") | length > 0)] | length' <<<"$wipe_outputs" 2>/dev/null || echo 0) -eq 0 ]]; then
        cover_ms=400
      fi
      if we_overlay_begin "$wipe_outputs" "$cover_ms"; then
        we_remember_wipe_stills "$from_cover"
        if we_engine_running; then
          we_uncover_omarchy_from
        fi
        return 0
      fi
    fi
  fi

  we_transition_log "pre-staged cover missed lastFrame; capture once while desktop remains visible"
  WE_FROM_COVER_ALLOW_GRIM=1
  from_cover=$(we_build_from_cover_outputs || true)
  unset WE_FROM_COVER_ALLOW_GRIM
  if [[ -n $from_cover && $from_cover != '[]' ]]; then
    WE_FROM_COVER_JSON=$from_cover
    wipe_outputs=$(we_build_wipe_outputs "$@" || true)
    unset WE_FROM_COVER_JSON
    if [[ -n $wipe_outputs && $wipe_outputs != '[]' ]] && we_overlay_begin "$wipe_outputs"; then
      we_remember_wipe_stills "$from_cover"
      if we_engine_running; then
        we_uncover_omarchy_from
      fi
      return 0
    fi
  fi
  return 1
}

# Instant hide of the parked still. Only call when LWE is painted (or revert
# has already set the theme). Never fade — Hyprland layersOut is disabled first.
we_overlay_end() {
  we_hypr_wipe_no_anim
  we_wipe_request_write "hide-$(we_now_ms)" "hide" '[]' || true
  WE_WIPE_ID=""
}

# Placeholder under WE (lock/blur). Instant — layer bottom hides Background.
# Safe while the overlay still covers TO. After hide, LWE must already be painted.
we_apply_placeholder() {
  [[ -f $WE_PLACEHOLDER ]] || return 0
  we_omarchy_bg_set_instant "$WE_PLACEHOLDER" || true
}

# Stop LWE. Overlay path calls this after covered; hard-cut path calls it anyway.
we_uncover_omarchy_from() {
  if ! we_engine_running; then
    we_transition_log "LWE already stopped"
    return 0
  fi
  we_transition_log "stopping LWE"
  we_stop_engine
  if ! we_wait_engine_unmapped; then
    we_transition_log "LWE unmap wait timed out (pids=$(we_engine_pids | paste -sd, -))"
  else
    we_transition_log "LWE unmapped"
  fi
}

# Stock Omarchy IPC wipe — not used as the user-visible apply/revert visual
# (mosaic + PreserveAspectCrop). Hard-fail if LWE still covers.
we_fire_omarchy_wipe() {
  local to=$1
  local from=${2:-}
  [[ -n $to && -f $to ]] || return 1
  we_wait_image_ready "$to" || return 1
  if we_engine_layer_mapped; then
    we_transition_log "REFUSING Omarchy wipe: LWE still mapped"
    return 1
  fi
  we_omarchy_bg_transition "$from" "$to" || return 1
}

we_play_omarchy_wipe() {
  we_fire_omarchy_wipe "$@" || return 1
  we_wait_bg_reveal
}

# Never restore the placeholder as a "theme" background.
we_first_theme_background() {
  local theme_name
  theme_name=$(we_current_theme_name)
  find -L \
    "$HOME/.config/omarchy/backgrounds/$theme_name" \
    "$HOME/.local/state/omarchy/current/theme/backgrounds" \
    -maxdepth 1 -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.gif' -o -iname '*.bmp' \) \
    ! -name 'we-placeholder.png' \
    2>/dev/null | sort | head -n1
}

# Undo any accidental disable from older plugin versions; Omarchy bg stays enabled.
we_ensure_omarchy_background_enabled() {
  rm -f "$WE_BG_WAS_DISABLED_FLAG"
  if command -v omarchy-plugin-list >/dev/null 2>&1; then
    if omarchy-plugin-list 2>/dev/null | awk '$1=="omarchy.background" && $2=="disabled"{found=1} END{exit !found}'; then
      omarchy plugin enable omarchy.background >/dev/null 2>&1 || true
    fi
  fi
}

# Property key names from this wallpaper's project.json (not a previous scene).
we_wallpaper_property_keys_json() {
  local dir=${1:-} project
  if [[ -z $dir || ! -d $dir ]]; then
    echo '[]'
    return 0
  fi
  project=$dir/project.json
  if [[ ! -f $project ]]; then
    echo '[]'
    return 0
  fi
  jq -c '[((.general.properties // {}) | keys[]) | select(. != "schemecolor")]' "$project" 2>/dev/null \
    || echo '[]'
}

# Build linux-wallpaperengine argv for one or more monitors.
# Official flag order per output: --screen-root NAME --bg ID --scaling MODE --clamp MODE
# Global: --layer bottom --fps N --silent (or --volume).
# --screenshot / --screenshot-delay: one FBO dump (process keeps running).
# Speed: only via --set-property (no global playback-speed flag exists).
#
# The current runtime calls this with exactly one monitor per process. Read every
# process-wide option from that monitor's effective config so a global default
# can never override the display tab. Multi-monitor support remains for the
# legacy migration path and uses the first monitor's effective settings.
we_build_engine_argv() {
  local -n _we_argv=$1
  shift
  local monitors=("$@")
  _we_argv=()

  local primary=${monitors[0]:-} effective
  [[ -n $primary ]] || return 1
  effective=$(we_effective_display_json "$primary")

  local layer fps silent volume nfp pause_only_active pause_ignore_json assets
  local noautomute no_audio_processing disable_particles disable_mouse disable_parallax
  layer=$(jq -r '.layer // "bottom"' <<<"$effective")
  # Authoritative Omarchy guidance: never use background (fights omarchy.background).
  [[ $layer == background ]] && layer=bottom
  fps=$(jq -r '.fps // 30' <<<"$effective")
  silent=$(jq -r 'if .silent == null then true else .silent end' <<<"$effective")
  volume=$(jq -r '.volume // 15' <<<"$effective")
  nfp=$(jq -r '.noFullscreenPause // false' <<<"$effective")
  pause_only_active=$(jq -r '.fullscreenPauseOnlyActive // false' <<<"$effective")
  pause_ignore_json=$(jq -c '.fullscreenPauseIgnoreAppIds // []' <<<"$effective")
  noautomute=$(jq -r '.noautomute // false' <<<"$effective")
  no_audio_processing=$(jq -r '.noAudioProcessing // false' <<<"$effective")
  disable_particles=$(jq -r '.disableParticles // false' <<<"$effective")
  disable_mouse=$(jq -r '.disableMouse // false' <<<"$effective")
  disable_parallax=$(jq -r '.disableParallax // false' <<<"$effective")
  assets=$(we_jq -r '.assets_dir // empty')

  _we_argv+=(--layer "$layer" --fps "$fps")
  if [[ $silent == true || $silent == True ]]; then
    _we_argv+=(--silent)
  else
    _we_argv+=(--volume "$volume")
  fi
  [[ $noautomute == true || $noautomute == True ]] && _we_argv+=(--noautomute)
  [[ $no_audio_processing == true || $no_audio_processing == True ]] && _we_argv+=(--no-audio-processing)
  [[ $nfp == true || $nfp == True ]] && _we_argv+=(--no-fullscreen-pause)
  if [[ $nfp != true && $nfp != True && ($pause_only_active == true || $pause_only_active == True) ]]; then
    _we_argv+=(--fullscreen-pause-only-active)
  fi
  if [[ $nfp != true && $nfp != True && $pause_ignore_json != '[]' ]]; then
    local ignored_appid
    while IFS= read -r ignored_appid; do
      [[ -n $ignored_appid ]] && _we_argv+=(--fullscreen-pause-ignore-appid "$ignored_appid")
    done < <(jq -r '.[] | tostring' <<<"$pause_ignore_json")
  fi
  [[ $disable_particles == true || $disable_particles == True ]] && _we_argv+=(--disable-particles)
  [[ $disable_mouse == true || $disable_mouse == True ]] && _we_argv+=(--disable-mouse)
  [[ $disable_parallax == true || $disable_parallax == True ]] && _we_argv+=(--disable-parallax)
  [[ -n $assets ]] && _we_argv+=(--assets-dir "$assets")
  # FBO dump for first-paint detection; the selected display layer is retained.
  if [[ -n ${WE_LWE_SCREENSHOT:-} ]]; then
    local delay
    delay=$(we_lwe_screenshot_delay "$fps")
    _we_argv+=(--screenshot "$WE_LWE_SCREENSHOT" --screenshot-delay "$delay")
  fi

  local wallpaper scaling clamp resolved props
  for m in "${monitors[@]}"; do
    wallpaper=$(we_display_wallpaper "$m")
    [[ -n $wallpaper ]] || continue
    scaling=$(we_display_setting "$m" scaling)
    clamp=$(we_display_setting "$m" clamp)
    [[ -n $scaling ]] || scaling=fill
    [[ -n $clamp ]] || clamp=border
    resolved=$(we_resolve_wallpaper "$wallpaper")

    # scaling/clamp apply to the previous --screen-root/--bg group.
    _we_argv+=(--screen-root "$m" --bg "$resolved" --scaling "$scaling" --clamp "$clamp")

    # Only --set-property keys the CURRENT wallpaper exposes. Stale keys from a
    # previous scene on this display (or defaults.properties) must not leak into
    # this display's linux-wallpaperengine argv.
    props=$(we_jq -c --arg m "$m" \
      '((.defaults.properties // {}) + (.displays[$m].properties // {}))')
    local keys='[]'
    keys=$(we_wallpaper_property_keys_json "$resolved")
    if [[ $keys != '[]' && $props != '{}' && $props != null ]]; then
      props=$(jq -c --argjson keys "$keys" \
        'to_entries | map(select(.key as $k | $keys | index($k) != null)) | from_entries' \
        <<<"$props")
    else
      props='{}'
    fi
    if [[ $props != '{}' && $props != null ]]; then
      while IFS=$'\t' read -r k v; do
        [[ -n $k ]] && _we_argv+=(--set-property "${k}=${v}")
      done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<<"$props")
    fi
  done
}

# Start (or restart) the engine with ALL configured displays from config.
#
# GUI call sequence (one tab = one display):
#   1. we set-display <mon> --wallpaper … --scaling … --fps …   # write that tab only
#   2. we apply [monitor]   # queue FROM/TO canvases for every hyprctl output,
#      wipe, then restart the engine with the full configured set
#   3. we status --json  /  we display-config <mon> --json      # re-bind the UI
#
# Optional monitor args do NOT limit the engine to those outputs — that would drop
# other monitors' wallpapers from the single linux-wallpaperengine process.
# They only mark which TO regions are re-rendered (apply-tab); siblings keep
# live grim / current wallpaper stills in the same canvas.
we_start_engine() {
  we_bg_queue_enter
  we_load_config
  command -v "$WE_ENGINE_BIN" >/dev/null 2>&1 || {
    echo "Missing dependency: $WE_ENGINE_BIN (install linux-wallpaperengine-git from AUR)" >&2
    return 1
  }

  we_ensure_omarchy_background_enabled

  local monitors=()
  local m wallpaper
  mapfile -t monitors < <(we_configured_monitors)

  # Optional args: ensure named monitors are configured with a wallpaper.
  # Still rebuild argv from the full configured set so sibling displays stay live.
  if [[ $# -gt 0 ]]; then
    for m in "$@"; do
      [[ -n $m ]] || continue
      wallpaper=$(we_display_wallpaper "$m")
      if [[ -z $wallpaper ]]; then
        echo "Display $m has no wallpaper in config. Use: we set-display $m --wallpaper <id>" >&2
        return 1
      fi
    done
  fi

  if ((${#monitors[@]} == 0)); then
    echo "No displays configured. Use the menu or: we set-display <monitor> --wallpaper <id>" >&2
    return 1
  fi

  we_save_theme_background_if_needed

  we_ensure_dirs

  local -a args=()
  we_build_engine_argv args "${monitors[@]}"
  if ((${#args[@]} == 0)); then
    echo "Failed to build engine arguments." >&2
    return 1
  fi

  local wipe_outputs="" running=false overlay_ok=false overlay_done=false
  local -a changed=()
  if [[ $# -gt 0 ]]; then
    for m in "$@"; do
      [[ -n $m ]] && changed+=("$m")
    done
  fi

  we_transition_log "apply start plugin=$WE_PLUGIN_ROOT changed=${changed[*]:-all-configured} engine=$(we_engine_running && echo running || echo stopped)"

  # Overlay is cosmetic. set-display already wrote config; apply MUST stop+start
  # LWE with those ids. A missing we-wipe IPC or cover timeout is a hard cut,
  # never a silent no-op that leaves the old engine running.
  if we_engine_running; then
    running=true
  fi

  if we_wipe_available; then
    if we_overlay_cover_then_to "${changed[@]}"; then
      overlay_ok=true
    else
      we_transition_log "overlay not ready; hard-cut stop+start with current config"
      echo "Wipe overlay did not cover; applying with a hard cut." >&2
    fi
  else
    we_transition_log "we-wipe IPC missing; hard-cut stop+start with current config"
    echo "Wipe overlay unavailable; applying with a hard cut." >&2
  fi

  if $running && we_engine_running; then
    we_uncover_omarchy_from
  fi

  if $overlay_ok; then
    if we_overlay_wait_done; then
      overlay_done=true
    else
      we_transition_log "overlay wipe done wait failed"
    fi
  fi

  rm -f "$WE_LWE_SCREENSHOT"
  : >"$WE_LOG_FILE"
  echo "+ $WE_ENGINE_BIN ${args[*]}" >>"$WE_LOG_FILE"

  local -a env_prefix=()
  if [[ $(we_jq -r '.nvidia_workaround // false') == true ]]; then
    env_prefix=(env __GL_THREADED_OPTIMIZATIONS=0)
  fi

  # Start LWE under the overlay (holding TO). Drop flock fd 9 so LWE cannot
  # hold it for its whole lifetime.
  nohup "${env_prefix[@]}" "$WE_ENGINE_BIN" "${args[@]}" \
    </dev/null >>"$WE_LOG_FILE" 2>&1 9>&- &
  local engine_pid=$! pid_ready=false pid_tmp engine_start
  engine_start=$(we_proc_starttime "$engine_pid" 2>/dev/null || true)
  local pid_try
  for pid_try in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if we_is_engine_pid "$engine_pid"; then
      pid_ready=true
      break
    fi
    kill -0 -- "$engine_pid" 2>/dev/null || break
    sleep 0.05
  done
  if ! $pid_ready; then
    we_transition_log "engine exec failed identity validation pid=$engine_pid"
    if [[ -n $engine_start && $(we_proc_starttime "$engine_pid" 2>/dev/null || true) == "$engine_start" ]]; then
      kill -TERM -- "$engine_pid" 2>/dev/null || true
      sleep 0.1
      if [[ $(we_proc_starttime "$engine_pid" 2>/dev/null || true) == "$engine_start" ]]; then
        kill -KILL -- "$engine_pid" 2>/dev/null || true
      fi
    fi
    we_overlay_end
    we_jq_write '.active = false'
    we_set_active_flag false
    echo "Wallpaper Engine process did not start correctly; see $WE_LOG_FILE" >&2
    we_notify "Wallpaper Engine failed to start"
    return 1
  fi
  pid_tmp=$(mktemp "$WE_STATE_DIR/engine.pid.tmp.XXXXXX")
  engine_start=$(we_proc_starttime "$engine_pid")
  if [[ -z $engine_start ]]; then
    rm -f "$pid_tmp"
    we_overlay_end
    we_jq_write '.active = false'
    we_set_active_flag false
    echo "Wallpaper Engine exited before its process identity could be recorded." >&2
    we_notify "Wallpaper Engine failed to start"
    return 1
  fi
  printf '%s %s\n' "$engine_pid" "$engine_start" >"$pid_tmp"
  mv -f "$pid_tmp" "$WE_PID_FILE"

  # Map ≠ first paint. Hide at hyprctl namespace/alpha reveals 100–600ms of
  # black while shaders compile. Keep TO up; placeholder goes under LWE.
  local -a wait_outputs=()
  local live
  while IFS= read -r live; do
    [[ -n $live ]] || continue
    we_name_in_list "$live" "${monitors[@]}" && wait_outputs+=("$live")
  done < <(we_list_monitors 2>/dev/null || true)
  if ((${#wait_outputs[@]} == 0)); then
    wait_outputs=("${monitors[@]}")
  fi

  local painted=false
  if we_wait_engine_layer "$WE_BG_LAYER_WAIT_MS" "${wait_outputs[@]}"; then
    we_apply_placeholder
    if we_wait_engine_first_paint "$WE_LWE_READY_MS"; then
      painted=true
    fi
  else
    we_transition_log "LWE did not map on ${wait_outputs[*]:-?}; holding overlay"
    if we_wait_engine_first_paint "$WE_LWE_READY_MS"; then
      painted=true
    fi
    if we_engine_layer_mapped "${wait_outputs[@]}"; then
      we_apply_placeholder
    fi
  fi
  # Safety invariant: this cosmetic full-screen overlay never outlives the
  # bounded apply transaction. A static/black background on engine failure is
  # preferable to making the entire desktop appear frozen indefinitely.
  if ! $painted; then
    we_transition_log "LWE did not produce a confirmed frame; hiding overlay and marking inactive"
  fi
  we_overlay_end
  if $overlay_done && [[ -n $wipe_outputs && $wipe_outputs != '[]' ]]; then
    we_remember_wipe_stills "$wipe_outputs"
  fi
  we_prune_transition_history

  if ! $painted || ! we_engine_running; then
    we_stop_engine
    we_jq_write '.active = false'
    we_set_active_flag false
    we_notify "Wallpaper Engine failed to start"
    we_transition_log "apply failed safely; overlay hidden and engine stopped"
    return 1
  fi

  we_jq_write '.active = true'
  we_set_active_flag true
  we_notify "Wallpaper Engine applied"
  we_transition_log "apply done; LWE mapped=yes"
}

we_revert_target_image() {
  local saved theme_bg first
  saved=$(we_jq -r '.saved_theme_background // empty')
  if [[ -n $saved && -f $saved ]] && ! we_is_placeholder "$saved"; then
    printf '%s\n' "$saved"
    return 0
  fi
  theme_bg=$(we_current_theme_background)
  if [[ -n $theme_bg && -f $theme_bg ]] && ! we_is_placeholder "$theme_bg"; then
    printf '%s\n' "$theme_bg"
    return 0
  fi
  first=$(we_first_theme_background)
  if [[ -n $first && -f $first ]]; then
    printf '%s\n' "$first"
    return 0
  fi
  return 1
}

we_revert_to_theme() {
  we_bg_queue_enter
  we_load_config
  we_ensure_omarchy_background_enabled
  we_transition_log "revert start plugin=$WE_PLUGIN_ROOT engine=$(we_engine_running && echo running || echo stopped)"

  local target rc=0 wipe_outputs=""
  target=$(we_revert_target_image 2>/dev/null || true)

  # FROM cover first, then theme TO — never blocks stop/restore.
  if [[ -n ${target:-} && -f $target ]]; then
    if we_overlay_cover_then_to --theme; then
      we_overlay_wait_done || we_transition_log "revert overlay done wait failed"
    else
      we_transition_log "revert overlay not ready; continuing with kill + theme set"
    fi
  fi

  # Always kill via truncated comm (linux-wallpaper). Canvas/wipe failure
  # must not skip this.
  we_stop_engine
  we_wait_engine_unmapped || true
  we_jq_write '.active = false'
  we_set_active_flag false

  if [[ -z ${target:-} || ! -f $target ]]; then
    echo "Could not find a theme background to restore." >&2
    we_overlay_end
    we_jq_write '.saved_theme_background = null'
    we_clear_last_reveal
    return 1
  fi

  local unique
  unique=$(we_stage_transition_image "$target" "theme") || unique=$target
  we_transition_log "revert omarchy-theme-bg-set $unique"
  we_omarchy_bg_set "$unique" || rc=$?
  we_overlay_end
  we_jq_write '.saved_theme_background = null'
  we_clear_last_reveal
  we_prune_transition_history
  if (( rc == 0 )); then
    we_notify "Restored theme background"
    we_transition_log "revert done"
  else
    we_transition_log "revert omarchy-theme-bg-set failed rc=$rc"
  fi
  return "$rc"
}

# Re-apply placeholder after a theme-set while WE is active (hook helper).
we_on_theme_set() {
  we_bg_queue_enter
  we_load_config
  local active
  active=$(we_jq -r '.active // false')
  [[ $active == true ]] || return 0

  # Theme apply wrote a real background; remember it for revert, then cover again.
  local bg
  bg=$(we_current_theme_background)
  if [[ -n $bg && -f $bg ]] && ! we_is_placeholder "$bg"; then
    we_jq_write --arg p "$bg" '.saved_theme_background = $p'
  fi
  we_apply_placeholder
}

# ---------------------------------------------------------------------------
# Reliable per-display runtime (v1.5+)
#
# A shared linux-wallpaperengine process couples every monitor: one unsupported
# project terminates all wallpapers, and changing one display recreates every
# layer surface. Keep one owned process per output and never involve the QML
# transition service in apply/revert. The later definitions intentionally
# replace the legacy all-display functions above while keeping their helpers.

we_runtime_log() {
  we_ensure_dirs
  local ts
  ts=$(date '+%H:%M:%S.%3N')
  printf '[we-runtime %s] %s\n' "$ts" "$*" >>"$WE_TRANSITION_LOG"
}

we_monitor_key() {
  printf '%s' "${1:-}" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

we_wallpaper_key() {
  printf '%s' "${1:-}" | sha256sum | cut -c1-16
}

we_monitor_pid_file() {
  printf '%s/%s.pid\n' "$WE_PID_DIR" "$(we_monitor_key "$1")"
}

we_monitor_log_file() {
  printf '%s/engine.%s.log\n' "$WE_STATE_DIR" "$(we_monitor_key "$1")"
}

we_terminate_identity() {
  local identity=${1:-} pid start i
  [[ -n $identity ]] || return 0
  read -r pid start <<<"$identity"
  we_is_engine_pid "$pid" "$start" || return 0
  kill -TERM -- "$pid" 2>/dev/null || true
  for i in 1 2 3 4 5 6 7 8 9 10; do
    we_is_engine_pid "$pid" "$start" || return 0
    sleep 0.1
  done
  we_is_engine_pid "$pid" "$start" && kill -KILL -- "$pid" 2>/dev/null || true
}

we_stop_engine_monitor() {
  local monitor=$1 file identity
  file=$(we_monitor_pid_file "$monitor")
  identity=$(we_owned_pid_identity "$file" 2>/dev/null || true)
  rm -f "$file"
  we_terminate_identity "$identity"
}

we_sync_active_state() {
  local active=false
  [[ -n $(we_engine_pids) ]] && active=true
  we_jq_write --argjson active "$active" '.active = $active'
  we_set_active_flag "$active"
}

we_restore_non_placeholder_background() {
  local current target
  current=$(we_current_theme_background)
  if [[ -n $current && -f $current ]] && ! we_is_placeholder "$current"; then
    return 0
  fi
  target=$(we_revert_target_image 2>/dev/null || true)
  if [[ -n $target && -f $target ]] && ! we_is_placeholder "$target"; then
    we_omarchy_bg_set_instant "$target" || true
  fi
}

we_infer_last_applied_json() {
  local monitor wallpaper key wallpaper_key candidate base stamp
  local best_stamp=0 best_monitor="" best_wallpaper="" best_source=""
  while IFS= read -r monitor; do
    [[ -n $monitor ]] || continue
    wallpaper=$(we_display_wallpaper "$monitor")
    [[ -n $wallpaper ]] || continue
    key=$(we_monitor_key "$monitor")
    wallpaper_key=$(we_wallpaper_key "$wallpaper")
    candidate=$(find "$WE_STATE_DIR" -maxdepth 1 -type f \
      -name "lwe-ready.${key}.${wallpaper_key}.*.jpg" \
      -printf '%T@\t%p\n' 2>/dev/null | sort -nr | head -n1 | cut -f2-)
    [[ -n $candidate && -f $candidate ]] || continue
    base=${candidate%.jpg}
    stamp=${base##*.}
    [[ $stamp =~ ^[0-9]+$ ]] || continue
    if (( stamp > best_stamp )); then
      best_stamp=$stamp
      best_monitor=$monitor
      best_wallpaper=$wallpaper
      best_source=$(realpath "$candidate")
    fi
  done < <(we_configured_monitors)
  [[ -n $best_monitor && -n $best_source ]] || return 1
  jq -n \
    --arg monitor "$best_monitor" \
    --arg wallpaper "$best_wallpaper" \
    --arg source "$best_source" \
    --argjson applied_at "$best_stamp" \
    '{
      monitor: $monitor,
      wallpaper: $wallpaper,
      source_image: $source,
      applied_at: $applied_at
    }'
}

we_ensure_last_applied() {
  local inferred
  if [[ -n $(we_jq -r '.last_applied.monitor // empty') ]]; then
    return 0
  fi
  inferred=$(we_infer_last_applied_json) || return 1
  we_jq_write --argjson inferred "$inferred" '.last_applied = $inferred'
}

we_record_last_applied() {
  local monitor=${1:-} wallpaper=${2:-} source=${3:-} applied_at
  [[ ${WE_PRESERVE_LAST_APPLIED:-0} != 1 ]] || return 0
  [[ -n $monitor && -n $wallpaper && -n $source && -f $source ]] || return 1
  source=$(realpath "$source")
  applied_at=$(we_now_ms)
  we_jq_write \
    --arg monitor "$monitor" \
    --arg wallpaper "$wallpaper" \
    --arg source "$source" \
    --argjson applied_at "$applied_at" \
    '.last_applied = {
      monitor: $monitor,
      wallpaper: $wallpaper,
      source_image: $source,
      applied_at: $applied_at
    }'
}

we_start_engine_monitor() {
  local monitor=$1 wallpaper resolved key wallpaper_key pid_file log_file old_identity
  local screenshot engine_pid engine_start pid_ready=false pid_tmp i
  local project_type particles_disabled painted=true engine_alive=true
  local -a args=() env_prefix=()

  wallpaper=$(we_display_wallpaper "$monitor")
  [[ -n $wallpaper ]] || {
    echo "Display $monitor has no wallpaper configured." >&2
    return 1
  }
  resolved=$(we_resolve_wallpaper "$wallpaper" 2>/dev/null || true)
  if [[ -z $resolved || ! -d $resolved ]] || ! we_wallpaper_supported_dir "$resolved"; then
    echo "Display $monitor uses unsupported wallpaper $wallpaper (missing/unsupported project type)." >&2
    return 1
  fi
  project_type=$(jq -r '(.type // "") | ascii_downcase' "$resolved/project.json" 2>/dev/null || true)
  particles_disabled=$(we_effective_display_json "$monitor" | jq -r '.disableParticles // false')

  key=$(we_monitor_key "$monitor")
  wallpaper_key=$(we_wallpaper_key "$wallpaper")
  pid_file=$(we_monitor_pid_file "$monitor")
  log_file=$(we_monitor_log_file "$monitor")
  old_identity=$(we_owned_pid_identity "$pid_file" 2>/dev/null || true)
  screenshot="$WE_STATE_DIR/lwe-ready.${key}.${wallpaper_key}.$(we_now_ms).jpg"

  # Dynamic scope: argv builder and paint probe use this monitor's unique FBO.
  local WE_LWE_SCREENSHOT="$screenshot"
  we_build_engine_argv args "$monitor"
  ((${#args[@]})) || return 1

  : >"$log_file"
  printf '+ %q ' "$WE_ENGINE_BIN" "${args[@]}" >>"$log_file"
  printf '\n' >>"$log_file"
  if [[ $(we_jq -r '.nvidia_workaround // false') == true ]]; then
    env_prefix=(env __GL_THREADED_OPTIMIZATIONS=0)
  fi

  # Start the replacement first. Its unique framebuffer is the readiness
  # signal; the prior process keeps the old wallpaper visible until then.
  nohup "${env_prefix[@]}" "$WE_ENGINE_BIN" "${args[@]}" \
    </dev/null >>"$log_file" 2>&1 9>&- &
  engine_pid=$!
  engine_start=$(we_proc_starttime "$engine_pid" 2>/dev/null || true)
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if we_is_engine_pid "$engine_pid"; then
      pid_ready=true
      break
    fi
    kill -0 -- "$engine_pid" 2>/dev/null || break
    sleep 0.05
  done
  if ! $pid_ready || [[ -z $engine_start ]]; then
    if [[ -n $engine_start && $(we_proc_starttime "$engine_pid" 2>/dev/null || true) == "$engine_start" ]]; then
      kill -KILL -- "$engine_pid" 2>/dev/null || true
    fi
    echo "Wallpaper Engine could not start on $monitor; see $log_file" >&2
    return 1
  fi

  we_wait_engine_first_paint \
    "$WE_LWE_READY_MS" "$engine_pid" "$engine_start" "$monitor" "$log_file" || painted=false
  we_is_engine_pid "$engine_pid" "$engine_start" || engine_alive=false
  if ! $painted || ! $engine_alive; then
    we_terminate_identity "$engine_pid $engine_start"

    # Some older Scene projects trigger an upstream linux-wallpaperengine
    # crash while constructing a particle object. Retry a process that exited
    # before first paint once with particles disabled. Persist the setting only
    # when that compatibility attempt renders successfully, so later applies
    # do not generate another core dump for the same wallpaper.
    if ! $engine_alive && [[ $project_type == scene ]] \
      && [[ $particles_disabled != true && $particles_disabled != True ]]; then
      we_runtime_log "display $monitor engine exited before first paint; retrying wallpaper=$wallpaper with particles disabled"
      we_jq_write --arg m "$monitor" '.displays[$m].disable_particles = true'
      if we_start_engine_monitor "$monitor"; then
        we_runtime_log "display $monitor compatibility fallback active: particles disabled"
        we_notify "Wallpaper Engine: particles disabled for compatibility on $monitor"
        return 0
      fi
      we_jq_write --arg m "$monitor" '.displays[$m].disable_particles = false'
    fi

    echo "Wallpaper $wallpaper failed to render on $monitor; see $log_file" >&2
    return 1
  fi

  pid_tmp=$(mktemp "$WE_PID_DIR/.${key}.pid.tmp.XXXXXX")
  printf '%s %s\n' "$engine_pid" "$engine_start" >"$pid_tmp"
  mv -f "$pid_tmp" "$pid_file"
  we_terminate_identity "$old_identity"
  find "$WE_STATE_DIR" -maxdepth 1 -type f -name "lwe-ready.${key}.*.jpg" \
    ! -path "$screenshot" -delete 2>/dev/null || true
  we_record_last_applied "$monitor" "$wallpaper" "$screenshot" \
    || we_runtime_log "could not record last applied wallpaper for $monitor"
  we_runtime_log "display $monitor ready pid=$engine_pid wallpaper=$wallpaper"
}

we_start_engine() {
  we_bg_queue_enter
  we_load_config
  command -v "$WE_ENGINE_BIN" >/dev/null 2>&1 || {
    echo "Missing dependency: $WE_ENGINE_BIN (install linux-wallpaperengine-git from AUR)" >&2
    return 1
  }
  we_ensure_omarchy_background_enabled

  local -a targets=()
  local monitor rc=0 successes=0 legacy_identity="" migration=false previous_last_applied
  previous_last_applied=$(we_jq -c '.last_applied // {monitor:null, wallpaper:null, source_image:null}')
  legacy_identity=$(we_owned_pid_identity "$WE_PID_FILE" 2>/dev/null || true)
  if [[ -n $legacy_identity ]]; then
    # Upgrade the old shared runtime without blanking either output. Build and
    # validate every configured replacement while the shared process remains
    # visible; retire it only after all replacements are ready.
    migration=true
    mapfile -t targets < <(we_configured_monitors)
  elif (($#)); then
    rm -f "$WE_PID_FILE"
    targets=("$@")
  else
    rm -f "$WE_PID_FILE"
    mapfile -t targets < <(we_configured_monitors)
  fi
  ((${#targets[@]})) || {
    echo "No displays configured. Select a wallpaper first." >&2
    return 1
  }

  we_save_theme_background_if_needed
  we_restore_non_placeholder_background
  we_runtime_log "direct per-display apply targets=${targets[*]}"
  for monitor in "${targets[@]}"; do
    if we_start_engine_monitor "$monitor"; then
      successes=$((successes + 1))
    else
      rc=1
    fi
  done
  if $migration; then
    if (( rc == 0 && successes == ${#targets[@]} )); then
      rm -f "$WE_PID_FILE"
      we_terminate_identity "$legacy_identity"
      we_runtime_log "legacy shared process migrated to ${#targets[@]} per-display processes"
    else
      # The legacy process still owns every output, so discard partial new
      # processes and leave the pre-upgrade desktop exactly as it was.
      for monitor in "${targets[@]}"; do
        we_stop_engine_monitor "$monitor"
      done
      we_jq_write --argjson previous "$previous_last_applied" '.last_applied = $previous'
      we_sync_active_state
      echo "Could not migrate the shared wallpaper process; the previous wallpapers remain running." >&2
      we_notify "Wallpaper Engine migration failed safely"
      return 1
    fi
  fi
  we_sync_active_state
  if (( successes > 0 )); then
    we_notify "Wallpaper Engine applied"
  elif (( rc != 0 )); then
    we_notify "Wallpaper Engine failed to apply"
  fi
  return "$rc"
}

we_auto_theme_source_image() {
  local monitor=${1:-} wallpaper=${2:-} preferred_source=${3:-}
  local key wallpaper_key latest resolved geometry width height rendered preview
  [[ -n $monitor ]] || {
    echo "No display was selected for auto-match." >&2
    return 1
  }
  if [[ -n $preferred_source && -f $preferred_source ]]; then
    printf '%s\n' "$(realpath "$preferred_source")"
    return 0
  fi
  [[ -n $wallpaper ]] || wallpaper=$(we_display_wallpaper "$monitor")
  [[ -n $wallpaper ]] || {
    echo "Display $monitor has no wallpaper configured. Pick and apply one first." >&2
    return 1
  }

  # The readiness image is an actual linux-wallpaperengine framebuffer, so it
  # represents Scene/Web wallpapers better than their Workshop thumbnail. The
  # wallpaper key prevents a prior framebuffer for this monitor from being
  # reused after set-display changes its configured wallpaper.
  key=$(we_monitor_key "$monitor")
  wallpaper_key=$(we_wallpaper_key "$wallpaper")
  latest=$(find "$WE_STATE_DIR" -maxdepth 1 -type f \
    -name "lwe-ready.${key}.${wallpaper_key}.*.jpg" \
    -printf '%T@\t%p\n' 2>/dev/null | sort -nr | head -n1 | cut -f2-)
  if [[ -n $latest && -f $latest ]]; then
    printf '%s\n' "$latest"
    return 0
  fi

  resolved=$(we_resolve_wallpaper "$wallpaper" 2>/dev/null || true)
  [[ -n $resolved && -d $resolved ]] || {
    echo "Could not resolve wallpaper $wallpaper for $monitor." >&2
    return 1
  }
  geometry=$(we_monitors_json 2>/dev/null | jq -r --arg m "$monitor" \
    '.[] | select(.name == $m) | [(.width // 1920), (.height // 1080)] | @tsv' | head -n1)
  read -r width height <<<"${geometry:-1920 1080}"
  [[ $width =~ ^[1-9][0-9]*$ ]] || width=1920
  [[ $height =~ ^[1-9][0-9]*$ ]] || height=1080
  rendered="$WE_STATE_DIR/auto-theme-source.${key}.$(we_now_ms).jpg"
  if we_render_output_still "$wallpaper" "$width" "$height" "$rendered" \
    "$(we_display_setting "$monitor" scaling 2>/dev/null || echo fill)" >/dev/null 2>&1; then
    printf '%s\n' "$rendered"
    return 0
  fi

  preview=$(we_wallpaper_preview_file "$resolved" 2>/dev/null || true)
  if [[ -n $preview && -f $preview ]]; then
    printf '%s\n' "$preview"
    return 0
  fi
  echo "Could not capture a usable image from wallpaper $wallpaper." >&2
  return 1
}

we_theme_exists() {
  local slug=${1:-}
  [[ -n $slug && $slug != */* && $slug != .* ]] || return 1
  [[ -d $WE_USER_THEMES_DIR/$slug || -d /usr/share/omarchy/themes/$slug ]]
}

we_apply_auto_theme() {
  we_load_config
  local monitor=${1:-} current previous source stage backup old_state applied_theme
  local last_applied wallpaper_override="" preferred_source=""
  if [[ -z $monitor ]]; then
    last_applied=$(we_jq -c '.last_applied // {}')
    monitor=$(jq -r '.monitor // empty' <<<"$last_applied")
    wallpaper_override=$(jq -r '.wallpaper // empty' <<<"$last_applied")
    preferred_source=$(jq -r '.source_image // empty' <<<"$last_applied")
    if [[ -z $monitor ]]; then
      monitor=$(we_configured_monitors | head -n1)
      wallpaper_override=""
      preferred_source=""
    fi
  fi
  [[ -x $WE_THEME_GENERATOR || -f $WE_THEME_GENERATOR ]] || {
    echo "Auto-theme generator is missing: $WE_THEME_GENERATOR" >&2
    return 1
  }
  command -v python3 >/dev/null 2>&1 || {
    echo "Auto-match requires python3." >&2
    return 1
  }
  command -v omarchy >/dev/null 2>&1 || {
    echo "Auto-match requires the Omarchy theme command." >&2
    return 1
  }

  current=$(we_current_theme_name)
  old_state=$(we_jq -c '.auto_theme // {active:false, previous_theme:null, source_monitor:null}')
  previous=$(jq -r '.previous_theme // empty' <<<"$old_state")
  if [[ $current != "$WE_AUTO_THEME_SLUG" ]]; then
    previous=$current
  elif [[ -z $previous ]]; then
    echo "The generated theme is already selected, but its prior theme is unknown. Select another theme first." >&2
    return 1
  fi
  [[ -n $previous && $previous != "$WE_AUTO_THEME_SLUG" ]] || {
    echo "Could not determine a theme to restore before auto-matching." >&2
    return 1
  }

  source=$(we_auto_theme_source_image \
    "$monitor" "$wallpaper_override" "$preferred_source") || return 1
  mkdir -p "$WE_USER_THEMES_DIR"
  if [[ -e $WE_AUTO_THEME_DIR && ! -f $WE_AUTO_THEME_DIR/.wallpaper-engine-omarchy-generated ]]; then
    echo "Refusing to overwrite non-plugin theme: $WE_AUTO_THEME_DIR" >&2
    return 1
  fi
  stage=$(mktemp -d "$WE_USER_THEMES_DIR/.${WE_AUTO_THEME_SLUG}.stage.XXXXXX")
  if ! python3 "$WE_THEME_GENERATOR" "$source" "$stage"; then
    rm -rf -- "$stage"
    return 1
  fi

  backup=""
  if [[ -d $WE_AUTO_THEME_DIR ]]; then
    backup="$WE_USER_THEMES_DIR/.${WE_AUTO_THEME_SLUG}.previous.$$"
    mv -- "$WE_AUTO_THEME_DIR" "$backup"
  fi
  if ! mv -- "$stage" "$WE_AUTO_THEME_DIR"; then
    [[ -n $backup && -d $backup ]] && mv -- "$backup" "$WE_AUTO_THEME_DIR"
    rm -rf -- "$stage"
    return 1
  fi
  [[ -n $backup && -d $backup ]] && rm -rf -- "$backup"

  we_jq_write \
    --arg previous "$previous" \
    --arg monitor "$monitor" \
    --arg source "$(realpath "$source")" \
    '.auto_theme = {
      active: true,
      previous_theme: $previous,
      source_monitor: $monitor,
      source_image: $source
    }'

  if ! omarchy theme set "$WE_AUTO_THEME_SLUG"; then
    applied_theme=$(we_current_theme_name)
    if [[ $applied_theme != "$WE_AUTO_THEME_SLUG" ]]; then
      we_jq_write --argjson old "$old_state" '.auto_theme = $old'
    fi
    echo "Omarchy could not apply the generated wallpaper theme." >&2
    return 1
  fi
  we_notify "Theme auto-matched to $monitor wallpaper"
  echo "Auto-matched Omarchy theme to the wallpaper on $monitor."
}

we_undo_auto_theme() {
  we_load_config
  local previous
  previous=$(we_jq -r '.auto_theme.previous_theme // empty')
  [[ $(we_jq -r '.auto_theme.active // false') == true && -n $previous ]] || {
    echo "No auto-matched theme change is available to undo." >&2
    return 1
  }
  we_theme_exists "$previous" || {
    echo "The previous Omarchy theme no longer exists: $previous" >&2
    return 1
  }
  command -v omarchy >/dev/null 2>&1 || {
    echo "Undo requires the Omarchy theme command." >&2
    return 1
  }
  if ! omarchy theme set "$previous"; then
    echo "Omarchy could not restore the previous theme: $previous" >&2
    return 1
  fi
  we_jq_write '.auto_theme = {active:false, previous_theme:null, source_monitor:null}'
  we_notify "Restored theme $previous"
  echo "Restored Omarchy theme: $previous"
}

we_revert_to_theme() {
  we_bg_queue_enter
  we_load_config
  we_ensure_omarchy_background_enabled
  local target rc=0
  target=$(we_revert_target_image 2>/dev/null || true)
  we_stop_engine
  we_jq_write '.active = false'
  we_set_active_flag false
  if [[ -z $target || ! -f $target ]]; then
    echo "Could not find a theme background to restore." >&2
    return 1
  fi
  we_omarchy_bg_set "$target" || rc=$?
  we_jq_write '.saved_theme_background = null'
  we_clear_last_reveal
  we_prune_transition_history
  (( rc == 0 )) && we_notify "Restored theme background"
  return "$rc"
}

we_on_theme_set() {
  we_bg_queue_enter
  we_load_config
  local bg
  bg=$(we_current_theme_background)
  if [[ -n $bg && -f $bg ]] && ! we_is_placeholder "$bg"; then
    we_jq_write --arg p "$bg" '.saved_theme_background = $p'
  fi
}

we_status_text() {
  we_load_config
  local active engine pids
  active=$(we_jq -r '.active')
  pids=$(we_engine_pids | paste -sd, -)
  if [[ -n $pids ]]; then
    engine=running
  else
    engine=stopped
  fi
  printf 'active=%s engine=%s pids=%s theme=%s layer=%s\n' \
    "$active" "$engine" "${pids:-none}" "$(we_current_theme_name)" "$(we_jq -r '.defaults.layer // "bottom"')"
  printf 'saved_theme_bg=%s\n' "$(we_jq -r '.saved_theme_background // "none"')"
  printf 'config=%s\n' "$WE_CONFIG_FILE"
  printf 'log=%s\n' "$WE_LOG_FILE"
  echo "displays (effective = overrides ∪ defaults):"
  local m eff
  while IFS= read -r m; do
    [[ -n $m ]] || continue
    eff=$(we_effective_display_json "$m")
    printf '  %s wallpaper=%s scaling=%s fps=%s clamp=%s silent=%s volume=%s props=%s\n' \
      "$m" \
      "$(jq -r '.wallpaper // "none"' <<<"$eff")" \
      "$(jq -r '.scaling' <<<"$eff")" \
      "$(jq -r '.fps' <<<"$eff")" \
      "$(jq -r '.clamp' <<<"$eff")" \
      "$(jq -r '.silent' <<<"$eff")" \
      "$(jq -r '.volume' <<<"$eff")" \
      "$(jq -c '.properties' <<<"$eff")"
  done < <({
    we_list_monitors || true
    we_jq -r '.displays | keys[]' 2>/dev/null || true
  } | awk 'NF && !seen[$0]++')
  if [[ $(we_jq -r '.displays | length') -eq 0 ]]; then
    echo "  (none configured)"
    echo "detected monitors:"
    we_list_monitors | sed 's/^/  /' || echo "  (none)"
  fi
}
