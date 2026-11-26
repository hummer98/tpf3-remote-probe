#!/usr/bin/env python3
"""Drive a running Transport Fever 3 through the remote probe mod (hummer_remote_probe).

The game's GUI Lua can only read and write its own userdata files, so this tool writes a command file next to the
mod's hello file and waits for the answer file. Answers carry one JSON string; the files themselves are Lua
("function data() return {...} end"), read here with luajit in an empty environment.

  tf3ctl.py status
  tf3ctl.py speed 8             # beyond the UI's 4x, capped at the game's estimate (getEstimatedMaximumGameSpeed);
            # 0 pauses
  tf3ctl.py calendar-speed [0.25 | --millis-per-day 8000]   # the base's calendar slider (0, 0.25 .. 4x): read with
            # no value; set answers before / after (millisPerDay: game ms per calendar day; 0: the date stands)
  tf3ctl.py run --months 2 --speed 4
  tf3ctl.py saves
  tf3ctl.py info "probe"
  tf3ctl.py load "probe" --param example_mod:treePollution=3 [--add MOD] [--remove MOD] [--dry-run]
  tf3ctl.py save "probe-after"
  tf3ctl.py newgame --size tiny --year 1900 --param example_mod:extraDemand=2 [--dry-run] [--list]
  tf3ctl.py launch --new --editor --size tiny --no-towns --no-industries   # the map editor (isMapEditor): the
            # official mods (ug_*) and the probe, not the running game's (--add / --remove still apply)
  tf3ctl.py log --grep remote_probe --tail 40
  tf3ctl.py poll --idle 5 --active 0.5     # until the next load; the mod settings apply again after it
  tf3ctl.py --owner alice run --months 2
  tf3ctl.py quit [--kill]                   # app.quit; --kill: SIGKILL if it does not (an unsaved game is lost)
  tf3ctl.py restart --load "probe" [--param ...]      # quit, launch with the probe in the main menu, load
  tf3ctl.py restart --new --year 1900 --size small --add example_mod
  tf3ctl.py launch [--load ... | --new ...]           # the same, when the game is not running
  tf3ctl.py restart --lang de --load "probe"          # this start in German; quit / the next start put profile.lua back
  tf3ctl.py restore-profile                 # put profile.lua back from tf3ctl's backup now (the game not running)
  tf3ctl.py event example_window.show --param '{"welcome": true}'   # a react event (fired by the speed control)
  tf3ctl.py window --line "Bus 1" --manager  # that line in the line manager (its Manage Line button), not its window
  tf3ctl.py rename "Chesham" --entity 48064   # a station (its group), line, vehicle or depot, as the base's windows do
  tf3ctl.py tool music [--close]            # a base window that opens as a tool (music, calendar)
  tf3ctl.py depots [--grep bus]             # depot entities to buy at
  tf3ctl.py vehicles [--line 21]            # the company's vehicles: models, purchaseTime, value
  tf3ctl.py vehicles --entity 601,602 --state [--since 120000]   # + state, stop, door/departure times, cargo, costs
            # and the game time of the read (gameTime); --at-terminal: only those in port now; --every 2 --count 60:
            # one JSON line per sample, as persons --every
  tf3ctl.py models [--grep trillium] [--carrier water]   # vehicle models: store price, running costs, speed, capacity
  tf3ctl.py buy --model bus_1900 --depot 301 [--line 21] [--count 2] [--via gui|cmd]
  tf3ctl.py buy --model shinkansen_0s.mu.lua --depot 302      (a multiple unit: the whole train, via gui)
  tf3ctl.py models --mu [shinkansen]                          (read only: the multiple units and their names)
  tf3ctl.py duplicate --vehicle 601 | replace --vehicle 601 --model bus_1920 | sell --vehicle 601
            # each answers with via, balance before/after, spent, the model's store price, parts' purchaseTime
  tf3ctl.py money --set 10000000 | --add -5000   # the balance, as the sandbox money editor (a journal entry)
  tf3ctl.py stations [--name cent] [--near 11 --radius 800]   # station groups: id, platforms, carriers, distance
  tf3ctl.py stations --catchment 47         # what a station reaches (town buildings, industries) and why (diagnosis)
  tf3ctl.py lines [--name probe]            # lines: stops (platforms), vehicles, cargo loaded and carried
  tf3ctl.py lines --problems [--line 23]    # + each stop's path problems, platform modes, the line's mode union
  tf3ctl.py industry-workers [--entity 51]  # industries: capacity, sims headed there, last visitors (boost), town
  tf3ctl.py industry-stocks [--entity 51] [--grep mine] [--all-params]  # stocks, rules, construction params
  tf3ctl.py town connections [--entity 801]   # read only: towns the engine counts as connected, each industry's
            # town (the closest one)
  tf3ctl.py town connect --auto | --build [--entity 801,802] [--pairs 801:802] [--default] [--no-keep] [--dry-run]
            # meant for test saves (not checked): the map editor's Auto-detect connections / Generate (streets to all industries)
  tf3ctl.py company                         # read only: the base's company progression (basePopulation, level,
            # ticket price multiplier) and what is missing
  tf3ctl.py running-costs --model bus_1900        # read only: metadata.cost / .maintenance (runningCosts,
            # runningCostScale, maintenanceScale, ...) and the model's vehicles with getRunningCost per year
  tf3ctl.py running-costs --model bus_1900 --scale-running 2 [--set-maintenance 1.5] [--where gui]   # test saves
            # only (as road --ignore-errors), not in coop: the fields written in place, in the game script (needs the
            # mod setting gameScript: --param hummer_remote_probe:gameScript=2 at launch / load) or the GUI; the
            # answer has before, the writes (the engine's error word for word) and after, in both Lua states
  tf3ctl.py eval 'api.engine.getComponent(1, 1)' [--file x.lua] [--depth 6] [--max-chars 200000] [--gs]
            # needs "eval": true in the configuration file. Read only: Lua in an environment without api.cmd, api.gui,
            # app, game, io and the functions under api named as writers (a userdata's own methods are not covered);
            # any save. The value as JSON (cut at the depth and size, marked), print's lines, or {kind: compile |
            # runtime, error}. No timeout (the game's Lua has no debug.sethook): a loop that never ends hangs the game.
            # --gs: in the probe's game script (needs gameScript=2, as running-costs)
  tf3ctl.py eval --write 'CODE' [--user-asked]   # every global: test saves only, during coop only with --user-asked;
            # app.saveGame / deleteSavegame raise (best effort: the real app stays reachable through require("_G"))
  tf3ctl.py finance [--since GAMETIME] [--vehicles 601,602] [--columns 4]   # read only: the finance table's rows
            # per carrier (MAINTENANCE / VEHICLE = the running costs), and calculateBalance of the fleet and vehicles
  tf3ctl.py mod --list | mod <modId>   # read only: the mods that ship remote_probe_ext.lua and their commands
            # (name, description, tag reads / changes; the tag is the mod's own claim). --list requires every
            # such mod's file, so their top-level code runs in the game; mod <modId> requires that one only
  tf3ctl.py mod <modId> <command> ['{"key": 1}'] [--timeout 30]   # run one of them; a command tagged changes (or
            # untagged) goes past the owner check as every game-changing command does
  tf3ctl.py company init [--dry-run] [--force]   # meant for test saves: the base's start event (initNewGameFromMap) sent
            # again when basePopulation is missing or 0 while towns have population (a start with no towns)
  tf3ctl.py fit --res R --at x,y [--radius 100] [--size W,D] [--mouth DX,DY [--link 8,40]] [--houses N] [--check 3]   # where
            # it fits: around's list searched here, the best few asked of the engine (dry runs); builds nothing;
            # with --mouth also the road (from its mouth to a road node a short way off) to give after the build
  tf3ctl.py around --at x,y [--radius 100] [--kinds town_building,street,...|all] [--limit 200] [--lanes]   # read
            # only: what stands near a point (kind, name, box, distance; constructions' road mouths in their own
            # frame; --lanes: each street's and track's lanes, as lanes --edge)
  tf3ctl.py lanes --edge 9010[,9011,...] [--no-network]   # read only: a road or track piece's lanes left to right
            # from node0 (number, side and metres from the middle, direction, transport modes, speed, width), its
            # street type, bridge / tunnel, tram track (NO / YES / ELECTRIC) and bus lanes; the transport network's
            # own edges too
  tf3ctl.py parcels --edge 9010 [--no-list] | parcels --rect x0,y0,x1,y1 [--list]   # read only: the town
            # building parcels left and right of a road piece (count, built on, centre, area), whether the piece is in
            # a construction; a rect: each street piece with an end or its middle in it, and totals
  tf3ctl.py reach --target 51 | reach --town 11 [--limit 20] | reach --problems | reach --api   # read only:
            # the engine's targets (workplaces, shops) and whether they are reachable walking / driving / by lines,
            # the town problems (Disconnected, Overlength); not checked in a game yet
  tf3ctl.py reach --from 11 --to 51 [--mode walk|drive|lines|all] [--radius 40]   # read only: is there a footway
            # / road path between two places (entity ids or x,y points); no cost, lines only as the target's mark
  tf3ctl.py persons --vehicle 601 [--limit 50] [--every 5 --count 120]   # who is aboard: happiness, expected
            # arrival vs the game time; the engine's unhappy counts for the vehicle, its line and stops (read only).
            # --every: one compact JSON line per sample (JSON Lines), until --count or Ctrl-C; --line 21: a line's
            # riders instead of one vehicle (whether those waiting for it are included is not checked)
  tf3ctl.py persons --town 11 [--limit 2000] | persons --destination 51   # a town's residents, or those with an
            # entity as a destination; each with the counts of destinations it reaches (reachable), and summary.reach
  tf3ctl.py line create --stops Central,Harbour [--name "[probe] A"] [--cargo grain] [--via gui|cmd]
  tf3ctl.py line update 21 [--stops 41,42,43] [--name N] [--cargo C] | line delete 21 [--sell-vehicles]
  tf3ctl.py line create --stops 47,48 --terminals 0:2,0:1 --load-mode all,available   # piers picked, full load
  tf3ctl.py line update 23 --force-unload 0,1   # per stop: unload into a matching input stock even when full
            # (that cargo is lost); no matching input stock: no unloading either way (lines shows it)
  tf3ctl.py connect --from 5123 --to Harbour [--build]   # a track between two free ends (needs Track Connector)
  tf3ctl.py build --res road_bridge_ramp::/road_bridge_ramp/ramp.con --at 1200,800 [--angle 1.57] \
            [--params '{"rbr_height": 8}'] [--name N] [--dry-run]   # one construction (.con), no click: test saves
            # only; no z: the terrain's height. Answers its id, cost, the engine's errors, its depots and free ends
  tf3ctl.py build --remove 5123[,5124] | build --remove-all   # only what the probe built (as built, or its name + mark)
  tf3ctl.py build --res ::/stations/water/harbor_modular.con --at 1500,-300 \
            --params '{"modules": {"<slot id>": {"name": "<module resName>"}}}' [--no-fill-modules]
            # a modular construction: slot ids made whole numbers, autoFillSlots off, each module's name checked
            # and its metadata / updateScript filled from moduleRep; --no-owner: playerEntity -1 (an industry)
  tf3ctl.py road --from 1500,-300 --to 1620,-300 [--type town_new_small] [--snap 5] [--dry-run]
  tf3ctl.py road --from 1500,-300 --to 1620,-260 --align-to-edge from [--align-edge 9010] [--tangent-to 1,0]
            # a curved piece: the from end follows the road there, the to end arrives heading east
  tf3ctl.py road --from 2564,2400,110 --to 2636,2400,110 --snap 1 \
            --bridge hummer_pier_spike::/infrastructure/bridge/hps_pillarless.bridge [--dry-run --engine-check]
            # the piece as a bridge of that type (edge type BRIDGE); ends in the air by their z (or a node there)
  tf3ctl.py road --batch pieces.json [--dry-run [--engine-check]] [--ignore-errors] [--remove-fields]
            # several pieces in one proposal, judged and built together (at most 16): a JSON list, each piece with
            # road's values (from, to, type, bridge, snap, tangent-from, tangent-to, align-to-edge, align-edge) and
            # from-node / to-node: an existing node's id, or "@a" for a new node the pieces share
  tf3ctl.py road --from-node 4077 --from 1504.5,-300 --to 1620,-300 [--dry-run]   # the from end at that point,
            # joined to node 4077 (at most 12 m across from it, else refused; the answer shows endOffset). [guess]
            # not checked in a game yet. --from-node alone: the end is the node's own point (a batch piece: the same)
  tf3ctl.py track --from 0,0,-15 --to 200,0,-15 --type simple --tunnel tunnel_a [--dry-run [--engine-check]]
            # track pieces as road builds roads (RoadType TRACK; --tunnel: edge type TUNNEL, the ends' z required);
            # --batch pieces.json: at most 16 in one proposal, "@a" for a node the pieces share (a switch where
            # three meet). The answer gives the edges (pieceEdges) and the engine's errors. Not checked in a game yet
  tf3ctl.py road --inspect-node 4077   # read only: the node's pieces, construction, set-up (with its
            # trafficLightPreference YES / NO / AUTO), octree hits
  tf3ctl.py lights --node 4077 --off [--dry-run]   # test saves only, not in coop: the junction's traffic light
            # taken off as the node's window does it (trafficLightPreference NO); then road joins the node
            # one straight road piece, no click: meant for test saves; an end within --snap m of a road node joins it
  tf3ctl.py road --from 1500,-300 --to 1620,-300 --ignore-errors [--dry-run]   # for test saves only: skips the
            # engine's checks (ignoreErrors); refused unless a test save is loaded (not a new game), and refused
            # during coop. Answers ignoredErrors (sent forced), and unforced: what a build without it would get
            # After one forced build (not --dry-run), this run of the game saves only to probe-force-* names
            # (exit 4, "refused": "forced-save"; --other-owner-ok / --user-asked do not widen it; status says so)
  tf3ctl.py water --at 1500,-300 | water --grid 1000,-800,2000,200,50   # read only: the water level, and per
            # point water or land and the terrain's height (a grid: at most 400 points, rows of ~ water . land)
  tf3ctl.py terrain --rect 0,0,500,300 --flat 40 [--blend 16] [--dry-run]   # a rectangle's ground replaced
  tf3ctl.py terrain --rect 0,0,500,300 --slope-x 5 --base 40 | --slope-y -10 --base 80   # base at x0 / y0
            # the map editor only (--in-game: a new test game); at most 1024 m a side, a small map at most; refused
            # when a road, construction, town building, industry or town is in it. Answers the grid, the heights,
            # the way (gui, or update when asked), the heights read back
  tf3ctl.py terrain --probe-api              # read only: which terrain functions the probe's two Lua states have
  tf3ctl.py town --at 1200,-300 --name "Harbourside" [--size 1.5] [--capacity 300] [--needs com:fish,ind:planks]
            [--in-game] [--dry-run]   # one town (createTowns, as the map editor): the map editor only (--in-game:
            # a new test game); first needs from the economy's lowest tier unless --needs / --no-needs. Answers the
            # town's entity, name, position, population, the engine's proposal, the needs read back
  tf3ctl.py town develop --at 120,-40 [--count 30] [--streets] [--upgrade] [--radius 250] [--dry-run]
            # meant for test saves: makeTownDevelopAtCmd N times (1-200), one after another; answers sent / succeeded /
            # failed and the town buildings (residential, commercial, industrial) before / after, all and near
  tf3ctl.py town size --entity 801 --factors 2,1.5,1 [--update-all] [--dry-run]   # meant for test saves: the town's
            # size factors (makeTownUpdateSizeCmd); answers the factors and the town's buildings before / after
  tf3ctl.py stock list --entity 51          # read only: a stock list's stocks (ids 0-based), counts per cargo; an
            # industry, town building or warehouse, a station, a construction with one under it (a warehouse's, as
            # build gives it: entities --kind warehouse lists them), or a vehicle (its load per cargo, stock -1)
  tf3ctl.py stock set --entity 51 --stock 0 --amount 100 [--cargo COAL] [--dry-run]   # debug command: meant
            # for test saves; a vehicle's load: --stock -1 --cargo NAME. Answers before / after and the engine's success
  tf3ctl.py steps 500 [--dry-run]           # debug command: the simulation 1-10000 steps on; meant for test saves.
            # Pause first (refused while running, unless --allow-running). Waits until all the steps ran
            # (1 step = 200 game time, 20 a day; 1000 steps about 15 s), then answers before / after / waitedSec
  tf3ctl.py pointer 0.5,0.47 [--px]          # the game's pointer only (hover, preview): no click, no key; needs
            # "pointer": true in the configuration file; Linux (X11) only
  tf3ctl.py connect --from 801 --to 802 --road [--template ::/infrastructure/street/...street_template]
            # without --build: the route, its length, bridges and tunnels, slope, the dry run's cost and verdict
  tf3ctl.py modhub status [--folder F] | modhub validate F   # My Mods in the main menu (read; re-validate)
  tf3ctl.py modhub publish F --public yes --changelog "..." --first-upload [--version X.Y.Z] [--dry-run]   # one new mod to mod.io
            # (an allowed folder not on mod.io; no fileid yet; a mark in $XDG_STATE_HOME/tf3ctl/ until the fileid appears)
  tf3ctl.py modhub publish F --public yes --changelog "..." [--version X.Y.Z] [--update-metadata] [--dry-run]   # update the mod.io page of its fileid
            # (the fileid there; mod.json's revision above the last one uploaded, from publish_history.jsonl or,
            # when that has none, --previous-revision N; the page's name, summary and description are kept unless
            # --update-metadata, which replaces them with modinfo.json's)
  tf3ctl.py modhub publish-clear --yes       # remove that mark, after looking at mod.io
  tf3ctl.py --owner bob coop start --reason "test the new depot with the user" [--minutes 60]   # share the game
  tf3ctl.py --owner bob coop end             # the mark goes; says whether the game was changed during coop

The configuration file ($TF3CTL_CONFIG, else $XDG_CONFIG_HOME/tf3ctl/config.json, else ~/.config/tf3ctl/config.json;
tools/config.example.json shows every key and its default) turns on what only some setups want: ownerCheck (the
owner check below), coop, testSavePrefixes / testSaveDigitFirst (which save names count as test saves: probe-* by
default), modhub.validateFolders / publishFolders / publishedIds (modhub validate and publish: none by default),
and pointer. Without the file all of them are off. A file that cannot be read (not JSON, an unknown key, a value of
the wrong kind, coop without ownerCheck, ...) stops every command: nothing is sent, the reason goes to stderr and as
JSON ("refused": "config-broken"), exit 2. Only `tf3ctl.py config` still answers then (exit 2, "file": {"state":
"broken", "error"}), to see what to fix. `tf3ctl.py config` shows what is in effect, and status carries "config":
{"path", "state": "file" or "none"}.

The debug commands (stock set, steps, money, town develop / size / connect, company init, running-costs writes,
lights --off, road --ignore-errors, eval --write) change the save's contents as no player can: their answers carry
"saveNote" (saving keeps the change). They are meant for test saves, but only road --ignore-errors, lights --off,
running-costs writes and eval --write check that a test save (testSavePrefixes) is loaded; the others go to any
save.

--owner (or TF3CTL_OWNER) names the client sending commands (a person or a script). It is shown (status:
run.owner, lastAction) and used for a warning when another owner changed the game in the last 10 minutes. With
"ownerCheck": true, launch / restart with an owner leave $XDG_RUNTIME_DIR/tf3ctl/launched.json (/tmp/tf3ctl-<uid>/ without it): that
owner and the game's pid; it goes when tf3ctl sees the game stopped. While the game runs, a command that changes the
game (save, quit, load, speed, build, ...; also restart's quit and quit --kill) goes only to the game this --owner
started: it is refused (exit 4, nothing sent) when the record names another owner, when there is no --owner, and
when there is no record or its pid is not the running game (a game started outside tf3ctl, e.g. by a person from
Steam). Reading commands, --dry-run / --list and camera without arguments always go. Without ownerCheck none of
this is refused (launch / restart with an owner still write the record: road --ignore-errors keeps its force
mark there). --other-owner-ok sends anyway,
for a client the others agreed may use that game; the answer (otherOwnerOk) and the game's log line say so.

With "coop": true, coop start --reason "..." [--minutes 60] (or launch --coop --reason "...") shares the running game between the user
and this --owner: the game this owner started, or one a person started from Steam (never another owner's). The
launch record then carries "coop": {"with", "reason", "since", "until"[, "modified", "changes"]}; it counts until
"until", while its pid is the running game. Meanwhile this owner may send camera, window, event, build, road,
stock set, money, steps and other mods' commands (mod; fit too); speed, run, pause and eval --write (on a test
save) only with --user-asked;
save only to a test save's name, and with a person's save loaded only with --user-asked; nothing else (quit,
load, newgame, restart, ...): exit 4, "refused": "coop". A game-changing command on a person's save sets
"modified" and counts "changes"; status and coop end say so. coop end removes the mark.
A mark whose until has passed, or a malformed one (no client, until not a finite number or more than 7 days ahead),
on the running game is the strict side: the user may still be playing, so its launcher and client send no
game-changing command (exit 4, "refused": "coop-expired" / "coop-invalid"; not with --other-owner-ok either) until
coop start extends or rewrites it, or coop end removes it. Its time running out never removes it; status says so.

Several tool processes may run at once (e.g. a long run plus status calls): a lock makes them write the single
command file one after another, each waiting until the mod has picked its command up.

Exit codes: 0 ok, 1 the game answered with an error, 2 no answer / tool error / a configuration file that cannot
be read, 3 the game cannot answer where it is (menu, loading, main menu, closed: gameState in the output says which),
4 refused, nothing sent: the running game is not this --owner's (see --owner above), road --ignore-errors / lights
--off / a running-costs write / eval --write on a save that is not a test save, a command the configuration does not enable
("refused": "config"), or mod --read-only for a command its mod does not tag reads ("refused": "not-read-only").

Environment: TF3_REMOTE_DIR = the exchange folder (default: the newest hello file under Steam's userdata),
TF3_LOG = the game log, TF3_STEAM = the command that starts Steam, TF3CTL_OWNER = the default --owner,
LUAJIT = the luajit binary, TF3_PROFILE = the game's profile.lua (default: next to the exchange folder, else the newest
under Steam's userdata), TF3_GAME_DIR = the game's install folder (for the languages --lang may pick),
TF3CTL_OTHER_BACKUPS = backups of profile.lua made by other tools (files or folders, separated by os.pathsep: ':', ';'
on Windows; a folder counts while a file is in it): while one exists, --lang and the restore refuse, so the backups are
put back in the reverse order they were made. TF3_ASSUME_RUNNING = any non-empty value: take the game as running
without the process list (state is never closed / crashed, the main menu's hello is not checked against the
process start; for tests, or where the process list cannot show the game). The owner check and the coop mark's
refusals still look for the game's process: when the list does not show it, they let every command through; so
does the forced mark after road --ignore-errors (saving only to probe-force-* names).

Windows: a minimal port, not tested on a Windows machine (please report problems in an issue or a pull request).
The configuration file is ~/.config/tf3ctl/config.json there too; frame (it looks for Steam's recordings in Linux's
Steam folders only) and pointer (X11) are Linux only.
"""
import argparse
import contextlib
import csv
import filecmp
import glob
import json
import math
import os
import re
import signal
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time

try:
    import fcntl
except ImportError:  # Windows: lock_file uses msvcrt.locking there
    fcntl = None

PREFIX = "remote_probe__"
APP_ID = "3493540"
DIRS = ("recordings", "keyframes", "mod_presets")  # the mod's order (mod_presets files show up as presets)
SELF_MOD = "hummer_remote_probe"
STALE_SEC = 3600  # answers nobody read (a killed tool) are removed after this
PICKUP_TIMEOUT_SEC = 30  # the mod polls every 2 s when idle (at most 20 s); longer means it is not running
RECENT_SEC = 600  # another owner's game-changing command this recent gets a warning
CHANGES_GAME = {"speed", "run", "load", "save", "newgame", "window", "quit", "event", "tool", "buy", "duplicate",
                "replace", "sell", "money", "line", "connect", "camera", "buildTool", "scriptEvent", "rename",
                "build", "road", "track", "terrain", "town", "modhubValidate", "modhubPublish",
                "stockSet", "steps", "townDevelop", "townSize", "companyInit", "townConnect", "runningCostsSet", "lightsOff",
                "modChange", "calendarSpeedSet", "evalWrite"}  # window: what the player sees  # poll: only the mod's file reads
# modhubValidate: no save changes and nothing written to mod.io, but it runs the game's validator for minutes and
# aborts a validation a person may have started on the My Mods page. modhubStatus only reads. modhubPublish uploads.
# modChange: another mod's command tagged "changes" (or untagged); modList and modRead (tagged "reads") only read.
# calendarSpeedSet: the base's calendar slider (calendar-speed with a value); calendarSpeed only reads it.
# evalWrite: eval --write (any Lua, with every global); eval alone runs in an environment without the writers.

READ_LUA = r"""
local f = assert(loadfile(arg[1]))
local env = {}
setfenv(f, env)
f()
local t = env.data and env.data()
if type(t) ~= "table" then error("no data() table") end
io.write(type(t.json) == "string" and t.json or "null")
"""


class ToolError(Exception):
    pass


class ReaderFailed(ToolError):
    """luajit, which reads the mod's files, could not be started or hung: waiting longer will not help."""


class OwnerRefused(ToolError):
    """A game-changing command for a game this --owner did not start; nothing was sent. Exit code 4."""
    refused = "owner"  # the answer's "refused"


class ConfigRefused(OwnerRefused):
    """A command or option the configuration does not enable; nothing was sent. Exit code 4."""
    refused = "config"


class NotReadOnly(OwnerRefused):
    """mod ... --read-only for a command the mod does not tag reads: the mod ran nothing, and it is not sent again
    as a change. Exit code 4."""
    refused = "not-read-only"


class GameNotReady(ToolError):
    """The mod cannot answer because of where the game is (menu, loading, closed); exit code 3."""
    def __init__(self, msg, state):
        super().__init__(msg)
        self.state = state


# ---------------------------------------------------------------------------------------------------------------
# the configuration file: what only some setups want. Without a file every one of these is off (or the shortest
# list), so a fresh install has no owner check, no coop, test saves named probe-* only, no mod.io upload and no
# pointer. A file that cannot be read stops every command but config (main): running on with a guess would either
# loosen what the file meant to keep tight or open what it kept closed, and a warning on stderr goes unread by the
# scripts that send most commands.
#
# $TF3CTL_CONFIG, else $XDG_CONFIG_HOME/tf3ctl/config.json, else ~/.config/tf3ctl/config.json. A JSON object; keys
# starting with "_" are comments. Any other unknown key, or a value of the wrong kind, makes the file unreadable
# (a typo must not silently turn a check off).

CONFIG_NAME = "config.json"
CONFIG_DEFAULTS = {
    # --owner and the launch record: game-changing commands go only to the game this --owner started
    "ownerCheck": False,
    # coop start / end and launch --coop: a person and one client share the running game
    "coop": False,
    # saves the test-save-only fences take: names starting with one of these ...
    "testSavePrefixes": ["probe-"],
    # ... or with one digit and then no digit ("3-probe")
    "testSaveDigitFirst": False,
    # pointer: synthetic X11 pointer events into the game window
    "pointer": False,
    # eval: any Lua code sent into the running game (read only; --write on test saves only)
    "eval": False,
    # modhub validate / publish: the staging folders each takes, and the folders already on mod.io (folder: id)
    "modhub": {"validateFolders": [], "publishFolders": [], "publishedIds": {}},
}
# over the defaults, when the file cannot be read: main refuses every command then, but a caller importing the
# module and calling its functions directly still gets the strict side
CONFIG_BROKEN = {"ownerCheck": True}
_CONFIG_BOOLS = ("ownerCheck", "coop", "testSaveDigitFirst", "pointer", "eval")
_PLAIN_NAME_RE = re.compile(r"[^/\\,\x00-\x1f]{1,200}")


def config_path(env=None):
    """(path, named): the configuration file's path, and whether TF3CTL_CONFIG named it."""
    env = os.environ if env is None else env
    if env.get("TF3CTL_CONFIG"):
        return env["TF3CTL_CONFIG"], True
    base = env.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "tf3ctl", CONFIG_NAME), False


def _config_defaults():
    return json.loads(json.dumps(CONFIG_DEFAULTS))  # a deep copy


def _config_names(v, what):
    if not isinstance(v, list) or not all(isinstance(x, str) and _PLAIN_NAME_RE.fullmatch(x) for x in v):
        raise ValueError("%s must be a list of names (not empty; no '/', '\\', ',' or control characters)" % what)
    return list(dict.fromkeys(v))


def config_values(raw):
    """The configuration from a parsed file over CONFIG_DEFAULTS; ValueError naming the first problem."""
    if not isinstance(raw, dict):
        raise ValueError("not a JSON object")
    out = _config_defaults()
    for key, v in raw.items():
        if key.startswith("_"):
            continue
        if key in _CONFIG_BOOLS:
            if not isinstance(v, bool):
                raise ValueError("%s must be true or false" % key)
            out[key] = v
        elif key == "testSavePrefixes":
            out[key] = _config_names(v, key)
        elif key == "modhub":
            if not isinstance(v, dict):
                raise ValueError("modhub must be an object")
            for mk, mv in v.items():
                if mk.startswith("_"):
                    continue
                if mk in ("validateFolders", "publishFolders"):
                    out["modhub"][mk] = _config_names(mv, "modhub." + mk)
                elif mk == "publishedIds":
                    if not isinstance(mv, dict) or not all(
                            _PLAIN_NAME_RE.fullmatch(f) and isinstance(i, str) and re.fullmatch(r"[0-9]{1,20}", i)
                            for f, i in mv.items()):
                        raise ValueError("modhub.publishedIds must map folder names to mod.io ids (digits, as text)")
                    out["modhub"][mk] = dict(mv)
                else:
                    raise ValueError("unknown key modhub.%s" % mk)
        else:
            raise ValueError("unknown key %s" % key)
    # coop keeps every other client away from the person's game only through the owner check: without it a
    # second script could save or quit the person's game mid-coop.
    if out["coop"] and not out["ownerCheck"]:
        raise ValueError("coop needs ownerCheck true")
    return out


def load_config(env=None):
    """(config, info): the configuration and where it came from. info: {"path", "state": "none" (no file: the
    defaults), "file", or "broken" with "error" (main then refuses every command but config; the config returned is
    CONFIG_BROKEN over the defaults, for callers of the module's functions)}. Never raises."""
    path, named = config_path(env)
    info = {"path": path}
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        if not named:
            return _config_defaults(), dict(info, state="none")
        err = "TF3CTL_CONFIG names a file that does not exist"
    except (OSError, UnicodeDecodeError) as e:
        err = str(e)
    else:
        try:
            return config_values(json.loads(text)), dict(info, state="file")
        except ValueError as e:  # json.JSONDecodeError is one
            err = str(e)
    return dict(_config_defaults(), **CONFIG_BROKEN), dict(info, state="broken", error=err)


CONFIG, CONFIG_INFO = load_config()


def config_broken_text():
    """The reason every command but config stops, when the configuration file could not be read; else None."""
    if CONFIG_INFO.get("state") != "broken":
        return None
    return ("cannot read the configuration file %s (%s): nothing was sent; fix or remove the file "
            "(tf3ctl.py config shows the problem)" % (CONFIG_INFO["path"], CONFIG_INFO.get("error")))


TEST_SAVE_PREFIX_MIN = 3  # a 1-2 character prefix ("a", "3-") is the start of many a player's save name
# everything a test save's name decides (is_test_save's callers), for the warnings
TEST_SAVE_USES = ("road --ignore-errors, lights --off, running-costs writes and eval --write, save during coop, loads with "
                  "gameScript=2, and which coop commands count as changes")


def test_save_warnings():
    """Lines for stderr (and the config command) when testSavePrefixes makes the test-save check useless: an empty
    list refuses the checked commands on every save, a very short prefix lets them reach a player's saves."""
    out = []
    prefixes = test_save_prefixes()
    if not prefixes:
        out.append("warning: testSavePrefixes is empty: what needs a test save (%s) " % TEST_SAVE_USES
                   + ("takes only saves named with one digit first" if CONFIG["testSaveDigitFirst"]
                      else "is refused on every save, and every coop change counts"))
    for p in prefixes:
        if len(p) < TEST_SAVE_PREFIX_MIN:
            out.append("warning: testSavePrefixes has %r, shorter than %d characters: many save names start with "
                       "it, so a player's save may count as a test save (%s)" % (p, TEST_SAVE_PREFIX_MIN,
                                                                             TEST_SAVE_USES))
    return out


def config_note():
    """For status: which configuration is in effect ("file", or "none": the defaults), so a caller sees whether the
    fences it counts on are on."""
    return {"config": {"path": CONFIG_INFO["path"], "state": CONFIG_INFO["state"]}}


def config_needed(what, key):
    """ConfigRefused: what needs "key": true in the configuration file."""
    return ConfigRefused("%s is off: set \"%s\": true in the configuration file %s to use it; nothing was sent"
                         % (what, key, CONFIG_INFO["path"]))


def test_save_prefixes():
    return tuple(CONFIG["testSavePrefixes"])


def test_save_text():
    """The test saves' names for a message: "probe-*", or "probe-*, x-*, or one digit first"."""
    names = ", ".join(p + "*" for p in test_save_prefixes())
    if CONFIG["testSaveDigitFirst"]:
        return names + ", or one digit first" if names else "one digit first"
    return names or "none: testSavePrefixes is empty"


def test_save_rules():
    """The test saves' names for the mod, which checks a test save's name again by these."""
    return {"prefixes": list(test_save_prefixes()), "digitFirst": bool(CONFIG["testSaveDigitFirst"])}


# ---------------------------------------------------------------------------------------------------------------
# files


def on_windows():
    """Windows is not tested on a Windows machine: only the paths and command lines are built for it."""
    return sys.platform == "win32"


def windows_steam_registry():
    """{"SteamPath": ..., "SteamExe": ...} from HKCU\\Software\\Valve\\Steam, with only the values that are there
    ({} without winreg or the key)."""
    try:
        import winreg
    except ImportError:
        return {}
    out = {}
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as key:
            for name in ("SteamPath", "SteamExe"):
                try:
                    value = winreg.QueryValueEx(key, name)[0]
                except OSError:
                    continue
                if isinstance(value, str) and value:
                    out[name] = os.path.normpath(value)  # Steam writes c:/program files (x86)/steam
    except OSError:
        return {}
    return out


def windows_steam_dirs():
    """Where Steam may be on Windows: the registry's SteamPath, then the default install folder."""
    dirs = []
    reg = windows_steam_registry().get("SteamPath")
    if reg:
        dirs.append(reg)
    pf = os.environ.get("ProgramFiles(x86)")
    if pf:
        dirs.append(os.path.join(pf, "Steam"))
    uniq = []
    for d in dirs:
        if os.path.normcase(d) not in [os.path.normcase(u) for u in uniq]:
            uniq.append(d)
    return uniq


def userdata_roots():
    home = os.path.expanduser("~")
    roots = []
    steams = [os.path.join(home, ".local", "share", "Steam"), os.path.join(home, ".steam", "steam"),
              os.path.join(home, ".var", "app", "com.valvesoftware.Steam", ".local", "share", "Steam")]
    if on_windows():
        steams += windows_steam_dirs()
    for steam in steams:
        roots += glob.glob(os.path.join(steam, "userdata", "*", APP_ID, "local"))
    return roots


REPLACE_TRIES = 5


def replace_file(src, dst):
    """os.replace; on Windows it fails with PermissionError while another process (the game reading the file, a
    virus scanner) has dst open, so there it tries again a few times after a short pause."""
    for i in range(REPLACE_TRIES):
        try:
            return os.replace(src, dst)
        except PermissionError:
            if not on_windows() or i == REPLACE_TRIES - 1:
                raise
            time.sleep(0.05 * (i + 1))


@contextlib.contextmanager
def lock_file(f):
    """Holds an exclusive lock on the open file f until the block ends; waits for other tf3ctl processes. POSIX:
    flock. Windows: msvcrt.locking on the first byte (the same byte in every process, so seek(0) first; locking past
    the end of an empty file is allowed). Its LK_LOCK gives up after about 10 tries a second apart, so loop."""
    if fcntl is not None:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)
        return
    import errno
    import msvcrt
    while True:
        f.seek(0)
        try:
            msvcrt.locking(f.fileno(), msvcrt.LK_LOCK, 1)
            break
        except OSError as e:
            if e.errno not in (errno.EDEADLK, getattr(errno, "EDEADLOCK", errno.EDEADLK), errno.EACCES):
                raise
    try:
        yield
    finally:
        f.seek(0)
        msvcrt.locking(f.fileno(), msvcrt.LK_UNLCK, 1)


def owned_by_me(st):
    """st (an lstat) belongs to this user. Windows has no uid (st_uid is always 0 there), so nothing is checked."""
    return not hasattr(os, "getuid") or st.st_uid == os.getuid()


def mtime(path):
    try:
        return os.path.getmtime(path)
    except OSError:  # removed by another tool process in between
        return None


def hello_files(folder):
    found = [(mtime(p), p) for p in glob.glob(os.path.join(folder, PREFIX + "hello_*.lua"))]
    return [p for t, p in sorted((x for x in found if x[0] is not None), reverse=True)]


def exchange_dir():
    env = os.environ.get("TF3_REMOTE_DIR")
    if env:
        return env
    found = []
    for root in userdata_roots():
        for d in DIRS:
            hellos = hello_files(os.path.join(root, d))
            if hellos and mtime(hellos[0]) is not None:
                found.append((mtime(hellos[0]), os.path.join(root, d)))
    if not found:
        raise ToolError("no hello file from the mod yet: enable 'hummer_remote_probe' for the save and load it")
    return max(found)[1]


def read_json(path):
    """The JSON inside one of the mod's files; ToolError when it cannot be read (yet)."""
    luajit = os.environ.get("LUAJIT", "luajit")
    # the reader comes on stdin ("-"): with -e, luajit would run the path as a second script
    try:
        r = subprocess.run([luajit, "-", path], input=READ_LUA, capture_output=True, text=True, encoding="utf-8",
                           timeout=10)
    except (OSError, subprocess.TimeoutExpired) as e:  # no luajit on PATH (common on Windows), or it hung
        raise ReaderFailed(f"cannot read {path}: luajit ({luajit}) did not run: {e}")
    if r.returncode != 0:
        raise ToolError(f"cannot read {path}: {r.stderr.strip()}")
    try:
        return json.loads(r.stdout)
    except ValueError as e:
        raise ToolError(f"cannot read {path}: {e}")


def try_read(path):
    """None while the file is missing or still being written: the game does not write atomically."""
    if not os.path.exists(path):
        return None
    try:
        return read_json(path)
    except ReaderFailed:  # not a half-written file: a wait for the answer would only run into its timeout
        raise
    except ToolError:
        return None


def lua_str(s):
    out = ['"']
    for ch in s:
        o = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif o < 32 or o == 127:
            out.append("\\%03d" % o)
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def to_lua(v):
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        if v != v or v in (float("inf"), float("-inf")):
            raise ToolError("numbers must be finite")
        return repr(v)
    if isinstance(v, str):
        return lua_str(v)
    if isinstance(v, (list, tuple)):
        return "{ " + ", ".join(to_lua(x) for x in v) + " }"
    if isinstance(v, dict):
        return "{ " + ", ".join("[" + lua_str(str(k)) + "] = " + to_lua(x) for k, x in v.items()) + " }"
    raise ToolError(f"cannot write {type(v).__name__} to Lua")


def command_text(cid, cmd, args):
    return "function data()\nreturn { id = %d, cmd = %s, args = %s }\nend\n" % (cid, lua_str(cmd), to_lua(args or {}))


def current_stamp(folder):
    hellos = hello_files(folder)
    if not hellos:
        raise ToolError("no hello file in " + folder)
    return os.path.basename(hellos[0])[len(PREFIX + "hello_"):-len(".lua")]


def write_command(folder, cid, cmd, args):
    path = os.path.join(folder, PREFIX + "cmd_" + current_stamp(folder) + ".lua")
    tmp = os.path.join(folder, PREFIX + "cmd.%d.tmp" % os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(command_text(cid, cmd, args))
    replace_file(tmp, path)  # atomic: the game never reads half a command


def answer_files(folder, cid):
    return glob.glob(os.path.join(folder, PREFIX + "res_%d.lua" % cid)) + \
        glob.glob(os.path.join(folder, PREFIX + "res_%d_*.lua" % cid))


def remove(paths):
    for p in paths:
        try:
            os.remove(p)
        except OSError:
            pass


def other_dirs(folder):
    here = os.path.normpath(folder)
    root = os.path.dirname(here)
    return [os.path.join(root, d) for d in DIRS if os.path.normpath(os.path.join(root, d)) != here]


def idle_dir(d):
    """No game writes here now: its newest hello is older than STALE_SEC (or there is none). A second game
    instance on another folder keeps its files."""
    hellos = hello_files(d)
    t = mtime(hellos[0]) if hellos else None
    return t is None or time.time() - t > STALE_SEC


def clean_all(folder, include_current):
    """Every probe file in the exchange folders; the current load's hello and command file only when asked
    (the game is not running, so nothing is left for the player's mod preset list)."""
    paths = []
    for d in [folder] + [o for o in other_dirs(folder) if include_current or idle_dir(o)]:
        paths += glob.glob(os.path.join(d, PREFIX + "*.lua"))
    if not include_current:
        stamp = current_stamp(folder)
        keep = {os.path.join(folder, PREFIX + "hello_" + stamp + ".lua"), os.path.join(folder, PREFIX + "cmd_" + stamp + ".lua")}
        paths = [p for p in paths if p not in keep]
    remove(paths)
    return len(paths)


def cleanup(folder):
    """The game cannot delete files: drop files of earlier loads and answers nobody collected, here and in the
    other exchange folders (an older mod version used mod_presets)."""
    for d in other_dirs(folder):
        if idle_dir(d):
            remove(glob.glob(os.path.join(d, PREFIX + "*.lua")))
    stamp = current_stamp(folder)
    keep = {PREFIX + "hello_" + stamp + ".lua", PREFIX + "cmd_" + stamp + ".lua"}
    now = time.time()
    old = []
    for path in glob.glob(os.path.join(folder, PREFIX + "*.lua")):
        name = os.path.basename(path)
        if name in keep:
            continue
        if name.startswith(PREFIX + "res_"):
            t = mtime(path)
            if t is None or now - t < STALE_SEC:
                continue  # another tool process may still be waiting for it
        old.append(path)
    remove(old)


def activity_path(folder):
    return os.path.join(folder, PREFIX + "activity.json")


def read_activity(folder):
    try:
        with open(activity_path(folder), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def note_activity(folder, owner, cmd):
    """Who changed the game last; written under the command lock. Advisory: a failure only warns."""
    tmp = activity_path(folder) + ".%d.tmp" % os.getpid()
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"owner": owner, "cmd": cmd, "time": time.time()}, f)
        replace_file(tmp, activity_path(folder))
    except OSError as e:
        print("warning: could not record who used the game: %s" % e, file=sys.stderr)
        remove([tmp])


def warn_other_owner(folder, owner, cmd):
    last = read_activity(folder)
    if not last or last.get("owner") == owner:
        return None
    age = time.time() - float(last.get("time") or 0)
    if age > RECENT_SEC:
        return None
    msg = ("warning: %s sent '%s' %d min ago; if that client is still using the game, ask it before '%s' "
           "(not refused)" % (last.get("owner") or "someone without --owner", last.get("cmd"), age // 60, cmd))
    print(msg, file=sys.stderr)
    return msg


@contextlib.contextmanager
def command_lock(folder):
    with open(os.path.join(folder, PREFIX + "lock"), "a") as f, lock_file(f):
        yield


# ---------------------------------------------------------------------------------------------------------------
# talking to the mod

_last_id = 0


def new_id():
    global _last_id
    cid = max(int(time.time() * 1000) % 2_000_000_000, _last_id + 1)
    _last_id = cid
    return cid


def answer_path(folder, cid, tag=None):
    return os.path.join(folder, PREFIX + "res_%d%s.lua" % (cid, "_" + tag if tag else ""))


def progress_number(path):
    return int(path.rsplit("_p", 1)[1][:-4])


def progress_files(folder, cid):
    return sorted(glob.glob(os.path.join(folder, PREFIX + "res_%d_p*.lua" % cid)), key=progress_number)


NOT_ANSWERING = "(game closed, in a menu or loading, or the mod is not enabled for this save)"


def wait_answer(folder, cid, timeout, final_tag=None, on_progress=None):
    """The final answer (or the error answer) of one command; progress answers go to on_progress."""
    deadline = time.time() + timeout
    seen = 0  # highest progress number shown: cleanup may remove old progress files of a long run
    while time.time() < deadline:
        for tag in ("error", final_tag):
            got = try_read(answer_path(folder, cid, tag))
            if got is not None:
                return got
        prog = progress_files(folder, cid)
        if on_progress and prog and progress_number(prog[-1]) > seen:
            got = try_read(prog[-1])
            if got is not None:
                seen = progress_number(prog[-1])
                on_progress(got)
        time.sleep(0.1)
    raise ToolError(f"no answer to command {cid} in {timeout:g} s {NOT_ANSWERING}")


NOT_READY_GRACE_SEC = 3  # the game's log says it cannot answer: give it this long, then report why
LOG_SETTLE_SEC = 5  # a state this fresh may just be a line the game has not flushed yet: do not trust it


def wait_pickup(folder, cid):
    """Until the mod has taken the command: its receipt, or any answer, is on disk. When the game is in a
    menu, loading or closed, says so after a few seconds instead of waiting the full timeout."""
    start = time.time()
    deadline = start + PICKUP_TIMEOUT_SEC
    next_check = start + NOT_READY_GRACE_SEC
    while time.time() < deadline:
        if answer_files(folder, cid):
            return
        if time.time() >= next_check:
            next_check = time.time() + 1
            st = game_state(folder)
            # a closed game needs no settling; otherwise the next marker may not be on disk yet (e.g. "Game is
            # ready" still buffered), so trust a state only once its marker is a few seconds old
            age = st.get("sinceAge")
            settled = st["state"] in ("closed", "crashed") or (age is not None and age >= LOG_SETTLE_SEC)
            if st["state"] != "in_game" and settled and not menu_probe(folder, st):
                raise GameNotReady(f"the mod cannot take command {cid}: {st['text']}", st)
        time.sleep(0.05)
    st = game_state(folder)
    if st["state"] != "in_game" and not menu_probe(folder, st):
        raise GameNotReady(f"the mod did not pick up command {cid} in {PICKUP_TIMEOUT_SEC} s: {st['text']}", st)
    # the save is running, so the mod itself is not answering: not exit 3, which means "where the game is"
    raise ToolError(f"the mod did not pick up command {cid} in {PICKUP_TIMEOUT_SEC} s although the log says "
                    f"{st['text']}: an ESC menu or a dialog (not in the log), or the mod is not enabled or failed "
                    "(look at `log --grep remote_probe`)")


OWNER = None  # set by main from --owner / TF3CTL_OWNER
OTHER_OWNER_OK = False  # set by main from --other-owner-ok

# commands in CHANGES_GAME whose --dry-run still does work in the game (the validator runs for minutes)
DRY_RUN_CHANGES = {"modhubPublish", "modhubValidate", "lightsOff"}  # lightsOff: its dry run asks the engine


def changes_game(cmd, args):
    """Whether this command, with these args, changes the game: CHANGES_GAME, except a --dry-run / --list (the mod
    only answers what it would do) and camera without arguments (only reads the camera)."""
    if cmd not in CHANGES_GAME:
        return False
    args = args or {}
    # road --dry-run --engine-check: the engine evaluates the proposal (makeProposalData), so it counts as changing
    # the game (ask for the game first), unlike a plain dry run
    if cmd in ("road", "track", "build") and args.get("engineCheck") is True:
        return True
    if cmd not in DRY_RUN_CHANGES and (args.get("dryRun") is True or args.get("list") is True):
        return False
    if cmd == "camera" and not args:
        return False
    return True


def read_launched():
    """(record, why): the launch record as written by write_launched (or coop start), or (None, why it does not
    count). A record without an owner counts only while it carries a coop mark (or coopChanges, after coop end): a game a person started, shared with
    one client (coop start); its "owner" is None then."""
    path = launched_path()
    try:
        st = os.lstat(path)
        if not stat.S_ISREG(st.st_mode) or not owned_by_me(st):
            return None, "the launch record %s is not a file of this user" % path
        with open(path, encoding="utf-8") as f:
            rec = json.load(f)
    except FileNotFoundError:
        return None, "no launch record %s" % path
    except (OSError, ValueError) as e:
        return None, "cannot read the launch record %s: %s" % (path, e)
    if not isinstance(rec, dict) or rec.get("v") != 1:
        return None, "the launch record %s is not a version 1 object" % path
    owner, pid = rec.get("owner"), rec.get("pid")
    if isinstance(pid, bool) or not isinstance(pid, int) or pid <= 0:
        return None, "the launch record %s has no owner and pid" % path
    # any coop key counts here, a malformed one too: coop_mark then makes it the strict side, and coop end removes it
    if owner is None and ("coop" in rec or isinstance(rec.get("coopChanges"), int)):
        return dict(rec, owner=None), None
    if not isinstance(owner, str) or not owner:
        return None, "the launch record %s has no owner and pid" % path
    return rec, None


# ---------------------------------------------------------------------------------------------------------------
# coop: a person and one client (--owner) share the running game. The launch record carries
# "coop": {"with", "reason", "since", "until"[, "modified", "changes"]}; it counts while until is ahead and the
# record's pid is the running game. The client then may do what helps a person playing (look, build, test events),
# but nothing that takes the game away from them or writes their saves.

# saves tf3ctl's clients may write and change freely: the configuration's testSavePrefixes, or (testSaveDigitFirst)
# one digit and then no digit ("3-probe"). Every other name is a person's own save.
TEST_SAVE_ONE_DIGIT = re.compile(r"[0-9](?![0-9])")
COOP_MINUTES_MAX = 7 * 24 * 60  # a mark further ahead, NaN or Infinity is no mark (also for the guard outside)
COOP_UNTIL_MAX_SEC = COOP_MINUTES_MAX * 60
COOP_REASON_MAX = 200
# what the coop client may send (after the reading commands, which always go): a person keeps the game itself
# modChange: another mod's command, the same as event (a test command a mod ships); a save stays refused by "save"
COOP_ALLOWED = {"camera", "window", "event", "build", "road", "track", "stockSet", "money", "steps", "modChange"}
# calendarSpeedSet: the calendar slider goes as speed does (the person's own control of the time)
# evalWrite: any Lua on a test save (eval_write_check), and during coop only when the person asked
COOP_USER_ASKED = {"speed", "run", "calendarSpeedSet", "evalWrite"}  # pause is speed 0: only when the person asked (--user-asked)
COOP_UNCOUNTED = {"camera", "window", "speed", "save", "calendarSpeedSet"}  # they leave the world as it was
LOADED_ANCHORS = (b"Application startup", b"Loading game from file", b"Start new game")
USER_ASKED = False  # set by main from --user-asked


class IgnoreErrorsRefused(OwnerRefused):
    """road --ignore-errors on a game that is not a test save's, or during coop; nothing was sent. Exit code 4."""
    refused = "ignore-errors"


def ignore_errors_check(cmd, args):
    """Before a command carrying ignoreErrors (road --ignore-errors): the loaded save's name when it may go, which
    the mod checks again (_testSave). Refused (nothing sent): on any command but road; when the loaded save is not a
    test save's (a person's save, a new game with no name yet, or not known from the log); while the running game
    carries any coop mark (active, expired or malformed: a person may be playing). None without ignoreErrors."""
    if not args or "ignoreErrors" not in args:
        return None
    if cmd != "road":
        raise IgnoreErrorsRefused("refused '%s', nothing sent: ignoreErrors goes with road only" % cmd)
    if args["ignoreErrors"] is not True:
        raise IgnoreErrorsRefused("refused 'road', nothing sent: ignoreErrors must be true (or left out)")
    head = "refused 'road --ignore-errors', nothing sent (for test saves only: skips the engine's checks): "
    return loaded_test_save_or_refuse(head, IgnoreErrorsRefused)


def loaded_test_save_or_refuse(head, refusal, coop_ok=False):
    """The loaded save's name when it is a test save's and the running game carries no coop mark (active, expired or
    malformed: a person may be playing); else refusal(head + why) is raised, nothing sent. A new game with no save
    name yet, or a save not known from the log, is refused too. coop_ok: an active coop mark naming this --owner
    goes on (coop_check, in check_game_owner, decided over it); any other mark still refuses (another client, even
    with --other-owner-ok, an expired or a malformed mark)."""
    pids = game_pids()
    rec, _ = read_launched()
    mine = False
    if coop_ok and pids and rec is not None:
        coop = active_coop(rec, pids)
        mine = coop is not None and bool(OWNER) and OWNER in coop_with(coop)
    if not mine and pids and rec is not None and coop_mark(rec, pids)[0] is not None:
        raise refusal(head + "the running game carries a coop mark, so the user may be playing it (coop end first)")
    save = loaded_save()
    if save == "":
        raise refusal(head + "the running game is a new game with no save name yet. Save it under a test "
                      "save's name (save probe-NAME), then load that (load probe-NAME): the loaded "
                      "save's name is read from the game's log")
    if save is None:
        raise refusal(head + "which save the game loaded is not known (no game log, or the main menu)")
    if not is_test_save(save):
        raise refusal(head + "the loaded save %r is not a test save's (%s)" % (save, test_save_text()))
    return save


class RunningCostsRefused(OwnerRefused):
    """running-costs --set-* / --scale-* on a game that is not a test save's, or during coop; nothing was sent.
    Exit code 4."""
    refused = "running-costs"


def running_costs_check(cmd, args):
    """Before runningCostsSet (running-costs --set-* / --scale-*): the loaded save's name, which the mod checks
    again (_testSave), when it is a test save's and no coop mark is on the running game; else RunningCostsRefused,
    nothing sent (the same rules as road --ignore-errors). None for any other command: the read-only running-costs
    and finance go anywhere."""
    if cmd != "runningCostsSet":
        return None
    head = ("refused 'running-costs' (a write), nothing sent (for test saves only: it rewrites a vehicle model's "
            "running costs for the rest of the session): ")
    return loaded_test_save_or_refuse(head, RunningCostsRefused)


class LightsRefused(OwnerRefused):
    """lights --off on a game that is not a test save's, or during coop; nothing was sent. Exit code 4."""
    refused = "lights"


def lights_check(cmd, args):
    """Before lightsOff (lights --off, its --dry-run too: it asks the engine): the loaded save's name, which the mod
    checks again (_testSave), when it is a test save's and no coop mark is on the running game; else LightsRefused,
    nothing sent (the same rules as road --ignore-errors). None for any other command."""
    if cmd != "lightsOff":
        return None
    head = ("refused 'lights --off', nothing sent (for test saves only: it changes a junction's traffic light): ")
    return loaded_test_save_or_refuse(head, LightsRefused)


class EvalRefused(OwnerRefused):
    """eval --write on a game that is not a test save's; nothing was sent. Exit code 4."""
    refused = "eval"


def eval_write_check(cmd, args):
    """Before evalWrite (eval --write): the loaded save's name, which the mod checks again (_testSave), when it is a
    test save's; else EvalRefused, nothing sent. Unlike the other test-save commands it may go during coop: on a
    test save, and only with --user-asked (coop_check, COOP_USER_ASKED). None for any other command: eval alone
    (its environment has no writers) goes to any save."""
    if cmd != "evalWrite":
        return None
    head = ("refused 'eval --write', nothing sent (for test saves only: the code runs with every global, so it can "
            "change anything): ")
    return loaded_test_save_or_refuse(head, EvalRefused, coop_ok=True)


def test_save_checks(cmd, args):
    """The loaded test save's name for the commands that go to test saves only (road --ignore-errors, running-costs
    writes, lights --off, eval --write), which the mod checks again (_testSave); None for any other command. Refuses
    (nothing sent) as each check says."""
    for check in (ignore_errors_check, running_costs_check, lights_check, eval_write_check):
        save = check(cmd, args)
        if save is not None:
            return save
    return None


# The force mark (2026-11-24): once road --ignore-errors went to the running game (a build, not --dry-run), its
# launch record carries "forced": true and "forcedCount". A game built past the engine's checks then saves only
# under FORCED_SAVE_PREFIX names, so the state never lands in a test base or a person's save. The mark is part of the
# record: the next launch / restart writes a new record without it, and the record goes once the game is seen
# stopped. Any "forced" key counts (the strict side, like a malformed coop mark).
FORCED_SAVE_PREFIX = "probe-force-"


class ForcedSaveRefused(OwnerRefused):
    """save to a name but FORCED_SAVE_PREFIX's after road --ignore-errors went to this run of the game; nothing
    was sent. Exit code 4. Neither --other-owner-ok nor --user-asked sends it."""
    refused = "forced-save"


def forced_count(rec, pids):
    """How many forced builds the record notes for the running game (at least 1 once marked), or None: no record,
    no mark, or a record of another game (its pid not running)."""
    if rec is None or "forced" not in rec or rec.get("pid") not in pids:
        return None
    n = rec.get("forcedCount")
    return n if isinstance(n, int) and not isinstance(n, bool) and n > 0 else 1


def is_forced_save_name(name):
    """A plain save name starting with FORCED_SAVE_PREFIX and more after it."""
    return (isinstance(name, str) and name.startswith(FORCED_SAVE_PREFIX) and len(name) > len(FORCED_SAVE_PREFIX)
            and "/" not in name and "\\" not in name and name == name.strip())


def loaded_forced_save():
    """The loaded save's name when it is a FORCED_SAVE_PREFIX save (a state built forced in an earlier run of the
    game), else None. Never raises."""
    save = loaded_save()
    if not isinstance(save, str) or not save:
        return None
    name = re.split(r"[/\\]", save.strip())[-1]
    name = name[:-4] if name.endswith(".sav") else name
    return name if is_forced_save_name(name) else None


def forced_save_check(cmd, args):
    """Before save: refused (ForcedSaveRefused, nothing sent) when the name is not FORCED_SAVE_PREFIX's and the
    running game carries the force mark, or has a FORCED_SAVE_PREFIX save loaded (its forced state, saved in an
    earlier run, would else go under another name). Unforced games save as before."""
    if cmd != "save":
        return
    name = (args or {}).get("name")
    if is_forced_save_name(name):
        return
    pids = game_pids()
    if not pids:
        return
    rec, _ = read_launched()
    n = forced_count(rec, pids)
    if n is None:
        loaded = loaded_forced_save()
        if loaded is None:
            return
        raise ForcedSaveRefused(
            "refused 'save %s', nothing sent: the loaded save %r was built with the engine's checks skipped "
            "(road --ignore-errors), so it saves only under %s* names, to keep test bases and the user's saves free "
            "of that state (--other-owner-ok and --user-asked do not change it)" % (name, loaded, FORCED_SAVE_PREFIX))
    raise ForcedSaveRefused(
        "refused 'save %s', nothing sent: this run of the game had roads built with the engine's checks skipped "
        "(road --ignore-errors, %d time%s), so it saves only under %s* names, to keep test bases and the user's "
        "saves free of that state (--other-owner-ok and --user-asked do not change it; the mark goes with the game: "
        "the next launch / restart has none)" % (name, n, "" if n == 1 else "s", FORCED_SAVE_PREFIX))


def note_forced(cmd, args):
    """Before a forced road build (ignoreErrors, not dryRun) is written for the mod: the force mark in the running
    game's launch record, count + 1. Without a record of the running game to keep it in, or when it cannot be
    written, the build is refused (IgnoreErrorsRefused, nothing sent): a force nobody remembers would let a save
    through. Counted before the send, so a build that then fails still counts (the strict side)."""
    if cmd != "road" or not args or args.get("ignoreErrors") is not True or args.get("dryRun") is True:
        return None
    head = "refused 'road --ignore-errors', nothing sent: "
    pids = game_pids()
    if not pids:
        return None  # no game: send says where the game is, and nothing is built
    try:
        with launched_lock():
            rec, why = read_launched()
            if rec is None or rec["pid"] not in pids:
                raise IgnoreErrorsRefused(
                    head + "no launch record of the running game to keep the force mark in (%s); the mark keeps "
                    "later saves to %s* names. Start the game with tf3ctl launch / restart --owner"
                    % (why or "the record names pid %d, not the running game" % rec["pid"], FORCED_SAVE_PREFIX))
            n = forced_count(rec, pids) or 0
            record = dict(rec, forced=True, forcedCount=n + 1)
            if record.get("owner") is None:
                record.pop("owner", None)  # as written: a record without an owner has no owner key
            _write_record(record)
    except OSError as e:
        raise IgnoreErrorsRefused(head + "could not write the force mark into the launch record %s: %s"
                                  % (launched_path(), e))
    return n + 1


def forced_note():
    """For status: {"forced": one line} while the running game carries the force mark, else {}. Never raises."""
    try:
        rec, _ = read_launched()
        n = forced_count(rec, game_pids()) if rec else None
        if n is None:
            loaded = loaded_forced_save() if game_pids() else None
            if loaded is None:
                return {}
            return {"forced": {
                "count": 0, "loaded": loaded, "savePrefix": FORCED_SAVE_PREFIX,
                "text": "the loaded save %s was built past the engine's checks: save goes to %s* names only"
                        % (loaded, FORCED_SAVE_PREFIX),
                "textJa": "読み込んだセーブ %s はエンジンの検査を外して建てたものです。保存できるのは %s* の名前だけです"
                          % (loaded, FORCED_SAVE_PREFIX)}}
        return {"forced": {
            "count": n, "savePrefix": FORCED_SAVE_PREFIX,
            "text": "built past the engine's checks in this run (road --ignore-errors, %d time%s): save goes to %s* "
                    "names only" % (n, "" if n == 1 else "s", FORCED_SAVE_PREFIX),
            "textJa": "この起動でエンジンの検査を外して建てました（road --ignore-errors、%d 回）。保存できるのは %s* の名前だけです"
                      % (n, FORCED_SAVE_PREFIX)}}
    except Exception:
        return {}


class CoopRefused(OwnerRefused):
    """A command the coop client may not send while a person shares the game; nothing was sent. Exit code 4."""
    refused = "coop"


class CoopMarkRefused(OwnerRefused):
    """A game-changing command from the launcher or the client of a coop mark that does not count any more (its
    until is past: "coop-expired") or that is malformed ("coop-invalid"), on the running game; nothing was sent.
    Exit code 4. The strict side, like the guard outside: the person may still be playing, so the mark only ends
    by coop end (or the game ending), never by its time running out."""

    def __init__(self, msg, refused):
        super().__init__(msg)
        self.refused = refused


def is_test_save(name, path_ok=True):
    """Whether name is a test save's (test_save_prefixes, or one digit first with testSaveDigitFirst). A loaded
    save may be given as a path (its file name counts); a name to save to must be a plain name (path_ok=False)."""
    if not isinstance(name, str) or not name.strip():
        return False
    name = name.strip()
    if "/" in name or "\\" in name:
        if not path_ok:
            return False
        name = re.split(r"[/\\]", name)[-1]
    if name.endswith(".sav"):
        name = name[:-4]
    return name.startswith(test_save_prefixes()) or bool(CONFIG["testSaveDigitFirst"]
                                                         and TEST_SAVE_ONE_DIGIT.match(name))


def loaded_save():
    """The save the running game loaded, from its log: its name, "" for a new game (no save name yet), None when
    unknown (no log, the main menu). Never raises."""
    try:
        path = os.environ.get("TF3_LOG") or stdout_log(exchange_dir())
        lines = log_tail_from_anchor(path, LOADED_ANCHORS)
    except (OSError, ToolError):
        return None
    first = lines[0] if lines else ""
    if "Loading game from file" in first:
        return first.split("Loading game from file", 1)[1].strip()
    if "Start new game" in first:
        return ""
    return None


def coop_with(coop):
    """The coop mark's clients: "with" is one name (a list is read too, for other writers)."""
    w = coop.get("with") if isinstance(coop, dict) else None
    if isinstance(w, str):
        return [w] if w else []
    if isinstance(w, list):
        return [x for x in w if isinstance(x, str) and x]
    return []


def coop_mark(rec, pids, now=None):
    """(state, why) of the record's coop mark on the running game: state "active" (with named, until ahead, at
    most COOP_UNTIL_MAX_SEC), "expired" (well formed, until past) or "invalid" (no or empty with; until not a
    finite number or too far ahead; the mark not an object), with why for "invalid". (None, None) when the record
    has no coop key or its pid is not the running game's (the shared game ended)."""
    if not isinstance(rec, dict) or "coop" not in rec or rec.get("pid") not in pids:
        return None, None
    c = rec["coop"]
    if not isinstance(c, dict):
        return "invalid", "the mark is not an object"
    if not coop_with(c):
        return "invalid", "it names no client (with)"
    until = c.get("until")
    if isinstance(until, bool) or not isinstance(until, (int, float)) or not math.isfinite(until):
        return "invalid", "its until %r is not a finite number" % (until,)
    now = time.time() if now is None else now
    if until > now + COOP_UNTIL_MAX_SEC:
        return "invalid", "its until is more than %d days ahead" % (COOP_UNTIL_MAX_SEC // 86400)
    if until <= now:
        return "expired", None
    return "active", None


def active_coop(rec, pids, now=None):
    """The record's coop mark while it counts: until ahead, the record's pid among the running game's. Else None."""
    state, _ = coop_mark(rec, pids, now)
    return rec["coop"] if state == "active" else None


def coop_mark_refusal(cmd, rec, pids, now=None):
    """CoopMarkRefused for this --owner when the running game's coop mark is expired or malformed and this owner
    is its launcher or one of its clients: the person is taken to be playing. Else None (other owners are checked
    as before)."""
    state, why = coop_mark(rec, pids, now)
    if state not in ("expired", "invalid") or not OWNER:
        return None
    c = rec["coop"]
    if OWNER != rec.get("owner") and OWNER not in coop_with(c):
        # a person's game whose mark names no client that can be read: whose coop it is is not known, so no
        # client changes it (not with --other-owner-ok either)
        if not (rec.get("owner") is None and not coop_with(c)):
            return None
    if state == "expired":
        return CoopMarkRefused(
            "refused '%s', nothing sent: the coop (%s with the user) expired at %s, and the user may still be "
            "playing. To go on, extend it with coop start; to finish, coop end"
            % (cmd, ", ".join(coop_with(c)), _clock(c["until"])), "coop-expired")
    return CoopMarkRefused(
        "refused '%s', nothing sent: the coop mark on the running game is malformed (%s), so the user is taken to "
        "be playing. Remove it with coop end, or write it anew with coop start" % (cmd, why), "coop-invalid")


def coop_check(cmd, args, coop):
    """For the coop client: {"coop": ..., "count": bool} when cmd may go (count: it changes a person's game), else
    CoopRefused."""
    args = args or {}
    save = loaded_save()
    test = is_test_save(save)
    who = ", ".join(coop_with(coop))
    head = ("refused '%s', nothing sent: during coop (%s with the user, until %s) the user is playing, so "
            % (cmd, who, time.strftime("%H:%M", time.localtime(coop["until"]))))
    if cmd == "window" and args.get("closeAll"):
        raise CoopRefused(head + "their windows stay open (window --close-all is not sent)")
    if cmd in COOP_USER_ASKED and not USER_ASKED:
        if cmd == "evalWrite":
            raise CoopRefused(head + "eval --write (any Lua, with every global) goes only when the user asked for "
                              "it: add --user-asked then")
        raise CoopRefused(head + "the game's speed is theirs: add --user-asked only when the user asked for it")
    if cmd == "save":
        target = args.get("name")
        if not is_test_save(target, path_ok=False):
            raise CoopRefused(head + "no save of theirs is written: %r is not a test save's name (%s)"
                              % (target, test_save_text()))
        if not test and not USER_ASKED:
            raise CoopRefused(head + "their game (%s) is not saved, not even to a new name: add --user-asked only "
                              "when the user asked for it" % (repr(save) if save else "no test save loaded"))
    elif cmd not in COOP_ALLOWED and cmd not in COOP_USER_ASKED:
        raise CoopRefused(head + "'%s' is theirs to do (coop sends looking, building and test commands only); ask "
                          "the user, or end coop with them first (coop end)" % cmd)
    count = not test and cmd not in COOP_UNCOUNTED and args.get("dryRun") is not True
    return {"coop": {"with": who, "save": save, "testSave": test}, "count": count}


# The debug commands: they change the save's contents as no player can. They go as any command (some to test saves
# only: test_save_checks); their answers say that saving keeps the change (saveNote), except a dry run's.
SAVE_NOTE = "this command changes the save's contents; saving keeps the change"
# a model's values live in the session, not in the save (whether a save keeps them was not checked)
RUNNING_COSTS_NOTE = "this command changes the vehicle model for the rest of the session, as no player can"
# eval --write: what the code did is not known to the tool
EVAL_WRITE_NOTE = ("eval --write ran code with every global: the save's contents may have changed (saving keeps what "
                   "it changed); the save entry points were replaced, best effort, so it did not save")
DEBUG_COMMANDS = {"stockSet": "stock set", "steps": "steps", "money": "money", "townDevelop": "town develop",
                  "townSize": "town size", "townConnect": "town connect", "companyInit": "company init",
                  "runningCostsSet": "running-costs --set-* / --scale-*", "lightsOff": "lights --off",
                  "evalWrite": "eval --write"}


def debug_command(cmd, args):
    """The name of the debug command cmd with args is, for a message; None when it is none."""
    args = args or {}
    if cmd in DEBUG_COMMANDS:
        return DEBUG_COMMANDS[cmd]
    if cmd == "road" and args.get("ignoreErrors") is True:
        return "road --ignore-errors"
    return None


def note_save_change(cmd, args, res):
    """A debug command's answer gets saveNote when it did something: not a dry run, not a refusal or error,
    not one that sent nothing (company init on a game already set up)."""
    if (isinstance(res, dict) and debug_command(cmd, args) and (args or {}).get("dryRun") is not True
            and res.get("ok") is True and res.get("sent") is not False):
        res["saveNote"] = (RUNNING_COSTS_NOTE if cmd == "runningCostsSet" else EVAL_WRITE_NOTE if cmd == "evalWrite"
                           else SAVE_NOTE)
    return res


def check_game_owner(cmd, args=None):
    """Before a game-changing command: refuses it (OwnerRefused, nothing sent) unless the running game is the one
    this --owner started through tf3ctl (2026-11-23: a script left running after a crash sent save and quit to the
    game another client had started meanwhile). Returns None when it may go, or, with --other-owner-ok, a note of
    whose game it went to. While a coop mark names this --owner, coop_check decides instead (--other-owner-ok does
    not widen it). No game process: nothing to protect, and send says where the game is."""
    if not changes_game(cmd, args):
        return None
    pids = game_pids()
    if not pids:
        return None
    rec, why = read_launched()
    coop = active_coop(rec, pids) if rec else None
    if coop is not None and OWNER and OWNER in coop_with(coop):
        return coop_check(cmd, args, coop)
    refusal = coop_mark_refusal(cmd, rec, pids) if rec else None
    if refusal is not None:
        raise refusal  # --other-owner-ok does not send it either
    if not CONFIG["ownerCheck"]:
        return None  # one client, or clients that keep out of each other's way themselves
    if rec is None:
        problem = ("%s: the running game (pid %s) was not started by tf3ctl with an --owner (started from Steam "
                   "by a person?)" % (why, ", ".join(map(str, pids))))
        whose = "none"
    elif rec["pid"] not in pids:
        problem = ("the launch record names pid %d (owner %s), but the running game is pid %s: it was started "
                   "outside tf3ctl (from Steam by a person?)" % (rec["pid"], rec["owner"] or "none",
                                                               ", ".join(map(str, pids))))
        whose = "none"
    elif rec["owner"] is None:
        state, _ = coop_mark(rec, pids)
        problem = ("the running game (pid %d) was started by a person, and its coop mark %s"
                   % (rec["pid"], "names %s" % ", ".join(coop_with(coop)) if coop else
                      "is %s, so the user may still be playing" % state if state else "has ended"))
        whose = "none"
    elif not OWNER:
        problem = "the running game was started by %s, and this command has no --owner" % rec["owner"]
        whose = rec["owner"]
    elif rec["owner"] != OWNER:
        problem = "the running game was started by %s, not by %s" % (rec["owner"], OWNER)
        whose = rec["owner"]
    else:
        return None
    if OTHER_OWNER_OK:
        note = {"launchedBy": whose, "why": problem, "owner": OWNER}
        if coop is not None:
            problem += " (the user is playing it in coop with %s)" % ", ".join(coop_with(coop))
        print("warning: --other-owner-ok: '%s' sent although %s" % (cmd, problem), file=sys.stderr)
        return note
    raise OwnerRefused("refused '%s', nothing sent: %s. Only the owner who started the game changes it; ask the "
                       "client using it (--other-owner-ok sends anyway, when the clients agreed)" % (cmd, problem))


def send(cmd, args=None, timeout=20, final_tag=None, on_progress=None, folder=None):
    other = check_game_owner(cmd, args)  # before anything is written to the exchange folder
    # (road --ignore-errors, running-costs writes, lights --off: a test save, no coop)
    test_save = test_save_checks(cmd, args)
    folder = folder or exchange_dir()
    args = dict(args or {})
    for key in ("_testSave", "_testSaveRules", "_modhub"):
        args.pop(key, None)  # only this function names them
    if test_save is not None:
        # the mod checks the name again, by the same rules (the configuration's: the mod cannot read the file)
        args["_testSave"] = test_save
        args["_testSaveRules"] = test_save_rules()
    if cmd in MODHUB_COMMANDS:
        args["_modhub"] = modhub_config()  # the folders the mod's validate and publish take
    if OWNER:
        args["_owner"] = OWNER
    if other and other.get("launchedBy"):
        args["_otherOwnerOk"] = other["launchedBy"]  # the mod's log line says so
    with command_lock(folder):
        # under the command lock: no other client's forced build can come between this check and this save
        forced_save_check(cmd, args)  # (after road --ignore-errors, or a probe-force-* save loaded: probe-force-*)
        note_forced(cmd, args)  # (a forced build: the mark goes into the launch record before it is sent)
        cleanup(folder)
        if cmd in CHANGES_GAME:
            try:
                warn_other_owner(folder, OWNER, cmd)
            except (OSError, ValueError, TypeError):
                pass  # advisory only: never stop a command over it
        cid = new_id()
        write_command(folder, cid, cmd, args)
        # one command file: the next tool may only overwrite it once the mod has read this command
        try:
            wait_pickup(folder, cid)
            if cmd in CHANGES_GAME:
                note_activity(folder, OWNER, cmd)  # only commands the mod really took
            if other and other.get("count"):
                coop_note_change()  # a person's game changed: status and coop end say so
        except ToolError:
            # withdraw it: a mod that wakes up later must not run a command reported as failed (a load twice)
            write_command(folder, 0, "none", {})
            raise
    try:
        res = wait_answer(folder, cid, timeout, final_tag, on_progress)
        if other and other.get("launchedBy") and isinstance(res, dict):
            res["otherOwnerOk"] = other
        elif other and other.get("coop") and isinstance(res, dict):
            res["coop"] = other["coop"]
        return note_save_change(cmd, args, res)
    finally:
        if final_tag is None:
            remove(answer_files(folder, cid))


def wait_new_hello(folder, cid, after_stamp, timeout, why_slow=None):
    """After a load's ack: the new game's hello, or the load's error answer. A game that closes or crashes
    meanwhile ends the wait at once (2026-11-15: a crashed newgame kept the tool waiting 10 minutes)."""
    deadline = time.time() + timeout
    next_check = time.time() + 5
    gone = 0  # consecutive readings of a closed game: one odd process scan must not end a normal load
    while time.time() < deadline:
        if time.time() >= next_check:
            next_check = time.time() + 5
            st = game_state(folder)
            gone = gone + 1 if st["state"] in ("closed", "crashed") else 0
            if gone >= 2:
                remove_launched()  # the launched game is gone
                raise GameNotReady(f"the game {'crashed' if st['state'] == 'crashed' else 'closed'} during the "
                                   "load: look at `log`", st)
        err = try_read(answer_path(folder, cid, "error"))
        if err is not None:
            return err
        hellos = hello_files(folder)
        if hellos and current_stamp(folder) != after_stamp:
            got = try_read(hellos[0])
            if got is not None:
                return got
        time.sleep(0.25)
    if why_slow:
        raise ToolError(f"the game did not come back from the load in {timeout:g} s: {why_slow}")
    raise ToolError(f"the game did not come back from the load in {timeout:g} s (it may have dropped to the main "
                    "menu: look at the log)")


def stdout_log(folder):
    return os.path.join(os.path.dirname(os.path.normpath(folder)), "crash_dump", "stdout.txt")


# ---------------------------------------------------------------------------------------------------------------
# where the game is, from its log and process: the mod's script does not run in menus or while loading, so
# it cannot say so itself

# marker in stdout.txt -> state it starts; checked in this order on each line
LOAD_SUSPECT_SEC = 180  # loads take 30-40 s here; much longer suggests one that failed

LOG_MARKERS = (
    ("Application startup", "starting"),
    ("Main menu is ready", "main_menu"),
    ("Loading game from file", "loading"),
    ("Game is ready", "in_game"),
    ("mod management mode from Disabled to Restricted", "menu"),
    ("mod management mode from Restricted to Disabled", "unmenu"),
)
STATE_TEXT = {
    "closed": "the game is not running",
    "crashed": "the game is not running and left a crash dump",
    "starting": "the game is starting",
    "main_menu": "the game is in the main menu (no save loaded)",
    "loading": "the game is loading a save",
    "menu": "a menu (load, save, settings or mod screen) is open in the game",
    "in_game": "the game is running a save",
}


def seconds_since(stamp):
    """Age of a log timestamp "YYYY-MM-DD HH:MM:SSZ" (UTC)."""
    if not stamp:
        return None
    try:
        import calendar
        return time.time() - calendar.timegm(time.strptime(stamp, "%Y-%m-%d %H:%M:%SZ"))
    except (ValueError, OverflowError):
        return None


TF3_EXE_WINDOWS = "TransportFever3.exe"  # [guess] the Windows build's process name: not seen on a Windows machine


def windows_game_pids():
    """The game's processes on Windows, from tasklist's CSV ("name","pid",...); [] when there are none (tasklist
    then prints an "INFO: No tasks ..." line) or tasklist cannot run."""
    try:
        r = subprocess.run(["tasklist", "/FI", "IMAGENAME eq " + TF3_EXE_WINDOWS, "/FO", "CSV", "/NH"],
                           capture_output=True, text=True, errors="replace", timeout=15)
    except (OSError, subprocess.SubprocessError):
        return []
    out = []
    for row in csv.reader((r.stdout or "").splitlines()):
        if len(row) >= 2 and row[0].strip().lower() == TF3_EXE_WINDOWS.lower() and row[1].strip().isdigit():
            out.append(int(row[1].strip()))
    return out


def game_pids():
    """TransportFever3's processes: their threads are named "Main Thread" etc. (pgrep -x TransportFever3 finds
    nothing), so look at the command line."""
    if on_windows():
        return windows_game_pids()
    out = []
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open("/proc/%s/cmdline" % pid, "rb") as f:
                argv0 = f.read().split(b"\0", 1)[0]
        except OSError:
            continue
        if os.path.basename(argv0) == b"TransportFever3":
            out.append(int(pid))
    return out


def game_running():
    return bool(game_pids())


def windows_kernel32():
    import ctypes
    return ctypes.WinDLL("kernel32", use_last_error=True)


def windows_process_start(pid):
    """Unix time a process started on Windows, from GetProcessTimes (None if unknown)."""
    import ctypes

    class FILETIME(ctypes.Structure):  # 100 ns steps since 1601-01-01 UTC
        _fields_ = [("low", ctypes.c_uint32), ("high", ctypes.c_uint32)]

    try:
        k32 = windows_kernel32()
        k32.OpenProcess.restype = ctypes.c_void_p  # a HANDLE: the default int would cut a 64-bit one
        k32.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
        k32.GetProcessTimes.argtypes = [ctypes.c_void_p] + [ctypes.POINTER(FILETIME)] * 4
        k32.CloseHandle.argtypes = [ctypes.c_void_p]
        handle = k32.OpenProcess(0x1000, False, int(pid))  # PROCESS_QUERY_LIMITED_INFORMATION
    except (OSError, AttributeError, ValueError, TypeError):
        return None
    if not handle:
        return None
    try:
        times = [FILETIME() for _ in range(4)]  # creation, exit, kernel, user
        if not k32.GetProcessTimes(handle, *[ctypes.byref(t) for t in times]):
            return None
        ticks = (times[0].high << 32) | times[0].low
        return ticks / 1e7 - 11644473600 if ticks else None
    finally:
        k32.CloseHandle(handle)


def process_start(pid):
    """Unix time a process started, from /proc (None if unknown)."""
    if on_windows():
        return windows_process_start(pid)
    try:
        with open("/proc/%d/stat" % pid) as f:
            fields = f.read().rsplit(")", 1)[1].split()
        with open("/proc/stat") as f:
            btime = next(int(l.split()[1]) for l in f if l.startswith("btime "))
        return btime + int(fields[19]) / os.sysconf("SC_CLK_TCK")
    except (OSError, ValueError, IndexError, StopIteration):
        return None


def menu_probe(folder, state=None):
    """The probe's hello when the newest one comes from the main-menu copy (startup.lua) of the game running now
    and the game is still in the main menu: then the mod answers there, where it otherwise cannot. (A save loaded
    by hand without the probe leaves that hello the newest, but the menu copy stops in a game.)"""
    hellos = hello_files(folder)
    if not hellos:
        return None
    st = state or game_state(folder)
    if st["state"] not in ("main_menu", "starting"):
        return None
    if not os.environ.get("TF3_ASSUME_RUNNING"):
        starts = [t for t in (process_start(p) for p in game_pids()) if t]
        # a menu hello from an earlier run of the game says nothing about this one
        if not starts or (mtime(hellos[0]) or 0) < max(starts) - 2:
            return None
    h = try_read(hellos[0])
    return h if isinstance(h, dict) and h.get("menu") else None


# markers that settle the state on their own (unlike the menu markers, which need to know if a save is running)
ANCHORS = (b"Application startup", b"Main menu is ready", b"Loading game from file", b"Game is ready")
CHUNK = 2_000_000
MAX_BACK = 200_000_000


def log_tail_from_anchor(path, anchors=ANCHORS):
    """The log's lines from the last anchor marker on: read backwards in chunks, since a chatty mod can write
    megabytes between two markers."""
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        end = f.tell()
        pos, data = end, b""
        while pos > 0 and end - pos < MAX_BACK:
            prev, pos = pos, max(0, pos - CHUNK)
            f.seek(pos)
            data = f.read(prev - pos) + data
            # the first line of a chunk may be cut: look for anchors only after its first newline
            body = data if pos == 0 else data[data.find(b"\n") + 1:]
            idx = max(body.rfind(a) for a in anchors)
            if idx >= 0:
                start = body.rfind(b"\n", 0, idx) + 1
                return body[start:].decode("utf-8", "replace").splitlines()
        return data.decode("utf-8", "replace").splitlines()


def lines_args(ns):
    """The lines command's args: name, line and problems only when given."""
    out = {}
    if ns.name:
        out["name"] = ns.name
    if getattr(ns, "line", None) is not None:
        out["line"] = ns.line
    if getattr(ns, "problems", False):
        out["problems"] = True
    return out


def log_state(lines):
    """(state, since, detail) from the log lines, newest last."""
    state, since, detail = "starting", None, None
    in_save = False
    for line in lines:
        for marker, new in LOG_MARKERS:
            if marker in line:
                ts = line[1:21] if line.startswith("[") else None
                if new == "unmenu":
                    new = "in_game" if in_save else "main_menu"
                elif new == "menu" and not in_save:
                    continue  # the main menu enables the mod hub too
                if new == "loading":
                    detail = line.split("Loading game from file", 1)[1].strip()
                in_save = new in ("in_game", "menu")
                state, since = new, ts
                break
    return state, since, detail


def game_state(folder=None):
    path = os.environ.get("TF3_LOG") or (stdout_log(folder or exchange_dir()))
    try:
        lines = log_tail_from_anchor(path)
        log_mtime = os.path.getmtime(path)
    except OSError:
        lines, log_mtime = [], None
    state, since, detail = log_state(lines)
    running = game_running() if not os.environ.get("TF3_ASSUME_RUNNING") else True
    if not running:
        dumps = glob.glob(os.path.join(os.path.dirname(path), "*.dmp"))
        newest = max((t for t in (mtime(d) for d in dumps) if t), default=None)
        state = "crashed" if newest and log_mtime and newest >= log_mtime - 5 else "closed"
        since, detail = None, None
    age = seconds_since(since)
    out = {"state": state, "text": STATE_TEXT[state], "since": since, "sinceAge": age, "log": path}
    if state == "loading" and age is not None and age > LOAD_SUSPECT_SEC:
        # no "Game is ready" for this long: the load may have failed without the log saying so
        out["text"] += " (for %d s: it may have failed; look at the log)" % age
    if detail:
        out["save"] = detail
    return out


# ---------------------------------------------------------------------------------------------------------------
# command line


def parse_param(s):
    """mod:key=index -> (mod, key, index); mod "" (base game) is written ':key=index'."""
    try:
        left, idx = s.rsplit("=", 1)
        mod, key = left.split(":", 1)
        return mod, key, int(idx)
    except ValueError:
        raise ToolError(f"--param must look like mod:key=index (1-based), got {s!r}")


def load_args(ns):
    args = {"save": ns.save}
    mods = {}
    if ns.set_mods is not None:
        mods["set"] = [m for m in ns.set_mods.split(",") if m]
    if ns.add:
        mods["add"] = ns.add
    if ns.remove:
        if SELF_MOD in ns.remove:
            raise ToolError("the remote probe cannot remove itself: nothing would answer after the load")
        mods["remove"] = ns.remove
    if mods:
        args["mods"] = mods
    if ns.param:
        params = {}
        for p in ns.param:
            mod, key, idx = parse_param(p)
            params.setdefault(mod, {})[key] = idx
        # the probe's game script listens for running-costs writes with this on (and may keep its subscription in
        # the save): never on a person's save. A new game (save None) may: it is a test until saved, and
        # running-costs writes only once it is loaded from a test save's name
        if (params.get(SELF_MOD, {}).get("gameScript") not in (None, 1) and ns.save is not None
                and not is_test_save(ns.save)):
            raise ToolError("--param %s:gameScript=%s goes with test saves only (%s); %r is not one"
                            % (SELF_MOD, params[SELF_MOD]["gameScript"], test_save_text(),
                               ns.save))
        args["params"] = params
    if ns.dry_run:
        args["dryRun"] = True
    if getattr(ns, "wait_for_start", False):
        args["waitForStart"] = True
    return args


# --wait-for-start: the loading screen holds at the base "Start Game" button until someone clicks it. Neither the
# game script nor guiUpdate runs there, so the mod reads no command files, not even quit (2026-11-20: a load with it
# stalled at the button and only quit --kill got out). Nothing here clicks it: the tool sends no clicks or keys.
WAIT_FOR_START_NOTE = "waiting for a person to press Start Game; the mod takes no commands until then"
# the answer comes only after the new game's hello, so after the click: it says what happened, not what is happening
WAIT_FOR_START_DONE = ("loaded with --wait-for-start: the loading screen waited for a person to press Start Game, "
                       "and the mod took no commands until then")
WAIT_FOR_START_HELP = ("keep the base game's 'Start Game' button: the loading screen stops there until a person "
                       "clicks it, and the mod takes no commands meanwhile (not even quit). Use it only with "
                       "someone at the game")
WAIT_FOR_START_SLOW = ("most likely the loading screen is waiting at the Start Game button (--wait-for-start), "
                       "which only a person can press; the mod takes no commands, not even quit, until then")


COMPANY_INIT_TIMEOUT_SEC = 45  # the mod waits 15 s for company.gs's state
RUNNING_COSTS_TIMEOUT_SEC = 45  # the mod waits 15 s for the game script's answer
# running-costs: the fields that may be written (metadata.maintenance), and the shorthand flags for them
RUNNING_COST_FIELDS = ("runningCosts", "runningCostScale", "maintenanceScale")


def company_init_after_newgame():
    """After a newgame: company init. A game started with town population has its basePopulation from the start
    event (measured 2026-11-23) and nothing is sent; one with basePopulation 0 and no town population (--no-towns)
    gets nothing either, since the event would give 0 again: the note says to place towns, then company init. Its
    answer is kept in the newgame's; a failure is a warning, the game is started either way."""
    try:
        res = send("companyInit", {}, timeout=COMPANY_INIT_TIMEOUT_SEC)
    except ToolError as e:
        res = {"ok": False, "error": str(e)}
    if not (isinstance(res, dict) and res.get("ok")):
        why = res.get("error") if isinstance(res, dict) else res
        print("warning: the new game started, but company init failed (%s): the base's company progression may "
              "not work (tf3ctl company)" % why, file=sys.stderr)
    elif res.get("noPopulation"):
        print("note: the new game has no town population, so the base's company progression (rank, ticket price "
              "multiplier) stays off: place towns, let them grow a little, then company init", file=sys.stderr)
    return res


def print_start_warnings(res):
    """A newgame's plan came out other than the menu would make it (the mod's warnings: difficulty_util not
    loaded, a base param missing or out of range): on stderr too, so it is not missed in the JSON."""
    warnings = res.get("warnings") if isinstance(res, dict) else None
    if isinstance(warnings, list):
        for w in warnings:
            print("warning: " + str(w), file=sys.stderr)


def replace_game(cmd, args, answer_only, timeout, company_init=True):
    """load / newgame: the mod acks, the next frame ends its game, and the new game's mod writes a new hello.
    A newgame (not the map editor) then gets company init unless company_init is False."""
    folder = exchange_dir()
    before = current_stamp(folder)
    if answer_only:
        res = send(cmd, args, timeout=90, folder=folder)
        print_start_warnings(res)
        return res
    ack = send(cmd, args, timeout=90, final_tag="ack", folder=folder)
    try:
        if not ack.get("ok"):
            return ack
        print_start_warnings(ack)
        held = bool(args.get("waitForStart"))
        print("loading ..." if cmd == "load" else "starting a new game ...", file=sys.stderr)
        if held:
            print("note: " + WAIT_FOR_START_NOTE, file=sys.stderr)
        after = wait_new_hello(folder, ack["id"], before, timeout, WAIT_FOR_START_SLOW if held else None)
        res = after if after.get("ok") is False else {"ok": True, "plan": ack, "hello": after}
        if held and res.get("ok"):  # a failed loadGame never reached the button
            res = dict(res, note=WAIT_FOR_START_DONE)
        if cmd == "newgame" and res.get("ok") and company_init and not args.get("editor"):
            res["companyInit"] = company_init_after_newgame()
        return res
    finally:
        if ack.get("id") is not None:
            remove(answer_files(folder, ack["id"]))


def newgame_args(ns):
    args = {}
    for key, value in (("climate", ns.climate), ("generator", ns.generator), ("size", ns.size), ("year", ns.year),
                       ("seed", ns.seed)):
        if value is not None:
            args[key] = value
    if ns.no_towns:
        args["towns"] = False
    if ns.no_industries:
        args["industries"] = False
    if ns.list:
        args["list"] = True
    if getattr(ns, "editor", False) and not ns.list:
        args["editor"] = True  # the map editor; the mod takes the official mods and the probe as the base list
    base = load_args(argparse.Namespace(save=None, set_mods=ns.set_mods, add=ns.add, remove=ns.remove,
                                        param=ns.param, dry_run=ns.dry_run))
    base.pop("save", None)
    # New games start without the base tutorial unless asked for (--tutorial): a test game has nobody to click
    # through it. The base parameter is 1-based like --param: 1 = Off, 2 = On (base mod.json, values Off / On;
    # the base pages test == 2 for on). The menu probe fills in the base defaults, whose tutorial is On, so
    # leaving it out started games with the tutorial window (2026-11-17). An explicit --param wins.
    if not getattr(ns, "tutorial", False) and not ns.list:
        base_params = base.setdefault("params", {}).setdefault("", {})
        base_params.setdefault(TUTORIAL_PARAM, TUTORIAL_OFF)
    args.update(base)
    return args


NO_COMPANY_INIT_HELP = ("leave out company init after the start (it sends the base's initNewGameFromMap again only "
                        "when basePopulation is missing, or 0 while the towns have population)")
TUTORIAL_PARAM = "guideSystemConfig.tutorial"
TUTORIAL_OFF = 1


# ---------------------------------------------------------------------------------------------------------------
# quit, launch, restart. The game reads "--script <mod>::/<file>" at startup and runs that file's update() every
# frame, in the main menu too (found 2026-11-16): startup.lua runs the probe there, so a save can be loaded or a
# new game started with nobody at the keyboard.

STARTUP_SCRIPT = SELF_MOD + "::/startup.lua"
LAUNCH_TIMEOUT_SEC = 240
QUIT_TIMEOUT_SEC = 60
LAUNCH_NO_PROCESS_SEC = 120
RELAUNCH_PAUSE_SEC = 5  # right after the game quit, Steam may still count it as running and ignore -applaunch


def wait_exit(timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if not game_pids():
            return True
        time.sleep(0.5)
    return not game_pids()


def recent_other_owner():
    """Another client's game-changing command in the last RECENT_SEC, or None (the tool's activity file)."""
    try:
        folder = exchange_dir()
    except ToolError:
        return None
    last = read_activity(folder)
    if not last or last.get("owner") == OWNER:
        return None
    try:
        age = time.time() - float(last.get("time") or 0)
    except (TypeError, ValueError):
        return None
    return last if age <= RECENT_SEC else None


# The launch record: which owner started the running game through tf3ctl, and its pid. Another tool (a guard that
# holds back game-changing commands while the game runs) reads it to let the owner who started the game quit it; a
# game started by hand from Steam has no record. Written once the probe answered after launch / restart, removed
# whenever tf3ctl saw the game stopped. Failing to write or remove it is only a warning: the record must never stop
# a launch or a quit. A record left behind is harmless to the reader, which checks the pid and its command line.

LAUNCHED_NAME = "launched.json"


def launched_path():
    """$XDG_RUNTIME_DIR/tf3ctl/launched.json, or /tmp/tf3ctl-<uid>/launched.json without XDG_RUNTIME_DIR. Windows
    (no uid): %LOCALAPPDATA%\\tf3ctl\\launched.json, or tf3ctl in the temporary folder without LOCALAPPDATA."""
    if not hasattr(os, "getuid"):
        folder = os.path.join(os.environ.get("LOCALAPPDATA") or tempfile.gettempdir(), "tf3ctl")
        return os.path.join(folder, LAUNCHED_NAME)
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    folder = os.path.join(runtime, "tf3ctl") if runtime else "/tmp/tf3ctl-%d" % os.getuid()
    return os.path.join(folder, LAUNCHED_NAME)


def _own_private_dir(folder):
    """Makes folder (0700) if missing and checks it is a real directory of this user: under /tmp anybody could have
    made it first, or put a symlink there."""
    try:
        os.mkdir(folder, 0o700)
    except FileExistsError:
        pass
    st = os.lstat(folder)
    if not stat.S_ISDIR(st.st_mode) or not owned_by_me(st):
        raise OSError("%s is not a folder of this user" % folder)
    if hasattr(os, "getuid") and stat.S_IMODE(st.st_mode) != 0o700:  # Windows: chmod sets only read-only
        os.chmod(folder, 0o700)


def remove_launched():
    """Removes the launch record once the game is seen stopped. Returns {"removed": path} (None when there was
    none); a failure is a warning."""
    path = launched_path()
    try:
        os.remove(path)
    except FileNotFoundError:
        return None
    except OSError as e:
        print("warning: could not remove the launch record %s: %s" % (path, e), file=sys.stderr)
        return {"warning": "could not remove %s: %s" % (path, e)}
    return {"removed": path}


def _write_record(record):
    """Writes the launch record through a temporary file in the same folder and os.replace (a reader never sees
    half a file). Returns the path; OSError on failure."""
    path = launched_path()
    folder = os.path.dirname(path)
    tmp = None
    try:
        _own_private_dir(folder)
        fd, tmp = tempfile.mkstemp(prefix=".launched-", suffix=".tmp", dir=folder)  # 0600
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(record, f)
            f.flush()
            os.fsync(f.fileno())
        replace_file(tmp, path)
        tmp = None
    finally:
        if tmp:
            _remove_quietly(tmp)
    return path


def write_launched(pid, owner=None, cmd="launch", now=None):
    """Writes the launch record for pid started by owner. Without an owner there is nothing to record: an older
    record is removed instead. Returns what was done for the command's answer; a failure is a warning."""
    owner = OWNER if owner is None else owner
    if not owner or pid is None:
        gone = remove_launched()
        return dict(gone or {}, written=False, why="no --owner" if not owner else "no game process found")
    path = launched_path()
    record = {"v": 1, "owner": owner, "pid": int(pid), "started_at": int(time.time() if now is None else now),
              "cmd": cmd}
    try:
        _write_record(record)
    except OSError as e:
        print("warning: could not write the launch record %s: %s" % (path, e), file=sys.stderr)
        return {"written": False, "warning": "could not write %s: %s" % (path, e)}
    return {"written": path, "owner": owner, "pid": int(pid)}


@contextlib.contextmanager
def launched_lock():
    """One read-change-write of the launch record at a time (coop start / end, the change count)."""
    folder = os.path.dirname(launched_path())
    _own_private_dir(folder)
    with open(os.path.join(folder, ".launched.lock"), "a") as f, lock_file(f):
        yield


def _clock(t):
    return time.strftime("%H:%M", time.localtime(t))


def coop_summary(rec, pids, now=None, ending=False):
    """status / coop start / coop end: the coop mark of the running game as one line (text, and textJa for the
    person), or None when the record has none for this game."""
    now = time.time() if now is None else now
    state, why = coop_mark(rec, pids, now)
    if state is None:
        return None
    c = rec["coop"] if isinstance(rec["coop"], dict) else {}
    active = state == "active" and not ending
    who = ", ".join(coop_with(c)) or "?"
    until = c.get("until") if state != "invalid" else now
    save = loaded_save()
    since = c.get("since")
    since = since if isinstance(since, (int, float)) and not isinstance(since, bool) and math.isfinite(since) else None
    reason = c.get("reason") if isinstance(c.get("reason"), str) else None
    # strict JSON out: a malformed mark's values written by another tool (NaN) are not passed on
    out = {"active": active, "with": who, "reason": reason, "since": since, "until": until,
           "minutesLeft": max(0, int((until - now) // 60)) if active else 0, "save": save,
           "testSave": is_test_save(save)}
    if active:
        text = "coop with %s until %s (%d min left): %s" % (who, _clock(until), out["minutesLeft"], reason)
        ja = "共同作業中（%s、%s まで、残り %d 分）: %s" % (who, _clock(until), out["minutesLeft"], reason)
    elif state == "expired" and not ending:
        out["expired"] = True
        text = ("coop with %s expired at %s: its game-changing commands are refused (the user may still be "
                "playing); coop start extends it, coop end finishes it" % (who, _clock(until)))
        ja = ("共同作業（%s）の期限（%s）が切れました。ゲームを変える命令は断ります。続けるなら coop start で延ばし、"
              "終えるなら coop end" % (who, _clock(until)))
    elif state == "invalid" and not ending:
        out.update(invalid=True, why=why)
        text = ("the coop mark is malformed (%s): game-changing commands of its launcher and client are refused; "
                "coop end removes it, coop start writes it anew" % why)
        ja = "共同作業の印の形が壊れています（%s）。ゲームを変える命令は断ります。coop end で消すか、coop start で書き直してください" % why
    else:
        text = "coop with %s %s" % (who, "ended now" if ending else "ended at %s" % _clock(until))
        ja = "共同作業（%s）は%s" % (who, "終わりました" if ending else " %s に終わりました" % _clock(until))
    n = c.get("changes") if isinstance(c.get("changes"), int) else 0
    if c.get("modified"):
        out.update(modified=True, changes=n)
        text += "; this game was changed during coop (%d times): saving keeps the changes" % n
        ja += "。このゲームは共同作業で変更されています（%d 回）。保存すると変更が残ります" % n
        if ending:
            text += (". The autosave (every 10 minutes) has the changed game: to go back, do not save, and load a "
                     "named save again")
            ja += "。オートセーブ（10 分ごと）には変更後の状態が入っています。元に戻すには、保存せずに、名前のついたセーブを読み直してください"
    out.update(text=text, textJa=ja)
    return out


def coop_args(minutes, reason):
    """The checked (minutes, reason) of coop start / launch --coop, else ToolError."""
    reason = (reason or "").strip()
    if not reason or len(reason) > COOP_REASON_MAX:
        raise ToolError("coop needs --reason: what the user and the client do together (1-%d characters)"
                        % COOP_REASON_MAX)
    if isinstance(minutes, bool) or not isinstance(minutes, int) or not 1 <= minutes <= COOP_MINUTES_MAX:
        raise ToolError("--minutes must be 1-%d" % COOP_MINUTES_MAX)
    return minutes, reason


def coop_start(minutes, reason, now=None):
    """Puts a coop mark for this --owner on the running game: the game this owner started, or a game a person
    started (no record of a running game, or one without an owner). Never on another owner's game, nor while
    another client's coop mark counts."""
    now = int(time.time() if now is None else now)
    if not OWNER:
        raise ToolError("coop start needs --owner: the client that shares the game with the user")
    minutes, reason = coop_args(minutes, reason)
    pids = game_pids()
    if not pids:
        raise ToolError("no game is running to share (launch --coop starts one and shares it)")
    try:
        with launched_lock():
            rec, _ = read_launched()
            old = None
            if rec is not None and rec["pid"] in pids:
                if rec["owner"] is not None and rec["owner"] != OWNER:
                    raise OwnerRefused("refused 'coop start', nothing changed: the running game was started by %s, "
                                       "not by %s; coop goes on the game this owner started or on one a person "
                                       "started (--other-owner-ok does not change that)" % (rec["owner"], OWNER))
                cur = active_coop(rec, pids, now)
                if cur is not None and OWNER not in coop_with(cur):
                    raise OwnerRefused("refused 'coop start', nothing changed: the game is shared with %s until %s "
                                       "(coop end first)" % (", ".join(coop_with(cur)), _clock(cur["until"])))
                old = rec.get("coop") if isinstance(rec.get("coop"), dict) else None
                if old is None and isinstance(rec.get("coopChanges"), int) and rec["coopChanges"] > 0:
                    old = {"modified": True, "changes": rec["coopChanges"]}  # an earlier coop on this game
                record = {k: v for k, v in rec.items() if k not in ("coop", "coopChanges")
                          and not (k == "owner" and v is None)}
            else:
                # a game a person started: the record names no owner, only the coop mark
                record = {"v": 1, "pid": int(launched_pid()), "started_at": now, "cmd": "coop"}
            mark = {"with": OWNER, "reason": reason, "since": now, "until": now + minutes * 60}
            if old and old.get("modified"):  # the same game, still changed by an earlier coop
                mark.update(modified=True, changes=old.get("changes") if isinstance(old.get("changes"), int) else 0)
            record["coop"] = mark
            path = _write_record(record)
    except OSError as e:
        raise ToolError("coop start: could not write the launch record %s: %s" % (launched_path(), e))
    return {"ok": True, "coop": coop_summary(record, pids, now), "launchedFile": path}


def coop_end(now=None):
    """Removes the coop mark (the rest of the record stays). Anybody may: it only takes rights away."""
    try:
        with launched_lock():
            rec, why = read_launched()
            if rec is None or "coop" not in rec:
                return {"ok": True, "note": "no coop mark (%s)" % (why or "the record has none")}
            summary = coop_summary(rec, game_pids(), now, ending=True)
            record = {k: v for k, v in rec.items() if k != "coop" and not (k == "owner" and v is None)}
            c = rec["coop"] if isinstance(rec["coop"], dict) else {}  # a malformed mark goes too
            if c.get("modified") and isinstance(c.get("changes"), int):
                # the game stays changed: a later coop start on it says so again
                record["coopChanges"] = c["changes"]
            path = _write_record(record)
    except OSError as e:
        raise ToolError("coop end: could not change the launch record %s: %s" % (launched_path(), e))
    out = {"ok": True, "ended": rec["coop"], "launchedFile": path}
    if summary:
        out["coop"] = summary
    return out


def coop_note_change():
    """After the mod took a coop client's command that changes a person's game: "modified" and the count in the
    coop mark. Advisory: a failure only warns."""
    try:
        with launched_lock():
            rec, _ = read_launched()
            c = rec.get("coop") if rec else None
            if not isinstance(c, dict):
                return
            c["modified"] = True
            c["changes"] = (c.get("changes") if isinstance(c.get("changes"), int) else 0) + 1
            if rec["owner"] is None:
                rec = {k: v for k, v in rec.items() if k != "owner"}
            _write_record(rec)
    except OSError as e:
        print("warning: could not count the change in the coop mark: %s" % e, file=sys.stderr)


def coop_note():
    """For status: {"coop": one line of the running game's coop mark} while there is one, else {}. Never raises."""
    try:
        rec, _ = read_launched()
        summary = coop_summary(rec, game_pids()) if rec else None
        return {"coop": summary} if summary else {}
    except Exception:
        return {}


def cmd_coop(ns):
    if not CONFIG["coop"]:
        raise config_needed("coop", "coop")
    if ns.coop_action == "start":
        return coop_start(ns.minutes, ns.reason)
    return coop_end()


def launched_pid():
    """The pid to record: the game's process (game_pids); with several, the one started last (the one just
    launched)."""
    pids = game_pids()
    if len(pids) <= 1:
        return pids[0] if pids else None
    return max(pids, key=lambda p: (process_start(p) or 0, p))


def quit_game(timeout=QUIT_TIMEOUT_SEC, kill=False, force=False):
    res = _quit_game(timeout, kill, force)
    gone = remove_launched()  # only reached with the game seen stopped
    if gone:
        res["launchedFile"] = gone
    return res


def _quit_game(timeout=QUIT_TIMEOUT_SEC, kill=False, force=False):
    """app.quit through the probe; with kill, SIGKILL when that fails or the game is still there after timeout.
    SIGTERM is no use: the game only opens its quit menu ("Quit requested", 2026-11-16). SIGKILL loses what is
    not saved, so it is refused while another client used the game recently, unless force."""
    asked = set(game_pids())  # SIGKILL goes only to these: the game the quit was checked and sent for
    if not asked:
        return {"ok": True, "how": "not running"}
    err = None
    try:
        res = send("quit", timeout=20)
        if not res.get("ok"):
            err = res.get("error") or "the mod refused"
    except OwnerRefused:
        raise  # not this owner's game: never on to --kill
    except ToolError as e:  # GameNotReady too: loading, a menu without the probe, no hello at all
        err = str(e)
    if err is None and wait_exit(timeout):
        return {"ok": True, "how": "quit"}
    why = err or f"it is still running {timeout:g} s after app.quit"
    if not kill:
        raise ToolError(f"the game did not quit: {why} (--kill ends it with SIGKILL; an unsaved game is lost)")
    # an upload to mod.io may be under way (the mod refuses a quit while it is Publishing; a mark is there from the
    # moment the tool sent one): a SIGKILL in the middle of it leaves mod.io in a state nobody knows. Not even
    # --force kills then; a person decides, after looking at mod.io.
    mark = read_pending()
    if mark is not None or (err and "Publishing" in err):
        raise ToolError("the game did not quit (%s), and an upload to mod.io %s: not killed, not even with --force. "
                        "Let the game finish it (modhub status), look at mod.io, then `modhub publish-clear`"
                        % (why, "may be under way (publish mark %s)" % pending_path() if mark is not None
                           else "is under way"))
    other = recent_other_owner()
    if other and not force:
        raise ToolError("the game did not quit (%s), and %s sent '%s' %d min ago: ask that client before killing "
                        "the game (--force kills it anyway)" % (why, other.get("owner") or "someone without --owner",
                                                                 other.get("cmd"),
                                                                 (time.time() - float(other["time"])) // 60))
    refused = []
    for pid in [p for p in game_pids() if p in asked]:  # not a game somebody started meanwhile
        try:
            os.kill(pid, getattr(signal, "SIGKILL", signal.SIGTERM))  # Windows: SIGTERM is TerminateProcess
        except OSError as e:  # gone already; on Windows a process that is exiting refuses with access denied
            refused.append(e)  # wait_exit decides; kept to say why, should the game stay
    if not wait_exit(15):
        raise ToolError("the game is still running after SIGKILL"
                        + "".join("; kill refused: %s" % e for e in refused))
    return {"ok": True, "how": "kill", "quitProblem": err}


def newest_hello():
    """(folder, path, mtime) of the newest hello in any exchange folder, or None."""
    best = None
    for root in userdata_roots():
        for d in DIRS:
            folder = os.path.join(root, d)
            for path in hello_files(folder)[:1]:
                t = mtime(path)
                if t is not None and (best is None or t > best[2]):
                    best = (folder, path, t)
    env = os.environ.get("TF3_REMOTE_DIR")
    if env:
        hs = hello_files(env)
        best = (env, hs[0], mtime(hs[0])) if hs and mtime(hs[0]) is not None else None
    return best


# The game rewrites crash_dump/stdout.txt at every start, so the last run's log (a crash, a kill, a quit) is gone
# once the game is started again (2026-11-17: logs of a menu UI reload and of a killed game were lost that way).
# launch / restart keep a copy first, named by the log's own time, in crash_dump/logs; the newest LOG_KEEP stay.
LOG_KEEP = 20
KEPT_LOG_PREFIX = "stdout-"


def game_log_path():
    """The game's stdout.txt: TF3_LOG, the exchange folder's, or the first userdata folder that has one."""
    env = os.environ.get("TF3_LOG")
    if env:
        return env
    try:
        return stdout_log(exchange_dir())
    except ToolError:
        pass
    for root in userdata_roots():
        path = os.path.join(root, "crash_dump", "stdout.txt")
        if os.path.exists(path):
            return path
    return None


def keep_last_log(path=None, keep=LOG_KEEP):
    """Copies the game log aside before a start would overwrite it. Returns the copy's path, None when there is
    no log (or it is empty), and never raises: keeping the log must not stop a launch."""
    try:
        path = path or game_log_path()
        if not path or os.path.getsize(path) == 0:
            return None
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(os.path.getmtime(path)))
        folder = os.path.join(os.path.dirname(path), "logs")
        os.makedirs(folder, exist_ok=True)
        dest = os.path.join(folder, KEPT_LOG_PREFIX + stamp + ".txt")
        if not os.path.exists(dest):  # the same run's log, kept already (launch after a restart's quit)
            shutil.copy2(path, dest)
        kept = sorted(glob.glob(os.path.join(folder, KEPT_LOG_PREFIX + "*.txt")))
        for old in kept[:-keep] if keep > 0 else []:
            try:
                os.remove(old)
            except OSError:
                pass
        return dest
    except Exception as e:  # anything: keeping the log must never stop a launch
        print(f"warning: could not keep the last game log: {e}", file=sys.stderr)
        return None


# --lang: the game takes its language only from profile.lua (language = { code = "ja", ...}), read at startup; no
# command-line option for it was found in the binary (2026-11-20). So launch / restart change that one value for the
# start, keep the original next to the file, and put its code back once the game is gone: after quit, before the next
# launch / restart (a crashed game leaves the backup behind), or by restore-profile. Never while the game runs: it
# rewrites profile.lua itself, which is also why only the code goes back, not the whole backup.
LANG_RE = re.compile(r"^[a-z]{2}(_[A-Z]{2})?$")  # de, ja; the base also has pt_BR, zh_CN, zh_TW
LANGUAGE_LINE_RE = re.compile(rb"^[ \t]*language[ \t]*=[ \t]*\{", re.M)
LANGUAGE_CODE_RE = re.compile(rb'\bcode[ \t]*=[ \t]*"([^"]*)"')
PROFILE_BACKUP_SUFFIX = ".tf3ctl-backup"
PROFILE_LOCK_SUFFIX = ".tf3ctl-lock"
# the base game's languages (base/strings, 2026-11-20), for when the install is not found
BASE_LANGUAGES = ("de", "en", "es", "fr", "it", "ja", "ko", "nl", "pl", "pt_BR", "ru", "zh_CN", "zh_TW")
_warned = {"install": False}
_profile_lock_depth = [0]


def profile_path():
    """The game's profile.lua: TF3_PROFILE, the one next to the exchange folder, or the newest in Steam's userdata
    (None if there is none)."""
    env = os.environ.get("TF3_PROFILE")
    if env:
        return env
    try:
        path = os.path.join(os.path.dirname(exchange_dir()), "profile.lua")
        if os.path.exists(path):
            return path
    except ToolError:
        pass
    found = [(t, p) for t, p in ((mtime(p), p) for p in (os.path.join(r, "profile.lua") for r in userdata_roots()))
             if t is not None]
    return max(found)[1] if found else None


def profile_backup_path(profile):
    return profile + PROFILE_BACKUP_SUFFIX


def language_code_span(data, path="profile.lua"):
    """(start, end) of the code's value in data, inside its one 'language = {' block (up to the first '}'). Anything
    else is refused, so a file of another shape is never half changed."""
    starts = [m.end() for m in LANGUAGE_LINE_RE.finditer(data)]
    if len(starts) != 1:
        raise ToolError("expected one 'language = {' line in %s, found %d" % (path, len(starts)))
    end = data.find(b"}", starts[0])
    m = LANGUAGE_CODE_RE.search(data, starts[0], end if end >= 0 else len(data))
    if not m:
        raise ToolError("no code = \"..\" in the language block of %s" % path)
    return m.start(1), m.end(1)


def profile_language(path):
    with open(path, "rb") as f:
        data = f.read()
    s, e = language_code_span(data, path)
    return data[s:e].decode("utf-8", "replace")


def game_languages():
    """The base game's languages (folders of base/strings), or None when the install is not found."""
    dirs = [os.environ["TF3_GAME_DIR"]] if os.environ.get("TF3_GAME_DIR") else [
        os.path.join(os.path.normpath(os.path.join(r, "../../../..")), "steamapps", "common", "Transport Fever 3")
        for r in userdata_roots()]  # <steam>/userdata/<id>/<app>/local -> <steam>/steamapps/common/...
    for d in dirs:
        folder = os.path.join(d, "base", "strings")
        if os.path.isdir(folder):
            return sorted(n for n in os.listdir(folder) if os.path.isdir(os.path.join(folder, n)))
    return None


def check_lang(lang):
    if not LANG_RE.fullmatch(lang or ""):  # fullmatch: "de\n" would end up inside the Lua string
        raise ToolError("--lang takes a language code like de, en, ja (or pt_BR): %r" % lang)
    langs = game_languages()
    if langs is None:
        # without the install, the base's own list: the engine asserts that the profile's language exists
        # (m_languageRep->Exists), so a code it lacks would crash the start, not fall back
        if not _warned["install"]:  # restart checks before and after the quit: say it once
            _warned["install"] = True
            print("warning: the game's install was not found (TF3_GAME_DIR names it): --lang %s is checked against "
                  "the base game's languages only" % lang, file=sys.stderr)
        if lang not in BASE_LANGUAGES:
            raise ToolError("the base game has no language %r (it has %s; TF3_GAME_DIR names the install)"
                            % (lang, ", ".join(BASE_LANGUAGES)))
        return
    if lang not in langs:
        raise ToolError("the game has no language %r (base/strings has %s; TF3_GAME_DIR names the install)"
                        % (lang, ", ".join(langs)))


def backup_is_there(path):
    """A file counts while it exists; a folder only while it holds a file (shot_settings.sh keeps its folder after
    putting its copies back, so the folder alone would block every --lang)."""
    path = os.path.expanduser(path)
    if not os.path.isdir(path):
        return os.path.exists(path)
    return any(files for _, _, files in os.walk(path))


def other_backups():
    """Backups of profile.lua by other tools (TF3CTL_OTHER_BACKUPS) that exist now."""
    paths = [p for p in os.environ.get("TF3CTL_OTHER_BACKUPS", "").split(os.pathsep) if p]
    return [p for p in paths if backup_is_there(p)]


def refuse_other_backups(what):
    # a full copy taken by another tool around ours would, put back in the wrong order, leave the wrong language
    others = other_backups()
    if others:
        raise ToolError("%s: another tool's backup of the settings is there (%s); put that back first"
                        % (what, ", ".join(others)))


def _remove_quietly(path):
    with contextlib.suppress(OSError):
        os.remove(path)


def write_replacing(path, data):
    """Writes data to path through a file next to it, so the game never finds a half-written profile. The file is
    synced before the rename (a power cut must not leave an empty profile.lua) and removed if anything fails, Ctrl-C
    too, so no *.tf3ctl-tmp is left beside the player's files."""
    tmp = path + ".tf3ctl-tmp"
    try:
        with open(tmp, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        shutil.copymode(path, tmp)
        replace_file(tmp, path)
    except BaseException:
        _remove_quietly(tmp)
        raise


def copy_backup(profile, backup):
    """The original as the backup, through a file beside it and compared: a half-written backup would later give
    back a wrong code. The temporary file goes on any failure."""
    tmp = backup + ".tmp"
    try:
        shutil.copy2(profile, tmp)
        with open(tmp, "rb") as f:
            os.fsync(f.fileno())
        if not filecmp.cmp(profile, tmp, shallow=False):
            raise ToolError("--lang: the backup of %s did not come out equal to it" % profile)
        replace_file(tmp, backup)
    except BaseException:
        _remove_quietly(tmp)
        raise


@contextlib.contextmanager
def profile_lock(profile):
    """Serialises tf3ctl processes over the profile (backup, change, restore): two at once could each find no backup
    and the second take the first one's changed file as the original. Re-entrant within one process, since flock
    on a second descriptor of the same file would wait for ourselves."""
    if _profile_lock_depth[0]:
        _profile_lock_depth[0] += 1
        try:
            yield
        finally:
            _profile_lock_depth[0] -= 1
        return
    with open(profile + PROFILE_LOCK_SUFFIX, "a") as f, lock_file(f):
        _profile_lock_depth[0] = 1
        try:
            yield
        finally:
            _profile_lock_depth[0] = 0


def set_profile_language(lang, profile=None):
    """--lang: backs profile.lua up (unless tf3ctl's backup is there already: the first one holds the original) and
    sets the language code."""
    check_lang(lang)
    profile = profile or profile_path()
    if not profile or not os.path.exists(profile):
        raise ToolError("--lang: no profile.lua found (TF3_PROFILE names it)")
    with profile_lock(profile):
        if game_pids():
            raise ToolError("--lang: the game is running and rewrites profile.lua itself: quit it first")
        refuse_other_backups("--lang")
        with open(profile, "rb") as f:
            data = f.read()
        s, e = language_code_span(data, profile)  # before the backup: a file of another shape is left alone
        was = data[s:e].decode("utf-8", "replace")
        backup = profile_backup_path(profile)
        out = {"language": lang, "was": was, "profile": profile}
        if was == lang and not os.path.exists(backup):
            out["changed"] = False
            return out
        if not os.path.exists(backup):
            copy_backup(profile, backup)
        write_replacing(profile, data[:s] + lang.encode() + data[e:])
        out.update(changed=True, backup=backup)
        return out


def backup_language(backup):
    """The original code kept in tf3ctl's backup; ToolError when the backup is not of the one-block shape."""
    with open(backup, "rb") as f:
        data = f.read()
    s, e = language_code_span(data, backup)
    return data[s:e]


def restore_profile(profile=None):
    """Puts the original language code from tf3ctl's backup back into profile.lua and removes the backup once the
    file has that code. Only the code: the game rewrites profile.lua while it runs, and a backup left for days (a
    crash, a quit by hand) would otherwise take the player's later changes with it. None when there is no backup;
    ToolError (the backup kept) while the game runs, when either file is not of the one-block shape, or when the
    file does not come out with the code."""
    profile = profile or profile_path()
    if not profile:
        return None
    backup = profile_backup_path(profile)
    if not os.path.exists(backup):
        return None  # before the lock: without a backup there is nothing to serialise, and no lock file is made
    with profile_lock(profile):
        if not os.path.exists(backup):
            return None  # another tf3ctl put it back while we waited
        if game_pids():
            raise ToolError("the game is running and rewrites profile.lua itself: the backup %s stays until it is "
                            "gone" % backup)
        refuse_other_backups("restoring " + profile)
        code = backup_language(backup)
        with open(profile, "rb") as f:
            data = f.read()
        s, e = language_code_span(data, profile)
        if data[s:e] != code:
            write_replacing(profile, data[:s] + code + data[e:])
        try:
            now = profile_language(profile).encode("utf-8")
        except ToolError:
            now = None
        if now != code:
            raise ToolError("%s does not have the language %r of its backup %s after putting it back: the backup is "
                            "kept" % (profile, code.decode("utf-8", "replace"), backup))
        os.remove(backup)
        return {"restored": profile, "language": code.decode("utf-8", "replace")}


def check_profile_start(lang):
    """What restore_profile / set_profile_language would refuse for this start, checked before restart quits the
    game: a refusal after the quit would leave the player's game stopped and not started again."""
    if lang is not None:
        check_lang(lang)
    profile = profile_path()
    backup = profile and profile_backup_path(profile)
    has_backup = bool(backup and os.path.exists(backup))
    if lang is None and not has_backup:
        return
    refuse_other_backups("--lang" if lang is not None else "restoring " + profile)
    if not profile or not os.path.exists(profile):
        raise ToolError("%s: no profile.lua found (TF3_PROFILE names it)"
                        % ("--lang" if lang is not None else "restoring tf3ctl's backup " + backup))
    with open(profile, "rb") as f:
        language_code_span(f.read(), profile)
    if has_backup:
        backup_language(backup)


def profile_note():
    """For state / status: tf3ctl's backup of profile.lua while one is there (the language is then not the
    player's own), else {}. Never raises."""
    try:
        profile = profile_path()
        backup = profile and profile_backup_path(profile)
        if not backup or not os.path.exists(backup):
            return {}
        note = {"backup": backup, "profile": profile,
                "note": "--lang changed the language; quit, the next launch / restart or restore-profile puts it back"}
        for key, path in (("language", profile), ("originalLanguage", backup)):
            try:
                note[key] = profile_language(path)
            except (OSError, ToolError):
                pass
        return {"profileBackup": note}
    except Exception:
        return {}


def steam_command():
    """The command that starts Steam, as a list: TF3_STEAM when it names a file, as one argument (it may hold
    spaces: C:\\Program Files (x86)\\Steam\\steam.exe), else TF3_STEAM split on spaces (flatpak run ...). Without
    it: steam, or on Windows the registry's SteamExe (then <ProgramFiles(x86)>\\Steam\\steam.exe)."""
    env = os.environ.get("TF3_STEAM")
    if env and env.strip():
        if os.path.isfile(env):
            return [env]
        if on_windows():  # posix=False keeps the backslashes; the quotes around a part are taken off
            return [p[1:-1] if len(p) >= 2 and p[0] == p[-1] == '"' else p for p in shlex.split(env, posix=False)]
        return env.split()
    if on_windows():
        exe = windows_steam_registry().get("SteamExe")
        if exe:
            return [exe]
        for d in windows_steam_dirs():
            if os.path.isfile(os.path.join(d, "steam.exe")):
                return [os.path.join(d, "steam.exe")]
    return ["steam"]


def launch_game(timeout=LAUNCH_TIMEOUT_SEC):
    """Starts the game through Steam with startup.lua, and waits until the probe answers in the main menu."""
    if game_pids():
        raise ToolError("the game is already running: use restart (or quit first)")
    remove_launched()  # a record of a game that is gone now (quit by hand, crashed)
    kept = keep_last_log()
    started = time.time()
    steam = steam_command()
    try:
        subprocess.Popen(steam + ["-applaunch", APP_ID, "--script", STARTUP_SCRIPT], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError as e:
        raise ToolError(f"cannot run {steam[0]}: {e} (TF3_STEAM names another command)")
    print("launching ...", file=sys.stderr)
    deadline = started + timeout
    hello = folder = None
    seen = False  # the game's process appeared
    while time.time() < deadline:
        got = newest_hello()
        if got and got[2] >= started - 1:
            h = try_read(got[1])
            if isinstance(h, dict) and h.get("menu"):
                folder, hello = got[0], h
                break
        # Steam may take a while (starting itself, shader processing): give up only when the game came and went,
        # or never came
        running = bool(game_pids())
        seen = seen or running
        if (seen and not running) or (not seen and time.time() - started > LAUNCH_NO_PROCESS_SEC):
            remove_launched()  # no game left to have a record of
            st = game_state()
            raise GameNotReady(("the game ended during startup: " if seen else "no game process %d s after the "
                                "launch (a dialog in Steam?): " % LAUNCH_NO_PROCESS_SEC) + st["text"]
                               + " (look at `log`)", st)
        time.sleep(0.5)
    if hello is None:
        raise ToolError(f"no main-menu hello from the probe {timeout:g} s after the launch (look at `log --grep "
                        "remote_probe`)")
    # the probe starts with the menu's first frame: give the menu itself time to be ready before loading
    while time.time() < deadline:
        st = game_state(folder)
        age = st.get("sinceAge")
        if st["state"] == "main_menu" and age is not None and age <= time.time() - started + 2:
            break
        time.sleep(0.5)
    time.sleep(2)
    return {"ok": True, "menu": True, "seconds": round(time.time() - started, 1), "hello": hello, "keptLog": kept}


def start_args(ns):
    """What launch / restart do in the main menu: (cmd, args) for --load or --new, or None."""
    if ns.load and ns.new:
        raise ToolError("give --load or --new, not both")
    if getattr(ns, "editor", False) and not ns.new:
        raise ToolError("--editor goes with --new (the map editor starts as a new map)")
    if ns.load:
        return "load", load_args(argparse.Namespace(save=ns.load, set_mods=ns.set_mods, add=ns.add,
                                                    remove=ns.remove, param=ns.param, dry_run=False,
                                                    wait_for_start=ns.wait_for_start))
    if ns.new:
        return "newgame", newgame_args(argparse.Namespace(
            climate=ns.climate, generator=ns.generator, size=ns.size, year=ns.year, seed=ns.seed,
            no_towns=ns.no_towns, no_industries=ns.no_industries, list=False, set_mods=ns.set_mods,
            add=ns.add, remove=ns.remove, param=ns.param, dry_run=False, tutorial=getattr(ns, "tutorial", False),
            editor=getattr(ns, "editor", False)))
    return None


def cmd_start(ns, restart):
    plan = start_args(ns)  # refused before anything is quit
    coop = getattr(ns, "coop", False)
    if coop and not CONFIG["coop"]:
        raise config_needed("launch --coop", "coop")
    if coop and not OWNER:
        raise ToolError("launch --coop needs --owner (the client that shares the game with the user)")
    if coop:
        coop_args(ns.minutes, ns.reason)  # before anything is started
    if plan and not OWNER and not OTHER_OWNER_OK and CONFIG["ownerCheck"]:
        # without an owner there is no launch record, so the --load / --new after the launch would be refused
        raise OwnerRefused("refused '%s --%s', nothing started: give --owner, so that the %s after the launch goes "
                           "to the game this owner started" % ("restart" if restart else "launch",
                                                               "load" if plan[0] == "load" else "new", plan[0]))
    lang = getattr(ns, "lang", None)
    check_profile_start(lang)  # --lang '' too; before anything is quit
    out = {"ok": True}
    if restart:
        out["quit"] = quit_game(ns.quit_timeout, kill=not ns.no_kill, force=ns.force)
        if out["quit"]["how"] != "not running":
            time.sleep(RELAUNCH_PAUSE_SEC)
    elif game_pids():  # before profile.lua is touched
        raise ToolError("the game is already running: use restart (or quit first)")
    # an earlier --lang start that crashed or was quit by hand left its backup: this start is in the player's
    # language unless --lang says otherwise
    try:
        profile = profile_path()
        # put back and changed under one lock; without --lang or a backup nothing is touched, not even the lock file
        touch = profile and (lang is not None or os.path.exists(profile_backup_path(profile)))
        with profile_lock(profile) if touch else contextlib.nullcontext():
            restored = restore_profile(profile)
            if restored:
                out["profileRestored"] = restored
            if lang is not None:
                out["language"] = set_profile_language(lang, profile)
    except (ToolError, OSError, KeyboardInterrupt) as e:
        if not restart:
            if isinstance(e, OSError):  # nothing was quit: the plain refusal, not a traceback
                raise ToolError("--lang: " + str(e))
            raise
        # the game is stopped now: a bare exit 2 (or 130 for Ctrl-C) would hide that, so show the quit and why it
        # was not started again, as quit does
        why = str(e) or "interrupted"
        print("error: %s, but %s" % ("the game quit" if out["quit"]["how"] != "not running" else
                                     "the game was not running", why), file=sys.stderr)
        out.update(ok=False, profileError=why)
        return out
    out["launch"] = launch_game(ns.launch_timeout)
    # the probe answered in the main menu: this owner started the game (cmd is "launch" for restart too)
    out["launchedFile"] = write_launched(launched_pid())
    if plan and not out["launchedFile"].get("written") and not OTHER_OWNER_OK and CONFIG["ownerCheck"]:
        # the record says the game is this owner's; without it the load / newgame would be refused anyway
        out.update(ok=False, error="the game started, but the launch record was not written (%s): the %s was not "
                   "sent" % (out["launchedFile"].get("warning") or out["launchedFile"].get("why"), plan[0]))
        print("error: " + out["error"], file=sys.stderr)
        return out
    if plan:
        res = replace_game(plan[0], plan[1], False, ns.timeout,
                           company_init=not getattr(ns, "no_company_init", False))
        out[plan[0]] = res
        out["ok"] = bool(res.get("ok"))
        if res.get("note"):
            out["note"] = res["note"]
    if coop and out["ok"] and out["launchedFile"].get("written"):
        # after the load: coop itself refuses a load
        out["coop"] = coop_start(ns.minutes, ns.reason)["coop"]
    elif coop:
        out["coopNote"] = "coop was not started (the start or the load failed, or no launch record)"
    return out


FREECAM_OPTS = (("free", "--free"), ("eye", "--eye"), ("look", "--look"), ("method", "--method"),
                ("via", "--via"), ("mouse", "--mouse"))


def camera_args(ns):
    """--set / --entity / --focus (+ --distance) as the mod's camera args; none = only read. The free camera
    options (--free, --eye + --look, --method, --via, --mouse) go alone; the mod checks the values."""
    given = [x for x in (ns.set, ns.entity, ns.focus) if x is not None]
    if len(given) > 1:
        raise ToolError("give one of --set, --entity or --focus")
    free = {key: getattr(ns, key, None) for key, _ in FREECAM_OPTS if getattr(ns, key, None) is not None}
    if free:
        if given or ns.distance is not None:
            raise ToolError("--free, --eye, --look, --method, --via and --mouse do not go with --set, --entity, "
                            "--focus or --distance")
        if ("eye" in free) != ("look" in free):
            raise ToolError("give --eye and --look together")
        if "via" in free and "free" not in free:
            raise ToolError("--via goes with --free")
        if "method" in free and "eye" not in free:
            raise ToolError("--method goes with --eye and --look")
        if free.get("free") == "off" and "eye" in free:
            raise ToolError("--eye and --look do not go with --free off")
        for key in ("eye", "look"):
            if key in free:
                parts = free[key].split(",")
                try:
                    nums = [float(x) for x in parts]
                except ValueError:
                    nums = None
                if nums is None or len(nums) != 3 or any(n != n or n in (float("inf"), float("-inf")) for n in nums):
                    raise ToolError(f"--{key}: give X,Y,Z (three numbers, metres)")
        return free
    if ns.distance is not None and ns.focus is None:
        raise ToolError("--distance goes with --focus (with --set it is the third number)")
    if ns.set is not None:
        return {"set": ns.set}
    if ns.entity is not None:
        return {"entity": ns.entity}
    if ns.focus is not None:
        args = {"focus": ns.focus}
        if ns.distance is not None:
            args["distance"] = ns.distance
        return args
    return {}


BUILD_MENUS = ("road", "rail", "water", "air", "landscaping", "town", "industry", "roads", "tracks", "warehouses")


def build_tool_args(ns):
    if ns.close:
        return {"close": True}
    if not ns.res and not ns.menu:
        raise ToolError("give --res <resName> and/or --menu (or --close)")
    args = {"res": ns.res, "seconds": ns.seconds} if ns.res else {}
    if ns.menu:
        args["menu"] = ns.menu
    if ns.template is not None:
        args["template"] = ns.template
    return args


def event_args(ns):
    args = {"name": ns.name}
    if ns.param is not None:
        try:
            param = json.loads(ns.param)
        except ValueError as e:
            raise ToolError(f"--param must be a JSON object: {e}")
        if not isinstance(param, dict):
            raise ToolError("--param must be a JSON object, e.g. '{\"welcome\": true}'")
        args["param"] = param
    return args


def script_event_args(ns):
    """A game script event: the event's args plus the id the script listens to."""
    if not ns.id:
        raise ToolError("--id is needed: the id the game script listens to (e.g. the mod's UI id)")
    args = event_args(ns)
    args["id"] = ns.id
    return args


def rename_args(ns):
    """A rename: the entity's id and the new name, checked here as the mod checks them."""
    if ns.entity < 0:
        raise ToolError("--entity must be an id (0 or more)")
    if not ns.name.strip():
        raise ToolError("the new name must not be empty")
    return {"entity": ns.entity, "name": ns.name}


def stock_args(ns):
    """stock list / stock set: checked here as the mod checks them (the stock itself is checked in the game)."""
    if ns.entity < 0:
        raise ToolError("--entity must be an id (0 or more)")
    if ns.action == "list":
        return {"entity": ns.entity}
    if ns.stock < -1:
        raise ToolError("--stock must be a stock's id (0, 1, ... as stock list shows them; -1 for a vehicle's load)")
    if not 0 <= ns.amount <= STOCK_MAX_AMOUNT:
        raise ToolError("--amount must be from 0 to %d" % STOCK_MAX_AMOUNT)
    args = {"entity": ns.entity, "stock": ns.stock, "amount": ns.amount}
    if ns.cargo is not None:
        if not ns.cargo or re.search(r"\s", ns.cargo):
            raise ToolError("--cargo must be a cargo type's name as stock list shows it (e.g. COAL)")
        args["cargo"] = ns.cargo
    elif ns.stock == -1:
        raise ToolError("--stock -1 (a vehicle's load) needs --cargo")
    if ns.dry_run:
        args["dryRun"] = True
    return args


def steps_args(ns):
    if not 1 <= ns.count <= STEPS_MAX:
        raise ToolError("the step count must be from 1 to %d" % STEPS_MAX)
    args = {"count": ns.count}
    if ns.dry_run:
        args["dryRun"] = True
    if getattr(ns, "allow_running", False):
        args["allowRunning"] = True
    return args


def steps_timeout(count):
    """How long tf3ctl waits for a steps answer: the mod's own wait for all the steps (core.stepsWaitSec) and room."""
    return max(STEPS_WAIT_MIN_SEC, count / 10000.0 * STEPS_WAIT_SEC_PER_10000) + STEPS_TIMEOUT_MARGIN_SEC


def build_args(ns):
    """build: one construction at --at (x,y[,z]), or --remove / --remove-all; checked here as the mod checks them."""
    if ns.remove is not None or ns.remove_all:
        if ns.res or ns.at or ns.params or ns.name or ns.angle is not None or ns.seed is not None or ns.dry_run \
                or getattr(ns, "no_owner", False) or getattr(ns, "no_fill_modules", False) \
                or getattr(ns, "remove_buildings", False) or getattr(ns, "join_streets", False) or getattr(ns, "engine_check", False) \
                or getattr(ns, "collision_detail", False):
            raise ToolError("--remove / --remove-all go alone")
        if ns.remove_all:
            if ns.remove is not None:
                raise ToolError("give --remove or --remove-all, not both")
            return {"removeAll": True}
        ids = []
        for part in ns.remove.split(","):
            part = part.strip()
            if not (part.isascii() and part.isdigit()):
                raise ToolError("--remove: not an entity id: %r" % part)
            ids.append(int(part))
        return {"remove": ids}
    if not ns.res or not ns.res.strip():
        raise ToolError("give --res (the construction's resName, e.g. some_mod::/path/thing.con)")
    if not ns.at:
        raise ToolError("give --at x,y[,z] (metres; for a negative x write --at=-100,50)")
    try:
        at = [float(x) for x in ns.at.split(",")]
    except ValueError:
        raise ToolError("--at must be numbers: x,y[,z]")
    if not 2 <= len(at) <= 3 or any(x != x or abs(x) == float("inf") for x in at):
        raise ToolError("--at must be x,y or x,y,z (finite numbers)")
    args = {"res": ns.res.strip(), "at": at}
    if ns.angle is not None:
        if ns.angle != ns.angle or abs(ns.angle) == float("inf"):
            raise ToolError("--angle must be a finite number of radians")
        args["angle"] = ns.angle
    if ns.params is not None:
        try:
            params = json.loads(ns.params)
        except ValueError as e:
            raise ToolError(f"--params must be a JSON object: {e}")
        if not isinstance(params, dict):
            raise ToolError("--params must be a JSON object, e.g. '{\"rbr_height\": 8}'")
        if "modules" in params:
            check_modules(params["modules"])
        args["params"] = params
    if ns.seed is not None:
        args["seed"] = ns.seed
    if ns.name is not None:
        if not ns.name.strip():
            raise ToolError("--name must not be empty")
        args["name"] = ns.name
    if ns.dry_run:
        args["dryRun"] = True
    if getattr(ns, "no_owner", False):
        args["noOwner"] = True
    if getattr(ns, "no_fill_modules", False):
        args["fillModules"] = False
    if getattr(ns, "remove_buildings", False):
        args["removeBuildings"] = True
    if getattr(ns, "join_streets", False):
        args["joinStreets"] = True
    if getattr(ns, "engine_check", False):
        if not ns.dry_run:
            raise ToolError("--engine-check goes with --dry-run only")
        args["engineCheck"] = True
    if ns.dry_run and (args.get("removeBuildings") or args.get("joinStreets")):
        # (the dry run asks the engine nothing: the Context's flags would be dropped unseen)
        raise ToolError("--remove-buildings and --join-streets go with a build, not with --dry-run")
    collision_detail_arg(ns, args)
    return args


def collision_detail_arg(ns, args):
    """--collision-detail (build, road): the engine's ProposalData copied out whole into the answer
    (collisionDetail). Only where the engine is asked: a build, or --dry-run with --engine-check."""
    if not getattr(ns, "collision_detail", False):
        return
    if args.get("dryRun") and not args.get("engineCheck"):
        raise ToolError("--collision-detail goes with a build or with --dry-run --engine-check (a dry run alone asks "
                        "the engine nothing)")
    args["collisionDetail"] = True


def check_modules(mods):
    """params.modules: {slot id: {name, variant?, metadata?, updateScript?}}. JSON keys are text: the mod makes
    them whole numbers (a module under a text key sits on no slot); here only the shape is checked."""
    if not isinstance(mods, dict):
        raise ToolError("params.modules must be a JSON object of slot id -> module, e.g. "
                        "'{\"modules\": {\"120001\": {\"name\": \"...module\"}}}'")
    if not mods:
        raise ToolError("params.modules is empty: give at least one module, or leave modules out")
    for k, m in mods.items():
        if not (k.isascii() and k.isdigit()):
            raise ToolError("params.modules: slot ids are whole numbers 0 or more, not %r" % k)
        if not isinstance(m, dict) or not isinstance(m.get("name"), str) or not m["name"].strip():
            raise ToolError("params.modules slot %s: give the module's name (its resName)" % k)
        v = m.get("variant", 0)
        if isinstance(v, bool) or not isinstance(v, int) or v < 0:
            raise ToolError("params.modules slot %s: variant must be a whole number 0 or more" % k)
        if "metadata" in m and not isinstance(m["metadata"], dict):
            raise ToolError("params.modules slot %s: metadata must be a JSON object" % k)
        us = m.get("updateScript")
        if "updateScript" in m and not (isinstance(us, dict) and isinstance(us.get("fileName"), str)
                                        and isinstance(us.get("params", {}), dict)):
            raise ToolError("params.modules slot %s: updateScript must be {\"fileName\": ..., \"params\": {...}}" % k)


def terrain_args(ns):
    """terrain: --rect x0,y0,x1,y1 and one of --flat Z, --slope-x PCT --base Z, --slope-y PCT --base Z (the mod
    checks all of it again, and the heights' range)."""
    def finite(x):
        return x == x and abs(x) != float("inf")
    try:
        rect = [float(x) for x in (ns.rect or "").split(",")]
    except ValueError:
        raise ToolError("--rect must be numbers: x0,y0,x1,y1")
    if len(rect) != 4 or not all(finite(x) for x in rect):
        raise ToolError("--rect must be x0,y0,x1,y1 (finite numbers)")
    x0, y0, x1, y1 = rect
    if not (x1 > x0 and y1 > y0):
        raise ToolError("--rect: x0 < x1 and y0 < y1")
    if x1 - x0 > TERRAIN_MAX_SIDE or y1 - y0 > TERRAIN_MAX_SIDE:
        raise ToolError("--rect: %g x %g m, at most %d m per side" % (x1 - x0, y1 - y0, TERRAIN_MAX_SIDE))
    given = [(k, v) for k, v in (("flat", ns.flat), ("slopeX", ns.slope_x), ("slopeY", ns.slope_y)) if v is not None]
    if len(given) != 1:
        raise ToolError("give one of --flat Z, --slope-x PCT or --slope-y PCT")
    mode, value = given[0]
    if not finite(value):
        raise ToolError("the height or percentage must be a finite number")
    args = {"rect": rect, mode: value}
    if mode == "flat":
        if ns.base is not None:
            raise ToolError("--flat is the height itself: no --base")
    else:
        if ns.base is None or not finite(ns.base):
            raise ToolError("--slope-x / --slope-y need --base (the height at the rectangle's x0 / y0 edge)")
        args["base"] = ns.base
    if ns.blend is not None:
        if not finite(ns.blend) or ns.blend < 0:
            raise ToolError("--blend must be metres >= 0")
        args["blend"] = ns.blend
    if ns.via:
        args["via"] = ns.via
    if getattr(ns, "in_game", False):
        args["inGame"] = True
    if ns.dry_run:
        args["dryRun"] = True
    return args


def town_args(ns):
    """town: --at x,y, --name, and --size, --capacity, --needs / --no-needs, --via, --in-game, --dry-run as given
    (the mod checks all of it again)."""
    if ns.at is None:
        raise ToolError("give --at x,y (metres)")
    try:
        at = [float(x) for x in (ns.at or "").split(",")]
    except ValueError:
        raise ToolError("--at must be numbers: x,y (for a negative x write --at=-100,50)")
    if len(at) != 2 or any(x != x or abs(x) == float("inf") for x in at):
        raise ToolError("--at must be x,y (finite numbers; for a negative x write --at=-100,50)")
    name = (ns.name or "").strip()
    if not name:
        raise ToolError("give --name (the town's name)")
    if len(name.encode("utf-8")) > TOWN_NAME_MAX:
        raise ToolError("--name: at most %d bytes" % TOWN_NAME_MAX)
    args = {"at": at, "name": name}
    if ns.size is not None:
        if ns.size != ns.size or not TOWN_SIZE[0] <= ns.size <= TOWN_SIZE[1]:
            raise ToolError("--size must be %g-%g (the size factor of each district; 1 as the base import)" % TOWN_SIZE)
        args["size"] = ns.size
    if ns.capacity is not None:
        if not 1 <= ns.capacity <= TOWN_MAX_CAPACITY:
            raise ToolError("--capacity must be 1-%d" % TOWN_MAX_CAPACITY)
        args["capacity"] = ns.capacity
    if ns.no_needs:
        if ns.needs is not None:
            raise ToolError("--needs or --no-needs, not both")
        args["needs"] = "none"
    elif ns.needs is not None:
        parts = [x.strip() for x in ns.needs.split(",")]
        for part in parts:
            lu, _, cat = part.partition(":")
            if lu.strip().lower() not in ("res", "com", "ind") or not re.fullmatch(r"\w+", cat.strip()):
                raise ToolError("--needs: land use:category, comma separated (com:fish,ind:planks); land use res, com "
                                "or ind")
        args["needs"] = ",".join(parts)
    if ns.via:
        args["via"] = ns.via
    if ns.in_game:
        args["inGame"] = True
    if ns.dry_run:
        args["dryRun"] = True
    return args


TOWN_PLAIN_OPTIONS = ("at", "name", "size", "capacity", "needs", "via")
TOWN_PLAIN_FLAGS = ("no_needs", "in_game", "dry_run")


def town_grow_args(ns):
    """town develop / town size: checked here as the mod checks them. -> (command, args). An option of the plain
    town given before the word (town --dry-run develop ...) would be dropped by argparse, so it is refused."""
    given = [o for o in TOWN_PLAIN_OPTIONS if getattr(ns, o, None) is not None]
    given += [o for o in TOWN_PLAIN_FLAGS if getattr(ns, o, False)]
    if given:
        raise ToolError("town %s: put its options after the word (%s given before it)"
                        % (ns.town_action, ", ".join("--" + o.replace("_", "-") for o in given)))
    if ns.town_action == "connections":
        args = {"entity": ns.conn_entity} if ns.conn_entity is not None else {}
        if ns.conn_index_base is not None:
            args["indexBase"] = ns.conn_index_base
        return "townConnections", args
    if ns.town_action == "connect":
        return town_connect_args(ns)
    if ns.town_action == "develop":
        try:
            at = [float(x) for x in ns.grow_at.split(",")]
        except ValueError:
            raise ToolError("--at must be numbers: x,y (for a negative x write --at=-100,50)")
        if len(at) != 2 or any(x != x or abs(x) == float("inf") for x in at):
            raise ToolError("--at must be x,y (finite numbers; for a negative x write --at=-100,50)")
        if not 1 <= ns.grow_count <= TOWN_DEVELOP_MAX:
            raise ToolError("--count must be 1-%d" % TOWN_DEVELOP_MAX)
        args = {"at": at, "count": ns.grow_count}
        if ns.grow_radius is not None:
            if ns.grow_radius != ns.grow_radius or not 0 < ns.grow_radius <= TOWN_GROW_RADIUS_MAX:
                raise ToolError("--radius must be above 0 and at most %g metres" % TOWN_GROW_RADIUS_MAX)
            args["radius"] = ns.grow_radius
        if ns.grow_streets:
            args["streets"] = True
        if ns.grow_upgrade:
            args["upgrade"] = True
        if ns.grow_dry_run:
            args["dryRun"] = True
        return "townDevelop", args
    if ns.grow_entity < 0:
        raise ToolError("--entity must be a town's id (entities --kind town)")
    try:
        f = [float(x) for x in ns.grow_factors.split(",")]
    except ValueError:
        raise ToolError("--factors must be numbers: residential,commercial,industrial")
    if len(f) != 3 or any(x != x or not 0 <= x <= TOWN_GROW_SIZE_MAX for x in f):
        raise ToolError("--factors must be 3 numbers, each 0-%g: residential,commercial,industrial" % TOWN_GROW_SIZE_MAX)
    args = {"entity": ns.grow_entity, "factors": f}
    if ns.grow_update_all:
        args["updateAll"] = True
    if ns.grow_dry_run:
        args["dryRun"] = True
    return "townSize", args


TOWN_CONNECT_TIMEOUT_SEC = 150  # the mod waits 120 s for the engine's callback (a street network to build)


def town_connect_args(ns):
    """town connect --auto | --build: checked here as the mod checks them. -> ("townConnect", args)"""
    if ns.conn_auto == ns.conn_build:
        raise ToolError("give --auto (detect the connections over the roads there are) or --build (streets)")
    args = {"auto": True} if ns.conn_auto else {"build": True}
    if ns.conn_entities is not None:
        try:
            ids = [int(x) for x in ns.conn_entities.split(",")]
        except ValueError:
            raise ToolError("--entity must be town ids separated by commas (entities --kind town)")
        if not ids or any(i < 0 for i in ids) or len(set(ids)) != len(ids):
            raise ToolError("--entity must be distinct town ids (0 or more)")
        args["entities"] = ids
    if ns.conn_auto and (ns.conn_pairs or ns.conn_default or ns.conn_no_keep):
        raise ToolError("--pairs, --default and --no-keep go with --build (--auto builds nothing)")
    if ns.conn_pairs:
        pairs = []
        for part in ns.conn_pairs.split(","):
            a, sep, b = part.partition(":")
            try:
                pair = [int(a), int(b)]
            except ValueError:
                raise ToolError("--pairs must be town:town,... (town ids, e.g. 801:802)")
            if not sep or pair[0] == pair[1] or min(pair) < 0:
                raise ToolError("--pairs must be town:town,... with two different towns (e.g. 801:802)")
            pairs.append(pair)
        args["pairs"] = pairs
    if ns.conn_default:
        args["default"] = True
    if ns.conn_no_keep:
        args["keep"] = False
    if ns.conn_index_base is not None:
        args["indexBase"] = ns.conn_index_base
    if ns.conn_dry_run:
        args["dryRun"] = True
    return "townConnect", args


def town_grow_timeout(cmd, args):
    """The mod sends a develop's commands one after another (a frame or two each) and waits 30 s for a missing
    callback: room for both."""
    if cmd == "townDevelop":
        return TOWN_GROW_TIMEOUT_SEC + args.get("count", 1) * TOWN_DEVELOP_SEC_EACH
    return TOWN_GROW_TIMEOUT_SEC


TOWN_DEVELOP_MAX = 200  # the mod's core.TOWN_DEVELOP_MAX
TOWN_GROW_RADIUS = 250  # core.TOWN_GROW_RADIUS
TOWN_GROW_RADIUS_MAX = 2000  # core.TOWN_GROW_RADIUS_MAX
TOWN_GROW_SIZE_MAX = 5  # core.TOWN_GROW_SIZE_MAX
TOWN_GROW_TIMEOUT_SEC = 60
TOWN_DEVELOP_SEC_EACH = 0.5
TOWN_NAME_MAX = 64  # the mod's core.TOWN_NAME_MAX
TOWN_SIZE = (0.1, 2.5)  # core.TOWN_SIZE
TOWN_MAX_CAPACITY = 1000  # core.TOWN_MAX_CAPACITY
TOWN_TIMEOUT_SEC = 120  # the mod waits 20 s for the recipe, 60 s for the create callback, 10 s for the needs


def water_args(ns):
    """water: --at x,y or --grid x0,y0,x1,y1,step (at most WATER_MAX_POINTS points; the mod checks again)."""
    def numbers(text, n, what):
        try:
            v = [float(x) for x in text.split(",")]
        except ValueError:
            raise ToolError("%s must be numbers: %s" % (what[0], what[1]))
        if len(v) != n or any(x != x or abs(x) == float("inf") for x in v):
            raise ToolError("%s must be %s (finite numbers)" % what)
        return v
    if (ns.at is None) == (ns.grid is None):
        raise ToolError("give --at x,y or --grid x0,y0,x1,y1,step")
    if ns.at is not None:
        return {"at": numbers(ns.at, 2, ("--at", "x,y"))}
    x0, y0, x1, y1, step = numbers(ns.grid, 5, ("--grid", "x0,y0,x1,y1,step"))
    if x1 < x0 or y1 < y0:
        raise ToolError("--grid: x0 <= x1 and y0 <= y1")
    if step < WATER_MIN_STEP:
        raise ToolError("--grid: step must be at least %g m" % WATER_MIN_STEP)
    nx, ny = math.floor((x1 - x0) / step + 1e-9) + 1, math.floor((y1 - y0) / step + 1e-9) + 1
    if nx * ny > WATER_MAX_POINTS:
        raise ToolError("--grid: %d x %d = %d points, at most %d (a larger step or a smaller box)"
                        % (nx, ny, nx * ny, WATER_MAX_POINTS))
    return {"grid": [x0, y0, x1, y1, step]}


def road_inspect_args(ns):
    """road --inspect-node ID (read only): the node alone; nothing else goes with it."""
    if ns.from_ is not None or ns.to is not None or ns.type is not None or ns.snap is not None or ns.dry_run \
            or ns.engine_check or ns.remove_fields or getattr(ns, "remove_buildings", False) \
            or getattr(ns, "ignore_errors", False) or getattr(ns, "bridge", None) is not None \
            or getattr(ns, "batch", None) is not None or getattr(ns, "collision_detail", False) \
            or getattr(ns, "from_node", None) is not None or getattr(ns, "to_node", None) is not None:
        raise ToolError("--inspect-node takes nothing else (no --from, --to, --from-node, --to-node, --type, --snap, --dry-run, "
                        "--engine-check, --remove-fields, --remove-buildings, --ignore-errors, --bridge, --batch, "
                        "--collision-detail)")
    if getattr(ns, "tangent_from", None) is not None or getattr(ns, "tangent_to", None) is not None \
            or getattr(ns, "align_to_edge", None) is not None or getattr(ns, "align_edge", None):
        raise ToolError("--inspect-node takes nothing else (no --tangent-from, --tangent-to, --align-to-edge, "
                        "--align-edge)")
    if ns.inspect_node < 0:
        raise ToolError("--inspect-node must be a node's entity id (0 or more)")
    return {"node": ns.inspect_node}


def lights_args(ns):
    """lights --node ID --off [--dry-run]: lightsOff's args (send checks the loaded save and coop: lights_check)."""
    if not ns.off:
        raise ToolError("lights needs --off (taking a junction's traffic light off is all it does; road "
                        "--inspect-node reads one)")
    if ns.node < 0:
        raise ToolError("--node must be a node's entity id (0 or more)")
    args = {"node": ns.node}
    if ns.dry_run:
        args["dryRun"] = True
    return args


def road_args(ns):
    """road: --from and --to as x,y[,z]; --type, --snap, --dry-run as given (the mod checks them again)."""
    args = {}
    node_ids = {}
    for key, flag in (("fromNode", "from_node"), ("toNode", "to_node")):
        v = getattr(ns, flag, None)
        if v is None:
            continue
        if isinstance(v, bool) or not isinstance(v, int) or v < 0:
            raise ToolError("--%s must be a node's entity id (0 or more)" % flag.replace("_", "-"))
        node_ids[key] = v
    if len(node_ids) == 2 and node_ids["fromNode"] == node_ids["toNode"]:
        raise ToolError("--from-node and --to-node are the same node %d: a piece needs two ends" % node_ids["fromNode"])
    for key, text in (("fromNode", ns.from_), ("toNode", ns.to)):
        if text is None and key not in node_ids:
            raise ToolError("road needs --from (or --from-node) and --to (or --to-node) (or --inspect-node ID alone)")
    for key, text in (("from", ns.from_), ("to", ns.to)):
        if text is None:
            continue  # the end is its node's (--from-node / --to-node)
        try:
            v = [float(x) for x in text.split(",")]
        except ValueError:
            raise ToolError("--%s must be numbers: x,y[,z]" % key)
        if not 2 <= len(v) <= 3 or any(x != x or abs(x) == float("inf") for x in v):
            raise ToolError("--%s must be x,y or x,y,z (finite numbers; for a negative x write --%s=-100,50)" % (key, key))
        args[key] = v
    args.update(node_ids)
    if ns.type is not None:
        if not ns.type.strip():
            raise ToolError("--type is empty")
        args["type"] = ns.type.strip()
    bridge = getattr(ns, "bridge", None)
    if bridge is not None:
        # (the mod looks the type up in bridgeTypeRep and refuses one it does not know: nothing sent)
        if not bridge.strip():
            raise ToolError("--bridge is empty")
        args["bridge"] = bridge.strip()
    if ns.snap is not None:
        if ns.snap != ns.snap or not 0 <= ns.snap <= ROAD_MAX_SNAP:
            raise ToolError("--snap must be 0-%g metres" % ROAD_MAX_SNAP)
        args["snap"] = ns.snap
    if ns.dry_run:
        args["dryRun"] = True
    if ns.engine_check:
        if not ns.dry_run:
            raise ToolError("--engine-check goes with --dry-run only")
        args["engineCheck"] = True
    if ns.remove_fields:
        args["removeFields"] = True
    if getattr(ns, "remove_buildings", False):
        args["removeBuildings"] = True
    if getattr(ns, "ignore_errors", False):
        # (send checks the loaded save and coop: ignore_errors_check)
        args["ignoreErrors"] = True
        if ns.dry_run:
            args["engineCheck"] = True  # a forced dry run asks the engine what it would have refused; builds nothing
    collision_detail_arg(ns, args)
    for key, text in (("tangentFrom", getattr(ns, "tangent_from", None)), ("tangentTo", getattr(ns, "tangent_to", None))):
        if text is None:
            continue
        flag = "--tangent-" + key[len("tangent"):].lower()
        try:
            v = [float(x) for x in text.split(",")]
        except ValueError:
            raise ToolError("%s must be numbers: dx,dy" % flag)
        if len(v) != 2 or any(x != x or abs(x) == float("inf") for x in v):
            raise ToolError("%s must be dx,dy (finite numbers; for a negative dx write %s=-1,0)" % (flag, flag))
        if max(abs(v[0]), abs(v[1])) < 1e-6:  # the mod's core.ROAD_MIN_DIR, on the larger part
            raise ToolError("%s: a direction of length 0 gives no way" % flag)
        args[key] = v
    align = getattr(ns, "align_to_edge", None)
    if align is not None:
        if align in ("from", "both") and "tangentFrom" in args:
            raise ToolError("--tangent-from and --align-to-edge %s both set the from end's way: give one" % align)
        if align in ("to", "both") and "tangentTo" in args:
            raise ToolError("--tangent-to and --align-to-edge %s both set the to end's way: give one" % align)
        args["alignToEdge"] = align
    if getattr(ns, "align_edge", None):
        if align is None:
            raise ToolError("--align-edge goes with --align-to-edge only")
        if len(ns.align_edge) > 2 or any(i < 0 for i in ns.align_edge):
            raise ToolError("--align-edge: at most two pieces' entity ids (one per end)")
        if len(ns.align_edge) == 2 and ns.align_edge[0] == ns.align_edge[1]:
            raise ToolError("--align-edge %d given twice: give it once" % ns.align_edge[0])
        args["alignEdge"] = list(ns.align_edge)
    return args


ROAD_MAX_SNAP = 20  # the mod's core.ROAD_LIMITS.snap
ROAD_BATCH_MAX = 16  # the mod's core.ROAD_BATCH_MAX
# a --batch piece's keys as road's flags spell them (and as the mod's args, which are read too) -> the mod's
ROAD_BATCH_KEYS = {"from": "from", "to": "to", "from-node": "fromNode", "to-node": "toNode", "type": "type",
                   "bridge": "bridge", "snap": "snap", "tangent-from": "tangentFrom", "tangent-to": "tangentTo",
                   "align-to-edge": "alignToEdge", "align-edge": "alignEdge"}
ROAD_BATCH_KEYS.update({v: v for v in list(ROAD_BATCH_KEYS.values())})


def read_batch_file(path):
    """A --batch FILE (road, track): its JSON, a key written twice in one object refused. Nothing is sent when the
    file does not read."""
    try:
        def once(pairs):
            # (a key written twice in one object: json would take the last one silently)
            seen = {}
            for k, v in pairs:
                if k in seen:
                    raise ToolError("--batch %s: %r written twice in one object (nothing sent)" % (path, k))
                seen[k] = v
            return seen
        with open(path, encoding="utf-8") as f:
            return json.load(f, object_pairs_hook=once)
    except OSError as e:
        raise ToolError("--batch %s: cannot read it: %s (nothing sent)" % (path, e))
    except ValueError as e:
        raise ToolError("--batch %s: not JSON: %s (nothing sent)" % (path, e))


def road_batch_piece(el, i):
    """road --batch: piece i of the file as road_args takes road's flags (from-node / to-node: an id or "@name")."""
    head = "--batch piece %d: " % i
    if not isinstance(el, dict):
        raise ToolError(head + "not a JSON object of from, to, ... (nothing sent)")
    piece = {}
    for k, v in el.items():
        key = ROAD_BATCH_KEYS.get(k)
        if key is None:
            raise ToolError(head + "unknown key %r (from, to, from-node, to-node, type, bridge, snap, tangent-from, "
                            "tangent-to, align-to-edge, align-edge; the whole proposal's --dry-run, --ignore-errors, "
                            "... go on the command line) (nothing sent)" % (k,))
        if key in piece:
            raise ToolError(head + "%s given twice (nothing sent)" % k)
        piece[key] = v
    # (each piece's own values the way road takes them from its flags: from road_args, so both say the same)
    flags = argparse.Namespace(
        from_=None, to=None, type=None, snap=None, dry_run=False, engine_check=False, remove_fields=False,
        remove_buildings=False, ignore_errors=False, bridge=None, tangent_from=None, tangent_to=None,
        align_to_edge=None, align_edge=None)
    def text(key, v):
        if isinstance(v, list) and all(isinstance(x, (int, float)) and not isinstance(x, bool) for x in v):
            return ",".join(repr(float(x)) for x in v)
        if isinstance(v, str):
            return v
        raise ToolError(head + "%s must be \"x,y[,z]\" or a list of numbers (nothing sent)" % key)
    for key, attr in (("from", "from_"), ("to", "to"), ("tangentFrom", "tangent_from"), ("tangentTo", "tangent_to")):
        if key in piece:
            setattr(flags, attr, text(key, piece[key]))
    for key, attr in (("type", "type"), ("bridge", "bridge"), ("alignToEdge", "align_to_edge")):
        if key in piece:
            if not isinstance(piece[key], str):
                raise ToolError(head + "%s must be a string (nothing sent)" % key)
            setattr(flags, attr, piece[key])
    if "snap" in piece:
        v = piece["snap"]
        if isinstance(v, bool) or not isinstance(v, (int, float)):
            raise ToolError(head + "snap must be a number of metres (nothing sent)")
        flags.snap = float(v)
    if "alignEdge" in piece:
        v = piece["alignEdge"]
        v = [v] if isinstance(v, int) and not isinstance(v, bool) else v
        if not isinstance(v, list) or not all(isinstance(x, int) and not isinstance(x, bool) for x in v):
            raise ToolError(head + "align-edge must be a piece's entity id or a list of them (nothing sent)")
        flags.align_edge = v
    if flags.align_to_edge is not None and flags.align_to_edge not in ("from", "to", "both"):
        raise ToolError(head + "align-to-edge must be from, to or both (nothing sent)")
    nodes = {}
    for key in ("fromNode", "toNode"):
        if key not in piece:
            continue
        v = piece[key]
        name = "from-node" if key == "fromNode" else "to-node"
        if isinstance(v, int) and not isinstance(v, bool):
            if v < 0:
                raise ToolError(head + "%s must be a node's entity id (0 or more) or \"@name\" (nothing sent)" % name)
            # with the end's point too: the piece's end is that point, joined to the node (the mod refuses
            # a point more than core.ROAD_END_OFFSET_MAX m from it). [guess] not checked in a game yet
        elif isinstance(v, str):
            if not re.match(r"^@[A-Za-z0-9_-]{1,32}$", v.strip()):
                raise ToolError(head + "%s %r: a new node's name is @ and up to 32 letters, digits, _ or - "
                                "(nothing sent)" % (name, v))
            v = v.strip()
        else:
            raise ToolError(head + "%s must be a node's entity id or \"@name\" (nothing sent)" % name)
        nodes[key] = v
    # road_args wants both ends as points: an end given by its node only is put in for the check and taken out
    for key, attr in (("fromNode", "from_"), ("toNode", "to")):
        if key in nodes and getattr(flags, attr) is None:
            setattr(flags, attr, "0,0")
    try:
        got = road_args(flags)
    except ToolError as e:
        raise ToolError(head + str(e) + " (nothing sent)")
    for key, end in (("fromNode", "from"), ("toNode", "to")):
        if key in nodes:
            if end not in piece:
                got.pop(end, None)
            got[key] = nodes[key]
    return got


def road_batch_args(ns):
    """road --batch FILE: the pieces of one proposal from a JSON list (each as road's flags, from-node / to-node
    besides), with the options that go for the whole proposal (--dry-run, --engine-check, --remove-fields,
    --remove-buildings, --ignore-errors, --collision-detail) beside them. Each piece is checked as road_args checks road's flags; the
    mod checks them all again (the named nodes' points among them). Nothing is sent when the file does not read."""
    for flag, v in (("--from", ns.from_), ("--to", ns.to), ("--from-node", getattr(ns, "from_node", None)),
                    ("--to-node", getattr(ns, "to_node", None)), ("--type", ns.type), ("--snap", ns.snap),
                    ("--bridge", getattr(ns, "bridge", None)), ("--tangent-from", getattr(ns, "tangent_from", None)),
                    ("--tangent-to", getattr(ns, "tangent_to", None)),
                    ("--align-to-edge", getattr(ns, "align_to_edge", None)),
                    ("--align-edge", getattr(ns, "align_edge", None) or None),
                    ("--inspect-node", getattr(ns, "inspect_node", None))):
        if v is not None:
            raise ToolError("--batch takes the pieces from its file: %s goes in each piece there (nothing sent)" % flag)
    pieces = read_batch_file(ns.batch)
    if not isinstance(pieces, list):
        raise ToolError("--batch: the file must hold a JSON list of pieces ([{\"from\": ..., \"to\": ...}, ...]); "
                        "nothing sent")
    if not pieces:
        raise ToolError("--batch: the list is empty: give at least one piece (nothing sent)")
    if len(pieces) > ROAD_BATCH_MAX:
        raise ToolError("--batch: %d pieces, at most %d in one proposal (nothing sent)" % (len(pieces), ROAD_BATCH_MAX))
    out = [road_batch_piece(el, i) for i, el in enumerate(pieces, 1)]
    # the whole proposal's options, as road's
    whole = argparse.Namespace(from_="0,0", to="0,0", type=None, snap=None, dry_run=ns.dry_run,
                               engine_check=ns.engine_check, remove_fields=ns.remove_fields,
                               remove_buildings=getattr(ns, "remove_buildings", False),
                               ignore_errors=getattr(ns, "ignore_errors", False),
                               collision_detail=getattr(ns, "collision_detail", False))
    args = road_args(whole)
    args.pop("from")
    args.pop("to")
    args["batch"] = out
    return args


TRACK_BATCH_MAX = 16  # the mod's core.TRACK_BATCH_MAX
# a track --batch piece's keys (road's spelling and the mod's): road's but bridge, snap and the alignment, and tunnel
TRACK_BATCH_KEYS = {"from", "to", "from-node", "to-node", "fromNode", "toNode", "type", "tunnel", "tangent-from",
                    "tangent-to", "tangentFrom", "tangentTo"}


def track_tunnel(v, head):
    """A tunnel type's name as given (the mod looks it up in tunnelTypeRep and refuses one that carries no rails)."""
    if not isinstance(v, str) or not v.strip():
        raise ToolError(head + "tunnel must be a tunnel type's resName or a base tunnel's file name (tunnel_a) "
                        "(nothing sent)")
    return v.strip()


def track_point_z(args, tunnel, head):
    """With a tunnel, an end given as a point must say its z: the terrain's height is no tunnel's."""
    if tunnel is None:
        return
    for key in ("from", "to"):
        if key in args and len(args[key]) < 3:
            raise ToolError(head + "--%s needs z with --tunnel (x,y,z: the piece's height under the ground) "
                            "(nothing sent)" % key)


def track_args(ns):
    """track: road's ends (--from / --to as x,y[,z], --from-node / --to-node, --tangent-from / --tangent-to) and
    --dry-run / --engine-check / --collision-detail, checked by road_args; --type required; --tunnel. No snap,
    bridge, alignment, fields, buildings or forced build (road's only). The mod checks them all again."""
    flags = argparse.Namespace(
        from_=ns.from_, to=ns.to, from_node=ns.from_node, to_node=ns.to_node, type=ns.type, snap=None,
        dry_run=ns.dry_run, engine_check=ns.engine_check, remove_fields=False, remove_buildings=False,
        ignore_errors=False, bridge=None, tangent_from=ns.tangent_from, tangent_to=ns.tangent_to,
        align_to_edge=None, align_edge=None, collision_detail=ns.collision_detail)
    if ns.type is None:
        raise ToolError("track needs --type: a track's street template (simple, standard, high_speed or a resName)")
    try:
        args = road_args(flags)
    except ToolError as e:
        raise ToolError(str(e).replace("road needs", "track needs").replace(" (or --inspect-node ID alone)", ""))
    if ns.from_node is not None and ns.from_ is not None or ns.to_node is not None and ns.to is not None:
        raise ToolError("track: an end at a node and at a point (road's shifted end) is road's only: give one")
    if ns.tunnel is not None:
        args["tunnel"] = track_tunnel(ns.tunnel, "")
        track_point_z(args, args["tunnel"], "")
    return args


def track_batch_args(ns):
    """track --batch FILE: the pieces of one proposal from a JSON list, each with track's values (from, to,
    from-node / to-node: an existing track node's id or "@name", type (required), tunnel, tangent-from,
    tangent-to); --dry-run, --engine-check and --collision-detail go for the whole proposal. Each piece is checked
    as road --batch checks its own; the mod checks them all again (a named node's z with a tunnel among them)."""
    for flag, v in (("--from", ns.from_), ("--to", ns.to), ("--from-node", ns.from_node), ("--to-node", ns.to_node),
                    ("--type", ns.type), ("--tunnel", ns.tunnel), ("--tangent-from", ns.tangent_from),
                    ("--tangent-to", ns.tangent_to)):
        if v is not None:
            raise ToolError("--batch takes the pieces from its file: %s goes in each piece there (nothing sent)" % flag)
    pieces = read_batch_file(ns.batch)
    if not isinstance(pieces, list):
        raise ToolError("--batch: the file must hold a JSON list of pieces ([{\"from\": ..., \"to\": ..., \"type\": "
                        "...}, ...]); nothing sent")
    if not pieces:
        raise ToolError("--batch: the list is empty: give at least one piece (nothing sent)")
    if len(pieces) > TRACK_BATCH_MAX:
        raise ToolError("--batch: %d pieces, at most %d in one proposal (nothing sent)" % (len(pieces), TRACK_BATCH_MAX))
    out = []
    for i, el in enumerate(pieces, 1):
        head = "--batch piece %d: " % i
        if not isinstance(el, dict):
            raise ToolError(head + "not a JSON object of from, to, type, ... (nothing sent)")
        for k in el:
            if k not in TRACK_BATCH_KEYS:
                raise ToolError(head + "unknown key %r (from, to, from-node, to-node, type, tunnel, tangent-from, "
                                "tangent-to; the whole proposal's --dry-run, --engine-check, --collision-detail go on "
                                "the command line; snap, bridge and the alignment are road's only) (nothing sent)" % (k,))
        if "type" not in el:
            raise ToolError(head + "give type: a track's street template (simple, standard, high_speed or a resName) "
                            "(nothing sent)")
        rest = {k: v for k, v in el.items() if k != "tunnel"}
        for a, b in (("from-node", "from"), ("fromNode", "from"), ("to-node", "to"), ("toNode", "to")):
            if a in el and b in el and not (isinstance(el[a], str)):
                raise ToolError(head + "%s with %s (road's shifted end) is road's only: give one (nothing sent)" % (a, b))
        try:
            got = road_batch_piece(rest, i)
        except ToolError as e:
            raise ToolError(str(e).replace("road needs", "track needs").replace(" (or --inspect-node ID alone)", ""))
        if "tunnel" in el:
            got["tunnel"] = track_tunnel(el["tunnel"], head)
            track_point_z({k: v for k, v in got.items() if k in ("from", "to") and k in el}, got["tunnel"], head)
        out.append(got)
    whole = argparse.Namespace(from_="0,0", to="0,0", type=None, snap=None, dry_run=ns.dry_run,
                               engine_check=ns.engine_check, remove_fields=False, remove_buildings=False,
                               ignore_errors=False, collision_detail=ns.collision_detail)
    args = road_args(whole)
    args.pop("from")
    args.pop("to")
    args["batch"] = out
    return args


TERRAIN_MAX_SIDE = 1024  # the mod's core.TERRAIN_MAX_SIDE (metres per side)
TERRAIN_TIMEOUT_SEC = 180  # the mod waits 120 s for the replacement's callback
WATER_MAX_POINTS = 400  # the mod's core.WATER_MAX_POINTS
WATER_MIN_STEP = 0.1  # core.WATER_MIN_STEP: a smaller step overflows the point count before the limit is checked
BUILD_TIMEOUT_SEC = 60  # the mod waits 30 s for the engine's callback
STOCK_TIMEOUT_SEC = 60  # stock set: the mod waits 30 s for the engine's callback
STEP_GAME_TIME = 200  # core.STEP_GAME_TIME: one step's game time (20 steps a day)
STEPS_WAIT_MIN_SEC = 30  # core.STEPS_WAIT_MIN_SEC / STEPS_WAIT_SEC_PER_10000: the mod's wait for all the steps
STEPS_WAIT_SEC_PER_10000 = 200
STEPS_TIMEOUT_MARGIN_SEC = 30  # over the mod's wait: picking the command up and writing the answer
STEPS_MAX = 10000  # as the mod's core.STEPS_MAX
STOCK_MAX_AMOUNT = 100000  # as the mod's core.STOCK_MAX_AMOUNT
LOG_ERRORS_MAX = 10  # entries of the game's log added to a build's answer
LOG_ERROR_CHARS = 600


def log_size(path):
    """The log's size now (where a command's own lines will start), None without a log."""
    try:
        return os.path.getsize(path) if path else None
    except OSError:
        return None


def log_errors_since(path, start):
    """The game log's Main Thread errors written from byte start on: each ERROR line, and each VERBOSE "Exception type" entry
    (where the engine puts its own message), with their "    |" / "    +" lines, joined into one string. A log
    shorter than start was rewritten by a new start of the game: nothing is said then."""
    if not path or start is None:
        return []
    try:
        if os.path.getsize(path) < start:
            return []
        with open(path, "rb") as f:
            f.seek(start)
            data = f.read(4_000_000)
    except OSError:
        return []
    out, cur = [], None
    for line in data.decode("utf-8", "replace").splitlines():
        if line.startswith("["):
            if cur:
                out.append(cur)
            head = line.split("]", 1)
            fields = [f.strip() for f in head[0].split(" - ")]
            level = fields[1] if len(fields) > 1 else ""
            thread = fields[2] if len(fields) > 2 else ""
            body = head[1].lstrip("+ ").strip() if len(head) > 1 else line
            cur = None
            # the Main Thread only: a build is checked there, while game scripts of other mods may fill the
            # Simulation Thread with errors of their own in the same second (2026-11-22: company_growth, 15 a second)
            if thread == "Main Thread" and (level == "ERROR" or (level == "VERBOSE" and body.startswith("Exception type"))):
                cur = head[0][1:21] + " " + level + ": " + body
        elif cur is not None and line.startswith("    "):
            part = line.strip().lstrip("|+").strip()
            if part and part != "Details:":
                cur += " | " + part
    if cur:
        out.append(cur)
    # the first ones: those right after the command are nearest to its cause
    return [e[:LOG_ERROR_CHARS] for e in out[:LOG_ERRORS_MAX]]


PROPOSAL_LOG_RE = re.compile(r"ProposalData (error|warning|info)s?:\s*(.*)$", re.IGNORECASE)
PROPOSAL_LOG_WAIT_SEC = 0.75


def log_proposal_since(path, start):
    """The engine's "ProposalData error: <reason>" lines (any thread: the Simulation Thread writes them) from byte
    start on, as {"time", "kind", "text"}, the proposal's dump below each left out. A build refused on water came
    back with no message while this line had its reason (2026-11-23: "ProposalData error: 陸上に配置")."""
    if not path or start is None:
        return []
    try:
        if os.path.getsize(path) < start:
            return []
        with open(path, "rb") as f:
            f.seek(start)
            data = f.read(4_000_000)
    except OSError:
        return []
    out = []
    for line in data.decode("utf-8", "replace").splitlines():
        if not line.startswith("["):
            continue
        head = line.split("]", 1)
        if len(head) < 2:
            continue
        m = PROPOSAL_LOG_RE.match(head[1].lstrip("+ ").strip())
        if m and m.group(2).strip():
            out.append({"time": head[0][1:21], "kind": m.group(1).lower(), "text": m.group(2).strip()[:LOG_ERROR_CHARS]})
    return out[:LOG_ERRORS_MAX]


def add_proposal_log(args, res, log_path, log_start):
    """The engine's ProposalData lines of the command's seconds into a build's or a road's answer (proposalLog).
    A refusal whose answer had no message takes its reason from them (errorFrom: "game log"); a dry run that said
    buildable while the log has a ProposalData error gets a note (another mod's proposal may have written it)."""
    lines = log_proposal_since(log_path, log_start)
    if not lines and not res.get("ok") and "no message" in str(res.get("error", "")):
        # the Simulation Thread may write its line after the mod's answer (2026-11-23: the answer's log line came
        # first in the same second): read once more
        time.sleep(PROPOSAL_LOG_WAIT_SEC)
        lines = log_proposal_since(log_path, log_start)
    if not lines:
        if not res.get("ok") and "no message" in str(res.get("error", "")):
            res = dict(res, proposalLogNote="no ProposalData line in the game's log while the command ran")
        return res
    res = dict(res, proposalLog=lines)
    errors = [ln["text"] for ln in lines if ln["kind"] == "error"]
    err = str(res.get("error", ""))
    if not res.get("ok") and errors and "no message" in err:
        # (the answer's own "no message (...)" stays after it, as what the mod read)
        reason = "; ".join(dict.fromkeys(errors))
        if "no message (" in err:
            res["error"] = err.replace("no message (", "%s (from the game's log, ProposalData error; the answer had "
                                       "no message: " % reason, 1)
        else:
            res["error"] = err.replace("no message", "%s (from the game's log, ProposalData error; the answer had "
                                       "no message)" % reason, 1)
        res["errorFrom"] = "game log"
        res["proposalLogNote"] = ("the engine's ProposalData lines written while the command ran: its reason, unless "
                                  "another mod's proposal wrote one in the same seconds")
    elif res.get("ok") and args.get("dryRun") and args.get("engineCheck") and errors:
        res["proposalLogNote"] = ("the game's log has a ProposalData error from the seconds of this check (%s): the "
                                  "build may be refused although the check said %s (or another mod's proposal wrote it)"
                                  % ("; ".join(errors), res.get("verdict") or "buildable"))
    return res


def check_build_answer(args, res, log_path=None, log_start=None):
    """A place the mod says is built must name its construction: an engine that says success and builds nothing
    (2026-11-22, a harbour whose update script failed) is no success, whatever an older mod answered. The game
    log's errors from the command on are added (logErrors), and its ProposalData lines (proposalLog): the engine's
    reason is sometimes only there. For road's answers too (no res in args: nothing to name)."""
    if not isinstance(res, dict):
        return res
    placing = "res" in args and not args.get("dryRun")
    if placing and res.get("ok") and res.get("entity") is None:
        res = dict(res, ok=False, error="nothing was built: the answer names no construction (entities: %s)"
                   % (res.get("entities") or "none"))
    # only for a build that is not ok: on one that is, errors of the same seconds belong to something else
    errs = log_errors_since(log_path, log_start) if not res.get("ok") and not args.get("dryRun") else []
    if errs:
        res = dict(res, logErrors=errs, logErrorsNote="the game log's Main Thread errors written while the "
                   "command ran: likely its reason, not certainly")
    if not res.get("ok") or (args.get("dryRun") and args.get("engineCheck")):
        res = add_proposal_log(args, res, log_path, log_start)
    return res


# Tools whose base button passes more than gameCtx, so a plain push breaks the GUI; their button listens to an
# event that opens them with the right params. notification_log.tl calls param.toolParam.storeFilterState(...) in
# its recipe body (line 509): pushed with only gameCtx that is a nil call, "Failed during state update of
# ... 'WindowContainerDelegate'" and a UI reload (2026-11-17 06:37 JST). notification_button.tl:27-30 listens to
# openNotificationLog / closeNotificationLog.
TOOL_EVENTS = {
    "/game_mechanics/notifications/gui/notification_log.tl": ("openNotificationLog", "closeNotificationLog"),
}
TOOL_EVENT_NAMES = {"notifications": "/game_mechanics/notifications/gui/notification_log.tl"}


def tool_event(ns):
    """The event to send instead of a tool push, or None."""
    module = TOOL_EVENT_NAMES.get(ns.name) if ns.name else ns.module
    events = TOOL_EVENTS.get(module)
    if not events:
        return None
    return {"name": events[1] if ns.close else events[0]}


def tool_args(ns):
    if (ns.name is None) == (ns.module is None):
        raise ToolError("give a tool name (music, calendar, notifications) or --module")
    args = {"name": ns.name} if ns.name else {"module": ns.module}
    if ns.field:
        args["field"] = ns.field
    if ns.close:
        args["close"] = True
    return args


VEHICLE_TIMEOUT_SEC = 90  # the mod gives up after 60 s and answers with what it has; this waits for that answer


def vehicle_args(ns):
    """The vehicle commands' args, from whichever of the options the command has."""
    args = {"via": ns.via}
    for key in ("model", "depot", "line", "vehicle", "count"):
        v = getattr(ns, key, None)
        if v is not None:
            args[key] = v
    return args


def parse_stops(text):
    """--stops "Central,42,Harbour" -> ["Central", 42, "Harbour"]: digits are entity ids (a station group or a
    station), anything else a part of a station group's name. A name with a comma in it goes by its id."""
    if text is None:
        return None
    items = [s.strip() for s in text.split(",")]
    if not any(items):
        raise ToolError("--stops is empty: give the stations, e.g. --stops Central,Harbour or --stops 41,42")
    if not all(items):
        raise ToolError("--stops has an empty item (two commas, or one at an end): %r" % text)
    return [int(s) if s.isdigit() else s for s in items]


LOAD_MODES = ("available", "any", "all")  # Line.Stop.loadMode 0, 1, 2, as the base's line window offers them


def parse_terminals(text):
    """--terminals "0:2,0:1" (station:terminal per stop, 0-based as `lines` and `stations` show them) or "2,1"
    (station 0) -> [{"station": 0, "terminal": 2}, ...]. One per stop or none: when a stop has none the base assigns
    every stop's platform anew."""
    if text is None:
        return None
    out = []
    for i, item in enumerate(text.split(","), 1):
        item = item.strip()
        parts = [p.strip() for p in item.split(":")] if ":" in item else ["0", item]
        if len(parts) != 2 or not all(p.isdigit() for p in parts):
            raise ToolError("--terminals item %d %r: give station:terminal or terminal (whole numbers, 0-based), one "
                            "per stop, e.g. --terminals 0:2,0:1" % (i, item))
        out.append({"station": int(parts[0]), "terminal": int(parts[1])})
    return out


def parse_load_modes(text):
    """--load-mode any (every stop) or "all,available" (one per stop) -> "any" or ["all", "available"]."""
    if text is None:
        return None
    items = [s.strip().lower() for s in text.split(",")]
    for i, m in enumerate(items, 1):
        if m not in LOAD_MODES:
            raise ToolError("--load-mode item %d %r: give available, any or all (one for every stop, or one per stop)"
                            % (i, m))
    return items[0] if len(items) == 1 else items


def parse_force_unload(text):
    """--force-unload 0,1 (one per stop, in order: Line.Stop.stopConfig.forceUnload) -> [False, True]. No "one for
    all": a count that does not match the line's stops is refused (here against --stops, in the mod against the
    line's own)."""
    if text is None:
        return None
    out = []
    for i, item in enumerate(text.split(","), 1):
        item = item.strip()
        if item not in ("0", "1"):
            raise ToolError("--force-unload item %d %r: give 0 or 1 for every stop, in order, e.g. --force-unload 0,1"
                            % (i, item))
        out.append(item == "1")
    return out


def line_args(ns):
    """The line command's args: action and what it takes (the mod checks every one again)."""
    args = {"action": ns.action}
    if ns.action != "delete":
        args["via"] = ns.via
    if getattr(ns, "line", None) is not None:
        args["line"] = ns.line
    stops = parse_stops(getattr(ns, "stops", None))
    if stops is not None:
        args["stops"] = stops
    for key in ("name", "cargo"):
        v = getattr(ns, key, None)
        if v is not None:
            args[key] = v
    terminals = parse_terminals(getattr(ns, "terminals", None))
    if terminals is not None:
        if stops is not None and len(terminals) != len(stops):
            raise ToolError("--terminals: give one for every stop (%d stops, %d terminals): when one stop has none, the "
                            "base assigns every stop's platform anew, so some would not hold" % (len(stops), len(terminals)))
        args["terminals"] = terminals
    modes = parse_load_modes(getattr(ns, "load_mode", None))
    if modes is not None:
        if isinstance(modes, list) and stops is not None and len(modes) != len(stops):
            raise ToolError("--load-mode: give one for every stop, or one for all (%d stops, %d modes)"
                            % (len(stops), len(modes)))
        args["loadModes"] = modes
    force = parse_force_unload(getattr(ns, "force_unload", None))
    if force is not None:
        if stops is not None and len(force) != len(stops):
            raise ToolError("--force-unload: give one for every stop (%d stops, %d values)" % (len(stops), len(force)))
        args["forceUnload"] = force
    if getattr(ns, "sell_vehicles", False):
        args["sellVehicles"] = True
    if ns.action == "update" and not any(k in args for k in ("stops", "name", "cargo", "terminals", "loadModes",
                                                               "forceUnload")):
        raise ToolError("line update: give --stops, --name, --cargo, --terminals, --load-mode or --force-unload")
    return args


CONNECT_GRACE_SEC = 30  # the mod gives up after --timeout and answers; this waits that much longer for it


def connect_end(text, what):
    """--from / --to: digits are an entity id (a node, station, station group or station construction),
    anything else a part of a station group's name."""
    s = (text or "").strip()
    if not s:
        raise ToolError("--%s is empty: give a node id, a station id or a station's name" % what)
    # (isdigit alone takes "²" and other Unicode digits, which int() refuses)
    return int(s) if s.isascii() and s.isdigit() else s


def connect_args(ns):
    """The connect command's args (the mod checks every one again)."""
    args = {"from": connect_end(ns.from_, "from"), "to": connect_end(ns.to, "to")}
    if ns.road:
        if ns.track is not None or ns.electric:
            raise ToolError("--track and --electric go with tracks, not with --road (give the road type as --template)")
        args["road"] = True
        if ns.template is not None:
            args["template"] = ns.template
    else:
        if ns.template is not None:
            raise ToolError("--template goes with --road (for tracks give --track)")
        if ns.track is not None:
            args["track"] = ns.track
        if ns.electric:
            args["electric"] = True
    for key in ("slope", "radius"):
        v = getattr(ns, key)
        if v is not None:
            args[key] = v
    for key in ("bridges", "tunnels"):
        if getattr(ns, key) is False:
            args[key] = False
    if ns.clear and not ns.build:
        raise ToolError("--clear (knock down town buildings in the way) goes with --build")
    if ns.build:
        args["build"] = True
    if ns.clear:
        args["clear"] = True
    args["timeout"] = ns.timeout
    return args


# fit: where a construction of a known size can go near a wanted point, searched here (pure functions, below) over
# what `around` lists, and the best few asked of the engine (build --dry-run --engine-check) before one is answered.
# The boxes are the octree's, axis aligned (a turned station reads larger), and road and track widths are a guess:
# the search narrows the places, the engine's check decides.
FIT_RADIUS_MAX = 1000
FIT_STEP_MIN = 0.5
FIT_CANDIDATES_MAX = 200000  # places tried at most (each against the obstacles near it only)
FIT_GRID_MAX = 1000000  # grid points made at most
FIT_CHECK_MAX = 10
# a town's box is the whole town; trees go when one builds; map: a box the size of the map (around's kind)
FIT_SKIP_KINDS = ("town", "moving", "node", "asset", "map")
# m, both sides: a box this large is the map's own (entity 2, kind other, 14,336 m square, stood in the way of every
# place a road depot's fit tried, 2026-11-23), never a thing a build collides with. The mod's core.AROUND_MAP_SIZE
FIT_MAP_SIZE = 2000
FIT_ANGLES_ANY = tuple(i * math.pi / 2 for i in range(4))
FIT_ANGLES_JOIN = tuple(i * math.pi / 12 for i in range(24))


def fit_rect(cx, cy, angle, box):
    """The 4 corners of a box (x0, y0, x1, y1 in a construction's own frame) at cx, cy turned by angle."""
    c, s = math.cos(angle), math.sin(angle)
    x0, y0, x1, y1 = box
    return [(cx + c * x - s * y, cy + s * x + c * y) for x, y in ((x0, y0), (x1, y0), (x1, y1), (x0, y1))]


def fit_to_world(cx, cy, angle, dx, dy):
    c, s = math.cos(angle), math.sin(angle)
    return cx + c * dx - s * dy, cy + s * dx + c * dy


def _fit_axes(poly):
    out = []
    for i in range(len(poly)):
        (ax, ay), (bx, by) = poly[i], poly[(i + 1) % len(poly)]
        n = math.hypot(ay - by, bx - ax)
        if n > 0:
            out.append(((ay - by) / n, (bx - ax) / n))
    return out


def fit_polys_overlap(a, b, margin=0.0):
    """Whether two convex polygons come closer than margin metres along some axis or overlap (separating axes):
    with margin 0 touching is no overlap; with margin m a gap below m counts as one (room kept between them)."""
    for ax in _fit_axes(a) + _fit_axes(b):
        pa = [p[0] * ax[0] + p[1] * ax[1] for p in a]
        pb = [p[0] * ax[0] + p[1] * ax[1] for p in b]
        if max(pa) + margin <= min(pb) or max(pb) + margin <= min(pa):
            return False
    return True


def fit_seg_dist(p, a, b):
    """The distance from point p to the segment a-b."""
    vx, vy = b[0] - a[0], b[1] - a[1]
    l2 = vx * vx + vy * vy
    t = 0.0 if l2 == 0 else max(0.0, min(1.0, ((p[0] - a[0]) * vx + (p[1] - a[1]) * vy) / l2))
    return math.hypot(p[0] - a[0] - t * vx, p[1] - a[1] - t * vy)


def _fit_cross(a, b, c, d):
    def orient(p, q, r):
        return (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0])
    o1, o2, o3, o4 = orient(a, b, c), orient(a, b, d), orient(c, d, a), orient(c, d, b)
    return ((o1 > 0) != (o2 > 0)) and ((o3 > 0) != (o4 > 0)) and 0 not in (o1, o2, o3, o4)


def _fit_inside(poly, p):
    sign = None
    for i in range(len(poly)):
        q, r = poly[i], poly[(i + 1) % len(poly)]
        cr = (r[0] - q[0]) * (p[1] - q[1]) - (r[1] - q[1]) * (p[0] - q[0])
        if cr != 0:
            if sign is None:
                sign = cr > 0
            elif sign != (cr > 0):
                return False
    return True


def fit_poly_seg_dist(poly, a, b):
    """0 when the segment a-b meets the convex polygon, else the least distance between them."""
    if _fit_inside(poly, a) or _fit_inside(poly, b):
        return 0.0
    best = float("inf")
    for i in range(len(poly)):
        q, r = poly[i], poly[(i + 1) % len(poly)]
        if _fit_cross(a, b, q, r):
            return 0.0
        best = min(best, fit_seg_dist(q, a, b), fit_seg_dist(a, q, r), fit_seg_dist(b, q, r))
    return best


def fit_obstacles(entities, skip=FIT_SKIP_KINDS):
    """around's entries -> obstacles: {"id", "kind", "name", "line": (a, b, halfWidth)} for a road or track piece,
    {"id", "kind", "name", "poly": corners} for one with a box (a point: 1 m square). One entry per town building:
    its construction (with building) is dropped when its TOWN_BUILDING entity (with construction) is there. The kinds
    in skip and a box the size of the map (FIT_MAP_SIZE both sides, from a mod that lists it as other) are none."""
    houses = {e.get("construction") for e in entities if e.get("kind") == "town_building" and not e.get("fileName")}
    out = []
    for e in entities:
        kind = e.get("kind")
        if kind in skip:
            continue
        if kind == "town_building" and e.get("fileName") and e.get("id") in houses:
            continue
        base = {"id": e.get("id"), "kind": kind, "name": e.get("name") or e.get("townName"),
                "x": e.get("x"), "y": e.get("y")}
        f, t = e.get("from"), e.get("to")
        if kind in ("street", "track") and f and t and f.get("x") is not None and t.get("x") is not None:
            base["line"] = ((f["x"], f["y"]), (t["x"], t["y"]), float(e.get("halfWidth") or 0))
            base["construction"] = e.get("construction")
        else:
            b = e.get("box")
            if not b or b.get("x0") is None:
                continue
            x0, y0, x1, y1 = b["x0"], b["y0"], b["x1"], b["y1"]
            if x1 - x0 >= FIT_MAP_SIZE and y1 - y0 >= FIT_MAP_SIZE:
                continue
            if x1 - x0 < 1:
                x0, x1 = (x0 + x1) / 2 - 0.5, (x0 + x1) / 2 + 0.5
            if y1 - y0 < 1:
                y0, y1 = (y0 + y1) / 2 - 0.5, (y0 + y1) / 2 + 0.5
            base["poly"] = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
        out.append(base)
    return out


def fit_houses(entities):
    """The town buildings' centres, one per building (the TOWN_BUILDING entity's; its construction's only when that
    is all there is)."""
    tb = [e for e in entities if e.get("kind") == "town_building" and not e.get("fileName") and e.get("x") is not None]
    if not tb:
        tb = [e for e in entities if e.get("kind") == "town_building" and e.get("x") is not None]
    return [(e["x"], e["y"]) for e in tb]


def fit_join_nodes(entities, track=False):
    """The ends of the road (or track) pieces that belong to no construction: {(x, y): [obstacle ids at it]}."""
    want = "track" if track else "street"
    nodes = {}
    for e in entities:
        if e.get("kind") != want or e.get("construction") is not None:
            continue
        for k in ("from", "to"):
            p = e.get(k)
            if p and p.get("x") is not None:
                key = (round(p["x"], 3), round(p["y"], 3))
                nodes.setdefault(key, []).append(e.get("id"))
    return nodes


FIT_CELL = 50.0  # m: the grid the obstacles are kept in, so each place is checked against those near it only


def fit_index(obstacles, cell=FIT_CELL):
    """obstacles -> {(i, j): [their positions in the list]} by the cells their box (a line's, with its width) meets."""
    grid = {}
    for k, o in enumerate(obstacles):
        if "line" in o:
            (ax, ay), (bx, by), hw = o["line"]
            x0, y0, x1, y1 = min(ax, bx) - hw, min(ay, by) - hw, max(ax, bx) + hw, max(ay, by) + hw
        else:
            xs, ys = [p[0] for p in o["poly"]], [p[1] for p in o["poly"]]
            x0, y0, x1, y1 = min(xs), min(ys), max(xs), max(ys)
        o["aabb"] = (x0, y0, x1, y1)
        for i in range(int(math.floor(x0 / cell)), int(math.floor(x1 / cell)) + 1):
            for j in range(int(math.floor(y0 / cell)), int(math.floor(y1 / cell)) + 1):
                grid.setdefault((i, j), []).append(k)
    return grid


def fit_near(poly, obstacles, grid, margin, cell=FIT_CELL):
    """The obstacles whose box comes within margin of the box round poly, in list order."""
    xs, ys = [p[0] for p in poly], [p[1] for p in poly]
    x0, y0, x1, y1 = min(xs) - margin, min(ys) - margin, max(xs) + margin, max(ys) + margin
    ks = set()
    for i in range(int(math.floor(x0 / cell)), int(math.floor(x1 / cell)) + 1):
        for j in range(int(math.floor(y0 / cell)), int(math.floor(y1 / cell)) + 1):
            ks.update(grid.get((i, j), ()))
    out = []
    for k in sorted(ks):
        b = obstacles[k]["aabb"]
        if b[0] <= x1 and b[2] >= x0 and b[1] <= y1 and b[3] >= y0:
            out.append(obstacles[k])
    return out


def fit_blocker(poly, obstacles, margin, join=None):
    """The first obstacle the footprint poly overlaps or comes closer than margin to, or None. join = ((x, y),
    ids): the node a mouth is put on; the pieces at it are drawn back from it by their width and a metre, as the
    mouth meets them there (a piece shorter than that: its far end only)."""
    for o in obstacles:
        if "line" in o:
            a, b, hw = o["line"]
            if join and o["id"] in join[1]:
                (nx, ny) = join[0]
                L = math.hypot(b[0] - a[0], b[1] - a[1])
                cut = min(hw + 1.0, L)
                if math.hypot(a[0] - nx, a[1] - ny) < 0.01 and L > 0:
                    a = (a[0] + (b[0] - a[0]) * cut / L, a[1] + (b[1] - a[1]) * cut / L)
                elif math.hypot(b[0] - nx, b[1] - ny) < 0.01 and L > 0:
                    b = (b[0] + (a[0] - b[0]) * cut / L, b[1] + (a[1] - b[1]) * cut / L)
            if fit_poly_seg_dist(poly, a, b) < hw + margin:
                return o
        elif fit_polys_overlap(poly, o["poly"], margin):
            return o
    return None


# --mouth on a road: the mouth is never put on a road's node (a depot's mouth on a dead end, both nodes at one
# point, was refused as "Construction Not Possible" with and without --join-streets, 2026-11-23). It is kept a
# short way off, straight out of its face, so that one road piece (road --from mouth --to there --snap 3) joins it to
# the road once it stands: a node of a free road piece first, else a point on one (fallback: the road command joins
# nodes only, a piece ending on another's middle is not checked in a game).
FIT_LINK_DEFAULT = (8.0, 40.0)  # m, mouth to the road's centre line: shorter pieces are refused, longer ones wander
FIT_LINK_MIN = 2.0  # m, the least --link MIN taken
FIT_LINK_SNAP = 3.0  # road --snap for both ends: the mouth's node once built, the road's node
# the link and every piece at its node: at least this apart (at 30 degrees two pieces' widths overlap some 16 m
# out from the node, unseen by the link's own clearance, which skips the pieces it joins)
FIT_LINK_NODE_ANGLE = math.radians(60)
FIT_LINK_EDGE_ANGLE = math.radians(45)  # a link onto a piece's middle: at least this across it
FIT_LINK_EDGE_TURNS = tuple(math.radians(d) for d in (0, -15, 15, -30, 30))  # off square to the piece, tried in turn
FIT_LINK_HALF = 3.0  # m, the least half width the link is kept clear by (the target piece's when wider)


def fit_mouth_normal(box, mouth):
    """The way out of the box face a mouth (own frame) is on, or nearest to: a unit vector in the own frame. A
    mouth outside the box goes out the side it is beyond (the farthest beyond, when beyond two)."""
    x0, y0, x1, y1 = box
    mx, my = mouth
    beyond = [(y0 - my, (0.0, -1.0)), (my - y1, (0.0, 1.0)), (x0 - mx, (-1.0, 0.0)), (mx - x1, (1.0, 0.0))]
    far = max(beyond, key=lambda f: f[0])
    if far[0] > 0:
        return far[1]
    faces = ((abs(my - y0), (0.0, -1.0)), (abs(my - y1), (0.0, 1.0)), (abs(mx - x0), (-1.0, 0.0)),
             (abs(mx - x1), (1.0, 0.0)))
    return min(faces, key=lambda f: f[0])[1]


def fit_seg_seg_dist(a, b, c, d):
    """The least distance between the segments a-b and c-d (0 when they cross)."""
    if _fit_cross(a, b, c, d):
        return 0.0
    return min(fit_seg_dist(a, c, d), fit_seg_dist(b, c, d), fit_seg_dist(c, a, b), fit_seg_dist(d, a, b))


def _fit_angle_between(u, v):
    nu, nv = math.hypot(*u), math.hypot(*v)
    if nu == 0 or nv == 0:
        return math.pi
    c = max(-1.0, min(1.0, (u[0] * v[0] + u[1] * v[1]) / (nu * nv)))
    return math.acos(c)


def fit_link_targets(entities, track=False):
    """Where a link may end: {"nodes": [((x, y), [(piece id, (dx, dy) out of the node along it)])], "edges":
    [(piece id, a, b, halfWidth)]}, of the road pieces that belong to no construction."""
    want = "track" if track else "street"
    nodes, edges = {}, []
    for e in entities:
        if e.get("kind") != want or e.get("construction") is not None:
            continue
        f, t = e.get("from"), e.get("to")
        if not (f and t and f.get("x") is not None and t.get("x") is not None):
            continue
        a, b = (f["x"], f["y"]), (t["x"], t["y"])
        edges.append((e.get("id"), a, b, float(e.get("halfWidth") or 0)))
        for p, q in ((a, b), (b, a)):
            key = (round(p[0], 3), round(p[1], 3))
            nodes.setdefault(key, []).append((e.get("id"), (q[0] - p[0], q[1] - p[1])))
    return {"nodes": sorted(nodes.items()), "edges": edges}


def fit_link_ok_at_node(direction, pieces):
    """Whether a link leaving a node the way direction points (node to mouth) stays FIT_LINK_NODE_ANGLE off every
    piece at it (pieces: [(id, (dx, dy) along it out of the node)])."""
    return all(_fit_angle_between(direction, d) >= FIT_LINK_NODE_ANGLE for _, d in pieces)


def fit_link_on_edge(mouth_pt, out, a, b, lmin, lmax):
    """A link straight out of a mouth at mouth_pt the way out points (a unit vector) onto the piece a-b: (to,
    length) where the ray crosses the piece's centre line within lmin..lmax metres and at FIT_LINK_EDGE_ANGLE or
    more across it, at least FIT_LINK_SNAP + 1 m from both its ends (nearer: its node is the target); else None."""
    vx, vy = b[0] - a[0], b[1] - a[1]
    L = math.hypot(vx, vy)
    den = out[0] * vy - out[1] * vx
    if L == 0 or abs(den) < 1e-12:
        return None
    wx, wy = a[0] - mouth_pt[0], a[1] - mouth_pt[1]
    t = (wx * vy - wy * vx) / den  # along the ray
    s = (wx * out[1] - wy * out[0]) / den  # along the piece, 0..1
    if not lmin <= t <= lmax:
        return None
    if s * L < FIT_LINK_SNAP + 1 or (1 - s) * L < FIT_LINK_SNAP + 1:
        return None
    cross = _fit_angle_between(out, (vx, vy))
    if min(cross, math.pi - cross) < FIT_LINK_EDGE_ANGLE:
        return None
    return (a[0] + s * vx, a[1] + s * vy), t


def fit_link_clear(frm, to, half, obstacles, skip, margin):
    """The first obstacle a link frm-to (kept clear by half metres each side; its last half + 1 m, inside the road
    it joins, not looked at) comes closer than margin to, or None. skip: ids it joins (the pieces at its node, or
    the piece it ends on)."""
    L = math.hypot(to[0] - frm[0], to[1] - frm[1])
    if L == 0:
        return None
    cut = min(L, half + 1.0)
    end = (to[0] - (to[0] - frm[0]) * cut / L, to[1] - (to[1] - frm[1]) * cut / L)
    for o in obstacles:
        if o["id"] in skip:
            continue
        if "line" in o:
            a, b, hw = o["line"]
            if fit_seg_seg_dist(frm, end, a, b) < hw + half + margin:
                return o
        elif fit_poly_seg_dist(o["poly"], frm, end) < half + margin:
            return o
    return None


def _fit_link_places(want, radius, step, angles, box, mouth, targets, link, edges=False):
    """The places with a link, nearest to want first: (offset, x, y, angle, link) with link = {"from", "to",
    "length", "on", "pieces"}. On nodes; with edges, after them, on pieces' middles too."""
    lmin, lmax = link
    nx, ny = fit_mouth_normal(box, mouth)
    reach = radius + lmax + math.hypot(*mouth)
    lens = []
    v = lmin
    while v < lmax - 1e-9:
        lens.append(v)
        v += max(step, 1.0)
    lens.append(lmax)

    def turn_for(out):
        """The construction's turn that points its mouth's face the world way out."""
        a = math.atan2(out[1], out[0]) - math.atan2(ny, nx)
        return math.atan2(math.sin(a), math.cos(a))

    def ordered(group):
        group.sort(key=lambda p: (round(p[0], 6), p[1], p[5]["length"], p[4], p[2], p[3]))
        for p in group:
            yield (p[0], p[2], p[3], p[4], p[5])

    node_places, edge_places = [], []
    for (tx, ty), pieces in targets["nodes"]:
        if math.hypot(tx - want[0], ty - want[1]) > reach:
            continue
        ids = sorted(p[0] for p in pieces)
        for a in angles:
            ox, oy = fit_to_world(0, 0, a, nx, ny)  # the way out, in the world
            if not fit_link_ok_at_node((-ox, -oy), pieces):
                continue
            mdx, mdy = fit_to_world(0, 0, a, mouth[0], mouth[1])
            for L in lens:
                mx, my = tx - ox * L, ty - oy * L
                x, y = mx - mdx, my - mdy
                d = math.hypot(x - want[0], y - want[1])
                if d <= radius:
                    node_places.append((d, 0 if len(pieces) == 1 else 1, x, y, a,
                                        {"from": (mx, my), "to": (tx, ty), "length": L, "on": "node", "pieces": ids}))
    for p in ordered(node_places):
        yield p
    if not edges:
        return
    # (made only once every node's place was taken: the search stops early when enough are found)
    for pid, pa, pb, hw in targets["edges"]:
        L = math.hypot(pb[0] - pa[0], pb[1] - pa[1])
        if L < 2 * (FIT_LINK_SNAP + 1) or fit_seg_dist(want, pa, pb) > reach:
            continue
        rx, ry = -(pb[1] - pa[1]) / L, (pb[0] - pa[0]) / L  # square to the piece
        k = FIT_LINK_SNAP + 1
        while k <= L - (FIT_LINK_SNAP + 1) + 1e-9:
            tx, ty = pa[0] + (pb[0] - pa[0]) * k / L, pa[1] + (pb[1] - pa[1]) * k / L
            k += max(step, 1.0)
            if math.hypot(tx - want[0], ty - want[1]) > reach:
                continue
            for side in (1.0, -1.0):
                for turn in FIT_LINK_EDGE_TURNS:
                    c, sn = math.cos(turn), math.sin(turn)
                    # the way out of the mouth: towards the piece, so the mouth stands on this side
                    ox, oy = -side * (c * rx - sn * ry), -side * (sn * rx + c * ry)
                    a = turn_for((ox, oy))
                    if len(angles) == 1 and abs(math.atan2(math.sin(a - angles[0]), math.cos(a - angles[0]))) > 1e-6:
                        continue
                    mdx, mdy = fit_to_world(0, 0, a, mouth[0], mouth[1])
                    for Ln in lens:
                        mx, my = tx - ox * Ln, ty - oy * Ln
                        hit = fit_link_on_edge((mx, my), (ox, oy), pa, pb, lmin, lmax)
                        if hit is None:
                            continue
                        x, y = mx - mdx, my - mdy
                        d = math.hypot(x - want[0], y - want[1])
                        if d <= radius:
                            edge_places.append((d, 2, x, y, a, {"from": (mx, my), "to": hit[0], "length": hit[1],
                                                                 "on": "edge", "pieces": [pid]}))
    for p in ordered(edge_places):
        yield p


def _fit_places(want, radius, step, angles, mouth, joins):
    """The places to try, nearest to want first: (offset, x, y, angle, join), made as they are taken."""
    if mouth is not None:
        places = []
        for (nx, ny), ids in joins:
            for a in angles:
                mx, my = fit_to_world(0, 0, a, mouth[0], mouth[1])
                x, y = nx - mx, ny - my
                d = math.hypot(x - want[0], y - want[1])
                if d <= radius:
                    # (a dead end, one piece at the node, before a node inside a road)
                    places.append((d, 0 if len(ids) == 1 else 1, x, y, a, ((nx, ny), ids)))
        places.sort(key=lambda p: (round(p[0], 6), p[1], p[4], p[2], p[3]))
        for p in places:
            yield (p[0], p[2], p[3], p[4], p[5])
        return
    n = int(radius // step)
    pts = []
    for i in range(-n, n + 1):
        for j in range(-n, n + 1):
            d = math.hypot(i * step, j * step)
            if d <= radius:
                pts.append((d, i, j))
    pts.sort()
    for d, i, j in pts:
        for a in angles:
            yield (d, want[0] + i * step, want[1] + j * step, a, None)


def fit_search(entities, box, want, radius, angles, step=4.0, mouth=None, track=False, houses=0, catchment=None,
               margin=0.5, limit=50, most=None, link=None, link_edges=False):
    """Places for a construction whose box (x0, y0, x1, y1, own frame) fits among around's entities, nearest to
    want (x, y) first, within radius of it. angles: the turns tried. mouth (dx, dy, own frame): with track, put
    that point on the end of a track piece that belongs to no construction; on a road, kept link (min, max, default
    FIT_LINK_DEFAULT) metres off a free road piece, straight out of its face, with the link road clear (each
    candidate's "link": from, to, length, on node / edge, pieces); without it a grid every step metres. houses
    / catchment: at least that many town buildings within catchment metres of the box's centre. At most `most`
    places are tried (FIT_CANDIDATES_MAX): searched says how far out they went.
    -> {"candidates": [...], "tried": n, "searched": m, "complete": bool, "tooFewHouses": n,
        "blockers": [{"id", "kind", "name", "x", "y", "count"}]}"""
    most = FIT_CANDIDATES_MAX if most is None else most
    if (2 * radius / step + 1) ** 2 > FIT_GRID_MAX and mouth is None:
        raise ToolError("--radius / --step: %d grid points, at most %d (a larger --step or a smaller --radius)"
                        % ((2 * radius / step + 1) ** 2, FIT_GRID_MAX))
    obstacles = fit_obstacles(entities)
    grid = fit_index(obstacles)
    homes = fit_houses(entities) if houses else []
    bcx, bcy = (box[0] + box[2]) / 2, (box[1] + box[3]) / 2
    linking = mouth is not None and not track
    if linking:
        link = tuple(link or FIT_LINK_DEFAULT)
        places = _fit_link_places(want, radius, step, angles, box, mouth, fit_link_targets(entities), link,
                                  edges=link_edges)
        halves = {o["id"]: o["line"][2] for o in obstacles if "line" in o}
    else:
        joins = list(fit_join_nodes(entities, track).items()) if mouth is not None else []
        places = ((d, x, y, a, join, None) for d, x, y, a, join in _fit_places(want, radius, step, angles, mouth, joins))
    found, blocked, tried, searched, few, complete = [], {}, 0, 0.0, 0, True
    for item in places:
        if linking:
            d, x, y, a, lk = item
            join = None
        else:
            d, x, y, a, join, lk = item
        if tried >= most:
            complete = False
            break
        tried += 1
        searched = d
        poly = fit_rect(x, y, a, box)
        o = fit_blocker(poly, fit_near(poly, obstacles, grid, margin), margin, join)
        if o is None and lk is not None:
            half = max([FIT_LINK_HALF] + [halves.get(i, 0.0) for i in lk["pieces"]])
            lpoly = [lk["from"], lk["to"], lk["to"], lk["from"]]
            o = fit_link_clear(lk["from"], lk["to"], half, fit_near(lpoly, obstacles, grid, margin + half), set(lk["pieces"]),
                               margin)
        if o is not None:
            k = o["id"]
            if k not in blocked:
                blocked[k] = dict({key: o.get(key) for key in ("id", "kind", "name", "x", "y")}, count=0)
            blocked[k]["count"] += 1
            continue
        cx, cy = fit_to_world(x, y, a, bcx, bcy)
        near = sum(1 for hx, hy in homes if math.hypot(hx - cx, hy - cy) <= (catchment or 0)) if houses else None
        if houses and near < houses:
            few += 1
            continue
        cand = {"x": round(x, 3), "y": round(y, 3), "angle": round(a, 6), "offset": round(d, 3),
                "centre": {"x": round(cx, 3), "y": round(cy, 3)}}
        if near is not None:
            cand["houses"] = near
        roads = [fit_poly_seg_dist(poly, *o["line"][:2]) - o["line"][2] for o in obstacles
                 if o.get("kind") == "street" and "line" in o]
        if roads:
            cand["roadDist"] = round(max(0.0, min(roads)), 3)
        if join:
            cand["joinAt"] = {"x": join[0][0], "y": join[0][1], "pieces": sorted(join[1])}
        if lk is not None:
            cand["link"] = {"from": [round(lk["from"][0], 3), round(lk["from"][1], 3)],
                            "to": [round(lk["to"][0], 3), round(lk["to"][1], 3)], "length": round(lk["length"], 3),
                            "on": lk["on"], "pieces": lk["pieces"]}
        found.append(cand)
        if len(found) >= limit:
            break
    blockers = sorted(blocked.values(), key=lambda b: -b["count"])[:5]
    return {"candidates": found, "tried": tried, "searched": round(searched, 3), "complete": complete,
            "tooFewHouses": few, "blockers": blockers}


FIT_CATCHMENT_DEFAULT = 150  # m: a small rail station's main building (remote_catchment.lua's notes: 150 / 175 / 200)


def fit_numbers(text, n, name):
    try:
        v = [float(x) for x in text.split(",")]
    except (ValueError, AttributeError):
        raise ToolError("%s must be numbers separated by commas" % name)
    if len(v) not in n or any(x != x or abs(x) == float("inf") for x in v):
        raise ToolError("%s must be %s finite numbers" % (name, " or ".join(map(str, n))))
    return v


def fit_plan(ns):
    """fit's arguments checked: (want, radius, angles, box or None, mouth or None, params or None)."""
    want = fit_numbers(ns.at, (2,), "--at")
    radius = 100.0 if ns.radius is None else ns.radius
    if not 0 < radius <= FIT_RADIUS_MAX:
        raise ToolError("--radius must be more than 0 and at most %d m" % FIT_RADIUS_MAX)
    step = 4.0 if ns.step is None else ns.step
    if not step >= FIT_STEP_MIN:
        raise ToolError("--step must be at least %g m" % FIT_STEP_MIN)
    mouth = fit_numbers(ns.mouth, (2,), "--mouth") if ns.mouth else None
    if ns.angle is not None:
        if ns.angle != ns.angle or abs(ns.angle) == float("inf"):
            raise ToolError("--angle must be a finite number of radians")
        angles = (ns.angle,)
    else:
        angles = FIT_ANGLES_JOIN if mouth else FIT_ANGLES_ANY
    box = None
    if ns.size:
        v = fit_numbers(ns.size, (2, 4), "--size")
        if v[0] <= 0 or v[1] <= 0:
            raise ToolError("--size: W and D must be above 0")
        ox, oy = (v[2], v[3]) if len(v) == 4 else (0.0, 0.0)
        box = (ox - v[0] / 2, oy - v[1] / 2, ox + v[0] / 2, oy + v[1] / 2)
    if not ns.res or not ns.res.strip():
        raise ToolError("give --res (the construction to place)")
    params = None
    if ns.params is not None:
        try:
            params = json.loads(ns.params)
        except ValueError as e:
            raise ToolError("--params must be a JSON object: %s" % e)
        if not isinstance(params, dict):
            raise ToolError("--params must be a JSON object")
    if ns.houses is not None and ns.houses < 1:
        raise ToolError("--houses must be 1 or more")
    if ns.check is not None and not 0 <= ns.check <= FIT_CHECK_MAX:
        raise ToolError("--check must be 0-%d" % FIT_CHECK_MAX)
    if box is None and ns.check == 0:
        raise ToolError("without --size the box comes from the engine's check: --check 0 needs --size")
    link = None
    if ns.link is not None:
        if not mouth or ns.track:
            raise ToolError("--link goes with --mouth on a road (not --track)")
    if ns.link_edge and (not mouth or ns.track):
        raise ToolError("--link-edge goes with --mouth on a road (not --track)")
    if ns.link is not None:
        link = fit_numbers(ns.link, (2,), "--link")
        if not FIT_LINK_MIN <= link[0] <= link[1] <= FIT_RADIUS_MAX:
            raise ToolError("--link MIN,MAX: %g <= MIN <= MAX <= %d m" % (FIT_LINK_MIN, FIT_RADIUS_MAX))
        link = tuple(link)
    return want, radius, step, angles, box, mouth, params, link


def fit_link_road(lk):
    """The road command that joins a placed construction's mouth to the road: both ends snapped FIT_LINK_SNAP m."""
    def pt(p):
        return "%s,%s" % (round(p[0], 3), round(p[1], 3))
    return "road --from=%s --to=%s --snap %g" % (pt(lk["from"]), pt(lk["to"]), FIT_LINK_SNAP)


def _fit_res_stem(res):
    base = res.replace("\\", "/").rsplit("/", 1)[-1]
    return base[:-4] if base.endswith(".con") else base


def fit_mouth_hint(entities, res):
    """A road mouth of the same construction standing near (around's mouths, in its own frame): {"mouth": "DX,DY",
    "from": its id} for --mouth, or None. Only a hint: fit without --mouth searches as before."""
    stem = _fit_res_stem(res)
    for e in entities:
        fn = e.get("fileName")
        if not fn or e.get("kind") == "town_building" or _fit_res_stem(fn) != stem:
            continue
        for m in e.get("mouths") or []:
            loc = m.get("local") if isinstance(m, dict) else None
            if m.get("kind") == "mouth" and not m.get("track") and loc and loc.get("dx") is not None:
                return {"mouth": "%g,%g" % (loc["dx"], loc["dy"]), "from": e.get("id"),
                        "note": "a road mouth of the same construction near (around's mouths): give it as --mouth "
                                "to get a place with a link road"}
    return None


def cmd_fit(ns, sender=None):
    """fit: the box (--size, else one engine check at the point), around's list, the search here, then the best
    few asked of the engine; the first it would build is the answer."""
    sender = sender or send
    want, radius, step, angles, box, mouth, params, link = fit_plan(ns)
    checks = 3 if ns.check is None else ns.check
    base = {"res": ns.res.strip(), "dryRun": True, "engineCheck": True}
    if params is not None:
        base["params"] = params
    out = {"ok": True, "at": {"x": want[0], "y": want[1]}, "radius": radius}
    if box is None:
        first = sender("build", dict(base, at=want, angle=0.0), timeout=BUILD_TIMEOUT_SEC)
        fp = isinstance(first, dict) and first.get("footprint")
        if not fp:
            return {"ok": False, "error": "the engine's check gave no box for the construction (footprint): give "
                    "--size W,D", "check": first}
        box = (fp["x0"], fp["y0"], fp["x1"], fp["y1"])
        out["boxFrom"] = "the engine's check at the point, unturned"
    else:
        out["boxFrom"] = "--size"
    out["box"] = {"x0": box[0], "y0": box[1], "x1": box[2], "y1": box[3]}
    reach = radius + math.hypot(box[2] - box[0], box[3] - box[1]) + ((ns.catchment or FIT_CATCHMENT_DEFAULT) if ns.houses else 0) + 10
    if mouth and not ns.track:
        reach += (link or FIT_LINK_DEFAULT)[1]
    seen = sender("around", {"at": want, "radius": min(reach, AROUND_RADIUS_MAX), "limit": AROUND_LIMIT_MAX},
                  timeout=60)
    if not isinstance(seen, dict) or not seen.get("ok"):
        return {"ok": False, "error": "around failed: %s" % (seen.get("error") if isinstance(seen, dict) else seen)}
    if seen.get("truncated") or seen.get("timeTruncated") or seen.get("scanTruncated"):
        out["warning"] = "around's list was cut short (a smaller --radius): places may be taken that are not free"
    found = fit_search(seen.get("entities") or [], box, want, radius, angles, step=step, mouth=mouth,
                       track=ns.track, houses=ns.houses or 0,
                       catchment=(ns.catchment or FIT_CATCHMENT_DEFAULT) if ns.houses else None, link=link,
                       link_edges=ns.link_edge)
    if not mouth:
        hint = fit_mouth_hint(seen.get("entities") or [], ns.res.strip())
        if hint:
            out["mouthHint"] = hint
    out.update(tried=found["tried"], searched=found["searched"], complete=found["complete"],
               free=len(found["candidates"]), blockers=found["blockers"],
               aroundMs=(seen.get("ms") or {}).get("total"),
               note="boxes are the octree's (axis aligned), road and track widths a guess: the search narrows, the "
                    "engine's check decides")
    if found["tooFewHouses"]:
        out["tooFewHouses"] = found["tooFewHouses"]
    if not found["candidates"]:
        within = radius if found["complete"] else found["searched"]
        why = ("; %d free places had too few town buildings near" % found["tooFewHouses"]) if found["tooFewHouses"] else ""
        cut = "" if found["complete"] else " (the search stopped at %d places, %g m out: %s)" % (
            found["tried"], found["searched"], "a smaller --radius" if mouth and not ns.track else "a larger --step")
        out.update(ok=False, error="no free place within %g m of the point%s (the box %s, %d places tried)%s; most "
                   "in the way: %s" % (within, cut, out["box"], found["tried"], why,
                                    ", ".join("%s %s (%s) x%d" % (b["kind"], b["id"], b.get("name") or "-", b["count"])
                                              for b in found["blockers"][:3]) or "nothing"))
        return out
    if checks == 0:
        out["place"] = found["candidates"][0]
        out["checked"] = False
        out["candidates"] = found["candidates"][:10]
        return out
    refused = []
    for cand in found["candidates"][:checks]:
        res = sender("build", dict(base, at=[cand["x"], cand["y"]], angle=cand["angle"]), timeout=BUILD_TIMEOUT_SEC)
        if isinstance(res, dict) and res.get("ok") and res.get("checked") is False:
            # (the engine could not be asked: no verdict, not a refusal)
            out.update(ok=False, error="the engine could not be asked (%s): nothing checked" % res.get("engineCheck"),
                       place=cand, checked=False, candidates=found["candidates"][:10])
            return out
        # a warning or buildings it would take: judged in the engine's own context, where the build's (no fields
        # or buildings gathered) may still refuse it (a road's dry run said buildable with "fields will be
        # removed" and the build collided, 2026-11-23): not taken
        doubt = isinstance(res, dict) and (res.get("warnings") or res.get("buildingsInWay"))
        # infos with a buildable verdict (an older mod's answer: this one says refused, infosRefusal): the engine
        # refuses such a build all the same (2026-11-23, a depot over water, infos only): not taken
        if isinstance(res, dict) and res.get("buildable") and res.get("infos"):
            refused.append({"place": cand, "error": "the engine's check has infos (%s): such a build is refused"
                            % "; ".join(res.get("infos"))})
            continue
        # messages with critical not set and a buildable verdict (an older mod's answer: this one says refused,
        # errorsRefusal): a build sent without ignoreErrors is refused for them (2026-11-26, a road depot over a
        # road's node, "衝突" in the check, the build refused): not taken
        if isinstance(res, dict) and res.get("buildable") and res.get("errors"):
            refused.append({"place": cand, "error": "the engine's check has messages (%s): such a build is refused"
                            % "; ".join(res.get("errors")), "hits": res.get("hits")})
            continue
        if isinstance(res, dict) and res.get("ok") and res.get("buildable") and not doubt:
            out.update(place=cand, checked=True, engine={k: res.get(k) for k in ("verdict", "cost", "warnings",
                                                                                  "engineContext")})
            cmd = "build --res %s --at=%s,%s --angle %s" % (base["res"], cand["x"], cand["y"], cand["angle"])
            if params is not None:
                cmd += " --params " + shlex.quote(json.dumps(params))
            out["build"] = cmd
            if "link" in cand:
                lk = cand["link"]
                out["link"] = lk
                out["road"] = fit_link_road(lk)
                out["roadNote"] = ("build first, then road: its from is the mouth's node once the construction "
                                   "stands; the road piece itself was not asked of the engine")
                if lk["on"] == "edge":
                    out["roadNote"] += ("; it ends on the middle of piece %s, not on a node: road joins nodes only, "
                                        "so a new node there, not checked in a game (it may be refused)" % lk["pieces"][0])
            elif mouth and "joinAt" not in cand:
                out["roadNote"] = "not put on a road end"
            if refused:
                out["refusedFirst"] = refused
            return out
        if doubt and res.get("buildable"):
            refused.append({"place": cand, "error": "buildable only with warnings in the engine's own context: %s"
                            % "; ".join(res.get("warnings") or ["town buildings in the way"]),
                            "buildingsInWay": res.get("buildingsInWay")})
            continue
        refused.append({"place": cand, "error": res.get("error") if isinstance(res, dict) else str(res),
                        "hits": res.get("hits") if isinstance(res, dict) else None})
    out.update(ok=False, error="the engine refused (or doubted) the %d best places the search found" % len(refused),
               refused=refused, candidates=found["candidates"][:10])
    return out


def cmd_connect(ns):
    args = connect_args(ns)

    def progress(a):
        p = a.get("progress")
        print("... %s%s, %.0f s" % (a.get("phase") or "?", "" if p is None else " %.0f%%" % (num(p) * 100),
                                   num(a.get("seconds"))), file=sys.stderr)
    return send("connect", args, timeout=ns.timeout + CONNECT_GRACE_SEC, on_progress=progress)


MODHUB_GRACE_SEC = 30  # past the mod's own limits (wait / timeout), so its answer arrives before this gives up


def modhub_status_args(ns):
    args = {}
    if ns.folder:
        args["folder"] = ns.folder
    if ns.wait is not None:
        args["wait"] = ns.wait
    return args


def modhub_validate_args(ns):
    args = {"folder": ns.folder}
    if ns.timeout is not None:
        args["timeout"] = ns.timeout
    if ns.messages is not None:
        args["messages"] = ns.messages
    return args


# modhub publish: one mod uploaded from My Mods' staging area, as the page's Upload / Update button (one publish
# call for both; the page names it "Update" when mod.io holds the mod). Which of the two is never guessed: with
# --first-upload the staging folder must have no _metadata/mod.io_fileid.txt (the file that makes the next upload
# update the same mod.io page; with it, a "first upload" would make a second page); without it the file must be
# there, and its id goes to the mod, which updates only a mod whose mod.io id is that one and that mod.io holds. An
# update also needs mod.json's revision above the last one uploaded to that page (publish_history.jsonl, or
# --previous-revision when the history has none). The mod checks what the game knows (new or that mod, logged in,
# the validation); this side checks what only files show, as Lua has no io: the fileid file, the revision, a
# cover image (_metadata/0.png), and the lengths of the mod.io fields (_metadata/modinfo.json, --changelog: mod.io
# refuses a long name only after the upload began).
# Before it sends the command it writes a mark (publish_pending.json): an upload that timed out, failed half-way
# or lost its game may still have made a mod on mod.io, and a second one must not go until a person looked. The
# mark goes only when the upload succeeded and the fileid file appeared with the same mod.io id, or by
# `modhub publish-clear`.

# The configuration's modhub lists (none by default: validate and publish refuse every folder), sent with every
# modhub command (_modhub) so the mod checks by the same lists:
# - validateFolders: the staging folders validate takes (a typo, or another project's half-made folder, must not
#   start minutes of validation on the wrong mod)
# - publishFolders: the staging folders publish takes (separate: a folder fit to validate is not fit to upload by
#   that alone; a folder is added only once a person decided it)
# - publishedIds: the folders already on mod.io, each held to its page: a first upload of one is refused and an
#   update goes only to that id, also when _metadata/mod.io_fileid.txt went missing or was remade (then both this
#   tool and the game would take the folder for a new mod and make a second page). After a first upload, add the
#   folder and its new id there.
MODHUB_COMMANDS = ("modhubStatus", "modhubValidate", "modhubPublish")


def modhub_config():
    m = CONFIG["modhub"]
    return {"validateFolders": list(m["validateFolders"]), "publishFolders": list(m["publishFolders"]),
            "publishedIds": dict(m["publishedIds"])}

# --version X.Y.Z: sent as PublishSettings.additionalMetadata = {version = "X.Y.Z"} (a trial: whether mod.io's
# file version takes it is not known). It must be mod.json's revision written X*10000 + Y*100 + Z.
VERSION_RE = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)")
PENDING_NAME = "publish_pending.json"
FILEID_NAME = "mod.io_fileid.txt"
FILEID_WAIT_SEC = 60  # after a success, how long the game may take to write the fileid file
COVER_MAX_BYTES = 8 * 1024 * 1024  # mod.io's limit for a logo (Add Mod)
COVER_MIN_SIZE = (512, 288)  # mod.io's smallest logo
# mod.io's field limits, in characters (Python len, code points: mod.io counts characters, not bytes; a staging name
# of 37 characters and 59 UTF-8 bytes went up). The game sends modinfo.json's name as the mod.io name (its rename
# field stops at 50 too) and its summary and description; changelog is --changelog. name 50 and summary 250 are in
# mod.io's Add Mod documentation (and a 51+ name came back "code 13009"); description and changelog have no limit
# written there, 50000 is the one mod.io writes for metadata_blob, kept as a guard against a runaway text.
MODINFO_LIMITS = (("name", 50, "mod.io's"), ("summary", 250, "mod.io's"),
                  ("description", 50000, "this tool's guard of"))
CHANGELOG_MAX = 50000


def state_dir():
    """$XDG_STATE_HOME/tf3ctl, or ~/.local/state/tf3ctl: kept across reboots, unlike the runtime folder."""
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "tf3ctl")


def pending_path():
    return os.path.join(state_dir(), PENDING_NAME)


def read_pending():
    """The publish mark, or None. A mark that cannot be read still counts: it is answered as unreadable."""
    path = pending_path()
    if not os.path.lexists(path):
        return None
    try:
        with open(path, encoding="utf-8") as f:
            got = json.load(f)
        return got if isinstance(got, dict) else {"unreadable": "not a JSON object"}
    except (OSError, ValueError) as e:
        return {"unreadable": str(e)}


def write_pending(record):
    """Writes the mark through a temporary file linked into place (0600, in a 0700 folder): a reader never sees half
    a file, and the link fails if a mark appeared meanwhile (another tool process). A failure is a ToolError:
    without the mark, nothing is sent."""
    path = pending_path()
    folder = os.path.dirname(path)
    tmp = None
    try:
        os.makedirs(os.path.dirname(folder), exist_ok=True)
        _own_private_dir(folder)
        fd, tmp = tempfile.mkstemp(prefix=".publish-", suffix=".tmp", dir=folder)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(record, f)
            f.flush()
            os.fsync(f.fileno())
        os.link(tmp, path)  # exclusive, as O_EXCL: FileExistsError when a mark is there
    except FileExistsError:
        raise ToolError("a publish mark appeared meanwhile (%s); nothing was sent" % path)
    except OSError as e:
        raise ToolError("could not write the publish mark %s (%s): nothing was sent" % (path, e))
    finally:
        if tmp:
            with contextlib.suppress(OSError):
                os.remove(tmp)
    return path


HISTORY_NAME = "publish_history.jsonl"


def history_path():
    return os.path.join(state_dir(), HISTORY_NAME)


def append_history(record):
    """One line per upload sent (success or not) in publish_history.jsonl (0600), next to the mark: what went up,
    when, and how it ended, also after the mark is gone. A failure to write is a warning: the upload has happened."""
    path = history_path()
    line = json.dumps(record, sort_keys=True, ensure_ascii=False) + "\n"
    try:
        os.makedirs(os.path.dirname(os.path.dirname(path)), exist_ok=True)
        _own_private_dir(os.path.dirname(path))
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.write(fd, line.encode("utf-8"))
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError as e:
        print("warning: could not add to the publish history %s: %s" % (path, e), file=sys.stderr)
        return None
    return path


def clear_pending():
    """Removes the mark; returns what it said (None when there was none)."""
    got = read_pending()
    if got is None:
        return None
    os.remove(pending_path())
    return got


def staging_dir(folder=None):
    """<user data>/staging_area: next to the exchange folder, as the game's stdout.txt is (stdout_log)."""
    folder = folder or exchange_dir()
    return os.path.join(os.path.dirname(os.path.normpath(folder)), "staging_area")


def png_size(path):
    """(width, height) of a PNG file, None when it is not one."""
    with open(path, "rb") as f:
        head = f.read(24)
    if len(head) < 24 or head[:8] != b"\x89PNG\r\n\x1a\n" or head[12:16] != b"IHDR":
        return None
    return int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")


def read_fileid(name, meta):
    """The mod.io id in _metadata/mod.io_fileid.txt: None when there is no such file; ToolError when it is there but
    is not one id (digits)."""
    path = os.path.join(meta, FILEID_NAME)
    if not os.path.lexists(path):
        return None
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read().strip()
    except (OSError, ValueError) as e:
        raise ToolError("%s: cannot read _metadata/%s (%s); nothing was sent" % (name, FILEID_NAME, e))
    if not re.fullmatch(r"[0-9]{1,20}", text):
        raise ToolError("%s: _metadata/%s does not hold one mod.io id (%r); nothing was sent" % (name, FILEID_NAME, text[:40]))
    return text


def read_revision(name, mod_dir):
    """mod.json's revision (a whole number), None when it has none or cannot be read as JSON with one."""
    try:
        with open(os.path.join(mod_dir, "mod.json"), encoding="utf-8") as f:
            info = json.load(f)
    except (OSError, ValueError):
        return None
    rev = info.get("revision") if isinstance(info, dict) else None
    return rev if isinstance(rev, int) and not isinstance(rev, bool) else None


def uploaded_revision(name, modio_id):
    """The highest revision publish_history.jsonl records as gone up to mod.io mod modio_id from this folder (an
    upload mod.io answered with that id: success, partial errors, or a fileid that came late), None if none."""
    best = None
    try:
        with open(history_path(), encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return None
    for line in lines:
        try:
            h = json.loads(line)
        except ValueError:
            continue
        if not isinstance(h, dict) or h.get("folder") != name or str(h.get("modId")) != modio_id:
            continue
        # only the outcomes where mod.io took the upload: a failed one may be sent again with the same revision
        outcome = str(h.get("outcome") or "")
        if not (outcome == "partial" or outcome.startswith("success")):
            continue
        rev = h.get("revision")
        if isinstance(rev, int) and not isinstance(rev, bool) and (best is None or rev > best):
            best = rev
    return best


def publish_update_checks(name, mod_dir, modio_id, changelog, previous=None):
    """An update's own checks: mod.json's revision above the last one uploaded to that mod.io page. The last one is
    the history's; --previous-revision (previous) stands in only when the history has none, and must agree with it
    when it has one. Returns what the answer shows; ToolError when it fails (nothing is sent then)."""
    rev = read_revision(name, mod_dir)
    if rev is None:
        raise ToolError("%s: mod.json has no whole-number revision: an update must raise it; nothing was sent" % name)
    known = uploaded_revision(name, modio_id)
    if known is not None and previous is not None and previous != known:
        raise ToolError("%s: --previous-revision %d, but %s says revision %d went up to mod.io mod %s last; drop "
                        "--previous-revision; nothing was sent" % (name, previous, HISTORY_NAME, known, modio_id))
    last, source = (known, HISTORY_NAME) if known is not None else (previous, "--previous-revision")
    if last is None:
        raise ToolError("%s: %s records no revision uploaded to mod.io mod %s (uploads before the revision was "
                        "recorded): give --previous-revision N, the revision now on mod.io; nothing was sent"
                        % (name, HISTORY_NAME, modio_id))
    if rev <= last:
        raise ToolError("%s: mod.json's revision %d is not above %d, the last one uploaded to mod.io mod %s (%s): "
                        "raise it; nothing was sent" % (name, rev, last, modio_id, source))
    return {"modioId": modio_id, "revision": rev, "previousRevision": last, "previousFrom": source,
            "changelog": changelog}


def version_revision(version):
    """The revision a version X.Y.Z stands for (X*10000 + Y*100 + Z); ToolError when it is not X.Y.Z with whole
    numbers (no leading zeros, Y and Z 0-99)."""
    m = VERSION_RE.fullmatch(version or "")
    if m is None or len(version) > 20:
        raise ToolError("--version is X.Y.Z, whole numbers without leading zeros, Y and Z 0-99 (not %r); nothing was "
                        "sent" % (version or "")[:40])
    x, y, z = (int(g) for g in m.groups())
    return x * 10000 + y * 100 + z


def publish_version_checks(name, mod_dir, version):
    """--version against mod.json's revision. Returns {"version", "additionalMetadata"}; ToolError when they differ."""
    want = version_revision(version)
    rev = read_revision(name, mod_dir)
    if rev is None:
        raise ToolError("%s: mod.json has no whole-number revision to check --version %s against; nothing was sent"
                        % (name, version))
    if rev != want:
        raise ToolError("%s: --version %s is revision %d, but mod.json's revision is %d (that is %d.%d.%d); nothing "
                        "was sent" % (name, version, want, rev, rev // 10000, rev // 100 % 100, rev % 100))
    return {"version": version, "additionalMetadata": {"version": version}}


def publish_local_checks(name, folder=None, changelog=None, first_upload=True, previous=None, version=None):
    """What only the files show. Returns the checks; ToolError when one fails (nothing is sent then). first_upload:
    a new mod (no fileid file may be there) or an update (the fileid file must be there; its id is answered as
    fileid, the update's checks as update)."""
    mod_dir = os.path.join(staging_dir(folder), name)
    meta = os.path.join(mod_dir, "_metadata")
    if not os.path.isfile(os.path.join(mod_dir, "mod.json")):
        raise ToolError("no staging mod %s: %s has no mod.json" % (name, mod_dir))
    modio_id = read_fileid(name, meta)
    pinned = CONFIG["modhub"]["publishedIds"].get(name)
    if pinned is not None and first_upload:
        raise ToolError("%s is on mod.io already (mod %s): --first-upload would make a second page; nothing was sent"
                        % (name, pinned))
    if pinned is not None and modio_id != pinned:
        raise ToolError("%s is mod.io mod %s, but _metadata/%s %s: not updated; nothing was sent"
                        % (name, pinned, FILEID_NAME, "is missing" if modio_id is None else "says " + modio_id))
    if first_upload and modio_id is not None:
        raise ToolError("%s has _metadata/%s (mod.io mod %s): it was uploaded before, and --first-upload makes only "
                        "a new mod (a second mod.io page); leave out --first-upload to update that page; nothing "
                        "was sent" % (name, FILEID_NAME, modio_id))
    if not first_upload and modio_id is None:
        raise ToolError("%s has no _metadata/%s: it was never uploaded, so there is no mod.io page to update; a new "
                        "mod takes --first-upload; nothing was sent" % (name, FILEID_NAME))
    if first_upload and previous is not None:
        raise ToolError("--previous-revision is only for an update; nothing was sent")
    if previous is not None and previous < 1:
        raise ToolError("--previous-revision is a revision, a whole number of 1 or more; nothing was sent")
    update = None if first_upload else publish_update_checks(name, mod_dir, modio_id, changelog, previous)
    ver = publish_version_checks(name, mod_dir, version) if version is not None else None
    cover = os.path.join(meta, "0.png")
    if not os.path.isfile(cover):
        raise ToolError("%s has no _metadata/0.png: the page says \"No valid cover image found\"; nothing was sent" % name)
    size = os.path.getsize(cover)
    dims = png_size(cover)
    if dims is None:
        raise ToolError("%s: _metadata/0.png is not a PNG file; nothing was sent" % name)
    if size > COVER_MAX_BYTES:
        raise ToolError("%s: _metadata/0.png is %d bytes, more than mod.io's 8 MB; nothing was sent" % (name, size))
    if dims[0] < COVER_MIN_SIZE[0] or dims[1] < COVER_MIN_SIZE[1]:
        raise ToolError("%s: _metadata/0.png is %dx%d, smaller than mod.io's %dx%d; nothing was sent"
                        % ((name,) + dims + COVER_MIN_SIZE))
    metadata = publish_metadata_checks(name, meta, changelog)
    out = {"stagingFolder": name, "mode": "firstUpload" if first_upload else "update", "fileid": modio_id or False,
           "revision": read_revision(name, mod_dir),
           "cover": {"width": dims[0], "height": dims[1], "bytes": size}, "metadata": metadata}
    if ver is not None:
        out["version"] = ver["version"]
        out["additionalMetadata"] = ver["additionalMetadata"]
    if update is not None:
        update["name"] = metadata.get("nameText")
        out["update"] = update
    metadata.pop("nameText", None)
    return out


def publish_metadata_checks(name, meta, changelog=None):
    """Lengths of what goes into the mod.io fields against mod.io's limits. Returns them; ToolError naming every field
    over its limit (or a field missing: the game needs a name, a summary and a description for a new mod)."""
    path = os.path.join(meta, "modinfo.json")
    try:
        with open(path, encoding="utf-8") as f:
            info = json.load(f)
    except (OSError, ValueError) as e:
        raise ToolError("%s: cannot read _metadata/modinfo.json (%s); nothing was sent" % (name, e))
    if not isinstance(info, dict):
        raise ToolError("%s: _metadata/modinfo.json is not a JSON object; nothing was sent" % name)
    got, bad = {}, []
    fields = [("modinfo.json " + key, info.get(key), limit, whose) for key, limit, whose in MODINFO_LIMITS]
    if changelog is not None:
        fields.append(("--changelog", changelog, CHANGELOG_MAX, "this tool's guard of"))
    for label, value, limit, whose in fields:
        if not isinstance(value, str) or not value.strip():
            bad.append("%s is missing, empty or not a string" % label)
            continue
        got[label.split(" ")[-1].lstrip("-")] = {"length": len(value), "max": limit}
        if label == "modinfo.json name":
            got["nameText"] = value  # for an update's answer (the caller takes it out of the lengths)
        if len(value) > limit:
            bad.append("%s is %d characters, more than %s %d" % (label, len(value), whose, limit))
    tags = info.get("tags")
    if tags is not None and not (isinstance(tags, list) and all(isinstance(t, str) for t in tags)):
        bad.append("modinfo.json tags is not a list of strings")
    got["tags"] = {"count": len(tags) if isinstance(tags, list) else 0}
    if bad:
        raise ToolError("%s: %s; nothing was sent" % (name, "; ".join(bad)))
    return got


def modhub_publish_args(ns):
    """The mod's args for modhubPublish; ToolError for anything the mod would refuse too (said here, before a mark)."""
    folders = CONFIG["modhub"]["publishFolders"]
    if not folders:
        raise ToolError("publish takes no staging folder: list the ones it may upload in the configuration file %s "
                        "(modhub.publishFolders); nothing was sent" % CONFIG_INFO["path"])
    if ns.folder not in folders:
        raise ToolError("publish takes only these staging folders: %s (not %s)" % (", ".join(folders), ns.folder))
    if ns.public not in ("yes", "no"):
        raise ToolError("give --public yes or --public no: there is no default visibility")
    if not ns.changelog or not ns.changelog.strip():
        raise ToolError("give --changelog TEXT")
    if ns.previous_revision is not None and ns.first_upload:
        raise ToolError("--previous-revision is only for an update (without --first-upload)")
    if ns.update_metadata and ns.first_upload:
        raise ToolError("--update-metadata is only for an update (without --first-upload): a first upload always "
                        "sends modinfo.json's name, summary and description")
    if ns.version is not None:
        version_revision(ns.version)  # the form; against mod.json's revision in publish_local_checks
    # firstUpload or update: which one also needs the staging files (cmd_modhub_publish adds modioId for an update)
    args = {"folder": ns.folder, "public": ns.public == "yes", "changelog": ns.changelog}
    # updateMetadata: a first upload always sends the page's fields; an update only with --update-metadata, since
    # they replace mod.io's name, summary and description (a description written on mod.io, e.g. HTML through its
    # API, went back to modinfo.json's plain text when an update sent them, 2026-11-23)
    if ns.first_upload:
        args["firstUpload"] = True
        args["updateMetadata"] = True
    else:
        args["update"] = True
        args["updateMetadata"] = bool(ns.update_metadata)
    if ns.timeout is not None:
        args["timeout"] = ns.timeout
    if ns.messages is not None:
        args["messages"] = ns.messages
    return args


def wait_fileid(name, folder=None, wait=None):
    """The mod.io id the game wrote into _metadata/mod.io_fileid.txt, waiting up to FILEID_WAIT_SEC; None if none."""
    path = os.path.join(staging_dir(folder), name, "_metadata", FILEID_NAME)
    deadline = time.time() + (FILEID_WAIT_SEC if wait is None else wait)
    while True:
        try:
            with open(path, encoding="utf-8") as f:
                text = f.read().strip()
            if text:
                return text
        except OSError:
            pass
        if time.time() >= deadline:
            return None
        time.sleep(0.5)


def cmd_modhub_publish(ns):
    args = modhub_publish_args(ns)
    folder = exchange_dir()
    first = args.get("firstUpload") is True
    previous = ns.previous_revision

    def local_checks():
        got = publish_local_checks(args["folder"], folder, args["changelog"], first_upload=first, previous=previous,
                                   version=ns.version)
        if ns.version is not None:
            # the mod checks the version against the revision too (it cannot read mod.json)
            args["version"], args["revision"] = got["version"], got["revision"]
        if not first:
            if "modioId" in args and args["modioId"] != got["fileid"]:
                raise ToolError("%s changed meanwhile (%s, was %s); nothing was sent"
                                % (FILEID_NAME, got["fileid"], args["modioId"]))
            args["modioId"] = got["fileid"]
        return got
    local = local_checks()
    mark = read_pending()
    if mark is not None:
        raise ToolError("a publish mark is there (%s: %s): an earlier upload's outcome was not confirmed. Look at "
                        "mod.io (the account's mods) first, then `modhub publish-clear`; nothing was sent"
                        % (pending_path(), json.dumps(mark, sort_keys=True)))
    timeout = args.get("timeout", 900) + MODHUB_GRACE_SEC

    def progress(a):
        print("... %s%s, %.0f s%s" % (a.get("phase") or "?", " (" + a["state"] + ")" if a.get("state") else "",
                                     num(a.get("seconds")), ", publish called" if a.get("publishCalled") else ""),
              file=sys.stderr)
    # the dry run, and before a real upload the same run first: a refusal there leaves no mark behind
    pre = send("modhubPublish", dict(args, dryRun=True), timeout=timeout, on_progress=progress, folder=folder)
    pre["local"] = local
    if not first:
        pre["update"] = update_summary(local, pre)
    pre["additionalMetadata"] = additional_metadata(pre)
    metadata_answer(pre, args, first)
    if pre.get("ok") and sent_update_metadata(pre) is not args["updateMetadata"]:
        # a mod older than updateMetadata always sends true: an update would overwrite the page's description
        pre["ok"] = False
        pre["error"] = ("the mod would send updateMetadata %s, not %s (an older remote_probe in the game?); "
                        "nothing was sent" % (json.dumps(sent_update_metadata(pre)), json.dumps(args["updateMetadata"])))
    elif pre.get("ok") and pre["additionalMetadata"] != local.get("additionalMetadata"):
        # a mod older than --version drops the version without a word: then it would go up without it
        pre["ok"] = False
        pre["error"] = ("the mod would send additionalMetadata %s, not %s (an older remote_probe in the game?); "
                        "nothing was sent" % (json.dumps(pre["additionalMetadata"]),
                                              json.dumps(local.get("additionalMetadata"))))
    if ns.dry_run or not pre.get("ok"):
        if not ns.dry_run:
            pre["preflight"] = True
            pre["note"] = "the dry run before the upload refused it: nothing was uploaded and no mark was written"
        return pre
    # again just before: the dry run took a while
    local = local_checks()
    if read_pending() is not None:
        raise ToolError("a publish mark appeared meanwhile (%s); nothing was sent" % pending_path())
    path = write_pending({"v": 1, "folder": args["folder"], "owner": OWNER, "public": args["public"],
                          "firstUpload": first, "update": not first, "modioId": args.get("modioId"),
                          "updateMetadata": args["updateMetadata"],
                          "revision": local.get("revision"), "version": local.get("version"), "at": int(time.time()),
                          "atUtc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
    def history(outcome, res=None, fileid=None):
        res = res or {}
        # revision: what the next update compares with (uploaded_revision takes the records with a mod.io id)
        got = append_history({"v": 1, "at": int(time.time()), "atUtc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                              "owner": OWNER, "folder": args["folder"], "public": args["public"], "outcome": outcome,
                              "mode": "firstUpload" if first else "update", "modioId": args.get("modioId"),
                              "updateMetadata": args["updateMetadata"], "revision": local.get("revision"), "version": local.get("version"),
                              "publishCalled": res.get("publishCalled"), "modId": res.get("modId"), "fileid": fileid,
                              "error": res.get("error")})
        if got:
            res["history"] = got
    try:
        res = send("modhubPublish", dict(args, dryRun=False), timeout=timeout, on_progress=progress, folder=folder)
    except OwnerRefused:
        clear_pending()  # refused before anything was written for the game: nothing was uploaded
        raise
    except ToolError as e:
        history("no answer", {"error": str(e)})
        raise ToolError("%s; the outcome of the upload is not known, the publish mark stays (%s)" % (e, path))
    res["local"] = local
    if not first:
        res["update"] = update_summary(local, res)
    res["additionalMetadata"] = additional_metadata(res)
    metadata_answer(res, args, first)
    res["preflight"] = {"ok": True, "validation": pre.get("validation")}
    res["pendingMark"] = path
    result = res.get("result") if isinstance(res.get("result"), dict) else {}
    partial = result.get("partialErrors") or []
    if result.get("success") is not True or partial:
        res["pendingKept"] = True
        if res.get("publishCalled") is False:
            outcome = "not sent"
            res["note"] = ("publish was not called: nothing was uploaded, but the mark stays (it goes only by "
                           "`modhub publish-clear`)")
        elif partial:
            outcome = "partial"
            res["note"] = ("mod.io took the mod with %d partial errors: the mark stays; look at the mod on mod.io "
                           "before `modhub publish-clear`" % len(partial))
        else:
            outcome = res.get("outcome") or "failed"
            res["note"] = ("the upload did not succeed or its outcome is not known: the mark stays; look at mod.io "
                           "before `modhub publish-clear`")
        history(outcome, res, fileid=wait_fileid(args["folder"], folder, wait=0) if partial else None)
        return res
    got = wait_fileid(args["folder"], folder)
    res["fileid"] = got
    if not first and res.get("modId") != args["modioId"]:
        # the mod refuses this too; kept here as well: an update that came back as another mod.io mod is a new page
        res["pendingKept"] = True
        res["ok"] = False
        res["error"] = ("the update of mod.io mod %s came back as mod.io mod %s: the mark stays; look at the "
                        "account's mods on mod.io before `modhub publish-clear`" % (args["modioId"], res.get("modId")))
        history("success, other mod.io id", res, fileid=got)
        return res
    if got is None or got != res.get("modId"):
        res["pendingKept"] = True
        res["ok"] = False
        res["error"] = ("mod.io took the mod (id %s), but %s %s: the mark stays; write it or look at mod.io before "
                        "`modhub publish-clear`" % (res.get("modId"), FILEID_NAME,
                                                    "did not appear in %d s" % FILEID_WAIT_SEC if got is None
                                                    else "says %s" % got))
        history("success, fileid missing" if got is None else "success, fileid differs", res, fileid=got)
        return res
    history("success", res, fileid=got)  # before the mark goes: the record outlives it
    clear_pending()
    res["pendingCleared"] = True
    return res


def additional_metadata(answer):
    """The additionalMetadata the mod's settings say it sends (or sent): None when it sends none."""
    settings = answer.get("settings") if isinstance(answer.get("settings"), dict) else {}
    return settings.get("additionalMetadata")


def sent_update_metadata(answer):
    """The updateMetadata the mod's settings say it sends (or sent): None when the answer has no settings."""
    settings = answer.get("settings") if isinstance(answer.get("settings"), dict) else {}
    return settings.get("updateMetadata")


UPDATE_METADATA_WARNING = (
    "updateMetadata is sent: the mod.io page's name, summary and description are replaced with "
    "_metadata/modinfo.json's (plain text). A description written on mod.io by other means (e.g. HTML through "
    "mod.io's API) is overwritten and has to be put back after the update.")


def metadata_answer(answer, args, first):
    """Says in the answer whether the page's fields go up (updateMetadata, as the tool asked for it) and what that
    does to the mod.io page: a warning for an update with --update-metadata, a note for one without it."""
    um = args["updateMetadata"]
    answer["updateMetadata"] = um
    if first:
        answer["updateMetadataNote"] = ("a first upload sends modinfo.json's name, summary and description (the "
                                        "page's own setting; --update-metadata is only for an update)")
        return
    if um:
        answer["updateMetadataWarning"] = UPDATE_METADATA_WARNING
        return
    note = ("updateMetadata is not sent: the mod.io page's name, summary and description stay as they are; "
            "modinfo.json's are not sent (--update-metadata sends them, and overwrites the page's description)")
    up = answer.get("update") if isinstance(answer.get("update"), dict) else {}
    name, title = up.get("name"), up.get("modioTitle")
    if isinstance(name, str) and isinstance(title, str) and name != title:
        note += "; modinfo.json's name %s is not mod.io's title %s, which stays" % (json.dumps(name), json.dumps(title))
    answer["updateMetadataNote"] = note


def update_summary(local, answer):
    """What an update is about to change (or changed), in one place: the mod.io id, the name (modinfo.json's, which
    the update sends, and mod.io's title now), the revision against the last one uploaded, and the changelog."""
    up = local.get("update") or {}
    checks = answer.get("checks") if isinstance(answer.get("checks"), dict) else {}
    modio = checks.get("modio") if isinstance(checks.get("modio"), dict) else {}
    return {"modioId": up.get("modioId"), "name": up.get("name"), "modioTitle": modio.get("title"),
            "modioVisible": modio.get("visible"), "modioVersion": modio.get("version"),
            "revision": up.get("revision"), "previousRevision": up.get("previousRevision"),
            "previousFrom": up.get("previousFrom"), "changelog": up.get("changelog")}


def cmd_modhub_publish_clear(ns):
    """Removes the mark, with --yes only, and not while the game's mod says the upload is still Publishing."""
    mark = read_pending()
    out = {"ok": True, "path": pending_path(), "mark": mark}
    if mark is None:
        out.update(cleared=None, note="there was no publish mark")
        return out
    if not ns.yes:
        raise ToolError("the publish mark says %s: look at the account's mods on mod.io first, then run this again "
                        "with --yes" % json.dumps(mark, sort_keys=True))
    if game_pids():
        args = {"wait": 0}
        if isinstance(mark.get("folder"), str):
            args["folder"] = mark["folder"]
        try:
            st = send("modhubStatus", args, timeout=MODHUB_GRACE_SEC)
        except ToolError as e:  # in a save, loading, no probe: nobody to ask; a person said --yes
            st = None
            out["statusNote"] = "could not ask the game (%s)" % e
        publishing = [m.get("folder") for m in (st or {}).get("mods") or [] if m.get("state") == "Publishing"]
        if publishing:
            raise ToolError("the game says the upload of %s is still Publishing: the mark stays until it has a "
                            "result (modhub status)" % ", ".join(str(f) for f in publishing))
    out["cleared"] = clear_pending()
    return out


MOD_TIMEOUT_SEC = 30
MOD_LIST_TIMEOUT_SEC = 60  # a list requires every candidate mod's file once
MOD_EXT_TIMEOUT_MAX = 120  # the mod's core.EXT_TIMEOUT_MAX: how long a command may defer its answer
MOD_EXT_MARGIN_SEC = 5  # the mod's own timeout comes this much before the tool's, so its error answer arrives
# a list's --timeout: below 5 s the mod's poll (every 2 s when idle) leaves next to no time to require the files;
# above 10 minutes a hung require is better seen as hung than waited for
MOD_LIST_TIMEOUT_MIN = 5
MOD_LIST_TIMEOUT_MAX = 600


def mod_call_args(ns):
    """(wire command, args) for mod: modList, or modRead with the command's own JSON arguments."""
    # --list stands alone: a guard outside that lets "mod --list" through by its shape must not let a command
    # ride along with it, so anything after it is an error before anything is sent
    if ns.list and (ns.mod_id is not None or ns.mod_command is not None or ns.mod_json is not None):
        raise ToolError("mod --list takes nothing else (one mod's commands: mod <modId>)")
    if ns.read_only and ns.mod_command is None:
        raise ToolError("--read-only goes with a command: mod <modId> <command> [JSON] --read-only")
    if ns.list or ns.mod_command is None:
        # (refused like a command's --timeout below; NaN fails both comparisons, so it is refused too)
        if ns.timeout is not None and not (MOD_LIST_TIMEOUT_MIN <= ns.timeout <= MOD_LIST_TIMEOUT_MAX):
            raise ToolError("--timeout for a list must be between %d and %d seconds" % (MOD_LIST_TIMEOUT_MIN,
                                                                                    MOD_LIST_TIMEOUT_MAX))
        return "modList", ({"mod": ns.mod_id} if ns.mod_id else {})
    if ns.mod_json is None:
        call_args = {}
    else:
        try:
            call_args = json.loads(ns.mod_json)  # (NaN / Infinity: to_lua refuses them)
        except ValueError as e:
            raise ToolError("the arguments are not JSON: %s" % e)
        if not isinstance(call_args, (dict, list)):
            raise ToolError("the arguments must be a JSON object or list, e.g. '{\"speed\": 0}'")
    t = MOD_TIMEOUT_SEC if ns.timeout is None else ns.timeout
    if not (MOD_EXT_MARGIN_SEC + 1 <= t <= MOD_EXT_TIMEOUT_MAX + MOD_EXT_MARGIN_SEC):
        raise ToolError("--timeout must be between %d and %d seconds" % (MOD_EXT_MARGIN_SEC + 1,
                                                                      MOD_EXT_TIMEOUT_MAX + MOD_EXT_MARGIN_SEC))
    return "modRead", {"mod": ns.mod_id, "command": ns.mod_command, "args": call_args,
                       "timeout": t - MOD_EXT_MARGIN_SEC}


def cmd_mod(ns):
    """Another mod's commands. A command runs as modRead first: the mod runs it there only when the mod tagged it
    reads, and otherwise answers needsChange without running anything; it then goes again as modChange, a command
    in CHANGES_GAME, so the owner check (and coop) decide over it as over every game-changing command. With
    --read-only it is not sent again: NotReadOnly instead, so a caller (or a guard) can count on a read."""
    wire, args = mod_call_args(ns)
    if wire == "modList":
        return send("modList", args, timeout=MOD_LIST_TIMEOUT_SEC if ns.timeout is None else ns.timeout)
    t = MOD_TIMEOUT_SEC if ns.timeout is None else ns.timeout
    res = send("modRead", args, timeout=t)
    if isinstance(res, dict) and res.get("needsChange") is True:
        if ns.read_only:
            raise NotReadOnly("refused: %s %s is not tagged reads by its mod (tag %s), and --read-only does not send "
                              "it again as a change; the mod ran nothing"
                              % (ns.mod_id, ns.mod_command, res.get("tag") or "none"))
        res = send("modChange", args, timeout=t)
    return res


EVAL_TIMEOUT_SEC = 45  # the mod waits 15 s for the game script's answer (--gs)
EVAL_CODE_MAX = 100000  # the mod's core.EVAL_CODE_MAX
EVAL_DEPTH_MAX = 16  # the mod's limits: core.EVAL_DEPTH (6) up to this
EVAL_CHARS_MIN, EVAL_CHARS_MAX = 1000, 1000000  # core.EVAL_CHARS (200000) between these
EVAL_GS_NOTE = ("--gs: the answer stays in the probe's game-script state for about a minute (saving within it keeps "
                "it in the save)")


def eval_args(ns):
    """(wire command, args) for eval: the code from the argument or --file, the limits, --gs."""
    if ns.code is not None and ns.file is not None:
        raise ToolError("give the code or --file, not both")
    if ns.file is not None:
        try:
            with open(ns.file, encoding="utf-8") as f:
                code = f.read()
        except (OSError, UnicodeDecodeError) as e:
            raise ToolError("cannot read %s: %s" % (ns.file, e))
    elif ns.code is not None:
        code = ns.code
    else:
        raise ToolError("give the Lua code to run: eval 'CODE' or eval --file FILE.lua")
    if not code.strip():
        raise ToolError("the code is empty: nothing to run")
    if len(code) > EVAL_CODE_MAX:
        raise ToolError("the code is longer than %d characters" % EVAL_CODE_MAX)
    args = {"code": code}
    if ns.depth is not None:
        if not (1 <= ns.depth <= EVAL_DEPTH_MAX):
            raise ToolError("--depth must be between 1 and %d" % EVAL_DEPTH_MAX)
        args["depth"] = ns.depth
    if ns.max_chars is not None:
        if not (EVAL_CHARS_MIN <= ns.max_chars <= EVAL_CHARS_MAX):
            raise ToolError("--max-chars must be between %d and %d" % (EVAL_CHARS_MIN, EVAL_CHARS_MAX))
        args["maxChars"] = ns.max_chars
    if ns.gs:
        args["gs"] = True
    return ("evalWrite" if ns.write else "eval"), args


def cmd_eval(ns):
    """eval: Lua code in the running game, and its value back. Only with "eval": true in the configuration file.
    Without --write the mod runs it in an environment without the entry points that write or send (read only, any
    save); --write runs it with every global (a test save; during coop only with --user-asked; save entry points
    replaced). --gs runs it in the probe's game script instead of the GUI's Lua state."""
    if not CONFIG["eval"]:
        raise config_needed("eval (any Lua code sent into the running game)", "eval")
    wire, args = eval_args(ns)
    res = send(wire, args, timeout=EVAL_TIMEOUT_SEC)
    if isinstance(res, dict) and args.get("gs") and res.get("where") == "script":
        res["gsNote"] = EVAL_GS_NOTE
    return res


def cmd_modhub(ns):
    """My Mods in the main menu: status (read only), validate (one staging mod), publish (one new mod, or an update
    of the mod.io page of the folder's fileid)."""
    if ns.action == "publish":
        return cmd_modhub_publish(ns)
    if ns.action == "publish-clear":
        return cmd_modhub_publish_clear(ns)
    if ns.action == "status":
        args = modhub_status_args(ns)
        wait = args.get("wait", 30)
        return send("modhubStatus", args, timeout=wait + MODHUB_GRACE_SEC)
    args = modhub_validate_args(ns)

    def progress(a):
        p = a.get("progress")
        print("... %s%s%s, %.0f s" % (a.get("phase") or "?", "" if p is None else " %.0f%%" % (num(p) * 100),
                                     " (" + a["task"] + ")" if a.get("task") else "", num(a.get("seconds"))),
              file=sys.stderr)
    return send("modhubValidate", args, timeout=args.get("timeout", 300) + MODHUB_GRACE_SEC, on_progress=progress)


def industry_workers_args(ns):
    return {} if ns.entity is None else {"entity": ns.entity}


def vehicles_args(ns):
    """The vehicles command's args: line and limit as always; --entity (ids, comma-separated), --state and --since
    only when given, so a plain call sends what it always sent."""
    args = {"limit": ns.limit}
    if ns.line is not None:
        args["line"] = ns.line
    if ns.entity is not None:
        try:
            ids = [int(x) for x in ns.entity.split(",") if x.strip()]
        except ValueError:
            raise ToolError("--entity takes vehicle ids, comma-separated")
        if not ids or any(i < 0 for i in ids):
            raise ToolError("--entity takes vehicle ids, comma-separated")
        args["entities"] = ids
    if ns.since is not None and not ns.state:
        raise ToolError("--since goes with --state")
    if ns.state:
        args["state"] = True
    if ns.since is not None:
        args["since"] = ns.since
    if getattr(ns, "at_terminal", False):
        if not ns.state:
            raise ToolError("--at-terminal goes with --state")
        args["atTerminal"] = True
    every_checks(ns)
    return args


PERSONS_MIN_EVERY_SEC = 0.5  # the mod reads the command file every 0.25 s while active: faster only queues up


PERSONS_MAX = 2000  # the mod's PERSONS_MAX (remote_core.lua)


def persons_args(ns):
    """The persons command's args: --vehicle, --line, --town or --destination (argparse makes it one of them), --limit
    when given."""
    args = {}
    for k in ("vehicle", "line", "town", "destination"):
        if getattr(ns, k, None) is not None:
            args[k] = getattr(ns, k)
            break
    if ns.limit is not None:
        if not 1 <= ns.limit <= PERSONS_MAX:
            raise ToolError("--limit must be from 1 to %d" % PERSONS_MAX)
        args["limit"] = ns.limit
    every_checks(ns)
    return args


def every_checks(ns):
    """--every and --count as persons and vehicles take them (absent on a namespace without them: nothing to check)."""
    every, count = getattr(ns, "every", None), getattr(ns, "count", None)
    if count is not None and every is None:
        raise ToolError("--count goes with --every")
    if every is not None and not (math.isfinite(every) and every >= PERSONS_MIN_EVERY_SEC):
        raise ToolError("--every must be a number of seconds, at least %g" % PERSONS_MIN_EVERY_SEC)
    if count is not None and count < 1:
        raise ToolError("--count must be 1 or more")


def no_answer_reason(err):
    """Why a sample got nothing, from the tool's own error: timeout (the mod took the command but did not answer
    in time), notPickedUp (the mod did not read the command file), file (an exchange file could not be read or
    written), other."""
    msg = str(err)
    if isinstance(err, OSError) or msg.startswith("cannot read"):
        return "file"
    if msg.startswith("no answer to command"):
        return "timeout"
    if "did not pick up" in msg:
        return "notPickedUp"
    return "other"


def persons_every(ns, out=None, sleep=time.sleep, clock=time.time):
    """persons --every (sample_every)."""
    return sample_every("persons", persons_args(ns), ns, out=out, sleep=sleep, clock=clock)


def vehicles_every(ns, out=None, sleep=time.sleep, clock=time.time):
    """vehicles --every (sample_every): with --state each line has the game time of its read (gameTime)."""
    return sample_every("vehicles", vehicles_args(ns), ns, out=out, sleep=sleep, clock=clock)


def sample_every(cmd, args, ns, out=None, sleep=time.sleep, clock=time.time):
    """--every of a read-only command (persons, vehicles): samples on a fixed grid of ns.every seconds from the
    start (a slow answer does not drift the times), each as one compact JSON line with sample (its slot on the
    grid, 1-based) and unixTime (when the tool sent it) added, until ns.count samples or Ctrl-C. A sample that ran
    past later slots does not make up for them in a burst: those slots are skipped (the next line says how many,
    under skipped) and the loop waits for the next one. Read only, as one call is. An answer that is not ok, or a
    game that cannot answer (menu, closed), ends the loop as a last line with ok false; its exit code is the
    loop's. No answer is a line with noAnswer and reason, and the loop goes on (exit code 2 at the end)."""
    out = out or sys.stdout
    start = clock()
    slot = taken = gaps = skipped = 0
    try:
        while ns.count is None or taken < ns.count:
            # the next slot not yet past: start + slot * every >= now
            due = max(slot, math.ceil((clock() - start) / ns.every - 1e-9)) if slot else 0
            missed, slot = due - slot, due
            wait = start + slot * ns.every - clock()
            if wait > 0:
                sleep(wait)
            slot += 1
            skipped += missed
            sent = clock()
            code = 0
            try:
                res = send(cmd, args)
                if not res.get("ok"):
                    code = 1
            except GameNotReady as e:
                res, code = {"ok": False, "error": str(e), "gameState": e.state}, 3
            except (ToolError, OSError) as e:
                # nothing in time (an autosave or a long frame holds the game up): noted, and the next sample is
                # tried, so a voyage's record does not end on one stall
                res = {"ok": False, "error": str(e), "noAnswer": True, "reason": no_answer_reason(e)}
                gaps += 1
            res = dict(res, sample=slot, unixTime=round(sent, 3))
            if missed:
                res["skipped"] = missed
            out.write(json.dumps(res, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")
            out.flush()
            taken += 1  # after the line: a sample cut short by Ctrl-C is not counted
            if code:
                return code
    except KeyboardInterrupt:
        persons_warn(taken, gaps, skipped)
        raise
    persons_warn(taken, gaps, skipped)
    return 2 if gaps else 0


def persons_warn(taken, gaps, skipped):
    if gaps:
        print("warning: %d of %d samples got no answer (noAnswer and reason in their lines)" % (gaps, taken),
              file=sys.stderr)
    if skipped:
        print("warning: %d slots skipped: a sample took longer than --every (skipped in the next line)" % skipped,
              file=sys.stderr)


def models_args(ns):
    args = {"limit": ns.limit}
    if ns.grep is not None:
        if not ns.grep:
            raise ToolError("--grep needs a part of the name")
        args["grep"] = ns.grep
    if ns.carrier:
        args["carrier"] = ns.carrier
    mu = getattr(ns, "mu", None)
    if mu is not None:
        if mu is not True and not mu:
            raise ToolError("--mu takes a part of the name, or nothing for all")
        if ns.carrier:
            raise ToolError("--carrier does not go with --mu (multiple units are trains)")
        if ns.grep is not None:
            raise ToolError("--grep does not go with --mu (give the filter as --mu FILTER)")
        args["mu"] = mu
    return args


# the base's calendar slider steps (game_bar_widgets.tl); the mod checks them again (remote_core.lua)
CALENDAR_FACTORS = (0.0, 0.25, 0.5, 1.0, 2.0, 4.0)
CALENDAR_MIN_MS, CALENDAR_MAX_MS = 100, 3600000


def calendar_speed_args(ns):
    """(cmd, args): calendarSpeed (read only) without a value, else calendarSpeedSet with factor or millisPerDay."""
    factor, ms = ns.factor, ns.millis_per_day
    if factor is not None and ms is not None:
        raise ToolError("give a factor or --millis-per-day, not both")
    if factor is None and ms is None:
        return "calendarSpeed", {}
    if factor is not None:
        if factor not in CALENDAR_FACTORS:
            raise ToolError("the factor must be one of the calendar slider's steps: 0, 0.25, 0.5, 1, 2, 4 "
                            "(or give --millis-per-day)")
        return "calendarSpeedSet", {"factor": factor}
    if ms != 0 and not CALENDAR_MIN_MS <= ms <= CALENDAR_MAX_MS:
        raise ToolError("--millis-per-day must be 0 or between %d and %d" % (CALENDAR_MIN_MS, CALENDAR_MAX_MS))
    return "calendarSpeedSet", {"millisPerDay": ms}


def running_costs_args(ns):
    """(cmd, args): runningCosts (read only) without a --set-* / --scale-*, else runningCostsSet with its ops."""
    if not ns.model or not ns.model.strip():
        raise ToolError("--model needs an id or a part of the file name (models --grep lists them)")
    args = {"model": ns.model}
    if ns.limit is not None:
        args["limit"] = ns.limit
    ops = {}

    def add(field, kind, value, flag):
        if field not in RUNNING_COST_FIELDS:
            raise ToolError("%s: the field must be one of %s" % (flag, ", ".join(RUNNING_COST_FIELDS)))
        if field in ops:
            raise ToolError("%s: %s is given twice" % (flag, field))
        if not math.isfinite(value):
            raise ToolError("%s: a number is needed" % flag)
        ops[field] = {"field": field, kind: value}

    for flag, field, kind in (("--set-running", "runningCosts", "set"), ("--scale-running", "runningCosts", "scale"),
                              ("--set-maintenance", "maintenanceScale", "set"),
                              ("--scale-maintenance", "maintenanceScale", "scale")):
        v = getattr(ns, flag[2:].replace("-", "_"))
        if v is not None:
            add(field, kind, v, flag)
    for flag, kind in (("--set", "set"), ("--scale", "scale")):
        for item in getattr(ns, kind + "_fields") or []:
            name, sep, value = item.partition("=")
            try:
                num = float(value)
            except ValueError:
                num = None
            if not sep or num is None:
                raise ToolError("%s takes FIELD=NUMBER (%s)" % (flag, ", ".join(RUNNING_COST_FIELDS)))
            add(name.strip(), kind, num, flag)
    if not ops:
        if ns.where is not None:
            raise ToolError("--where goes with a write (--set-* / --scale-*)")
        return "runningCosts", args
    args["ops"] = [ops[f] for f in RUNNING_COST_FIELDS if f in ops]
    args["where"] = ns.where or "script"
    return "runningCostsSet", args


def finance_args(ns):
    args = {}
    if ns.columns is not None:
        args["columns"] = ns.columns
    if ns.since is not None:
        if not math.isfinite(ns.since) or ns.since < 0:
            raise ToolError("--since needs a game time (a number >= 0; status / finance give gameTime)")
        args["since"] = ns.since
    if ns.vehicles is not None:
        try:
            ids = [int(x) for x in ns.vehicles.split(",") if x.strip()]
        except ValueError:
            ids = []
        if not ids or any(i < 0 for i in ids):
            raise ToolError("--vehicles takes vehicle ids, comma-separated")
        args["vehicles"] = ids
    return args


def industry_stocks_args(ns):
    args = industry_workers_args(ns)
    if ns.grep is not None:
        if not ns.grep:
            raise ToolError("--grep needs a part of the name")
        args["grep"] = ns.grep
    if ns.all_params:
        args["allParams"] = True
    return args


PARCELS_RECT_MAX = 2000  # the mod's core.PARCELS_RECT_MAX (m, a side)


def parcels_args(ns):
    """parcels: --edge ID or --rect x0,y0,x1,y1 (at most PARCELS_RECT_MAX m a side; the mod checks again)."""
    if (ns.edge is None) == (ns.rect is None):
        raise ToolError("give --edge ID or --rect x0,y0,x1,y1")
    if ns.edge is not None:
        if ns.edge < 0:
            raise ToolError("--edge must be a road piece's entity id (0 or more)")
        args = {"edge": ns.edge}
        if ns.list is False:
            args["list"] = False
        return args
    try:
        v = [float(x) for x in ns.rect.split(",")]
    except ValueError:
        raise ToolError("--rect must be numbers: x0,y0,x1,y1")
    if len(v) != 4 or any(x != x or abs(x) == float("inf") for x in v):
        raise ToolError("--rect must be x0,y0,x1,y1 (finite numbers)")
    if abs(v[2] - v[0]) > PARCELS_RECT_MAX or abs(v[3] - v[1]) > PARCELS_RECT_MAX:
        raise ToolError("--rect: at most %d m a side" % PARCELS_RECT_MAX)
    args = {"rect": v}
    if ns.list:
        args["list"] = True
    return args


AROUND_RADIUS_MAX = 2000  # the mod's core.AROUND_RADIUS.max
AROUND_LIMIT_MAX = 2000  # the mod's core.AROUND_LIMIT.max
AROUND_KINDS = ("street", "track", "node", "town_building", "station", "depot", "industry", "construction", "field",
                "asset", "town", "model", "moving", "other", "map")  # the mod's core.AROUND_KINDS


EDGE_LANES_MAX = 20  # the mod's core.EDGE_LANES_MAX


def lanes_args(ns):
    """lanes: --edge ID[,ID...] (1-20 piece ids), --no-network; checked as the mod checks them."""
    parts = [p.strip() for p in (ns.edge or "").split(",")]
    try:
        ids = [int(p) for p in parts]
    except ValueError:
        raise ToolError("--edge must be piece ids separated by commas (around --kinds street lists them)")
    if not ids or len(ids) > EDGE_LANES_MAX or any(i < 0 for i in ids):
        raise ToolError("--edge: 1-%d piece ids, each 0 or more" % EDGE_LANES_MAX)
    args = {"edges": ids}
    if ns.no_network:
        args["network"] = False
    return args


def around_args(ns):
    """around: --at x,y, --radius, --kinds a,b (or all), --limit, --lanes; checked as the mod checks them."""
    try:
        at = [float(x) for x in (ns.at or "").split(",")]
    except ValueError:
        raise ToolError("--at must be numbers: x,y (for a negative x write --at=-100,50)")
    if len(at) != 2 or any(x != x or abs(x) == float("inf") for x in at):
        raise ToolError("--at must be x,y (finite numbers)")
    args = {"at": at}
    if ns.radius is not None:
        if not (0 < ns.radius <= AROUND_RADIUS_MAX):
            raise ToolError("--radius must be more than 0 and at most %d m" % AROUND_RADIUS_MAX)
        args["radius"] = ns.radius
    if ns.kinds is not None:
        kinds = [k.strip() for k in ns.kinds.split(",") if k.strip()]
        bad = [k for k in kinds if k != "all" and k not in AROUND_KINDS]
        if not kinds or bad:
            raise ToolError("--kinds: one or more of all, %s%s" % (", ".join(AROUND_KINDS),
                                                                  (" (not %s)" % ", ".join(bad)) if bad else ""))
        args["kinds"] = ",".join(kinds)
    if ns.limit is not None:
        if not 1 <= ns.limit <= AROUND_LIMIT_MAX:
            raise ToolError("--limit must be 1-%d" % AROUND_LIMIT_MAX)
        args["limit"] = ns.limit
    if getattr(ns, "lanes", False):
        args["lanes"] = True
    return args


STRIPS_EDGES_MAX = 20  # the mod's core.STRIPS_EDGES_MAX
STRIPS_RADIUS_MAX = 500  # the mod's core.STRIPS_RADIUS.max (default 30)
STRIPS_LIMIT_MAX = 40  # the mod's core.STRIPS_LIMIT.max (default 20)
STRIPS_GS_DEPTH = 16  # eval's most: the answer nests 8 deep (strips, groups, ranges, bounds)
STRIPS_GS_CHARS = 1000000  # eval's most
# the answer's lists: eval --gs gives an empty Lua list as {} (its dump does not know it was a list)
STRIPS_LISTS = {"strips", "groups", "ranges", "edges", "rangeGroups", "ends", "deadEnds", "unread", "asked",
                "pieces", "list", "models", "missing", "bounds"}


def strips_args(ns):
    """strips: --edge ID[,ID...] or --at X,Y [--radius R], --limit; checked as the mod checks them."""
    if (ns.edge is None) == (ns.at is None):
        raise ToolError("give --edge ID[,ID...] or --at X,Y (one of them)")
    args = {}
    if ns.edge is not None:
        if ns.radius is not None:
            raise ToolError("--radius goes with --at, not --edge")
        parts = [p.strip() for p in ns.edge.split(",")]
        try:
            ids = [int(p) for p in parts]
        except ValueError:
            raise ToolError("--edge must be piece ids separated by commas (around --kinds track lists them)")
        if not ids or len(ids) > STRIPS_EDGES_MAX or any(i < 0 for i in ids):
            raise ToolError("--edge: 1-%d piece ids, each 0 or more" % STRIPS_EDGES_MAX)
        args["edges"] = ids
    else:
        try:
            at = [float(x) for x in ns.at.split(",")]
        except ValueError:
            raise ToolError("--at must be numbers: x,y (for a negative x write --at=-100,50)")
        if len(at) != 2 or any(x != x or abs(x) == float("inf") for x in at):
            raise ToolError("--at must be x,y (finite numbers)")
        args["at"] = at
        if ns.radius is not None:
            if not (0 < ns.radius <= STRIPS_RADIUS_MAX):
                raise ToolError("--radius must be more than 0 and at most %d m" % STRIPS_RADIUS_MAX)
            args["radius"] = ns.radius
    if ns.limit is not None:
        if not 1 <= ns.limit <= STRIPS_LIMIT_MAX:
            raise ToolError("--limit must be 1-%d" % STRIPS_LIMIT_MAX)
        args["limit"] = ns.limit
    return args


def strips_gs_code(args):
    """The Lua eval --gs runs for strips --gs: remote_strips.lua's run, in the game script's state, with args."""
    def lua(v):
        if isinstance(v, bool):
            return "true" if v else "false"
        if isinstance(v, (int, float)):
            return repr(v)
        if isinstance(v, list):
            return "{" + ", ".join(lua(x) for x in v) + "}"
        if isinstance(v, dict):
            return "{" + ", ".join("%s = %s" % (k, lua(x)) for k, x in sorted(v.items())) + "}"
        raise ToolError("strips: cannot write %r as Lua" % (v,))
    return ('return require("hummer_remote_probe::/remote_strips.lua").run(%s, { where = "gs" })' % lua(args))


def strips_lists(v, key=None):
    """{} back to [] under the answer's list keys (eval --gs's dump)."""
    if isinstance(v, dict):
        if key in STRIPS_LISTS and not v:
            return []
        return {k: strips_lists(x, k) for k, x in v.items()}
    if isinstance(v, list):
        return [strips_lists(x) for x in v]
    return v


def cmd_strips(ns):
    """strips: the engine's parallel strips of tracks (read only). Without --gs read in the GUI's Lua state; with --gs
    in the probe's game script, through eval --gs (so only with "eval": true in the configuration file, and with the
    mod setting gameScript on: --param hummer_remote_probe:gameScript=2)."""
    args = strips_args(ns)
    if not ns.gs:
        return send("strips", args, timeout=60)
    if not CONFIG["eval"]:
        raise config_needed("strips --gs (sent through eval --gs)", "eval")
    res = send("eval", {"code": strips_gs_code(args), "gs": True, "depth": STRIPS_GS_DEPTH,
                        "maxChars": STRIPS_GS_CHARS}, timeout=EVAL_TIMEOUT_SEC)
    if not isinstance(res, dict) or res.get("ok") is False:
        return res  # eval's own refusal (gameScript off, a Lua error): shown as it is, exit 1
    value = res.get("value")
    if not isinstance(value, dict):
        raise ToolError("strips --gs: the game script gave no answer table (%s)%s"
                        % (str(value)[:200], "; try a smaller --limit" if res.get("truncated") else ""))
    out = strips_lists(value)
    out["where"] = "gs"
    out["evalWhere"] = res.get("where")
    if res.get("truncated"):
        out["evalTruncated"] = True
    out["gsNote"] = EVAL_GS_NOTE
    return out


REACH_RADIUS_MAX = 500  # the mod's RADIUS_MAX (remote_reach.lua)
REACH_LIMIT_MAX = 200  # the mod's TARGETS_LIST_MAX


def reach_place(v, name):
    """An end of reach --from / --to: an entity id, or a point x,y (sent as it is written; the mod checks too)."""
    v = v.strip()
    if re.fullmatch(r"\d+", v):
        return int(v)
    parts = v.split(",")
    try:
        xy = [float(x) for x in parts]
    except ValueError:
        xy = []
    if len(xy) != 2 or any(x != x or abs(x) == float("inf") for x in xy):
        raise ToolError("%s must be an entity id or a point x,y (for a negative x write %s=-100,50)" % (name, name))
    return "%s,%s" % (repr(xy[0]), repr(xy[1]))


def reach_args(ns):
    """reach: one of --api, --problems, --target E, --town T (with --limit), --from A --to B (with --mode, --radius)."""
    forms = [f for f, on in (("api", ns.api), ("problems", ns.problems), ("target", ns.target is not None),
                             ("town", ns.town is not None),
                             ("path", ns.from_ is not None or ns.to is not None)) if on]
    if len(forms) != 1:
        raise ToolError("give one of --api, --problems, --target ID, --town ID, --from A --to B")
    form = forms[0]
    if form != "path" and (ns.mode is not None or ns.radius is not None):
        raise ToolError("--mode and --radius go with --from and --to")
    if form != "town" and ns.limit is not None:
        raise ToolError("--limit goes with --town")
    if form in ("api", "problems"):
        return {form: True}
    if form in ("target", "town"):
        v = getattr(ns, form)
        if v < 0:
            raise ToolError("--%s must be an entity id" % form)
        args = {form: v}
        if ns.limit is not None:
            if not 0 <= ns.limit <= REACH_LIMIT_MAX:
                raise ToolError("--limit must be from 0 to %d" % REACH_LIMIT_MAX)
            args["limit"] = ns.limit
        return args
    if ns.from_ is None or ns.to is None:
        raise ToolError("give both --from and --to")
    args = {"from": reach_place(ns.from_, "--from"), "to": reach_place(ns.to, "--to")}
    if ns.mode is not None:
        args["mode"] = ns.mode
    if ns.radius is not None:
        if not 0 < ns.radius <= REACH_RADIUS_MAX:
            raise ToolError("--radius must be above 0 and at most %d m" % REACH_RADIUS_MAX)
        args["radius"] = ns.radius
    return args


CATCHMENT_RADIUS_MAX = 2000  # remote_lines.lua stations --catchment
CATCHMENT_PATHS_MAX = 50  # remote_catchment.lua PATHS_MAX


def stations_args(ns):
    catchment = getattr(ns, "catchment", None)
    paths = getattr(ns, "paths", None)
    if catchment is not None:
        if ns.name or ns.near is not None:
            raise ToolError("--catchment goes alone (one station or station group; --radius and --paths go with it)")
        args = {"catchment": catchment}
        if ns.radius is not None:
            # the circle the diagnosis uses when the engine gives none (the mod checks again)
            if not 0 < ns.radius <= CATCHMENT_RADIUS_MAX:
                raise ToolError("--radius with --catchment must be above 0 and at most %d m" % CATCHMENT_RADIUS_MAX)
            args["radius"] = ns.radius
        if paths is not None:
            if not 0 <= paths <= CATCHMENT_PATHS_MAX:
                raise ToolError("--paths must be from 0 to %d" % CATCHMENT_PATHS_MAX)
            args["paths"] = paths
        return args
    if paths is not None:
        raise ToolError("--paths goes with --catchment")
    args = {}
    if ns.name:
        args["name"] = ns.name
    if ns.near is not None:
        args["near"] = ns.near
        if ns.radius is not None:
            args["radius"] = ns.radius
    elif ns.radius is not None:
        raise ToolError("--radius goes with --near")
    return args


def money_args(ns):
    """set or add, whichever was given (argparse makes them exclusive; the mod checks again)."""
    return {"set": ns.set} if ns.set is not None else {"add": ns.add}


def recording_dirs():
    """Steam's background game recordings of TF3, newest first (userdata/<id>/gamerecordings/video/bg_3493540_*)."""
    home = os.path.expanduser("~")
    found = []
    for steam in (os.path.join(home, ".local", "share", "Steam"), os.path.join(home, ".steam", "steam")):
        found += glob.glob(os.path.join(steam, "userdata", "*", "gamerecordings", "video", "bg_" + APP_ID + "_*"))
    uniq = {os.path.realpath(p): p for p in found}
    return newest_recordings(uniq.values())


def last_chunk_time(rec_dir):
    """When the recording in rec_dir last wrote a chunk (finished or not), 0 if it has none."""
    times = [mtime(p) or 0 for p in glob.glob(os.path.join(rec_dir, "chunk-stream0-*"))]
    return max(times, default=0)


def newest_recordings(dirs):
    """By the last chunk written, then by name (bg_<app>_YYYYMMDD_HHMMSS sorts by start time). Not by the
    folder's mtime: Steam trims old chunks out of a stopped recording, which bumps that folder's mtime, and
    2026-11-17 `frame` took one stopped 81 min before (mtime 03:04:26 JST) over the live one."""
    return sorted(dirs, key=lambda p: (last_chunk_time(p), os.path.basename(p)), reverse=True)


def recent_chunks(rec_dir):
    """Video chunks newest first. Steam writes the chunk being recorded as .m4s.tmp and renames it when done,
    so every .m4s is finished; ties in mtime are broken by the chunk number."""
    chunks = glob.glob(os.path.join(rec_dir, "chunk-stream0-*.m4s"))
    return sorted(chunks, key=lambda p: (mtime(p) or 0, os.path.basename(p)), reverse=True)


def finished_chunk(rec_dir):
    chunks = recent_chunks(rec_dir)
    return chunks[0] if chunks else None


STALE_FRAME_SEC = 30
CROP_RE = re.compile(r"(\d+)x(\d+)\+(\d+)\+(\d+)")


def cmd_frame(ns):
    """The game's picture with its UI, a few seconds old, from Steam's background recording: needs no window
    focus or key press and no game command (the API screenshot only works in photo mode)."""
    vf = []
    if ns.crop:
        m = CROP_RE.fullmatch(ns.crop)
        if not m:
            raise ToolError("--crop must look like WxH+X+Y in the recording's pixels, e.g. 1150x170+2690+1450")
        vf = ["-vf", "crop=%s:%s:%s:%s" % m.groups()]
    dirs = recording_dirs()
    if not dirs:
        raise ToolError("no Steam background recording of TF3 found: turn on background recording in Steam's "
                        "game recording settings")
    init = os.path.join(dirs[0], "init-stream0.m4s")
    chunks = recent_chunks(dirs[0])[:2]  # the newest, and one more in case ffmpeg cannot read it
    if not chunks or not os.path.exists(init):
        raise ToolError("the recording in " + dirs[0] + " has no finished chunk yet")
    seg = ns.out + ".seg.mp4"
    last_err = None
    try:
        for chunk in chunks:
            with open(seg, "wb") as out, open(init, "rb") as a, open(chunk, "rb") as b:
                out.write(a.read())
                out.write(b.read())
            r = subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", seg] + vf + ["-update", "1", ns.out],
                               capture_output=True, text=True, encoding="utf-8", errors="replace")
            if r.returncode == 0 and os.path.exists(ns.out):
                break
            last_err = r.stderr.strip()
        else:
            raise ToolError("ffmpeg could not read the newest chunks of " + dirs[0] + ": " + str(last_err))
    except OSError as e:
        raise ToolError("cannot make the frame (ffmpeg missing, or --out not writable?): " + str(e))
    finally:
        remove([seg])
    age = time.time() - (mtime(chunk) or 0)
    out = {"ok": True, "path": ns.out, "chunk": chunk, "ageSec": round(age, 1),
           "note": "the picture is %.0f s old, at the recording's resolution" % age}
    if age > STALE_FRAME_SEC:
        out["stale"] = True
        out["warning"] = ("the recording stopped %.0f min ago: the game is closed or background recording is off"
                          % (age / 60))
    return out


# pointer: the game's own idea of where the mouse is, set from outside. TF3 runs as an XWayland window; a synthetic
# EnterNotify + MotionNotify sent to that window moves the game's hover (the placement preview, tooltips) and its
# drawn cursor, while the real pointer stays where it is. Only these two event types are ever sent: a button or
# key event would act in the game on its own (2026-11-18: pointer movement only, no buttons or keys).
TF3_WINDOW_TITLE = "Transport Fever 3"
X_MOTION_NOTIFY, X_ENTER_NOTIFY = 6, 7
X_POINTER_MOTION_MASK, X_ENTER_WINDOW_MASK = 1 << 6, 1 << 4
POINTER_EVENTS = {X_ENTER_NOTIFY: X_ENTER_WINDOW_MASK, X_MOTION_NOTIFY: X_POINTER_MOTION_MASK}
POINTER_WIGGLE = (-2, -1, 0, 1, 2, 0)  # px steps along x ending on the target: the game reacts to movement
POINTER_STEP_SEC = 0.05
POINTER_RE = re.compile(r"\s*([-+0-9.eE]+)\s*,\s*([-+0-9.eE]+)\s*")


def pointer_target(spec, width, height, pixels=False):
    """(x, y) in the window's pixels from "FX,FY" (fractions of the window, 0-1) or, with pixels, "X,Y"."""
    m = POINTER_RE.fullmatch(spec or "")
    if not m:
        raise ToolError("give the position as X,Y, e.g. 0.5,0.47 (fractions of the window) or 1920,1080 with --px")
    try:
        a, b = float(m.group(1)), float(m.group(2))
    except ValueError:
        raise ToolError("not a number in " + repr(spec))
    if not all(v == v and abs(v) != float("inf") for v in (a, b)):
        raise ToolError("not a finite number in " + repr(spec))
    if width <= 0 or height <= 0:
        raise ToolError("the game window has no size (%dx%d)" % (width, height))
    if pixels:
        x, y = a, b
        if not (0 <= x < width and 0 <= y < height):
            raise ToolError("%s is outside the window (%dx%d)" % (spec, width, height))
    else:
        if not (0 <= a <= 1 and 0 <= b <= 1):
            raise ToolError("fractions must be 0-1 (use --px for pixels)")
        x, y = a * width, b * height
    return min(int(x), width - 1), min(int(y), height - 1)


def pointer_events(x, y, width):
    """The (type, x, y) list sent for one move: enter, a small wiggle (clamped to the window), then the target."""
    out = [(X_ENTER_NOTIFY, x, y)]
    out += [(X_MOTION_NOTIFY, max(0, min(width - 1, x + dx)), y) for dx in POINTER_WIGGLE]
    return out


class X11:
    """The few libX11 calls the pointer needs, through ctypes (no extra package)."""

    def __init__(self):
        import ctypes
        import ctypes.util
        self.c = c = ctypes
        name = ctypes.util.find_library("X11") or "libX11.so.6"
        try:
            self.lib = X = ctypes.CDLL(name)
        except OSError as e:
            raise ToolError("cannot load libX11 (" + name + "): " + str(e))
        vp, ul, ui, i, l = c.c_void_p, c.c_ulong, c.c_uint, c.c_int, c.c_long
        X.XOpenDisplay.restype, X.XOpenDisplay.argtypes = vp, [c.c_char_p]
        X.XCloseDisplay.argtypes = [vp]
        X.XDefaultRootWindow.restype, X.XDefaultRootWindow.argtypes = ul, [vp]
        X.XQueryTree.argtypes = [vp, ul, c.POINTER(ul), c.POINTER(ul), c.POINTER(c.POINTER(ul)), c.POINTER(ui)]
        X.XFetchName.argtypes = [vp, ul, c.POINTER(c.c_char_p)]
        X.XFree.argtypes = [vp]
        X.XGetGeometry.argtypes = [vp, ul, c.POINTER(ul), c.POINTER(i), c.POINTER(i), c.POINTER(ui), c.POINTER(ui),
                                   c.POINTER(ui), c.POINTER(ui)]
        X.XSendEvent.argtypes = [vp, ul, i, l, vp]
        X.XFlush.argtypes = [vp]
        X.XTranslateCoordinates.argtypes = [vp, ul, ul, i, i, c.POINTER(i), c.POINTER(i), c.POINTER(ul)]
        # Xlib's default handler exits the process on any error, e.g. BadWindow from a popup that closed while the
        # tree is walked; this one only notes it, so the tool still answers. Kept on self: ctypes must not free it.
        self.errors = []
        handler_t = c.CFUNCTYPE(i, vp, vp)
        self._on_error = handler_t(lambda d, e: self.errors.append(1) or 0)
        X.XSetErrorHandler.argtypes = [handler_t]
        X.XSetErrorHandler.restype = vp
        X.XSetErrorHandler(self._on_error)
        head = [("type", i), ("serial", ul), ("send_event", i), ("display", vp), ("window", ul), ("root", ul),
                ("subwindow", ul), ("time", ul), ("x", i), ("y", i), ("x_root", i), ("y_root", i)]

        class Motion(c.Structure):
            _fields_ = head + [("state", ui), ("is_hint", c.c_char), ("same_screen", i)]

        class Crossing(c.Structure):
            _fields_ = head + [("mode", i), ("detail", i), ("same_screen", i), ("focus", i), ("state", ui)]

        class Event(c.Union):
            _fields_ = [("motion", Motion), ("crossing", Crossing), ("pad", l * 24)]

        self.Event = Event
        self.d = X.XOpenDisplay(None)
        if not self.d:
            raise ToolError("cannot open the X display (DISPLAY=%s): TF3 runs under XWayland, the tool needs it too"
                            % os.environ.get("DISPLAY"))
        self.root = X.XDefaultRootWindow(self.d)

    def close(self):
        self.lib.XCloseDisplay(self.d)

    def find(self, title):
        c, X = self.c, self.lib
        stack = [self.root]
        while stack:
            w = stack.pop()
            name = c.c_char_p()
            if X.XFetchName(self.d, w, c.byref(name)):
                found = (name.value or b"").decode("utf-8", "replace") == title
                X.XFree(name)
                if found:
                    return w
            r, par, ch, n = c.c_ulong(), c.c_ulong(), c.POINTER(c.c_ulong)(), c.c_uint()
            if X.XQueryTree(self.d, w, c.byref(r), c.byref(par), c.byref(ch), c.byref(n)):
                stack.extend(ch[k] for k in range(n.value))
                if ch:
                    X.XFree(ch)
        return None

    def size(self, w):
        c = self.c
        r, x, y, ww, hh, b, dep = c.c_ulong(), c.c_int(), c.c_int(), c.c_uint(), c.c_uint(), c.c_uint(), c.c_uint()
        if not self.lib.XGetGeometry(self.d, w, c.byref(r), c.byref(x), c.byref(y), c.byref(ww), c.byref(hh),
                                     c.byref(b), c.byref(dep)):
            raise ToolError("cannot read the game window's size")
        return ww.value, hh.value

    def to_root(self, w, x, y):
        """The root window's coordinates of (x, y) in w: the same unless the window is not at 0,0 (windowed)."""
        c = self.c
        rx, ry, child = c.c_int(), c.c_int(), c.c_ulong()
        if self.lib.XTranslateCoordinates(self.d, w, self.root, x, y, c.byref(rx), c.byref(ry), c.byref(child)):
            return rx.value, ry.value
        return x, y

    def send(self, w, typ, x, y):
        if typ not in POINTER_EVENTS:  # the one place events leave: nothing but pointer movement
            raise ToolError("refusing to send X event type %r: only EnterNotify and MotionNotify" % (typ,))
        ev = self.Event()
        s = ev.crossing if typ == X_ENTER_NOTIFY else ev.motion
        s.type, s.send_event, s.display, s.window, s.root = typ, 1, self.d, w, self.root
        rx, ry = self.to_root(w, x, y)
        s.x, s.y, s.x_root, s.y_root, s.same_screen = x, y, rx, ry, 1
        if typ == X_ENTER_NOTIFY:
            s.mode, s.detail, s.focus = 0, 0, 1  # NotifyNormal, NotifyAncestor
        if not self.lib.XSendEvent(self.d, w, 0, POINTER_EVENTS[typ], self.c.byref(ev)):
            raise ToolError("XSendEvent failed")
        self.lib.XFlush(self.d)


def cmd_pointer(ns, x11_factory=None, sleep=time.sleep):
    if not CONFIG["pointer"]:
        raise config_needed("pointer (synthetic X11 pointer events into the game window)", "pointer")
    x = (x11_factory or X11)()
    try:
        w = x.find(ns.title)
        if not w:
            raise ToolError("no window titled %r: is the game running?" % ns.title)
        width, height = x.size(w)
        tx, ty = pointer_target(ns.pos, width, height, pixels=ns.px)
        for k, (typ, ex, ey) in enumerate(pointer_events(tx, ty, width)):
            if k:
                sleep(POINTER_STEP_SEC)
            x.send(w, typ, ex, ey)
    finally:
        x.close()
    return {"ok": True, "window": "0x%x" % w, "size": [width, height], "x": tx, "y": ty,
            "note": "only the game's pointer moved (synthetic EnterNotify/MotionNotify); the real pointer did not. "
                    "The game may take a frame or two to redraw; frame pictures lag a few seconds."}


def num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return 0.0


def show(obj):
    print(json.dumps(obj, ensure_ascii=False, indent=2, sort_keys=True))


BUTTON_MAX_SPEED = 4  # the base buttons' top speed, used while the game has no estimate yet


def choose_speed(requested, estimated_max, force):
    """(speed to send, note). Above the game's own estimate the simulation cannot keep up: frames grow long and
    sound breaks up (2026-11-15, x8 on a save estimated at x5-6). The base UI caps at the estimate too."""
    if force or requested <= 1:
        return requested, None
    cap = estimated_max if estimated_max and estimated_max > 0 else BUTTON_MAX_SPEED
    if requested > cap:
        return cap, ("speed %d lowered to %d, the game's estimate of what it can sustain%s; --force sends it as is"
                     % (requested, cap, "" if estimated_max else " (no estimate yet: the buttons' 4x)"))
    return requested, None


def capped_speed(requested, force, folder=None):
    """(speed to send, note, extra args). Mod version 2 caps by itself, and a run follows the estimate as it
    changes, so it gets the speed asked for; version 1 gets it lowered here once."""
    if requested <= 1:
        return requested, None, {}
    if force:
        return requested, None, {"force": True}
    st = send("status", folder=folder)
    if (st.get("version") or 1) >= 2:
        return requested, None, {}
    speed, note = choose_speed(requested, (st.get("state") or {}).get("estimatedMaxSpeed"), force)
    return speed, note, {}


def cmd_run(ns):
    folder = exchange_dir()
    speed, note, extra = capped_speed(ns.speed, ns.force, folder)
    if note:
        print("note: " + note, file=sys.stderr)
    args = dict(extra, speed=speed)
    if ns.days is not None:
        args["days"] = ns.days
    elif ns.months is not None:
        args["months"] = ns.months
    else:
        args["untilDate"] = ns.until_date

    def progress(a):
        m = a.get("measured") or {}
        d = (a.get("state") or {}).get("date") or {}
        print("... %s-%02d-%02d  x%.1f overall" % (d.get("year"), d.get("month") or 0, d.get("day") or 0,
                                                 m.get("overall") or 0), file=sys.stderr)
    try:
        res = send("run", args, timeout=ns.timeout, on_progress=progress, folder=folder)
        if note:
            res["speedNote"] = note
        return res
    except (ToolError, KeyboardInterrupt):
        # do not leave the game racing on at 64x when nobody waits for it any more
        try:
            send("speed", {"speed": 0}, folder=folder)
            print("paused the game", file=sys.stderr)
        except (ToolError, KeyboardInterrupt):
            pass
        raise


def cmd_keep_log(ns):
    """keep-log: the copy made now (unless --list) and every kept log, newest first."""
    path = game_log_path()
    if path is None:
        raise ToolError("no game log found (set TF3_LOG)")
    out = {"ok": True, "log": path}
    if not ns.list:
        out["kept"] = keep_last_log(path)
    folder = os.path.join(os.path.dirname(path), "logs")
    files = sorted(glob.glob(os.path.join(folder, KEPT_LOG_PREFIX + "*.txt")), reverse=True)
    out["logs"] = [{"path": f, "bytes": os.path.getsize(f)} for f in files if os.path.exists(f)]
    return out


def cmd_log(ns):
    path = os.environ.get("TF3_LOG") or stdout_log(exchange_dir())
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.readlines()
    if ns.grep:
        lines = [l for l in lines if ns.grep in l]
    for l in lines[-ns.tail:]:
        sys.stdout.write(l)
    return None


class _ExactParser(argparse.ArgumentParser):
    """A parser that takes only whole option names (no --eng for --engine-check).

    The game guard outside tf3ctl tells read-only from game-changing calls by the flags as typed; an abbreviation
    would read as one thing there and as another here. add_subparsers makes every sub parser (and theirs) of this
    class, so the rule holds at every level.
    """

    def __init__(self, *args, **kwargs):
        kwargs["allow_abbrev"] = False
        super().__init__(*args, **kwargs)


def make_parser():
    p = _ExactParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--owner", default=os.environ.get("TF3CTL_OWNER"),
                   help="name of the client sending commands; game-changing commands go only to the game this owner "
                        "started (launch / restart)")
    p.add_argument("--other-owner-ok", action="store_true",
                   help="send game-changing commands to a game another owner (or a person from Steam) started; only "
                        "when the clients sharing the game agreed. The answer and the game's log say so")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("config", help="the configuration in effect and where it was read from (sends nothing)")
    pl = sub.add_parser("poll", help="how often the mod reads the command file, until the next load")
    pl.add_argument("--idle", type=float)
    pl.add_argument("--active", type=float)
    sub.add_parser("status")
    s = sub.add_parser("speed")
    s.add_argument("speed", type=int)
    s.add_argument("--force", action="store_true", help="above the game's estimate of what it can sustain")
    s.add_argument("--user-asked", action="store_true", help="send it during coop: only when the user asked for it")
    cs = sub.add_parser("calendar-speed", help="read (no value) or set the base's calendar speed slider (0.25x-4x)")
    cs.add_argument("factor", nargs="?", type=float, help="one of the slider's steps: 0 (paused), 0.25, 0.5, 1, 2, 4")
    cs.add_argument("--millis-per-day", type=int, help="the engine's value itself: game ms per calendar day (0: paused)")
    cs.add_argument("--user-asked", action="store_true", help="send it during coop: only when the user asked for it")
    pz = sub.add_parser("pause")
    pz.add_argument("--user-asked", action="store_true", help="send it during coop: only when the user asked for it")
    r = sub.add_parser("run")
    r.add_argument("--user-asked", action="store_true", help="send it during coop: only when the user asked for it")
    g = r.add_mutually_exclusive_group(required=True)
    g.add_argument("--days", type=int)
    g.add_argument("--months", type=int)
    g.add_argument("--until", dest="until_date")
    r.add_argument("--speed", type=int, default=4)
    r.add_argument("--force", action="store_true", help="above the game's estimate of what it can sustain")
    r.add_argument("--timeout", type=float, default=3600)
    sub.add_parser("saves")
    i = sub.add_parser("info")
    i.add_argument("save")
    l = sub.add_parser("load")
    l.add_argument("save")
    l.add_argument("--add", action="append", default=[])
    l.add_argument("--remove", action="append", default=[])
    l.add_argument("--set-mods")
    l.add_argument("--param", action="append", default=[])
    l.add_argument("--dry-run", action="store_true")
    l.add_argument("--wait-for-start", action="store_true", help=WAIT_FOR_START_HELP)
    l.add_argument("--timeout", type=float, default=600)
    ng = sub.add_parser("newgame", help="start a new game (app.startGame); the running game's mods by default")
    ng.add_argument("--climate", help="temperate (default), dry, subarctic, tropical, or a resource name")
    ng.add_argument("--generator", help="terrain generator; default: the base new-game page's first")
    ng.add_argument("--size", help="tiny, small (default), medium, large, veryLarge or WxH tiles")
    ng.add_argument("--year", type=int, help="start year (default 1900)")
    ng.add_argument("--seed")
    ng.add_argument("--no-towns", action="store_true")
    ng.add_argument("--no-industries", action="store_true")
    ng.add_argument("--tutorial", action="store_true", help="start with the base tutorial (off by default)")
    ng.add_argument("--add", action="append", default=[])
    ng.add_argument("--remove", action="append", default=[])
    ng.add_argument("--set-mods")
    ng.add_argument("--param", action="append", default=[])
    ng.add_argument("--list", action="store_true", help="climates and terrain generators the game has")
    ng.add_argument("--dry-run", action="store_true")
    ng.add_argument("--timeout", type=float, default=900)
    ng.add_argument("--editor", action="store_true", help="the map editor instead of a game (isMapEditor); its mods: "
                    "the official ones (ug_*) and the probe, not the running game's")
    ng.add_argument("--no-company-init", action="store_true", help=NO_COMPANY_INIT_HELP)
    fr = sub.add_parser("frame", help="the game's picture with UI, from Steam's background recording (Linux only: "
                        "it looks in Linux's Steam folders)")
    fr.add_argument("--out", required=True, help="image to write (.png or .jpg)")
    fr.add_argument("--crop", help="WxH+X+Y in the recording's pixels, e.g. 1150x170+2690+1450 for the speed row")
    po = sub.add_parser("pointer", help="move the game's mouse pointer (hover, placement preview) without the real "
                        "one; pointer movement only, never a click or a key. Needs \"pointer\": true in the "
                        "configuration file; Linux (X11) only")
    po.add_argument("pos", metavar="FX,FY", help="fractions of the game window, e.g. 0.5,0.47 (0,0 = top left)")
    po.add_argument("--px", action="store_true", help="the position is in the window's pixels instead")
    po.add_argument("--title", default=TF3_WINDOW_TITLE, help="the game window's title")
    en = sub.add_parser("entities", help="towns, lines, vehicles, stations, industries or warehouses with their ids "
                                         "(a warehouse: its construction, stock list entity, stocks and capacity)")
    en.add_argument("--kind", required=True, choices=["town", "line", "vehicle", "station", "industry", "warehouse"])
    en.add_argument("--grep")
    en.add_argument("--limit", type=int, default=200)
    wi = sub.add_parser("window", help="open the window of a town, line, vehicle, station, industry or warehouse")
    wg = wi.add_mutually_exclusive_group(required=True)
    for kind in ("town", "line", "vehicle", "station", "industry", "warehouse"):
        wg.add_argument("--" + kind, metavar="NAME", help="exact name (any case) or a unique part of it")
    wg.add_argument("--entity", type=int)
    wg.add_argument("--close-all", action="store_true")
    wi.add_argument("--focus", action="store_true", help="also move the camera to it")
    wi.add_argument("--manager", action="store_true", help="with --line or --entity (a line): open the line manager "
                    "with that line selected, as the line window's Manage Line button does, instead of its window")
    ca = sub.add_parser("camera", help="read the camera, or move it (answers the values read back)")
    ca.add_argument("--set", metavar="X,Y[,DIST[,ANGLE[,PITCH]]]", help="the numbers left out stay as they are")
    ca.add_argument("--entity", type=int, help="focus on this entity")
    ca.add_argument("--focus", metavar="X,Y,Z", help="focus on this point")
    ca.add_argument("--distance", type=float, help="with --focus (default: the distance now)")
    ca.add_argument("--free", choices=("on", "off"), help="switch the free camera, as the base's eye button (its "
                    "tool on the tool stack, through the speed control); not checked in a game yet")
    ca.add_argument("--via", choices=("tool", "toggle"), help="with --free: tool (default, the base's way) or toggle "
                    "(api.gui.camera.toggleFreeCamera alone; its state is only estimated)")
    ca.add_argument("--eye", metavar="X,Y,Z", help="put the camera's eye here (with --look; Z may be under the ground; "
                    "a negative X as --eye=-5,0,0); the answer reads getEye back")
    ca.add_argument("--look", metavar="X,Y,Z", help="the point the eye looks at (with --eye)")
    ca.add_argument("--method", choices=("data", "focus", "both"), help="how the eye is placed: data = setCameraData, "
                    "focus = focusPosition (keeps Z), both = the one then the other (default)")
    ca.add_argument("--mouse", choices=("attach", "detach"), help="the free camera's mouse attachment")
    bt = sub.add_parser("build-tool", help="open the construction menu's placing tool for one construction")
    bt.add_argument("--res", help="the construction's resName, e.g. depots/road/road_depot/road_depot.con")
    bt.add_argument("--template", type=int, help="the template number (menu tag resName@N)")
    bt.add_argument("--seconds", type=float, default=60, help="the mod clears the menu filter after this (5-600)")
    bt.add_argument("--close", action="store_true", help="clear the menu filter now")
    bt.add_argument("--menu", choices=BUILD_MENUS, help="first open this toolbar menu (its own button's event), which "
                    "picks its first item as the placing tool; the only way seen to open the tool (2026-11-18)")
    bd = sub.add_parser("build", help="put one construction (.con) on the map at a point, as a mod's tool builds "
                                       "(no click); or take away ones the probe built. Meant for test saves (not checked)")
    bd.add_argument("--res", help="the construction's resName: a mod's content/<dir>/x.con.lua is <modId>::/<dir>/x.con, "
                    "a base game one ::/depots/... (on a miss the answer lists names like it)")
    bd.add_argument("--at", metavar="X,Y[,Z]", help="where (metres); no Z: the terrain's height there (under water "
                    "the bottom: give Z for a construction on water)")
    bd.add_argument("--angle", type=float, help="turn about the vertical in radians (default 0)")
    bd.add_argument("--params", help="a JSON object over the construction's default params, as values (not indexes; a "
                    "param without numbers takes its index), e.g. '{\"rbr_height\": 8}'")
    bd.add_argument("--seed", type=int, help="params.seed when --params has none (default 1, the same look each time)")
    bd.add_argument("--name", help="its name (default probe-build N; build --remove after a load knows it by that)")
    bd.add_argument("--dry-run", action="store_true", help="no build and no engine check (it takes no SimpleProposal): the name, the "
                    "params and the height, and the constructions within 30 m")
    bd.add_argument("--remove", metavar="ID[,ID...]", help="take away constructions the probe built (the same file "
                    "and place it built, or after a load its probe-build name with the probe's mark in the params)")
    bd.add_argument("--remove-all", action="store_true", help="take away all the probe built since this load")
    bd.add_argument("--no-owner", action="store_true", help="no company's: playerEntity -1, as an industry (AoM's "
                    "strawberry farm); default the company's (--owner names the client, not this)")
    bd.add_argument("--no-fill-modules", action="store_true", help="with params.modules: send each module as given; "
                    "default: a module without metadata / updateScript gets moduleRep's own")
    bd.add_argument("--engine-check", action="store_true", help="with --dry-run only: also ask the engine about the "
                    "same proposal a build sends (makeProposalData: errors, collisions with hits, cost, and the box it "
                    "takes: footprint). Counts as changing the game: ask for the game first")
    bd.add_argument("--collision-detail", action="store_true", help="with a build, or with --dry-run --engine-check: also copy the "
                    "engine's whole ProposalData into the answer (collisionDetail: collisionInfo, errorState, the new "
                    "boxes and the rest, field by field; lists cut at 40, fields that raise or read nil named), and how "
                    "each box in the way meets the proposal's own (collisionDetail.overlaps: x, y, z). Off by default "
                    "(the answer grows)")
    bd.add_argument("--remove-buildings", action="store_true", help="let it take the town buildings in its way (the "
                    "Context's gatherBuildings, as the player's tools do; the answer's buildingsInWay). Meant for test saves (not checked)")
    bd.add_argument("--join-streets", action="store_true", help="the Context's cleanupStreetGraph: whether its road "
                    "end put on an old road node becomes that node (the answer's joins: wasThere, nodesHere). Not "
                    "checked in a game yet. Meant for test saves (not checked)")
    rd = sub.add_parser("road", help="build one straight road piece between two points, as a mod's tool builds (no "
                                      "click; a SimpleStreetProposal). Meant for test saves (not checked)")
    rd.add_argument("--from", dest="from_", metavar="X,Y[,Z]",
                    help="one end (metres); no Z: the terrain's height there (required, but with --inspect-node)")
    rd.add_argument("--to", metavar="X,Y[,Z]", help="the other end (required, but with --inspect-node)")
    rd.add_argument("--from-node", type=int, metavar="ID", help="join the from end to this existing road node (its "
                    "entity id; no snap). Alone: the end is the node's own point. With --from: the piece's end is "
                    "that point, joined to the node, at most 12 m from it across (else refused, nothing sent; the "
                    "answer shows the end's endOffset). [guess] the shifted end is not checked in a game yet")
    rd.add_argument("--to-node", type=int, metavar="ID", help="the same for the to end")
    rd.add_argument("--type", help="the street template's resName, or a base road's file name (town_new_small, "
                    "country_old_medium; looked for under the base's town, country and highway roads); default the "
                    "base medium town road of the game's year")
    rd.add_argument("--bridge", metavar="RES", help="build the piece as a bridge of this type: a bridge type's "
                    "resName (hummer_pier_spike::/infrastructure/bridge/hps_pillarless.bridge), or a base bridge's file "
                    "name (concrete: ::/infrastructure/bridge/concrete.bridge). Sent as the piece's edge type BRIDGE "
                    "with the type's id; an unknown type, or one that carries no roads, is refused (nothing sent). "
                    "Give the ends' heights (X,Y,Z) for a piece in the air")
    rd.add_argument("--snap", type=float, help="an end within this many metres of a node with road pieces joins that "
                    "node (default 5, 0: never); never a node without a junction set-up (BaseNodeConfig; this "
                    "command gives its new nodes one): the next one, else refused")
    rd.add_argument("--dry-run", action="store_true", help="no build: the template, the ends (snapped or on the "
                    "terrain), the length and the set-ups checked here only; the engine is not asked")
    rd.add_argument("--engine-check", action="store_true", help="with --dry-run only: also ask the engine about the "
                    "same proposal a build sends (makeProposalData: errors, collisions, cost). Counts as changing "
                    "the game: ask for the game first")
    rd.add_argument("--collision-detail", action="store_true", help="with a build, or with --dry-run --engine-check: also copy the "
                    "engine's whole ProposalData into the answer (collisionDetail: collisionInfo, errorState, the new "
                    "boxes and the rest, field by field; lists cut at 40, fields that raise or read nil named), and how "
                    "each box in the way meets the proposal's own (collisionDetail.overlaps: x, y, z). Off by default "
                    "(the answer grows)")
    rd.add_argument("--remove-fields", action="store_true", help="let the road take farm fields in its way (the "
                    "context's gatherFields, as the base's tools: the engine warns that fields will be removed); "
                    "buildings, tracks and the rest still refuse it. Meant for test saves (not checked; changes the game)")
    rd.add_argument("--remove-buildings", action="store_true", help="let the road take town buildings in its way "
                    "(the Context's gatherBuildings). Meant for test saves (not checked; changes the game)")
    rd.add_argument("--ignore-errors", action="store_true", help="changes the save's contents (saving keeps it); for test saves only: skips the engine's checks "
                    "(the build sent with the engine's ignoreErrors on: built past its non-critical errors; its API "
                    "says a critical one still refuses it). Refused unless the loaded save is a test save's (the "
                    "configuration's testSavePrefixes, probe-* by default; a new game has no name: save it as "
                    "probe-... and load that), and during coop. The probe's own checks (junction set-ups) still "
                    "refuse. The answer: ignoredErrors, and unforced (the errors a build without it would be refused "
                    "for). With --dry-run: the engine is asked, nothing is built")
    rd.add_argument("--tangent-from", metavar="DX,DY", help="a curved piece: the way the road leaves the from end "
                    "(a direction only; the length is the chord's). Both tangents point the way from -> to; at most "
                    "90 degrees off the line from -> to. A negative dx: --tangent-from=-1,0")
    rd.add_argument("--tangent-to", metavar="DX,DY", help="the way the road arrives at the to end (from -> to; a negative dx: --tangent-to=-1,0)")
    rd.add_argument("--align-to-edge", choices=("from", "to", "both"), help="at a joined end (a road node within "
                    "--snap), follow the road there: a dead end's piece straight on. A node with more than one road "
                    "piece needs --align-edge")
    rd.add_argument("--align-edge", type=int, action="append", metavar="ID", help="with --align-to-edge: the road "
                    "piece to follow at a node with more than one (once per end; each id is taken at the end it is at)")
    rd.add_argument("--batch", metavar="FILE", help="several pieces in one proposal (one SimpleProposal, judged and "
                    "built together; at most %d): a JSON file with a list of pieces, each an object with road's own "
                    "values by their flags' names (from, to, type, bridge, snap, tangent-from, tangent-to, "
                    "align-to-edge, align-edge) and from-node / to-node: an existing road node's entity id (joined as "
                    "it is, no snap), or a name \"@a\" for a new node the pieces share (its point given at one of its "
                    "ends at least, the same at each). --dry-run, --engine-check, --remove-fields, --remove-buildings, "
                    "--ignore-errors and --collision-detail go for the whole proposal, as for one piece; the answer is the one proposal's "
                    "(errors, critical, hits) with each piece's ends and edge" % ROAD_BATCH_MAX)
    rd.add_argument("--inspect-node", type=int, metavar="ID", help="read only, alone: what road reads of one node "
                    "(the street system's pieces there, the construction it belongs to and whether it is frozen, its "
                    "junction set-up, the octree's pieces within 1, 5 and 20 m) and what road would do with it")
    tk = sub.add_parser("track", help="build track pieces between points, as road builds road pieces (no click; a "
                                       "SimpleStreetProposal of RoadType TRACK), on the ground or in a tunnel. Meant "
                                       "for test saves (not checked). Not checked in a game yet")
    tk.add_argument("--from", dest="from_", metavar="X,Y[,Z]", help="one end (metres); no Z: the terrain's height "
                    "there (with --tunnel, Z is required)")
    tk.add_argument("--to", metavar="X,Y[,Z]", help="the other end")
    tk.add_argument("--from-node", type=int, metavar="ID", help="the from end on this existing track node (its entity "
                    "id: a node with a track piece; the end is the node's own point; no snap)")
    tk.add_argument("--to-node", type=int, metavar="ID", help="the same for the to end")
    tk.add_argument("--type", help="required: the track's street template: its resName, or a base track's file name "
                    "(simple, standard, high_speed; looked for under ::/infrastructure/track/); a road template, or one "
                    "not to be had in the game's year, is refused (nothing sent)")
    tk.add_argument("--tunnel", metavar="RES", help="build the piece underground as a tunnel of this type: a tunnel "
                    "type's resName, or a base tunnel's file name (tunnel_a: ::/infrastructure/tunnel/tunnel_a.tunnel). "
                    "Sent as the piece's edge type TUNNEL with the type's id; an unknown type, or one that carries no "
                    "rails, is refused (nothing sent). The ends' Z is required. [guess] the depth the engine wants and "
                    "a piece with no portal are not checked in a game yet")
    tk.add_argument("--tangent-from", metavar="DX,DY", help="a curved piece: the way the track leaves the from end "
                    "(as road's; a negative dx: --tangent-from=-1,0). The answer gives the turn and radiusApprox")
    tk.add_argument("--tangent-to", metavar="DX,DY", help="the way the track arrives at the to end (from -> to)")
    tk.add_argument("--dry-run", action="store_true", help="no build: the template, the tunnel type, the ends and the "
                    "length checked here only; the engine is not asked")
    tk.add_argument("--engine-check", action="store_true", help="with --dry-run only: also ask the engine about the "
                    "same proposal a build sends (makeProposalData). Counts as changing the game: ask for the game first")
    tk.add_argument("--collision-detail", action="store_true", help="as road's: with a build, or with --dry-run "
                    "--engine-check, the engine's whole ProposalData in the answer (collisionDetail)")
    tk.add_argument("--batch", metavar="FILE", help="several pieces in one proposal (judged and built together; at "
                    "most %d): a JSON list, each piece an object of from, to, from-node / to-node (an existing track "
                    "node's id, or \"@a\" for a new node the pieces share: a switch where three meet), type (required), "
                    "tunnel, tangent-from, tangent-to. --dry-run, --engine-check and --collision-detail go for the "
                    "whole proposal; the answer gives each piece's edge (pieceEdges) and the named nodes' ids "
                    "(namedNodes)" % TRACK_BATCH_MAX)
    li = sub.add_parser("lights", help="changes the save's contents (saving keeps it); take a road junction's traffic light off, as the node's window does it "
                        "(trafficLightPreference NO, sent with createTrafficLightProposal): road does not join a node "
                        "with traffic lights. Test saves only, not in coop (changes the game)")
    li.add_argument("--node", type=int, required=True, metavar="ID", help="the junction's node (road --inspect-node "
                    "shows its trafficLightPreference); more than two street pieces must meet there, and it must not "
                    "be a construction's")
    li.add_argument("--off", action="store_true", help="take its traffic light off (required)")
    li.add_argument("--dry-run", action="store_true", help="make the proposal and ask the engine (makeProposalData); "
                    "nothing is sent. Test saves only all the same")
    te = sub.add_parser("terrain", help="replace a rectangle's ground: flat at a height, or a uniform slope along x "
                        "or y (one whole-map replacement, as the map editor's); in the map editor only, unless "
                        "--in-game")
    te.add_argument("--rect", metavar="X0,Y0,X1,Y1", help="metres, at most %d a side (for a negative x0 write "
                    "--rect=-100,0,100,50)" % TERRAIN_MAX_SIDE)
    tm = te.add_mutually_exclusive_group()
    tm.add_argument("--flat", type=float, metavar="Z", help="the height in metres")
    tm.add_argument("--slope-x", type=float, metavar="PCT", help="per cent, rising toward x1 (negative: falling)")
    tm.add_argument("--slope-y", type=float, metavar="PCT", help="per cent, rising toward y1")
    tm.add_argument("--probe-api", action="store_true", help="read only: which terrain functions the guiUpdate "
                    "state and the speed control's recipe have (type() only, nothing called)")
    te.add_argument("--base", type=float, metavar="Z", help="with a slope: the height at x0 (--slope-x) or y0 (--slope-y)")
    te.add_argument("--blend", type=float, metavar="M", help="metres inside the edge over which the new heights blend "
                    "into the old, so the edge meets the land round it (default 16, less on a small rectangle; 0: a "
                    "sharp step)")
    te.add_argument("--via", choices=("auto", "update", "gui"), help="where it runs: the speed control's recipe "
                    "(gui; auto, the default, is gui: the base editor calls these from react only) or the guiUpdate "
                    "state (update, only when given)")
    te.add_argument("--in-game", action="store_true", help="also outside the map editor (a new test game): whether "
                    "the replacement works in a game is not known; the editor's seed and material calls are left out")
    te.add_argument("--dry-run", action="store_true", help="the grid and the heights, nothing sent")
    tw = sub.add_parser("town", help="one town at a point (createTowns and makeTownCreateCmd, as the map editor's "
                        "towns window); in the map editor only, unless --in-game")
    tw.add_argument("--at", metavar="X,Y", help="metres (for a negative x write --at=-100,50); required")
    tw.add_argument("--name", help="the town's name; required")
    tw.add_argument("--size", type=float, help="the size factor of each district (%g-%g, default 1 as the base "
                    "import; Real World Map Importer: 0.5 for 500 inhabitants, 1 for 5000)" % TOWN_SIZE)
    tw.add_argument("--capacity", type=int, help="the average initial capacity per district (1-%d): the engine's "
                    "proposal scaled to it, its proportions kept (as Advanced Town Placement); default the engine's"
                    % TOWN_MAX_CAPACITY)
    tn = tw.add_mutually_exclusive_group()
    tn.add_argument("--needs", metavar="LU:CAT,...", help="first cargo needs, land use (res, com, ind) : the "
                    "economy's category, e.g. com:fish,ind:planks; default one for the shops and one for the industry "
                    "from the lowest tier")
    tn.add_argument("--no-needs", action="store_true", help="no first needs (the game then never adds one)")
    tw.add_argument("--via", choices=("auto", "update", "gui"), help="where it runs: the speed control's recipe "
                    "(gui; auto, the default) or the guiUpdate state (update, only when given)")
    tw.add_argument("--in-game", action="store_true", help="also outside the map editor (a new test game): whether "
                    "it works in a game is not known")
    tw.add_argument("--dry-run", action="store_true", help="nothing sent: the needs and, in the editor or with "
                    "--in-game, the engine's proposal for the place")
    # town develop / town size: their own options (other dests, so an option given before the word is caught in
    # town_grow_args instead of being dropped)
    tws = tw.add_subparsers(dest="town_action", required=False, metavar="{develop,size,connections,connect}")
    td = tws.add_parser("develop", help="changes the save's contents (saving keeps it); meant for test saves (not checked): new buildings or street segments at a point "
                        "(api.cmd.makeTownDevelopAtCmd), N times one after another; not checked in a game yet")
    td.add_argument("--at", dest="grow_at", required=True, metavar="X,Y",
                    help="metres (for a negative x write --at=-100,50)")
    td.add_argument("--streets", dest="grow_streets", action="store_true", help="develop streets too")
    td.add_argument("--upgrade", dest="grow_upgrade", action="store_true", help="upgrade buildings")
    td.add_argument("--count", dest="grow_count", type=int, default=1, help="commands to send, 1-%d (default 1)"
                    % TOWN_DEVELOP_MAX)
    td.add_argument("--radius", dest="grow_radius", type=float, help="metres round the point the buildings near it "
                    "are counted in (default %g, a harbour's circle; at most %g)" % (TOWN_GROW_RADIUS, TOWN_GROW_RADIUS_MAX))
    td.add_argument("--dry-run", dest="grow_dry_run", action="store_true", help="the counts, nothing sent")
    tz = tws.add_parser("size", help="changes the save's contents (saving keeps it); meant for test saves (not checked): a town's size factors, residential, commercial, industrial "
                        "(api.cmd.makeTownUpdateSizeCmd); not checked in a game yet")
    tz.add_argument("--entity", dest="grow_entity", type=int, required=True, help="the town (entities --kind town)")
    tz.add_argument("--factors", dest="grow_factors", required=True, metavar="R,C,I",
                    help="residential,commercial,industrial, each 0-%g (1 as a new town)" % TOWN_GROW_SIZE_MAX)
    tz.add_argument("--update-all", dest="grow_update_all", action="store_true",
                    help="take every building to its target capacity")
    tz.add_argument("--dry-run", dest="grow_dry_run", action="store_true", help="the town as it is, nothing sent")
    tcs = tws.add_parser("connections", help="read only: the towns the engine counts as connected (the map's "
                         "townConnections, between towns) and each industry's town (the closest one)")
    tcs.add_argument("--entity", dest="conn_entity", type=int, help="one town (entities --kind town)")
    tcs.add_argument("--index-base", dest="conn_index_base", type=int, choices=(0, 1),
                     help="how the engine numbers towns in its connections, when the map does not tell")
    tcn = tws.add_parser("connect", help="changes the save's contents (saving keeps it); meant for test saves (not checked): the map editor's connection commands; --auto detects "
                         "the connections over the roads there are (builds nothing), --build makes streets between "
                         "the connected towns and to all industries; not checked in a game yet")
    tcm = tcn.add_mutually_exclusive_group(required=True)
    tcm.add_argument("--auto", dest="conn_auto", action="store_true",
                     help="api.cmd.makeTownAutoDetectConnectionsCmd (the editor's Auto-detect connections)")
    tcm.add_argument("--build", dest="conn_build", action="store_true",
                     help="api.cmd.makeTownConnectWithIndustriesCmd (the editor's Generate): the map's connections, "
                     "--default and --pairs, and streets to every industry (no list of industries goes in)")
    tcn.add_argument("--entity", dest="conn_entities", metavar="TOWN,...", help="these towns only (default: all)")
    tcn.add_argument("--pairs", dest="conn_pairs", metavar="A:B,...", help="--build: town pairs to connect (town ids)")
    tcn.add_argument("--default", dest="conn_default", action="store_true",
                     help="--build: add the engine's default connections (the editor's Propose Default Connections)")
    tcn.add_argument("--no-keep", dest="conn_no_keep", action="store_true",
                     help="--build: remove the street connections there are (keep is the default)")
    tcn.add_argument("--index-base", dest="conn_index_base", type=int, choices=(0, 1),
                     help="how the engine numbers towns in its connections, when the map does not tell (--auto: "
                     "for the answer's before / after only)")
    tcn.add_argument("--dry-run", dest="conn_dry_run", action="store_true", help="what would be sent, nothing sent")
    wa = sub.add_parser("water", help="read only: the water level, and at a point or on a grid water or land and the "
                                       "terrain's height (to find a shore for a harbour)")
    wg = wa.add_mutually_exclusive_group(required=True)
    wg.add_argument("--at", metavar="X,Y", help="one point (for a negative x write --at=-100,50)")
    wg.add_argument("--grid", metavar="X0,Y0,X1,Y1,STEP", help="points every STEP metres in the box, at most %d; "
                    "rows from Y0 up, each from X0: ~ water, . land, ? not read" % WATER_MAX_POINTS)
    qu = sub.add_parser("quit", help="quit the game (app.quit through the probe)")
    qu.add_argument("--kill", action="store_true", help="SIGKILL when it does not quit (an unsaved game is lost)")
    qu.add_argument("--timeout", type=float, default=QUIT_TIMEOUT_SEC)
    qu.add_argument("--force", action="store_true", help="kill even if another client used the game recently")
    for name, helptext in (("launch", "start the game with the probe running in the main menu (then --load/--new)"),
                           ("restart", "quit (SIGKILL if needed), launch, then --load or --new")):
        st = sub.add_parser(name, help=helptext)
        st.add_argument("--load", metavar="SAVE", help="load this save from the main menu")
        st.add_argument("--new", action="store_true", help="start a new game from the main menu")
        st.add_argument("--add", action="append", default=[])
        st.add_argument("--remove", action="append", default=[])
        st.add_argument("--set-mods")
        st.add_argument("--param", action="append", default=[])
        st.add_argument("--wait-for-start", action="store_true", help="with --load: " + WAIT_FOR_START_HELP)
        st.add_argument("--climate")
        st.add_argument("--generator")
        st.add_argument("--size")
        st.add_argument("--year", type=int)
        st.add_argument("--seed")
        st.add_argument("--no-towns", action="store_true")
        st.add_argument("--no-industries", action="store_true")
        st.add_argument("--tutorial", action="store_true", help="with --new: start with the base tutorial (off by default)")
        st.add_argument("--editor", action="store_true", help="with --new: the map editor (the official mods and the probe)")
        st.add_argument("--no-company-init", action="store_true", help="with --new: " + NO_COMPANY_INIT_HELP)
        st.add_argument("--timeout", type=float, default=900, help="for the load or new game")
        st.add_argument("--launch-timeout", type=float, default=LAUNCH_TIMEOUT_SEC)
        st.add_argument("--lang", metavar="CODE", help="start in this language (de, en, ja, ...): profile.lua is "
                        "changed for the start and put back after quit or before the next launch / restart")
        if name == "launch":
            st.add_argument("--coop", action="store_true", help="share the game with the user once started (and "
                            "loaded): coop start for --owner")
            st.add_argument("--reason", help="with --coop: what the user and the client do together")
            st.add_argument("--minutes", type=int, default=60, help="with --coop: how long (1-%d, default 60)"
                            % COOP_MINUTES_MAX)
        if name == "restart":
            st.add_argument("--quit-timeout", type=float, default=QUIT_TIMEOUT_SEC)
            st.add_argument("--no-kill", action="store_true", help="give up instead of SIGKILL when it does not quit")
            st.add_argument("--force", action="store_true", help="kill even if another client used the game recently")
    ev = sub.add_parser("event", help="fire a react event in the game's GUI (e.g. example_window.show)")
    ev.add_argument("name")
    ev.add_argument("--param", help="a JSON object")
    se = sub.add_parser("script-event", help="send a game script event, as a mod's button does (e.g. an upgrade)")
    se.add_argument("name")
    se.add_argument("--id", required=True, help="the id the game script listens to, e.g. a mod's UI id")
    se.add_argument("--param", help="a JSON object")
    rn = sub.add_parser("rename", help="rename an entity (a station, line, vehicle, depot), as the base's windows do")
    rn.add_argument("name", help="the new name")
    rn.add_argument("--entity", type=int, required=True, help="its id (stations, lines, vehicles, depots, entities)")
    to = sub.add_parser("tool", help="open or close a base window that is a tool (music, calendar, notifications)")
    to.add_argument("name", nargs="?")
    to.add_argument("--module", help="a GUI module that returns the tool, e.g. /gui/music_player/music_player.tl")
    to.add_argument("--field", help="the tool's field in that module")
    to.add_argument("--close", action="store_true")
    vehicle_help = {
        "buy": "buy new vehicles of a model at a depot (the store's way by default)",
        "duplicate": "clone a vehicle (as the line manager's clone button)",
        "replace": "replace a vehicle with another model",
        "sell": "sell a vehicle",
    }
    for name, helptext in vehicle_help.items():
        vb = sub.add_parser(name, help=helptext)
        if name != "buy":
            vb.add_argument("--vehicle", type=int, required=True)
        if name in ("buy", "replace"):
            vb.add_argument("--model", required=True, help="model id, or a unique part of its file name" + (
                "; a name ending in .mu.lua buys that multiple unit (the whole train its file lists, e.g. "
                "shinkansen_0s.mu.lua; via gui only)" if name == "buy" else ""))
        if name in ("buy", "duplicate"):
            vb.add_argument("--depot", type=int, required=(name == "buy"),
                            help="depot entity (the depots command)" + ("" if name == "buy" else
                                                                         "; default: the engine's best for the vehicle"))
            vb.add_argument("--line", type=int, help="send the new vehicle onto this line")
        if name == "buy":
            vb.add_argument("--count", type=int, default=1)
        vb.add_argument("--via", choices=["gui", "cmd"], default="gui",
                        help="gui: the base's HandleVehicleChanges (stamps purchaseTime); cmd: the engine command alone")
    sk = sub.add_parser("stock", help="a stock list's stocks: list (read only), set (a debug command: test saves "
                                      "only, not checked in a game yet)")
    ssub = sk.add_subparsers(dest="action", required=True)
    skl = ssub.add_parser("list", help="read only: the stocks (ids 0-based), cargo, capacity, counts per cargo; a "
                                       "vehicle's load per cargo")
    skl.add_argument("--entity", type=int, required=True, help="an industry, station, town building, warehouse, a "
                                                               "construction with one (as build gives it) or a "
                                                               "vehicle (industry-stocks, stations, entities --kind "
                                                               "warehouse, vehicles)")
    sks = ssub.add_parser("set", help="changes the save's contents (saving keeps it); set a stock's amount (api.cmd.debug.makeStockSetCargoAmountCmd): meant for test saves (not checked)")
    sks.add_argument("--entity", type=int, required=True, help="as stock list")
    sks.add_argument("--stock", type=int, required=True, help="the stock's id as stock list shows it (0-based); -1: "
                                                              "a vehicle's load (with --cargo)")
    sks.add_argument("--amount", type=int, required=True, help="0-%d, at most the stock's capacity" % STOCK_MAX_AMOUNT)
    sks.add_argument("--cargo", help="a cargo type's name exactly as stock list shows it (its cargo field); a stock "
                                     "list's stock: optional")
    sks.add_argument("--dry-run", action="store_true", help="check and show the before, send nothing")
    st = sub.add_parser("steps", help="changes the save's contents (saving keeps it); run the simulation N steps on (api.cmd.debug.makeGamePerformSimulationStepsCmd) "
                                      "and answer once they have all run; one step is 200 of game time (20 a day). "
                                      "Pause first (speed 0). Meant for test saves (not checked)")
    st.add_argument("count", type=int, help="1-%d" % STEPS_MAX)
    st.add_argument("--dry-run", action="store_true", help="check and show the game time, send nothing")
    st.add_argument("--allow-running", action="store_true",
                    help="send while the game is not paused (refused otherwise): the deltas then mix the steps with "
                         "the game's own running, and the wait may end early")
    mo = sub.add_parser("money", help="changes the save's contents (saving keeps it); set or change the company's balance (a journal entry of category OTHER, "
                                      "as the sandbox money editor)")
    mg = mo.add_mutually_exclusive_group(required=True)
    mg.add_argument("--set", type=int, help="the balance to have")
    mg.add_argument("--add", type=int, help="the amount to add (negative: take away)")
    dp = sub.add_parser("depots", help="vehicle depots with their ids, kinds (from transport modes) and vehicles inside")
    dp.add_argument("--grep")
    vl = sub.add_parser("vehicles", help="the company's vehicles: parts, purchaseTime, line, depreciated value")
    vl.add_argument("--line", type=int)
    vl.add_argument("--limit", type=int, default=200)
    vl.add_argument("--entity", help="only these vehicles (ids, comma-separated); gone ones are listed under missing")
    vl.add_argument("--state", action="store_true", help="add what the engine holds about each vehicle's stop "
                    "(state, loadState, doorsTime, lineStopDepartures, timeUntil*, load speed modifiers), the cargo "
                    "on board, its running cost per year and balance; and the game time")
    vl.add_argument("--since", type=int, help="with --state: each vehicle's balance (income less costs) from this "
                    "game time (the gameTime of an earlier answer)")
    vl.add_argument("--at-terminal", action="store_true", help="with --state: only the vehicles at a terminal now "
                    "(state AT_TERMINAL); total counts those")
    vl.add_argument("--every", type=float, help="repeat every this many seconds (at least 0.5): one JSON line each "
                    "(with --state: each with its gameTime)")
    vl.add_argument("--count", type=int, help="with --every: this many samples (default: until Ctrl-C)")
    mdl = sub.add_parser("models", help="vehicle models (read only): the store's price and running costs, priceScale, "
                                        "speed, capacity per cargo type, loadSpeed, compartments, waterVehicle")
    mdl.add_argument("--grep", help="a part of the file name or the shown name, any case (digits: the id too)")
    mdl.add_argument("--carrier", type=str.upper, choices=["ROAD", "RAIL", "TRAM", "AIR", "WATER"], help="any case")
    mdl.add_argument("--limit", type=int, default=200, help="details for this many, 1-1000 (total counts them all)")
    mdl.add_argument("--mu", nargs="?", const=True, default=None, metavar="FILTER",
                     help="the multiple units (.mu.lua) instead: id, getName's and getAll's names, shown name, cars, "
                          "and buyAs (what buy --model takes); FILTER: a part of a name or the shown name, any case")
    sg = sub.add_parser("stations", help="the company's (and nobody's) station groups: id, stations, platforms, "
                                         "carriers, position; per platform (station:terminal) its tag, position, "
                                         "load flags, cargoTransferSpeeds and carriers")
    sg.add_argument("--name", help="a part of the name, any case")
    sg.add_argument("--near", type=int, help="only those within --radius of this entity (a town, industry, ...)")
    sg.add_argument("--radius", type=float, help="metres around --near (default 1000); with --catchment: the circle "
                                                 "its diagnosis uses when the engine gives none")
    sg.add_argument("--catchment", type=int, metavar="ID",
                    help="what this station or station group reaches (read only): town buildings per town "
                         "(residential, commercial, industrial) and industries, for passengers and for cargo; "
                         "and why: its circles (radius, from the engine), the nearest town buildings of each kind, "
                         "those in a circle the engine does not count and whether they can be walked to (diagnosis)")
    sg.add_argument("--paths", type=int, metavar="N",
                    help="with --catchment: walking searches for buildings in the circle the engine does not count "
                         "(default 20, 0: none, at most 50)")
    iw = sub.add_parser("industry-workers", help="industries (read only): capacity, sims with it as destination, "
                                                  "last visitors of the base's workers script, productivity, nearest town")
    iw.add_argument("--entity", type=int, help="one industry's id (entities --kind industry); none: all")
    ist = sub.add_parser("industry-stocks", help="industries (read only): stocks (cargo, capacity, count), rules, "
                                                 "modifiers, and the construction's file and params (hummer_aom_upg_*)")
    ist.add_argument("--entity", type=int, help="one industry's id (entities --kind industry); none: all")
    ist.add_argument("--grep", help="a part of the name, any case")
    ist.add_argument("--all-params", action="store_true", help="every param of the construction too")
    co = sub.add_parser("company", help="read only: the base's company progression (company.gs basePopulation, the "
                        "company's level and ticket price multiplier) and what is missing; company init: meant for test saves "
                        "(not checked)")
    cos = co.add_subparsers(dest="company_action", required=False, metavar="{init}")
    ci = cos.add_parser("init", help="changes the save's contents (saving keeps it); meant for test saves (not checked): send the base's start event initNewGameFromMap again, when "
                        "company.gs has no basePopulation, or 0 while the towns have population now (a game started "
                        "with no towns); "
                        "it also resets the towns' cached ratings, the subventions and the notifications")
    ci.add_argument("--dry-run", dest="company_dry_run", action="store_true", help="the states, nothing sent")
    ci.add_argument("--force", dest="company_force", action="store_true", help="send in any case (also after a send "
                    "that timed out, whose event may still run): it resets the company's progression")
    rc = sub.add_parser("running-costs", help="(its writes change the game as no player can, for the rest of the session) a vehicle model's running-cost fields (metadata.cost and "
                        ".maintenance) and its vehicles' running cost per year; read only, unless a --set-* / "
                        "--scale-* writes (test saves only, not in coop: it rewrites the model for the rest of the "
                        "session, to see whether the engine bills the new value)")
    rc.add_argument("--model", required=True, help="an id, a file name or a part of it (models --grep lists them)")
    rc.add_argument("--set-running", type=float, metavar="X", help="write maintenance.runningCosts = X")
    rc.add_argument("--scale-running", type=float, metavar="K", help="write maintenance.runningCosts x K")
    rc.add_argument("--set-maintenance", type=float, metavar="Y", help="write maintenance.maintenanceScale = Y "
                    "(the model has no maintenance amount of its own, only this scale)")
    rc.add_argument("--scale-maintenance", type=float, metavar="K", help="write maintenance.maintenanceScale x K")
    rc.add_argument("--set", dest="set_fields", action="append", metavar="FIELD=X",
                    help="write any of %s (repeatable)" % ", ".join(RUNNING_COST_FIELDS))
    rc.add_argument("--scale", dest="scale_fields", action="append", metavar="FIELD=K", help="the same, x K")
    rc.add_argument("--where", choices=["script", "gui"], help="the Lua state that writes: script (default; the game "
                    "script, as price_probe wrote prices; needs the mod setting gameScript, --param "
                    "hummer_remote_probe:gameScript=2 at launch / load) or gui")
    rc.add_argument("--limit", type=int, help="list this many of the model's vehicles (default 20, 0-50)")
    fi = sub.add_parser("finance", help="read only: the finance table's rows per carrier (MAINTENANCE / VEHICLE: the "
                        "vehicles' running costs; VEHICLE_MAINTENANCE), and calculateBalance of the fleet and of "
                        "vehicles from --since to now")
    fi.add_argument("--since", type=float, metavar="GAMETIME", help="from this game time (an answer's gameTime); "
                    "default: a twelfth of a year back")
    fi.add_argument("--vehicles", metavar="E1,E2", help="these vehicles each (at most 50)")
    fi.add_argument("--columns", type=int, help="columns of the finance table, 1-8 (default 4: the years)")
    pa = sub.add_parser("parcels", help="read only: the town building parcels on the left and right of a road "
                                        "piece (count, built on, centre, area), from the engine's parcel system; "
                                        "not checked in a game yet")
    pg = pa.add_mutually_exclusive_group(required=True)
    pg.add_argument("--edge", type=int, help="one road piece's entity id (parcels --rect lists the pieces in a box)")
    pg.add_argument("--rect", metavar="X0,Y0,X1,Y1", help="the street pieces with an end or their middle in this box, "
                    "at most %d m a side (for a negative x write --rect=-100,0,100,50)" % PARCELS_RECT_MAX)
    pl = pa.add_mutually_exclusive_group()
    pl.add_argument("--list", dest="list", action="store_true", default=None,
                    help="each parcel too (the default for --edge; --rect gives counts only)")
    pl.add_argument("--no-list", dest="list", action="store_false", help="counts only")
    ar = sub.add_parser("around", help="read only: what stands near a point, nearest first: id, kind (street, track, "
                        "town_building, station, depot, industry, field, ...), name (a house's town), place, box (the "
                        "octree's, axis aligned), distance; a construction's road ends and mouths in its own frame")
    ar.add_argument("--at", required=True, metavar="X,Y", help="the point (for a negative x write --at=-100,50)")
    ar.add_argument("--radius", type=float, help="metres (default 100, at most %d)" % AROUND_RADIUS_MAX)
    ar.add_argument("--kinds", metavar="A,B", help="only these (all: every kind; default all but node, moving and map: map is a box "
                    "the size of the map): "
                    + ", ".join(AROUND_KINDS))
    ar.add_argument("--limit", type=int, help="entries listed, nearest first (default 200, at most %d)" % AROUND_LIMIT_MAX)
    ar.add_argument("--lanes", action="store_true", help="also each street's and track's lanes (the nearest 100), "
                    "as lanes --edge gives them without the transport network")
    st = sub.add_parser("strips", help="read only: the engine's parallel strips of tracks (a tunnel's or bridge's "
                        "walls go along them): kind (carrier, edge type, tunnel, bridge), range groups as read (each "
                        "group's pieces in order, with bounds), length, curvature, ends (dead end, junction), across "
                        "offsets, BRIDGE's placed pieces, and what could not be read (lane.type among them)")
    st.add_argument("--edge", metavar="ID[,ID...]", help="track piece ids (around --kinds track), at most %d"
                    % STRIPS_EDGES_MAX)
    st.add_argument("--at", metavar="X,Y", help="every track piece within --radius of the point (for a negative x "
                    "write --at=-100,50)")
    st.add_argument("--radius", type=float, help="metres, with --at (default 30, at most %d)" % STRIPS_RADIUS_MAX)
    st.add_argument("--limit", type=int, help="strips listed (default 20, at most %d)" % STRIPS_LIMIT_MAX)
    st.add_argument("--gs", action="store_true", help="read in the probe's game script (through eval --gs: needs "
                    "\"eval\": true in the configuration file and --param hummer_remote_probe:gameScript=2 at load)")
    la = sub.add_parser("lanes", help="read only: road or track pieces' lanes, left to right looking from node0 to "
                        "node1: number, side and metres from the middle, direction, transport modes (TRAM, "
                        "ELECTRIC_TRAM, BUS, CAR, PERSON, ...), speed, width; the piece's street type, bridge or "
                        "tunnel, tram track (NO, YES, ELECTRIC: from the lanes) and bus lanes")
    la.add_argument("--edge", required=True, metavar="ID[,ID...]", help="piece ids (around --kinds street, "
                    "road --inspect-node), at most %d" % EDGE_LANES_MAX)
    la.add_argument("--no-network", action="store_true", help="leave out the transport network's own edges")
    fi = sub.add_parser("fit", help="where a construction fits near a point: around's list searched here (its box, "
                        "turns, a road end for its mouth, town buildings near), the best few asked of the engine "
                        "(build --dry-run --engine-check: counts as changing the game). Builds nothing")
    fi.add_argument("--res", required=True, help="the construction's resName, as build takes it")
    fi.add_argument("--params", help="a JSON object over its defaults, as build takes it")
    fi.add_argument("--at", required=True, metavar="X,Y", help="the wanted point (for a negative x write --at=-100,50)")
    fi.add_argument("--radius", type=float, help="how far from it it may go (default 100, at most %d m)" % FIT_RADIUS_MAX)
    fi.add_argument("--step", type=float, help="the grid's step without --mouth (default 4 m)")
    fi.add_argument("--angle", type=float, help="this turn only (radians); default: four quarter turns, with --mouth "
                    "every 15 degrees")
    fi.add_argument("--size", metavar="W,D[,X,Y]", help="its box in its own frame (W along its x; X,Y: the box's "
                    "centre from its origin); default: from the engine's check at the point, unturned")
    fi.add_argument("--mouth", metavar="DX,DY", help="the road end in its own frame (build's connectable[].local, "
                    "around's mouths; a road depot: 0,-35): only places with it a short way straight out from a road "
                    "piece of no construction (never on its node), answered with the link and its road command")
    fi.add_argument("--link", metavar="MIN,MAX", help="with --mouth: the link road's length, mouth to the road's "
                    "centre line (default %g,%g m)" % FIT_LINK_DEFAULT)
    fi.add_argument("--link-edge", action="store_true", help="with --mouth: also links ending on a road piece's middle, "
                    "after every node's (road joins nodes only: a new node there, not checked in a game)")
    fi.add_argument("--track", action="store_true", help="with --mouth: on a track's end instead of a road's "
                    "(put on its node, as before)")
    fi.add_argument("--houses", type=int, help="at least this many town buildings within --catchment of its centre")
    fi.add_argument("--catchment", type=float, help="metres for --houses (default %d)" % FIT_CATCHMENT_DEFAULT)
    fi.add_argument("--check", type=int, help="the best places asked of the engine, in turn (default 3, at most %d; "
                    "0: none, read only, needs --size)" % FIT_CHECK_MAX)
    ps = sub.add_parser("persons", help="sim persons (read only) aboard a vehicle or on a line: happiness, expected "
                                        "arrival and the game time, line and stops; the engine's unhappy counts")
    pw = ps.add_mutually_exclusive_group(required=True)
    pw.add_argument("--vehicle", type=int, help="the company's vehicle (vehicles lists them); gone: missing true")
    pw.add_argument("--line", type=int, help="the company's line: who rides it (those waiting for it too: not checked)")
    pw.add_argument("--town", type=int, help="a town's residents (those whose home is one of its buildings)")
    pw.add_argument("--destination", type=int, help="those with this entity (an industry, a town building) as a "
                    "destination: home, shop or work")
    ps.add_argument("--limit", type=int, help="persons listed, 1-2000 (default 200; total counts them all)")
    ps.add_argument("--every", type=float, help="repeat every this many seconds (at least 0.5): one JSON line each")
    ps.add_argument("--count", type=int, help="with --every: this many samples (default: until Ctrl-C)")
    rc = sub.add_parser("reach", help="read only: whether places can be got to, as the engine keeps it (its "
                                      "targets' isReachable walk / drive / lines, town problems, a path search); "
                                      "not checked in a game yet")
    rc.add_argument("--api", action="store_true", help="which of the engine functions are there (calls none)")
    rc.add_argument("--problems", action="store_true", help="every town's problems (Disconnected, Overlength)")
    rc.add_argument("--target", type=int, help="an industry, town building, station or construction: its target "
                    "entries (reachable walking, driving, by lines) and its town's problems")
    rc.add_argument("--town", type=int, help="a town: its buildings' target entries counted (and the first "
                    "--limit listed, those out of reach first) and its problems")
    rc.add_argument("--limit", type=int, help="with --town: entries listed, 0-%d (default 20)" % REACH_LIMIT_MAX)
    rc.add_argument("--from", dest="from_", metavar="A", help="an entity id or a point x,y")
    rc.add_argument("--to", metavar="B", help="an entity id or a point x,y")
    rc.add_argument("--mode", choices=("walk", "drive", "lines", "all"), help="with --from/--to: walk (footways), "
                    "drive (roads), lines (the target's mark only) or all (walk and drive, the default)")
    rc.add_argument("--radius", type=float, help="m round a point (or a place without nodes of its own) the "
                    "network nodes are taken from (default 40)")
    ls = sub.add_parser("lines", help="the company's lines: stops and platforms, vehicles, cargo")
    ls.add_argument("--name", help="a part of the name, any case")
    ls.add_argument("--line", type=int, help="this line only (its entity id)")
    ls.add_argument("--problems", action="store_true",
                    help="each line's problems as the line manager reads them (no path, incompatible or duplicate "
                         "stop, where the path ends and the modes there), each platform's transport modes and the "
                         "line's mode union (read only)")
    ln = sub.add_parser("line", help="create, change or remove a line (the line manager's way by default)")
    lsub = ln.add_subparsers(dest="action", required=True)
    for action, helptext in (("create", "a new line through the stops, platforms assigned by the engine or given"),
                             ("update", "change a line's stops, name, cargo, platforms or load modes"),
                             ("delete", "remove a line (its vehicles too with --sell-vehicles)")):
        la = lsub.add_parser(action, help=helptext)
        if action != "create":
            la.add_argument("line", type=int, help="line entity (the lines command)")
        if action != "delete":
            la.add_argument("--stops", required=(action == "create"),
                            help="station groups in order, comma-separated: ids or parts of names (stations command)")
            la.add_argument("--name", help="the line's name (create: default the base's next 'Line N')")
            la.add_argument("--cargo", help="load only this cargo (id or name), at the stops that make it, as the cargo filter")
            la.add_argument("--terminals", metavar="S:T,...",
                            help="the platform of every stop, in order: station:terminal (or terminal, station 0), "
                                 "0-based as the stations command lists them (platforms); all stops or none. Each "
                                 "is checked to exist and to serve a carrier all of them share (update of a line "
                                 "with vehicles: the vehicles' carrier). Default: the engine assigns them")
            la.add_argument("--load-mode", metavar="MODE[,...]",
                            help="available, any (full load, any cargo) or all (full load, all cargo): one for every "
                                 "stop, or one per stop in order (Line.Stop.loadMode)")
            la.add_argument("--force-unload", metavar="0|1,...",
                            help="0 or 1 for every stop, in order: unload at a matching input stock even when it is "
                                 "full, the cargo being lost (\"Unload Even if Stocks Are Full\"); without a matching "
                                 "input stock nothing is unloaded either way (Line.Stop.stopConfig.forceUnload)")
            la.add_argument("--via", choices=["gui", "cmd"], default="gui",
                            help="gui: the base's line_util (in the speed control); cmd: stops built by the probe")
        else:
            la.add_argument("--sell-vehicles", action="store_true", help="sell the line's vehicles first, as the "
                                                                         "line manager's delete does")
    cn = sub.add_parser("connect", help="a track (or road) between two free ends, planned and built by the Track "
                                         "Connector mod (which the save needs); without --build only checked")
    cn.add_argument("--from", dest="from_", required=True, metavar="END",
                    help="a free end's node id, a station (group) id or a part of a station's name, or a depot's id "
                    "(its one free end; two or more are listed and refused)")
    cn.add_argument("--to", required=True, metavar="END", help="as --from")
    cn.add_argument("--road", action="store_true", help="a road instead of a track (between dead-end roads)")
    cn.add_argument("--template", help="--road: the road type's full resource name (default: as the start road, or a "
                    "country road of the game's year when that is a construction's entrance road or out of its years)")
    cn.add_argument("--track", help="standard (default), high_speed, simple, or a track type's full resource name")
    cn.add_argument("--electric", action="store_true", help="with overhead wires")
    cn.add_argument("--slope", type=float, help="the steepest grade in percent (default 2.5 tracks, 6 roads)")
    cn.add_argument("--radius", type=float, help="the tightest curve in metres (default 300 tracks, 100 roads)")
    # (pairs of store_true / store_false, not BooleanOptionalAction: that needs Python 3.9, and the parser is built
    # for every command)
    for what in ("bridges", "tunnels"):
        cn.add_argument("--" + what, dest=what, action="store_true", help="allow %s (the default)" % what)
        cn.add_argument("--no-" + what, dest=what, action="store_false", help="no " + what)
    cn.set_defaults(bridges=None, tunnels=None)
    cn.add_argument("--build", action="store_true", help="build it (default: only plan and check it)")
    cn.add_argument("--clear", action="store_true", help="with --build: knock down town buildings in the way")
    cn.add_argument("--timeout", type=float, default=120, help="seconds for the whole command (10-1800)")
    mx = sub.add_parser("mod", help="other mods' commands: those a mod ships in remote_probe_ext.lua (--list, or a "
                        "mod's id alone, reads which there are); a command tagged changes goes past the owner check "
                        "(the tag is the mod's own claim: one tagged reads is sent without it). With --read-only "
                        "only a command tagged reads runs, anything else is refused (exit 4) without running. "
                        "Forms a guard outside may let through by their shape: 'mod --list' alone, and "
                        "'mod <modId> <command> [JSON] --read-only'; 'mod <modId>' (one mod's list) is not one of "
                        "them")
    mx.add_argument("mod_id", nargs="?", metavar="MOD_ID", help="the mod's id (its mod.json modId)")
    mx.add_argument("mod_command", nargs="?", metavar="COMMAND", help="one of the mod's commands")
    mx.add_argument("mod_json", nargs="?", metavar="JSON", help="the command's arguments: a JSON object or list "
                    "(default {})")
    mx.add_argument("--list", action="store_true", help="the mods with commands, and their commands (read only; it "
                    "requires every candidate mod's remote_probe_ext.lua, so their top-level code runs in the game). "
                    "Alone: with a mod's id, a command or JSON it is an error and nothing is sent")
    mx.add_argument("--read-only", action="store_true", help="run the command only if its mod tags it reads; "
                    "otherwise refuse (exit 4) and do not send it again as a change (the tag is the mod's own claim)")
    mx.add_argument("--timeout", type=float, help="seconds to wait for the answer (default %d, %d-%d; for a list %d, "
                    "%d-%d; the mod gives a command that defers its answer %d s less)"
                    % (MOD_TIMEOUT_SEC, MOD_EXT_MARGIN_SEC + 1, MOD_EXT_TIMEOUT_MAX + MOD_EXT_MARGIN_SEC,
                       MOD_LIST_TIMEOUT_SEC, MOD_LIST_TIMEOUT_MIN, MOD_LIST_TIMEOUT_MAX, MOD_EXT_MARGIN_SEC))
    ev = sub.add_parser("eval", help="needs \"eval\": true in the configuration file. Run Lua code in the game and "
                        "read its value (as JSON) and print output back. Read only: the code runs in an environment "
                        "without api.cmd, api.gui, app, game, io and the functions under api named as writers (a "
                        "userdata's own methods are not covered), on any save. --write: with every global, on test "
                        "saves only (during coop also --user-asked); the save entry points raise")
    ev.add_argument("code", nargs="?", help="the code: an expression ('api.engine.getComponent(1, 1)') or "
                    "statements ending in return")
    ev.add_argument("--file", help="read the code from this file instead")
    ev.add_argument("--write", action="store_true", help="changes the save's contents (saving keeps it); run with "
                    "every global (test saves only)")
    ev.add_argument("--gs", action="store_true", help="run in the probe's game script (needs the mod setting "
                    "gameScript: --param hummer_remote_probe:gameScript=2 at launch / load) instead of the GUI's "
                    "Lua state")
    ev.add_argument("--depth", type=int, help="table levels in the answer (default 6, 1-%d)" % EVAL_DEPTH_MAX)
    ev.add_argument("--max-chars", type=int, help="characters of JSON in the answer (default 200000, %d-%d)"
                    % (EVAL_CHARS_MIN, EVAL_CHARS_MAX))
    ev.add_argument("--user-asked", action="store_true", help="--write during coop: only when the user asked for it")
    mh = sub.add_parser("modhub", help="My Mods (the staging area) from the main menu: status, validate, publish "
                                       "(one new mod, or an update of one on mod.io)")
    msub = mh.add_subparsers(dest="action", required=True)
    mst = msub.add_parser("status", help="read only: whether the publish helper can be made, mod.io's state, and "
                                         "each staging mod (state, mod.io id, mod.io details and visibility)")
    mst.add_argument("--folder", help="only this staging folder (its name, e.g. my_mod_1)")
    mst.add_argument("--wait", type=float, help="seconds to wait for mod.io and the staging mods' sync (0-120, "
                                                "default 30; 0: answer at once)")
    mva = msub.add_parser("validate", help="validate one staging mod as My Mods' Re-Validate does (only the "
                                           "folders the mod allows); answers PC and console results")
    mva.add_argument("folder", help="the staging folder name (modhub status lists them)")
    mva.add_argument("--timeout", type=float, help="seconds before the validation is aborted (default 300, at "
                                                   "most 1800)")
    mva.add_argument("--messages", type=int, help="validator messages listed (0-500, default 50; all are counted)")
    mpu = msub.add_parser("publish", help="upload one mod to mod.io as My Mods' Upload / Update button (only the "
                                          "folders both this tool and the mod allow): a new mod with --first-upload, "
                                          "else an update of the mod.io page in _metadata/" + FILEID_NAME)
    mpu.add_argument("folder", help="the staging folder name")
    mpu.add_argument("--public", help="yes or no (required: there is no default visibility)")
    mpu.add_argument("--changelog", help="the changelog text (required)")
    mpu.add_argument("--first-upload", action="store_true", help="a new mod (refused when the folder has "
                     + FILEID_NAME + "); without it, an update (refused when it has none)")
    mpu.add_argument("--previous-revision", type=int, help="an update only, when " + HISTORY_NAME + " records no "
                     "revision for that mod.io mod: the revision now on mod.io (mod.json's must be above it)")
    mpu.add_argument("--version", help="X.Y.Z, sent as PublishSettings.additionalMetadata {version = X.Y.Z} (a "
                     "trial); must be mod.json's revision X*10000+Y*100+Z")
    mpu.add_argument("--update-metadata", action="store_true", help="an update only: send modinfo.json's name, "
                     "summary and description too (they replace the mod.io page's; a description written on mod.io "
                     "is overwritten). Without it an update keeps the page's; a first upload always sends them")
    mpu.add_argument("--dry-run", action="store_true", help="check and validate, answer the settings; no upload")
    mpu.add_argument("--timeout", type=float, help="seconds for the mod's whole command (default 900, at most 3600); "
                                                   "past it the upload is not aborted and its outcome is unknown")
    mpu.add_argument("--messages", type=int, help="validator messages listed (0-500, default 50)")
    mpc = msub.add_parser("publish-clear", help="remove the publish mark (" + PENDING_NAME + ") after looking at "
                                                "mod.io (not while the game says the upload is Publishing)")
    mpc.add_argument("--yes", action="store_true", help="required: you looked at mod.io")
    v = sub.add_parser("save")
    v.add_argument("name", help="the save's name; after road --ignore-errors in this run of the game, only "
                   + FORCED_SAVE_PREFIX + "* names")
    v.add_argument("--user-asked", action="store_true", help="during coop with a person's save loaded: save to a "
                   "new test save's name, only when the user asked for it")
    cp = sub.add_parser("coop", help="share the running game with the user: the --owner client may look, build and "
                        "send test commands, not quit, load or save the user's game")
    cps = cp.add_subparsers(dest="coop_action", required=True)
    cst = cps.add_parser("start", help="put the coop mark for --owner on the running game (this owner's, or one a "
                         "person started)")
    cst.add_argument("--minutes", type=int, default=60, help="how long it counts (1-%d, default 60)" % COOP_MINUTES_MAX)
    cst.add_argument("--reason", required=True, help="what the user and the client do together")
    cps.add_parser("end", help="remove the coop mark (says whether the game was changed during coop)")
    sub.add_parser("state", help="where the game is (menu, loading, ...), from its log; needs no mod")
    sub.add_parser("restore-profile", help="put profile.lua back from the backup launch / restart --lang made (not "
                                           "while the game runs)")
    sub.add_parser("clean", help="remove every probe file; the current load's too when the game is closed, has "
                   "crashed, or is at the main menu or starting")
    lg = sub.add_parser("log", help="lines of the game's stdout.txt")
    lg.add_argument("--grep")
    lg.add_argument("--tail", type=int, default=50)
    kl = sub.add_parser("keep-log", help="copy the game log to crash_dump/logs now (launch and restart do it "
                                         "before every start); lists the kept logs")
    kl.add_argument("--list", action="store_true", help="only list the kept logs")
    _test_module().add_parser(sub)
    return p


def _test_module():
    """tools/tf3ctl_test.py (test scenarios), loaded from beside this file: tf3ctl may be run or loaded by path."""
    mod = sys.modules.get("tf3ctl_test")
    if mod is None:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "tf3ctl_test", os.path.join(os.path.dirname(os.path.abspath(__file__)), "tf3ctl_test.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        sys.modules["tf3ctl_test"] = mod
    return mod


def main(argv=None):
    for stream in (sys.stdout, sys.stderr):  # Windows' console code page cannot show every name in the answers
        enc = (getattr(stream, "encoding", None) or "").lower().replace("-", "").replace("_", "")
        if hasattr(stream, "reconfigure") and enc != "utf8":  # an UTF-8 stream (Linux) is left as it is
            try:
                stream.reconfigure(encoding="utf-8")
            except (ValueError, OSError):
                pass
    ns = make_parser().parse_args(argv)
    global OWNER, OTHER_OWNER_OK, USER_ASKED, CONFIG, CONFIG_INFO
    OWNER = ns.owner
    OTHER_OWNER_OK = ns.other_owner_ok
    USER_ASKED = getattr(ns, "user_asked", False)
    CONFIG, CONFIG_INFO = load_config()  # each run reads it again: a long-lived caller (tests) sees a changed file
    broken = config_broken_text()
    if broken:
        print("error: " + broken, file=sys.stderr)
        if ns.cmd == "config":  # the one command that answers: it shows what to fix
            show({"ok": False, "error": broken, "config": None, "file": CONFIG_INFO})
        else:
            show({"ok": False, "error": broken, "refused": "config-broken", "config": CONFIG_INFO})
        return 2
    for line in test_save_warnings():
        print(line, file=sys.stderr)
    if ns.cmd == "test":  # each step runs through main itself, with its checks
        try:
            return _test_module().cmd_test(ns, main, make_parser, game_log_path, show)
        except KeyboardInterrupt:
            return 130

    try:
        if ns.cmd == "config":
            out = {"ok": True, "config": CONFIG, "file": CONFIG_INFO}
            notes = test_save_warnings()
            if notes:
                out["warnings"] = notes
            show(out)
            return 0
        if ns.cmd == "log":
            cmd_log(ns)
            return 0
        if ns.cmd == "keep-log":
            show(cmd_keep_log(ns))
            return 0
        if ns.cmd == "pointer":
            show(cmd_pointer(ns))
            return 0
        if ns.cmd == "frame":
            show(cmd_frame(ns))
            return 0
        if ns.cmd == "state":
            show(dict(game_state(), **profile_note()))
            return 0
        if ns.cmd == "clean":
            folder = exchange_dir()
            st = game_state(folder)
            # only states in which no probe is running may lose the current load's files
            n = clean_all(folder, include_current=st["state"] in ("closed", "crashed", "main_menu", "starting"))
            show({"ok": True, "removed": n, "gameState": st["state"]})
            return 0
        if ns.cmd == "status":
            res = send("status")
            if isinstance(res, dict):
                res.update(config_note())
                res.update(profile_note())
                res.update(coop_note())
                res.update(forced_note())
        elif ns.cmd == "poll":
            args = {k: v for k, v in (("idle", ns.idle), ("active", ns.active)) if v is not None}
            res = send("poll", args)
        elif ns.cmd in ("speed", "pause"):
            speed, note, extra = (0, None, {}) if ns.cmd == "pause" else capped_speed(ns.speed, ns.force)
            if note:
                print("note: " + note, file=sys.stderr)
            res = send("speed", dict(extra, speed=speed))
            if note:
                res["speedNote"] = note
        elif ns.cmd == "calendar-speed":
            ccmd, cargs = calendar_speed_args(ns)
            res = send(ccmd, cargs)
        elif ns.cmd == "run":
            res = cmd_run(ns)
        elif ns.cmd == "saves":
            res = send("saves")
            res["saves"] = sorted(res.get("saves") or [], key=lambda s: -num(s.get("timestamp")))
        elif ns.cmd == "info":
            # longer than the mod's own 60 s limit, so its error answer arrives before this gives up
            res = send("info", {"save": ns.save}, timeout=90)
        elif ns.cmd == "load":
            res = replace_game("load", load_args(ns), ns.dry_run, ns.timeout)
        elif ns.cmd == "newgame":
            if not (ns.dry_run or ns.list or menu_probe(exchange_dir())):
                # 2026-11-15: app.startGame from inside a running game hit the base's StartGame assertion
                # `!m_game` and crashed TF3; the mod does not run in the main menu, where it would be allowed
                raise ToolError("newgame crashes the game when started from inside a save (StartGame asserts that "
                                "no game is running): use restart --new. --list and --dry-run still work.")
            res = replace_game("newgame", newgame_args(ns), ns.dry_run or ns.list, ns.timeout,
                               company_init=not ns.no_company_init)
        elif ns.cmd == "entities":
            args = {"kind": ns.kind, "limit": ns.limit}
            if ns.grep:
                args["grep"] = ns.grep
            res = send("entities", args)
        elif ns.cmd == "window":
            if ns.close_all:
                args = {"closeAll": True}
            elif ns.entity is not None:
                args = {"entity": ns.entity}
            else:
                kind = next(k for k in ("town", "line", "vehicle", "station", "industry", "warehouse")
                            if getattr(ns, k))
                args = {"kind": kind, "name": getattr(ns, kind)}
            if ns.manager:
                if ns.close_all or (ns.line is None and ns.entity is None):
                    raise ToolError("--manager opens a line: give --line NAME or --entity ID with it")
                args["manager"] = True
            if ns.focus:
                args["focus"] = True
            res = send("window", args)
        elif ns.cmd == "camera":
            res = send("camera", camera_args(ns))
        elif ns.cmd == "build-tool":
            res = send("buildTool", build_tool_args(ns))
        elif ns.cmd == "save":
            res = send("save", {"name": ns.name}, timeout=300)
        elif ns.cmd == "quit":
            res = quit_game(ns.timeout, kill=ns.kill, force=ns.force)
            try:
                restored = restore_profile()  # the process is gone now
                if restored:
                    res["profileRestored"] = restored
            except (ToolError, OSError) as e:  # the quit itself went through: say so, and how
                print("error: the game quit, but " + str(e), file=sys.stderr)
                res = dict(res, ok=False, profileError=str(e))
        elif ns.cmd == "restore-profile":
            restored = restore_profile()
            res = {"ok": True, "profileRestored": restored}
            if restored is None:
                res["note"] = "no backup of tf3ctl's to put back"
        elif ns.cmd in ("launch", "restart"):
            res = cmd_start(ns, ns.cmd == "restart")
        elif ns.cmd == "event":
            res = send("event", event_args(ns))
        elif ns.cmd == "script-event":
            res = send("scriptEvent", script_event_args(ns))
        elif ns.cmd == "rename":
            res = send("rename", rename_args(ns))
        elif ns.cmd == "build":
            args = build_args(ns)
            log_path = game_log_path()
            log_start = log_size(log_path)
            res = check_build_answer(args, send("build", args, timeout=BUILD_TIMEOUT_SEC), log_path, log_start)
        elif ns.cmd == "road" and ns.inspect_node is not None:
            res = send("roadInspect", road_inspect_args(ns))
        elif ns.cmd == "road":
            args = road_batch_args(ns) if ns.batch is not None else road_args(ns)
            log_path = game_log_path()
            log_start = log_size(log_path)
            res = check_build_answer(args, send("road", args, timeout=BUILD_TIMEOUT_SEC), log_path, log_start)
        elif ns.cmd == "track":
            args = track_batch_args(ns) if ns.batch is not None else track_args(ns)
            log_path = game_log_path()
            log_start = log_size(log_path)
            res = check_build_answer(args, send("track", args, timeout=BUILD_TIMEOUT_SEC), log_path, log_start)
        elif ns.cmd == "lights":
            res = send("lightsOff", lights_args(ns), timeout=BUILD_TIMEOUT_SEC)
        elif ns.cmd == "water":
            res = send("water", water_args(ns))
        elif ns.cmd == "terrain":
            if ns.probe_api:
                if ns.rect or ns.base is not None or ns.blend is not None or ns.via or ns.dry_run or ns.in_game:
                    raise ToolError("--probe-api takes nothing else")
                res = send("terrainApi", {}, timeout=30)
            else:
                res = send("terrain", terrain_args(ns), timeout=TERRAIN_TIMEOUT_SEC)
        elif ns.cmd == "town" and ns.town_action:
            gcmd, gargs = town_grow_args(ns)
            if gcmd == "townConnect":
                res = send(gcmd, gargs, timeout=TOWN_CONNECT_TIMEOUT_SEC)
            else:
                res = send(gcmd, gargs, timeout=town_grow_timeout(gcmd, gargs))
        elif ns.cmd == "town":
            res = send("town", town_args(ns), timeout=TOWN_TIMEOUT_SEC)
        elif ns.cmd == "tool":
            ev = tool_event(ns)
            if ev:
                res = send("event", ev)
                if isinstance(res, dict) and res.get("ok"):
                    res["note"] = ("sent the event " + ev["name"] + " instead of a tool push: this window's base "
                                   "button passes more than gameCtx, and a plain push makes the GUI reload")
            else:
                res = send("tool", tool_args(ns))
        elif ns.cmd in ("buy", "duplicate", "replace", "sell"):
            res = send(ns.cmd, vehicle_args(ns), timeout=VEHICLE_TIMEOUT_SEC)
        elif ns.cmd == "stock":
            if ns.action == "list":
                res = send("stockList", stock_args(ns))
            else:
                res = send("stockSet", stock_args(ns), timeout=STOCK_TIMEOUT_SEC)
        elif ns.cmd == "steps":
            res = send("steps", steps_args(ns), timeout=steps_timeout(ns.count))
        elif ns.cmd == "money":
            res = send("money", money_args(ns), timeout=VEHICLE_TIMEOUT_SEC)  # the mod's own wait is 60 s
        elif ns.cmd == "depots":
            res = send("depots", {"grep": ns.grep} if ns.grep else {})
        elif ns.cmd == "vehicles":
            if ns.every is not None:
                return vehicles_every(ns)  # prints its own lines
            res = send("vehicles", vehicles_args(ns))
        elif ns.cmd == "models":
            res = send("models", models_args(ns))
        elif ns.cmd == "stations":
            res = send("stations", stations_args(ns))
        elif ns.cmd == "industry-workers":
            res = send("industryWorkers", industry_workers_args(ns))
        elif ns.cmd == "industry-stocks":
            res = send("industryStocks", industry_stocks_args(ns))
        elif ns.cmd == "company":
            if ns.company_action == "init":
                cargs = {"dryRun": True} if ns.company_dry_run else {}
                if ns.company_force:
                    cargs["force"] = True
                res = send("companyInit", cargs, timeout=COMPANY_INIT_TIMEOUT_SEC)
            else:
                res = send("company")
        elif ns.cmd == "running-costs":
            rcmd, rargs = running_costs_args(ns)
            res = send(rcmd, rargs, timeout=RUNNING_COSTS_TIMEOUT_SEC)
        elif ns.cmd == "finance":
            res = send("finance", finance_args(ns))
        elif ns.cmd == "parcels":
            res = send("parcels", parcels_args(ns))
        elif ns.cmd == "around":
            res = send("around", around_args(ns), timeout=60)
        elif ns.cmd == "lanes":
            res = send("edgeLanes", lanes_args(ns))
        elif ns.cmd == "strips":
            res = cmd_strips(ns)
        elif ns.cmd == "fit":
            res = cmd_fit(ns)
        elif ns.cmd == "persons":
            if ns.every is not None:
                return persons_every(ns)  # prints its own lines
            res = send("persons", persons_args(ns))
        elif ns.cmd == "reach":
            res = send("reach", reach_args(ns))
        elif ns.cmd == "lines":
            res = send("lines", lines_args(ns))
        elif ns.cmd == "line":
            res = send("line", line_args(ns), timeout=VEHICLE_TIMEOUT_SEC)  # the mod's own wait is 60 s
        elif ns.cmd == "connect":
            res = cmd_connect(ns)
        elif ns.cmd == "modhub":
            res = cmd_modhub(ns)
        elif ns.cmd == "mod":
            res = cmd_mod(ns)
        elif ns.cmd == "eval":
            res = cmd_eval(ns)
        elif ns.cmd == "coop":
            res = cmd_coop(ns)
    except OwnerRefused as e:
        print("error: " + str(e), file=sys.stderr)
        show({"ok": False, "error": str(e), "refused": e.refused})
        return 4
    except GameNotReady as e:
        print("error: " + str(e), file=sys.stderr)
        out = {"ok": False, "error": str(e), "gameState": e.state}
        show(dict(out, **config_note(), **profile_note(), **coop_note(), **forced_note()) if ns.cmd == "status"
             else out)
        return 3
    except ToolError as e:
        print("error: " + str(e), file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 130
    show(res)
    return 0 if res.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
