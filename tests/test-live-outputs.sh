#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

HOME="$TEST_ROOT/home"
XDG_CONFIG_HOME="$HOME/.config"
XDG_STATE_HOME="$HOME/.local/state"
WE_HOTPLUG_START_SETTLE_MS=0
unset HYPRLAND_INSTANCE_SIGNATURE || true
mkdir -p "$HOME"

# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

install_hyprctl() {
  local json=$1
  local stub_bin="$TEST_ROOT/bin"
  mkdir -p "$stub_bin"
  cat >"$stub_bin/hyprctl" <<EOF
#!/usr/bin/env bash
[[ \${1:-} == monitors && \${2:-} == -j ]] || exit 2
printf '%s\\n' '$json'
EOF
  chmod +x "$stub_bin/hyprctl"
  PATH="$stub_bin:$PATH"
}

seed_two_displays() {
  we_load_config
  we_jq_write '.displays["DP-1"] = {"wallpaper":"111"} | .displays["HDMI-A-1"] = {"wallpaper":"222"} | .active = true'
}

stub_engine_start() {
  local log=$1
  : >"$log"
  we_start_engine_monitor() {
    printf '%s\n' "$1" >>"$WE_TEST_START_LOG"
    return 0
  }
  we_notify() { :; }
  we_ensure_omarchy_background_enabled() { return 0; }
  we_ensure_monitor_watch() { return 0; }
  we_sync_active_state() { return 0; }
  WE_ENGINE_BIN=true
  WE_TEST_START_LOG=$log
}

run_start() {
  local err=$1
  local rc=0
  we_start_engine >"$TEST_ROOT/start.out" 2>"$err" || rc=$?
  return "$rc"
}

test_configured_but_not_live_is_skipped() {
  seed_two_displays
  install_hyprctl '[{"name":"DP-1","width":1920,"height":1080,"x":0,"y":0,"scale":1}]'

  local live
  live=$(we_configured_live_monitors | paste -sd, -)
  [[ $live == DP-1 ]] || fail "live configured set was '$live', expected DP-1"

  local start_log="$TEST_ROOT/start.log"
  stub_engine_start "$start_log"

  local started elapsed rc=0
  started=$(we_now_ms)
  run_start "$TEST_ROOT/skip.err" || rc=$?
  elapsed=$(( $(we_now_ms) - started ))
  (( rc == 0 )) || fail "bare apply rc=$rc: $(cat "$TEST_ROOT/skip.err")"

  grep -qx HDMI-A-1 "$start_log" \
    && fail 'disconnected HDMI-A-1 was started'
  grep -qx DP-1 "$start_log" \
    || fail "bare apply started '$(cat "$start_log")' instead of only DP-1"
  grep -q 'Skipping disconnected display HDMI-A-1' "$TEST_ROOT/skip.err" \
    || fail 'bare apply did not report the skipped disconnected output'
  (( elapsed < 2000 )) \
    || fail "bare apply stalled ${elapsed}ms on a disconnected output"
}

test_all_disconnected_skips_without_clearing_active() {
  seed_two_displays
  install_hyprctl '[]'

  local start_log="$TEST_ROOT/start-empty.log"
  stub_engine_start "$start_log"
  we_start_engine_monitor() {
    printf '%s\n' "$1" >>"$start_log"
    sleep 15
    return 0
  }

  local started elapsed rc=0
  started=$(we_now_ms)
  run_start "$TEST_ROOT/empty.err" || rc=$?
  elapsed=$(( $(we_now_ms) - started ))
  (( rc == 0 )) || fail "disconnected-only apply rc=$rc: $(cat "$TEST_ROOT/empty.err")"

  [[ ! -s $start_log ]] || fail 'disconnected-only apply started an engine'
  (( elapsed < 2000 )) || fail "disconnected-only apply stalled ${elapsed}ms"
  [[ $(we_jq -r '.active') == true ]] \
    || fail 'skipping disconnected outputs cleared active=true'
}

test_disabled_hyprctl_head_is_not_live() {
  seed_two_displays
  install_hyprctl '[{"name":"HDMI-A-1","disabled":true,"width":0,"height":0},{"name":"DP-1","disabled":false,"width":1920,"height":1080}]'
  local names
  names=$(we_live_monitor_names | paste -sd, -)
  [[ $names == DP-1 ]] || fail "disabled HDMI-A-1 was treated as live: $names"
}

test_named_apply_rejects_disconnected() {
  seed_two_displays
  install_hyprctl '[{"name":"DP-1","width":1920,"height":1080}]'
  local rc=0
  env HOME="$HOME" PATH="$PATH" "$ROOT/bin/we" apply HDMI-A-1 \
    >"$TEST_ROOT/named.out" 2>"$TEST_ROOT/named.err" || rc=$?
  (( rc != 0 )) || fail 'named apply accepted a disconnected output'
  grep -q 'Unknown display: HDMI-A-1' "$TEST_ROOT/named.err" \
    || fail 'named apply did not explain the disconnected output'
}

test_hotplug_start_and_stop() {
  seed_two_displays
  we_ensure_dirs
  local start_log="$TEST_ROOT/hotplug-start.log"
  stub_engine_start "$start_log"
  we_start_engine_monitor() {
    printf 'start:%s\n' "$1" >>"$start_log"
    return 0
  }

  install_hyprctl '[{"name":"DP-1","width":1920,"height":1080},{"name":"HDMI-A-1","width":2560,"height":1440}]'
  we_reconcile_live_outputs
  grep -qx 'start:DP-1' "$start_log" || fail 'hotplug did not start live DP-1'
  grep -qx 'start:HDMI-A-1' "$start_log" || fail 'hotplug did not start live HDMI-A-1'
  we_jq_write '.active = true'

  : >"$start_log"
  local hdmi_pid
  hdmi_pid=$(we_monitor_pid_file HDMI-A-1)
  printf '99999 1\n' >"$hdmi_pid"
  [[ -f $hdmi_pid ]] || fail 'hdmi pid fixture was not created'

  install_hyprctl '[{"name":"DP-1","width":1920,"height":1080}]'
  we_reconcile_live_outputs
  [[ ! -f $hdmi_pid ]] || fail 'disconnected HDMI engine pid file was left behind'
  if grep -q 'start:HDMI-A-1' "$start_log"; then
    fail 'unplug reconcile restarted the disconnected output'
  fi

  we_jq_write '.active = false'
  : >"$start_log"
  install_hyprctl '[{"name":"DP-1","width":1920,"height":1080},{"name":"HDMI-A-1","width":2560,"height":1440}]'
  we_reconcile_live_outputs
  [[ ! -s $start_log ]] || fail 'inactive session still started engines on hotplug'
}

test_unstable_hotplug_set_is_not_started() (
  seed_two_displays
  we_ensure_dirs
  local start_log="$TEST_ROOT/unstable-start.log"
  local monitor_state="$TEST_ROOT/unstable-monitors.json"
  local stub_bin="$TEST_ROOT/unstable-bin"
  stub_engine_start "$start_log"

  mkdir -p "$stub_bin"
  cat >"$stub_bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == monitors && ${2:-} == -j ]] || exit 2
cat "$WE_TEST_MONITOR_STATE"
EOF
  chmod +x "$stub_bin/hyprctl"
  PATH="$stub_bin:$PATH"
  export WE_TEST_MONITOR_STATE="$monitor_state"
  printf '%s\n' '[{"name":"DP-1","width":1920,"height":1080},{"name":"HDMI-A-1","width":2560,"height":1440}]' \
    >"$monitor_state"

  # Simulate the display profile changing while the hotplug start is settling.
  WE_HOTPLUG_START_SETTLE_MS=1
  we_wait_ms() {
    printf '%s\n' '[{"name":"DP-1","width":1920,"height":1080}]' >"$monitor_state"
  }

  we_reconcile_live_outputs
  [[ ! -s $start_log ]] \
    || fail "unstable hotplug started renderers: $(cat "$start_log")"
)

test_empty_live_outputs_do_not_stop_engines() {
  seed_two_displays
  we_ensure_dirs
  local pid_file
  pid_file=$(we_monitor_pid_file DP-1)
  printf '99999 1\n' >"$pid_file"
  install_hyprctl '[]'
  we_reconcile_live_outputs
  [[ -f $pid_file ]] || fail 'empty live list removed the engine pid file'
}

test_monitor_watch_ensure_is_noop_without_hyprland() {
  local started elapsed
  started=$(we_now_ms)
  "$ROOT/hooks/monitor-watch.sh" --ensure
  elapsed=$(( $(we_now_ms) - started ))
  (( elapsed < 1000 )) || fail "--ensure blocked ${elapsed}ms without Hyprland"
}

test_monitor_watch_ignores_config_reload() {
  if grep -E 'configreloaded\\>\\>\*' "$ROOT/hooks/monitor-watch.sh"; then
    fail 'monitor-watch still reconciles on hyprctl configreloaded'
  fi
}

test_monitor_watch_can_cancel_active_reconcile() {
  grep -Fq 'exec "$ROOT/bin/we" sync-outputs' "$ROOT/hooks/monitor-watch.sh" \
    || fail 'monitor-watch does not replace its debounce child with the cancellable reconcile'
}

test_configured_but_not_live_is_skipped
test_all_disconnected_skips_without_clearing_active
test_empty_live_outputs_do_not_stop_engines
test_disabled_hyprctl_head_is_not_live
test_named_apply_rejects_disconnected
test_hotplug_start_and_stop
test_unstable_hotplug_set_is_not_started
test_monitor_watch_ensure_is_noop_without_hyprland
test_monitor_watch_ignores_config_reload
test_monitor_watch_can_cancel_active_reconcile

echo 'live-output regression tests: PASS'
