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
- Base components come from `qs.Ui` (`BarWidget`, `Panel`, `PopupCard`,
  `PanelSlider`, `PanelKeyCatcher`, `Button`, …) and tokens from `qs.Commons`
  (`Style`, `Color`). Read `/usr/share/omarchy/shell/Ui/` before inventing a
  control.

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

- Panel opens with one row per `Success` display, named from EDID and ordered
  left to right by desktop position.
- The slider track is continuous — no notches — and dragging updates the number
  field live and the display within ~25 ms; releasing between throttle ticks
  still lands the final value.
- Typing in the number field applies on commit; the slider follows.
- Identify flashes exactly one display six times and leaves it on its stored
  value. Closing the panel mid-pulse stops it.
- Rename persists, survives a restart, and an empty name falls back to the EDID
  label.
- Save then drift then Restore returns the exact saved values. Restore is
  disabled until a snapshot exists.
- Right-click on a slider neutralizes that display; Reset neutralizes all and
  leaves the snapshot and names intact.
- Values survive `omarchy-restart-shell` (check
  `~/.local/state/omarchy/omavibrance.json`); a version 1 file still loads.
- With `nvibrant` renamed away, the panel shows the missing-binary warning and
  spawns no processes.
