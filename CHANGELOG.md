# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The version is `mod.json`'s `revision` written
X*10000 + Y*100 + Z (1.0.0 is revision 10000). The command protocol's own number (`version` in the mod's answers)
is separate and does not follow the release version.

## [Unreleased]

### Added

- `road --from-node ID` / `--to-node ID`: join an end to an existing road node by its id (before, only `--batch`
  pieces could). With `--from` / `--to` as well, the end sits at that point beside the node (the edge's `node0`
  the node, `position0` the point), up to 12 m off on the map; further is refused with nothing sent. The answer's
  ends give `position` and `endOffset`, and `offsetNote` says it. `--batch` pieces take `from` with `from-node`
  (and `to` with `to-node`) the same way, which was refused before. A player's narrow road joined beside a wide
  one's lanes was read with its end 4.5 m off its node, and there was no way to build that. Not checked in a game
  yet whether the engine takes such an end.
- `status` answers `luaLoad`: whether `load`, `loadstring` and `setfenv` exist in the GUI's Lua state and in the game
  script's (`gui` / `gs`, each `type()` of the three; `gs` is `"unread"` unless the setting `gameScript` is on, as
  the script writes it into its state). Asked before building anything that evaluates Lua text on them.
- `lanes`: each piece also gives `tangent0` / `tangent1`, `node0Position` / `node1Position` and `endOffset0` /
  `endOffset1` (each end's point less its node's), so an end beside its node can be seen before building one.

## [1.0.2] - 2026-11-25

### Added

- `calendar-speed`: reads the base's calendar speed slider (`GAME_SPEED.millisPerDay`, 0.25x-4x or paused) without
  a value, and sets it with one (a slider step, or `--millis-per-day`), answering the value before and after. Tests
  that need the date to move slower or faster than the simulation could only get there by a click in the calendar
  window before. Setting it is checked as `speed` is (owner, coop with `--user-asked`).

## [1.0.1] - 2026-11-25

### Changed

- The mod.io download holds only the mod: mod.io does not take `.py` files, so `tools/` is left out there. README,
  AGENTS.md and the mod.io description now say to get the tool from GitHub (a clone or the release zip) and keep it
  outside the game's mods folder. The GitHub release zip still holds the tool. No code changed.

## [1.0.0] - 2026-11-25

First public release: a Transport Fever 3 mod (`hummer_remote_probe`) and a command-line tool (`tools/tf3ctl.py`)
that let a script outside the game drive a running game through small files in the game's userdata folder.

### Added

- Game control: `launch`, `quit`, `restart` (also into the main menu or a new game), `load` with other mods and mod
  settings, `save`, `saves` / `info`, and `newgame` from the main menu.
- Time: `speed` beyond the UI's 4x (capped at the game's own estimate), `run` until a date and stop, `pause`, and
  ×8 / ×16 buttons beside the speed buttons with a label for speeds the base buttons do not show.
- Reading commands: `status`, `state`, `entities`, `stations`, `lines`, `depots`, `vehicles`, `models`, `persons`,
  `company`, `finance`, `around`, `lanes`, `parcels`, `water` and `stock list`.
- `log` and `keep-log` for the game log, and `frame` for a still from Steam's background game recording.
- Building on test maps: `build` (constructions, modular harbours, industries), `road` (one piece, bridges, and
  `--batch` for several pieces in one proposal), `terrain`, `town`, `connect` (with the Track Connector mod), with
  `--dry-run --engine-check` and `--collision-detail` to ask the engine first.
- `fit` to find where a construction stands, and `reach` to read whether a place can be got to on foot, by road or
  by the lines.
- Vehicles, money and lines: `buy`, `duplicate`, `replace`, `sell`, `money`, `line create` / `update` / `delete`
  and `rename`.
- Debug commands for test saves: `stock set`, `steps`, `town develop` / `size` / `connect`, `company init`,
  `running-costs`, `lights --off` and `road --ignore-errors`.
- `window`, `tool` and `event` to open windows and send test events through the GUI.
- `mod`: commands that other mods register in their own `remote_probe_ext.lua`, listed with `mod --list`.
- `modhub status` / `validate` / `publish` for My Mods and mod.io uploads from the main menu.
- A configuration file (`~/.config/tf3ctl/config.json`, or `$TF3CTL_CONFIG`) for what only some setups need:
  without it there is no owner check and no coop, test saves are `probe-*` only, `pointer` is refused and
  `modhub validate` / `publish` take no folder; a broken file stops every command but `config`.
  `tools/config.example.json` lists every key.
- Several clients on one game: a lock per command, the launching `--owner` recorded in `launched.json`, and
  `coop` for a person and one client sharing the running game.
- Mod settings for the check intervals, the log amount, the speed label, the ×8 / ×16 buttons and the game-script commands, in English and
  Japanese.

[1.0.2]: https://github.com/hummer98/tpf3-remote-probe/releases/tag/v1.0.2
[1.0.1]: https://github.com/hummer98/tpf3-remote-probe/releases/tag/v1.0.1
[1.0.0]: https://github.com/hummer98/tpf3-remote-probe/releases/tag/v1.0.0
