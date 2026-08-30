#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_ROOT=$(mktemp -d)
cleanup() {
  pkill -KILL -f "$TEST_ROOT/.*/linux-wallpaperengine" 2>/dev/null || true
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

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

# systemd-run stub records argv and starts the payload, like --user without --wait.
test_post_boot_systemd_run_uses_killmode_process() {
  local home="$TEST_ROOT/post-boot-systemd-home"
  local stub_bin="$TEST_ROOT/post-boot-systemd-bin"
  local apply_stub="$TEST_ROOT/post-boot-systemd-apply"
  local marker="$TEST_ROOT/post-boot-systemd-complete"
  local argv_file="$TEST_ROOT/post-boot-systemd-argv"
  local config="$home/.config/omarchy/wallpaper-engine/config.json"
  local start elapsed
  mkdir -p "$home" "$stub_bin"
  run_we "$home" status --json >/dev/null
  jq '.active = true' "$config" >"$config.next"
  mv "$config.next" "$config"

  cat >"$stub_bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$WE_TEST_SYSTEMD_RUN_ARGV"
cmd=()
stdout_append=""
stderr_append=""
while (( $# )); do
  case "$1" in
    --user|--collect|--quiet|--wait|--no-block|--pty|--pipe|--scope)
      shift
      ;;
    --unit|--description|--uid|--gid|--working-directory|--service-type|--setenv)
      shift 2 || exit 1
      ;;
    --property)
      prop=${2:-}
      shift 2 || exit 1
      case "$prop" in
        StandardOutput=append:*) stdout_append=${prop#StandardOutput=append:} ;;
        StandardError=append:*) stderr_append=${prop#StandardError=append:} ;;
      esac
      ;;
    --property=*)
      prop=${1#--property=}
      case "$prop" in
        StandardOutput=append:*) stdout_append=${prop#StandardOutput=append:} ;;
        StandardError=append:*) stderr_append=${prop#StandardError=append:} ;;
      esac
      shift
      ;;
    --unit=*|--description=*|--uid=*|--gid=*|--working-directory=*|--service-type=*|--setenv=*)
      shift
      ;;
    --*)
      shift
      ;;
    *)
      cmd=("$@")
      break
      ;;
  esac
done
((${#cmd[@]})) || exit 1
if [[ -n $stdout_append ]]; then
  "${cmd[@]}" </dev/null >>"$stdout_append" 2>>"${stderr_append:-$stdout_append}" &
else
  "${cmd[@]}" </dev/null &
fi
exit 0
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
printf '%s\n' 'systemd restore complete'
EOF
  chmod +x "$stub_bin/systemd-run" "$stub_bin/hyprctl" "$apply_stub"

  start=$(date +%s%N)
  env HOME="$home" PATH="$stub_bin:$PATH" \
    WE_POST_BOOT_APPLY_BIN="$apply_stub" \
    WE_TEST_POST_BOOT_MARKER="$marker" \
    WE_TEST_SYSTEMD_RUN_ARGV="$argv_file" \
    "$ROOT/hooks/post-boot.sh"
  elapsed=$(( ($(date +%s%N) - start) / 1000000 ))
  (( elapsed < 750 )) || fail "systemd-run post-boot hook blocked for ${elapsed}ms"

  [[ -f $argv_file ]] || fail 'post-boot did not invoke systemd-run'
  grep -qx -- '--user' "$argv_file" || fail 'systemd-run was not invoked with --user'
  grep -qx -- '--collect' "$argv_file" || fail 'systemd-run was not invoked with --collect'
  grep -q 'KillMode=process' "$argv_file" \
    || fail 'systemd-run was not invoked with KillMode=process'
  if grep -q 'KillMode=control-group' "$argv_file"; then
    fail 'systemd-run still used KillMode=control-group'
  fi
  if grep -qx -- '--wait' "$argv_file"; then
    fail 'systemd-run --wait would keep the hook blocked on apply'
  fi

  for _ in $(seq 1 80); do
    [[ -f $marker ]] && break
    sleep 0.05
  done
  [[ -f $marker ]] || fail 'systemd-run post-boot restore did not complete'
  grep -q 'systemd restore complete' \
    "$home/.local/state/omarchy/wallpaper-engine/post-boot.log" \
    || fail 'systemd-run post-boot restore output was not logged'
}

build_engine_stub() {
  local dest=$1
  local src="$TEST_ROOT/engine-stub.c"
  cat >"$src" <<'EOF'
#include <unistd.h>
int main(void) {
  for (;;)
    pause();
  return 0;
}
EOF
  if command -v cc >/dev/null 2>&1; then
    cc -O0 -o "$dest" "$src"
  elif command -v gcc >/dev/null 2>&1; then
    gcc -O0 -o "$dest" "$src"
  elif command -v clang >/dev/null 2>&1; then
    clang -O0 -o "$dest" "$src"
  else
    fail 'C compiler required to build linux-wallpaperengine test stub'
  fi
}

setup_apply_harness() {
  local home=$1 stub_bin=$2
  local workshop="$home/.steam/steam/steamapps/workshop/content/431960/999001"
  local config="$home/.config/omarchy/wallpaper-engine/config.json"
  mkdir -p "$home" "$stub_bin" "$workshop"
  printf '%s\n' '{"title":"Fixture","type":"scene"}' >"$workshop/project.json"
  run_we "$home" status --json >/dev/null
  jq '.displays["DP-1"] = {"wallpaper":"999001"}' "$config" >"$config.next"
  mv "$config.next" "$config"
  build_engine_stub "$stub_bin/linux-wallpaperengine"
  cat >"$stub_bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "monitors -j")
    printf '%s\n' '[{"name":"DP-1","width":1920,"height":1080,"x":0,"y":0,"scale":1}]'
    ;;
  *)
    printf '%s\n' '[]'
    ;;
esac
EOF
  cat >"$stub_bin/omarchy-plugin-list" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat >"$stub_bin/omarchy-theme-bg-set" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat >"$stub_bin/omarchy-notification-send" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$stub_bin/hyprctl" "$stub_bin/omarchy-plugin-list" \
    "$stub_bin/omarchy-theme-bg-set" "$stub_bin/omarchy-notification-send"
}

wait_for_starting_pid() {
  local file=$1
  local i
  for i in $(seq 1 100); do
    if [[ -f $file ]]; then
      read -r pid start <"$file" || true
      if [[ $pid =~ ^[1-9][0-9]*$ ]] && kill -0 -- "$pid" 2>/dev/null; then
        printf '%s %s\n' "$pid" "$start"
        return 0
      fi
    fi
    sleep 0.05
  done
  return 1
}

run_we_apply_bg() {
  local home=$1
  shift
  env HOME="$home" \
    XDG_CONFIG_HOME="$home/xdg-config-should-not-be-used" \
    XDG_STATE_HOME="$home/xdg-state-should-not-be-used" \
    PATH="$1:$PATH" \
    WE_LWE_READY_MS="${WE_LWE_READY_MS:-8000}" \
    "$ROOT/bin/we" apply DP-1
}

test_capture_engine_starttime_retries_empty() {
  local home="$TEST_ROOT/starttime-home"
  local stub_bin="$TEST_ROOT/starttime-bin"
  mkdir -p "$home" "$stub_bin"
  build_engine_stub "$stub_bin/linux-wallpaperengine"
  HOME="$home" ROOT="$ROOT" STUB="$stub_bin/linux-wallpaperengine" \
    COUNTER="$stub_bin/starttime-calls" bash <<'EOS' \
    || fail 'starttime capture did not retry an empty first sample'
set -euo pipefail
source "$ROOT/lib/common.sh"
WE_ENGINE_BIN=$STUB
printf '0\n' >"$COUNTER"
"$WE_ENGINE_BIN" &
pid=$!
we_proc_starttime() {
  local n
  n=$(cat "$COUNTER")
  n=$((n + 1))
  printf '%s\n' "$n" >"$COUNTER"
  if (( n == 1 )); then
    return 1
  fi
  awk '{print $22}' "/proc/${1:-}/stat" 2>/dev/null
}
start=$(we_capture_engine_starttime "$pid")
[[ -n $start ]]
(( $(cat "$COUNTER") >= 2 ))
kill -KILL -- "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
EOS
}

test_apply_term_during_first_paint_reaps_engine() {
  local home="$TEST_ROOT/term-apply-home"
  local stub_bin="$TEST_ROOT/term-apply-bin"
  local starting pid_dir identity engine_pid apply_pid
  setup_apply_harness "$home" "$stub_bin"
  pid_dir="$home/.local/state/omarchy/wallpaper-engine/pids"
  starting="$pid_dir/DP-1.starting.pid"

  run_we_apply_bg "$home" "$stub_bin" >"$home/apply.out" 2>"$home/apply.err" &
  apply_pid=$!
  identity=$(wait_for_starting_pid "$starting") || {
    cat "$home/apply.err" >&2 || true
    fail 'apply did not record an in-flight engine pid before first paint'
  }
  engine_pid=${identity%% *}
  kill -TERM -- "$apply_pid" 2>/dev/null || true
  wait "$apply_pid" 2>/dev/null || true
  sleep 0.2
  if kill -0 -- "$engine_pid" 2>/dev/null; then
    fail 'SIGTERM of we apply left a leftover engine process'
  fi
}

test_stop_reaps_leftover_pid_after_killed_apply() {
  local home="$TEST_ROOT/kill-apply-home"
  local stub_bin="$TEST_ROOT/kill-apply-bin"
  local starting pid_dir identity engine_pid apply_pid
  setup_apply_harness "$home" "$stub_bin"
  pid_dir="$home/.local/state/omarchy/wallpaper-engine/pids"
  starting="$pid_dir/DP-1.starting.pid"

  run_we_apply_bg "$home" "$stub_bin" >"$home/apply.out" 2>"$home/apply.err" &
  apply_pid=$!
  identity=$(wait_for_starting_pid "$starting") || {
    cat "$home/apply.err" >&2 || true
    fail 'killed-apply test did not observe an in-flight engine pid'
  }
  engine_pid=${identity%% *}
  kill -KILL -- "$apply_pid" 2>/dev/null || true
  wait "$apply_pid" 2>/dev/null || true
  kill -0 -- "$engine_pid" 2>/dev/null \
    || fail 'SIGKILL of we apply did not leave the engine for stop to reap'
  [[ -f $starting ]] || fail 'SIGKILL of we apply dropped the leftover starting pid file'
  env HOME="$home" \
    XDG_CONFIG_HOME="$home/xdg-config-should-not-be-used" \
    XDG_STATE_HOME="$home/xdg-state-should-not-be-used" \
    PATH="$stub_bin:$PATH" \
    "$ROOT/bin/we" stop
  sleep 0.2
  if kill -0 -- "$engine_pid" 2>/dev/null; then
    fail 'we stop could not reap leftover engine after killed apply'
  fi
}

test_canonical_paths
test_config_normalization_and_invalid_surface
test_set_defaults_rejects_wallpaper
test_post_boot_is_detached_and_logged
test_post_boot_systemd_run_uses_killmode_process
test_capture_engine_starttime_retries_empty
test_apply_term_during_first_paint_reaps_engine
test_stop_reaps_leftover_pid_after_killed_apply

echo 'backend regression tests: PASS'
