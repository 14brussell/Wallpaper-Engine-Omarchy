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

forbid() {
  local file=$1 pattern=$2 message=$3
  if grep -Fq -- "$pattern" "$ROOT/$file"; then
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
require Panel.qml 'current.discardDraftAndReload()' \
  'tab-switch discard must reload saved config and cancel apply'
require Panel.qml 'item.discardDraftAndReload()' \
  'panel-close discard must reload dirty drafts and cancel apply'
require Panel.qml 'root.wallpaperDirsDirty' \
  'wallpaper-folder exits must account for dirty state'

require DisplayTab.qml 'Accessible.role: Accessible.ListItem' \
  'wallpaper rows must expose an accessible list-item role'
require DisplayTab.qml 'Keys.onSpacePressed: wallpaperRow.chooseWallpaper()' \
  'wallpaper rows must be keyboard selectable'
require DisplayTab.qml 'text: "Save & apply"' \
  'Save & apply must keep a stable action label'
require DisplayTab.qml 'readonly property var layerOptions: ["bottom"]' \
  'GUI must not offer covering Wayland layers'
require DisplayTab.qml '"--layer", coerceEngineLayer(engineLayer)' \
  'Save & apply must coerce covering layers before persist'
require DisplayTab.qml 'overlay can hide the bar' \
  'GUI must warn that overlay can hide the bar widget'
forbid DisplayTab.qml '["bottom", "top", "overlay"]' \
  'GUI still lists top/overlay as selectable Wayland layers'

require DisplayTab.qml 'saveApplyState: "idle"' \
  'Save & apply must expose typed feedback state'
require DisplayTab.qml 'text: "Clear & stop"' \
  'the primary GUI must expose per-display Clear and stop'
require DisplayTab.qml 'Clear saved settings and stop Wallpaper Engine on ' \
  'Clear must require explicit, accurately worded confirmation'
require DisplayTab.qml 'No wallpapers match ‘' \
  'an empty filter result must differ from an empty catalog'
require DisplayTab.qml 'function qmlBool(value)' \
  'display-config JSON booleans must unwrap Quickshell V4 false'
require DisplayTab.qml 'configured = root.qmlBool(data.configured)' \
  'configured: false must not look Start-ready'
require DisplayTab.qml 'silent = (data.silent === undefined || data.silent === null)' \
  'missing silent must default muted; JSON false must stay unmuted via qmlBool'
require DisplayTab.qml ': root.qmlBool(data.silent)' \
  'silent must use qmlBool so JSON false does not reload as muted'
require DisplayTab.qml 'hasAudio: root.qmlBool(wallpaperCaps && wallpaperCaps.hasAudio)' \
  'hasAudio: false must not show audio chrome'
require DisplayTab.qml 'function cancelQueuedOrInFlightApply()' \
  'discard must cancel queued and in-flight we apply'
require DisplayTab.qml 'cancelQueuedOrInFlightApply()' \
  'discardDraftAndReload must cancel apply before reloading saved config'
require DisplayTab.qml 'if (gen !== root.actionGen)' \
  'queued Save & apply must not fire after discard bumps actionGen'
require DisplayTab.qml 'args.push("--silent")' \
  'Save & apply must still pass --silent'
require DisplayTab.qml 'args.push("--audio")' \
  'Save & apply must still pass --audio when unmuted'

forbid DisplayTab.qml 'data.silent !== false' \
  'bindEffective must not treat V4-wrapped JSON false as muted'
forbid DisplayTab.qml '!!data.configured' \
  'configured must go through qmlBool, not !!'
forbid DisplayTab.qml '!!(wallpaperCaps && wallpaperCaps.hasAudio)' \
  'hasAudio must go through qmlBool, not !!'

require BarWidget.qml 'root.bar.shell.toggle(root.pluginId, "{}")' \
  'the bar click behavior and tooltip must use panel toggle semantics'
require BarWidget.qml 'notifyRevertFailure' \
  'bar-adjacent revert failures must be visible'
require BarWidget.qml 'middle: advanced TUI' \
  'the tooltip must document all pointer actions in every state'

printf 'UI contracts: ok\n'
