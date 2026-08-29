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
  moduleName: "wallpaper-engine-omarchy"

  property bool engineActive: false

  readonly property string pluginRoot: {
    var url = Qt.resolvedUrl(".")
    return decodeURIComponent(String(url).replace(/^file:\/\//, "").replace(/\/$/, ""))
  }
  readonly property string weBin: root.pluginRoot + "/bin/we"
  readonly property string pluginId: root.moduleName || "wallpaper-engine-omarchy"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function syncActiveFlag() {
    try {
      root.engineActive = String(activeFlag.text() || "").trim() === "true"
    } catch (e) {
      root.engineActive = false
    }
  }

  function openPanel() {
    // Summon (always show), never toggle — a second left-click must not close.
    if (root.bar && root.bar.shell && typeof root.bar.shell.summon === "function") {
      root.bar.shell.summon(root.pluginId)
      return
    }
    if (!root.bar) return
    root.bar.run("omarchy-shell shell summon " + Util.shellQuote(root.pluginId))
  }

  function revertTheme() {
    if (!root.weBin.length) return
    Util.execArgv([root.weBin, "revert"])
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
    openPanel()
  }

  FileView {
    id: activeFlag
    path: {
      var state = Quickshell.env("XDG_STATE_HOME")
      var home = Quickshell.env("HOME")
      var base = (state && state.length) ? state : (home + "/.local/state")
      return base + "/omarchy/wallpaper-engine/active"
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
    tooltipText: root.engineActive
      ? "Wallpaper Engine active — left: summon panel, right: revert, middle: advanced TUI"
      : "Wallpaper Engine — left: summon panel, right: revert"

    onPressed: function (b) {
      root.triggerPress(b)
    }
  }
}
