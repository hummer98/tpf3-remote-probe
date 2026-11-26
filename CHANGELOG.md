# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). The version is `mod.json`'s `revision` written
X*10000 + Y*100 + Z (1.0.0 is revision 10000). The command protocol's own number (`version` in the mod's answers)
is separate and does not follow the release version.

## [Unreleased]

### Added

- `"officialModsByDefault"` in the configuration file (off by default): a new game (`newgame`, `launch` /
  `restart --new`) starts with the official mods installed (`ug_*`) too, as players' games do; `--remove ug_x` takes
  one out, an `--add` of one already in is not added twice. The answer names them in `plan.officialMods` (the
  editor's answer too); a mod older than the key, which starts the game without them, gets a warning. Measured
  2026-11-26: `launch --new` started a game with the probe alone.
- `track`: track pieces by coordinates as `road` builds roads (RoadType TRACK, SegmentAndEntity type 1), on the
  ground or underground with `--tunnel` (edge type TUNNEL, the tunnel type's id); `--from-node` / `--to-node`,
  `--tangent-from` / `--tangent-to`, `--batch` (at most 16, `"@name"` shared nodes), `--dry-run --engine-check`,
  `--collision-detail`. The answer gives the edges and the engine's words when it refuses. Not checked in a game
  yet.

### Changed

- Coop is no longer guarded beyond the saves: in this `--owner`'s coop every command goes but `quit`, `load`,
  `newgame` (and so `restart`), which stay the user's, and `modhub validate` / `publish`. `tool`, `buy`, `line`,
  `sell`, `terrain`, `town`, `connect`, `script-event`, `window --close-all` and the rest now go, and `speed`, `run`,
  `pause` and `calendar-speed` no longer need `--user-asked` (still parsed, no effect). The commands for test saves
  only (`road --ignore-errors`, `lights --off`, `running-costs` writes, `eval --write`) go on the person's save too:
  tf3ctl sends `_coop` (the coop's owner; it drops one written by hand, so the mod takes it as it comes) and the mod
  takes it in place of a test save's name; their answers name it in `coop`. Kept: `save` only to a test save's name
  (and `--user-asked` for that on a person's save), `--user-asked` for `eval --write` on a person's save (its code
  runs with every global and could reach the real save and delete, whose replacement is best effort: tf3ctl refuses
  it without, exit 4 `"refused": "coop"`, and the mod checks `_userAsked` again), the force mark after a forced
  road, the change count and `saveNote`, the refusals of an expired or malformed mark and of another client's coop. Why: the user's save stays as it was, so changing the running game
  together needs no more fences than that (D-20261126-08).
- `town size --factors`: each factor may be 0-25 (was 0-5). Measured 2026-11-26: 20,20,20 sent with updateAll was
  taken, 40 steps took a town from 384 to 719 buildings, a year later the factors were still 20, with no error.

## [1.1.1] - 2026-11-26

### Fixed

- `build --dry-run --engine-check`, `road --dry-run --engine-check` and `fit`'s checks said `buildable` where the
  engine's check had messages (`errorState.messages`, its errors) with `critical` not set, and the build, sent
  without ignoreErrors, was refused for them (measured 2026-11-26: a road depot over a road's node and a piece just
  built, the check `critical false` with messages `衝突` and both in `collisionEntities`, the build refused `衝突`
  twice). Such a check is a refusal now: `buildable: false`, `verdict: "refused"`, `errorsRefusal: true` (new), and
  `error` gives the messages with `(errorState.messages, critical not set: ...)`; `critical` is left out as before.
  So the verdicts of `engineContexts`, `unforced` (`road --ignore-errors`) and `lights --dry-run` count them too.
  `fit` also skips a place whose check is buildable with messages (an older mod's answer). Nothing sent changes: a
  build or a road is sent as before, and a forced road is still built past such errors; but
  `road --ignore-errors --dry-run` over such errors now answers `ok: false` (its verdict is the unforced one). A
  refused build's answer keeps `errorsRefusal` too. As the stricter of the two contexts is still the verdict, a
  road's dry run with `--remove-buildings` may be refused where only the engine's own context (which takes no
  buildings) has such messages (`build` takes `--join-streets` and `--remove-buildings` only without `--dry-run`).
  Checked in a game (2026-11-26): the depot's place above is refused `衝突` with `errorsRefusal` in both contexts;
  `fit` passed it over and its next place was built; a road over a construction was refused in the dry run and in
  the real build alike, and built with `--ignore-errors`; a road through town houses with `--remove-buildings` was
  refused `衝突` in the dry run and in the real build alike (no over-refusal seen there).

## [1.1.0] - 2026-11-26

### Added

- `test FILE`: run a test scenario, a JSON file of tf3ctl commands with checks of their answers (`expect`: a path
  into the answer with `eq`, `ne`, `gt`, `ge`, `lt`, `le`, `exists`, `contains`, `len`) and of the game's log since
  the start (a `log` step: no `ERROR` or Lua error entries, patterns can be set). One JSON result; exit `0` all
  passed, `5` (new) a step failed, `2` a broken scenario (nothing sent) or no answer. Each step goes through
  tf3ctl's own checks; flags that skip one (`--force`, `--user-asked`, `--other-owner-ok`, `--ignore-errors`) are
  refused in a scenario, and so are starting coop, `quit --kill`, `restart` without `--no-kill`,
  `window --close-all` and `--every` without `--count`. `--dry-run` only checks the file. So a mod's author can run the same checks again after every change without reading the
  answers. Sample: `examples/test_scenario_sample.json`, which passed against a game (6 of 6 steps, 2026-11-26).
- `eval 'CODE'` (or `--file`): runs a piece of Lua in the game's GUI Lua state (`--gs`: in the game script, with the
  setting `gameScript` on) and returns its value as JSON, with `print`'s lines; depth and size limits mark what they
  cut, userdata are walked as tables, a cycle is `"<cycle>"`, errors are `{ "ok": false, "kind": "compile" |
  "runtime" }`. Plain `eval` runs in an environment without the game's writers (`app`, `game`, `io`, `debug`,
  `api.cmd`, `api.gui`, functions under `api` named as writers, ...) and goes to any save; Lua cannot fence code
  in fully (an engine object's methods are real), as the reference says. `eval --write` has every global, goes on
  test saves only (during coop with `--user-asked`), carries `saveNote`, and its `app.saveGame` /
  `app.deleteSavegame` raise (best effort: `tf3ctl save` saves). Off unless the configuration file has
  `"eval": true`. There is no timeout: a loop that never ends freezes the game. Asked for to read values no command
  gives yet, without a new probe release for each. The engine's functions are callable tables in the game
  (`type()` `"table"`, `getmetatable` `false`): the read-only views call them. Such a table under `api` gets the
  real tables for the views among its arguments; a Lua function gets the views, a callback gets a view back, and a
  table seen only through a view comes back as that view (a Lua callable table that hides its metatable cannot be
  told apart from the engine's: see the reference). The writer names drop such tables too. Checked in a game
  (2026-11-26): plain `eval` (`api.engine.forEachEntityWithComponent` and `getComponent` answer, a write is
  refused, `api.cmd` is not there), `--gs`, `--write`'s refusal of `app.saveGame`, and that a component (userdata)
  cannot be walked with `pairs` (it comes back as `"userdata: 0x..."`; read its fields by name into a table).
- `road --from-node ID` / `--to-node ID`: join an end to an existing road node by its id (before, only `--batch`
  pieces could). With `--from` / `--to` as well, the end sits at that point beside the node (the edge's `node0`
  the node, `position0` the point), up to 12 m off on the map; further is refused with nothing sent. The answer's
  ends give `position` and `endOffset`, and `offsetNote` says it. `--batch` pieces take `from` with `from-node`
  (and `to` with `to-node`) the same way, which was refused before. A player's narrow road joined beside a wide
  one's lanes was read with its end 4.5 m off its node, and there was no way to build that. Checked in a game
  (2026-11-26): one piece with its end 4.5 to 6.25 m beside a four-lane road's end node was built, but a second
  such piece at the same node was refused ("cannot be built", critical, no `collisionEntities`; also as a dry run
  with `--ignore-errors`), in one proposal or after the first; a second piece out of the node's own point was built
  beside it. How far the engine takes, and which way an offset should run against the lanes, are not checked yet
  (more in `docs/KNOWN_BEHAVIOR.md`).
- `status` answers `luaLoad`: whether `load`, `loadstring` and `setfenv` exist in the GUI's Lua state and in the game
  script's (`gui` / `gs`, each `type()` of the three, or `"raised"` when reading it raised; `gs` is `"unread"` unless
  the setting `gameScript` is on now, as the script writes it into its state). Asked before building anything that
  evaluates Lua text on them.
- `lanes`: each piece also gives `tangent0` / `tangent1`, `node0Position` / `node1Position` and `endOffset0` /
  `endOffset1` (each end's point less its node's), so an end beside its node can be seen before building one.
- `tools/tf3ctl_mcp.py`: an MCP server (stdio, standard library only) that offers tf3ctl's commands as tools, so
  clients that take MCP servers can use the tool, and people looking for an MCP server find it. A thin wrapper: the
  tool list comes from tf3ctl's own parser and every call runs `tf3ctl.py` with its checks; `pointer` and
  `modhub publish` / `publish-clear` are left out. README: "MCP server". Checked so far by hand with `initialize`
  and `tools/list` only (no game).
- `tools/config.example.json`: the `eval` key (off).
- `docs/KNOWN_BEHAVIOR.md`: what was seen in a game on 2026-11-26 with proposals sent from a game script (a mod's
  script event: an on-road stop placed, a native crash with a stock in an edge object's construction, a refused
  vehicle at a `build --no-owner` construction's mouth), with `eval`, and with `test` and `road`'s end offsets.

### Fixed

- The `fit` example in the reference named the base road depot as `::/depots/road/road_depot.con`; it is
  `depots/road/road_depot/road_depot.con`.
- `road` to a construction's node that is not frozen (a station's, depot's or industry's mouth) remakes its
  junction set-up as at a town node: the old connections kept, the new piece's road and tram lanes joined to the
  construction's pieces (and, where the old list was empty and two or more pieces met there, those pieces to each
  other). It used to leave that set-up as it was, and in a game a bus terminal's mouth joined so kept no lane
  connections: a no-entry sign, `lines --problems` noPath, and `buy --line` refused with "Unkown". The end's
  answer now has `construction`, `constructionFile`, `pieces` and `laneRules`; `nodeConfigKept` is no longer
  answered, and `road --inspect-node` says the set-up is remade. A frozen node, and a node of a construction whose
  `CONSTRUCTION` does not read, are refused; `--ignore-errors` still does not join a construction's node.
  Checked in a game (2026-11-26) at two bus terminals' mouths and a road depot's: built with no errors, a mouth
  then had four lane connections, a line between the terminals had no noPath and a bus ran it; an industry's
  mouth, `--ignore-errors`, a construction upgraded or replaced afterwards, and whether pedestrians walk there
  are not checked yet.

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

[Unreleased]: https://github.com/hummer98/tpf3-remote-probe/compare/v1.1.1...HEAD
[1.1.1]: https://github.com/hummer98/tpf3-remote-probe/releases/tag/v1.1.1
[1.1.0]: https://github.com/hummer98/tpf3-remote-probe/releases/tag/v1.1.0
[1.0.2]: https://github.com/hummer98/tpf3-remote-probe/releases/tag/v1.0.2
[1.0.1]: https://github.com/hummer98/tpf3-remote-probe/releases/tag/v1.0.1
[1.0.0]: https://github.com/hummer98/tpf3-remote-probe/releases/tag/v1.0.0
