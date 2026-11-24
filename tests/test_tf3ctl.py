"""Tests for tools/tf3ctl.py.  python3 -m unittest discover -s tests   (needs luajit on PATH)

The end-to-end cases run the real content/remote.script.lua in tests/fake_game.lua (real time, own process) and talk
to it through real files, exactly as with the game.
"""
import atexit
import contextlib
import glob
import importlib.util
import io
import json
import shlex
import math
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
import unittest.mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Every tempfile.mkdtemp() here (many tests make one and leave it) lands in one folder for this run, which goes at the
# end, even when tests fail or raise: tearDownModule, and atexit for a run stopped early. The folder is under
# $REMOTE_PROBE_TEST_TMP, else $TMPDIR unless that is in /tmp, else tests/.tmp (gitignored) -- /tmp only when
# REMOTE_PROBE_TEST_TMP asks for it: a small tmpfs that once ran out of inodes with test leftovers. Set before anything
# else asks tempfile for a folder; the luajit processes the tests start inherit it through $TMPDIR. A killed run leaves
# its folder: the next run removes such folders (py-* and tests/run.lua's run-*) once they are a day old.
_TMPDIR = os.environ.get("TMPDIR")
if _TMPDIR and (_TMPDIR.rstrip("/") == "/tmp" or _TMPDIR.startswith("/tmp/")):
    _TMPDIR = None
_TEST_BASE = os.path.join(os.environ.get("REMOTE_PROBE_TEST_TMP") or _TMPDIR
                          or os.path.join(ROOT, "tests", ".tmp"), "remote_probe_tests")
for _old in glob.glob(os.path.join(_TEST_BASE, "py-*")) + glob.glob(os.path.join(_TEST_BASE, "run-*")):
    with contextlib.suppress(OSError):
        if os.path.isdir(_old) and time.time() - os.path.getmtime(_old) > 86400:
            shutil.rmtree(_old, ignore_errors=True)
for _attempt in range(10):
    # made again each time: another run that just finished may have removed the base
    os.makedirs(_TEST_BASE, exist_ok=True)
    try:
        TEST_RUN_DIR = tempfile.mkdtemp(prefix="py-", dir=_TEST_BASE)
        break
    except FileNotFoundError:
        if _attempt == 9:
            raise
tempfile.tempdir = TEST_RUN_DIR
os.environ["TMPDIR"] = TEST_RUN_DIR


def _remove_test_run_dir():
    shutil.rmtree(TEST_RUN_DIR, ignore_errors=True)
    with contextlib.suppress(OSError):
        os.rmdir(_TEST_BASE)  # only when no other run is using it


atexit.register(_remove_test_run_dir)

# The configuration file tf3ctl reads (TF3CTL_CONFIG): the tests were written against a setup with every switch on,
# several test-save prefixes, the digit rule and four modhub folders, and run with that configuration, so they keep
# checking that such a setup works as before. ConfigDefaultsTest checks the defaults without a file. use_config
# writes another one for a test (main reads the file again at every call); restore with use_config(CONFIGURED).
CONFIGURED = {
    "ownerCheck": True, "coop": True, "pointer": True,
    "testSavePrefixes": ["probe-", "aom-ops-", "aom-shot-", "aom-bgm-check-"], "testSaveDigitFirst": True,
    "modhub": {
        "validateFolders": ["hummer_construction_altitude_tooltip_1", "hummer_cursor_altitude_tooltip_1",
                            "hummer_industry_pollution_display_1", "hummer_force_unload_default_1"],
        "publishFolders": ["hummer_force_unload_default_1", "hummer_cursor_altitude_tooltip_1",
                           "hummer_construction_altitude_tooltip_1", "hummer_industry_pollution_display_1"],
        "publishedIds": {"hummer_force_unload_default_1": "6543965", "hummer_cursor_altitude_tooltip_1": "6523060",
                         "hummer_construction_altitude_tooltip_1": "6536988",
                         "hummer_industry_pollution_display_1": "6536959"}},
}
CONFIG_DIR = tempfile.mkdtemp()
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")
with open(CONFIG_FILE, "w", encoding="utf-8") as _f:
    json.dump(CONFIGURED, _f)
os.environ["TF3CTL_CONFIG"] = CONFIG_FILE
spec = importlib.util.spec_from_file_location("tf3ctl", os.path.join(ROOT, "tools", "tf3ctl.py"))
tf3ctl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tf3ctl)

# launch / restart / quit put back a backup of the game's profile.lua: never look at the real one here
NO_PROFILE_DIR = tempfile.mkdtemp()
os.environ["TF3_PROFILE"] = os.path.join(NO_PROFILE_DIR, "no_profile.lua")
os.environ.pop("TF3CTL_OTHER_BACKUPS", None)
# launch / restart / quit write and remove the launch record: never the real $XDG_RUNTIME_DIR here
RUNTIME_DIR = tempfile.mkdtemp()
os.environ["XDG_RUNTIME_DIR"] = RUNTIME_DIR
# modhub publish writes its mark under $XDG_STATE_HOME/tf3ctl: never the real one here
STATE_DIR = tempfile.mkdtemp()
os.environ["XDG_STATE_HOME"] = STATE_DIR
os.environ.pop("TF3CTL_OWNER", None)
# the owner check looks at the real game's processes: a game running on this machine (another client's) must not
# change what the other tests see, so it is only checked where a test stands in its own game_pids
_REAL_GAME_PIDS = tf3ctl.game_pids
_REAL_CHECK_GAME_OWNER = tf3ctl.check_game_owner


def _check_game_owner_unless_real(cmd, args=None):
    if tf3ctl.game_pids is _REAL_GAME_PIDS:
        return None
    return _REAL_CHECK_GAME_OWNER(cmd, args)


tf3ctl.check_game_owner = _check_game_owner_unless_real


def use_config(cfg):
    """Writes cfg as the configuration file and reads it into tf3ctl (main reads it again too)."""
    with open(CONFIG_FILE, "w", encoding="utf-8") as f:
        json.dump(cfg, f)
    tf3ctl.CONFIG, tf3ctl.CONFIG_INFO = tf3ctl.load_config()


def configured(**modhub):
    """CONFIGURED with some modhub lists replaced."""
    cfg = json.loads(json.dumps(CONFIGURED))
    cfg["modhub"].update(modhub)
    return cfg



def tearDownModule():
    shutil.rmtree(NO_PROFILE_DIR, ignore_errors=True)
    shutil.rmtree(RUNTIME_DIR, ignore_errors=True)
    shutil.rmtree(STATE_DIR, ignore_errors=True)
    _remove_test_run_dir()


# what the mod makes of a command file: remote_core.readCommand over loadUserdata's table, as JSON
PARSE_CMD = r"""
package.path = arg[2] .. "/content/?.lua;" .. package.path
local core = require "remote_core"
local f = assert(loadfile(arg[1]))
local env = {}
setfenv(f, env)
f()
io.write(core.json(core.readCommand(env.data(), 0)))
"""


def mod_reads(text):
    with tempfile.NamedTemporaryFile("w", suffix=".lua", delete=False, encoding="utf-8") as f:
        f.write(text)
    try:
        r = subprocess.run(["luajit", "-", f.name, ROOT], input=PARSE_CMD, capture_output=True, text=True, check=True)
        return json.loads(r.stdout)
    finally:
        os.remove(f.name)


class CommandFileTest(unittest.TestCase):
    def test_round_trip_through_the_mods_reader(self):
        args = {"save": 'odd "name" \\ with\nnewline 日本', "params": {"example_mod": {"treePollution": 3},
                                                                     "": {"map.size": 4}},
                "mods": {"add": ["x", "y"]}, "dryRun": True, "speed": 1.5}
        got = mod_reads(tf3ctl.command_text(42, "load", args))
        self.assertEqual(got["id"], 42)
        self.assertEqual(got["cmd"], "load")
        self.assertEqual(got["args"]["save"], args["save"])
        self.assertEqual(got["args"]["params"], args["params"])
        self.assertEqual(got["args"]["mods"], {"add": ["x", "y"]})
        self.assertIs(got["args"]["dryRun"], True)
        self.assertEqual(got["args"]["speed"], 1.5)

    def test_control_characters_are_escaped(self):
        self.assertEqual(tf3ctl.lua_str("a\x01\x7fb"), '"a\\001\\127b"')

    def test_non_finite_numbers_are_refused(self):
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.to_lua(float("nan"))

    def test_param_syntax(self):
        self.assertEqual(tf3ctl.parse_param("m:key.sub=3"), ("m", "key.sub", 3))
        self.assertEqual(tf3ctl.parse_param(":map.size=4"), ("", "map.size", 4))
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.parse_param("m.key=3")
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.parse_param("m:key=x")

    def test_load_refuses_to_remove_the_probe(self):
        p = tf3ctl.main.__globals__["argparse"].Namespace(save="s", set_mods=None, add=[], remove=["hummer_remote_probe"],
                                                         param=[], dry_run=False)
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.load_args(p)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


class FileHandlingTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()

    def test_half_written_answer_is_retried_not_fatal(self):
        path = tf3ctl.answer_path(self.dir, 5)
        write(path, 'function data()\nreturn { id = 5, json = "{\\"ok\\":tr')
        self.assertIsNone(tf3ctl.try_read(path))

        def finish():
            time.sleep(0.3)
            write(path, 'function data()\nreturn { id = 5, json = "{\\"ok\\":true}" }\nend\n')
        threading.Thread(target=finish).start()
        self.assertEqual(tf3ctl.wait_answer(self.dir, 5, timeout=5), {"ok": True})

    def test_error_after_a_load_ack_ends_the_wait(self):
        write(os.path.join(self.dir, "remote_probe__hello_1_1.lua"), 'function data()\nreturn { json = "{}" }\nend\n')
        write(tf3ctl.answer_path(self.dir, 9, "error"),
              'function data()\nreturn { json = "{\\"ok\\":false,\\"error\\":\\"loadGame: x\\"}" }\nend\n')
        t0 = time.time()
        got = tf3ctl.wait_new_hello(self.dir, 9, "1_1", timeout=30)
        self.assertIs(got["ok"], False)
        self.assertLess(time.time() - t0, 2)

    def test_cleanup_keeps_answers_another_tool_may_wait_for(self):
        write(os.path.join(self.dir, "remote_probe__hello_2_2.lua"), "x")
        write(os.path.join(self.dir, "remote_probe__hello_1_1.lua"), "x")
        os.utime(os.path.join(self.dir, "remote_probe__hello_1_1.lua"), (1, 1))
        write(os.path.join(self.dir, "remote_probe__cmd_1_1.lua"), "x")
        fresh = tf3ctl.answer_path(self.dir, 7, "p1")
        stale = tf3ctl.answer_path(self.dir, 6)
        write(fresh, "x")
        write(stale, "x")
        os.utime(stale, (1, 1))
        tf3ctl.cleanup(self.dir)
        names = sorted(os.listdir(self.dir))
        self.assertEqual(names, ["remote_probe__hello_2_2.lua", os.path.basename(fresh)])

    def test_a_second_tool_waits_until_the_mod_has_the_first_command(self):
        # no game here: this test plays the mod by hand, so the order is certain
        write(os.path.join(self.dir, "remote_probe__hello_1_1.lua"), "x")
        cmd_file = os.path.join(self.dir, "remote_probe__cmd_1_1.lua")
        out = {}

        def tool(name, cmd):
            try:
                out[name] = tf3ctl.send(cmd, folder=self.dir, timeout=10)
            except tf3ctl.ToolError as e:
                out[name] = e
        a = threading.Thread(target=tool, args=("a", "run"))
        a.start()
        while not os.path.exists(cmd_file):
            time.sleep(0.01)
        first = read(cmd_file)
        b = threading.Thread(target=tool, args=("b", "status"))
        b.start()
        time.sleep(0.5)
        self.assertEqual(read(cmd_file), first, "the second tool overwrote a command the mod had not read")
        cid_a = int(first.split("id = ")[1].split(",")[0])
        write(tf3ctl.answer_path(self.dir, cid_a, "got"), "x")  # the mod picks it up
        deadline = time.time() + 5
        while read(cmd_file) == first and time.time() < deadline:
            time.sleep(0.01)
        second = read(cmd_file)
        self.assertIn('"status"', second, "the second command goes out after the receipt")
        cid_b = int(second.split("id = ")[1].split(",")[0])
        ok = 'function data()\nreturn { json = "{\\"ok\\":true}" }\nend\n'
        write(tf3ctl.answer_path(self.dir, cid_b, "got"), "x")
        write(tf3ctl.answer_path(self.dir, cid_b), ok)
        write(tf3ctl.answer_path(self.dir, cid_a), ok)
        a.join(10)
        b.join(10)
        self.assertEqual(out, {"a": {"ok": True}, "b": {"ok": True}})
        self.assertEqual(tf3ctl.answer_files(self.dir, cid_a), [], "each tool removes its own answers")

    def test_a_command_nobody_picked_up_is_withdrawn(self):
        write(os.path.join(self.dir, "remote_probe__hello_1_1.lua"), "x")
        old = tf3ctl.PICKUP_TIMEOUT_SEC
        tf3ctl.PICKUP_TIMEOUT_SEC = 0.3
        try:
            with self.assertRaises(tf3ctl.ToolError):
                tf3ctl.send("load", {"save": "s"}, folder=self.dir)
        finally:
            tf3ctl.PICKUP_TIMEOUT_SEC = old
        text = read(os.path.join(self.dir, "remote_probe__cmd_1_1.lua"))
        self.assertIn("id = 0,", text, "a late mod must not run the load the tool reported as failed")

    def test_progress_keeps_coming_when_old_progress_files_are_gone(self):
        prog = lambda k, day: (tf3ctl.answer_path(self.dir, 3, "p%d" % k),
                               'function data()\nreturn { json = "{\\"day\\":%d}" }\nend\n' % day)
        shown = []
        for k, day in ((1, 1), (2, 2)):
            write(*prog(k, day))

        def later():
            time.sleep(0.4)
            os.remove(prog(1, 1)[0])  # cleanup of a run older than an hour
            os.remove(prog(2, 2)[0])
            write(*prog(3, 3))
            time.sleep(0.4)
            write(tf3ctl.answer_path(self.dir, 3), 'function data()\nreturn { json = "{\\"ok\\":true}" }\nend\n')
        threading.Thread(target=later).start()
        tf3ctl.wait_answer(self.dir, 3, timeout=5, on_progress=lambda a: shown.append(a["day"]))
        self.assertEqual(shown, [2, 3])

    def test_warns_about_another_recent_owner_but_never_refuses(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertIsNone(tf3ctl.warn_other_owner(self.dir, "a", "load"), "nothing recorded yet")
            tf3ctl.note_activity(self.dir, "alice", "run")
            self.assertIsNone(tf3ctl.warn_other_owner(self.dir, "alice", "load"), "same owner")
            msg = tf3ctl.warn_other_owner(self.dir, "bob", "load")
        self.assertIn("alice sent 'run' 0 min ago", msg)
        self.assertIn("not refused", err.getvalue())
        rec = tf3ctl.read_activity(self.dir)
        rec["time"] -= tf3ctl.RECENT_SEC + 1
        with open(tf3ctl.activity_path(self.dir), "w") as f:
            json.dump(rec, f)
        self.assertIsNone(tf3ctl.warn_other_owner(self.dir, "bob", "load"), "older than 10 min")

    def test_activity_is_advisory_and_only_for_commands_the_mod_took(self):
        write(os.path.join(self.dir, "remote_probe__hello_1_1.lua"), "x")
        old, tf3ctl.PICKUP_TIMEOUT_SEC, tf3ctl.OWNER = tf3ctl.PICKUP_TIMEOUT_SEC, 0.2, "me"
        try:
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(tf3ctl.ToolError):
                tf3ctl.send("speed", {"speed": 1}, folder=self.dir)
            self.assertIsNone(tf3ctl.read_activity(self.dir), "nobody took the command: not recorded")
            os.mkdir(tf3ctl.activity_path(self.dir))  # makes the record unwritable
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                tf3ctl.note_activity(self.dir, "me", "run")  # must not raise
            self.assertIn("could not record", err.getvalue())
            self.assertEqual([n for n in os.listdir(self.dir) if n.endswith(".tmp")], [], "no tmp left behind")
        finally:
            tf3ctl.PICKUP_TIMEOUT_SEC, tf3ctl.OWNER = old, None

    def test_choose_speed_caps_at_the_games_estimate_unless_forced(self):
        self.assertEqual(tf3ctl.choose_speed(8, 5, False)[0], 5)
        self.assertIn("lowered to 5", tf3ctl.choose_speed(8, 5, False)[1])
        self.assertEqual(tf3ctl.choose_speed(8, 5, True), (8, None))
        self.assertEqual(tf3ctl.choose_speed(4, 6, False), (4, None))
        self.assertEqual(tf3ctl.choose_speed(16, 0, False)[0], 4, "no estimate yet: the buttons' 4x")
        self.assertEqual(tf3ctl.choose_speed(0, 5, False), (0, None))

    def test_capped_speed_lowers_for_an_old_mod_and_defers_to_version_2(self):
        old = tf3ctl.send
        try:
            tf3ctl.send = lambda *a, **k: {"version": 1, "state": {"estimatedMaxSpeed": 5}}
            self.assertEqual(tf3ctl.capped_speed(8, False)[0], 5, "version 1: lowered here")
            tf3ctl.send = lambda *a, **k: {"version": 2, "state": {"estimatedMaxSpeed": 5}}
            self.assertEqual(tf3ctl.capped_speed(8, False), (8, None, {}), "version 2 caps by itself")
            self.assertEqual(tf3ctl.capped_speed(8, True), (8, None, {"force": True}))
        finally:
            tf3ctl.send = old

    def test_clean_removes_leftovers_in_every_exchange_folder(self):
        root = tempfile.mkdtemp()
        rec, pre = os.path.join(root, "recordings"), os.path.join(root, "mod_presets")
        os.makedirs(rec)
        os.makedirs(pre)
        write(os.path.join(rec, "remote_probe__hello_2_2.lua"), "x")
        write(os.path.join(rec, "remote_probe__cmd_2_2.lua"), "x")
        write(os.path.join(pre, "remote_probe__hello_1_1.lua"), "x")  # left by an older version, long ago
        os.utime(os.path.join(pre, "remote_probe__hello_1_1.lua"), (1, 1))
        write(os.path.join(pre, "standard_mod.preset.lua"), "x")
        self.assertEqual(tf3ctl.clean_all(rec, include_current=False), 1)
        self.assertEqual(sorted(os.listdir(pre)), ["standard_mod.preset.lua"], "the player's presets untouched")
        self.assertEqual(len(os.listdir(rec)), 2, "the running game's files kept")
        self.assertEqual(tf3ctl.clean_all(rec, include_current=True), 2)
        self.assertEqual(os.listdir(rec), [])

    def test_cleanup_spares_another_running_games_folder(self):
        root = tempfile.mkdtemp()
        rec, pre = os.path.join(root, "recordings"), os.path.join(root, "mod_presets")
        os.makedirs(rec)
        os.makedirs(pre)
        write(os.path.join(rec, "remote_probe__hello_2_2.lua"), "x")
        write(os.path.join(pre, "remote_probe__hello_1_1.lua"), "x")  # a second game, live
        write(os.path.join(pre, "remote_probe__cmd_1_1.lua"), "x")
        tf3ctl.cleanup(rec)
        self.assertEqual(len(os.listdir(pre)), 2, "a folder with a fresh hello is in use")
        for n in os.listdir(pre):
            os.utime(os.path.join(pre, n), (1, 1))  # that game has been gone for a long time
        tf3ctl.cleanup(rec)
        self.assertEqual(os.listdir(pre), [], "leftovers of an old version are swept")
        self.assertEqual(tf3ctl.other_dirs(rec + "//"), [os.path.join(root, "keyframes"), pre],
                         "its own folder is never 'other', however it is written")

    def test_frame_uses_the_newest_finished_recording_chunk(self):
        d = tempfile.mkdtemp()
        for i, name in enumerate(["chunk-stream0-00001.m4s", "chunk-stream0-00002.m4s", "chunk-stream0-00003.m4s"]):
            write(os.path.join(d, name), "x")
            os.utime(os.path.join(d, name), (100 + i, 100 + i))
        write(os.path.join(d, "chunk-stream0-00004.m4s.tmp"), "x")  # being written: not a .m4s yet
        self.assertTrue(tf3ctl.finished_chunk(d).endswith("00003.m4s"))
        for name in os.listdir(d):
            os.utime(os.path.join(d, name), (200, 200))  # same second: the chunk number decides
        self.assertTrue(tf3ctl.finished_chunk(d).endswith("00003.m4s"))
        self.assertIsNone(tf3ctl.finished_chunk(tempfile.mkdtemp()))

    def test_frame_picks_the_recording_that_wrote_last_not_the_newest_folder_mtime(self):
        root = tempfile.mkdtemp()
        old, live, empty = (os.path.join(root, "bg_3493540_20261116_" + t) for t in ("151139", "175116", "180000"))
        for d in (old, live, empty):
            os.makedirs(d)
        write(os.path.join(old, "chunk-stream0-01107.m4s"), "x")
        os.utime(os.path.join(old, "chunk-stream0-01107.m4s"), (100, 100))
        write(os.path.join(live, "chunk-stream0-00269.m4s"), "x")
        os.utime(os.path.join(live, "chunk-stream0-00269.m4s"), (200, 200))
        os.utime(live, (150, 150))
        os.utime(old, (300, 300))  # Steam trimmed old chunks out of the stopped one just now
        os.utime(empty, (400, 400))
        self.assertEqual(tf3ctl.newest_recordings([old, empty, live]), [live, old, empty])
        write(os.path.join(old, "chunk-stream0-01108.m4s.tmp"), "x")  # it records again: a chunk in progress counts
        os.utime(os.path.join(old, "chunk-stream0-01108.m4s.tmp"), (250, 250))
        self.assertEqual(tf3ctl.newest_recordings([live, old])[0], old)
        os.utime(os.path.join(old, "chunk-stream0-01108.m4s.tmp"), (200, 200))  # same second: the later start wins
        self.assertEqual(tf3ctl.newest_recordings([old, live])[0], live)
        self.assertEqual(tf3ctl.newest_recordings([]), [])

    def test_frame_refuses_a_malformed_crop(self):
        ns = tf3ctl.argparse.Namespace(crop="1150X170+0+0", out="/tmp/x.png")
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.cmd_frame(ns)

    def test_a_crash_during_a_load_ends_the_wait(self):
        write(os.path.join(self.dir, "remote_probe__hello_1_1.lua"), "x")
        old = tf3ctl.game_state
        tf3ctl.game_state = lambda folder=None: {"state": "crashed", "text": "crashed"}
        try:
            t0 = time.time()
            with self.assertRaises(tf3ctl.GameNotReady) as cm:
                tf3ctl.wait_new_hello(self.dir, 9, "1_1", timeout=60)
            self.assertLess(time.time() - t0, 12, "two readings 5 s apart")
            self.assertIn("crashed", str(cm.exception))
        finally:
            tf3ctl.game_state = old

    def test_log_filters_the_games_stdout(self):
        log = os.path.join(self.dir, "stdout.txt")
        write(log, "a\n[remote_probe] one\nb\n[remote_probe] two\n")
        os.environ["TF3_LOG"] = log
        try:
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                code = tf3ctl.main(["log", "--grep", "[remote_probe]", "--tail", "1"])
        finally:
            os.environ.pop("TF3_LOG")
        self.assertEqual(code, 0)
        self.assertEqual(out.getvalue(), "[remote_probe] two\n")


def log_line(t, text, day="2026-11-15"):
    return "[%s %sZ - MESSAGE  - Main Thread      - Main           ]  %s" % (day, t, text)


class WaitForStartTest(unittest.TestCase):
    """--wait-for-start holds the loading screen at the base Start Game button, where the mod reads no commands:
    the answer and a timed-out wait have to say so (2026-11-20: a load stalled there and only quit --kill got out)."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.dir, True)
        self.sent = []

        def send(cmd, args, timeout=None, final_tag=None, folder=None):
            self.sent.append((cmd, dict(args), final_tag))
            return {"ok": True, "id": 7, "loading": True}
        patches = [unittest.mock.patch.object(tf3ctl, "exchange_dir", lambda: self.dir),
                   unittest.mock.patch.object(tf3ctl, "current_stamp", lambda folder: "1_1"),
                   unittest.mock.patch.object(tf3ctl, "send", send)]
        for pt in patches:
            pt.start()
            self.addCleanup(pt.stop)

    def replace(self, args, hello=None, timeout=30):
        err = io.StringIO()
        waited = {}

        def wait(folder, cid, after, t, why_slow=None):
            waited["why_slow"] = why_slow
            if hello is None:
                raise tf3ctl.ToolError("the game did not come back from the load in 0 s: " + str(why_slow))
            return hello
        with unittest.mock.patch.object(tf3ctl, "wait_new_hello", wait), contextlib.redirect_stderr(err):
            res = tf3ctl.replace_game("load", args, False, timeout)
        return res, err.getvalue(), waited

    def test_the_answer_carries_a_note(self):
        res, err, waited = self.replace({"save": "s", "waitForStart": True}, hello={"stamp": "2_2"})
        self.assertIs(res["ok"], True)
        self.assertEqual(res["note"], tf3ctl.WAIT_FOR_START_DONE, "the answer comes after the click: past tense")
        self.assertIn("Start Game", res["note"])
        self.assertIn("no commands", res["note"])
        self.assertIn("note: " + tf3ctl.WAIT_FOR_START_NOTE, err, "shown while it waits, not only at the end")
        self.assertIn("Start Game", waited["why_slow"])
        self.assertEqual(self.sent[0][1]["waitForStart"], True)

    def test_no_note_without_it(self):
        res, err, waited = self.replace({"save": "s"}, hello={"stamp": "2_2"})
        self.assertNotIn("note", res)
        self.assertNotIn("note:", err)
        self.assertIsNone(waited["why_slow"])

    def test_an_error_answer_stays_as_it_was(self):
        # a failed loadGame never reached the button: no note that says it waited there
        res, err, _ = self.replace({"save": "s", "waitForStart": True}, hello={"ok": False, "error": "loadGame: x"})
        self.assertEqual(res, {"ok": False, "error": "loadGame: x"})
        self.assertIn("note: " + tf3ctl.WAIT_FOR_START_NOTE, err, "the warning while waiting is still shown")

    def test_dry_run_sends_no_note(self):
        res = tf3ctl.replace_game("load", {"save": "s", "waitForStart": True, "dryRun": True}, True, 30)
        self.assertNotIn("note", res)

    def test_a_timed_out_wait_names_the_button(self):
        with self.assertRaises(tf3ctl.ToolError) as cm:
            tf3ctl.wait_new_hello(self.dir, 9, "1_1", timeout=0.3, why_slow=tf3ctl.WAIT_FOR_START_SLOW)
        self.assertIn("Start Game", str(cm.exception))
        self.assertIn("not even quit", str(cm.exception))
        with self.assertRaises(tf3ctl.ToolError) as cm:
            tf3ctl.wait_new_hello(self.dir, 9, "1_1", timeout=0.3)
        self.assertIn("dropped to the main menu", str(cm.exception), "the old reason without the option")
        self.assertNotIn("Start Game", str(cm.exception))

    def test_launch_load_passes_it_and_lifts_the_note(self):
        ns = tf3ctl.argparse.Namespace(load="s", new=False, add=[], remove=[], set_mods=None, param=[],
                                       wait_for_start=True, lang=None, timeout=30, launch_timeout=30)
        self.assertEqual(tf3ctl.start_args(ns), ("load", {"save": "s", "waitForStart": True}))
        # --load needs an owner whose launch record was written (the load goes to that owner's game)
        with unittest.mock.patch.object(tf3ctl, "game_pids", lambda: []), \
                unittest.mock.patch.object(tf3ctl, "OWNER", "me"), \
                unittest.mock.patch.object(tf3ctl, "write_launched", lambda pid: {"written": "x"}), \
                unittest.mock.patch.object(tf3ctl, "launch_game", lambda t: {"ok": True, "menu": True}), \
                unittest.mock.patch.object(tf3ctl, "wait_new_hello", lambda *a, **k: {"stamp": "2_2"}), \
                contextlib.redirect_stderr(io.StringIO()):
            out = tf3ctl.cmd_start(ns, restart=False)
        self.assertIs(out["ok"], True)
        self.assertEqual(out["note"], tf3ctl.WAIT_FOR_START_DONE, "at the top, not only inside load")
        self.assertEqual(out["load"]["note"], tf3ctl.WAIT_FOR_START_DONE)

    def test_help_says_it_needs_a_person(self):
        for name in ("load", "launch", "restart"):
            out = io.StringIO()
            with contextlib.redirect_stdout(out), self.assertRaises(SystemExit):
                tf3ctl.make_parser().parse_args([name, "--help"])
            text = out.getvalue()
            self.assertIn("--wait-for-start", text, name)
            flat = " ".join(text.split())
            self.assertIn("not even quit", flat, name)
            self.assertIn("a person", flat, name)


class GameStateTest(unittest.TestCase):
    def test_states_from_the_log(self):
        L = log_line
        start = [L("08:22:08", "Application startup. Hello!")]
        menu = start + [L("08:22:20", "Main menu is ready"),
                        L("08:22:20", "ModioModHubBackend: Setting mod management mode from Restricted to Disabled")]
        self.assertEqual(tf3ctl.log_state(start)[0], "starting")
        self.assertEqual(tf3ctl.log_state(menu)[0], "main_menu", "leaving the main menu's mod hub is not a save")
        loading = menu + [L("08:29:56", "Loading game from file test-save-bus")]
        st = tf3ctl.log_state(loading)
        self.assertEqual(st, ("loading", "2026-11-15 08:29:56Z", "test-save-bus"))
        game = loading + [L("08:30:31", "Game is ready")]
        self.assertEqual(tf3ctl.log_state(game)[0], "in_game")
        opened = game + [L("08:34:17", "ModioModHubBackend: Setting mod management mode from Disabled to Restricted")]
        self.assertEqual(tf3ctl.log_state(opened)[:2], ("menu", "2026-11-15 08:34:17Z"))
        closed = opened + [L("08:35:19", "ModioModHubBackend: Setting mod management mode from Restricted to Disabled")]
        self.assertEqual(tf3ctl.log_state(closed)[0], "in_game")
        back = closed + [L("08:36:02", "Main menu is ready"),
                         L("08:36:03", "Loading game from file test-save")]
        self.assertEqual(tf3ctl.log_state(back)[0], "loading", "an in-game load passes the main menu")

    def test_markers_megabytes_back_are_found_and_lines_are_whole(self):
        d = tempfile.mkdtemp()
        log = os.path.join(d, "stdout.txt")
        old = tf3ctl.CHUNK
        tf3ctl.CHUNK = 1000  # small chunks: the same code path as megabytes of mod output
        try:
            noise = "".join(log_line("09:%02d:00" % (i % 60), "chatty mod line %05d" % i) + "\n" for i in range(400))
            write(log, log_line("09:00:00", "Application startup. Hello!") + "\n" +
                  log_line("09:01:00", "Loading game from file test-save") + "\n" +
                  log_line("09:01:30", "Game is ready") + "\n" + noise +
                  log_line("09:20:00", "ModioModHubBackend: Setting mod management mode from Disabled to Restricted")
                  + "\n" + noise)
            lines = tf3ctl.log_tail_from_anchor(log)
            self.assertIn("Game is ready", lines[0], "starts at the last anchor")
            self.assertEqual(len(lines), 1 + 400 + 1 + 400, "every line once, none cut or doubled")
            self.assertEqual(tf3ctl.log_state(lines)[0], "menu")
            write(log, noise)  # no anchor at all: the whole file, still once
            self.assertEqual(len(tf3ctl.log_tail_from_anchor(log)), 400)
        finally:
            tf3ctl.CHUNK = old

    def _pickup_env(self, lines, timeout):
        d = tempfile.mkdtemp()
        write(os.path.join(d, "remote_probe__hello_1_1.lua"), "x")
        log = os.path.join(d, "stdout.txt")
        write(log, "\n".join(lines) + "\n")
        os.environ["TF3_LOG"] = log
        os.environ["TF3_ASSUME_RUNNING"] = "1"
        self.old_timeout = tf3ctl.PICKUP_TIMEOUT_SEC
        tf3ctl.PICKUP_TIMEOUT_SEC = timeout
        return d

    def tearDown(self):
        if hasattr(self, "old_timeout"):
            tf3ctl.PICKUP_TIMEOUT_SEC = self.old_timeout
        for k in ("TF3_LOG", "TF3_ASSUME_RUNNING"):
            os.environ.pop(k, None)

    def test_no_pickup_while_in_game_is_the_mods_fault_not_exit_3(self):
        d = self._pickup_env([log_line("08:30:31", "Game is ready")], 1.0)
        with self.assertRaises(tf3ctl.ToolError) as cm:
            tf3ctl.send("speed", {"speed": 1}, folder=d)
        self.assertNotIsInstance(cm.exception, tf3ctl.GameNotReady)
        self.assertIn("ESC menu", str(cm.exception))

    def test_a_fresh_marker_is_not_trusted_at_once(self):
        # today's date too: with the date fixed, the marker was a day old once the date had moved on
        t = time.gmtime()
        d = self._pickup_env([log_line("08:30:31", "Game is ready"), log_line(
            time.strftime("%H:%M:%S", t), "ModioModHubBackend: Setting mod management mode from Disabled to Restricted",
            time.strftime("%Y-%m-%d", t))], 4.5)
        # the menu marker is 0 s old: "Restricted to Disabled" may still be in the game's buffer
        t0 = time.time()
        with self.assertRaises(tf3ctl.GameNotReady):
            tf3ctl.send("speed", {"speed": 1}, folder=d)
        self.assertGreaterEqual(time.time() - t0, tf3ctl.LOG_SETTLE_SEC - 1.5, "waited for the marker to settle")

    def test_game_state_reports_closed_and_crashed(self):
        d = tempfile.mkdtemp()
        log = os.path.join(d, "stdout.txt")
        write(log, log_line("08:30:31", "Game is ready") + "\n")
        os.environ["TF3_LOG"] = log
        old = tf3ctl.game_running
        try:
            tf3ctl.game_running = lambda: False
            self.assertEqual(tf3ctl.game_state(d)["state"], "closed")
            write(os.path.join(d, "x.dmp"), "dump")
            self.assertEqual(tf3ctl.game_state(d)["state"], "crashed")
            tf3ctl.game_running = lambda: True
            self.assertEqual(tf3ctl.game_state(d)["state"], "in_game")
        finally:
            tf3ctl.game_running = old
            os.environ.pop("TF3_LOG")

    def test_a_command_to_a_game_in_a_menu_fails_fast_with_the_reason(self):
        d = tempfile.mkdtemp()
        write(os.path.join(d, "remote_probe__hello_1_1.lua"), "x")
        log = os.path.join(d, "stdout.txt")
        write(log, "\n".join([log_line("08:30:31", "Game is ready"), log_line(
            "08:34:17", "ModioModHubBackend: Setting mod management mode from Disabled to Restricted")]) + "\n")
        os.environ["TF3_LOG"] = log
        os.environ["TF3_ASSUME_RUNNING"] = "1"
        try:
            t0 = time.time()
            with self.assertRaises(tf3ctl.GameNotReady) as cm:
                tf3ctl.send("speed", {"speed": 1}, folder=d)
            self.assertLess(time.time() - t0, tf3ctl.NOT_READY_GRACE_SEC + 2, "not the 30 s timeout")
            self.assertEqual(cm.exception.state["state"], "menu")
            self.assertIn("id = 0,", read(os.path.join(d, "remote_probe__cmd_1_1.lua")), "withdrawn")
            out = io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                os.environ["TF3_REMOTE_DIR"] = d
                code = tf3ctl.main(["status"])
            self.assertEqual(code, 3)
            self.assertEqual(json.loads(out.getvalue())["gameState"]["state"], "menu")
        finally:
            for k in ("TF3_LOG", "TF3_ASSUME_RUNNING", "TF3_REMOTE_DIR"):
                os.environ.pop(k, None)


class EndToEndTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = tempfile.mkdtemp()
        cls.dir = os.path.join(cls.root, "recordings")
        cls.game = subprocess.Popen(["luajit", os.path.join(ROOT, "tests", "fake_game.lua"), cls.root, "120"],
                                    stderr=subprocess.PIPE, text=True)
        deadline = time.time() + 10
        while not glob.glob(os.path.join(cls.dir, "remote_probe__cmd_*.lua")):
            if time.time() > deadline:
                raise RuntimeError("the fake game did not start")
            time.sleep(0.05)
        os.environ["TF3_REMOTE_DIR"] = cls.dir

    @classmethod
    def tearDownClass(cls):
        cls.game.kill()
        cls.game.wait()
        cls.game.stderr.close()
        os.environ.pop("TF3_REMOTE_DIR", None)

    def ctl(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = tf3ctl.main(list(argv))
        return code, json.loads(out.getvalue()) if out.getvalue() else None

    def test_1_status(self):
        code, res = self.ctl("status")
        self.assertEqual(code, 0)
        self.assertEqual(res["mod"], "hummer_remote_probe")
        self.assertEqual(res["state"]["date"]["year"], 1900)

    def test_2_speed_beyond_4x_and_pause(self):
        code, res = self.ctl("speed", "16")
        self.assertEqual(code, 0)
        self.assertEqual(res["state"]["speedup"], 16, "under the fake's estimate of 40")
        code, res = self.ctl("speed", "64")
        self.assertEqual(res["state"]["speedup"], 40, "capped at the estimate (by the mod, version 2)")
        self.assertIs(res["capped"], True)
        self.assertEqual(res["requested"], 64)
        code, res = self.ctl("speed", "64", "--force")
        self.assertEqual(res["state"]["speedup"], 64)
        code, res = self.ctl("pause")
        self.assertEqual(res["state"]["speedup"], 0)

    def test_3_saves_newest_first_and_info(self):
        code, res = self.ctl("saves")
        self.assertEqual([s["saveName"] for s in res["saves"]], ["probe", "other"])
        code, res = self.ctl("info", "probe")
        self.assertEqual(code, 0)
        self.assertEqual(res["mods"], ["example_mod", "hummer_remote_probe"])
        self.assertEqual(res["modParams"]["example_mod"]["treePollution"], 1)
        code, res = self.ctl("info", "missing")
        self.assertEqual(code, 1)
        self.assertIn("no save named", res["error"])

    def test_4_run_reports_the_capped_rate(self):
        code, res = self.ctl("run", "--days", "20", "--speed", "64")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["state"]["speedup"], 0)
        # the fake game caps at 40x like a busy CPU would; the measured rate must show that, not 64
        self.assertLess(res["measured"]["overall"], 45)
        self.assertGreater(res["measured"]["overall"], 5)

    def test_5_load_dry_run_then_load(self):
        code, res = self.ctl("load", "other", "--add", "m2", "--param", "m2:k=2", "--dry-run")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["mods"], ["m2", "hummer_remote_probe"])
        before = tf3ctl.current_stamp(self.dir)
        code, res = self.ctl("load", "probe", "--param", "example_mod:treePollution=3", "--timeout", "30")
        self.assertEqual(code, 0, res)
        self.assertNotEqual(res["hello"]["stamp"], before)
        self.assertEqual(res["hello"]["modParams"]["example_mod"]["treePollution"], 3)
        code, res = self.ctl("status")
        self.assertEqual(code, 0, "the loaded game answers")
        self.assertNotIn("note", res)
        # the fake game does not hold at the button, so the load comes back; the answer still says what it means
        code, res = self.ctl("load", "probe", "--wait-for-start", "--timeout", "30")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["note"], tf3ctl.WAIT_FOR_START_DONE)
        self.assertIn("no commands", res["note"])
        code, res = self.ctl("status")
        self.assertEqual(code, 0, "the loaded game answers")

    def test_6_old_files_are_cleaned_up(self):
        self.ctl("status")
        names = os.listdir(self.dir)
        self.assertEqual(len([n for n in names if n.startswith("remote_probe__hello_")]), 1, names)
        self.assertEqual(len([n for n in names if n.startswith("remote_probe__cmd_")]), 1, names)
        self.assertLessEqual(len([n for n in names if n.startswith("remote_probe__res_")]), 1, names)

    def test_7_status_while_a_run_is_going(self):
        results = {}

        def run():
            results["run"] = self.ctl("run", "--months", "2", "--speed", "8")
        t = threading.Thread(target=run)
        t.start()
        time.sleep(1)
        for _ in range(2):
            code, res = self.ctl("status")
            self.assertEqual(code, 0)
            self.assertIsNotNone(res["run"], "the run was not overwritten")
        t.join(90)
        code, res = results["run"]
        self.assertEqual(code, 0, res)

    def test_8_a_run_the_tool_gives_up_on_is_paused(self):
        code, res = self.ctl("run", "--months", "6", "--speed", "1", "--timeout", "2")
        self.assertEqual(code, 2)
        code, res = self.ctl("status")
        self.assertEqual(res["state"]["speedup"], 0)
        self.assertIsNone(res.get("run"))

    def test_9_owner_and_poll(self):
        code, res = self.ctl("--owner", "tester", "poll", "--idle", "1", "--active", "0.1")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["poll"], {"active": 0.1, "idle": 1})
        code, res = self.ctl("--owner", "tester", "speed", "0")
        self.assertEqual(code, 0, res)
        code, res = self.ctl("--owner", "other", "poll", "--idle", "2")
        code, res = self.ctl("--owner", "other", "status")
        self.assertEqual(res["lastAction"]["owner"], "tester", "status and poll do not count as using the game")
        self.assertEqual(res["lastAction"]["cmd"], "speed")
        self.assertEqual(tf3ctl.read_activity(self.dir)["owner"], "tester", "tool-side record agrees")
        code, res = self.ctl("poll", "--idle", "60")
        self.assertEqual(code, 1)
        self.assertIn("between", res["error"])

    def test_9x_industry_workers(self):
        code, res = self.ctl("industry-workers")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["total"], 1)
        m = res["industries"][0]
        self.assertEqual((m["id"], m["name"], m["construction"], m["capacity"], m["workers"], m["lastVisitors"]),
                         (51, "Coal mine", 5100, 12, 5, 1))
        self.assertEqual((m["town"]["id"], m["town"]["population"], m["town"]["distance"]), (11, 140, 300))
        self.assertTrue(res["workersScript"]["ok"], res)
        code, res = self.ctl("industry-workers", "--entity", "51")
        self.assertEqual(code, 0, res)
        self.assertEqual([e["id"] for e in res["industries"]], [51])
        code, res = self.ctl("industry-workers", "--entity", "12345")
        self.assertEqual(code, 1, res)
        self.assertIn("no industry", res["error"])

    def test_9x_industry_stocks(self):
        code, res = self.ctl("industry-stocks")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["total"], 1)
        m = res["industries"][0]
        self.assertEqual((m["id"], m["construction"], m.get("fileName")), (51, 5100, "industry/coal_mine.con"), m)
        st = m["stocks"][0]
        self.assertEqual((st["stockId"], st["cargoType"], st["cargo"]["fileName"], st["capacity"], st["count"]),
                         (0, 1, "COAL", 400, 37))
        self.assertEqual(m["aomParams"], {"hummer_aom_upg_pollution": "", "hummer_aom_upg_boost": 2})
        self.assertEqual(m["params"], {"year": 1900})
        self.assertNotIn("allParams", m)
        self.assertEqual(m["rules"][0]["output"], [{"cargoType": 1, "amount": 2, "cargo": {"fileName": "COAL", "name": "Coal"}}])
        code, res = self.ctl("industry-stocks", "--entity", "51", "--all-params")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["industries"][0]["allParams"]["year"], 1900)
        code, res = self.ctl("industry-stocks", "--grep", "farm")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["industries"], [])
        code, res = self.ctl("industry-stocks", "--grep", "coal")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["industries"][0]["stocks"][0]["stockCargoTypes"][0]["cargoType"], 1)
        code, res = self.ctl("industry-stocks", "--grep", "farm")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["industries"], [])
        code, res = self.ctl("industry-stocks", "--entity", "12345")
        self.assertEqual(code, 1, res)
        self.assertIn("no industry", res["error"])

    def test_9wb_vehicles_state(self):
        code, res = self.ctl("vehicles")
        self.assertEqual(code, 0, res)
        self.assertEqual(set(res), {"ok", "total", "vehicles", "id"}, "the plain answer as before")
        self.assertTrue(res["vehicles"], "test_9w left a vehicle")
        e = res["vehicles"][0]["entity"]
        self.assertNotIn("state", res["vehicles"][0])
        code, res = self.ctl("vehicles", "--entity", "%d,77777" % e, "--state", "--since", "0")
        self.assertEqual(code, 0, res)
        self.assertEqual((res["total"], res["missing"], res["since"]), (1, [77777], 0))
        self.assertIn("gameTime", res)
        st = res["vehicles"][0]["state"]
        self.assertEqual((st["runningCostPerYear"], st["balanceSince"], st["cargo"]), (1234.5, 0, []))
        code, res = self.ctl("vehicles", "--entity", "77777", "--state")
        self.assertEqual((code, res["total"], res["vehicles"], res["missing"]), (0, 0, [], [77777]))

    def test_9wb_build_place_and_remove(self):
        ramp = "road_bridge_ramp::/road_bridge_ramp/ramp.con"
        code, res = self.ctl("build", "--res", ramp, "--at", "300,40", "--dry-run")
        self.assertEqual(code, 0, res)
        self.assertTrue(res["dryRun"], res)
        self.assertIs(res["checked"], False, "the engine's check is not run")
        self.assertNotIn("buildable", res, "no verdict without the engine's check")
        self.assertEqual(res["near"], [])
        code, res = self.ctl("build", "--res", ramp, "--at", "300,40", "--params", '{"rbr_height": 4}')
        self.assertEqual(code, 0, res)
        self.assertEqual(res["zFrom"], "terrain")
        self.assertEqual(res["at"]["z"], 3)
        self.assertEqual(res["params"]["rbr_height"], 4)
        self.assertEqual(len(res["construction"]["ends"]), 2)
        e = res["entity"]
        # a road from the ramp's free end (the answer's ends, as a harbour's entrance would be): joined to it
        end = res["construction"]["ends"][0]
        code, road = self.ctl("road", "--from", "%g,%g" % (end["x"], end["y"]), "--to", "%g,%g" % (end["x"], end["y"] + 60))
        self.assertEqual(code, 0, road)
        self.assertEqual(road["from"]["node"], end["node"])
        self.assertEqual(road["template"], "::/infrastructure/street/town/town_old_medium.street_template")
        self.assertEqual(len(road["edges"]), 1)
        self.assertEqual(road["cost"], 600)
        code, res = self.ctl("build", "--res", "road_bridge_ramp::/nope.con", "--at", "0,0")
        self.assertEqual(code, 1)
        self.assertIn(ramp, res["error"], "names like it")
        code, res = self.ctl("build", "--remove", str(e))
        self.assertEqual(code, 0, res)
        self.assertEqual(res["removed"], [e])
        code, res = self.ctl("build", "--remove-all")
        self.assertEqual(code, 1, "nothing left the probe built")

    def test_9wb_build_harbour_modules_and_water(self):
        harbour, quay = "::/stations/water/harbor_modular.con", "::/station/water/harbor_quay.module"
        code, res = self.ctl("water", "--at", "1100,0")
        self.assertEqual(code, 0, res)
        self.assertEqual((res["waterLevel"], res["points"][0]["onWater"], res["points"][0]["height"]), (5, True, -3))
        code, res = self.ctl("water", "--grid", "900,0,1100,100,100")
        self.assertEqual(code, 0, res)
        self.assertEqual((res["rows"], res["water"], res["land"]), ([".~~", ".~~"], 4, 2))
        code, res = self.ctl("build", "--res", harbour, "--at", "1050,0", "--dry-run")
        self.assertEqual(code, 0, res)
        self.assertEqual((res["waterLevel"], res["onWater"]), (5, True))
        mods = json.dumps({"modules": {"120001": {"name": quay}}})
        code, res = self.ctl("build", "--res", harbour, "--at", "1050,0", "--params", mods)
        self.assertEqual(code, 0, res)
        self.assertEqual((res["terminals"], res["autoFillSlots"]), (1, False), "the text slot id reached a slot")
        self.assertEqual(res["params"]["modules"][0]["slot"], 120001)
        self.assertEqual(res["params"]["modules"][0]["filled"], ["metadata"])
        code, res = self.ctl("build", "--res", harbour, "--at", "1300,0", "--params",
                             json.dumps({"modules": {"1": {"name": "::/station/water/nope.module"}}}))
        self.assertEqual(code, 1)
        self.assertIn(quay, res["error"], "names like it")
        code, res = self.ctl("build", "--remove-all")
        self.assertEqual(code, 0, res)

    def test_9wc_persons(self):
        # no vehicle 77777 in the fake: missing, not an error, so a poll goes on; one JSON line per sample
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = tf3ctl.main(["persons", "--vehicle", "77777", "--every", "0.5", "--count", "3"])
        self.assertEqual(code, 0, out.getvalue())
        lines = out.getvalue().splitlines()
        self.assertEqual(len(lines), 3, lines)
        rows = [json.loads(x) for x in lines]
        # the first pickup waits for the mod's idle poll (2 s), so slots may be skipped after it: never sent in a burst
        self.assertEqual(rows[0]["sample"], 1)
        for prev, cur in zip(rows, rows[1:]):
            self.assertEqual(cur["sample"] - prev["sample"] - 1, cur.get("skipped", 0), rows)
            self.assertGreaterEqual(cur["unixTime"] - rows[0]["unixTime"], 0.5 * (cur["sample"] - 1) - 0.05, rows)
        for r in rows:
            self.assertEqual((r["ok"], r["missing"], r["total"], r["persons"], r["vehicle"]), (True, True, 0, [], 77777))
            self.assertIn("gameTime", r)
        code, res = self.ctl("persons", "--vehicle", "77777")
        self.assertEqual((code, res["missing"]), (0, True), res)
        self.assertNotIn("sample", res, "one call: the plain answer")
        code, res = self.ctl("persons", "--line", "999")
        self.assertEqual(code, 1, res)
        self.assertIn("not one of the company's lines", res["error"])

    def test_9w_vehicles_buy_list_sell(self):
        code, res = self.ctl("depots")
        self.assertEqual(code, 0, res)
        self.assertEqual([(d["id"], d["kind"], d["carrier"]) for d in res["depots"]], [(301, "road", "OTHER")])
        code, res = self.ctl("buy", "--model", "bus_1900", "--depot", "301", "--via", "cmd", "--count", "2")
        self.assertEqual(code, 0, res)
        self.assertEqual((res["via"], res["spent"], res["storePriceTotal"]), ("cmd", 60000, 60000))
        self.assertEqual(res["sentParts"], [{"modelId": 101, "purchaseTime": 0}])
        self.assertEqual(len(res["vehicles"]), 2)
        code, res = self.ctl("buy", "--model", "bus", "--depot", "301")
        self.assertEqual(code, 1)
        self.assertIn("2 models match", res["error"])
        code, res = self.ctl("vehicles")
        self.assertEqual((code, res["total"]), (0, 2), res)
        e = res["vehicles"][0]["entity"]
        code, res = self.ctl("sell", "--vehicle", str(e))
        self.assertEqual(code, 0, res)
        self.assertEqual((res["via"], res["sold"], res["spent"]), ("gui", True, -27000))
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            tf3ctl.main(["buy", "--model", "bus_1900"])  # no depot: the probe cannot pick one as the store does

    def test_9u_models(self):
        code, res = self.ctl("models", "--grep", "bus")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["total"], 2)
        m = res["models"][0]
        self.assertEqual((m["id"], m["fileName"], m["price"]), (101, "vehicle/bus/bus_1900.mdl", 30000))
        self.assertEqual((m["compartments"], m["capacities"], m["totalCapacity"]),
                         ([{"loadConfigs": []}, {"loadConfigs": []}], [], 0))
        code, res = self.ctl("models", "--grep", "zeppelin")
        self.assertEqual((code, res["total"], res["models"]), (0, 0, []))
        code, res = self.ctl("models", "--limit", "1")
        self.assertEqual((code, res["total"], len(res["models"])), (0, 3, 1))

    def test_9v_money(self):
        code, res = self.ctl("money", "--set", "2000000")
        self.assertEqual(code, 0, res)
        self.assertEqual((res["balanceAfter"], res["amount"], res["callback"]), (2000000, 2000000 - res["balanceBefore"], True))
        code, res = self.ctl("money", "--add", "-500")
        self.assertEqual((code, res["balanceAfter"], res["spent"]), (0, 1999500, 500), res)
        for bad in (["money"], ["money", "--set", "1", "--add", "2"], ["money", "--set", "lots"]):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                tf3ctl.main(bad)

    def test_9u_stations_and_lines(self):
        code, res = self.ctl("stations", "--near", "11", "--radius", "1000")
        self.assertEqual(code, 0, res)
        self.assertEqual([(s["name"], s["distance"]) for s in res["stations"]], [("Central", 100), ("Harbour", 900)],
                         "nearest first; another company's left out")
        code, res = self.ctl("line", "create", "--stops", "Central,42", "--name", "[probe] e2e")
        self.assertEqual(code, 0, res)
        self.assertEqual((res["via"], res["name"]), ("gui", "[probe] e2e"))
        self.assertEqual([(s["stationGroup"], s["name"]) for s in res["stops"]], [(41, "Central"), (42, "Harbour")])
        line = res["line"]
        code, res = self.ctl("line", "update", str(line), "--cargo", "coal", "--via", "cmd")
        self.assertEqual(code, 0, res)
        self.assertEqual((res["via"], res["loads"], res["customFilters"]), ("cmd", ["COAL"], True))
        code, res = self.ctl("buy", "--model", "bus_1900", "--depot", "301", "--line", str(line), "--via", "cmd")
        self.assertEqual(code, 0, res)
        vehicle = res["vehicleIds"][0]
        code, res = self.ctl("lines", "--name", "probe")
        self.assertEqual(code, 0, res)
        self.assertEqual([(l["id"], l["vehicles"], l["vehicleIds"]) for l in res["lines"]], [(line, 1, [vehicle])])
        code, res = self.ctl("line", "create", "--stops", "Central,Rival Halt")
        self.assertEqual(code, 1)
        self.assertIn("belongs to another company", res["error"])
        code, res = self.ctl("line", "delete", str(line))
        self.assertEqual(code, 1)
        self.assertIn("has 1 vehicles", res["error"])
        code, res = self.ctl("line", "delete", str(line), "--sell-vehicles")
        self.assertEqual(code, 0, res)
        self.assertEqual((res["removed"], res["soldVehicles"]), (True, [vehicle]))

    def test_9t_connect_dry_run_then_build(self):
        code, res = self.ctl("connect", "--from", "101", "--to", "103")
        self.assertEqual(code, 0, res)
        self.assertEqual((res["dryRun"], res["buildable"], res["from"]["node"], res["to"]["node"]), (True, True, 101, 103))
        self.assertEqual(res["route"]["length"], 1000)
        self.assertGreater(res["estimate"]["cost"], 0)
        code, res = self.ctl("connect", "--from", "101", "--to", "103", "--build", "--slope", "3")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["settings"]["maxSlope"], 0.03)
        self.assertEqual(res["build"]["spent"], res["estimate"]["cost"])
        self.assertEqual(len(res["build"]["newEdges"]), res["route"]["pieces"])
        self.assertEqual(res["build"]["joined"], {"from": True, "to": True})
        code, res = self.ctl("connect", "--from", "101", "--to", "103")
        self.assertEqual(code, 1, "the ends are taken now")
        self.assertIn("is not a free track end", res["error"])

    def test_9x_entities_and_window(self):
        code, res = self.ctl("entities", "--kind", "town", "--grep", "bay")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["entities"], [{"id": 12, "name": "Emsworth Bay"}])
        code, res = self.ctl("window", "--town", "Emsworth", "--focus")
        self.assertEqual(code, 0, res)
        self.assertEqual((res["entity"], res["name"], res["focused"]), (11, "Emsworth", True))
        code, res = self.ctl("window", "--line", "nope")
        self.assertEqual(code, 1)
        self.assertIn("no match", res["error"])

    def test_9x_entities_warehouse_and_its_stocks(self):
        code, res = self.ctl("entities", "--kind", "warehouse")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["entities"], [{"id": 46841, "name": "", "construction": 46840, "stockList": 46842,
                                            "stocks": 2, "capacity": 1500}])
        # the construction's id (as build gives it) reaches the warehouse's stock list
        code, res = self.ctl("stock", "list", "--entity", "46840")
        self.assertEqual(code, 0, res)
        self.assertEqual((res["stockList"], res["via"], res["owner"], res["construction"], len(res["stocks"])),
                         (46842, "CONSTRUCTION>WAREHOUSE", 46841, 46840, 2))
        code, res = self.ctl("stock", "set", "--entity", "46840", "--stock", "1", "--amount", "500", "--dry-run")
        self.assertEqual(code, 0, res)
        self.assertEqual((res["sent"], res["stockList"], res["before"]), (False, 46842, 0))
        code, res = self.ctl("stock", "set", "--entity", "46840", "--stock", "1", "--amount", "501")
        self.assertEqual(code, 1, res)
        self.assertIn("capacity (500)", res["error"])

    def test_9x_window_manager(self):
        code, res = self.ctl("window", "--line", "Bus 1", "--manager")
        self.assertEqual(code, 0, res)
        self.assertEqual((res["entity"], res["name"], res["manager"]), (21, "Bus 1", True))
        code, res = self.ctl("window", "--entity", "21", "--manager")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["manager"], True)
        code, res = self.ctl("window", "--entity", "11", "--manager")
        self.assertEqual(code, 1, "a town's id is not a line")
        self.assertIn("not one of the company's lines", res["error"])
        code, res = self.ctl("window", "--line", "nope", "--manager")
        self.assertEqual(code, 1)
        self.assertIn("no match", res["error"])
        code, res = self.ctl("window", "--town", "Emsworth", "--manager")
        self.assertEqual(code, 2, "refused before anything is sent")
        code, res = self.ctl("window", "--close-all", "--manager")
        self.assertEqual(code, 2)

    def test_9x_camera(self):
        code, res = self.ctl("camera")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["camera"]["distance"], 500)
        code, res = self.ctl("camera", "--set", "10,20")
        self.assertEqual(code, 0, res)
        self.assertEqual((res["camera"]["x"], res["camera"]["y"], res["camera"]["distance"]), (10, 20, 500))
        code, res = self.ctl("camera", "--focus", "1,2,3", "--distance", "300")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["camera"]["distance"], 300)
        code, res = self.ctl("camera", "--set", "1,nan")
        self.assertEqual(code, 1)
        code, res = self.ctl("camera", "--set", "1,2", "--entity", "3")
        self.assertEqual(code, 2, "refused by the tool")

    def test_9x_build_tool(self):
        code, res = self.ctl("build-tool", "--res", "station/street/bus_stop.con", "--template", "2", "--seconds", "5")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["tag"], "station/street/bus_stop.con@2")
        self.assertIn("notes", res)
        code, res = self.ctl("build-tool", "--close")
        self.assertEqual(code, 0, res)
        self.assertTrue(res["wasOpen"])
        code, res = self.ctl("build-tool", "--res", "nope.con")
        self.assertEqual(code, 1)
        self.assertIn("no such construction", res["error"])
        code, res = self.ctl("build-tool")
        self.assertEqual(code, 2)
        code, res = self.ctl("build-tool", "--menu", "rail")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["menuEvent"], "openRail")
        code, res = self.ctl("build-tool", "--menu", "rail", "--template", "1")
        self.assertEqual(code, 1, "template needs res: refused by the mod")

    def test_9xz_around(self):
        code, res = self.ctl("around", "--at", "0,7000", "--radius", "120")
        self.assertEqual(code, 0, res)
        ids = {e["id"]: e for e in res["entities"]}
        self.assertEqual(ids[9601]["kind"], "town_building")
        self.assertEqual(ids[9601]["townName"], "Fakeham")
        self.assertEqual(ids[9601]["box"]["x1"], 25)
        self.assertEqual(ids[9604]["kind"], "field")
        self.assertIn("ms", res)
        code, res = self.ctl("around", "--at", "0,7000", "--kinds", "field")
        self.assertEqual([e["id"] for e in res["entities"]], [9604])

    def test_9xz_mod_commands(self):
        sample = "hummer_remote_probe_ext_sample"
        code, res = self.ctl("mod", "--list")
        self.assertEqual(code, 0, res)
        mods = {m["mod"]: m for m in res["mods"]}
        self.assertEqual([c["name"] for c in mods[sample]["commands"]], ["hello", "speed"])
        self.assertEqual([c["tag"] for c in mods[sample]["commands"]], ["reads", "changes"])
        self.assertEqual(res["checked"], 2, "example_mod has no file and is left out")
        code, res = self.ctl("mod", sample)
        self.assertEqual(code, 0, res)
        self.assertEqual(res["checked"], 1)
        code, res = self.ctl("--owner", "tester", "mod", sample, "hello", '{"who": "ann", "n": [1, 2]}')
        self.assertEqual(code, 0, res)
        self.assertEqual(res["result"]["greeting"], "hello, ann")
        self.assertEqual(res["result"]["args"]["n"], [1, 2])
        self.assertEqual(res["result"]["from"], "tester")
        # tagged changes: sent again as modChange, which the mod runs
        code, res = self.ctl("--owner", "tester", "mod", sample, "speed", '{"speed": 0}')
        self.assertEqual(code, 0, res)
        self.assertEqual(res["result"]["speed"], 0)
        self.assertEqual(res["result"]["speedup"], 0)
        code, res = self.ctl("status")
        self.assertEqual(res["lastAction"]["cmd"], "modChange")
        code, res = self.ctl("--owner", "tester", "mod", sample, "speed", '{"speed": 9}')
        self.assertEqual(code, 1, res)
        self.assertEqual(res["kind"], "error")
        code, res = self.ctl("mod", sample, "nope")
        self.assertEqual(code, 1, res)
        self.assertEqual(res["kind"], "noCommand")
        code, res = self.ctl("mod", "example_mod", "x")
        self.assertEqual(res["kind"], "noExt")
        self.ctl("--owner", "tester", "mod", sample, "speed", '{"speed": 1}')

    def test_9xz_lanes(self):
        # the fake's electric tram street 9620 (the base's town_new_medium_tram_electrified lanes): track on the
        # outer road lanes, 2 (left, against the piece) and 5 (right)
        code, res = self.ctl("lanes", "--edge", "9620")
        self.assertEqual(code, 0, res)
        d = res["edges"][0]
        self.assertEqual(d["tramTrackType"], "ELECTRIC")
        self.assertEqual(d["tramLanes"], [2, 5])
        self.assertEqual([d["lanes"][1]["side"], d["lanes"][4]["side"]], ["left", "right"])
        self.assertIn("ELECTRIC_TRAM", d["lanes"][1]["modes"])
        self.assertEqual(d["lanes"][1]["direction"], "node1->node0")
        code, res = self.ctl("lanes", "--edge", "9620,9601")
        self.assertEqual(code, 0, res)
        self.assertIn("no BASE_EDGE", res["edges"][1]["error"])
        code, res = self.ctl("around", "--at", "0,7400", "--radius", "20", "--kinds", "street", "--lanes")
        self.assertEqual(code, 0, res)
        self.assertEqual([e["id"] for e in res["entities"]], [9620])
        self.assertEqual(res["entities"][0]["lanes"]["tramLanes"], [2, 5])

    def test_9xz_fit(self):
        # the house at x 10..25, y 7010..7025 and the field at x 60..100 (around's fake): the fake's 20 m box fits
        # between them, the engine's check takes it
        code, res = self.ctl("fit", "--res", "road_bridge_ramp::/road_bridge_ramp/ramp.con", "--at", "40,7017",
                             "--radius", "30", "--angle", "0", "--check", "1")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["boxFrom"], "the engine's check at the point, unturned")
        self.assertEqual(res["box"], {"x0": -10, "y0": -10, "x1": 10, "y1": 10})
        self.assertEqual(res["place"]["offset"], 0)
        self.assertTrue(res["checked"])
        code, res = self.ctl("build", "--res", "road_bridge_ramp::/road_bridge_ramp/ramp.con", "--at", "17,7017",
                             "--dry-run", "--engine-check")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["footprint"]["x1"], 10)

    def test_9xy_parcels(self):
        code, res = self.ctl("parcels", "--edge", "9010")
        self.assertEqual(code, 0, res)
        e = res["edges"][0]
        self.assertEqual((e["left"]["count"], e["right"]["count"], e["left"]["built"], e["inConstruction"]),
                         (2, 1, 1, False))
        self.assertEqual(e["left"]["parcels"][0]["area"], 200)
        code, res = self.ctl("parcels", "--edge", "9011", "--no-list")
        self.assertEqual(code, 0, res)
        e = res["edges"][0]
        self.assertEqual((e["left"]["count"], e["right"]["count"], e["construction"]), (0, 0, 9900))
        self.assertNotIn("parcels", e["left"])
        code, res = self.ctl("parcels", "--rect=-10,4990,250,5010")
        self.assertEqual(code, 0, res)
        self.assertEqual([x["edge"] for x in res["edges"]], [9010, 9011])
        self.assertEqual((res["totals"]["left"], res["totals"]["right"]), (2, 1))
        code, res = self.ctl("parcels", "--edge", "424242")
        self.assertEqual(code, 1, res)
        self.assertIn("no such entity", res["error"])

    def test_9xz_debug_stock_and_steps(self):
        code, res = self.ctl("stock", "list", "--entity", "51")
        self.assertEqual(code, 0, res)
        self.assertEqual((res["stockList"], res["stocks"][0]["stockId"], res["stocks"][0]["cargo"],
                          res["stocks"][0]["count"]), (51, 0, "COAL", 37))
        code, res = self.ctl("stock", "set", "--entity", "51", "--stock", "0", "--amount", "100", "--dry-run")
        self.assertEqual(code, 0, res)
        self.assertEqual((res["sent"], res["before"], res["functionPresent"]), (False, 37, True))
        code, res = self.ctl("stock", "set", "--entity", "51", "--stock", "0", "--amount", "100")
        self.assertEqual(code, 0, res)
        self.assertEqual((res["sent"], res["success"], res["before"], res["after"]), (True, True, 37, 100))
        code, res = self.ctl("stock", "set", "--entity", "51", "--stock", "3", "--amount", "1")
        self.assertEqual(code, 1, res)
        self.assertIn("no stock 3", res["error"])
        code, res = self.ctl("stock", "set", "--entity", "51", "--stock", "0", "--amount", "37")  # back as it was
        self.assertEqual((code, res["after"]), (0, 37), res)
        self.assertEqual(self.ctl("speed", "1")[0], 0)
        code, res = self.ctl("steps", "20")  # the game runs: refused
        self.assertEqual(code, 1, res)
        self.assertIn("pause it first", res["error"])
        code, res = self.ctl("speed", "0")
        self.assertEqual(code, 0, res)
        try:
            code, res = self.ctl("steps", "20", "--dry-run")
            self.assertEqual((code, res["sent"], res["count"]), (0, False, 20), res)
            code, res = self.ctl("steps", "200")  # the fake runs them on 5 a frame after the callback
            self.assertEqual(code, 0, res)
            self.assertEqual((res["sent"], res["success"], res["timedOut"], res["updateCountDelta"],
                              res["gameTimeDelta"]), (True, True, False, 200, 200 * 200), res)
            self.assertGreater(res["waitedSec"], 0, res)
        finally:
            self.ctl("speed", "1")
        code, res = self.ctl("stock", "list", "--entity", "999999")
        self.assertEqual(code, 1, res)
        self.assertIn("no such entity", res["error"])

    def test_9y_screenshot_and_newgame_unsafe_are_gone(self):
        for argv in (["screenshot"], ["newgame", "--size", "tiny", "--unsafe"]):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as cm:
                tf3ctl.main(argv)
            self.assertEqual(cm.exception.code, 2, argv)

    def test_8_town_connections_and_connect(self):
        code, res = self.ctl("town", "connections")
        self.assertEqual(code, 0, res)
        self.assertEqual([t["id"] for t in res["towns"]], [11, 12])
        self.assertEqual(res["towns"][0]["industries"][0]["id"], 51, "the coal mine's closest town")
        self.assertEqual(res["connections"], [])
        code, res = self.ctl("--owner", "t", "town", "connect", "--build", "--default", "--dry-run")
        self.assertEqual(code, 0, res)
        self.assertIs(res["sent"], False)
        self.assertEqual(res["connectionsSent"], [[0, 1]])
        code, res = self.ctl("--owner", "t", "town", "connect", "--build", "--default")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["after"]["towns"][0]["connectedTowns"][0]["id"], 12)
        code, res = self.ctl("town", "connections", "--entity", "51")
        self.assertEqual(code, 1, "an industry is no town")

    def test_9z_newgame_list_dry_run_and_start(self):  # runs last: it replaces the game
        self._newgame()

    def _newgame(self):
        code, res = self.ctl("newgame", "--list")
        self.assertEqual(code, 0, res)
        self.assertIn("temperate.clima", res["climates"])
        code, res = self.ctl("newgame", "--size", "tiny", "--year", "1930", "--add", "m9", "--dry-run")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["plan"]["numTiles"], [16, 16])
        self.assertIn("m9", res["plan"]["mods"])
        loc = res["plan"]["locations"]  # the values sent as locationsConfig, to compare with the menu's
        for key in ("townFrequency", "populationDensity", "industryDensity", "maxNumberPerArea"):
            self.assertIsInstance(loc[key], (int, float), key)
        self.assertEqual(res["plan"]["timeOfDaySeconds"], 14 * 3600)
        before = tf3ctl.current_stamp(self.dir)
        code, res = self.ctl("newgame", "--size", "tiny")
        self.assertEqual(code, 2, "refused: it crashes the game from inside a save (a start from the main menu: "
                         "launch / restart --new, LaunchEndToEndTest)")
        self.assertEqual(tf3ctl.current_stamp(self.dir), before, "nothing started")
        code, res = self.ctl("newgame", "--climate", "arctic", "--dry-run")
        self.assertEqual(code, 1)
        self.assertIn("known:", res["error"])


class QuitLaunchTest(unittest.TestCase):
    """quit / launch / restart, event and tool arguments, the main-menu probe."""

    def setUp(self):
        self.saved = {k: getattr(tf3ctl, k) for k in ("game_pids", "send", "process_start", "OWNER")}
        self.saved_kill = os.kill
        # an exchange folder of its own: never the real game's activity file
        self.x = tempfile.mkdtemp()
        write(os.path.join(self.x, "remote_probe__hello_1_1.lua"), 'function data() return { json = "{}" } end')
        os.environ["TF3_REMOTE_DIR"] = self.x

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(tf3ctl, k, v)
        os.kill = self.saved_kill
        for k in ("TF3_ASSUME_RUNNING", "TF3_LOG", "TF3_REMOTE_DIR"):
            os.environ.pop(k, None)

    def test_quit_when_the_game_quits(self):
        pids = [123]
        sent = []

        def fake_send(cmd, args=None, timeout=20, **kw):
            sent.append(cmd)
            pids.clear()  # the game goes away
            return {"ok": True, "quitting": True}
        tf3ctl.game_pids = lambda: list(pids)
        tf3ctl.send = fake_send
        self.assertEqual(tf3ctl.quit_game(timeout=2)["how"], "quit")
        self.assertEqual(sent, ["quit"])
        self.assertEqual(tf3ctl.quit_game(timeout=2)["how"], "not running", "nothing to do")

    def test_quit_without_answer_needs_kill_and_then_uses_sigkill(self):
        pids = [123]
        killed = []

        def no_answer(*a, **kw):
            raise tf3ctl.GameNotReady("the mod cannot take command 1: loading", {"state": "loading"})
        tf3ctl.game_pids = lambda: list(pids)
        tf3ctl.send = no_answer
        with self.assertRaises(tf3ctl.ToolError) as cm:
            tf3ctl.quit_game(timeout=0.5)
        self.assertIn("--kill", str(cm.exception))
        self.assertEqual(killed, [], "nothing killed without --kill")

        def fake_kill(pid, sig):
            killed.append((pid, sig))
            pids.clear()
        os.kill = fake_kill
        res = tf3ctl.quit_game(timeout=0.5, kill=True)
        self.assertEqual(res["how"], "kill")
        self.assertEqual(killed, [(123, tf3ctl.signal.SIGKILL)])
        self.assertIn("loading", res["quitProblem"])

    def test_quit_that_answers_but_does_not_end_the_game_is_killed_only_with_kill(self):
        pids = [5]
        tf3ctl.game_pids = lambda: list(pids)
        tf3ctl.send = lambda *a, **kw: {"ok": True}
        with self.assertRaises(tf3ctl.ToolError) as cm:
            tf3ctl.quit_game(timeout=0.6)
        self.assertIn("still running", str(cm.exception))
        os.kill = lambda pid, sig: pids.clear()
        self.assertEqual(tf3ctl.quit_game(timeout=0.6, kill=True)["how"], "kill")

    def test_kill_is_refused_during_an_upload_even_with_force(self):
        pids = [77]
        killed = []
        tf3ctl.game_pids = lambda: list(pids)
        os.kill = lambda pid, sig: killed.append(pid)
        # the mod refuses the quit: the upload is still Publishing
        tf3ctl.send = lambda *a, **kw: {"ok": False, "error": "quit the upload of staging mod x (command 5) is still "
                                                             "Publishing: refused until it has a result"}
        for force in (False, True):
            with self.assertRaises(tf3ctl.ToolError) as cm:
                tf3ctl.quit_game(timeout=0.3, kill=True, force=force)
            self.assertIn("not killed, not even with --force", str(cm.exception))
        # a publish mark is there, whatever the mod says (no answer at all here)

        def no_answer(*a, **kw):
            raise tf3ctl.ToolError("no answer")
        tf3ctl.send = no_answer
        tf3ctl.write_pending({"folder": "x"})
        try:
            with self.assertRaises(tf3ctl.ToolError) as cm:
                tf3ctl.quit_game(timeout=0.3, kill=True, force=True)
            self.assertIn("publish mark", str(cm.exception))
            # restart without --no-kill takes the same way
            ns = tf3ctl.make_parser().parse_args(["restart", "--force"])
            with self.assertRaises(tf3ctl.ToolError) as cm:
                tf3ctl.cmd_start(ns, True)
            self.assertIn("not even with --force", str(cm.exception))
        finally:
            os.remove(tf3ctl.pending_path())
        self.assertEqual(killed, [])
        # without either, the kill goes as before
        os.kill = lambda pid, sig: (killed.append(pid), pids.clear())
        self.assertEqual(tf3ctl.quit_game(timeout=0.3, kill=True)["how"], "kill")
        self.assertEqual(killed, [77])

    def test_kill_is_refused_while_another_client_used_the_game_recently(self):
        pids = [9]
        tf3ctl.game_pids = lambda: list(pids)
        tf3ctl.send = lambda *a, **kw: {"ok": False, "error": "busy"}
        os.kill = lambda pid, sig: pids.clear()
        tf3ctl.OWNER = "me"
        tf3ctl.note_activity(self.x, "bob", "run")
        with self.assertRaises(tf3ctl.ToolError) as cm:
            tf3ctl.quit_game(timeout=0.3, kill=True)
        self.assertIn("bob sent 'run'", str(cm.exception))
        self.assertEqual(pids, [9], "not killed")
        self.assertEqual(tf3ctl.quit_game(timeout=0.3, kill=True, force=True)["how"], "kill")
        pids.append(9)
        tf3ctl.note_activity(self.x, "me", "run")
        self.assertEqual(tf3ctl.quit_game(timeout=0.3, kill=True)["how"], "kill", "my own activity is no reason")

    def test_launch_reports_a_missing_steam_and_a_game_that_ends_at_once(self):
        tf3ctl.game_pids = lambda: []
        os.environ["TF3_STEAM"] = "/nonexistent/steam"
        try:
            with self.assertRaises(tf3ctl.ToolError) as cm:
                tf3ctl.launch_game(timeout=5)
            self.assertIn("cannot run", str(cm.exception))
            os.environ["TF3_STEAM"] = "true"
            os.environ["TF3_LOG"] = os.path.join(self.x, "stdout.txt")
            write(os.environ["TF3_LOG"], "")
            answers = iter([[], [77]])  # not running before the launch, then once; gone after that

            def came_and_went():
                return next(answers, [])
            tf3ctl.game_pids = came_and_went
            t0 = time.time()
            with self.assertRaises(tf3ctl.GameNotReady) as cm:
                tf3ctl.launch_game(timeout=30)
            self.assertIn("ended during startup", str(cm.exception))
            self.assertLess(time.time() - t0, 10, "at once, not after the timeout")
        finally:
            os.environ.pop("TF3_STEAM", None)

    def test_launch_keeps_the_last_game_log_before_starting(self):
        log = os.path.join(self.x, "crash_dump", "stdout.txt")
        os.makedirs(os.path.dirname(log))
        write(log, "last run's lines\n")
        os.utime(log, (1794890000, 1794890000))
        os.environ["TF3_LOG"] = log
        os.environ["TF3_STEAM"] = "/nonexistent/steam"
        tf3ctl.game_pids = lambda: []
        try:
            with self.assertRaises(tf3ctl.ToolError):  # the launch itself fails here, after the copy
                tf3ctl.launch_game(timeout=5)
        finally:
            os.environ.pop("TF3_STEAM", None)
            os.environ.pop("TF3_LOG", None)
        kept = glob.glob(os.path.join(self.x, "crash_dump", "logs", "stdout-*.txt"))
        self.assertEqual(len(kept), 1)
        self.assertEqual(os.path.basename(kept[0]),
                         "stdout-" + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(1794890000)) + ".txt", "named by the log's time")
        with open(kept[0]) as f:
            self.assertEqual(f.read(), "last run's lines\n")

    def test_keep_last_log_names_by_log_time_skips_repeats_and_keeps_the_newest(self):
        log = os.path.join(self.x, "stdout.txt")
        folder = os.path.join(self.x, "logs")
        self.assertIsNone(tf3ctl.keep_last_log(log), "no log yet")
        write(log, "")
        self.assertIsNone(tf3ctl.keep_last_log(log), "an empty log is not kept")
        for i in range(5):
            write(log, "run %d\n" % i)
            os.utime(log, (1794890000 + i * 60, 1794890000 + i * 60))
            tf3ctl.keep_last_log(log, keep=3)
        tf3ctl.keep_last_log(log, keep=3)  # the same run again (restart: quit, then launch): no second copy
        kept = sorted(os.listdir(folder))
        self.assertEqual(len(kept), 3, kept)
        name = lambda t: "stdout-" + time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(t)) + ".txt"
        self.assertEqual(kept, [name(1794890000 + i * 60) for i in (2, 3, 4)], "the two oldest went")

    def test_keep_last_log_never_stops_a_launch(self):
        log = os.path.join(self.x, "stdout.txt")
        write(log, "x")
        blocker = os.path.join(self.x, "logs")
        write(blocker, "a file where the folder should be")
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertIsNone(tf3ctl.keep_last_log(log))
        self.assertIn("could not keep", err.getvalue())

    def test_keep_log_command_copies_now_and_lists(self):
        log = os.path.join(self.x, "stdout.txt")
        write(log, "lines\n")
        os.environ["TF3_LOG"] = log
        try:
            res = tf3ctl.cmd_keep_log(tf3ctl.argparse.Namespace(list=False))
            self.assertTrue(res["kept"].endswith(".txt"))
            self.assertEqual(len(res["logs"]), 1)
            res = tf3ctl.cmd_keep_log(tf3ctl.argparse.Namespace(list=True))
            self.assertNotIn("kept", res)
            self.assertEqual(res["logs"][0]["bytes"], 6)
        finally:
            os.environ.pop("TF3_LOG", None)

    def test_launch_refuses_a_running_game(self):
        tf3ctl.game_pids = lambda: [1]
        with self.assertRaises(tf3ctl.ToolError) as cm:
            tf3ctl.launch_game(timeout=1)
        self.assertIn("restart", str(cm.exception))

    def _ns(self, **kw):
        base = dict(load=None, new=False, add=[], remove=[], set_mods=None, param=[], wait_for_start=False,
                    climate=None, generator=None, size=None, year=None, seed=None, no_towns=False,
                    no_industries=False)
        base.update(kw)
        return tf3ctl.argparse.Namespace(**base)

    def test_start_args(self):
        self.assertIsNone(tf3ctl.start_args(self._ns()), "launch only")
        cmd, args = tf3ctl.start_args(self._ns(load="probe", param=["m:k=2"], add=["m"]))
        self.assertEqual(cmd, "load")
        self.assertEqual(args, {"save": "probe", "mods": {"add": ["m"]}, "params": {"m": {"k": 2}}})
        cmd, args = tf3ctl.start_args(self._ns(new=True, year=1900, size="small", add=["a"]))
        self.assertEqual(cmd, "newgame")
        self.assertEqual(args, {"year": 1900, "size": "small", "mods": {"add": ["a"]},
                                "params": {"": {"guideSystemConfig.tutorial": 1}}}, "tutorial off by default")
        cmd, args = tf3ctl.start_args(self._ns(new=True, tutorial=True))
        self.assertNotIn("params", args, "--tutorial: the base default (On) stays")
        cmd, args = tf3ctl.start_args(self._ns(new=True, param=[":guideSystemConfig.tutorial=2", ":map.size=3"]))
        self.assertEqual(args["params"][""], {"guideSystemConfig.tutorial": 2, "map.size": 3}, "an explicit --param wins")
        cmd, args = tf3ctl.start_args(self._ns(new=True, param=["m:k=2"]))
        self.assertEqual(args["params"], {"m": {"k": 2}, "": {"guideSystemConfig.tutorial": 1}}, "other params kept")
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.start_args(self._ns(load="x", new=True))
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.start_args(self._ns(load="x", remove=[tf3ctl.SELF_MOD]))

    def test_newgame_command_starts_without_the_tutorial_too_but_not_its_list(self):
        ns = tf3ctl.argparse.Namespace(climate=None, generator=None, size="tiny", year=None, seed=None,
                                       no_towns=False, no_industries=False, list=False, set_mods=None,
                                       add=[], remove=[], param=[], dry_run=True, tutorial=False)
        self.assertEqual(tf3ctl.newgame_args(ns)["params"], {"": {"guideSystemConfig.tutorial": 1}})
        ns.list = True
        self.assertNotIn("params", tf3ctl.newgame_args(ns), "--list sends no params")

    def test_notification_log_goes_by_its_event_not_a_tool_push(self):
        ns = tf3ctl.argparse.Namespace
        mod = "/game_mechanics/notifications/gui/notification_log.tl"
        self.assertEqual(tf3ctl.tool_event(ns(name=None, module=mod, field=None, close=False)),
                         {"name": "openNotificationLog"})
        self.assertEqual(tf3ctl.tool_event(ns(name="notifications", module=None, field=None, close=True)),
                         {"name": "closeNotificationLog"})
        self.assertIsNone(tf3ctl.tool_event(ns(name="music", module=None, field=None, close=False)))
        self.assertIsNone(tf3ctl.tool_event(ns(name=None, module="/m.tl", field=None, close=False)))

    def test_script_event_args(self):
        ns = lambda **k: tf3ctl.argparse.Namespace(**k)
        self.assertEqual(tf3ctl.script_event_args(ns(name="industry_upgrades.apply", id="hummer_age_of_mobility",
                                                     param='{"construction": 9, "step": 3}')),
                         {"name": "industry_upgrades.apply", "id": "hummer_age_of_mobility",
                          "param": {"construction": 9, "step": 3}})
        self.assertEqual(tf3ctl.script_event_args(ns(name="x", id="m", param=None)), {"name": "x", "id": "m"})
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.script_event_args(ns(name="x", id="", param=None))
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.script_event_args(ns(name="x", id="m", param="[1]"))
        self.assertIn("scriptEvent", tf3ctl.CHANGES_GAME)

    def test_script_event_main_sends_script_event(self):
        sent = []

        def fake_send(cmd, args=None, timeout=20, **kw):
            sent.append((cmd, args))
            return {"ok": True}
        tf3ctl.send = fake_send
        with contextlib.redirect_stdout(io.StringIO()):
            code = tf3ctl.main(["script-event", "industry_upgrades.apply", "--id", "hummer_age_of_mobility",
                                "--param", '{"step": 3}'])
        self.assertEqual(code, 0)
        self.assertEqual(sent, [("scriptEvent", {"name": "industry_upgrades.apply", "id": "hummer_age_of_mobility",
                                                 "param": {"step": 3}})])

    def test_rename_args_and_main(self):
        ns = tf3ctl.argparse.Namespace
        self.assertEqual(tf3ctl.rename_args(ns(entity=48064, name="Chesham")), {"entity": 48064, "name": "Chesham"})
        for bad in (dict(entity=-1, name="x"), dict(entity=1, name="  "), dict(entity=1, name="")):
            with self.assertRaises(tf3ctl.ToolError):
                tf3ctl.rename_args(ns(**bad))
        self.assertIn("rename", tf3ctl.CHANGES_GAME)
        sent = []

        def fake_send(cmd, args=None, timeout=20, **kw):
            sent.append((cmd, args))
            return {"ok": True}
        tf3ctl.send = fake_send
        with contextlib.redirect_stdout(io.StringIO()):
            code = tf3ctl.main(["rename", "Petworth", "--entity", "48118"])
        self.assertEqual(code, 0)
        self.assertEqual(sent, [("rename", {"entity": 48118, "name": "Petworth"})])

    def test_parcels_args_and_main(self):
        def ns(**kw):
            base = dict(edge=None, rect=None, list=None)
            base.update(kw)
            return tf3ctl.argparse.Namespace(**base)
        self.assertEqual(tf3ctl.parcels_args(ns(edge=10)), {"edge": 10})
        self.assertEqual(tf3ctl.parcels_args(ns(edge=10, list=False)), {"edge": 10, "list": False})
        self.assertEqual(tf3ctl.parcels_args(ns(rect="-10,0,100,50.5")), {"rect": [-10.0, 0.0, 100.0, 50.5]})
        self.assertEqual(tf3ctl.parcels_args(ns(rect="0,0,1,1", list=True)), {"rect": [0.0, 0.0, 1.0, 1.0], "list": True})
        m = tf3ctl.PARCELS_RECT_MAX
        self.assertEqual(tf3ctl.parcels_args(ns(rect="0,0,%d,%d" % (m, m)))["rect"][2], m)
        for bad in (dict(), dict(edge=1, rect="0,0,1,1"), dict(edge=-1), dict(rect="0,0,1"), dict(rect="a,0,1,1"),
                    dict(rect="0,0,1,nan"), dict(rect="0,0,%d,1" % (m + 1)), dict(rect="0,0,1,1,1")):
            with self.assertRaises(tf3ctl.ToolError, msg=bad):
                tf3ctl.parcels_args(ns(**bad))
        self.assertNotIn("parcels", tf3ctl.CHANGES_GAME)
        sent = []

        def fake_send(cmd, args=None, timeout=20, **kw):
            sent.append((cmd, args))
            return {"ok": True}
        tf3ctl.send = fake_send
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(tf3ctl.main(["parcels", "--edge", "12"]), 0)
            self.assertEqual(tf3ctl.main(["parcels", "--rect=-5,-5,5,5", "--list"]), 0)
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(tf3ctl.main(["parcels", "--rect", "0,0,9999,1"]), 2, "refused before sending")
            with self.assertRaises(SystemExit):
                tf3ctl.main(["parcels"])
        self.assertEqual(sent, [("parcels", {"edge": 12}), ("parcels", {"rect": [-5.0, -5.0, 5.0, 5.0], "list": True})])

    def test_lanes_args_and_main(self):
        parse = tf3ctl.make_parser().parse_args

        def args(*a):
            return tf3ctl.lanes_args(parse(["lanes"] + list(a)))
        self.assertEqual(args("--edge", "9010"), {"edges": [9010]})
        self.assertEqual(args("--edge", " 1, 2 ", "--no-network"), {"edges": [1, 2], "network": False})
        too_many = ",".join(str(i) for i in range(tf3ctl.EDGE_LANES_MAX + 1))
        for bad in (["--edge", "a"], ["--edge", ""], ["--edge", "1,,2"], ["--edge=-1"], ["--edge", "1.5"],
                    ["--edge", too_many]):
            with self.assertRaises(tf3ctl.ToolError, msg=bad):
                args(*bad)
        self.assertNotIn("edgeLanes", tf3ctl.CHANGES_GAME)
        self.assertFalse(tf3ctl.changes_game("edgeLanes", {"edges": [1]}))
        self.assertEqual(tf3ctl.around_args(parse(["around", "--at", "1,2", "--lanes"])), {"at": [1.0, 2.0], "lanes": True})
        sent = []

        def fake_send(cmd, args=None, timeout=20, **kw):
            sent.append((cmd, args))
            return {"ok": True}
        tf3ctl.send = fake_send
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(tf3ctl.main(["lanes", "--edge", "5,6"]), 0)
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(tf3ctl.main(["lanes", "--edge", "x"]), 2, "refused before sending")
        self.assertEqual(sent, [("edgeLanes", {"edges": [5, 6]})])

    def test_around_args_and_main(self):
        parse = tf3ctl.make_parser().parse_args

        def args(*a):
            return tf3ctl.around_args(parse(["around"] + list(a)))
        self.assertEqual(args("--at=-10,20.5"), {"at": [-10.0, 20.5]})
        self.assertEqual(args("--at", "1,2", "--radius", "50", "--kinds", " station, field ", "--limit", "5"),
                         {"at": [1.0, 2.0], "radius": 50.0, "kinds": "station,field", "limit": 5})
        self.assertEqual(args("--at", "1,2", "--kinds", "all")["kinds"], "all")
        for bad in (["--at", "1"], ["--at", "a,b"], ["--at", "1,2,3"], ["--at", "nan,1"], ["--at", "1,2", "--radius", "0"],
                    ["--at", "1,2", "--radius", str(tf3ctl.AROUND_RADIUS_MAX + 1)], ["--at", "1,2", "--kinds", "house"],
                    ["--at", "1,2", "--kinds", ","], ["--at", "1,2", "--limit", "0"]):
            with self.assertRaises(tf3ctl.ToolError, msg=bad):
                args(*bad)
        self.assertNotIn("around", tf3ctl.CHANGES_GAME)
        self.assertFalse(tf3ctl.changes_game("around", {"at": [0, 0]}))
        sent = []

        def fake_send(cmd, args=None, timeout=20, **kw):
            sent.append((cmd, args))
            return {"ok": True}
        tf3ctl.send = fake_send
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(tf3ctl.main(["around", "--at=-5,5", "--radius", "30"]), 0)
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(tf3ctl.main(["around", "--at", "0,0", "--kinds", "nope"]), 2, "refused before sending")
        self.assertEqual(sent, [("around", {"at": [-5.0, 5.0], "radius": 30.0})])

    # fit: a town's edge as around lists it: a street along y = 0 (x -100..100), a house of town 700 (its
    # TOWN_BUILDING 601 and construction 602) at x 20..35, y 10..25, a field at x 60..140, y 30..90, the town's
    # own box over all of it, and a person walking (moving: never in the way)
    FIT_SCENE = [
        {"id": 501, "kind": "street", "from": {"x": -100, "y": 0}, "to": {"x": 100, "y": 0}, "halfWidth": 6,
         "box": {"x0": -100, "y0": -4, "x1": 100, "y1": 4}, "x": 0, "y": 0},
        {"id": 601, "kind": "town_building", "construction": 602, "town": 700, "townName": "Chesham",
         "box": {"x0": 20, "y0": 10, "x1": 35, "y1": 25}, "x": 27.5, "y": 17.5},
        {"id": 602, "kind": "town_building", "fileName": "building/res.con", "building": 601,
         "box": {"x0": 20, "y0": 10, "x1": 35, "y1": 25}, "x": 27.5, "y": 17.5},
        {"id": 604, "kind": "field", "box": {"x0": 60, "y0": 30, "x1": 140, "y1": 90}, "x": 100, "y": 60},
        {"id": 700, "kind": "town", "box": {"x0": -500, "y0": -500, "x1": 500, "y1": 500}, "x": 0, "y": 0},
        {"id": 606, "kind": "moving", "box": {"x0": 0, "y0": 20, "x1": 1, "y1": 21}, "x": 0.5, "y": 20.5},
    ]

    def test_fit_geometry(self):
        r = tf3ctl.fit_rect(10, 20, math.pi / 2, (-1, -2, 1, 2))
        self.assertAlmostEqual(r[0][0], 12); self.assertAlmostEqual(r[0][1], 19)
        sq = [(0, 0), (10, 0), (10, 10), (0, 10)]
        self.assertTrue(tf3ctl.fit_polys_overlap(sq, [(5, 5), (15, 5), (15, 15), (5, 15)]))
        self.assertFalse(tf3ctl.fit_polys_overlap(sq, [(10, 0), (20, 0), (20, 10), (10, 10)]), "touching")
        self.assertTrue(tf3ctl.fit_polys_overlap(sq, [(10.2, 0), (20, 0), (20, 10), (10.2, 10)], margin=0.5),
                        "closer than the room kept")
        self.assertFalse(tf3ctl.fit_polys_overlap(sq, [(10.6, 0), (20, 0), (20, 10), (10.6, 10)], margin=0.5))
        diamond = [(15, 5), (20, 0), (25, 5), (20, 10)]
        self.assertFalse(tf3ctl.fit_polys_overlap(sq, diamond))
        self.assertEqual(tf3ctl.fit_poly_seg_dist(sq, (5, 5), (50, 5)), 0.0, "an end inside")
        self.assertEqual(tf3ctl.fit_poly_seg_dist(sq, (-5, 5), (15, 5)), 0.0, "through it")
        self.assertAlmostEqual(tf3ctl.fit_poly_seg_dist(sq, (-5, 13), (15, 13)), 3.0)
        self.assertAlmostEqual(tf3ctl.fit_seg_dist((5, 3), (0, 0), (10, 0)), 3.0)
        x, y = tf3ctl.fit_to_world(0, 0, math.pi / 2, 0, -10)
        self.assertAlmostEqual(x, 10); self.assertAlmostEqual(y, 0)

    def test_fit_obstacles_houses_and_nodes(self):
        obs = tf3ctl.fit_obstacles(self.FIT_SCENE)
        self.assertEqual(sorted(o["id"] for o in obs), [501, 601, 604], "the town, the person and the house's "
                         "construction (its TOWN_BUILDING is there) left out")
        self.assertEqual(next(o for o in obs if o["id"] == 501)["line"][2], 6)
        self.assertEqual(tf3ctl.fit_houses(self.FIT_SCENE), [(27.5, 17.5)])
        self.assertEqual(tf3ctl.fit_join_nodes(self.FIT_SCENE), {(-100, 0): [501], (100, 0): [501]})
        owned = [dict(self.FIT_SCENE[0], construction=900)]
        self.assertEqual(tf3ctl.fit_join_nodes(owned), {}, "a construction's own piece is no road end to join")

    def test_fit_ignores_the_maps_own_boxes_and_the_town(self):
        # as a game's around answered 2026-11-23: entity 2 (kind other, 14,336 m square) met every place, and the
        # town 4835 (180 m square) was listed too; map from a mod that names it, and a map-sized box of another kind
        huge = {"x0": -7168, "y0": -7168, "x1": 7168, "y1": 7168}
        scene = self.FIT_SCENE + [
            {"id": 2, "kind": "other", "box": dict(huge), "x": 0, "y": 0},
            {"id": 3, "kind": "model", "box": dict(huge), "x": 0, "y": 0},
            {"id": 4, "kind": "map", "box": dict(huge), "x": 0, "y": 0},
            {"id": 4835, "kind": "town", "box": {"x0": -90, "y0": -90, "x1": 90, "y1": 90}, "x": 0, "y": 0},
            # large, but no map (an airport): still in the way
            {"id": 9, "kind": "construction", "box": {"x0": 500, "y0": 500, "x1": 2300, "y1": 1900}, "x": 1400, "y": 1200},
        ]
        ids = sorted(o["id"] for o in tf3ctl.fit_obstacles(scene))
        self.assertEqual(ids, [9, 501, 601, 604])
        res = tf3ctl.fit_search(scene, (-5, -5, 5, 5), (0, 40), 10, (0.0,), step=2)
        self.assertEqual(res["candidates"][0]["offset"], 0, "the free point itself, as without them")
        self.assertNotIn(2, [b["id"] for b in res["blockers"]])
        self.assertNotIn(4835, [b["id"] for b in res["blockers"]])
        self.assertIn("map", tf3ctl.AROUND_KINDS)

    def test_fit_search_grid_nearest_free_place(self):
        box = (-5, -5, 5, 5)  # 10 m square round its origin
        # wanted on the house: the nearest free place, never on the street or the house
        res = tf3ctl.fit_search(self.FIT_SCENE, box, (27.5, 17.5), 40, (0.0,), step=1)
        c = res["candidates"][0]
        poly = tf3ctl.fit_rect(c["x"], c["y"], c["angle"], box)
        self.assertFalse(tf3ctl.fit_polys_overlap(poly, [(20, 10), (35, 10), (35, 25), (20, 25)]))
        self.assertGreaterEqual(min(p[1] for p in poly), 6 - 1e-9, "clear of the street's half width")
        self.assertLessEqual(c["offset"], 14.0, "the house is 15 m a side: 7.5 + 0.5 + 5 m out at most a step more")
        for a, b in zip(res["candidates"], res["candidates"][1:]):
            self.assertLessEqual(a["offset"], b["offset"])
        self.assertEqual(res["blockers"][0]["id"], 601, "the house is what stood in the way most")
        self.assertIn("roadDist", c)
        # a free point: itself, offset 0
        res = tf3ctl.fit_search(self.FIT_SCENE, box, (0, 40), 10, (0.0,), step=2)
        self.assertEqual(res["candidates"][0]["offset"], 0)
        # nowhere: a box larger than the gap, in a small radius -> no candidate, and what is in the way
        res = tf3ctl.fit_search(self.FIT_SCENE, (-60, -60, 60, 60), (27.5, 17.5), 10, (0.0,), step=2)
        self.assertEqual(res["candidates"], [])
        self.assertTrue(res["blockers"]); self.assertGreater(res["tried"], 0)

    def test_fit_search_mouth_kept_off_the_road_end_with_a_link_and_houses(self):
        # a depot 10 x 20 with its mouth on its -y face: never on the street's free end (100, 0) (a mouth on a dead
        # end's node was refused in a game, 2026-11-23), but a link's length straight out of its face from it
        box, mouth = (-5, -10, 5, 10), (0, -10)
        res = tf3ctl.fit_search(self.FIT_SCENE, box, (100, 15), 60, tf3ctl.FIT_ANGLES_JOIN, mouth=mouth)
        self.assertTrue(res["candidates"])
        c = res["candidates"][0]
        self.assertNotIn("joinAt", c)
        lk = c["link"]
        self.assertEqual(lk["on"], "node"); self.assertEqual(lk["to"], [100, 0]); self.assertEqual(lk["pieces"], [501])
        mx, my = tf3ctl.fit_to_world(c["x"], c["y"], c["angle"], *mouth)
        self.assertAlmostEqual(mx, lk["from"][0], places=2); self.assertAlmostEqual(my, lk["from"][1], places=2)
        self.assertAlmostEqual(math.hypot(lk["to"][0] - mx, lk["to"][1] - my), lk["length"], places=2)
        lo, hi = tf3ctl.FIT_LINK_DEFAULT
        self.assertGreaterEqual(lk["length"], lo); self.assertLessEqual(lk["length"], hi)
        # straight out of its face: the way from the mouth to the road is the face's way out, turned
        ox, oy = tf3ctl.fit_to_world(0, 0, c["angle"], 0, -1)
        self.assertAlmostEqual((lk["to"][0] - mx) / lk["length"], ox, places=6)
        self.assertAlmostEqual((lk["to"][1] - my) / lk["length"], oy, places=6)
        # the box clear of the whole street (no piece drawn back for a mouth on it)
        poly = tf3ctl.fit_rect(c["x"], c["y"], c["angle"], box)
        self.assertGreaterEqual(tf3ctl.fit_poly_seg_dist(poly, (-100, 0), (100, 0)), 6.5 - 1e-9)
        # every candidate's link: off the node, at 30 degrees or more from the street at it
        for x in res["candidates"]:
            if x["link"]["on"] == "node" and x["link"]["to"] == [100, 0]:
                d = (x["link"]["from"][0] - 100, x["link"]["from"][1])
                self.assertGreaterEqual(tf3ctl._fit_angle_between(d, (-1, 0)), tf3ctl.FIT_LINK_NODE_ANGLE - 1e-4)
        # houses: at least 1 within 40 m of the centre of a 10 m square, wanted north of the street
        res = tf3ctl.fit_search(self.FIT_SCENE, (-5, -5, 5, 5), (0, 40), 30, (0.0,), step=2, houses=1, catchment=40)
        c = res["candidates"][0]
        self.assertGreaterEqual(c["houses"], 1)
        self.assertLessEqual(math.hypot(c["centre"]["x"] - 27.5, c["centre"]["y"] - 17.5), 40)
        res = tf3ctl.fit_search(self.FIT_SCENE, (-5, -5, 5, 5), (0, 40), 30, (0.0,), step=2, houses=2, catchment=40)
        self.assertEqual(res["candidates"], [], "only one house there")

    def test_fit_link_pure_functions(self):
        self.assertEqual(tf3ctl.fit_mouth_normal((-5, -35, 5, 5), (0, -35)), (0.0, -1.0))
        self.assertEqual(tf3ctl.fit_mouth_normal((-5, -35, 5, 5), (6, 0)), (1.0, 0.0))
        # a box that stops short of its mouth (outside it, nearer a side's line): the side it is beyond
        self.assertEqual(tf3ctl.fit_mouth_normal((-8, -25, 8, 10), (0, -35)), (0.0, -1.0))
        self.assertEqual(tf3ctl.fit_mouth_normal((-8, -25, 8, 10), (-9, -40)), (0.0, -1.0), "farthest beyond")
        self.assertAlmostEqual(tf3ctl.fit_seg_seg_dist((0, 0), (10, 0), (0, 3), (10, 3)), 3.0)
        self.assertEqual(tf3ctl.fit_seg_seg_dist((0, 0), (10, 0), (5, -1), (5, 1)), 0.0, "crossing")
        # a ray straight down from (50, 20) onto a street along y = 0 (x 0..100): 20 m, square to it
        on = tf3ctl.fit_link_on_edge((50, 20), (0, -1), (0, 0), (100, 0), 8, 40)
        self.assertEqual(on[0], (50.0, 0.0)); self.assertAlmostEqual(on[1], 20.0)
        self.assertIsNone(tf3ctl.fit_link_on_edge((50, 5), (0, -1), (0, 0), (100, 0), 8, 40), "too short")
        self.assertIsNone(tf3ctl.fit_link_on_edge((50, 60), (0, -1), (0, 0), (100, 0), 8, 40), "too far")
        self.assertIsNone(tf3ctl.fit_link_on_edge((50, 20), (0, 1), (0, 0), (100, 0), 8, 40), "pointing away")
        self.assertIsNone(tf3ctl.fit_link_on_edge((50, 20), (1, 0), (0, 0), (100, 0), 8, 40), "along it")
        sh = (math.cos(math.radians(-20)), math.sin(math.radians(-20)))  # 20 degrees across: too shallow
        self.assertIsNone(tf3ctl.fit_link_on_edge((10, 10 * math.tan(math.radians(20))), sh, (0, 0), (100, 0), 1, 80))
        self.assertIsNone(tf3ctl.fit_link_on_edge((2, 20), (0, -1), (0, 0), (100, 0), 8, 40), "by its end: the node's")
        self.assertIsNone(tf3ctl.fit_link_on_edge((0, 20), (0, -1), (0, 0), (0, 0), 8, 40), "a piece of no length")
        # nodes: the pieces at each end, and the way along them out of it
        t = tf3ctl.fit_link_targets(self.FIT_SCENE)
        self.assertEqual(t["nodes"], [((-100, 0), [(501, (200, 0))]), ((100, 0), [(501, (-200, 0))])])
        self.assertEqual(t["edges"], [(501, (-100, 0), (100, 0), 6.0)])
        self.assertTrue(tf3ctl.fit_link_ok_at_node((1, 0), [(501, (-1, 0))]), "straight on from a dead end")
        self.assertFalse(tf3ctl.fit_link_ok_at_node((-1, 0.2), [(501, (-1, 0))]), "back along the street")
        self.assertTrue(tf3ctl.fit_link_ok_at_node((0, 1), [(501, (-1, 0)), (502, (1, 0))]), "square into a road")
        sharp = (math.cos(math.radians(150)), math.sin(math.radians(150)))  # 30 degrees off the piece going west
        self.assertFalse(tf3ctl.fit_link_ok_at_node(sharp, [(501, (-1, 0))]), "their widths would overlap")
        # the link road kept clear: a house in its way, the piece it joins skipped
        obs = tf3ctl.fit_obstacles(self.FIT_SCENE)
        house = tf3ctl.fit_link_clear((27.5, 40), (27.5, 0), 3, obs, {501}, 0.5)
        self.assertEqual(house["id"], 601)
        self.assertIsNone(tf3ctl.fit_link_clear((-50, 30), (-50, 0), 3, obs, {501}, 0.5))
        self.assertEqual(tf3ctl.fit_link_clear((-50, 30), (-50, 0), 3, obs, set(), 0.5)["id"], 501,
                         "the street it joins is in the way when not skipped")
        self.assertEqual(tf3ctl.fit_link_road({"from": [108.0, 0.0], "to": [100, 0]}),
                         "road --from=108.0,0.0 --to=100,0 --snap 3")
        self.assertEqual(tf3ctl.fit_link_road({"from": [-72.5, 1250.25], "to": [-80.123456, 1210]}),
                         "road --from=-72.5,1250.25 --to=-80.123,1210 --snap 3")

    def test_fit_link_onto_a_pieces_middle_when_no_node_will_do(self):
        # a long street (x -300..300) with its nodes far off: the link ends on its middle, square to it
        scene = [{"id": 801, "kind": "street", "from": {"x": -300, "y": 0}, "to": {"x": 300, "y": 0}, "halfWidth": 5,
                  "x": 0, "y": 0}]
        box, mouth = (-5, -35, 5, 5), (0, -35)
        res = tf3ctl.fit_search(scene, box, (0, 60), 50, tf3ctl.FIT_ANGLES_JOIN, mouth=mouth)
        self.assertEqual(res["candidates"], [], "a piece's middle only when asked (--link-edge)")
        res = tf3ctl.fit_search(scene, box, (0, 60), 50, tf3ctl.FIT_ANGLES_JOIN, mouth=mouth, link_edges=True)
        c = res["candidates"][0]
        lk = c["link"]
        self.assertEqual(lk["on"], "edge"); self.assertEqual(lk["pieces"], [801])
        self.assertAlmostEqual(lk["to"][1], 0.0, places=6)
        self.assertGreaterEqual(lk["length"], tf3ctl.FIT_LINK_DEFAULT[0])
        self.assertTrue(all(x["link"]["on"] == "edge" for x in res["candidates"]))
        # nodes before middles: a free dead end near makes the first candidates node links
        scene.append({"id": 802, "kind": "street", "from": {"x": 40, "y": 0}, "to": {"x": 40, "y": 30}, "halfWidth": 5,
                      "x": 40, "y": 15})
        res = tf3ctl.fit_search(scene, box, (0, 60), 50, tf3ctl.FIT_ANGLES_JOIN, mouth=mouth, link_edges=True)
        self.assertEqual(res["candidates"][0]["link"]["on"], "node")
        # --link: shorter than its MIN never
        res = tf3ctl.fit_search(scene, box, (0, 60), 50, tf3ctl.FIT_ANGLES_JOIN, mouth=mouth, link=(20, 25))
        self.assertTrue(res["candidates"])
        self.assertTrue(all(20 - 1e-9 <= x["link"]["length"] <= 25 + 1e-9 for x in res["candidates"]))
        # a track's mouth: on its end, as before (no link)
        rails = [dict(e, kind="track") for e in self.FIT_SCENE if e["kind"] == "street"]
        res = tf3ctl.fit_search(rails, (-5, -10, 5, 10), (100, 15), 60, tf3ctl.FIT_ANGLES_JOIN, mouth=(0, -10),
                                track=True)
        self.assertIn("joinAt", res["candidates"][0]); self.assertNotIn("link", res["candidates"][0])

    def test_fit_command_flow(self):
        calls = []
        scene = self.FIT_SCENE

        def sender(cmd, args=None, timeout=20, **kw):
            calls.append((cmd, dict(args or {})))
            if cmd == "around":
                return {"ok": True, "entities": scene, "ms": {"total": 3}}
            if not args.get("dryRun") or not args.get("engineCheck"):
                raise AssertionError("fit only asks dry runs with the engine's check")
            if "angle" in args and args["at"] == [27.5, 17.5] and args["angle"] == 0.0 and len(calls) == 1:
                return {"ok": True, "footprint": {"x0": -5, "y0": -5, "x1": 5, "y1": 5}, "buildable": False}
            # the engine refuses the first place offered, takes the second
            n = sum(1 for c in calls if c[0] == "build")
            if n == 2:
                return {"ok": False, "error": "the engine would refuse it: Collision", "hits": [{"id": 9}]}
            return {"ok": True, "buildable": True, "verdict": "buildable", "cost": 100}
        p = tf3ctl.make_parser()
        ns = p.parse_args(["fit", "--res", "::/depots/road/road_depot.con", "--at", "27.5,17.5", "--radius", "40",
                           "--angle", "0", "--step", "1"])
        out = tf3ctl.cmd_fit(ns, sender=sender)
        self.assertTrue(out["ok"], out)
        self.assertEqual(out["boxFrom"], "the engine's check at the point, unturned")
        self.assertEqual([c[0] for c in calls], ["build", "around", "build", "build"])
        self.assertEqual(out["refusedFirst"][0]["hits"], [{"id": 9}])
        self.assertTrue(out["build"].startswith("build --res ::/depots/road/road_depot.con --at="))
        self.assertEqual(calls[1][1]["at"], [27.5, 17.5])
        # --size and --check 0: no engine at all (read only)
        calls.clear()
        ns = p.parse_args(["fit", "--res", "x.con", "--at", "0,40", "--size", "10,10", "--check", "0"])
        out = tf3ctl.cmd_fit(ns, sender=sender)
        self.assertEqual([c[0] for c in calls], ["around"]); self.assertEqual(out["checked"], False)
        self.assertEqual(out["place"]["offset"], 0)
        # no place: ok false with what is in the way
        calls.clear()
        ns = p.parse_args(["fit", "--res", "x.con", "--at", "27.5,17.5", "--size", "120,120", "--radius", "10",
                           "--angle", "0"])
        out = tf3ctl.cmd_fit(ns, sender=sender)
        self.assertFalse(out["ok"]); self.assertIn("no free place", out["error"])
        self.assertEqual([c[0] for c in calls], ["around"], "nothing asked of the engine for no place")
        # bad arguments
        for bad in (["--at", "1"], ["--at", "0,0", "--radius", "0"], ["--at", "0,0", "--size", "0,1"],
                    ["--at", "0,0", "--check", "0"], ["--at", "0,0", "--houses", "0"], ["--at", "0,0", "--step", "0.1"],
                    ["--at", "0,0", "--params", "[1]"], ["--at", "0,0", "--mouth", "1"]):
            with self.assertRaises(tf3ctl.ToolError, msg=bad):
                tf3ctl.fit_plan(p.parse_args(["fit", "--res", "x.con"] + bad))
        self.assertNotIn("fit", tf3ctl.CHANGES_GAME)
        self.assertTrue(tf3ctl.changes_game("build", {"res": "x", "dryRun": True, "engineCheck": True}))

    def test_fit_command_with_a_mouth_answers_the_link_road(self):
        p = tf3ctl.make_parser()
        calls = []
        depot = {"id": 32760, "kind": "depot", "fileName": "depots/road/road_depot.con", "x": -500, "y": -500,
                 "box": {"x0": -505, "y0": -535, "x1": -495, "y1": -495},
                 "mouths": [{"kind": "mouth", "node": 9, "track": False, "local": {"dx": 0, "dy": -35}}]}
        scene = self.FIT_SCENE + [depot]

        def sender(cmd, args=None, timeout=20, **kw):
            calls.append((cmd, dict(args or {})))
            if cmd == "around":
                return {"ok": True, "entities": scene}
            return {"ok": True, "buildable": True, "verdict": "buildable"}
        ns = p.parse_args(["fit", "--res", "road_depot", "--at", "100,15", "--radius", "60", "--size", "10,20",
                           "--mouth", "0,-10"])
        out = tf3ctl.cmd_fit(ns, sender=sender)
        self.assertTrue(out["ok"], out)
        lk = out["link"]
        self.assertEqual(lk, out["place"]["link"]); self.assertEqual(lk["to"], [100, 0])
        self.assertEqual(out["road"], tf3ctl.fit_link_road(lk))
        self.assertIn("--snap 3", out["road"]); self.assertIn("build first", out["roadNote"])
        rp = tf3ctl.road_args(p.parse_args(shlex.split(out["road"])))
        self.assertEqual(rp["from"], lk["from"]); self.assertEqual(rp["to"], [100.0, 0.0]); self.assertEqual(rp["snap"], 3)
        self.assertNotIn("mouthHint", out, "a mouth given: no hint")
        # the link's length made the list around asked wider
        self.assertGreaterEqual(calls[0][1]["radius"], 60 + tf3ctl.FIT_LINK_DEFAULT[1])
        # no --mouth: as before (no link), with a hint from the same construction standing near
        calls.clear()
        ns = p.parse_args(["fit", "--res", "road_depot", "--at", "0,40", "--size", "10,10", "--angle", "0"])
        out = tf3ctl.cmd_fit(ns, sender=sender)
        self.assertTrue(out["ok"], out); self.assertNotIn("link", out); self.assertNotIn("road", out)
        self.assertEqual(out["mouthHint"]["mouth"], "0,-35"); self.assertEqual(out["mouthHint"]["from"], 32760)
        self.assertIsNone(tf3ctl.fit_mouth_hint(scene, "::/depots/road/tram_depot.con"))
        self.assertIsNotNone(tf3ctl.fit_mouth_hint(scene, "::/depots/road/road_depot.con"))
        # an edge link: its note says the piece's middle is not checked
        long_street = [{"id": 801, "kind": "street", "from": {"x": -300, "y": 0}, "to": {"x": 300, "y": 0},
                        "halfWidth": 5, "x": 0, "y": 0}]
        scene[:] = long_street
        ns = p.parse_args(["fit", "--res", "road_depot", "--at", "0,60", "--radius", "50", "--size", "10,40,0,-15",
                           "--mouth", "0,-35"])
        out = tf3ctl.cmd_fit(ns, sender=sender)
        self.assertFalse(out["ok"], "no node near, and no --link-edge")
        self.assertIn("no free place", out["error"])
        ns = p.parse_args(["fit", "--res", "road_depot", "--at", "0,60", "--radius", "50", "--size", "10,40,0,-15",
                           "--mouth", "0,-35", "--link-edge"])
        out = tf3ctl.cmd_fit(ns, sender=sender)
        self.assertTrue(out["ok"], out); self.assertEqual(out["link"]["on"], "edge")
        self.assertIn("middle of piece 801", out["roadNote"])
        # bad --link
        for bad in (["--link", "8,40"], ["--mouth", "0,-35", "--link", "1,40"], ["--mouth", "0,-35", "--link", "40,8"],
                    ["--mouth", "0,-35", "--link", "8"], ["--mouth", "0,-35", "--track", "--link", "8,40"],
                    ["--link-edge"], ["--mouth", "0,-35", "--track", "--link-edge"]):
            with self.assertRaises(tf3ctl.ToolError, msg=bad):
                tf3ctl.fit_plan(p.parse_args(["fit", "--res", "x.con", "--at", "0,0"] + bad))
        self.assertEqual(tf3ctl.fit_plan(p.parse_args(["fit", "--res", "x.con", "--at", "0,0", "--mouth", "0,-35",
                                                        "--link", "6,20"]))[-1], (6.0, 20.0))

    def test_fit_doubts_unchecked_cut_short_and_too_few_houses(self):
        p = tf3ctl.make_parser()
        scene = self.FIT_SCENE

        def make(answers):
            calls = []

            def sender(cmd, args=None, timeout=20, **kw):
                calls.append(cmd)
                if cmd == "around":
                    return {"ok": True, "entities": scene}
                return answers.pop(0)
            return sender, calls
        ns = p.parse_args(["fit", "--res", "x.con", "--at", "0,40", "--size", "10,10", "--angle", "0", "--check", "3"])
        # a warning (in the engine's own context) or buildings it would take: not taken, the next place asked
        sender, calls = make([{"ok": True, "buildable": True, "warnings": ["3 fields will be removed"]},
                              {"ok": True, "buildable": True, "buildingsInWay": [601]},
                              {"ok": True, "buildable": True, "verdict": "buildable"}])
        out = tf3ctl.cmd_fit(ns, sender=sender)
        self.assertTrue(out["ok"], out)
        self.assertEqual(len(out["refusedFirst"]), 2)
        self.assertIn("warnings", out["refusedFirst"][0]["error"])
        self.assertEqual(out["refusedFirst"][1]["buildingsInWay"], [601])
        # infos only: refused by this mod (buildable false, its own error), and an older mod's buildable with infos
        # not taken either (the engine refuses such a build, 2026-11-23); the third place taken
        sender, calls = make([{"ok": False, "buildable": False, "verdict": "refused", "infos": ["陸上に配置"],
                               "infosRefusal": True, "error": "the engine would refuse it: 陸上に配置 (errorState.infos"},
                              {"ok": True, "buildable": True, "verdict": "buildable", "infos": ["海岸線に配置"]},
                              {"ok": True, "buildable": True, "verdict": "buildable"}])
        out = tf3ctl.cmd_fit(ns, sender=sender)
        self.assertTrue(out["ok"], out)
        self.assertEqual(len(out["refusedFirst"]), 2)
        self.assertIn("陸上に配置", out["refusedFirst"][0]["error"])
        self.assertIn("infos (海岸線に配置)", out["refusedFirst"][1]["error"])
        # the engine could not be asked: said so, not "refused"
        sender, calls = make([{"ok": True, "checked": False, "engineCheck": "not available: x"}])
        out = tf3ctl.cmd_fit(ns, sender=sender)
        self.assertFalse(out["ok"]); self.assertIn("could not be asked", out["error"])
        self.assertEqual(calls, ["around", "build"])
        # cut short: the error names how far it went, not the radius
        res = tf3ctl.fit_search(scene, (-60, -60, 60, 60), (27.5, 17.5), 100, (0.0,), step=1, most=50)
        self.assertFalse(res["complete"]); self.assertEqual(res["tried"], 50); self.assertLess(res["searched"], 10)
        self.assertEqual(res["candidates"], [])
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.fit_search(scene, (-1, -1, 1, 1), (0, 0), 1000, (0.0,), step=0.5)
        # free but too few houses: said apart from "in the way"
        ns = p.parse_args(["fit", "--res", "x.con", "--at", "0,40", "--size", "10,10", "--angle", "0", "--check", "0",
                           "--radius", "20", "--houses", "3", "--catchment", "40"])
        sender, calls = make([])
        out = tf3ctl.cmd_fit(ns, sender=sender)
        self.assertFalse(out["ok"]); self.assertGreater(out["tooFewHouses"], 0)
        self.assertIn("too few town buildings", out["error"])
        # the build command quotes its params for a shell
        ns = p.parse_args(["fit", "--res", "x.con", "--at", "0,40", "--size", "10,10", "--angle", "0", "--check", "1",
                           "--params", '{"name": "it\'s"}'])
        sender, calls = make([{"ok": True, "buildable": True}])
        out = tf3ctl.cmd_fit(ns, sender=sender)
        import shlex
        self.assertEqual(json.loads(shlex.split(out["build"])[-1]), {"name": "it's"})

    def test_fit_join_dead_ends_first_and_short_pieces(self):
        # a short piece (2 m) at the street's end: drawn back to its far end only, never skipped
        scene = self.FIT_SCENE + [{"id": 502, "kind": "street", "from": {"x": 100, "y": 0}, "to": {"x": 100, "y": 2},
                                   "halfWidth": 6, "x": 100, "y": 1}]
        obs = tf3ctl.fit_obstacles(scene)
        o = next(x for x in obs if x["id"] == 502)
        poly = tf3ctl.fit_rect(100, 10, 0, (-5, -10, 5, 10))  # its box reaches down to the node (100, 0)
        self.assertIs(tf3ctl.fit_blocker(poly, [o], 0.5, ((100, 0), [502])), o, "its far end is still in the box")
        nodes = tf3ctl.fit_join_nodes(scene)
        self.assertEqual(nodes[(100, 0)], [501, 502])
        rails = [dict(e, kind="track") if e["kind"] == "street" else e for e in scene]
        res = tf3ctl.fit_search(rails, (-5, -10, 5, 10), (100, 50), 200, (0.0,), mouth=(0, -10), track=True)
        firsts = [c["joinAt"] for c in res["candidates"]]
        self.assertTrue(all(len(j["pieces"]) >= 1 for j in firsts))

    def test_build_and_road_collision_detail_args(self):
        """--collision-detail: with a build or --dry-run --engine-check; not with a plain dry run, --remove or
        --inspect-node; absent unless given (the answers as before)."""
        p = tf3ctl.make_parser()
        b = tf3ctl.build_args(p.parse_args(["build", "--res", "x.con", "--at", "1,2", "--collision-detail"]))
        self.assertEqual(b["collisionDetail"], True)
        d = tf3ctl.build_args(p.parse_args(["build", "--res", "x.con", "--at", "1,2", "--dry-run", "--engine-check",
                                            "--collision-detail"]))
        self.assertEqual((d["dryRun"], d["engineCheck"], d["collisionDetail"]), (True, True, True))
        self.assertTrue(tf3ctl.changes_game("build", d))
        self.assertNotIn("collisionDetail", tf3ctl.build_args(p.parse_args(["build", "--res", "x.con", "--at", "1,2"])))
        for argv in (["build", "--res", "x.con", "--at", "1,2", "--dry-run", "--collision-detail"],
                     ["build", "--remove", "5", "--collision-detail"],
                     ["build", "--remove-all", "--collision-detail"]):
            with self.assertRaises(tf3ctl.ToolError, msg=argv):
                tf3ctl.build_args(p.parse_args(argv))
        r = tf3ctl.road_args(p.parse_args(["road", "--from", "0,0", "--to", "1,1", "--dry-run", "--engine-check",
                                           "--collision-detail"]))
        self.assertEqual(r["collisionDetail"], True)
        self.assertEqual(tf3ctl.road_args(p.parse_args(["road", "--from", "0,0", "--to", "1,1",
                                                        "--collision-detail"]))["collisionDetail"], True)
        self.assertNotIn("collisionDetail", tf3ctl.road_args(p.parse_args(["road", "--from", "0,0", "--to", "1,1"])))
        # (--ignore-errors --dry-run implies the engine check: the detail goes with it)
        f = tf3ctl.road_args(p.parse_args(["road", "--from", "0,0", "--to", "1,1", "--ignore-errors", "--dry-run",
                                           "--collision-detail"]))
        self.assertEqual((f["engineCheck"], f["collisionDetail"]), (True, True))
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.road_args(p.parse_args(["road", "--from", "0,0", "--to", "1,1", "--dry-run", "--collision-detail"]))
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.road_inspect_args(p.parse_args(["road", "--inspect-node", "5", "--collision-detail"]))

    def test_build_and_road_remove_buildings_join_streets_args(self):
        p = tf3ctl.make_parser()
        b = tf3ctl.build_args(p.parse_args(["build", "--res", "x.con", "--at", "1,2", "--remove-buildings",
                                            "--join-streets"]))
        self.assertEqual((b["removeBuildings"], b["joinStreets"]), (True, True))
        self.assertNotIn("joinStreets", tf3ctl.build_args(p.parse_args(["build", "--res", "x.con", "--at", "1,2"])))
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.build_args(p.parse_args(["build", "--remove", "5", "--join-streets"]))
        for flag in ("--remove-buildings", "--join-streets"):
            with self.assertRaises(tf3ctl.ToolError, msg=flag):
                tf3ctl.build_args(p.parse_args(["build", "--res", "x.con", "--at", "1,2", "--dry-run", flag]))
        r = tf3ctl.road_args(p.parse_args(["road", "--from", "0,0", "--to", "1,1", "--remove-buildings"]))
        self.assertEqual(r["removeBuildings"], True)
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.road_inspect_args(p.parse_args(["road", "--inspect-node", "5", "--remove-buildings"]))
        self.assertTrue(tf3ctl.changes_game("build", b))
        self.assertTrue(tf3ctl.changes_game("road", r))

    def test_road_tangent_and_align_args(self):
        p = tf3ctl.make_parser()

        def road(*a):
            return tf3ctl.road_args(p.parse_args(["road", "--from", "0,0", "--to", "10,0"] + list(a)))
        plain = road()
        for k in ("tangentFrom", "tangentTo", "alignToEdge", "alignEdge"):
            self.assertNotIn(k, plain, "no flag: nothing sent (a straight piece, as before)")
        self.assertEqual(road("--tangent-to=-1,0")["tangentTo"], [-1.0, 0.0], "a negative dx written with =")
        r = road("--tangent-from", "1,0.5", "--tangent-to=-0,1")
        self.assertEqual((r["tangentFrom"], r["tangentTo"]), ([1.0, 0.5], [0.0, 1.0]))
        r = road("--align-to-edge", "both", "--align-edge", "9010", "--align-edge", "9011")
        self.assertEqual((r["alignToEdge"], r["alignEdge"]), ("both", [9010, 9011]))
        self.assertEqual(road("--align-to-edge", "from", "--tangent-to", "0,1")["tangentTo"], [0.0, 1.0])
        for bad in (["--tangent-from", "0,0"], ["--tangent-from", "1"], ["--tangent-to", "1,2,3"],
                    ["--tangent-to", "a,1"], ["--tangent-from", "nan,1"], ["--tangent-from", "inf,0"],
                    ["--align-to-edge", "from", "--tangent-from", "1,0"],
                    ["--align-to-edge", "both", "--tangent-to", "1,0"], ["--align-edge", "5"],
                    ["--align-to-edge", "to", "--align-edge", "-1"],
                    ["--align-to-edge", "both", "--align-edge", "1", "--align-edge", "2", "--align-edge", "3"],
                    ["--align-to-edge", "both", "--align-edge", "4", "--align-edge", "4"]):
            with self.assertRaises(tf3ctl.ToolError, msg=bad):
                road(*bad)
        with self.assertRaises(SystemExit):
            road("--align-to-edge", "middle")
        for flag in (["--tangent-from", "1,0"], ["--align-to-edge", "from"]):
            with self.assertRaises(tf3ctl.ToolError, msg=flag):
                tf3ctl.road_inspect_args(p.parse_args(["road", "--inspect-node", "5"] + flag))

    def test_reach_args_and_main(self):
        parse = tf3ctl.make_parser().parse_args

        def args(*a):
            return tf3ctl.reach_args(parse(["reach"] + list(a)))
        self.assertEqual(args("--api"), {"api": True})
        self.assertEqual(args("--problems"), {"problems": True})
        self.assertEqual(args("--target", "51"), {"target": 51})
        self.assertEqual(args("--town", "11", "--limit", "0"), {"town": 11, "limit": 0})
        self.assertEqual(args("--from", "41", "--to", "51"), {"from": 41, "to": 51})
        self.assertEqual(args("--from=-100.5,20", "--to", "51", "--mode", "walk", "--radius", "80"),
                         {"from": "-100.5,20.0", "to": 51, "mode": "walk", "radius": 80.0})
        for bad in ([], ["--api", "--problems"], ["--target", "1", "--town", "2"], ["--target", "-1"],
                    ["--from", "1"], ["--to", "1"], ["--from", "a,b", "--to", "1"], ["--from", "1", "--to", "1,2,3"],
                    ["--from", "1", "--to", "nan,1"], ["--from", "1", "--to", "2", "--radius", "0"],
                    ["--from", "1", "--to", "2", "--radius", "501"], ["--target", "1", "--mode", "walk"],
                    ["--target", "1", "--limit", "3"], ["--town", "1", "--limit", "201"], ["--api", "--radius", "5"]):
            with self.assertRaises(tf3ctl.ToolError, msg=bad):
                args(*bad)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            parse(["reach", "--from", "1", "--to", "2", "--mode", "fly"])
        self.assertNotIn("reach", tf3ctl.CHANGES_GAME)
        got = mod_reads(tf3ctl.command_text(9, "reach", {"from": "-1.5,2.0", "to": 51, "mode": "all"}))
        self.assertEqual(got["args"], {"from": "-1.5,2.0", "to": 51, "mode": "all"})
        # persons --town / --destination
        self.assertEqual(tf3ctl.persons_args(parse(["persons", "--town", "11"])), {"town": 11})
        self.assertEqual(tf3ctl.persons_args(parse(["persons", "--destination", "51", "--limit", "9"])),
                         {"destination": 51, "limit": 9})
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            parse(["persons", "--town", "1", "--destination", "2"])
        sent = []

        def fake_send(cmd, args=None, timeout=20, **kw):
            sent.append((cmd, args))
            return {"ok": True}
        tf3ctl.send = fake_send
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(tf3ctl.main(["reach", "--target", "51"]), 0)
            self.assertEqual(tf3ctl.main(["reach", "--from", "0,0", "--to", "51", "--mode", "drive"]), 0)
            self.assertEqual(tf3ctl.main(["persons", "--town", "11"]), 0)
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(tf3ctl.main(["reach"]), 2, "refused before sending")
        self.assertEqual(sent, [("reach", {"target": 51}), ("reach", {"from": "0.0,0.0", "to": 51, "mode": "drive"}),
                                ("persons", {"town": 11})])

    def test_stock_and_steps_args_and_main(self):
        def ns(**kw):
            base = dict(action="set", entity=51, stock=0, amount=100, cargo=None, dry_run=False)
            base.update(kw)
            return tf3ctl.argparse.Namespace(**base)
        self.assertEqual(tf3ctl.stock_args(ns()), {"entity": 51, "stock": 0, "amount": 100})
        self.assertEqual(tf3ctl.stock_args(ns(entity=601, stock=-1, amount=0, cargo="COAL", dry_run=True)),
                         {"entity": 601, "stock": -1, "amount": 0, "cargo": "COAL", "dryRun": True})
        self.assertEqual(tf3ctl.stock_args(ns(action="list", stock=None, amount=None)), {"entity": 51})
        for bad in (dict(entity=-1), dict(stock=-2), dict(amount=-1), dict(amount=tf3ctl.STOCK_MAX_AMOUNT + 1),
                    dict(stock=-1), dict(cargo=""), dict(cargo="CO AL"), dict(action="list", entity=-5)):
            with self.assertRaises(tf3ctl.ToolError, msg=bad):
                tf3ctl.stock_args(ns(**bad))
        sns = tf3ctl.argparse.Namespace
        self.assertEqual(tf3ctl.steps_args(sns(count=1, dry_run=False)), {"count": 1})
        self.assertEqual(tf3ctl.steps_args(sns(count=1, dry_run=False, allow_running=True)),
                         {"count": 1, "allowRunning": True})
        self.assertEqual(tf3ctl.steps_timeout(1), 30 + tf3ctl.STEPS_TIMEOUT_MARGIN_SEC)
        self.assertEqual(tf3ctl.steps_timeout(10000), 200 + tf3ctl.STEPS_TIMEOUT_MARGIN_SEC)
        self.assertEqual(tf3ctl.steps_args(sns(count=tf3ctl.STEPS_MAX, dry_run=True)),
                         {"count": tf3ctl.STEPS_MAX, "dryRun": True})
        for bad in (0, -1, tf3ctl.STEPS_MAX + 1):
            with self.assertRaises(tf3ctl.ToolError):
                tf3ctl.steps_args(sns(count=bad, dry_run=False))
        self.assertIn("stockSet", tf3ctl.CHANGES_GAME)
        self.assertIn("steps", tf3ctl.CHANGES_GAME)
        self.assertNotIn("stockList", tf3ctl.CHANGES_GAME)
        sent = []

        def fake_send(cmd, args=None, timeout=20, **kw):
            sent.append((cmd, args, timeout))
            return {"ok": True}
        tf3ctl.send = fake_send
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(tf3ctl.main(["stock", "list", "--entity", "47"]), 0)
            self.assertEqual(tf3ctl.main(["stock", "set", "--entity", "47", "--stock", "1", "--amount", "100",
                                          "--cargo", "COAL"]), 0)
            self.assertEqual(tf3ctl.main(["steps", "500", "--dry-run"]), 0)
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(tf3ctl.main(["steps", "0"]), 2, "refused before sending")
            self.assertEqual(tf3ctl.main(["stock", "set", "--entity", "47", "--stock", "-1", "--amount", "5"]), 2)
        self.assertEqual(sent, [("stockList", {"entity": 47}, 20),
                                ("stockSet", {"entity": 47, "stock": 1, "amount": 100, "cargo": "COAL"},
                                 tf3ctl.STOCK_TIMEOUT_SEC),
                                ("steps", {"count": 500, "dryRun": True}, tf3ctl.steps_timeout(500))])
        # warehouses: entities --kind warehouse and window --warehouse NAME
        del sent[:]
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(tf3ctl.main(["entities", "--kind", "warehouse"]), 0)
            self.assertEqual(tf3ctl.main(["window", "--warehouse", "Lager"]), 0)
        self.assertEqual([(c, a) for c, a, _ in sent], [("entities", {"kind": "warehouse", "limit": 200}),
                                                       ("window", {"kind": "warehouse", "name": "Lager"})])

    def test_build_args_and_main(self):
        def ns(**kw):
            base = dict(res=None, at=None, angle=None, params=None, seed=None, name=None, dry_run=False, remove=None,
                        remove_all=False)
            base.update(kw)
            return tf3ctl.argparse.Namespace(**base)
        self.assertEqual(tf3ctl.build_args(ns(res=" m::/a/ramp.con ", at="10,-20.5")),
                         {"res": "m::/a/ramp.con", "at": [10.0, -20.5]})
        self.assertEqual(tf3ctl.build_args(ns(res="x.con", at="1,2,3", angle=1.5, params='{"h": 8}', seed=4, name="R",
                                              dry_run=True)),
                         {"res": "x.con", "at": [1.0, 2.0, 3.0], "angle": 1.5, "params": {"h": 8}, "seed": 4,
                          "name": "R", "dryRun": True})
        self.assertEqual(tf3ctl.build_args(ns(remove="5001, 5002")), {"remove": [5001, 5002]})
        self.assertEqual(tf3ctl.build_args(ns(remove_all=True)), {"removeAll": True})
        for bad in (dict(), dict(res="x.con"), dict(res=" ", at="1,2"), dict(res="x.con", at="1"),
                    dict(res="x.con", at="1,2,3,4"), dict(res="x.con", at="a,b"), dict(res="x.con", at="nan,1"),
                    dict(res="x.con", at="1,2", params="[1]"), dict(res="x.con", at="1,2", params="nope"),
                    dict(res="x.con", at="1,2", name=" "), dict(res="x.con", at="1,2", angle=float("nan")),
                    dict(res="x.con", at="1,2", angle=float("inf")), dict(remove="1,x"), dict(remove="-1"),
                    dict(remove="1", res="x.con"), dict(remove="1", remove_all=True), dict(remove_all=True, dry_run=True)):
            with self.assertRaises(tf3ctl.ToolError, msg=str(bad)):
                tf3ctl.build_args(ns(**bad))
        self.assertIn("build", tf3ctl.CHANGES_GAME)
        got = mod_reads(tf3ctl.command_text(9, "build", {"res": "m::/r.con", "at": [1.0, 2.0], "params": {"h": 8}}))
        self.assertEqual(got["args"]["at"], [1, 2])
        self.assertEqual(got["args"]["params"], {"h": 8})
        sent = []

        def fake_send(cmd, args=None, timeout=20, **kw):
            sent.append((cmd, args, timeout))
            return {"ok": True, "entity": 5}  # a place is ok only with its construction
        tf3ctl.send = fake_send
        with contextlib.redirect_stdout(io.StringIO()):
            code = tf3ctl.main(["build", "--res", "m::/r.con", "--at=-100,50", "--angle", "0.5"])
        self.assertEqual(code, 0)
        self.assertEqual(sent, [("build", {"res": "m::/r.con", "at": [-100.0, 50.0], "angle": 0.5},
                                 tf3ctl.BUILD_TIMEOUT_SEC)])

    def test_build_silent_failure_is_not_ok_and_brings_the_log_errors(self):
        # measured 2026-11-22: the mod answered ok for a harbour the engine had not built; the reason was only in
        # the log, an Exception entry and an ERROR entry with their continuation lines
        log = os.path.join(self.x, "stdout.txt")
        before = "[2026-11-22 08:09:30Z - ERROR    - Main Thread      - Main           ]  an older error\n"
        mine = ("[2026-11-22 08:09:36Z - MESSAGE  - Main Thread      - Main           ]  [remote_probe] command 1: build\n"
                "[2026-11-22 08:09:36Z - VERBOSE  - Main Thread      - Main           ]+ Exception type: Unknown error\n"
                "    | Details:\n"
                "    | Error message: Terminal 2 of station in subconstruction 2 has transport modes not supported "
                "by the vehicle node: SHIP\n"
                "    + In function: ValidateConstructionResult\n"
                "[2026-11-22 08:09:36Z - VERBOSE  - Main Thread      - Main           ]  something else\n"
                "    | not an error\n"
                "[2026-11-22 08:09:36Z - ERROR    - Main Thread      - Main           ]+ Error during construction update\n"
                "    | DetailMessage: file='::/stations/water/harbor_modular.con'\n"
                "    + Location: proposal_util.cpp(176): operator()\n")
        write(log, before)
        start = tf3ctl.log_size(log)
        with open(log, "a") as f:
            f.write(mine)
        errs = tf3ctl.log_errors_since(log, start)
        self.assertEqual(len(errs), 2, errs)
        self.assertIn("Error message: Terminal 2 of station", errs[0])
        self.assertTrue(errs[0].startswith("2026-11-22 08:09:36Z VERBOSE: Exception type"), errs[0])
        self.assertNotIn("Details:", errs[0])
        self.assertIn("Error during construction update | DetailMessage: file='::/stations/water/harbor_modular.con'",
                      errs[1])
        # other mods' game scripts fill the Simulation Thread with errors in the same second: left out, and the
        # first ones are kept (measured 2026-11-22: company_growth, about 15 a second)
        noise = ("[2026-11-22 08:09:36Z - ERROR    - Simulation Thread - Main           ]+ Error while running game "
                 "script\n    | company_growth.script@handleEvent\n") * 15
        write(log, before)
        with open(log, "a") as f:
            f.write(mine + noise + "[2026-11-22 08:09:37Z - ERROR    - Main Thread      - Main           ]  "
                    "x\n" * 12)
        errs2 = tf3ctl.log_errors_since(log, start)
        self.assertEqual(len(errs2), tf3ctl.LOG_ERRORS_MAX)
        self.assertEqual(errs2[:2], errs, "the harbour's two first, the noise left out")
        self.assertFalse(any("company_growth" in e for e in errs2))
        self.assertEqual(tf3ctl.log_errors_since(log, 10 ** 9), [], "a log rewritten by a new start says nothing")
        self.assertEqual(tf3ctl.log_errors_since(None, 0), [])
        self.assertEqual(tf3ctl.log_errors_since(os.path.join(self.x, "none.txt"), 0), [])
        self.assertIsNone(tf3ctl.log_size(os.path.join(self.x, "none.txt")))
        # an older mod's answer: ok with no construction -> not ok, whatever it said
        answer = {"ok": True, "entities": [], "errors": [], "warnings": [], "cost": 0, "spent": 0,
                  "why": "built, but no construction came back among the result's entities", "name": "probe-build 3"}
        got = tf3ctl.check_build_answer({"res": "h.con", "at": [1.0, 2.0]}, answer)
        self.assertIs(got["ok"], False)
        self.assertIn("nothing was built", got["error"])
        self.assertNotIn("logErrors", got)
        ok = tf3ctl.check_build_answer({"res": "h.con", "at": [1.0, 2.0]}, {"ok": True, "entity": 5}, log, start)
        self.assertIs(ok["ok"], True)
        self.assertNotIn("logErrors", ok, "a build that is ok gets no errors of the same seconds")
        self.assertIs(tf3ctl.check_build_answer({"res": "h.con", "at": [1, 2], "dryRun": True}, {"ok": True})["ok"], True,
                      "a dry run names no construction")
        self.assertIs(tf3ctl.check_build_answer({"remove": [5]}, {"ok": True, "removed": [5]})["ok"], True)
        # main: the exit code is not 0 and the log's errors written while the command ran come with the answer
        def fake_send(cmd, args=None, timeout=20, **kw):
            with open(log, "a") as f:
                f.write(mine)
            return dict(answer)
        tf3ctl.send = fake_send
        write(log, before)
        os.environ["TF3_LOG"] = log
        try:
            out = io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                code = tf3ctl.main(["build", "--res", "h.con", "--at", "1,2"])
        finally:
            os.environ.pop("TF3_LOG")
        self.assertEqual(code, 1)
        shown = json.loads(out.getvalue())
        self.assertIs(shown["ok"], False)
        self.assertEqual(len(shown["logErrors"]), 2, "the older error before the command is left out")
        self.assertIn("SHIP", shown["logErrors"][0])

    def test_refusal_with_no_message_takes_the_reason_from_the_game_log(self):
        # 2026-11-23: a build refused on water answered "no message" while the Simulation Thread logged its reason
        log = os.path.join(self.x, "stdout.txt")
        before = ("[2026-11-23 08:14:00Z - MESSAGE  - Simulation Threa - Main           ]  ProposalData error: "
                  "older\n")
        mine = ("[2026-11-23 08:14:33Z - MESSAGE  - Main Thread      - Main           ]  [remote_probe] command 1: build\n"
                "[2026-11-23 08:14:33Z - MESSAGE  - Simulation Threa - Main           ]  ProposalData error: 陸上に配置\n"
                "[2026-11-23 08:14:33Z - MESSAGE  - Simulation Threa - Main           ]+ Proposal:\n"
                "    | Added segments:\n"
                "    |  - -21 -1 -2 \n")
        write(log, before)
        start = tf3ctl.log_size(log)
        with open(log, "a") as f:
            f.write(mine)
        lines = tf3ctl.log_proposal_since(log, start)
        self.assertEqual(lines, [{"time": "2026-11-23 08:14:33Z", "kind": "error", "text": "陸上に配置"}],
                         "the older line and the proposal's dump are left out")
        self.assertEqual(tf3ctl.log_proposal_since(log, 10 ** 9), [])
        self.assertEqual(tf3ctl.log_proposal_since(None, 0), [])
        refused = {"ok": False, "error": "the engine refused it: no message (resultProposalData.errorState: critical "
                   "true, messages 0, warnings 0, infos 0)"}
        got = tf3ctl.check_build_answer({"res": "h.con", "at": [1.0, 2.0]}, dict(refused), log, start)
        self.assertEqual(got["error"], "the engine refused it: 陸上に配置 (from the game's log, ProposalData error; the "
                         "answer had no message: resultProposalData.errorState: critical true, messages 0, warnings 0, "
                         "infos 0)")
        self.assertEqual(got["errorFrom"], "game log")
        self.assertEqual(got["proposalLog"][0]["text"], "陸上に配置")
        # an older mod's plain "no message"
        old = tf3ctl.check_build_answer({"res": "h.con", "at": [1.0, 2.0]},
                                        {"ok": False, "error": "the engine refused it: no message"}, log, start)
        self.assertEqual(old["error"], "the engine refused it: 陸上に配置 (from the game's log, ProposalData error; "
                         "the answer had no message)")
        # a refusal with its own message keeps it; the log's lines come along
        own = tf3ctl.check_build_answer({"res": "h.con", "at": [1.0, 2.0]},
                                        {"ok": False, "error": "the engine refused it: 衝突"}, log, start)
        self.assertEqual(own["error"], "the engine refused it: 衝突"); self.assertNotIn("errorFrom", own)
        self.assertIn("proposalLog", own)
        # a road's answer (no res): the same
        road = tf3ctl.check_build_answer({"from": [0, 0], "to": [1, 1]}, dict(refused), log, start)
        self.assertEqual(road["errorFrom"], "game log")
        # a dry run that said buildable while the log has an error: a note
        dry = tf3ctl.check_build_answer({"res": "h.con", "at": [1, 2], "dryRun": True, "engineCheck": True},
                                        {"ok": True, "verdict": "buildable"}, log, start)
        self.assertIs(dry["ok"], True); self.assertIn("陸上に配置", dry["proposalLogNote"])
        # a dry run that asked no engine: no note
        plain = tf3ctl.check_build_answer({"res": "h.con", "at": [1, 2], "dryRun": True}, {"ok": True}, log, start)
        self.assertNotIn("proposalLogNote", plain); self.assertNotIn("proposalLog", plain)
        # the words inside another mod's line are not the engine's
        self.assertEqual(tf3ctl.PROPOSAL_LOG_RE.match("[x] saw ProposalData error: y"), None)
        # a build that is ok: no lines read
        self.assertNotIn("proposalLog", tf3ctl.check_build_answer({"res": "h.con", "at": [1, 2]},
                                                                  {"ok": True, "entity": 5}, log, start))
        # nothing in the log: said so, the answer's own text kept
        write(log, before)
        start = tf3ctl.log_size(log)
        none = tf3ctl.check_build_answer({"res": "h.con", "at": [1, 2]}, dict(refused), log, start)
        self.assertEqual(none["error"], refused["error"])
        self.assertIn("no ProposalData line", none["proposalLogNote"])
        # main: road goes through it too
        def fake_send(cmd, args=None, timeout=20, **kw):
            with open(log, "a") as f:
                f.write(mine)
            return dict(refused)
        saved = tf3ctl.send
        tf3ctl.send = fake_send
        os.environ["TF3_LOG"] = log
        try:
            out = io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
                code = tf3ctl.main(["road", "--from", "0,0", "--to", "10,0"])
        finally:
            os.environ.pop("TF3_LOG")
            tf3ctl.send = saved
        self.assertEqual(code, 1)
        self.assertIn("陸上に配置", json.loads(out.getvalue())["error"])

    def test_build_modules_owner_and_water_args(self):
        def ns(**kw):
            base = dict(res="h.con", at="1,2", angle=None, params=None, seed=None, name=None, dry_run=False,
                        remove=None, remove_all=False, no_owner=False, no_fill_modules=False)
            base.update(kw)
            return tf3ctl.argparse.Namespace(**base)
        mods = '{"modules": {"120001": {"name": "a.module", "variant": 1}}}'
        got = tf3ctl.build_args(ns(params=mods, no_owner=True, no_fill_modules=True))
        self.assertEqual(got, {"res": "h.con", "at": [1.0, 2.0], "noOwner": True, "fillModules": False,
                               "params": {"modules": {"120001": {"name": "a.module", "variant": 1}}}})
        ok = '{"modules": {"1": {"name": "x", "metadata": {"a": 1}, "updateScript": {"fileName": "s", "params": {}}}}}'
        self.assertIn("params", tf3ctl.build_args(ns(params=ok)))
        self.assertNotIn("noOwner", tf3ctl.build_args(ns()), "the default: the company's")
        self.assertNotIn("fillModules", tf3ctl.build_args(ns()), "the default: filled")
        for bad in ('{"modules": [1]}', '{"modules": {"a": {"name": "x"}}}', '{"modules": {"-1": {"name": "x"}}}',
                    '{"modules": {"1": "x"}}', '{"modules": {"1": {"name": " "}}}',
                    '{"modules": {"1": {"name": "x", "variant": -1}}}', '{"modules": {"1": {"name": "x", "variant": true}}}',
                    '{"modules": {}}', '{"modules": {"1": {"name": "x", "metadata": 3}}}',
                    '{"modules": {"1": {"name": "x", "updateScript": "s"}}}',
                    '{"modules": {"1": {"name": "x", "updateScript": {"params": {}}}}}',
                    '{"modules": {"1": {"name": "x", "updateScript": {"fileName": "s", "params": 1}}}}'):
            with self.assertRaises(tf3ctl.ToolError, msg=bad):
                tf3ctl.build_args(ns(params=bad))
        for bad in (dict(remove="1", res=None, at=None, no_owner=True), dict(remove="1", res=None, at=None, no_fill_modules=True)):
            with self.assertRaises(tf3ctl.ToolError, msg=str(bad)):
                tf3ctl.build_args(ns(**bad))
        p = tf3ctl.make_parser()
        self.assertTrue(p.parse_args(["build", "--res", "x", "--at", "1,2", "--no-owner"]).no_owner)
        # the mod reads the text key as text; it makes it a number itself (core.buildModules)
        got = mod_reads(tf3ctl.command_text(9, "build", tf3ctl.build_args(ns(params=mods))))
        self.assertEqual(got["args"]["params"]["modules"]["120001"]["name"], "a.module")
        # water
        wa = tf3ctl.argparse.Namespace
        self.assertEqual(tf3ctl.water_args(wa(at="10,-20", grid=None)), {"at": [10.0, -20.0]})
        self.assertEqual(tf3ctl.water_args(wa(at=None, grid="0,0,100,50,50")), {"grid": [0.0, 0.0, 100.0, 50.0, 50.0]})
        self.assertEqual(tf3ctl.water_args(wa(at=None, grid="0,0,399,0,1")), {"grid": [0.0, 0.0, 399.0, 0.0, 1.0]},
                         "400 points: the limit itself")
        for bad in (dict(at=None, grid=None), dict(at="1,2", grid="0,0,1,1,1"), dict(at="1", grid=None),
                    dict(at="a,b", grid=None), dict(at="nan,1", grid=None), dict(at=None, grid="0,0,1,1"),
                    dict(at=None, grid="5,0,1,1,1"), dict(at=None, grid="0,0,1,1,0"), dict(at=None, grid="0,0,400,0,1"),
                    dict(at=None, grid="0,0,1,1,1e-300"), dict(at=None, grid="0,0,1,1,0.05"),
                    dict(at=None, grid="0,0,1,1,inf")):
            with self.assertRaises(tf3ctl.ToolError, msg=str(bad)):
                tf3ctl.water_args(wa(**bad))
        self.assertNotIn("water", tf3ctl.CHANGES_GAME, "read only")
        # road: changes the game; from and to as numbers, the rest only when given
        self.assertIn("road", tf3ctl.CHANGES_GAME)
        rd = p.parse_args(["road", "--from=-100,5", "--to", "20,5,3"])
        self.assertEqual(tf3ctl.road_args(rd), {"from": [-100.0, 5.0], "to": [20.0, 5.0, 3.0]})
        rd = p.parse_args(["road", "--from", "0,0", "--to", "1,1", "--type", " town_new_small ", "--snap", "0", "--dry-run"])
        self.assertEqual(tf3ctl.road_args(rd), {"from": [0.0, 0.0], "to": [1.0, 1.0], "type": "town_new_small",
                                                "snap": 0.0, "dryRun": True})
        for bad in (["--from", "0", "--to", "1,1"], ["--from", "a,b", "--to", "1,1"], ["--from", "0,0,0,0", "--to", "1,1"],
                    ["--from", "0,0", "--to", "1,inf"], ["--from", "0,0", "--to", "1,1", "--snap", "21"],
                    ["--from", "0,0", "--to", "1,1", "--snap", "-1"], ["--from", "0,0", "--to", "1,1", "--type", " "]):
            with self.assertRaises(tf3ctl.ToolError, msg=str(bad)):
                tf3ctl.road_args(p.parse_args(["road"] + bad))
        # --remove-fields: sent as removeFields; a build with it changes the game, as any road build
        rd = p.parse_args(["road", "--from", "0,0", "--to", "1,1", "--remove-fields"])
        self.assertEqual(tf3ctl.road_args(rd)["removeFields"], True)
        self.assertNotIn("removeFields", tf3ctl.road_args(p.parse_args(["road", "--from", "0,0", "--to", "1,1"])))
        self.assertTrue(tf3ctl.changes_game("road", tf3ctl.road_args(rd)))
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.road_inspect_args(p.parse_args(["road", "--inspect-node", "5", "--remove-fields"]))
        # --bridge: sent as bridge (trimmed), only when given; a dry run with it still changes nothing
        res = "hummer_pier_spike::/infrastructure/bridge/hps_pillarless.bridge"
        rd = p.parse_args(["road", "--from", "0,0,10", "--to", "70,0,10", "--bridge", " %s " % res, "--dry-run"])
        args = tf3ctl.road_args(rd)
        self.assertEqual(args, {"from": [0.0, 0.0, 10.0], "to": [70.0, 0.0, 10.0], "bridge": res, "dryRun": True})
        self.assertFalse(tf3ctl.changes_game("road", args))
        self.assertTrue(tf3ctl.changes_game("road", tf3ctl.road_args(p.parse_args(
            ["road", "--from", "0,0", "--to", "1,1", "--bridge", "concrete"]))))
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.road_args(p.parse_args(["road", "--from", "0,0", "--to", "1,1", "--bridge", " "]))
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.road_inspect_args(p.parse_args(["road", "--inspect-node", "5", "--bridge", "concrete"]))
        # --engine-check: with --dry-run only; it counts as changing the game, a plain dry run does not
        rd = p.parse_args(["road", "--from", "0,0", "--to", "1,1", "--dry-run", "--engine-check"])
        args = tf3ctl.road_args(rd)
        self.assertEqual(args["engineCheck"], True)
        self.assertTrue(tf3ctl.changes_game("road", args))
        self.assertFalse(tf3ctl.changes_game("road", {"from": [0, 0], "to": [1, 1], "dryRun": True}))
        self.assertTrue(tf3ctl.changes_game("road", {"from": [0, 0], "to": [1, 1]}))
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.road_args(p.parse_args(["road", "--from", "0,0", "--to", "1,1", "--engine-check"]))
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.road_inspect_args(p.parse_args(["road", "--inspect-node", "5", "--engine-check"]))
        # --from and --to: required unless --inspect-node (checked after parsing)
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.road_args(p.parse_args(["road", "--from", "0,0"]))
        # --inspect-node: read only, alone
        self.assertNotIn("roadInspect", tf3ctl.CHANGES_GAME, "read only")
        self.assertEqual(tf3ctl.road_inspect_args(p.parse_args(["road", "--inspect-node", "4077"])), {"node": 4077})
        for bad in (["--inspect-node", "-1"], ["--inspect-node", "5", "--from", "0,0"], ["--inspect-node", "5", "--dry-run"],
                    ["--inspect-node", "5", "--to", "1,1"], ["--inspect-node", "5", "--snap", "2"]):
            with self.assertRaises(tf3ctl.ToolError, msg=str(bad)):
                tf3ctl.road_inspect_args(p.parse_args(["road"] + bad))
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            p.parse_args(["road", "--inspect-node", "x"])
        self.assertEqual(p.parse_args(["water", "--grid", "0,0,1,1,1"]).grid, "0,0,1,1,1")
        sent = []

        def fake_send(cmd, args=None, timeout=20, **kw):
            sent.append((cmd, args))
            return {"ok": True}
        tf3ctl.send = fake_send
        with contextlib.redirect_stdout(io.StringIO()):
            code = tf3ctl.main(["water", "--at=-100,50"])
        self.assertEqual((code, sent), (0, [("water", {"at": [-100.0, 50.0]})]))
        del sent[:]
        with contextlib.redirect_stdout(io.StringIO()):
            code = tf3ctl.main(["road", "--inspect-node", "4077"])
        self.assertEqual((code, sent), (0, [("roadInspect", {"node": 4077})]))

    def test_terrain_args_and_probe_api(self):
        p = tf3ctl.make_parser()

        def args(*argv):
            return tf3ctl.terrain_args(p.parse_args(["terrain"] + list(argv)))
        self.assertEqual(args("--rect=-100,0,100,50", "--flat", "40"), {"rect": [-100.0, 0.0, 100.0, 50.0], "flat": 40.0})
        self.assertEqual(args("--rect", "0,0,500,300", "--slope-x", "5", "--base", "40", "--blend", "0", "--dry-run",
                              "--via", "gui"),
                         {"rect": [0.0, 0.0, 500.0, 300.0], "slopeX": 5.0, "base": 40.0, "blend": 0.0, "dryRun": True,
                          "via": "gui"})
        self.assertEqual(args("--rect", "0,0,1024,1024", "--slope-y", "-10", "--base", "80")["slopeY"], -10.0,
                         "the limit itself")
        self.assertEqual(args("--rect", "0,0,10,10", "--flat", "1", "--in-game")["inGame"], True)
        self.assertNotIn("inGame", args("--rect", "0,0,10,10", "--flat", "1"), "the map editor only by default")
        for bad in (["--rect", "0,0,1", "--flat", "1"], ["--rect", "5,0,1,1", "--flat", "1"],
                    ["--rect", "0,0,1025,10", "--flat", "1"], ["--rect", "0,0,10,10"],
                    ["--rect", "0,0,10,10", "--slope-x", "5"], ["--rect", "0,0,10,10", "--flat", "1", "--base", "2"],
                    ["--rect", "0,0,10,10", "--flat", "nan"], ["--rect", "0,0,10,10", "--flat", "1", "--blend", "-1"],
                    ["--rect", "a,b,c,d", "--flat", "1"], ["--flat", "1"]):
            with self.assertRaises(tf3ctl.ToolError, msg=str(bad)):
                args(*bad)
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            p.parse_args(["terrain", "--rect", "0,0,1,1", "--flat", "1", "--slope-x", "2"])
        self.assertIn("terrain", tf3ctl.CHANGES_GAME)
        self.assertNotIn("terrainApi", tf3ctl.CHANGES_GAME, "it only looks")
        # the mod reads the rect as a list of numbers
        got = mod_reads(tf3ctl.command_text(9, "terrain", args("--rect", "0,0,10,10", "--flat", "1")))
        self.assertEqual((got["cmd"], got["args"]["rect"][3], got["args"]["flat"]), ("terrain", 10, 1))
        sent = []

        def fake_send(cmd, a=None, timeout=20, **kw):
            sent.append((cmd, a, timeout))
            return {"ok": True}
        tf3ctl.send = fake_send
        with contextlib.redirect_stdout(io.StringIO()):
            code = tf3ctl.main(["terrain", "--probe-api"])
            code2 = tf3ctl.main(["terrain", "--rect", "0,0,10,10", "--flat", "3", "--dry-run"])
        self.assertEqual((code, code2), (0, 0))
        self.assertEqual(sent[0][:2], ("terrainApi", {}))
        self.assertEqual(sent[1][:2], ("terrain", {"rect": [0.0, 0.0, 10.0, 10.0], "flat": 3.0, "dryRun": True}))
        self.assertEqual(sent[1][2], tf3ctl.TERRAIN_TIMEOUT_SEC)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(tf3ctl.main(["terrain", "--probe-api", "--rect", "0,0,1,1"]), 2)

    def test_town_develop_and_size_args_and_main(self):
        p = tf3ctl.make_parser()

        def grow(*argv):
            return tf3ctl.town_grow_args(p.parse_args(["town"] + list(argv)))
        self.assertEqual(grow("develop", "--at=-100,50"), ("townDevelop", {"at": [-100.0, 50.0], "count": 1}))
        self.assertEqual(grow("develop", "--at", "10,20", "--count", "200", "--streets", "--upgrade", "--radius", "300",
                              "--dry-run"),
                         ("townDevelop", {"at": [10.0, 20.0], "count": 200, "radius": 300.0, "streets": True,
                                          "upgrade": True, "dryRun": True}))
        self.assertEqual(grow("size", "--entity", "801", "--factors", "2,1.5,1"),
                         ("townSize", {"entity": 801, "factors": [2.0, 1.5, 1.0]}))
        self.assertEqual(grow("size", "--entity", "801", "--factors", "0,5,1", "--update-all", "--dry-run"),
                         ("townSize", {"entity": 801, "factors": [0.0, 5.0, 1.0], "updateAll": True, "dryRun": True}))
        for bad in (["develop", "--at", "1"], ["develop", "--at", "a,b"], ["develop", "--at", "nan,1"],
                    ["develop", "--at", "1,2", "--count", "0"], ["develop", "--at", "1,2", "--count", "201"],
                    ["develop", "--at", "1,2", "--radius", "0"], ["develop", "--at", "1,2", "--radius", "2001"],
                    ["size", "--entity", "-1", "--factors", "1,1,1"], ["size", "--entity", "1", "--factors", "1,1"],
                    ["size", "--entity", "1", "--factors", "1,x,1"], ["size", "--entity", "1", "--factors", "1,1,5.1"],
                    ["size", "--entity", "1", "--factors", "-1,1,1"], ["size", "--entity", "1", "--factors", "nan,1,1"]):
            with self.assertRaises(tf3ctl.ToolError, msg=str(bad)):
                grow(*bad)
        # an option of the plain town before the word would be dropped: refused, never sent as a real command
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.town_grow_args(p.parse_args(["town", "--dry-run", "develop", "--at", "1,2"]))
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.town_grow_args(p.parse_args(["town", "--at", "1,2", "size", "--entity", "1", "--factors", "1,1,1"]))
        for argv in (["town", "develop"], ["town", "size", "--entity", "1"], ["town", "size", "--factors", "1,1,1"]):
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                p.parse_args(argv)
        self.assertIn("townDevelop", tf3ctl.CHANGES_GAME)
        self.assertIn("townSize", tf3ctl.CHANGES_GAME)
        self.assertEqual(tf3ctl.town_grow_timeout("townDevelop", {"count": 200}),
                         tf3ctl.TOWN_GROW_TIMEOUT_SEC + 200 * tf3ctl.TOWN_DEVELOP_SEC_EACH)
        self.assertEqual(tf3ctl.town_grow_timeout("townSize", {}), tf3ctl.TOWN_GROW_TIMEOUT_SEC)
        # the mod reads the point and the factors as lists of numbers, the flags as booleans
        got = mod_reads(tf3ctl.command_text(9, "townDevelop", grow("develop", "--at", "10,-20", "--streets")[1]))
        self.assertEqual((got["args"]["at"][1], got["args"]["streets"], got["args"]["count"]), (-20, True, 1))
        got = mod_reads(tf3ctl.command_text(9, "townSize", grow("size", "--entity", "8", "--factors", "2,1.5,1")[1]))
        self.assertEqual((got["args"]["entity"], got["args"]["factors"][1]), (8, 1.5))
        sent = []

        def fake_send(cmd, args=None, timeout=20, **kw):
            sent.append((cmd, args, timeout))
            return {"ok": True}
        tf3ctl.send = fake_send
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(tf3ctl.main(["town", "develop", "--at", "1,2", "--count", "3", "--dry-run"]), 0)
            self.assertEqual(tf3ctl.main(["town", "size", "--entity", "801", "--factors", "2,1,1", "--update-all"]), 0)
            self.assertEqual(tf3ctl.main(["town", "--at", "1,2", "--name", "N", "--dry-run"]), 0)
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(tf3ctl.main(["town", "develop", "--at", "1,2", "--count", "999"]), 2, "refused before sending")
            self.assertEqual(tf3ctl.main(["town", "--dry-run", "develop", "--at", "1,2"]), 2)
        self.assertEqual(sent, [("townDevelop", {"at": [1.0, 2.0], "count": 3, "dryRun": True},
                                 tf3ctl.town_grow_timeout("townDevelop", {"count": 3})),
                                ("townSize", {"entity": 801, "factors": [2.0, 1.0, 1.0], "updateAll": True},
                                 tf3ctl.TOWN_GROW_TIMEOUT_SEC),
                                ("town", {"at": [1.0, 2.0], "name": "N", "dryRun": True}, tf3ctl.TOWN_TIMEOUT_SEC)])

    def test_town_args(self):
        p = tf3ctl.make_parser()

        def args(*argv):
            return tf3ctl.town_args(p.parse_args(["town"] + list(argv)))
        self.assertEqual(args("--at=-100,50", "--name", " Harbourside "), {"at": [-100.0, 50.0], "name": "Harbourside"})
        self.assertEqual(args("--at", "1200,-300", "--name", "B", "--size", "1.5", "--capacity", "300", "--needs",
                              "com:fish, IND:planks", "--via", "gui", "--in-game", "--dry-run"),
                         {"at": [1200.0, -300.0], "name": "B", "size": 1.5, "capacity": 300,
                          "needs": "com:fish,IND:planks", "via": "gui", "inGame": True, "dryRun": True})
        self.assertEqual(args("--at", "0,0", "--name", "C", "--no-needs")["needs"], "none")
        self.assertNotIn("inGame", args("--at", "0,0", "--name", "C"), "the map editor only by default")
        self.assertEqual(args("--at", "0,0", "--name", "C", "--size", "2.5")["size"], 2.5, "the limit itself")
        for bad in (["--at", "0", "--name", "N"], ["--at", "a,b", "--name", "N"], ["--at", "0,nan", "--name", "N"],
                    ["--at", "0,0", "--name", "  "], ["--at", "0,0", "--name", "x" * 65],
                    ["--at", "0,0", "--name", "N", "--size", "0"], ["--at", "0,0", "--name", "N", "--size", "nan"],
                    ["--at", "0,0", "--name", "N", "--capacity", "0"], ["--at", "0,0", "--name", "N", "--capacity", "1001"],
                    ["--at", "0,0", "--name", "N", "--size", "2.6"],
                    ["--at", "0,0", "--name", "N", "--needs", "fish"], ["--at", "0,0", "--name", "N", "--needs", "shop:fish"],
                    ["--at", "0,0", "--name", "N", "--needs", "com:fi sh"]):
            with self.assertRaises(tf3ctl.ToolError, msg=str(bad)):
                args(*bad)
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            p.parse_args(["town", "--at", "0,0", "--name", "N", "--needs", "com:fish", "--no-needs"])
        # --at and --name are checked in town_args (town develop / size take neither)
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.town_args(p.parse_args(["town", "--at", "0,0"]))
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.town_args(p.parse_args(["town", "--name", "N"]))
        self.assertIn("town", tf3ctl.CHANGES_GAME)
        # the mod reads the point as a list of numbers and the name as a string
        got = mod_reads(tf3ctl.command_text(9, "town", args("--at", "10,-20", "--name", "N", "--needs", "com:fish")))
        self.assertEqual((got["cmd"], got["args"]["at"][1], got["args"]["name"], got["args"]["needs"]),
                         ("town", -20, "N", "com:fish"))
        sent = []

        def fake_send(cmd, a=None, timeout=20, **kw):
            sent.append((cmd, a, timeout))
            return {"ok": True}
        tf3ctl.send = fake_send
        with contextlib.redirect_stdout(io.StringIO()):
            code = tf3ctl.main(["town", "--at", "1,2", "--name", "T", "--dry-run"])
        self.assertEqual(code, 0)
        self.assertEqual(sent, [("town", {"at": [1.0, 2.0], "name": "T", "dryRun": True}, tf3ctl.TOWN_TIMEOUT_SEC)])

    def test_company_init_after_newgame_only_for_a_game(self):
        """replace_game sends companyInit after a newgame, not after the map editor, a load, a dry run, or with
        company_init False; a failed one is kept in the answer, the start still ok."""
        sent = []

        def fake_send(cmd, args=None, timeout=20, final_tag=None, on_progress=None, folder=None):
            sent.append(cmd)
            if cmd == "companyInit":
                if fail == "nopop":
                    return {"ok": True, "sent": False, "noPopulation": True}
                return {"ok": False, "error": "nope"} if fail else {"ok": True, "sent": True}
            return {"ok": True, "id": 7}

        with unittest.mock.patch.object(tf3ctl, "send", fake_send), \
                unittest.mock.patch.object(tf3ctl, "exchange_dir", lambda: "/nonexistent"), \
                unittest.mock.patch.object(tf3ctl, "current_stamp", lambda folder: "a"), \
                unittest.mock.patch.object(tf3ctl, "wait_new_hello", lambda *a: {"stamp": "b"}), \
                unittest.mock.patch.object(tf3ctl, "remove", lambda *a: None), \
                unittest.mock.patch.object(tf3ctl, "answer_files", lambda *a: []), \
                contextlib.redirect_stderr(io.StringIO()) as err:
            fail = False
            res = tf3ctl.replace_game("newgame", {"size": "tiny"}, False, 30)
            self.assertEqual(sent, ["newgame", "companyInit"])
            self.assertTrue(res["ok"] and res["companyInit"]["ok"])
            for cmd, args, only, ci in (("newgame", {"editor": True}, False, True), ("load", {"save": "s"}, False, True),
                                        ("newgame", {"dryRun": True}, True, True), ("newgame", {}, False, False)):
                sent.clear()
                res = tf3ctl.replace_game(cmd, args, only, 30, company_init=ci)
                self.assertNotIn("companyInit", sent, (cmd, args, ci))
                self.assertNotIn("companyInit", res)
            fail = True
            sent.clear()
            res = tf3ctl.replace_game("newgame", {}, False, 30)
            self.assertTrue(res["ok"], "the game started either way")
            self.assertFalse(res["companyInit"]["ok"])
            self.assertIn("company init failed (nope)", err.getvalue())
            fail = "nopop"  # a start with no towns: nothing sent, and a note to place towns first
            res = tf3ctl.replace_game("newgame", {"towns": False}, False, 30)
            self.assertTrue(res["ok"] and res["companyInit"]["noPopulation"])
            self.assertIn("no town population", err.getvalue())

    def test_newgame_warnings_go_to_stderr_too(self):
        """The mod's warnings on a newgame (difficulty_util not loaded, a base param missing) are printed, for the
        dry run's answer and for the start's ack; none when the plan came out as in the menu."""
        answers = {}

        def fake_send(cmd, args=None, timeout=20, final_tag=None, on_progress=None, folder=None):
            if cmd == "companyInit":
                return {"ok": True, "sent": False}
            return answers[cmd]

        with unittest.mock.patch.object(tf3ctl, "send", fake_send), \
                unittest.mock.patch.object(tf3ctl, "exchange_dir", lambda: "/nonexistent"), \
                unittest.mock.patch.object(tf3ctl, "current_stamp", lambda folder: "a"), \
                unittest.mock.patch.object(tf3ctl, "wait_new_hello", lambda *a: {"stamp": "b"}), \
                unittest.mock.patch.object(tf3ctl, "remove", lambda *a: None), \
                unittest.mock.patch.object(tf3ctl, "answer_files", lambda *a: []):
            answers["newgame"] = {"ok": True, "dryRun": True, "plan": {}, "warnings": ["difficulty_util not available (x)"]}
            with contextlib.redirect_stderr(io.StringIO()) as err:
                res = tf3ctl.replace_game("newgame", {"dryRun": True}, True, 30)
            self.assertEqual(res["warnings"], ["difficulty_util not available (x)"])
            self.assertIn("warning: difficulty_util not available (x)", err.getvalue())
            answers["newgame"] = {"ok": True, "id": 7, "plan": {}, "warnings": ["base param a missing", "b"]}
            with contextlib.redirect_stderr(io.StringIO()) as err:
                res = tf3ctl.replace_game("newgame", {}, False, 30)
            self.assertTrue(res["ok"])
            self.assertIn("warning: base param a missing\nwarning: b\n", err.getvalue())
            answers["newgame"] = {"ok": True, "id": 7, "plan": {}}
            with contextlib.redirect_stderr(io.StringIO()) as err:
                tf3ctl.replace_game("newgame", {}, False, 30)
            self.assertNotIn("warning", err.getvalue())

    def test_town_connect_args(self):
        p = tf3ctl.make_parser()

        def args(*argv):
            return tf3ctl.town_grow_args(p.parse_args(["town"] + list(argv)))
        self.assertEqual(args("connections"), ("townConnections", {}))
        self.assertEqual(args("connections", "--entity", "801"), ("townConnections", {"entity": 801}))
        self.assertEqual(args("connections", "--index-base", "1"), ("townConnections", {"indexBase": 1}))
        self.assertEqual(args("connect", "--auto", "--index-base", "0"), ("townConnect", {"auto": True, "indexBase": 0}))
        self.assertEqual(args("connect", "--auto", "--entity", "801,802"),
                         ("townConnect", {"auto": True, "entities": [801, 802]}))
        self.assertEqual(args("connect", "--build", "--pairs", "801:802,802:803", "--default", "--no-keep",
                              "--index-base", "1", "--dry-run"),
                         ("townConnect", {"build": True, "pairs": [[801, 802], [802, 803]], "default": True,
                                          "keep": False, "indexBase": 1, "dryRun": True}))
        self.assertEqual(args("connect", "--build"), ("townConnect", {"build": True}), "keep left to the mod")
        for bad in (["connect", "--auto", "--pairs", "1:2"], ["connect", "--auto", "--no-keep"],
                    ["connect", "--build", "--pairs", "1:1"], ["connect", "--build", "--pairs", "1-2"],
                    ["connect", "--build", "--entity", "1,1"], ["connect", "--build", "--entity", "x"]):
            with self.assertRaises(tf3ctl.ToolError, msg=bad):
                args(*bad)
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            p.parse_args(["town", "connect"])  # --auto or --build is required
        self.assertIn("townConnect", tf3ctl.CHANGES_GAME)
        self.assertNotIn("townConnections", tf3ctl.CHANGES_GAME)

    def test_company_commands_parse(self):
        p = tf3ctl.make_parser()
        ns = p.parse_args(["company"])
        self.assertIsNone(ns.company_action)
        ns = p.parse_args(["company", "init", "--dry-run"])
        self.assertEqual((ns.company_action, ns.company_dry_run), ("init", True))
        self.assertTrue(p.parse_args(["company", "init", "--force"]).company_force)
        self.assertTrue(p.parse_args(["newgame", "--no-company-init"]).no_company_init)
        self.assertTrue(p.parse_args(["restart", "--new", "--no-company-init"]).no_company_init)
        self.assertFalse(p.parse_args(["launch", "--new"]).no_company_init)
        self.assertIn("companyInit", tf3ctl.CHANGES_GAME)
        self.assertNotIn("company", tf3ctl.CHANGES_GAME)
        self.assertFalse(tf3ctl.changes_game("companyInit", {"dryRun": True}))
        self.assertTrue(tf3ctl.changes_game("companyInit", {}))

    def test_newgame_and_launch_editor(self):
        p = tf3ctl.make_parser()
        ns = p.parse_args(["newgame", "--editor", "--size", "tiny", "--no-towns", "--dry-run"])
        got = tf3ctl.newgame_args(ns)
        self.assertEqual((got["editor"], got["towns"], got["size"]), (True, False, "tiny"))
        self.assertNotIn("editor", tf3ctl.newgame_args(p.parse_args(["newgame", "--size", "tiny"])), "off by default")
        self.assertNotIn("editor", tf3ctl.newgame_args(p.parse_args(["newgame", "--editor", "--list"])), "--list: no plan")
        cmd, a = tf3ctl.start_args(p.parse_args(["launch", "--new", "--editor", "--size", "tiny"]))
        self.assertEqual((cmd, a["editor"]), ("newgame", True))
        self.assertNotIn("editor", tf3ctl.start_args(p.parse_args(["launch", "--new"]))[1])
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.start_args(p.parse_args(["launch", "--editor"]))
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.start_args(p.parse_args(["restart", "--load", "x", "--editor"]))

    def test_event_and_tool_args(self):
        ns = tf3ctl.argparse.Namespace
        self.assertEqual(tf3ctl.event_args(ns(name="example_window.show", param='{"welcome": true}')),
                         {"name": "example_window.show", "param": {"welcome": True}})
        self.assertEqual(tf3ctl.event_args(ns(name="x", param=None)), {"name": "x"})
        for bad in ("[1]", "nope", "3"):
            with self.assertRaises(tf3ctl.ToolError):
                tf3ctl.event_args(ns(name="x", param=bad))
        self.assertEqual(tf3ctl.tool_args(ns(name="music", module=None, field=None, close=True)),
                         {"name": "music", "close": True})
        self.assertEqual(tf3ctl.tool_args(ns(name=None, module="/m.tl", field="F", close=False)),
                         {"module": "/m.tl", "field": "F"})
        for a in (dict(name=None, module=None), dict(name="music", module="/m.tl")):
            with self.assertRaises(tf3ctl.ToolError):
                tf3ctl.tool_args(ns(field=None, close=False, **a))
        # event / tool as Lua command files the mod reads back
        text = tf3ctl.command_text(7, "event", {"name": "e", "param": {"welcome": True, "list": [1, 2]}})
        got = mod_reads(text)
        self.assertEqual(got["args"]["param"], {"welcome": True, "list": [1, 2]})

    def test_vehicle_args(self):
        ns = tf3ctl.argparse.Namespace
        self.assertEqual(tf3ctl.vehicle_args(ns(via="gui", model="bus", depot=301, line=None, count=1)),
                         {"via": "gui", "model": "bus", "depot": 301, "count": 1})
        self.assertEqual(tf3ctl.vehicle_args(ns(via="cmd", vehicle=7)), {"via": "cmd", "vehicle": 7})
        got = mod_reads(tf3ctl.command_text(8, "buy", {"via": "cmd", "model": "101", "depot": 301, "line": 21}))
        self.assertEqual(got["args"], {"via": "cmd", "model": "101", "depot": 301, "line": 21})
        # a multiple unit goes as the model text: the mod tells it by its .mu.lua ending
        mu = tf3ctl.make_parser().parse_args(["buy", "--model", "shinkansen_0s.mu.lua", "--depot", "302"])
        self.assertEqual(tf3ctl.vehicle_args(mu), {"via": "gui", "model": "shinkansen_0s.mu.lua", "depot": 302, "count": 1})
        got = mod_reads(tf3ctl.command_text(9, "buy", tf3ctl.vehicle_args(mu)))
        self.assertEqual(got["args"]["model"], "shinkansen_0s.mu.lua")
        self.assertTrue({"buy", "duplicate", "replace", "sell", "money"} <= tf3ctl.CHANGES_GAME)
        self.assertEqual(tf3ctl.money_args(ns(set=5, add=None)), {"set": 5})
        self.assertEqual(tf3ctl.money_args(ns(set=None, add=-3)), {"add": -3})
        self.assertFalse({"depots", "vehicles"} & tf3ctl.CHANGES_GAME)
        self.assertNotIn("industryWorkers", tf3ctl.CHANGES_GAME)
        self.assertEqual(tf3ctl.industry_workers_args(ns(entity=None)), {})
        self.assertEqual(tf3ctl.industry_workers_args(ns(entity=51)), {"entity": 51})
        self.assertNotIn("industryStocks", tf3ctl.CHANGES_GAME)
        self.assertEqual(tf3ctl.industry_stocks_args(ns(entity=None, grep=None, all_params=False)), {})
        self.assertEqual(tf3ctl.industry_stocks_args(ns(entity=51, grep="Mine", all_params=True)),
                         {"entity": 51, "grep": "Mine", "allParams": True})
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.industry_stocks_args(ns(entity=None, grep="", all_params=False))

    def test_vehicles_and_models_args(self):
        parse = tf3ctl.make_parser().parse_args
        # a plain vehicles call sends what it always sent
        self.assertEqual(tf3ctl.vehicles_args(parse(["vehicles"])), {"limit": 200})
        self.assertEqual(tf3ctl.vehicles_args(parse(["vehicles", "--line", "21"])), {"limit": 200, "line": 21})
        self.assertEqual(tf3ctl.vehicles_args(parse(["vehicles", "--entity", "601, 602", "--state", "--since", "120000"])),
                         {"limit": 200, "entities": [601, 602], "state": True, "since": 120000})
        for bad in (["--entity", "x"], ["--entity", ","], ["--entity", "-3"], ["--since", "5"]):
            with self.assertRaises(tf3ctl.ToolError, msg=bad):
                tf3ctl.vehicles_args(parse(["vehicles"] + bad))
        got = mod_reads(tf3ctl.command_text(9, "vehicles", {"limit": 200, "entities": [601], "state": True, "since": 5.5}))
        self.assertEqual(got["args"], {"limit": 200, "entities": [601], "state": True, "since": 5.5})
        self.assertEqual(tf3ctl.models_args(parse(["models"])), {"limit": 200})
        self.assertEqual(tf3ctl.models_args(parse(["models", "--grep", "Trillium", "--carrier", "water", "--limit", "3"])),
                         {"limit": 3, "grep": "Trillium", "carrier": "WATER"})
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.models_args(parse(["models", "--grep", ""]))
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            parse(["models", "--carrier", "boat"])
        # --mu: the multiple units, all of them or those whose name holds the filter
        self.assertEqual(tf3ctl.models_args(parse(["models", "--mu"])), {"limit": 200, "mu": True})
        self.assertEqual(tf3ctl.models_args(parse(["models", "--mu", "shinkansen"])), {"limit": 200, "mu": "shinkansen"})
        got = mod_reads(tf3ctl.command_text(10, "models", {"limit": 200, "mu": True}))
        self.assertEqual(got["args"], {"limit": 200, "mu": True})
        for bad in (["--mu", ""], ["--mu", "--carrier", "rail"], ["--mu", "--grep", "x"]):
            with self.assertRaises(tf3ctl.ToolError, msg=bad):
                tf3ctl.models_args(parse(["models"] + bad))
        # read only: no "who changed the game" entry, no warning about another owner
        self.assertFalse({"models", "vehicles"} & tf3ctl.CHANGES_GAME)

    def test_modhub_args_timeouts_and_no_upload(self):
        parse = tf3ctl.make_parser().parse_args
        self.assertEqual(tf3ctl.modhub_status_args(parse(["modhub", "status"])), {})
        self.assertEqual(tf3ctl.modhub_status_args(parse(["modhub", "status", "--folder", "a_1", "--wait", "0"])),
                         {"folder": "a_1", "wait": 0})
        self.assertEqual(tf3ctl.modhub_validate_args(parse(["modhub", "validate", "a_1", "--timeout", "60",
                                                            "--messages", "5"])),
                         {"folder": "a_1", "timeout": 60, "messages": 5})
        # the only upload is modhub publish (its own tests below): no other subcommand, no other command name
        for bad in (["modhub"], ["modhub", "validate"], ["modhub", "publish"], ["modhub", "upload", "a_1"]):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit, msg=bad):
                parse(bad)
        self.assertIn("unknown command", mod_reads(tf3ctl.command_text(9, "publish", {}))["error"])
        self.assertNotIn("error", mod_reads(tf3ctl.command_text(9, "modhubPublish", {})))
        got = mod_reads(tf3ctl.command_text(9, "modhubValidate", {"folder": "a_1", "timeout": 60}))
        self.assertEqual((got["cmd"], got["args"]), ("modhubValidate", {"folder": "a_1", "timeout": 60}))
        self.assertNotIn("error", mod_reads(tf3ctl.command_text(9, "modhubStatus", {})))
        # validate runs the game's validator and may abort a person's: others are warned; status only reads
        self.assertIn("modhubValidate", tf3ctl.CHANGES_GAME)
        self.assertNotIn("modhubStatus", tf3ctl.CHANGES_GAME)
        sent = []
        real = tf3ctl.send

        def fake_send(cmd, args=None, timeout=20, final_tag=None, on_progress=None, folder=None):
            sent.append((cmd, args, timeout))
            if on_progress:
                on_progress({"phase": "validating", "progress": 0.5, "task": "Checking files", "seconds": 3})
            return {"ok": True}
        tf3ctl.send = fake_send
        try:
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                tf3ctl.cmd_modhub(parse(["modhub", "status"]))
                tf3ctl.cmd_modhub(parse(["modhub", "status", "--wait", "100"]))
                tf3ctl.cmd_modhub(parse(["modhub", "validate", "a_1"]))
                tf3ctl.cmd_modhub(parse(["modhub", "validate", "a_1", "--timeout", "900"]))
        finally:
            tf3ctl.send = real
        # past the mod's own limits, so its answer (or its error) arrives first
        self.assertEqual([(c, t) for c, _, t in sent], [("modhubStatus", 60), ("modhubStatus", 130),
                                                        ("modhubValidate", 330), ("modhubValidate", 930)])
        self.assertIn("validating 50% (Checking files)", err.getvalue())

    def test_persons_args_and_every(self):
        parse = tf3ctl.make_parser().parse_args
        self.assertEqual(tf3ctl.persons_args(parse(["persons", "--vehicle", "601"])), {"vehicle": 601})
        self.assertEqual(tf3ctl.persons_args(parse(["persons", "--line", "21", "--limit", "5"])), {"line": 21, "limit": 5})
        for bad in (["--vehicle", "1", "--count", "3"], ["--vehicle", "1", "--every", "0.1"],
                    ["--vehicle", "1", "--every", "nan"], ["--vehicle", "1", "--every", "inf"],
                    ["--vehicle", "1", "--every", "2", "--count", "0"], ["--vehicle", "1", "--limit", "0"],
                    ["--vehicle", "1", "--limit", "2001"]):
            with self.assertRaises(tf3ctl.ToolError, msg=bad):
                tf3ctl.persons_args(parse(["persons"] + bad))
        for bad in (["persons"], ["persons", "--vehicle", "1", "--line", "2"]):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit, msg=bad):
                parse(bad)
        # read only: no "who changed the game" entry, no warning about another owner
        self.assertNotIn("persons", tf3ctl.CHANGES_GAME)
        got = mod_reads(tf3ctl.command_text(9, "persons", {"vehicle": 601, "limit": 5}))
        self.assertEqual(got["args"], {"vehicle": 601, "limit": 5})
        # the loop: fixed times from the start, one compact line each, ends at the first answer that is not ok
        now = [100.0]
        sleeps = []

        def sleep(sec):
            sleeps.append(round(sec, 3))
            now[0] += sec

        answers = [{"ok": True, "gameTime": 1}, {"ok": True, "gameTime": 2}, {"ok": False, "error": "boom"}]
        sent = []

        def fake_send(cmd, args=None, **_):
            sent.append((cmd, args))
            now[0] += 0.2  # the answer takes a while: the next sample still starts on its time
            return answers[len(sent) - 1]

        out = io.StringIO()
        with unittest.mock.patch.object(tf3ctl, "send", fake_send):
            code = tf3ctl.persons_every(parse(["persons", "--vehicle", "601", "--every", "2", "--count", "5"]),
                                        out=out, sleep=sleep, clock=lambda: now[0])
        self.assertEqual(code, 1)
        rows = [json.loads(x) for x in out.getvalue().splitlines()]
        self.assertEqual([(r["sample"], r["ok"]) for r in rows], [(1, True), (2, True), (3, False)])
        self.assertEqual([r["unixTime"] for r in rows], [100.0, 102.0, 104.0])
        self.assertEqual(sleeps, [1.8, 1.8])
        self.assertEqual(sent, [("persons", {"vehicle": 601})] * 3)
        self.assertNotIn("\n", out.getvalue().splitlines()[0])

        def no_game(cmd, args=None, **_):
            raise tf3ctl.GameNotReady("the game is in the main menu", {"state": "menu"})

        out = io.StringIO()
        with unittest.mock.patch.object(tf3ctl, "send", no_game):
            code = tf3ctl.persons_every(parse(["persons", "--line", "21", "--every", "1"]), out=out, sleep=sleep,
                                        clock=lambda: now[0])
        self.assertEqual(code, 3)
        row = json.loads(out.getvalue())
        self.assertEqual((row["ok"], row["gameState"]["state"], row["sample"]), (False, "menu", 1))

        # no answer in time (a stall): a line with noAnswer, and the loop goes on; exit code 2 at the end
        calls = []

        def stall_once(cmd, args=None, **_):
            calls.append(1)
            if len(calls) == 1:
                raise tf3ctl.ToolError("no answer within 20 s")
            return {"ok": True, "gameTime": 5}

        out = io.StringIO()
        with unittest.mock.patch.object(tf3ctl, "send", stall_once), contextlib.redirect_stderr(io.StringIO()):
            code = tf3ctl.persons_every(parse(["persons", "--vehicle", "601", "--every", "1", "--count", "3"]), out=out,
                                        sleep=sleep, clock=lambda: now[0])
        rows = [json.loads(x) for x in out.getvalue().splitlines()]
        self.assertEqual(code, 2)
        self.assertEqual([(r["sample"], r["ok"], r.get("noAnswer"), r.get("reason")) for r in rows],
                         [(1, False, True, "other"), (2, True, None, None), (3, True, None, None)])
        self.assertEqual(tf3ctl.no_answer_reason(tf3ctl.ToolError("no answer to command 5 in 20 s (x)")), "timeout")
        self.assertEqual(tf3ctl.no_answer_reason(tf3ctl.ToolError("the mod did not pick up command 5 in 30 s")),
                         "notPickedUp")
        self.assertEqual(tf3ctl.no_answer_reason(tf3ctl.ToolError("cannot read /x: y")), "file")
        self.assertEqual(tf3ctl.no_answer_reason(OSError("disk")), "file")

        # a stall past later slots: those are skipped, not sent in a burst; the loop waits for the next slot
        now[0] = 1000.0
        sleeps.clear()
        times = []

        def slow_second(cmd, args=None, **_):
            times.append(now[0])
            if len(times) == 2:
                now[0] += 7.5  # the second sample takes 7.5 s: slots at 1004, 1006, 1008 go by
            return {"ok": True}

        out, err = io.StringIO(), io.StringIO()
        with unittest.mock.patch.object(tf3ctl, "send", slow_second), contextlib.redirect_stderr(err):
            code = tf3ctl.persons_every(parse(["persons", "--vehicle", "601", "--every", "2", "--count", "4"]), out=out,
                                        sleep=sleep, clock=lambda: now[0])
        rows = [json.loads(x) for x in out.getvalue().splitlines()]
        self.assertEqual(code, 0)
        self.assertEqual(times, [1000.0, 1002.0, 1010.0, 1012.0], "no burst after the stall")
        self.assertEqual([(r["sample"], r.get("skipped")) for r in rows], [(1, None), (2, None), (6, 3), (7, None)])
        self.assertIn("3 slots skipped", err.getvalue())

        # Ctrl-C: the counts are still said
        def interrupt(cmd, args=None, **_):
            if len(calls) >= 2:
                raise KeyboardInterrupt
            calls.append(1)
            raise tf3ctl.ToolError("no answer to command 1 in 20 s")

        calls.clear()
        err = io.StringIO()
        with unittest.mock.patch.object(tf3ctl, "send", interrupt), contextlib.redirect_stderr(err), \
                self.assertRaises(KeyboardInterrupt):
            tf3ctl.persons_every(parse(["persons", "--vehicle", "601", "--every", "1"]), out=io.StringIO(),
                                 sleep=sleep, clock=lambda: now[0])
        self.assertIn("2 of 2 samples got no answer", err.getvalue())

    def test_vehicles_at_terminal_and_every(self):
        parse = tf3ctl.make_parser().parse_args
        self.assertEqual(tf3ctl.vehicles_args(parse(["vehicles", "--entity", "601", "--state", "--at-terminal"])),
                         {"limit": 200, "entities": [601], "state": True, "atTerminal": True})
        # without the new flags the args are as before (no atTerminal key)
        self.assertEqual(tf3ctl.vehicles_args(parse(["vehicles", "--entity", "601", "--state"])),
                         {"limit": 200, "entities": [601], "state": True})
        for bad in (["--at-terminal"], ["--state", "--count", "3"], ["--state", "--every", "0.1"],
                    ["--state", "--every", "nan"], ["--state", "--every", "2", "--count", "0"]):
            with self.assertRaises(tf3ctl.ToolError, msg=bad):
                tf3ctl.vehicles_args(parse(["vehicles"] + bad))
        got = mod_reads(tf3ctl.command_text(9, "vehicles", {"limit": 200, "state": True, "atTerminal": True}))
        self.assertEqual(got["args"], {"limit": 200, "state": True, "atTerminal": True})
        self.assertNotIn("vehicles", tf3ctl.CHANGES_GAME)
        # --every: the persons loop with the vehicles command; each line keeps the answer's gameTime
        now = [50.0]

        def sleep(sec):
            now[0] += sec

        sent = []

        def fake_send(cmd, args=None, **_):
            sent.append((cmd, args))
            return {"ok": True, "gameTime": 1000 * len(sent), "total": 1, "vehicles": [{"entity": 601}]}

        out = io.StringIO()
        with unittest.mock.patch.object(tf3ctl, "send", fake_send):
            code = tf3ctl.vehicles_every(parse(["vehicles", "--entity", "601", "--state", "--at-terminal", "--every",
                                                "2", "--count", "3"]), out=out, sleep=sleep, clock=lambda: now[0])
        self.assertEqual(code, 0)
        rows = [json.loads(x) for x in out.getvalue().splitlines()]
        self.assertEqual([(r["sample"], r["gameTime"], r["unixTime"]) for r in rows],
                         [(1, 1000, 50.0), (2, 2000, 52.0), (3, 3000, 54.0)])
        self.assertEqual(sent, [("vehicles", {"limit": 200, "entities": [601], "state": True, "atTerminal": True})] * 3)
        # main runs the loop for vehicles --every (and a plain call still sends once)
        out = io.StringIO()
        sent.clear()
        with unittest.mock.patch.object(tf3ctl, "send", fake_send), \
                unittest.mock.patch.object(tf3ctl, "vehicles_every", lambda ns: sent.append("loop") or 0):
            self.assertEqual(tf3ctl.main(["vehicles", "--state", "--every", "1", "--count", "2"]), 0)
        self.assertEqual(sent, ["loop"])

    def test_line_force_unload_args(self):
        parse = tf3ctl.make_parser().parse_args
        args = tf3ctl.line_args(parse(["line", "update", "23", "--force-unload", "0, 1"]))
        self.assertEqual(args, {"action": "update", "via": "gui", "line": 23, "forceUnload": [False, True]})
        self.assertEqual(tf3ctl.line_args(parse(["line", "create", "--stops", "47,48,49", "--force-unload", "1,0,1"]))
                         ["forceUnload"], [True, False, True])
        # the mod reads them as booleans, in order
        got = mod_reads(tf3ctl.command_text(9, "line", args))
        self.assertEqual(got["args"]["forceUnload"], [False, True])
        for bad, why in ((["line", "update", "23", "--force-unload", "2,0"], "item 1"),
                         (["line", "update", "23", "--force-unload", "0,"], "item 2"),
                         (["line", "update", "23", "--force-unload", "yes"], "item 1"),
                         (["line", "create", "--stops", "47,48", "--force-unload", "1"], "one for every stop"),
                         (["line", "create", "--stops", "47,48", "--force-unload", "1,1,0"], "one for every stop")):
            with self.assertRaises(tf3ctl.ToolError, msg=bad) as cm:
                tf3ctl.line_args(parse(bad))
            self.assertIn(why, str(cm.exception))
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            parse(["line", "delete", "23", "--force-unload", "0,1"])

    def test_line_args(self):
        def parse(*argv):
            ns = tf3ctl.argparse.Namespace
            p = {"create": ns(action="create", via="gui", stops=None, name=None, cargo=None),
                 "update": ns(action="update", via="gui", line=None, stops=None, name=None, cargo=None),
                 "delete": ns(action="delete", line=None, sell_vehicles=False)}[argv[0]]
            for k, v in zip(argv[1::2], argv[2::2]):
                setattr(p, k, v)
            return tf3ctl.line_args(p)
        self.assertEqual(parse("create", "stops", " Central , 42,Harbour Bay ", "name", "[probe] A"),
                         {"action": "create", "via": "gui", "stops": ["Central", 42, "Harbour Bay"], "name": "[probe] A"})
        self.assertEqual(parse("update", "line", 21, "cargo", "grain", "via", "cmd"),
                         {"action": "update", "via": "cmd", "line": 21, "cargo": "grain"})
        self.assertEqual(parse("delete", "line", 21, "sell_vehicles", True),
                         {"action": "delete", "line": 21, "sellVehicles": True})
        self.assertEqual(parse("delete", "line", 21), {"action": "delete", "line": 21})
        for bad in (("create", "stops", ""), ("create", "stops", " , "), ("create", "stops", "A,,B"),
                    ("create", "stops", "A,"), ("update", "line", 21)):
            with self.assertRaises(tf3ctl.ToolError, msg=bad):
                parse(*bad)
        # what the mod reads back from the command file: the list in order, ids as numbers
        got = mod_reads(tf3ctl.command_text(9, "line", parse("create", "stops", "Central,42")))
        self.assertEqual(got["args"]["stops"], ["Central", 42])
        self.assertNotIn("terminals", got["args"], "none given: the engine assigns, as before")
        # --terminals: station:terminal (or a terminal of station 0), one per stop; --load-mode one or one per stop
        self.assertEqual(parse("create", "stops", "47,48", "terminals", "0:2, 1 : 0", "load_mode", "ANY"),
                         {"action": "create", "via": "gui", "stops": [47, 48],
                          "terminals": [{"station": 0, "terminal": 2}, {"station": 1, "terminal": 0}], "loadModes": "any"})
        self.assertEqual(parse("create", "stops", "47,48", "terminals", "2,1", "load_mode", "all,available")["terminals"],
                         [{"station": 0, "terminal": 2}, {"station": 0, "terminal": 1}])
        self.assertEqual(parse("create", "stops", "47,48", "load_mode", "all,available")["loadModes"], ["all", "available"])
        self.assertEqual(parse("update", "line", 23, "terminals", "0:2,0:1"),
                         {"action": "update", "via": "gui", "line": 23,
                          "terminals": [{"station": 0, "terminal": 2}, {"station": 0, "terminal": 1}]},
                         "an update of the line's own stops: the mod checks the count")
        self.assertEqual(parse("update", "line", 23, "load_mode", "any")["loadModes"], "any")
        got = mod_reads(tf3ctl.command_text(9, "line", parse("create", "stops", "47,48", "terminals", "0:2,0:1",
                                                             "load_mode", "all,any")))
        self.assertEqual(got["args"]["terminals"], [{"station": 0, "terminal": 2}, {"station": 0, "terminal": 1}])
        self.assertEqual(got["args"]["loadModes"], ["all", "any"])
        for bad, why in ((("create", "stops", "47,48", "terminals", "0:2"), "one for every stop"),
                         (("create", "stops", "47,48", "terminals", "0:2,0:1,0:0"), "one for every stop"),
                         (("create", "stops", "47,48", "terminals", "0:2,"), "item 2"),
                         (("create", "stops", "47,48", "terminals", "0:-1,0:1"), "item 1"),
                         (("create", "stops", "47,48", "terminals", "a,1"), "item 1"),
                         (("create", "stops", "47,48", "terminals", "0:1:2,1"), "item 1"),
                         (("create", "stops", "47,48", "load_mode", "fast"), "available, any or all"),
                         (("create", "stops", "47,48", "load_mode", "any,"), "item 2"),
                         (("create", "stops", "47,48", "load_mode", "legacy_unload_only"), "available, any or all"),
                         (("create", "stops", "47,48,49", "load_mode", "any,all"), "one for every stop, or one for all")):
            with self.assertRaises(tf3ctl.ToolError, msg=bad) as cm:
                parse(*bad)
            self.assertIn(why, str(cm.exception))
        self.assertIn("line", tf3ctl.CHANGES_GAME)
        self.assertFalse({"stations", "lines"} & tf3ctl.CHANGES_GAME)
        # lines --problems --line N: read only, args only when given
        p = tf3ctl.make_parser()
        self.assertEqual(tf3ctl.lines_args(p.parse_args(["lines"])), {})
        self.assertEqual(tf3ctl.lines_args(p.parse_args(["lines", "--problems", "--line", "23", "--name", "Ship"])),
                         {"name": "Ship", "line": 23, "problems": True})
        with self.assertRaises(SystemExit):
            with contextlib.redirect_stderr(io.StringIO()):
                p.parse_args(["lines", "--line", "x"])
        ns = tf3ctl.argparse.Namespace
        self.assertEqual(tf3ctl.stations_args(ns(name="cen", near=11, radius=500.0)),
                         {"name": "cen", "near": 11, "radius": 500.0})
        self.assertEqual(tf3ctl.stations_args(ns(name=None, near=None, radius=None)), {})
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.stations_args(ns(name=None, near=None, radius=5.0))
        # --catchment: one id, alone; read only
        self.assertEqual(tf3ctl.stations_args(ns(name=None, near=None, radius=None, catchment=47)), {"catchment": 47})
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.stations_args(ns(name="Port", near=None, radius=None, catchment=47))
        self.assertEqual(tf3ctl.make_parser().parse_args(["stations", "--catchment", "47"]).catchment, 47)
        # with --catchment: --radius (the diagnosis' circle when the engine gives none) and --paths
        self.assertEqual(tf3ctl.stations_args(ns(name=None, near=None, radius=150.0, catchment=47, paths=0)),
                         {"catchment": 47, "radius": 150.0, "paths": 0})
        for bad in (dict(radius=0.0), dict(radius=2001.0), dict(paths=-1), dict(paths=51)):
            kw = dict(name=None, near=None, radius=None, catchment=47, paths=None)
            kw.update(bad)
            with self.assertRaises(tf3ctl.ToolError, msg=bad):
                tf3ctl.stations_args(ns(**kw))
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.stations_args(ns(name=None, near=None, radius=None, catchment=None, paths=3))
        a = tf3ctl.make_parser().parse_args(["stations", "--catchment", "47", "--paths", "5", "--radius", "150"])
        self.assertEqual((a.paths, a.radius), (5, 150.0))
        # argparse: create needs --stops, update and delete the line id
        for bad in (["line"], ["line", "create"], ["line", "update"], ["line", "delete"], ["line", "create", "--stops",
                    "A,B", "--via", "react"], ["line", "delete", "21", "--stops", "A,B"], ["stations", "--near", "x"],
                    ["line", "delete", "21", "--terminals", "0:1"], ["line", "delete", "21", "--load-mode", "any"]):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit, msg=bad):
                tf3ctl.main(bad)

    def test_connect_args(self):
        def parse(*argv):
            ns = tf3ctl.argparse.Namespace(from_="101", to="Harbour", road=False, template=None, track=None,
                                           electric=False, slope=None, radius=None, bridges=None, tunnels=None,
                                           build=False, clear=False, timeout=120.0)
            for k, v in zip(argv[0::2], argv[1::2]):
                setattr(ns, k, v)
            return tf3ctl.connect_args(ns)
        self.assertEqual(parse(), {"from": 101, "to": "Harbour", "timeout": 120.0})
        self.assertEqual(parse("to", " 42 ", "slope", 3.0, "radius", 250.0, "bridges", False, "build", True,
                               "clear", True, "track", "high_speed", "electric", True),
                         {"from": 101, "to": 42, "slope": 3.0, "radius": 250.0, "bridges": False, "build": True,
                          "clear": True, "track": "high_speed", "electric": True, "timeout": 120.0})
        self.assertEqual(parse("road", True, "template", "::/x.street_template", "tunnels", False),
                         {"from": 101, "to": "Harbour", "road": True, "template": "::/x.street_template",
                          "tunnels": False, "timeout": 120.0})
        self.assertNotIn("bridges", parse("bridges", True), "on is the mod's default: not sent")
        self.assertEqual(parse("to", "12²")["to"], "12²", "a Unicode digit is no id: a name")
        for bad in (("from_", " "), ("to", ""), ("clear", True), ("road", True, "track", "standard"),
                    ("road", True, "electric", True), ("template", "::/x.street_template")):
            with self.assertRaises(tf3ctl.ToolError, msg=bad):
                parse(*bad)
        # what the mod reads back from the command file
        got = mod_reads(tf3ctl.command_text(9, "connect", parse("to", "103", "bridges", False, "build", True)))
        self.assertEqual(got["args"], {"from": 101, "to": 103, "bridges": False, "build": True, "timeout": 120})
        self.assertIn("connect", tf3ctl.CHANGES_GAME)
        # argparse: --no-bridges / --no-tunnels understood, neither given means the mod's default
        parsed = tf3ctl.make_parser().parse_args(["connect", "--from", "1", "--to", "2", "--no-bridges", "--tunnels"])
        self.assertEqual((parsed.bridges, parsed.tunnels), (False, True))
        self.assertEqual(tf3ctl.connect_args(parsed)["bridges"], False)
        self.assertNotIn("tunnels", tf3ctl.connect_args(parsed))
        parsed = tf3ctl.make_parser().parse_args(["connect", "--from", "1", "--to", "2"])
        self.assertEqual((parsed.bridges, parsed.tunnels), (None, None))
        # argparse: both ends needed, numbers checked
        for bad in (["connect"], ["connect", "--from", "1"], ["connect", "--to", "1"],
                    ["connect", "--from", "1", "--to", "2", "--slope", "steep"],
                    ["connect", "--from", "1", "--to", "2", "--bridges", "no"]):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit, msg=bad):
                tf3ctl.main(bad)

    def test_menu_probe_needs_a_menu_hello_from_the_running_game(self):
        d = tempfile.mkdtemp()
        hello = os.path.join(d, "remote_probe__hello_1_1.lua")
        write(hello, 'function data() return { json = "{\\"menu\\":true,\\"stamp\\":\\"1_1\\"}" } end')
        tf3ctl.game_pids = lambda: [42]
        tf3ctl.process_start = lambda pid: time.time() - 60
        log = os.path.join(d, "stdout.txt")
        write(log, log_line("08:30:31", "Main menu is ready") + "\n")
        os.environ["TF3_LOG"] = log
        self.assertTrue(tf3ctl.menu_probe(d))
        write(log, log_line("08:30:31", "Main menu is ready") + "\n" + log_line("08:31:00", "Game is ready") + "\n")
        self.assertIsNone(tf3ctl.menu_probe(d), "a save loaded by hand: the menu copy stopped")
        write(log, log_line("08:30:31", "Main menu is ready") + "\n")
        tf3ctl.process_start = lambda pid: time.time() + 60  # the game started after this hello was written
        self.assertIsNone(tf3ctl.menu_probe(d), "a menu hello of an earlier run")
        tf3ctl.process_start = lambda pid: time.time() - 60
        write(hello, 'function data() return { json = "{\\"menu\\":false}" } end')
        self.assertIsNone(tf3ctl.menu_probe(d), "a hello from inside a save")
        tf3ctl.game_pids = lambda: []
        write(hello, 'function data() return { json = "{\\"menu\\":true}" } end')
        self.assertIsNone(tf3ctl.menu_probe(d), "no game running")
        self.assertIsNone(tf3ctl.menu_probe(tempfile.mkdtemp()), "no hello")

    def test_a_command_in_the_main_menu_waits_for_the_menu_probe(self):
        d = tempfile.mkdtemp()
        write(os.path.join(d, "remote_probe__hello_1_1.lua"),
              'function data() return { json = "{\\"menu\\":true}" } end')
        log = os.path.join(d, "stdout.txt")
        write(log, log_line("08:30:31", "Main menu is ready") + "\n")
        os.environ["TF3_LOG"] = log
        os.environ["TF3_ASSUME_RUNNING"] = "1"

        def answer_later():
            time.sleep(tf3ctl.NOT_READY_GRACE_SEC + 1.5)  # after the check that used to give up
            write(os.path.join(d, "remote_probe__res_%d.lua" % tf3ctl.new_id.last),
                  'function data() return { json = "{\\"ok\\":true}" } end')
        real_new_id = tf3ctl.new_id

        def new_id():
            new_id.last = real_new_id()
            threading.Thread(target=answer_later, daemon=True).start()
            return new_id.last
        tf3ctl.new_id = new_id
        try:
            self.assertEqual(tf3ctl.send("status", folder=d), {"ok": True})
        finally:
            tf3ctl.new_id = real_new_id
        write(os.path.join(d, "remote_probe__hello_1_1.lua"),
              'function data() return { json = "{\\"menu\\":false}" } end')
        with self.assertRaises(tf3ctl.GameNotReady):
            tf3ctl.send("status", folder=d)


PROFILE = """function data()
return {
	mods = { },
	profile = {
		language = { 
			code = "ja",
			mod = { "", },
		},
		lastGame = { 0, },
	},
}
end
"""


class LanguageTest(unittest.TestCase):
    """launch / restart --lang: profile.lua's language for one start, and putting it back."""

    def setUp(self):
        self.saved = {k: getattr(tf3ctl, k) for k in ("game_pids", "send", "launch_game", "quit_game")}
        self.saved_env = {k: os.environ.get(k) for k in ("TF3_PROFILE", "TF3_GAME_DIR", "TF3CTL_OTHER_BACKUPS",
                                                         "TF3_REMOTE_DIR")}
        self.d = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.d, ignore_errors=True)
        self.profile = os.path.join(self.d, "profile.lua")
        self.backup = self.profile + tf3ctl.PROFILE_BACKUP_SUFFIX
        write(self.profile, PROFILE)
        game = os.path.join(self.d, "game")
        for lang in ("de", "en", "ja", "pt_BR"):
            os.makedirs(os.path.join(game, "base", "strings", lang))
        os.environ.update(TF3_PROFILE=self.profile, TF3_GAME_DIR=game, TF3_REMOTE_DIR=self.d)
        os.environ.pop("TF3CTL_OTHER_BACKUPS", None)
        self.pids = []
        tf3ctl.game_pids = lambda: list(self.pids)
        self.launched = []  # the profile's language each time the game was started

        def fake_launch(timeout=None):
            self.launched.append(tf3ctl.profile_language(self.profile))
            self.pids.append(77)
            return {"ok": True, "menu": True}
        tf3ctl.launch_game = fake_launch

        def fake_quit(timeout=None, kill=False, force=False):
            if not self.pids:
                return {"ok": True, "how": "not running"}
            self.pids.clear()
            return {"ok": True, "how": "quit"}
        tf3ctl.quit_game = fake_quit
        tf3ctl.send = lambda cmd, args=None, **kw: {"ok": True, "cmd": cmd}
        self.saved_pause = tf3ctl.RELAUNCH_PAUSE_SEC
        tf3ctl.RELAUNCH_PAUSE_SEC = 0
        tf3ctl._warned["install"] = False

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(tf3ctl, k, v)
        tf3ctl.RELAUNCH_PAUSE_SEC = self.saved_pause
        for k, v in self.saved_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    def ctl(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = tf3ctl.main(list(argv))
        self.err = err.getvalue()
        return code, json.loads(out.getvalue()) if out.getvalue().strip() else None

    def test_launch_with_lang_backs_up_and_quit_puts_it_back(self):
        code, res = self.ctl("launch", "--lang", "de")
        self.assertEqual(code, 0, self.err)
        self.assertEqual(self.launched, ["de"])
        self.assertEqual(res["language"]["was"], "ja")
        self.assertEqual(read(self.backup), PROFILE, "the backup is the original")
        self.assertEqual(read(self.profile), PROFILE.replace('code = "ja"', 'code = "de"'), "only the code changed")
        code, res = self.ctl("state")
        self.assertEqual(res["profileBackup"]["language"], "de")
        self.assertEqual(res["profileBackup"]["originalLanguage"], "ja")
        code, res = self.ctl("status")
        self.assertEqual(res["profileBackup"]["backup"], self.backup)
        code, res = self.ctl("quit")
        self.assertEqual(code, 0, self.err)
        self.assertEqual(res["profileRestored"]["language"], "ja")
        self.assertEqual(read(self.profile), PROFILE)
        self.assertFalse(os.path.exists(self.backup), "removed once equal")
        code, res = self.ctl("state")
        self.assertNotIn("profileBackup", res)

    def test_a_second_lang_keeps_the_first_backup(self):
        tf3ctl.set_profile_language("de")
        tf3ctl.set_profile_language("en")
        self.assertEqual(tf3ctl.profile_language(self.profile), "en")
        self.assertEqual(read(self.backup), PROFILE, "still the original, not the German one")
        tf3ctl.restore_profile()
        self.assertEqual(read(self.profile), PROFILE)

    def test_restart_with_lang_twice_starts_from_the_original(self):
        self.assertEqual(self.ctl("launch", "--lang", "de")[0], 0, self.err)
        self.assertEqual(self.ctl("restart", "--lang", "en")[0], 0, self.err)
        self.assertEqual(self.launched, ["de", "en"])
        self.assertEqual(read(self.backup), PROFILE)
        code, res = self.ctl("restart")
        self.assertEqual(code, 0, self.err)
        self.assertEqual(self.launched[-1], "ja", "no --lang: the player's own language")
        self.assertEqual(res["profileRestored"]["language"], "ja")
        self.assertFalse(os.path.exists(self.backup))

    def test_launch_after_a_crash_puts_it_back_first(self):
        tf3ctl.set_profile_language("de")  # the game ran in German and crashed: the backup is left
        code, res = self.ctl("launch")
        self.assertEqual(code, 0, self.err)
        self.assertEqual(self.launched, ["ja"])
        self.assertEqual(res["profileRestored"]["restored"], self.profile)
        self.assertNotIn("language", res)

    def test_quit_of_a_crashed_game_and_restore_profile_put_it_back(self):
        tf3ctl.set_profile_language("de")
        code, res = self.ctl("quit")
        self.assertEqual((code, res["how"]), (0, "not running"))
        self.assertEqual(read(self.profile), PROFILE)
        tf3ctl.set_profile_language("de")
        code, res = self.ctl("restore-profile")
        self.assertEqual(code, 0, self.err)
        self.assertEqual(read(self.profile), PROFILE)
        code, res = self.ctl("restore-profile")
        self.assertEqual(code, 0)
        self.assertIsNone(res["profileRestored"], "nothing to do is no error")

    def test_nothing_is_touched_while_the_game_runs(self):
        tf3ctl.set_profile_language("de")
        changed = read(self.profile)
        self.pids.append(5)
        code, _ = self.ctl("restore-profile")
        self.assertEqual(code, 2)
        self.assertIn("running", self.err)
        self.assertEqual(read(self.profile), changed)
        self.assertTrue(os.path.exists(self.backup))
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.set_profile_language("en")
        self.assertEqual(read(self.profile), changed)
        code, _ = self.ctl("launch", "--lang", "en")
        self.assertEqual(code, 2)
        self.assertIn("already running", self.err)
        self.assertEqual(read(self.profile), changed)
        self.assertEqual(self.launched, [])

    def test_a_restore_that_does_not_come_out_equal_keeps_the_backup(self):
        tf3ctl.set_profile_language("de")

        def bad_write(path, data):
            write(path, "something else\n")
        with unittest.mock.patch.object(tf3ctl, "write_replacing", bad_write):
            with self.assertRaises(tf3ctl.ToolError) as cm:
                tf3ctl.restore_profile()
        self.assertIn("backup is kept", str(cm.exception))
        self.assertTrue(os.path.exists(self.backup))
        self.assertEqual(read(self.backup), PROFILE)

    def test_a_profile_without_one_language_block_is_left_alone(self):
        for text in (PROFILE.replace("language = { ", "lang = { "),
                     PROFILE.replace("\t\tlastGame", '\t\tlanguage = { code = "en", },\n\t\tlastGame'),
                     PROFILE.replace('code = "ja",', "")):
            write(self.profile, text)
            with self.assertRaises(tf3ctl.ToolError):
                tf3ctl.set_profile_language("de")
            self.assertEqual(read(self.profile), text)
            self.assertFalse(os.path.exists(self.backup), "no backup of a file that was not changed")

    def test_the_language_block_on_one_line(self):
        write(self.profile, 'profile = {\n\tlanguage = { code = "en", mod = { "", }, },\n}\n')
        tf3ctl.set_profile_language("ja")
        self.assertEqual(read(self.profile), 'profile = {\n\tlanguage = { code = "ja", mod = { "", }, },\n}\n')

    def test_bad_language_codes_are_refused_before_anything_is_quit(self):
        self.pids.append(5)
        for bad in ("deu", "DE", "d", "de-DE", "", "fr", "de\n"):  # fr: the test install has no French
            code, _ = self.ctl("restart", "--lang", bad)
            self.assertEqual(code, 2, bad)
            self.assertEqual(self.pids, [5], "not quit: " + bad)
        self.assertEqual(read(self.profile), PROFILE)
        tf3ctl.check_lang("pt_BR")
        os.environ["TF3_GAME_DIR"] = os.path.join(self.d, "nowhere")  # install not found: only the shape is checked
        tf3ctl.check_lang("fr")

    def test_the_install_is_found_beside_the_userdata(self):
        steam = os.path.join(self.d, "Steam")
        local = os.path.join(steam, "userdata", "123", tf3ctl.APP_ID, "local")
        os.makedirs(os.path.join(steam, "steamapps", "common", "Transport Fever 3", "base", "strings", "ko"))
        os.environ.pop("TF3_GAME_DIR")
        with unittest.mock.patch.object(tf3ctl, "userdata_roots", lambda: [local]):
            self.assertEqual(tf3ctl.game_languages(), ["ko"])

    def test_restart_refuses_before_the_quit_what_it_would_refuse_after(self):
        self.pids.append(5)
        write(self.profile, PROFILE.replace("language = { ", "lang = { "))
        code, _ = self.ctl("restart", "--lang", "de")
        self.assertEqual(code, 2)
        self.assertEqual(self.pids, [5], "a profile of another shape: not quit")
        write(self.profile, PROFILE)
        other = os.path.join(self.d, "other.lua")
        write(other, PROFILE)
        os.environ["TF3CTL_OTHER_BACKUPS"] = other
        code, _ = self.ctl("restart", "--lang", "de")
        self.assertEqual(code, 2)
        self.assertEqual(self.pids, [5], "another tool's backup: not quit")
        os.environ["TF3_PROFILE"] = os.path.join(self.d, "missing.lua")
        os.environ.pop("TF3CTL_OTHER_BACKUPS")
        code, _ = self.ctl("restart", "--lang", "de")
        self.assertEqual(code, 2)
        self.assertEqual(self.pids, [5], "no profile: not quit")
        code, _ = self.ctl("restart")
        self.assertEqual(code, 0, "without --lang the profile does not matter")

    def test_a_failed_restore_after_quit_still_shows_the_quit(self):
        tf3ctl.set_profile_language("de")
        self.pids.append(5)
        other = os.path.join(self.d, "other.lua")
        write(other, PROFILE)
        os.environ["TF3CTL_OTHER_BACKUPS"] = other
        code, res = self.ctl("quit")
        self.assertEqual(code, 1)
        self.assertEqual(res["how"], "quit")
        self.assertIn(other, res["profileError"])
        self.assertTrue(os.path.exists(self.backup))

    def test_status_shows_the_backup_when_the_game_cannot_answer(self):
        tf3ctl.set_profile_language("de")

        def not_ready(*a, **kw):
            raise tf3ctl.GameNotReady("loading", {"state": "loading"})
        tf3ctl.send = not_ready
        code, res = self.ctl("status")
        self.assertEqual(code, 3)
        self.assertEqual(res["profileBackup"]["originalLanguage"], "ja")

    def test_the_profile_next_to_the_exchange_folder(self):
        local = os.path.join(self.d, "local")
        os.makedirs(os.path.join(local, "mod_presets"))
        write(os.path.join(local, "profile.lua"), PROFILE)
        os.environ.pop("TF3_PROFILE")
        os.environ["TF3_REMOTE_DIR"] = os.path.join(local, "mod_presets")
        self.assertEqual(tf3ctl.profile_path(), os.path.join(local, "profile.lua"))

    def test_the_same_language_changes_nothing(self):
        res = tf3ctl.set_profile_language("ja")
        self.assertFalse(res["changed"])
        self.assertFalse(os.path.exists(self.backup))

    def test_another_tools_backup_blocks_lang_and_the_restore(self):
        other = os.path.join(self.d, "other_backup", "profile.lua")
        os.environ["TF3CTL_OTHER_BACKUPS"] = os.path.join(self.d, "absent") + os.pathsep + other
        os.makedirs(os.path.dirname(other))
        tf3ctl.set_profile_language("de")
        write(other, PROFILE)  # taken after ours: it has to go back first
        with self.assertRaises(tf3ctl.ToolError) as cm:
            tf3ctl.restore_profile()
        self.assertIn(other, str(cm.exception))
        self.assertTrue(os.path.exists(self.backup))
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.set_profile_language("en")
        os.remove(other)
        tf3ctl.restore_profile()
        self.assertEqual(read(self.profile), PROFILE)

    def test_without_lang_and_backup_nothing_changes(self):
        mtime = os.path.getmtime(self.profile)
        code, res = self.ctl("launch")
        self.assertEqual(code, 0, self.err)
        self.assertNotIn("profileRestored", res)
        self.assertNotIn("language", res)
        self.ctl("quit")
        self.assertEqual(os.path.getmtime(self.profile), mtime)
        self.assertEqual(sorted(os.listdir(self.d)), ["game", "profile.lua"], "no backup or temporary file left")

    def leftovers(self):
        return sorted(n for n in os.listdir(self.d) if n.endswith((".tf3ctl-tmp", ".tmp")))

    def test_the_restore_puts_back_only_the_code(self):
        tf3ctl.set_profile_language("de")
        # the game ran in German for days and wrote the player's later changes into the file
        later = read(self.profile).replace("lastGame = { 0, }", 'lastGame = { 3, "my save", }')
        write(self.profile, later)
        res = tf3ctl.restore_profile()
        self.assertEqual(res["language"], "ja")
        self.assertEqual(read(self.profile), later.replace('code = "de"', 'code = "ja"'), "the later changes stay")
        self.assertFalse(os.path.exists(self.backup))

    def test_a_restore_with_the_code_already_back_only_removes_the_backup(self):
        tf3ctl.set_profile_language("de")
        write(self.profile, PROFILE)  # the player chose Japanese again in the game's settings
        mtime = os.path.getmtime(self.profile)
        self.assertEqual(tf3ctl.restore_profile()["language"], "ja")
        self.assertEqual(os.path.getmtime(self.profile), mtime, "not written")
        self.assertFalse(os.path.exists(self.backup))

    def test_a_restore_between_files_of_another_shape_keeps_the_backup(self):
        tf3ctl.set_profile_language("de")
        changed = read(self.profile)
        def two(text):
            return text.replace("\t\tlastGame", '\t\tlanguage = { code = "en", },\n\t\tlastGame')
        for name, text in (("backup", PROFILE.replace("language = { ", "lang = { ")), ("backup", two(PROFILE)),
                           ("profile", changed.replace("language = { ", "lang = { ")), ("profile", two(changed))):
            write(self.backup, PROFILE)
            write(self.profile, changed)
            write(self.backup if name == "backup" else self.profile, text)
            before = read(self.profile)
            with self.assertRaises(tf3ctl.ToolError):
                tf3ctl.restore_profile()
            self.assertTrue(os.path.exists(self.backup), name)
            self.assertEqual(read(self.profile), before, name)
            self.pids.append(5)  # restart refuses it before the quit, too
            code, _ = self.ctl("restart")
            self.assertEqual((code, self.pids), (2, [5]), name)
            self.pids.clear()
            code, res = self.ctl("quit")
            self.assertEqual(code, 1, name)
            self.assertIn("profileError", res)
            self.assertTrue(os.path.exists(self.backup), name)

    def test_another_tools_backup_folder_counts_only_with_a_file_in_it(self):
        folder = os.path.join(self.d, "settings_backup")
        os.makedirs(os.path.join(folder, "sub"))
        missing = os.path.join(self.d, "absent.lua")
        os.environ["TF3CTL_OTHER_BACKUPS"] = folder + os.pathsep + missing
        self.assertEqual(tf3ctl.other_backups(), [], "an empty folder (its copies put back) is no backup")
        tf3ctl.set_profile_language("de")
        tf3ctl.restore_profile()
        write(os.path.join(folder, "sub", "profile.lua"), PROFILE)
        self.assertEqual(tf3ctl.other_backups(), [folder], "a file inside, at any depth")
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.set_profile_language("de")
        os.remove(os.path.join(folder, "sub", "profile.lua"))
        write(missing, PROFILE)
        self.assertEqual(tf3ctl.other_backups(), [missing], "a file while it exists")

    def test_restart_failing_after_the_quit_shows_the_quit_and_leaves_no_temporary_file(self):
        self.assertEqual(self.ctl("launch", "--lang", "de")[0], 0, self.err)
        real_replace = os.replace

        def full_disk(src, dst):
            if dst == self.profile:
                raise OSError(28, "No space left on device")
            real_replace(src, dst)
        with unittest.mock.patch.object(tf3ctl.os, "replace", full_disk):
            code, res = self.ctl("restart", "--lang", "en")
        self.assertEqual(code, 1)
        self.assertEqual(res["quit"]["how"], "quit")
        self.assertFalse(res["ok"])
        self.assertIn("No space left", res["profileError"])
        self.assertNotIn("launch", res)
        self.assertEqual(self.launched, ["de"], "not started again")
        self.assertEqual(self.leftovers(), [])
        self.assertEqual(read(self.backup), PROFILE)
        self.assertEqual(self.ctl("restore-profile")[0], 0, self.err)
        self.assertEqual(read(self.profile), PROFILE)

    def test_restart_interrupted_after_the_quit_shows_the_quit(self):
        self.assertEqual(self.ctl("launch", "--lang", "de")[0], 0, self.err)

        def interrupted(profile):
            raise KeyboardInterrupt
        with unittest.mock.patch.object(tf3ctl, "profile_lock", interrupted):
            code, res = self.ctl("restart")
        self.assertEqual(code, 1)
        self.assertEqual((res["quit"]["how"], res["profileError"]), ("quit", "interrupted"))
        self.assertIn("the game quit", self.err)
        self.assertTrue(os.path.exists(self.backup))

    def test_restart_of_a_game_not_running_says_so_when_the_profile_fails(self):
        tf3ctl.set_profile_language("de")
        with unittest.mock.patch.object(tf3ctl, "write_replacing",
                                        lambda p, d: (_ for _ in ()).throw(OSError(28, "No space left on device"))):
            code, res = self.ctl("restart")
        self.assertEqual((code, res["quit"]["how"]), (1, "not running"))
        self.assertIn("the game was not running", self.err)

    def test_launch_with_an_os_error_is_a_plain_refusal(self):
        with unittest.mock.patch.object(tf3ctl, "write_replacing",
                                        lambda p, d: (_ for _ in ()).throw(OSError(13, "Permission denied"))):
            code, res = self.ctl("launch", "--lang", "de")
        self.assertEqual((code, res), (2, None))
        self.assertIn("Permission denied", self.err)
        self.assertEqual(self.launched, [])

    def test_launch_failing_before_the_start_is_refused_as_before(self):
        def bad_copy(profile, backup):
            raise tf3ctl.ToolError("--lang: the backup of %s did not come out equal to it" % profile)
        with unittest.mock.patch.object(tf3ctl, "copy_backup", bad_copy):
            code, res = self.ctl("launch", "--lang", "de")
        self.assertEqual((code, res), (2, None), "nothing was quit: the plain refusal")
        self.assertEqual(self.launched, [])

    def test_a_failed_or_interrupted_write_leaves_no_temporary_file(self):
        real_replace = os.replace
        for exc in (OSError(28, "No space left on device"), KeyboardInterrupt()):
            def fail(src, dst, exc=exc):
                raise exc
            with unittest.mock.patch.object(tf3ctl.os, "replace", fail):
                with self.assertRaises(type(exc)):
                    tf3ctl.set_profile_language("de")  # the backup's rename fails
            self.assertEqual(self.leftovers(), [], repr(exc))
            self.assertFalse(os.path.exists(self.backup))
            self.assertEqual(read(self.profile), PROFILE)

            def fail_profile(src, dst, exc=exc):
                if dst == self.profile:
                    raise exc
                real_replace(src, dst)
            with unittest.mock.patch.object(tf3ctl.os, "replace", fail_profile):
                with self.assertRaises(type(exc)):
                    tf3ctl.set_profile_language("de")
            self.assertEqual(self.leftovers(), [], repr(exc))
            self.assertEqual(read(self.profile), PROFILE)
            os.remove(self.backup)

    def test_the_writes_are_synced_before_the_rename(self):
        order = []
        real_fsync, real_replace = os.fsync, os.replace
        with unittest.mock.patch.object(tf3ctl.os, "fsync", lambda fd: (order.append("fsync"), real_fsync(fd))), \
                unittest.mock.patch.object(tf3ctl.os, "replace",
                                           lambda a, b: (order.append("replace"), real_replace(a, b))):
            tf3ctl.set_profile_language("de")
        self.assertEqual(order, ["fsync", "replace", "fsync", "replace"])

    def test_a_second_tf3ctl_waits_for_the_profile_lock(self):
        lock = open(self.profile + tf3ctl.PROFILE_LOCK_SUFFIX, "a")
        self.addCleanup(lock.close)
        tf3ctl.fcntl.flock(lock, tf3ctl.fcntl.LOCK_EX)  # another tf3ctl in the middle of its backup
        done = []
        t = threading.Thread(target=lambda: done.append(tf3ctl.set_profile_language("de")))
        t.start()
        time.sleep(0.3)
        self.assertEqual(done, [])
        self.assertEqual(read(self.profile), PROFILE, "nothing touched while the other holds the lock")
        self.assertFalse(os.path.exists(self.backup))
        tf3ctl.fcntl.flock(lock, tf3ctl.fcntl.LOCK_UN)
        t.join(5)
        self.assertTrue(done and done[0]["changed"])
        self.assertEqual(read(self.backup), PROFILE)
        tf3ctl.fcntl.flock(lock, tf3ctl.fcntl.LOCK_EX)  # the restore waits too
        t = threading.Thread(target=lambda: done.append(tf3ctl.restore_profile()))
        t.start()
        time.sleep(0.3)
        self.assertTrue(os.path.exists(self.backup))
        tf3ctl.fcntl.flock(lock, tf3ctl.fcntl.LOCK_UN)
        t.join(5)
        self.assertEqual(done[-1]["language"], "ja")

    def test_without_the_install_the_base_languages_are_the_list(self):
        os.environ["TF3_GAME_DIR"] = os.path.join(self.d, "nowhere")
        for lang in tf3ctl.BASE_LANGUAGES:
            tf3ctl.check_lang(lang)
        for bad in ("xx", "pt_PT", "zh_HK"):
            with self.assertRaises(tf3ctl.ToolError, msg=bad):
                tf3ctl.check_lang(bad)
        self.pids.append(5)
        code, _ = self.ctl("restart", "--lang", "xx")
        self.assertEqual((code, self.pids), (2, [5]), "refused before the quit")
        tf3ctl._warned["install"] = False
        code, _ = self.ctl("restart", "--lang", "fr")
        self.assertEqual(code, 0, self.err)
        self.assertEqual(self.err.count("install was not found"), 1, "one warning, not one per check")
        self.assertEqual(self.launched, ["fr"])


class LaunchedFileTest(unittest.TestCase):
    """The launch record ($XDG_RUNTIME_DIR/tf3ctl/launched.json): written after launch / restart with an owner,
    removed when the game is seen stopped, never in the way of either."""

    def setUp(self):
        self.saved = {k: getattr(tf3ctl, k) for k in ("game_pids", "send", "process_start", "OWNER", "launch_game",
                                                       "replace_game")}
        self.saved_env = {k: os.environ.get(k) for k in ("XDG_RUNTIME_DIR", "TF3_REMOTE_DIR")}
        self.run_dir = tempfile.mkdtemp()
        os.environ["XDG_RUNTIME_DIR"] = self.run_dir
        self.path = os.path.join(self.run_dir, "tf3ctl", "launched.json")
        self.x = tempfile.mkdtemp()  # an exchange folder of its own (quit's activity check)
        write(os.path.join(self.x, "remote_probe__hello_1_1.lua"), 'function data() return { json = "{}" } end')
        os.environ["TF3_REMOTE_DIR"] = self.x
        tf3ctl.OWNER = None

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(tf3ctl, k, v)
        for k, v in self.saved_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        os.chmod(self.run_dir, 0o700)
        shutil.rmtree(self.run_dir, ignore_errors=True)
        shutil.rmtree(self.x, ignore_errors=True)

    def quiet(self, fn, *a, **kw):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            res = fn(*a, **kw)
        return res, err.getvalue()

    def test_path_under_xdg_runtime_dir_or_tmp(self):
        self.assertEqual(tf3ctl.launched_path(), self.path)
        os.environ.pop("XDG_RUNTIME_DIR")
        self.assertEqual(tf3ctl.launched_path(), "/tmp/tf3ctl-%d/launched.json" % os.getuid())
        os.environ["XDG_RUNTIME_DIR"] = ""
        self.assertEqual(tf3ctl.launched_path(), "/tmp/tf3ctl-%d/launched.json" % os.getuid(), "empty = not set")

    def test_write_and_remove(self):
        res = tf3ctl.write_launched(4242, owner="alice", now=1794890000.7)
        self.assertEqual(res, {"written": self.path, "owner": "alice", "pid": 4242})
        with open(self.path) as f:
            self.assertEqual(json.load(f), {"v": 1, "owner": "alice", "pid": 4242, "started_at": 1794890000,
                                            "cmd": "launch"})
        self.assertEqual(tf3ctl.remove_launched(), {"removed": self.path})
        self.assertFalse(os.path.exists(self.path))
        self.assertIsNone(tf3ctl.remove_launched(), "nothing to remove is no error")

    def test_owner_comes_from_the_tools_owner(self):
        tf3ctl.OWNER = "bob"  # main sets it from --owner, else TF3CTL_OWNER
        tf3ctl.write_launched(7)
        self.assertEqual(json.loads(read(self.path))["owner"], "bob")
        self.assertEqual(tf3ctl.make_parser().parse_args(["--owner", "carol", "status"]).owner, "carol")
        with unittest.mock.patch.dict(os.environ, {"TF3CTL_OWNER": "dave"}):
            self.assertEqual(tf3ctl.make_parser().parse_args(["status"]).owner, "dave")

    def test_no_owner_writes_nothing_and_removes_an_older_record(self):
        tf3ctl.write_launched(1, owner="alice")
        for owner in (None, ""):
            tf3ctl.OWNER = owner
            res = tf3ctl.write_launched(2)
            self.assertFalse(res["written"])
            self.assertFalse(os.path.exists(self.path), "the older owner's record is not left for this game")
        self.assertEqual(os.listdir(os.path.dirname(self.path)), [], "no temporary file either")

    def test_permissions(self):
        tf3ctl.write_launched(3, owner="alice")
        self.assertEqual(os.stat(os.path.dirname(self.path)).st_mode & 0o777, 0o700)
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)
        os.chmod(os.path.dirname(self.path), 0o755)  # a folder made looser by someone: tightened again
        tf3ctl.write_launched(3, owner="alice")
        self.assertEqual(os.stat(os.path.dirname(self.path)).st_mode & 0o777, 0o700)

    def test_replaced_through_a_temporary_file_in_the_same_folder(self):
        tf3ctl.write_launched(1, owner="alice")
        replaced = []
        real = os.replace

        def spy(src, dst):
            replaced.append((src, dst))
            self.assertEqual(json.loads(read(dst))["pid"], 1, "the old record whole until the rename")
            return real(src, dst)
        with unittest.mock.patch.object(tf3ctl.os, "replace", spy):
            tf3ctl.write_launched(2, owner="alice")
        self.assertEqual(len(replaced), 1)
        self.assertEqual(os.path.dirname(replaced[0][0]), os.path.dirname(self.path))
        self.assertEqual(replaced[0][1], self.path)
        self.assertEqual(json.loads(read(self.path))["pid"], 2)
        self.assertEqual(os.listdir(os.path.dirname(self.path)), ["launched.json"])

    def test_a_failed_rename_leaves_no_temporary_file(self):
        def boom(src, dst):
            raise OSError("disk full")
        with unittest.mock.patch.object(tf3ctl.os, "replace", boom):
            res, err = self.quiet(tf3ctl.write_launched, 2, owner="alice")
        self.assertFalse(res["written"])
        self.assertIn("disk full", err)
        self.assertEqual(os.listdir(os.path.dirname(self.path)), [])

    def test_cannot_write_is_only_a_warning(self):
        write(os.path.join(self.run_dir, "tf3ctl"), "a file where the folder should be")
        res, err = self.quiet(tf3ctl.write_launched, 5, owner="alice")
        self.assertFalse(res["written"])
        self.assertIn("warning: could not write the launch record", err)
        os.remove(os.path.join(self.run_dir, "tf3ctl"))
        os.chmod(self.run_dir, 0o500)  # the folder cannot be made
        if os.access(self.run_dir, os.W_OK):
            self.skipTest("running as a user that writes anywhere")
        res, err = self.quiet(tf3ctl.write_launched, 5, owner="alice")
        self.assertFalse(res["written"])
        self.assertIn("warning", err)

    def test_cannot_remove_is_only_a_warning(self):
        tf3ctl.write_launched(5, owner="alice")
        os.chmod(os.path.dirname(self.path), 0o500)
        try:
            if os.access(os.path.dirname(self.path), os.W_OK):
                self.skipTest("running as a user that writes anywhere")
            res, err = self.quiet(tf3ctl.remove_launched)
            self.assertIn("warning", res)
            self.assertIn("could not remove the launch record", err)
            # quit still answers that the game quit
            tf3ctl.game_pids = lambda: []
            res, err = self.quiet(tf3ctl.quit_game, timeout=1)
            self.assertEqual(res["how"], "not running")
            self.assertIn("warning", res["launchedFile"])
        finally:
            os.chmod(os.path.dirname(self.path), 0o700)

    def test_a_folder_of_someone_else_or_a_symlink_is_not_used(self):
        target = tempfile.mkdtemp()
        try:
            os.symlink(target, os.path.join(self.run_dir, "tf3ctl"))
            res, err = self.quiet(tf3ctl.write_launched, 5, owner="alice")
            self.assertFalse(res["written"])
            self.assertEqual(os.listdir(target), [], "nothing written through the link")
        finally:
            shutil.rmtree(target, ignore_errors=True)

    def test_every_quit_that_saw_the_game_stop_removes_it(self):
        pids = []
        tf3ctl.game_pids = lambda: list(pids)
        # not running
        tf3ctl.write_launched(1, owner="alice")
        res = tf3ctl.quit_game(timeout=1)
        self.assertEqual(res["launchedFile"], {"removed": self.path})
        self.assertFalse(os.path.exists(self.path))
        self.assertNotIn("launchedFile", tf3ctl.quit_game(timeout=1), "nothing to remove: no mark")
        # app.quit
        pids[:] = [1]
        tf3ctl.write_launched(1, owner="alice")

        def quits(*a, **kw):
            pids.clear()
            return {"ok": True}
        tf3ctl.send = quits
        self.assertEqual(tf3ctl.quit_game(timeout=2)["how"], "quit")
        self.assertFalse(os.path.exists(self.path))
        # SIGKILL
        pids[:] = [1]
        tf3ctl.write_launched(1, owner="alice")
        tf3ctl.send = lambda *a, **kw: {"ok": False, "error": "busy"}
        with unittest.mock.patch.object(tf3ctl.os, "kill", lambda pid, sig: pids.clear()):
            self.assertEqual(tf3ctl.quit_game(timeout=0.3, kill=True)["how"], "kill")
        self.assertFalse(os.path.exists(self.path))

    def test_a_quit_that_failed_keeps_it(self):
        tf3ctl.game_pids = lambda: [1]
        tf3ctl.send = lambda *a, **kw: {"ok": True}  # answers, but the game stays
        tf3ctl.write_launched(1, owner="alice")
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.quit_game(timeout=0.3)
        self.assertTrue(os.path.exists(self.path), "the game still runs: its record stays")

    def test_launch_and_restart_write_it_after_the_probe_answered(self):
        pids = []
        tf3ctl.game_pids = lambda: list(pids)
        seen = []

        def fake_launch(timeout):
            seen.append(os.path.exists(self.path))
            pids[:] = [31337]
            return {"ok": True, "menu": True}
        tf3ctl.launch_game = fake_launch
        tf3ctl.OWNER = "alice"
        ns = tf3ctl.argparse.Namespace(load=None, new=False, lang=None, launch_timeout=1, timeout=1)
        res = tf3ctl.cmd_start(ns, restart=False)
        self.assertEqual(res["launchedFile"]["written"], self.path)
        rec = json.loads(read(self.path))
        self.assertEqual((rec["owner"], rec["pid"], rec["cmd"], rec["v"]), ("alice", 31337, "launch", 1))
        self.assertLessEqual(abs(rec["started_at"] - time.time()), 5)

        # restart: the quit removes it, the new launch writes the new pid
        def quits(*a, **kw):
            pids.clear()
            return {"ok": True}
        tf3ctl.send = quits
        ns = tf3ctl.argparse.Namespace(load=None, new=False, lang=None, launch_timeout=1, timeout=1,
                                       quit_timeout=2, no_kill=True, force=False)

        def fake_launch2(timeout):
            seen.append(os.path.exists(self.path))
            pids[:] = [31338]
            return {"ok": True, "menu": True}
        tf3ctl.launch_game = fake_launch2
        with unittest.mock.patch.object(tf3ctl, "RELAUNCH_PAUSE_SEC", 0):
            res = tf3ctl.cmd_start(ns, restart=True)
        self.assertEqual(seen, [False, False], "nothing before the probe answered")
        self.assertEqual(res["quit"]["launchedFile"], {"removed": self.path})
        self.assertEqual(json.loads(read(self.path))["pid"], 31338)
        self.assertEqual(json.loads(read(self.path))["cmd"], "launch")

    def test_launch_without_owner_leaves_no_record(self):
        pids = []
        tf3ctl.game_pids = lambda: list(pids)
        tf3ctl.write_launched(1, owner="old")

        def fake_launch(timeout):
            pids[:] = [5]
            return {"ok": True}
        tf3ctl.launch_game = fake_launch
        ns = tf3ctl.argparse.Namespace(load=None, new=False, lang=None, launch_timeout=1, timeout=1)
        res = tf3ctl.cmd_start(ns, restart=False)
        self.assertFalse(res["launchedFile"]["written"])
        self.assertFalse(os.path.exists(self.path))

    def test_launch_game_removes_a_stale_record_and_one_of_a_game_that_ended(self):
        tf3ctl.write_launched(1, owner="alice")
        tf3ctl.game_pids = lambda: []
        with unittest.mock.patch.dict(os.environ, {"TF3_STEAM": "/nonexistent/steam"}):
            with self.assertRaises(tf3ctl.ToolError):
                tf3ctl.launch_game(timeout=1)
        self.assertFalse(os.path.exists(self.path), "no game was running: the record was stale")
        tf3ctl.game_pids = lambda: [1]
        tf3ctl.write_launched(1, owner="alice")
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.launch_game(timeout=1)
        self.assertTrue(os.path.exists(self.path), "refused for a running game: its record stays")

    def test_a_game_that_ends_during_the_load_removes_it(self):
        tf3ctl.write_launched(1, owner="alice")
        with unittest.mock.patch.object(tf3ctl, "game_state", lambda folder=None: {"state": "crashed", "text": "x"}), \
                unittest.mock.patch.object(tf3ctl.time, "sleep", lambda s: None):
            clock = iter(range(0, 1000, 3))
            with unittest.mock.patch.object(tf3ctl.time, "time", lambda: next(clock)):
                with self.assertRaises(tf3ctl.GameNotReady):
                    tf3ctl.wait_new_hello(self.x, 9, "1_1", timeout=500)
        self.assertFalse(os.path.exists(self.path))

    def test_pid_of_several_is_the_newest(self):
        tf3ctl.game_pids = lambda: [10, 20, 30]
        tf3ctl.process_start = lambda p: {10: 100.0, 20: 300.0, 30: 200.0}[p]
        self.assertEqual(tf3ctl.launched_pid(), 20)
        tf3ctl.game_pids = lambda: [10]
        self.assertEqual(tf3ctl.launched_pid(), 10)
        tf3ctl.game_pids = lambda: []
        self.assertIsNone(tf3ctl.launched_pid())


class LaunchEndToEndTest(unittest.TestCase):
    """launch --new and restart --load against the fake game, started by a stand-in for steam."""

    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.dir = os.path.join(self.root, "recordings")
        os.makedirs(self.dir)
        self.log = os.path.join(self.root, "stdout.txt")
        write(self.log, "")
        self.steam = os.path.join(self.root, "steam.sh")
        write(self.steam, "#!/bin/sh\n"
              'echo "$@" > "%s/steam_args"\n'
              'printf "[%%s - MESSAGE  - Main Thread      - Main           ]  Main menu is ready\\n" '
              '"$(date -u "+%%Y-%%m-%%d %%H:%%M:%%SZ")" >> "%s"\n'
              'exec luajit "%s" "%s" 60 menu\n' % (self.root, self.log, os.path.join(ROOT, "tests", "fake_game.lua"),
                                                   self.root))
        os.chmod(self.steam, 0o755)
        self.saved = {k: getattr(tf3ctl, k) for k in ("game_pids",)}
        os.environ.update(TF3_STEAM=self.steam, TF3_REMOTE_DIR=self.dir, TF3_LOG=self.log, TF3_ASSUME_RUNNING="1")
        # the fake game's process is luajit, not TransportFever3
        tf3ctl.game_pids = lambda: [int(p) for p in subprocess.run(["pgrep", "-f", "fake_game.lua " + self.root],
                                                                   capture_output=True, text=True).stdout.split()]

    def tearDown(self):
        for pid in tf3ctl.game_pids():
            try:
                os.kill(pid, 9)
            except ProcessLookupError:
                pass
        for k, v in self.saved.items():
            setattr(tf3ctl, k, v)
        for k in ("TF3_STEAM", "TF3_REMOTE_DIR", "TF3_LOG", "TF3_ASSUME_RUNNING"):
            os.environ.pop(k, None)

    def ctl(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = tf3ctl.main(list(argv))
        return code, json.loads(out.getvalue()) if out.getvalue().strip() else None

    def test_launch_new_then_restart_load(self):
        record = os.path.join(os.environ["XDG_RUNTIME_DIR"], "tf3ctl", "launched.json")
        code, res = self.ctl("--owner", "tester", "launch", "--new", "--size", "tiny", "--year", "1930", "--add",
                             "m9", "--launch-timeout", "30", "--timeout", "30")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["launchedFile"]["written"], record)
        self.assertEqual(json.loads(read(record))["pid"], tf3ctl.game_pids()[0], "the game started by steam")
        self.assertEqual(json.loads(read(record))["owner"], "tester")
        self.assertIn("--script hummer_remote_probe::/startup.lua", read(os.path.join(self.root, "steam_args")))
        self.assertTrue(res["launch"]["hello"]["menu"])
        self.assertFalse(res["newgame"]["hello"]["menu"], "the new game's own probe")
        self.assertEqual(res["newgame"]["hello"]["state"]["date"]["year"], 1930)
        self.assertTrue(res["newgame"]["companyInit"]["ok"], res["newgame"].get("companyInit"))
        self.assertIs(res["newgame"]["companyInit"]["sent"], False, "the start event gave the basePopulation")
        code, res = self.ctl("status")
        self.assertEqual(code, 0, res)
        self.assertFalse(res["menu"])
        pid = tf3ctl.game_pids()
        # another owner, or none, may not restart, save or quit tester's game: refused, nothing quit or killed
        for argv in (["restart", "--load", "probe", "--quit-timeout", "10"],
                     ["--owner", "other", "restart", "--load", "probe", "--quit-timeout", "10"],
                     ["--owner", "other", "save", "x"], ["--owner", "other", "quit", "--kill", "--force"]):
            code, res = self.ctl(*argv)
            self.assertEqual(code, 4, (argv, res))
            self.assertEqual(res["refused"], "owner")
            self.assertEqual(tf3ctl.game_pids(), pid, "the game still runs")
            self.assertEqual(json.loads(read(record))["owner"], "tester")
        code, res = self.ctl("--owner", "other", "status")
        self.assertEqual(code, 0, res)
        code, res = self.ctl("--owner", "tester", "restart", "--load", "probe", "--launch-timeout", "30",
                             "--timeout", "30", "--quit-timeout", "10")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["quit"]["how"], "quit", "app.quit through the probe, no SIGKILL")
        self.assertTrue(res["load"]["ok"], "the load in tester's own main menu goes")
        self.assertIn("example_mod", res["load"]["plan"]["mods"])
        self.assertEqual(json.loads(read(record))["pid"], tf3ctl.game_pids()[0], "the record names the new game")
        code, res = self.ctl("--owner", "tester", "quit")
        self.assertEqual(code, 0, res)
        self.assertEqual(tf3ctl.game_pids(), [])
        self.assertFalse(os.path.exists(record))



class ModhubEndToEndTest(unittest.TestCase):
    """modhub status / validate through real files, against the fake game in its main menu with a staging area."""

    @classmethod
    def setUpClass(cls):
        cls.root = tempfile.mkdtemp()
        cls.dir = os.path.join(cls.root, "recordings")
        cls.game = subprocess.Popen(["luajit", os.path.join(ROOT, "tests", "fake_game.lua"), cls.root, "60", "menu",
                                     "modhub"], stderr=subprocess.PIPE, text=True)
        deadline = time.time() + 10
        while not glob.glob(os.path.join(cls.dir, "remote_probe__cmd_*.lua")):
            if time.time() > deadline:
                raise RuntimeError("the fake game did not start")
            time.sleep(0.05)
        os.environ["TF3_REMOTE_DIR"] = cls.dir
        os.environ["TF3_ASSUME_RUNNING"] = "1"

    @classmethod
    def tearDownClass(cls):
        cls.game.kill()
        cls.game.wait()
        cls.game.stderr.close()
        os.environ.pop("TF3_REMOTE_DIR", None)
        os.environ.pop("TF3_ASSUME_RUNNING", None)
        shutil.rmtree(cls.root, ignore_errors=True)

    def ctl(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = tf3ctl.main(list(argv))
        return code, json.loads(out.getvalue()) if out.getvalue() else None

    def test_status_then_validate_then_a_refused_folder(self):
        code, res = self.ctl("modhub", "status", "--wait", "10")
        self.assertEqual(code, 0, res)
        self.assertTrue(res["helper"])
        self.assertEqual(sorted(m["folder"] for m in res["mods"]), ["example_mod_1", "hummer_force_unload_default_1"])
        self.assertTrue(all(m["state"] == "Ready" for m in res["mods"]), res["mods"])
        code, res = self.ctl("modhub", "validate", "hummer_force_unload_default_1", "--timeout", "30")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["result"]["counts"]["warning"], 1)
        self.assertEqual(res["result"]["levelConsole"], "Warning")
        code, res = self.ctl("modhub", "validate", "example_mod_1")
        self.assertEqual(code, 1)
        self.assertIn("only these staging folders", res["error"])


FU = "hummer_force_unload_default_1"


MODINFO = {"name": "Force Unload / 積み下ろし強制", "summary": "Turns it on. / オンにする。",
           "description": "[English] ...\n\n[日本語] ...", "authors": [{"name": "hummer", "role": "CREATOR"}],
           "tags": ["Script Mod"]}


def make_staging(root, name=FU, cover=(1920, 1080), fileid=None, modinfo=MODINFO, revision=None):
    """A staging mod as stage.py leaves it: mod.json (with revision, if given), _metadata/modinfo.json and
    _metadata/0.png (only the PNG header matters here)."""
    meta = os.path.join(root, "staging_area", name, "_metadata")
    os.makedirs(meta, exist_ok=True)
    with open(os.path.join(root, "staging_area", name, "mod.json"), "w") as f:
        f.write("{}" if revision is None else json.dumps({"modId": "x", "revision": revision}))
    if modinfo is not None:
        with open(os.path.join(meta, "modinfo.json"), "w", encoding="utf-8") as f:
            json.dump(modinfo, f, ensure_ascii=False)
    if cover is not None:
        with open(os.path.join(meta, "0.png"), "wb") as f:
            f.write(b"\x89PNG\r\n\x1a\n" + (13).to_bytes(4, "big") + b"IHDR" + cover[0].to_bytes(4, "big")
                    + cover[1].to_bytes(4, "big") + b"\x08\x06\x00\x00\x00" + b"\x00" * 64)
    if fileid is not None:
        with open(os.path.join(meta, "mod.io_fileid.txt"), "w") as f:
            f.write(fileid)
    return meta


class ModhubPublishTest(unittest.TestCase):
    """modhub publish without a game: what the tool refuses on its own, the mark, and the order of its commands."""

    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.dir = os.path.join(self.root, "recordings")
        os.makedirs(self.dir)
        self.saved = os.environ.get("TF3_REMOTE_DIR")
        os.environ["TF3_REMOTE_DIR"] = self.dir
        self.meta = make_staging(self.root)
        with contextlib.suppress(OSError):
            os.remove(tf3ctl.history_path())  # other classes' uploads
        self.sent = []
        self.answers = []
        self.real_send = tf3ctl.send
        self.mark_at_send = []

        def fake_send(cmd, args=None, timeout=20, final_tag=None, on_progress=None, folder=None):
            self.sent.append((cmd, dict(args or {}), timeout))
            self.mark_at_send.append(tf3ctl.read_pending())
            a = self.answers.pop(0)
            if callable(a):
                a = a()
            if isinstance(a, dict) and a.get("ok") and "settings" not in a:
                # the mod answers the settings it builds from the args (remote_modhub plannedSettings); a mod that
                # answers other ones is tested on its own, with settings in the answer
                a["settings"] = {"updateMetadata": (args or {}).get("updateMetadata")}
            return a
        tf3ctl.send = fake_send
        # force unload stands for a new mod here: out of the configuration's folders held to a mod.io page
        self.saved_pins = dict(CONFIGURED["modhub"]["publishedIds"])
        use_config(configured(publishedIds={k: v for k, v in self.saved_pins.items() if k != FU}))
        self.saved_wait = tf3ctl.FILEID_WAIT_SEC
        tf3ctl.FILEID_WAIT_SEC = 0.5

    def history(self):
        try:
            with open(tf3ctl.history_path(), encoding="utf-8") as f:
                return [json.loads(line) for line in f]
        except FileNotFoundError:
            return []

    def tearDown(self):
        tf3ctl.send = self.real_send
        use_config(CONFIGURED)
        tf3ctl.FILEID_WAIT_SEC = self.saved_wait
        with contextlib.suppress(OSError):
            os.remove(tf3ctl.history_path())
        if self.saved is None:
            os.environ.pop("TF3_REMOTE_DIR", None)
        else:
            os.environ["TF3_REMOTE_DIR"] = self.saved
        with contextlib.suppress(OSError):
            os.remove(tf3ctl.pending_path())
        shutil.rmtree(self.root, ignore_errors=True)

    def run_publish(self, *extra, folder=FU):
        ns = tf3ctl.make_parser().parse_args(["modhub", "publish", folder] + list(extra))
        with contextlib.redirect_stderr(io.StringIO()):
            return tf3ctl.cmd_modhub(ns)

    FULL = ("--public", "yes", "--changelog", "First release.", "--first-upload")

    def refused(self, msg, *extra, folder=FU):
        with self.assertRaises(tf3ctl.ToolError) as cm:
            self.run_publish(*extra, folder=folder)
        self.assertIn(msg, str(cm.exception))
        self.assertEqual(self.sent, [], "nothing sent")
        self.assertIsNone(tf3ctl.read_pending(), "no mark")

    def test_mark_lives_under_xdg_state_home(self):
        self.assertEqual(tf3ctl.pending_path(), os.path.join(STATE_DIR, "tf3ctl", "publish_pending.json"))
        self.assertEqual(tf3ctl.staging_dir(), os.path.join(self.root, "staging_area"))
        self.assertIn("modhubPublish", tf3ctl.CHANGES_GAME)

    def test_refuses_folders_outside_the_list_and_missing_flags(self):
        make_staging(self.root, "hummer_proto_models_1")
        self.refused("only these staging folders", *self.FULL, folder="hummer_proto_models_1")
        self.refused("only these staging folders", *self.FULL, folder="example_mod_1")
        self.refused("--first-upload", "--public", "yes", "--changelog", "x")
        self.refused("--public yes or --public no", "--changelog", "x", "--first-upload")
        self.refused("--public yes or --public no", "--public", "true", "--changelog", "x", "--first-upload")
        self.refused("--changelog", "--public", "yes", "--first-upload")
        self.refused("--changelog", "--public", "yes", "--changelog", "  ", "--first-upload")
        self.refused("--first-upload", "--public", "yes", "--changelog", "x", "--dry-run")

    def test_refuses_a_fileid_a_missing_or_bad_cover_and_a_mark(self):
        with open(os.path.join(self.meta, "mod.io_fileid.txt"), "w") as f:
            f.write("6536959")
        self.refused("mod.io_fileid.txt", *self.FULL)
        self.refused("mod.io_fileid.txt", *(self.FULL + ("--dry-run",)))
        os.remove(os.path.join(self.meta, "mod.io_fileid.txt"))
        os.remove(os.path.join(self.meta, "0.png"))
        self.refused("no _metadata/0.png", *self.FULL)
        with open(os.path.join(self.meta, "0.png"), "wb") as f:
            f.write(b"JFIF not a png at all, long enough....")
        self.refused("not a PNG", *self.FULL)
        make_staging(self.root, cover=(320, 200))
        self.refused("smaller than", *self.FULL)
        shutil.rmtree(os.path.join(self.root, "staging_area", FU))
        self.refused("no staging mod", *self.FULL)
        make_staging(self.root)
        tf3ctl.write_pending({"folder": FU, "at": 1})
        with self.assertRaises(tf3ctl.ToolError) as cm:
            self.run_publish(*self.FULL)
        self.assertIn("publish mark", str(cm.exception))
        self.assertEqual(self.sent, [])
        # an unreadable mark still counts
        with open(tf3ctl.pending_path(), "w") as f:
            f.write("{half")
        with self.assertRaises(tf3ctl.ToolError):
            self.run_publish(*(self.FULL + ("--dry-run",)))
        self.assertEqual(self.sent, [])

    def modinfo(self, **fields):
        info = dict(MODINFO, **fields)
        for key in [k for k, v in info.items() if v is None]:
            del info[key]
        with open(os.path.join(self.meta, "modinfo.json"), "w", encoding="utf-8") as f:
            json.dump(info, f, ensure_ascii=False)

    def test_mod_io_field_limits_are_checked_before_anything_is_sent(self):
        # mod.io refused a 58-character name ("code 13009") after the upload began: say it before, in characters
        for dry in ((), ("--dry-run",)):
            self.modinfo(name="N" * 51)
            self.refused("modinfo.json name is 51 characters, more than mod.io's 50", *(self.FULL + dry))
        # Japanese counts as characters, not bytes: 50 characters of 3 UTF-8 bytes each go
        self.modinfo(name="積" * 50)
        self.answers = [{"ok": True, "dryRun": True}]
        res = self.run_publish(*(self.FULL + ("--dry-run",)))
        self.assertEqual(res["local"]["metadata"]["name"], {"length": 50, "max": 50})
        self.sent = []
        self.modinfo(name="Force Unload / " + "積" * 36)  # 51 characters
        self.refused("name is 51 characters", *self.FULL)
        self.modinfo(name="A" * 50, summary="s" * 251)
        self.refused("modinfo.json summary is 251 characters, more than mod.io's 250", *self.FULL)
        self.modinfo(summary="概" * 251, description="d" * 50001)
        with self.assertRaises(tf3ctl.ToolError) as cm:  # every field over its limit is named
            self.run_publish(*self.FULL)
        self.assertIn("summary is 251 characters", str(cm.exception))
        self.assertIn("description is 50001 characters, more than this tool's guard of 50000", str(cm.exception))
        self.modinfo()
        self.refused("--changelog is 50001 characters, more than this tool's guard of 50000",
                     "--public", "yes", "--changelog", "c" * 50001, "--first-upload")
        self.modinfo(summary=None)
        self.refused("modinfo.json summary is missing, empty or not a string", *self.FULL)
        self.modinfo(description="  ")
        self.refused("modinfo.json description is missing, empty or not a string", *self.FULL)
        self.modinfo(name=50)
        self.refused("modinfo.json name is missing, empty or not a string", *self.FULL)
        self.modinfo(tags="Script Mod")
        self.refused("tags is not a list of strings", *self.FULL)
        self.modinfo(tags=["Script Mod", 3])
        self.refused("tags is not a list of strings", *self.FULL)
        os.remove(os.path.join(self.meta, "modinfo.json"))
        self.refused("cannot read _metadata/modinfo.json", *self.FULL)
        with open(os.path.join(self.meta, "modinfo.json"), "w") as f:
            f.write("[]")
        self.refused("not a JSON object", *self.FULL)
        self.assertEqual(self.history(), [])

    def test_fields_at_their_limits_go_and_the_dry_run_answers_the_lengths(self):
        self.modinfo(name="名" * 50, summary="s" * 250, description="d" * 50000, tags=["Script Mod", "Misc"])
        self.answers = [{"ok": True, "dryRun": True}]
        res = self.run_publish("--public", "no", "--changelog", "c" * 50000, "--first-upload", "--dry-run")
        self.assertEqual(res["local"]["metadata"], {
            "name": {"length": 50, "max": 50}, "summary": {"length": 250, "max": 250},
            "description": {"length": 50000, "max": 50000}, "changelog": {"length": 50000, "max": 50000},
            "tags": {"count": 2}})
        self.assertEqual(len(self.sent), 1)
        # tags are optional
        self.modinfo(tags=None)
        self.answers = [{"ok": True, "dryRun": True}]
        res = self.run_publish(*(self.FULL + ("--dry-run",)))
        self.assertEqual(res["local"]["metadata"]["tags"], {"count": 0})

    def test_dry_run_sends_one_dry_run_and_writes_no_mark(self):
        self.answers = [{"ok": True, "dryRun": True, "wouldPublish": True}]
        res = self.run_publish(*(self.FULL + ("--dry-run", "--timeout", "120")))
        self.assertTrue(res["ok"])
        self.assertEqual(len(self.sent), 1)
        cmd, args, timeout = self.sent[0]
        self.assertEqual(cmd, "modhubPublish")
        self.assertEqual(args, {"folder": FU, "public": True, "firstUpload": True, "changelog": "First release.",
                                "updateMetadata": True, "timeout": 120, "dryRun": True})
        self.assertEqual(timeout, 150)
        self.assertEqual(res["local"]["cover"], {"width": 1920, "height": 1080, "bytes": os.path.getsize(
            os.path.join(self.meta, "0.png"))})
        self.assertIsNone(tf3ctl.read_pending())
        # the mod reads it as it was meant
        got = mod_reads(tf3ctl.command_text(9, "modhubPublish", args))
        self.assertEqual(got["args"], args)

    def test_a_refused_dry_run_before_the_upload_leaves_no_mark(self):
        self.answers = [{"ok": False, "error": "nobody is logged in", "publishCalled": False}]
        res = self.run_publish(*self.FULL)
        self.assertFalse(res["ok"])
        self.assertTrue(res["preflight"])
        self.assertEqual(len(self.sent), 1)
        self.assertIsNone(tf3ctl.read_pending())

    def success(self, write="7000001"):
        def answer():
            if write:
                with open(os.path.join(self.meta, "mod.io_fileid.txt"), "w") as f:
                    f.write(write + "\n")
            return {"ok": True, "publishCalled": True, "modId": "7000001", "result": {"success": True}}
        return answer

    def test_upload_writes_the_mark_before_sending_and_clears_it_on_the_fileid(self):
        self.answers = [{"ok": True, "dryRun": True, "wouldPublish": True, "validation": {"text": "ok"}}, self.success()]
        res = self.run_publish(*self.FULL)
        self.assertTrue(res["ok"], res)
        self.assertEqual([a.get("dryRun") for _, a, _ in self.sent], [True, False])
        self.assertIsNone(self.mark_at_send[0], "no mark for the dry run")
        mark = self.mark_at_send[1]
        self.assertEqual((mark["folder"], mark["public"], mark["firstUpload"]), (FU, True, True))
        self.assertIn("at", mark)
        self.assertEqual(res["fileid"], "7000001")
        self.assertTrue(res["pendingCleared"])
        self.assertIsNone(tf3ctl.read_pending())
        h = self.history()
        self.assertEqual(len(h), 1)
        self.assertEqual((h[0]["outcome"], h[0]["folder"], h[0]["public"], h[0]["modId"], h[0]["fileid"]),
                         ("success", FU, True, "7000001", "7000001"))
        self.assertIn("at", h[0])
        self.assertEqual(os.stat(tf3ctl.history_path()).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(os.path.dirname(tf3ctl.history_path())).st_mode & 0o777, 0o700)

    def test_partial_errors_keep_the_mark_and_go_to_the_history(self):
        def partial():
            with open(os.path.join(self.meta, "mod.io_fileid.txt"), "w") as f:
                f.write("7000001")
            return {"ok": False, "publishCalled": True, "outcome": "partial", "modId": "7000001",
                    "error": "uploaded as mod.io mod 7000001, with 1 partial errors",
                    "result": {"success": True, "modId": "7000001", "partialErrors": [{"step": "Gallery"}]}}
        self.answers = [{"ok": True, "dryRun": True}, partial]
        res = self.run_publish(*self.FULL)
        self.assertFalse(res["ok"])
        self.assertTrue(res["pendingKept"])
        self.assertIn("partial errors", res["note"])
        self.assertIsNotNone(tf3ctl.read_pending(), "a person looks at mod.io first")
        h = self.history()
        self.assertEqual((h[-1]["outcome"], h[-1]["modId"], h[-1]["fileid"]), ("partial", "7000001", "7000001"))

    def test_the_mark_is_made_exclusively(self):
        tf3ctl.write_pending({"folder": FU})
        with self.assertRaises(tf3ctl.ToolError) as cm:
            tf3ctl.write_pending({"folder": "other"})
        self.assertIn("appeared meanwhile", str(cm.exception))
        self.assertEqual(tf3ctl.read_pending()["folder"], FU)
        self.assertEqual(os.stat(tf3ctl.pending_path()).st_mode & 0o777, 0o600)
        self.assertEqual([n for n in os.listdir(os.path.dirname(tf3ctl.pending_path())) if n.startswith(".publish-")], [])

    def test_publish_clear_is_refused_while_the_game_says_publishing(self):
        tf3ctl.write_pending({"folder": FU})
        saved_pids = tf3ctl.game_pids
        tf3ctl.game_pids = lambda: [42]
        ns = tf3ctl.make_parser().parse_args(["modhub", "publish-clear", "--yes"])
        try:
            self.answers = [{"ok": True, "mods": [{"folder": FU, "state": "Publishing"}]}]
            with self.assertRaises(tf3ctl.ToolError) as cm:
                tf3ctl.cmd_modhub(ns)
            self.assertIn("still Publishing", str(cm.exception))
            self.assertEqual(self.sent[-1][:2], ("modhubStatus", {"wait": 0, "folder": FU}))
            self.assertIsNotNone(tf3ctl.read_pending())
            # a result there: it goes
            self.answers = [{"ok": True, "mods": [{"folder": FU, "state": "Ready"}]}]
            self.assertEqual(tf3ctl.cmd_modhub(ns)["cleared"]["folder"], FU)
            # a game that cannot be asked (in a save): --yes is the person's word
            tf3ctl.write_pending({"folder": FU})

            def cannot():
                raise tf3ctl.ToolError("no answer")
            self.answers = [cannot]
            out = tf3ctl.cmd_modhub(ns)
            self.assertEqual(out["cleared"]["folder"], FU)
            self.assertIn("could not ask", out["statusNote"])
        finally:
            tf3ctl.game_pids = saved_pids

    def test_a_failure_keeps_the_mark_and_the_games_words(self):
        self.answers = [{"ok": True, "dryRun": True},
                        {"ok": False, "publishCalled": True, "outcome": "failed",
                         "error": "Upload Failed: Name taken (code 21012)", "result": {"success": False}}]
        res = self.run_publish(*self.FULL)
        self.assertFalse(res["ok"])
        self.assertEqual(res["error"], "Upload Failed: Name taken (code 21012)")
        self.assertTrue(res["pendingKept"])
        self.assertEqual(tf3ctl.read_pending()["folder"], FU)
        # and the next one is refused until a person clears it
        with self.assertRaises(tf3ctl.ToolError):
            self.run_publish(*self.FULL)
        self.assertEqual(len(self.sent), 2)
        # publish-clear wants --yes
        with self.assertRaises(tf3ctl.ToolError) as cm:
            tf3ctl.cmd_modhub(tf3ctl.make_parser().parse_args(["modhub", "publish-clear"]))
        self.assertIn("--yes", str(cm.exception))
        self.assertIsNotNone(tf3ctl.read_pending())
        ns = tf3ctl.make_parser().parse_args(["modhub", "publish-clear", "--yes"])
        saved_pids = tf3ctl.game_pids
        tf3ctl.game_pids = lambda: []
        try:
            out = tf3ctl.cmd_modhub(ns)
            self.assertEqual(out["cleared"]["folder"], FU)
            self.assertIsNone(tf3ctl.read_pending())
            out = tf3ctl.cmd_modhub(ns)
            self.assertIsNone(out["cleared"])
        finally:
            tf3ctl.game_pids = saved_pids
        lines = self.history()
        self.assertEqual([(h["outcome"], h["folder"], h["public"]) for h in lines], [("failed", FU, True)])
        self.assertEqual(lines[0]["error"], "Upload Failed: Name taken (code 21012)")

    def test_a_refusal_after_the_mark_keeps_it(self):
        self.answers = [{"ok": True, "dryRun": True},
                        {"ok": False, "publishCalled": False, "error": "mod.io is busy; nothing was uploaded"}]
        res = self.run_publish(*self.FULL)
        self.assertFalse(res["ok"])
        self.assertTrue(res["pendingKept"])
        self.assertIn("publish-clear", res["note"])
        self.assertIsNotNone(tf3ctl.read_pending())
        self.assertEqual(self.history()[-1]["outcome"], "not sent")

    def test_no_answer_in_time_keeps_the_mark(self):
        def lost():
            raise tf3ctl.ToolError("no answer in 930 s")
        self.answers = [{"ok": True, "dryRun": True}, lost]
        with self.assertRaises(tf3ctl.ToolError) as cm:
            self.run_publish(*self.FULL)
        self.assertIn("publish mark stays", str(cm.exception))
        self.assertIsNotNone(tf3ctl.read_pending())
        self.assertEqual(self.history()[-1]["outcome"], "no answer")
        # the mod's own timeout answer: outcome unknown, the mark stays
        os.remove(tf3ctl.pending_path())
        self.answers = [{"ok": True, "dryRun": True},
                        {"ok": False, "publishCalled": True, "outcome": "unknown", "error": "timed out"}]
        res = self.run_publish(*self.FULL)
        self.assertTrue(res["pendingKept"])
        self.assertIsNotNone(tf3ctl.read_pending())
        self.assertEqual(self.history()[-1]["outcome"], "unknown")

    def test_a_success_without_the_fileid_or_with_another_id_keeps_the_mark(self):
        self.answers = [{"ok": True, "dryRun": True}, self.success(write=None)]
        res = self.run_publish(*self.FULL)
        self.assertFalse(res["ok"])
        self.assertIn("did not appear", res["error"])
        self.assertIsNotNone(tf3ctl.read_pending())
        os.remove(tf3ctl.pending_path())
        self.answers = [{"ok": True, "dryRun": True}, self.success(write="7999999")]
        res = self.run_publish(*self.FULL)
        self.assertFalse(res["ok"])
        self.assertIn("says 7999999", res["error"])
        self.assertIsNotNone(tf3ctl.read_pending())


class ModhubPublishUpdateTest(unittest.TestCase):
    """modhub publish of an update (no --first-upload): the fileid's mod.io page, mod.json's revision above the last
    one uploaded, the two never taken for each other. ModhubPublishTest's fake send, set-up and helpers, without
    its tests."""

    MODIO = "6543965"
    UPDATE = ("--public", "yes", "--changelog", "Wording.")
    FULL = ModhubPublishTest.FULL
    tearDown = ModhubPublishTest.tearDown
    history = ModhubPublishTest.history
    run_publish = ModhubPublishTest.run_publish
    refused = ModhubPublishTest.refused

    def setUp(self):
        ModhubPublishTest.setUp(self)
        self.meta = make_staging(self.root, fileid=self.MODIO, revision=10003)

    def revision(self, rev):
        make_staging(self.root, fileid=self.MODIO, revision=rev)

    def add_history(self, **rec):
        tf3ctl.append_history(dict({"v": 1, "folder": FU, "outcome": "success", "modId": self.MODIO,
                                    "fileid": self.MODIO}, **rec))

    def dry(self, *extra):
        return {"ok": True, "dryRun": True, "wouldPublish": True, "mode": "update", "modioId": self.MODIO,
                "checks": {"modio": {"title": "Auto Force Unload", "visible": True, "version": "10001",
                                     "modId": self.MODIO}}}

    def test_a_fileid_with_first_upload_and_an_update_without_a_fileid_are_both_refused(self):
        self.refused("--first-upload makes only a new mod", *(self.UPDATE + ("--first-upload",)))
        self.refused("--first-upload makes only a new mod", *(self.UPDATE + ("--first-upload", "--dry-run")))
        os.remove(os.path.join(self.meta, "mod.io_fileid.txt"))
        self.refused("never uploaded, so there is no mod.io page to update", *(self.UPDATE + ("--previous-revision", "1")))
        self.refused("never uploaded", *(self.UPDATE + ("--dry-run", "--previous-revision", "1")))
        self.assertEqual(self.history(), [])

    def test_a_fileid_that_is_not_one_id_is_refused(self):
        for bad in ("", "abc", "6543965 7000001", "-5"):
            with open(os.path.join(self.meta, "mod.io_fileid.txt"), "w") as f:
                f.write(bad)
            self.refused("does not hold one mod.io id", *(self.UPDATE + ("--previous-revision", "10001")))

    def test_the_revision_must_be_known_and_above_the_last_upload(self):
        self.refused("records no revision uploaded to mod.io mod 6543965", *(self.UPDATE + ("--dry-run",)))
        self.add_history()  # the first upload, from before the history kept the revision: still not known
        self.refused("give --previous-revision N", *self.UPDATE)
        self.refused("is not above 10003", *(self.UPDATE + ("--previous-revision", "10003")))
        self.refused("is not above 10004", *(self.UPDATE + ("--previous-revision", "10004", "--dry-run")))
        # the history knows it: that one counts, and --previous-revision may not say otherwise
        self.add_history(revision=10001)
        self.add_history(revision=10003, folder="another_1")  # another folder's
        self.add_history(revision=10005, modId="7000001")  # another mod.io page's
        self.add_history(revision=10009, modId=None, outcome="failed")  # mod.io did not take it
        self.refused("--previous-revision 10002, but publish_history.jsonl says revision 10001",
                     *(self.UPDATE + ("--previous-revision", "10002")))
        self.answers = [self.dry()]
        res = self.run_publish(*(self.UPDATE + ("--dry-run",)))
        self.assertEqual(res["update"]["previousRevision"], 10001)
        self.assertEqual(res["update"]["previousFrom"], "publish_history.jsonl")
        self.add_history(revision=10003)
        self.sent = []
        self.refused("revision 10003 is not above 10003", *self.UPDATE)
        self.revision(10002)
        self.refused("revision 10002 is not above 10003", *self.UPDATE)
        # no revision in mod.json at all
        with open(os.path.join(self.root, "staging_area", FU, "mod.json"), "w") as f:
            f.write("{}")
        self.refused("mod.json has no whole-number revision", *(self.UPDATE + ("--previous-revision", "1")))

    def test_the_changelog_is_required_and_previous_revision_is_for_an_update_only(self):
        self.refused("--changelog", "--public", "yes", "--previous-revision", "10001")
        self.refused("--changelog", "--public", "yes", "--changelog", "  \t ", "--previous-revision", "10001")
        os.remove(os.path.join(self.meta, "mod.io_fileid.txt"))
        self.refused("--previous-revision is only for an update", *(self.FULL + ("--previous-revision", "1")))

    def test_dry_run_sends_one_update_dry_run_answers_what_changes_and_writes_nothing(self):
        self.answers = [self.dry()]
        res = self.run_publish(*(self.UPDATE + ("--dry-run", "--previous-revision", "10001")))
        self.assertTrue(res["ok"])
        self.assertEqual(len(self.sent), 1)
        cmd, args, _ = self.sent[0]
        self.assertEqual(cmd, "modhubPublish")
        self.assertEqual(args, {"folder": FU, "public": True, "update": True, "modioId": self.MODIO,
                                "changelog": "Wording.", "updateMetadata": False, "dryRun": True})
        self.assertNotIn("firstUpload", args)
        self.assertEqual(res["update"], {
            "modioId": self.MODIO, "name": MODINFO["name"], "modioTitle": "Auto Force Unload", "modioVisible": True,
            "modioVersion": "10001", "revision": 10003, "previousRevision": 10001, "previousFrom": "--previous-revision",
            "changelog": "Wording."})
        self.assertEqual(res["local"]["mode"], "update")
        self.assertEqual(res["local"]["fileid"], self.MODIO)
        self.assertIsNone(tf3ctl.read_pending())
        self.assertEqual(self.history(), [])
        # the mod reads it as it was meant
        self.assertEqual(mod_reads(tf3ctl.command_text(9, "modhubPublish", args))["args"], args)

    def test_an_update_keeps_the_page_s_fields_unless_update_metadata_is_given(self):
        # without --update-metadata: the mod is asked for false, the answer says so, and why the name stays
        self.answers = [self.dry(), self.updated()]
        res = self.run_publish(*(self.UPDATE + ("--previous-revision", "10001")))
        self.assertTrue(res["ok"], res)
        self.assertEqual([a["updateMetadata"] for _, a, _ in self.sent], [False, False])
        self.assertIs(res["updateMetadata"], False)
        self.assertNotIn("updateMetadataWarning", res)
        self.assertIn("name, summary and description stay as they are", res["updateMetadataNote"])
        self.assertIs(self.mark_at_send[1]["updateMetadata"], False)
        self.assertIs(self.history()[-1]["updateMetadata"], False)
        # the dry run names a name that would not go up (modinfo.json's against mod.io's title)
        self.revision(10004)
        self.answers = [self.dry()]
        res = self.run_publish(*(self.UPDATE + ("--dry-run",)))
        self.assertTrue(res["ok"], res)
        self.assertIs(res["updateMetadata"], False)
        self.assertIn("is not mod.io's title \"Auto Force Unload\", which stays", res["updateMetadataNote"])

    def test_update_metadata_sends_true_and_warns_in_the_dry_run_and_the_upload(self):
        self.answers = [self.dry()]
        res = self.run_publish(*(self.UPDATE + ("--update-metadata", "--dry-run", "--previous-revision", "10001")))
        self.assertTrue(res["ok"], res)
        self.assertIs(self.sent[0][1]["updateMetadata"], True)
        self.assertIs(res["updateMetadata"], True)
        self.assertEqual(res["updateMetadataWarning"], tf3ctl.UPDATE_METADATA_WARNING)
        self.assertIn("description are replaced", res["updateMetadataWarning"])
        self.assertIn("has to be put back", res["updateMetadataWarning"])
        self.assertNotIn("updateMetadataNote", res)
        self.assertEqual(self.history(), [])
        self.sent, self.mark_at_send = [], []
        self.answers = [self.dry(), self.updated()]
        res = self.run_publish(*(self.UPDATE + ("--update-metadata", "--previous-revision", "10001")))
        self.assertTrue(res["ok"], res)
        self.assertEqual([a["updateMetadata"] for _, a, _ in self.sent], [True, True])
        self.assertEqual(res["updateMetadataWarning"], tf3ctl.UPDATE_METADATA_WARNING)
        self.assertIs(self.mark_at_send[1]["updateMetadata"], True)
        h = self.history()[-1]
        self.assertEqual((h["mode"], h["updateMetadata"], h["outcome"]), ("update", True, "success"))

    def test_a_mod_that_would_send_another_update_metadata_is_refused_before_the_upload(self):
        # an older remote_probe always sends true: the dry run before the upload stops it, nothing goes up
        for answer, says in (({"updateMetadata": True}, "updateMetadata true, not false"),
                             ({}, "updateMetadata null, not false")):
            self.sent = []
            dry = self.dry()
            dry["settings"] = answer
            self.answers = [dry]
            res = self.run_publish(*(self.UPDATE + ("--previous-revision", "10001")))
            self.assertFalse(res["ok"])
            self.assertIn(says, res["error"])
            self.assertTrue(res["preflight"])
            self.assertEqual(len(self.sent), 1, "only the dry run")
            self.assertIsNone(tf3ctl.read_pending())
            self.assertEqual(self.history(), [])
        dry = self.dry()
        dry["settings"] = {"updateMetadata": False}
        self.answers = [dry]
        self.sent = []
        res = self.run_publish(*(self.UPDATE + ("--update-metadata", "--dry-run", "--previous-revision", "10001")))
        self.assertFalse(res["ok"])
        self.assertIn("updateMetadata false, not true", res["error"])

    def test_a_first_upload_always_sends_update_metadata_and_refuses_the_flag(self):
        os.remove(os.path.join(self.meta, "mod.io_fileid.txt"))
        self.refused("--update-metadata is only for an update", *(self.FULL + ("--update-metadata",)))
        self.refused("--update-metadata is only for an update", *(self.FULL + ("--update-metadata", "--dry-run")))

        def first():
            with open(os.path.join(self.meta, "mod.io_fileid.txt"), "w") as f:
                f.write(self.MODIO)
            return {"ok": True, "publishCalled": True, "modId": self.MODIO, "result": {"success": True}}
        self.answers = [{"ok": True, "dryRun": True}, first]
        res = self.run_publish(*self.FULL)
        self.assertTrue(res["ok"], res)
        self.assertEqual([a["updateMetadata"] for _, a, _ in self.sent], [True, True])
        self.assertIs(res["updateMetadata"], True)
        self.assertNotIn("updateMetadataWarning", res, "no page yet to overwrite")
        self.assertIn("a first upload sends", res["updateMetadataNote"])
        self.assertIs(self.mark_at_send[1]["updateMetadata"], True)
        self.assertEqual((self.history()[-1]["mode"], self.history()[-1]["updateMetadata"]), ("firstUpload", True))

    def updated(self, modid=None):
        def answer():
            return {"ok": True, "publishCalled": True, "modId": modid or self.MODIO, "mode": "update",
                    "result": {"success": True}}
        return answer

    def test_an_update_marks_records_the_revision_and_the_next_one_must_be_higher(self):
        self.answers = [self.dry(), self.updated()]
        res = self.run_publish(*(self.UPDATE + ("--previous-revision", "10001")))
        self.assertTrue(res["ok"], res)
        self.assertEqual([a.get("dryRun") for _, a, _ in self.sent], [True, False])
        self.assertTrue(all(a.get("update") is True and a.get("modioId") == self.MODIO for _, a, _ in self.sent))
        mark = self.mark_at_send[1]
        self.assertEqual((mark["update"], mark["firstUpload"], mark["modioId"], mark["revision"]),
                         (True, False, self.MODIO, 10003))
        self.assertTrue(res["pendingCleared"])
        self.assertEqual(res["fileid"], self.MODIO)
        self.assertIsNone(tf3ctl.read_pending())
        h = self.history()[-1]
        self.assertEqual((h["outcome"], h["mode"], h["modioId"], h["modId"], h["revision"]),
                         ("success", "update", self.MODIO, self.MODIO, 10003))
        self.assertEqual(res["update"]["revision"], 10003)
        # the same revision again: refused by the history, whatever --previous-revision says
        self.sent = []
        self.refused("is not above 10003", *self.UPDATE)
        self.refused("says revision 10003", *(self.UPDATE + ("--previous-revision", "10001")))
        self.revision(10004)
        self.answers = [self.dry()]
        res = self.run_publish(*(self.UPDATE + ("--dry-run",)))
        self.assertEqual((res["update"]["revision"], res["update"]["previousRevision"]), (10004, 10003))

    def test_an_update_answered_with_another_mod_io_id_keeps_the_mark(self):
        self.answers = [self.dry(), self.updated("7000077")]
        res = self.run_publish(*(self.UPDATE + ("--previous-revision", "10001")))
        self.assertFalse(res["ok"])
        self.assertTrue(res["pendingKept"])
        self.assertIn("came back as mod.io mod 7000077", res["error"])
        self.assertIsNotNone(tf3ctl.read_pending())
        self.assertEqual(self.history()[-1]["outcome"], "success, other mod.io id")

    def test_a_fileid_changed_during_the_dry_run_stops_it(self):
        def dry_then_change():
            with open(os.path.join(self.meta, "mod.io_fileid.txt"), "w") as f:
                f.write("7000001")
            return self.dry()
        self.answers = [dry_then_change]
        with self.assertRaises(tf3ctl.ToolError) as cm:
            self.run_publish(*(self.UPDATE + ("--previous-revision", "10001")))
        self.assertIn("changed meanwhile", str(cm.exception))
        self.assertEqual(len(self.sent), 1, "only the dry run")
        self.assertIsNone(tf3ctl.read_pending())

    def test_previous_revision_is_one_or_more(self):
        for bad in ("0", "-3"):
            self.refused("whole number of 1 or more", *(self.UPDATE + ("--previous-revision", bad)))

    def test_only_uploads_mod_io_took_count_as_the_last_revision(self):
        self.add_history(revision=10001)
        self.add_history(revision=10003, outcome="partial")
        self.add_history(revision=10004, outcome="failed")  # with a mod.io id written by some other version
        self.add_history(revision=10005, outcome="no answer")
        self.revision(10004)
        self.answers = [self.dry()]
        res = self.run_publish(*(self.UPDATE + ("--dry-run",)))
        self.assertEqual(res["update"]["previousRevision"], 10003)
        self.add_history(revision=10004, outcome="success, fileid missing")
        self.sent = []
        self.refused("is not above 10004", *self.UPDATE)

    def test_a_first_upload_records_its_revision_for_the_next_update(self):
        os.remove(os.path.join(self.meta, "mod.io_fileid.txt"))
        self.revision(10001)
        os.remove(os.path.join(self.meta, "mod.io_fileid.txt"))

        def first():
            with open(os.path.join(self.meta, "mod.io_fileid.txt"), "w") as f:
                f.write(self.MODIO)
            return {"ok": True, "publishCalled": True, "modId": self.MODIO, "result": {"success": True}}
        self.answers = [{"ok": True, "dryRun": True}, first]
        res = self.run_publish(*self.FULL)
        self.assertTrue(res["ok"], res)
        self.assertEqual((self.mark_at_send[1]["firstUpload"], self.mark_at_send[1]["revision"]), (True, 10001))
        h = self.history()[-1]
        self.assertEqual((h["mode"], h["revision"], h["modId"]), ("firstUpload", 10001, self.MODIO))
        # the update after it needs no --previous-revision
        self.revision(10002)
        self.answers = [self.dry()]
        res = self.run_publish(*(self.UPDATE + ("--dry-run",)))
        self.assertEqual((res["update"]["previousRevision"], res["update"]["previousFrom"]), (10001, "publish_history.jsonl"))

    def test_the_publish_list_is_the_configuration_s_and_holds_its_mods_on_mod_io(self):
        # the mod holds no list of its own: it gets the configuration's with every modhub command
        with open(os.path.join(ROOT, "content", "remote_core.lua"), encoding="utf-8") as f:
            lua = f.read()
        for table in ("MODHUB_VALIDATE_FOLDERS", "MODHUB_PUBLISH_FOLDERS", "MODHUB_PUBLISHED_IDS"):
            self.assertIn("M.%s = {}\n" % table, lua, table)
        # one of them as an update: its fileid goes to the mod; as a first upload it is refused (it has a page)
        use_config(CONFIGURED)
        name = "hummer_cursor_altitude_tooltip_1"
        make_staging(self.root, name, fileid="6523060", revision=2)
        self.refused("would make a second page", *(self.UPDATE + ("--first-upload",)), folder=name)
        self.answers = [self.dry()]
        res = self.run_publish(*(self.UPDATE + ("--dry-run", "--previous-revision", "1")), folder=name)
        self.assertTrue(res["ok"], res)
        self.assertEqual((self.sent[0][1]["folder"], self.sent[0][1]["modioId"]), (name, "6523060"))

    def test_a_folder_on_mod_io_is_held_to_its_page_even_without_its_fileid(self):
        use_config(CONFIGURED)  # force unload held to its page again
        name = "hummer_industry_pollution_display_1"
        meta = make_staging(self.root, name, revision=10002)  # no fileid file: it would look new
        self.refused("is on mod.io already (mod 6536959): --first-upload would make a second page", *self.FULL,
                     folder=name)
        self.refused("--first-upload would make a second page", *(self.FULL + ("--dry-run",)), folder=name)
        self.refused("is mod.io mod 6536959, but _metadata/mod.io_fileid.txt is missing",
                     *(self.UPDATE + ("--previous-revision", "10001")), folder=name)
        with open(os.path.join(meta, "mod.io_fileid.txt"), "w") as f:
            f.write("7000001")
        self.refused("is mod.io mod 6536959, but _metadata/mod.io_fileid.txt says 7000001",
                     *(self.UPDATE + ("--previous-revision", "10001", "--dry-run")), folder=name)
        # force unload too, the first folder of the list
        self.refused("is on mod.io already (mod 6543965)", *self.FULL)
        with open(os.path.join(meta, "mod.io_fileid.txt"), "w") as f:
            f.write("6536959")
        self.answers = [self.dry()]
        res = self.run_publish(*(self.UPDATE + ("--previous-revision", "10001", "--dry-run")), folder=name)
        self.assertTrue(res["ok"], res)
        self.assertEqual(self.sent[0][1]["modioId"], "6536959")

    def dry_with(self, meta):
        answer = self.dry()
        answer["settings"] = {"setPublic": True, "updateMetadata": False, "changeLog": "Wording.",
                              "additionalMetadata": meta}
        return answer

    def test_version_is_x_y_z_and_must_be_mod_json_s_revision(self):
        for bad in ("1.0", "1.0.3.4", "v1.0.3", "01.0.3", "1.00.3", "1.0.03", "1.100.0", "1.0.100", "", "1..3",
                    " 1.0.3", "1.0.3\n", "\uff11.0.3", "1.0.3-rc"):
            self.refused("--version is X.Y.Z", *(self.UPDATE + ("--version", bad, "--previous-revision", "10001")))
        self.refused("--version 1.0.1 is revision 10001, but mod.json's revision is 10003 (that is 1.0.3)",
                     *(self.UPDATE + ("--version", "1.0.1", "--previous-revision", "10001", "--dry-run")))
        self.refused("is revision 1, but mod.json's revision is 10003",
                     *(self.UPDATE + ("--version", "0.0.1", "--previous-revision", "10001")))
        self.assertEqual(tf3ctl.version_revision("12.34.56"), 123456)
        self.assertEqual(tf3ctl.version_revision("0.0.1"), 1)
        self.assertEqual(self.history(), [])

    def test_dry_run_with_a_version_sends_version_and_revision_and_answers_additional_metadata(self):
        self.answers = [self.dry_with({"version": "1.0.3"})]
        res = self.run_publish(*(self.UPDATE + ("--version", "1.0.3", "--dry-run", "--previous-revision", "10001")))
        self.assertTrue(res["ok"], res)
        _, args, _ = self.sent[0]
        self.assertEqual((args["version"], args["revision"]), ("1.0.3", 10003))
        self.assertEqual(res["additionalMetadata"], {"version": "1.0.3"})
        self.assertEqual((res["local"]["version"], res["local"]["additionalMetadata"]), ("1.0.3", {"version": "1.0.3"}))
        self.assertIsNone(tf3ctl.read_pending())
        self.assertEqual(self.history(), [])
        # the mod reads the two as they were meant
        got = mod_reads(tf3ctl.command_text(9, "modhubPublish", args))["args"]
        self.assertEqual((got["version"], got["revision"]), ("1.0.3", 10003))
        # without --version: neither is sent, and none is answered
        self.sent = []
        self.answers = [self.dry()]
        res = self.run_publish(*(self.UPDATE + ("--dry-run", "--previous-revision", "10001")))
        self.assertNotIn("version", self.sent[0][1])
        self.assertNotIn("revision", self.sent[0][1])
        self.assertIsNone(res["additionalMetadata"])
        self.assertNotIn("version", res["local"])

    def test_a_mod_that_drops_the_version_is_refused_before_the_upload(self):
        # an older remote_probe in the game ignores version: it would go up without it
        self.answers = [self.dry()]
        res = self.run_publish(*(self.UPDATE + ("--version", "1.0.3", "--previous-revision", "10001")))
        self.assertFalse(res["ok"])
        self.assertIn("would send additionalMetadata null", res["error"])
        self.assertEqual(len(self.sent), 1, "only the dry run")
        self.assertIsNone(tf3ctl.read_pending())
        self.assertEqual(self.history(), [])

    def test_an_update_with_a_version_records_it_in_the_mark_and_the_history(self):
        def updated():
            return {"ok": True, "publishCalled": True, "modId": self.MODIO, "mode": "update",
                    "result": {"success": True}, "settings": {"additionalMetadata": {"version": "1.0.3"}}}
        self.answers = [self.dry_with({"version": "1.0.3"}), updated]
        res = self.run_publish(*(self.UPDATE + ("--version", "1.0.3", "--previous-revision", "10001")))
        self.assertTrue(res["ok"], res)
        self.assertEqual([(a.get("dryRun"), a.get("version"), a.get("revision")) for _, a, _ in self.sent],
                         [(True, "1.0.3", 10003), (False, "1.0.3", 10003)])
        self.assertEqual(self.mark_at_send[1]["version"], "1.0.3")
        h = self.history()[-1]
        self.assertEqual((h["outcome"], h["revision"], h["version"]), ("success", 10003, "1.0.3"))
        self.assertEqual(res["additionalMetadata"], {"version": "1.0.3"})

    def test_a_refused_update_dry_run_leaves_no_mark(self):
        self.answers = [{"ok": False, "error": "mod.io holds no details of mod 6543965", "publishCalled": False}]
        res = self.run_publish(*(self.UPDATE + ("--previous-revision", "10001")))
        self.assertFalse(res["ok"])
        self.assertTrue(res["preflight"])
        self.assertEqual(len(self.sent), 1)
        self.assertIsNone(tf3ctl.read_pending())


class ModhubPublishEndToEndTest(unittest.TestCase):
    """modhub publish through real files, against the fake game in its main menu: the dry run, the upload, the
    fileid the fake game writes, and the refusal of a second one."""

    @classmethod
    def setUpClass(cls):
        cls.root = tempfile.mkdtemp()
        cls.dir = os.path.join(cls.root, "recordings")
        cls.meta = make_staging(cls.root)
        cls.game = subprocess.Popen(["luajit", os.path.join(ROOT, "tests", "fake_game.lua"), cls.root, "60", "menu",
                                     "modhub"], stderr=subprocess.PIPE, text=True)
        deadline = time.time() + 10
        while not glob.glob(os.path.join(cls.dir, "remote_probe__cmd_*.lua")):
            if time.time() > deadline:
                raise RuntimeError("the fake game did not start")
            time.sleep(0.05)
        os.environ["TF3_REMOTE_DIR"] = cls.dir
        os.environ["TF3_ASSUME_RUNNING"] = "1"
        # the fake game's first upload is force unload: out of the configuration's folders held to a page (which
        # the mod gets with each command)
        cls.saved_pins = True
        use_config(configured(publishedIds={k: v for k, v in CONFIGURED["modhub"]["publishedIds"].items()
                                            if k != FU}))

    @classmethod
    def tearDownClass(cls):
        if "saved_pins" in cls.__dict__:
            use_config(CONFIGURED)
        cls.game.kill()
        cls.game.wait()
        cls.game.stderr.close()
        os.environ.pop("TF3_REMOTE_DIR", None)
        os.environ.pop("TF3_ASSUME_RUNNING", None)
        for path in (tf3ctl.pending_path(), tf3ctl.history_path()):
            with contextlib.suppress(OSError):
                os.remove(path)
        shutil.rmtree(cls.root, ignore_errors=True)

    def ctl(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = tf3ctl.main(list(argv))
        return code, json.loads(out.getvalue()) if out.getvalue() else None

    def test_dry_run_then_the_upload_then_no_second_one(self):
        full = ("modhub", "publish", FU, "--public", "yes", "--changelog", "First release.", "--first-upload",
                "--timeout", "60")
        code, res = self.ctl(*(full + ("--dry-run",)))
        self.assertEqual(code, 0, res)
        self.assertTrue(res["wouldPublish"])
        self.assertFalse(res["publishCalled"])
        self.assertEqual(res["settings"], {"setPublic": True, "updateMetadata": True, "changeLog": "First release.",
                                           "isSavegame": False, "issuesConfirmed": False})
        self.assertEqual(res["validation"]["levelConsole"], "Warning")
        self.assertIsNone(tf3ctl.read_pending())
        self.assertFalse(os.path.exists(os.path.join(self.meta, "mod.io_fileid.txt")))
        code, res = self.ctl(*full)
        self.assertEqual(code, 0, res)
        self.assertTrue(res["publishCalled"])
        self.assertEqual(res["modId"], "7000001")
        self.assertEqual(res["fileid"], "7000001")
        self.assertTrue(res["pendingCleared"])
        self.assertTrue(res["cleanedUp"])
        self.assertIsNone(tf3ctl.read_pending())
        with open(tf3ctl.history_path(), encoding="utf-8") as f:
            self.assertEqual(json.loads(f.readlines()[-1])["outcome"], "success")
        # the fileid is there now: the tool refuses on its own (exit 2), before the mod sees anything
        code, res = self.ctl(*full)
        self.assertEqual(code, 2)


class ModhubPublishUpdateEndToEndTest(unittest.TestCase):
    """An update through real files, against the fake game in its main menu with the mod on mod.io: the tool's
    update and modioId reach the mod, which answers mode update; the history keeps the revision, and the same
    revision a second time is refused by the tool."""

    @classmethod
    def setUpClass(cls):
        cls.root = tempfile.mkdtemp()
        cls.dir = os.path.join(cls.root, "recordings")
        cls.meta = make_staging(cls.root, fileid="6543965", revision=10003)
        cls.game = subprocess.Popen(["luajit", os.path.join(ROOT, "tests", "fake_game.lua"), cls.root, "60", "menu",
                                     "modhub-update"], stderr=subprocess.PIPE, text=True)
        deadline = time.time() + 10
        while not glob.glob(os.path.join(cls.dir, "remote_probe__cmd_*.lua")):
            if time.time() > deadline:
                raise RuntimeError("the fake game did not start")
            time.sleep(0.05)
        os.environ["TF3_REMOTE_DIR"] = cls.dir
        os.environ["TF3_ASSUME_RUNNING"] = "1"
        for path in (tf3ctl.pending_path(), tf3ctl.history_path()):
            with contextlib.suppress(OSError):
                os.remove(path)

    # its own game (a classmethod taken from the other class would stop that class's game, not this one)
    tearDownClass = classmethod(ModhubPublishEndToEndTest.tearDownClass.__func__)
    ctl = ModhubPublishEndToEndTest.ctl

    def test_update_dry_run_then_the_update_then_the_same_revision_is_refused(self):
        full = ("modhub", "publish", FU, "--public", "yes", "--changelog", "Wording.", "--timeout", "60")
        # without the previous revision (nothing in the history), and with --first-upload: refused by the tool
        code, res = self.ctl(*(full + ("--dry-run",)))
        self.assertEqual(code, 2)
        code, res = self.ctl(*(full + ("--dry-run", "--first-upload")))
        self.assertEqual(code, 2)
        code, res = self.ctl(*(full + ("--dry-run", "--previous-revision", "10001")))
        self.assertEqual(code, 0, res)
        self.assertEqual((res["mode"], res["modioId"], res["wouldPublish"], res["publishCalled"]),
                         ("update", "6543965", True, False))
        self.assertEqual(res["checks"]["modhubIdValue"], "6543965")
        self.assertIs(res["settings"]["updateMetadata"], False)
        self.assertIs(res["updateMetadata"], False)
        code, res = self.ctl(*(full + ("--dry-run", "--previous-revision", "10001", "--update-metadata")))
        self.assertEqual(code, 0, res)
        self.assertIs(res["settings"]["updateMetadata"], True)
        self.assertIn("updateMetadataWarning", res)
        code, res = self.ctl(*(full + ("--dry-run", "--previous-revision", "10001")))
        self.assertEqual((res["update"]["modioTitle"], res["update"]["modioVersion"], res["update"]["revision"],
                          res["update"]["previousRevision"]), ("Auto Force Unload", "10001", 10003, 10001))
        self.assertIsNone(tf3ctl.read_pending())
        # a version that is not mod.json's revision: refused by the tool; the right one goes through the mod
        code, res = self.ctl(*(full + ("--dry-run", "--previous-revision", "10001", "--version", "1.0.2")))
        self.assertEqual(code, 2)
        code, res = self.ctl(*(full + ("--dry-run", "--previous-revision", "10001", "--version", "1.0.3")))
        self.assertEqual(code, 0, res)
        self.assertEqual(res["additionalMetadata"], {"version": "1.0.3"})
        self.assertEqual(res["settings"]["additionalMetadata"], {"version": "1.0.3"})
        code, res = self.ctl(*(full + ("--previous-revision", "10001", "--version", "1.0.3")))
        self.assertEqual(code, 0, res)
        self.assertTrue(res["publishCalled"])
        self.assertEqual(res["additionalMetadata"], {"version": "1.0.3"})
        self.assertEqual((res["modId"], res["fileid"]), ("6543965", "6543965"))
        self.assertTrue(res["pendingCleared"])
        with open(tf3ctl.history_path(), encoding="utf-8") as f:
            h = json.loads(f.readlines()[-1])
        self.assertEqual((h["outcome"], h["mode"], h["revision"], h["modId"], h["version"], h["updateMetadata"]),
                         ("success", "update", 10003, "6543965", "1.0.3", False))
        self.assertIs(res["settings"]["updateMetadata"], False)
        # the same revision again: the tool refuses it from the history (exit 2), before the mod sees anything
        code, res = self.ctl(*full)
        self.assertEqual(code, 2)


class ModFilesTest(unittest.TestCase):
    """mod.json and strings.json: what the game reads at startup, never run by the other tests."""

    def setUp(self):
        with open(os.path.join(ROOT, "mod.json"), encoding="utf-8") as f:
            self.mod = json.load(f)
        with open(os.path.join(ROOT, "strings.json"), encoding="utf-8") as f:
            self.strings = json.load(f)

    def test_english_and_japanese_have_the_same_keys(self):
        self.assertEqual(set(self.strings), {"en", "ja"})
        self.assertEqual(set(self.strings["en"]), set(self.strings["ja"]))
        for lang, table in self.strings.items():
            for key, text in table.items():
                self.assertTrue(isinstance(text, str) and text, f"{lang}.{key} is empty")

    def test_every_settings_text_is_translated(self):
        for p in self.mod["params"]:
            for key in [p["name"], p["tooltip"]] + p["values"]:
                self.assertIn(key, self.strings["en"], f"{p['key']}: {key} missing")
        self.assertIn("mod_name", self.strings["en"])
        self.assertIn("mod_desc", self.strings["en"])

    def test_settings_keep_their_meaning_for_saved_choices(self):
        # a save stores each setting as an index: the keys, the number of values and the defaults must not move
        got = [(p["key"], len(p["values"]), p["defaultIndex"]) for p in self.mod["params"]]
        self.assertEqual(got, [("pollIdle", 4, 1), ("pollActive", 4, 1), ("logLevel", 3, 1), ("speedLabel", 2, 0), ("speedButtons", 2, 0),
                               ("gameScript", 2, 0)])

    def test_mod_list_info_has_a_name_authors_and_the_repository(self):
        # the game's mod list reads these, not strings.json: without them it shows the folder name and empty fields
        with open(os.path.join(ROOT, "_metadata", "modinfo.json"), encoding="utf-8") as f:
            info = json.load(f)
        self.assertIn("Remote Probe", info["name"])
        self.assertEqual(info["authors"], [{"name": "hummer", "role": "CREATOR"}])
        self.assertTrue(info["summary"] and info["description"] and info["tags"])
        self.assertIn("github.com/hummer98/tpf3-remote-probe", info["url"])
        with open(os.path.join(ROOT, "_metadata", "0.png"), "rb") as f:
            head = f.read(24)
        self.assertEqual(head[:8], b"\x89PNG\r\n\x1a\n")
        self.assertEqual((int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")), (1920, 1080))

    def test_time_warp_is_incompatible(self):
        # Time Warp (mod.io 6453396) replaces the same speed buttons with its own 8x/16x: the game must not
        # enable both (the format is the game's, as other mods write it)
        self.assertEqual(self.mod["incompatibilities"], [{"mod": {"modId": "mobarzik_faster_game_speed"}}])
        self.assertIsNone(self.mod["dependencies"])

    def test_label_patterns_keep_their_placeholder(self):
        for lang, table in self.strings.items():
            for key, text in table.items():
                if key.startswith(("hummer_remote_probe_label_", "hummer_remote_probe_tip_")) and key != "hummer_remote_probe_tip_run":
                    self.assertEqual(text.count("%s"), 1, f"{lang}.{key}")


class FakeX11:
    """Stands in for libX11: records what would have been sent; never touches a display."""

    def __init__(self, window=0x3c00002, size=(5120, 2160)):
        self.window, self.wsize, self.sent, self.closed, self.titles = window, size, [], False, []

    def find(self, title):
        self.titles.append(title)
        return self.window

    def size(self, w):
        return self.wsize

    def send(self, w, typ, x, y):
        self.sent.append((w, typ, x, y))

    def close(self):
        self.closed = True


class BuildMenusTest(unittest.TestCase):
    def test_the_tools_menus_are_the_mods(self):
        r = subprocess.run(["luajit", "-e", 'package.path = "%s/content/?.lua;" .. package.path; '
                            'local t = {} for k in pairs(require("remote_core").BUILD_MENUS) do t[#t + 1] = k end '
                            'table.sort(t) io.write(table.concat(t, ","))' % ROOT],
                           capture_output=True, text=True, check=True)
        self.assertEqual(r.stdout.split(","), sorted(tf3ctl.BUILD_MENUS))

    def test_menu_without_res_sends_only_the_menu(self):
        ns = tf3ctl.make_parser().parse_args(["build-tool", "--menu", "road"])
        self.assertEqual(tf3ctl.build_tool_args(ns), {"menu": "road"})
        ns = tf3ctl.make_parser().parse_args(["build-tool", "--menu", "road", "--res", "a.con", "--seconds", "9"])
        self.assertEqual(tf3ctl.build_tool_args(ns), {"menu": "road", "res": "a.con", "seconds": 9})
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            tf3ctl.make_parser().parse_args(["build-tool", "--menu", "perks"])


class PointerTest(unittest.TestCase):
    def ns(self, pos, px=False, title=tf3ctl.TF3_WINDOW_TITLE):
        return tf3ctl.argparse.Namespace(pos=pos, px=px, title=title)

    def test_fractions_and_pixels_map_into_the_window(self):
        self.assertEqual(tf3ctl.pointer_target("0.5,0.47", 5120, 2160), (2560, 1015))
        self.assertEqual(tf3ctl.pointer_target(" 0 , 0 ", 5120, 2160), (0, 0))
        self.assertEqual(tf3ctl.pointer_target("1,1", 5120, 2160), (5119, 2159), "the far edge stays inside")
        self.assertEqual(tf3ctl.pointer_target("1920,1080", 5120, 2160, pixels=True), (1920, 1080))

    def test_bad_positions_are_refused(self):
        for spec, px in (("", False), (None, False), ("0.5", False), ("0.5,0.5,1", False), ("a,b", False),
                         ("1.5,0.5", False), ("-0.1,0.5", False), ("nan,0.5", False), ("inf,0", False),
                         ("5120,0", True), ("0,-1", True), ("1e9,0", True)):
            with self.assertRaises(tf3ctl.ToolError, msg=repr(spec)):
                tf3ctl.pointer_target(spec, 5120, 2160, pixels=px)
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.pointer_target("0.5,0.5", 0, 0)

    def test_events_are_only_enter_and_motion_and_end_on_the_target(self):
        ev = tf3ctl.pointer_events(100, 50, 5120)
        self.assertEqual(ev[0], (tf3ctl.X_ENTER_NOTIFY, 100, 50))
        self.assertEqual(ev[-1], (tf3ctl.X_MOTION_NOTIFY, 100, 50))
        self.assertEqual({t for t, _, _ in ev}, {6, 7}, "EnterNotify and MotionNotify only")
        self.assertTrue(all(y == 50 for _, _, y in ev))
        edge = tf3ctl.pointer_events(0, 0, 5120)
        self.assertTrue(all(0 <= x for _, x, _ in edge), "the wiggle stays inside at the left edge")
        right = tf3ctl.pointer_events(5119, 0, 5120)
        self.assertTrue(all(x <= 5119 for _, x, _ in right), "and at the right edge")

    def test_masks_match_the_event_types(self):
        self.assertEqual(tf3ctl.POINTER_EVENTS, {7: 1 << 4, 6: 1 << 6})

    def test_send_refuses_buttons_and_keys_before_touching_x(self):
        # KeyPress 2, KeyRelease 3, ButtonPress 4, ButtonRelease 5: never sent, whatever the caller asks
        for typ in (2, 3, 4, 5, 0, None):
            with self.assertRaises(tf3ctl.ToolError, msg=repr(typ)):
                tf3ctl.X11.send(object(), 1, typ, 0, 0)

    def test_pointer_sends_the_events_to_the_game_window(self):
        fake, waits = FakeX11(), []
        out = tf3ctl.cmd_pointer(self.ns("0.5,0.47"), x11_factory=lambda: fake, sleep=waits.append)
        self.assertTrue(out["ok"])
        self.assertEqual((out["x"], out["y"], out["size"], out["window"]), (2560, 1015, [5120, 2160], "0x3c00002"))
        self.assertEqual(fake.titles, ["Transport Fever 3"])
        self.assertEqual([s[1:] for s in fake.sent], tf3ctl.pointer_events(2560, 1015, 5120))
        self.assertTrue(all(s[0] == 0x3c00002 for s in fake.sent))
        self.assertEqual(len(waits), len(fake.sent) - 1)
        self.assertTrue(fake.closed)

    def test_no_window_or_bad_position_sends_nothing_and_closes(self):
        fake = FakeX11(window=None)
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.cmd_pointer(self.ns("0.5,0.5"), x11_factory=lambda: fake, sleep=lambda s: None)
        self.assertEqual((fake.sent, fake.closed), ([], True))
        fake = FakeX11()
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.cmd_pointer(self.ns("2,2"), x11_factory=lambda: fake, sleep=lambda s: None)
        self.assertEqual((fake.sent, fake.closed), ([], True))

    def test_parser_takes_position_px_and_title(self):
        ns = tf3ctl.make_parser().parse_args(["pointer", "0.25,0.75"])
        self.assertEqual((ns.cmd, ns.pos, ns.px, ns.title), ("pointer", "0.25,0.75", False, "Transport Fever 3"))
        ns = tf3ctl.make_parser().parse_args(["pointer", "10,20", "--px", "--title", "X"])
        self.assertEqual((ns.px, ns.title), (True, "X"))

    def test_main_reports_a_missing_display_as_a_tool_error(self):
        def no_display():
            raise tf3ctl.ToolError("cannot open the X display")
        old = tf3ctl.X11
        tf3ctl.X11 = no_display
        try:
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                code = tf3ctl.main(["pointer", "0.5,0.5"])
        finally:
            tf3ctl.X11 = old
        self.assertEqual(code, 2)
        self.assertIn("X display", err.getvalue())


class OwnerCheckTest(unittest.TestCase):
    """Game-changing commands go only to the game this --owner started (launched.json), 2026-11-23: a script left
    running after a crash sent save and quit to the game another client had started meanwhile."""

    def setUp(self):
        self.saved = {k: getattr(tf3ctl, k) for k in ("game_pids", "OWNER", "OTHER_OWNER_OK", "exchange_dir")}
        self.saved_env = os.environ.get("XDG_RUNTIME_DIR")
        self.run_dir = tempfile.mkdtemp()
        os.environ["XDG_RUNTIME_DIR"] = self.run_dir
        self.x = tempfile.mkdtemp()  # an exchange folder: a refused command must leave nothing in it
        tf3ctl.exchange_dir = lambda: self.x
        tf3ctl.game_pids = lambda: [4242]
        tf3ctl.OWNER, tf3ctl.OTHER_OWNER_OK = "alice", False

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(tf3ctl, k, v)
        os.environ["XDG_RUNTIME_DIR"] = self.saved_env
        shutil.rmtree(self.run_dir, ignore_errors=True)
        shutil.rmtree(self.x, ignore_errors=True)

    def record(self, owner, pid=4242):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertTrue(tf3ctl.write_launched(pid, owner=owner)["written"])

    def refused(self, cmd, args=None):
        with self.assertRaises(tf3ctl.OwnerRefused) as cm:
            tf3ctl.send(cmd, args, timeout=0.1, folder=self.x)
        self.assertEqual(os.listdir(self.x), [], "nothing written for the game")
        return str(cm.exception)

    def test_another_owners_game_refuses_every_game_changing_command(self):
        self.record("bob")
        for cmd in sorted(tf3ctl.CHANGES_GAME):
            msg = self.refused(cmd, {"x": 1})
            self.assertIn("started by bob, not by alice", msg, cmd)
        self.assertIsInstance(tf3ctl.OwnerRefused("x"), tf3ctl.ToolError)

    def test_no_record_refuses_a_game_started_from_steam(self):
        self.assertIn("not started by tf3ctl", self.refused("save", {"name": "x"}))
        self.assertIn("not started by tf3ctl", self.refused("quit"))
        os.makedirs(os.path.join(self.run_dir, "tf3ctl"))
        write(os.path.join(self.run_dir, "tf3ctl", "launched.json"), "not json")
        self.assertIn("cannot read", self.refused("speed", {"speed": 1}))
        write(os.path.join(self.run_dir, "tf3ctl", "launched.json"), '{"v": 1, "owner": "alice", "pid": true}')
        self.assertIn("no owner and pid", self.refused("speed", {"speed": 1}))
        write(os.path.join(self.run_dir, "tf3ctl", "launched.json"), '{"v": 2, "owner": "alice", "pid": 4242}')
        self.assertIn("version 1", self.refused("speed", {"speed": 1}))
        os.remove(os.path.join(self.run_dir, "tf3ctl", "launched.json"))
        other = os.path.join(self.run_dir, "elsewhere.json")
        write(other, '{"v": 1, "owner": "alice", "pid": 4242}')
        os.symlink(other, os.path.join(self.run_dir, "tf3ctl", "launched.json"))
        self.assertIn("not a file of this user", self.refused("speed", {"speed": 1}))

    def test_a_record_of_another_pid_refuses(self):
        self.record("alice", pid=1111)  # the launched game is gone; the running one came from Steam
        msg = self.refused("save", {"name": "x"})
        self.assertIn("pid 1111", msg)
        self.assertIn("4242", msg)

    def test_no_owner_refuses_even_the_launchers_game(self):
        self.record("alice")
        tf3ctl.OWNER = None
        self.assertIn("no --owner", self.refused("quit"))

    def test_other_mods_commands_that_change_the_game_go_past_the_owner_check(self):
        self.record("bob")
        args = {"mod": "m", "command": "c", "args": {}, "timeout": 25}
        self.assertIn("started by bob, not by alice", self.refused("modChange", args))
        for cmd in ("modList", "modRead"):
            self.assertIsNone(tf3ctl.check_game_owner(cmd, args), cmd)
        # a dryRun inside the command's own arguments is the other mod's business: still changing
        self.assertTrue(tf3ctl.changes_game("modChange", dict(args, args={"dryRun": True})))
        self.assertNotIn("modChange", tf3ctl.COOP_ALLOWED, "not one of the commands coop lets through")

    def test_reading_commands_dry_runs_and_camera_reading_go(self):
        self.record("bob")
        for cmd, args in (("status", None), ("stations", {}), ("industryStocks", {}), ("saves", None),
                          ("load", {"save": "s", "dryRun": True}), ("newgame", {"list": True}),
                          ("build", {"res": "x", "dryRun": True}), ("camera", {})):
            self.assertIsNone(tf3ctl.check_game_owner(cmd, args), cmd)
        with self.assertRaises(tf3ctl.OwnerRefused):
            tf3ctl.check_game_owner("camera", {"set": "1,2,3,4,5"})
        for cmd in ("modhubPublish", "modhubValidate"):  # their dry run still runs the validator
            with self.assertRaises(tf3ctl.OwnerRefused):
                tf3ctl.check_game_owner(cmd, {"folder": "f", "dryRun": True})

    def test_no_game_running_lets_it_through_to_say_where_the_game_is(self):
        tf3ctl.game_pids = lambda: []
        self.assertIsNone(tf3ctl.check_game_owner("save", {"name": "x"}))

    def test_own_record_goes_as_before(self):
        self.record("alice")
        self.assertIsNone(tf3ctl.check_game_owner("save", {"name": "x"}))
        tf3ctl.game_pids = lambda: [4000, 4242]  # several processes: the recorded one among them
        self.assertIsNone(tf3ctl.check_game_owner("quit"))

    def test_other_owner_ok_sends_and_says_so(self):
        self.record("bob")
        tf3ctl.OTHER_OWNER_OK = True
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            note = tf3ctl.check_game_owner("save", {"name": "x"})
        self.assertEqual(note["launchedBy"], "bob")
        self.assertEqual(note["owner"], "alice")
        self.assertIn("--other-owner-ok", err.getvalue())
        # through send: the command file carries it for the mod's log line, and the answer has it
        sent = {}

        def fake_write(folder, cid, cmd, args):
            sent.update(cmd=cmd, args=args)
        with unittest.mock.patch.object(tf3ctl, "write_command", fake_write), \
                unittest.mock.patch.object(tf3ctl, "cleanup", lambda f: None), \
                unittest.mock.patch.object(tf3ctl, "note_activity", lambda *a: None), \
                unittest.mock.patch.object(tf3ctl, "wait_pickup", lambda f, c: None), \
                unittest.mock.patch.object(tf3ctl, "wait_answer", lambda *a: {"ok": True}), \
                contextlib.redirect_stderr(io.StringIO()):
            res = tf3ctl.send("save", {"name": "x"}, folder=self.x)
        self.assertEqual(sent["args"]["_otherOwnerOk"], "bob")
        self.assertEqual(res["otherOwnerOk"]["launchedBy"], "bob")
        os.remove(tf3ctl.launched_path())
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(tf3ctl.check_game_owner("quit")["launchedBy"], "none", "a game from Steam")

    def test_quit_kill_never_kills_a_game_it_may_not_quit(self):
        self.record("bob")
        kills = []
        with unittest.mock.patch.object(tf3ctl.os, "kill", lambda pid, sig: kills.append(pid)), \
                self.assertRaises(tf3ctl.OwnerRefused):
            tf3ctl.quit_game(timeout=0.1, kill=True, force=True)
        self.assertEqual(kills, [])
        self.assertTrue(os.path.exists(tf3ctl.launched_path()), "bob's record stays")

    def test_quit_kill_kills_only_the_processes_it_sent_the_quit_to(self):
        self.record("alice")
        calls = []

        def pids():  # the game ends while the quit waits, and somebody starts another (pid 5555)
            calls.append(1)
            return [4242] if len(calls) <= 1 else [5555]
        tf3ctl.game_pids = pids
        kills = []
        with unittest.mock.patch.object(tf3ctl, "send", lambda *a, **k: {"ok": False, "error": "no"}), \
                unittest.mock.patch.object(tf3ctl.os, "kill", lambda pid, sig: kills.append(pid)), \
                unittest.mock.patch.object(tf3ctl, "wait_exit", lambda t: False), \
                contextlib.redirect_stderr(io.StringIO()):
            try:
                tf3ctl.quit_game(timeout=0.1, kill=True, force=True)
            except tf3ctl.ToolError:
                pass
        self.assertEqual(kills, [], "pid 5555 was not there when the quit was sent")
        tf3ctl.game_pids = lambda: [4242]  # still the same game: killed, as before
        with unittest.mock.patch.object(tf3ctl, "send", lambda *a, **k: {"ok": False, "error": "no"}), \
                unittest.mock.patch.object(tf3ctl.os, "kill", lambda pid, sig: kills.append(pid)), \
                unittest.mock.patch.object(tf3ctl, "wait_exit", lambda t: False), \
                contextlib.redirect_stderr(io.StringIO()):
            try:
                tf3ctl.quit_game(timeout=0.1, kill=True, force=True)
            except tf3ctl.ToolError:
                pass
        self.assertEqual(kills, [4242])

    def test_launch_load_without_owner_is_refused_before_starting(self):
        tf3ctl.OWNER = None
        tf3ctl.game_pids = lambda: []
        ns = tf3ctl.argparse.Namespace(load="s", new=False, add=[], remove=[], set_mods=None, param=[],
                                       wait_for_start=False, lang=None, launch_timeout=1, timeout=1)
        with unittest.mock.patch.object(tf3ctl, "launch_game", lambda t: self.fail("launched")), \
                self.assertRaises(tf3ctl.OwnerRefused) as cm:
            tf3ctl.cmd_start(ns, restart=False)
        self.assertIn("give --owner", str(cm.exception))
        ns.load = None  # a plain launch without an owner still goes (no record, nothing to send after it)
        with unittest.mock.patch.object(tf3ctl, "launch_game", lambda t: {"ok": True}), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertIs(tf3ctl.cmd_start(ns, restart=False)["ok"], True)

    def test_launch_load_stops_when_the_record_is_not_written(self):
        tf3ctl.game_pids = lambda: []
        ns = tf3ctl.argparse.Namespace(load="s", new=False, add=[], remove=[], set_mods=None, param=[],
                                       wait_for_start=False, lang=None, launch_timeout=1, timeout=1)

        def fake_launch(t):
            tf3ctl.game_pids = lambda: [5555]
            return {"ok": True}
        with unittest.mock.patch.object(tf3ctl, "launch_game", fake_launch), \
                unittest.mock.patch.object(tf3ctl, "write_launched", lambda pid: {"written": False, "warning": "x"}), \
                unittest.mock.patch.object(tf3ctl, "replace_game", lambda *a: self.fail("load sent")), \
                contextlib.redirect_stderr(io.StringIO()):
            out = tf3ctl.cmd_start(ns, restart=False)
        self.assertIs(out["ok"], False)
        self.assertIn("not written", out["error"])

    def test_run_does_not_pause_another_owners_game_after_its_refusal(self):
        self.record("bob")
        ns = tf3ctl.argparse.Namespace(months=1, days=None, until_date=None, speed=4, force=False, timeout=1)
        sent = []
        real_send = tf3ctl.send

        def counting_send(cmd, *a, **k):
            sent.append(cmd)
            return real_send(cmd, *a, **k)
        with unittest.mock.patch.object(tf3ctl, "capped_speed", lambda *a: (4, None, {})), \
                unittest.mock.patch.object(tf3ctl, "send", counting_send), \
                self.assertRaises(tf3ctl.OwnerRefused), contextlib.redirect_stderr(io.StringIO()):
            tf3ctl.cmd_run(ns)
        self.assertEqual(sent, ["run", "speed"], "the pause after the refusal was tried, and refused too")
        self.assertEqual(os.listdir(self.x), [], "neither run nor its speed 0 reached the game")

    def test_restart_of_another_owners_game_quits_nothing(self):
        self.record("bob")
        ns = tf3ctl.argparse.Namespace(load=None, new=False, lang=None, quit_timeout=0.1, no_kill=False,
                                       force=False, launch_timeout=1, timeout=1)
        with unittest.mock.patch.object(tf3ctl, "launch_game", lambda t: self.fail("launched")), \
                self.assertRaises(tf3ctl.OwnerRefused):
            tf3ctl.cmd_start(ns, restart=True)

    def test_main_exits_4_for_save_and_quit_of_another_owners_game(self):
        self.record("bob")
        for argv in (["--owner", "alice", "save", "x"], ["--owner", "alice", "quit"],
                     ["--owner", "alice", "quit", "--kill"], ["save", "x"]):
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                self.assertEqual(tf3ctl.main(argv), 4, argv)
            self.assertEqual(json.loads(out.getvalue())["refused"], "owner")
            self.assertIn("refused", err.getvalue())
        self.assertEqual(os.listdir(self.x), [])

    def test_launch_by_a_new_owner_rewrites_the_record(self):
        self.record("bob", pid=1111)  # bob's game crashed; carol starts one
        tf3ctl.OWNER = "carol"
        tf3ctl.game_pids = lambda: []
        ns = tf3ctl.argparse.Namespace(load=None, new=False, lang=None, launch_timeout=1, timeout=1)

        def fake_launch(t):
            tf3ctl.game_pids = lambda: [5555]
            return {"ok": True, "menu": True}
        with unittest.mock.patch.object(tf3ctl, "launch_game", fake_launch), \
                contextlib.redirect_stderr(io.StringIO()):
            tf3ctl.cmd_start(ns, restart=False)
        rec, why = tf3ctl.read_launched()
        self.assertEqual((rec["owner"], rec["pid"]), ("carol", 5555))
        self.assertIsNone(tf3ctl.check_game_owner("load", {"save": "s"}), "carol's load in her main menu goes")
        tf3ctl.OWNER = "bob"
        with self.assertRaises(tf3ctl.OwnerRefused):
            tf3ctl.check_game_owner("save", {"name": "x"})


class CoopTest(unittest.TestCase):
    """coop: the user and one client share the running game (2026-11-23). The client may look, build and send test
    commands, also on the user's own save, but never quit, load or save over the user's game; a change to a
    person's save is counted, and status / coop end say so."""

    def setUp(self):
        self.saved = {k: getattr(tf3ctl, k) for k in ("game_pids", "OWNER", "OTHER_OWNER_OK", "USER_ASKED",
                                                       "exchange_dir")}
        self.saved_env = {k: os.environ.get(k) for k in ("XDG_RUNTIME_DIR", "TF3_LOG")}
        self.run_dir = tempfile.mkdtemp()
        os.environ["XDG_RUNTIME_DIR"] = self.run_dir
        self.x = tempfile.mkdtemp()
        self.log = os.path.join(self.x, "stdout.txt")
        os.environ["TF3_LOG"] = self.log
        self.loaded("probe-flat-base")
        tf3ctl.exchange_dir = lambda: self.x
        tf3ctl.game_pids = lambda: [4242]
        tf3ctl.OWNER, tf3ctl.OTHER_OWNER_OK, tf3ctl.USER_ASKED = "alice", False, False

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(tf3ctl, k, v)
        for k, v in self.saved_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.run_dir, ignore_errors=True)
        shutil.rmtree(self.x, ignore_errors=True)

    def loaded(self, save):
        lines = ["[2026-11-23 11:00:00Z - MESSAGE - Main Thread - Main ]  Application startup",
                 "[2026-11-23 11:00:30Z - MESSAGE - Main Thread - Main ]  Main menu is ready"]
        if save == "":
            lines.append("[2026-11-23 11:01:00Z - MESSAGE - Main Thread - Main ]  Start new game...")
        elif save is not None:
            lines.append("[2026-11-23 11:01:00Z - MESSAGE - Load Game Pool 1 - Main ]  Loading game from file " + save)
        lines.append("[2026-11-23 11:01:20Z - MESSAGE - Main Thread - Main ]  Game is ready")
        write(self.log, "\n".join(lines) + "\n")

    def record(self, owner, pid=4242):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertTrue(tf3ctl.write_launched(pid, owner=owner)["written"])

    def start(self, owner="alice", minutes=60, now=None):
        tf3ctl.OWNER = owner
        return tf3ctl.coop_start(minutes, "try the depot together", now=now)

    def rec(self):
        with open(tf3ctl.launched_path(), encoding="utf-8") as f:
            return json.load(f)

    def goes(self, cmd, args=None):
        note = tf3ctl.check_game_owner(cmd, args)
        self.assertIsNotNone(note, cmd)
        self.assertIn("coop", note, cmd)
        return note

    def refused(self, cmd, args=None):
        with self.assertRaises(tf3ctl.CoopRefused) as cm:
            tf3ctl.send(cmd, args, timeout=0.1, folder=self.x)
        self.assertEqual(os.listdir(self.x), ["stdout.txt"], "nothing written for the game")
        self.assertIn("the user is playing", str(cm.exception))
        return str(cm.exception)

    def sent(self, cmd, args):
        """Through send with the mod faked: the answer."""
        with unittest.mock.patch.object(tf3ctl, "write_command", lambda *a: None), \
                unittest.mock.patch.object(tf3ctl, "cleanup", lambda f: None), \
                unittest.mock.patch.object(tf3ctl, "note_activity", lambda *a: None), \
                unittest.mock.patch.object(tf3ctl, "wait_pickup", lambda f, c: None), \
                unittest.mock.patch.object(tf3ctl, "wait_answer", lambda *a: {"ok": True}), \
                contextlib.redirect_stderr(io.StringIO()):
            return tf3ctl.send(cmd, args, folder=self.x)

    # (a)
    def test_a_launchers_coop_lets_build_and_camera_through_not_quit_or_load(self):
        self.record("alice")
        self.start()
        rec = self.rec()
        self.assertEqual((rec["v"], rec["owner"], rec["pid"], rec["cmd"]), (1, "alice", 4242, "launch"), "kept")
        self.assertEqual(rec["coop"]["with"], "alice")
        self.assertEqual(rec["coop"]["reason"], "try the depot together")
        self.assertEqual(rec["coop"]["until"] - rec["coop"]["since"], 3600)
        for cmd, args in (("build", {"res": "x"}), ("camera", {"set": "1,2,3,4,5"}), ("window", {"entity": 1}),
                          ("event", {"name": "e"}), ("road", {"from": [0, 0]}), ("stockSet", {"entity": 1}),
                          ("money", {"set": 1}), ("steps", {"count": 5}),
                          ("build", {"res": "x", "dryRun": True, "engineCheck": True})):  # fit's check
            self.assertFalse(self.goes(cmd, args)["count"], "a test save: nothing to count")
        self.assertIsNone(tf3ctl.check_game_owner("stations", {}), "reading goes as ever")
        for cmd, args in (("quit", None), ("load", {"save": "s"}), ("newgame", {}), ("tool", {"x": 1}),
                          ("modhubValidate", {"folder": "f"}), ("buy", {"x": 1})):
            self.assertIn("'%s'" % cmd, self.refused(cmd, args))
        self.assertIn("--close-all", self.refused("window", {"closeAll": True}))
        tf3ctl.OTHER_OWNER_OK = True  # does not widen coop
        self.refused("quit")
        kills = []
        with unittest.mock.patch.object(tf3ctl.os, "kill", lambda pid, sig: kills.append(pid)), \
                self.assertRaises(tf3ctl.CoopRefused):
            tf3ctl.quit_game(timeout=0.1, kill=True, force=True)  # restart's quit too
        self.assertEqual(kills, [])

    def test_speed_run_pause_only_when_the_user_asked(self):
        self.record("alice")
        self.start()
        self.assertIn("--user-asked", self.refused("speed", {"speed": 0}))
        self.assertIn("--user-asked", self.refused("run", {"days": 1}))
        tf3ctl.USER_ASKED = True
        self.goes("speed", {"speed": 4})
        self.goes("run", {"days": 1})
        # through main: the flag is parsed on speed, pause and run, and the refusal is exit 4 "coop"
        tf3ctl.USER_ASKED = False
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(tf3ctl.main(["--owner", "alice", "pause"]), 4)
        self.assertEqual(json.loads(out.getvalue())["refused"], "coop")
        p = tf3ctl.make_parser()
        for argv in (["speed", "1", "--user-asked"], ["pause", "--user-asked"], ["run", "--days", "1", "--user-asked"],
                     ["save", "probe-x", "--user-asked"]):
            self.assertTrue(p.parse_args(argv).user_asked, argv)

    def test_save_only_to_a_test_name(self):
        self.record("alice")
        self.start()
        self.goes("save", {"name": "probe-after"})
        self.goes("save", {"name": "3-probe"})
        for name in ("aom-eu-1900", "aom-long-12m", "39-x", "../probe-x", "probe-x/../aom-eu-1900", ""):
            tf3ctl.USER_ASKED = True  # not even when asked: the user's names are never written
            self.assertIn("not a test save", self.refused("save", {"name": name}), name)

    # (b')
    def test_b_a_persons_save_takes_build_refuses_save_and_status_says_changed(self):
        self.loaded("aom-eu-1900")
        tf3ctl.game_pids = lambda: [4242]
        tf3ctl.OWNER = "alice"
        # without coop: as before, a person's game refuses everything
        with self.assertRaises(tf3ctl.OwnerRefused) as cm:
            tf3ctl.check_game_owner("build", {"res": "x"})
        self.assertNotIsInstance(cm.exception, tf3ctl.CoopRefused)
        self.start()  # a game a person started: the record has no owner
        rec = self.rec()
        self.assertNotIn("owner", rec)
        self.assertEqual((rec["v"], rec["pid"], rec["cmd"]), (1, 4242, "coop"))
        self.assertTrue(self.goes("build", {"res": "x"})["count"])
        self.assertFalse(self.goes("camera", {"set": "1,2,3,4,5"})["count"], "the view is not the game")
        self.assertIn("not saved", self.refused("save", {"name": "probe-new"}))
        self.assertIn("not a test save", self.refused("save", {"name": "aom-eu-1900"}))
        tf3ctl.USER_ASKED = True
        self.assertFalse(self.goes("save", {"name": "probe-new"})["count"])
        self.assertIn("not a test save", self.refused("save", {"name": "aom-eu-1900"}))
        tf3ctl.USER_ASKED = False
        self.assertNotIn("modified", self.rec()["coop"])
        res = self.sent("build", {"res": "x"})
        self.assertEqual(res["coop"]["save"], "aom-eu-1900")
        self.sent("steps", {"count": 5})
        self.sent("camera", {"set": "1,2,3,4,5"})  # not counted
        self.assertEqual((self.rec()["coop"]["modified"], self.rec()["coop"]["changes"]), (True, 2))
        self.assertNotIn("owner", self.rec(), "the count keeps the record's shape")
        note = tf3ctl.coop_note()["coop"]
        self.assertTrue(note["active"])
        self.assertIn("changed during coop (2 times)", note["text"])
        self.assertIn("このゲームは共同作業で変更されています（2 回）。保存すると変更が残ります", note["textJa"])
        end = tf3ctl.coop_end()
        self.assertIn("オートセーブ（10 分ごと）には変更後の状態が入っています", end["coop"]["textJa"])
        self.assertIn("load a named save again", end["coop"]["text"])
        self.assertNotIn("coop", self.rec(), "coop end removes the mark only")
        self.assertEqual(self.rec()["pid"], 4242)
        # after coop end a person's game refuses again
        with self.assertRaises(tf3ctl.OwnerRefused) as cm:
            tf3ctl.check_game_owner("build", {"res": "x"})
        self.assertNotIsInstance(cm.exception, tf3ctl.CoopRefused)
        self.assertEqual(tf3ctl.coop_note(), {})

    def test_a_new_game_or_an_unknown_save_counts_as_a_persons(self):
        for save in ("", None):
            self.loaded(save)
            self.start()
            self.assertTrue(self.goes("build", {"res": "x"})["count"], save)
            self.assertIn("not saved", self.refused("save", {"name": "probe-new"}))

    def test_is_test_save(self):
        for name in ("probe-x", "aom-ops-u6", "aom-shot-1950", "aom-bgm-check-1", "3-probe", "6", "3.sav",
                     "/a/b/probe-x.sav"):
            self.assertTrue(tf3ctl.is_test_save(name), name)
        for name in ("aom-eu-1900", "aom-long-12m", "39-x", "Probe-x", "", None, 3, "autosave_1", "xprobe-"):
            self.assertFalse(tf3ctl.is_test_save(name), name)
        self.assertFalse(tf3ctl.is_test_save("/a/probe-x", path_ok=False), "a name to save to is a plain name")

    # (c)
    def test_c_without_coop_as_before(self):
        self.record("bob")
        for cmd in ("build", "camera", "quit", "save"):
            with self.assertRaises(tf3ctl.OwnerRefused) as cm:
                tf3ctl.check_game_owner(cmd, {"x": 1})
            self.assertNotIsInstance(cm.exception, tf3ctl.CoopRefused)
            self.assertIn("started by bob, not by alice", str(cm.exception))
        self.record("alice")
        self.assertIsNone(tf3ctl.check_game_owner("quit"), "the launcher without coop: unchanged")
        self.assertIsNone(tf3ctl.check_game_owner("save", {"name": "aom-eu-1900"}))

    def test_other_clients_are_refused_as_before_during_coop(self):
        self.start()  # a person's game shared with alice
        tf3ctl.OWNER = "bob"
        with self.assertRaises(tf3ctl.OwnerRefused) as cm:
            tf3ctl.check_game_owner("build", {"res": "x"})
        self.assertNotIsInstance(cm.exception, tf3ctl.CoopRefused)
        self.assertIn("names alice", str(cm.exception))
        tf3ctl.OWNER = None
        with self.assertRaises(tf3ctl.OwnerRefused):
            tf3ctl.check_game_owner("build", {"res": "x"})
        tf3ctl.OWNER, tf3ctl.OTHER_OWNER_OK = "bob", True  # unchanged: sends anyway
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(tf3ctl.check_game_owner("quit")["launchedBy"], "none")

    def test_start_refused_on_another_owners_game_or_another_clients_coop(self):
        self.record("bob")
        tf3ctl.OTHER_OWNER_OK = True
        with self.assertRaises(tf3ctl.OwnerRefused):
            self.start("alice")
        self.assertNotIn("coop", self.rec())
        os.remove(tf3ctl.launched_path())
        self.start("alice")
        with self.assertRaises(tf3ctl.OwnerRefused) as cm:
            self.start("carol")
        self.assertIn("shared with alice", str(cm.exception))
        self.start("alice", minutes=30)  # renewing one's own goes
        self.assertEqual(self.rec()["coop"]["until"] - self.rec()["coop"]["since"], 1800)

    def test_start_checks_its_args_and_a_running_game(self):
        tf3ctl.OWNER = None
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.coop_start(60, "x")
        tf3ctl.OWNER = "alice"
        for minutes, reason in ((0, "x"), (10081, "x"), (True, "x"), (60, " "), (60, "x" * 201)):
            with self.assertRaises(tf3ctl.ToolError):
                tf3ctl.coop_start(minutes, reason)
        tf3ctl.game_pids = lambda: []
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.coop_start(60, "x")
        self.assertFalse(os.path.exists(tf3ctl.launched_path()))

    # (d)
    def test_d_the_mark_ends_with_its_time_and_with_the_game(self):
        now = time.time()
        self.start(now=now - 3601)  # until is past: the strict side (CoopExpiredTest)
        self.assertIsNone(tf3ctl.active_coop(self.rec(), [4242]))
        with self.assertRaises(tf3ctl.CoopMarkRefused) as cm:
            tf3ctl.check_game_owner("build", {"res": "x"})
        self.assertEqual(cm.exception.refused, "coop-expired")
        self.assertFalse(tf3ctl.coop_note()["coop"]["active"], "status: not active")
        self.start()
        self.assertIsNotNone(tf3ctl.active_coop(self.rec(), [4242]))
        tf3ctl.game_pids = lambda: [5555]  # the shared game is gone; another runs
        self.assertIsNone(tf3ctl.active_coop(self.rec(), [5555]))
        with self.assertRaises(tf3ctl.OwnerRefused) as cm:
            tf3ctl.check_game_owner("build", {"res": "x"})
        self.assertNotIsInstance(cm.exception, tf3ctl.CoopRefused)
        self.assertEqual(tf3ctl.coop_note(), {}, "status: not this game's")
        tf3ctl.game_pids = lambda: [4242]
        with contextlib.redirect_stderr(io.StringIO()):
            tf3ctl.remove_launched()  # what quit and launch do once the game is seen stopped
        self.assertIsNone(tf3ctl.read_launched()[0])
        # a mark of a bad shape never counts
        for coop in ({"with": "alice", "until": "tomorrow"}, {"with": [], "until": now + 99}, {"until": now + 99},
                     {"with": "alice", "until": True}):
            self.assertIsNone(tf3ctl.active_coop({"pid": 4242, "coop": coop}, [4242]), coop)
        self.assertIsNotNone(tf3ctl.active_coop({"pid": 4242, "coop": {"with": ["x", "alice"], "until": now + 99}},
                                                [4242]), "a list of clients is read")

    def test_until_is_finite_and_at_most_seven_days_ahead(self):
        self.start(minutes=10080)  # the longest: 7 days
        self.assertEqual(self.rec()["coop"]["until"] - self.rec()["coop"]["since"], 7 * 86400)
        self.assertIsNotNone(tf3ctl.active_coop(self.rec(), [4242]))
        now = time.time()
        for until in (now + 7 * 86400 + 60, float("nan"), float("inf"), 1e300):
            self.assertIsNone(tf3ctl.active_coop({"pid": 4242, "coop": {"with": "alice", "until": until}}, [4242],
                                                 now=now), until)
        # as written by another tool: JSON's NaN / Infinity never count, and are the strict side
        for text in ("NaN", "Infinity", str(int(now) + 8 * 86400)):
            write(tf3ctl.launched_path(), '{"v": 1, "pid": 4242, "coop": {"with": "alice", "until": %s}}' % text)
            with self.assertRaises(tf3ctl.CoopMarkRefused) as cm:
                tf3ctl.check_game_owner("build", {"res": "x"})
            self.assertEqual(cm.exception.refused, "coop-invalid", text)
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.coop_start(10081, "x")

    def test_owner_less_record_without_coop_does_not_count(self):
        os.makedirs(os.path.dirname(tf3ctl.launched_path()), exist_ok=True)
        write(tf3ctl.launched_path(), '{"v": 1, "pid": 4242, "started_at": 1, "cmd": "coop"}')
        self.assertIsNone(tf3ctl.read_launched()[0])
        write(tf3ctl.launched_path(), '{"v": 1, "pid": 4242, "coop": {"with": "alice", "until": 1}}')
        self.assertIsNone(tf3ctl.read_launched()[0]["owner"])

    def test_launch_coop_shares_after_the_load(self):
        tf3ctl.OWNER = "alice"
        tf3ctl.game_pids = lambda: []
        ns = tf3ctl.make_parser().parse_args(["launch", "--load", "aom-eu-1900", "--coop", "--reason", "play",
                                              "--minutes", "30"])
        seen = []

        def fake_launch(t):
            tf3ctl.game_pids = lambda: [4242]
            return {"ok": True, "menu": True}

        def fake_replace(cmd, args, dry, timeout, company_init=True):
            seen.append(tf3ctl.check_game_owner(cmd, args))  # the load goes: coop comes after it
            self.loaded("aom-eu-1900")
            return {"ok": True}
        with unittest.mock.patch.object(tf3ctl, "launch_game", fake_launch), \
                unittest.mock.patch.object(tf3ctl, "replace_game", fake_replace), \
                contextlib.redirect_stderr(io.StringIO()):
            out = tf3ctl.cmd_start(ns, restart=False)
        self.assertEqual(seen, [None])
        self.assertTrue(out["coop"]["active"])
        self.assertEqual(self.rec()["owner"], "alice")
        self.assertEqual(self.rec()["coop"]["until"] - self.rec()["coop"]["since"], 1800)
        self.refused("load", {"save": "s"})
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.cmd_start(tf3ctl.make_parser().parse_args(["launch", "--coop"]), restart=False)

    def test_launch_coop_checks_reason_before_starting(self):
        tf3ctl.OWNER = "alice"
        tf3ctl.game_pids = lambda: []
        started = []
        for argv in (["launch", "--coop", "--reason", "x" * 201], ["launch", "--coop", "--reason", "x",
                                                                   "--minutes", "10081"]):
            with unittest.mock.patch.object(tf3ctl, "launch_game", lambda t: started.append(1)), \
                    self.assertRaises(tf3ctl.ToolError):
                tf3ctl.cmd_start(tf3ctl.make_parser().parse_args(argv), restart=False)
        self.assertEqual(started, [], "nothing started")

    def test_changes_are_remembered_after_coop_end_on_the_same_game(self):
        self.loaded("aom-eu-1900")
        self.start()
        self.sent("build", {"res": "x"})
        tf3ctl.coop_end()
        self.assertEqual(self.rec()["coopChanges"], 1)
        self.assertNotIn("coop", self.rec())
        self.start()
        self.assertEqual((self.rec()["coop"]["modified"], self.rec()["coop"]["changes"]), (True, 1))
        self.assertNotIn("coopChanges", self.rec())
        self.assertIn("(1 times)", tf3ctl.coop_note()["coop"]["text"])

    def test_coop_end_without_a_mark(self):
        self.assertTrue(tf3ctl.coop_end()["ok"])
        self.record("alice")
        self.assertIn("note", tf3ctl.coop_end())
        self.assertEqual(self.rec()["owner"], "alice")


class CoopExpiredTest(unittest.TestCase):
    """An expired or malformed coop mark on the running game is the strict side (D-20261123-26, like the guard
    outside): the launcher and the client send no game-changing command until coop start or coop end; reading
    commands go; the mark is never removed for its time."""

    # CoopTest's fixture and helpers, not its tests
    setUp, tearDown, loaded, record, start, rec, goes, sent = (
        CoopTest.setUp, CoopTest.tearDown, CoopTest.loaded, CoopTest.record, CoopTest.start, CoopTest.rec,
        CoopTest.goes, CoopTest.sent)

    def mark_refused(self, cmd, args=None, refused="coop-expired"):
        before = sorted(os.listdir(self.x))
        with self.assertRaises(tf3ctl.CoopMarkRefused) as cm:
            tf3ctl.send(cmd, args, timeout=0.1, folder=self.x)
        self.assertEqual(cm.exception.refused, refused)
        self.assertEqual(sorted(os.listdir(self.x)), before, "nothing written for the game")
        self.assertNotIn("remote_probe__cmd", " ".join(before))
        return str(cm.exception)

    def main(self, argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = tf3ctl.main(argv)
        return code, out.getvalue()

    def expire(self):
        rec = self.rec()
        rec["coop"]["until"] = int(time.time()) - 120
        write(tf3ctl.launched_path(), json.dumps(rec))

    def test_expired_on_the_launchers_game(self):
        self.record("alice")
        self.start()
        self.loaded("aom-eu-1900")
        self.sent("build", {"res": "x"})  # a change on a person's save: counted
        self.expire()
        before = self.rec()
        msg = self.mark_refused("build", {"res": "x"})
        self.assertIn("expired at %s" % tf3ctl._clock(before["coop"]["until"]), msg)
        self.assertIn("extend it with coop start", msg)
        self.assertIn("coop end", msg)
        self.mark_refused("camera", {"x": 1, "y": 2})  # camera --set changes the game
        self.mark_refused("quit")
        self.mark_refused("save", {"name": "probe-x"})
        tf3ctl.OTHER_OWNER_OK = True
        self.mark_refused("build", {"res": "x"})  # --other-owner-ok does not send it either
        tf3ctl.OTHER_OWNER_OK = False
        # reading commands go
        self.assertIsNone(tf3ctl.check_game_owner("status"))
        self.assertIsNone(tf3ctl.check_game_owner("camera", {}))
        self.assertIsNone(tf3ctl.check_game_owner("build", {"res": "x", "dryRun": True}))
        # status says so, in both languages
        note = tf3ctl.coop_note()["coop"]
        self.assertTrue(note["expired"])
        self.assertFalse(note["active"])
        self.assertIn("expired at", note["text"])
        self.assertIn("期限", note["textJa"])
        self.assertIn("coop start", note["textJa"])
        # the mark stays as it was: nothing removes or rewrites it for its time
        self.assertEqual(self.rec(), before)
        # through main: exit 4, "refused": "coop-expired"
        code, out = self.main(["--owner", "alice", "build", "--res", "x.con", "--at", "1,2"])
        self.assertEqual(code, 4)
        self.assertEqual(json.loads(out)["refused"], "coop-expired")
        self.assertEqual(self.rec(), before)
        # coop start extends it, with the change count kept
        self.start()
        self.assertEqual((self.rec()["coop"]["modified"], self.rec()["coop"]["changes"]), (True, 1))
        self.goes("build", {"res": "x"})
        # coop end: the launcher's game is its own again
        self.expire()
        self.mark_refused("build", {"res": "x"})
        tf3ctl.coop_end()
        self.assertNotIn("coop", self.rec())
        self.assertIsNone(tf3ctl.check_game_owner("build", {"res": "x"}))
        self.assertIsNone(tf3ctl.check_game_owner("quit"))

    def test_expired_on_a_persons_game(self):
        self.start()  # no record: a game a person started
        self.expire()
        self.assertIsNone(self.rec().get("owner"))
        self.mark_refused("build", {"res": "x"})
        tf3ctl.OTHER_OWNER_OK = True
        self.mark_refused("build", {"res": "x"})
        tf3ctl.OTHER_OWNER_OK = False
        # other clients: as before (the owner check, --other-owner-ok sends)
        tf3ctl.OWNER = "bob"
        with self.assertRaises(tf3ctl.OwnerRefused) as cm:
            tf3ctl.check_game_owner("build", {"res": "x"})
        self.assertNotIsInstance(cm.exception, tf3ctl.CoopMarkRefused)
        tf3ctl.OTHER_OWNER_OK = True
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertIn("launchedBy", tf3ctl.check_game_owner("build", {"res": "x"}))
        tf3ctl.OTHER_OWNER_OK = False
        tf3ctl.OWNER = None
        with self.assertRaises(tf3ctl.OwnerRefused) as cm:
            tf3ctl.check_game_owner("build", {"res": "x"})
        self.assertNotIsInstance(cm.exception, tf3ctl.CoopMarkRefused)
        # coop end as anybody, then the person's game refuses as before
        tf3ctl.OWNER = "alice"
        tf3ctl.coop_end()
        with self.assertRaises(tf3ctl.OwnerRefused) as cm:
            tf3ctl.check_game_owner("build", {"res": "x"})
        self.assertNotIsInstance(cm.exception, tf3ctl.CoopMarkRefused)

    def test_the_mark_of_a_game_that_ended_is_no_mark(self):
        self.record("alice")
        self.start()
        self.expire()
        tf3ctl.game_pids = lambda: [5555]  # another game runs
        with self.assertRaises(tf3ctl.OwnerRefused) as cm:
            tf3ctl.check_game_owner("build", {"res": "x"})
        self.assertNotIsInstance(cm.exception, tf3ctl.CoopMarkRefused)
        self.assertEqual(tf3ctl.coop_note(), {})
        self.assertEqual(tf3ctl.coop_mark(self.rec(), [5555]), (None, None))
        # malformed, too
        write(tf3ctl.launched_path(), '{"v": 1, "owner": "alice", "pid": 4242, "coop": {"until": NaN}}')
        with self.assertRaises(tf3ctl.OwnerRefused) as cm:
            tf3ctl.check_game_owner("build", {"res": "x"})
        self.assertNotIsInstance(cm.exception, tf3ctl.CoopMarkRefused)

    def test_malformed_marks(self):
        self.record("alice")
        now = int(time.time())
        good = {"with": "alice", "reason": "r", "since": now, "until": now + 600}
        for bad in ({"until": now + 600}, dict(good, **{"with": ""}), dict(good, **{"with": []}),
                    dict(good, until="tomorrow"), dict(good, until=True), dict(good, until=None),
                    dict(good, until=now + 8 * 86400), "x", [1], None):
            rec = dict(self.rec(), coop=bad)
            write(tf3ctl.launched_path(), json.dumps(rec))
            self.assertEqual(tf3ctl.coop_mark(rec, [4242])[0], "invalid", bad)
            msg = self.mark_refused("build", {"res": "x"}, refused="coop-invalid")
            self.assertIn("malformed", msg)
            self.assertIn("coop end", msg)
            self.assertIn("coop start", msg)
            self.assertIsNone(tf3ctl.check_game_owner("status"))
            note = tf3ctl.coop_note()["coop"]
            self.assertTrue(note["invalid"], bad)
            self.assertIn("壊れて", note["textJa"])
            self.assertEqual(self.rec(), rec, "the mark is not rewritten")
        for text in ("NaN", "Infinity", "-Infinity"):
            write(tf3ctl.launched_path(), '{"v": 1, "owner": "alice", "pid": 4242, "coop": {"with": "alice", '
                  '"until": %s}}' % text)
            self.mark_refused("build", {"res": "x"}, refused="coop-invalid")
        # a person's game (no owner) with a malformed until: its client is refused too
        write(tf3ctl.launched_path(), json.dumps({"v": 1, "pid": 4242, "coop": dict(good, until=float("inf"))})
              .replace("Infinity", "1e999"))
        self.mark_refused("build", {"res": "x"}, refused="coop-invalid")
        code, out = self.main(["--owner", "alice", "pause"])
        self.assertEqual(code, 4)
        self.assertEqual(json.loads(out)["refused"], "coop-invalid")
        # coop start writes it anew; coop end removes even a mark that is not an object
        self.start()
        self.goes("build", {"res": "x"})
        write(tf3ctl.launched_path(), json.dumps(dict(self.rec(), owner="alice", coop="x")))
        self.mark_refused("build", {"res": "x"}, refused="coop-invalid")
        self.start()
        self.assertEqual(self.rec()["coop"]["with"], "alice")
        write(tf3ctl.launched_path(), json.dumps(dict(self.rec(), coop="x")))
        tf3ctl.coop_end()
        self.assertNotIn("coop", self.rec())
        self.assertIsNone(tf3ctl.check_game_owner("build", {"res": "x"}))

    def test_malformed_mark_on_a_persons_game_refuses_every_client(self):
        """A person's game (no owner) whose mark names no client: whose coop it is is not known, so no client
        changes it, not even with --other-owner-ok; coop end removes it, coop start writes it anew."""
        now = int(time.time())
        os.makedirs(os.path.dirname(tf3ctl.launched_path()), exist_ok=True)
        for coop in ('"x"', "null", "[1]", '{"until": %d}' % (now + 600), '{"with": "", "until": %d}' % (now + 600)):
            write(tf3ctl.launched_path(), '{"v": 1, "pid": 4242, "cmd": "coop", "coop": %s}' % coop)
            for owner, ok in (("alice", False), ("alice", True), ("bob", True)):
                tf3ctl.OWNER, tf3ctl.OTHER_OWNER_OK = owner, ok
                self.mark_refused("build", {"res": "x"}, refused="coop-invalid")
            tf3ctl.OTHER_OWNER_OK = False
            self.assertTrue(tf3ctl.coop_note()["coop"]["invalid"], coop)
            json.dumps(tf3ctl.coop_note(), allow_nan=False)  # strict JSON out
            tf3ctl.coop_end()
            self.assertNotIn("coop", self.rec(), coop)
            with self.assertRaises(tf3ctl.OwnerRefused) as cm:  # a person's game, as before
                tf3ctl.check_game_owner("build", {"res": "x"})
            self.assertNotIsInstance(cm.exception, tf3ctl.CoopMarkRefused)
        write(tf3ctl.launched_path(), '{"v": 1, "pid": 4242, "cmd": "coop", "coop": "x"}')
        self.start()
        self.goes("build", {"res": "x"})
        # NaN written by another tool is not passed on to status's JSON
        write(tf3ctl.launched_path(), '{"v": 1, "pid": 4242, "coop": {"with": "alice", "since": NaN, '
              '"reason": NaN, "until": NaN}}')
        json.dumps(tf3ctl.coop_note(), allow_nan=False)

    def test_other_clients_hear_that_the_user_may_still_be_playing(self):
        self.start()  # a person's game
        self.expire()
        tf3ctl.OWNER = "bob"
        with self.assertRaises(tf3ctl.OwnerRefused) as cm:
            tf3ctl.check_game_owner("build", {"res": "x"})
        self.assertIn("is expired, so the user may still be playing", str(cm.exception))

    def test_quit_kill_and_restart_stop_before_the_game(self):
        self.record("alice")
        self.start()
        self.expire()
        killed = []
        with unittest.mock.patch.object(tf3ctl.os, "kill", lambda *a: killed.append(a)):
            with self.assertRaises(tf3ctl.CoopMarkRefused):
                tf3ctl.quit_game(timeout=0.1, kill=True, force=True)
        self.assertEqual(killed, [], "no SIGKILL")
        self.assertIn("coop", self.rec(), "the record stays")
        code, out = self.main(["--owner", "alice", "restart", "--no-kill"])
        self.assertEqual(code, 4)
        self.assertEqual(json.loads(out)["refused"], "coop-expired")
        self.assertEqual(killed, [])

    def test_no_change_counted_while_expired(self):
        self.record("alice")
        self.start()
        self.loaded("aom-eu-1900")
        self.expire()
        with self.assertRaises(tf3ctl.CoopMarkRefused):
            self.sent("build", {"res": "x"})
        self.assertNotIn("changes", self.rec()["coop"])


class NoAbbrevTest(unittest.TestCase):
    """Only whole option names: the game guard outside reads the flags as typed, so --eng must not mean --engine-check."""

    def refused(self, argv):
        err = io.StringIO()
        with contextlib.redirect_stderr(err), self.assertRaises(SystemExit) as cm:
            tf3ctl.make_parser().parse_args(argv)
        self.assertEqual(cm.exception.code, 2, argv)
        return err.getvalue()

    def test_every_parser_is_strict(self):
        seen = []

        def walk(pr, path):
            seen.append(path)
            self.assertFalse(pr.allow_abbrev, path)
            for a in pr._actions:
                if isinstance(a, tf3ctl.argparse._SubParsersAction):
                    for name, sp in a.choices.items():
                        walk(sp, path + [name])
        walk(tf3ctl.make_parser(), [])
        for nested in (["town", "develop"], ["modhub", "publish"], ["line", "create"], ["stock", "set"]):
            self.assertIn(nested, seen, "the nested parsers are walked too")

    def test_abbreviations_are_refused(self):
        for argv, short in ((["road", "--from", "0,0", "--to", "1,1", "--dry-run", "--eng"], "--eng"),
                            (["camera", "--se", "1,2"], "--se"),
                            (["--own", "me", "status"], "--own"),
                            (["--other", "speed", "1"], "--other"),
                            (["town", "develop", "--at", "1,2", "--stre"], "--stre"),
                            (["modhub", "publish", "f", "--public", "yes", "--changelog", "c", "--first"], "--first"),
                            (["line", "create", "--stops", "1,2", "--force-un", "1"], "--force-un"),
                            (["stock", "set", "--ent", "1", "--stock", "0", "--amount", "5"], "--ent")):
            with self.subTest(argv=argv):
                self.assertIn(short, self.refused(argv), argv)

    def test_whole_names_still_parse(self):
        p = tf3ctl.make_parser()
        self.assertTrue(p.parse_args(["road", "--from", "0,0", "--to", "1,1", "--dry-run", "--engine-check"]).engine_check)
        self.assertEqual(p.parse_args(["camera", "--set", "1,2"]).set, "1,2")
        self.assertEqual(p.parse_args(["camera", "--set=1,2"]).set, "1,2", "--name=value stays")
        self.assertEqual(p.parse_args(["--owner", "me", "status"]).owner, "me")
        ns = p.parse_args(["town", "develop", "--at", "1,2", "--streets"])
        self.assertEqual((ns.town_action, ns.grow_streets), ("develop", True))
        ns = p.parse_args(["modhub", "publish", "f", "--public", "yes", "--changelog", "c", "--first-upload"])
        self.assertEqual((ns.action, ns.folder, ns.first_upload), ("publish", "f", True))
        self.assertTrue(p.parse_args(["--other-owner-ok", "speed", "1"]).other_owner_ok)
        ns = p.parse_args(["line", "create", "--stops", "1,2", "--force-unload", "1"])
        self.assertEqual((ns.action, ns.force_unload), ("create", "1"))
        self.assertEqual(p.parse_args(["stock", "set", "--entity", "1", "--stock", "0", "--amount", "5"]).entity, 1)

class _ForceBase(unittest.TestCase):
    """A running test save (pid 4242) launched by alice, with the mod faked (IgnoreErrorsTest, ForcedSaveTest)."""

    def setUp(self):
        self.saved = {k: getattr(tf3ctl, k) for k in ("game_pids", "OWNER", "OTHER_OWNER_OK", "USER_ASKED",
                                                       "exchange_dir")}
        self.saved_env = {k: os.environ.get(k) for k in ("XDG_RUNTIME_DIR", "TF3_LOG")}
        self.run_dir = tempfile.mkdtemp()
        os.environ["XDG_RUNTIME_DIR"] = self.run_dir
        self.x = tempfile.mkdtemp()
        self.log = os.path.join(self.x, "stdout.txt")
        os.environ["TF3_LOG"] = self.log
        tf3ctl.exchange_dir = lambda: self.x
        tf3ctl.game_pids = lambda: [4242]
        tf3ctl.OWNER, tf3ctl.OTHER_OWNER_OK, tf3ctl.USER_ASKED = "alice", False, False
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertTrue(tf3ctl.write_launched(4242, owner="alice")["written"])
        self.loaded("probe-flat-base")
        self.p = tf3ctl.make_parser()

    def tearDown(self):
        for k, v in self.saved.items():
            setattr(tf3ctl, k, v)
        for k, v in self.saved_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(self.run_dir, ignore_errors=True)
        shutil.rmtree(self.x, ignore_errors=True)

    def loaded(self, save):
        lines = ["[2026-11-23 11:00:00Z - MESSAGE - Main Thread - Main ]  Application startup",
                 "[2026-11-23 11:00:30Z - MESSAGE - Main Thread - Main ]  Main menu is ready"]
        if save == "":
            lines.append("[2026-11-23 11:01:00Z - MESSAGE - Main Thread - Main ]  Start new game...")
        elif save is not None:
            lines.append("[2026-11-23 11:01:00Z - MESSAGE - Load Game Pool 1 - Main ]  Loading game from file " + save)
        lines.append("[2026-11-23 11:01:20Z - MESSAGE - Main Thread - Main ]  Game is ready")
        write(self.log, "\n".join(lines) + "\n")

    def road(self, *a):
        return tf3ctl.road_args(self.p.parse_args(["road", "--from", "0,0", "--to", "10,0"] + list(a)))

    def sent(self, cmd, args):
        """Through send with the mod faked: the args written for the mod."""
        got = []
        with unittest.mock.patch.object(tf3ctl, "write_command", lambda f, cid, c, a: got.append((c, a))), \
                unittest.mock.patch.object(tf3ctl, "cleanup", lambda f: None), \
                unittest.mock.patch.object(tf3ctl, "note_activity", lambda *a: None), \
                unittest.mock.patch.object(tf3ctl, "wait_pickup", lambda f, c: None), \
                unittest.mock.patch.object(tf3ctl, "wait_answer", lambda *a: {"ok": True}), \
                contextlib.redirect_stderr(io.StringIO()):
            tf3ctl.send(cmd, args, folder=self.x)
        self.assertEqual(len(got), 1)
        return got[0][1]

    def refused(self, cmd, args, why):
        written = []
        with unittest.mock.patch.object(tf3ctl, "write_command", lambda *a: written.append(a)):
            with self.assertRaises(tf3ctl.OwnerRefused) as cm:
                tf3ctl.send(cmd, args, timeout=0.1, folder=self.x)
        self.assertEqual(written, [], "nothing written for the game")
        # (the command lock an earlier send left is no command)
        self.assertEqual([f for f in os.listdir(self.x) if f not in ("stdout.txt", tf3ctl.PREFIX + "lock")], [])
        self.assertIn(why, str(cm.exception))
        return cm.exception



class IgnoreErrorsTest(_ForceBase):
    """road --ignore-errors (2026-11-24): the build sent with the engine's ignoreErrors on, for test saves only;
    refused (nothing sent) on a person's save, a new game with no name, an unknown save, during coop, and on any
    command but road."""

    def test_args_and_help(self):
        self.assertNotIn("ignoreErrors", self.road(), "off unless asked: as before")
        self.assertNotIn("engineCheck", self.road())
        r = self.road("--ignore-errors")
        self.assertIs(r["ignoreErrors"], True)
        self.assertNotIn("engineCheck", r, "a build: the engine checks it as it builds")
        r = self.road("--ignore-errors", "--dry-run")
        self.assertEqual((r["ignoreErrors"], r["dryRun"], r["engineCheck"]), (True, True, True),
                         "a forced dry run asks the engine")
        self.assertTrue(tf3ctl.changes_game("road", r), "asking the engine counts as changing the game")
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.road_inspect_args(self.p.parse_args(["road", "--inspect-node", "5", "--ignore-errors"]))
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            self.p.parse_args(["build", "--res", "x.con", "--at", "1,2", "--ignore-errors"])
        self.assertNotIn("ignoreErrors", tf3ctl.build_args(self.p.parse_args(["build", "--res", "x.con", "--at", "1,2"])))
        helptext = " ".join(self.p._subparsers._group_actions[0].choices["road"].format_help().split())
        self.assertIn("for test saves only: skips the engine's checks", helptext)

    def test_a_test_save_sends_it_with_the_save_named(self):
        for save in ("probe-flat-base", "aom-ops-ship", "3-probe", "aom-shot-x"):
            self.loaded(save)
            a = self.sent("road", self.road("--ignore-errors"))
            self.assertIs(a["ignoreErrors"], True, save)
            self.assertEqual(a["_testSave"], save)
        # without it: nothing of it goes, and a _testSave given by hand is dropped
        a = self.sent("road", dict(self.road(), _testSave="probe-x"))
        self.assertNotIn("ignoreErrors", a)
        self.assertNotIn("_testSave", a)
        a = self.sent("build", {"res": "x.con", "at": [1, 2], "_testSave": "probe-x"})
        self.assertNotIn("_testSave", a)

    def test_refused_on_a_persons_save_a_new_game_or_an_unknown_one(self):
        self.loaded("aom-eu-1900")
        e = self.refused("road", self.road("--ignore-errors"), "'aom-eu-1900' is not a test save's")
        self.assertEqual(e.refused, "ignore-errors")
        self.assertIn("for test saves only: skips the engine's checks", str(e))
        self.loaded("12-probe")
        self.refused("road", self.road("--ignore-errors"), "is not a test save's")
        self.loaded("")
        self.refused("road", self.road("--ignore-errors"), "save probe-NAME), then load that")
        self.refused("road", self.road("--ignore-errors", "--dry-run"), "a new game with no save name")
        self.loaded(None)
        self.refused("road", self.road("--ignore-errors"), "is not known")
        os.remove(self.log)
        self.refused("road", self.road("--ignore-errors"), "is not known")
        # the same road without it goes, on a person's save too (as before)
        self.loaded("aom-eu-1900")
        self.assertNotIn("ignoreErrors", self.sent("road", self.road()))

    def test_refused_during_coop_even_on_a_test_save(self):
        tf3ctl.coop_start(60, "look at the junction together")
        self.refused("road", self.road("--ignore-errors"), "coop mark")
        self.refused("road", self.road("--ignore-errors", "--dry-run"), "coop mark")
        self.assertNotIn("ignoreErrors", self.sent("road", self.road()), "an unforced road goes in coop, as before")
        # an expired mark: still refused
        rec = json.loads(read(tf3ctl.launched_path()))
        rec["coop"]["until"] = time.time() - 10
        write(tf3ctl.launched_path(), json.dumps(rec))
        with self.assertRaises(tf3ctl.OwnerRefused):
            tf3ctl.send("road", self.road("--ignore-errors"), timeout=0.1, folder=self.x)
        # a person's game in coop with another client, --other-owner-ok: still refused
        tf3ctl.OWNER, tf3ctl.OTHER_OWNER_OK = "bob", True
        with self.assertRaises(tf3ctl.OwnerRefused):
            tf3ctl.send("road", self.road("--ignore-errors"), timeout=0.1, folder=self.x)

    def test_other_commands_never_carry_it(self):
        for cmd in ("build", "connect", "terrain", "town", "line"):
            self.refused(cmd, {"ignoreErrors": True, "res": "x"}, "road only")
            self.refused(cmd, {"ignoreErrors": False}, "road only")
        self.refused("road", dict(self.road(), ignoreErrors=1), "must be true")


class RoadBatchTest(_ForceBase):
    """road --batch FILE (2026-11-24): several pieces in one proposal, from a JSON list; each piece checked as road's
    flags are, the whole proposal's options beside them; nothing sent when the file does not read or a piece is bad.
    It goes as the command road, so road's fences (--ignore-errors on test saves only and not in coop, the force
    mark, changes_game) are the same."""

    def setUp(self):
        super().setUp()
        # (the pieces' file beside the exchange folder, which refused checks for leftovers)
        self.files = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.files, ignore_errors=True)

    def batch(self, pieces, *a, raw=None):
        path = os.path.join(self.files, "pieces.json")
        write(path, raw if raw is not None else json.dumps(pieces))
        return tf3ctl.road_batch_args(self.p.parse_args(["road", "--batch", path] + list(a)))

    def bad(self, why, pieces=None, *a, raw=None):
        with self.assertRaises(tf3ctl.ToolError) as cm:
            self.batch(pieces, *a, raw=raw)
        self.assertIn(why, str(cm.exception))
        return cm.exception

    TWO = [{"from-node": 8001, "to": "300,-12", "type": "town_new_medium", "tangent-from": [1, 0]},
           {"from": [100, 0, 2], "to": "300,12", "to-node": "@a", "snap": 0, "align-to-edge": "from", "align-edge": 8100},
           {"fromNode": "@a", "to": "400,12", "tangentTo": "1,0"}]

    def test_pieces_by_road_flags_names_and_the_mods(self):
        a = self.batch(self.TWO)
        self.assertEqual(set(a), {"batch"}, "nothing else unless asked")
        b = a["batch"]
        self.assertEqual(b[0], {"fromNode": 8001, "to": [300.0, -12.0], "type": "town_new_medium", "tangentFrom": [1.0, 0.0]})
        self.assertEqual(b[1], {"from": [100.0, 0.0, 2.0], "to": [300.0, 12.0], "toNode": "@a", "snap": 0.0,
                                "alignToEdge": "from", "alignEdge": [8100]})
        self.assertEqual(b[2], {"fromNode": "@a", "to": [400.0, 12.0], "tangentTo": [1.0, 0.0]})
        # the whole proposal's options, as road's
        a = self.batch(self.TWO, "--dry-run", "--engine-check", "--remove-fields", "--remove-buildings")
        self.assertEqual((a["dryRun"], a["engineCheck"], a["removeFields"], a["removeBuildings"]), (True, True, True, True))
        self.assertTrue(tf3ctl.changes_game("road", a), "the engine asked: changes the game, as road's")
        self.assertFalse(tf3ctl.changes_game("road", self.batch(self.TWO, "--dry-run")))
        self.assertTrue(tf3ctl.changes_game("road", self.batch(self.TWO)))
        a = self.batch(self.TWO, "--ignore-errors", "--dry-run")
        self.assertEqual((a["ignoreErrors"], a["engineCheck"]), (True, True), "a forced dry run asks the engine")
        # what the mod is written: a Lua list of pieces
        self.assertIn('["tangentFrom"] = { 1.0, 0.0 }, ["fromNode"] = 8001 }', tf3ctl.to_lua(self.batch(self.TWO)))
        self.assertIn("--batch", " ".join(self.p._subparsers._group_actions[0].choices["road"].format_help().split()))

    def test_bad_files_and_pieces_send_nothing(self):
        self.bad("not JSON", raw="[{\"from\": ")
        self.bad("not JSON", raw="")
        self.bad("'from' written twice in one object", raw='[{"from": "0,0", "from": "5,0", "to": "1,0"}]')
        with self.assertRaises(tf3ctl.ToolError) as cm:
            tf3ctl.road_batch_args(self.p.parse_args(["road", "--batch", os.path.join(self.files, "none.json")]))
        self.assertIn("cannot read it", str(cm.exception))
        self.bad("a JSON list of pieces", {"from": "0,0", "to": "1,0"})
        self.bad("the list is empty", [])
        many = [{"from": [i * 20, 0], "to": [i * 20, 50]} for i in range(17)]
        self.bad("17 pieces, at most 16", many)
        self.assertEqual(len(self.batch(many[:16])["batch"]), 16)
        for why, pieces in (
                ("piece 2: not a JSON object", [{"from": "0,0", "to": "1,0"}, 5]),
                ("piece 1: unknown key 'tangent_from'", [{"from": "0,0", "to": "1,0", "tangent_from": "1,0"}]),
                ("unknown key 'dry-run'", [{"from": "0,0", "to": "1,0", "dry-run": True}]),
                ("tangentFrom given twice", [{"from": "0,0", "to": "1,0", "tangent-from": "1,0", "tangentFrom": "1,0"}]),
                ("piece 1: road needs --from and --to", [{"from": "0,0"}]),
                ("piece 1: --to must be", [{"from": "0,0", "to": "1"}]),
                ("piece 1: --from must be numbers", [{"from": "a,0", "to": "1,0"}]),
                ("from must be", [{"from": True, "to": "1,0"}]),
                ("snap must be 0-20", [{"from": "0,0", "to": "1,0", "snap": 30}]),
                ("snap must be a number", [{"from": "0,0", "to": "1,0", "snap": "5"}]),
                ("align-edge must be", [{"from": "0,0", "to": "1,0", "align-to-edge": "from", "align-edge": "x"}]),
                ("align-to-edge must be from, to or both", [{"from": "0,0", "to": "1,0", "align-to-edge": "x"}]),
                ("--align-edge goes with --align-to-edge only", [{"from": "0,0", "to": "1,0", "align-edge": 5}]),
                ("from-node must be a node's entity id", [{"from-node": -1, "to": "1,0"}]),
                ("from-node must be a node's entity id", [{"from-node": 1.5, "to": "1,0"}]),
                ("a new node's name is @", [{"from-node": "a", "to": "1,0"}]),
                ("a new node's name is @", [{"from-node": "@" + "x" * 33, "to": "1,0"}]),
                ("give from or from-node 8001", [{"from": "0,0", "from-node": 8001, "to": "1,0"}]),
                ("type must be a string", [{"from": "0,0", "to": "1,0", "type": 5}]),
        ):
            self.bad(why, pieces)
        # road's own flags beside --batch: in the file instead
        for flag in (["--from", "0,0"], ["--type", "x"], ["--snap", "1"], ["--tangent-from", "1,0"], ["--bridge", "concrete"]):
            path = os.path.join(self.files, "pieces.json")
            write(path, json.dumps(self.TWO))
            with self.assertRaises(tf3ctl.ToolError) as cm:
                tf3ctl.road_batch_args(self.p.parse_args(["road", "--batch", path] + flag))
            self.assertIn("goes in each piece there", str(cm.exception))
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.road_inspect_args(self.p.parse_args(["road", "--inspect-node", "5", "--batch", "x.json"]))
        with self.assertRaises(tf3ctl.ToolError):
            self.batch(self.TWO, "--engine-check")  # without --dry-run, as road

    def test_collision_detail_for_the_whole_batch(self):
        """--collision-detail beside --batch: for the one proposal, with road's fence (a build, or --dry-run
        --engine-check; not a plain dry run); not a piece's key in the file."""
        self.assertEqual(self.batch(self.TWO, "--collision-detail")["collisionDetail"], True)
        a = self.batch(self.TWO, "--dry-run", "--engine-check", "--collision-detail")
        self.assertEqual((a["dryRun"], a["engineCheck"], a["collisionDetail"]), (True, True, True))
        a = self.batch(self.TWO, "--ignore-errors", "--dry-run", "--collision-detail")
        self.assertEqual((a["engineCheck"], a["collisionDetail"]), (True, True), "a forced dry run asks the engine")
        self.assertNotIn("collisionDetail", self.batch(self.TWO), "absent unless given")
        self.bad("--collision-detail goes with a build or with --dry-run --engine-check", self.TWO, "--dry-run",
                 "--collision-detail")
        self.bad("unknown key 'collision-detail'", [dict(self.TWO[0], **{"collision-detail": True})])
        self.bad("unknown key 'collisionDetail'", [dict(self.TWO[0], collisionDetail=True)])

    def test_main_sends_nothing_for_a_bad_file(self):
        path = os.path.join(self.files, "pieces.json")
        write(path, "[]")
        written = []
        with unittest.mock.patch.object(tf3ctl, "write_command", lambda *a: written.append(a)), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            code = tf3ctl.main(["road", "--batch", path])
        self.assertNotEqual(code, 0)
        self.assertEqual(written, [], "nothing written for the game")

    def test_one_bad_piece_of_three_sends_none(self):
        # piece 2 of three fails tf3ctl's check: nothing written for the game, the piece named
        pieces = [dict(self.TWO[0]), {"from": "0,900", "to": "100,900", "snap": 99}, dict(self.TWO[2])]
        path = os.path.join(self.files, "pieces.json")
        write(path, json.dumps(pieces))
        written, err = [], io.StringIO()
        with unittest.mock.patch.object(tf3ctl, "write_command", lambda *a: written.append(a)), \
                contextlib.redirect_stdout(err), contextlib.redirect_stderr(err):
            code = tf3ctl.main(["--owner", "alice", "road", "--batch", path])
        self.assertNotEqual(code, 0)
        self.assertEqual(written, [], "nothing written for the game")
        self.assertIn("--batch piece 2: --snap must be 0-20", err.getvalue())
        # forced on a person's save or in coop: the batch as a whole refused, nothing written (fences above)
        self.loaded("aom-eu-1900")
        self.refused("road", self.batch(self.TWO, "--ignore-errors"), "is not a test save's")

    def test_fences_as_roads(self):
        # a test save: sent with the save named; the force mark counts a forced batch as one forced build
        a = self.sent("road", self.batch(self.TWO, "--ignore-errors"))
        self.assertEqual((a["ignoreErrors"], a["_testSave"]), (True, "probe-flat-base"))
        self.assertEqual(len(a["batch"]), 3)
        rec = json.loads(read(tf3ctl.launched_path()))
        self.assertEqual((rec["forced"], rec["forcedCount"]), (True, 1))
        self.refused("save", {"name": "aom-shot-x"}, "probe-force-* names")
        # a person's save, a new game: refused, nothing sent
        self.loaded("aom-eu-1900")
        e = self.refused("road", self.batch(self.TWO, "--ignore-errors"), "'aom-eu-1900' is not a test save's")
        self.assertEqual(e.refused, "ignore-errors")
        self.refused("road", self.batch(self.TWO, "--ignore-errors", "--dry-run"), "is not a test save's")
        self.assertNotIn("ignoreErrors", self.sent("road", self.batch(self.TWO)), "unforced it goes, as road")
        self.loaded("")
        self.refused("road", self.batch(self.TWO, "--ignore-errors"), "a new game with no save name")
        # coop: refused forced, unforced it goes (road is among the coop client's commands)
        self.loaded("probe-flat-base")
        tf3ctl.coop_start(60, "two roads with the user")
        self.refused("road", self.batch(self.TWO, "--ignore-errors"), "coop mark")
        self.assertNotIn("ignoreErrors", self.sent("road", self.batch(self.TWO)))
        # a _testSave written into the file's pieces or beside them by hand is not tf3ctl's word: dropped
        a = self.sent("road", dict(self.batch(self.TWO), _testSave="probe-x"))
        self.assertNotIn("_testSave", a)


class ForcedSaveTest(_ForceBase):
    """After road --ignore-errors went to this run of the game (a build, not --dry-run), save goes to probe-force-*
    names only (2026-11-24): a state built past the engine's checks must not land in a test base or a person's
    save. The mark lives in the launch record, so the next launch has none."""

    OTHER_NAMES = ("probe-flat-base-x", "aom-shot-x", "aom-bgm-check-x", "3-probe", "aom-eu-1900-2", "My Railway",
                   "probe-force-", "probe-force-/x", " probe-force-a", "probe-forced-a", "probe-force")

    def record(self):
        return json.loads(read(tf3ctl.launched_path()))

    def save_refused(self, name):
        e = self.refused("save", {"name": name}, "probe-force-* names")
        self.assertEqual(e.refused, "forced-save")
        self.assertIsInstance(e, tf3ctl.ForcedSaveRefused)
        return e

    def test_unforced_saves_go_as_before(self):
        for name in self.OTHER_NAMES[:6] + ("probe-force-a",):
            self.assertEqual(self.sent("save", {"name": name})["name"], name)
        self.sent("road", self.road())  # an unforced build
        self.sent("road", self.road("--ignore-errors", "--dry-run"))  # a forced dry run builds nothing
        self.assertNotIn("forced", self.record())
        self.assertNotIn("forcedCount", self.record())
        for name in ("aom-shot-x", "3-probe", "probe-flat-base-x"):
            self.assertEqual(self.sent("save", {"name": name})["name"], name, "a dry run does not count")
        self.assertEqual(tf3ctl.forced_note(), {})

    def test_after_a_forced_build_only_probe_force_names(self):
        before = self.record()
        self.assertIs(self.sent("road", self.road("--ignore-errors"))["ignoreErrors"], True)
        rec = self.record()
        self.assertEqual((rec["forced"], rec["forcedCount"]), (True, 1))
        self.assertEqual({k: v for k, v in rec.items() if k not in ("forced", "forcedCount")}, before,
                         "the record's other keys stay as they were (the guard outside reads them)")
        self.assertEqual(self.sent("save", {"name": "probe-force-a"})["name"], "probe-force-a")
        for name in self.OTHER_NAMES:
            e = self.save_refused(name)
            self.assertIn("road --ignore-errors, 1 time)", str(e))
        # neither --other-owner-ok nor --user-asked widens it
        tf3ctl.OTHER_OWNER_OK, tf3ctl.USER_ASKED = True, True
        self.save_refused("aom-shot-x")
        tf3ctl.OWNER = "bob"  # another owner's client on this game, with --other-owner-ok
        self.save_refused("probe-flat-base-x")
        self.assertEqual(self.sent("save", {"name": "probe-force-b"})["name"], "probe-force-b")
        tf3ctl.OWNER, tf3ctl.OTHER_OWNER_OK, tf3ctl.USER_ASKED = "alice", False, False
        # a second forced build counts; a forced dry run does not
        self.sent("road", self.road("--ignore-errors"))
        self.sent("road", self.road("--ignore-errors", "--dry-run"))
        self.assertEqual(self.record()["forcedCount"], 2)
        note = tf3ctl.forced_note()["forced"]
        self.assertEqual((note["count"], note["savePrefix"]), (2, "probe-force-"))
        self.assertIn("2 times", note["text"])
        self.assertIn("probe-force-*", note["textJa"])
        self.assertIn("2 回", note["textJa"])

    def test_the_next_launch_has_no_mark(self):
        self.sent("road", self.road("--ignore-errors"))
        self.save_refused("aom-shot-x")
        # the same game, coop start / end: the mark stays
        tf3ctl.coop_start(30, "look at it together")
        self.assertTrue(self.record()["forced"])
        tf3ctl.coop_end()
        self.assertTrue(self.record()["forced"])
        self.save_refused("aom-shot-x")
        # a new run of the game (restart): a new record, no mark
        tf3ctl.game_pids = lambda: [4243]
        with contextlib.redirect_stderr(io.StringIO()):
            tf3ctl.write_launched(4243, owner="alice")
        self.assertNotIn("forced", self.record())
        self.assertEqual(self.sent("save", {"name": "aom-shot-x"})["name"], "aom-shot-x")
        self.assertEqual(tf3ctl.forced_note(), {})

    def test_a_record_of_another_game_does_not_count(self):
        self.sent("road", self.road("--ignore-errors"))
        # the game quit by hand and was started again from Steam: the old record names a pid not running
        tf3ctl.game_pids = lambda: [5000]
        tf3ctl.OTHER_OWNER_OK = True
        self.assertEqual(self.sent("save", {"name": "aom-shot-x"})["name"], "aom-shot-x")
        self.assertEqual(tf3ctl.forced_note(), {})
        # ... and a forced build on it has no record to keep the mark in: refused, nothing sent
        e = self.refused("road", self.road("--ignore-errors"), "no launch record of the running game")
        self.assertEqual(e.refused, "ignore-errors")
        os.remove(tf3ctl.launched_path())
        self.refused("road", self.road("--ignore-errors"), "no launch record of the running game")
        self.sent("road", self.road("--ignore-errors", "--dry-run"))  # a dry run needs no mark

    def test_a_refused_forced_build_leaves_no_mark(self):
        self.loaded("aom-eu-1900")
        self.refused("road", self.road("--ignore-errors"), "is not a test save's")
        self.assertNotIn("forced", self.record())

    def test_a_mark_that_cannot_be_written_refuses_the_build(self):
        def fail(record):
            raise OSError("disk full")
        with unittest.mock.patch.object(tf3ctl, "_write_record", fail):
            self.refused("road", self.road("--ignore-errors"), "could not write the force mark")

    def test_malformed_marks_count(self):
        rec = self.record()
        rec.update(forced="yes", forcedCount="many")
        write(tf3ctl.launched_path(), json.dumps(rec))
        self.assertIn("1 time)", str(self.save_refused("aom-shot-x")))

    def test_a_loaded_probe_force_save_saves_only_to_probe_force_names(self):
        # forced, saved, then restarted (a new record without the mark) and that save loaded again
        self.sent("road", self.road("--ignore-errors"))
        self.sent("save", {"name": "probe-force-j"})
        tf3ctl.game_pids = lambda: [4243]
        with contextlib.redirect_stderr(io.StringIO()):
            tf3ctl.write_launched(4243, owner="alice")
        self.loaded("probe-force-j")
        e = self.save_refused("probe-flat-base")
        self.assertIn("the loaded save 'probe-force-j'", str(e))
        self.save_refused("aom-shot-x")
        self.assertEqual(self.sent("save", {"name": "probe-force-k"})["name"], "probe-force-k")
        note = tf3ctl.forced_note()["forced"]
        self.assertEqual((note["count"], note["loaded"]), (0, "probe-force-j"))
        self.assertIn("probe-force-*", note["textJa"])
        self.loaded("/some/where/probe-force-j.sav")  # a loaded save given as a path counts by its file name
        self.save_refused("aom-shot-x")
        # another save loaded: as before
        self.loaded("probe-flat-base")
        self.assertEqual(self.sent("save", {"name": "aom-shot-x"})["name"], "aom-shot-x")
        self.assertEqual(tf3ctl.forced_note(), {})

    def test_a_persons_game_after_coop_keeps_the_mark_and_its_record(self):
        # a game a person started, shared once (coop end leaves coopChanges and no owner): forced with
        # --other-owner-ok, the record keeps no owner key and still reads
        write(tf3ctl.launched_path(), json.dumps({"v": 1, "pid": 4242, "started_at": 1, "cmd": "coop",
                                                  "coopChanges": 2}))
        tf3ctl.OTHER_OWNER_OK = True
        self.sent("road", self.road("--ignore-errors"))
        rec = self.record()
        self.assertNotIn("owner", rec)
        self.assertEqual((rec["forced"], rec["forcedCount"], rec["coopChanges"]), (True, 1, 2))
        self.assertIsNotNone(tf3ctl.read_launched()[0])
        self.save_refused("aom-shot-x")

    def test_status_says_so(self):
        self.sent("road", self.road("--ignore-errors"))
        for answer in ({"ok": True}, tf3ctl.GameNotReady("loading", {"state": "loading"})):
            def fake_send(cmd, args=None, **kw):
                if isinstance(answer, Exception):
                    raise answer
                return dict(answer)
            out = io.StringIO()
            with unittest.mock.patch.object(tf3ctl, "send", fake_send), contextlib.redirect_stdout(out), \
                    contextlib.redirect_stderr(io.StringIO()):
                tf3ctl.main(["--owner", "alice", "status"])
            res = json.loads(out.getvalue())
            self.assertEqual(res["forced"]["count"], 1, answer)
            self.assertIn("textJa", res["forced"])

    def test_main_exit_code_and_answer(self):
        self.sent("road", self.road("--ignore-errors"))
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()), \
                unittest.mock.patch.object(tf3ctl, "write_command", lambda *a: self.fail("sent")):
            code = tf3ctl.main(["--owner", "alice", "--other-owner-ok", "save", "aom-shot-x", "--user-asked"])
        self.assertEqual(code, 4)
        res = json.loads(out.getvalue())
        self.assertEqual((res["ok"], res["refused"]), (False, "forced-save"))


class RunningCostsTest(_ForceBase):
    """running-costs (2026-11-24): read only without --set-* / --scale-*; a write (runningCostsSet) only on a test
    save, not in coop, as road --ignore-errors, and through the owner check; finance only reads."""

    def rc(self, *a):
        return tf3ctl.running_costs_args(self.p.parse_args(["running-costs", "--model", "bus_1900"] + list(a)))

    def test_args(self):
        self.assertEqual(self.rc(), ("runningCosts", {"model": "bus_1900"}))
        self.assertEqual(self.rc("--limit", "3"), ("runningCosts", {"model": "bus_1900", "limit": 3}))
        cmd, a = self.rc("--scale-running", "2", "--set-maintenance", "1.5")
        self.assertEqual(cmd, "runningCostsSet")
        self.assertEqual(a["ops"], [{"field": "runningCosts", "scale": 2.0}, {"field": "maintenanceScale", "set": 1.5}])
        self.assertEqual(a["where"], "script")
        self.assertEqual(self.rc("--set", "runningCostScale=3", "--where", "gui")[1],
                         {"model": "bus_1900", "ops": [{"field": "runningCostScale", "set": 3.0}], "where": "gui"})
        self.assertEqual(self.rc("--set-running", "500")[1]["ops"], [{"field": "runningCosts", "set": 500.0}])
        for bad in (["--set-running", "1", "--scale-running", "2"], ["--set", "price=1"], ["--set", "runningCosts"],
                    ["--scale", "runningCosts=x"], ["--where", "gui"], ["--set-running", "nan"]):
            with self.assertRaises(tf3ctl.ToolError, msg=bad):
                self.rc(*bad)
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.running_costs_args(self.p.parse_args(["running-costs", "--model", " "]))
        f = tf3ctl.finance_args(self.p.parse_args(["finance", "--since", "120", "--vehicles", "601,602", "--columns", "2"]))
        self.assertEqual(f, {"since": 120.0, "vehicles": [601, 602], "columns": 2})
        self.assertEqual(tf3ctl.finance_args(self.p.parse_args(["finance"])), {})
        for bad in (["--vehicles", "a"], ["--vehicles", "-1"], ["--since", "-5"]):
            with self.assertRaises(tf3ctl.ToolError, msg=bad):
                tf3ctl.finance_args(self.p.parse_args(["finance"] + bad))

    def test_reads_change_nothing_and_go_anywhere(self):
        self.assertFalse(tf3ctl.changes_game("runningCosts", {"model": "x"}))
        self.assertFalse(tf3ctl.changes_game("finance", {}))
        self.assertTrue(tf3ctl.changes_game("runningCostsSet", {"model": "x"}))
        self.loaded("aom-eu-1900")
        self.assertNotIn("_testSave", self.sent("runningCosts", {"model": "x", "_testSave": "probe-x"}))
        tf3ctl.coop_start(60, "look together")
        self.sent("runningCosts", {"model": "x"})
        self.sent("finance", {})
        # another owner's game: reads still go, without --other-owner-ok
        tf3ctl.OWNER = "bob"
        self.sent("runningCosts", {"model": "x"})

    def test_a_write_on_a_test_save_names_it(self):
        for save in ("probe-flat-base", "3-probe", "aom-ops-x"):
            self.loaded(save)
            a = self.sent("runningCostsSet", self.rc("--scale-running", "2")[1])
            self.assertEqual(a["_testSave"], save)
            self.assertEqual(a["_owner"], "alice")

    def test_a_write_refused_on_a_persons_save_a_new_game_or_an_unknown_one(self):
        args = self.rc("--scale-running", "2")[1]
        self.loaded("aom-eu-1900")
        e = self.refused("runningCostsSet", args, "'aom-eu-1900' is not a test save's")
        self.assertEqual(e.refused, "running-costs")
        self.assertIsInstance(e, tf3ctl.RunningCostsRefused)
        self.loaded("")
        self.refused("runningCostsSet", args, "save probe-NAME), then load that")
        self.loaded(None)
        self.refused("runningCostsSet", args, "is not known")
        # a _testSave written by hand is dropped and named again from the log
        self.loaded("aom-eu-1900")
        self.refused("runningCostsSet", dict(args, _testSave="probe-x"), "is not a test save's")

    def test_a_write_refused_in_coop_and_by_the_owner_check(self):
        args = self.rc("--scale-running", "2")[1]
        tf3ctl.coop_start(60, "look together")
        self.refused("runningCostsSet", args, "during coop")  # the coop client: coop_check refuses it
        # another client with --other-owner-ok: the test-save rule refuses any coop mark
        tf3ctl.OWNER, tf3ctl.OTHER_OWNER_OK = "bob", True
        e = self.refused("runningCostsSet", args, "coop mark")
        self.assertEqual(e.refused, "running-costs")
        tf3ctl.OWNER, tf3ctl.OTHER_OWNER_OK = "alice", False
        tf3ctl.coop_end()
        # another owner's game: the owner check refuses it before anything
        tf3ctl.OWNER = "bob"
        e = self.refused("runningCostsSet", args, "not by bob")
        self.assertNotIsInstance(e, tf3ctl.RunningCostsRefused)
        # --other-owner-ok passes the owner check, but not the test-save rule
        tf3ctl.OTHER_OWNER_OK = True
        self.loaded("aom-eu-1900")
        self.refused("runningCostsSet", args, "is not a test save's")
        self.loaded("probe-x")
        self.assertEqual(self.sent("runningCostsSet", args)["_testSave"], "probe-x")

    def test_game_script_setting_only_on_test_saves_or_a_new_game(self):
        def load(*a):
            return tf3ctl.load_args(self.p.parse_args(["load"] + list(a)))
        p = "--param=hummer_remote_probe:gameScript=2"
        self.assertEqual(load("probe-runcost", p)["params"], {"hummer_remote_probe": {"gameScript": 2}})
        self.assertEqual(load("3-probe", p)["params"]["hummer_remote_probe"]["gameScript"], 2)
        for save in ("aom-eu-1900", "My Railway", "12-probe"):
            with self.assertRaises(tf3ctl.ToolError, msg=save):
                load(save, p)
        load("aom-eu-1900", "--param=hummer_remote_probe:gameScript=1")  # off: anywhere
        load("aom-eu-1900", "--param=hummer_remote_probe:speedLabel=2")
        ns = tf3ctl.make_parser().parse_args(["newgame", "--param", "hummer_remote_probe:gameScript=2"])
        self.assertEqual(tf3ctl.newgame_args(ns)["params"]["hummer_remote_probe"]["gameScript"], 2)

    def test_main_routes_reads_and_writes(self):
        got = []

        def fake_send(cmd, args=None, **kw):
            got.append((cmd, args, kw.get("timeout")))
            return {"ok": True}
        with unittest.mock.patch.object(tf3ctl, "send", fake_send), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(tf3ctl.main(["--owner", "alice", "running-costs", "--model", "101"]), 0)
            self.assertEqual(tf3ctl.main(["--owner", "alice", "running-costs", "--model", "101", "--scale-running", "2"]), 0)
            self.assertEqual(tf3ctl.main(["--owner", "alice", "finance", "--since", "5"]), 0)
        self.assertEqual([g[0] for g in got], ["runningCosts", "runningCostsSet", "finance"])
        self.assertEqual(got[1][2], tf3ctl.RUNNING_COSTS_TIMEOUT_SEC)


class LightsTest(_ForceBase):
    """lights --node ID --off (2026-11-24): a junction's traffic light taken off (lightsOff), only
    on a test save, not in coop, as road --ignore-errors, and through the owner check; its dry run asks the engine,
    so it goes through the same rules. road --inspect-node (its trafficLightPreference) only reads."""

    def la(self, *a):
        return tf3ctl.lights_args(self.p.parse_args(["lights"] + list(a)))

    def test_args(self):
        self.assertEqual(self.la("--node", "4077", "--off"), {"node": 4077})
        self.assertEqual(self.la("--node", "4077", "--off", "--dry-run"), {"node": 4077, "dryRun": True})
        for bad in (["--node", "4077"], ["--node", "-1", "--off"]):
            with self.assertRaises(tf3ctl.ToolError, msg=bad):
                self.la(*bad)
        with contextlib.redirect_stderr(io.StringIO()):
            for bad in (["--off"], ["--node", "x", "--off"]):
                with self.assertRaises(SystemExit, msg=bad):
                    self.p.parse_args(["lights"] + bad)

    def test_changes_the_game_dry_run_too(self):
        self.assertTrue(tf3ctl.changes_game("lightsOff", {"node": 1}))
        self.assertTrue(tf3ctl.changes_game("lightsOff", {"node": 1, "dryRun": True}))
        self.assertFalse(tf3ctl.changes_game("roadInspect", {"node": 1}))

    def test_on_a_test_save_names_it(self):
        for save in ("probe-flat-base", "3-probe", "aom-ops-x"):
            self.loaded(save)
            for extra in ((), ("--dry-run",)):
                a = self.sent("lightsOff", self.la("--node", "9000", "--off", *extra))
                self.assertEqual(a["_testSave"], save)
                self.assertEqual(a["_owner"], "alice")
                self.assertEqual(a["node"], 9000)

    def test_refused_on_a_persons_save_a_new_game_or_an_unknown_one(self):
        args = self.la("--node", "9000", "--off")
        self.loaded("aom-eu-1900")
        e = self.refused("lightsOff", args, "'aom-eu-1900' is not a test save's")
        self.assertEqual(e.refused, "lights")
        self.assertIsInstance(e, tf3ctl.LightsRefused)
        self.refused("lightsOff", dict(args, dryRun=True), "is not a test save's")
        self.loaded("")
        self.refused("lightsOff", args, "save probe-NAME), then load that")
        self.loaded(None)
        self.refused("lightsOff", args, "is not known")
        # a _testSave written by hand is dropped and named again from the log
        self.loaded("aom-eu-1900")
        self.refused("lightsOff", dict(args, _testSave="probe-x"), "is not a test save's")

    def test_refused_in_coop_and_by_the_owner_check(self):
        args = self.la("--node", "9000", "--off")
        tf3ctl.coop_start(60, "look together")
        self.refused("lightsOff", args, "during coop")  # the coop client: coop_check refuses it
        tf3ctl.OWNER, tf3ctl.OTHER_OWNER_OK = "bob", True
        e = self.refused("lightsOff", args, "coop mark")
        self.assertEqual(e.refused, "lights")
        tf3ctl.OWNER, tf3ctl.OTHER_OWNER_OK = "alice", False
        tf3ctl.coop_end()
        # another owner's game: the owner check refuses it before anything, its dry run too
        tf3ctl.OWNER = "bob"
        e = self.refused("lightsOff", args, "not by bob")
        self.assertNotIsInstance(e, tf3ctl.LightsRefused)
        self.refused("lightsOff", dict(args, dryRun=True), "not by bob")
        # --other-owner-ok passes the owner check, but not the test-save rule
        tf3ctl.OTHER_OWNER_OK = True
        self.loaded("aom-eu-1900")
        self.refused("lightsOff", args, "is not a test save's")
        self.loaded("probe-x")
        self.assertEqual(self.sent("lightsOff", args)["_testSave"], "probe-x")

    def test_the_other_test_save_commands_still_checked(self):
        # (test_save_checks: road --ignore-errors and running-costs writes as before)
        self.loaded("aom-eu-1900")
        self.refused("road", self.road("--ignore-errors"), "is not a test save's")
        self.refused("runningCostsSet", {"model": "x", "ops": [{"field": "runningCosts", "set": 1}]},
                     "is not a test save's")
        self.assertNotIn("_testSave", self.sent("roadInspect", {"node": 5, "_testSave": "probe-x"}))
        self.loaded("probe-x")
        self.assertEqual(self.sent("road", self.road("--ignore-errors"))["_testSave"], "probe-x")

    def test_main_routes_it(self):
        got = []

        def fake_send(cmd, args=None, **kw):
            got.append((cmd, args, kw.get("timeout")))
            return {"ok": True}
        with unittest.mock.patch.object(tf3ctl, "send", fake_send), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(tf3ctl.main(["--owner", "alice", "lights", "--node", "9000", "--off", "--dry-run"]), 0)
        self.assertEqual(got, [("lightsOff", {"node": 9000, "dryRun": True}, tf3ctl.BUILD_TIMEOUT_SEC)])


class _Past(Exception):
    """Raised by a stand-in once a command got past the check a test looks at."""


class ConfigDefaultsTest(unittest.TestCase):
    """Without a configuration file (a fresh install): no owner check, no coop, test saves named probe-* only, no
    modhub validate or publish, no pointer. A file that cannot be read: the strict side (a warning, the owner check on, all else as without a file)."""

    def setUp(self):
        self.saved = {k: getattr(tf3ctl, k) for k in ("game_pids", "OWNER", "OTHER_OWNER_OK", "USER_ASKED",
                                                       "exchange_dir")}
        self.home = tempfile.mkdtemp()
        self.env = unittest.mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": self.home})
        self.env.start()
        os.environ.pop("TF3CTL_CONFIG", None)
        tf3ctl.CONFIG, tf3ctl.CONFIG_INFO = tf3ctl.load_config()
        self.x = tempfile.mkdtemp()  # an exchange folder: a refused command leaves nothing in it
        tf3ctl.exchange_dir = lambda: self.x
        tf3ctl.OWNER, tf3ctl.OTHER_OWNER_OK, tf3ctl.USER_ASKED = None, False, False

    def tearDown(self):
        self.env.stop()
        for k, v in self.saved.items():
            setattr(tf3ctl, k, v)
        use_config(CONFIGURED)
        shutil.rmtree(self.home, ignore_errors=True)
        shutil.rmtree(self.x, ignore_errors=True)

    def ctl(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = tf3ctl.main(list(argv))
        return code, (json.loads(out.getvalue()) if out.getvalue().strip() else None), err.getvalue()

    def write_config(self, text):
        os.makedirs(os.path.join(self.home, "tf3ctl"), exist_ok=True)
        write(os.path.join(self.home, "tf3ctl", "config.json"), text)

    def test_no_file_is_the_defaults_and_its_place_follows_xdg(self):
        self.assertEqual(tf3ctl.CONFIG_INFO, {"path": os.path.join(self.home, "tf3ctl", "config.json"),
                                              "state": "none"})
        self.assertEqual(tf3ctl.CONFIG, {"ownerCheck": False, "coop": False, "testSavePrefixes": ["probe-"],
                                         "testSaveDigitFirst": False, "pointer": False,
                                         "modhub": {"validateFolders": [], "publishFolders": [],
                                                    "publishedIds": {}}})
        self.assertIsNone(tf3ctl.config_warning())
        home = os.path.expanduser("~")
        self.assertEqual(tf3ctl.config_path({}), (os.path.join(home, ".config", "tf3ctl", "config.json"), False))
        self.assertEqual(tf3ctl.config_path({"XDG_CONFIG_HOME": "/x"}), ("/x/tf3ctl/config.json", False))
        self.assertEqual(tf3ctl.config_path({"XDG_CONFIG_HOME": "/x", "TF3CTL_CONFIG": "/y.json"}), ("/y.json", True))
        code, res, err = self.ctl("config")
        self.assertEqual((code, res["file"]["state"], res["config"]["coop"], err), (0, "none", False, ""))

    def test_the_example_file_is_the_defaults(self):
        with unittest.mock.patch.dict(os.environ, {"TF3CTL_CONFIG": os.path.join(ROOT, "tools", "config.example.json")}):
            cfg, info = tf3ctl.load_config()
        self.assertEqual((info["state"], cfg), ("file", tf3ctl._config_defaults()))
        self.assertEqual(cfg, tf3ctl.CONFIG_DEFAULTS)

    def test_a_file_sets_what_it_names_and_the_rest_stays_default(self):
        self.write_config('{"_about": "a comment", "pointer": true, "testSavePrefixes": ["shot-", "probe-"], '
                          '"modhub": {"_why": "x", "publishFolders": ["my_mod_1"]}}')
        cfg, info = tf3ctl.load_config()
        self.assertEqual(info["state"], "file")
        self.assertEqual((cfg["pointer"], cfg["ownerCheck"], cfg["testSavePrefixes"]), (True, False, ["shot-", "probe-"]))
        self.assertEqual(cfg["modhub"], {"validateFolders": [], "publishFolders": ["my_mod_1"], "publishedIds": {}})

    def test_a_file_that_cannot_be_read_is_the_strict_side(self):
        for text, why in (("{not json", "Expecting"), ("[]", "not a JSON object"),
                          ('{"debug": true}', "unknown key debug"), ('{"coop": "yes"}', "coop must be true or false"),
                          ('{"ownerCheck": 0}', "ownerCheck must be"), ('{"testSavePrefixes": "probe-"}', "list"),
                          ('{"testSavePrefixes": [""]}', "list"), ('{"testSavePrefixes": ["a/b"]}', "list"),
                          ('{"modhub": {"publishFolders": ["x"], "folders": []}}', "unknown key modhub.folders"),
                          ('{"modhub": {"publishedIds": {"x": 5}}}', "mod.io ids"),
                          ('{"modhub": []}', "modhub must be an object"),
                          ('{"coop": true}', "coop needs ownerCheck true"),
                          ('{"coop": true, "ownerCheck": false}', "coop needs ownerCheck true")):
            self.write_config(text)
            cfg, info = tf3ctl.load_config()
            self.assertEqual(info["state"], "broken", text)
            self.assertIn(why, info["error"], text)
            self.assertEqual(cfg, dict(tf3ctl._config_defaults(), ownerCheck=True), text)
        code, res, err = self.ctl("config")
        self.assertEqual((code, res["file"]["state"], res["config"]["ownerCheck"]), (0, "broken", True))
        self.assertIn("warning: cannot read the configuration file %s" % os.path.join(self.home, "tf3ctl",
                                                                                      "config.json"), err)
        self.assertIn("the owner check on", err)
        # a file TF3CTL_CONFIG names that is not there: the same
        with unittest.mock.patch.dict(os.environ, {"TF3CTL_CONFIG": os.path.join(self.home, "missing.json")}):
            cfg, info = tf3ctl.load_config()
        self.assertEqual((info["state"], cfg["ownerCheck"]), ("broken", True))
        self.assertIn("does not exist", info["error"])

    def test_a_broken_file_refuses_a_game_change_without_owner(self):
        self.write_config("{not json")
        tf3ctl.game_pids = lambda: [4242]
        with contextlib.redirect_stderr(io.StringIO()):
            tf3ctl.write_launched(4242, owner="alice")
        code, res, err = self.ctl("save", "x")  # main re-reads the file: the owner check is on
        self.assertEqual(code, 4)
        self.assertIn("warning: cannot read the configuration file", err)
        self.assertEqual(os.listdir(self.x), [], "nothing sent")

    def test_save_note_only_on_an_answer_that_did_something(self):
        for cmd, args in (("stockSet", {}), ("steps", {"count": 1}), ("money", {"add": 1}), ("townDevelop", {}),
                          ("townSize", {}), ("townConnect", {}), ("companyInit", {}), ("lightsOff", {"node": 1}),
                          ("road", {"ignoreErrors": True})):
            self.assertEqual(tf3ctl.note_save_change(cmd, args, {"ok": True})["saveNote"], tf3ctl.SAVE_NOTE, cmd)
            self.assertNotIn("saveNote", tf3ctl.note_save_change(cmd, dict(args, dryRun=True), {"ok": True}), cmd)
            self.assertNotIn("saveNote", tf3ctl.note_save_change(cmd, args, {"ok": False, "error": "x"}), cmd)
        self.assertEqual(tf3ctl.note_save_change("runningCostsSet", {"model": "x"}, {"ok": True})["saveNote"],
                         tf3ctl.RUNNING_COSTS_NOTE)
        self.assertNotIn("saveNote", tf3ctl.note_save_change("companyInit", {}, {"ok": True, "sent": False}))
        for cmd, args in (("road", {}), ("build", {}), ("save", {"name": "x"}), ("runningCosts", {"model": "x"})):
            self.assertNotIn("saveNote", tf3ctl.note_save_change(cmd, args, {"ok": True}), cmd)

    def test_no_owner_check_lets_any_client_change_any_game(self):
        tf3ctl.game_pids = lambda: [4242]
        for owner in (None, "alice"):
            tf3ctl.OWNER = owner
            for cmd, args in (("save", {"name": "x"}), ("quit", None), ("speed", {"speed": 2})):
                self.assertIsNone(tf3ctl.check_game_owner(cmd, args), (owner, cmd))  # no launch record at all
        with contextlib.redirect_stderr(io.StringIO()):
            tf3ctl.write_launched(4242, owner="bob")
        self.assertIsNone(tf3ctl.check_game_owner("save", {"name": "x"}), "another owner's game")
        # launch --load without an owner is not refused up front
        launched = []
        with unittest.mock.patch.object(tf3ctl, "launch_game", lambda t: launched.append(t) or {"ok": True}), \
                unittest.mock.patch.object(tf3ctl, "game_pids", lambda: []), \
                unittest.mock.patch.object(tf3ctl, "replace_game", lambda *a, **k: {"ok": True}), \
                unittest.mock.patch.object(tf3ctl, "check_profile_start", lambda lang: None):
            code, res, _ = self.ctl("launch", "--load", "probe-x")
        self.assertEqual((code, len(launched), res["load"]), (0, 1, {"ok": True}), res)

    def test_coop_is_refused_until_the_configuration_enables_it(self):
        launched = []
        with unittest.mock.patch.object(tf3ctl, "launch_game", lambda t: launched.append(t)):
            for argv in (["--owner", "a", "coop", "start", "--reason", "x"], ["--owner", "a", "coop", "end"],
                         ["--owner", "a", "launch", "--coop", "--reason", "x"]):
                code, res, err = self.ctl(*argv)
                self.assertEqual((code, res["refused"]), (4, "config"), argv)
                self.assertIn('set "coop": true in the configuration file', res["error"])
        self.assertEqual(launched, [], "nothing started")

    def test_test_saves_are_probe_names_only(self):
        for name in ("probe-x", "probe-flat-base", "/s/probe-x.sav"):
            self.assertTrue(tf3ctl.is_test_save(name), name)
        for name in ("aom-shot-x", "3-probe", "6", "My Railway"):
            self.assertFalse(tf3ctl.is_test_save(name), name)
        self.assertEqual(tf3ctl.test_save_text(), "probe-*")
        self.assertEqual(tf3ctl.test_save_rules(), {"prefixes": ["probe-"], "digitFirst": False})
        ns = tf3ctl.make_parser().parse_args(["load", "3-probe", "--param", "hummer_remote_probe:gameScript=2"])
        with self.assertRaises(tf3ctl.ToolError) as cm:
            tf3ctl.load_args(ns)
        self.assertIn("goes with test saves only (probe-*); '3-probe' is not one", str(cm.exception))
        # the configuration's names instead, and the digit rule
        self.write_config('{"testSavePrefixes": ["shot-"], "testSaveDigitFirst": true}')
        tf3ctl.CONFIG, tf3ctl.CONFIG_INFO = tf3ctl.load_config()
        self.assertTrue(tf3ctl.is_test_save("shot-1") and tf3ctl.is_test_save("3-probe"))
        self.assertFalse(tf3ctl.is_test_save("probe-x"))
        self.assertEqual(tf3ctl.test_save_text(), "shot-*, or one digit first")

    def test_an_empty_or_short_prefix_list_is_warned_on_stderr_and_in_config(self):
        # the defaults: no warning anywhere
        self.assertEqual(tf3ctl.test_save_warnings(), [])
        code, res, err = self.ctl("config")
        self.assertEqual((code, "warnings" in res, err), (0, False, ""))
        # an empty list: the checked commands are refused on every save
        self.write_config('{"testSavePrefixes": []}')
        tf3ctl.CONFIG, tf3ctl.CONFIG_INFO = tf3ctl.load_config()
        code, res, err = self.ctl("config")
        self.assertEqual(code, 0)
        self.assertEqual(len(res["warnings"]), 1)
        self.assertIn("testSavePrefixes is empty", res["warnings"][0])
        self.assertIn("refused on every save", res["warnings"][0])
        self.assertIn("testSavePrefixes is empty", err)
        # with the digit rule on, the digit saves are still test saves
        self.write_config('{"testSavePrefixes": [], "testSaveDigitFirst": true}')
        tf3ctl.CONFIG, tf3ctl.CONFIG_INFO = tf3ctl.load_config()
        self.assertIn("one digit first", tf3ctl.test_save_warnings()[0])
        # one and two characters are warned, three are not
        self.write_config('{"testSavePrefixes": ["a", "ab", "abc"]}')
        tf3ctl.CONFIG, tf3ctl.CONFIG_INFO = tf3ctl.load_config()
        warnings = tf3ctl.test_save_warnings()
        self.assertEqual(len(warnings), 2)
        self.assertIn("'a'", warnings[0])
        self.assertIn("'ab'", warnings[1])
        code, res, err = self.ctl("config")
        self.assertEqual(res["warnings"], warnings)
        self.assertEqual(err.count("warning: testSavePrefixes"), 2)

    def test_the_mod_gets_the_test_save_rules_and_the_modhub_lists_with_the_command(self):
        got = []

        def capture(folder, cid, cmd, args):
            got.append((cmd, args))
            raise _Past()

        tf3ctl.game_pids = lambda: []
        with unittest.mock.patch.object(tf3ctl, "write_command", capture), \
                unittest.mock.patch.object(tf3ctl, "cleanup", lambda folder: None):
            with self.assertRaises(_Past):
                tf3ctl.send("modhubStatus", {"_modhub": {"publishFolders": ["sneaked_in"]}}, folder=self.x)
            with unittest.mock.patch.object(tf3ctl, "test_save_checks", lambda cmd, args: "probe-x"), \
                    self.assertRaises(_Past):
                tf3ctl.send("lightsOff", {"node": 5, "_testSaveRules": {"prefixes": ["x"]}}, folder=self.x)
            with self.assertRaises(_Past):
                tf3ctl.send("status", {"_testSave": "aom-shot-x"}, folder=self.x)
        self.assertEqual(got[0], ("modhubStatus", {"_modhub": {"validateFolders": [], "publishFolders": [],
                                                                "publishedIds": {}}}))
        self.assertEqual(got[1][1], {"node": 5, "_testSave": "probe-x",
                                     "_testSaveRules": {"prefixes": ["probe-"], "digitFirst": False}})
        self.assertEqual(got[2][1], {}, "only send names them")

    def test_modhub_validate_and_publish_take_no_folder(self):
        sent = []
        with unittest.mock.patch.object(tf3ctl, "send", lambda *a, **k: sent.append(a) or {"ok": True}):
            code, _, err = self.ctl("modhub", "publish", "hummer_force_unload_default_1", "--public", "yes",
                                    "--changelog", "x", "--first-upload", "--dry-run")
        self.assertEqual(code, 2)
        self.assertIn("publish takes no staging folder: list the ones it may upload in the configuration file", err)
        self.assertEqual(sent, [], "nothing sent, no mark")
        self.assertFalse(os.path.exists(tf3ctl.pending_path()))

    def test_pointer_is_refused_until_the_configuration_enables_it(self):
        code, res, _ = self.ctl("pointer", "0.5,0.5")
        self.assertEqual((code, res["refused"]), (4, "config"))
        self.assertIn('"pointer": true', res["error"])


class FencesTest(_ForceBase):
    """The fences as they stood before the configuration file, with the CONFIGURED file (every switch on, the four
    prefixes and the digit rule), and what changes without a file. A person's save: aom-eu-1900-2 (no test save's
    name). The game: pid 4242, launched by alice."""

    PERSON = "aom-eu-1900-2"

    def tearDown(self):
        use_config(CONFIGURED)
        super().tearDown()

    def answer(self, cmd, args):
        """Through send with the mod faked: (the args written for the mod, the answer)."""
        got = []
        with unittest.mock.patch.object(tf3ctl, "write_command", lambda f, cid, c, a: got.append((c, a))), \
                unittest.mock.patch.object(tf3ctl, "cleanup", lambda f: None), \
                unittest.mock.patch.object(tf3ctl, "note_activity", lambda *a: None), \
                unittest.mock.patch.object(tf3ctl, "wait_pickup", lambda f, c: None), \
                unittest.mock.patch.object(tf3ctl, "wait_answer", lambda *a: {"ok": True}), \
                contextlib.redirect_stderr(io.StringIO()):
            res = tf3ctl.send(cmd, args, folder=self.x)
        self.assertEqual(len(got), 1, cmd)
        return got[0][1], res

    def coop(self, minutes=30):
        rec, _ = tf3ctl.read_launched()
        now = time.time()
        rec["coop"] = {"with": "alice", "reason": "test", "since": now, "until": now + minutes * 60}
        tf3ctl._write_record(rec)

    def ignore_errors(self):
        return self.road("--ignore-errors")

    def test_configured_a_persons_save_refuses_the_test_save_commands(self):
        self.loaded(self.PERSON)
        self.refused("road", self.ignore_errors(), "is not a test save's")
        self.refused("road", self.road("--ignore-errors", "--dry-run", "--engine-check"), "is not a test save's")
        self.refused("lightsOff", {"node": 5}, "is not a test save's")
        self.refused("lightsOff", {"node": 5, "dryRun": True}, "is not a test save's")
        self.refused("runningCostsSet", {"model": "bus", "ops": [{"field": "runningCosts", "scale": 2}]},
                     "is not a test save's")
        ns = tf3ctl.make_parser().parse_args(["load", self.PERSON, "--param", "hummer_remote_probe:gameScript=2"])
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.load_args(ns)

    def test_configured_a_persons_save_takes_what_had_no_fence(self):
        # (before the configuration file too: tf3ctl has no check of the save for these; their help says test saves)
        self.loaded(self.PERSON)
        for cmd, args in (("stockSet", {"entity": 1, "stock": 0, "amount": 5}), ("money", {"add": 1}),
                          ("steps", {"count": 5}), ("townDevelop", {"town": 1}), ("companyInit", {}),
                          ("build", {"res": "x"}), ("road", self.road("--remove-buildings")),
                          ("road", self.road("--remove-fields")), ("save", {"name": self.PERSON}),
                          ("save", {"name": "aom-eu-1900"})):
            sent, res = self.answer(cmd, args)
            self.assertEqual(sent.get("_owner"), "alice", cmd)
        self.assertEqual(self.answer("money", {"add": 1})[1]["saveNote"], tf3ctl.SAVE_NOTE)
        self.assertNotIn("saveNote", self.answer("build", {"res": "x"})[1])
        self.assertNotIn("saveNote", self.answer("stockSet", {"entity": 1, "stock": 0, "amount": 5,
                                                              "dryRun": True})[1], "a dry run changes nothing")

    def test_configured_test_saves_take_them_by_the_four_prefixes_and_the_digit_rule(self):
        for save in ("probe-flat-base", "aom-ops-x", "aom-shot-x", "aom-bgm-check-x", "3-probe"):
            self.loaded(save)
            sent, res = self.answer("lightsOff", {"node": 5, "dryRun": True})
            self.assertEqual(sent["_testSave"], save)
            self.assertEqual(sent["_testSaveRules"], {"prefixes": CONFIGURED["testSavePrefixes"], "digitFirst": True})
        self.loaded("3-probe")
        sent, res = self.answer("road", self.ignore_errors())
        self.assertEqual(res["saveNote"], tf3ctl.SAVE_NOTE)
        # and once forced, saves go to probe-force-* names only
        self.refused("save", {"name": "3-probe"}, "probe-force-* names")
        self.refused("save", {"name": self.PERSON}, "probe-force-* names")

    def test_configured_coop_refuses_saving_quitting_and_loading(self):
        self.loaded(self.PERSON)
        self.coop()
        self.refused("save", {"name": self.PERSON}, "not a test save's name")
        self.refused("save", {"name": "probe-x"}, "add --user-asked")
        for cmd, args in (("quit", None), ("load", {"save": "probe-x"}), ("newgame", {}), ("tool", {"name": "x"})):
            self.refused(cmd, args, "is theirs to do")
        self.refused("speed", {"speed": 2}, "add --user-asked")
        self.refused("road", self.ignore_errors(), "coop mark")
        self.refused("lightsOff", {"node": 5}, "is theirs to do")
        tf3ctl.USER_ASKED = True
        self.refused("save", {"name": self.PERSON}, "not a test save's name")
        for cmd, args in (("quit", None), ("load", {"save": "probe-x"})):
            self.refused(cmd, args, "is theirs to do")
        self.assertEqual(self.answer("save", {"name": "probe-x"})[0]["name"], "probe-x")
        self.assertEqual(self.answer("speed", {"speed": 2})[0]["speed"], 2)
        tf3ctl.USER_ASKED = False
        # looking, building and the test commands go (counted as changes of the person's game)
        for cmd, args in (("camera", {"set": "1,2"}), ("build", {"res": "x"}), ("stockSet", {"entity": 1}),
                          ("money", {"add": 1}), ("steps", {"count": 5})):
            self.answer(cmd, args)
        self.assertGreater(tf3ctl.read_launched()[0]["coop"].get("changes", 0), 0)

    def test_configured_owner_check_refuses_other_clients(self):
        for owner in ("bob", None):
            tf3ctl.OWNER = owner
            for cmd, args in (("save", {"name": "probe-x"}), ("quit", None), ("stockSet", {"entity": 1}),
                              ("build", {"res": "x"})):
                self.refused(cmd, args, "started by alice" if owner is None else "not by bob")
        tf3ctl.OWNER, tf3ctl.OTHER_OWNER_OK = "bob", True
        self.assertEqual(self.answer("save", {"name": "probe-x"})[0]["_otherOwnerOk"], "alice")

    def test_without_a_file_the_owner_check_and_the_extra_names_are_gone_the_rest_holds(self):
        os.remove(CONFIG_FILE)
        try:
            tf3ctl.CONFIG, tf3ctl.CONFIG_INFO = tf3ctl.load_config({"XDG_CONFIG_HOME": self.x})
            self.assertEqual(tf3ctl.CONFIG_INFO["state"], "none")
            # any client changes the game
            tf3ctl.OWNER = "bob"
            self.answer("save", {"name": "probe-x"})
            tf3ctl.OWNER = None
            self.answer("quit", None)
            # test saves: probe-* only
            for save in ("aom-shot-x", "3-probe", self.PERSON):
                self.loaded(save)
                self.refused("road", self.ignore_errors(), "is not a test save's (probe-*)")
                self.refused("lightsOff", {"node": 5}, "is not a test save's (probe-*)")
            self.loaded("probe-flat-base")
            self.assertEqual(self.answer("lightsOff", {"node": 5})[0]["_testSaveRules"],
                             {"prefixes": ["probe-"], "digitFirst": False})
            # a coop mark left on the running game still holds (none can be made without "coop": true)
            self.loaded(self.PERSON)
            self.coop()
            tf3ctl.OWNER = "alice"
            self.refused("save", {"name": self.PERSON}, "not a test save's name")
            self.refused("quit", None, "is theirs to do")
        finally:
            with open(CONFIG_FILE, "w", encoding="utf-8") as f:
                json.dump(CONFIGURED, f)



class ConfiguredMachineTest(unittest.TestCase):
    """With every switch on and the four prefixes and the digit rule (the CONFIGURED file the other tests run
    with): the names and texts as before the configuration file."""

    def test_test_saves_and_their_text_as_before(self):
        use_config(CONFIGURED)
        for name in ("probe-x", "aom-ops-u6", "aom-shot-1950", "aom-bgm-check-1", "3-probe", "6"):
            self.assertTrue(tf3ctl.is_test_save(name), name)
        self.assertFalse(tf3ctl.is_test_save("aom-eu-1900"))
        self.assertEqual(tf3ctl.test_save_text(), "probe-*, aom-ops-*, aom-shot-*, aom-bgm-check-*, or one digit first")
        self.assertEqual(tf3ctl.CONFIG_INFO["state"], "file")
        for key in ("ownerCheck", "coop", "pointer"):
            self.assertIs(tf3ctl.CONFIG[key], True, key)


class ModCommandTest(unittest.TestCase):
    """mod --list / mod <modId> <command> [JSON]: the arguments, and modRead first, modChange when the mod says so."""

    def ns(self, *argv):
        return tf3ctl.make_parser().parse_args(["mod"] + list(argv))

    def test_args(self):
        self.assertEqual(tf3ctl.mod_call_args(self.ns("--list")), ("modList", {}))
        self.assertEqual(tf3ctl.mod_call_args(self.ns("m")), ("modList", {"mod": "m"}))
        self.assertEqual(tf3ctl.mod_call_args(self.ns("--list", "m")), ("modList", {"mod": "m"}))
        self.assertEqual(tf3ctl.mod_call_args(self.ns("m", "c")),
                         ("modRead", {"mod": "m", "command": "c", "args": {}, "timeout": 25}))
        self.assertEqual(tf3ctl.mod_call_args(self.ns("m", "c", '[1, {"a": null}]', "--timeout", "60"))[1],
                         {"mod": "m", "command": "c", "args": [1, {"a": None}], "timeout": 55})
        for argv, text in ((("--list", "m", "c"), "at most a mod's id"), (("m", "c", "{x"), "not JSON"),
                           (("m", "c", "3"), "object or list"), (("m", "c", '"s"'), "object or list"),
                           (("m", "c", "--timeout", "5"), "between 6 and 125"),
                           (("m", "c", "--timeout", "126"), "between 6 and 125"),
                           (("m", "c", "--timeout", "nan"), "between 6 and 125"),
                           (("--list", "--timeout", "4"), "between 5 and 600"),
                           (("--list", "--timeout", "601"), "between 5 and 600"),
                           (("--list", "--timeout", "nan"), "between 5 and 600")):
            with self.assertRaises(tf3ctl.ToolError) as cm:
                tf3ctl.mod_call_args(self.ns(*argv))
            self.assertIn(text, str(cm.exception), argv)
        # NaN in the arguments: the command file cannot hold it
        wire, args = tf3ctl.mod_call_args(self.ns("m", "c", '{"x": NaN}'))
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.command_text(1, wire, args)

    def test_arguments_reach_the_mod_as_sent(self):
        wire, args = tf3ctl.mod_call_args(self.ns("m", "c", '{"s": "a \\"q\\" 日本", "l": [1, 2.5, true], "o": {"k": {}}}'))
        got = mod_reads(tf3ctl.command_text(7, wire, args))
        self.assertEqual(got["cmd"], "modRead")
        self.assertEqual(got["args"]["args"], {"s": 'a "q" 日本', "l": [1, 2.5, True], "o": {"k": {}}})

    def run_mod(self, answers, *argv):
        sent = []

        def fake_send(cmd, args=None, timeout=20, **kw):
            sent.append((cmd, args, timeout))
            return answers.pop(0)
        with unittest.mock.patch.object(tf3ctl, "send", fake_send):
            res = tf3ctl.cmd_mod(self.ns(*argv))
        return res, sent

    def test_list_takes_the_timeout_given(self):
        _, sent = self.run_mod([{"ok": True, "mods": []}], "--list")
        self.assertEqual(sent, [("modList", {}, tf3ctl.MOD_LIST_TIMEOUT_SEC)])
        _, sent = self.run_mod([{"ok": True, "mods": []}], "--list", "--timeout", "15")
        self.assertEqual(sent, [("modList", {}, 15)])
        _, sent = self.run_mod([{"ok": True, "result": 1}], "m", "c")
        self.assertEqual(sent[0][2], tf3ctl.MOD_TIMEOUT_SEC)

    def test_reads_once_and_changes_twice(self):
        res, sent = self.run_mod([{"ok": True, "result": 1}], "m", "c")
        self.assertEqual([c for c, _, _ in sent], ["modRead"])
        self.assertEqual(res["result"], 1)
        res, sent = self.run_mod([{"ok": False, "needsChange": True, "kind": "changes"}, {"ok": True, "result": 2}],
                                 "m", "c", '{"a": 1}', "--timeout", "40")
        self.assertEqual([c for c, _, _ in sent], ["modRead", "modChange"])
        self.assertEqual(sent[0][1], sent[1][1], "the same arguments both times")
        self.assertEqual(sent[1][2], 40)
        self.assertEqual(res["result"], 2)
        # an error that is not needsChange is the answer
        res, sent = self.run_mod([{"ok": False, "kind": "noExt", "error": "x"}], "m", "c")
        self.assertEqual(len(sent), 1)
        self.assertEqual(res["kind"], "noExt")
        res, sent = self.run_mod([{"ok": True, "mods": []}], "--list")
        self.assertEqual(sent[0][0], "modList")

    def test_a_refused_change_sends_nothing_after_the_read(self):
        def fake_send(cmd, args=None, timeout=20, **kw):
            if cmd == "modChange":
                raise tf3ctl.OwnerRefused("refused 'modChange', nothing sent")
            return {"ok": False, "needsChange": True}
        out = io.StringIO()
        with unittest.mock.patch.object(tf3ctl, "send", fake_send), contextlib.redirect_stdout(out), \
                contextlib.redirect_stderr(io.StringIO()):
            code = tf3ctl.main(["--owner", "alice", "mod", "m", "c"])
        self.assertEqual(code, 4)
        self.assertIn("refused 'modChange'", json.loads(out.getvalue())["error"])

    def test_owner_check_takes_mod_change_only_when_the_configuration_turns_it_on(self):
        # the real check_game_owner (not a stand-in): modChange changes the game, modRead / modList only read
        saved = (tf3ctl.game_pids, tf3ctl.OWNER, tf3ctl.OTHER_OWNER_OK)
        args = {"mod": "m", "command": "c", "args": {}, "timeout": 25}
        try:
            tf3ctl.game_pids = lambda: [4242]
            with contextlib.redirect_stderr(io.StringIO()):
                tf3ctl.write_launched(4242, owner="bob")
            tf3ctl.OWNER, tf3ctl.OTHER_OWNER_OK = "alice", False
            use_config(CONFIGURED)
            with self.assertRaises(tf3ctl.OwnerRefused) as cm:
                tf3ctl.check_game_owner("modChange", args)
            self.assertIn("not by alice", str(cm.exception))
            for wire in ("modRead", "modList"):
                self.assertIsNone(tf3ctl.check_game_owner(wire, args), wire)
            tf3ctl.OWNER = "bob"
            self.assertIsNone(tf3ctl.check_game_owner("modChange", args), "the owner's own game")
            tf3ctl.OWNER = "alice"
            use_config(dict(CONFIGURED, ownerCheck=False, coop=False))
            self.assertIsNone(tf3ctl.check_game_owner("modChange", args), "no owner check configured")
        finally:
            tf3ctl.game_pids, tf3ctl.OWNER, tf3ctl.OTHER_OWNER_OK = saved
            use_config(CONFIGURED)
            tf3ctl.remove_launched()


if __name__ == "__main__":
    unittest.main()
