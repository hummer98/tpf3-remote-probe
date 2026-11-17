# Remote Probe for Transport Fever 3

[日本語版 README](README.ja.md)

A Transport Fever 3 mod (`hummer_remote_probe`) plus a command-line tool (`tools/tf3ctl.py`) that let a script
outside the game drive a running game: set the speed beyond the UI's 4x, run until a date and stop, load and save
games (with other mods or mod settings), start a new game from the main menu, open windows, buy and sell vehicles,
make lines, lay track or roads between two ends (with the Track Connector mod), and read the game log.

It was made to check mods without someone at the keyboard: load a test save with some settings, run a few months,
stop, read the log, repeat. A person can use it from a shell; so can a test script or an AI agent.

**Use it on test saves.** Commands can load other saves (unsaved progress is lost), change the company's money and
buy or sell vehicles.

## How it works

The game's GUI Lua has no sockets and no file access (`io`). What it does have is `app.saveUserdata` /
`app.loadUserdata`, which write and read Lua files in the game's userdata folder. The mod's GUI script
(`content/remote.script.lua`, a `guiUpdateScript`) uses those files as a mailbox:

```
tf3ctl.py  --writes-->  <userdata>/recordings/remote_probe__cmd_<stamp>.lua   { id, cmd, args }
the mod    --reads every 0.25-2 s, runs the command, writes-->
                         <userdata>/recordings/remote_probe__res_<id>.lua     { id, json = "..." }
tf3ctl.py  --reads the answer, prints the JSON, removes old files
```

`<userdata>` is `<Steam>/userdata/<your Steam id>/3493540/local`. The mod also writes a `remote_probe__hello_*`
file on every load (who it is, the game state, the mod settings), which the tool uses to find the folder and to
notice a new load. If `recordings` does not keep the files, the mod falls back to `keyframes`, then `mod_presets`.
The file format is described at the top of `content/remote.script.lua`.

A few commands need the GUI's react state (opening windows, firing events, the vehicle store's code path). For those
the mod replaces the speed buttons' recipe with the same buttons plus ×8 / ×16 buttons and a small label, and passes requests to that
recipe through the GUI save data. So **the speed buttons must be on screen** for `window`, `event`, `tool`, and the
`--via gui` way of the vehicle and line commands (without them those fail after 60 s with "no word from the speed
control").

In the main menu there is no game script yet. For that, the game can be launched with
`--script hummer_remote_probe::/startup.lua`, which runs the same command loop in the menu (status, saves, info,
load, newgame, poll and quit only). `tf3ctl.py launch` and `restart` do this for you.

## Requirements

- Transport Fever 3 (tested on build 40444) through Steam, on Linux. The tool uses `fcntl` and the Linux process
  list, so it does not run on Windows as it is.
- Python 3.8 or newer, and `luajit` on the `PATH` (the tool reads the mod's Lua files with it).
- Optional: `ffmpeg` and Steam's background game recording for `frame`; ImageMagick for `screenshot --preview`.
- Optional: the Track Connector mod (on mod.io, modId `ethan_track_connector`, written against revision 3 / v1.3, not yet run with it in a game) for
  `connect`, enabled for the save.
- Not together with Time Warp (mod.io 6453396, modId `mobarzik_faster_game_speed`): both replace the same speed
  buttons, so `mod.json` lists it under `incompatibilities` and the game warns when both are enabled. If both
  are enabled anyway, Time Warp's buttons are shown with the label, without this mod's ×8 / ×16.

## Install

1. Copy this repository's folder into the game's local mods folder, for example
   `<Steam>/userdata/<your Steam id>/3493540/local/mods/hummer_remote_probe_1/` (the folder holds `mod.json`).
2. In the game, enable "Remote Probe" for a save and load it. Or let the tool start the game (see `launch` below).
3. Check that it answers:

```
python3 tools/tf3ctl.py status
```

The game log then shows `[remote_probe] ready`.

## Usage

All commands print one JSON object. Exit codes: 0 ok, 1 the game answered with an error, 2 no answer or a tool
error, 3 the game cannot answer where it is (a menu, loading, the main menu without the probe, closed; the
`gameState` field says which).

### Time and speed

```
python3 tools/tf3ctl.py status                        # date, speed, measured rate, mods and their settings
python3 tools/tf3ctl.py speed 16                      # beyond the UI's 4x (capped, see Safety); 0 pauses
python3 tools/tf3ctl.py pause
python3 tools/tf3ctl.py run --months 2 --speed 16     # or --days N / --until YYYY-MM-DD; then speed 0
python3 tools/tf3ctl.py poll --idle 5 --active 0.5    # how often the mod reads the command file, until the next load
```

In game, the mod adds ×8 and ×16 buttons to the right of the base ⏸ ▶ ▶▶ ▶▶▶ (0/1/2/4), in the same style. The
current speed lights up as with the base buttons. A ×8 / ×16 button sets that speed as it is, even above the game's
estimated maximum (unlike `speed`, which caps: the player chose it). A base button goes back to the base speeds. The
label beside them (`×16 real ×3.2`) still shows for 8 and 16, which the base buttons do not have.

### Saves and new games

```
python3 tools/tf3ctl.py saves
python3 tools/tf3ctl.py info my-save                  # a save's mods and mod settings
python3 tools/tf3ctl.py load my-save --param example_mod:difficulty=3 --dry-run   # show the plan only
python3 tools/tf3ctl.py load my-save --param example_mod:difficulty=3 [--add MOD] [--remove MOD] [--set-mods a,b]
python3 tools/tf3ctl.py save my-save-after            # overwrites a save of the same name
python3 tools/tf3ctl.py newgame --list                # climates and terrain generators (safe in a game)
```

`--param mod:key=index` takes the 1-based index into that setting's `values` in the mod's `mod.json` (as mod
presets store them); base game settings are `:key=index`. This mod always stays enabled: without it nobody would
answer.

### Starting, quitting and restarting the game

```
python3 tools/tf3ctl.py launch [--load SAVE | --new ...]   # when the game is not running
python3 tools/tf3ctl.py restart --load my-save [--param ...]
python3 tools/tf3ctl.py restart --new --year 1900 --size small --add example_mod
python3 tools/tf3ctl.py quit [--kill]
python3 tools/tf3ctl.py state                         # in_game / menu / loading / main_menu / starting / closed / crashed
```

`launch` runs `steam -applaunch 3493540 --script hummer_remote_probe::/startup.lua` and waits until the probe
answers in the main menu; then it loads a save or starts a new game from there. `restart` quits first and, by
default, SIGKILLs the game when it does not quit (`--no-kill` gives up instead; see Safety). New game options:
`--climate` (default temperate), `--size` (tiny 16x16, small 32x32 (default), medium 44x44, large 56x56, veryLarge
64x64, or WxH), `--year` (default 1900), `--seed`, `--generator` (default: the first one, as the base new-game page
picks it), `--no-towns`, `--no-industries`, and the mod options as for `load`. From the main menu there is no
current game, so the mods are this mod plus those given with `--add` / `--set-mods`; check the plan in the ack.
New games start with the base tutorial off (`:guideSystemConfig.tutorial=1`), since nobody is there to click
through it; `--tutorial` keeps the base default (on), and an explicit `--param :guideSystemConfig.tutorial=N` wins.
The same holds for the `newgame` command.

### Looking at the game

```
python3 tools/tf3ctl.py log --grep remote_probe --tail 40   # the game's stdout.txt
python3 tools/tf3ctl.py entities --kind town --grep ems     # ids and names: town, line, vehicle, station, industry
python3 tools/tf3ctl.py window --town Emsworth --focus      # open its window and move the camera (--close-all)
python3 tools/tf3ctl.py frame --out shot.png [--crop 1150x170+2690+1450]   # the screen with UI, from Steam's recording
python3 tools/tf3ctl.py tool music [--close]                # base windows that open as a tool: music, calendar, notifications
python3 tools/tf3ctl.py event example_window.show --param '{"page": 2}'   # fire any react event
python3 tools/tf3ctl.py camera                              # x, y, distance, angle, pitch, heightAboveTerrain
python3 tools/tf3ctl.py camera --set 1200,-800,600         # x,y[,distance[,angle[,pitch]]]; the rest stays as it is
python3 tools/tf3ctl.py camera --entity 12345              # or --focus x,y,z [--distance d]
python3 tools/tf3ctl.py build-tool --res station/street/bus_stop.con [--template N] [--seconds 60]   # (--close)
```

`camera` answers the values read back after the move. Numbers are checked first: NaN, infinity, a centre beyond
1e6, a distance outside 1-1e5, an angle beyond +-2 pi or a pitch beyond +-pi/2 are refused. `--entity` checks that
the entity exists. Refused in the main menu.

`build-tool` opens the construction menu's placing tool for one construction, with two base events sent through
the speed control one after the other (1.5 s apart, since it reads every 0.5 s and keeps only the newest):
`setMenuFilter` with the construction's tag (`resName`, or `resName@N` with `--template`), so the menu lists only
it, then `constructionMenuSelectTabForConstruction`, which opens its tab and picks the first item. Undoing it:

- the mod itself clears the filter `--seconds` after (default 60, at most 600), so a tool that died midway does
  not leave the menu showing one building;
- `build-tool --close` clears it at once;
- loading a game or quitting also clears it (the filter is GUI state; it is not saved).

The resName must exist (`api.res.constructionRep`). A construction not available in the current year is not
listed, and module tabs (dynamic) are not covered. **The mouse pointer has to be over the 3D view, put there by a
person**: the placement preview and its tooltip only appear when there is a proposal under the mouse. For a cover
shot: `camera --set` (or `--focus`) to the place, `build-tool --res ...`, keep the pointer over the view, then
`frame` or `screenshot`, and `build-tool --close`.

The events share the speed control's one request slot with `window`, `event` and `tool`: one of those sent
within the 1.5 s gap, or just before the clear, is overwritten (or overwrites the tab request). Wait for
`build-tool` to finish before sending them.

### Vehicles, money and lines

```
python3 tools/tf3ctl.py depots [--grep bus]
python3 tools/tf3ctl.py vehicles [--line 21]
python3 tools/tf3ctl.py buy --model bus_1900 --depot 301 [--line 21] [--count 2] [--via gui|cmd]
python3 tools/tf3ctl.py duplicate --vehicle 601 [--depot D] [--line L]
python3 tools/tf3ctl.py replace --vehicle 601 --model bus_1920
python3 tools/tf3ctl.py sell --vehicle 601
python3 tools/tf3ctl.py money --set 10000000 | --add -5000
python3 tools/tf3ctl.py stations [--name cent] [--near 11 --radius 800]
python3 tools/tf3ctl.py lines [--name probe]
python3 tools/tf3ctl.py line create --stops Central,42 [--name "[probe] A"] [--cargo coal] [--via gui|cmd]
python3 tools/tf3ctl.py line update 21 [--stops 41,42,43] [--name N] [--cargo C]
python3 tools/tf3ctl.py line delete 21 [--sell-vehicles]
```

Vehicle answers carry the balance before and after, what was spent, the store price of each part
(`metadata.cost`, read before sending and again when answering), every part's `purchaseTime` and the vehicle's
depreciated value: enough to check a mod that changes vehicle prices. Run them paused, or fares and running costs
end up in the difference too (a `warning` says so when game time moved).

### Track and roads between two ends (`connect`)

```
python3 tools/tf3ctl.py connect --from 5123 --to Harbour                 # plan it and dry-run it; nothing is built
python3 tools/tf3ctl.py connect --from 5123 --to 5200 --build            # build it
python3 tools/tf3ctl.py connect --from 801 --to 802 --road [--template ::/infrastructure/street/country/country_old_medium.street_template]
python3 tools/tf3ctl.py connect --from A --to B [--track standard|high_speed|simple|<template> --electric]
    [--slope 3 --radius 250] [--no-bridges] [--no-tunnels] [--build [--clear]] [--timeout 300]
```

`connect` needs the Track Connector mod (on mod.io), enabled for the save (its game script
joins a save when the save is loaded with it). The probe loads that mod's planner and proposal modules at run
time and sends its game script the events its own tool sends; nothing of that mod is shipped here. The rest (finding
the ends, the map the planner works on, turning its result into the route record the game script takes, reading the
outcome) is the probe's own code, written against those modules' functions and the game script's events and state.
Without the mod, `connect` answers with an error saying so, and every other command works as before.

- Ends (`--from`, `--to`): a free end's node id (a node with exactly one track piece and no road; with `--road`, one
  road piece and no track), or a station group, a station or a station's construction (by id, or a part of a
  station group's name). A station stands for its free platform ends; the pair of ends that face each other best is
  taken.
- Defaults are Track Connector's default settings: tracks 2.5 % and 300 m curves, roads 6 % and 100 m (a road type that states a
  steepest grade it may be built at lowers a steeper slope to that); bridges and tunnels on. A road without `--template` gets the start road's own type and lanes,
  as Track Connector's road tool does, unless that type is a construction's own entrance road (`street/constructions/`,
  as industries, stations and depots have; not in the player's road menu) or cannot be built in the game's year (its
  `availability`): then it gets the first of the base game's medium and small country roads (new, old) that can be
  built that year, without the start road's lanes, and a note says so.
- A road type given with `--template` that is such an entrance road, or that cannot be built in the game's year, is
  refused before anything is sent. A track type out of its years only gets a note (whether the game refuses one from a
  script is not known). The answer has the game's `year`.
- Without `--build` the answer is the plan and the dry run: `route` (`points`, `pieces`, `pieceKinds`, `length`,
  `straight`, `bridge`, `tunnel` in metres, `steepestPercent`, `maxCut`, `maxFill`), `plan` (seconds, frames, the
  longest frame, search steps, what the map read found), `preview` (Track Connector's verdict: `ok`, `short`,
  `summary`), `estimate` (`cost`, `errors`, `problem`, `blockers`; `clear`, `clearCost`, `clearCount` when it can be
  built once town buildings go), `buildable`, the `settings` sent, `from` / `to` (node, position, the station's free
  ends). `ok` is `buildable`; `error` says why not. A refusal without a cost (the game's "Not buildable" at $0) means
  the game refused the route before pricing it; a note says so, and Track Connector logs the refused pieces a few
  seconds later.
- With `--build`, when the dry run allows it (or `--clear` and the town buildings in the way can go), the route is
  built by Track Connector's game script. `build` then has Track Connector's outcome (`tc`), `balanceBefore`,
  `balanceAfter`, `spent` (the balance difference, so a cost another mod adds after the build is in it),
  `estimatedCost`, `beyondEstimate`, `newEdges` / `newNodes` (pieces and nodes along the route that were not there
  before) and `joined` (both ends now carry the new piece). Track Connector refuses a build the company cannot pay
  for. Run it paused: otherwise fares and running costs are in `spent` too (`warning`).
- First the land along the way is read (a few blocks per frame), then the route is planned. That takes seconds to
  minutes; the tool prints the progress on stderr and waits `--timeout` (default 120 s)
  plus 30 s. One `connect` at a time.
- Track Connector keeps one state for everyone: a player using its tool while a `connect` runs, or the other way
  round, overwrites the picked ends and the route. `connect` checks that the state still shows its own ends and
  route, before and after a build, and ends with an error otherwise. The settings it sends stay in that state: Track Connector's track tool
  starts from them next time (its road tool does not read the settings in the state).
- Removing Track Connector from a save later: its `severityRemove` is Warning. What was built is ordinary track or
  road of the game's own types (a type from another mod, given with `--track` / `--template`, needs that mod), so it
  stays. Track Connector's game script state stays in the save.

### Several clients at once

Several tool processes may run at once (a long `run` plus `status` calls, say): a lock makes them write the single
command file one after another. When more than one person or script shares a game, give each a name with
`--owner NAME` (or `TF3CTL_OWNER`). It is shown in `status` (`run.owner`, `lastAction`), and a client gets a
warning on stderr before any command that changes the game (`load`, `run`, `speed`, `save`, `buy`, `line`, ...)
when another owner changed the game in the last 10 minutes. Nothing is refused; clients agree among themselves
who uses the game. `quit --kill` is the exception: it will not SIGKILL a game another owner used in the last
10 minutes unless `--force` is given.

### Environment

- `TF3_REMOTE_DIR`: the exchange folder (default: the one with the newest hello file under Steam's userdata,
  looked for in `~/.local/share/Steam`, `~/.steam/steam` and the Flatpak Steam).
- `TF3_LOG`: the game log (default: `crash_dump/stdout.txt` next to the exchange folder).
- `TF3_STEAM`: the command that starts Steam (default `steam`).
- `LUAJIT`: the luajit binary.
- `TF3CTL_OWNER`: the default for `--owner`.

## Mod settings

| Setting | Values | |
|---|---|---|
| Idle check interval | 1 / **2** / 5 / 10 s | how often the command file is read when no command came for a while (one read takes a few ms) |
| Check interval after a command and during a run | 0.1 / **0.25** / 0.5 / 1 s | for two minutes after a command and during a `run` |
| Log amount | Minimal / **Per command** / Detailed | `[remote_probe]` lines in the game log |
| Label beside the speed buttons | **Show** / Hide | e.g. `×16 real ×3.2 →2045-07-03` for speeds the buttons do not have, and during a `run` |

The settings and the speed label are in English and Japanese (`strings.json`), in the game's language; other
languages get English. The name, summary, description and cover in the game's mod list come from
`_metadata/modinfo.json` and `_metadata/0.png`; the game shows one text there for every language, so it holds both.

## Safety

- **`newgame` does not work from inside a game.** The base `StartGame` expects no game to be running and TF3
  crashed (2026-11-15). In a save only `newgame --list` and `--dry-run` are safe (`--unsafe` sends it anyway and
  crashes). Start new games with `restart --new` or `launch --new`, from the main menu.
- **Use `--via gui` (the default) for vehicle price tests.** `--via cmd` sends bare engine commands and leaves
  `purchaseTime` at 0; the engine does not fill it in, so the vehicle counts as bought at the start of the game and
  costs only its fully depreciated value (store price 48441, spent 261 in one test). The cmd way also must send
  `autoLoadConfig` with one entry per compartment: an empty one hit an engine assertion
  (`UpdateConfigFromModelIds`) that killed the game, uncatchable by `pcall` (2026-11-16). This is fixed in the
  mod, but the cmd ways of `buy` and `line` build engine structures by hand; try them on a small save first.
- **Speed is capped** at the game's own estimate of what it can sustain (`getEstimatedMaximumGameSpeed`, or 4
  before it is known). Above it the simulation falls behind, frames get long and sound breaks up (x8 on a save
  estimated at x5-6). `run` re-checks the estimate every 2 s. `--force` sends the speed as given.
- **Not every window can be opened as a tool.** The notification log's recipe needs parameters its base button
  passes, so pushed as a plain tool it hit a nil call and the GUI reloaded (2026-11-17). `tool notifications`
  therefore fires the base events `openNotificationLog` / `closeNotificationLog` instead. Before pointing `tool
  --module` at another module, check what its base button passes.
- **`quit --kill` and `restart` SIGKILL a game that does not quit**, losing unsaved progress (`restart --no-kill`
  gives up instead). Neither kills a game another `--owner` changed in the last 10 minutes without `--force`.
- **Loading discards unsaved progress**, and a load starts without waiting for the "Start Game" button (the base
  loading page waits for it; `--wait-for-start` keeps that).
- `line delete` refuses a line with vehicles unless `--sell-vehicles` is given. It skips the base checks for
  missions and protected entities (it is meant for test saves).
- `money` books an "other" journal entry, which shows in the finance tables and charts.
- `buy` can buy models outside their years (the store's availability check is not applied).

## What was checked in game

Checked (build 40444, 2026-11-15 to 2026-11-17):

- `status` answers, also paused (the GUI script keeps running at speed 0). Reading the command file adds no log
  lines; each command adds one. The ESC menu and the in-game loading screen stop it.
- Speeds 8 / 16 / 64 are accepted, but on a mid-size save the rate topped out around x3 on average (x12.7 at most
  over one second), limited by CPU.
- `info` shows mod settings in the same shape as mod presets.
- `load` (also with `--param`; the other mod received the changed setting) loaded in 33 s and started without the
  button. A loaded game starts at speed 0. `save` (2.5 s). `run --until` stops on the date.
- `launch` / `restart` with the menu probe; `newgame` from the main menu (1900, temperate, 32x32).
- `buy --via cmd` and `depots` answer in the expected shape. An earlier version of the gui way bought at the store
  price.
- `frame`.

Not checked yet:

- The `--via gui` ways of `buy`, `duplicate`, `replace` and `sell` in their current form (run in the speed
  control's recipe), and whether that recipe runs while paused.
- `money`: whether the balance changes in game and the entry stays in the save.
- Line commands beyond the first test (`stations`, `stations --near`, `lines` and a two-stop `line create --via gui`
  worked on a small save): `line update`, `line delete`, `--cargo`, `buy --line` and the `--via cmd` way. Try them on
  a small save first; the details are under Implementation notes.
- `window` and `event` opening windows, the speed label's position and look, `tool` closing a window with `pop`.
- The ×8 / ×16 buttons in game: their look and width beside the base buttons, the lit button, and the speed they set.
- Whether `app.quit` ends the game without a confirmation dialog.
- `connect`, entirely: see "Connections" under Implementation notes for what may go wrong, riskiest first.

## Tests

```
luajit tests/run.lua                                   # the mod: pure logic, and the real scripts on a fake game
python3 -m unittest discover -s tests -p 'test_*.py'   # tf3ctl.py, end to end against the fake game and real files
```

Neither needs the game. `tests/fake_tc.lua` is a stand-in for Track Connector written for these tests: it
imitates what `connect` relies on (its module functions, its game script's events and state), contains none of that
mod's code, and was checked against no running copy of it.

## Notes

- **Exchange folder.** `recordings` is used first. The base lists every file in `mod_presets` as a mod preset (no
  extension filter), so files there showed up in the player's preset list; nothing in the base GUI lists
  `recordings` or `keyframes` (the debug camera tool uses them). `saveUserdata` never overwrites a file, so every
  answer gets a new name and the tool removes old ones. `clean` removes every probe file (the current load's too
  when the game is not running).
- **Answers.** Every command gets exactly one answer. Exception: when a load or new game replaces the script while
  a command waits, no answer comes and the tool times out. Asynchronous commands (vehicles, lines, money) give up
  after 60 s with what they have; the tool waits 90 s for them. `state` needs no mod: it reads the game's log and
  processes. Lists in answers are written as `[]` when empty.
- **Pickup.** When a command is not picked up and the game is not in a game (by its log), the tool stops after 3
  s with exit code 3 and withdraws the command. The ESC menu and dialogs do not show in the log, so those end as
  "no answer" after 30 s.
- **`run`** ends as `stalled` when the date does not move for 20 s. When the tool exits early (timeout, Ctrl-C) it
  sets speed 0. The answer waits for the pause command's callback (or says `stopConfirmed: false` after 2 s).
- **`save`.** The save callback reports no success, so `ok` means the save is in the list afterwards; `overwrote`
  says whether one of that name existed.
- **Status.** `modParams` lists every enabled mod (`{}` for one without settings), so it shows whether `--add` /
  `--remove` took effect. There is no API to read the enabled mod list at run time.
- **Main menu.** Loading or starting a game from outside React before mod.io is ready sent the base main menu
  into a dialog branch in its recipe body (`GetApi() must not be called in the recipe itself`) and the menu UI
  reloaded (the load went on; 2026-11-16). The menu probe therefore waits up to 30 s for mod.io (while
  `restrictedModeAllowed=false`, 2-3 s after the menu appears, or while mods download) and logs
  `waits: mod.io is not ready` / `waited N s for mod.io`. A second load or new game sent while it waits is
  refused (`still waiting`). A new game from the menu takes the climate's default town names (temperate and
  subarctic: European); the name list is not part of `StartGameParams`. A save loaded by hand stops the menu probe
  as soon as game time can be read, so the in-game probe takes over.
- **`--script`** (found in the game binary, 2026-11-16) takes a resource path (`<mod>::/<file>`). A disk path, or
  a file missing from the base `_content.json`, is "not cached" and the game exits. If `startup.lua` fails to load,
  the game goes on without the menu probe.
- **`quit`.** The probe calls `app.quit` the frame after it answered (after a save in progress). SIGTERM only opens
  the game's quit menu (2026-11-16). `restart` waits 5 s after the game ended before launching, since Steam may
  still count it as running. The game's main thread is named "Main Thread", so `pgrep -x TransportFever3` does not
  find it; the tool looks at command lines.
- **Speed buttons and label.** The base speed buttons are 0/1/2/4 only and select none for other speeds. The mod
  replaces `game_bar_widgets.GameSpeedControl` with a `react-replacement-config` (order 500) and draws the base
  recipe unchanged (`CallOriginalRecipe`), then a second button group with ×8 and ×16, then the label. The extra
  group lights from the same `gameSpeedHelper.getSpeed()` the base buttons use, and its click sends
  `api.cmd.makeGameSetSpeedCmd` from `onValueChange`, where the base buttons send theirs; it does not go through
  the helper's `setSpeed`, which clamps to `api.gui.game.getEstimatedMaximumGameSpeed()`. The helper picks the new
  speed up from the `GAME_SPEED` component on its next step. Note that the base's pause key resumes through the
  helper, so resuming 16x from a pause is clamped like a base button. The buttons hold text (`×8`, `×16`), since the
  base has icons up to 4x only, and are a group of their own beside the base group. A mod that replaced the recipe
  before this one (lower order) is drawn instead of the base buttons and of the ×8 / ×16 group, with the label
  beside it. Time Warp (mod.io 6453396) replaces the same recipe with 8x/16x buttons of its own (order 10) and sets
  the same CSS widths, so only the stylesheet loaded last would size the bar: it is listed in `incompatibilities`
  (the game warns, but can be told to go on). GW Faster Game Speed swaps the module's table at run
  time, and only one of the two takes effect. Mods that replace the whole game bar or `game.tl` with a copy
  (Upkeep Inspector, Buy Industries) still call `game_bar_widgets.GameSpeedControl` and the same
  `GameSpeedHelper`, so the replacement applies there too. UI Overhaul does not touch the speed control. No game
  API is called in the recipe body or its steps: react runs them on worker threads too, and
  `api.util.getApplicationTime` there crashed TF3 with SIGSEGV right after every load (2026-11-15). Game calls
  happen in `react.enqueueJoin` and in the buttons' `onValueChange`, on the main thread.
- **`frame`** takes the last frame of the newest finished chunk of Steam's background recording
  (`userdata/<id>/gamerecordings/video/bg_3493540_*`) with ffmpeg: with the UI, a few seconds old, at the
  recording's resolution, without focusing the window or sending keys. The recording folder is chosen by its last
  written chunk, not by its mtime: Steam trims old chunks out of a stopped recording, which bumps that folder's
  mtime, and once picked a recording stopped 81 minutes earlier. `screenshot` (`api.gui.camera.takeScreenshot`)
  wrote no file in a test (it seems to be for photo mode).
- **`window`** opens with `react.fireEvent(nil, "selectEntity", {entity})`, as the base statistics and line
  windows do. Events can only be fired from inside react, so the GUI script writes the request into the GUI save
  data (`api.gui.game.setGuiSaveData`, kept per mod in C++) and the speed buttons' recipe reads it in
  `react.enqueueJoin`. A plain Lua table shared between the two never reached the recipe (they are separate Lua
  states). Requests left from the previous game are dropped on load, so a request sent right after a load may time
  out.
- **`event`** takes a react event name and, as its parameter, a JSON object of plain values. Its answer and `tool`'s only say
  that the request was written; whether a window opened shows in `frame` or the log.
- **`tool`** pushes the module's tool on the game's tool stack as the base buttons do
  (`gameCtx.toolStack:get():getApi().push(tool, nil, {gameCtx})`). Only tools a module returns can be opened:
  music (`/gui/music_player/music_player.tl`) and calendar (`game_bar_widgets.CalendarEditorTool`); statistics are
  local to `statistics.tl`. `--module` and `--field` point at other modules.

## Implementation notes

### Vehicles (`buy`, `duplicate`, `replace`, `sell`, `depots`, `vehicles`)

- `--via gui` (default) calls the base `vehicle_react_util.HandleVehicleChanges`, which the vehicle store and the
  clone button use: it stamps the current game time as `purchaseTime` on parts that have none, turns autoload on,
  then sends `makeVehicleBuyCmd` / `ReplaceCmd` / `SellCmd`. Parts come from the base `vehicle_util.makePart`. The
  module cannot load in the GUI script's Lua state (`react.RegisterRecipe` fails there with
  `react.lua:298: table index is nil`, 2026-11-16), so the request goes through the GUI save data to the speed
  buttons' recipe, which runs it in its join (`content/vehicle_configs.lua`, `performGui`) and reports under its
  own key (`hummer_remote_probe.vehicles`). Success is judged from the engine state (new, changed or removed
  vehicles), so an answer comes even without the report (`notes` says "no report"). If the module does not load,
  the command fails; it never falls back to cmd silently.
- The recipe is not the store window's react state, so it is not known whether it shares module instances. Mods
  that replace files or rewrite `metadata.cost` reach it; mods that patch module tables at run time may not.
- `--via cmd` sends the engine commands only, with `purchaseTime` 0 (see Safety).
- Answers: `via`, `balanceBefore` / `balanceAfter` (`getPlayersBalance`, read 3 frames after the result), `spent`
  (negative for a sale), `gameTimeBefore` / `gameTimeAfter`, `storeParts` (per part: model id, file name, price and
  price scale before sending and when answering), `storePriceTotal` (sum of the parts' price times count, as the
  store adds them up, even for a negative price, with a note), `sentParts`, `vehicles` (read back: parts, purchase
  time, maintenance state, `partPrice`, line, depot, `depreciatedValue`), `notes`; `model` for buy and replace,
  `before` for replace and sell, `source` for duplicate, `vehicleIds` for buy and duplicate. With `--line`, the
  answer waits until the vehicle is on the line and reports `setLine`.
- `buy` needs `--depot` (the store only picks a depot when opened from one); count 1-20; with `--line` the first
  stop is stop 0. `duplicate` copies the config with parts at `purchaseTime` 0 and maintenance 1, as the base
  clone does; depot and line default to `findBestLineAndDepotForVehicle`.
- `replace` and `sell` via gui get no callback from the base, so the mod watches the vehicle each frame. A replace
  is done when the parts match what was sent or differ from before (`matchesSent` tells which). When the new parts
  equal the old ones, it answers `ok: false, uncertain: true` rather than guess.
- `depots` lists the company's depots only (`requireOwnedByPlayer`, as the line manager). No position (no API to
  read it was found). The kind (road / tram / rail / water / air) comes from the transport modes; `carrier` was
  OTHER for all 49 depots in a test (the base also goes by transport modes), so `carrier` / `carrierRaw` are for
  reference. Maintenance buildings show up too (`maintenancePool`).
- Requests left in the GUI save data when the recipe first reads it are from the previous game and are not run;
  the GUI script also clears them on every load. Done requests and reports are kept in module variables, so a
  redrawn speed control does not lose them. Only the newest 10 reports are kept.
- Unchecked: whether `getPlayersBalance` / `getDepreciatedValue` / `getPartPrice` work in the GUI state; the first
  callback argument of `makeVehicleBuyCmd`; whether `getComponent` returns nil right after a sale; whether
  `transportModesToCarriers` works in the GUI state.

### Money

`money --set N` / `--add N` sends an `api.type.JournalEntry` (amount = the difference, time = -1, category OTHER)
with `makeJournalBookAssetCmd`, as the base sandbox money editor does. With infinite money
(`getPlayersBalance` nil) it fails. Amounts are rounded to integers and refused beyond 2^53-1. The answer has
`balanceBefore` / `balanceAfter`, `amount` and `callback`; with `--set`, `notes` says "set not reached" when fares
came in meanwhile (use it paused).

### Lines (`stations`, `lines`, `line`)

All unchecked in game. There is no command to build stations.

- `stations` lists the company's and nobody's station groups (`isOwnedByPlayerOrNotOwned`, as the base station
  statistics): `id`, `name`, `stations`, `terminals`, `carriers`, `owner`, `lines`, `position` (centre of the
  first station's bounding volume). `--name` matches a part of the name (any case); `--near <entity> --radius <m>`
  (default 1000 m) filters by horizontal distance from an entity with a bounding volume and adds `distance`.
- `lines` lists the company's lines: stops (station group, station and terminal, 0-based), vehicles, carriers,
  `customFilters`, `loads` (cargo some stop loads) and `vehicleCargo` (cargo the line's vehicles can carry).
- `line create --stops A,B,...` takes station groups in order, by id (a station entity means its group) or name
  (exact match first, then a unique part; several matches are an error with the candidates; names with commas need
  the id). Platforms are assigned automatically. The default name is the base `makeLineName` (gui) or "Line N"
  (cmd).
- `line update <line>` takes `--stops` (replaces the stop list), `--name` (`makeEntitySetNameCmd`) and / or
  `--cargo`. Stops of the same station group keep their settings, as in the base. When a new stop has no
  platform, every stop is reassigned (`allowTerminalChanges = true`) as the base does, so existing platforms may
  change; via gui the base `autoLoadConfig` also redistributes cargo (except on lines with custom filters).
  Reordering alone keeps platforms. Waypoints are lost. Via gui without the recipe's report, an update counts as
  done when the stops are as asked and differ from before, so a `--cargo`-only change, or one that keeps the stops,
  times out after 60 s.
- `line delete <line>` sells the vehicles first (only with `--sell-vehicles`), and sends `makeLineDestroyCmd` once
  the sale succeeded.
- `--cargo <id or name>` makes every stop load only that cargo, as the base cargo filter does (`load` true for
  that cargo, `maxLoad` 1, `customFilters = true`). A stop whose platform handles neither loading nor unloading of
  that kind (passengers or cargo) is an error before anything is sent. There is no `buy --cargo`: the base store
  does not pick cargo per vehicle; what a vehicle loads is set by the line's stops.
- `--via gui` (default) builds the line with the base `line_util.tl` as the line manager does (`makeNewStop`,
  `autoLoadConfig`, `autoAssignTerminals`, `makeLineColor`), in the speed buttons' recipe like the vehicle
  commands; report key `hummer_remote_probe.lines`. `--via cmd` builds `Line.Stop` itself with platforms from
  `lineSystem.getBestLineAssignment` (0/0 where it finds none, as the base, noted), loads passengers at passenger
  stations and otherwise only `--cargo`, waiting time 30 s for road or tram stations without rail and 60 s
  otherwise.
- Checked before sending, either way: at least 2 stops, no two neighbouring stops (last and first too) in the same
  group, every group the company's or nobody's with stations and platforms, a carrier common to all stops; after
  building, every stop's station and terminal exist. Otherwise nothing is sent: the base may send -1 for a group
  without stations, which could hit an engine assertion. `load` / `maxLoad` have one entry per cargo type, as the
  base builds them.
- Answers: `ok`, `action`, `via`, `line`, `name`, `stops`, `vehicles`, `carriers`, `loads`, `customFilters` (read
  back), `sentStops` / `sentName`, `notes`, `failures`; `before` for update; `removed`, `before`, `soldVehicles` for
  delete. `ok` is false when the stops or the name differ from what was asked.
- Unchecked, riskiest first: building `Line.Stop` via cmd (defaults of `api.type.Line.Stop.new()`, Lua tables in
  `stopConfig` / `alternativeTerminals` / `waypoints`, copying with `api.type.Line.new(line)`); copying a
  `StopConfig` with `StopConfig.new(stop.stopConfig)` for `--cargo`; platforms of another carrier assigned by the
  engine; the line entity in `makeLineCreateCmd`'s callback; deleting a line with vehicles (the mod keeps the base
  order: sell, then delete); whether a town entity has a bounding volume for `--near` (if not, use an industry or
  station); whether the station and line systems used work in the GUI state; whether the report key can be
  written ("line report not written" in the log if not).

### Connections (`connect`)

All unchecked in game. How it works: the GUI script requires Track Connector's planner and proposal modules
(`ethan_track_connector::/track_connector/tc_planner.script.tl`, `tc_proposal.script.tl`), builds a small map for
the planner (its `World`) from the engine, runs the planner a 15 ms slice per frame in `guiUpdate`, turns the result
into Track Connector's `Route`, and sends its game script the events its own tool sends
(`makeScriptingSendEventCmd("", "TrackConnector", ...)`: `tc_settings`, `tc_setFromEnd`, `tc_setToEnd`, `tc_route`,
`tc_estimate`, then `tc_build`). The dry run and the build are Track Connector's; the answer reads its game script
state (`preview`, `estimates[key]`, `builds`, `build`) from the `GAME_SCRIPT` component.

The map is the probe's own code; the idea is the one Track Connector's tool has too (read the land around the
way through the octree, buildings as blocked land, lines as crossings). Terrain height (asked every 4 m) and water (every 10 m; over water the planner sees the
water level plus 6.5 m, so it bridges), constructions and town buildings as blocked land, and road and track pieces
as crossings, on 5 m cells in 200 m blocks read through the octree. An industry's parts that the engine keeps apart
from its construction (entities with `INDUSTRY` or `SUBCONSTRUCTION` and no `CONSTRUCTION`) block too. The blocks of
the area the planner searches (the ends' box and 1.5 km round it, or 0.6 times their distance when that is more; inside
the map; at most 3000, nearest the straight line between the ends first) are read before planning, six per frame;
others when the planner first asks. The planner asks from inside its own coroutine, so after every three such reads
it waits for the next frame right there (a count, not a time: `os.clock` runs ahead of real time on Linux); a
planner without a coroutine cannot wait, and more than 8 in one of its slices are logged once. The two ends' own
pieces and those of the construction they belong to are no crossings; that construction still blocks. Only each
end's mouth is open: 10 m round the end node, and a wedge out the way the end points (6 m to each side at the node,
0.15 m more per metre out) that runs 20 m, or 10 m past every building the end node lies in (an end of a
construction's own road lies inside the construction's box), at most 150 m. `plan.map` has `endConstructions`,
`leftOutPieces` and `mouths` (`from` / `to`: `length`, and `inside`, how many buildings the end node lies in). Not
there, compared with Track Connector's own tool: level crossings, the heights of the roads and tracks crossed (the
planner then assumes 7.5 m over and 9.5 m under the ground), running alongside an existing line (it counts as a
crossing, so a route may keep away from one or bridge it), water areas learned from refused builds, branching off
the middle of a piece, double and more tracks, station platform layouts, route goals.

Unchecked, riskiest first (the first ones could take the game down):

- Requiring Track Connector's Teal modules from this Lua GUI script, and sending scripting events from `guiUpdate`
  (Track Connector does both from its own GUI script).
- Engine calls made inside the planner's coroutine from `guiUpdate`: the octree, `terrain.getHeightAt` /
  `isOnWater`, components of whatever the octree returns. Street-system calls are only made on entities that are
  nodes (asked about anything else, the engine dies on an assertion), and the ends are checked again before the
  route is sent.
- `streetConnectorSystem.getConstructionEntityForStation` (if missing, a construction around the station that lists
  it is looked for) and the `roadTemplate` field of a road piece (if unreadable, a country road of the game's year is
  used).
- `api.engine.util.getYear` (else the calendar date of the game time) and a street template's `availability`: when
  either cannot be read, no type is refused or replaced for its years (a note says so). Whether a road from an
  industry's entrance road, kept out of the industry's land, is accepted by the game there, and whether the mouth's
  wedge is wide enough for the new road's own width.
- An end deep inside a building's box: the planner's coarse map (100 m cells or more, each blocked when most of five
  points in it are) may not see the narrow mouth and find no way out. When no route is found, a note names such an
  end (`plan.map.mouths.*.inside` above 0).
- Whether the game script takes the events while the game is paused, and how fast (the wait is 30 s).
- The planner's time slice: Track Connector measures it with `os.clock`, which on Linux is the CPU time of the
  whole process, so a slice may be much shorter than 15 ms of real time and planning slower than in its own tool.
  The map read before it goes by blocks per frame, not by time; how long six blocks take on a dense map is unknown.
- Track types: a short `--track` name is turned into a template by Track Connector, which quietly uses the
  standard track when that template is missing; `connect` refuses then instead.
- A build's outcome: Track Connector writes it in the build command's callback. If the state still says "nothing
  happened" after 5 s, the build counts as done when new pieces join both ends (a note says so).
- `newEdges` / `newNodes` are whatever appeared along the route between before and after the build: a road a town
  built meanwhile would be in them.

## License

MIT. See [LICENSE](LICENSE).

Track Connector (`ethan_track_connector`) is another author's mod. It is not part of this repository, not covered
by its licence, and not connected with this project; `connect` only loads it from the player's own installation.
