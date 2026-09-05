# Development

## Rules

1. **Primary project directory**: `/home/marv/Projects/omavibrance`. This will
   eventually be a Git repository.
2. **Workflow**: develop here, then copy the **entire** contents to
   `~/.config/omarchy/plugins/<plugin_id>` to test. The destination folder name
   **must** match the `id` in `manifest.json`.
3. **Reference**: <https://plugins.omarchy.org/develop.html>.

## Test loop

```sh
cp -a manifest.json *.qml *.js README.md LICENSE assets \
  ~/.config/omarchy/plugins/com.github.marvreichmann.omavibrance/
```

The shell watches local plugins and reloads them on change, but a failed load
is not retried until a full rescan, so after fixing a QML syntax error restart
the shell outright:

```sh
omarchy-restart-shell
journalctl --user --since -20s | grep omavibrance
```

Open the panel without touching the bar:

```sh
omarchy-shell com.github.marvreichmann.omavibrance open   # also: close, toggle
```

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
  `trailingControl` slot; row cards are `BorderSurface` tinted
  with `Style.normalFillFor` / `hoverFillFor` / `selectedFillFor` and
  `Border.controlSpec`. The first-party Dropbox and Tailscale panels are the
  reference implementations.

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

## Testing the service without a mouse

`Service.qml` imports only `QtQuick`, `Quickshell` and `Quickshell.Io` — no
`qs.Ui` — so it runs standalone under a plain Quickshell instance. That is how
the click-driven paths (save/restore, identify, rename) get exercised, since
nothing here can synthesize a mouse click:

```sh
mkdir -p /tmp/qstest/omavibrance-test && cd /tmp/qstest
cp ~/Projects/omavibrance/{Service.qml,Model.js} omavibrance-test/
# write a harness shell.qml that instantiates Service and calls its functions
XDG_STATE_HOME=$PWD/state qs -p omavibrance-test/shell.qml
```

Point `XDG_STATE_HOME` at a scratch directory or the harness will overwrite the
real state file. Note that the harness drives real hardware: it changes actual
vibrance, so end it on `resetAll()`.

## Manual checks

- Panel opens with a hero header reading `<n> displays · driver <version>`, and
  one card per `Success` display, named from EDID and ordered left to right by
  desktop position.
- Hovering a card brightens its fill and border and brings its identify/rename
  icons to full opacity. Note that `hyprctl dispatch movecursor` alone does not
  raise a hover — warp twice, a few hundred ms apart, to generate real motion;
  warping while the popup is open can also dismiss it, so position the cursor
  first and open afterwards.
- The slider track is continuous — no notches — and dragging updates the number
  field live and the display within ~25 ms; releasing between throttle ticks
  still lands the final value.
- Typing in the number field applies on commit; the slider follows.
- Identify flashes exactly one display six times and leaves it on its stored
  value. Closing the panel mid-pulse stops it.
- Rename persists, survives a restart, and an empty name falls back to the EDID
  label. Enter and the check commit; Escape and the cross discard. There is
  deliberately no commit-on-focus-loss: clicking the discard button can take
  focus off the field before its click handler runs, so a focus-loss commit
  would save the very edit being thrown away.
- The keyboard button reveals the numeric field in place of the percentage
  reading; clicking it again hides it.
- The neutral mark must clear the *knob*, not just the track — at exactly 0% the
  knob parks dead centre and a shorter mark vanishes under it.
- The panel has two vertical rules, and both matter. The **outer** one is the
  content column's edge: card borders, the hero's toggle and the footer buttons
  all sit on it, one `KeyboardPanel.padding` in from the frame — which is also the
  gap below the buttons, so the margin reads the same on every side. The
  **inner** one is `rowInset` further in: the card's own padding, and what the
  hero and the status texts are shifted by so their contents line up with the
  rows'.
- Three things fight that alignment. Card padding is derived from the live
  border width, so a row does not slide sideways when its border changes on
  hover. `ToggleSwitch` pads itself by `cursorPad` around the visible track, so
  it needs `cursorRing: false` to reach the edge. And `OpticalGlyph` is an Item
  with **no implicit size** that centers its text on itself, so a glyph given no
  width is a zero-wide box with half the mark hanging off its left — every glyph
  here is sized explicitly, to the shared `iconColumn`.
- The header switch bypasses: every display goes neutral, stored values and
  slider positions do not move, and turning it back on restores them exactly.
  An identify pulse outranks the bypass.
- Save then drift then Restore returns the exact saved values. Restore is
  disabled until a snapshot exists.
- Right-click on a slider neutralizes that display; Reset neutralizes all and
  leaves the snapshot and names intact.
- Tab and up/down walk the display cards in the order they are shown (wrapping
  at the ends), left/right move the cursored row by 5%, Enter flashes it and
  Escape closes the panel. Hovering a card moves the keyboard cursor to it.
  `wtype -k Right` and friends drive all of this from a script — it is the one
  input this environment can synthesize, so use it rather than reasoning about
  the key handling.
- Values survive `omarchy-restart-shell` (check
  `~/.local/state/omarchy/omavibrance.json`); a version 1 file still loads.
- With `nvibrant` renamed away, the panel shows the missing-binary warning and
  spawns no processes. Its help button expands the install commands, and Save,
  Restore and Reset are all disabled — a saved snapshot can outlive the binary,
  so Restore needs the missing-binary guard as well as the snapshot check.
  To exercise this without uninstalling anything, point the `which` probe in the
  *installed copy* at a name that does not exist and restart the shell.
