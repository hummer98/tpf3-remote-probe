#!/usr/bin/env python3
"""Drive a running Transport Fever 3 through the remote probe mod (hummer_remote_probe).

The game's GUI Lua can only read and write its own userdata files, so this tool writes a command file next to the
mod's hello file and waits for the answer file. Answers carry one JSON string; the files themselves are Lua
("function data() return {...} end"), read here with luajit in an empty environment.

  tf3ctl.py status
  tf3ctl.py speed 16            # beyond the UI's 4x; 0 pauses
  tf3ctl.py run --months 2 --speed 16
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
  tf3ctl.py duplicate --vehicle 601 | replace --vehicle 601 --model bus_1920 | sell --vehicle 601
            # each answers with via, balance before/after, spent, the model's store price, parts' purchaseTime
  tf3ctl.py money --set 10000000 | --add -5000   # the balance, as the sandbox money editor (a journal entry)
  tf3ctl.py stations [--name cent] [--near 11 --radius 800]   # station groups: id, platforms, carriers, distance
  tf3ctl.py stations --catchment 47         # town buildings (per town and kind) and industries a station reaches
  tf3ctl.py lines [--name probe]            # lines: stops (platforms), vehicles, cargo loaded and carried
  tf3ctl.py lines --problems [--line 23]    # + each stop's path problems, platform modes, the line's mode union
  tf3ctl.py industry-workers [--entity 51]  # industries: capacity, sims headed there, last visitors (boost), town
  tf3ctl.py industry-stocks [--entity 51] [--grep mine] [--all-params]  # stocks, rules, construction params
  tf3ctl.py persons --vehicle 601 [--limit 50] [--every 5 --count 120]   # who is aboard: happiness, expected
            # arrival vs the game time; the engine's unhappy counts for the vehicle, its line and stops (read only).
            # --every: one compact JSON line per sample (JSON Lines), until --count or Ctrl-C; --line 21: a line's
            # riders instead of one vehicle (whether those waiting for it are included is not checked)
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
            # one straight road piece, no click: test saves only; an end within --snap m of a road node joins it
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
            # test saves only: makeTownDevelopAtCmd N times (1-200), one after another; answers sent / succeeded /
            # failed and the town buildings (residential, commercial, industrial) before / after, all and near
  tf3ctl.py town size --entity 801 --factors 2,1.5,1 [--update-all] [--dry-run]   # test saves only: the town's
            # size factors (makeTownUpdateSizeCmd); answers the factors and the town's buildings before / after
  tf3ctl.py stock list --entity 51          # read only: a stock list's stocks (ids 0-based), counts per cargo; an
            # industry, town building or warehouse, a station, or a vehicle (its load per cargo, stock -1)
  tf3ctl.py stock set --entity 51 --stock 0 --amount 100 [--cargo COAL] [--dry-run]   # debug command: test saves
            # only; a vehicle's load: --stock -1 --cargo NAME. Answers before / after and the engine's success
  tf3ctl.py steps 500 [--dry-run]           # debug command: the simulation 1-10000 steps on; test saves only.
            # Pause first (refused while running, unless --allow-running). Waits until all the steps ran
            # (1 step = 200 game time, 20 a day; 1000 steps about 15 s), then answers before / after / waitedSec
  tf3ctl.py pointer 0.5,0.47 [--px]          # the game's pointer only (hover, preview): no click, no key
  tf3ctl.py connect --from 801 --to 802 --road [--template ::/infrastructure/street/...street_template]
            # without --build: the route, its length, bridges and tunnels, slope, the dry run's cost and verdict
  tf3ctl.py modhub status [--folder F] | modhub validate F   # My Mods in the main menu (read; re-validate)
  tf3ctl.py modhub publish F --public yes --changelog "..." --first-upload [--version X.Y.Z] [--dry-run]   # one new mod to mod.io
            # (an allowed folder not on mod.io; no fileid yet; a mark in $XDG_STATE_HOME/tf3ctl/ until the fileid appears)
  tf3ctl.py modhub publish F --public yes --changelog "..." [--version X.Y.Z] [--dry-run]   # update the mod.io page of its fileid
            # (the fileid there; mod.json's revision above the last one uploaded, from publish_history.jsonl or,
            # when that has none, --previous-revision N)
  tf3ctl.py modhub publish-clear --yes       # remove that mark, after looking at mod.io

--owner (or TF3CTL_OWNER) names the client sending commands (a person or a script). It is only shown (status:
run.owner, lastAction) and used for a warning when another owner changed the game in the last 10 minutes; nothing
is refused, since clients sharing the game agree among themselves who uses it. launch / restart with an owner
also leave $XDG_RUNTIME_DIR/tf3ctl/launched.json (/tmp/tf3ctl-<uid>/ without it): that owner and the game's pid,
for tools that let the owner who started the game quit it; it goes when tf3ctl sees the game stopped.

Several tool processes may run at once (e.g. a long run plus status calls): a lock makes them write the single
command file one after another, each waiting until the mod has picked its command up.

Exit codes: 0 ok, 1 the game answered with an error, 2 no answer / tool error, 3 the game cannot answer where it
is (menu, loading, main menu, closed: gameState in the output says which).

Environment: TF3_REMOTE_DIR = the exchange folder (default: the newest hello file under Steam's userdata),
TF3_LOG = the game log, TF3_STEAM = the command that starts Steam, TF3CTL_OWNER = the default --owner,
LUAJIT = the luajit binary, TF3_PROFILE = the game's profile.lua (default: next to the exchange folder, else the newest
under Steam's userdata), TF3_GAME_DIR = the game's install folder (for the languages --lang may pick),
TF3CTL_OTHER_BACKUPS = backups of profile.lua made by other tools (files or folders, separated by ':'; a folder counts
while a file is in it): while one exists, --lang and the restore refuse, so the backups are put back in the reverse
order they were made.
"""
import argparse
import contextlib
import fcntl
import filecmp
import glob
import json
import math
import os
import re
import signal
import shutil
import stat
import subprocess
import sys
import tempfile
import time

PREFIX = "remote_probe__"
APP_ID = "3493540"
DIRS = ("recordings", "keyframes", "mod_presets")  # the mod's order (mod_presets files show up as presets)
SELF_MOD = "hummer_remote_probe"
STALE_SEC = 3600  # answers nobody read (a killed tool) are removed after this
PICKUP_TIMEOUT_SEC = 30  # the mod polls every 2 s when idle (at most 20 s); longer means it is not running
RECENT_SEC = 600  # another owner's game-changing command this recent gets a warning
CHANGES_GAME = {"speed", "run", "load", "save", "newgame", "window", "quit", "event", "tool", "buy", "duplicate",
                "replace", "sell", "money", "line", "connect", "camera", "buildTool", "scriptEvent", "rename",
                "build", "road", "terrain", "town", "modhubValidate", "modhubPublish",
                "stockSet", "steps", "townDevelop", "townSize"}  # window: what the player sees  # poll: only the mod's file reads
# modhubValidate: no save changes and nothing written to mod.io, but it runs the game's validator for minutes and
# aborts a validation a person may have started on the My Mods page. modhubStatus only reads. modhubPublish uploads.

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


class GameNotReady(ToolError):
    """The mod cannot answer because of where the game is (menu, loading, closed); exit code 3."""
    def __init__(self, msg, state):
        super().__init__(msg)
        self.state = state


# ---------------------------------------------------------------------------------------------------------------
# files


def userdata_roots():
    home = os.path.expanduser("~")
    roots = []
    for steam in (os.path.join(home, ".local", "share", "Steam"), os.path.join(home, ".steam", "steam"),
                  os.path.join(home, ".var", "app", "com.valvesoftware.Steam", ".local", "share", "Steam")):
        roots += glob.glob(os.path.join(steam, "userdata", "*", APP_ID, "local"))
    return roots


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
    r = subprocess.run([luajit, "-", path], input=READ_LUA, capture_output=True, text=True, timeout=10)
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
    os.replace(tmp, path)  # atomic: the game never reads half a command


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
        os.replace(tmp, activity_path(folder))
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
    with open(os.path.join(folder, PREFIX + "lock"), "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


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


def send(cmd, args=None, timeout=20, final_tag=None, on_progress=None, folder=None):
    folder = folder or exchange_dir()
    args = dict(args or {})
    if OWNER:
        args["_owner"] = OWNER
    with command_lock(folder):
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
        except ToolError:
            # withdraw it: a mod that wakes up later must not run a command reported as failed (a load twice)
            write_command(folder, 0, "none", {})
            raise
    try:
        return wait_answer(folder, cid, timeout, final_tag, on_progress)
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
    return os.path.join(os.path.dirname(folder.rstrip("/")), "crash_dump", "stdout.txt")


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


def game_pids():
    """TransportFever3's processes: their threads are named "Main Thread" etc. (pgrep -x TransportFever3 finds
    nothing), so look at the command line."""
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


def process_start(pid):
    """Unix time a process started, from /proc (None if unknown)."""
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


def log_tail_from_anchor(path):
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
            idx = max(body.rfind(a) for a in ANCHORS)
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


def replace_game(cmd, args, answer_only, timeout):
    """load / newgame: the mod acks, the next frame ends its game, and the new game's mod writes a new hello."""
    folder = exchange_dir()
    before = current_stamp(folder)
    if answer_only:
        return send(cmd, args, timeout=90, folder=folder)
    ack = send(cmd, args, timeout=90, final_tag="ack", folder=folder)
    try:
        if not ack.get("ok"):
            return ack
        held = bool(args.get("waitForStart"))
        print("loading ..." if cmd == "load" else "starting a new game ...", file=sys.stderr)
        if held:
            print("note: " + WAIT_FOR_START_NOTE, file=sys.stderr)
        after = wait_new_hello(folder, ack["id"], before, timeout, WAIT_FOR_START_SLOW if held else None)
        res = after if after.get("ok") is False else {"ok": True, "plan": ack, "hello": after}
        if held and res.get("ok"):  # a failed loadGame never reached the button
            res = dict(res, note=WAIT_FOR_START_DONE)
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
    if getattr(ns, "unsafe", False):
        args["unsafe"] = True  # the mod refuses a start from inside a save too
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
    """$XDG_RUNTIME_DIR/tf3ctl/launched.json, or /tmp/tf3ctl-<uid>/launched.json without XDG_RUNTIME_DIR."""
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
    if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid():
        raise OSError("%s is not a folder of this user" % folder)
    if stat.S_IMODE(st.st_mode) != 0o700:
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


def write_launched(pid, owner=None, cmd="launch", now=None):
    """Writes the launch record for pid started by owner, through a temporary file in the same folder and
    os.replace (a reader never sees half a file). Without an owner there is nothing to record: an older record is
    removed instead. Returns what was done for the command's answer; a failure is a warning."""
    owner = OWNER if owner is None else owner
    if not owner or pid is None:
        gone = remove_launched()
        return dict(gone or {}, written=False, why="no --owner" if not owner else "no game process found")
    path = launched_path()
    folder = os.path.dirname(path)
    record = {"v": 1, "owner": owner, "pid": int(pid), "started_at": int(time.time() if now is None else now),
              "cmd": cmd}
    tmp = None
    try:
        _own_private_dir(folder)
        fd, tmp = tempfile.mkstemp(prefix=".launched-", suffix=".tmp", dir=folder)  # 0600
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(record, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        tmp = None
    except OSError as e:
        print("warning: could not write the launch record %s: %s" % (path, e), file=sys.stderr)
        return {"written": False, "warning": "could not write %s: %s" % (path, e)}
    finally:
        if tmp:
            _remove_quietly(tmp)
    return {"written": path, "owner": owner, "pid": int(pid)}


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
    if not game_pids():
        return {"ok": True, "how": "not running"}
    err = None
    try:
        res = send("quit", timeout=20)
        if not res.get("ok"):
            err = res.get("error") or "the mod refused"
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
    for pid in game_pids():
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    if not wait_exit(15):
        raise ToolError("the game is still running after SIGKILL")
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
        os.replace(tmp, path)
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
        os.replace(tmp, backup)
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
    with open(profile + PROFILE_LOCK_SUFFIX, "a") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        _profile_lock_depth[0] = 1
        try:
            yield
        finally:
            _profile_lock_depth[0] = 0
            fcntl.flock(f, fcntl.LOCK_UN)


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


def launch_game(timeout=LAUNCH_TIMEOUT_SEC):
    """Starts the game through Steam with startup.lua, and waits until the probe answers in the main menu."""
    if game_pids():
        raise ToolError("the game is already running: use restart (or quit first)")
    remove_launched()  # a record of a game that is gone now (quit by hand, crashed)
    kept = keep_last_log()
    started = time.time()
    steam = os.environ.get("TF3_STEAM", "steam").split()
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
            no_towns=ns.no_towns, no_industries=ns.no_industries, list=False, unsafe=False, set_mods=ns.set_mods,
            add=ns.add, remove=ns.remove, param=ns.param, dry_run=False, tutorial=getattr(ns, "tutorial", False),
            editor=getattr(ns, "editor", False)))
    return None


def cmd_start(ns, restart):
    plan = start_args(ns)  # refused before anything is quit
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
    if plan:
        res = replace_game(plan[0], plan[1], False, ns.timeout)
        out[plan[0]] = res
        out["ok"] = bool(res.get("ok"))
        if res.get("note"):
            out["note"] = res["note"]
    return out


def camera_args(ns):
    """--set / --entity / --focus (+ --distance) as the mod's camera args; none = only read."""
    given = [x for x in (ns.set, ns.entity, ns.focus) if x is not None]
    if len(given) > 1:
        raise ToolError("give one of --set, --entity or --focus")
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
                or getattr(ns, "no_owner", False) or getattr(ns, "no_fill_modules", False):
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
    return args


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


def road_args(ns):
    """road: --from and --to as x,y[,z]; --type, --snap, --dry-run as given (the mod checks them again)."""
    args = {}
    for key, text in (("from", ns.from_), ("to", ns.to)):
        try:
            v = [float(x) for x in text.split(",")]
        except ValueError:
            raise ToolError("--%s must be numbers: x,y[,z]" % key)
        if not 2 <= len(v) <= 3 or any(x != x or abs(x) == float("inf") for x in v):
            raise ToolError("--%s must be x,y or x,y,z (finite numbers; for a negative x write --%s=-100,50)" % (key, key))
        args[key] = v
    if ns.type is not None:
        if not ns.type.strip():
            raise ToolError("--type is empty")
        args["type"] = ns.type.strip()
    if ns.snap is not None:
        if ns.snap != ns.snap or not 0 <= ns.snap <= ROAD_MAX_SNAP:
            raise ToolError("--snap must be 0-%g metres" % ROAD_MAX_SNAP)
        args["snap"] = ns.snap
    if ns.dry_run:
        args["dryRun"] = True
    return args


ROAD_MAX_SNAP = 20  # the mod's core.ROAD_LIMITS.snap

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


def check_build_answer(args, res, log_path=None, log_start=None):
    """A place the mod says is built must name its construction: an engine that says success and builds nothing
    (2026-11-22, a harbour whose update script failed) is no success, whatever an older mod answered. The game
    log's errors from the command on are added (logErrors): the engine's reason is only there."""
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

# the same list as the mod's (MODHUB_PUBLISH_FOLDERS): the first mod uploaded this way, and the author's mods
# already on mod.io (updates only: MODHUB_PUBLISHED_IDS below)
MODHUB_PUBLISH_FOLDERS = ("hummer_force_unload_default_1", "hummer_cursor_altitude_tooltip_1",
                          "hummer_construction_altitude_tooltip_1", "hummer_industry_pollution_display_1")
# the folders already on mod.io, each held to its page (the same table as the mod's MODHUB_PUBLISHED_IDS): a first
# upload of one is refused and an update goes only to that id, also when _metadata/mod.io_fileid.txt went missing
# or was remade (then both this tool and the game would take the folder for a new mod and make a second page).
# After a first upload, add the folder and its new id here and in the mod.
MODHUB_PUBLISHED_IDS = {"hummer_force_unload_default_1": "6543965", "hummer_cursor_altitude_tooltip_1": "6523060",
                        "hummer_construction_altitude_tooltip_1": "6536988",
                        "hummer_industry_pollution_display_1": "6536959"}
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
    return os.path.join(os.path.dirname(folder.rstrip("/")), "staging_area")


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
    pinned = MODHUB_PUBLISHED_IDS.get(name)
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
    if ns.folder not in MODHUB_PUBLISH_FOLDERS:
        raise ToolError("publish takes only these staging folders: %s (not %s)" % (", ".join(MODHUB_PUBLISH_FOLDERS),
                                                                                    ns.folder))
    if ns.public not in ("yes", "no"):
        raise ToolError("give --public yes or --public no: there is no default visibility")
    if not ns.changelog or not ns.changelog.strip():
        raise ToolError("give --changelog TEXT")
    if ns.previous_revision is not None and ns.first_upload:
        raise ToolError("--previous-revision is only for an update (without --first-upload)")
    if ns.version is not None:
        version_revision(ns.version)  # the form; against mod.json's revision in publish_local_checks
    # firstUpload or update: which one also needs the staging files (cmd_modhub_publish adds modioId for an update)
    args = {"folder": ns.folder, "public": ns.public == "yes", "changelog": ns.changelog}
    if ns.first_upload:
        args["firstUpload"] = True
    else:
        args["update"] = True
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
    if pre.get("ok") and pre["additionalMetadata"] != local.get("additionalMetadata"):
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
                          "revision": local.get("revision"), "version": local.get("version"), "at": int(time.time()),
                          "atUtc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
    def history(outcome, res=None, fileid=None):
        res = res or {}
        # revision: what the next update compares with (uploaded_revision takes the records with a mod.io id)
        got = append_history({"v": 1, "at": int(time.time()), "atUtc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                              "owner": OWNER, "folder": args["folder"], "public": args["public"], "outcome": outcome,
                              "mode": "firstUpload" if first else "update", "modioId": args.get("modioId"),
                              "revision": local.get("revision"), "version": local.get("version"),
                              "publishCalled": res.get("publishCalled"), "modId": res.get("modId"), "fileid": fileid,
                              "error": res.get("error")})
        if got:
            res["history"] = got
    try:
        res = send("modhubPublish", dict(args, dryRun=False), timeout=timeout, on_progress=progress, folder=folder)
    except ToolError as e:
        history("no answer", {"error": str(e)})
        raise ToolError("%s; the outcome of the upload is not known, the publish mark stays (%s)" % (e, path))
    res["local"] = local
    if not first:
        res["update"] = update_summary(local, res)
    res["additionalMetadata"] = additional_metadata(res)
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
    """The persons command's args: --vehicle or --line (argparse makes it one of them), --limit when given."""
    args = {"vehicle": ns.vehicle} if ns.vehicle is not None else {"line": ns.line}
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


def stations_args(ns):
    catchment = getattr(ns, "catchment", None)
    if catchment is not None:
        if ns.name or ns.near is not None or ns.radius is not None:
            raise ToolError("--catchment goes alone (one station or station group)")
        return {"catchment": catchment}
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


def screenshots_dir(folder):
    return os.path.join(os.path.dirname(os.path.normpath(folder)), "screenshots")


def cmd_screenshot(ns):
    """The game's own screenshot (photo mode's takeScreenshot): waits until the new file stops growing."""
    folder = exchange_dir()
    shots = screenshots_dir(folder)
    before = set(glob.glob(os.path.join(shots, "*")))
    res = send("screenshot", {"scale": ns.scale}, folder=folder)
    if not res.get("ok"):
        return res
    deadline = time.time() + ns.timeout
    path, last, steady = None, None, 0
    while time.time() < deadline:
        new = [p for p in glob.glob(os.path.join(shots, "*")) if p not in before]
        if new:
            path = max(new, key=lambda p: mtime(p) or 0)
            try:
                size = os.path.getsize(path)
            except OSError:  # renamed or replaced while we looked
                size = None
            # a ~100 MB PNG: done once its size has held still for three looks in a row
            steady = steady + 1 if size and size == last else 0
            last = size
            if steady >= 2:
                break
        time.sleep(0.5)
    else:
        raise ToolError(f"no new file in {shots} after {ns.timeout:g} s")
    out = {"ok": True, "path": path, "bytes": os.path.getsize(path)}
    if ns.preview:
        # a small JPEG that an assistant can read (the PNG is ~100 MB)
        try:
            r = subprocess.run(["magick", path, "-resize", "%dx" % ns.preview_width, ns.preview],
                               capture_output=True, text=True)
            err = None if r.returncode == 0 else r.stderr.strip()
        except OSError as e:  # no ImageMagick: the screenshot itself still worked
            err = str(e)
        out["preview"] = None if err else ns.preview
        if err:
            out["previewError"] = err
    return out


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
                               capture_output=True, text=True)
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
           "note": "the picture is %.0f s old, at the recording's resolution (3840x1620 here)" % age}
    if age > STALE_FRAME_SEC:
        out["stale"] = True
        out["warning"] = ("the recording stopped %.0f min ago: the game is closed or background recording is off"
                          % (age / 60))
    return out


# pointer: the game's own idea of where the mouse is, set from outside. TF3 runs as an XWayland window; a synthetic
# EnterNotify + MotionNotify sent to that window moves the game's hover (the placement preview, tooltips) and its
# drawn cursor, while the real pointer stays where it is. Only these two event types are ever sent: a button or
# key event would act in the game on its own (2026-11-18, aom-master: pointer movement only, no buttons or keys).
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


def make_parser():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--owner", default=os.environ.get("TF3CTL_OWNER"),
                   help="name of the client sending commands (shown to others, never used to refuse)")
    sub = p.add_subparsers(dest="cmd", required=True)
    pl = sub.add_parser("poll", help="how often the mod reads the command file, until the next load")
    pl.add_argument("--idle", type=float)
    pl.add_argument("--active", type=float)
    sub.add_parser("status")
    s = sub.add_parser("speed")
    s.add_argument("speed", type=int)
    s.add_argument("--force", action="store_true", help="above the game's estimate of what it can sustain")
    sub.add_parser("pause")
    r = sub.add_parser("run")
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
    ng.add_argument("--unsafe", action="store_true", help="start it although it crashes the game from inside a save")
    ng.add_argument("--editor", action="store_true", help="the map editor instead of a game (isMapEditor); its mods: "
                    "the official ones (ug_*) and the probe, not the running game's")
    fr = sub.add_parser("frame", help="the game's picture with UI, from Steam's background recording")
    fr.add_argument("--out", required=True, help="image to write (.png or .jpg)")
    fr.add_argument("--crop", help="WxH+X+Y in the recording's pixels, e.g. 1150x170+2690+1450 for the speed row")
    po = sub.add_parser("pointer", help="move the game's mouse pointer (hover, placement preview) without the real "
                        "one; pointer movement only, never a click or a key")
    po.add_argument("pos", metavar="FX,FY", help="fractions of the game window, e.g. 0.5,0.47 (0,0 = top left)")
    po.add_argument("--px", action="store_true", help="the position is in the window's pixels instead")
    po.add_argument("--title", default=TF3_WINDOW_TITLE, help="the game window's title")
    sc = sub.add_parser("screenshot", help="the game's own screenshot (photo mode, likely without the UI)")
    sc.add_argument("--scale", type=int, default=1, help="1 (default) = twice the screen size, as photo mode")
    sc.add_argument("--preview", help="also write a small JPEG here (needs ImageMagick)")
    sc.add_argument("--preview-width", type=int, default=1600)
    sc.add_argument("--timeout", type=float, default=60)
    en = sub.add_parser("entities", help="towns, lines, vehicles, stations or industries with their ids")
    en.add_argument("--kind", required=True, choices=["town", "line", "vehicle", "station", "industry"])
    en.add_argument("--grep")
    en.add_argument("--limit", type=int, default=200)
    wi = sub.add_parser("window", help="open the window of a town, line, vehicle, station or industry")
    wg = wi.add_mutually_exclusive_group(required=True)
    for kind in ("town", "line", "vehicle", "station", "industry"):
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
    bt = sub.add_parser("build-tool", help="open the construction menu's placing tool for one construction")
    bt.add_argument("--res", help="the construction's resName, e.g. depots/road/road_depot/road_depot.con")
    bt.add_argument("--template", type=int, help="the template number (menu tag resName@N)")
    bt.add_argument("--seconds", type=float, default=60, help="the mod clears the menu filter after this (5-600)")
    bt.add_argument("--close", action="store_true", help="clear the menu filter now")
    bt.add_argument("--menu", choices=BUILD_MENUS, help="first open this toolbar menu (its own button's event), which "
                    "picks its first item as the placing tool; the only way seen to open the tool (2026-11-18)")
    bd = sub.add_parser("build", help="put one construction (.con) on the map at a point, as a mod's tool builds "
                                       "(no click); or take away ones the probe built. Test saves only")
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
    rd = sub.add_parser("road", help="build one straight road piece between two points, as a mod's tool builds (no "
                                      "click; a SimpleStreetProposal). Test saves only")
    rd.add_argument("--from", dest="from_", required=True, metavar="X,Y[,Z]",
                    help="one end (metres); no Z: the terrain's height there")
    rd.add_argument("--to", required=True, metavar="X,Y[,Z]", help="the other end")
    rd.add_argument("--type", help="the street template's resName, or a base road's file name (town_new_small, "
                    "country_old_medium; looked for under the base's town, country and highway roads); default the "
                    "base medium town road of the game's year")
    rd.add_argument("--snap", type=float, help="an end within this many metres of a node with road pieces joins that "
                    "node (default 5, 0: never); never a node without a junction set-up (BaseNodeConfig, as a "
                    "script's road ends): the next one, else refused")
    rd.add_argument("--dry-run", action="store_true", help="no build: the template, the ends (snapped or on the "
                    "terrain) and the length, checked here only")
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
    tws = tw.add_subparsers(dest="town_action", required=False, metavar="{develop,size}")
    td = tws.add_parser("develop", help="test saves only: new buildings or street segments at a point "
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
    tz = tws.add_parser("size", help="test saves only: a town's size factors, residential, commercial, industrial "
                        "(api.cmd.makeTownUpdateSizeCmd); not checked in a game yet")
    tz.add_argument("--entity", dest="grow_entity", type=int, required=True, help="the town (entities --kind town)")
    tz.add_argument("--factors", dest="grow_factors", required=True, metavar="R,C,I",
                    help="residential,commercial,industrial, each 0-%g (1 as a new town)" % TOWN_GROW_SIZE_MAX)
    tz.add_argument("--update-all", dest="grow_update_all", action="store_true",
                    help="take every building to its target capacity")
    tz.add_argument("--dry-run", dest="grow_dry_run", action="store_true", help="the town as it is, nothing sent")
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
        st.add_argument("--timeout", type=float, default=900, help="for the load or new game")
        st.add_argument("--launch-timeout", type=float, default=LAUNCH_TIMEOUT_SEC)
        st.add_argument("--lang", metavar="CODE", help="start in this language (de, en, ja, ...): profile.lua is "
                        "changed for the start and put back after quit or before the next launch / restart")
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
            vb.add_argument("--model", required=True, help="model id, or a unique part of its file name")
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
    skl.add_argument("--entity", type=int, required=True, help="an industry, station, town building or vehicle "
                                                               "(industry-stocks, stations, vehicles)")
    sks = ssub.add_parser("set", help="set a stock's amount (api.cmd.debug.makeStockSetCargoAmountCmd): test saves only")
    sks.add_argument("--entity", type=int, required=True, help="as stock list")
    sks.add_argument("--stock", type=int, required=True, help="the stock's id as stock list shows it (0-based); -1: "
                                                              "a vehicle's load (with --cargo)")
    sks.add_argument("--amount", type=int, required=True, help="0-%d, at most the stock's capacity" % STOCK_MAX_AMOUNT)
    sks.add_argument("--cargo", help="a cargo type's name exactly as stock list shows it (its cargo field); a stock "
                                     "list's stock: optional")
    sks.add_argument("--dry-run", action="store_true", help="check and show the before, send nothing")
    st = sub.add_parser("steps", help="run the simulation N steps on (api.cmd.debug.makeGamePerformSimulationStepsCmd) "
                                      "and answer once they have all run; one step is 200 of game time (20 a day). "
                                      "Pause first (speed 0). Test saves only")
    st.add_argument("count", type=int, help="1-%d" % STEPS_MAX)
    st.add_argument("--dry-run", action="store_true", help="check and show the game time, send nothing")
    st.add_argument("--allow-running", action="store_true",
                    help="send while the game is not paused (refused otherwise): the deltas then mix the steps with "
                         "the game's own running, and the wait may end early")
    mo = sub.add_parser("money", help="set or change the company's balance (a journal entry of category OTHER, "
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
    sg = sub.add_parser("stations", help="the company's (and nobody's) station groups: id, stations, platforms, "
                                         "carriers, position; per platform (station:terminal) its tag, position, "
                                         "load flags, cargoTransferSpeeds and carriers")
    sg.add_argument("--name", help="a part of the name, any case")
    sg.add_argument("--near", type=int, help="only those within --radius of this entity (a town, industry, ...)")
    sg.add_argument("--radius", type=float, help="metres around --near (default 1000)")
    sg.add_argument("--catchment", type=int, metavar="ID",
                    help="what this station or station group reaches (read only): town buildings per town "
                         "(residential, commercial, industrial) and industries, for passengers and for cargo")
    iw = sub.add_parser("industry-workers", help="industries (read only): capacity, sims with it as destination, "
                                                  "last visitors of the base's workers script, productivity, nearest town")
    iw.add_argument("--entity", type=int, help="one industry's id (entities --kind industry); none: all")
    ist = sub.add_parser("industry-stocks", help="industries (read only): stocks (cargo, capacity, count), rules, "
                                                 "modifiers, and the construction's file and params (hummer_aom_upg_*)")
    ist.add_argument("--entity", type=int, help="one industry's id (entities --kind industry); none: all")
    ist.add_argument("--grep", help="a part of the name, any case")
    ist.add_argument("--all-params", action="store_true", help="every param of the construction too")
    ps = sub.add_parser("persons", help="sim persons (read only) aboard a vehicle or on a line: happiness, expected "
                                        "arrival and the game time, line and stops; the engine's unhappy counts")
    pw = ps.add_mutually_exclusive_group(required=True)
    pw.add_argument("--vehicle", type=int, help="the company's vehicle (vehicles lists them); gone: missing true")
    pw.add_argument("--line", type=int, help="the company's line: who rides it (those waiting for it too: not checked)")
    ps.add_argument("--limit", type=int, help="persons listed, 1-2000 (default 200; total counts them all)")
    ps.add_argument("--every", type=float, help="repeat every this many seconds (at least 0.5): one JSON line each")
    ps.add_argument("--count", type=int, help="with --every: this many samples (default: until Ctrl-C)")
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
                    help="a free end's node id, a station (group) id or a part of a station's name")
    cn.add_argument("--to", required=True, metavar="END")
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
    mpu.add_argument("--dry-run", action="store_true", help="check and validate, answer the settings; no upload")
    mpu.add_argument("--timeout", type=float, help="seconds for the mod's whole command (default 900, at most 3600); "
                                                   "past it the upload is not aborted and its outcome is unknown")
    mpu.add_argument("--messages", type=int, help="validator messages listed (0-500, default 50)")
    mpc = msub.add_parser("publish-clear", help="remove the publish mark (" + PENDING_NAME + ") after looking at "
                                                "mod.io (not while the game says the upload is Publishing)")
    mpc.add_argument("--yes", action="store_true", help="required: you looked at mod.io")
    v = sub.add_parser("save")
    v.add_argument("name")
    sub.add_parser("state", help="where the game is (menu, loading, ...), from its log; needs no mod")
    sub.add_parser("restore-profile", help="put profile.lua back from the backup launch / restart --lang made (not "
                                           "while the game runs)")
    sub.add_parser("clean", help="remove every probe file; the current load's too when the game is not running")
    lg = sub.add_parser("log", help="lines of the game's stdout.txt")
    lg.add_argument("--grep")
    lg.add_argument("--tail", type=int, default=50)
    kl = sub.add_parser("keep-log", help="copy the game log to crash_dump/logs now (launch and restart do it "
                                         "before every start); lists the kept logs")
    kl.add_argument("--list", action="store_true", help="only list the kept logs")
    return p


def main(argv=None):
    ns = make_parser().parse_args(argv)
    global OWNER
    OWNER = ns.owner

    try:
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
                res.update(profile_note())
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
            if not (ns.dry_run or ns.list or ns.unsafe or menu_probe(exchange_dir())):
                # 2026-11-15: app.startGame from inside a running game hit the base's StartGame assertion
                # `!m_game` and crashed TF3; the mod does not run in the main menu, where it would be allowed
                raise ToolError("newgame crashes the game when started from inside a save (StartGame asserts that "
                                "no game is running): use restart --new. --list and --dry-run still work; --unsafe "
                                "sends it anyway.")
            res = replace_game("newgame", newgame_args(ns), ns.dry_run or ns.list, ns.timeout)
        elif ns.cmd == "screenshot":
            res = cmd_screenshot(ns)
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
                kind = next(k for k in ("town", "line", "vehicle", "station", "industry") if getattr(ns, k))
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
        elif ns.cmd == "road":
            res = send("road", road_args(ns), timeout=BUILD_TIMEOUT_SEC)
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
        elif ns.cmd == "persons":
            if ns.every is not None:
                return persons_every(ns)  # prints its own lines
            res = send("persons", persons_args(ns))
        elif ns.cmd == "lines":
            res = send("lines", lines_args(ns))
        elif ns.cmd == "line":
            res = send("line", line_args(ns), timeout=VEHICLE_TIMEOUT_SEC)  # the mod's own wait is 60 s
        elif ns.cmd == "connect":
            res = cmd_connect(ns)
        elif ns.cmd == "modhub":
            res = cmd_modhub(ns)
    except GameNotReady as e:
        print("error: " + str(e), file=sys.stderr)
        out = {"ok": False, "error": str(e), "gameState": e.state}
        show(dict(out, **profile_note()) if ns.cmd == "status" else out)
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
