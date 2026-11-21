"""Tests for tools/tf3ctl.py.  python3 -m unittest discover -s tests   (needs luajit on PATH)

The end-to-end cases run the real content/remote.script.lua in tests/fake_game.lua (real time, own process) and talk
to it through real files, exactly as with the game.
"""
import contextlib
import glob
import importlib.util
import io
import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
import unittest
import unittest.mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
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
os.environ.pop("TF3CTL_OWNER", None)



def tearDownModule():
    shutil.rmtree(NO_PROFILE_DIR, ignore_errors=True)
    shutil.rmtree(RUNTIME_DIR, ignore_errors=True)


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
        with unittest.mock.patch.object(tf3ctl, "game_pids", lambda: []), \
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

    def test_9y_screenshot_waits_for_the_file(self):
        code, res = self.ctl("screenshot", "--scale", "0", "--timeout", "10")
        self.assertEqual(code, 0, res)
        self.assertTrue(res["path"].endswith("_0.png"), res)
        self.assertTrue(os.path.exists(res["path"]))

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
        code, res = self.ctl("newgame", "--size", "tiny")
        self.assertEqual(code, 2, "refused: it crashes the game from inside a save")
        before = tf3ctl.current_stamp(self.dir)
        code, res = self.ctl("--owner", "t", "newgame", "--size", "tiny", "--year", "1930", "--timeout", "30", "--unsafe")
        self.assertEqual(code, 0, res)
        self.assertNotEqual(res["hello"]["stamp"], before)
        self.assertEqual(res["hello"]["state"]["date"]["year"], 1930)
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
        self.assertNotIn("unsafe", args, "from the main menu it needs no unsafe")
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
                                       no_towns=False, no_industries=False, list=False, unsafe=False, set_mods=None,
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
        # no upload of any kind: no such subcommand, and nothing in the mod's command list
        for bad in (["modhub"], ["modhub", "validate"], ["modhub", "publish", "a_1"], ["modhub", "upload", "a_1"]):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit, msg=bad):
                parse(bad)
        for name in ("modhubPublish", "publish"):
            self.assertIn("unknown command", mod_reads(tf3ctl.command_text(9, name, {}))["error"])
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
        ns = tf3ctl.argparse.Namespace
        self.assertEqual(tf3ctl.stations_args(ns(name="cen", near=11, radius=500.0)),
                         {"name": "cen", "near": 11, "radius": 500.0})
        self.assertEqual(tf3ctl.stations_args(ns(name=None, near=None, radius=None)), {})
        with self.assertRaises(tf3ctl.ToolError):
            tf3ctl.stations_args(ns(name=None, near=None, radius=5.0))
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
        code, res = self.ctl("status")
        self.assertEqual(code, 0, res)
        self.assertFalse(res["menu"])
        code, res = self.ctl("restart", "--load", "probe", "--launch-timeout", "30", "--timeout", "30",
                             "--quit-timeout", "10")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["quit"]["how"], "quit", "app.quit through the probe, no SIGKILL")
        self.assertTrue(res["load"]["ok"])
        self.assertIn("example_mod", res["load"]["plan"]["mods"])
        self.assertFalse(os.path.exists(record), "restart without --owner: the old owner's record went")
        code, res = self.ctl("quit")
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
        self.assertEqual(got, [("pollIdle", 4, 1), ("pollActive", 4, 1), ("logLevel", 3, 1), ("speedLabel", 2, 0), ("speedButtons", 2, 0)])

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


if __name__ == "__main__":
    unittest.main()
