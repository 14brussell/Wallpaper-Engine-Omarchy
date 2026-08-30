#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MENU="$ROOT/scripts/we-menu"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

bash -n "$MENU" || fail 'TUI does not parse as valid Bash'

grep -Fq 'Wallpaper Engine for Omarchy · $monitor · $runtime_label' "$MENU" \
  || fail 'display menu does not expose per-display runtime state'
grep -Fq 'run_we "Started $monitor." apply "$monitor"' "$MENU" \
  || fail 'Start is not scoped to the selected display'
grep -Fq 'run_we "Stopped $monitor." stop "$monitor"' "$MENU" \
  || fail 'Stop is not scoped to the selected display'
grep -Fq '"Save & apply"' "$MENU" \
  || fail 'display menu has no explicit Save & apply action'
! grep -Fq 'offer_apply_now' "$MENU" \
  || fail 'individual setting edits still prompt for immediate apply'
! grep -Fq '"Apply saved config"' "$MENU" \
  || fail 'TUI still exposes the obsolete global apply action'
! grep -Fq '"Stop Wallpaper Engine"' "$MENU" \
  || fail 'TUI still exposes the obsolete global stop action'

for setting in \
  'Wayland layer' \
  'Disable automute' \
  'Disable audio processing' \
  'Keep playing when fullscreen' \
  'Pause only for active fullscreen app' \
  'Ignore fullscreen app IDs' \
  'Disable particles' \
  'Disable mouse interaction' \
  'Disable parallax' \
  'Wallpaper properties'; do
  grep -Fq "$setting" "$MENU" || fail "TUI is missing setting: $setting"
done

grep -Fq 'lastAppliedMonitor // empty' "$MENU" \
  || fail 'auto-match is not tied to the most recently applied wallpaper'
grep -Fq 'if [[ $active == true ]]' "$MENU" \
  || fail 'TUI cannot undo an active theme match'
grep -Fq 'wallpaper_folders_menu' "$MENU" \
  || fail 'TUI cannot manage additional Workshop folders'

WE_MENU_TEST_MODE=1 bash -c '
  set -euo pipefail
  source "$1"

  gum() {
    case "$1" in
      choose|filter) head -n1 ;;
      style|pager) cat >/dev/null || true ;;
    esac
  }
  status_json() {
    printf "%s\n" '\''{"monitors":[{"name":"DP-1","width":2560,"height":1440},{"name":"HDMI-A-1","width":1920,"height":1080}],"engineDisplays":["DP-1"]}'\''
  }
  we_list_wallpapers() {
    printf "42\\tA Wallpaper\\t/tmp/42\\t/tmp/42/preview.png\\n"
  }

  monitor_is_running DP-1
  ! monitor_is_running HDMI-A-1
  pick_monitor
  [[ $PICKED_MONITOR == DP-1 ]]
  choose_toggle test false Enabled Disabled
  [[ $TOGGLE_VALUE == true ]]
  pick_wallpaper_id
  [[ $PICKED_WALLPAPER_ID == 42 ]]
' _ "$MENU" || fail 'TUI helper interaction smoke test failed'

echo 'TUI parity tests: PASS'
