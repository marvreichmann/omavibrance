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

// A label the user can match to a physical monitor. Connector names repeat
// ("DP", "DP", "DP"), so the index has to stay part of the label.
function displayLabel(display) {
  return (display.name || "Display") + " · " + display.index
}
