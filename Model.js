.pragma library

// nvibrant's value range, confirmed by probing the binary: values outside it
// are clamped rather than rejected, and the table echoes back what was set.
var MIN_RAW = -1024
var MAX_RAW = 1023

// nvibrant has no query mode — it only ever *sets*. Every invocation takes one
// positional value per display index and prints the resulting table, so the
// echoed table is the only read-back that exists. Rows look like:
//
//   Driver version: (610.57.04)
//
//   Display 0:
//   • (0, HDMI) • Set vibrance (    0) • None
//   • (1, DP  ) • Set vibrance ( 1023) • Success
//
// The trailing field is the ioctl result: "Success" means the value landed on a
// real connected output, "None" means there is nothing on that index. Indices
// are positional and stay stable, so unconnected ones still need a placeholder
// argument to keep later displays aligned.
var ROW = /^\s*•\s*\((\d+),\s*([^)]*)\)\s*•\s*Set\s+(\w+)\s*\(\s*(-?\d+)\s*\)\s*•\s*(\w+)/

function clampRaw(value) {
  var n = Math.round(Number(value))
  if (!isFinite(n)) return 0
  return Math.max(MIN_RAW, Math.min(MAX_RAW, n))
}

// nvidia-settings presents digital vibrance as -100%..100%, so the UI does too.
// The raw scale is asymmetric (-1024..1023), which is why each direction is
// scaled against its own bound instead of by a single factor.
function percentToRaw(percent) {
  var p = Math.max(-100, Math.min(100, Number(percent) || 0))
  return clampRaw(p >= 0 ? (p / 100) * MAX_RAW : (p / 100) * -MIN_RAW)
}

function rawToPercent(raw) {
  var r = clampRaw(raw)
  return Math.round(r >= 0 ? (r / MAX_RAW) * 100 : (r / -MIN_RAW) * 100)
}

// Parses one nvibrant invocation's output. Returns the driver version, the GPU
// index the table belongs to, and every display row in index order.
function parseOutput(text) {
  var result = { driver: "", gpu: -1, displays: [] }
  if (!text) return result

  var lines = String(text).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]

    var driver = /^\s*Driver version:\s*\((.+)\)\s*$/.exec(line)
    if (driver) {
      result.driver = driver[1]
      continue
    }

    // Only one GPU's table is printed per invocation (NVIDIA_GPU selects it),
    // so a later header would mean a format change rather than a second GPU.
    var gpu = /^\s*Display\s+(\d+):\s*$/.exec(line)
    if (gpu) {
      result.gpu = parseInt(gpu[1], 10)
      continue
    }

    var row = ROW.exec(line)
    if (!row) continue

    var status = row[5]
    result.displays.push({
      index: parseInt(row[1], 10),
      // Names are space-padded to a fixed width in the table ("DP  ").
      name: row[2].replace(/^\s+|\s+$/g, ""),
      attribute: row[3],
      raw: clampRaw(row[4]),
      percent: rawToPercent(row[4]),
      status: status,
      connected: status === "Success"
    })
  }

  return result
}

// ------------------------------------------------------------- reconciling
//
// What to hold after an invocation. The echoed table is authoritative about
// which indices exist; our stored values are authoritative about what the user
// wants on them. So: keep a stored value wherever we have one, adopt the
// table's for an index we have never seen, and drop anything past the end of
// the table (a monitor that has gone away).
function reconcileValues(parsedDisplays, storedValues) {
  var out = []
  var stored = storedValues || []
  for (var i = 0; i < parsedDisplays.length; i++) {
    out.push(stored[i] === undefined ? clampRaw(parsedDisplays[i].raw) : clampRaw(stored[i]))
  }
  return out
}

// Whether the values we hold still need to be pushed to the hardware.
//
// nvibrant echoes the argument it was given for every index, connected or not,
// so the table is a faithful record of what the last invocation set. The first
// invocation of a session is made before the display count is known: it passes
// no arguments, and nvibrant defaults every index to 0. Comparing the two is
// therefore what catches a session start — and equally a hotplug, or vibrance
// moved by something outside this plugin.
//
// The comparison is against the *effective* values (bypass and identify
// applied), not the stored ones, or a bypassed session would re-apply forever.
function needsReapply(parsedDisplays, effectiveValues) {
  var effective = effectiveValues || []
  for (var i = 0; i < parsedDisplays.length; i++) {
    var want = effective[i] === undefined ? 0 : effective[i]
    if (parsedDisplays[i].raw !== want) return true
  }
  return false
}

// ---------------------------------------------------------------- monitors
//
// nvibrant reports a connector family and a positional index; Hyprland reports
// an output name, make/model/serial, and a desktop position. Neither knows
// about the other, and nothing in either output is a shared key — so the two
// lists can only be correlated by ordering within a connector family.
//
// Family of an nvibrant connector name ("DP  ", "HDMI", "DVID", ...) mapped to
// the prefix Hyprland gives the same physical connector. USBC and ADC are
// deliberately absent: DisplayPort-over-USB-C surfaces as a plain DP-n output,
// so guessing would risk stealing a row that belongs to a real DP.
var FAMILIES = {
  "DP": ["DP-"],
  "HDMI": ["HDMI-"],
  "DVID": ["DVI-D-"],
  "DVII": ["DVI-I-"],
  "LVDS": ["LVDS-", "eDP-"],
  "DSI": ["DSI-"],
  "VGA": ["VGA-"]
}

function familyOf(connectorName) {
  var key = String(connectorName || "").replace(/\s+/g, "").toUpperCase()
  return FAMILIES[key] ? key : ""
}

function monitorFamily(outputName) {
  var name = String(outputName || "")
  for (var key in FAMILIES) {
    var prefixes = FAMILIES[key]
    for (var i = 0; i < prefixes.length; i++) {
      if (name.toLowerCase().indexOf(prefixes[i].toLowerCase()) === 0) return key
    }
  }
  return ""
}

// Trailing connector number, so DP-10 sorts after DP-2 rather than before it.
function connectorNumber(outputName) {
  var m = /(\d+)\s*$/.exec(String(outputName || ""))
  return m ? parseInt(m[1], 10) : 0
}

// Pairs nvibrant display rows with Hyprland monitors, returning a map of
// nvibrant index -> monitor. Within each connector family both lists are put in
// their natural order — nvibrant by its positional index, Hyprland by connector
// number — and zipped.
//
// This is a heuristic, not a lookup: it assumes the driver enumerates a family's
// connectors in the same order Hyprland numbers them. It holds on ordinary
// setups but cannot be verified from either data source, which is why the panel
// offers an identify pulse and a manual name override.
function correlateMonitors(displays, monitors) {
  var byIndex = {}
  if (!displays || !monitors) return byIndex

  var pools = {}
  for (var i = 0; i < monitors.length; i++) {
    var family = monitorFamily(monitors[i].name)
    if (!family) continue
    if (!pools[family]) pools[family] = []
    pools[family].push(monitors[i])
  }
  for (var key in pools) {
    pools[key].sort(function(a, b) { return connectorNumber(a.name) - connectorNumber(b.name) })
  }

  var taken = {}
  for (var d = 0; d < displays.length; d++) {
    // Disconnected indices are placeholders in the argument list, not outputs,
    // so they must not consume a monitor from the pool.
    if (!displays[d].connected) continue
    var f = familyOf(displays[d].name)
    if (!f || !pools[f]) continue
    var next = taken[f] === undefined ? 0 : taken[f]
    if (next >= pools[f].length) continue
    byIndex[displays[d].index] = pools[f][next]
    taken[f] = next + 1
  }

  return byIndex
}

// Parses `hyprctl -j monitors` into the subset this plugin correlates against.
function parseMonitors(json) {
  var out = []
  try {
    var list = JSON.parse(json)
    if (!Array.isArray(list)) return out
    for (var i = 0; i < list.length; i++) {
      var m = list[i]
      out.push({
        name: String(m.name || ""),
        make: String(m.make || ""),
        model: String(m.model || ""),
        serial: String(m.serial || ""),
        // Desktop position, used to order the panel left to right so the rows
        // read in the same order as the monitors on the desk.
        x: Number(m.x) || 0,
        y: Number(m.y) || 0
      })
    }
  } catch (e) {
    // Hyprland absent or output unparseable: correlation is optional, so an
    // empty list just falls the panel back to connector labels.
  }
  return out
}

// A label the user can match to a physical monitor, best information first:
// a name they typed, else the monitor model, else the raw connector. Connector
// names repeat ("DP", "DP", "DP"), so the index stays whenever it is all we
// have to tell two rows apart.
function displayLabel(display, monitor, customName) {
  if (customName) return customName
  if (monitor && monitor.model) return monitor.model
  if (monitor && monitor.name) return monitor.name
  return (display.name || "Display") + " · " + display.index
}

// The supporting line under the label: the output name plus whatever identity
// is left over once the label has taken the best of it.
function displayDetail(display, monitor, customName) {
  var parts = []
  if (monitor && monitor.name) parts.push(monitor.name)
  else parts.push((display.name || "?") + " · " + display.index)
  if (customName && monitor && monitor.model) parts.push(monitor.model)
  if (monitor && monitor.serial) parts.push(monitor.serial)
  return parts.join("  ·  ")
}
