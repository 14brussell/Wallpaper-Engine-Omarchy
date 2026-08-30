#!/usr/bin/env bash
# Omarchy theme-set hook (installed as ~/.config/omarchy/hooks/theme-set.d/50-wallpaper-engine).
#
# omarchy-theme-set writes a real theme background, then runs this. While
# Wallpaper Engine is active:
#   1. Save that real theme file for revert (never we-placeholder.png).
#   2. Instantly re-park the placeholder under LWE (--layer bottom).
# Do not use the animated omarchy-theme-bg-set path here — that would make the
# placeholder look like the chosen theme.

set -euo pipefail

THEME_SLUG=${1:-}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/lib/common.sh"

we_hook_is_real_theme_bg() {
  local path=${1:-}
  [[ -n $path && -f $path ]] || return 1
  if we_is_placeholder "$path"; then
    return 1
  fi
  case "$path" in
    */wallpaper-engine/transitions/*) return 1 ;;
    */.cache/omarchy/background-transitions/*) return 1 ;;
  esac
  return 0
}

we_hook_first_theme_bg() {
  local slug=${1:-}
  local candidate=""
  if [[ -n $slug ]]; then
    candidate=$(
      find -L \
        "$HOME/.config/omarchy/backgrounds/$slug" \
        "$HOME/.local/state/omarchy/current/theme/backgrounds" \
        -maxdepth 1 -type f \
        \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' -o -iname '*.gif' -o -iname '*.bmp' \) \
        ! -name 'we-placeholder.png' \
        2>/dev/null | sort | head -n1
    )
    if we_hook_is_real_theme_bg "$candidate"; then
      printf '%s\n' "$(realpath "$candidate")"
      return 0
    fi
  fi
  candidate=$(we_first_theme_background 2>/dev/null || true)
  if we_hook_is_real_theme_bg "$candidate"; then
    printf '%s\n' "$(realpath "$candidate")"
    return 0
  fi
  return 1
}

# Auto-match and undo invoke `omarchy theme set` synchronously while already
# holding the transition lock. Their child hook is inside the same transaction;
# every external/manual theme change still acquires the lock normally.
if [[ ${WE_THEME_HOOK_UNDER_BG_QUEUE:-0} != 1 ]]; then
  we_bg_queue_enter
fi
we_load_config

# A theme selected outside the auto-match action is itself a valid undo. Clear
# the toggle state so the panel never offers to restore a stale prior theme.
auto_active=$(we_jq -r '.auto_theme.active // false')
if [[ $auto_active == true && $THEME_SLUG != "$WE_AUTO_THEME_SLUG" \
  && ${WE_AUTO_THEME_INTERNAL_RESTORE:-0} != 1 ]]; then
  we_jq_write '.auto_theme = {active:false, previous_theme:null, source_monitor:null}' || true
fi

active=$(we_jq -r '.active // false')
if we_install_lock_held; then
  # install.sh still swapping/hooking. Do not treat Omarchy's theme refresh as
  # a session stop (that restored the theme ~45s after a successful apply).
  if [[ $active == true ]] || we_engine_running; then
    we_apply_placeholder || true
  fi
  exit 0
fi
if ! we_engine_running; then
  # A Hyprland reload can hide engines for a moment. Clearing .active here
  # permanently restored the Omarchy theme after apply. Leave stop/revert
  # to own that write. Re-park the placeholder if this session is still live.
  if [[ $active == true ]]; then
    we_apply_placeholder || true
  fi
  exit 0
fi
if [[ $active != true ]]; then
  we_jq_write '.active = true' || true
  we_set_active_flag true || true
fi

# Prefer the file omarchy-theme-set just linked; fall back to this theme's pool.
real_bg=""
current=$(we_current_theme_background)
if we_hook_is_real_theme_bg "$current"; then
  real_bg=$(realpath "$current")
else
  real_bg=$(we_hook_first_theme_bg "$THEME_SLUG" || true)
fi

# The generated theme background resembles the live wallpaper by design; it is
# never a valid revert target. Preserve the real pre-auto-match background.
if [[ $THEME_SLUG != "$WE_AUTO_THEME_SLUG" ]]; then
  existing=$(we_jq -r '.saved_theme_background // empty')
  if [[ -n $real_bg ]]; then
    we_jq_write --arg p "$real_bg" '.saved_theme_background = $p' || true
  elif we_is_placeholder "${existing:-}" 2>/dev/null || [[ $(basename "${existing:-}") == we-placeholder.png ]]; then
    # Drop a stale placeholder path so revert cannot restore it as the theme.
    we_jq_write '.saved_theme_background = null' || true
  fi
fi

# Re-cover the static Omarchy layer. Instant — LWE hides it. Never animated set.
if declare -F we_apply_placeholder >/dev/null 2>&1; then
  we_apply_placeholder || true
elif [[ -n ${WE_PLACEHOLDER:-} && -f $WE_PLACEHOLDER ]]; then
  ln -nsf "$WE_PLACEHOLDER" "${WE_CURRENT_BACKGROUND_LINK:-$HOME/.local/state/omarchy/current/background}" || true
  if command -v omarchy-shell >/dev/null 2>&1; then
    timeout -k 1 3 omarchy-shell background setInstant "$WE_PLACEHOLDER" >/dev/null 2>&1 || true
  fi
fi
