import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Per-display Wallpaper Engine settings — content of one monitor tab.
//
// CLI contract:
//   Load:  we display-config <mon> --json
//   Caps:  we list-properties <id> --json   (audio / mouse / property schema)
//   Save:  we set-display <mon> --wallpaper … --scaling … --fps … --clamp …
//            --silent|--audio --volume … [--noautomute] [--no-fullscreen-pause]
//            [--fullscreen-pause-only-active] [--fullscreen-pause-ignore-appids …]
//            [--no-audio-processing] [--disable-particles]
//            [--disable-mouse] [--disable-parallax] [--property k=v …]
//          Only --property keys listed for the *selected* wallpaper are sent.
//   Start: we apply <mon>
//   Stop:  we stop <mon>
//   Apply: we set-display <mon> … && we apply <mon>
//   Clear: we set-display <mon> --clear && we stop <mon>
//
// Panel contract:
//   property string displayName / weBin / pluginRoot
//   function reload()
//   signal applied() / refreshNeeded() / filterTextEdited(string)
//          / statusMessage(string)
Item {
  id: root

  property string displayName: ""
  property string weBin: ""
  property string pluginRoot: ""
  /** True while this tab is the visible StackLayout child. */
  property bool tabActive: false
  /** Panel busy (theme-wide action) — disable display actions inside the tab. */
  property bool panelBusy: false
  /** Live linux-wallpaperengine process (from panel status). */
  property bool engineRunning: false

  signal applied()
  signal refreshNeeded()
  signal editWallpaperFoldersRequested()
  signal filterTextEdited(string text)
  signal statusMessage(string text)
  signal loadFinished()
  signal errorOccurred(string message)
  signal actionBusyChanged(bool busy, string actionKind)

  // ---- Internal status -------------------------------------------------
  /** Shared Workshop catalog state supplied by Panel. */
  property bool loading: false
  property bool capsLoading: false
  property bool busy: false
  onBusyChanged: root.actionBusyChanged(busy, actionKind)
  property string localStatus: ""
  property string saveApplyStatus: ""
  property bool configured: false
  property bool hasWallpaper: false
  property string actionKind: ""
  property string wallpaperTitleBound: ""
  /** Monotonic version of user-authored draft changes. Config reads capture
      this value and may bind only if the draft has not changed meanwhile. */
  property int draftRevision: 0
  /** True while the controls contain changes not yet saved by Save & apply/Clear. */
  property bool draftDirty: false
  /** Draft revision captured by the current Save & apply/Clear transaction. */
  property int actionDraftRevision: 0
  /** Preserve a Save & apply click made while capabilities are loading. */
  property bool applyQueued: false
  property string queuedApplyWallpaperId: ""
  /** Coalesce reload requests that arrive while display-config is running. */
  property bool configReloadPending: false
  /** Remaining argv vectors after the current we step (set-display then apply). */
  property var actionQueue: []
  /** Bumps to cancel stale Qt.callLater starts after timeout / fail. */
  property int actionGen: 0

  // ---- Draft settings for this display ---------------------------------
  property string selectedWallpaperId: ""
  property string scaling: "fill"
  property int fps: 30
  property string clampMode: "border"
  property bool silent: true
  property int volume: 15
  property bool noautomute: false
  // Named engineLayer — Item.layer is FINAL in Qt Quick.
  property string engineLayer: "bottom"
  property bool noFullscreenPause: false
  property bool fullscreenPauseOnlyActive: false
  property string fullscreenPauseIgnoreAppIds: ""
  property bool noAudioProcessing: false
  property bool disableParticles: false
  property bool disableMouse: false
  property bool disableParallax: false
  property var properties: ({})
  /** Wallpaper id the current `properties` draft belongs to. */
  property string propertiesWallpaperId: ""
  property string propKey: ""
  property string propValue: ""
  readonly property bool actionsBlocked: busy || panelBusy

  property var wallpapers: []
  property string filterText: ""

  // Capability blob from `we list-properties <id> --json`
  property var wallpaperCaps: ({})
  property string capsWallpaperId: ""
  /** Wallpaper id the in-flight / latest caps request is for. */
  property string capsExpectedId: ""

  readonly property bool wallpaperSelected: String(selectedWallpaperId || "").length > 0
  readonly property bool hasAudio: !!(wallpaperCaps && wallpaperCaps.hasAudio)
  readonly property bool supportsMouse: !!(wallpaperCaps && wallpaperCaps.supportsMouse)
  readonly property bool supportsParallax: !!(wallpaperCaps && wallpaperCaps.supportsParallax)
  readonly property var listedProperties: {
    var caps = wallpaperCaps || ({})
    var list = caps.properties
    return (list && list.length !== undefined) ? list : []
  }
  readonly property bool hasListedProperties: listedProperties.length > 0
  readonly property string wallpaperTypeLabel: {
    var t = wallpaperCaps && wallpaperCaps.type ? String(wallpaperCaps.type) : ""
    return t.length ? t : ""
  }

  readonly property string resolvedPluginRoot: {
    if (pluginRoot && pluginRoot.length)
      return pluginRoot
    var url = Qt.resolvedUrl(".")
    return decodeURIComponent(String(url).replace(/^file:\/\//, "").replace(/\/$/, ""))
  }
  readonly property string resolvedWeBin: {
    if (weBin && weBin.length)
      return weBin
    return resolvedPluginRoot + "/bin/we"
  }

  readonly property color fg: Color.foreground
  readonly property color dim: Qt.darker(fg, 1.45)
  readonly property string fontFamily: Style.font.family
  readonly property var scalingOptions: ["fill", "fit", "stretch", "default"]
  readonly property var clampOptions: ["border", "clamp", "repeat"]
  readonly property var layerOptions: ["bottom", "top", "overlay"]
  readonly property var sectionBorder: Border.controlSpec("normal", fg, Color.accent)
  readonly property color sectionFill: Qt.rgba(fg.r, fg.g, fg.b, 0.03)

  readonly property var filteredWallpapers: {
    var q = String(filterText || "").trim().toLowerCase()
    var list = wallpapers || []
    if (!q.length) return list
    var out = []
    for (var i = 0; i < list.length; i++) {
      var w = list[i]
      var hay = (String(w.title || "") + " " + String(w.id || "")).toLowerCase()
      if (hay.indexOf(q) >= 0) out.push(w)
    }
    return out
  }

  readonly property string wallpaperTitle: {
    if (wallpaperTitleBound && wallpaperTitleBound.length
        && String(selectedWallpaperId).length)
      return wallpaperTitleBound
    var id = String(selectedWallpaperId || "")
    if (!id.length) return "None selected"
    for (var i = 0; i < wallpapers.length; i++) {
      if (String(wallpapers[i].id) === id) return wallpapers[i].title || id
    }
    return id
  }

  onSelectedWallpaperIdChanged: {
    var id = String(selectedWallpaperId || "")
    if (applyQueued && id !== String(queuedApplyWallpaperId || "")) {
      applyQueued = false
      queuedApplyWallpaperId = ""
    }
    // Drop the previous wallpaper's property bag immediately so Save & apply cannot
    // pass stale --set-property keys (config accumulates them across wallpapers).
    if (id !== String(propertiesWallpaperId || "")) {
      properties = ({})
      propertiesWallpaperId = id
      if (id !== String(capsWallpaperId || "")) {
        wallpaperCaps = ({})
        capsWallpaperId = ""
        capsLoading = !!id.length
      }
    }
    if (!id.length) {
      wallpaperCaps = ({})
      capsWallpaperId = ""
      capsExpectedId = ""
      capsLoading = false
      return
    }
    if (id !== String(capsWallpaperId || ""))
      capsDebounce.restart()
  }

  function setStatus(msg) {
    localStatus = msg || ""
    // Always forward so the panel can clear a stale error after a successful retry.
    root.statusMessage(localStatus)
  }

  function setError(msg) {
    setStatus(msg)
    if (msg && msg.length)
      root.errorOccurred(msg)
  }

  function markDraftEdited() {
    draftRevision += 1
    draftDirty = true
    saveApplyStatus = ""
  }

  function continueQueuedApply() {
    var configReadCurrent = !draftDirty && configProc.running
      && configProc.draftRevisionAtStart === draftRevision
    if (!applyQueued || capsLoading || configReadCurrent)
      return
    var queuedId = String(queuedApplyWallpaperId || "")
    applyQueued = false
    queuedApplyWallpaperId = ""
    if (!queuedId.length || queuedId !== String(selectedWallpaperId || ""))
      return
    Qt.callLater(function() {
      if (!root.actionsBlocked
          && queuedId === String(root.selectedWallpaperId || ""))
        root.applySettings()
    })
  }

  function reload() {
    if (!displayName || !displayName.length) return
    saveApplyStatus = ""
    setStatus("")
    loadDisplayConfig()
  }

  onDisplayNameChanged: {
    if (tabActive && displayName && displayName.length)
      Qt.callLater(reload)
  }
  onTabActiveChanged: {
    if (tabActive && displayName && displayName.length)
      Qt.callLater(reload)
  }
  Component.onCompleted: {
    if (tabActive && displayName && displayName.length)
      reload()
  }

  function loadDisplayConfig() {
    if (configProc.running) {
      configReloadPending = true
      return
    }
    configReloadPending = false
    configProc.draftRevisionAtStart = draftRevision
    configProc.bindAllowedAtStart = !draftDirty
    // Direct argv only. A login-shell Process on this hot path has previously
    // crashed omarchy-shell and can run arbitrary shell startup work.
    configProc.command = [resolvedWeBin, "display-config", displayName, "--json"]
    configWatchdog.restart()
    try {
      configProc.running = true
    } catch (e) {
      configWatchdog.stop()
      setError("Could not read display config")
    }
  }

  function loadWallpaperCapabilities(id) {
    var wid = String(id || "").trim()
    if (!wid.length) {
      wallpaperCaps = ({})
      capsWallpaperId = ""
      capsExpectedId = ""
      capsLoading = false
      return
    }
    capsExpectedId = wid
    capsWallpaperId = wid
    capsLoading = true
    // Restarting kills any in-flight request; its empty stdout must be ignored
    // (see capsProc handlers — they no-op while a newer run is already going).
    if (capsProc.running)
      capsProc.running = false
    capsProc.command = [resolvedWeBin, "list-properties", wid, "--json"]
    capsWatchdog.restart()
    try {
      capsProc.running = true
    } catch (e) {
      capsWatchdog.stop()
      capsLoading = false
      setError("Could not read wallpaper capabilities")
    }
  }

  function propValueFor(key, fallback) {
    var props = properties || ({})
    if (props[key] !== undefined && props[key] !== null && String(props[key]).length)
      return String(props[key])
    return fallback !== undefined && fallback !== null ? String(fallback) : ""
  }

  function setPropValue(key, value) {
    var k = String(key || "").trim()
    if (!k.length) return
    var next = ({})
    var keys = Object.keys(properties || ({}))
    for (var i = 0; i < keys.length; i++) next[keys[i]] = properties[keys[i]]
    next[k] = String(value)
    markDraftEdited()
    properties = next
  }

  // Keep only keys this wallpaper lists. Never carry keys from a previous id.
  function prunePropertiesToListed(schemaList, seedDefaults) {
    var list = schemaList || []
    var props = properties || ({})
    var next = ({})
    for (var j = 0; j < list.length; j++) {
      var p = list[j]
      if (!p || !p.key) continue
      var k = String(p.key)
      var cur = props[k]
      if (cur !== undefined && cur !== null && String(cur).length)
        next[k] = String(cur)
      else if (seedDefaults && p.value !== undefined && p.value !== null
               && String(p.value).length)
        next[k] = String(p.value)
    }
    properties = next
    propertiesWallpaperId = String(selectedWallpaperId || "")
  }

  function comboLabels(options) {
    var out = []
    var list = options || []
    for (var i = 0; i < list.length; i++) {
      var o = list[i]
      if (o && typeof o === "object")
        out.push({ value: String(o.value), label: String(o.label || o.value) })
      else
        out.push(String(o))
    }
    return out
  }

  function buildSetDisplayArgv() {
    var args = [
      resolvedWeBin, "set-display", displayName,
      "--wallpaper", String(selectedWallpaperId),
      "--scaling", String(scaling),
      "--fps", String(fps),
      "--clamp", String(clampMode),
      "--layer", String(engineLayer || "bottom")
    ]
    if (silent) {
      args.push("--silent")
    } else {
      args.push("--audio")
      args.push("--volume")
      args.push(String(volume))
    }
    args.push(noautomute ? "--noautomute" : "--automute")
    args.push(noFullscreenPause ? "--no-fullscreen-pause" : "--fullscreen-pause")
    args.push(fullscreenPauseOnlyActive
      ? "--fullscreen-pause-only-active" : "--fullscreen-pause-any")
    args.push("--fullscreen-pause-ignore-appids")
    args.push(String(fullscreenPauseIgnoreAppIds || ""))
    args.push(noAudioProcessing ? "--no-audio-processing" : "--audio-processing")
    args.push(disableParticles ? "--disable-particles" : "--particles")
    args.push(disableMouse ? "--disable-mouse" : "--mouse")
    args.push(disableParallax ? "--disable-parallax" : "--parallax")

    // Only keys this wallpaper lists — never the accumulated bag from prior ids.
    var list = listedProperties
    var props = properties || ({})
    for (var i = 0; i < list.length; i++) {
      var p = list[i]
      if (!p || !p.key) continue
      var k = String(p.key)
      var v = props[k]
      if (v === undefined || v === null || !String(v).length) {
        if (p.value !== undefined && p.value !== null && String(p.value).length)
          v = p.value
        else
          continue
      }
      args.push("--property", k + "=" + String(v))
    }
    return args
  }

  function failAction(msg) {
    if (!busy && !actionKind.length)
      return
    var failedKind = actionKind
    var failure = msg || "we failed"
    actionWatchdog.stop()
    startGuard.stop()
    actionQueue = []
    actionGen += 1
    var wasRunning = actionProc.running
    busy = false
    actionKind = ""
    if (wasRunning)
      actionProc.running = false
    if (failedKind === "apply")
      saveApplyStatus = failure
    setError(failure)
  }

  // Argv Process only — no bash -lc. Login-shell Process has crashed omarchy-shell
  // and can also sit forever without ever exec'ing we.
  function launchWe(argv) {
    if (!argv || !argv.length || !String(argv[0] || "").length) {
      failAction("we binary not found")
      return
    }
    actionWatchdog.stop()
    startGuard.stop()
    actionGen += 1
    var gen = actionGen
    actionProc.currentGen = gen
    if (actionProc.running)
      actionProc.running = false
    actionProc.lastStderr = ""
    actionProc.command = argv
    Qt.callLater(function() {
      if (gen !== root.actionGen || !root.busy)
        return
      try {
        actionProc.running = true
      } catch (e) {
        root.failAction("Could not start we")
        return
      }
      actionWatchdog.restart()
      startGuard.restart()
    })
  }

  function startWeChain(steps, kind, status) {
    if (!steps || !steps.length) {
      failAction("we binary not found")
      return
    }
    actionKind = kind
    busy = true
    actionQueue = steps.slice(1)
    setStatus(status || "")
    launchWe(steps[0])
  }

  function applySettings() {
    if (actionsBlocked || actionProc.running) return
    // The shell Button does not take focus on pointer clicks. Explicitly move
    // focus so editable SpinBoxes commit their current text before argv is read.
    root.forceActiveFocus(Qt.MouseFocusReason)
    if (!displayName || !displayName.length) {
      saveApplyStatus = "No display selected"
      setError("No display selected")
      return
    }
    if (!selectedWallpaperId || !String(selectedWallpaperId).length) {
      saveApplyStatus = "Select a wallpaper first"
      setError("Select a wallpaper first")
      return
    }
    var configReadCurrent = !draftDirty && configProc.running
      && configProc.draftRevisionAtStart === draftRevision
    if (capsLoading || configReadCurrent) {
      applyQueued = true
      queuedApplyWallpaperId = String(selectedWallpaperId)
      saveApplyStatus = "Save & apply queued…"
      setStatus(capsLoading
        ? "Loading wallpaper properties — Save & apply queued"
        : "Loading display settings — Save & apply queued")
      return
    }
    actionDraftRevision = draftRevision
    saveApplyStatus = "Applying…"
    startWeChain(
      [buildSetDisplayArgv(), [resolvedWeBin, "apply", displayName]],
      "apply",
      "Applying…")
  }

  function startDisplay() {
    if (actionsBlocked || actionProc.running) return
    if (!displayName || !displayName.length) {
      setError("No display selected")
      return
    }
    if (!configured || !hasWallpaper) {
      setError("Save a wallpaper for this display first")
      return
    }
    startWeChain(
      [[resolvedWeBin, "apply", displayName]],
      "start",
      "Starting " + displayName + "…")
  }

  function stopDisplay() {
    if (actionsBlocked || actionProc.running || !engineRunning) return
    if (!displayName || !displayName.length) return
    startWeChain(
      [[resolvedWeBin, "stop", displayName]],
      "stop",
      "Stopping " + displayName + "…")
  }

  function clearDisplay() {
    if (actionsBlocked || actionProc.running) return
    if (!displayName || !displayName.length) return
    actionDraftRevision = draftRevision
    startWeChain(
      [
        [resolvedWeBin, "set-display", displayName, "--clear"],
        [resolvedWeBin, "stop", displayName]
      ],
      "clear",
      "Clearing…")
  }

  function setCustomProperty() {
    if (actionsBlocked || actionProc.running) return
    var k = String(propKey || "").trim()
    var v = String(propValue || "").trim()
    if (!k.length || !v.length) {
      setError("Enter a property name and value")
      return
    }
    setPropValue(k, v)
    if (!displayName || !displayName.length) return
    startWeChain([[resolvedWeBin, "set-property", displayName, k, v]], "property", "")
  }

  function bindEffective(data) {
    if (!data || typeof data !== "object") return

    configured = !!data.configured
    hasWallpaper = !!data.hasWallpaper
      || !!(data.wallpaper !== undefined && data.wallpaper !== null && String(data.wallpaper).length)

    selectedWallpaperId = data.wallpaper !== undefined && data.wallpaper !== null
      ? String(data.wallpaper) : ""
    wallpaperTitleBound = data.wallpaperTitle ? String(data.wallpaperTitle) : ""
    scaling = String(data.scaling || "fill")
    fps = Number(data.fps) || 30
    clampMode = String(data.clamp || "border")
    silent = data.silent !== false
    volume = Number(data.volume)
    if (isNaN(volume)) volume = 15
    engineLayer = String(data.layer || "bottom")
    noFullscreenPause = !!data.noFullscreenPause
    fullscreenPauseOnlyActive = !!data.fullscreenPauseOnlyActive
    var ignoredApps = data.fullscreenPauseIgnoreAppIds
    fullscreenPauseIgnoreAppIds = (ignoredApps && ignoredApps.join)
      ? ignoredApps.join(", ") : String(ignoredApps || "")
    noautomute = !!data.noautomute
    noAudioProcessing = !!data.noAudioProcessing
    disableParticles = !!data.disableParticles
    disableMouse = !!data.disableMouse
    disableParallax = !!data.disableParallax

    var props = ({})
    var rawProps = data.properties
    if (rawProps && typeof rawProps === "object") {
      var keys = Object.keys(rawProps)
      for (var i = 0; i < keys.length; i++)
        props[keys[i]] = String(rawProps[keys[i]])
    }
    properties = props
    if (String(selectedWallpaperId || "") === String(capsWallpaperId || "")
        && wallpaperCaps && wallpaperCaps.properties)
      prunePropertiesToListed(wallpaperCaps.properties, false)

    if (selectedWallpaperId.length)
      capsDebounce.restart()
    else {
      wallpaperCaps = ({})
      capsWallpaperId = ""
    }
  }

  function parseConfigPayload(raw) {
    try {
      var data = JSON.parse(String(raw || "{}"))

      if (data && data.monitor !== undefined) {
        bindEffective(data)
        return
      }

      if (data && data.effectiveDisplays && typeof data.effectiveDisplays === "object") {
        var eff = data.effectiveDisplays[displayName]
        if (eff) {
          bindEffective(eff)
          return
        }
      }

      if (data && data.displays && typeof data.displays === "object") {
        var d = data.displays[displayName] || ({})
        var defs = data.defaults || ({})
        bindEffective({
          configured: !!(d.wallpaper !== undefined && d.wallpaper !== null && String(d.wallpaper).length),
          hasWallpaper: !!(d.wallpaper !== undefined && d.wallpaper !== null && String(d.wallpaper).length),
          wallpaper: d.wallpaper !== undefined ? d.wallpaper : "",
          scaling: (d.scaling !== undefined && d.scaling !== null && String(d.scaling).length) ? d.scaling : (defs.scaling || "fill"),
          fps: (d.fps !== undefined && d.fps !== null) ? d.fps : (defs.fps || 30),
          clamp: (d.clamp !== undefined && d.clamp !== null && String(d.clamp).length) ? d.clamp : (defs.clamp || "border"),
          silent: (d.silent !== undefined) ? d.silent : (defs.silent !== false),
          volume: (d.volume !== undefined && d.volume !== null) ? d.volume : (defs.volume || 15),
          layer: (d.layer !== undefined && d.layer !== null && String(d.layer).length) ? d.layer : (defs.layer || "bottom"),
          noFullscreenPause: (d.no_fullscreen_pause !== undefined) ? d.no_fullscreen_pause : !!defs.no_fullscreen_pause,
          fullscreenPauseOnlyActive: (d.fullscreen_pause_only_active !== undefined) ? d.fullscreen_pause_only_active : !!defs.fullscreen_pause_only_active,
          fullscreenPauseIgnoreAppIds: (d.fullscreen_pause_ignore_appids !== undefined) ? d.fullscreen_pause_ignore_appids : (defs.fullscreen_pause_ignore_appids || []),
          noautomute: (d.noautomute !== undefined) ? d.noautomute : !!defs.noautomute,
          noAudioProcessing: (d.no_audio_processing !== undefined) ? d.no_audio_processing : !!defs.no_audio_processing,
          disableParticles: (d.disable_particles !== undefined) ? d.disable_particles : !!defs.disable_particles,
          disableMouse: (d.disable_mouse !== undefined) ? d.disable_mouse : !!defs.disable_mouse,
          disableParallax: (d.disable_parallax !== undefined) ? d.disable_parallax : !!defs.disable_parallax,
          properties: d.properties || defs.properties || ({})
        })
        return
      }

      setError("Could not read display config")
    } catch (e) {
      setError("Could not read display config")
    }
  }

  function parseCapabilities(raw) {
    capsLoading = false
    try {
      var data = JSON.parse(String(raw || "{}"))
      if (!data || typeof data !== "object") {
        wallpaperCaps = ({})
        continueQueuedApply()
        return
      }
      // Ignore stale responses if selection changed mid-flight.
      if (String(data.id || "") !== String(selectedWallpaperId || "")
          && String(capsWallpaperId || "") !== String(selectedWallpaperId || "")) {
        return
      }
      wallpaperCaps = data
      // Clear a prior caps error once we have a valid blob for this wallpaper.
      if (String(data.id || "") === String(selectedWallpaperId || "")
          || String(capsWallpaperId || "") === String(selectedWallpaperId || "")) {
        if (localStatus.indexOf("wallpaper capabilities") >= 0
            || localStatus.indexOf("wallpaper properties") >= 0)
          setStatus("")
      }

      // Drop keys the new wallpaper does not list; seed missing from schema.
      prunePropertiesToListed(data.properties || [], true)
      continueQueuedApply()
    } catch (e) {
      wallpaperCaps = ({})
      setError("Could not read wallpaper properties")
      continueQueuedApply()
    }
  }

  Process {
    id: configProc
    property int draftRevisionAtStart: 0
    property bool bindAllowedAtStart: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // A late response must never replace a wallpaper or setting selected
        // after this display-config request started.
        if (!configProc.bindAllowedAtStart || root.draftDirty
            || configProc.draftRevisionAtStart !== root.draftRevision)
          return
        root.parseConfigPayload(text)
      }
    }
    onExited: function(code) {
      configWatchdog.stop()
      root.loadFinished()
      if (code !== 0 && root.tabActive)
        root.setError("Could not read display config")
      if (root.configReloadPending)
        Qt.callLater(root.loadDisplayConfig)
      root.continueQueuedApply()
    }
  }

  Process {
    id: capsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        capsWatchdog.stop()
        var t = String(text || "").trim()
        var want = String(root.capsExpectedId || "")
        var selected = String(root.selectedWallpaperId || "")

        // Superseded: selection moved on, or a newer request is already running.
        if (!want.length || want !== selected)
          return
        if (capsProc.running)
          return

        if (!t.length || t.charAt(0) !== "{") {
          root.capsLoading = false
          // Don't clobber good caps we already have for this wallpaper.
          if (root.wallpaperCaps
              && String(root.wallpaperCaps.id || "") === selected) {
            root.continueQueuedApply()
            return
          }
          if (root.wallpaperSelected)
            root.setError("Could not read wallpaper capabilities")
          root.continueQueuedApply()
          return
        }
        root.parseCapabilities(t)
      }
    }
    onExited: function(code) {
      capsWatchdog.stop()
      // Errors are owned by stdout handler (empty/non-JSON). A non-zero exit
      // from a killed restart must not paint a false failure over good data.
      if (capsProc.running)
        return
      if (code === 0)
        return
      if (String(root.capsExpectedId || "") !== String(root.selectedWallpaperId || ""))
        return
      if (root.wallpaperCaps
          && String(root.wallpaperCaps.id || "") === String(root.selectedWallpaperId || "")) {
        root.capsLoading = false
        root.continueQueuedApply()
        return
      }
      root.capsLoading = false
      if (root.wallpaperSelected)
        root.setError("Could not read wallpaper capabilities")
      root.continueQueuedApply()
    }
  }

  Process {
    id: actionProc
    property string lastStderr: ""
    property int currentGen: 0
    stdout: StdioCollector { waitForEnd: false }
    stderr: StdioCollector {
      waitForEnd: false
      onStreamFinished: actionProc.lastStderr = String(text || "").trim()
    }
    onStarted: startGuard.stop()
    onExited: function(code) {
      startGuard.stop()
      var exitCode = code
      var exitedGen = actionProc.currentGen
      // waitForEnd:false keeps inherited grandchild pipes from wedging the UI,
      // so defer completion long enough for the collector's final chunk.
      Qt.callLater(function() {
        Qt.callLater(function() {
          if (exitedGen !== actionProc.currentGen || actionProc.running)
            return
          // Watchdog / failAction already cleared busy and reported.
          if (!root.busy)
            return
          var queued = root.actionQueue || []
          if (exitCode === 0 && queued.length) {
            root.actionQueue = queued.slice(1)
            root.launchWe(queued[0])
            return
          }
          actionWatchdog.stop()
          root.actionQueue = []
          root.busy = false
          var kind = root.actionKind
          root.actionKind = ""
          var err = actionProc.lastStderr
          actionProc.lastStderr = ""
          if (exitCode === 0) {
            if ((kind === "apply" || kind === "clear")
                && root.actionDraftRevision === root.draftRevision)
              root.draftDirty = false
            if (kind === "apply") {
              var appliedMessage = root.engineRunning
                ? ("Applied to " + root.displayName)
                : ("Applied & started on " + root.displayName)
              root.saveApplyStatus = appliedMessage
              root.setStatus(appliedMessage)
            }
            else if (kind === "clear")
              root.setStatus("Cleared " + root.displayName)
            else if (kind === "start")
              root.setStatus("Started " + root.displayName)
            else if (kind === "stop")
              root.setStatus("Stopped " + root.displayName)
            else if (kind === "property")
              root.setStatus("Property saved — use Save & apply to go live")
            if (kind === "apply" || kind === "clear")
              root.applied()
            root.refreshNeeded()
            root.loadDisplayConfig()
          } else {
            var first = err.length ? err.split("\n")[0] : ""
            var failureMessage = "we failed"
            if (/Missing dependency:.*linux-wallpaperengine/i.test(first)
                || /linux-wallpaperengine-git/i.test(err)) {
              failureMessage = first + " — run: we doctor"
            } else if (kind === "apply") {
              failureMessage = first.length
                ? first
                : "Apply failed — check we doctor / engine.log"
            } else if (kind === "start") {
              failureMessage = first.length
                ? first
                : "Start failed — check we doctor / engine.log"
            } else if (first.length) {
              failureMessage = first
            } else {
              failureMessage = kind === "clear" ? "Clear failed"
                : (kind === "stop" ? "Stop failed" : "we failed")
            }
            if (kind === "apply")
              root.saveApplyStatus = failureMessage
            root.setError(failureMessage)
          }
        })
      })
    }
  }

  Timer {
    id: capsDebounce
    interval: 150
    repeat: false
    onTriggered: root.loadWallpaperCapabilities(root.selectedWallpaperId)
  }

  Timer {
    id: configWatchdog
    interval: 8000
    repeat: false
    onTriggered: {
      if (!configProc.running) return
      try { configProc.running = false } catch (e) {}
      root.setError("Display config timed out")
    }
  }

  Timer {
    id: capsWatchdog
    interval: 8000
    repeat: false
    onTriggered: {
      if (!capsProc.running) return
      try { capsProc.running = false } catch (e) {}
      root.capsLoading = false
      root.setError("Wallpaper capabilities timed out")
      root.continueQueuedApply()
    }
  }

  // Process.running can stay false with no onExited if spawn fails.
  Timer {
    id: startGuard
    interval: 800
    repeat: false
    onTriggered: {
      if (root.busy && !actionProc.running)
        root.failAction("we did not start")
    }
  }

  // First-frame rendering is bounded in the backend; keep a UI watchdog too.
  Timer {
    id: actionWatchdog
    interval: 90000
    repeat: false
    onTriggered: {
      if (root.busy)
        root.failAction(root.actionKind === "apply"
          ? "Apply timed out"
          : (root.actionKind === "start"
            ? "Start timed out"
            : (root.actionKind === "stop" ? "Stop timed out" : "Timed out waiting for we")))
    }
  }

  // ---- Layout: per-display lifecycle, then wallpaper browser | settings --
  BorderSurface {
      id: displayActions
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      color: root.sectionFill
      borderSpec: Border.controlSpec(
        root.engineRunning ? "selected" : "normal", root.fg, Color.accent)
      radius: Style.cornerRadius
      implicitHeight: displayActionsRow.implicitHeight + Style.space(20)

      RowLayout {
        id: displayActionsRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Style.space(10)
        spacing: Style.space(8)

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(2)

          Text {
            textFormat: Text.PlainText
            text: root.displayName
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: root.engineRunning
              ? "Wallpaper Engine is running on this display only."
              : (root.configured
                ? "A saved wallpaper is ready to start on this display."
                : "Choose a wallpaper below, then Save & apply.")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Button {
          id: startButton
          text: "Start"
          iconText: "󰐊"
          tooltipText: "Start the saved wallpaper on " + root.displayName
          foreground: root.fg
          accent: Color.accent
          active: !root.engineRunning && root.configured
          bordered: true
          visible: !root.engineRunning
          enabled: !root.actionsBlocked && root.displayName.length > 0
            && root.configured && root.hasWallpaper && !root.engineRunning
          onClicked: root.startDisplay()
        }

        Button {
          id: stopButton
          text: "Stop"
          iconText: "󰓛"
          tooltipText: "Stop Wallpaper Engine on " + root.displayName
          foreground: root.fg
          bordered: true
          visible: root.engineRunning
          enabled: !root.actionsBlocked && root.displayName.length > 0
            && root.engineRunning
          onClicked: root.stopDisplay()
        }
      }
    }

  RowLayout {
    anchors.top: displayActions.bottom
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.topMargin: Style.space(10)
    spacing: Style.space(18)

    // ---- Left: wallpaper picker ----------------------------------------
    BorderSurface {
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.preferredWidth: 1
      color: root.sectionFill
      borderSpec: root.sectionBorder
      radius: Style.cornerRadius

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.space(12)
        spacing: Style.space(8)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          PanelSectionHeader {
            Layout.fillWidth: true
            text: "WORKSHOP WALLPAPERS"
            foreground: root.fg
            fontFamily: root.fontFamily
            font.weight: Font.Black
          }

          Button {
            text: "Folders"
            iconText: "󰉖"
            tooltipText: "Manage wallpaper folders"
            foreground: root.fg
            fontFamily: root.fontFamily
            bordered: true
            enabled: !root.actionsBlocked && !root.loading
            onClicked: root.editWallpaperFoldersRequested()
          }
        }

        TextField {
          Layout.fillWidth: true
          placeholderText: "Filter by title or id"
          text: root.filterText
          foreground: root.fg
          font.family: root.fontFamily
          onTextEdited: root.filterTextEdited(text)
        }

        Text {
          textFormat: Text.PlainText
          visible: root.loading
          text: "Scanning Workshop…"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          textFormat: Text.PlainText
          visible: !root.loading && root.filteredWallpapers.length === 0
          text: "No wallpapers found. Subscribe in Steam Wallpaper Engine."
          color: root.dim
          wrapMode: Text.WordWrap
          Layout.fillWidth: true
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        ListView {
          id: wallpaperList
          readonly property bool hasVerticalOverflow: contentHeight > height + 0.5
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true
          spacing: Style.space(4)
          model: root.filteredWallpapers
          boundsBehavior: Flickable.StopAtBounds
          QQC.ScrollBar.vertical: QQC.ScrollBar {
            id: wallpaperScrollBar
            policy: wallpaperList.hasVerticalOverflow
              ? QQC.ScrollBar.AsNeeded
              : QQC.ScrollBar.AlwaysOff

            contentItem: Rectangle {
              implicitWidth: Style.space(6)
              implicitHeight: Style.space(32)
              radius: width / 2
              color: Color.accent
              opacity: wallpaperScrollBar.pressed || wallpaperScrollBar.hovered ? 1 : 0.82

              Behavior on opacity {
                NumberAnimation { duration: 100 }
              }
            }

            background: Item {}
          }

          delegate: BorderSurface {
            required property var modelData
            required property int index

            width: wallpaperList.width
            implicitHeight: Style.space(64)
            radius: Style.cornerRadius
            color: {
              var selected = String(root.selectedWallpaperId) === String(modelData.id)
              if (selected) return Style.selectedFillFor(root.fg, Color.accent)
              if (rowMouse.containsMouse) return Style.hoverFillFor(root.fg, Color.accent)
              return "transparent"
            }
            borderSpec: String(root.selectedWallpaperId) === String(modelData.id)
              ? Border.controlSpec("selected", root.fg, Color.accent)
              : Border.none()

            RowLayout {
              anchors.fill: parent
              anchors.margins: Style.space(6)
              spacing: Style.space(10)

              Rectangle {
                width: Style.space(52)
                height: Style.space(52)
                radius: Style.cornerRadius
                color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.08)
                clip: true

                Image {
                  id: previewImage
                  anchors.fill: parent
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  source: modelData.preview ? Util.fileUrl(modelData.preview) : ""
                  visible: status === Image.Ready
                }

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  visible: previewImage.status !== Image.Ready
                  text: "󰸉"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                }
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: modelData.title || modelData.id
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  text: modelData.id
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.markDraftEdited()
                root.selectedWallpaperId = String(modelData.id)
                root.wallpaperTitleBound = String(modelData.title || "")
              }
            }
          }
        }
      }
    }

    // ---- Right: settings -----------------------------------------------
    ColumnLayout {
      id: rightSettingsColumn
      Layout.fillWidth: true
      Layout.fillHeight: true
      Layout.preferredWidth: 1
      spacing: Style.space(10)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        PanelSectionHeader {
          Layout.fillWidth: true
          text: root.displayName.length
            ? ("SETTINGS · " + root.displayName)
            : "SETTINGS"
          foreground: root.fg
          fontFamily: root.fontFamily
        }

        PanelActionButton {
          iconText: "󰑐"
          tooltipText: "Reload this display"
          foreground: root.fg
          fontFamily: root.fontFamily
          enabled: !root.actionsBlocked && !configProc.running
          onClicked: {
            // An explicit reload intentionally discards the current draft.
            root.draftDirty = false
            root.reload()
          }
        }
      }

      Flickable {
        id: settingsFlick
        readonly property bool hasVerticalOverflow: contentHeight > height + 0.5
        Layout.fillWidth: true
        Layout.fillHeight: true
        clip: true
        contentWidth: width
        contentHeight: settingsColumn.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        QQC.ScrollBar.vertical: QQC.ScrollBar {
          id: settingsScrollBar
          policy: settingsFlick.hasVerticalOverflow
            ? QQC.ScrollBar.AsNeeded
            : QQC.ScrollBar.AlwaysOff

          contentItem: Rectangle {
            implicitWidth: Style.space(6)
            implicitHeight: Style.space(32)
            radius: width / 2
            color: Color.accent
            opacity: settingsScrollBar.pressed || settingsScrollBar.hovered ? 1 : 0.82

            Behavior on opacity {
              NumberAnimation { duration: 100 }
            }
          }

          background: Item {}
        }

        ColumnLayout {
          id: settingsColumn
          width: settingsFlick.width
          spacing: Style.space(10)

          // Empty state when nothing picked
          BorderSurface {
            visible: !root.wallpaperSelected
            Layout.fillWidth: true
            color: root.sectionFill
            borderSpec: root.sectionBorder
            radius: Style.cornerRadius
            implicitHeight: emptyCol.implicitHeight + Style.space(24)

            ColumnLayout {
              id: emptyCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(14)
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: "Pick a Workshop wallpaper"
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: "Select one on the left. Engine settings below always apply; audio and scene properties appear only when that wallpaper supports them."
                color: root.dim
                wrapMode: Text.WordWrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // Selected wallpaper summary
          BorderSurface {
            visible: root.wallpaperSelected
            Layout.fillWidth: true
            color: root.sectionFill
            borderSpec: root.sectionBorder
            radius: Style.cornerRadius
            implicitHeight: selectedCol.implicitHeight + Style.space(24)

            ColumnLayout {
              id: selectedCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(12)
              spacing: Style.space(6)

              PanelSectionHeader {
                text: "SELECTED WALLPAPER"
                foreground: root.fg
                fontFamily: root.fontFamily
              }
              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: root.wallpaperTitle
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: {
                  var parts = [String(root.selectedWallpaperId)]
                  if (root.wallpaperTypeLabel.length)
                    parts.push(root.wallpaperTypeLabel)
                  if (root.capsLoading)
                    parts.push("loading capabilities…")
                  else if (root.hasAudio)
                    parts.push("has audio")
                  return parts.join(" · ")
                }
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                visible: root.hasWallpaper
                text: "Editing saved settings for this display. Adjust, then Save & apply."
                color: root.dim
                wrapMode: Text.WordWrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // Engine / display settings — always visible
          BorderSurface {
            Layout.fillWidth: true
            color: root.sectionFill
            borderSpec: root.sectionBorder
            radius: Style.cornerRadius
            implicitHeight: engineCol.implicitHeight + Style.space(24)

            ColumnLayout {
              id: engineCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(12)
              spacing: Style.space(8)

              PanelSectionHeader {
                text: "DISPLAY / ENGINE"
                foreground: root.fg
                fontFamily: root.fontFamily
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: "Every setting in this tab is saved and launched only for " + root.displayName + "."
                color: root.dim
                wrapMode: Text.WordWrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Dropdown {
                Layout.fillWidth: true
                label: "Scaling"
                value: root.scaling
                options: root.scalingOptions
                foreground: root.fg
                onChanged: function(v) {
                  root.markDraftEdited()
                  root.scaling = v
                }
              }

              NumberField {
                Layout.fillWidth: true
                label: "FPS"
                value: root.fps
                from: 1
                to: 240
                foreground: root.fg
                onModified: function(v) {
                  root.markDraftEdited()
                  root.fps = v
                }
              }

              Dropdown {
                Layout.fillWidth: true
                label: "Clamp"
                value: root.clampMode
                options: root.clampOptions
                foreground: root.fg
                onChanged: function(v) {
                  root.markDraftEdited()
                  root.clampMode = v
                }
              }

              Dropdown {
                Layout.fillWidth: true
                label: "Wayland layer"
                value: root.engineLayer
                options: root.layerOptions
                foreground: root.fg
                onChanged: function(v) {
                  root.markDraftEdited()
                  root.engineLayer = v
                }
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: "Bottom is recommended for Omarchy. Top and overlay can cover desktop content."
                color: root.dim
                wrapMode: Text.WordWrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // Audio and audio-reactive processing
          BorderSurface {
            visible: root.wallpaperSelected
            Layout.fillWidth: true
            color: root.sectionFill
            borderSpec: root.sectionBorder
            radius: Style.cornerRadius
            implicitHeight: audioCol.implicitHeight + Style.space(24)

            ColumnLayout {
              id: audioCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(12)
              spacing: Style.space(8)

              PanelSectionHeader {
                text: "AUDIO"
                foreground: root.fg
                fontFamily: root.fontFamily
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: root.hasAudio
                  ? "Audio settings apply only to this display's wallpaper process."
                  : "This wallpaper does not advertise playback audio; audio-reactive processing can still be controlled."
                color: root.dim
                wrapMode: Text.WordWrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Toggle {
                Layout.fillWidth: true
                label: "Mute wallpaper audio"
                description: "Uses --silent. Unmute to set --volume."
                checked: root.silent
                foreground: root.fg
                onClicked: {
                  root.markDraftEdited()
                  root.silent = !root.silent
                }
              }

              NumberField {
                visible: !root.silent
                label: "Volume"
                value: root.volume
                from: 0
                to: 100
                foreground: root.fg
                onModified: function(v) {
                  root.markDraftEdited()
                  root.volume = v
                }
              }

              Toggle {
                Layout.fillWidth: true
                label: "Disable automute"
                description: "Keep wallpaper audio when other apps play sound (--noautomute)."
                checked: root.noautomute
                foreground: root.fg
                onClicked: {
                  root.markDraftEdited()
                  root.noautomute = !root.noautomute
                }
              }

              Toggle {
                Layout.fillWidth: true
                label: "Disable audio processing"
                description: "Turns off audio-reactive wallpaper features (--no-audio-processing)."
                checked: root.noAudioProcessing
                foreground: root.fg
                onClicked: {
                  root.markDraftEdited()
                  root.noAudioProcessing = !root.noAudioProcessing
                }
              }
            }
          }

          // Wallpaper --set-property controls from schema
          BorderSurface {
            visible: root.wallpaperSelected && root.hasListedProperties
            Layout.fillWidth: true
            color: root.sectionFill
            borderSpec: root.sectionBorder
            radius: Style.cornerRadius
            implicitHeight: propsCol.implicitHeight + Style.space(24)

            ColumnLayout {
              id: propsCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(12)
              spacing: Style.space(8)

              PanelSectionHeader {
                text: "WALLPAPER PROPERTIES"
                foreground: root.fg
                fontFamily: root.fontFamily
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: "From project.json / --list-properties. Passed as --set-property on Save & apply. No global speed flag."
                color: root.dim
                wrapMode: Text.WordWrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Repeater {
                model: root.listedProperties

                delegate: ColumnLayout {
                  required property var modelData
                  Layout.fillWidth: true
                  spacing: Style.space(4)

                  // bool
                  Toggle {
                    visible: String(modelData.type || "").toLowerCase() === "bool"
                    Layout.fillWidth: true
                    label: modelData.label || modelData.key
                    checked: {
                      var v = root.propValueFor(modelData.key, modelData.value)
                      return v === "true" || v === "1" || v === "True"
                    }
                    foreground: root.fg
                    onClicked: {
                      var cur = root.propValueFor(modelData.key, modelData.value)
                      var on = cur === "true" || cur === "1" || cur === "True"
                      root.setPropValue(modelData.key, on ? "false" : "true")
                    }
                  }

                  // combo
                  Dropdown {
                    visible: String(modelData.type || "").toLowerCase() === "combo"
                    Layout.fillWidth: true
                    label: modelData.label || modelData.key
                    value: root.propValueFor(modelData.key, modelData.value)
                    options: root.comboLabels(modelData.options)
                    foreground: root.fg
                    onChanged: function(v) { root.setPropValue(modelData.key, v) }
                  }

                  // slider (integer range → NumberField; else text)
                  NumberField {
                    visible: {
                      var t = String(modelData.type || "").toLowerCase()
                      if (t !== "slider") return false
                      var mn = modelData.min
                      var mx = modelData.max
                      if (mn === undefined || mn === null || mx === undefined || mx === null)
                        return false
                      var step = Number(modelData.step)
                      return (!isFinite(step) || step >= 1)
                        && Number(mn) === Math.floor(Number(mn))
                        && Number(mx) === Math.floor(Number(mx))
                    }
                    label: (modelData.label || modelData.key)
                      + (modelData.min !== undefined && modelData.max !== undefined
                        ? (" (" + modelData.min + "–" + modelData.max + ")")
                        : "")
                    value: {
                      var n = Number(root.propValueFor(modelData.key, modelData.value))
                      return isFinite(n) ? Math.round(n) : Math.round(Number(modelData.value) || 0)
                    }
                    from: Math.round(Number(modelData.min) || 0)
                    to: Math.round(Number(modelData.max) || 100)
                    foreground: root.fg
                    onModified: function(v) { root.setPropValue(modelData.key, v) }
                  }

                  // text / color / fractional slider
                  ColumnLayout {
                    visible: {
                      var t = String(modelData.type || "").toLowerCase()
                      if (t === "bool" || t === "combo") return false
                      if (t === "slider") {
                        var mn = modelData.min
                        var mx = modelData.max
                        if (mn === undefined || mn === null || mx === undefined || mx === null)
                          return true
                        var step = Number(modelData.step)
                        var intish = (!isFinite(step) || step >= 1)
                          && Number(mn) === Math.floor(Number(mn))
                          && Number(mx) === Math.floor(Number(mx))
                        return !intish
                      }
                      return true
                    }
                    Layout.fillWidth: true
                    spacing: Style.space(2)

                    Text {
                      textFormat: Text.PlainText
                      text: {
                        var label = modelData.label || modelData.key
                        var t = String(modelData.type || "")
                        var range = ""
                        if (modelData.min !== undefined && modelData.min !== null
                            && modelData.max !== undefined && modelData.max !== null)
                          range = " · " + modelData.min + "–" + modelData.max
                        return label + (t.length ? (" (" + t + ")" + range) : range)
                      }
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    TextField {
                      Layout.fillWidth: true
                      text: root.propValueFor(modelData.key, modelData.value)
                      foreground: root.fg
                      font.family: root.fontFamily
                      // Commit on every user edit. Action buttons are not
                      // focusable, so focus loss is not a reliable commit.
                      onTextEdited: root.setPropValue(modelData.key, text)
                    }
                  }
                }
              }
            }
          }

          // Advanced
          BorderSurface {
            visible: root.wallpaperSelected
            Layout.fillWidth: true
            color: root.sectionFill
            borderSpec: root.sectionBorder
            radius: Style.cornerRadius
            implicitHeight: advCol.implicitHeight + Style.space(24)

            ColumnLayout {
              id: advCol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(12)
              spacing: Style.space(8)

              PanelSectionHeader {
                text: "ADVANCED"
                foreground: root.fg
                fontFamily: root.fontFamily
              }

              Toggle {
                Layout.fillWidth: true
                label: "Keep playing when fullscreen"
                description: "Do not pause this display's wallpaper for fullscreen apps."
                checked: root.noFullscreenPause
                foreground: root.fg
                onClicked: {
                  root.markDraftEdited()
                  root.noFullscreenPause = !root.noFullscreenPause
                }
              }

              Toggle {
                Layout.fillWidth: true
                enabled: !root.noFullscreenPause
                label: "Pause only for the active fullscreen app"
                description: "Wayland-only. Ignores fullscreen windows that are not active."
                checked: root.fullscreenPauseOnlyActive
                foreground: root.fg
                onClicked: {
                  root.markDraftEdited()
                  root.fullscreenPauseOnlyActive = !root.fullscreenPauseOnlyActive
                }
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  text: "Ignore fullscreen app IDs"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                TextField {
                  Layout.fillWidth: true
                  enabled: !root.noFullscreenPause
                  placeholderText: "comma-separated app_id fragments"
                  text: root.fullscreenPauseIgnoreAppIds
                  foreground: root.fg
                  font.family: root.fontFamily
                  onTextEdited: {
                    root.markDraftEdited()
                    root.fullscreenPauseIgnoreAppIds = text
                  }
                }
              }

              Toggle {
                Layout.fillWidth: true
                label: "Disable particles"
                description: "Skips scene particle systems (--disable-particles)."
                checked: root.disableParticles
                foreground: root.fg
                onClicked: {
                  root.markDraftEdited()
                  root.disableParticles = !root.disableParticles
                }
              }

              Toggle {
                Layout.fillWidth: true
                label: "Disable mouse interaction"
                description: root.supportsMouse
                  ? "Turns off wallpaper mouse input."
                  : "Available even though this wallpaper does not advertise mouse support."
                checked: root.disableMouse
                foreground: root.fg
                onClicked: {
                  root.markDraftEdited()
                  root.disableMouse = !root.disableMouse
                }
              }

              Toggle {
                Layout.fillWidth: true
                label: "Disable parallax"
                description: root.supportsParallax
                  ? "Turns off cursor-driven parallax."
                  : "Available even though this wallpaper does not advertise parallax support."
                checked: root.disableParallax
                foreground: root.fg
                onClicked: {
                  root.markDraftEdited()
                  root.disableParallax = !root.disableParallax
                }
              }

              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: "Custom property (optional)"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              RowLayout {
                Layout.fillWidth: true
                spacing: Style.space(8)

                TextField {
                  Layout.preferredWidth: Style.space(100)
                  placeholderText: "key"
                  text: root.propKey
                  foreground: root.fg
                  font.family: root.fontFamily
                  onTextChanged: root.propKey = text
                }

                TextField {
                  Layout.fillWidth: true
                  placeholderText: "value"
                  text: root.propValue
                  foreground: root.fg
                  font.family: root.fontFamily
                  onTextChanged: root.propValue = text
                }

                Button {
                  text: "Set"
                  foreground: root.fg
                  bordered: true
                  enabled: !root.actionsBlocked && root.displayName.length > 0
                  onClicked: root.setCustomProperty()
                }
              }
            }
          }

        }
      }

      // Fixed right-side footer — a sibling of settingsFlick so it stays
      // visible while only the settings content scrolls above it.
      BorderSurface {
        id: fixedSaveActions
        Layout.fillWidth: true
        color: root.sectionFill
        borderSpec: Border.controlSpec(
          root.wallpaperSelected ? "selected" : "normal", root.fg, Color.accent)
        radius: Style.cornerRadius
        implicitHeight: actionsCol.implicitHeight + Style.space(24)

        ColumnLayout {
          id: actionsCol
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(12)
          spacing: Style.space(8)

          PanelSectionHeader {
            text: "SAVE SETTINGS"
            foreground: root.fg
            fontFamily: root.fontFamily
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            Button {
              id: saveApplyButton
              text: root.saveApplyStatus.length
                ? root.saveApplyStatus
                : "Save & apply"
              iconText: "󰐊"
              foreground: root.fg
              accent: Color.accent
              bordered: true
              enabled: !root.actionsBlocked && root.displayName.length > 0
                && root.wallpaperSelected
              Layout.fillWidth: true
              onClicked: root.applySettings()
            }

          }

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            visible: !root.busy && !root.wallpaperSelected
            text: "Select a wallpaper, then Save & apply to update and start this display."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            visible: root.wallpaperSelected && !root.engineRunning
            text: "Saves these settings and starts this display only. Other displays remain unchanged."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
