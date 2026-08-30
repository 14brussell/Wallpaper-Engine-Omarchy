#!/usr/bin/env bash
# Watch Hyprland monitor add/remove the same way Omarchy's
# omarchy-hyprland-monitor-watch does. This plugin never disables or replaces
# that watcher; it only starts or stops per-output Wallpaper Engine processes
# after Hyprland (and clamshell) have settled.
#
# Usage:
#   monitor-watch.sh --ensure     Start detached if a Hyprland session is live
#   monitor-watch.sh --reconcile  One-shot start/stop vs current hyprctl outputs
#   monitor-watch.sh --loop       Foreground socket listener (systemd/setsid)

set -euo pipefail

HOOK_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/lib/common.sh"

WE_MONITOR_WATCH_UNIT="${WE_MONITOR_WATCH_UNIT:-wallpaper-engine-monitor-watch}"
WE_MONITOR_WATCH_DEBOUNCE_S="${WE_MONITOR_WATCH_DEBOUNCE_S:-0.4}"
WE_MONITOR_WATCH_PID_FILE="${WE_MONITOR_WATCH_PID_FILE:-$WE_STATE_DIR/monitor-watch.pid}"
WE_MONITOR_WATCH_LOG="${WE_MONITOR_WATCH_LOG:-$WE_STATE_DIR/monitor-watch.log}"

hyprland_socket() {
  local runtime=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
  local sig=${HYPRLAND_INSTANCE_SIGNATURE:-}
  [[ -n $sig ]] || return 1
  printf '%s/hypr/%s/.socket2.sock' "$runtime" "$sig"
}

watch_pid_live() {
  local pid
  [[ -f $WE_MONITOR_WATCH_PID_FILE ]] || return 1
  pid=$(<"$WE_MONITOR_WATCH_PID_FILE")
  [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 -- "$pid" 2>/dev/null
}

unit_is_running() {
  command -v systemctl >/dev/null 2>&1 \
    && systemctl --user is-active --quiet "$WE_MONITOR_WATCH_UNIT" 2>/dev/null
}

watch_already_running() {
  unit_is_running || watch_pid_live
}

cmd_ensure() {
  [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] || return 0
  we_ensure_dirs
  : >>"$WE_MONITOR_WATCH_LOG"

  # Singleton: never systemd-run (or setsid) a second --loop. A failed
  # systemd-run while the unit is already starting used to fall through to
  # setsid and overlap PIDs. Exec stays HOOK_PATH (plugin dir when installed).
  if watch_already_running; then
    return 0
  fi

  if command -v systemd-run >/dev/null 2>&1; then
    systemctl --user reset-failed "$WE_MONITOR_WATCH_UNIT" 2>/dev/null || true
    if systemd-run --user --quiet --unit="$WE_MONITOR_WATCH_UNIT" \
      --property=Restart=on-failure \
      --property=RestartSec=2 \
      --property="StandardOutput=append:$WE_MONITOR_WATCH_LOG" \
      --property="StandardError=append:$WE_MONITOR_WATCH_LOG" \
      "$HOOK_PATH" --loop 9>&-; then
      return 0
    fi
    # Lost the start race, or the unit name is already taken: do not setsid.
    if watch_already_running; then
      return 0
    fi
    if command -v systemctl >/dev/null 2>&1 \
      && systemctl --user is-failed --quiet "$WE_MONITOR_WATCH_UNIT" 2>/dev/null; then
      :
    elif command -v systemctl >/dev/null 2>&1 \
      && systemctl --user show -p LoadState --value "$WE_MONITOR_WATCH_UNIT" 2>/dev/null \
        | grep -qx loaded; then
      return 0
    fi
  fi

  if watch_already_running; then
    return 0
  fi

  if command -v setsid >/dev/null 2>&1; then
    nohup setsid -f "$HOOK_PATH" --loop </dev/null >>"$WE_MONITOR_WATCH_LOG" 2>&1 9>&- &
  else
    nohup "$HOOK_PATH" --loop </dev/null >>"$WE_MONITOR_WATCH_LOG" 2>&1 9>&- &
  fi
}

kick_reconcile() {
  if [[ -n ${debounce_pid:-} ]] && kill -0 -- "$debounce_pid" 2>/dev/null; then
    kill -- "$debounce_pid" 2>/dev/null || true
    wait "$debounce_pid" 2>/dev/null || true
  fi
  (
    sleep "$WE_MONITOR_WATCH_DEBOUNCE_S"
    "$ROOT/bin/we" sync-outputs || true
  ) &
  debounce_pid=$!
}

cmd_loop() {
  local socket debounce_pid="" existing
  we_ensure_dirs
  : >>"$WE_MONITOR_WATCH_LOG"
  if watch_pid_live; then
    existing=$(<"$WE_MONITOR_WATCH_PID_FILE")
    if [[ $existing != "$$" ]]; then
      printf 'monitor-watch already running pid=%s; exiting\n' "$existing" \
        >>"$WE_MONITOR_WATCH_LOG"
      exit 0
    fi
  fi
  printf '%s\n' "$$" >"$WE_MONITOR_WATCH_PID_FILE"
  printf 'monitor-watch loop start pid=%s root=%s\n' "$$" "$ROOT" \
    >>"$WE_MONITOR_WATCH_LOG"
  trap 'rm -f -- "$WE_MONITOR_WATCH_PID_FILE"' EXIT
  while true; do
    socket=$(hyprland_socket || true)
    if [[ -z $socket || ! -S $socket ]]; then
      sleep 2
      continue
    fi
    if ! command -v socat >/dev/null 2>&1; then
      # Compose with Omarchy without fighting it: poll live outputs when socat
      # is missing rather than installing a second compositor integration.
      sleep 2
      "$ROOT/bin/we" sync-outputs || true
      continue
    fi

    while read -r event; do
      case "$event" in
        # configreloaded is hyprctl reload (omarchy-theme-set). Reconciling
        # then can see zero heads and SIGTERM every engine.
        monitoradded\>\>*|monitoraddedv2\>\>*|monitorremoved\>\>*|monitorremovedv2\>\>*)
          kick_reconcile
          ;;
      esac
    done < <(socat -U - "UNIX-CONNECT:$socket" 2>/dev/null || true)

    sleep 1
  done
}

case ${1:-} in
  --ensure) cmd_ensure ;;
  --reconcile) we_reconcile_live_outputs ;;
  --loop) cmd_loop ;;
  *)
    echo "Usage: monitor-watch.sh --ensure|--reconcile|--loop" >&2
    exit 2
    ;;
esac
