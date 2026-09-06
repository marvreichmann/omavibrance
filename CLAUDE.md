# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An Omarchy shell plugin (QML / Quickshell) that controls NVIDIA digital vibrance
per display by driving the external `nvibrant` binary. There is no build step —
the plugin is the four source files at the repository root plus `manifest.json`.
`README.md` documents the user-facing behaviour. `tests/` holds unit tests for
`Model.js` and ships with nothing (the install copies named files); everything
in the QML files is still verified by hand, per the test loop below.

Develop in this repository, never in the installed copy.

For any question about the rules an Omarchy plugin has to follow — manifest
schema, entry points and kinds, what the shell loads and when, the plugin APIs —
consult <https://plugins.omarchy.org/develop.html> rather than guessing. The
notes below record what this plugin actually depends on; that page is the
authority.

## Tests

`Model.js` is covered by unit tests, run with Node's built-in runner — no
dependencies, nothing to install:

```sh
node --test tests/
```

`tests/model.js` evaluates `Model.js` (minus its `.pragma library` line) in the
host realm and returns its top-level declarations, so a new pure function is
testable without an export list — and without the cross-realm prototypes that
make every `deepEqual` fail while printing two identical-looking values.

This is why `Model.js` exists: a decision moved there becomes checkable in
milliseconds, against captured real `nvibrant` output, instead of by restarting
the shell and looking at a monitor. Prefer extracting to it over testing through
QML. Nothing below `Model.js` — processes, timers, panel state — has automated
coverage, so changes there still go through the loop that follows.

## Test loop

Testing the QML requires copying everything to the installed location, whose folder name
must match `manifest.json`'s `id`:

```sh
cp -a manifest.json *.qml *.js README.md LICENSE preview.png assets \
  ~/.config/omarchy/plugins/com.github.marvreichmann.omavibrance/
```

The shell watches local plugins and reloads on change, but a failed load is not
retried until a full rescan, so after fixing a QML syntax error restart outright:

```sh
omarchy-restart-shell
journalctl --user --since -20s | grep omavibrance
omarchy-shell com.github.marvreichmann.omavibrance open   # also: close, toggle
```

`Service.qml` imports only `QtQuick`, `Quickshell` and `Quickshell.Io` — no
`qs.Ui` — so it runs standalone under a plain Quickshell instance. That is how
the click-driven paths (save/restore, identify, rename) get exercised, since
nothing here can synthesize a mouse click:

```sh
mkdir -p /tmp/qstest/omavibrance-test && cd /tmp/qstest
cp "$OLDPWD"/{Service.qml,Model.js} omavibrance-test/   # from the repo root
# write a harness shell.qml that instantiates Service and calls its functions
XDG_STATE_HOME=$PWD/state qs -p omavibrance-test/shell.qml
```

Point `XDG_STATE_HOME` at a scratch directory or the harness overwrites the real
state file. The harness drives real hardware — it changes actual vibrance, so
end it on `resetAll()`.

Keyboard paths are the one input this environment *can* synthesize: drive them
with `wtype -k Right` and friends rather than reasoning about the key handling.
Hover cannot be raised by `hyprctl dispatch movecursor` alone — warp twice, a
few hundred ms apart, to generate real motion; warping while the popup is open
can dismiss it, so position the cursor first and open afterwards.

## Architecture

Four files, one direction of data flow:

- **`Service.qml`** — the singleton (manifest kind `service`, one per shell
  session) that owns *all* state: the display table, desired raw value per
  index, the Save/Restore snapshot, custom names, bypass, and the Hyprland
  monitor correlation. Bar widgets are instantiated per monitor, so no state may
  live anywhere else. It spawns every process: `which nvibrant`, a one-shot
  `python3` probe that resolves the bundled per-driver binary (skipping the slow
  launcher), `hyprctl -j monitors`, and the vibrance-applying invocation.
- **`Model.js`** — a `.pragma library` of pure functions: the nvibrant output
  parser, the raw ↔ percent conversion (asymmetric range, each direction scaled
  against its own bound), the connector-family monitor correlation heuristic,
  and label formatting. Anything testable in isolation belongs here.
- **`BarWidget.qml`** — the bar entry point. `injectPanel()` hands the nested
  panel what it needs, and the widget re-exports `opened`/`open`/`close`/
  `toggle` because the bar routes popup coordination through the widget in its
  slot, not the panel.
- **`Panel.qml`** — rendering and input only; every edit is forwarded to the
  service.

### Invariants that break things when violated

- `nvibrant` has no read-back. Enumerating displays *is* a write, so the service
  persists values to `$XDG_STATE_HOME/omarchy/omavibrance.json` (currently
  version 2; version 1 files must keep loading) and re-applies at startup.
- The first invocation of a session runs before the display count is known, so
  it sends no arguments — which sets every display to `0`. The restored values
  are therefore not on the hardware until `consumeOutput` compares the echoed
  table against `effectiveValue` and queues a second run. Drop that comparison
  and vibrance silently flattens on every shell reload, coming back only when
  the panel is opened and `refresh()` applies. It terminates because the re-run
  sends exactly the values the next table echoes back.
- Every invocation sends the **whole** array, including positional placeholders
  for disconnected indices. `displays` therefore keeps disconnected rows; the
  panel filters them, the service must not.
- One `nvibrant` process at a time, with a single coalesced pending re-run.
  Overlapping invocations mean the last one to *finish* wins, and re-running
  unconditionally on exit previously produced an infinite respawn loop.
- Identify pulses are held outside `values`, so they are never persisted and the
  slider does not move; a pulse outranks bypass.
- Bypass drives displays to neutral without touching stored values or slider
  positions; switching it back restores them exactly.
- Rename deliberately has no commit-on-focus-loss: clicking the discard button
  can take focus off the field before its click handler runs, so a focus-loss
  commit would save the very edit being thrown away.
- A saved snapshot can outlive the binary, so Restore needs the missing-binary
  guard as well as the snapshot check. With `nvibrant` absent the panel shows
  the warning and spawns no processes.

## Shell APIs this plugin relies on

Worth knowing, because guessing at them is how the first version broke:

- The **shell registers plugin bar widgets itself**, from `manifest.json`, under
  the plugin id. A plugin must not call `barWidgetRegistry.register` — doing so
  adds a second, phantom widget under a different key.
- The bar injects only `bar`, `moduleName` and `settings` into a widget. There is
  no `shell` and no `service`. A nested panel gets nothing at all unless the
  widget hands it over (see `BarWidget.injectPanel`).
- The service singleton is reachable from a bar-hosted component as
  `bar.shell.serviceFor(pluginId)`.
- A plugin is *enabled* — and therefore its `service` entry point loaded — by
  appearing in the bar layout in `shell.json`.
- The manifest's `panel` entry point is a different mechanism: the shell loads
  and positions that panel itself and injects `service` into it directly. This
  plugin does not use it; its panel is nested inside the bar widget, which is
  what every other panel-bearing plugin does.
- Base components come from `qs.Ui` (`BarWidget`, `Panel`, `KeyboardPanel`,
  `PanelSlider`, `PanelKeyCatcher`, `Button`, …) and tokens from `qs.Commons`
  (`Style`, `Color`). Read `/usr/share/omarchy/shell/Ui/` before inventing a
  control.
- **A panel that wants keys must be a `KeyboardPanel`, not a `PopupCard`.**
  PopupCard is an xdg-popup, which only receives keys once a click or hover has
  routed focus through its parent surface; KeyboardPanel is the layer-shell
  equivalent with the same API plus a keyboard-focus prime. Set its
  `focusTarget` to the `PanelKeyCatcher` — the surface has to map before
  anything inside it can take active focus, so doing it yourself on `opened` is
  too early.
- The panel's look is the house style, not a bespoke design. `PanelHero` gives
  the icon + title + small-caps status header, with the bypass switch in its
  `trailingControl` slot; row cards are `BorderSurface` tinted with
  `Style.normalFillFor` / `hoverFillFor` / `selectedFillFor` and
  `Border.controlSpec`. The first-party Dropbox and Tailscale panels are the
  reference implementations.

### Layout traps

The panel has two vertical rules, and both matter. The **outer** one is the
content column's edge: card borders, the hero's toggle and the footer buttons
all sit on it, one `KeyboardPanel.padding` in from the frame — which is also the
gap below the buttons, so the margin reads the same on every side. The **inner**
one is `rowInset` further in: the card's own padding, and what the hero and
status texts are shifted by so their contents line up with the rows'.

Three things fight that alignment. Card padding is derived from the live border
width, so a row does not slide sideways when its border changes on hover.
`ToggleSwitch` pads itself by `cursorPad` around the visible track, so it needs
`cursorRing: false` to reach the edge. And `OpticalGlyph` is an Item with **no
implicit size** that centers its text on itself, so a glyph given no width is a
zero-wide box with half the mark hanging off its left — every glyph here is
sized explicitly, to the shared `iconColumn`.

Also: the neutral mark must clear the *knob*, not just the track — at exactly 0%
the knob parks dead centre and a shorter mark vanishes under it.

## `nvibrant` contract

Verified against `nvibrant-bin` 1.2.1 by probing the binary — do not trust
secondhand descriptions of its CLI:

- **No flags.** `--help` and `-l` are not options; they are parsed as (invalid)
  positional values and the program sets vibrance anyway.
- Arguments are **one value per display index**, in order. Omitted trailing
  values default to `0`.
- Values are **clamped to `-1024..1023`**, not rejected.
- Every invocation prints the resulting table. There is **no read-back**: this
  echo is the only way to learn the display list, and producing it is a write.
- The trailing field is the ioctl result — `Success` on a connected output,
  `None` on an index with nothing attached.
- `ATTRIBUTE=vibrance|dithering` and `NVIDIA_GPU=<n>` are read from the
  environment. A non-existent GPU index exits non-zero.
- `nvibrant` on `PATH` is a Python launcher (~40 ms/call). The binary it execs
  runs in ~12 ms; `python3 -c "import nvibrant; print(nvibrant.get_best()[1])"`
  resolves its path. The service does this once and calls the binary directly,
  falling back to the launcher if the direct call ever exits non-zero.

## Before publishing

Reference: <https://plugins.omarchy.org/publish.html>.

`omarchy plugin validate <folder>` mirrors the checks the shell itself enforces
— schemaVersion, required fields, safe relative entry points that exist, an
entry point for every declared kind, no symlinks, no reserved id. It exits 0
silently on success. It does **not** check what the marketplace listing needs,
so verify those by hand:

- `author`, `description` and `license` present in `manifest.json`, and the
  `license` value matching what `LICENSE` actually says.
- `README.md`, `LICENSE` and `preview.png` at the repository root — every
  published plugin ships a preview and the store optimizes it automatically. No
  fixed dimensions; existing ones run from 960x540 to 2560x1600.
- `homepage` pointing at the public repository.
