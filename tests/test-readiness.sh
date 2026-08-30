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
mkdir -p "$HOME"

# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"

test_complete_clear_screenshot_fails_fast() {
  local screenshot="$TEST_ROOT/clear.png"
  local started elapsed timeout_ms=1000

  python3 - "$screenshot" <<'PY'
import sys
from PIL import Image

Image.new("RGB", (32, 32), "black").save(sys.argv[1])
PY

  we_file_is_image "$screenshot" \
    || fail 'clear screenshot fixture was not recognized as a complete image'
  if we_lwe_fbo_painted "$screenshot"; then
    fail 'uniform-black screenshot fixture was incorrectly considered painted'
  fi

  WE_LWE_SCREENSHOT="$screenshot"
  started=$(we_now_ms)
  if we_wait_engine_first_paint "$timeout_ms" >/dev/null 2>&1; then
    fail 'uniform-black one-shot screenshot was incorrectly considered ready'
  fi
  elapsed=$(( $(we_now_ms) - started ))

  # --screenshot is a one-shot FBO dump: after a complete image is present,
  # polling the same clear pixels cannot produce a later painted frame.
  (( elapsed < timeout_ms / 2 )) \
    || fail "complete clear screenshot consumed ${elapsed}ms of a ${timeout_ms}ms timeout"
}

test_incremental_screenshot_is_rechecked_after_stabilizing() (
  local screenshot="$TEST_ROOT/incremental.bmp"
  local complete="$TEST_ROOT/incremental-complete.bmp"
  local publish="$TEST_ROOT/publish-incremental"
  local writer_pid first_probe=1

  python3 - "$complete" <<'PY'
import sys
from PIL import Image

image = Image.new("RGB", (32, 32), "black")
image.putpixel((15, 15), (255, 0, 0))
image.save(sys.argv[1])
PY
  head -c 64 "$complete" >"$screenshot"

  we_file_is_image "$screenshot" \
    || fail 'incremental fixture header was not recognized as an image'
  if we_lwe_fbo_painted "$screenshot"; then
    fail 'incomplete screenshot fixture was incorrectly considered painted'
  fi

  # Publish the remaining pixels immediately after the first paint probe. This
  # deterministically recreates LWE extending a screenshot between the failed
  # paint decode and the following valid-image check.
  (
    while [[ ! -e $publish ]]; do
      sleep 0.005
    done
    dd if="$complete" of="$screenshot" bs=1 skip=64 seek=64 \
      conv=notrunc status=none
  ) &
  writer_pid=$!

  we_lwe_fbo_painted() {
    local path=${1:-$WE_LWE_SCREENSHOT}
    local eps=${2:-$WE_LWE_PAINT_EPS}
    local rc=0
    [[ -n $path && -f $path ]] || return 1
    we_file_is_image "$path" || return 1
    we_compose_py painted "$path" --epsilon "$eps" >/dev/null 2>&1 || rc=$?
    if (( first_probe == 1 )); then
      first_probe=0
      : >"$publish"
      wait "$writer_pid"
    fi
    return "$rc"
  }

  WE_LWE_SCREENSHOT="$screenshot"
  if ! we_wait_engine_first_paint 1000 >/dev/null 2>&1; then
    fail 'painted screenshot published during the readiness probe was rejected'
  fi
)

test_readback_fallback_requires_replacement_layer() {
  local screenshot="$TEST_ROOT/readback-clear.png"
  local log_file="$TEST_ROOT/engine.DP-2.log"
  local stub_bin="$TEST_ROOT/bin"
  local engine_pid engine_start

  python3 - "$screenshot" <<'PY'
import sys
from PIL import Image

Image.new("RGB", (32, 32), "black").save(sys.argv[1])
PY
  printf '%s\n' \
    'Cannot obtain pixel data for screen DP-2. OpenGL error: 1282' \
    >"$log_file"

  mkdir -p "$stub_bin"
  cat >"$stub_bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1:-} == layers && ${2:-} == -j ]] || exit 2
jq -n --argjson pid "${TEST_ENGINE_PID:?}" '{
  "DP-2": {
    levels: {
      "0": [{
        namespace: "linux-wallpaperengine",
        alpha: 1,
        pid: $pid
      }]
    }
  }
}'
EOF
  chmod +x "$stub_bin/hyprctl"

  sleep 10 &
  engine_pid=$!
  engine_start=$(we_proc_starttime "$engine_pid")
  export TEST_ENGINE_PID=$engine_pid

  WE_ENGINE_BIN=sleep
  WE_LWE_SCREENSHOT="$screenshot"
  WE_LWE_READBACK_GRACE_MS=100
  PATH="$stub_bin:$PATH"

  if ! we_wait_engine_first_paint \
      1000 "$engine_pid" "$engine_start" DP-2 "$log_file" >/dev/null 2>&1; then
    kill "$engine_pid" 2>/dev/null || true
    wait "$engine_pid" 2>/dev/null || true
    fail 'exact readback error with the replacement layer was rejected'
  fi

  printf '%s\n' \
    'Cannot obtain pixel data for screen DP-3. OpenGL error: 1282' \
    >"$log_file"
  if we_wait_engine_first_paint \
      1000 "$engine_pid" "$engine_start" DP-3 "$log_file" >/dev/null 2>&1; then
    kill "$engine_pid" 2>/dev/null || true
    wait "$engine_pid" 2>/dev/null || true
    fail 'readback fallback accepted a layer on the wrong monitor'
  fi

  kill "$engine_pid" 2>/dev/null || true
  wait "$engine_pid" 2>/dev/null || true
}

test_last_applied_tracking() {
  local first="$TEST_ROOT/last-applied-first.jpg"
  local second="$TEST_ROOT/last-applied-second.jpg"
  : >"$first"
  : >"$second"
  we_load_config

  we_record_last_applied DP-1 wallpaper-a "$first"
  jq -e --arg source "$(realpath "$first")" '
    .last_applied.monitor == "DP-1"
    and .last_applied.wallpaper == "wallpaper-a"
    and .last_applied.source_image == $source
  ' "$WE_CONFIG_FILE" >/dev/null \
    || fail 'successful apply metadata was not recorded'

  WE_PRESERVE_LAST_APPLIED=1 we_record_last_applied DP-2 wallpaper-b "$second"
  jq -e '
    .last_applied.monitor == "DP-1"
    and .last_applied.wallpaper == "wallpaper-a"
  ' "$WE_CONFIG_FILE" >/dev/null \
    || fail 'boot-style apply replaced the interactive last-applied source'
}

test_complete_clear_screenshot_fails_fast
test_incremental_screenshot_is_rechecked_after_stabilizing
test_readback_fallback_requires_replacement_layer
test_last_applied_tracking

echo 'readiness regression tests: PASS'
