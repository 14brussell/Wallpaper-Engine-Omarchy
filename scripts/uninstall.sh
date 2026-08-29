#!/usr/bin/env bash
# Remove Wallpaper Engine's Omarchy integrations before removing the plugin.
# User configuration and state are preserved unless --purge is explicit.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PLUGIN_ID="io.github.14brussell.wallpaper-engine"
if [[ -f $ROOT/manifest.json ]]; then
  manifest_id=$(sed -n 's/^[[:space:]]*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$ROOT/manifest.json" | head -n1)
  [[ -n ${manifest_id:-} ]] && PLUGIN_ID=$manifest_id
fi

HOOKS_ROOT="${WE_HOOKS_ROOT:-${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/hooks}"
MENU_FILE="${WE_MENU_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/extensions/omarchy-menu.jsonc}"
BIN_DIR="${WE_BIN_DIR:-$HOME/.local/bin}"
CONFIG_DIR="${WE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/wallpaper-engine}"
STATE_DIR="${WE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/wallpaper-engine}"
CONTROLLER="${WE_CONTROLLER:-$ROOT/bin/we}"
HOOK_MARKER="# wallpaper-engine-omarchy"
MENU_MARKER="  // Added by wallpaper-engine-omarchy"

usage() {
  cat <<'EOF'
Usage: uninstall.sh [--purge]

Stops Wallpaper Engine, restores the Omarchy theme background when possible,
and removes only verified plugin-owned hooks, menu entries, and command links.
Configuration and runtime state are preserved by default. --purge permanently
removes both plugin-owned data directories after the integrations are removed.
EOF
}

note_preserved() {
  printf 'Preserved (not recognized as plugin-owned): %s\n' "$1" >&2
}

run_controller() {
  local command=$1
  [[ -f $CONTROLLER ]] || return 127
  if command -v timeout >/dev/null 2>&1; then
    if [[ -x $CONTROLLER ]]; then
      timeout -k 2 20 "$CONTROLLER" "$command"
    else
      timeout -k 2 20 bash "$CONTROLLER" "$command"
    fi
  elif [[ -x $CONTROLLER ]]; then
    "$CONTROLLER" "$command"
  else
    bash "$CONTROLLER" "$command"
  fi
}

restore_background_and_stop() {
  if run_controller revert; then
    echo "Stopped Wallpaper Engine and restored the Omarchy theme background."
    return 0
  fi

  echo "Could not fully restore the theme background; attempting a safe stop." >&2
  if run_controller stop; then
    echo "Stopped Wallpaper Engine. Restore your theme background manually if needed."
  else
    echo "Could not confirm that Wallpaper Engine stopped; continuing with integration cleanup." >&2
  fi
}

hook_is_owned() {
  local path=$1
  [[ -f $path ]] && grep -Fqx "$HOOK_MARKER" "$path"
}

remove_owned_hook() {
  local path=$1
  if [[ ! -e $path && ! -L $path ]]; then
    return 0
  fi
  if hook_is_owned "$path"; then
    rm -f -- "$path"
    printf 'Removed hook: %s\n' "$path"
  else
    note_preserved "$path"
  fi
}

menu_line_is_owned() {
  local line=$1
  local key_pattern='^[[:space:]]*"(appearance\.wallpaper-engine[^"]*|style\.wallpaper-engine([.-](revert|tui))?)"[[:space:]]*:'
  [[ $line =~ $key_pattern ]] || return 1

  [[ $line == *"omarchy-shell shell summon $PLUGIN_ID"* \
    || $line == *"omarchy-shell shell summon wallpaper-engine-omarchy"* \
    || $line == *'/bin/we revert'* \
    || $line == *'/scripts/we-menu'* ]]
}

remove_owned_menu_entries() {
  [[ -f $MENU_FILE ]] || return 0

  local line tmp removed=0 marker_removed=0
  tmp=$(mktemp "${MENU_FILE}.tmp.XXXXXX")
  while IFS= read -r line || [[ -n $line ]]; do
    if menu_line_is_owned "$line"; then
      removed=$((removed + 1))
      continue
    fi
    if [[ $line == "$MENU_MARKER" ]]; then
      marker_removed=1
      continue
    fi
    printf '%s\n' "$line"
  done <"$MENU_FILE" >"$tmp"

  if (( removed || marker_removed )); then
    mv -f -- "$tmp" "$MENU_FILE"
    printf 'Removed %d plugin-owned menu entr%s from %s\n' \
      "$removed" "$([[ $removed == 1 ]] && printf y || printf ies)" "$MENU_FILE"
    if [[ ${WE_SKIP_MENU_REFRESH:-0} != 1 ]] && command -v omarchy-shell >/dev/null 2>&1; then
      timeout -k 1 3 omarchy-shell shell call omarchy.menu refresh "" >/dev/null 2>&1 || true
    fi
  else
    rm -f -- "$tmp"
  fi
}

symlink_target_is_owned() {
  local link=$1 target candidate_root candidate_id
  [[ -L $link ]] || return 1
  target=$(readlink -f -- "$link" 2>/dev/null || true)
  [[ -n $target && -f $target && $target == */bin/we ]] || return 1

  candidate_root=$(cd "$(dirname "$target")/.." 2>/dev/null && pwd -P) || return 1
  [[ -f $candidate_root/manifest.json ]] || return 1
  candidate_id=$(sed -n 's/^[[:space:]]*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$candidate_root/manifest.json" | head -n1)
  [[ -n $candidate_id && $candidate_id == "$PLUGIN_ID" ]]
}

remove_owned_link() {
  local link=$1
  if [[ ! -e $link && ! -L $link ]]; then
    return 0
  fi
  if symlink_target_is_owned "$link"; then
    rm -f -- "$link"
    printf 'Removed command link: %s\n' "$link"
  else
    note_preserved "$link"
  fi
}

validate_purge_data_dir() {
  local path=$1 label=$2 base
  base=$(basename -- "$path")
  if [[ -z $path || $path != /* || $path == / || $path == "$HOME" || $base != wallpaper-engine ]]; then
    printf 'Refusing to purge unsafe %s path: %s\n' "$label" "$path" >&2
    return 1
  fi
}

purge_data_dir() {
  local path=$1 label=$2
  if [[ -e $path || -L $path ]]; then
    rm -rf -- "$path"
    printf 'Purged %s: %s\n' "$label" "$path"
  else
    printf '%s already absent: %s\n' "$label" "$path"
  fi
}

purge_plugin_data() {
  validate_purge_data_dir "$CONFIG_DIR" configuration
  if [[ $STATE_DIR != "$CONFIG_DIR" ]]; then
    validate_purge_data_dir "$STATE_DIR" 'runtime state'
  fi

  purge_data_dir "$CONFIG_DIR" configuration
  if [[ $STATE_DIR != "$CONFIG_DIR" ]]; then
    purge_data_dir "$STATE_DIR" 'runtime state'
  fi
}

main() {
  local purge=0
  case ${1:-} in
    -h|--help) usage; return 0 ;;
    --purge) purge=1 ;;
    '') ;;
    *) usage >&2; return 2 ;;
  esac

  restore_background_and_stop

  remove_owned_hook "$HOOKS_ROOT/post-boot.d/50-wallpaper-engine"
  remove_owned_hook "$HOOKS_ROOT/theme-set.d/50-wallpaper-engine"
  remove_owned_menu_entries
  remove_owned_link "$BIN_DIR/omarchy-we"
  remove_owned_link "$BIN_DIR/we-omarchy"

  if (( purge )); then
    purge_plugin_data
  fi

  echo
  echo "Wallpaper Engine integrations removed."
  if (( ! purge )); then
    echo "Preserved configuration: $CONFIG_DIR"
    echo "Preserved runtime state: $STATE_DIR"
  fi
  echo "The plugin checkout was not removed. Finish with:"
  echo "  omarchy plugin remove $PLUGIN_ID"
}

main "$@"
