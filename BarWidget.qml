import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Thin bar launcher for the Wallpaper Engine Quickshell panel.
// Plugin kinds include panel, so summon/hide go through the panel loader —
// not Bar.findPanelWidget (that path is only for bar-widget-only plugins).
BarWidget {
  id: root
  moduleName: "io.github.14brussell.wallpaper-engine"

  property bool engineActive: false
  property bool revertBusy: false
  property string revertError: ""

  readonly property string pluginRoot: {
    var url = Qt.resolvedUrl(".")
    return decodeURIComponent(String(url).replace(/^file:\/\//, "").replace(/\/$/, ""))
  }
  readonly property string weBin: root.pluginRoot + "/bin/we"
  readonly property string pluginId: root.moduleName || "io.github.14brussell.wallpaper-engine"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function syncActiveFlag() {
    try {
      root.engineActive = String(activeFlag.text() || "").trim() === "true"
    } catch (e) {
      root.engineActive = false
    }
  }

  function togglePanel() {
    if (root.bar && root.bar.shell && typeof root.bar.shell.toggle === "function") {
      root.bar.shell.toggle(root.pluginId, "{}")
      return
    }
    if (!root.bar) return
    root.bar.run("omarchy-shell shell toggle " + Util.shellQuote(root.pluginId))
  }

  function revertTheme() {
    if (!root.weBin.length || revertProc.running) return
    revertError = ""
    revertBusy = true
    revertProc.command = [root.weBin, "revert"]
    try {
      revertProc.running = true
    } catch (e) {
      revertBusy = false
      notifyRevertFailure("Could not start the theme restore")
    }
  }

  function notifyRevertFailure(detail) {
    var body = String(detail || "Run we doctor for details").replace(/[\r\n]+/g, " ").trim()
    if (body.length > 160) body = body.slice(0, 157) + "…"
    revertError = body
    Quickshell.execDetached([
      "omarchy-notification-send",
      "--app-name", "Wallpaper Engine",
      "-g", "󰕍",
      "-u", "critical",
      "-t", "7000",
      "Wallpaper theme restore failed",
      body
    ])
  }

  function openAdvancedTui() {
    if (!root.bar) return
    root.bar.run("omarchy-launch-tui --app-id=org.omarchy.wallpaper-engine "
      + Util.shellQuote(root.pluginRoot + "/scripts/we-menu"))
  }

  function triggerPress(buttonCode) {
    if (buttonCode === Qt.RightButton) {
      revertTheme()
      return
    }
    if (buttonCode === Qt.MiddleButton) {
      openAdvancedTui()
      return
    }
    togglePanel()
  }

  Process {
    id: revertProc
    property string lastStderr: ""
    stdout: StdioCollector { waitForEnd: false }
    stderr: StdioCollector {
      waitForEnd: false
      onStreamFinished: revertProc.lastStderr = String(text || "").trim()
    }
    onExited: function(code) {
      root.revertBusy = false
      if (code === 0) {
        root.revertError = ""
        return
      }
      var first = revertProc.lastStderr.length
        ? revertProc.lastStderr.split("\n")[0]
        : "Revert exited with status " + code
      root.notifyRevertFailure(first)
    }
  }

  FileView {
    id: activeFlag
    path: {
      var home = Quickshell.env("HOME")
      return home + "/.local/state/omarchy/wallpaper-engine/active"
    }
    watchChanges: true
    printErrors: false
    onLoaded: root.syncActiveFlag()
    onFileChanged: reload()
    onLoadFailed: root.engineActive = false
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰸉"
    slotSize: Style.bar.statusSlot
    active: root.engineActive
    activeColor: Color.accent
    tooltipText: {
      var state = root.engineActive ? "Wallpaper Engine active" : "Wallpaper Engine stopped"
      var actions = "left: toggle panel, right: revert theme, middle: advanced TUI"
      if (root.revertBusy) return state + " — restoring theme…"
      if (root.revertError.length) return state + " — restore failed: " + root.revertError
      return state + " — " + actions
    }

    onPressed: function (b) {
      root.triggerPress(b)
    }
  }
}
