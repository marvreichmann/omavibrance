# Changelog

All notable changes to this plugin are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the version is the
`version` field in `manifest.json`, which follows
[semantic versioning](https://semver.org/spec/v2.0.0.html).

Versions before 0.7.0 predate the public repository and have no release; they
are recorded here for continuity.

## [Unreleased]

## [0.7.1] - 2026-09-06

### Fixed

- Vibrance no longer flattens to neutral on a shell restart. The first
  `nvibrant` call of a session runs before the display count is known, so it
  passes no arguments — which sets every display to `0`. The stored values are
  now compared against the table that call echoes back and re-applied when they
  disagree, instead of only returning the next time the panel was opened. The
  same comparison re-syncs after a hotplug.

### Added

- Unit tests for `Model.js`, run with `node --test tests/` against captured real
  `nvibrant` output.

## [0.7.0] - 2026-09-06

### Added

- The panel is keyboard driven. **Tab** and up/down walk the display cards in
  the order shown, wrapping at the ends; **left/right** move the cursored
  display by 5%; **Enter** flashes it; **Escape** closes. Hovering a card aims
  the keys at it, so the arrows act on whatever is under the pointer.

### Changed

- The neutral mark on each track is half as tall, sized off the slider knob so
  it stays visible at exactly 0%, where the knob parks on top of it.

## 0.6.0 - 2026-09-06

### Added

- The missing-`nvibrant` warning carries a help button with the install commands
  (AUR and pipx) and the `nvidia_drm.modeset=1` kernel parameter it needs.

### Fixed

- Restore is disabled when `nvibrant` is missing. A saved snapshot outlives the
  binary that applied it, so the button stayed enabled with nothing to apply it
  with and its click was silently swallowed.
- The panel's right edge lines up: the bypass switch, the card borders and the
  footer buttons all sit one padding in from the frame, with the same gap below
  the buttons.

## 0.5.1 - 2026-09-06

### Fixed

- The hero icon, the title and the display rows share one left edge. The hero
  icon had no width and hung half outside the column everything else respected.

## 0.5.0 - 2026-09-06

### Added

- A **bypass** switch in the header drives every display to neutral without
  touching the stored values: the sliders stay put and remain editable, and the
  rows dim to show they are not in effect. An identify pulse still works while
  bypassed.
- A neutral mark on each slider track, and the reading moved above the track as
  a plain percentage — the exact numeric field is now a button away.

### Changed

- A rename can be abandoned. The row's actions become a check and a cross for
  the duration of an edit; Enter, Escape and those two buttons are the only
  exits. Committing on focus loss is gone, because clicking the discard button
  could take focus off the field first and save the edit being thrown away.
- The panel uses the full panel padding, so the header has room on every side.

## 0.4.0 - 2026-09-05

### Changed

- The panel adopts the house style: a hero header with the plugin mark, title
  and a small-caps status line carrying the display count and driver version,
  and one card per display with hover and identify highlighting. The identify
  and rename icons rest at 45% opacity and come up on hover.

## 0.3.0 - 2026-09-05

### Added

- An exact numeric field beside each slider.
- **Save** pins the current values and **Restore** returns to them. The state
  file moves to version 2 (`saved` and `names`); version 1 files still load.
- Displays are named from their EDID and ordered left to right by desktop
  position, instead of by connector index. Because the correlation is a
  heuristic, each row also gains an **identify** pulse to confirm it and a
  **rename** to override it.

### Changed

- Sliders are continuous — the nine tick marks and the 5% wheel step are gone.
- Dragging feels immediate. The service resolves the bundled per-driver binary
  once and calls it directly instead of going through the Python launcher on
  `PATH` (~40 ms → ~12 ms per call), falling back to the launcher if a direct
  call ever fails. The drag throttle drops to 25 ms.

## 0.2.0 - 2026-09-05

### Added

- First working plugin: a bar widget and panel driving `nvibrant`, with one
  slider per connected display on a -100%..100% scale, values persisted to
  `$XDG_STATE_HOME/omarchy/omavibrance.json` and re-applied at startup, and
  **Reset** to neutralize every display.

[Unreleased]: https://github.com/marvreichmann/omavibrance/compare/v0.7.1...HEAD
[0.7.1]: https://github.com/marvreichmann/omavibrance/releases/tag/v0.7.1
[0.7.0]: https://github.com/marvreichmann/omavibrance/releases/tag/v0.7.0
