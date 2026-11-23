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
`--via gui` way of the vehicle and line commands (without them `window`, `event` and `tool` fail after 10 s with
`"relayed": false`, the vehicle and line commands after 60 s with "no word from the speed control").

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
`gameState` field says which), 4 refused: the running game is not this `--owner`'s (nothing was sent; see
"Only the owner who started the game changes it").

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
python3 tools/tf3ctl.py launch --new --editor --size tiny --no-towns --no-industries   # the map editor
```

`--editor` (with `newgame` or `launch` / `restart --new`) starts the map editor instead of a game:
`StartGameParams.isMapEditor = true`, the rest as a new game. A map keeps the mods it was made with, so its mods are
the official ones installed (`ug_*`) and the probe, not the running game's (`--add` / `--remove` still apply), with
their default settings. `status` answers `mapEditor` (`gui`: `api.gui.game.isMapEditor()`, `modParams`: the base's
`isMapEditor`). **Not checked in game yet** (written 2026-11-22): whether the editor opens this way, and whether
the probe answers inside it.

A new game gets the town and industry placement the base new-game page computes from the base settings
(`locations.towns.frequency`, `locations.towns.populationDensity`, `locations.industry.initialIndustryDensity`,
1-based levels, default 3): `townFrequency`, `populationDensity` and `industryDensity` through the base's
`difficulty_util.getScale` (0.4, 1.0 and 1.0 at the defaults), so `--param :locations.towns.frequency=5` works as
in the menu. If `difficulty_util` cannot be loaded, the mod uses its copy of the same tables (base build 40444) and
the answer carries `warnings` (also printed by the tool). A base setting that is missing is taken as the menu's
default; one out of range gives 1.0, as the base's `getScale` does (the start time and clouds: the first entry);
both with a warning. The start time and clouds follow `gameTimeConfig.timeOfDayMode` and `weatherConfig.dynamicWeather` as in the
menu: 14:00 and clear by default (before 2026-11-23: always 12:00, and the densities were left at the engine's
`Locations.new()` values). `newgame --dry-run` shows them in the plan: `locations` (what is sent as
`locationsConfig`), `startLevels`, `locationsSource` (`difficulty_util` or `copy`), `timeOfDaySeconds`,
`cloudCoverage`.

The base's company progression (company rank, perks, ticket price multiplier) starts from the world's town
population when the game starts: on the start event `initNewGameFromMap` the base's company script stores it as
`basePopulation`, and company_growth does nothing while it is 0. A game started with no town population
(`--no-towns`, or a flat base with towns placed later) keeps `basePopulation` 0: no rank (the bottom-left company
button shows "Achievements"), no ticket price multiplier, and `company_growth.script` logs an error at every ticket
price (when its companyState is nil); towns placed later do not change it. Measured 2026-11-23: a `newgame` game with generated towns had
`basePopulation` 793 and its rank after 10 days with nothing sent; with `--no-towns` it was 0, and still no rank 20
days after towns were placed. After a new game (not the map editor) the tool sends `company init` (below) and keeps
its answer as `companyInit`: it sends nothing when the start gave a `basePopulation`, and with no town population
it says so (`noPopulation`: place towns, then `company init`). `--no-company-init` leaves it out; a failed one is
a warning, the game is started either way.

```
python3 tools/tf3ctl.py company                       # read only: the base's company progression and what is missing
python3 tools/tf3ctl.py company init [--dry-run] [--force]   # test saves only: send the start event again
```

- `company` reads the state of `::/game_mechanics/company/company.gs` (`basePopulation`, `version`, `companies`)
  and of `company_progression.gs` (`growth.initialized`; the player's `level`, `potentialLevel`, `experience`,
  `ticketPriceMultiplier`), the towns' population now as the base counts it (`worldPopulation`), `rankButton`
  (`rank` or `achievements`: what the company button shows; the rank only for an entry with experience above 0)
  and a one-line `diagnosis`.
- `company init` sends `api.cmd.makeScriptingSendEventCmd("", "", "initNewGameFromMap", {})` when `company.gs` has
  no `basePopulation`, or has 0 while the towns have population now; `--force` sends in any case. Otherwise it
  sends nothing and says why (`reason`; `alreadyInitialized`, or `noPopulation` when both are 0). After a send it
  waits at most 15 s for a read that shows the event ran (`basePopulation` set anew, or company_growth's entry for
  the player emptied) and answers `before` / `after`, `expectedBasePopulation` (the towns' population) and
  `basePopulationMatches` (within 10 %). company_growth makes the company's level in its own update: run the game
  a few days and look with `company` (`growth.initialized` true, `growth.player.level`, `rankButton` `rank`), as
  `check` in the answer says (`basePopulationMatches` only shows the event took today's towns). Towns just placed
  give a small `basePopulation`, and the ranks then come sooner. Refused in the map editor and in a mission.
- In the base this event also resets the company's progression and the towns' cached ratings, the subventions and
  the notifications, sets the game speed to 1 (as a base new game starts) and the welcome flag, and other mods'
  scripts may listen to it: test saves only. After a send that timed out, another is refused unless `--force`:
  its event may still run later, and a second one would reset the progression again.
- **Not checked in game yet** (written 2026-11-23): whether a sent event reaches the scripts at all (they subscribe
  to event names, and none of the base's subscribes to this one), and whether the game runs it while paused.

`--param mod:key=index` takes the 1-based index into that setting's `values` in the mod's `mod.json` (as mod
presets store them); base game settings are `:key=index`. This mod always stays enabled: without it nobody would
answer.

### Starting, quitting and restarting the game

```
python3 tools/tf3ctl.py launch [--load SAVE | --new ...]   # when the game is not running
python3 tools/tf3ctl.py restart --load my-save [--param ...]
python3 tools/tf3ctl.py restart --new --year 1900 --size small --add example_mod
python3 tools/tf3ctl.py restart --lang de --load my-save   # this start in German (launch takes --lang too)
python3 tools/tf3ctl.py quit [--kill]
python3 tools/tf3ctl.py state                         # in_game / menu / loading / main_menu / starting / closed / crashed
python3 tools/tf3ctl.py restore-profile               # put profile.lua back from --lang's backup now
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

`--lang CODE` starts the game in another language (`de`, `en`, `ja`, ... or `pt_BR`, `zh_CN`, `zh_TW`; a code the
install's `base/strings` lacks is refused; when the install is not found, a code outside the base game's 13 languages
is refused), e.g. to see a mod's texts fall back to English. The game takes its language only from `profile.lua`
(`language = { code = "ja", ... }`, next to `settings.lua` in the userdata `local` folder); no command-line option
for it was found. So, while the game is not running, the tool copies `profile.lua` to `profile.lua.tf3ctl-backup`
beside it (only when no such backup is there: the first one holds the original) and changes only that code. Putting
it back also changes only the code: the original code from the backup goes into the file as it is now, and once the
file has it, the backup is removed. The game rewrites `profile.lua` while it runs, so whatever it or the player
changed there in the meantime (the last game, other settings) stays, even when the backup was left for days. This
happens after `quit` once the game is gone, before the next `launch` / `restart` (a crashed game leaves the backup
behind; without `--lang` that start is in the original language), and by `restore-profile`; never while the game
runs. When the file or the backup does not have exactly one `language = {` block, or the code does not come out
right, the backup is kept and the command fails. `state` and `status` show `profileBackup` while a backup is there.
The backup, the change and the restore are done under a lock on `profile.lua.tf3ctl-lock` (left beside the file),
so two tf3ctl at once cannot take a changed file as the original. If `restart` fails to put the profile back or
change it after the quit, it prints the quit and `profileError` and exits 1, like `quit`: the game is then stopped.
If another tool keeps its own copy of `profile.lua`, name it in `TF3CTL_OTHER_BACKUPS`: while it exists (a folder
counts only while a file is in it), `--lang` and the restore refuse, so the copies go back in the reverse order.
Not covered: when the game ends without tf3ctl (a crash, or quit from its own menu) and is then started from Steam,
it starts in the `--lang` language; the next tf3ctl `launch` / `restart` / `quit` or `restore-profile` puts it back.

### Looking at the game

The game rewrites `crash_dump/stdout.txt` at every start, so the last run's log (after a crash, a kill or a
quit) is lost once the game starts again. `launch` and `restart` therefore copy it first to
`crash_dump/logs/stdout-<the log's time, UTC>.txt` and keep the newest 20 (the answer's `launch.keptLog`).
A game started by hand from Steam skips this: run `keep-log` before starting it.

```
python3 tools/tf3ctl.py log --grep remote_probe --tail 40   # the game's stdout.txt
python3 tools/tf3ctl.py keep-log [--list]                   # copy stdout.txt to crash_dump/logs now; list the copies
python3 tools/tf3ctl.py entities --kind town --grep ems     # ids and names: town, line, vehicle, station, industry, warehouse
python3 tools/tf3ctl.py entities --kind warehouse           # read only: each WAREHOUSE entity with its construction, stockList, stocks and capacity
python3 tools/tf3ctl.py industry-workers [--entity 51]      # read only: capacity, sims headed there, last visitors (workers script), productivity, nearest town
python3 tools/tf3ctl.py industry-stocks [--entity 51] [--grep mine] [--all-params]  # read only: stocks (cargo, capacity, count), rules (boost), productivity, the construction's .con and params (hummer_aom_upg_*; --all-params: best with --entity)
python3 tools/tf3ctl.py window --town Emsworth --focus      # open its window and move the camera (--close-all)
python3 tools/tf3ctl.py window --line "Bus 1" --manager    # that line in the line manager, as its Manage Line button
python3 tools/tf3ctl.py frame --out shot.png [--crop 1150x170+2690+1450]   # the screen with UI, from Steam's recording
python3 tools/tf3ctl.py tool music [--close]                # base windows that open as a tool: music, calendar, notifications
python3 tools/tf3ctl.py event example_window.show --param '{"page": 2}'   # fire any react event
python3 tools/tf3ctl.py script-event example_mod.apply --id example_mod --param '{"step": 2}'   # a game script event, as a mod's button sends it
python3 tools/tf3ctl.py rename "Chesham" --entity 48064   # rename a station, line, vehicle or depot, as the game's windows do
python3 tools/tf3ctl.py camera                              # x, y, distance, angle, pitch, heightAboveTerrain
python3 tools/tf3ctl.py camera --set 1200,-800,600         # x,y[,distance[,angle[,pitch]]]; the rest stays as it is
python3 tools/tf3ctl.py camera --entity 12345              # or --focus x,y,z [--distance d]
python3 tools/tf3ctl.py build-tool --res depots/road/road_depot/road_depot.con [--template N] [--seconds 60]   # (--close)
python3 tools/tf3ctl.py build-tool --menu rail [--res ...]   # the toolbar's own menu event first (road, rail, water, ...)
python3 tools/tf3ctl.py pointer 0.5,0.47 [--px]          # the game's pointer only, as fractions of its window
```

`camera` answers the values read back after the move. Numbers are checked first: NaN, infinity, a centre beyond
1e6, a distance outside 1-1e5, an angle beyond +-2 pi or a pitch beyond +-pi/2 are refused. `--entity` checks that
the entity exists. Refused in the main menu.

`build-tool` opens the construction menu's placing tool for one construction, with two base events sent through
the speed control one after the other (1.5 s apart, so the menu is open before the next one):
`setMenuFilter` with the construction's tag (`resName`, or `resName@N` with `--template`), so the menu lists only
it, then `constructionMenuSelectTabForConstruction`, which opens its tab and picks the first item. Undoing it:

- the mod itself clears the filter `--seconds` after (default 60, at most 600), so a tool that died midway does
  not leave the menu showing one building;
- `build-tool --close` clears it at once;
- loading a game or quitting also clears it (the filter is GUI state; it is not saved).

The resName must exist (`api.res.constructionRep`). A construction not available in the current year is not
listed, and module tabs (dynamic) are not covered.

**Seen in game (2026-11-18): the filter and the select alone did not open the tool** (the road depot: the log said
no construction menu entry was found, and the filtered menu was empty). What did work is the toolbar's own event:
`--menu rail` sends `openRail` (as the rail button does), which opens the rail menu with its first item, a
station, as the placing tool. `--menu` alone sends only that event, with no filter to clear. With `--res` too, the
filter and the select follow it 1.5 s apart; whether that then picks the given construction is not checked yet.

The placement preview and its tooltip only appear when there is a proposal under the mouse, so the game's pointer
has to be over the 3D view: `pointer FX,FY` puts it there without a person. It sends the game window synthetic
X11 `EnterNotify` and `MotionNotify` events (through libX11 with ctypes; TF3 runs under XWayland): the game's hover
and its drawn cursor move, the real pointer does not. It never sends a button or key event. For a cover shot:
`camera --set` to the place, `build-tool --menu rail`, `pointer 0.5,0.47`, then `frame`; reload the save (unsaved)
to put the menu away. With the company's money at 0 the tooltip says "not enough money" instead of the cost.

The events go into the same queue as `window`, `event` and `tool` (see `event` below), so nothing is overwritten;
one of those sent within the 1.5 s gap fires between the build tool's events, which may close its menu. Wait for
`build-tool` to finish before sending them.

### Vehicles, money and lines

```
python3 tools/tf3ctl.py depots [--grep bus]
python3 tools/tf3ctl.py vehicles [--line 21]
python3 tools/tf3ctl.py vehicles --entity 601,602 --state [--since 120000]
python3 tools/tf3ctl.py vehicles --entity 601 --state --at-terminal --every 2 --count 300   # JSON Lines with gameTime
python3 tools/tf3ctl.py persons --vehicle 601 [--limit 200] [--every 5 --count 120]   # or --line 21
python3 tools/tf3ctl.py models [--grep trillium] [--carrier water] [--limit 200]
python3 tools/tf3ctl.py models --mu [shinkansen]   # read only: the multiple units (.mu.lua) and the names buy takes
python3 tools/tf3ctl.py buy --model bus_1900 --depot 301 [--line 21] [--count 2] [--via gui|cmd]
python3 tools/tf3ctl.py buy --model shinkansen_0s.mu.lua --depot 302 [--line 21] [--count 2]   # a multiple unit
python3 tools/tf3ctl.py duplicate --vehicle 601 [--depot D] [--line L]
python3 tools/tf3ctl.py replace --vehicle 601 --model bus_1920
python3 tools/tf3ctl.py sell --vehicle 601
python3 tools/tf3ctl.py money --set 10000000 | --add -5000
python3 tools/tf3ctl.py stations [--name cent] [--near 11 --radius 800]
python3 tools/tf3ctl.py stations --catchment 47   # what a station (or group) reaches: town buildings, industries
python3 tools/tf3ctl.py stations --catchment 47 --paths 5   # and why: circles, nearest houses, walking
python3 tools/tf3ctl.py lines [--name probe]
python3 tools/tf3ctl.py lines --problems [--line 23]   # path problems, platform modes, the line's mode union
python3 tools/tf3ctl.py line create --stops Central,42 [--name "[probe] A"] [--cargo coal] [--via gui|cmd]
python3 tools/tf3ctl.py line update 21 [--stops 41,42,43] [--name N] [--cargo C]
python3 tools/tf3ctl.py line create --stops 47,48 --terminals 0:2,0:1 [--load-mode all,available]
python3 tools/tf3ctl.py line update 23 [--terminals 0:2,0:1] [--load-mode any]
python3 tools/tf3ctl.py line update 23 --force-unload 0,1   # per stop: unload into a full input stock too
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
  taken. A depot's entity id (as `depots` lists it) stands for its construction's free ends, its frozen nodes left
  out (`getConstructionEntityForDepot`): one is the end; two or more are named and refused (give one node); none
  is refused (its track may be joined to a line already: `depots` lists `joinedEnds`).
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

### One construction on the map (`build`)

```
python3 tools/tf3ctl.py build --res road_bridge_ramp::/road_bridge_ramp/ramp.con --at 1200,800        # on the terrain
python3 tools/tf3ctl.py build --res road_bridge_ramp::/road_bridge_ramp/ramp.con --at=-300,450,82 --angle 1.5708 \
    --params '{"rbr_height": 8, "rbr_length": 120}' [--name "Ramp A"] [--seed 3] [--dry-run]
python3 tools/tf3ctl.py build --remove 51234[,51240]      # take away constructions the probe built
python3 tools/tf3ctl.py build --remove-all                # all it built since this load
python3 tools/tf3ctl.py build --res <resName> --at 2600,3400,20 --dry-run --engine-check --collision-detail   # the whole ProposalData
```

**For test saves.** `build` puts one construction (a `.con`: a depot, a station, an asset, an industry, another
mod's construction) at a point, with no click and no key: a `SimpleProposal` with one `ConstructionEntity` goes to
the engine as `api.cmd.makeWorldBuildProposalCmd` from the probe's GUI script, the way a mod's own tool builds. The
engine checks it as it checks a player's build (collisions, terrain, money); a refused build is not built
(`ignoreErrors` is off), and nothing of the player's or of a town is knocked down for it.

- `--res`: the construction's resource name. A mod's `content/<dir>/x.con.lua` is `<modId>::/<dir>/x.con`; a base
  game one starts with `::/` (`depots/...con.lua` is also tried as `::/depots/...con`). A name the game does not know
  is refused before anything is sent, with up to 12 names like it (the same file name, or the same mod's).
- `--at x,y[,z]` in metres (a negative x: `--at=-300,450`). Without z the terrain's height there is used
  (`api.engine.terrain.getHeightAt`); the construction's own terrain alignment then levels or cuts the ground, as
  when a player places it. Under water that height is the bottom, not the surface: **give z for a construction on
  water** (a shipyard, a harbour). `--angle`: radians about the vertical.
- `--params`: a JSON object laid over the construction's own defaults (each param's `numbers[defaultIndex]`, as the
  game's construction menu starts them). The values are the params' values, not indexes into their lists: a param
  with `numbers` takes one of its numbers (`"rbr_height": 8` for 8 m), a param without `numbers` takes its index
  (that is its value). `seed` is 1 unless given (`--seed`, or in `--params`), so the same placement looks the
  same each time. The probe adds `remote_probe_build = 1` to the params, its mark (see `--remove`); the
  construction's updateFn does not know the key and leaves it alone.
- The answer: `entity` (the new construction), `construction` (`fileName`, `name`, `depots`, `stations`,
  `industries`, `stockLists`: the stock lists under it, `entity` / `kind` / `stockList`, e.g. a warehouse's
  WAREHOUSE subconstruction, and `ends`: the free ends of its own road or track pieces with their positions, candidates for
  `connect --from`; and `connectable`: where a `road` can join it, see `road`), `cost` (the engine's), `balanceBefore` / `balanceAfter` / `spent`, `errors`, `warnings`,
  `collisions` (ids in the way), `params` as sent, `at` (with the z used, `zFrom`). A refusal is `ok: false` with
  the engine's messages in `error`.
- The reason of a refusal (`build` and `road`, built or a dry run's engine check): the engine's
  `errorState.messages` (ProposalData, `type.d.tl`), else its `infos` or `warnings` (named so), else
  `no message (...)` with the fields read in `errorStateRead` (e.g. `resultProposalData.errorState: critical true,
  messages 0, warnings 0, infos 0`, or `errorState: none`). A build or a road refused with no message asks the engine about
  the same proposal again (`makeProposalData`, both contexts, nothing sent) and takes its message (`recheck`;
  `recheckNote` when that says buildable). tf3ctl then adds the game log's `ProposalData error: ...` lines written
  while the command ran (`proposalLog`; the Simulation Thread writes them) and, when the answer had no message,
  puts their text in `error` (`errorFrom: "game log"`). Measured 2026-11-23: a construction placed over water at
  the map's edge was refused with no message in the callback, while the log said `ProposalData error: 陸上に配置`
  ("place on land"); collisions (`衝突`) did come with their message. Another mod's proposal in the same seconds
  may write a line too (`proposalLogNote`).
- `--dry-run --engine-check` asks the engine about the same proposal a build sends, building nothing
  (`makeProposalData`, as `road`'s; it counts as changing the game): `buildable`, `verdict`, `errors`,
  `collisions` with `hits`, `cost`, and `footprint`: the box the construction takes there (the engine's
  `toAddData` bounding volume less the point: `x0`, `y0`, `x1`, `y1`, `height`, axis aligned in the world).
  `fit` takes its box from it.
- `--dry-run --engine-check` asks the engine in two contexts: the proposal alone (the engine's own context, the
  form known to work on the GUI thread) and the proposal with the build's Context (player, `gatherFields`,
  `gatherBuildings`, `cleanupStreetGraph` as the build sends them). The verdict is the build's context's, unless
  only the engine's own refuses (the stricter is taken); `engineCheck` names the form, `engineContexts` has both
  (`own`, `build`: each `verdict`, `critical`, `errors`, `warnings`, `infos`, `collisions` count, `cost`, or
  `raised` when that form raised), and when they differ `contextsDisagree: true` with `contextsNote`. Why: the
  engine's own context gathered fields where the build collided, and said buildable on water where the build was
  refused (2026-11-23). Whether the Context form judges as the build does on the GUI thread is **not checked in a
  game yet**; when it raises, the answer is the engine's own context's as before (`engineContext`, `caution`).
- `errorState.infos` with `critical` not set count as a refusal in `--dry-run --engine-check` (`build` and `road`,
  and so in `fit`'s checks): `buildable: false`, `verdict: "refused"`, `infosRefusal: true`, and `error` says the
  infos' text with `(errorState.infos, critical not set: ...)`; `critical` is left out (the engine did not set it). It goes by
  the field, not its words (they change with the game's language). Measured 2026-11-23: a road depot placed over
  water was `critical false` in both contexts with infos `陸上に配置` ("place on land") and 6 collisions, and the
  build was refused all the same (its `errorState` the same, the log `ProposalData error: 陸上に配置`); an earlier
  run had `海岸線に配置` ("place on the coastline") the same way. Infos that do not refuse a build are not seen yet: if
  one turns up, the check says refused where the build would go. `fit` also skips a place whose check is buildable
  with infos (an older mod's answer).
- `--collision-detail` (`build` and `road`; with a build, or with `--dry-run --engine-check`; off by default, the
  answer grows): the engine's whole `ProposalData` copied out into `collisionDetail`, field by field as the game's
  types name them (`api/tealdef/api/type.d.tl` `ProposalData`): `collisionInfo` (`collisionEntities[].entity`,
  `autoRemovalEntity2models`, `buildingEntities`, `removableModules`), `errorState`, `old2new`, `toAddData`
  (`boundingVolume.bbox` as `x0`..`z1`, `subconstructionDatas`), `parallelProposal`, `terrainPreviewHeightMod*`,
  `entity2tn` (each network's list lengths only), `tpNetLinkProposal`, `costs`. Maps come as `[{key, value}]`
  (their keys are entity ids). `from` says which ProposalData (`resultProposalData` of the build's callback, or
  the check's form). A field that raises is in `unread` with its error, one that reads nil in `absent`; lists
  longer than 40 items, nesting deeper than 10 and more than 4000 values are cut and named in `truncated` /
  `valuesCut`; keys the types leave out are in `unlisted` (a table's own keys, a userdata's metatable keys) and a
  few guessed names that read something on the collision records in `guessed`. With hits, `overlaps` says how
  each box in the way meets the proposal's own (`build`: the new construction's box; `road`: the piece's ends,
  no width): `overlap` per axis as `[lo, hi]`, or `gap` in metres, `meet`, and `noZ` when a height is unknown.
  The boxes are axis aligned: a T pier's box runs from its foot to its beam, so `meet` says the boxes meet, not
  which model does. With the option a dry run that is buildable but names collisions also gets `hits`, and a
  forced `road --ignore-errors` has the unforced check's detail in `unforced.collisionDetail`. Without the option
  the answers are as before. The game's types give `CollisionInfo.EntityData`
  only an `entity`: which part of the proposal collides, and at what height, is not in them; what the engine
  really hands back is **not checked in a game yet** (written 2026-11-24).
- `--dry-run` alone builds nothing and does **not** ask the engine (`road --dry-run --engine-check` does: `makeProposalData` takes a
  `SimpleProposal` on the GUI thread, though `engine/util.d.tl:939` types it for a `Proposal`; a construction's is
  not asked yet). The probe checks the name, the params it
  would send and the height, and lists the constructions within 30 m of the point (`near`, a rough look by their
  boxes). The answer has `checked: false` and no `buildable`: whether the engine takes it (collisions, terrain,
  money) is known only from a build.
- `--remove` takes away only constructions the probe built: one built since this load, if the engine still has
  the same file at the same place under that id (an id the engine gave again to something else, after ours went
  by hand or unseen, is refused); or, after a load, one whose name starts with `probe-build` (the default name,
  `probe-build N`) **and** whose params carry the probe's mark. A construction given its own `--name` can be
  removed only in the load that built it. One id that does not qualify refuses the whole command. `--remove-all`
  takes what this load built and still stands as built; the rest is dropped from its list unremoved and named in
  `forgotten`.
- No answer from the engine in 30 s: a build is then looked for by its name (each gets its own, `probe-build N`)
  and file within 60 m of the point, and if found answered as built (`why` says so). Otherwise the error names
  what to look for: if it shows up later, it carries that name and the mark, so `build --remove <id>` takes it.
- The engine can answer success and build nothing (measured 2026-11-22: a harbour whose own script failed its check;
  the log says `Error during construction update`). A build is ok only when its construction is read back (among
  the result's entities, or by its name near the point); otherwise `ok: false`, `error` says why, and tf3ctl exits
  with 1 and adds the game log's Main Thread errors written while the command ran (`logErrors`, the first 10). A
  construction that stands but cost nothing (cost and spent 0: a no-costs mod) is ok with a line in `warnings`.
- A refusal for a collision also names what is in the way: `hits`, one entry per id in `collisions`, as `around`
  gives it (`kind`, `name`, the town of a house, `x` / `y`, `box`, `sizeX` / `sizeY`, `dist` from `--at`; for a
  construction its `mouths`). An id the engine no longer has is `kind: "gone"`.
- `construction.at` is where it stands and its turn (`angle`, from its transf); each of its `ends` and
  `connectable` entries has `local` (`dx`, `dy`, `dz`: the point in the construction's own frame, dx along its x
  axis), so where its road leaves it is known wherever it is put. A `mouth` has `joined` (true when a piece that is
  not one of the construction's frozen ones meets it: a road joined to it, or its own free arms) and
  `joinedPieces`. `joins` (after a build): per road mouth its `node`, `wasThere` (the node was a road's before the
  build: the construction took it) and `nodesHere` (other road nodes within 0.5 m: a node beside it, not one with
  it). The nodes "there before" are those of the road pieces within 150 m of `--at`.
- `--remove-buildings`: the Context's `gatherBuildings` on, so the town buildings in the way go, as with the
  player's tools; `buildingsInWay` lists those the engine names (`CollisionInfo.buildingEntities`).
  `--join-streets`: the Context's `cleanupStreetGraph` on, to see whether a road end put right on an old road node
  becomes that node (`joins`). Test saves only (they change the game), and not with `--dry-run` (refused: a dry run
  asks the engine nothing). **Not checked in a game yet** (written
  2026-11-23): what the engine does with either; the answer's `contextNote` says so.
- It changes the game (as `line` and `connect`), so other clients get the usual warning; one build at a time is
  enough (each waits up to 30 s for the engine's answer).
- **Not checked in game yet** (written 2026-11-22): in particular whether the engine takes the default params, the
  mark, the name and `autoFillSlots` as sent, whether `ends` and the mark read back, and the dry run's `near`.

#### A modular construction (a harbour), an industry, and the water (`water`)

```
python3 tools/tf3ctl.py water --at 1500,-300                     # read only: the level, water or land, the height
python3 tools/tf3ctl.py water --grid 1000,-800,2000,200,50       # at most 400 points: rows of ~ (water) and . (land)
python3 tools/tf3ctl.py build --res ::/stations/water/harbor_modular.con --at 1500,-300,5 --dry-run \
    --params '{"modules": {"120001": {"name": "<module resName>"}, "120002": {"name": "<module resName>", "variant": 1}}}'
python3 tools/tf3ctl.py build --res <industry resName> --at 800,600 --no-owner   # no company's (an industry)
```

- `params.modules` is `{slot id: {name, variant, metadata, updateScript}}`, as a modular construction's updateFn
  reads it (`construction_util_serialized.d.tl`, `ModuleUpdateFnParams.modules : {integer : Module}`). A JSON
  object's keys are text; the probe makes each `"120001"` the whole number 120001 before sending, since a module
  under a text key would sit on no slot. `variant` is 0 unless given. Slot ids depend on the construction (its
  updateFn's slots); the probe does not work them out.
- With modules given, `autoFillSlots` is off (only the modules given go on), as AoM's strawberry farm does it.
  Without `params.modules` nothing changes: `autoFillSlots` stays on.
- Each module's `name` is looked up with `api.res.moduleRep.find` first; one the game does not know refuses the
  whole command before anything is sent, with names like it (the same file name, or the same folder's).
- A module without `metadata` or `updateScript` gets the module's own from `moduleRep.get` (its desc's values, as
  they are), so an engine that fills them itself gets the same. `--no-fill-modules` sends each module as given
  (a mod's toll station sends only `name` and `variant`; one sent without `metadata` is named in
  `moduleWarnings`). With filling on, a module whose metadata is neither given nor readable (moduleRep.get fails,
  or an engine map without `asTable`) refuses the whole command: a harbour's module scripts read
  `mod.metadata.platform` unchecked. An empty `modules` is refused. The answer's `params.modules` lists slot, name, variant,
  whether metadata and updateScript went, and what was `filled`.
- After a build, a construction with stations (a harbour) has `terminals` (all its stations' terminals,
  `STATION.terminals`) and `stationTerminals`; 0 comes with a `warning` that the modules may not be on their slots.
- `--no-owner` builds with `playerEntity` -1, no company's, as AoM builds its industries; by default it is the
  company's. (`--owner`, before the command, names the client, as for every command.)
- `water` reads only (no warning to others): `waterLevel` (the world's `TERRAIN.waterLevel`) and per point
  `onWater` (`api.engine.terrain.isOnWater`), `height` (`getHeightAt`, the bottom under water) and `depth` (the
  level minus the height, on water). `--grid x0,y0,x1,y1,step` takes points every step metres in the box, at
  most 400 (step at least 0.1 m), and adds `rows` (one per y from y0 up, each from x0: `~` water, `.` land, `?` not read) and the counts
  `water` / `land`. isOnWater is asked only where `isValidCoordinate` says the point is on the map: off it
  `onWater` is null, `offMap` true (`?` in the rows). The `build --dry-run` answer has `waterLevel` and `onWater` at the point too. For a construction
  on water, give z (the level from `water`).
- **Not checked in game yet** (written 2026-11-22): whether the harbour's modules go on their slots as sent, the
  terminal count, the filled metadata, `--no-owner`, and `water`'s values.

### One straight road (`road`)

```
python3 tools/tf3ctl.py road --from 1500,-300 --to 1620,-300 [--type town_new_small] [--snap 5] [--dry-run]
python3 tools/tf3ctl.py road --from 1500,-300 --to 1620,-300 --dry-run --engine-check   # asks the engine (changes the game)
python3 tools/tf3ctl.py road --from 1500,-300 --to 1620,-260 --align-to-edge from [--align-edge 9010] [--tangent-to 1,0]
python3 tools/tf3ctl.py road --from 2564,2400,110 --to 2636,2400,110 --snap 1 --bridge concrete [--dry-run --engine-check]
python3 tools/tf3ctl.py road --inspect-node 4077     # read only: what road reads of one node
python3 tools/tf3ctl.py lights --node 4077 --off [--dry-run]   # test saves only: a junction's light off
python3 tools/tf3ctl.py lanes --edge 9010            # read only: a piece's lanes (see "A road's lanes")
```

- Builds one straight road piece between two points (x,y[,z], metres; no z: the terrain's height), with no click:
  a `SimpleStreetProposal` (one new edge and its new nodes, numbered down from -1, as `type.d.tl` describes it)
  sent as `api.cmd.makeWorldBuildProposalCmd`, the way `build` sends a construction (the same context: nothing
  knocked down, errors not ignored). Changes the game: test saves only.
- `--bridge RES` builds the piece as a bridge of that type: a bridge type's resName as `api.res.bridgeTypeRep`
  knows it (a mod's: `<modId>::/infrastructure/bridge/<name>.bridge`), or a base bridge's file name (`concrete` is
  `::/infrastructure/bridge/concrete.bridge`). The piece goes with its edge type `BRIDGE` and `typeIndex` the
  type's id (`bridgeTypeRep.find`), as the game's own bridge pieces hold it (`BaseEdge.type` / `typeIndex`). The
  player's road tool picks the bridge type itself, so the engine is taken not to turn a proposal's plain piece into
  a bridge by its height (not checked in a game); both are set here. A type the game does not know is refused with some of the names there; one whose
  carriers read without `ROAD` is refused; nothing is sent either way (dry runs too). The answer's `bridge`: `name`,
  `id`, `carriers`, `carriesRoad` (or `carriersNote` when they do not read), `availability` / `available` (said, not
  refused), and after a build `built` (the new piece's edge type and `typeIndex` read back, `asSent`). A piece in the
  air takes its ends' heights from `--from` / `--to` (x,y,z), or joins a road node there (`--snap`, measured in three
  dimensions). Without `--bridge` the piece is plain (`NORMAL`, `typeIndex` -1), as before. Not checked in a game yet
  (pillars, abutments, a bridge low over the ground): look at it.
- An end within `--snap` metres (default 5, at most 20, 0: never; measured in three dimensions, so a bridge's
  node above the point is not taken) of an end of a road piece is that node, so the piece joins the road there.
  The pieces near the point are found in the octree (`api.engine.util.octree.findEntitiesInCircle` with
  BASE_EDGE, else the octree system's box), roads only (`roadType` STREET; one whose type does not read is left
  out), and their `node0` / `node1` taken; no track node is asked about. The pieces are looked for 25 m beyond
  `--snap` (a town road's seam node was missed from right on it with a snap of 3 m: the octree met neither piece
  near the node); only their ends within `--snap` count. An end that becomes a new node says why in `snapNote`
  (the nearest road node beyond `--snap` and its distance, or that no road piece was met). The pieces at the joined node are then
  read from the street system (`streetSystem.getNodeStreetSegments`; the answer's `piecesFrom: "streetSystem"`),
  and only when that is not there or raises from the octree within 1 m (`"octree"`): at an industry's T the
  octree met none of them. Otherwise the end is a new node; a new node right on an old one (within 0.1 m: with
  `--snap 0`) is refused before sending, as the engine refuses the whole proposal (Construction Not Possible).
- A construction's road: the `build` answer's `construction.connectable` lists where a road (or a track:
  `track: true`, e.g. a rail depot's, for `connect`) can join it, each with `node`, `x` / `y` / `z`, `track`,
  `edges` (pieces of its kind there) and, for a road node, `nodeConfig`: `kind: "mouth"`, the open end of
  a frozen piece (a node of its `frozenEdges` not among its `frozenNodes`; an industry's road stub ends there in
  a T with two free arms), and `kind: "arm"`, the far end of a free piece leaving a mouth (`from`: the mouth,
  `via`: the piece). `ends` (the frozen pieces' ends) does not show the arms. A node that is the construction's
  (`streetConnectorSystem.getConstructionEntityForNode` 0 or more, or a frozen edge of a construction there) is
  joined **without touching its junction set-up** (neither removed nor remade: Overpass Builder refuses that for
  a construction's node): the end gets `construction`, `nodeConfigKept: true` and `pieces`, the answer a
  `caution`. A construction's frozen node (the stub's inner end) is refused before sending, dry run too.
- Junction set-ups (`BaseNodeConfig`, sent as `nodeConfigsToAdd` / `nodeConfigsToRemove`): each new node gets
  one (a dead end: no lane connections), and a joined node keeps its own connections and gets the new piece's:
  between the new piece and each other piece there, straight on lane for lane where the node then has two
  pieces of the same lane count, else every arriving road (tram) lane to every leaving road (tram) lane. Lanes
  are numbered over all of a piece's `laneConfigs`, sidewalks too, from the node outwards. So pieces of this
  command can be chained and branched. The answer's `newNodeConfigs` reads the new nodes' set-ups back,
  `nodeConfigs` counts those sent, an end's `laneRules` the connections added there. Refused before anything is
  sent: a joined node with traffic lights, one whose own connections number lanes otherwise, and lanes or a
  set-up that cannot be read (all of these by the dry run too), or a set-up record that cannot be made (only a
  build finds that).
- A node without a set-up (a road a script built without them, as this command did before 2026-11-23) is never
  joined: the next nearest node within `--snap` is (`passedOver` names the ones left out), and with none the
  command is refused before anything is sent. The game died right after a piece was joined to such a node that
  had two pieces (2026-11-23: `Engine.h:322 GetComponentDataIndex`, BaseNodeConfig). When whether a node has one
  cannot be read, the command is refused too (dry run included).
- `--type` is a street template's resName, or a base road's file name (`town_new_small`, `country_old_medium`)
  looked for under the base's town, country and highway roads; a track type, or one not to be had in the game's
  year, is refused. The default is the base medium town road of the year (old until 1940, new from then). The
  piece gets the template's `laneConfigs` and `streetStyle`, type NORMAL (`typeIndex` -1: no bridge or tunnel) and
  the company's `PlayerOwned`; both tangents are the chord (a straight piece) unless a way is given (next).
- A curved piece: `--tangent-from DX,DY` / `--tangent-to DX,DY` give the way the road leaves the from end and
  arrives at the to end (a direction only; both point the way from -> to, so a straight east piece is `1,0` at
  both ends). `--align-to-edge from|to|both` follows the road at a joined end (a road node within `--snap`): the
  way that road runs on out past the node (a dead end: straight on), read from its `BASE_EDGE` tangent there
  (`tangent1` at its node1, `tangent0` turned round at its node0), else from its chord. A node with one road piece
  is followed; with more than one the command refuses unless `--align-edge ID` names the piece (give it once per
  end; each id is taken at the end it is at; an id at no aligned end is refused). An end on a new node has no road
  to follow: refused. `--tangent-*` and `--align-to-edge` for the same end are refused; for different ends they go
  together. The piece is sent as a cubic Hermite curve: each tangent as long on the map as the chord (the usual
  length; a straight piece's tangents are its chord) and climbing the chord's whole rise, so the height still runs
  evenly. A negative dx is written with `=` (`--tangent-to=-1,0`). Refused before sending (the dry run too): a way of length 0, ends under 1 m apart on the map, an end
  turned more than 90 degrees off the line from -> to (the curve would run back behind its end).
- Every answer (the dry run too) gives `tangent0` / `tangent1` (sent, rounded to mm), `curved`, and on a curve
  `turnOffChord` (`from` / `to`, degrees). A joined end gives `kinks` (each road piece at the node: `edge`, `kinkDeg`:
  the angle between the way it runs on out past the node and the way the new piece leaves it, 0 = straight on;
  `wayFrom`: `tangent` or `chord`), `kinkDeg` (the followed piece's, or the only one's) and with `--align-to-edge`
  `alignedTo` (`edge`, `from`). A straight piece's `kinkDeg` shows how bent the chord joins the road. `length` (and its 2000 m limit) stays the
  chord's on a curve too; the curve itself is longer.
  **Not checked in a game yet** (written 2026-11-23): whether the engine takes these curves (and refuses less
  than the bent straight piece did), and how close the chord-long tangents keep it to a circle.
- The answer: `from` / `to` (`node` and `snapped` when joined, else `zFrom`), `template`, `year`, `length`,
  `edges` / `nodes` (the result's new entities), `edge`, `node0` / `node1`, `cost`, `spent`, the engine's
  `errors`, `warnings` and `collisions` when refused. Without ids in the result, or with no callback in 30 s, the
  piece is looked for between the two ends, leaving out the pieces that were there before it was sent; built with
  no new piece found gives a `warning`. A template or the `BaseEdgeType` / `RoadType` enum that does not read
  refuses the command before anything is sent.
- `--dry-run` sends nothing and does not ask the engine: it answers the plan, checked by the probe only
  (`checked: false`, `engineCheck: "not asked (use --engine-check)"`), so it is safe to run as other dry runs.
- `--dry-run --engine-check` (`--engine-check` goes with `--dry-run` only): it also makes the same proposal the
  road's build sends (set-ups included) and asks the engine about it with `api.engine.util.proposal.makeProposalData` (the proposal alone and with the build's context, as `build`'s), in
  the guiUpdate (never in a recipe's body). The answer has `checked: true`, `engineCheck` (the form taken),
  `buildable`, the engine's `cost`, `errors`, `warnings`, `collisions`, `critical`, and `balance`; one the engine
  would refuse is `ok: false` with its messages in `error`. When `makeProposalData` is not there or raises both
  ways, the answer is the probe's own plan (`checked: false`, `engineCheck: "not available: ..."`). The engine's
  evaluation runs native code a `pcall` cannot guard (an assertion there would end the game), so tf3ctl counts
  this as changing the game: ask for the game first, test saves only.
  `verdict` is `buildable`, `buildable with warnings` or `refused` (`engineContexts` and `contextsDisagree` as
  `build`'s). Where only the proposal alone answers, the engine judges it in its own context, not the build's
  (`engineContext` says which): that one gathers farm fields, so a field in
  the way is only a warning ("3 fields will be removed") where the build without `--remove-fields` collides with
  it (2026-11-23, a road by a forest). Then the answer has a `caution`.
- `--remove-fields` lets the road take farm fields in its way: the build's context gathers fields
  (`gatherFields`, as Track Connector's does; buildings are still not gathered), so the engine removes them and
  builds. Anything else in the way (buildings, tracks, constructions) is still refused. A road refused for a
  collision without it gets a `hint`. Changes the game: test saves only. **Not checked in a game yet**
  (written 2026-11-23): that only fields go (buildings, tracks and an industry's own parts still refuse it), that
  the forest's entities in the way were its fields, and that the engine's own context gathers fields (a guess from
  its warning); the answer says so (`removeFieldsNote`). With `--remove-fields` the dry run's `caution` says a
  warning of anything but fields may still be a collision in the build.
- `--remove-buildings`: the Context's `gatherBuildings` on (town buildings in the way go, as with the player's
  tools). Test saves only; not checked in a game yet. A dry run's engine check judged in the engine's own context
  (`engineContext`) did not use it: `removeBuildingsNote` says town buildings among its `hits` may still go. A refusal for a collision (a build, or a dry run's engine
  check) names what is in the way in `hits`, as `build` does.
- `--ignore-errors` (**for test saves only: skips the engine's checks**): the build is sent with
  `makeWorldBuildProposalCmd`'s `ignoreErrors` on, so the engine builds past its errors. The game's API
  (`api/tealdef/api/cmd.d.tl`) says it passes non-critical errors only, so a `critical` one may still refuse it.
  Before sending, the same proposal is asked of the engine (`makeProposalData`, as `--dry-run --engine-check`):
  the answer's `unforced` holds what a build without it would be refused for (`refused`, `verdict`, `critical`, `errors`,
  `warnings`, `infos`, `collisions`, `collisionEntities`, `hits`), `unforcedContexts` both contexts, and
  `unforcedCritical` a note when the check says critical. The answer also has `ignoreErrors: true`,
  `ignoredErrors: true` (it was sent forced, whether or not there was an error to pass: `unforced.refused` says
  that), `testSave` and `ignoreErrorsNote`; built, it has `edge`, `edges` and `nodes` as any road.
  tf3ctl refuses it (exit 4, `"refused": "ignore-errors"`, nothing sent) unless the loaded save (read from the
  game's log) has a test save's name (`probe-*`, `aom-ops-*`, `aom-shot-*`, `aom-bgm-check-*`, one digit first),
  and whenever the running game carries a coop mark (active, expired or malformed). A new game has no save name
  yet: save it under a test save's name and load that save first. The mod checks the save's name again (tf3ctl
  sends it), and refuses `ignoreErrors` on every command but `road`. The probe's own checks are not skipped: an end
  at a node without a junction set-up, with traffic lights, or whose set-up does not read is refused as before
  (a road joined at a node without one once ended the game), and an end at a construction's node (its set-up left
  as it is) is not forced at all. With `--dry-run` the engine is asked
  (`--engine-check` is implied) and nothing is built: the answer is the unforced verdict, with `ignoredErrors:
  false`. **Not checked in a game yet** (written 2026-11-24): whether the engine builds a colliding piece, whether
  vehicles take it, and whether it survives a save and a load.
  **Saving after a forced build**: once a forced build (not `--dry-run`) went to the running game, its launch
  record (`launched.json`) carries `"forced": true` and `"forcedCount"`, and `save` then goes only to names starting
  with `probe-force-` (for example `save probe-force-junction`). Any other name is refused (exit 4,
  `"refused": "forced-save"`, nothing sent), with `--other-owner-ok` and `--user-asked` too, so a state built past
  the engine's checks never lands in a test base or a user's save. `status` says so in `forced` (`text`, `textJa`).
  The mark goes with that run of the game: the next `launch` / `restart` writes a new record without it. A forced
  build is refused when there is no launch record of the running game to keep the mark in (a game started from
  Steam). A loaded `probe-force-*` save (saved forced in an earlier run) saves only to `probe-force-*` names too.
Not covered: the game's own autosave (every 10 minutes) still writes the forced state to its autosave slot, and an
autosave loaded again saves under any name.
- `--batch FILE` (several pieces in **one** proposal, written 2026-11-24, **not checked in a game yet**): the pieces
  go in one SimpleProposal, so the engine judges and builds them together (one piece sent after another may be
  refused where the two together are not: two one-way roads out of one end of a four-lane street). FILE is a JSON
  list of at most 16 pieces; each is an object with this command's own values by their flags' names (`from`, `to`,
  `type`, `bridge`, `snap`, `tangent-from`, `tangent-to`, `align-to-edge`, `align-edge`; the mod's names
  `tangentFrom`, ... are read too; points as `"x,y[,z]"` or `[x, y, z]`) and, for sharing a node, `from-node` /
  `to-node`: an existing road node's entity id (joined as it is, no snap; giving `from` / `to` at the same end as well is refused), or a
  name `"@a"` for a new node the pieces share (never snapped; its point given at one of its ends at least and the
  same, within 0.01 m, at each end that gives one; a name used at one end only is refused). `--dry-run`,
  `--engine-check`, `--remove-fields`, `--remove-buildings`, `--ignore-errors` and `--collision-detail` go on the
  command line for the whole proposal, with the same meaning and the same fences as for one piece (it goes as the command `road`:
  `--ignore-errors` on test saves only and never in coop, the force mark, the probe's own set-up checks). `--from`,
  `--to` and the other per-piece flags are refused beside `--batch`. An empty list, more than 16 pieces, a file that
  is not JSON, an unknown key or a bad value is refused with nothing sent; so are two new ends on one point left
  unnamed (give them one name), two pieces between the same two nodes, a named node on an old node, and an end
  given by an id that is no road node. Pieces of one batch that cross or overlap (two ways out of one node at
  about 0 degrees) are not checked here: try such a batch with `--dry-run --engine-check` first.
  New entities are numbered as for one piece: the new nodes -1, -2, ... in the order the ends name them (piece 1
  from, piece 1 to, piece 2 from, ...), then the pieces; a batch of one piece sends the very proposal `road` sends.
  A node several pieces share gets one junction set-up: a joined node its old connections plus the new pieces'
  (to its pieces and to each other), a new node those among the new pieces (two: lane for lane; more: a
  junction's). The answer: `batch: true`, the one proposal's `errors`, `critical`, `warnings`, `collisions` and
  `hits`, `pieces` (each piece's `from` / `to`, `template`, `length`, tangents and kinks, and, built, its `edge`,
  `node0`, `node1`; a shared end has `sharedBy`), `proposal` (its `nodes` by id, with `name` and the `ends` that
  name each, and its `edges`), `edges` / `nodes` as built, `pieceEdges` (each piece's edge, in order) and
  `namedNodes` (each name's node as built). With `--collision-detail`, `collisionDetail` is the one proposal's
  (as for one piece), and its `overlaps` meet each piece's box from its ends: `mine` is the piece's number.
- `--inspect-node ID` (read only, alone): the node's position, `streetSegments` (each piece's `edge`, `node0` /
  `node1`, `street`, `construction`), `constructionForNode` (getConstructionEntityForNode), `construction`
  (the construction found, `frozen`, `by`) with its `constructionFrozenNodes` / `constructionFrozenEdges`,
  `nodeConfig` (`false` when none; else its `laneConnections`, `crosswalks`, `trafficLightStates`,
  `doubleSlipSwitch`, `trafficLightPreference` (`YES` / `NO` / `AUTO`, by the game's enum; its number in
  `trafficLightPreferenceValue`) and `trafficLightType`), `octree` (the pieces `findEntitiesInCircle` meets within 1, 5 and 20 m, whether each ends
  at the node, at most 40 listed) and `road`: what the road command would do with the node as an end.
- road does not join a node with traffic lights (their phases name lanes, and would not be remade). `lights --node
  ID --off` takes a junction's traffic light off first, with the node's window's two buttons in one proposal: "None"
  (`trafficLightPreference` NO) and "Reset to Default" (the phases, `states`, emptied; road refuses a node by its
  phases, and None alone keeps them). The set-up's traffic light config is copied (`clone`), its type kept, and sent
  with `createTrafficLightProposal` as `makeWorldBuildProposalCmd(proposal, nil, false, true)`.
  - **For test saves only, and not during coop**: tf3ctl refuses it (exit 4, `"refused": "lights"`, nothing sent)
    by the same rule as `road --ignore-errors`, and the mod checks the save name again. It goes through the owner
    check, `--dry-run` too.
  - Refused before anything is sent: a node with two street pieces or fewer (the node's window offers traffic
    lights only where more than two meet), a construction's node, a node without a junction set-up. A node whose
    preference is NO already and that has no phases: nothing is sent (`changed: false`).
  - The answer: `before` and `after` (read back: `trafficLightPreference`, `trafficLightStates`,
    `trafficLightType`), `off` (NO and no phases read back), `changed`. `--dry-run`: the proposal made and asked of the engine
    (makeProposalData, with no Context, as the window sends none): `verdict`, nothing sent.
  - **Not checked in game yet** (written 2026-11-24): whether the engine keeps NO and the emptied phases (or makes
    phases again), and whether road then joins the node. Look at it with `road --inspect-node` before trusting it.
- Between 1 m and 2000 m long. A piece across water or a valley needs a bridge, which this does not build (the
  engine refuses or follows the terrain: not known).
- Use: a harbour's pedestrian link alone does not join it to the road network; a road along it, from the
  harbour's free road end to the town's road, does (as players build it).
- **Not checked in game yet** (written 2026-11-22): in particular whether `api.type.NodeAndEntity` /
  `SegmentAndEntity` / `PlayerOwned` are reachable under those names (the probe also tries `api.type.Proposal.*`),
  whether the default `streetEdge` is enough, whether the engine takes a construction's node as an end with its
  set-up left alone and joins the new piece's lanes there (written 2026-11-23; a forest's outer end and inner end
  were refused before), whether makeProposalData answers in the guiUpdate as in Overpass Builder's tool,
  what the callback's entities hold, whether nodes are indeed not in the octree, and what becomes of a town road
  the new piece crosses (the proposal adds no crossing node: does the engine add one, refuse, or lay one over
  the other).

### The ground in a rectangle (`terrain`)

```
python3 tools/tf3ctl.py terrain --probe-api                         # read only: which functions each Lua state has
python3 tools/tf3ctl.py terrain --rect 0,0,500,300 --flat 40 --dry-run
python3 tools/tf3ctl.py terrain --rect 0,0,500,300 --flat 40 [--blend 16]
python3 tools/tf3ctl.py terrain --rect=-500,0,500,300 --slope-x 5 --base 40     # 40 m at x0, 5 % up toward x1
python3 tools/tf3ctl.py terrain --rect 0,0,300,800 --slope-y -10 --base 120 [--via auto|update|gui] [--in-game]
```

- Replaces the ground heights inside the rectangle (metres, at most 1024 a side): flat at a height, or a uniform
  slope along x or y (`--base` is the height at the x0 / y0 edge). Everything outside it stays as it is. Only in the
  map editor (`api.gui.game.isMapEditor()`); outside it the probe refuses unless `--in-game` is given, for a new
  test game (whether a replacement works in a game is not known). A dry run sends nothing and works anywhere. It
  warns other clients as a game-changing command (its dry run too).
- The map's size: the whole heightmap is copied into a Lua table, so a map with more than 4.5 M points (counted
  from the terrain's bounding box before anything is copied: a small map, 32 x 32 tiles, has 4.2 M) is refused.
- How: the whole map in one command, as the map editor's generate and import do. `makeMapFromGame(true, false,
  false, false)` copies the map without towns (a map that lists towns asserts in `terrain_util::ReplaceTerrain`),
  the grid points inside the rectangle (every 4 m, index `j * w + i + 1` from the map's min corner) are changed in
  the copied table, the whole table is assigned back (`GameMap.heightmap` hands out a copy on each read: an element
  written into it is lost) of a copy made with `api.type.Map.new` (as UTG does), then, in the map editor only,
  `setMapSeedText` and `reloadMaterialIndexManagerPipeline` as the base editor calls them, and
  `makeWorldReplaceTerrainCmd(map, baseConfig.terrain, "", world, keepAssets = true)`. Trees and rocks are
  kept (what they do on the new ground is not known).
- The edge: by default the new heights blend into the old over 16 m inside the rectangle (a quarter of the shorter
  side on a small one): a point on the edge keeps its height, one 16 m in has the full new height, so the land
  round it meets it without a step. `--blend 0` makes a sharp step at the edge.
- Refused, nothing sent: a road or track piece, a node, a construction, a town building or an industry in the
  rectangle or within 8 m of it (the octree), or a town whose bounding box comes within 200 m. The answer's
  `blockers` lists them. The heights asked for must stay within -99 .. 3170 m.
- Two ways (`via`): `gui` runs in the speed control's recipe (its join, where the base editor and the terrain mods
  call these functions: from react only); `auto`, the default, is `gui`. `update` runs in the guiUpdate state, only
  when given. `terrain --probe-api` answers which of `makeMapFromGame`,
  `Map.new`, `makeWorldReplaceTerrainCmd`, `mapgen.createTowns`, `setMapSeedText`,
  `reloadMaterialIndexManagerPipeline` and others each state has, calling none (read only).
- The answer: `via`, `functionsUpdate` / `functionsGui`, `rect`, `grid` (the first and last grid points, `nx`,
  `ny`, `points`), `mapPoints`, `inGame`, `target` (the heights asked for, min and max), `before` / `written` (min and max in the
  rectangle), `changed`, `waterLevel`, `sent`, `success` (the callback), and after a replacement `samples` (the
  middle and the corners of the full part, read back with `getHeightAt`) with `readBackOk`; `mapEditor`; on a
  refusal `error`.
- **Not checked in game yet** (written 2026-11-22): whether the guiUpdate state has these functions, whether the
  replacement works outside the map editor (every use seen is in the editor), what happens to trees and to the
  town mod's land in the rectangle, the read-back values.

### One town (`town`)

```
python3 tools/tf3ctl.py town --at 1200,-300 --name "Harbourside" --dry-run
python3 tools/tf3ctl.py town --at 1200,-300 --name "Harbourside" [--size 1.5] [--capacity 300]
python3 tools/tf3ctl.py town --at=-800,400 --name "Quayside" --needs com:fish,ind:planks [--via auto|update|gui] [--in-game]
python3 tools/tf3ctl.py town --at 0,0 --name "Plain" --no-needs
```

- Puts one town on the map at a point, as the map editor's towns window and import do (`map_editor.tl`
  `makeTowns`): one `GameMap.Town` (`api.type.Map.Town.new()`: `pos`, `name`, `sizeFactors`, `landUse2CargoNeeds`,
  `existing = -1`) goes to `api.engine.mapgen.createTowns("remote_probe", { town })`, and the one `TownInfo` it
  gives back (`toAdd`) is sent as `api.cmd.makeTownCreateCmd({ info })`. Only in the map editor
  (`api.gui.game.isMapEditor()`); outside it the probe refuses unless `--in-game` is given, for a new test game
  (every use seen, the base editor and the town mods, is in the editor). It warns other clients as a game-changing
  command (its dry run too).
- `--size` is each district's size factor (`sizeFactors = { f, f, f }`, 0.1 .. 2.5, default 1 as the base import;
  Real World Map Importer uses 0.5 for 500 inhabitants and 1 for 5000). `--capacity N` scales the engine's
  `initialLandUseCapacities` to an average of N per district (1 .. 1000), its proportions kept, as Advanced Town
  Placement does (its towns reach about 500); without it the engine's own values for the place are sent.
- First cargo needs: a town made by a script gets no first demand from the game, and without one it never asks for
  goods (Real World Map Importer's changelog). By default one category for the shops and one for the industry, the
  first by name of the economy's lowest tier (tier 0) that has a cargo type; `--needs com:fish,ind:planks` names
  them (land use `res`, `com` or `ind`, at most 3 each, the economy's category names); `--no-needs` gives none.
  They go twice: as `landUse2CargoNeeds` (category names with weight 1 per `LandUseType`, as the base import and
  Advanced Town Placement pass them), and, when the new town's `TOWN` component does not show them a few frames
  after the create callback, as `api.cmd.makeTownUpdateCargoNeedsCmd(town, { {res ids}, {com ids}, {ind ids} },
  true)` with the cargo type ids (as Real World Map Importer does), read back once more.
- Where the place cannot take a town (roads, buildings, water, rough ground), the engine decides: an error that
  `createTowns` raises comes back as it is; a proposal with no initial capacity (0, 0, 0) is refused, as Advanced
  Town Placement leaves such places out; a create the engine refuses (the callback) is an error. Towns that
  `createTowns` lists to remove (`toRemove`; the editor destroys them first) are only counted
  (`toRemoveIgnored`): this command never destroys a town. `createTowns` seems to take the list it gets as all the
  map's towns (the base import adds the towns it keeps), so `toRemoveIgnored` may well be the number of towns
  already there, and the engine's proposal may not leave room for them: put a town well away from the others. A
  point off the map (`isValidCoordinate`) is refused; one that cannot be checked is a warning.
- `--dry-run` sends nothing: in the editor or with `--in-game` it asks `createTowns` for the proposal (no command;
  the answer's `proposal`), elsewhere only the arguments and the needs are checked.
- Two ways (`via`), as `terrain`: `gui` (and `auto`, the default) runs in the speed control's recipe (its join),
  `update` in the guiUpdate state, only when given. The needs command is sent from the guiUpdate state: where that
  state lacks `makeTownUpdateCargoNeedsCmd` the town is still made, without it, and the answer says so
  (`needsSet`, `warnings`; `functionsUpdate` lists it). A success with no new town found is an error.
- The answer: `via`, `mapEditor`, `inGame`, `at`, `name`, `size`, `capacity`, `needs` (names per land use),
  `needIds` (cargo type ids per district), `proposal` (the TownInfo's `name`, `position`,
  `initialLandUseCapacities`, `scaledCapacities`, `capacityScalingFactor`, `majorStreetAngle`), `sent`, `success`,
  `entity` (the one town id new since the command, by name when there are several), `townName`, `position` (the
  middle of its bounding box), `population` (from `getTown2personCapacitiesMap`, as `industry-workers`; it starts
  low, the buildings come over the next game days), `personCapacities`, `needsRead` (cargo type ids per district,
  read back), `needsSet`, `needsMet`, `warnings`; on a refusal `error`.
- **Not checked in game yet** (written 2026-11-22): whether the guiUpdate state or the recipe has these functions,
  whether it works outside the map editor, whether `landUse2CargoNeeds` takes, the needs command, how the engine
  answers a place with roads or buildings on it, the population right after.

### Town connections (`town connections`, `town connect`: test saves only)

```
python3 tools/tf3ctl.py town connections [--entity 801] [--index-base 0|1]   # read only
python3 tools/tf3ctl.py town connect --auto [--entity 801,802] [--dry-run]
python3 tools/tf3ctl.py town connect --build [--entity 801,802] [--pairs 801:802] [--default] [--no-keep] [--dry-run]
```

- What the engine has (api types and the base map editor's Connections tab, read 2026-11-23): connections are
  between towns, not between a town and an industry. A map's `townConnections` (from
  `api.engine.terrain.makeMapFromGame(false, true, false, false)`, as the editor reads them) are pairs of indices
  into the map's towns. An industry's town is the closest one (`streetConnectorSystem.getConstructionClosestTown`
  of its construction).
- `town connections` answers each town (`id`, `name`, `mapIndex`, `connectedTowns`, `industries`: those whose
  closest town it is), `industriesWithoutTown`, the raw `connections` with the towns they resolve to, and
  `indexBase` (0 or 1: how the engine numbers the towns, when the map's own pairs tell it).
- `town connect --auto` sends `api.cmd.makeTownAutoDetectConnectionsCmd(towns)` (the editor's "Auto-detect
  connections": connections over the roads there are; it builds nothing).
- `town connect --build` sends `api.cmd.makeTownConnectWithIndustriesCmd(towns, connections, keep)` (the editor's
  "Generate"): streets between the connected towns and to **all** industries; no list of industries goes in.
  The connections are the map's, plus the engine's default ones with `--default` (the editor's "Propose Default
  Connections"), plus `--pairs` (town ids), re-numbered for the towns sent. Keep is on; `--no-keep` removes the
  street connections there are. With none of `--entity`, `--default` and `--pairs` the map's towns and pairs go as
  they are (`asMap`, as the editor sends them); otherwise, when the map does not tell the numbering,
  `--index-base 0|1` is needed (also taken by `town connections` and `--auto`, for the pairs in the answer).
- Both answer `before` / `after` (as `town connections`) and wait at most 120 s for the engine's callback.
- **Not checked in game yet** (written 2026-11-23): whether these work in a game outside the map editor, the
  numbering, and what `--build` does to the roads there are.

### Growing a town at a point (`town develop`, `town size`: test saves only)

```sh
python3 tools/tf3ctl.py town develop --at 120,-40 --count 30 [--streets] [--upgrade] [--radius 250] [--dry-run]
python3 tools/tf3ctl.py town size --entity 801 --factors 2,1.5,1 [--update-all] [--dry-run]
```

- **Use these on test saves only.** They add buildings no player could place, to give a harbour's or station's
  circle its houses and shops without running years of `steps`. They warn other clients as game-changing commands
  (their dry runs too). Options go after the word (`town develop --dry-run ...`): one of the plain `town`'s given
  before it is refused, so a `--dry-run` there is never dropped.
- `town develop` sends `api.cmd.makeTownDevelopAtCmd(api.type.Vec2f.new(x, y), streets, upgrade)` `--count` times
  (1-200, default 1), one after another: the next goes a frame after the last one's callback. The type's words:
  "new buildings or street segments are added at the given position"; `--streets` develops streets, `--upgrade`
  upgrades buildings (both false by default).
- `town size` sends `api.cmd.makeTownUpdateSizeCmd(town, { residential, commercial, industrial }, updateAll)`: the
  town's size factors (each 0-5; a new town has 1), as the base's town growth script sends them. `--update-all`
  takes every building to its target capacity. The town must be one the engine has, with a `TOWN` component. The
  base's town growth script resends the size from the town's own factors as it grows (raising only), so factors
  set lower than its own may be raised again.
- The counts: the town buildings of every town (`townBuildingSystem.getTown2BuildingMap`), each one's kind from its
  `PERSON_CAPACITY` type (`LandUseType`), as `stations --catchment` counts them: `buildings`, `residential`,
  `commercial`, `industrial`, `unknownKind`, `capacity` per kind. `town develop` answers `before` / `after` /
  `delta` for all towns together (`total`) and for the buildings whose bounding box centre is within `--radius`
  (default 250 m, a harbour's circle) of the point (`near`), and `towns`: the towns whose counts changed, by id and
  name. `town size` answers the town's `before` / `after` / `delta`, and `townBefore` / `townAfter`
  (`sizeFactors`, `initialLandUseCapacities`, `developmentActive`, `personCapacities`). The counts are read 5
  frames after the last callback: buildings that come later are not in them.
- Also in the answer: `sent`, `succeeded`, `failed`, `failures` (index, success, engineResult; the first 20),
  `engineResult` (what the first callback handed back), `waitedSec`, `functions` (which of the functions are
  there). `--dry-run` sends nothing and answers the counts (a develop's: every town). A function the game does not
  have (nil) is not called; an error raised while making or sending, no callback in 30 s, and every command refused
  (`success` false) are errors. One `town develop` or `town size` at a time: another is refused while one runs.
- **Not checked in game yet** (written 2026-11-22): whether the guiUpdate state has these functions and the engine
  takes them in a game, what a develop builds where and how fast, whether `--update-all` builds at once.

### Stocks and simulation steps (`stock`, `steps`: debug commands, test saves only)

```sh
python3 tools/tf3ctl.py stock list --entity 51                       # read only
python3 tools/tf3ctl.py stock set --entity 51 --stock 0 --amount 100 [--cargo COAL] [--dry-run]
python3 tools/tf3ctl.py stock set --entity 601 --stock -1 --amount 30 --cargo <cargo>   # a vehicle's load
python3 tools/tf3ctl.py speed 0                                      # pause first
python3 tools/tf3ctl.py steps 500 [--dry-run] [--allow-running]
```

- **Use these on test saves only.** They send the game's debug commands (`api.cmd.debug`), which change the game
  as no player can: cargo appears from nowhere, the simulation runs on without the clock. They are meant to cut the
  waiting on maps made for tests (a harbour's stock filling up, a vehicle arriving full, a town growing). They warn
  other clients as game-changing commands (their dry runs too).
- `stock list` reads a stock list as the base's debug panel does: the entity's `STOCK_LIST` component, stock ids
  0-based (the ids `stock set --stock` takes), each stock's `type`, `cargoType` and `cargo` (the cargo type's
  name), `capacity`, `count` (`getStockCount`) and `cargoTypes` (per cargo type the stock takes: its name and
  `count`). An industry, town building or warehouse whose own entity has no `STOCK_LIST` is followed to its
  `stockList` entity (`via`), which may be the owner itself (a warehouse's WAREHOUSE entity is its own stock list in
  a game, measured 2026-11-23). A construction (the id `build` answers, e.g. a warehouse's) is followed to the one
  warehouse, industry or town building with a stock list among its subconstructions (`via`
  `CONSTRUCTION>WAREHOUSE`, `owner`, `construction`), through the subconstructions as the base finds a
  warehouse's window from its construction (the base takes the first; here two or more are refused, naming them,
  so that nothing is guessed); with none there, a warehouse whose `WAREHOUSE.construction` is that construction
  (in a game, a warehouse's construction did not list its warehouse among its subconstructions, 2026-11-23); and
  none is an error. A warehouse (`warehouse.con`) keeps all its stocks
  in one stock list: one mixed stock for its universal modules (500 each, summed) and one stock per specialized
  module (bulk, liquid, flatbed, goods). A stock of capacity 0 is left out, so stock 0 is the mixed one only when
  there is a universal module: read the ids with `stock list`. A warehouse without modules has no stocks. A vehicle has no stock list: `kind` is `vehicle`, with `cargo` per cargo type it has
  room for (`capacity`, `count`; passengers left out and refused, as the base panel does), set with
  `--stock -1 --cargo NAME`. `--cargo` takes the `cargo` field exactly as `stock list` shows it. Ids come from `industry-stocks`, `stations`,
  `entities --kind warehouse` (or `build`'s answer) and `vehicles`; `window --warehouse NAME` opens a warehouse's
  window by the name `entities --kind warehouse` shows. **Not checked in game yet**: a warehouse's stock list
  (read from the base's sources, not measured), and whether its WAREHOUSE entity has a name to pick it by.
- `stock set` sends `api.cmd.debug.makeStockSetCargoAmountCmd(stock list entity, stock, amount[, cargo])` (the cargo
  only when given, as the base panel leaves it out for a stock list's stock). A cargo for a **mixed stock**
  (`cargoType` -1, e.g. a warehouse's universal one) is sent with stock **-1** and the cargo's name, as the base
  panel sets a vehicle's load per cargo type (`sentStock` -1, `form`): sent with the stock's own id, the engine did
  not take the name (grain asked, bricks set, 2026-11-23). A stock of one cargo type, and a mixed stock without
  `--cargo`, go with their stock id, as before. **Measured** (2026-11-23, a warehouse's mixed stock): the stock -1
  form took nothing either (grain asked, grain 0 and every other cargo 0, also after `steps 5`), while the engine
  said success: the debug command has no way to put a chosen cargo into a mixed stock. Such a set is still sent
  (an industry's or a station's mixed stock is not measured); its answer carries a `warning`, and when the stock
  reads as before it is an error (below). Without `--cargo` a mixed stock's own id fills its default cargo. Every count of the stock list is read before and after; the others that moved are in
  `elsewhere`. When one of them now reads the very amount asked while the asked one did not get it, the engine put
  it there: an error, not ok. When the asked count reads just as before (and the amount was another) while the
  engine said success, nothing went in: an error too ("nothing went in"; at a mixed stock it says that no chosen
  cargo goes in so). A vehicle's load is left to the warning ("reads back"): how soon it reads back is not
  measured. Other moves (a running game's production and deliveries) are a warning. Refused before anything is sent: a
  stock id the list does not have, an amount over the stock's capacity (or the vehicle's for that cargo, or
  100000; in a mixed stock with the other cargo there counted), passengers, a cargo the stock or vehicle does not
  take, an entity the engine does not have. The answer: `before`,
  `after` (read a couple of frames after the callback), `success`, `engineResult` (what the callback handed back),
  `stockList` (the entity it went to); `--dry-run` sends nothing and answers `before` and `functionPresent`.
- `steps N` (1-10000) sends `api.cmd.debug.makeGamePerformSimulationStepsCmd(N)`. One step is 200 of game time,
  so 20 steps make a game day; 1000 steps took about 15 s (measured 2026-11-22, paused, on a small test save). The engine's callback
  comes before the steps have all run (they run on over many frames), so the answer waits until `updateCount`
  is up by N or `gameTime` by N x 200 (`doneBy` says which), at most `waitSec` (N / 10000 x 200 s, at least
  30 s; tf3ctl waits 30 s more). The answer: `before` and `after` (`gameTime`, `updateCount`, `tickCount`,
  `date`), `gameTimeDelta`, `updateCountDelta`, `gameTimePerStep`, `callbackSec`, `waitedSec`, `timedOut`,
  `stepsPerSec`, `speedup`, `success`, `engineResult`. A wait that runs out is an error (`timedOut` true) with
  what ran by then; the engine runs the rest on all the same, so a `steps` sent while they may still run (or while
  another `steps` waits) is refused until they are done.
- **Pause first** (`speed 0`): while the game runs, its own running moves the same counts, so the wait would end
  early and the deltas would not be the steps'. `steps` is refused while the game runs (its `--dry-run` answers
  with a `warning` instead); `--allow-running` sends anyway and the answer carries a `warning`.
- A debug function the game does not have (nil) is not called: the answer says so (`functionPresent` false,
  `sent` false). The engine's refusal (`success` false), an error raised while making or sending the command, and
  no callback in 30 s (`steps`: its `waitSec`) are errors with the engine's own words where it gives any.
- **Checked in game** (2026-11-22, paused): the release build runs `steps`; one step is 200 of game time
  (`steps 1` / `10`: 200 / 2000, update count 1 / 10); 1000 steps ran on for about 15 s after an early callback.
  **Not checked in game yet**: the waiting answer itself, `stock set`, whether a station holds a stock list of its
  own.

### A vehicle model's running costs (`running-costs`) and the finance rows (`finance`)

```sh
python3 tools/tf3ctl.py running-costs --model bus_1900                 # read only
python3 tools/tf3ctl.py running-costs --model bus_1900 --scale-running 2 [--set-maintenance 1.5] [--where gui]
python3 tools/tf3ctl.py running-costs --model 101 --set runningCostScale=2 --scale maintenanceScale=3
python3 tools/tf3ctl.py finance [--since GAMETIME] [--vehicles 601,602] [--columns 4]   # read only
```

Made to measure whether the engine bills a running cost rewritten during a game (the purchase price written this
way is paid, the shop shows it and the sale price follows it: measured 2026-11-16 with a test mod).

- `running-costs` without a write reads the model's `metadata.cost` (`price`, `priceScale`) and
  `metadata.maintenance` (`lifespan`, `runningCosts`, `runningCostScale`, `maintenanceScale`,
  `topSpeedMaintenanceFactorPenaltyPerLevel`), as the GUI's Lua state sees them (`view`), and the company's vehicles
  with a part of that model (`vehicles`, at most `--limit`, default 20; `vehicleCount` counts them all) with the
  running cost per year the engine gives each (`getRunningCost`, as the vehicle window shows it). `--model` is an
  id or a part of the file name (`models --grep` lists them). It goes anywhere, as every reading command.
- **A write (`--set-running X`, `--scale-running K`, `--set-maintenance Y`, `--scale-maintenance K`, `--set
  FIELD=X`, `--scale FIELD=K` for `runningCosts`, `runningCostScale`, `maintenanceScale`) is for test saves only**,
  by the same rule as `road --ignore-errors`: the loaded save must have a test save's name (a new game with no name
  yet: `save probe-NAME`, then `load probe-NAME`), no coop mark may be on the running game, and the owner check
  applies (a game-changing command). The mod checks the save's name again. A model has no maintenance amount of its
  own, only `maintenanceScale`, so the `--*-maintenance` flags write that.
- The fields are written in place (`modelRep.get(id).metadata.maintenance.<field> = value`) and read back. `--where
  script` (the default) writes in the game script, as the test mod wrote prices; it needs the mod setting **Game
  script commands** on: `launch` / `load` with `--param hummer_remote_probe:gameScript=2`. Off (the default), the
  mod's game script subscribes to nothing and keeps no state. `--where gui`
  writes in the GUI's Lua state, and (with the setting on) the game script reads the model back (a way not tried in
  a game yet: whether writing there while the simulation reads the model is safe is not known).
- `load` (and `launch` / `restart --load`) refuses `--param hummer_remote_probe:gameScript=2` on a save that is
  not a test save's, so a person's save is not loaded with the game script listening (a new game may take it).
- The answer has `before` (`gui`, and `script` for a game-script write), `writes` (per field: `from`, `to`, `ok`,
  the engine's `error` word for word, `readBack`, `stuck`), `after` (`script`, `gui`), `vehiclesBefore` and
  `vehiclesAfter` (`runningCostPerYear` per vehicle), `wroteIn`, `testSave` and `gameTime`. `ok` is false when a
  field did not take the value. The game script answers through its state within 15 s, or the answer says it did
  not (with a game-script write, look at the log: `log --grep "game script"`).
- A write lasts for the session only: each load reads the models anew.
- `finance` reads the finance table as the base's finance window does (`computeFinanceTable`, `--columns` columns,
  the years in `header`): per carrier its rows (`type`, `maintenance`, `construction`, `values`), and
  `vehicleRunning` (the `MAINTENANCE` / `VEHICLE` rows: the vehicles' running costs) and `vehicleMaintenance`
  (`MAINTENANCE` / `VEHICLE_MAINTENANCE`) summed per column. `sameAs` marks a carrier whose rows are an earlier
  carrier's (TRAM gave ROAD's rows in a game). `fleet` is `calculateBalance` of all the company's vehicles over
  `[since, gameTime]` (maintenance and income entries; `running`: `Maintenance.VEHICLE` only; `maintenance`:
  `VEHICLE_MAINTENANCE`; `all`); `--vehicles` gives the same per vehicle. Without `--since`, a twelfth of a year
  back. Amounts are as the engine books them (costs negative). Not checked in a game yet.

### Town building parcels along a road (`parcels`, read only)

```
python3 tools/tf3ctl.py parcels --edge 9010 [--no-list]          # one road piece: its parcels on each side
python3 tools/tf3ctl.py parcels --rect=-100,0,400,300 [--list]    # every street piece in a box (at most 2000 m a side)
```

- Reads only (no warning to others, nothing sent). Towns put their buildings on parcels, which the engine keeps
  per road piece (edge), on its left and right. `parcels` asks the parcel system for them:
  `api.engine.system.parcelSystem.getSegment2ParcelData()` once (piece -> `ParcelData`, the two lists of parcel
  entities). A piece the map does not have has no parcels: `inParcelMap` false, 0 and 0. Only when that map cannot
  be read is `getParcelData(edge)` asked, and then only for a street piece (`source` says which).
- Per piece: `street` (it has `BASE_EDGE_STREET`), `node0` / `node1`, `from` / `to` and `length` (m, seen from
  above), `inConstruction` and `construction` (`streetConnectorSystem.getConstructionEntityForEdge`), `fields`
  (the `ParcelData` field names that were there: the tealdef has `leftEntities` and `rightParcels`; `leftParcels`
  and `rightEntities` are read too), and `left` / `right`: `count`, `built` (parcels with a town building, from
  `townBuildingSystem.getParcel2BuildingMap`), `area` (m²) and, unless `--no-list`, `parcels`: each one's `id`,
  `building`, `left`, `streetSegment`, `curveParam`, `offset`, and `x` / `y` / `z` (the mean of its faces' points)
  and `area` (its faces seen from above). Those come from the parcel's `PARCEL` component, read only when
  `api.type.ComponentType.PARCEL` is there (`parcelComponent`); `sideMismatch` counts parcels whose own `left`
  disagrees with the list they are in (0 when the field names are right).
- `--rect x0,y0,x1,y1`: the street pieces the octree finds round the box with an end or their middle in it (a
  piece that only crosses the box is left out; tracks are left out), sorted, counts only unless `--list`, at most
  400 listed (`truncated`), and `totals` (`edges`, `withParcels`, `left`, `right`, `built`, `inConstruction`).
  It also gives the edge ids for `--edge`. With `--list` in a town's centre the answer can be large.
- A piece whose `ParcelData` has none of the field names above has `unreadParcelData` (its keys, or what it
  prints as) instead of passing for 0 and 0; `totals.unreadParcelData` counts them. Both maps are read whole for
  each command, also for one `--edge`.
- An id that is no entity, or no road piece, is refused; every engine call is in pcall and asked only about
  entities the engine says exist.
- **Not checked in game yet** (written 2026-11-23): whether the map and the `PARCEL` component read in the GUI
  script, the field names, and the values.

### What stands near a point (`around`, read only)

```
python3 tools/tf3ctl.py around --at 1200,800 [--radius 100] [--kinds town_building,street,field] [--limit 200]
```

- Reads only (no warning to others, nothing sent). One walk of the octree
  (`octreeSystem.findIntersectingEntities`) over the square round the circle; each entity it gives, with the box
  the octree hands over, is looked at once and kept when it is within `--radius` (to its box, or to a road or
  track piece's line less half its width; `--radius` at most 2000 m). Nearest first, at most `--limit` (default 200, at most 2000:
  `truncated`, `total`); `counts` per kind; `scanned` (what the octree gave, at most 10000: `scanTruncated`, and
  `dropped`); `ms` (`octree`, `classify`, `total`: how long it took in the game, on `api.type.Clock`: the
  application time stays the same all through a frame, so it read 0 every time). The look at the entities stops
  after 2 s (it runs in one frame of the game's GUI): `timeTruncated`, and `looked` says how many were looked at.
- Per entry: `id`, `kind`, `name`, `x` / `y` / `z` (the box's centre), `box` (`x0`, `y0`, `z0`, `x1`, `y1`, `z1`),
  `sizeX` / `sizeY` / `height`, `dist`. Kinds, the first component found deciding: `street` / `track` (`BASE_EDGE`
  by its roadType; `template`, `from` / `to`, `construction` it belongs to, `halfWidth`), `node`,
  `town_building` (`TOWN_BUILDING`: `town`, `townName`, `construction`; its construction too, with `building`; a
  construction of a `building/...` file), `station` / `depot` / `industry` / `construction` (`CONSTRUCTION` by its
  stations, depots, industries; `fileName`; for each, up to 50 per answer: `place`, `ends` and `mouths` as `build`
  answers them, with `local`), `field` (`FIELD`), `town` (`TOWN`: its box covers the town), `asset` (`ASSET_GROUP`:
  trees, rocks), `model`, `moving` (vehicles, persons, animals), `map` (any box of 2000 m or more both
  ways but a road's, a track's or a town's, by its size only: what it was read as in `mapOf`; a game's entity 2,
  kind `other`, was a 14,336 m square, 2026-11-23) and `other`. `--kinds` takes some of them, or `all`; the default
  is all but `node`, `moving` and `map`. With `ms` on a clock that moves within the frame, the 2 s stop now takes
  effect.
- The boxes are the octree's bounding volumes: **axis aligned**, so a turned station or a slanting road reads
  larger than it is. Road and track widths (`halfWidth`, 6 m and 3 m) are **a guess**. What the octree does not
  hold is not listed (trees, if their asset groups are not in it).
- **Not checked in game yet** (written 2026-11-23): which entities the octree has, whether a town building's box
  is on its `TOWN_BUILDING` entity or its construction, the time it takes on a large map.
- `--lanes`: each `street` and `track` listed also gets `lanes`, as `lanes --edge` answers a piece (without the
  transport network), for the nearest 100 of them and within 2 s (the rest: `lanesSkipped`, and
  `lanesTimeTruncated`); the answer's `lanesRead` (pieces read), `lanesNote` and `ms.lanes`.

### A road's lanes (`lanes`, read only)

```
python3 tools/tf3ctl.py lanes --edge 9010[,9011,...] [--no-network]
```

- Reads only (no warning to others, nothing sent). Up to 20 road or track pieces by id (`around --kinds street`,
  `road --inspect-node` give them); each in the order asked, or an `error` (no such entity, no `BASE_EDGE`); `ok`
  when at least one was read, `read` / `asked`.
- Per piece: `edge`, `roadType` (`STREET` / `TRACK`), `edgeType` (`NORMAL` / `BRIDGE` / `TUNNEL`), `streetType`
  (the street template, `BASE_EDGE`'s roadTemplate), `roadStyle`, `node0` / `node1`, `from` / `to`, `chord`
  (straight metres between the ends), `distance` (`BASE_EDGE`'s own, as read), `width` (all lanes), `laneCount`,
  `tramTrackType` (from the lanes: `ELECTRIC` when a lane has `ELECTRIC_TRAM`, else `YES` when one has `TRAM`,
  else `NO`; `unknown` when a lane's modes did not all read as names), `tramLanes`, `busLanes` (`BUS` without
  `CAR`) and `hasBusLane`, `roadLanes`, `vehicleLanes`, `sidewalks` (lane numbers); `street`: what
  `BASE_EDGE_STREET` has of `streetType`, `tramTrackType`, `hasBus` (TF2's fields; the TF3 tealdef does not list
  them), and `tramMismatch` when its `tramTrackType` differs from the lanes'.
- Per lane (`lanes`, `laneConfigs` of `BASE_EDGE`, at most 32): `index` (1 = the leftmost looking from `node0` to
  `node1`, as type.d.tl says they run), `atNode0` / `atNode1` (the 0-based numbers `road --inspect-node`'s
  `laneConnections` use at each end: `index - 1` and `laneCount - index`), `vehicleIndex` (among the lanes with a
  vehicle mode, 1 = leftmost) and `outer` (the first or last of them), `side` (`left` / `middle` / `right`, by
  the widths alone: a lane within a quarter of its width of the middle is `middle`), `centre`, `left`, `right`
  (metres from the piece's middle with the offset, + to the right), `forward` and `direction` (`node0->node1` or
  `node1->node0`), `modes`
  (transport modes by name: `PERSON`, `CARGO`, `CAR`, `BUS`, `TRUCK`, `TRAM`, `ELECTRIC_TRAM`, `TRAIN`, ...),
  `modeKeys` (the keys as read; names by `enum[name]` for type.d.tl's sixteen, `unnamed` when one has none,
  `modesTruncated` past 64 keys), `speed` (m/s) and `speedKmh`, `width`, `offset`, `height`.
- `network` (unless `--no-network`): the piece's `TRANSPORT_NETWORK` edges in the engine's order (at most 64;
  `networkCount`): `index` (0-based), `modes`, `speedLimit`, `length`, `width`, `geometry`, `offset` (a cubic
  offset spline's). They are not matched to the lanes here.
- `centre` is **worked out**: the widths laid side by side left to right, plus the lane's `offset`. The base's
  templates give offset as a small nudge (town_new_medium_tram_electrified: sidewalks 0.15 / -0.15, the tram
  lanes -0.5 / 0.5), so + to the right is a guess from those numbers; `side` does not use it. Without every
  width, `side` comes from the lane's number alone and there are no metres. Two pieces that meet end to end
  (node1 to node0) keep left and right; meeting node1 to node1, one's left is the other's right.
- **Not checked in game yet** (written 2026-11-23): whether the game's `laneConfigs` keep the template's order
  and offsets, whether `transportModes`' keys are the enum's values (`modeKeys`: a sidewalk should read
  `CARGO,PERSON`), what the transport network's edges are per lane.

### Where a construction fits (`fit`)

```
python3 tools/tf3ctl.py fit --res ::/depots/road/road_depot.con --at 1200,800 [--radius 100] [--angle 1.5708]
python3 tools/tf3ctl.py fit --res road_depot --at 1200,800 --mouth 0,-35 [--link 8,40] [--link-edge] [--houses 5]   # + a link road
python3 tools/tf3ctl.py fit --res <station .con> --at 1200,800 --mouth 0,-12 --track --houses 5 [--catchment 150]
python3 tools/tf3ctl.py fit --res x.con --at 1200,800 --size 20,30 --check 0      # read only: no engine check
```

- Builds nothing. Its box: `--size W,D[,X,Y]` (in its own frame), else the engine's box for it at the point,
  unturned (one `build --dry-run --engine-check`). Then one `around` over the circle and what may reach into it,
  and the search here (tools/tf3ctl.py `fit_search`, plain functions tested without the game): places from the
  point outwards (a grid every `--step`, default 4 m), each turn (`--angle`, else four quarter turns), kept when its
  turned box keeps 0.5 m from every box around lists (not towns, trees, nodes, what moves or map, nor
  any box of 2000 m or more both ways: the map's own, which stood in the way of every place before, 2026-11-23) and from each road
  and track piece's line by its half width. `--mouth DX,DY` (a road end in its own frame: the `local` of a
  `connectable` mouth in `build`'s answer, or of `around`'s `mouths`; a road depot's is 0,-35, measured
  2026-11-23) tries instead only places from which one short straight road joins that mouth to a road piece of no
  construction: the mouth is never put on the road's node (a road depot's mouth on a dead end's node, two nodes
  at one point, was refused as not buildable with and without `--join-streets`, 2026-11-23). The link runs
  straight out of the box face the mouth is on (a mouth outside the box: the side it is beyond), `--link MIN,MAX`
  metres (default 8,40) from the mouth to the road's centre line; it ends on a node of a free road piece, at 60
  degrees or more from every piece there (a dead end: straight on or up to 120 degrees off it; at 30 the two
  roads' widths overlapped some 16 m out), each turn every 15 degrees, the places nearest the point first.
  `--link-edge` adds, after every node's, links ending on a piece's middle, 45 degrees or more across it and 4 m
  or more from its ends (off by default: `road` joins nodes only, so a piece ending on another's middle makes a
  new node there, not checked in a game; with `--angle`, only a piece whose way gives that very turn). The link keeps its half width (the road's
  it joins, at least 3 m) and 0.5 m from every other box and piece. With `--track` the mouth goes right on the end
  of a track piece, as before (the pieces at that end may meet the box there). Without `--mouth` nothing of this,
  as before; `mouthHint` gives the mouth of the same construction standing near, when around lists one.
  `--houses N`: at least N town buildings within `--catchment` (default 150 m) of the box's centre.
- Then the best `--check` places (default 3, 0: none) are asked of the engine in turn (`build --dry-run
  --engine-check`: this counts as changing the game, ask for it first); the first it would build is the answer:
  `place` (`x`, `y`, `angle`, `offset` from the point, `centre`, `houses`, `roadDist`, `link` with `--mouth`,
  `joinAt` with `--mouth --track`), `build` (the command to build it), with `--mouth` `link` (`from`: the mouth,
  `to`, `length`, `on` node or edge, `pieces`) and `road` (`road --from=... --to=... --snap 3`, to give after the
  build: its from snaps to the mouth's new node; the road piece is not asked of the engine), `refusedFirst` (the places the engine refused, with their `hits`). A place the
  engine calls buildable only with warnings, or with town buildings it would take, is not taken: that verdict is
  in the engine's own context, and the build gathers no fields or buildings (a road refused so, 2026-11-23). A
  place with `errorState.infos` only is refused too (see `build`: such a build is refused, 2026-11-23). An
  engine that cannot be asked stops it (`checked: false`), not counted as a refusal. None free: `ok: false`, "no
  free place", and `blockers` (what stood in the way of most places: id, kind, name, place, count);
  `tooFewHouses` counts free places with too few houses. At most 200000 places are tried (each against the
  obstacles near it only; about 2 s for 85000 in a 1600-house town): `complete` false and `searched` (how far
  out it went) when it stopped short, and the error names that distance. The grid has at most a million points
  (`--radius` / `--step`). `--check 0` answers the search's best place unchecked (`checked: false`).
- The boxes are the octree's (axis aligned: a turned thing reads larger) and the widths a guess, so the search
  only narrows the places; the engine's check decides. Water (a harbour) is not looked at.
- **Checked in game** (2026-11-23): a road depot's fit without `--mouth` near a town, its `build` built at once.
  **Not checked in game yet**: `--mouth` with its link and `road` (written 2026-11-23 after the node was refused).

### Whether a place can be got to (`reach`, read only)

```
python3 tools/tf3ctl.py reach --api                       # which engine functions are there (calls none)
python3 tools/tf3ctl.py reach --target 51                 # an industry / town building / station / construction
python3 tools/tf3ctl.py reach --town 11 [--limit 20]      # a town's targets counted, its problems
python3 tools/tf3ctl.py reach --problems                  # every town's problems (Disconnected, Overlength)
python3 tools/tf3ctl.py reach --from 4100 --to 51 [--mode walk|drive|lines|all] [--radius 40]
python3 tools/tf3ctl.py reach --from=-120,880 --to 51 --mode walk   # a point x,y as an end
python3 tools/tf3ctl.py persons --town 11 [--limit 2000]  # a town's residents, with what they reach
python3 tools/tf3ctl.py persons --destination 51          # those with the industry as a destination (its workers)
```

- Reads only (no warning to others, nothing sent). Made to find out why a town's people do not go to a workplace.
- `--target E`: the engine's destinations, `api.engine.util.pathfinding.getTargetsByLandUse()` (read once per
  command; every target of the map is in it, only the entries asked about are read in full). The answer has
  `entries`: one per list the entity is in, with `isReachableWalk`, `isReachableDrive`, `isReachableLines`,
  `capacity`, `freeCapacity`, `destinationWeight`, `edgeWalk` / `edgeDrive` (`entity`, `index`: the network edge
  the target is reached by), `landUseKey` (the list's own key) and `landUseGuess`; `counts`; `landUse` (the
  entity's own `PERSON_CAPACITY` type, to check the guess by); `found` false with `why` when it is no target (a
  home, an industry without workplaces). The answer is read by pairs as well as by index (a table from 0, or keyed
  by name, reads too); when it reads as no targets at all, `targetsRead` is false, `found` is null (not "no
  target") and `raw` describes what came (type, `#`, first keys, a few levels down); `reach --town` says so in
  `targetsWhy` and gives no `notTarget`. `read` says how it was read (`targets` or `top`, then `index`, `pairs`,
  `index1` / `index0` for a `targets` pair that only reads by number, and `flat` for entries without a list round
  them; `targets` is read by name, else as a getter, else from the metatable, and `raw.probe` / `raw.fieldProbe`
  say what each read gave: a type (with what a userdata prints as), nil, or the error; `targets/values` when its
  `__index` gives the pair as two values (`probe.indexCall` lists them); when nothing comes, `probe.other_*` has
  other names and the object read by number, for the next look); `targetLists[].read` how each list was; one that would not read
  makes a missing entity's `found` null too. A construction stands for its industries, town buildings and stations, a
  town building also for its PersonCapacity entity (`candidates`). With the building's town (or the closest town
  of an industry's construction) come `townProblems` (`api.engine.util.town.getTownProblems`: `problem` and the
  towns it is `with`).
- `--town T`: its buildings (`townBuildingSystem.getTown2BuildingMap`, at most 5000 read) by kind (`byKind`), the
  target entries of its shops and workplaces counted (`counts`: `walk`, `drive`, `lines`, `none`) and the first
  `--limit` listed, those out of reach first; `notTarget` counts the non-residential buildings that are no target;
  `problems` as above.
- `--from A --to B`: whether there is a path, by `api.engine.util.pathfinding.findPathNodeToNode` with
  `TransportMode.PERSON` (`walk`) and `CAR` (`drive`), one search per mode. An end is an entity or a point: the
  building's own `PERSON_CAPACITY` `personNodes` (walking) / `vehicleNodes` (driving), a target's `edgeWalk` /
  `edgeDrive` nodes, a station's terminals (`personNodes` walking, `vehicleNodeId` driving), a road or track
  piece's (`BASE_EDGE`) own transport network edges that carry the mode (their `conns`; `from.edge` gives its
  `node0` / `node1`), a junction's (`BASE_NODE`) the same (a junction with no network edges of its own: its
  network's nodes, modes not checked: `modesUnread`), else the network nodes within `--radius` m (default 40, at most
  500) of its position or the point (`findTransportNetworkNodesInCircle`); at most 32 nodes an end. A piece or a
  junction never takes the circle, so `--radius` does not change its answer (a piece without a lane for the
  mode: `found` null and `why`, which also tells a piece whose lanes for the mode give no node). A node both ends
  have from their circles, or that one end has from a circle wider than 40 m, says only that the circles
  overlap: it is left out of the circle's end (`sharedNode`, `droppedFrom` / `droppedTo`) and the rest searched;
  only when an end has nothing left: no search, `found` null, `trivial: true`, `why` (try a smaller `--radius`).
  A node both ends have of their own (a piece, a station, a target), at any radius, or that one end has of its
  own and the other from a circle of at most 40 m, is `found: true`, `sameNode: true`, with `sameNodeFrom` /
  `sameNodeTo` saying where each end had it (`circle`, `edge`, `node`, `terminal`, `target`, `personCapacity`).
  A circle is flat (a point and a radius, no height): round a point by a bridge, or under one, it holds the
  nodes above and below at any radius, 40 m too, so an end from a circle may start on the wrong level
  (`circleNote` says so on each search with a circle); give the road piece's id as the end to be sure. Per mode in `paths`: `found` (null when an end
  has no nodes: `why`), `edges`, `pieces` (network entities on the path; the first 50 in `pieceIds`), `ms`, and
  where the nodes came from (`fromFrom` / `toFrom`); a miss has `unverified: true` until a game shows the search
  finds such paths at all (first try two places known to connect); a search of 100 ms or more is logged. The
  engine gives no cost. There is no line path search to
  call: `lines` gives the target's `isReachableLines` only (`--mode lines` does no search).
- `persons --town T` lists the people whose home is one of the town's residential buildings
  (`getSimPersonsForDestination` of each); `persons --destination E` those with E as a destination (E must have
  a `PERSON_CAPACITY`). Every person of `persons` now has `reachable` (`walkDrive`, `lines`: the engine's
  `landUse2ReachableWalkDrive` / `landUse2ReachableLines`, how many destinations of each land use the person
  reaches), and `summary.reach` counts, per place of those lists, how many listed persons reach at least one
  (`none`: nothing either way).
- **Not checked in game yet** (written 2026-11-23): whether `getTargetsByLandUse` and `getTownProblems` are there
  in the GUI script (`reach --api` tells), the shape of `getTargetsByLandUse`'s answer, which land use each of its
  lists is (two lists: guessed commercial, industrial) and the same for the two numbers of `reachable`, whether
  `findPathNodeToNode` finds walking paths between these nodes (another mod's notes say it gave nothing between
  station terminal nodes), how long a search takes on a large map; for a piece or a junction (written
  2026-11-24), what its network's edges and their `conns` are in a game (whether a piece's lanes end in its
  junctions' networks, so two joined pieces share a node, or only meet through the search) and whether
  `transportModes` reads by `pairs`.

### My Mods from the main menu (`modhub`)

```
python3 tools/tf3ctl.py modhub status [--folder my_mod_1] [--wait 30]   # read only
python3 tools/tf3ctl.py modhub validate my_mod_1 [--timeout 300] [--messages 50]
python3 tools/tf3ctl.py modhub publish my_mod_1 --public yes|no --changelog "..." --first-upload [--version X.Y.Z] [--dry-run] [--timeout 900]
python3 tools/tf3ctl.py modhub publish my_mod_1 --public yes|no --changelog "..." [--previous-revision N] [--version X.Y.Z] [--update-metadata] [--dry-run]   # update
python3 tools/tf3ctl.py modhub publish-clear --yes
```

The base's MOD hub > My Mods page lists the mods in `<user data>/staging_area/<folder>/` and validates and uploads
them through one C++ object, `api.type.modhub.ModPublishHelper` (its buttons call its methods; no event is fired).
In the main menu (a game launched by `launch` / `restart`, before a save is loaded) the probe makes its own one.
`status` and `validate` use only its reading part; `publish` (below) is the one upload, held in narrow bounds. No
other method that changes a staging mod (`setRemoteModId`, `refreshMod`, the image setters, ...) and none of
`api.modhub`'s writes (subscribe, rate, report, log in or out, ...) are called anywhere, and the tests check that,
along with `publish`, `abortPublish` and `PublishSettings` appearing only in the one marked block of
`content/remote_modhub.lua`. Inside a save all three commands are refused.

- `status` answers whether `ModPublishHelper.new` worked (or the game's error message as it is), `hasPrivilegedApis()`,
  the backends, mod.io's state (initialized, start-up check done, busy / uploading, logged in as true / false; no
  names), and for each staging mod: the folder, its id's value, the title, `state` (Sync, Ready, Publishing,
  HasResult), `modhubId` (valid, value: the mod.io id of an earlier upload), `modhubDetails` (what mod.io holds:
  found, `visible`, title, version) and whether the page would upload it as new, update it, or warn that the mod.io
  mod is gone (`upload`: new / update / remoteMissing). It waits up to `--wait` seconds for mod.io to be ready and
  for the staging mods to leave Sync (with `--folder`, only that folder's mod), then answers what it has
  (`timedOut` says what it was waiting for).
- `validate FOLDER` runs the helper's `validate`, as the page's Re-Validate button, calls `update()` every frame
  until it is done, and answers the result as the page counts it (`text`, counts of Critical / Error / Warning,
  the first messages) with `criticalPc`, `criticalConsole`, `levelPc` and `levelConsole`. Progress goes to stderr
  every 15 s. It waits up to 30 s for mod.io to be ready and up to 60 s for the mod to leave Sync; a mod in
  Publishing or HasResult (an upload has it) is not touched. A mod the helper does not know yet counts as in Sync,
  as on the page. `--timeout` covers the whole command, these waits included; past it a running validation is
  aborted (`abortValidation`, as the page does when it closes). Only the folders listed in `MODHUB_VALIDATE_FOLDERS`
  (content/remote_core.lua) are taken; edit the list for your own mods.
- Making the helper makes the game sync the staging mods with mod.io: read requests to mod.io, no writes.
- The helper is made once, by the first modhub command that finds mod.io ready. If `ModPublishHelper.new` fails, the
  probe keeps that error and does not try again while the game stays in the main menu: every later modhub command
  answers the same error. Restart the game to try again.
- `validate` counts as changing the game (`--owner` warnings): it runs the validator for minutes and aborts a
  validation already running for that mod, e.g. one a person started on the My Mods page. Do not open My Mods while
  it runs: the page makes a helper of its own.
- `status` and `validate` worked in game (2026-11-22): the menu probe made `ModPublishHelper` although it is marked
  "privileged api, not available to mods", a staging mod's id reads `StagingArea,<folder>`, and a new mod read
  Ready with no valid `modhubId`. Other staging mods may stay in Sync for minutes; `status` without `--folder` waits
  for all of them.

#### Uploading a mod (`modhub publish`)

`publish FOLDER` uploads a staging mod to mod.io as the page's Upload / Update button does: either a **first
upload** (a new mod page, with `--first-upload`) or an **update** of the mod.io page the folder was uploaded to
before (without `--first-upload`). The page uses the same call for both (`ModPublishHelper.publish`) and only names
the button "Update" when mod.io holds the mod; this tool never guesses which one is meant. A new mod page or a
public mod cannot be undone from the game, so every one of these must hold, or nothing is sent:

- The folder is in both lists of folders publish takes: `MODHUB_PUBLISH_FOLDERS` in `tools/tf3ctl.py` and in
  `content/remote_core.lua` (separate from validate's list). Edit both for your own mod. A folder already on mod.io
  is also held to its mod.io id in `MODHUB_PUBLISHED_IDS` (both files): `--first-upload` is refused for it, and an
  update only goes when its fileid file holds that id (a lost fileid file would otherwise make it look new).
- `--public yes|no` (no default) and a non-empty `--changelog` are given.
- `_metadata/mod.io_fileid.txt` in the staging folder (the game writes it after the first upload, with the mod.io
  id; it is what makes the next upload update the same page): with `--first-upload` it must **not** be there (else
  a second page would be made); without `--first-upload` it **must** be there and hold one id (else the update
  would make a new page). The two mix-ups are refused before anything is sent.
- A `_metadata/0.png` that is a PNG of at least 512x288 and at most 8 MB (mod.io's limits; the page refuses without
  it, "No valid cover image found").
- `_metadata/modinfo.json` is there and its fields fit, counted in characters (not bytes): `name` (the mod.io name)
  at most 50 and `summary` at most 250 (mod.io's limits; mod.io refuses a longer name only after the upload began,
  "code 13009"), `description` and `--changelog` at most 50000 (this tool's guard: mod.io writes no limit for them).
  name, summary and description are not empty; `tags`, if given, is a list of strings. `--dry-run` answers each
  length with its limit (`local.metadata`).
- No publish mark (below) is there.
- An update only: `mod.json`'s `revision` is a whole number above the last one uploaded to that mod.io page. The last
  one is the highest `revision` that `publish_history.jsonl` (below) records for that folder and mod.io id (uploads
  mod.io took: success, partial errors, a late fileid). When the history has none (an upload from before the history
  kept the revision), give `--previous-revision N`, the revision now on mod.io; it is refused for a first upload,
  and when the history has a revision it must agree with it.
- `--version X.Y.Z` (optional, first upload or update): whole numbers without leading zeros, Y and Z 0-99, and the
  same number as `mod.json`'s `revision` written X*10000 + Y*100 + Z (revision 10003 takes only 1.0.3; revision 1
  only 0.0.1). The mod checks it again against the revision the tool sends, and the tool refuses the upload when
  the mod's dry run would not send it (an older remote_probe in the game ignores it).
- `--update-metadata` (optional, an update only; refused with `--first-upload`): see `updateMetadata` below. The
  tool refuses the upload when the mod's dry run would send another `updateMetadata` than asked (an older
  remote_probe in the game always sends true).
- In the game, a first upload: the mod is Ready, its `modhubId` is not valid and mod.io holds no details for it
  (new). An update: the mod is Ready, its `modhubId` is the id of the fileid file, mod.io holds details of that mod
  (without them the page warns the mod got deleted on mod.io and would make a new one: refused), and `--public no`
  is refused for a mod public on mod.io (the page's "Set Public" box is disabled then; a hidden one may stay hidden
  or turn public). Both: mod.io is initialized, allows uploads and is neither busy nor uploading; someone is logged in (otherwise the answer names
  `requiredUserAction: "login"` and stops: the page would show its login window); the local cover is set.
- A fresh validation (run first, as the page does before it enables the button) has no critical issue and neither
  `levelPc` nor `levelConsole` at Error or Critical: there the page asks a person to "Proceed Anyway", which this
  does not answer.
- One upload per launch of the game.

`--dry-run` goes through all of the above, including the validation, and answers the settings it would send; it
never calls `publish`. For an update the answer also has `update`: the mod.io id (`modioId`), the name that goes up
(`name`, from modinfo.json) and the name, visibility and version mod.io shows now (`modioTitle`, `modioVisible`,
`modioVersion`), the new and the last revision (`revision`, `previousRevision`, `previousFrom`: the history or
`--previous-revision`) and the changelog. Every answer has `updateMetadata` (true / false: whether modinfo.json's
name, summary and description are sent) and `updateMetadataNote` or, for an update with `--update-metadata`,
`updateMetadataWarning`: the mod.io page's description will be overwritten and has to be put back afterwards.
Without `--update-metadata` the note also names a modinfo.json name that differs from mod.io's title (it stays).
With `--version` the answer has `additionalMetadata`, what the mod
sends (`{"version": "X.Y.Z"}`). Without `--dry-run` the tool runs the same dry run first (a refusal there leaves nothing
behind), then writes a **publish mark**, `$XDG_STATE_HOME/tf3ctl/publish_pending.json` (`~/.local/state/tf3ctl/`
without it; folder, owner, time, visibility, first upload or update, mod.io id, updateMetadata, revision, version), and only then sends the
upload. While a mark is there, every publish
is refused. The mark goes only (1) when the upload succeeded without partial errors and the fileid file appeared
(within 60 s) holding the mod.io id the game answered (for an update the file is there from before, so this only
compares the game's answer with its id; an update the game answers with another mod.io id is not a success, and
the mark stays), or (2) by `modhub publish-clear --yes`, which a person runs
after looking at the account's mods on mod.io (refused while the running game says the upload is still
Publishing). Any other end (a failure, partial errors, a refusal after the mark, a timeout, a lost game) leaves it.
Every upload sent also adds one line to `publish_history.jsonl` next to the mark (time, owner, folder, visibility,
first upload or update, updateMetadata, revision, version (`--version`, else null), outcome, mod.io id, fileid), success or not; the next update compares its
revision with it. While a mark is there, or while the mod refuses a quit because the
upload is Publishing, `quit --kill` and `restart` do not kill the game, not even with `--force`. **Do not load a
save or quit the game by hand from the menu while an upload runs.**

The settings are built as the page builds them for a mod of the My Mods tab (`mod_manager_react_util.tl`): a new
`PublishSettings` with `setPublic` from `--public` (the page's "Set Public" box, false by default for a new mod and
mod.io's visibility for an update), `updateMetadata` (one boolean for the name, summary and description together;
the API has no field for each), `changeLog` from `--changelog`,
`isSavegame = false` and `issuesConfirmed = false` (no "Proceed Anyway" was asked). With `--version`,
`additionalMetadata = {version = "X.Y.Z"}` too (the API: "Free-form extra metadata merged into the upload's
metadata"; the page sets it only for savegames); without it, additionalMetadata is not set. The answer has them all.

`updateMetadata` differs from the page in one case. The page sends true for both (its default; the box is disabled
for a new mod). This tool sends true for a first upload (the new page needs them), but **false for an update unless
`--update-metadata` is given**: with true, the game replaces the mod.io page's name, summary and description with
modinfo.json's, and a description written on mod.io by other means (e.g. a longer HTML one through mod.io's API)
is lost. Give `--update-metadata` only when the name or the summary has to change, and put the description back
afterwards.

After `publish` the command answers its progress every 15 s and waits for HasResult up to `--timeout` (default 900
s, the whole command). The result is answered as the game gives it: success with the mod.io id and any partial
errors (the page's "Upload Failed" list), or the error's code, debug message and localized message. Then, as the
page does (at once after a failure, at its Ok button after a success), the probe calls `abortPublish` to clear the
result; it never calls it before HasResult. Past `--timeout` the upload is **not aborted** (the page never aborts
one in progress, and what would be left on mod.io is unknown): the answer says the outcome is unknown, the mark
stays, and `quit`, `load` and `newgame` are refused while the mod is still Publishing, so the game can finish it.
`modhub status` then shows the result and `publishedThisLaunch`.

- **Checked in game:** a first upload (2026-11-22): mod.io took the mod, and the fileid file held its id. An update
  sent with `updateMetadata = true` (2026-11-23): the mod.io page's description (HTML put there through the API)
  was replaced with modinfo.json's plain text.
- **Not checked in game:** an update with `updateMetadata = false` (whether the page's name, summary and
  description then stay as they are); whether the game writes `mod.io_fileid.txt` at the result or only at the
  page's Ok (`abortPublish`); whether `setPublic = false` makes a hidden mod on mod.io; what mod.io's `version`
  holds after an upload (it is only shown, never compared); whether `--version` (additionalMetadata) reaches the
  version of the file on mod.io (without it the game sent "1.0" for revision 10003).

### Several clients at once

Several tool processes may run at once (a long `run` plus `status` calls, say): a lock makes them write the single
command file one after another. When more than one person or script shares a game, give each a name with
`--owner NAME` (or `TF3CTL_OWNER`). It is shown in `status` (`run.owner`, `lastAction`), and a client gets a
warning on stderr before any command that changes the game (`load`, `run`, `speed`, `save`, `buy`, `line`, ...)
when another owner changed the game in the last 10 minutes. `quit --kill` will not SIGKILL a game another owner
used in the last 10 minutes unless `--force` is given.

### Only the owner who started the game changes it

While the game runs, a command that changes the game (everything counted as such: `save`, `quit`, `load`,
`newgame`, `speed`, `run`, `build`, `line`, `event`, `window`, `modhub validate` / `publish`, ...; also the quit
inside `restart`) is sent only when `launched.json` (below) names this `--owner` and its pid is the running game.
Otherwise tf3ctl refuses it before writing anything for the game, with exit code 4 and `"refused": "owner"`:

- the record names another owner (or the command has no `--owner`);
- there is no record, or its pid is not the running game: the game was started outside tf3ctl, for example by a
  person from Steam.

`quit --kill` and `restart` never go on to SIGKILL a game they were refused, and SIGKILL only the processes the
quit was sent to (not a game started meanwhile). `launch` / `restart` with `--load` / `--new` need `--owner`: without
one they are refused before anything is quit or started, and when the record cannot be written the game is left
in the main menu and the load is not sent. Commands that only read, a
`--dry-run` / `--list` (except `modhub validate` / `publish`, whose dry run still runs the validator), and `camera`
without arguments always go. When the game is not running at all, nothing is checked (`launch` and `restart`
start one, also with `--load` / `--new`, and the new record names the owner who started it). A script left running after a crash
therefore cannot change a game somebody else started meanwhile.

`--other-owner-ok` (before the command) sends anyway, for a client the others agreed may use that game: stderr
gets a warning, the answer an `otherOwnerOk` field (`launchedBy`: the record's owner, or `none` without a usable
record; `why`; `owner`), and the game's log line for the command says `(--other-owner-ok: the game of ...)`, even at log level 1. With it,
`quit --kill` may also kill that game.

### Who launched the game (`launched.json`)

`launch` and `restart` with an owner (`--owner` or `TF3CTL_OWNER`) leave a small record of which owner started the
running game and its process id. tf3ctl itself reads it before game-changing commands (above), and other tools
on the same machine may too: a guard that holds back game-changing commands while the game runs can read it and
still let the owner who started the game quit it. A game started by hand from Steam has no record.

- Where: `$XDG_RUNTIME_DIR/tf3ctl/launched.json`, or `/tmp/tf3ctl-<uid>/launched.json` without `XDG_RUNTIME_DIR`.
  The folder is 0700 and the file 0600; it is written to a temporary file in the same folder and renamed over the
  old one, so a reader never sees half of it.
- What: one JSON object, `{"v": 1, "owner": "<owner>", "pid": <the game's pid>, "started_at": <epoch seconds>,
  "cmd": "launch"}` (`cmd` is `launch` for `restart` too; `started_at` is when the probe answered).
- The coop mark (`coop`, above) adds one key, nothing else changes: `"coop": {"with": "<owner>", "reason": "<text>",
  "since": <epoch seconds>, "until": <epoch seconds>}`, and on a person's save also `"modified": true, "changes":
  <count>`. tf3ctl writes `with` as one name; a reader should take a list too. A game a person started gets a
  record without `owner`: `{"v": 1, "pid": ..., "started_at": ..., "cmd": "coop", "coop": {...}}`. It is not
  coop when the key is missing or the pid is not the running game. A key on the running game whose `until` is past,
  or that is malformed, is the strict side (see "Expired or malformed mark" below). `coop end` removes the key
  only (the record stays, so a person's game then has a record without owner and coop, which counts as none); when
  the game was changed it leaves `"coopChanges": <count>` at the top, so that a later `coop start` on the same game
  says so again (it is not a mark: readers ignore it).
- Written: after `launch` / `restart` once the probe answered in the main menu (before `--load` / `--new`). The pid
  is the running `TransportFever3` process (the newest one if there are several). Without an owner nothing is
  written, and an older record is removed.
- Removed: whenever tf3ctl saw the game stopped: `quit` (also `--kill`, and when the game was not running), the quit
  of `restart`, a `launch` that finds no game running, and a game that ended during the launch or during the
  `--load` / `--new` that followed it (also with `load` / `newgame` on their own).
- The answers of `launch` / `restart` / `quit` say what was done in `launchedFile`. Not being able to write or
  remove the record is only a warning on stderr. A record left behind (a crash, a quit by hand) is not to be
  trusted alone: readers should check that the pid is alive and is the game, and, under `/tmp`, that the folder
  and the file belong to them and are 0700 / 0600 (anybody may have made `/tmp/tf3ctl-<uid>` first).

### Sharing the game with the user (`coop`)

The owner check above keeps every other client off a game, which also keeps a client off a game the user is
playing with it. `coop` is for that: the user and one client (its `--owner`) share the running game for a while.

```
tf3ctl.py --owner bob coop start --reason "test the new depot with the user" [--minutes 60]
tf3ctl.py --owner bob launch --load probe-x --coop --reason "..." [--minutes 60]   # start, load, then share
tf3ctl.py --owner bob coop end
```

- `coop start` goes on the game this owner started, or on a game a person started from Steam (no record of the
  running game; the record then names no owner, only the coop mark). Never on another owner's game, and not while
  another client's mark counts (`--other-owner-ok` changes neither). Again by the same owner renews it. `--reason`
  is required (1-200 characters), `--minutes` is 1-10080 (7 days). Renewing keeps the change count of the mark.
- While it counts, this owner may send what helps the user: every reading command, `camera`, `window` (not
  `--close-all`), `event`, `build` (and `fit`), `road`, `stock set`, `money`, `steps`. This holds on the user's own
  saves too.
- Only with `--user-asked` (when the user asked for it): `speed`, `run`, `pause`.
- `save` only to a test save's name: `probe-*`, `aom-ops-*`, `aom-shot-*`, `aom-bgm-check-*`, or one digit first
  (`3-probe`); never another name, not even with `--user-asked`. With a person's save loaded (a name not of that
  kind, a new game, or unknown), a save to a new test name needs `--user-asked` too.
- Everything else is refused: `quit` (also `--kill`, and the quit of `restart`), `load`, `newgame`, `tool`, `buy`,
  `line`, `terrain`, `town`, `modhub`, ... Exit 4, `"refused": "coop"`, nothing sent; the message says why.
- The loaded save is read from the game's log (the last `Loading game from file` / `Start new game` since the
  start).
- On a person's save, each game-changing command the mod took (not `camera`, `window`, `speed`, `save`, nor a dry
  run) sets `"modified": true` and counts `"changes"` in the mark. `status` and `coop end` then say that the game
  was changed during coop and that saving keeps the changes; `coop end` adds that the autosave has the changed
  game, and that to go back the user loads a named save without saving. Each line is in `text` and `textJa`.
- Other clients are refused as before (`--other-owner-ok` as before).
- It ends when the game is gone (a reader sees the record's pid is not the running game), when tf3ctl removes the
  record (quit), or with `coop end`, which removes the mark only (anybody may: it only takes rights away). `status`
  shows it in `coop` (`active`, `with`, `minutesLeft`, `save`, `testSave`, `text`, ...).
- Expired or malformed mark: reaching `until` does not end coop, and tf3ctl never removes or changes the mark for
  it. The user may still be playing, so the strict side holds (like the game guard outside): while a mark on the
  running game is expired (`until` past) or malformed (no `with` or an empty one, `until` not a finite number or
  more than 7 days ahead, NaN, Infinity, the mark not an object), the game's launcher and the mark's client send no
  game-changing command at all: exit 4, `"refused": "coop-expired"` or `"coop-invalid"`, nothing sent, also with
  `--other-owner-ok`. Reading commands still go, and so do `coop start` (extends the mark, or writes a malformed
  one anew; the change count stays) and `coop end`. Other clients are checked as before, except on a game a person
  started whose malformed mark names no client that can be read: whose coop it is is not known, so every client is
  refused (`"coop-invalid"`, also with `--other-owner-ok`). `status` shows it in
  `coop` with `"expired": true` or `"invalid": true` (and `why`), in `text` and `textJa`. A mark whose pid is not
  the running game is no mark (the game ended).

### Environment

- `TF3_REMOTE_DIR`: the exchange folder (default: the one with the newest hello file under Steam's userdata,
  looked for in `~/.local/share/Steam`, `~/.steam/steam` and the Flatpak Steam).
- `TF3_LOG`: the game log (default: `crash_dump/stdout.txt` next to the exchange folder).
- `TF3_STEAM`: the command that starts Steam (default `steam`).
- `LUAJIT`: the luajit binary.
- `TF3CTL_OWNER`: the default for `--owner`.
- `TF3_PROFILE`: the game's `profile.lua` for `--lang` (default: next to the exchange folder, else the newest under
  Steam's userdata). Its backup is the same path plus `.tf3ctl-backup`.
- `TF3_GAME_DIR`: the game's install folder, for the languages `--lang` may pick (default: `steamapps/common/Transport
  Fever 3` of the Steam that has the userdata).
- `TF3CTL_OTHER_BACKUPS`: other tools' backups of `profile.lua` (files or folders), separated by `:` (see `--lang`).
- `XDG_STATE_HOME`: where `modhub publish` keeps its mark (`tf3ctl/publish_pending.json`; default `~/.local/state`).

## Mod settings

| Setting | Values | |
|---|---|---|
| Idle check interval | 1 / **2** / 5 / 10 s | how often the command file is read when no command came for a while (one read takes a few ms) |
| Check interval after a command and during a run | 0.1 / **0.25** / 0.5 / 1 s | for two minutes after a command and during a `run` |
| Log amount | Minimal / **Per command** / Detailed | `[remote_probe]` lines in the game log |
| Label beside the speed buttons | **Show** / Hide | e.g. `×16 real ×3.2 →2045-07-03` for speeds the buttons do not have, and during a `run` |
| Game script commands (test saves) | **Off** / On | on: the mod's game script takes `running-costs` writes (`--param hummer_remote_probe:gameScript=2`) |

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
  loading page waits for it; `--wait-for-start` keeps that). With `--wait-for-start` the loading screen stops at
  the button until a person clicks it, and meanwhile the mod takes no commands, not even `quit` (the tool never
  clicks it). Use it only with someone at the game. The tool says so on stderr while it waits, the answer
  after the click carries a `note`, and a load that times out names the button as the likely cause.
- `line delete` refuses a line with vehicles unless `--sell-vehicles` is given. It skips the base checks for
  missions and protected entities (it is meant for test saves).
- `stock set` and `steps` are the game's debug commands: use them on test saves only (nothing tells a test
  save from a player's; they are not checked in game yet).
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
- `build`, entirely (see "One construction on the map"). `road`, entirely (see "One straight road").
- The gui way's own send of a bought vehicle to its line and the refusal's reason; `lines --problems`;
  `stations --catchment`.
- `terrain`, `terrain --probe-api` and `newgame --editor`, entirely (see "The ground in a rectangle").
- `town`, entirely (see "One town").
- `town connections` and `town connect`, entirely (see "Town connections").
- `company` and `company init`, entirely (see the new game's company progression under "Saves and new games").
- `stock` and `steps`, entirely (see "Stocks and simulation steps"): test saves only.
- `parcels`, entirely (read only, see "Town building parcels along a road").
- `lanes` and `around --lanes`, entirely (read only, see "A road's lanes").
- `around`, entirely (read only, see "What stands near a point"); `build` / `road` `hits`, `--remove-buildings`,
  `--join-streets` and `joins`; `build --dry-run --engine-check` and `fit`, entirely.
- `persons`, entirely (read only): whether the sim person components and the quality counts read in the GUI script.
- `reach` and `persons --town` / `--destination`, entirely (read only, see "Whether a place can be got to").
- `modhub publish` of an update (see "Uploading a mod"). `modhub status`, `validate` and a first upload were
  checked on 2026-11-22.

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
  states). Requests left from the previous game are dropped on load, so a request sent right after a load may be
  answered "took it as old; not run". The answer waits for the recipe, as `event`'s does.
  With `--manager` (a line by `--line NAME` or `--entity ID`, the company's own only) it fires
  `openVehicleManager` with `{openWithLineEntity = line}` instead, as the line window's "Manage Line" button and the
  statistics' line rows do; the manager selects the line on its next step. Not checked in game yet.
- **`event`** takes a react event name and, as its parameter, a JSON object of plain values. `window`, `event`,
  `tool` and `build-tool`'s events go into a queue in the GUI save data (`opens`), and the recipe fires them one per
  read (every 0.5 s), oldest first. Until 2026-11-22 this was a single slot: of two events sent in the same second
  only the second was fired. The answer comes once the recipe has fired the event and said so (under
  `<mod>.open`), with `"relayed": true` and `relayedInSec` (about 0.5-1 s, plus 0.5 s for each request queued
before it), so a script that sends events one
  after another gets them in that order. The answer is an error when the recipe's `fireEvent` raised
  (`"relayed": true`, "relayed, but ..."), when the recipe did not take it within 10 s (`"relayed": false`: no game
  on screen, the ESC menu or a dialog, or another mod's speed control in its place; it is then dropped and never
  fires later; the 10 s count from when it was queued, so only about 19 can wait at once), or when it was left from
before the recipe's first read (a load). A request still waiting when a game loads gets no answer: tf3ctl gives
up after 20 s with "no answer". Relayed means fired, not that a
  listener acted on it: whether a window opened shows in `frame` or the log.
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
- With `--line` via gui, the base store's `HandleVehicleChanges` buys as before (purchaseTime, autoload) but gets
  no line; the mod then sends each new vehicle with the same `makeVehicleSetLineCmd(vehicle, line, 0)`, with its
  own callback (the base's only logs a refusal, so a refused vehicle stayed in its depot and the answer timed out).
  A refusal answers at once with `ok: false` and, per vehicle in `setLine`, `ok: false`, `reason` (the
  `Failure.Reason` name from `getFailedPathReason(vehicle, line, true)`, as the line manager asks: `NoPath`,
  `NoSmallShip`, `NoElectric`, ...), `message` (the line manager's text for it, when it has one, e.g. "No path for
  big ships.") and `position` (where the path fails, when given). A vehicle with no answer yet stays
  `pending: true` until the 60 s timeout. `--via cmd` is unchanged (a failure, no reason). Not checked in game.
- Ships: a large ship (mode SHIP) needs a large pier at every stop; the engine may assign a small one (SMALL_SHIP
  only) and refuse the ship (`NoSmallShip`). Make ship lines with `line create --terminals`, picking large piers
  (`transportModes` with SHIP in `stations` platforms), and check them with `lines --problems`.
- Multiple units: a `--model` ending in `.mu.lua` (e.g. `shinkansen_0s.mu.lua`, or the official TGV mod's
  `tgv.mu.lua`) buys that multiple unit, as the store's multiple-unit row does: every car its file lists, in order,
  each turned round where the file says `forward = false`, its model found by `api.res.modelRep.find`, sent as one
  vehicle with `vehicleGroups = { n }` and `muFileNames = { <the file's name> }` (`vehicle_configs.muParts` /
  `newMuConfig`, after `vehicle_store_window.tl`). The name is matched against both names of each unit `api.res.multipleUnitRep.getAll()`
  lists (its value, and `getName(id)`): the whole name, then without case, folder and `.mu.lua` / `.mu`
  (`shinkansen_0s.mu` works too), then a unique part of that. `muFileNames` gets `getName`'s, as the store sends it;
  a unit without one is refused. When `getAll()` is empty, `getAll(true)` is counted in the error and listed by
  `models --mu` (`invisible: true`), never bought from (the store does not offer those). A miss says how many units
  there are, those whose names hold a piece of the query, and the first 5. `models --mu [FILTER]` (read only)
  lists them: `id`, `fileName`, `getName`, `value` (getAll's), `name` (shown), `cars`, `buyAs` (what `--model`
  takes: the whole name when two units share a file name); FILTER matches a name or the shown name. The whole file is checked before anything is sent: no cars, a car the game has no
  model for, or one that is no vehicle model, is an error. Via gui only (`--via cmd` is refused), and `replace` takes
  no multiple unit. The answer adds `multipleUnit` (`id`, `fileName`, `name`, `parts` with each car's `modelId`, `name`,
  `forward`); `storeParts` and `storePriceTotal` cover every car; `sentParts` and `vehicles[].parts` mark any
  turned-round part with `reversed: true` (for any vehicle, not only a multiple unit), and each vehicle bought this
  way carries the engine's `vehicleGroups` and `muFileNames`. A file name (the folder left out) that equals the
  query wins over names that only contain it. A train of single models put together by hand (a locomotive and its coaches) is not offered.
  Not checked in game yet.
- `buy` needs `--depot` (the store only picks a depot when opened from one); count 1-20; with `--line` the first
  stop is stop 0. `duplicate` copies the config with parts at `purchaseTime` 0 and maintenance 1, as the base
  clone does; depot and line default to `findBestLineAndDepotForVehicle`.
- `replace` and `sell` via gui get no callback from the base, so the mod watches the vehicle each frame. A replace
  is done when the parts match what was sent or differ from before (`matchesSent` tells which). When the new parts
  equal the old ones, it answers `ok: false, uncertain: true` rather than guess.
- `models` (read only) lists vehicle models (those with `metadata.transportVehicle`), sorted by file name,
  matched by `--grep` (a part of the file name or the shown name, any case; digits also match the id) and
  `--carrier`. Per model: `price` / `priceScale` (`metadata.cost`) and `runningCosts` / `runningCostScale` /
  `lifespan` (`metadata.maintenance`) as the vehicle store reads them (the base fills in a -1 from its formula at
  load, `model_metadata_util.addCostMetadata`, then scales them by the difficulty, `post_run_util`), `topSpeed`
  (m/s, of the land, air or water part as the store) and `topSpeedKmh`, `loadSpeed`, `arrivalDelay` /
  `departureDelay`, `carrier`, `transportModes` (SHIP / SMALL_SHIP ...), `yearFrom` / `yearTo`, `water` (the
  waterVehicle: speed, weights, power, and `small` = SMALL_SHIP in `transportModes`, which is what the .mdl's
  `waterVehicle.type = "SMALL"` becomes at load; `type` itself is not in the engine's record and stays empty), `compartments` (each load config's capacity and
  cargo set) and `capacities` (per cargo type) / `totalCapacity` summed as the store does (per compartment the
  largest of its configs). `total` counts every match; details only for the first `--limit` (200, at most 1000). The
  models are walked once per load of the mod's script (a log line when that takes over 0.5 s).
- `vehicles --state` adds, per vehicle, what the engine holds about its stop: `state` (IN_DEPOT, EN_ROUTE,
  AT_TERMINAL, GOING_TO_DEPOT), `loadState` (Arrived, Unloading, Loading, WaitForScheduledDeparture, Departing),
  `doorsOpen` / `doorsTime` (game time the doors opened or closed) and `sinceDoors`, `stopIndex` and `stop` (the
  line's stop, `stops[stopIndex + 1]`), `lineStopDepartures` (last departure per stop), `sectionTimes`,
  `timeUntilCloseDoors` / `timeUntilDeparture` / `timeUntilNextLoad` / `timeUntilNextUnload`, `loadSpeedModifiers`
  (per cargo type it has room for, with `totalPenalty`), `cargo` (capacity and count on board), `speed`,
  `runningCostPerYear` (`getRunningCost`, as the vehicle window), `balanceLastYear` (as the statistics' vehicle
  table) and, with `--since T`, `balanceSince`; the answer also has `gameTime`. `--entity` takes ids
  (comma-separated, at most 50); a vehicle that is gone or not the company's is listed under `missing`, one on
  another line than `--line` is left out. Without `--entity`, `--state` answers at most 50 vehicles (`total`
  counts all). Fields the
  engine does not give are left out. Without these options the answer is as before. To time a stay in port, poll
  every few seconds: while AT_TERMINAL note `stopIndex` and `doorsTime` (the doors opened); once it has left, the
  departure is `lastLineStopDeparture`, and also the entry for that stop in `lineStopDepartures` (the JSON list's
  element `stopIndex`, counting from 0). Units of the game time and of the timeUntil* fields are not checked in game.
- `gameTime` in a `vehicles --state` answer is the engine's `GAME_TIME.gameTime`, read once per answer before the
  vehicles, so every vehicle in it is of that one frame (and `sinceDoors` is counted from it). `--at-terminal` (with
  `--state`) lists only the vehicles whose `state` is AT_TERMINAL now (`total` counts those; one of `--entity` that
  is not in port is neither listed nor missing; one whose state cannot be read is left out and counted in
  `stateUnknown`, so an empty list with `stateUnknown` above 0 is not "nobody in port"). `--every SEC --count N`
  repeats the call as `persons --every` does (one compact JSON line per sample with `sample` and `unixTime`, the
  same rules for stalls and skipped slots), so the cargo on board while in port can be logged against the game
  time. **Not checked in game yet** (written 2026-11-22): in particular how far `gameTime` moves between two
  samples at a given speed.
- `persons` (read only) lists the sim persons aboard one of the company's vehicles (`--vehicle`; the vehicle
  window's passenger list, `getVehicle2Cargo2SimEntitesMap`), or riding and waiting for one of its lines
  (`--line`, `simPersonSystem.getSimPersonsForLine`; that it includes those waiting is not checked: its doc says
  "travelling with the given line"), listed by id. Per person: `happiness` (`SIM_PERSON`; the base calls
  below 0.5 "Unhappy"), `good` (`isGoodQuality`), `destinations` (home, shopping, work), `targetOrAtEntity`,
  `where` (vehicle / terminal / other); aboard `atVehicle` (`vehicle`, `part`, `place`, `expectedArrivalTime`)
  with `untilArrival` (expected arrival minus the game time) and `late` (the game time is past it: the base
  person window's test for a falling happiness, `sim_person.tl`), and `trip` (line, `lineStop0` / `lineStop1`);
  waiting `atTerminal` (line, stops, `arrivalTime`, `sinceArrival`, `late`: waiting over 2 minutes, the person
  window's test there). With `--vehicle`, `vehicleState` (state, stopIndex, speed) says at sea or in port. `summary`
  counts the listed ones (unhappy, late aboard, `lateWaiting`, mean / min / max happiness); `quality` has the engine's passenger counts (`total`, `bad`,
  `averageQuality`, `veryBad`) for the vehicle, its line and each stop of the line (`waiting` at the stop,
  `stationGroupWaiting` at its station group): what the base shows as waiting and unhappy passengers. The answer
  has `gameTime`. `total` counts everyone; details for the first `--limit` (200, at most 2000). A vehicle that is
  gone or not the company's answers `missing: true` (not an error); a line that is not the company's is an error.
  `--every SEC` (at least 0.5) repeats it and prints one compact JSON line per sample (JSON Lines) with `sample`
  and `unixTime` added, until `--count N` samples or Ctrl-C; an answer that is not ok ends the loop, a sample with
  no answer is a line with `noAnswer` and `reason` (timeout, notPickedUp, file, other) and the loop goes on (exit
  code 2 at the end). `sample` is the slot on the grid: after a sample that took longer than `--every`, the slots
  gone by are skipped (the next line's `skipped`), not sent in a burst. `summary` counts the listed ones only
  (`summary.of`; `summary.total` is everyone): to record everyone aboard, give `--limit 2000`. A negative
  `expectedArrivalTime` is taken as none (no `late`). Comfort is not in
  the answer: compare models with `vehicles` / `models`. "Below 0.5" follows the person window
  (`sim_person_eow.script.tl`); the HUD's happy icon takes above 0.5. The time a
  person boarded is not in the engine's records: take the first sample it appears in. **Not checked in game:**
  that these components and calls read in the GUI script as the base's windows read them, that
  `expectedArrivalTime` is in the same unit as `gameTime` (the base compares the two, and adds 1000 * 2 * 60 for
  two minutes: ms), and what the counts are for a ship at sea.
- `depots` lists the company's depots only (`requireOwnedByPlayer`, as the line manager). No position (no API to
  read it was found). The kind (road / tram / rail / water / air) comes from the transport modes; `carrier` was
  OTHER for all 49 depots in a test (the base also goes by transport modes), so `carrier` / `carrierRaw` are for
  reference. Maintenance buildings show up too (`maintenancePool`).
- Each depot also has its construction's ends (`streetConnectorSystem.getConstructionEntityForDepot`, then the
  nodes of its `frozenEdges`, its `frozenNodes` left out): `construction`, `freeEnds` (nodes only one piece
  reaches, a `connect` end: `node`, `x` / `y` / `z`, `edges`, `track` true for a track, false for a road) and
  `joinedEnds` (nodes that also have pieces not of the depot's, with `trackPieces` / `roadPieces`: its track
  already joined to a line). A depot whose construction cannot be found has `endsWhy` instead.
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
  `platforms` lists every platform (read only), for `--terminals`: `station` and `terminal` (0-based, as a line
  stop holds them), `stationEntity`, `tag` (in a vanilla harbour the module's cell, `1000 * coordI + coordJ`, from
  modules.script.lua), `position` (where vehicles stop: the terminal's first vehicle edge through
  `transport.calcPosition`, as the base finds a waypoint), `cargoLoad` / `cargoUnload` / `passengersLoad` /
  `passengersUnload`, `cargoTransferSpeeds` (`length`, `loadSpeedModifier` each), `carriers`
  (`getCarriers(group, station, terminal)`), `transportModes` (the modes that are on, by name: a vanilla large
  pier has SHIP and SMALL_SHIP, a small one SMALL_SHIP only) and `capacity`. What cannot be read is left out
  (nil); `position` may well be missing at piers, whose terminals are made from a vehicle node (unverified).
- `stations --catchment <id>` (read only; a station group, or one station) lists what its catchment reaches, as
  the engine keeps it: `getStationCatchables(station, cargo)` of the catchment area system, which the base asks the
  same way (line_util.tl, cargo_util.tl). `passengers` (entities with a PersonCapacity) and `cargo` (entities
  with a StockList) each give `entities` (how many), `towns` (per town: `town`, `name`, `buildings`,
  `residential` / `commercial` / `industrial` counts and `capacity` per kind; the kind is the building's
  PERSON_CAPACITY type against the LandUseType enum, as the base town window compares it), `industries` (`id`,
  `name`; by the industry's own id or its INDUSTRY stockList) and `other` (ids it could not place). For a group,
  the union of its stations. Not checked in game: which entities the engine gives (a building itself, its
  PersonCapacity or its StockList entity; all three are looked up) and whether the kind's numbers match the enum.
  The answer also says why it catches what it does (content/remote_catchment.lua), for passengers:
  - `diagnosis`: one line, e.g. `0 town buildings in the circle (150 m); nearest residential 462 m (312 m outside
    the circle) in Emsworth, ...` (too far) or `3 town buildings in the circle (150 m: residential 2, commercial 1),
    2 not in the engine's catchment; on foot 1 of 2 checked have no path to the station` (in the circle, not reached).
  - `circles` (`station`, `x`, `y`, `radius`, `frame`) and `radiusSource`: the engine's `STATION.catchmentAreas`
    (one circle per module that has one). The base makes the centre in the construction's frame; whether the
    engine keeps it so is not known, so the centre as read (`frame: "world"`) and through the construction's
    `transf` (`"construction"`) are both worked out and the one nearer the station's box centre is used (the
    position read in `readX` / `readY`). Without a transf, a centre more than its radius and 1000 m from the
    station is taken round the station (`"station"`). When the engine gives none, `--radius M` gives the circle
    (`radiusSource` says so). The base's values (its station files): rail main buildings 150 / 175 /
    200 m (small / medium / large, passenger and cargo alike), side buildings 50 / 60 / 70, stairs 100; street
    station entrances 175; small street stops 160; harbour passenger docks 150 (25x25) and 250 (50x50, 100x50);
    the harbour's cargo docks have none in the base's files.
  - `near`: the town buildings of the `TOWNS_READ` (4) towns nearest the station (every town when one has no
    position: `townsUnplaced`), at most 1500 of them (`buildingsRead`, `truncated`, `townsTotal`, `towns` with
    their `distance`, `readMs` (on `api.type.Clock`, as `around`'s `ms`), `buildingsError`, `positionError`); `nearest` per kind (`building`, `town`, `townName`,
    `distance` to the circle's centre, `outside`: metres past its rim, negative inside); `inCircle` (`total`, per
    kind, `caught` / `notCaught`: in the engine's passenger catchables or not, `nearRim`: within 10 m of the rim);
    `notCaught` (the buildings, deepest in the circle first: `rim` metres inside, `walk`: `path`, `none` or
    `unknown`, `why`) and `walk` (`checked`, `found`, `noPath`, `unknown`, `unverified`, `limit`, `ms`, `maxMs`
    (the longest search), `truncated`, `control`: the same search for up to 3 caught buildings; when it finds none
    of those either, the search is not to be trusted, and with no caught building a missing path is unverified,
    which `diagnosis` says). A station with no passenger terminal (every terminal's flags read) is held against its
    cargo catchables instead (`cargoOnly`), with no walking search. The walking search is reach's (`reach --from
    <building> --to <station> --mode walk`), for at most `--paths N` buildings (default 20, 0: none), and stops
    after 300 ms. A building is in a circle by its box centre; the engine may measure from its door or street.
  - Not checked in a game yet (2026-11-23): whether `catchmentAreas` reads, in which frame, and whether the walking
    search finds paths between these nodes.
- `lines` lists the company's lines: stops (station group, station and terminal, 0-based, and `loadMode`: 0
  available, 1 full load any, 2 full load all), vehicles, carriers, `customFilters`, `loads` (cargo some stop
  loads) and `vehicleCargo` (cargo the line's vehicles can carry). `--line N` lists that line only (an error when
  it is not the company's). Each stop also has its `stopConfig` flags as the line window's cargo filter reads them:
  `forceUnload` (unload at a matching input stock even when it is full), `destroyForConfigChange`,
  `destroyForRefresh`; `stopLoads` (the cargo types the stop loads, with `maxLoad`, the fraction of capacity 0..1);
  and the stop's `minWaitingTime` / `maxWaitingTime` / `maxAdditionalWaitingTime`. What the engine does not give is
  left out. **Not checked in game yet** (written 2026-11-22).
- `lines --problems` (read only) adds `problems` per line, as the line manager reads them: `segments` (from
  `getDetailedLineProblems`: per segment, per stop, `noPath`, `incompatibleStop`, `duplicateStop`, `empty`,
  `noPathLocation` with `edgeIndex`, `node`, `nodePosition` and the mode sets `okModes` / `relaxedModes` /
  `allowedModes` by name, `noPathToAlternative` / `noPathFromAlternative` as `terminal` and `location`, and
  `problem` when the base would count the stop), `count` (stops with a problem), `transportModesUnion`
  (`getLineTransportModesUnion`), and on each stop its platform's `transportModes`. A call that raises shows as
  `readError` / `unionError`. Not checked in game: in particular how the segments map to the line's stops (the
  base counts them in order) and what `node` holds.
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
- `--terminals S:T,...` (create and update) gives every stop's platform, in order: `station:terminal`, or a bare
  terminal for station 0, 0-based as `stations` lists them in `platforms`. All stops or none: when one stop has no
  platform the base `autoAssignTerminals` takes the engine's assignment for every stop (allowing changes), so the
  others would not hold; a list shorter or longer than the stops is refused. With every stop given, no
  assignment is asked for. Without `--stops`, an update sets the platforms of the line's own stops (waypoints
  kept). Before anything is sent, each station and terminal must exist (checked before the engine is asked about
  it), its carriers must be readable, the platforms must share a carrier, and on an update of a line with
  vehicles that carrier must be one of the line's (the first stop's platform, as the base `getLineCarriers`). The
  Lua state that sends checks them again (via gui before the base `line_util` reads them), and that the built
  stops hold them. The check goes by carrier only: a ship of mode SHIP at a small pier (SMALL_SHIP) passes it
  (both WATER); see `transportModes` in `stations`. An update keeps the stops' `alternativeTerminals`, as the
  base's main-terminal change does. Without `--terminals` nothing changes: the engine assigns, as before.
- `--load-mode MODE[,...]` sets `Line.Stop.loadMode`: `available` (0, `LOAD_IF_AVAILABLE`), `any` (1,
  `FULL_LOAD_ANY`) or `all` (2, `FULL_LOAD_ALL`), the three the base line window offers; one for every stop, or
  one per stop. `LEGACY_UNLOAD_ONLY` is refused (the base does not offer it). Without `--stops` an update sets it
  on the line's own stops. `ok` is false when the platforms or load modes read back differ from those asked for.
  Via gui without the recipe's report, an update that changes only platforms or load modes times out, as a
  `--cargo`-only one.
- `--force-unload 0|1,...` sets `Line.Stop.stopConfig.forceUnload`: unload at a compatible input stock even when
  it is full, the cargo that does not fit being destroyed (engine.d.tl; the cargo filter window's "Unload Even if
  Stocks Are Full" against "Unload Only if Stocks Have Capacity"). Where no input stock in reach takes the cargo,
  nothing is unloaded either way. One 0 or 1 for every stop, in order. There is no "one for
  all": a count that does not match the stops (`--stops`, or the line's own) is refused before anything is sent.
  The stop's `StopConfig` is copied with only `forceUnload` changed (its loads, `maxLoad` and the destroy flags
  kept: `StopConfig.new(old)`, as the base copies one in `line_util` and the line manager); `customFilters` is left
  as it is. Via gui it goes through the base's `line_util` (the via's `passThroughStopData.stopConfig`, which
  `autoAssignTerminals` copies into the stop); via cmd the line's own stops are copied and sent with
  `makeLineUpdateCmd`, which is how the cargo filter window itself sends it. Neither moves money. `ok` is false
  when a stop read back has another `forceUnload` than asked for; `lines` shows it per stop. Via gui without the
  recipe's report, an update of `--force-unload` alone times out, as for `--load-mode`. **Not checked in game
  yet** (written 2026-11-22): in particular whether a ship then unloads into a full stock at a stop that loads
  nothing.
- `line delete <line>` sells the vehicles first (only with `--sell-vehicles`), and sends `makeLineDestroyCmd` once
  the sale succeeded.
- `--cargo <id or name>` loads only that cargo, at the stops whose station has it in an output stock, as the base
  does (`load` true there, false elsewhere, `maxLoad` 1, `customFilters = true`): a stop that loads a cargo does not
  unload it, so loading it everywhere meant it was never delivered. No stop giving it is an error; where the base's
  `cargo_util` cannot be read (the cmd way may run without it), every stop loads, as before. A stop whose platform handles neither loading nor unloading of
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
  written ("line report not written" in the log if not). For `--terminals` / `--load-mode` and `platforms`:
  whether `getCarriers` with a station and terminal gives the platform's own carriers (the base asks it so in
  `getLineCarriers`), whether setting `loadMode` to a number holds (the base cargo filter does it), whether
  `vehicleEdges` / `TRANSPORT_NETWORK` / `calcPosition` read in the GUI state, and what the engine does with a
  platform of the wrong carrier (the probe refuses it before sending, so this was never tried).

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
