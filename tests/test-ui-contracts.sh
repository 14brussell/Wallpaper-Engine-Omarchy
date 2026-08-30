#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

require() {
  local file=$1 pattern=$2 message=$3
  if ! grep -Fq -- "$pattern" "$ROOT/$file"; then
    printf 'FAIL: %s\n' "$message" >&2
    exit 1
  fi
}

require Panel.qml 'Accessible.role: Accessible.PageTab' \
  'display tabs must expose an accessible tab role'
require Panel.qml 'Keys.onLeftPressed:' \
  'display tabs must support arrow-key navigation'
require Panel.qml 'pendingDiscardAction = "tab"' \
  'display switching must protect unsaved drafts'
require Panel.qml 'root.wallpaperDirsDirty' \
  'wallpaper-folder exits must account for dirty state'

require DisplayTab.qml 'Accessible.role: Accessible.ListItem' \
  'wallpaper rows must expose an accessible list-item role'
require DisplayTab.qml 'Keys.onSpacePressed: wallpaperRow.chooseWallpaper()' \
  'wallpaper rows must be keyboard selectable'
require DisplayTab.qml 'text: "Save & apply"' \
  'Save & apply must keep a stable action label'
require DisplayTab.qml 'saveApplyState: "idle"' \
  'Save & apply must expose typed feedback state'
require DisplayTab.qml 'text: "Clear & stop"' \
  'the primary GUI must expose per-display Clear and stop'
require DisplayTab.qml 'Clear saved settings and stop Wallpaper Engine on ' \
  'Clear must require explicit, accurately worded confirmation'
require DisplayTab.qml 'No wallpapers match ‘' \
  'an empty filter result must differ from an empty catalog'

require BarWidget.qml 'root.bar.shell.toggle(root.pluginId, "{}")' \
  'the bar click behavior and tooltip must use panel toggle semantics'
require BarWidget.qml 'notifyRevertFailure' \
  'bar-adjacent revert failures must be visible'
require BarWidget.qml 'middle: advanced TUI' \
  'the tooltip must document all pointer actions in every state'

printf 'UI contracts: ok\n'
