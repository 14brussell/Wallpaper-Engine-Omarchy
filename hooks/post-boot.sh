#!/usr/bin/env bash
# Omarchy post-boot hook (installed as ~/.config/omarchy/hooks/post-boot.d/50-wallpaper-engine).
#
# Hyprland already waited ~2s before omarchy-hook post-boot. If Wallpaper Engine
# was left active last session, relaunch each configured display independently.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/lib/common.sh"

we_load_config

active=$(we_jq -r '.active // false')
if [[ $active != true ]]; then
  exit 0
fi

# Wait until Hyprland reports outputs before starting display-bound surfaces.
i=0
mons=""
while (( i < 20 )); do
  mons=$(we_list_monitors 2>/dev/null || true)
  [[ -n $mons ]] && break
  sleep 0.25
  i=$((i + 1))
done
sleep 1

"$ROOT/bin/we" apply >/dev/null 2>&1 || true
