import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Singleton state owner for the plugin. The shell loads one of these per
// session (kind "service"), so it is the only sane place to keep vibrance
// state: a bar widget is instantiated once per monitor, and three copies of
// the panel each spawning their own nvibrant would fight each other.
//
// nvibrant has no query mode. It takes one positional value per display index,
// clamps to -1024..1023, and prints the resulting table — which is also the
// only way to enumerate displays. Two consequences shape everything below:
//
//   1. Changing one display means re-sending *every* display's value, so this
//      service owns the full array and treats it as the source of truth.
//   2. Enumerating is itself a write, so the values we hold must be persisted
//      and re-applied at startup, or a shell restart would silently flatten
//      the user's vibrance back to zero.
Item {
  id: root

  // Injected by the shell when the service is constructed.
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  readonly property string pluginId: "com.github.marvreichmann.omavibrance"
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy"
  readonly property string statePath: stateDir + "/omavibrance.json"

  // ------------------------------------------------------------------ state

  // Parsed rows from the last invocation, in index order. Includes disconnected
  // indices: they still need a positional placeholder to keep later displays
  // aligned, so the panel filters them out rather than the service.
  property var displays: []
  property string driverVersion: ""

  // Desired raw value per display index. Longer than `displays` on first run
  // (restored before we know the display count) and trimmed once we do.
  property var values: []

  // The snapshot behind Save/Restore. Empty until the user pins one.
  property var saved: []

  // User-assigned display names, keyed by nvibrant index (as a string, since
  // that is what survives a JSON round-trip).
  property var names: ({})

  // Hyprland outputs, used to put a make and model against an index.
  property var monitors: []
  property var monitorsByIndex: ({})

  property bool nvibrantMissing: false
  property string lastError: ""
  readonly property bool busy: applyProc.running
  readonly property bool hasSnapshot: saved.length > 0

  readonly property var connectedDisplays: {
    var out = []
    for (var i = 0; i < displays.length; i++) if (displays[i].connected) out.push(displays[i])
    // Left to right across the desk, so the rows read in the order the
    // monitors physically sit. Unmatched rows sort last, in index order.
    var map = monitorsByIndex
    out.sort(function(a, b) {
      var ma = map[a.index]
      var mb = map[b.index]
      var xa = ma ? ma.x : Number.MAX_VALUE
      var xb = mb ? mb.x : Number.MAX_VALUE
      return xa !== xb ? xa - xb : a.index - b.index
    })
    return out
  }

  function valueFor(index) {
    var v = values[index]
    return v === undefined ? 0 : Model.clampRaw(v)
  }

  function percentFor(index) {
    return Model.rawToPercent(valueFor(index))
  }

  function monitorFor(index) {
    return monitorsByIndex[index] || null
  }

  function nameFor(index) {
    var n = names[String(index)]
    return n === undefined || n === null ? "" : String(n)
  }

  function setName(index, name) {
    var next = ({})
    for (var k in names) next[k] = names[k]
    var trimmed = String(name || "").replace(/^\s+|\s+$/g, "")
    if (trimmed === "") delete next[String(index)]
    else next[String(index)] = trimmed
    names = next
    saveTimer.restart()
  }

  // --------------------------------------------------------------- applying

  // One process at a time. A slider drag would otherwise queue dozens of
  // overlapping nvibrant invocations whose completion order decides the final
  // vibrance — the last one to *finish* wins, not the last one requested.
  // Coalescing to a single pending re-run keeps the newest request authoritative
  // however far behind the process gets.
  property bool applyQueued: false

  // While an identify pulse runs, one index is driven to a value that is not
  // its stored one. Kept separate from `values` so the slider does not lurch
  // around and nothing about the pulse gets persisted.
  property int identifyIndex: -1
  property int identifyValue: 0

  function effectiveValue(index) {
    return (identifyIndex === index) ? identifyValue : valueFor(index)
  }

  function apply() {
    if (nvibrantMissing) return
    if (applyProc.running) {
      applyQueued = true
      return
    }

    // Before the first successful run we don't know the display count. Passing
    // no arguments enumerates (and sets everything to zero, which is the driver
    // default anyway); afterwards we always send the full array.
    var args = [binaryPath]
    for (var i = 0; i < displays.length; i++) args.push(String(effectiveValue(i)))

    applyProc.command = args
    applyProc.running = true
  }

  function setVibranceRaw(index, raw) {
    var next = values.slice()
    while (next.length <= index) next.push(0)
    next[index] = Model.clampRaw(raw)
    values = next
    saveTimer.restart()
    apply()
  }

  function setVibrancePercent(index, percent) {
    setVibranceRaw(index, Model.percentToRaw(percent))
  }

  function resetAll() {
    var next = []
    for (var i = 0; i < displays.length; i++) next.push(0)
    values = next
    saveTimer.restart()
    apply()
  }

  // A plain re-apply: nvibrant reports the current table on every invocation,
  // so re-sending what we already hold is both the refresh and a no-op write.
  function refresh() {
    apply()
    readMonitors()
  }

  // ------------------------------------------------------- save and restore

  // Live values are persisted continuously, so nothing is ever lost across a
  // restart. These two are the explicit layer on top: a snapshot the user pins
  // deliberately and can come back to after experimenting.
  function saveSnapshot() {
    var next = []
    for (var i = 0; i < displays.length; i++) next.push(valueFor(i))
    saved = next
    saveTimer.restart()
  }

  function restoreSnapshot() {
    if (saved.length === 0) return
    values = saved.slice()
    saveTimer.restart()
    apply()
  }

  // ---------------------------------------------------------- identify

  // Swings one display between fully desaturated and fully saturated a few
  // times. Correlating nvibrant indices with Hyprland outputs is a heuristic,
  // so this is how the user confirms which physical monitor a row drives.
  function identify(index) {
    if (nvibrantMissing) return
    identifyIndex = index
    identifyStep = 0
    identifyTimer.restart()
    identifyTick()
  }

  function stopIdentify() {
    identifyTimer.stop()
    identifyIndex = -1
    apply()
  }

  property int identifyStep: 0
  readonly property int identifyPulses: 6

  function identifyTick() {
    if (identifyIndex < 0) return
    if (identifyStep >= identifyPulses) {
      stopIdentify()
      return
    }
    // Grayscale then oversaturated: visible on any content, and on any
    // starting value, unlike a swing relative to the display's own setting.
    identifyValue = (identifyStep % 2 === 0) ? Model.MIN_RAW : Model.MAX_RAW
    identifyStep = identifyStep + 1
    apply()
  }

  Timer {
    id: identifyTimer
    interval: 260
    repeat: true
    onTriggered: root.identifyTick()
  }

  // ------------------------------------------------------------- processes

  Process {
    id: applyProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.consumeOutput(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.lastStderr = String(text || "").trim()
    }

    onExited: function(exitCode) {
      if (exitCode !== 0) {
        // The resolved binary is one of nvibrant's bundled per-driver builds,
        // reached without its Python launcher. If it will not run — not
        // executable in this install, wrong driver — fall back to the launcher
        // once rather than leaving the plugin dead.
        if (root.usingDirectBinary) {
          console.warn("omavibrance: direct binary failed, falling back to the nvibrant launcher")
          root.usingDirectBinary = false
          root.binaryPath = "nvibrant"
          root.lastStderr = ""
          Qt.callLater(root.apply)
          return
        }
        root.lastError = root.lastStderr !== ""
          ? root.lastStderr
          : "nvibrant exited with code " + exitCode
        console.warn("omavibrance: " + root.lastError)
      } else {
        root.lastError = ""
      }
      root.lastStderr = ""

      // Only re-run for a request that arrived while this one was in flight.
      // Re-running unconditionally here is what turned the previous version
      // into an infinite respawn loop that also reset vibrance on every pass.
      if (root.applyQueued) {
        root.applyQueued = false
        Qt.callLater(root.apply)
      }
    }
  }

  property string lastStderr: ""

  function consumeOutput(text) {
    var parsed = Model.parseOutput(text)
    if (parsed.displays.length === 0) return

    root.driverVersion = parsed.driver
    root.displays = parsed.displays

    // First run, or the display count changed (monitor hotplug). Trust the
    // table for indices we have no stored preference for, and drop stored
    // values for indices that no longer exist.
    var next = []
    for (var i = 0; i < parsed.displays.length; i++) {
      next.push(root.values[i] === undefined ? parsed.displays[i].raw : Model.clampRaw(root.values[i]))
    }
    root.values = next
    root.correlate()
  }

  // ------------------------------------------------------- binary detection

  // `nvibrant` on PATH is a Python launcher that picks a bundled binary for the
  // running driver and execs it. That indirection costs ~28ms of interpreter
  // startup on every call, which is most of the latency of a slider drag, so
  // the launcher is asked once for the path and the binary is called directly
  // from then on.
  property string binaryPath: "nvibrant"
  property bool usingDirectBinary: false

  Process {
    id: whichProc
    command: ["which", "nvibrant"]
    onExited: function(exitCode) {
      root.nvibrantMissing = (exitCode !== 0)
      if (root.nvibrantMissing) {
        root.lastError = "nvibrant is not installed or not on PATH"
        console.warn("omavibrance: " + root.lastError)
        return
      }
      resolveProc.running = true
    }
  }

  Process {
    id: resolveProc
    command: ["python3", "-c", "import nvibrant, sys; sys.stdout.write(str(nvibrant.get_best()[1]))"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var path = String(text || "").replace(/^\s+|\s+$/g, "")
        if (path !== "") {
          root.binaryPath = path
          root.usingDirectBinary = true
        }
      }
    }
    onExited: {
      // Whatever the outcome, this is the first point at which it is safe to
      // invoke nvibrant: either directly, or via the launcher on PATH.
      root.readMonitors()
      root.apply()
    }
  }

  // ---------------------------------------------------------- hyprland

  function readMonitors() {
    if (monitorsProc.running) return
    monitorsProc.running = true
  }

  function correlate() {
    root.monitorsByIndex = Model.correlateMonitors(root.displays, root.monitors)
  }

  Process {
    id: monitorsProc
    command: ["hyprctl", "-j", "monitors"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.monitors = Model.parseMonitors(text)
        root.correlate()
      }
    }
  }

  // ------------------------------------------------------------ persistence

  property bool stateLoaded: false

  function loadState(text) {
    try {
      var parsed = JSON.parse(text)
      if (parsed) {
        if (Array.isArray(parsed.values)) {
          var next = []
          for (var i = 0; i < parsed.values.length; i++) next.push(Model.clampRaw(parsed.values[i]))
          root.values = next
        }
        // Absent in version 1 files; an empty snapshot simply leaves Restore
        // disabled until the user pins one.
        if (Array.isArray(parsed.saved)) {
          var snap = []
          for (var j = 0; j < parsed.saved.length; j++) snap.push(Model.clampRaw(parsed.saved[j]))
          root.saved = snap
        }
        if (parsed.names && typeof parsed.names === "object") {
          var n = ({})
          for (var k in parsed.names) n[String(k)] = String(parsed.names[k])
          root.names = n
        }
      }
    } catch (e) {
      // A corrupt or absent file just means "no preferences yet". Starting
      // from the table nvibrant reports is a correct fallback.
    }
    root.stateLoaded = true
    whichProc.running = true
  }

  function flushState() {
    if (!stateLoaded) return
    stateFile.setText(JSON.stringify({
      version: 2,
      values: root.values,
      saved: root.saved,
      names: root.names
    }, null, 2) + "\n")
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadState(text())
    // First run: the file doesn't exist. Without this branch `stateLoaded`
    // never flips, so nothing is ever written and nothing is ever probed.
    onLoadFailed: root.loadState("")
  }

  Timer {
    id: saveTimer
    interval: 400
    repeat: false
    onTriggered: root.flushState()
  }
}
