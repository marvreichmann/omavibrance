// Unit tests for Model.js, the plugin's pure-function layer.
//
// Nothing here touches QML, a shell, or the GPU: the point of Model.js is that
// the parsing, the raw/percent conversion, the reconcile and the monitor
// correlation are all decidable from their arguments alone. Run with:
//
//   node --test tests/
//
// The QML files are still exercised by hand — see CLAUDE.md's test loop.

const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("./model.js")

// Verbatim output from nvibrant-bin 1.2.1 on a 3-monitor DisplayPort setup,
// captured rather than written by hand so the parser is tested against the
// real column padding and bullet characters.
const REAL_OUTPUT = [
  "Driver version: (610.57.04)",
  "",
  "Display 0:",
  "• (0, HDMI) • Set vibrance (    0) • None",
  "• (1, DP  ) • Set vibrance (  307) • Success",
  "• (2, DP  ) • Set vibrance (    0) • None",
  "• (3, DP  ) • Set vibrance (  307) • Success",
  "• (4, DP  ) • Set vibrance (    0) • None",
  "• (5, DP  ) • Set vibrance (  307) • Success",
  "• (6, DP  ) • Set vibrance (    0) • None",
  ""
].join("\n")

// The table the *first* invocation of a session prints: it runs before the
// display count is known, so it passes no arguments and every index reads 0.
const ENUMERATION_OUTPUT = REAL_OUTPUT.replace(/307/g, "  0")

test("clampRaw", async (t) => {
  await t.test("holds the range nvibrant accepts", () => {
    assert.equal(Model.clampRaw(0), 0)
    assert.equal(Model.clampRaw(1023), 1023)
    assert.equal(Model.clampRaw(-1024), -1024)
  })

  await t.test("clamps rather than rejecting, as nvibrant does", () => {
    assert.equal(Model.clampRaw(5000), 1023)
    assert.equal(Model.clampRaw(-5000), -1024)
  })

  await t.test("rounds to an integer", () => {
    assert.equal(Model.clampRaw(2.4), 2)
    assert.equal(Model.clampRaw(2.6), 3)
  })

  await t.test("treats anything unusable as neutral", () => {
    for (const bad of [undefined, null, NaN, Infinity, -Infinity, "abc", {}, []]) {
      assert.equal(Model.clampRaw(bad), 0, `clampRaw(${String(bad)})`)
    }
  })

  await t.test("accepts the strings the parser pulls out of the table", () => {
    assert.equal(Model.clampRaw("307"), 307)
    assert.equal(Model.clampRaw("-1024"), -1024)
  })
})

test("percent conversion", async (t) => {
  await t.test("maps each direction against its own bound", () => {
    // The raw scale is asymmetric, so a single factor would put 100% and -100%
    // at different distances from their respective ends.
    assert.equal(Model.percentToRaw(100), 1023)
    assert.equal(Model.percentToRaw(-100), -1024)
    assert.equal(Model.percentToRaw(0), 0)
    assert.equal(Model.rawToPercent(1023), 100)
    assert.equal(Model.rawToPercent(-1024), -100)
    assert.equal(Model.rawToPercent(0), 0)
  })

  await t.test("clamps out-of-range percentages", () => {
    assert.equal(Model.percentToRaw(400), 1023)
    assert.equal(Model.percentToRaw(-400), -1024)
  })

  await t.test("treats unusable input as neutral", () => {
    for (const bad of [undefined, null, NaN, "abc"]) {
      assert.equal(Model.percentToRaw(bad), 0, `percentToRaw(${String(bad)})`)
    }
  })

  await t.test("round-trips every percentage the slider can produce", () => {
    // The panel shows whole percentages and writes back raw values, so a
    // percentage that does not survive the trip would make a slider drift by a
    // step each time the panel reopened.
    for (let p = -100; p <= 100; p++) {
      assert.equal(Model.rawToPercent(Model.percentToRaw(p)), p, `${p}%`)
    }
  })
})

test("parseOutput", async (t) => {
  await t.test("reads a real table", () => {
    const parsed = Model.parseOutput(REAL_OUTPUT)
    assert.equal(parsed.driver, "610.57.04")
    assert.equal(parsed.gpu, 0)
    assert.equal(parsed.displays.length, 7)
  })

  await t.test("trims the table's column padding off connector names", () => {
    const parsed = Model.parseOutput(REAL_OUTPUT)
    assert.equal(parsed.displays[0].name, "HDMI")
    assert.equal(parsed.displays[1].name, "DP")
  })

  await t.test("reads the ioctl result as the connected flag", () => {
    const parsed = Model.parseOutput(REAL_OUTPUT)
    const connected = parsed.displays.filter((d) => d.connected).map((d) => d.index)
    assert.deepEqual(connected, [1, 3, 5])
    assert.equal(parsed.displays[0].status, "None")
    assert.equal(parsed.displays[1].status, "Success")
  })

  await t.test("keeps disconnected rows, which are positional placeholders", () => {
    // Dropping them here would shift every later display's argument by one.
    const parsed = Model.parseOutput(REAL_OUTPUT)
    assert.deepEqual(parsed.displays.map((d) => d.index), [0, 1, 2, 3, 4, 5, 6])
  })

  await t.test("carries both representations of the value", () => {
    const row = Model.parseOutput(REAL_OUTPUT).displays[1]
    assert.equal(row.raw, 307)
    assert.equal(row.percent, 30)
    assert.equal(row.attribute, "vibrance")
  })

  await t.test("reads negative values", () => {
    const parsed = Model.parseOutput("• (0, DP  ) • Set vibrance (-1024) • Success")
    assert.equal(parsed.displays[0].raw, -1024)
    assert.equal(parsed.displays[0].percent, -100)
  })

  await t.test("reads the dithering attribute, which the same binary can set", () => {
    const parsed = Model.parseOutput("• (0, DP  ) • Set dithering (    1) • Success")
    assert.equal(parsed.displays[0].attribute, "dithering")
  })

  await t.test("returns an empty table for anything unparseable", () => {
    // The service keys off displays.length === 0 to leave its state untouched,
    // so garbage must not come back as a plausible-looking empty display list.
    for (const bad of ["", null, undefined, "command not found", "{}"]) {
      const parsed = Model.parseOutput(bad)
      assert.equal(parsed.displays.length, 0, JSON.stringify(bad))
      assert.equal(parsed.driver, "")
    }
  })
})

test("reconcileValues", async (t) => {
  const table = Model.parseOutput(REAL_OUTPUT).displays

  await t.test("keeps the values we already hold", () => {
    const stored = [0, 500, 0, 500, 0, 500, 0]
    assert.deepEqual(Model.reconcileValues(table, stored), stored)
  })

  await t.test("adopts the table for indices we have no preference for", () => {
    // First run with no state file: the hardware's own values are the only
    // sensible starting point.
    assert.deepEqual(Model.reconcileValues(table, []), [0, 307, 0, 307, 0, 307, 0])
  })

  await t.test("fills only the gap when stored values are short", () => {
    assert.deepEqual(Model.reconcileValues(table, [0, 500]), [0, 500, 0, 307, 0, 307, 0])
  })

  await t.test("drops stored values past the end of the table", () => {
    // A monitor that has gone away must not keep a positional slot, or every
    // display after it would be sent the wrong argument.
    const short = table.slice(0, 2)
    assert.deepEqual(Model.reconcileValues(short, [0, 500, 0, 500, 0, 500, 0]), [0, 500])
  })

  await t.test("clamps whatever came out of the state file", () => {
    // The file is user-editable and survives across versions.
    assert.deepEqual(
      Model.reconcileValues(table.slice(0, 3), [9999, -9999, "x"]),
      [1023, -1024, 0]
    )
  })
})

test("needsReapply", async (t) => {
  const stored = [0, 307, 0, 307, 0, 307, 0]

  await t.test("is true after the enumeration run, so a reload re-applies", () => {
    // The regression this exists for: the session's first invocation passes no
    // arguments, which sets every display to 0. Without this returning true the
    // restored values never reach the hardware and vibrance silently flattens
    // on every shell reload.
    const table = Model.parseOutput(ENUMERATION_OUTPUT).displays
    assert.equal(Model.needsReapply(table, stored), true)
  })

  await t.test("is false once the table echoes what we want, so it terminates", () => {
    // The re-apply sends exactly these values and nvibrant echoes them back, so
    // the next pass must find no mismatch. A predicate that stayed true here
    // would respawn nvibrant forever.
    const table = Model.parseOutput(REAL_OUTPUT).displays
    assert.equal(Model.needsReapply(table, stored), false)
  })

  await t.test("is false while bypassed, whose effective values are all neutral", () => {
    // Compared against the stored values instead, a bypassed session would
    // re-apply on every pass forever.
    const table = Model.parseOutput(ENUMERATION_OUTPUT).displays
    assert.equal(Model.needsReapply(table, [0, 0, 0, 0, 0, 0, 0]), false)
  })

  await t.test("is false mid-identify, where the pulse value is the effective one", () => {
    const table = Model.parseOutput(
      ENUMERATION_OUTPUT.replace("• (1, DP  ) • Set vibrance (    0)", "• (1, DP  ) • Set vibrance (-1024)")
    ).displays
    assert.equal(Model.needsReapply(table, [0, -1024, 0, 0, 0, 0, 0]), false)
  })

  await t.test("compares disconnected indices too, which also converge", () => {
    // nvibrant echoes the argument it was given even on a `None` row, so a
    // placeholder that disagrees is a real mismatch and re-sending it settles.
    const table = Model.parseOutput(REAL_OUTPUT).displays
    assert.equal(Model.needsReapply(table, [42, 307, 0, 307, 0, 307, 0]), true)
  })

  await t.test("treats a missing effective value as neutral", () => {
    const table = Model.parseOutput(ENUMERATION_OUTPUT).displays
    assert.equal(Model.needsReapply(table, []), false)
    assert.equal(Model.needsReapply(Model.parseOutput(REAL_OUTPUT).displays, []), true)
  })

  await t.test("says nothing to do for an empty table", () => {
    assert.equal(Model.needsReapply([], []), false)
  })
})

test("correlateMonitors", async (t) => {
  const displays = Model.parseOutput(REAL_OUTPUT).displays
  const monitor = (name, x) => ({ name, make: "ACME", model: "Model " + name, serial: "S" + name, x, y: 0 })

  await t.test("zips a connector family in order", () => {
    const monitors = [monitor("DP-1", 0), monitor("DP-2", 1920), monitor("DP-3", 3840)]
    const map = Model.correlateMonitors(displays, monitors)
    assert.equal(map[1].name, "DP-1")
    assert.equal(map[3].name, "DP-2")
    assert.equal(map[5].name, "DP-3")
  })

  await t.test("does not let a disconnected index consume a monitor", () => {
    // Indices 0, 2, 4 and 6 are placeholders; if they took from the pool the
    // connected rows would all be labelled with the wrong monitor.
    const map = Model.correlateMonitors(displays, [monitor("DP-1", 0)])
    assert.equal(map[1].name, "DP-1")
    assert.equal(map[3], undefined)
    assert.equal(map[0], undefined)
  })

  await t.test("orders connectors numerically, not as strings", () => {
    const map = Model.correlateMonitors(displays, [monitor("DP-10", 0), monitor("DP-2", 1920)])
    assert.equal(map[1].name, "DP-2", "DP-2 must come before DP-10")
    assert.equal(map[3].name, "DP-10")
  })

  await t.test("keeps families apart", () => {
    const hdmi = Model.parseOutput("• (0, HDMI) • Set vibrance (0) • Success").displays
    assert.equal(Model.correlateMonitors(hdmi, [monitor("DP-1", 0)])[0], undefined)
    assert.equal(Model.correlateMonitors(hdmi, [monitor("HDMI-A-1", 0)])[0].name, "HDMI-A-1")
  })

  await t.test("treats eDP as the panel connector nvibrant calls LVDS", () => {
    const lvds = Model.parseOutput("• (0, LVDS) • Set vibrance (0) • Success").displays
    assert.equal(Model.correlateMonitors(lvds, [monitor("eDP-1", 0)])[0].name, "eDP-1")
  })

  await t.test("leaves unknown connectors uncorrelated rather than guessing", () => {
    // DisplayPort-over-USB-C surfaces as a plain DP-n output, so matching USBC
    // would steal the row belonging to a real DP.
    const usbc = Model.parseOutput("• (0, USBC) • Set vibrance (0) • Success").displays
    assert.deepEqual(Model.correlateMonitors(usbc, [monitor("DP-1", 0)]), {})
  })

  await t.test("survives missing input", () => {
    assert.deepEqual(Model.correlateMonitors(displays, []), {})
    assert.deepEqual(Model.correlateMonitors([], [monitor("DP-1", 0)]), {})
    assert.deepEqual(Model.correlateMonitors(null, null), {})
  })
})

test("parseMonitors", async (t) => {
  await t.test("reads what hyprctl -j monitors gives", () => {
    const json = JSON.stringify([
      { name: "DP-1", make: "ACME", model: "XG27", serial: "ABC123", x: 1920, y: 0, extra: "ignored" }
    ])
    assert.deepEqual(Model.parseMonitors(json), [
      { name: "DP-1", make: "ACME", model: "XG27", serial: "ABC123", x: 1920, y: 0 }
    ])
  })

  await t.test("defaults missing fields instead of yielding undefined labels", () => {
    assert.deepEqual(Model.parseMonitors('[{"name":"DP-1"}]'), [
      { name: "DP-1", make: "", model: "", serial: "", x: 0, y: 0 }
    ])
  })

  await t.test("returns nothing when Hyprland is absent or unhappy", () => {
    // Correlation is optional: the panel falls back to connector labels.
    for (const bad of ["", "not json", "{}", "null", undefined]) {
      assert.deepEqual(Model.parseMonitors(bad), [], JSON.stringify(bad))
    }
  })
})

test("labels", async (t) => {
  const display = Model.parseOutput(REAL_OUTPUT).displays[1]
  const monitor = { name: "DP-1", make: "ACME", model: "XG27", serial: "ABC123", x: 0, y: 0 }

  await t.test("prefers the name the user typed", () => {
    assert.equal(Model.displayLabel(display, monitor, "Left"), "Left")
  })

  await t.test("falls back to the model, then the output, then the connector", () => {
    assert.equal(Model.displayLabel(display, monitor, ""), "XG27")
    assert.equal(Model.displayLabel(display, { name: "DP-1", model: "" }, ""), "DP-1")
    // Connector names repeat across rows, so the index has to stay.
    assert.equal(Model.displayLabel(display, null, ""), "DP · 1")
  })

  await t.test("keeps the detail line from repeating the label", () => {
    assert.equal(Model.displayDetail(display, monitor, ""), "DP-1  ·  ABC123")
    assert.equal(Model.displayDetail(display, monitor, "Left"), "DP-1  ·  XG27  ·  ABC123")
    assert.equal(Model.displayDetail(display, null, ""), "DP · 1")
  })
})
