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

  property bool nvibrantMissing: false
  property string lastError: ""
  readonly property bool busy: applyProc.running

  readonly property var connectedDisplays: {
    var out = []
    for (var i = 0; i < displays.length; i++) if (displays[i].connected) out.push(displays[i])
    return out
  }

  function valueFor(index) {
    var v = values[index]
    return v === undefined ? 0 : Model.clampRaw(v)
  }

  function percentFor(index) {
    return Model.rawToPercent(valueFor(index))
  }

  // --------------------------------------------------------------- applying

  // One process at a time. A slider drag would otherwise queue dozens of
  // overlapping nvibrant invocations whose completion order decides the final
  // vibrance — the last one to *finish* wins, not the last one requested.
  // Coalescing to a single pending re-run keeps the newest request authoritative
  // however far behind the process gets.
  property bool applyQueued: false

  function apply() {
    if (nvibrantMissing) return
    if (applyProc.running) {
      applyQueued = true
      return
    }

    // Before the first successful run we don't know the display count. Passing
    // no arguments enumerates (and sets everything to zero, which is the driver
    // default anyway); afterwards we always send the full array.
    var args = ["nvibrant"]
    for (var i = 0; i < displays.length; i++) args.push(String(valueFor(i)))

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
  }

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
  }

  // ------------------------------------------------------- binary detection

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
      // Only now is it safe to invoke it — apply() is a no-op while the
      // binary is presumed missing.
      root.apply()
    }
  }

  // ------------------------------------------------------------ persistence

  property bool stateLoaded: false

  function loadState(text) {
    try {
      var parsed = JSON.parse(text)
      if (parsed && Array.isArray(parsed.values)) {
        var next = []
        for (var i = 0; i < parsed.values.length; i++) next.push(Model.clampRaw(parsed.values[i]))
        root.values = next
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
    stateFile.setText(JSON.stringify({ version: 1, values: root.values }, null, 2) + "\n")
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
