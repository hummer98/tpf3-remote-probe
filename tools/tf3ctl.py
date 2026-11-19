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
  tf3ctl.py log --grep remote_probe --tail 40
  tf3ctl.py poll --idle 5 --active 0.5     # until the next load; the mod settings apply again after it
  tf3ctl.py --owner alice run --months 2
  tf3ctl.py quit [--kill]                   # app.quit; --kill: SIGKILL if it does not (an unsaved game is lost)
  tf3ctl.py restart --load "probe" [--param ...]      # quit, launch with the probe in the main menu, load
  tf3ctl.py restart --new --year 1900 --size small --add example_mod
  tf3ctl.py launch [--load ... | --new ...]           # the same, when the game is not running
  tf3ctl.py event example_window.show --param '{"welcome": true}'   # a react event (fired by the speed control)
  tf3ctl.py rename "Chesham" --entity 48064   # a station (its group), line, vehicle or depot, as the base's windows do
  tf3ctl.py tool music [--close]            # a base window that opens as a tool (music, calendar)
  tf3ctl.py depots [--grep bus]             # depot entities to buy at
  tf3ctl.py vehicles [--line 21]            # the company's vehicles: models, purchaseTime, value
  tf3ctl.py buy --model bus_1900 --depot 301 [--line 21] [--count 2] [--via gui|cmd]
  tf3ctl.py duplicate --vehicle 601 | replace --vehicle 601 --model bus_1920 | sell --vehicle 601
            # each answers with via, balance before/after, spent, the model's store price, parts' purchaseTime
  tf3ctl.py money --set 10000000 | --add -5000   # the balance, as the sandbox money editor (a journal entry)
  tf3ctl.py stations [--name cent] [--near 11 --radius 800]   # station groups: id, platforms, carriers, distance
  tf3ctl.py lines [--name probe]            # lines: stops (platforms), vehicles, cargo loaded and carried
  tf3ctl.py line create --stops Central,Harbour [--name "[probe] A"] [--cargo grain] [--via gui|cmd]
  tf3ctl.py line update 21 [--stops 41,42,43] [--name N] [--cargo C] | line delete 21 [--sell-vehicles]
  tf3ctl.py connect --from 5123 --to Harbour [--build]   # a track between two free ends (needs Track Connector)
  tf3ctl.py pointer 0.5,0.47 [--px]          # the game's pointer only (hover, preview): no click, no key
  tf3ctl.py connect --from 801 --to 802 --road [--template ::/infrastructure/street/...street_template]
            # without --build: the route, its length, bridges and tunnels, slope, the dry run's cost and verdict

--owner (or TF3CTL_OWNER) names the client sending commands (a person or a script). It is only shown (status:
run.owner, lastAction) and used for a warning when another owner changed the game in the last 10 minutes; nothing
is refused, since clients sharing the game agree among themselves who uses it.

Several tool processes may run at once (e.g. a long run plus status calls): a lock makes them write the single
command file one after another, each waiting until the mod has picked its command up.

Exit codes: 0 ok, 1 the game answered with an error, 2 no answer / tool error, 3 the game cannot answer where it
is (menu, loading, main menu, closed: gameState in the output says which).

Environment: TF3_REMOTE_DIR = the exchange folder (default: the newest hello file under Steam's userdata),
TF3_LOG = the game log, TF3_STEAM = the command that starts Steam, TF3CTL_OWNER = the default --owner,
LUAJIT = the luajit binary.
"""
import argparse
import contextlib
import fcntl
import glob
import json
import os
import re
import signal
import shutil
import subprocess
import sys
import time

PREFIX = "remote_probe__"
APP_ID = "3493540"
DIRS = ("recordings", "keyframes", "mod_presets")  # the mod's order (mod_presets files show up as presets)
SELF_MOD = "hummer_remote_probe"
STALE_SEC = 3600  # answers nobody read (a killed tool) are removed after this
PICKUP_TIMEOUT_SEC = 30  # the mod polls every 2 s when idle (at most 20 s); longer means it is not running
RECENT_SEC = 600  # another owner's game-changing command this recent gets a warning
CHANGES_GAME = {"speed", "run", "load", "save", "newgame", "window", "quit", "event", "tool", "buy", "duplicate",
                "replace", "sell", "money", "line", "connect", "camera", "buildTool", "scriptEvent", "rename"}  # window: what the player sees  # poll: only the mod's file reads

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


def wait_new_hello(folder, cid, after_stamp, timeout):
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
        print("loading ..." if cmd == "load" else "starting a new game ...", file=sys.stderr)
        after = wait_new_hello(folder, ack["id"], before, timeout)
        return after if after.get("ok") is False else {"ok": True, "plan": ack, "hello": after}
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


def quit_game(timeout=QUIT_TIMEOUT_SEC, kill=False, force=False):
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


def launch_game(timeout=LAUNCH_TIMEOUT_SEC):
    """Starts the game through Steam with startup.lua, and waits until the probe answers in the main menu."""
    if game_pids():
        raise ToolError("the game is already running: use restart (or quit first)")
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
    if ns.load:
        return "load", load_args(argparse.Namespace(save=ns.load, set_mods=ns.set_mods, add=ns.add,
                                                    remove=ns.remove, param=ns.param, dry_run=False,
                                                    wait_for_start=ns.wait_for_start))
    if ns.new:
        return "newgame", newgame_args(argparse.Namespace(
            climate=ns.climate, generator=ns.generator, size=ns.size, year=ns.year, seed=ns.seed,
            no_towns=ns.no_towns, no_industries=ns.no_industries, list=False, unsafe=False, set_mods=ns.set_mods,
            add=ns.add, remove=ns.remove, param=ns.param, dry_run=False, tutorial=getattr(ns, "tutorial", False)))
    return None


def cmd_start(ns, restart):
    plan = start_args(ns)  # refused before anything is quit
    out = {"ok": True}
    if restart:
        out["quit"] = quit_game(ns.quit_timeout, kill=not ns.no_kill, force=ns.force)
        if out["quit"]["how"] != "not running":
            time.sleep(RELAUNCH_PAUSE_SEC)
    out["launch"] = launch_game(ns.launch_timeout)
    if plan:
        res = replace_game(plan[0], plan[1], False, ns.timeout)
        out[plan[0]] = res
        out["ok"] = bool(res.get("ok"))
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
    if getattr(ns, "sell_vehicles", False):
        args["sellVehicles"] = True
    if ns.action == "update" and not any(k in args for k in ("stops", "name", "cargo")):
        raise ToolError("line update: give --stops, --name or --cargo")
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


def stations_args(ns):
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
    l.add_argument("--wait-for-start", action="store_true", help="keep the base game's 'Start Game' button")
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
        st.add_argument("--wait-for-start", action="store_true")
        st.add_argument("--climate")
        st.add_argument("--generator")
        st.add_argument("--size")
        st.add_argument("--year", type=int)
        st.add_argument("--seed")
        st.add_argument("--no-towns", action="store_true")
        st.add_argument("--no-industries", action="store_true")
        st.add_argument("--tutorial", action="store_true", help="with --new: start with the base tutorial (off by default)")
        st.add_argument("--timeout", type=float, default=900, help="for the load or new game")
        st.add_argument("--launch-timeout", type=float, default=LAUNCH_TIMEOUT_SEC)
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
    sg = sub.add_parser("stations", help="the company's (and nobody's) station groups: id, stations, platforms, "
                                         "carriers, position")
    sg.add_argument("--name", help="a part of the name, any case")
    sg.add_argument("--near", type=int, help="only those within --radius of this entity (a town, industry, ...)")
    sg.add_argument("--radius", type=float, help="metres around --near (default 1000)")
    ls = sub.add_parser("lines", help="the company's lines: stops and platforms, vehicles, cargo")
    ls.add_argument("--name", help="a part of the name, any case")
    ln = sub.add_parser("line", help="create, change or remove a line (the line manager's way by default)")
    lsub = ln.add_subparsers(dest="action", required=True)
    for action, helptext in (("create", "a new line through the stops, platforms assigned by the engine"),
                             ("update", "change a line's stops, name or cargo"),
                             ("delete", "remove a line (its vehicles too with --sell-vehicles)")):
        la = lsub.add_parser(action, help=helptext)
        if action != "create":
            la.add_argument("line", type=int, help="line entity (the lines command)")
        if action != "delete":
            la.add_argument("--stops", required=(action == "create"),
                            help="station groups in order, comma-separated: ids or parts of names (stations command)")
            la.add_argument("--name", help="the line's name (create: default the base's next 'Line N')")
            la.add_argument("--cargo", help="load only this cargo (id or name), at the stops that make it, as the cargo filter")
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
    v = sub.add_parser("save")
    v.add_argument("name")
    sub.add_parser("state", help="where the game is (menu, loading, ...), from its log; needs no mod")
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
            show(game_state())
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
        elif ns.cmd in ("launch", "restart"):
            res = cmd_start(ns, ns.cmd == "restart")
        elif ns.cmd == "event":
            res = send("event", event_args(ns))
        elif ns.cmd == "script-event":
            res = send("scriptEvent", script_event_args(ns))
        elif ns.cmd == "rename":
            res = send("rename", rename_args(ns))
        elif ns.cmd == "tool":
            ev = tool_event(ns)
            if ev:
                res = send("event", ev)
                if isinstance(res, dict):
                    res["note"] = ("sent the event " + ev["name"] + " instead of a tool push: this window's base "
                                   "button passes more than gameCtx, and a plain push makes the GUI reload")
            else:
                res = send("tool", tool_args(ns))
        elif ns.cmd in ("buy", "duplicate", "replace", "sell"):
            res = send(ns.cmd, vehicle_args(ns), timeout=VEHICLE_TIMEOUT_SEC)
        elif ns.cmd == "money":
            res = send("money", money_args(ns), timeout=VEHICLE_TIMEOUT_SEC)  # the mod's own wait is 60 s
        elif ns.cmd == "depots":
            res = send("depots", {"grep": ns.grep} if ns.grep else {})
        elif ns.cmd == "vehicles":
            args = {"limit": ns.limit}
            if ns.line is not None:
                args["line"] = ns.line
            res = send("vehicles", args)
        elif ns.cmd == "stations":
            res = send("stations", stations_args(ns))
        elif ns.cmd == "lines":
            res = send("lines", {"name": ns.name} if ns.name else {})
        elif ns.cmd == "line":
            res = send("line", line_args(ns), timeout=VEHICLE_TIMEOUT_SEC)  # the mod's own wait is 60 s
        elif ns.cmd == "connect":
            res = cmd_connect(ns)
    except GameNotReady as e:
        print("error: " + str(e), file=sys.stderr)
        show({"ok": False, "error": str(e), "gameState": e.state})
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
