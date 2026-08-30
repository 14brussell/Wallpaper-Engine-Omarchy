#!/usr/bin/env bash
# Omarchy post-boot hook (installed as ~/.config/omarchy/hooks/post-boot.d/50-wallpaper-engine).
#
# Hyprland already waited ~2s before omarchy-hook post-boot. If Wallpaper Engine
# was left active last session, relaunch each configured display independently.
# A socket watcher (same events as omarchy-hyprland-monitor-watch) keeps engines
# aligned with dock/lid/hotplug after boot.

set -euo pipefail

HOOK_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/lib/common.sh"

WE_POST_BOOT_APPLY_BIN="${WE_POST_BOOT_APPLY_BIN:-$ROOT/bin/we}"

restore_wallpapers() {
  # Wait in the detached worker, never in Omarchy's serial hook runner.
  local i=0 mons=""
  while (( i < 20 )); do
    mons=$(we_list_monitors 2>/dev/null || true)
    [[ -n $mons ]] && break
    sleep 0.25
    i=$((i + 1))
  done
  sleep 1

  # A boot restore is not a new user choice. Preserve whichever wallpaper was
  # most recently applied interactively as the default auto-match source.
  WE_PRESERVE_LAST_APPLIED=1 "$WE_POST_BOOT_APPLY_BIN" apply
}

if [[ ${1:-} == --restore ]]; then
  restore_wallpapers
  exit
fi

# Always listen for monitor add/remove, even when wallpapers are currently
# stopped, so a later apply can hotplug without a second login.
"$ROOT/hooks/monitor-watch.sh" --ensure || true

we_load_config

active=$(we_jq -r '.active // false')
if [[ $active != true ]]; then
  exit 0
fi

we_ensure_dirs
POST_BOOT_LOG="$WE_STATE_DIR/post-boot.log"
: >>"$POST_BOOT_LOG"

# A transient user unit is fully detached from the hook runner and cannot
# inherit its advisory-lock descriptors. Keep a setsid fallback for minimal
# sessions where the user systemd manager is unavailable. fd 9 is explicitly
# closed because it is the plugin transition lock's documented descriptor.
#
# Default KillMode=control-group SIGTERMs leftover cgroup members when the
# transient unit's main process (we apply) exits. linux-wallpaperengine is
# nohup'd on purpose so it outlives apply; KillMode=process is required so
# restore does not kill the engines it just started.
unit="wallpaper-engine-restore-${PPID}-$$"
if command -v systemd-run >/dev/null 2>&1 \
    && systemd-run --user --collect --quiet --unit="$unit" \
      --property="StandardOutput=append:$POST_BOOT_LOG" \
      --property="StandardError=append:$POST_BOOT_LOG" \
      --property=KillMode=process \
      env WE_PRESERVE_LAST_APPLIED=1 \
        WE_POST_BOOT_APPLY_BIN="$WE_POST_BOOT_APPLY_BIN" \
        "$HOOK_PATH" --restore 9>&-; then
  exit 0
fi

if command -v setsid >/dev/null 2>&1; then
  nohup setsid -f env WE_PRESERVE_LAST_APPLIED=1 \
    WE_POST_BOOT_APPLY_BIN="$WE_POST_BOOT_APPLY_BIN" \
    "$HOOK_PATH" --restore </dev/null >>"$POST_BOOT_LOG" 2>&1 9>&- &
else
  nohup env WE_PRESERVE_LAST_APPLIED=1 \
    WE_POST_BOOT_APPLY_BIN="$WE_POST_BOOT_APPLY_BIN" \
    "$HOOK_PATH" --restore </dev/null >>"$POST_BOOT_LOG" 2>&1 9>&- &
fi
