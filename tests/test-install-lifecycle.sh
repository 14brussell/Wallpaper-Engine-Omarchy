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

test_save_apply_status_stays_in_button() {
  grep -A8 -F 'id: saveApplyButton' "$ROOT/DisplayTab.qml" \
    | grep -Fq 'text: root.saveApplyStatus.length' \
    || fail 'Save & apply does not expose status through its button label'
  ! grep -Fq 'visible: root.busy || root.localStatus.length > 0' \
    "$ROOT/DisplayTab.qml" \
    || fail 'display action status still adds a layout-shifting row'
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

test_symlinked_cli
test_additional_wallpaper_folders
test_qml_text_is_plain
test_panel_badges_track_display_runtime
test_display_actions_are_contextual
test_panel_uses_full_product_name
test_auto_match_hint_is_concise
test_save_apply_status_stays_in_button
test_save_controls_stay_outside_settings_scroll
test_workshop_heading_is_visibly_bold
test_workshop_catalog_persists_across_display_tabs
test_legacy_preflight
test_uninstall_preserves_data
test_uninstall_purges_data
test_uninstall_refuses_unsafe_purge_path
test_uninstall_validates_all_paths_before_purge

echo 'install lifecycle tests: PASS'
