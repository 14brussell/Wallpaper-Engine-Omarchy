import QtQuick
import QtQuick.Controls
import QtQuick.Controls as QQC
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Wallpaper Engine control surface — tileable FloatingWindow (no modal scrim).
// One tab per detected display; lifecycle controls + settings live inside
// DisplayTab. Only theme-wide actions remain in the global header.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property bool closingFromHost: false
  property bool loading: false
  property string busyAction: ""
  property string statusMessage: ""

  property var monitors: []
  // Parallel primitive string arrays — QML binds these safely (no V4 object tostring).
  // Always derived from live we status / hyprctl monitors on every refresh.
  property var monitorNames: []
  property var monitorTitles: []
  property var displays: ({})
  property var defaults: ({})
  property var enginePids: []
  property var engineDisplays: []
  property bool engineRunning: false
  property bool active: false
  property bool hasConfiguredDisplays: false
  property bool displayBusy: false
  property string themeName: ""
  property bool autoThemeActive: false
  property string autoThemePrevious: ""
  property string autoThemeSourceMonitor: ""
  property string lastAppliedMonitor: ""
  property var extraWallpaperDirs: []
  property var wallpaperDirsDraft: []
  property string wallpaperDirsError: ""
  property int currentTabIndex: 0

  readonly property string pluginRoot: {
    var url = Qt.resolvedUrl(".")
    return decodeURIComponent(String(url).replace(/^file:\/\//, "").replace(/\/$/, ""))
  }
  readonly property string weBin: root.pluginRoot + "/bin/we"
  readonly property color fg: Color.foreground
  readonly property color bg: Color.background
  readonly property color dim: Qt.darker(fg, 1.45)
  readonly property string fontFamily: Style.font.family
  readonly property color sectionFill: Qt.rgba(fg.r, fg.g, fg.b, 0.035)
  readonly property color sectionBorderColor: Qt.rgba(fg.r, fg.g, fg.b, 0.22)
  readonly property var sectionBorderSpec: Border.controlSpec("normal", fg, Color.accent)
  readonly property int displayCount: {
    var n = monitorNames ? monitorNames.length : 0
    return (typeof n === "number" && isFinite(n) && n > 0) ? Math.floor(n) : 0
  }

  // Single source of truth for caption + tab highlight + stack + tabActive.
  readonly property string currentMonitor: {
    if (displayCount === 0) return ""
    var i = Math.max(0, Math.min(currentTabIndex, displayCount - 1))
    return root.labelAt(monitorNames, i)
  }
  readonly property string currentMonitorTitle: {
    if (displayCount === 0) return ""
    var i = Math.max(0, Math.min(currentTabIndex, displayCount - 1))
    var t = root.labelAt(monitorTitles, i)
    if (t.length) return t
    return root.currentMonitor
  }
  readonly property bool applyInFlight: displayBusy || actionProc.running
  // Auto-match needs the captured frame recorded by a successful apply.
  // Merely selecting or saving a wallpaper does not provide a valid source.
  readonly property bool autoThemeHasSource: lastAppliedMonitor.length > 0
  readonly property string autoThemeHint: {
    var monitor = lastAppliedMonitor.length
      ? lastAppliedMonitor
      : autoThemeSourceMonitor
    var hint = "Uses the most recently applied wallpaper"
    return monitor.length ? (hint + " (" + monitor + ")") : hint
  }
  readonly property bool savingWallpaperDirs: actionProc.running
    && actionProc.actionName === "set-wallpaper-dirs"
  readonly property bool wallpaperDirsDirty: {
    if (root.asJsString(folderPathField.text).trim().length) return true
    return JSON.stringify(wallpaperDirsDraft || [])
      !== JSON.stringify(extraWallpaperDirs || [])
  }
  readonly property string progressText: {
    if (busyAction.length) return busyAction
    if (displayBusy) return "Applying…"
    return statusMessage
  }
  readonly property bool progressIsBusy: busyAction.length > 0 || displayBusy

  // Force a real JS string primitive (never String(object) → [object V4…]).
  function asJsString(value) {
    if (value === undefined || value === null) return ""
    var t = typeof value
    if (t === "string") return value
    if (t === "number" || t === "boolean") return "" + value
    try {
      var encoded = JSON.stringify(value)
      if (typeof encoded === "string" && encoded.length >= 2 && encoded.charAt(0) === '"')
        return JSON.parse(encoded)
    } catch (e) {}
    return ""
  }

  function looksLikeObjectDump(s) {
    if (!s || !s.length) return true
    if (s.indexOf("[object") !== -1) return true
    if (s.indexOf("V4Reference") !== -1) return true
    if (s.indexOf("V4Object") !== -1) return true
    return false
  }

  // Tab / caption text must never contain the word "Monitor".
  function stripMonitorWord(s) {
    var t = root.asJsString(s)
    if (!t.length) return ""
    t = t.replace(/Monitor/gi, "")
    t = t.replace(/\s{2,}/g, " ")
    t = t.replace(/^\s+|\s+$/g, "")
    t = t.replace(/^\s*·\s*/, "")
    t = t.replace(/\s*·\s*$/, "")
    return t
  }

  function labelAt(list, index) {
    if (!list || index < 0 || index >= list.length) return ""
    return root.stripMonitorWord(root.asJsString(list[index]))
  }

  // QV4/Quickshell often wraps JSON values as V4ReferenceObject; String(obj)
  // becomes "[object V4ReferenceObject]". Round-trip through JSON to get real
  // primitives before any UI concatenation.
  function qmlPlain(value) {
    if (value === undefined || value === null) return null
    var t = typeof value
    if (t === "string" || t === "number" || t === "boolean") return value
    try {
      return JSON.parse(JSON.stringify(value))
    } catch (e) {
      return null
    }
  }

  function qmlString(value) {
    return root.asJsString(value)
  }

  function qmlNumber(value) {
    var v = root.qmlPlain(value)
    var n = Number(v)
    return isFinite(n) ? n : 0
  }

  // JSON false wrapped as V4ReferenceObject is truthy under !!. Never treat
  // leftover objects as true — that hid Start while the engine was down.
  function qmlBool(value) {
    if (value === true) return true
    if (value === false || value === undefined || value === null) return false
    var v = root.qmlPlain(value)
    if (v === true) return true
    if (v === false || v === undefined || v === null) return false
    if (typeof v === "number") return v !== 0
    if (typeof v === "string") {
      var s = v.toLowerCase()
      return s === "true" || s === "1" || s === "running" || s === "yes"
    }
    if (Array.isArray(v)) return v.length > 0
    return false
  }

  function qmlPidList(value) {
    var src = root.qmlPlain(value)
    if (!Array.isArray(src)) return []
    var out = []
    for (var i = 0; i < src.length; i++) {
      var n = Number(src[i])
      if (isFinite(n) && n > 0) out.push(n)
    }
    return out
  }

  function qmlStringList(value) {
    var src = root.qmlPlain(value)
    if (!Array.isArray(src)) return []
    var out = []
    for (var i = 0; i < src.length; i++) {
      var s = root.asJsString(src[i])
      if (s.length) out.push(s)
    }
    return out
  }

  function displayEngineRunning(name) {
    var wanted = root.asJsString(name)
    for (var i = 0; i < engineDisplays.length; i++) {
      if (root.asJsString(engineDisplays[i]) === wanted) return true
    }
    return false
  }

  function geometryTitle(name, width, height) {
    var n = root.stripMonitorWord(name)
    if (!n.length) return ""
    var w = Math.round(Number(width) || 0)
    var h = Math.round(Number(height) || 0)
    if (w > 0 && h > 0)
      return n + " · " + w + "×" + h
    return n
  }

  // Live hyprctl / we status monitors → plain {name, width, height, title}.
  // Never hardcode display names or resolutions.
  function normalizeMonitors(rawList) {
    var src = root.qmlPlain(rawList)
    if (!Array.isArray(src)) src = []
    var out = []
    for (var i = 0; i < src.length; i++) {
      var entry = src[i]
      var name = ""
      var w = 0
      var h = 0
      if (typeof entry === "string" || typeof entry === "number") {
        name = root.stripMonitorWord("" + entry)
      } else if (entry && typeof entry === "object") {
        name = root.stripMonitorWord(root.qmlString(entry.name))
        w = root.qmlNumber(entry.width)
        h = root.qmlNumber(entry.height)
      }
      if (!name.length) continue
      if (w < 0 || !isFinite(w)) w = 0
      if (h < 0 || !isFinite(h)) h = 0
      w = Math.round(w)
      h = Math.round(h)
      out.push({ name: name, width: w, height: h, title: root.geometryTitle(name, w, h) })
    }
    return out
  }

  // Build parallel string arrays for QML bindings (preferred over object model).
  function stringListFrom(value) {
    var src = root.qmlPlain(value)
    if (!Array.isArray(src)) return []
    var out = []
    for (var i = 0; i < src.length; i++) {
      var s = root.stripMonitorWord(root.asJsString(src[i]))
      if (root.looksLikeObjectDump(s)) continue
      if (s.length) out.push(s)
    }
    return out
  }

  function applyMonitorModel(data) {
    var normalized = root.normalizeMonitors(data ? data.monitors : [])
    var names = root.stringListFrom(data ? data.monitorNames : null)
    var titles = root.stringListFrom(data ? data.monitorTitles : null)

    // Fallback: derive strings from normalized objects if status lacks arrays.
    if (names.length === 0 && normalized.length) {
      names = []
      for (var i = 0; i < normalized.length; i++)
        names.push(normalized[i].name)
    }
    if (titles.length === 0 && normalized.length) {
      titles = []
      for (var j = 0; j < normalized.length; j++)
        titles.push(normalized[j].title)
    }

    // Keep lengths aligned (names drive tabs / DisplayTab.displayName).
    while (titles.length < names.length)
      titles.push(names[titles.length])
    if (titles.length > names.length)
      titles = titles.slice(0, names.length)

    // Rebuild every title from live geometry so tabs stay "DP-2 · 2560×1440"
    // even if a V4 wrapper leaked "[object Object]" or a "Monitor " prefix.
    var rebuilt = []
    for (var k = 0; k < names.length; k++) {
      var n = names[k]
      var w = 0
      var h = 0
      for (var m = 0; m < normalized.length; m++) {
        if (normalized[m].name === n) {
          w = normalized[m].width
          h = normalized[m].height
          break
        }
      }
      var raw = titles[k]
      if (root.looksLikeObjectDump(raw) || raw === n)
        rebuilt.push(root.geometryTitle(n, w, h))
      else if (w > 0 && h > 0)
        rebuilt.push(root.geometryTitle(n, w, h))
      else
        rebuilt.push(raw)
    }

    monitors = normalized
    monitorNames = names
    monitorTitles = rebuilt
  }

  function monitorEntry(m) {
    var normalized = root.normalizeMonitors([m])
    if (normalized.length)
      return normalized[0]
    return { name: "", width: 0, height: 0, title: "" }
  }

  function monitorName(m) {
    return root.monitorEntry(m).name
  }

  function monitorResolution(m) {
    var e = root.monitorEntry(m)
    if (e.width > 0 && e.height > 0)
      return e.width + "×" + e.height
    return ""
  }

  function monitorTitle(m) {
    return root.monitorEntry(m).title
  }

  function openWallpaperFolders() {
    wallpaperDirsDraft = extraWallpaperDirs ? extraWallpaperDirs.slice(0) : []
    wallpaperDirsError = ""
    folderPathField.text = ""
    wallpaperDirsPopup.open()
  }

  function addWallpaperFolder() {
    var path = root.asJsString(folderPathField.text).trim()
    if (!path.length) return false
    var next = wallpaperDirsDraft ? wallpaperDirsDraft.slice(0) : []
    if (next.indexOf(path) < 0)
      next.push(path)
    wallpaperDirsDraft = next
    folderPathField.text = ""
    wallpaperDirsError = ""
    return true
  }

  function removeWallpaperFolder(index) {
    var next = wallpaperDirsDraft ? wallpaperDirsDraft.slice(0) : []
    if (index >= 0 && index < next.length)
      next.splice(index, 1)
    wallpaperDirsDraft = next
    wallpaperDirsError = ""
  }

  function saveWallpaperFolders() {
    if (root.asJsString(folderPathField.text).trim().length)
      root.addWallpaperFolder()
    wallpaperDirsError = ""
    runWe(["set-wallpaper-dirs"].concat(wallpaperDirsDraft), "Saving wallpaper folders…")
  }

  function open(payloadJson) {
    // Never summon another shell surface from this panel. Host summon already
    // delivered us here, and wallpaper lifecycle stays in the backend.
    closingFromHost = false
    opened = true
    statusMessage = ""
    try {
      selectTab(0, true)
      window.visible = true
      refresh()
      Qt.callLater(function() {
        if (!opened) return
        try {
          selectTab(0, true)
          keyCatcher.forceActiveFocus()
        } catch (e2) {}
      })
    } catch (e) {
      window.visible = true
      statusMessage = "Panel opened with errors"
    }
  }

  function close() {
    closingFromHost = true
    opened = false
    busyAction = ""
    statusMessage = ""
    wallpaperDirsPopup.close()
    window.visible = false
    closingFromHost = false
  }

  function dismiss() {
    try {
      if (shell && typeof shell.hide === "function")
        shell.hide((manifest && manifest.id) || "io.github.14brussell.wallpaper-engine")
      else
        close()
    } catch (e) {
      close()
    }
  }

  function refresh(soft) {
    if (statusProc.running) return
    if (!weBin || !weBin.length) {
      if (!soft) statusMessage = "Plugin bin/we missing"
      return
    }
    statusProc.softRefresh = !!soft
    statusProc.command = [weBin, "status", "--json"]
    statusWatchdog.restart()
    try {
      statusProc.running = true
    } catch (e) {
      statusWatchdog.stop()
      if (!soft) statusMessage = "Could not read status"
    }
  }

  function actionVerb(name) {
    if (name === "apply") return "Start"
    if (name === "stop") return "Stop"
    if (name === "revert") return "Revert"
    if (name === "auto-theme") return "Auto-match"
    if (name === "undo-auto-theme") return "Undo auto-match"
    if (!name || !name.length) return "Action"
    return name.charAt(0).toUpperCase() + name.slice(1)
  }

  // Global theme actions use argv Process calls only. Nested shell IPC is not
  // part of wallpaper lifecycle. waitForEnd:false + watchdog bounds the UI.
  function runWe(args, actionLabel) {
    if (actionProc.running || root.displayBusy) {
      statusMessage = "Busy — wait for the current action to finish"
      return
    }
    if (!weBin || !weBin.length) {
      busyAction = ""
      statusMessage = "Plugin bin/we missing"
      return
    }
    busyAction = actionLabel || ""
    statusMessage = ""
    actionProc.lastStderr = ""
    actionProc.settled = false
    actionProc.actionName = (args && args.length) ? String(args[0]) : "action"
    actionProc.command = [weBin].concat(args)
    actionWatchdog.restart()
    try {
      actionProc.running = true
    } catch (e) {
      actionWatchdog.stop()
      busyAction = ""
      statusMessage = "Could not start " + root.actionVerb(actionProc.actionName)
    }
  }

  function finishAction(code, timedOut) {
    if (actionProc.settled) return
    actionProc.settled = true
    actionWatchdog.stop()
    if (timedOut && actionProc.running) {
      try { actionProc.running = false } catch (e) {}
    }
    busyAction = ""
    var err = ""
    try { err = String(actionErr.text || "").trim() } catch (e2) {}
    if (!err.length) err = String(actionProc.lastStderr || "").trim()
    actionProc.lastStderr = ""
    var verb = root.actionVerb(actionProc.actionName)
    if (timedOut) {
      statusMessage = verb + " timed out — check we doctor / engine.log"
    } else if (code === 0) {
      if (!statusMessage.length)
        statusMessage = "Done"
    } else {
      var first = err.length ? err.split("\n")[0] : ""
      if (/Missing dependency:.*linux-wallpaperengine/i.test(first)
          || /linux-wallpaperengine-git/i.test(err)) {
        statusMessage = first + " — run: we doctor"
      } else if (first.length) {
        statusMessage = first
      } else {
        statusMessage = verb + " failed (exit " + code + ")"
      }
    }
    if (actionProc.actionName === "set-wallpaper-dirs") {
      if (!timedOut && code === 0) {
        extraWallpaperDirs = wallpaperDirsDraft.slice(0)
        wallpaperDirsError = ""
        wallpaperDirsPopup.close()
        statusMessage = "Wallpaper folders updated"
      } else {
        wallpaperDirsError = statusMessage
      }
    }
    Qt.callLater(function() { root.refresh() })
  }

  function revertTheme() { runWe(["revert"], "Restoring…") }
  function toggleAutoTheme() {
    if (autoThemeActive)
      runWe(["undo-auto-theme"], "Restoring previous theme…")
    else if (lastAppliedMonitor.length)
      runWe(["auto-theme"], "Matching the most recently applied wallpaper…")
    else
      statusMessage = "Save & apply a wallpaper before auto-matching its theme"
  }
  // Clamp + optionally force index 0. All UI (caption, highlight, stack, tabActive)
  // reads currentTabIndex / currentMonitor — never a parallel TabBar index.
  function selectTab(index, forceReload) {
    if (displayCount === 0) {
      if (currentTabIndex !== 0)
        currentTabIndex = 0
      return
    }
    var i = Math.max(0, Math.min(Number(index) || 0, displayCount - 1))
    var changed = currentTabIndex !== i
    if (changed)
      currentTabIndex = i
    if (forceReload || changed)
      Qt.callLater(function() { root.reloadCurrentTab() })
  }

  function clampTabIndex() {
    if (displayCount === 0) {
      currentTabIndex = 0
      return
    }
    if (currentTabIndex < 0 || currentTabIndex >= displayCount)
      selectTab(0, true)
  }

  function reloadCurrentTab() {
    if (displayCount === 0) return
    if (root.applyInFlight) return
    var i = Math.max(0, Math.min(currentTabIndex, displayCount - 1))
    var item = tabRepeater.itemAt(i)
    if (item && typeof item.reload === "function")
      item.reload()
  }

  function parseStatus(raw, soft) {
    try {
      var data = JSON.parse(String(raw || "{}"))
      var prevFingerprint = JSON.stringify(monitorNames) + "\n" + JSON.stringify(monitorTitles)
      active = root.qmlBool(data.active)
      enginePids = root.qmlPidList(data.enginePids)
      engineDisplays = root.qmlStringList(data.engineDisplays)
      // Live pids win; unwrap JSON booleans so a V4-wrapped false is not "running".
      engineRunning = enginePids.length > 0 || root.qmlBool(data.engineRunning)
      hasConfiguredDisplays = root.qmlBool(data.hasConfiguredDisplays)
      if (!hasConfiguredDisplays && data.configuredDisplayCount !== undefined)
        hasConfiguredDisplays = root.qmlNumber(data.configuredDisplayCount) > 0
      // Fallback if an older status payload lacks the field: infer from displays.
      if (!hasConfiguredDisplays && data.displays && typeof data.displays === "object") {
        var keys = Object.keys(data.displays)
        for (var i = 0; i < keys.length; i++) {
          var d = data.displays[keys[i]]
          if (d && root.asJsString(d.wallpaper).length) {
            hasConfiguredDisplays = true
            break
          }
        }
      }
      themeName = root.qmlString(data.theme)
      autoThemeActive = root.qmlBool(data.autoThemeActive)
      autoThemePrevious = root.qmlString(data.autoThemePrevious)
      autoThemeSourceMonitor = root.qmlString(data.autoThemeSourceMonitor)
      lastAppliedMonitor = root.qmlString(data.lastAppliedMonitor)
      extraWallpaperDirs = root.qmlStringList(data.extraWallpaperDirs)
      defaults = root.qmlPlain(data.defaults) || ({})
      displays = root.qmlPlain(data.displays) || ({})
      // Live hyprctl-backed monitors → plain objects + parallel string arrays.
      root.applyMonitorModel(data)
      clampTabIndex()
      // Soft poll: only update badge/engine state — don't wipe tab drafts.
      // Still refresh the current tab when monitor geometry/identity changes.
      if (soft) {
        var nextFingerprint = JSON.stringify(monitorNames) + "\n" + JSON.stringify(monitorTitles)
        if (nextFingerprint !== prevFingerprint && !root.applyInFlight)
          Qt.callLater(function() {
            root.clampTabIndex()
            root.reloadCurrentTab()
          })
        return
      }
      if (root.applyInFlight)
        return
      Qt.callLater(function() {
        root.clampTabIndex()
        root.reloadCurrentTab()
      })
    } catch (e) {
      statusMessage = "Could not read status"
    }
  }

  Process {
    id: statusProc
    property bool softRefresh: false
    stdout: StdioCollector {
      id: statusOut
      waitForEnd: true
      onStreamFinished: {
        statusWatchdog.stop()
        if (!root.opened) return
        var soft = statusProc.softRefresh
        statusProc.softRefresh = false
        root.parseStatus(text, soft)
      }
    }
    onExited: function(code) {
      statusWatchdog.stop()
      if (code === 0) return
      if (!root.opened || statusProc.softRefresh) return
      if (root.statusMessage === "Status timed out") return
      if (!root.statusMessage.length)
        root.statusMessage = "Could not read status"
    }
  }

  Timer {
    id: statusWatchdog
    interval: 8000
    repeat: false
    onTriggered: {
      if (!statusProc.running) return
      try { statusProc.running = false } catch (e) {}
      if (root.opened && !statusProc.softRefresh)
        root.statusMessage = "Status timed out"
    }
  }

  Process {
    id: actionProc
    property string lastStderr: ""
    property string actionName: ""
    property bool settled: true
    property int pendingCode: 1
    // waitForEnd must stay false: linux-wallpaperengine is long-running and
    // inherited pipes must not leave Start/Stop stuck after the CLI exits.
    stdout: StdioCollector { waitForEnd: false }
    stderr: StdioCollector {
      id: actionErr
      waitForEnd: false
      onStreamFinished: actionProc.lastStderr = String(text || "").trim()
    }
    onRunningChanged: {
      if (running) {
        actionWatchdog.restart()
        return
      }
      actionWatchdog.stop()
      // Defer twice so onExited + stderr flush win over this fallback.
      Qt.callLater(function() {
        Qt.callLater(function() {
          if (!actionProc.settled && !actionProc.running)
            root.finishAction(actionProc.pendingCode, false)
        })
      })
    }
    onExited: function(code) {
      actionProc.pendingCode = code
      Qt.callLater(function() {
        root.finishAction(actionProc.pendingCode, false)
      })
    }
  }

  Timer {
    id: actionWatchdog
    interval: (actionProc.actionName === "auto-theme"
      || actionProc.actionName === "undo-auto-theme") ? 120000 : 60000
    repeat: false
    onTriggered: {
      if (actionProc.settled) return
      root.finishAction(-1, true)
    }
  }

  Timer {
    id: displayBusyWatchdog
    interval: 60000
    repeat: false
    onTriggered: {
      if (!root.displayBusy) return
      root.displayBusy = false
      if (!actionProc.running)
        root.busyAction = ""
      if (!root.statusMessage.length)
        root.statusMessage = "Display action timed out"
    }
  }

  // Poll while open so the badge tracks an externally killed engine.
  Timer {
    id: statusPoll
    interval: 3000
    repeat: true
    running: root.opened
    onTriggered: root.refresh(true)
  }

  // Watch active flag so the badge updates without a manual refresh.
  FileView {
    id: activeFlag
    path: {
      var state = Quickshell.env("XDG_STATE_HOME")
      var home = Quickshell.env("HOME")
      var base = (state && state.length) ? state : (home + "/.local/state")
      return base + "/omarchy/wallpaper-engine/active"
    }
    watchChanges: true
    onFileChanged: if (root.opened) root.refresh(true)
  }

  onDisplayBusyChanged: {
    if (displayBusy) displayBusyWatchdog.restart()
    else displayBusyWatchdog.stop()
  }

  onCurrentTabIndexChanged: {
    // Reload the newly selected DisplayTab (tabActive flips → it also reloads;
    // call explicitly so first-show / programmatic select never misses).
    Qt.callLater(function() { root.reloadCurrentTab() })
  }

  FloatingWindow {
    id: window
    visible: root.opened
    title: "Wallpaper Engine for Omarchy"
    color: root.bg
    implicitWidth: Style.space(920)
    implicitHeight: Style.space(620)
    minimumSize: Qt.size(Style.space(720), Style.space(480))

    onVisibleChanged: {
      if (!visible && root.opened && !root.closingFromHost)
        root.dismiss()
    }

    FocusScope {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.dismiss()

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.space(16)
        spacing: Style.space(12)

        // ---- Section: header + status + global theme actions
        BorderSurface {
          Layout.fillWidth: true
          implicitHeight: headerCol.implicitHeight + Style.space(28)
          color: root.sectionFill
          borderSpec: root.sectionBorderSpec
          radius: Style.cornerRadius
          clip: true

          ColumnLayout {
            id: headerCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(14)
            spacing: Style.space(12)

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(12)

              Text {
                textFormat: Text.PlainText
                text: "󰸉"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  text: "Wallpaper Engine for Omarchy"
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  text: root.themeName.length
                    ? ("Omarchy theme · " + root.themeName)
                    : "linux-wallpaperengine on Hyprland"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                Layout.maximumWidth: Style.space(420)
                visible: !root.hasConfiguredDisplays && !root.engineRunning
                  && !root.applyInFlight && root.statusMessage.length === 0
                text: "No wallpapers configured — pick one on a display tab, then Save & apply."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignRight
                verticalAlignment: Text.AlignVCenter
                wrapMode: Text.WordWrap
              }

              PanelActionButton {
                iconText: "󰅖"
                tooltipText: "Close"
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: root.dismiss()
              }
            }

            PanelSeparator { Layout.fillWidth: true; foreground: root.fg }

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)

              Button {
                id: autoThemeButton
                text: root.autoThemeActive
                  ? "Undo theme match"
                  : "Auto-match theme"
                iconText: root.autoThemeActive ? "󰕍" : "󰏘"
                foreground: root.fg
                accent: Color.accent
                active: root.autoThemeActive
                bordered: true
                Layout.fillWidth: true
                enabled: !actionProc.running && !root.displayBusy
                  && (root.autoThemeActive || root.autoThemeHasSource)
                onClicked: root.toggleAutoTheme()
              }

              Button {
                text: "Revert to theme"
                iconText: "󰕍"
                foreground: root.fg
                accent: Color.accent
                active: root.engineRunning || root.active || root.hasConfiguredDisplays
                bordered: true
                enabled: !actionProc.running && !root.displayBusy
                Layout.fillWidth: true
                onClicked: root.revertTheme()
              }

              PanelActionButton {
                iconText: "󰑐"
                tooltipText: "Refresh status"
                foreground: root.fg
                fontFamily: root.fontFamily
                enabled: !statusProc.running
                onClicked: root.refresh()
              }
            }

            Text {
              textFormat: Text.PlainText
              Layout.preferredWidth: autoThemeButton.width
              Layout.maximumWidth: autoThemeButton.width
              text: root.autoThemeHint
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              visible: root.progressText.length > 0
              text: root.progressText
              color: root.progressIsBusy ? Color.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }

        // ---- Section: notebook tabs + selected DisplayTab
        BorderSurface {
          Layout.fillWidth: true
          Layout.fillHeight: true
          color: root.sectionFill
          borderSpec: root.sectionBorderSpec
          radius: Style.cornerRadius
          clip: true

          ColumnLayout {
            anchors.fill: parent
            anchors.margins: Style.space(14)
            spacing: 0

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(8)

              PanelSectionHeader {
                Layout.fillWidth: true
                text: "DISPLAYS"
                foreground: root.fg
                fontFamily: root.fontFamily
              }

            }

            Text {
              textFormat: Text.PlainText
              visible: root.displayCount === 0
              Layout.fillWidth: true
              Layout.topMargin: Style.space(10)
              text: "No displays detected (hyprctl)."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            // Notebook tab strip — equal-width tabs joined to the content below.
            // Selection visuals bind to currentTabIndex (not TabButton.checked).
            Item {
              id: tabStrip
              Layout.fillWidth: true
              Layout.topMargin: Style.space(10)
              implicitHeight: Style.font.title + Style.space(24)
              Layout.preferredHeight: implicitHeight
              visible: root.displayCount > 0

              Row {
                id: tabRow
                anchors.fill: parent
                spacing: 0

                Repeater {
                  // Integer model — never pass monitor objects as modelData.
                  model: root.displayCount

                  Item {
                    id: tabDelegate
                    required property int index

                    readonly property bool selected: index === root.currentTabIndex
                    readonly property bool hovered: tabMouse.containsMouse
                    readonly property string displayName: root.labelAt(
                      root.monitorNames, index)
                    readonly property bool engineRunning: root.displayEngineRunning(
                      tabDelegate.displayName)
                    readonly property string titleText: {
                      var t = root.labelAt(root.monitorTitles, index)
                      if (t.length) return t
                      return root.labelAt(root.monitorNames, index)
                    }

                    width: tabRow.width / Math.max(1, root.displayCount)
                    height: tabRow.height

                  Rectangle {
                    anchors.fill: parent
                    // Square the bottom so the selected tab reads as attached
                    // to the content pane; round the top like a notebook tab.
                    radius: Math.max(2, Style.cornerRadius - 2)
                    color: {
                      if (tabDelegate.selected)
                        return Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.28)
                      if (tabDelegate.hovered)
                        return Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.12)
                      return "transparent"
                    }
                    border.width: tabDelegate.selected ? 1 : 0
                    border.color: tabDelegate.selected
                      ? Color.accent
                      : "transparent"
                  }

                  // Cover the bottom edge of the selected tab so it merges
                  // into the content pane (no gap under the active tab).
                  Rectangle {
                    visible: tabDelegate.selected
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: Math.max(2, Style.cornerRadius - 2)
                    color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.28)
                  }

                  RowLayout {
                    anchors.centerIn: parent
                    anchors.verticalCenterOffset: tabDelegate.selected ? -1 : 0
                    width: parent.width - Style.space(16)
                    spacing: Style.space(8)

                    Text {
                      textFormat: Text.PlainText
                      Layout.fillWidth: true
                      text: tabDelegate.titleText
                      color: tabDelegate.selected
                        ? root.fg
                        : (tabDelegate.hovered ? root.fg : root.dim)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                      font.bold: tabDelegate.selected
                      horizontalAlignment: Text.AlignHCenter
                      elide: Text.ElideRight
                    }

                    BorderSurface {
                      implicitWidth: tabStatusText.implicitWidth + Style.space(16)
                      implicitHeight: tabStatusText.implicitHeight + Style.space(8)
                      color: "transparent"
                      borderSpec: Border.controlSpec(
                        "normal",
                        tabDelegate.engineRunning ? Color.accent : root.dim,
                        Color.accent)
                      radius: Style.cornerRadius

                      Text {
                        textFormat: Text.PlainText
                        id: tabStatusText
                        anchors.centerIn: parent
                        text: tabDelegate.engineRunning ? "Running" : "Stopped"
                        color: tabDelegate.engineRunning ? Color.accent : root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: true
                      }
                    }
                  }

                  Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: 3
                    color: Color.accent
                    visible: tabDelegate.selected
                  }

                  MouseArea {
                    id: tabMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.selectTab(tabDelegate.index, true)
                  }
                }
              }
            }
            }

            // Hairline under the tab strip; selected tab's accent bar sits on it.
            Rectangle {
              Layout.fillWidth: true
              visible: root.displayCount > 0
              height: 1
              color: root.sectionBorderColor
            }

            Item {
              Layout.fillWidth: true
              Layout.fillHeight: true
              Layout.topMargin: Style.space(12)
              visible: root.displayCount > 0
              clip: true

              Repeater {
                id: tabRepeater
                // Integer model so displayName is never an object / [object Object].
                model: root.displayCount

                DisplayTab {
                  id: displayTab
                  required property int index

                  anchors.fill: parent
                  visible: index === root.currentTabIndex
                  z: index === root.currentTabIndex ? 1 : 0

                  // Live monitor name string only (from we status monitorNames).
                  displayName: root.labelAt(root.monitorNames, index)
                  weBin: root.weBin
                  pluginRoot: root.pluginRoot
                  tabActive: index === root.currentTabIndex && root.currentTabIndex >= 0
                  panelBusy: actionProc.running || root.displayBusy
                  engineRunning: root.displayEngineRunning(displayTab.displayName)

                  onRefreshNeeded: root.refresh()
                  onApplied: root.refresh()
                  onEditWallpaperFoldersRequested: root.openWallpaperFolders()
                  onActionBusyChanged: function(isBusy, actionKind) {
                    root.displayBusy = isBusy
                    if (isBusy) {
                      var verb = "Working on"
                      if (actionKind === "start") verb = "Starting"
                      else if (actionKind === "stop") verb = "Stopping"
                      else if (actionKind === "clear") verb = "Clearing"
                      else if (actionKind === "apply") verb = "Applying to"
                      if (!root.busyAction.length)
                        root.busyAction = verb + " " + displayTab.displayName + "…"
                    } else if (!actionProc.running) {
                      root.busyAction = ""
                    }
                  }
                  onStatusMessage: function(text) {
                    root.statusMessage = text
                  }
                }
              }
            }
          }
        }
      }
    }

    Popup {
      id: wallpaperDirsPopup
      parent: window.contentItem
      x: Math.max(Style.space(8), (window.width - width) / 2)
      y: Math.max(Style.space(8), (window.height - height) / 2)
      width: Math.min(Style.space(620), window.width - Style.space(32))
      height: Math.min(Style.space(430), window.height - Style.space(32))
      padding: Style.space(16)
      modal: true
      focus: true
      closePolicy: root.savingWallpaperDirs
        ? Popup.NoAutoClose
        : Popup.CloseOnEscape | Popup.CloseOnPressOutside

      onOpened: Qt.callLater(function() { folderPathField.forceActiveFocus() })
      onClosed: if (root.opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })

      background: BorderSurface {
        color: root.bg
        borderSpec: root.sectionBorderSpec
        radius: Style.cornerRadius
      }

      contentItem: ColumnLayout {
        spacing: Style.space(10)

        RowLayout {
          Layout.fillWidth: true

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: "Wallpaper folders"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: "Add another Steam library or Workshop content folder. Automatic locations stay enabled."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          PanelActionButton {
            iconText: "󰅖"
            tooltipText: "Close"
            foreground: root.fg
            fontFamily: root.fontFamily
            enabled: !root.savingWallpaperDirs
            onClicked: wallpaperDirsPopup.close()
          }
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.fg }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: "Paste a Steam library folder, steamapps folder, or …/workshop/content/431960."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          TextField {
            id: folderPathField
            Layout.fillWidth: true
            placeholderText: "/mnt/games/SteamLibrary"
            foreground: root.fg
            font.family: root.fontFamily
            enabled: !actionProc.running
            onAccepted: root.addWallpaperFolder()
          }

          Button {
            text: "Add"
            iconText: "󰐕"
            foreground: root.fg
            bordered: true
            enabled: !actionProc.running && folderPathField.text.trim().length > 0
            onClicked: root.addWallpaperFolder()
          }
        }

        BorderSurface {
          Layout.fillWidth: true
          Layout.fillHeight: true
          color: root.sectionFill
          borderSpec: root.sectionBorderSpec
          radius: Style.cornerRadius
          clip: true

          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            visible: root.wallpaperDirsDraft.length === 0
            text: "No additional folders"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          ListView {
            id: wallpaperDirsList
            readonly property bool hasVerticalOverflow: contentHeight > height + 0.5
            anchors.fill: parent
            anchors.margins: Style.space(6)
            visible: root.wallpaperDirsDraft.length > 0
            model: root.wallpaperDirsDraft
            spacing: Style.space(4)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            QQC.ScrollBar.vertical: QQC.ScrollBar {
              id: wallpaperDirsScrollBar
              policy: wallpaperDirsList.hasVerticalOverflow
                ? QQC.ScrollBar.AsNeeded
                : QQC.ScrollBar.AlwaysOff

              contentItem: Rectangle {
                implicitWidth: Style.space(6)
                implicitHeight: Style.space(32)
                radius: width / 2
                color: Color.accent
                opacity: wallpaperDirsScrollBar.pressed || wallpaperDirsScrollBar.hovered ? 1 : 0.82

                Behavior on opacity {
                  NumberAnimation { duration: 100 }
                }
              }

              background: Item {}
            }

            delegate: RowLayout {
              required property string modelData
              required property int index
              width: ListView.view.width
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: modelData
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideMiddle
              }

              PanelActionButton {
                iconText: "󰆴"
                tooltipText: "Remove folder"
                foreground: root.fg
                fontFamily: root.fontFamily
                enabled: !actionProc.running
                onClicked: root.removeWallpaperFolder(index)
              }
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          visible: root.wallpaperDirsError.length > 0
          text: root.wallpaperDirsError
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Item { Layout.fillWidth: true }

          Button {
            text: "Cancel"
            foreground: root.fg
            bordered: true
            enabled: !root.savingWallpaperDirs
            onClicked: wallpaperDirsPopup.close()
          }

          Button {
            text: root.savingWallpaperDirs
              ? "Saving…" : "Save folders"
            iconText: "󰆓"
            foreground: root.fg
            accent: Color.accent
            active: true
            bordered: true
            enabled: !actionProc.running && !root.displayBusy && root.wallpaperDirsDirty
            onClicked: root.saveWallpaperFolders()
          }
        }
      }
    }
  }
}
