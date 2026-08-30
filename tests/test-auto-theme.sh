#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
TEST_HOME="$TEST_ROOT/home"
STUB_BIN="$TEST_ROOT/bin"
mkdir -p "$TEST_HOME/.local/state/omarchy/current" "$STUB_BIN"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cat >"$STUB_BIN/omarchy" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1:-} == theme && ${2:-} == set && -n ${3:-} ]] || exit 2
slug=$3
user_theme="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/themes/$slug"
[[ -d $user_theme ]] || exit 1
current="$HOME/.local/state/omarchy/current"
rm -rf "$current/theme"
mkdir -p "$current/theme"
cp -a "$user_theme"/. "$current/theme"/
printf '%s\n' "$slug" >"$current/theme.name"
background=$(find "$current/theme/backgrounds" -maxdepth 1 -type f | sort | head -n1)
[[ -n $background ]] && ln -nsf "$background" "$current/background"
EOF
chmod +x "$STUB_BIN/omarchy"

mkdir -p \
  "$TEST_HOME/.config/omarchy/themes/gruvbox/backgrounds" \
  "$TEST_HOME/.local/state/omarchy/wallpaper-engine"
printf 'mode = "dark"\n' >"$TEST_HOME/.config/omarchy/themes/gruvbox/colors.toml"
current_wallpaper_key=$(printf '%s' 123 | sha256sum | cut -c1-16)
old_wallpaper_key=$(printf '%s' old-wallpaper | sha256sum | cut -c1-16)
python3 - "$TEST_HOME" "$current_wallpaper_key" "$old_wallpaper_key" <<'PY'
import sys
from pathlib import Path
from PIL import Image

home = Path(sys.argv[1])
current_key = sys.argv[2]
old_key = sys.argv[3]
wallpaper = Image.new("RGB", (640, 360), "#1d2559")
for x in range(180, 460):
    for y in range(80, 280):
        wallpaper.putpixel((x, y), (225, 82, 120))
wallpaper.save(
    home / f".local/state/omarchy/wallpaper-engine/lwe-ready.DP-1.{current_key}.123.jpg"
)
# A newer capture for the monitor's previously configured wallpaper must not
# override the framebuffer associated with the current wallpaper.
Image.new("RGB", (640, 360), "#00ff00").save(
    home / f".local/state/omarchy/wallpaper-engine/lwe-ready.DP-1.{old_key}.456.jpg"
)
Image.new("RGB", (16, 9), "#282828").save(
    home / ".config/omarchy/themes/gruvbox/backgrounds/wallpaper.jpg"
)
PY
printf 'gruvbox\n' >"$TEST_HOME/.local/state/omarchy/current/theme.name"

env_cmd=(
  env
  "HOME=$TEST_HOME"
  "XDG_CONFIG_HOME=$TEST_HOME/.config"
  "XDG_STATE_HOME=$TEST_HOME/.local/state"
  "PATH=$STUB_BIN:$PATH"
)

"${env_cmd[@]}" "$ROOT/bin/we" status --json >/dev/null
config="$TEST_HOME/.config/omarchy/wallpaper-engine/config.json"
tmp="$TEST_ROOT/config.tmp"
jq '
  .displays["DP-0"] = {wallpaper:"old-wallpaper", scaling:"fill"}
  | .displays["DP-1"] = {wallpaper:"123", scaling:"fill"}
' "$config" >"$tmp"
mv "$tmp" "$config"

# Existing installs have no last_applied object. Status/config loading migrates
# the newest confirmed framebuffer that still matches a configured wallpaper.
"${env_cmd[@]}" "$ROOT/bin/we" status --json \
  | jq -e '.lastAppliedMonitor == "DP-1" and .lastAppliedWallpaper == "123"' >/dev/null \
  || fail 'last-applied wallpaper was not inferred for an existing config'

# With no monitor argument, auto-match must use the most recently successfully
# applied wallpaper rather than the first configured or currently selected tab.
"${env_cmd[@]}" "$ROOT/bin/we" auto-theme >/dev/null
generated="$TEST_HOME/.config/omarchy/themes/wallpaper-engine-auto-match"
[[ -f $generated/colors.toml ]] || fail 'colors.toml was not generated'
[[ -f $generated/backgrounds/wallpaper.jpg ]] || fail 'theme background was not generated'
jq -e '.auto_theme.active == true and .auto_theme.previous_theme == "gruvbox"
  and .auto_theme.source_monitor == "DP-1"' "$config" >/dev/null \
  || fail 'reversible auto-theme state was not recorded'
jq -e --arg key "$current_wallpaper_key" \
  '.auto_theme.source_image | endswith("lwe-ready.DP-1." + $key + ".123.jpg")' \
  "$config" >/dev/null \
  || fail 'auto-theme reused a readiness image from a different wallpaper'
"${env_cmd[@]}" "$ROOT/bin/we" status --json \
  | jq -e '.autoThemeActive == true and .autoThemePrevious == "gruvbox"
    and .lastAppliedMonitor == "DP-1" and .lastAppliedWallpaper == "123"' >/dev/null \
  || fail 'status did not expose auto-theme and last-applied state'

# Stopping the final Wallpaper Engine process must also undo auto-match. The
# generated theme's parked background would otherwise be exposed as a blank
# desktop after the live wallpaper disappears.
"${env_cmd[@]}" "$ROOT/bin/we" stop DP-1 >/dev/null
[[ $(<"$TEST_HOME/.local/state/omarchy/current/theme.name") == gruvbox ]] \
  || fail 'stopping Wallpaper Engine did not restore the previous theme'
jq -e '.auto_theme.active == false and .auto_theme.previous_theme == null' "$config" >/dev/null \
  || fail 'stopping Wallpaper Engine did not clear auto-theme undo state'

# The explicit undo action remains available while Wallpaper Engine is live.
"${env_cmd[@]}" "$ROOT/bin/we" auto-theme DP-1 >/dev/null
"${env_cmd[@]}" "$ROOT/bin/we" undo-auto-theme >/dev/null
[[ $(<"$TEST_HOME/.local/state/omarchy/current/theme.name") == gruvbox ]] \
  || fail 'previous theme was not restored'
jq -e '.auto_theme.active == false and .auto_theme.previous_theme == null' "$config" >/dev/null \
  || fail 'auto-theme undo state was not cleared'

# A normal Omarchy theme choice is also an implicit undo, even while the
# wallpaper engine itself is stopped.
jq '.auto_theme = {active:true, previous_theme:"gruvbox", source_monitor:"DP-1"}' \
  "$config" >"$tmp"
mv "$tmp" "$config"
"${env_cmd[@]}" "$ROOT/hooks/theme-set.sh" gruvbox
jq -e '.auto_theme.active == false and .auto_theme.previous_theme == null' "$config" >/dev/null \
  || fail 'manual theme selection did not clear stale undo state'

echo 'auto-theme integration tests: PASS'
