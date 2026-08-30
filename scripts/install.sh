#!/usr/bin/env bash
# One-shot setup after `omarchy plugin add` / local copy install.
# Omarchy never runs plugin post-install hooks — call this explicitly.
#
# Qt QML compares the plugin URL to the real filesystem path. A symlink from
# ~/.config/omarchy/plugins/io.github.14brussell.wallpaper-engine → a mixed-case repo
# (e.g. .../Wallpaper-Engine-Omarchy) fails with "File name case mismatch"
# and Service.qml never loads. Always install as a real directory
# whose name matches the lowercase plugin id.

set -euo pipefail

SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PLUGIN_ID="io.github.14brussell.wallpaper-engine"
if [[ -f $SOURCE/manifest.json ]]; then
  _id=$(sed -n 's/^[[:space:]]*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SOURCE/manifest.json" | head -n1)
  [[ -n ${_id:-} ]] && PLUGIN_ID=$_id
fi
DEST="$HOME/.config/omarchy/plugins/${PLUGIN_ID}"
LEGACY_PLUGIN_ID="wallpaper-engine-omarchy"
LEGACY_DEST="$HOME/.config/omarchy/plugins/${LEGACY_PLUGIN_ID}"

refuse_legacy_install() {
  [[ $PLUGIN_ID != "$LEGACY_PLUGIN_ID" ]] || return 0
  [[ -e $LEGACY_DEST || -L $LEGACY_DEST ]] || return 0

  cat >&2 <<EOF
Legacy Wallpaper Engine plugin detected:
  $LEGACY_DEST

Remove the legacy integration before installing $PLUGIN_ID:
  $LEGACY_DEST/bin/we revert
  $LEGACY_DEST/scripts/install-hooks remove
  $LEGACY_DEST/scripts/we-menu-entry remove
  omarchy plugin remove $LEGACY_PLUGIN_ID

The shared wallpaper configuration and runtime state are preserved. Re-run this
installer after the legacy plugin has been removed.
EOF
  return 1
}

copy_tree() {
  local src=$1 dest=$2
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude '.git/' --exclude '.git' \
      --exclude '__pycache__/' --exclude '*.pyc' "$src/" "$dest/"
  else
    find "$dest" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +
    cp -a "$src"/. "$dest"/
    rm -rf "$dest/.git"
    find "$dest" -type d -name __pycache__ -prune -exec rm -rf {} +
    find "$dest" -type f -name '*.pyc' -delete
  fi
}

set_tree_modes() {
  local root=$1
  chmod +x \
    "$root/bin/we" \
    "$root/lib/compose_desktop.py" \
    "$root/lib/generate_theme.py" \
    "$root/scripts/we-menu" \
    "$root/scripts/we-menu-entry" \
    "$root/scripts/we-stage-transition" \
    "$root/scripts/install-hooks" \
    "$root/scripts/install.sh" \
    "$root/scripts/uninstall.sh" \
    "$root/hooks/post-boot.sh" \
    "$root/hooks/theme-set.sh"
}

validate_stage() {
  local root=$1 f qml_lint="" lint_json=""
  jq -e --arg id "$PLUGIN_ID" '.id == $id and (.entryPoints | type == "object")' \
    "$root/manifest.json" >/dev/null
  for f in "$root"/bin/we "$root"/lib/common.sh "$root"/scripts/* "$root"/hooks/*.sh; do
    [[ -f $f ]] || continue
    case "$f" in
      *.sh|*/we|*/we-menu|*/we-menu-entry|*/we-stage-transition|*/install-hooks|*/uninstall.sh)
        bash -n "$f"
        ;;
    esac
  done
  python3 -m py_compile "$root/lib/compose_desktop.py" "$root/lib/generate_theme.py"
  if command -v qmllint >/dev/null 2>&1; then
    qml_lint=$(command -v qmllint)
  elif [[ -x /usr/lib/qt6/bin/qmllint ]]; then
    qml_lint=/usr/lib/qt6/bin/qmllint
  fi
  if [[ -n $qml_lint ]]; then
    # qmllint reports many false-positive semantic warnings for plugins because
    # Omarchy injects their host types and context at runtime. Its default exit
    # code also ignores those warnings, so a silent rc=0 is not validation.
    # Ask for machine-readable diagnostics and explicitly reject parser errors;
    # the supported Omarchy validator below owns manifest/entry-point checks.
    lint_json=$(mktemp "$root/.qmllint.XXXXXX.json")
    if ! "$qml_lint" --json "$lint_json" "$root"/*.qml >/dev/null 2>&1; then
      if ! jq -e '[.files[].warnings[]? | select(.id == "syntax")] | length == 0' \
        "$lint_json" >/dev/null 2>&1; then
        jq -r '.files[].warnings[]? | select(.id == "syntax")
          | "\(.filename):\(.line):\(.column): \(.message)"' "$lint_json" >&2
        rm -f -- "$lint_json"
        return 1
      fi
    fi
    if ! jq -e '[.files[].warnings[]? | select(.id == "syntax")] | length == 0' \
      "$lint_json" >/dev/null 2>&1; then
      jq -r '.files[].warnings[]? | select(.id == "syntax")
        | "\(.filename):\(.line):\(.column): \(.message)"' "$lint_json" >&2
      rm -f -- "$lint_json"
      return 1
    fi
    rm -f -- "$lint_json"
  fi
  if command -v omarchy-plugin-validate >/dev/null 2>&1; then
    omarchy-plugin-validate "$root" >/dev/null
  fi
}

# Copy into the lowercase plugin-id path as a real directory (never a symlink
# to a differently-cased source tree). Canonical git-managed installs retain
# their repository metadata across the validated atomic replacement.
sync_plugin_tree() {
  local src=$1 dest=$2
  local parent stage generation replaced=0 committed=0 require_health=0 shell_config
  local preserve_git=0 git_top dest_phys
  parent=$(dirname -- "$dest")
  mkdir -p "$parent"

  # `omarchy plugin add` creates the canonical destination as a git checkout,
  # and `omarchy plugin update` requires that checkout's .git directory.  An
  # in-place install still needs the staged validation and health-checked swap
  # below, but its repository metadata must travel with the replacement tree.
  # Only do this for a valid repository rooted at the exact source/destination;
  # external development copies must never donate their git metadata.
  if [[ ! -L $dest && -d $dest && $src -ef $dest && -d $dest/.git ]] \
    && git_top=$(git -C "$dest" rev-parse --show-toplevel 2>/dev/null); then
    dest_phys=$(cd "$dest" && pwd -P)
    git_top=$(cd "$git_top" && pwd -P)
    [[ $git_top == "$dest_phys" ]] && preserve_git=1
  fi

  # Hidden siblings are ignored by Omarchy's recursive plugin watcher. Build
  # and validate the complete replacement there, then expose one atomic move.
  stage=$(mktemp -d "$parent/.${PLUGIN_ID}.stage.XXXXXX")
  copy_tree "$src" "$stage"
  generation="$(date +%s%N)-$$-$RANDOM"
  printf '%s\n' "$generation" >"$stage/.we-build-generation"
  set_tree_modes "$stage"
  if ! validate_stage "$stage"; then
    rm -rf -- "$stage"
    return 1
  fi

  # Decide from durable shell configuration, not old IPC responsiveness. A
  # wedged old service is precisely when rollback protection matters most.
  shell_config="$HOME/.config/omarchy/shell.json"
  if [[ -f $shell_config ]] \
    && jq -e --arg id "$PLUGIN_ID" \
      '((.disabledPlugins // []) | index($id) == null)
       and ([.. | objects | select(.id? == $id)] | length > 0)' \
      "$shell_config" >/dev/null 2>&1; then
    require_health=1
  fi

  rollback_swap() {
    local restored=0
    (( committed )) || return 0
    # Clear the guard before moving anything: ERR after INT/TERM must not
    # exchange the trees a second time.
    committed=0
    if (( replaced )); then
      # After a successful forward swap, the original .git directory is moved
      # from the old tree into the replacement. Put it back before exchanging
      # the trees during rollback. Checking its actual location also covers a
      # signal arriving between mv(1) and the following shell statement.
      if (( preserve_git )) \
        && [[ -d $dest/.git ]] && [[ ! -e $stage/.git && ! -L $stage/.git ]]; then
        mv -- "$dest/.git" "$stage/.git" || return 1
      fi
      if mv --exchange --no-copy --no-target-directory "$stage" "$dest"; then
        restored=1
      fi
    elif [[ -e $dest || -L $dest ]]; then
      if mv --no-copy --no-target-directory "$dest" "$stage"; then
        restored=1
      fi
    fi
    (( restored )) && rm -rf -- "$stage"
  }
  rollback_error() {
    local rc=$?
    trap - ERR INT TERM
    rollback_swap
    return "$rc"
  }
  rollback_signal() {
    local rc=$1
    trap - ERR INT TERM
    rollback_swap
    exit "$rc"
  }
  trap rollback_error ERR
  trap 'rollback_signal 130' INT
  trap 'rollback_signal 143' TERM

  if [[ -e $dest || -L $dest ]]; then
    mv --exchange --no-copy --no-target-directory "$stage" "$dest"
    replaced=1
  else
    mv --no-copy --no-target-directory "$stage" "$dest"
  fi
  committed=1

  if (( preserve_git )); then
    # The exchanged-out tree still owns the repository metadata. Attach it to
    # the validated replacement before removing that old tree after health
    # verification, so Omarchy continues to recognize this as updateable.
    mv -- "$stage/.git" "$dest/.git"
  fi

  # The visible move causes one debounced automatic reload. Never overlap it
  # with an explicit rescan. Omarchy's in-process plugin reload can retain old
  # IPC handlers and invalid QML contexts, so an enabled plugin gets one clean,
  # supported shell restart before generation-specific health verification.
  if (( require_health )); then
    if ! command -v omarchy-restart-shell >/dev/null 2>&1 \
      || ! omarchy-restart-shell; then
      echo "Could not safely restart Omarchy shell; rolling back plugin update." >&2
      rollback_swap
      trap - ERR INT TERM
      command -v omarchy-restart-shell >/dev/null 2>&1 && omarchy-restart-shell || true
      return 1
    fi
    local healthy=0 actual deadline=$((SECONDS + 10))
    while (( SECONDS < deadline )); do
      actual=$(timeout -k 0.2 0.8 \
        omarchy-shell wallpaper-engine-generation ping 2>/dev/null || true)
      if [[ $actual == "$generation" ]]; then
        healthy=1
        break
      fi
      sleep 0.1
    done
    if (( ! healthy )); then
      echo "Updated plugin failed its health check; rolling back." >&2
      rollback_swap
      trap - ERR INT TERM
      omarchy-restart-shell || true
      return 1
    fi
  fi

  committed=0
  trap - ERR INT TERM
  if (( replaced )); then
    rm -rf "$stage"
  fi
}

dest_is_git_checkout() {
  local dest=$1 git_top dest_phys
  [[ -e $dest/.git ]] || return 1
  git_top=$(git -C "$dest" rev-parse --show-toplevel 2>/dev/null) || return 1
  dest_phys=$(cd "$dest" && pwd -P)
  git_top=$(cd "$git_top" && pwd -P)
  [[ $git_top == "$dest_phys" ]]
}

note_copy_install_cannot_plugin_update() {
  cat <<EOF

This plugin directory is not a git checkout, so omarchy plugin update will not work.
Current beta (copy) installs need a one-time reinstall. Configuration in
~/.config/omarchy/wallpaper-engine/ is preserved. Do not use uninstall.sh --purge
unless you want a factory wipe.

  omarchy plugin remove $PLUGIN_ID
  omarchy plugin add https://github.com/14brussell/Wallpaper-Engine-Omarchy.git --enable
  $DEST/scripts/install.sh

Omarchy does not run plugin installers. Always run install.sh after add or update.
EOF
}

# Refuse to swap code while an apply/revert transaction owns the same plugin.
refuse_legacy_install
mkdir -p "$(dirname -- "$DEST")" "$HOME/.local/state/omarchy/wallpaper-engine"
exec 8>"$(dirname -- "$DEST")/.${PLUGIN_ID}.install.lock"
flock -w 5 8 || { echo "Another plugin install is already running." >&2; exit 1; }
exec 7>"$HOME/.local/state/omarchy/wallpaper-engine/transition.lock"
flock -w 2 7 || { echo "Wallpaper transition is active; retry the install when it finishes." >&2; exit 1; }

sync_plugin_tree "$SOURCE" "$DEST"
ROOT=$DEST

set_tree_modes "$ROOT"

"$ROOT/scripts/we-menu-entry" install
"$ROOT/scripts/install-hooks" install

mkdir -p "$HOME/.local/bin"
ln -sfn "$ROOT/bin/we" "$HOME/.local/bin/omarchy-we"
ln -sfn "$ROOT/bin/we" "$HOME/.local/bin/we-omarchy"

echo
echo "Wallpaper Engine Omarchy setup complete."
echo "  Installed: $ROOT  (real directory; plugin id $PLUGIN_ID)"
echo "  GUI:    Style → Wallpaper Engine  (Quickshell panel; or: omarchy-we panel)"
echo "  Revert: Style → Revert to theme background"
echo "  TUI:    Style → Wallpaper Engine (advanced TUI)  — optional gum fallback"
echo "  CLI:    omarchy-we apply | revert | doctor"
echo "  Config: ~/.config/omarchy/wallpaper-engine/config.json"
echo
echo "Omarchy does not run this installer on plugin add or update."
if dest_is_git_checkout "$ROOT"; then
  echo "Later updates: omarchy plugin update $PLUGIN_ID"
  echo "  then re-run this installer:"
  echo "  $ROOT/scripts/install.sh"
else
  note_copy_install_cannot_plugin_update
fi
echo "Enable the plugin / bar widget (if not already):"
echo "  omarchy plugin enable $PLUGIN_ID"
echo
"$ROOT/bin/we" doctor || true
