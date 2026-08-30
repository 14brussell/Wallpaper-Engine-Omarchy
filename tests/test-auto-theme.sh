#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d)
fake_engine_pid=""
cleanup() {
  if [[ -n $fake_engine_pid ]]; then
    kill "$fake_engine_pid" 2>/dev/null || true
    wait "$fake_engine_pid" 2>/dev/null || true
  fi
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT
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
next_theme="$current/next-theme"

# Match omarchy-theme-set's observable ordering: fully stage the selected
# theme, atomically replace current/theme, publish its name and background,
# then synchronously run theme-set hooks. The Wallpaper Engine hook must see
# the restored palette/background, just as it does on a real Omarchy switch.
rm -rf "$next_theme"
mkdir -p "$next_theme"
cp -a "$user_theme"/. "$next_theme"/
rm -rf "$current/theme"
mv "$next_theme" "$current/theme"
printf '%s\n' "$slug" >"$current/theme.name"
background=$(find "$current/theme/backgrounds" -maxdepth 1 -type f | sort | head -n1)
if [[ ${OMARCHY_THEME_SKIP_BACKGROUND:-0} != 1 && -n $background ]]; then
  ln -nsf "$background" "$current/background"
  omarchy-shell background set "$background"
fi
colors_payload=""
shell_payload=""
[[ ! -f $current/theme/colors.toml ]] || colors_payload=$(base64 -w 0 "$current/theme/colors.toml")
[[ ! -f $current/theme/shell.toml ]] || shell_payload=$(base64 -w 0 "$current/theme/shell.toml")
omarchy-shell shell applyTheme "$colors_payload" "$shell_payload" >/dev/null
if [[ -n ${WE_TEST_PLUGIN_ROOT:-} ]]; then
  "$WE_TEST_PLUGIN_ROOT/hooks/theme-set.sh" "$slug"
fi
EOF
chmod +x "$STUB_BIN/omarchy"

# Never let an isolated test HOME send temporary image paths or palettes to the
# user's live Omarchy shell. Record the requested state inside TEST_HOME so the
# assertions can verify the same IPC contract without touching the desktop.
cat >"$STUB_BIN/omarchy-shell" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
current="$HOME/.local/state/omarchy/current"
printf '%s %s\n' "${1:-}" "${2:-}" >>"$current/ipc.log"
case "${1:-} ${2:-}" in
  "shell applyTheme")
    call_count=$(grep -c '^shell applyTheme$' "$current/ipc.log")
    if [[ -n ${WE_TEST_FAIL_APPLY_AT:-} && $call_count -eq $WE_TEST_FAIL_APPLY_AT ]]; then
      exit 1
    fi
    printf '%s' "${3:-}" | base64 -d >"$current/applied-colors.toml"
    printf '%s' "${4:-}" | base64 -d >"$current/applied-shell.toml"
    echo ok
    ;;
  "background set"|"background setInstant")
    [[ -f ${3:-} ]] || exit 1
    printf '%s\n' "$(realpath "$3")" >"$current/applied-background"
    ;;
  *) echo ok ;;
esac
EOF
chmod +x "$STUB_BIN/omarchy-shell"

cat >"$STUB_BIN/omarchy-theme-bg-set" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -f ${1:-} ]] || exit 1
ln -nsf "$(realpath "$1")" "$HOME/.local/state/omarchy/current/background"
omarchy-shell background set "$1"
EOF
chmod +x "$STUB_BIN/omarchy-theme-bg-set"

cat >"$STUB_BIN/omarchy-notification-send" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STUB_BIN/omarchy-notification-send"
cp "$(command -v sleep)" "$STUB_BIN/linux-wallpaperengine"

mkdir -p \
  "$TEST_HOME/.config/omarchy/themes/gruvbox/backgrounds" \
  "$TEST_HOME/.local/state/omarchy/wallpaper-engine"
original_theme="$TEST_HOME/.config/omarchy/themes/gruvbox"
original_colors="$original_theme/colors.toml"
original_shell="$original_theme/shell.toml"
original_background="$original_theme/backgrounds/wallpaper.jpg"
alternate_background="$original_theme/backgrounds/00-alternate.jpg"
cat >"$original_colors" <<'EOF'
accent = "#fe8019"
background = "#282828"
foreground = "#ebdbb2"
EOF
cat >"$original_shell" <<'EOF'
[bar]
transparent = false
EOF
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
Image.new("RGB", (16, 9), "#b16286").save(
    home / ".config/omarchy/themes/gruvbox/backgrounds/00-alternate.jpg"
)
PY
printf 'gruvbox\n' >"$TEST_HOME/.local/state/omarchy/current/theme.name"

assert_restored_theme() {
  local action=$1 current="$TEST_HOME/.local/state/omarchy/current"
  local restored_background

  [[ $(<"$current/theme.name") == gruvbox ]] \
    || fail "$action did not restore the theme name"
  cmp -s "$original_colors" "$current/theme/colors.toml" \
    || fail "$action did not restore the original colors.toml contents"
  cmp -s "$original_colors" "$current/applied-colors.toml" \
    || fail "$action did not apply the restored colors to the shell"
  cmp -s "$original_shell" "$current/theme/shell.toml" \
    || fail "$action did not restore the original shell.toml contents"
  cmp -s "$original_shell" "$current/applied-shell.toml" \
    || fail "$action did not apply the restored shell theme"
  [[ $(grep -c '^shell applyTheme$' "$current/ipc.log") -ge 3 ]] \
    || fail "$action did not explicitly confirm the restored shell palette"
  [[ ! -e $current/theme/.wallpaper-engine-omarchy-generated ]] \
    || fail "$action left the generated auto-theme staged as current"

  restored_background=$(readlink -f "$current/background" 2>/dev/null || true)
  [[ -n $restored_background && -f $restored_background ]] \
    || fail "$action did not restore a readable theme background"
  case "$restored_background" in
    "$TEST_HOME/.config/omarchy/themes/wallpaper-engine-auto-match"/*)
      fail "$action restored the generated auto-theme background"
      ;;
    */we-placeholder.png)
      fail "$action left the black Wallpaper Engine placeholder visible"
      ;;
  esac
  cmp -s "$original_background" "$restored_background" \
    || fail "$action did not restore the original theme background"
  [[ $(<"$current/applied-background") == "$restored_background" ]] \
    || fail "$action did not apply the restored background to the shell"
  python3 - "$restored_background" <<'PY' \
    || fail "$action restored a black theme background"
import sys
from PIL import Image, ImageStat

with Image.open(sys.argv[1]) as image:
    extrema = ImageStat.Stat(image.convert("RGB")).extrema
if max(high for _low, high in extrema) <= 8:
    raise SystemExit(1)
PY
}

reset_ipc_log() {
  : >"$TEST_HOME/.local/state/omarchy/current/ipc.log"
}

start_fake_engine() {
  "$STUB_BIN/linux-wallpaperengine" 30 &
  fake_engine_pid=$!
  local start
  start=$(awk '{print $22}' "/proc/$fake_engine_pid/stat")
  printf '%s %s\n' "$fake_engine_pid" "$start" \
    >"$TEST_HOME/.local/state/omarchy/wallpaper-engine/pids/DP-1.pid"
  jq '.active = true' "$config" >"$tmp"
  mv "$tmp" "$config"
}

env_cmd=(
  env
  "HOME=$TEST_HOME"
  "XDG_CONFIG_HOME=$TEST_HOME/.config"
  "XDG_STATE_HOME=$TEST_HOME/.local/state"
  "PATH=$STUB_BIN:$PATH"
  "WE_TEST_PLUGIN_ROOT=$ROOT"
)

"${env_cmd[@]}" omarchy theme set gruvbox >/dev/null
selected_background="$TEST_HOME/.local/state/omarchy/current/theme/backgrounds/wallpaper.jpg"
ln -nsf "$selected_background" "$TEST_HOME/.local/state/omarchy/current/background"
"${env_cmd[@]}" omarchy-shell background set "$selected_background"

"${env_cmd[@]}" "$ROOT/bin/we" status --json >/dev/null
config="$TEST_HOME/.config/omarchy/wallpaper-engine/config.json"
tmp="$TEST_ROOT/config.tmp"
jq --arg saved "$TEST_HOME/.config/omarchy/themes/gruvbox/backgrounds/wallpaper.jpg" '
  .displays["DP-0"] = {wallpaper:"old-wallpaper", scaling:"fill"}
  | .displays["DP-1"] = {wallpaper:"123", scaling:"fill"}
  | .active = true
  | .saved_theme_background = $saved
' "$config" >"$tmp"
mv "$tmp" "$config"

# Existing installs have no last_applied object. Status/config loading migrates
# the newest confirmed framebuffer that still matches a configured wallpaper.
"${env_cmd[@]}" "$ROOT/bin/we" status --json \
  | jq -e '.lastAppliedMonitor == "DP-1" and .lastAppliedWallpaper == "123"' >/dev/null \
  || fail 'last-applied wallpaper was not inferred for an existing config'

# With no monitor argument, auto-match must use the most recently successfully
# applied wallpaper rather than the first configured or currently selected tab.
reset_ipc_log
"${env_cmd[@]}" "$ROOT/bin/we" auto-theme >/dev/null
generated="$TEST_HOME/.config/omarchy/themes/wallpaper-engine-auto-match"
[[ -f $generated/colors.toml ]] || fail 'colors.toml was not generated'
[[ -f $generated/backgrounds/wallpaper.jpg ]] || fail 'theme background was not generated'
jq -e '.auto_theme.active == true and .auto_theme.previous_theme == "gruvbox"
  and .auto_theme.source_monitor == "DP-1"' "$config" >/dev/null \
  || fail 'reversible auto-theme state was not recorded'
jq -e --arg hash "$(sha256sum "$original_background" | cut -d' ' -f1)" \
  '.auto_theme.previous_background_sha256 == $hash' "$config" >/dev/null \
  || fail 'auto-theme did not preserve the selected prior background hash'
jq -e --arg saved "$TEST_HOME/.config/omarchy/themes/gruvbox/backgrounds/wallpaper.jpg" \
  '.saved_theme_background == $saved' "$config" >/dev/null \
  || fail 'generated auto-theme still replaced the prior revert target'
jq -e --arg key "$current_wallpaper_key" \
  '.auto_theme.source_image | endswith("lwe-ready.DP-1." + $key + ".123.jpg")' \
  "$config" >/dev/null \
  || fail 'auto-theme reused a readiness image from a different wallpaper'
"${env_cmd[@]}" "$ROOT/bin/we" status --json \
  | jq -e '.autoThemeActive == true and .autoThemePrevious == "gruvbox"
    and .lastAppliedMonitor == "DP-1" and .lastAppliedWallpaper == "123"' >/dev/null \
  || fail 'status did not expose auto-theme and last-applied state'

# A stale config can claim active=true after the owned engine has already died.
# Undo must trust PID identity, not that flag, or the theme hook parks the black
# placeholder after the prior theme has otherwise been restored.
"${env_cmd[@]}" "$ROOT/bin/we" undo-auto-theme >/dev/null
assert_restored_theme 'undo-auto-theme with stale active state'
jq -e '.active == false and .auto_theme.active == false' "$config" >/dev/null \
  || fail 'stale active state survived auto-theme undo'

# Revert is the global "return to the desktop theme" action. When auto-match
# is active it must restore the complete previous theme, not merely stop the
# engine and expose the generated theme's wallpaper as a frozen-looking still.
reset_ipc_log
"${env_cmd[@]}" "$ROOT/bin/we" auto-theme DP-1 >/dev/null
"${env_cmd[@]}" "$ROOT/bin/we" revert >/dev/null
assert_restored_theme 'revert'
jq -e '.auto_theme.active == false and .auto_theme.previous_theme == null' "$config" >/dev/null \
  || fail 'revert did not clear auto-theme undo state'

# Stopping the final Wallpaper Engine process must also undo auto-match. The
# generated theme's parked background would otherwise be exposed as a blank
# desktop after the live wallpaper disappears.
reset_ipc_log
"${env_cmd[@]}" "$ROOT/bin/we" auto-theme DP-1 >/dev/null
"${env_cmd[@]}" "$ROOT/bin/we" stop DP-1 >/dev/null
assert_restored_theme 'stopping Wallpaper Engine'
jq -e '.auto_theme.active == false and .auto_theme.previous_theme == null' "$config" >/dev/null \
  || fail 'stopping Wallpaper Engine did not clear auto-theme undo state'

# The explicit undo action remains available while auto-match is active.
reset_ipc_log
"${env_cmd[@]}" "$ROOT/bin/we" auto-theme DP-1 >/dev/null
"${env_cmd[@]}" "$ROOT/bin/we" undo-auto-theme >/dev/null
assert_restored_theme 'undo-auto-theme'
jq -e '.auto_theme.active == false and .auto_theme.previous_theme == null' "$config" >/dev/null \
  || fail 'auto-theme undo state was not cleared'

# A palette IPC failure must not strand a black/generated background. Keep the
# undo metadata visible for retry, but repair the stopped desktop background
# before returning the failure.
reset_ipc_log
"${env_cmd[@]}" "$ROOT/bin/we" auto-theme DP-1 >/dev/null
if "${env_cmd[@]}" "WE_TEST_FAIL_APPLY_AT=3" \
    "$ROOT/bin/we" undo-auto-theme >/dev/null 2>&1; then
  fail 'undo-auto-theme ignored a failed shell palette confirmation'
fi
assert_restored_theme 'failed palette confirmation cleanup'
jq -e '.auto_theme.active == true and .auto_theme.previous_theme == "gruvbox"' \
  "$config" >/dev/null \
  || fail 'failed theme restore discarded retry metadata'
"${env_cmd[@]}" "$ROOT/bin/we" status --json \
  | jq -e '.autoThemeActive == true and .autoThemePrevious == "gruvbox"' >/dev/null \
  || fail 'failed theme restore is not exposed as retryable'
"${env_cmd[@]}" "$ROOT/bin/we" undo-auto-theme >/dev/null
assert_restored_theme 'palette confirmation retry'

# With a real owned PID identity, undo restores the palette but deliberately
# keeps the placeholder under the live renderer. It must save the exact prior
# background so the subsequent global Revert exposes the right image.
reset_ipc_log
start_fake_engine
"${env_cmd[@]}" "$ROOT/bin/we" auto-theme DP-1 >/dev/null
"${env_cmd[@]}" "$ROOT/bin/we" undo-auto-theme >/dev/null
[[ $(readlink -f "$TEST_HOME/.local/state/omarchy/current/background") == "$ROOT/assets/we-placeholder.png" ]] \
  || fail 'live-engine undo did not keep the placeholder under the renderer'
jq -e '.active == true and .auto_theme.active == false
   and (.saved_theme_background | strings | length > 0)' "$config" >/dev/null \
  || fail 'live-engine undo did not preserve its background revert target'
[[ $(sha256sum "$(jq -r '.saved_theme_background' "$config")" | cut -d' ' -f1) \
    == "$(sha256sum "$original_background" | cut -d' ' -f1)" ]] \
  || fail 'live-engine undo saved the wrong background target'
"${env_cmd[@]}" "$ROOT/bin/we" revert >/dev/null
wait "$fake_engine_pid" 2>/dev/null || true
fake_engine_pid=""
assert_restored_theme 'revert after live-engine undo'
jq -e '.active == false and .auto_theme.active == false
  and .saved_theme_background == null' "$config" >/dev/null \
  || fail 'revert after live-engine undo left stale state'

# Auto-match generation and revert must be a single-flight transaction. A
# revert started while generation is blocked must run second and leave the
# prior theme restored, never let the late auto-match commit after revert.
generator_started="$TEST_ROOT/generator-started"
generator_release="$TEST_ROOT/generator-release"
generator="$TEST_ROOT/blocking-generator"
cat >"$generator" <<'EOF'
#!/usr/bin/env python3
import os
import pathlib
import sys
import time

pathlib.Path(os.environ["WE_TEST_GENERATOR_STARTED"]).touch()
release = pathlib.Path(os.environ["WE_TEST_GENERATOR_RELEASE"])
for _ in range(200):
    if release.exists():
        break
    time.sleep(0.01)
else:
    raise SystemExit(124)
os.execv(sys.executable, [sys.executable, os.environ["WE_TEST_REAL_GENERATOR"], *sys.argv[1:]])
EOF
chmod +x "$generator"
jq '.active = true' "$config" >"$tmp"
mv "$tmp" "$config"
reset_ipc_log
"${env_cmd[@]}" \
  "WE_THEME_GENERATOR=$generator" \
  "WE_TEST_GENERATOR_STARTED=$generator_started" \
  "WE_TEST_GENERATOR_RELEASE=$generator_release" \
  "WE_TEST_REAL_GENERATOR=$ROOT/lib/generate_theme.py" \
  "$ROOT/bin/we" auto-theme DP-1 >/dev/null &
auto_pid=$!
for _ in $(seq 1 200); do
  [[ -e $generator_started ]] && break
  sleep 0.01
done
[[ -e $generator_started ]] || fail 'blocking auto-theme generator did not start'
"${env_cmd[@]}" "$ROOT/bin/we" revert >/dev/null &
revert_pid=$!
sleep 0.1
kill -0 "$revert_pid" 2>/dev/null \
  || fail 'revert bypassed an in-flight auto-theme transaction'
: >"$generator_release"
wait "$auto_pid" || fail 'blocked auto-theme transaction failed'
wait "$revert_pid" || fail 'queued revert transaction failed'
assert_restored_theme 'queued revert after auto-match race'
jq -e '.active == false and .auto_theme.active == false
  and .auto_theme.previous_theme == null and .saved_theme_background == null' \
  "$config" >/dev/null \
  || fail 'auto-theme/revert race left stale lifecycle state'

# A normal Omarchy theme choice is also an implicit undo, even while the
# wallpaper engine itself is stopped.
jq '.auto_theme = {active:true, previous_theme:"gruvbox", source_monitor:"DP-1"}' \
  "$config" >"$tmp"
mv "$tmp" "$config"
"${env_cmd[@]}" "$ROOT/hooks/theme-set.sh" gruvbox
jq -e '.auto_theme.active == false and .auto_theme.previous_theme == null' "$config" >/dev/null \
  || fail 'manual theme selection did not clear stale undo state'

echo 'auto-theme integration tests: PASS'
