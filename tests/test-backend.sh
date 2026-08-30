#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

run_we() {
  local home=$1
  shift
  env HOME="$home" \
    XDG_CONFIG_HOME="$home/xdg-config-should-not-be-used" \
    XDG_STATE_HOME="$home/xdg-state-should-not-be-used" \
    "$ROOT/bin/we" "$@"
}

test_canonical_paths() {
  local home="$TEST_ROOT/canonical-home"
  mkdir -p "$home"
  run_we "$home" status --json >/dev/null

  [[ -f $home/.config/omarchy/wallpaper-engine/config.json ]] \
    || fail 'backend config was not created at the canonical Omarchy HOME path'
  [[ -d $home/.local/state/omarchy/wallpaper-engine ]] \
    || fail 'backend state was not created at the canonical Omarchy HOME path'
  [[ ! -e $home/xdg-config-should-not-be-used ]] \
    || fail 'backend split config ownership into XDG_CONFIG_HOME'
  [[ ! -e $home/xdg-state-should-not-be-used ]] \
    || fail 'backend split runtime ownership into XDG_STATE_HOME'

  local paths
  paths=$(env HOME="$home" \
    XDG_CONFIG_HOME="$home/rogue-config" \
    XDG_STATE_HOME="$home/rogue-state" \
    bash -c 'source "$1/lib/common.sh"; printf "%s\n%s\n%s\n" "$WE_CONFIG_DIR" "$WE_STATE_DIR" "$WE_USER_THEMES_DIR"' \
    bash "$ROOT")
  [[ $paths == "$home/.config/omarchy/wallpaper-engine"$'\n'\
"$home/.local/state/omarchy/wallpaper-engine"$'\n'\
"$home/.config/omarchy/themes" ]] \
    || fail 'backend path constants did not ignore conflicting XDG overrides'
}

test_config_normalization_and_invalid_surface() {
  local home="$TEST_ROOT/config-home"
  local dir="$home/.config/omarchy/wallpaper-engine"
  local config="$dir/config.json"
  mkdir -p "$dir"

  printf '%s\n' '{"displays":{}}' >"$config"
  run_we "$home" status --json >/dev/null
  jq -e '
    .version == 1
    and .defaults.fps == 30
    and .defaults.layer == "bottom"
    and .last_applied.monitor == null
    and .auto_theme.active == false
  ' "$config" >/dev/null || fail 'valid older config was not normalized to the full schema'

  jq '.defaults.fps = "fast"' "$config" >"$config.bad"
  mv "$config.bad" "$config"
  if run_we "$home" status --json >"$home/invalid.out" 2>"$home/invalid.err"; then
    fail 'status returned labels-only success for an invalid config'
  fi
  grep -q 'config was invalid' "$home/invalid.err" \
    || fail 'invalid config failure was not surfaced to the caller'
  compgen -G "$config.invalid.*" >/dev/null \
    || fail 'invalid typed config was not backed up'
  jq -e '.defaults.fps == 30 and .displays == {}' "$config" >/dev/null \
    || fail 'invalid config was not replaced with safe normalized defaults'
  run_we "$home" status --json | jq -e '.defaults.fps == 30' >/dev/null \
    || fail 'repaired config was not usable on the next command'
}

test_set_defaults_rejects_wallpaper() {
  local home="$TEST_ROOT/defaults-home"
  mkdir -p "$home"
  run_we "$home" status --json >/dev/null
  if run_we "$home" set-defaults --wallpaper 123 \
      >"$home/defaults.out" 2>"$home/defaults.err"; then
    fail 'set-defaults still accepted the unsupported wallpaper option'
  fi
  grep -q 'Unknown option: --wallpaper' "$home/defaults.err" \
    || fail 'set-defaults wallpaper rejection was not actionable'
  jq -e '.defaults | has("wallpaper") | not' \
    "$home/.config/omarchy/wallpaper-engine/config.json" >/dev/null \
    || fail 'rejected default wallpaper mutated config'
}

test_post_boot_is_detached_and_logged() {
  local home="$TEST_ROOT/post-boot-home"
  local stub_bin="$TEST_ROOT/post-boot-bin"
  local apply_stub="$TEST_ROOT/post-boot-apply"
  local marker="$TEST_ROOT/post-boot-complete"
  local config="$home/.config/omarchy/wallpaper-engine/config.json"
  local start elapsed
  mkdir -p "$home" "$stub_bin"
  run_we "$home" status --json >/dev/null
  jq '.active = true' "$config" >"$config.next"
  mv "$config.next" "$config"

  cat >"$stub_bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat >"$stub_bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == monitors && ${2:-} == -j ]] || exit 2
printf '%s\n' '[{"name":"DP-1","width":1920,"height":1080,"x":0,"y":0,"scale":1}]'
EOF
  cat >"$apply_stub" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == apply ]] || exit 2
sleep 1
printf '%s\n' complete >"$WE_TEST_POST_BOOT_MARKER"
printf '%s\n' 'detached restore complete'
EOF
  chmod +x "$stub_bin/systemd-run" "$stub_bin/hyprctl" "$apply_stub"

  start=$(date +%s%N)
  env HOME="$home" PATH="$stub_bin:$PATH" \
    HYPRLAND_INSTANCE_SIGNATURE= \
    WE_POST_BOOT_APPLY_BIN="$apply_stub" \
    WE_TEST_POST_BOOT_MARKER="$marker" \
    "$ROOT/hooks/post-boot.sh"
  elapsed=$(( ($(date +%s%N) - start) / 1000000 ))
  (( elapsed < 750 )) || fail "post-boot hook blocked for ${elapsed}ms"

  for _ in $(seq 1 80); do
    [[ -f $marker ]] && break
    sleep 0.05
  done
  [[ -f $marker ]] || fail 'detached post-boot restore did not complete'
  grep -q 'detached restore complete' \
    "$home/.local/state/omarchy/wallpaper-engine/post-boot.log" \
    || fail 'detached post-boot restore output was not logged'
}

test_canonical_paths
test_config_normalization_and_invalid_surface
test_set_defaults_rejects_wallpaper
test_post_boot_is_detached_and_logged

echo 'backend regression tests: PASS'
