#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PLUGIN_ID="io.github.14brussell.wallpaper-engine"
LEGACY_PLUGIN_ID="wallpaper-engine-omarchy"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_exists() {
  [[ -e $1 || -L $1 ]] || fail "expected path to exist: $1"
}

assert_absent() {
  [[ ! -e $1 && ! -L $1 ]] || fail "expected path to be absent: $1"
}

test_symlinked_cli() {
  local home="$TEST_ROOT/symlink-home"
  mkdir -p "$home/.local/bin"
  ln -s "$ROOT/bin/we" "$home/.local/bin/omarchy-we"

  HOME=$home \
    XDG_CONFIG_HOME="$home/.config" \
    XDG_STATE_HOME="$home/.local/state" \
    "$home/.local/bin/omarchy-we" status --json \
    | jq -e '.active == false
      and ([.effectiveDisplays[] | select(.configured == true)] | length == 0)' \
      >/dev/null
}

test_additional_wallpaper_folders() {
  local home="$TEST_ROOT/wallpaper-folders-home"
  local library="$TEST_ROOT/Steam Library"
  local workshop="$library/steamapps/workshop/content/431960"
  local output="$TEST_ROOT/wallpaper-folders-output"
  local private_preview="$TEST_ROOT/private-preview.png"
  mkdir -p "$home" "$workshop/123456" "$workshop/123457" \
    "$workshop/123458" "$workshop/123459"
  printf 'safe preview\n' >"$workshop/123456/preview.png"
  printf 'private preview\n' >"$private_preview"
  printf '{"title":"External <b>Test</b>","type":"scene","preview":"preview.png"}\n' \
    >"$workshop/123456/project.json"
  jq -cn --arg preview "$private_preview" \
    '{title:"Absolute preview",type:"scene",preview:$preview}' \
    >"$workshop/123457/project.json"
  ln -s "$private_preview" "$workshop/123458/preview.png"
  printf '{"title":"Escaping symlink","type":"scene","preview":"preview.png"}\n' \
    >"$workshop/123458/project.json"
  jq -cn '{title:"Line one\n999999\tInjected",type:"scene"}' \
    >"$workshop/123459/project.json"

  HOME=$home "$ROOT/bin/we" set-wallpaper-dirs "$library" >/dev/null

  HOME=$home "$ROOT/bin/we" wallpaper-dirs --json \
    | jq -e --arg root "$workshop" \
      '.additional == [$root] and (.effective | index($root) != null)' \
      >/dev/null
  HOME=$home "$ROOT/bin/we" list --json \
    | jq -e \
      --arg root "$workshop/123456" \
      --arg preview "$workshop/123456/preview.png" \
      'any(.[]; .id == "123456" and .path == $root
        and .title == "External <b>Test</b>" and .preview == $preview)
      and all(.[] | select(.id == "123457" or .id == "123458"); .preview == "")
      and any(.[]; .id == "123459" and .title == "Line one 999999 Injected")
      and (map(select(.id == "999999")) | length == 0)' \
      >/dev/null

  if HOME=$home "$ROOT/bin/we" set-wallpaper-dirs "$TEST_ROOT/not-mounted" \
      >"$output" 2>&1; then
    fail 'set-wallpaper-dirs accepted a nonexistent folder'
  fi
  HOME=$home "$ROOT/bin/we" wallpaper-dirs --json \
    | jq -e --arg root "$workshop" '.additional == [$root]' \
      >/dev/null

  HOME=$home "$ROOT/bin/we" set-wallpaper-dirs >/dev/null
  HOME=$home "$ROOT/bin/we" wallpaper-dirs --json \
    | jq -e '.additional == []' >/dev/null
}

test_qml_text_is_plain() {
  local qml text_count plain_count
  for qml in "$ROOT/Panel.qml" "$ROOT/DisplayTab.qml"; do
    text_count=$(grep -Ec '^[[:space:]]*Text \{' "$qml")
    plain_count=$(grep -Ec '^[[:space:]]*textFormat: Text\.PlainText$' "$qml")
    [[ $text_count -eq $plain_count ]] \
      || fail "every Text element must explicitly use Text.PlainText: $qml"
  done
}

test_panel_badges_track_display_runtime() {
  grep -Fq 'readonly property bool engineRunning: root.displayEngineRunning(' \
    "$ROOT/Panel.qml" \
    || fail 'display-tab status pills are not driven by per-display engine state'
  grep -Fq 'text: tabDelegate.engineRunning ? "Running" : "Stopped"' \
    "$ROOT/Panel.qml" \
    || fail 'display tabs do not expose their running state'
  ! grep -Fq 'id: statusText' "$ROOT/Panel.qml" \
    || fail 'panel still exposes a misleading global engine status pill'
  ! grep -Fq 'No display processes are running' "$ROOT/Panel.qml" \
    || fail 'panel duplicates the stopped runtime state outside the badge'
}

test_display_actions_are_contextual() {
  grep -A12 -F 'id: startButton' "$ROOT/DisplayTab.qml" \
    | grep -Fq 'visible: !root.engineRunning' \
    || fail 'display Start action is visible while its engine process is running'
  grep -A10 -F 'id: stopButton' "$ROOT/DisplayTab.qml" \
    | grep -Fq 'visible: root.engineRunning' \
    || fail 'display Stop action is visible while its engine process is stopped'
}

test_panel_uses_full_product_name() {
  [[ $(grep -Fc '"Wallpaper Engine for Omarchy"' "$ROOT/Panel.qml") -eq 2 ]] \
    || fail 'panel window and header do not use the full product name'
  ! grep -Fq 'text: "Editing " + root.currentMonitorTitle' "$ROOT/Panel.qml" \
    || fail 'Displays header still duplicates the active monitor label'
}

test_auto_match_hint_is_concise() {
  grep -Fq 'var hint = "Uses the most recently applied wallpaper"' \
    "$ROOT/Panel.qml" \
    || fail 'auto-match hint does not use the concise wording'
  grep -Fq 'text: root.autoThemeHint' "$ROOT/Panel.qml" \
    || fail 'auto-match hint still has a redundant label prefix'
  grep -Fq 'readonly property bool autoThemeHasSource: lastAppliedMonitor.length > 0' \
    "$ROOT/Panel.qml" \
    || fail 'auto-match is not gated on a successfully applied wallpaper'
  ! grep -Fq 'else if (currentHasWallpaper)' "$ROOT/Panel.qml" \
    || fail 'auto-match still accepts a merely configured wallpaper'
  grep -A16 -F 'id: autoThemeButton' "$ROOT/Panel.qml" \
    | grep -Fq '(root.engineRunning && root.autoThemeHasSource)' \
    || fail 'new auto-match remains enabled while Wallpaper Engine is stopped'
  grep -A7 -F 'function toggleAutoTheme()' "$ROOT/Panel.qml" \
    | grep -Fq 'if (autoThemeActive)' \
    || fail 'auto-match action cannot recover an active theme after the engine stops'
  grep -A7 -F 'function toggleAutoTheme()' "$ROOT/Panel.qml" \
    | grep -Fq 'else if (!engineRunning)' \
    || fail 'new auto-match does not reject stale clicks while the engine is stopped'
}

test_save_apply_status_is_stable_and_separate() {
  grep -A8 -F 'id: saveApplyButton' "$ROOT/DisplayTab.qml" \
    | grep -Fq 'text: "Save & apply"' \
    || fail 'Save & apply does not keep a stable action label'
  grep -Fq 'visible: root.saveApplyStatus.length > 0' "$ROOT/DisplayTab.qml" \
    || fail 'display action status is not exposed separately from the action label'
  grep -Fq 'if (root.saveApplyState === "error") return "Error: "' \
    "$ROOT/DisplayTab.qml" \
    || fail 'display action errors do not expose explicit severity'
  ! grep -Fq 'visible: !root.busy && root.wallpaperSelected && !root.engineRunning' \
    "$ROOT/DisplayTab.qml" \
    || fail 'Save & apply still hides guidance and shifts layout while busy'
}

test_save_controls_stay_outside_settings_scroll() {
  grep -Fq 'id: rightSettingsColumn' "$ROOT/DisplayTab.qml" \
    || fail 'settings pane does not own a dedicated right-side layout'
  ! grep -Fq 'id: settingsWorkspace' "$ROOT/DisplayTab.qml" \
    || fail 'save footer still spans the full wallpaper/settings workspace'
  local settings_line flick_line save_line
  settings_line=$(grep -n -F 'id: rightSettingsColumn' "$ROOT/DisplayTab.qml" | cut -d: -f1)
  flick_line=$(grep -n -F 'id: settingsFlick' "$ROOT/DisplayTab.qml" | cut -d: -f1)
  save_line=$(grep -n -F 'id: fixedSaveActions' "$ROOT/DisplayTab.qml" | cut -d: -f1)
  [[ -n $settings_line && -n $flick_line && -n $save_line \
      && $flick_line -gt $settings_line && $save_line -gt $flick_line ]] \
    || fail 'fixed save footer is not below the right-side settings scroller'
  ! grep -Fq 'text: "Clear"' "$ROOT/DisplayTab.qml" \
    || fail 'fixed save footer still exposes the redundant Clear action'
}

test_workshop_heading_is_visibly_bold() {
  grep -A6 -F 'text: "WORKSHOP WALLPAPERS"' "$ROOT/DisplayTab.qml" \
    | grep -Fq 'font.weight: Font.Black' \
    || fail 'Workshop wallpapers heading does not use a visibly bold weight'
}

test_workshop_catalog_persists_across_display_tabs() {
  grep -Fq 'property var workshopWallpapers: []' "$ROOT/Panel.qml" \
    || fail 'panel does not own the shared Workshop wallpaper catalog'
  grep -Fq 'property string workshopFilterText: ""' "$ROOT/Panel.qml" \
    || fail 'panel does not own the cross-display Workshop filter'
  grep -Fq 'wallpapers: root.workshopWallpapers' "$ROOT/Panel.qml" \
    || fail 'display tabs do not receive the shared Workshop catalog'
  grep -Fq 'filterText: root.workshopFilterText' "$ROOT/Panel.qml" \
    || fail 'display tabs do not receive the shared Workshop filter'
  grep -Fq 'onTextEdited: root.filterTextEdited(text)' "$ROOT/DisplayTab.qml" \
    || fail 'Workshop search edits are not forwarded to the shared filter'
  ! grep -Fq 'id: listProc' "$ROOT/DisplayTab.qml" \
    || fail 'each display tab still owns a Workshop directory scan process'
  ! grep -Fq 'loadWallpapers()' "$ROOT/DisplayTab.qml" \
    || fail 'display reload still rescans the Workshop directory'
}

test_legacy_preflight() {
  local home="$TEST_ROOT/legacy-home"
  local legacy="$home/.config/omarchy/plugins/$LEGACY_PLUGIN_ID"
  local output="$TEST_ROOT/legacy-output"
  mkdir -p "$legacy"

  if HOME=$home \
    XDG_CONFIG_HOME="$home/.config" \
    XDG_STATE_HOME="$home/.local/state" \
    "$ROOT/scripts/install.sh" >"$output" 2>&1; then
    fail 'installer accepted a legacy plugin installation'
  fi

  grep -Fq 'Legacy Wallpaper Engine plugin detected:' "$output" \
    || fail 'legacy preflight did not explain the failure'
  grep -Fq "omarchy plugin remove $LEGACY_PLUGIN_ID" "$output" \
    || fail 'legacy preflight did not print the removal command'
  assert_absent "$home/.config/omarchy/plugins/$PLUGIN_ID"
  assert_absent "$home/.local/state/omarchy/wallpaper-engine"
}

make_controller_stub() {
  local path=$1
  mkdir -p "$(dirname -- "$path")"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$path"
  chmod +x "$path"
}

run_uninstall() {
  local home=$1
  shift
  HOME=$home \
    XDG_CONFIG_HOME="$home/.config" \
    XDG_STATE_HOME="$home/.local/state" \
    WE_HOOKS_ROOT="$home/hooks" \
    WE_MENU_FILE="$home/menu.jsonc" \
    WE_BIN_DIR="$home/bin" \
    WE_CONTROLLER="$home/controller" \
    WE_SKIP_MENU_REFRESH=1 \
    "$ROOT/scripts/uninstall.sh" "$@" >/dev/null
}

seed_plugin_data() {
  local home=$1
  mkdir -p \
    "$home/.config/omarchy/wallpaper-engine" \
    "$home/.local/state/omarchy/wallpaper-engine" \
    "$home/bin"
  printf '{}\n' >"$home/.config/omarchy/wallpaper-engine/config.json"
  printf 'state\n' >"$home/.local/state/omarchy/wallpaper-engine/state"
  make_controller_stub "$home/controller"
}

test_uninstall_preserves_data() {
  local home="$TEST_ROOT/preserve-home"
  seed_plugin_data "$home"
  run_uninstall "$home"
  assert_exists "$home/.config/omarchy/wallpaper-engine/config.json"
  assert_exists "$home/.local/state/omarchy/wallpaper-engine/state"
}

test_uninstall_purges_data() {
  local home="$TEST_ROOT/purge-home"
  seed_plugin_data "$home"
  mkdir -p "$home/.config/omarchy/themes/wallpaper-engine-auto-match"
  printf 'generated\n' >"$home/.config/omarchy/themes/wallpaper-engine-auto-match/.wallpaper-engine-omarchy-generated"
  run_uninstall "$home" --purge
  assert_absent "$home/.config/omarchy/wallpaper-engine"
  assert_absent "$home/.local/state/omarchy/wallpaper-engine"
  assert_absent "$home/.config/omarchy/themes/wallpaper-engine-auto-match"
}

test_uninstall_refuses_unsafe_purge_path() {
  local home="$TEST_ROOT/unsafe-purge-home"
  local unsafe="$home/keep-me"
  seed_plugin_data "$home"
  mkdir -p "$unsafe"

  if HOME=$home \
    XDG_CONFIG_HOME="$home/.config" \
    XDG_STATE_HOME="$home/.local/state" \
    WE_CONFIG_DIR="$unsafe" \
    WE_HOOKS_ROOT="$home/hooks" \
    WE_MENU_FILE="$home/menu.jsonc" \
    WE_BIN_DIR="$home/bin" \
    WE_CONTROLLER="$home/controller" \
    WE_SKIP_MENU_REFRESH=1 \
    "$ROOT/scripts/uninstall.sh" --purge >/dev/null 2>&1; then
    fail 'uninstaller accepted an unsafe purge path'
  fi

  assert_exists "$unsafe"
  assert_exists "$home/.local/state/omarchy/wallpaper-engine/state"
}

test_uninstall_validates_all_paths_before_purge() {
  local home="$TEST_ROOT/atomic-purge-home"
  local config="$home/.config/omarchy/wallpaper-engine"
  local unsafe="$home/keep-state"
  seed_plugin_data "$home"
  mkdir -p "$unsafe"

  if HOME=$home \
    XDG_CONFIG_HOME="$home/.config" \
    XDG_STATE_HOME="$home/.local/state" \
    WE_STATE_DIR="$unsafe" \
    WE_HOOKS_ROOT="$home/hooks" \
    WE_MENU_FILE="$home/menu.jsonc" \
    WE_BIN_DIR="$home/bin" \
    WE_CONTROLLER="$home/controller" \
    WE_SKIP_MENU_REFRESH=1 \
    "$ROOT/scripts/uninstall.sh" --purge >/dev/null 2>&1; then
    fail 'uninstaller accepted an unsafe runtime-state purge path'
  fi

  assert_exists "$config/config.json"
  assert_exists "$unsafe"
}

test_purge_fails_closed_when_controller_fails() {
  local home="$TEST_ROOT/failed-controller-home"
  local output="$TEST_ROOT/failed-controller-output"
  seed_plugin_data "$home"
  mkdir -p "$home/hooks/post-boot.d" "$home/hooks/theme-set.d" "$home/bin"
  printf '#!/usr/bin/env bash\n# wallpaper-engine-omarchy\nexit 0\n' \
    >"$home/hooks/post-boot.d/50-wallpaper-engine"
  printf '#!/usr/bin/env bash\n# wallpaper-engine-omarchy\nexit 0\n' \
    >"$home/hooks/theme-set.d/50-wallpaper-engine"
  printf '{"style.wallpaper-engine":{"action":"omarchy-shell shell summon %s"}}\n' \
    "$PLUGIN_ID" >"$home/menu.jsonc"
  ln -s "$ROOT/bin/we" "$home/bin/omarchy-we"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$home/controller"
  chmod +x "$home/controller"

  if HOME=$home \
    WE_HOOKS_ROOT="$home/hooks" \
    WE_MENU_FILE="$home/menu.jsonc" \
    WE_BIN_DIR="$home/bin" \
    WE_CONTROLLER="$home/controller" \
    WE_SKIP_MENU_REFRESH=1 \
    "$ROOT/scripts/uninstall.sh" --purge >"$output" 2>&1; then
    fail 'purge continued after controller shutdown could not be confirmed'
  fi

  grep -Fq 'Purge cancelled:' "$output" \
    || fail 'failed-closed purge did not explain why it stopped'
  assert_exists "$home/.config/omarchy/wallpaper-engine/config.json"
  assert_exists "$home/.local/state/omarchy/wallpaper-engine/state"
  assert_exists "$home/hooks/post-boot.d/50-wallpaper-engine"
  assert_exists "$home/hooks/theme-set.d/50-wallpaper-engine"
  assert_exists "$home/menu.jsonc"
  assert_exists "$home/bin/omarchy-we"
  grep -Fq 'style.wallpaper-engine' "$home/menu.jsonc" \
    || fail 'failed purge removed the menu integration'
}

test_hooks_are_current_source_wrappers() {
  local home="$TEST_ROOT/hook-wrapper-home"
  local hooks="$home/.config/omarchy/hooks"
  mkdir -p "$home"

  HOME=$home WE_SKIP_MENU_REFRESH=1 "$ROOT/scripts/install-hooks" install >/dev/null
  for hook in \
    "$hooks/post-boot.d/50-wallpaper-engine" \
    "$hooks/theme-set.d/50-wallpaper-engine"; do
    assert_exists "$hook"
    grep -Fqx '# wallpaper-engine-omarchy' "$hook" \
      || fail "installed hook has no ownership marker: $hook"
    grep -Fq 'exec "$HOOK_SOURCE" "$@"' "$hook" \
      || fail "installed hook is a copied snapshot instead of a wrapper: $hook"
    [[ $(wc -l <"$hook") -lt 12 ]] \
      || fail "installed hook unexpectedly contains a copied hook body: $hook"
  done

  printf '#!/usr/bin/env bash\n# user hook\n' \
    >"$hooks/post-boot.d/50-wallpaper-engine"
  HOME=$home "$ROOT/scripts/install-hooks" remove >/dev/null 2>&1
  assert_exists "$hooks/post-boot.d/50-wallpaper-engine"
  assert_absent "$hooks/theme-set.d/50-wallpaper-engine"
}

test_canonical_home_paths_ignore_xdg_overrides() {
  local home="$TEST_ROOT/canonical-home"
  local xdg="$TEST_ROOT/noncanonical-xdg"
  mkdir -p "$home" "$xdg"

  HOME=$home XDG_CONFIG_HOME="$xdg/config" XDG_STATE_HOME="$xdg/state" \
    WE_SKIP_MENU_REFRESH=1 "$ROOT/scripts/install-hooks" install >/dev/null
  HOME=$home XDG_CONFIG_HOME="$xdg/config" XDG_STATE_HOME="$xdg/state" \
    WE_SKIP_MENU_REFRESH=1 "$ROOT/scripts/we-menu-entry" install >/dev/null

  assert_exists "$home/.config/omarchy/hooks/post-boot.d/50-wallpaper-engine"
  assert_exists "$home/.config/omarchy/extensions/omarchy-menu.jsonc"
  assert_absent "$xdg/config/omarchy"
  ! rg -n 'XDG_(CONFIG|STATE)_HOME' \
    "$ROOT/scripts/install.sh" "$ROOT/scripts/uninstall.sh" \
    "$ROOT/scripts/install-hooks" "$ROOT/scripts/we-menu-entry" >/dev/null \
    || fail 'lifecycle scripts still split canonical paths through XDG overrides'
}

test_menu_editor_handles_multiline_and_items_jsonc() {
  local home="$TEST_ROOT/menu-jsonc-home"
  local menu="$home/menu.jsonc"
  local flat="$home/flat-menu.jsonc"
  local before_bad after_bad
  mkdir -p "$home"
  printf '%s\n' \
    '{' \
    '  // root comment survives' \
    '  "items": {' \
    '    // custom comment survives' \
    '    "custom.entry": {' \
    '      "label": "Keep me",' \
    '      "action": "printf keep"' \
    '    },' \
    '    "appearance.wallpaper-engine.revert": {' \
    '      "label": "Legacy",' \
    '      "action": "/old plugin/bin/we revert"' \
    '    },' \
    '  },' \
    '  "metadata": {"enabled": true},' \
    '}' >"$menu"

  HOME=$home WE_MENU_FILE=$menu WE_SKIP_MENU_REFRESH=1 \
    "$ROOT/scripts/we-menu-entry" install >/dev/null
  [[ $(grep -c '"style.wallpaper-engine"' "$menu") -eq 1 ]] \
    || fail 'menu install did not create exactly one GUI entry'
  grep -Fq '// root comment survives' "$menu" \
    || fail 'menu install removed a root comment'
  grep -Fq '// custom comment survives' "$menu" \
    || fail 'menu install removed an items comment'
  grep -Fq '"metadata": {"enabled": true}' "$menu" \
    || fail 'menu install changed an unrelated root member'
  ! grep -Fq 'appearance.wallpaper-engine.revert' "$menu" \
    || fail 'menu install retained a multiline legacy entry'

  HOME=$home WE_MENU_FILE=$menu WE_SKIP_MENU_REFRESH=1 \
    "$ROOT/scripts/we-menu-entry" remove >/dev/null
  ! grep -Fq 'style.wallpaper-engine' "$menu" \
    || fail 'menu remove retained a plugin entry'
  grep -Fq '"custom.entry"' "$menu" \
    || fail 'menu remove deleted an unrelated entry'
  grep -Fq '// custom comment survives' "$menu" \
    || fail 'menu remove deleted an unrelated comment'

  printf '%s\n' \
    '{' \
    '  // flat-shape comment survives' \
    '  "custom.flat": {' \
    '    "label": "Keep flat",' \
    '    "action": "printf flat"' \
    '  }' \
    '}' >"$flat"
  HOME=$home WE_MENU_FILE=$flat WE_SKIP_MENU_REFRESH=1 \
    "$ROOT/scripts/we-menu-entry" install >/dev/null
  grep -Fq '"style.wallpaper-engine"' "$flat" \
    || fail 'menu install did not support the flat JSONC shape'
  HOME=$home WE_MENU_FILE=$flat WE_SKIP_MENU_REFRESH=1 \
    "$ROOT/scripts/we-menu-entry" remove >/dev/null
  grep -Fq '"custom.flat"' "$flat" \
    || fail 'menu remove damaged the flat JSONC shape'
  grep -Fq '// flat-shape comment survives' "$flat" \
    || fail 'menu remove deleted a flat-shape comment'

  printf '{ "items": { "broken": [ } }\n' >"$menu"
  before_bad=$(sha256sum "$menu" | cut -d' ' -f1)
  if HOME=$home WE_MENU_FILE=$menu WE_SKIP_MENU_REFRESH=1 \
      "$ROOT/scripts/we-menu-entry" install >/dev/null 2>&1; then
    fail 'menu editor accepted malformed JSONC'
  fi
  after_bad=$(sha256sum "$menu" | cut -d' ' -f1)
  [[ $before_bad == "$after_bad" ]] \
    || fail 'menu editor changed malformed JSONC before validation failed'
}

test_menu_actions_quote_plugin_paths() {
  local spaced_root="$TEST_ROOT/plugin path with spaces"
  local menu="$TEST_ROOT/spaced-menu.jsonc"
  mkdir -p "$spaced_root/scripts" "$spaced_root/bin"
  cp "$ROOT/manifest.json" "$spaced_root/manifest.json"
  cp "$ROOT/scripts/we-menu-entry" "$spaced_root/scripts/we-menu-entry"
  cp "$ROOT/scripts/we-menu" "$spaced_root/scripts/we-menu"
  cp "$ROOT/bin/we" "$spaced_root/bin/we"
  chmod +x "$spaced_root/scripts/we-menu-entry"

  HOME="$TEST_ROOT/spaced-home" WE_MENU_FILE=$menu WE_SKIP_MENU_REFRESH=1 \
    "$spaced_root/scripts/we-menu-entry" install >/dev/null
  grep -Fq 'plugin\\ path\\ with\\ spaces/bin/we revert' "$menu" \
    || fail 'menu action did not shell-quote a controller path containing spaces'
  grep -Fq 'plugin\\ path\\ with\\ spaces/scripts/we-menu' "$menu" \
    || fail 'menu action did not shell-quote a TUI path containing spaces'
}

test_in_place_install_is_staged_and_generation_stamped() {
  local home="$TEST_ROOT/in-place-home"
  local dest="$home/.config/omarchy/plugins/$PLUGIN_ID"
  local stub_bin="$home/stubs"
  local restart_log="$home/restart.log"
  local remote="$home/plugin-origin.git"
  local update_clone="$home/update-clone"
  local initial_head first_generation updated_head
  local output="$home/install-output"
  mkdir -p "$(dirname -- "$dest")" "$stub_bin"
  cp -a "$ROOT/." "$dest/"
  rm -rf -- "$dest/.git"
  git -C "$dest" init -q
  git -C "$dest" config user.name 'Lifecycle Test'
  git -C "$dest" config user.email 'lifecycle@example.invalid'
  git -C "$dest" config wallpaper-engine.lifecycle-marker preserved
  git -C "$dest" add .
  git -C "$dest" commit -qm 'Create managed plugin fixture'
  git -C "$dest" branch -M main
  git init --bare -q "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
  git -C "$dest" remote add origin "$remote"
  git -C "$dest" push -qu origin main
  initial_head=$(git -C "$dest" rev-parse HEAD)
  mkdir -p "$home/.config/omarchy"
  printf '{"widgets":[{"id":"%s"}]}\n' "$PLUGIN_ID" \
    >"$home/.config/omarchy/shell.json"
  printf '#!/usr/bin/env bash\nprintf restart >"$WE_TEST_RESTART_LOG"\n' \
    >"$stub_bin/omarchy-restart-shell"
  printf '#!/usr/bin/env bash\n[[ ${1:-} == wallpaper-engine-generation && ${2:-} == ping ]] || exit 2\nprintf "%%s\\n" "$(<"$WE_TEST_GENERATION_FILE")"\n' \
    >"$stub_bin/omarchy-shell"
  chmod +x "$stub_bin/omarchy-restart-shell" "$stub_bin/omarchy-shell"

  HOME=$home \
    PATH="$stub_bin:$PATH" \
    WE_TEST_RESTART_LOG=$restart_log \
    WE_TEST_GENERATION_FILE="$dest/.we-build-generation" \
    XDG_CONFIG_HOME="$TEST_ROOT/in-place-wrong-config" \
    XDG_STATE_HOME="$TEST_ROOT/in-place-wrong-state" \
    WE_SKIP_MENU_REFRESH=1 \
    "$dest/scripts/install.sh" >"$output" 2>&1
  grep -Fq "omarchy plugin update $PLUGIN_ID" "$output" \
    || fail 'git checkout install did not print the plugin update path'
  ! grep -Fq 'omarchy plugin update will not work' "$output" \
    || fail 'git checkout install printed the copy-install reinstall recipe'

  grep -Eq '^[0-9]+-[0-9]+-[0-9]+$' "$dest/.we-build-generation" \
    || fail 'canonical in-place install did not create a concrete generation'
  first_generation=$(<"$dest/.we-build-generation")
  [[ -d $dest/.git ]] \
    || fail 'canonical in-place install removed git metadata'
  [[ $(git -C "$dest" rev-parse --is-inside-work-tree) == true ]] \
    || fail 'canonical in-place install left an unusable git worktree'
  [[ $(git -C "$dest" rev-parse --show-toplevel) == "$dest" ]] \
    || fail 'canonical in-place install detached git from the plugin root'
  [[ $(git -C "$dest" rev-parse HEAD) == "$initial_head" ]] \
    || fail 'canonical in-place install changed the managed checkout revision'
  [[ $(git -C "$dest" config wallpaper-engine.lifecycle-marker) == preserved ]] \
    || fail 'canonical in-place install replaced repository configuration'
  [[ -z $(git -C "$dest" status --porcelain --untracked-files=all) ]] \
    || fail 'canonical in-place install dirtied the managed checkout'
  assert_exists "$restart_log"
  assert_exists "$home/.local/state/omarchy/wallpaper-engine/transition.lock"
  assert_absent "$TEST_ROOT/in-place-wrong-config/omarchy"
  assert_absent "$TEST_ROOT/in-place-wrong-state/omarchy"

  # Exercise the operation used by `omarchy plugin update`: a clean
  # fast-forward that changes Service.qml, followed by another in-place install.
  git clone -q -b main "$remote" "$update_clone"
  git -C "$update_clone" config user.name 'Lifecycle Test Updater'
  git -C "$update_clone" config user.email 'updater@example.invalid'
  printf '\n// lifecycle fast-forward fixture\n' >>"$update_clone/Service.qml"
  git -C "$update_clone" add Service.qml
  git -C "$update_clone" commit -qm 'Update service fixture'
  git -C "$update_clone" push -q origin main
  updated_head=$(git -C "$update_clone" rev-parse HEAD)
  git -C "$dest" fetch -q origin HEAD
  git -C "$dest" merge --ff-only -q FETCH_HEAD
  [[ $(git -C "$dest" rev-parse HEAD) == "$updated_head" ]] \
    || fail 'managed checkout could not fast-forward after installation'

  HOME=$home \
    PATH="$stub_bin:$PATH" \
    WE_TEST_RESTART_LOG=$restart_log \
    WE_TEST_GENERATION_FILE="$dest/.we-build-generation" \
    WE_SKIP_MENU_REFRESH=1 \
    "$dest/scripts/install.sh" >/dev/null
  [[ $(<"$dest/.we-build-generation") != "$first_generation" ]] \
    || fail 'repeated in-place install reused the previous generation'
  grep -Fq '// lifecycle fast-forward fixture' "$dest/Service.qml" \
    || fail 'repeated in-place install lost the fast-forwarded service update'
  [[ -z $(git -C "$dest" status --porcelain --untracked-files=all) ]] \
    || fail 'repeated in-place install dirtied the managed checkout'

  first_generation=$(<"$dest/.we-build-generation")
  printf '#!/usr/bin/env bash\nexit 1\n' >"$stub_bin/omarchy-restart-shell"
  if HOME=$home \
      PATH="$stub_bin:$PATH" \
      WE_TEST_RESTART_LOG=$restart_log \
      WE_TEST_GENERATION_FILE="$dest/.we-build-generation" \
      WE_SKIP_MENU_REFRESH=1 \
      "$dest/scripts/install.sh" >/dev/null 2>&1; then
    fail 'in-place install did not fail when shell restart failed'
  fi
  [[ -d $dest/.git && $(git -C "$dest" rev-parse HEAD) == "$updated_head" ]] \
    || fail 'health rollback did not preserve the managed git checkout'
  [[ $(<"$dest/.we-build-generation") == "$first_generation" ]] \
    || fail 'health rollback did not restore the previous generation'
  [[ -z $(git -C "$dest" status --porcelain --untracked-files=all) ]] \
    || fail 'health rollback dirtied the managed checkout'
}

test_copy_install_prints_reinstall_recipe() {
  local home="$TEST_ROOT/copy-install-home"
  local dest="$home/.config/omarchy/plugins/$PLUGIN_ID"
  local output="$TEST_ROOT/copy-install-output"
  mkdir -p "$home"

  HOME=$home WE_SKIP_MENU_REFRESH=1 \
    "$ROOT/scripts/install.sh" >"$output" 2>&1

  assert_exists "$dest/scripts/install.sh"
  [[ ! -e $dest/.git ]] \
    || fail 'copy install left a .git directory at dest'
  grep -Fq 'omarchy plugin update will not work' "$output" \
    || fail 'copy install did not say omarchy plugin update will not work'
  grep -Fq "omarchy plugin remove $PLUGIN_ID" "$output" \
    || fail 'copy install did not print omarchy plugin remove'
  grep -Fq "omarchy plugin add https://github.com/14brussell/Wallpaper-Engine-Omarchy.git --enable" \
    "$output" \
    || fail 'copy install did not print omarchy plugin add'
  grep -Fq "$dest/scripts/install.sh" "$output" \
    || fail 'copy install did not print the installer path'
  grep -Fq 'Omarchy does not run plugin installers' "$output" \
    || fail 'copy install did not say Omarchy never runs install.sh'
  grep -Fq '~/.config/omarchy/wallpaper-engine/' "$output" \
    || fail 'copy install did not say wallpaper-engine config is preserved'
  grep -Fq 'Do not use uninstall.sh --purge' "$output" \
    || fail 'copy install did not warn against a factory wipe'
  ! grep -Eq '^[[:space:]]+.*uninstall\.sh --purge' "$output" \
    || fail 'copy install must not prescribe uninstall.sh --purge as a command'
}

test_readme_update_leads_with_reinstall() {
  local update_section remove_line update_line
  update_section=$(awk '/^### Update$/,/^## Remove$/' "$ROOT/README.md")
  printf '%s\n' "$update_section" | grep -Fq 'one-time reinstall' \
    || fail 'README Update does not say this is a one-time reinstall'
  printf '%s\n' "$update_section" | grep -Fq '~/.config/omarchy/wallpaper-engine/' \
    || fail 'README Update does not say wallpaper-engine config is preserved'
  printf '%s\n' "$update_section" | grep -Fq 'git merge --ff-only' \
    || fail 'README Update does not require a fast-forward merge onto main'
  printf '%s\n' "$update_section" | grep -Fq \
    'omarchy plugin add https://github.com/14brussell/Wallpaper-Engine-Omarchy.git --enable' \
    || fail 'README Update is missing the plugin add command'
  printf '%s\n' "$update_section" | grep -Fq 'never invoke' \
    || fail 'README Update does not say platform add/update never runs install.sh'
  remove_line=$(printf '%s\n' "$update_section" \
    | grep -n -m1 'omarchy plugin remove io.github.14brussell.wallpaper-engine' \
    | cut -d: -f1)
  update_line=$(printf '%s\n' "$update_section" \
    | grep -n -m1 'omarchy plugin update io.github.14brussell.wallpaper-engine' \
    | cut -d: -f1)
  [[ -n $remove_line && -n $update_line && $remove_line -lt $update_line ]] \
    || fail 'README Update must lead with plugin remove, not plugin update'
  ! printf '%s\n' "$update_section" | awk '/^```/,/^```$/' | grep -Fq -- '--purge' \
    || fail 'README Update recipe must not use uninstall.sh --purge'
}

test_qml_validation_is_explicit_about_syntax() {
  grep -Fq -- '--json "$lint_json"' "$ROOT/scripts/install.sh" \
    || fail 'installer does not request machine-readable QML diagnostics'
  grep -Fq '.id == "syntax"' "$ROOT/scripts/install.sh" \
    || fail 'installer still treats warning-blind qmllint rc=0 as semantic validation'
  grep -Fq 'omarchy-plugin-validate "$root"' "$ROOT/scripts/install.sh" \
    || fail 'installer does not use the supported Omarchy plugin validator'
}

test_qml_syntax_error_blocks_install() {
  [[ -x /usr/lib/qt6/bin/qmllint || $(command -v qmllint 2>/dev/null) ]] || return 0
  local home="$TEST_ROOT/bad-qml-home"
  local dest="$home/.config/omarchy/plugins/$PLUGIN_ID"
  local output="$TEST_ROOT/bad-qml-output"
  mkdir -p "$(dirname -- "$dest")"
  cp -a "$ROOT/." "$dest/"
  printf 'import QtQuick\nItem { broken syntax }\n' >"$dest/Broken.qml"

  if HOME=$home WE_SKIP_MENU_REFRESH=1 \
      "$dest/scripts/install.sh" >"$output" 2>&1; then
    fail 'installer accepted a QML parser error'
  fi
  grep -Fq 'Expected token' "$output" \
    || fail 'installer did not report the QML parser diagnostic'
  [[ -z $(find "$(dirname -- "$dest")" -maxdepth 1 -type d \
      -name ".${PLUGIN_ID}.stage.*" -print -quit) ]] \
    || fail 'failed QML validation left a staged plugin tree behind'
}

if [[ ${WE_LIFECYCLE_TEST_FUNCTIONS_ONLY:-0} == 1 ]]; then
  return 0
fi

test_symlinked_cli
test_additional_wallpaper_folders
test_qml_text_is_plain
test_panel_badges_track_display_runtime
test_display_actions_are_contextual
test_panel_uses_full_product_name
test_auto_match_hint_is_concise
test_save_apply_status_is_stable_and_separate
test_save_controls_stay_outside_settings_scroll
test_workshop_heading_is_visibly_bold
test_workshop_catalog_persists_across_display_tabs
test_legacy_preflight
test_uninstall_preserves_data
test_uninstall_purges_data
test_uninstall_refuses_unsafe_purge_path
test_uninstall_validates_all_paths_before_purge
test_purge_fails_closed_when_controller_fails
test_hooks_are_current_source_wrappers
test_canonical_home_paths_ignore_xdg_overrides
test_menu_editor_handles_multiline_and_items_jsonc
test_menu_actions_quote_plugin_paths
test_in_place_install_is_staged_and_generation_stamped
test_copy_install_prints_reinstall_recipe
test_readme_update_leads_with_reinstall
test_qml_validation_is_explicit_about_syntax
test_qml_syntax_error_blocks_install

echo 'install lifecycle tests: PASS'
