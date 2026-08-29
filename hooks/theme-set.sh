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

we_bg_queue_enter
we_load_config

active=$(we_jq -r '.active // false')
if [[ $active != true ]]; then
  exit 0
fi

# Prefer the file omarchy-theme-set just linked; fall back to this theme's pool.
real_bg=""
current=$(we_current_theme_background)
if we_hook_is_real_theme_bg "$current"; then
  real_bg=$(realpath "$current")
else
  real_bg=$(we_hook_first_theme_bg "$THEME_SLUG" || true)
fi

existing=$(we_jq -r '.saved_theme_background // empty')
if [[ -n $real_bg ]]; then
  we_jq_write --arg p "$real_bg" '.saved_theme_background = $p' || true
elif we_is_placeholder "${existing:-}" 2>/dev/null || [[ $(basename "${existing:-}") == we-placeholder.png ]]; then
  # Drop a stale placeholder path so revert cannot restore it as the theme.
  we_jq_write '.saved_theme_background = null' || true
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
