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
  run_uninstall "$home" --purge
  assert_absent "$home/.config/omarchy/wallpaper-engine"
  assert_absent "$home/.local/state/omarchy/wallpaper-engine"
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
test_legacy_preflight
test_uninstall_preserves_data
test_uninstall_purges_data
test_uninstall_refuses_unsafe_purge_path
test_uninstall_validates_all_paths_before_purge

echo 'install lifecycle tests: PASS'
