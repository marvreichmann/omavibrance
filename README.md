# Omavibrance

Control NVIDIA digital vibrance for every connected display from the Omarchy
bar, using [`nvibrant`](https://github.com/Tremeschin/nvibrant).

![Bar widget and panel](assets/panel.png)

## Features

- One slider per **connected** display, from -100% (grayscale) to +100% (max
  saturation), matching how nvidia-settings presents the setting.
- Displays are labelled by connector and index (`DP · 1`), so a multi-monitor
  setup stays identifiable.
- Values are remembered and re-applied when the shell restarts — `nvibrant`
  itself has no way to read back what is currently set.
- Right-click a slider to return that display to neutral; **Reset** neutralizes
  all of them.
- Warns in the panel if `nvibrant` is missing or an invocation fails.

## Prerequisites

`nvibrant` must be installed and on `PATH` (`nvibrant-bin` on Arch). It needs
`nvidia_drm.modeset=1`, since it drives `/dev/nvidia-modeset` directly.

## Installation

Copy this directory to `~/.config/omarchy/plugins/com.github.marv.omavibrance/`,
then add the **Omavibrance** widget to your bar. Adding the widget is what
enables the plugin, which in turn starts its service.

## Notes on `nvibrant`

`nvibrant` has no query mode and no flags — it takes one positional value per
display index, clamps each to `-1024..1023`, and prints the resulting table.
Three consequences shape this plugin:

- Enumerating displays is itself a write, so the plugin persists its values to
  `$XDG_STATE_HOME/omarchy/omavibrance.json` and re-applies them at startup.
- Changing one display means re-sending every display's value, so the service
  owns the whole array.
- Indices are positional and include disconnected outputs. Those are kept in the
  array as placeholders but hidden from the panel.

Only the first GPU is controlled. `nvibrant` selects a GPU with the `NVIDIA_GPU`
environment variable; multi-GPU support is not implemented.

## License

MIT — see [LICENSE](LICENSE).
