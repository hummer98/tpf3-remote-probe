"""Tests for tools/tf3ctl_test.py (tf3ctl test: scenarios).  python3 -m unittest discover -s tests

No game. Most cases run scenarios against a fake main (it answers what each case tells it, and can write to a log
file); ScenarioOnFakeGameTest runs one through the real tf3ctl.main against tests/fake_game.lua, as EndToEndTest does.
test_tf3ctl.py is imported for its setup: the test folder (never /tmp), the configuration file and tf3ctl itself.
"""
import contextlib
import glob
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_tf3ctl as base  # noqa: E402  (its setup first: TMPDIR, TF3CTL_CONFIG, XDG_RUNTIME_DIR)


def setUpModule():
    # test_tf3ctl's tearDownModule removes the run's temp folder when the whole run gets past that module
    os.makedirs(tempfile.gettempdir(), exist_ok=True)


def tearDownModule():
    base._remove_test_run_dir()

tf3ctl = base.tf3ctl
T = tf3ctl._test_module()
ROOT = base.ROOT


class FakeMain:
    """Stands in for tf3ctl.main: answers[name] = (exit code, answer object or text, lines to append to the log)."""

    def __init__(self, answers, log=None):
        self.answers, self.log, self.calls = answers, log, []

    def __call__(self, argv):
        self.calls.append(list(argv))
        name = [a for a in argv if not a.startswith("--") and a != self.owner_of(argv)][0]
        code, ans, lines = self.answers.get(name) or (0, {"ok": True}, None)
        if lines and self.log:
            with open(self.log, "a", encoding="utf-8") as f:
                f.write(lines)
        if isinstance(ans, str):
            print(ans)
        elif ans is not None:
            print(json.dumps(ans))
        return code

    @staticmethod
    def owner_of(argv):
        return argv[argv.index("--owner") + 1] if "--owner" in argv else None


def answers(**kw):
    """name=(code, answer) or name=(code, answer, log text)."""
    return {k: (v + (None,))[:3] for k, v in kw.items()}


def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


ERR = "[2026-11-22 08:09:36Z - ERROR    - Main Thread      - Main           ]+ something broke\n"
LUA_ERR = ("[2026-11-22 08:09:37Z - VERBOSE  - Main Thread      - Main           ]+ Exception\n"
           "    | Exception type: Lua error\n"
           "    | Error message: attempt to index local 'x' (a nil value)\n")
OK_LINE = "[2026-11-22 08:09:35Z - MESSAGE  - Main Thread      - Main           ]+ loaded\n"
BENIGN = ("[2026-11-22 08:09:35Z - MESSAGE  - Main Thread      - Main           ]+ Ignoring Set() on expired "
          "ReactStateWrap\n    stack traceback:\n    [C]: in ?\n")


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.log = os.path.join(self.dir, "stdout.txt")

    def scenario(self, sc):
        path = os.path.join(self.dir, "sc.json")
        write(path, sc if isinstance(sc, str) else json.dumps(sc))
        return path

    def run_test(self, sc, fake, *extra, owner="t"):
        """Runs cmd_test as tf3ctl.main would: (exit code, the one JSON printed)."""
        ns = tf3ctl.make_parser().parse_args(["--owner", owner, "test", self.scenario(sc)] + list(extra))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = T.cmd_test(ns, fake, tf3ctl.make_parser, lambda: self.log, tf3ctl.show)
        return code, json.loads(out.getvalue())


class PathAndOpsTest(unittest.TestCase):
    def test_paths(self):
        self.assertEqual(T.parse_path(""), [])
        self.assertEqual(T.parse_path("lines[0].vehicles"), ["lines", 0, "vehicles"])
        self.assertEqual(T.parse_path('a[-1]["x.y"].b'), ["a", -1, "x.y", "b"])
        self.assertEqual(T.parse_path("[2]"), [2])
        for bad in (".a", "a.", "a..b", "a[x]", "a[", "a.[0]", 'a["x]', '["a\\q"]', '["a\\u12"]'):
            with self.assertRaises(T.ScenarioError, msg=bad):
                T.parse_path(bad)
        doc = {"lines": [{"vehicles": 3}], "e": []}
        self.assertEqual(T.resolve(doc, T.parse_path("lines[0].vehicles")), (True, 3))
        self.assertEqual(T.resolve(doc, T.parse_path("lines[-1].vehicles")), (True, 3))
        self.assertEqual(T.resolve(doc, ["lines", 1]), (False, None))
        self.assertEqual(T.resolve(doc, ["e", 0]), (False, None))
        self.assertEqual(T.resolve(doc, ["lines", "0"]), (False, None), "a key is not an index")
        self.assertEqual(T.resolve(doc, ["nope"]), (False, None))
        self.assertEqual(T.resolve(doc, []), (True, doc))

    def check(self, op, actual, value, **kw):
        exp = dict(kw, path="v", op=op, value=value)
        return T.check_expect(exp, {"v": actual})

    def test_every_op(self):
        cases = [  # (op, actual, value, passes)
            ("eq", 3, 3, True), ("eq", 3, 3.0, True), ("eq", 3, 4, False), ("eq", True, 1, False),
            ("eq", 1, True, False), ("eq", {"a": [1, 2]}, {"a": [1, 2]}, True), ("eq", "x", "x", True),
            ("eq", None, None, True), ("eq", 0, None, False),
            ("ne", 3, 4, True), ("ne", 3, 3, False), ("ne", False, 0, True),
            ("gt", 5, 4, True), ("gt", 4, 4, False), ("ge", 4, 4, True), ("ge", 3.5, 4, False),
            ("lt", 3, 4, True), ("lt", 4, 4, False), ("le", 4, 4, True), ("le", 5, 4, False),
            ("gt", "b", "a", True), ("gt", "5", 4, False), ("gt", True, 0, False), ("lt", None, 1, False),
            ("contains", "hello world", "lo w", True), ("contains", "hello", "x", False),
            ("contains", [1, "a", {"b": 2}], {"b": 2}, True), ("contains", [1, 2], 3, False),
            ("contains", [True], 1, False), ("contains", {"key": 1}, "key", True), ("contains", {"key": 1}, 1, False),
            ("contains", 5, 5, False),
        ]
        for op, actual, value, passes in cases:
            res = self.check(op, actual, value)
            self.assertIs(res["pass"], passes, (op, actual, value, res))
            if not passes:
                self.assertTrue(res["why"], res)

    def test_len_and_exists(self):
        self.assertTrue(self.check("len", [1, 2, 3], 3)["pass"])
        self.assertFalse(self.check("len", [1, 2, 3], 2)["pass"])
        self.assertTrue(self.check("len", "abc", 2, cmp="gt")["pass"])
        self.assertTrue(self.check("len", {"a": 1}, 1, cmp="le")["pass"])
        self.assertFalse(self.check("len", [], 1, cmp="ge")["pass"])
        res = self.check("len", 5, 1)
        self.assertFalse(res["pass"])
        self.assertIn("len counts", res["why"])
        self.assertEqual(self.check("len", [1, 2], 2)["actual"], 2)
        self.assertTrue(T.check_expect({"path": "v", "op": "exists"}, {"v": None})["pass"], "null is there")
        self.assertFalse(T.check_expect({"path": "w", "op": "exists"}, {"v": 1})["pass"])
        self.assertTrue(T.check_expect({"path": "w", "op": "exists", "value": False}, {"v": 1})["pass"])
        self.assertFalse(T.check_expect({"path": "v", "op": "exists", "value": False}, {"v": 1})["pass"])

    def test_a_missing_path_fails_with_why(self):
        for op, value in (("eq", 1), ("ne", 1), ("gt", 1), ("contains", 1), ("len", 0)):
            res = T.check_expect({"path": "a.b[3]", "op": op, "value": value}, {"a": {"b": [1]}})
            self.assertFalse(res["pass"], op)
            self.assertEqual(res["why"], "no such path in the answer")
            self.assertNotIn("actual", res)

    def test_long_actual_is_cut(self):
        res = T.check_expect({"path": "", "op": "eq", "value": 1}, {"x": "y" * 1000})
        self.assertIsInstance(res["actual"], str)
        self.assertTrue(res["actual"].endswith("..."))
        self.assertLessEqual(len(res["actual"]), T.ACTUAL_CHARS + 3)


class BrokenScenarioTest(Base):
    def broken(self, sc, needle):
        fake = FakeMain({})
        code, res = self.run_test(sc, fake)
        self.assertEqual(code, 2, res)
        self.assertEqual(res["result"], "broken")
        self.assertIs(res["ok"], False)
        self.assertIn(needle, res["error"])
        self.assertEqual(fake.calls, [], "nothing is run when the scenario is broken")
        return res

    def test_file_and_form(self):
        self.broken("{not json", "is not JSON")
        self.broken([1], "a scenario is a JSON object")
        self.broken({"steps": []}, "steps is empty")
        self.broken({"name": "x"}, "no steps list")
        self.broken({"steps": [{"cmd": "status"}], "stpes": 1}, "unknown keys in the scenario: stpes")
        self.broken({"steps": [{"cmd": "status", "expct": []}]}, "step 1: unknown keys: expct")
        self.broken({"steps": [{"cmd": "status", "log": {}}]}, "give cmd or log")
        self.broken({"steps": [{"name": "n"}]}, "give cmd or log")
        self.broken({"steps": ["status"]}, "step 1 is not an object")
        self.broken({"steps": [{"cmd": []}]}, "cmd is empty")
        self.broken({"steps": [{"cmd": {"a": 1}}]}, "cmd is a list of words or one string")
        self.broken({"steps": [{"cmd": ["status", True]}]}, "strings or numbers")
        self.broken({"steps": [{"cmd": "status 'x"}]}, "cannot be split")
        self.broken({"steps": [{"cmd": "status", "exit": "0"}]}, "exit is the exit code")
        self.broken({"steps": [{"cmd": "status", "continueOnFail": "yes"}]}, "continueOnFail is true or false")
        self.broken({"continueOnFail": 1, "steps": [{"cmd": "status"}]}, "continueOnFail is true or false")
        missing = os.path.join(self.dir, "nope.json")
        ns = tf3ctl.make_parser().parse_args(["test", missing])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(T.cmd_test(ns, FakeMain({}), tf3ctl.make_parser, lambda: None, tf3ctl.show), 2)
        self.assertIn("cannot read", json.loads(out.getvalue())["error"])

    def test_the_second_step_broken_stops_the_first_too(self):
        res = self.broken({"steps": [{"cmd": "status"}, {"cmd": "statsu"}]}, "step 2: tf3ctl cannot read the command")
        self.assertIn("invalid choice", res["error"])

    def test_commands_read_by_tf3ctl_s_parser(self):
        self.broken({"steps": [{"cmd": "steps"}]}, "tf3ctl cannot read the command")
        self.broken({"steps": [{"cmd": "steps 20 --dryrun"}]}, "unrecognized arguments")
        self.broken({"steps": [{"cmd": "steps 20 --dry"}]}, "unrecognized arguments")  # no abbreviations
        self.broken({"steps": [{"cmd": "--owner x status"}]}, "starts with the command's name")
        self.broken({"steps": [{"name": "n", "cmd": "--other-owner-ok status"}]}, "step 1 (n)")

    def test_skip_flags_refused(self):
        for cmd in ("speed 8 --force", "save probe-x --user-asked", "road --from 0,0 --to 1,1 --ignore-errors",
                    "status --other-owner-ok", ["run", "--days", "1", "--force=1"]):
            res = self.broken({"steps": [{"cmd": "status"}, {"cmd": cmd}]}, "refused in a scenario")
            self.assertIn("step 2", res["error"])

    def test_excluded_commands(self):
        self.broken({"steps": [{"cmd": "test other.json"}]}, "test is not run from a scenario")
        self.broken({"steps": [{"cmd": "log --tail 5"}]}, "use a log step")
        self.broken({"steps": [{"cmd": "pointer 0.5,0.5"}]}, "pointer is not run")
        self.broken({"steps": [{"cmd": "modhub publish my_mod_1 --public yes --changelog x"}]},
                    "modhub publish is not run")
        self.broken({"steps": [{"cmd": "modhub publish-clear --yes"}]}, "modhub publish-clear is not run")
        self.broken({"steps": [{"cmd": "vehicles --every 5"}]}, "--every needs --count")

    def test_coop_kill_and_close_all_refused(self):
        # a scenario runs unattended: it cannot loosen the checks (coop) or SIGKILL the game
        self.broken({"steps": [{"cmd": "coop start --reason x"}]}, "coop start is not run")
        self.broken({"steps": [{"cmd": "launch --new --coop --reason x"}]}, "--coop starts coop")
        self.broken({"steps": [{"cmd": "quit --kill"}]}, "--kill sends SIGKILL")
        self.broken({"steps": [{"cmd": "restart --load probe-x"}]}, "restart needs --no-kill")
        self.broken({"steps": [{"cmd": "window --close-all"}]}, "--close-all closes every window")
        for ok in ("coop end", "quit", "restart --load probe-x --no-kill", "launch --new"):
            self.assertTrue(T.validate({"steps": [{"cmd": ok}]}, tf3ctl.make_parser), ok)

    def test_a_broken_escape_in_a_path_is_a_broken_scenario(self):
        res = self.broken({"steps": [{"cmd": "status", "expect": {"path": '["a\\q"]', "op": "exists"}}]},
                          "cannot read the quoted key")
        self.assertEqual(res["exitCode"], 2)

    def test_expects_and_log_specs(self):
        st = lambda **e: {"steps": [{"cmd": "status", "expect": e}]}  # noqa: E731
        self.broken(st(path="a", op="equals", value=1), "op is one of")
        self.broken(st(path="a", op="eq"), "eq needs a value")
        self.broken(st(path="a..b", op="eq", value=1), "cannot read the path")
        self.broken(st(path=3, op="eq", value=1), "a path is a string")
        self.broken(st(path="a", op="exists", value=1), "exists takes value true or false")
        self.broken(st(path="a", op="len", value="3"), "len's value is a number")
        self.broken(st(path="a", op="len", value=3, cmp="eqq"), "len's cmp is one of")
        self.broken(st(path="a", op="eq", value=3, cmp="gt"), "cmp goes with op len only")
        self.broken(st(path="a", op="eq", value=3, vaule=1), "unknown keys in expect: vaule")
        self.broken({"steps": [{"cmd": "status", "expect": [1]}]}, "an expect is an object")
        self.broken({"steps": [{"cmd": "status", "expect": "ok"}]}, "expect is an object or a list")
        self.broken({"steps": [{"log": []}]}, "log is an object")
        self.broken({"steps": [{"log": {"patterns": "ERROR"}}]}, "log patterns is a list")
        self.broken({"steps": [{"log": {"patterns": []}}]}, "patterns is empty")
        self.broken({"steps": [{"log": {"ignore": ["("]}}]}, "log ignore '('")
        self.broken({"steps": [{"log": {"max": -1}}]}, "log max is a whole number")
        self.broken({"steps": [{"log": {"grep": "x"}}]}, "unknown keys in log: grep")
        self.broken({"steps": [{"log": {}, "expect": []}]}, "a log step takes no expect")

    def test_dry_run_checks_and_sends_nothing(self):
        fake = FakeMain({})
        code, res = self.run_test({"steps": [{"cmd": ["steps", 20]}, {"log": True}]}, fake, "--dry-run")
        self.assertEqual(code, 0, res)
        self.assertEqual(res["result"], "checked")
        self.assertEqual(res["steps"][0]["cmd"], ["steps", "20"], "numbers become words")
        self.assertEqual(res["steps"][1]["log"], {})
        self.assertEqual(fake.calls, [])

    def test_the_sample_scenario_is_valid(self):
        sc = T.load_scenario(os.path.join(ROOT, "examples", "test_scenario_sample.json"))
        steps = T.validate(sc, tf3ctl.make_parser)
        self.assertEqual([s.get("argv", ["(log)"])[0] for s in steps],
                         ["launch", "speed", "build", "steps", "status", "(log)"])


class RunTest(Base):
    SC = {"name": "three", "steps": [
        {"name": "a", "cmd": "status", "expect": [{"path": "state.date.year", "op": "ge", "value": 1900}]},
        {"name": "b", "cmd": ["saves"], "expect": {"path": "saves", "op": "len", "value": 2}},
        {"name": "c", "cmd": "info probe", "expect": {"path": "mods", "op": "contains", "value": "m"}},
    ]}

    def fake(self, n_saves=2, **kw):
        a = answers(status=(0, {"ok": True, "state": {"date": {"year": 1901}}}),
                    saves=(0, {"ok": True, "saves": list(range(n_saves))}),
                    info=(0, {"ok": True, "mods": ["m", "n"]}))
        a.update(answers(**kw))
        return FakeMain(a)

    def test_all_pass(self):
        fake = self.fake()
        code, res = self.run_test(self.SC, fake, owner="my-tests")
        self.assertEqual(code, 0, res)
        self.assertEqual((res["result"], res["ok"], res["passed"], res["failed"]), ("pass", True, 3, 0))
        self.assertEqual(res["name"], "three")
        self.assertEqual(fake.calls[0], ["--owner", "my-tests", "status"], "the test's owner on every step")
        self.assertEqual(fake.calls[2], ["--owner", "my-tests", "info", "probe"])
        s = res["steps"][1]
        self.assertEqual((s["index"], s["name"], s["status"], s["exit"]), (2, "b", "pass", 0))
        self.assertEqual(s["answer"], {"ok": True, "saves": [0, 1]})
        self.assertEqual(s["checks"], [{"path": "saves", "op": "len", "value": 2, "cmp": "eq", "actual": 2,
                                        "pass": True}])
        self.assertIsInstance(s["durationSec"], float)
        self.assertIn("durationSec", res)

    def test_other_owner_ok_from_the_command_line_goes_to_every_step(self):
        fake = self.fake()
        ns = tf3ctl.make_parser().parse_args(["--owner", "t", "--other-owner-ok", "test", self.scenario(self.SC)])
        with contextlib.redirect_stdout(io.StringIO()):
            code = T.cmd_test(ns, fake, tf3ctl.make_parser, lambda: self.log, tf3ctl.show)
        self.assertEqual(code, 0)
        self.assertEqual(fake.calls[0], ["--owner", "t", "--other-owner-ok", "status"])
        self.assertTrue(all("--other-owner-ok" in c for c in fake.calls))

    def test_ctrl_c_between_commands_still_prints_the_steps(self):
        fake = self.fake()
        real = fake.__call__

        def interrupt_on_saves(argv):
            if "saves" in argv:
                raise KeyboardInterrupt
            return real(argv)
        code, res = self.run_test(self.SC, interrupt_on_saves)
        self.assertEqual(code, 130, res)
        self.assertEqual([s["status"] for s in res["steps"]], ["pass", "interrupted", "skipped"])

    def test_a_failed_check_stops_and_exits_5(self):
        fake = self.fake(n_saves=3)
        code, res = self.run_test(self.SC, fake)
        self.assertEqual(code, 5, res)
        self.assertEqual((res["result"], res["ok"], res["passed"], res["failed"], res["skipped"]),
                         ("fail", False, 1, 1, 1))
        self.assertEqual([s["status"] for s in res["steps"]], ["pass", "fail", "skipped"])
        self.assertEqual(res["steps"][1]["checks"][0]["actual"], 3)
        self.assertIn("1 of 1 checks failed", res["steps"][1]["why"])
        self.assertEqual(len(fake.calls), 2, "the step after the failed one is not run")

    def test_continue_on_fail(self):
        sc = dict(self.SC, continueOnFail=True)
        fake = self.fake(n_saves=3, info=(1, {"ok": False, "error": "no save named probe"}))
        code, res = self.run_test(sc, fake)
        self.assertEqual(code, 5, res)
        self.assertEqual([s["status"] for s in res["steps"]], ["pass", "fail", "fail"])
        self.assertEqual(len(fake.calls), 3)
        self.assertIn("exit code 1, expected 0", res["steps"][2]["why"])
        # one step's continueOnFail over the scenario's
        sc = {"steps": [dict(self.SC["steps"][1], continueOnFail=True), self.SC["steps"][2]]}
        code, res = self.run_test(sc, self.fake(n_saves=3))
        self.assertEqual([s["status"] for s in res["steps"]], ["fail", "pass"])
        sc = dict(self.SC, continueOnFail=True)
        sc["steps"] = [dict(self.SC["steps"][1], continueOnFail=False), self.SC["steps"][2]]
        code, res = self.run_test(sc, self.fake(n_saves=3))
        self.assertEqual([s["status"] for s in res["steps"]], ["fail", "skipped"])

    def test_an_expected_error_exit_passes(self):
        sc = {"steps": [{"cmd": "info missing", "exit": 1,
                         "expect": {"path": "error", "op": "contains", "value": "no save named"}}]}
        code, res = self.run_test(sc, self.fake(info=(1, {"ok": False, "error": "no save named missing"})))
        self.assertEqual(code, 0, res)
        code, res = self.run_test(sc, self.fake())
        self.assertEqual(code, 5, "exit 0 where 1 was expected")
        self.assertIn("exit code 0, expected 1", res["steps"][0]["why"])

    def test_no_answer_is_an_error_exit_2(self):
        for code_in in (2, 3):
            fake = self.fake(saves=(code_in, {"ok": False, "gameState": "main_menu"}))
            code, res = self.run_test(self.SC, fake)
            self.assertEqual(code, 2, res)
            self.assertEqual(res["result"], "error")
            self.assertEqual([s["status"] for s in res["steps"]], ["pass", "error", "skipped"])
        # an error with continueOnFail still ends in 2, over a later fail
        sc = dict(self.SC, continueOnFail=True)
        code, res = self.run_test(sc, self.fake(saves=(2, None), info=(0, {"mods": []})))
        self.assertEqual(code, 2)
        self.assertEqual([s["status"] for s in res["steps"]], ["pass", "error", "fail"])
        self.assertEqual(res["steps"][1]["checks"][0]["why"], "no answer")

    def test_refused_4_is_a_fail(self):
        code, res = self.run_test(self.SC, self.fake(saves=(4, {"ok": False, "refused": "owner"})))
        self.assertEqual(code, 5)
        self.assertEqual(res["steps"][1]["exit"], 4)

    def test_interrupted(self):
        code, res = self.run_test(self.SC, self.fake(saves=(130, None)))
        self.assertEqual(code, 130)
        self.assertEqual(res["result"], "interrupted")
        self.assertEqual([s["status"] for s in res["steps"]], ["pass", "interrupted", "skipped"])

    def test_answers_text_lines_and_cuts(self):
        sc = {"steps": [{"cmd": "vehicles --every 1 --count 2", "expect": {"path": "[1].n", "op": "eq", "value": 2}},
                        {"cmd": "status", "expect": {"path": "ok", "op": "eq", "value": True}}],
              "continueOnFail": True}
        fake = self.fake(vehicles=(0, '{"n": 1}\n{"n": 2}'), status=(0, "not json"))
        code, res = self.run_test(sc, fake, "--excerpt", "10")
        self.assertEqual(code, 5, res)
        self.assertEqual(res["steps"][0]["status"], "pass", "JSON lines read as a list")
        self.assertEqual(res["steps"][0]["answer"], '[{"n": 1},...', "cut at --excerpt")
        self.assertEqual(res["steps"][1]["stdout"], "not json\n")
        self.assertEqual(res["steps"][1]["checks"][0]["why"], "no answer")

    def test_stderr_is_kept(self):
        def main(argv):
            print("note: x", file=sys.stderr)
            print("{}")
            return 0
        code, res = self.run_test({"steps": [{"cmd": "status"}]}, main)
        self.assertEqual(res["steps"][0]["stderr"], "note: x\n")


class LogStepTest(Base):
    def test_only_the_log_since_the_start(self):
        write(self.log, OK_LINE + ERR + LUA_ERR)  # errors from before the scenario: not looked at
        sc = {"steps": [{"cmd": "status"}, {"log": {}}]}
        code, res = self.run_test(sc, FakeMain(answers(status=(0, {}, OK_LINE + BENIGN)), log=self.log))
        self.assertEqual(code, 0, res)
        self.assertEqual(res["steps"][1]["matches"], 0)
        self.assertEqual(res["steps"][1]["entriesRead"], 2, "the OK line and the benign traceback entry")
        code, res = self.run_test(sc, FakeMain(answers(status=(0, {}, OK_LINE + ERR + LUA_ERR)), log=self.log))
        self.assertEqual(code, 5, res)
        lg = res["steps"][1]
        self.assertEqual((lg["status"], lg["matches"]), ("fail", 2))
        self.assertIn("something broke", lg["shown"][0])
        self.assertIn("attempt to index local", lg["shown"][1], "the entry with its indented lines")
        self.assertIn("2 error entries in the log (at most 0)", lg["why"])

    def test_patterns_ignore_require_max(self):
        sc = lambda spec: {"steps": [{"cmd": "status"}, {"log": spec}]}  # noqa: E731
        fake = lambda: FakeMain(answers(status=(0, {}, OK_LINE + ERR + LUA_ERR)), log=self.log)  # noqa: E731
        self.assertEqual(self.run_test(sc({"ignore": ["something broke", "index local"]}), fake())[0], 0)
        self.assertEqual(self.run_test(sc({"max": 2}), fake())[0], 0)
        self.assertEqual(self.run_test(sc({"max": 1}), fake())[0], 5)
        code, res = self.run_test(sc({"patterns": ["loaded"]}), fake())
        self.assertEqual((code, res["steps"][1]["matches"]), (5, 1))
        code, res = self.run_test(sc({"max": 9, "require": ["loaded", "never written"]}), fake())
        self.assertEqual(code, 5)
        self.assertEqual(res["steps"][1]["missing"], ["never written"])
        self.assertIn("not in the log: never written", res["steps"][1]["why"])

    def test_several_log_steps_see_everything_since_the_start(self):
        sc = {"continueOnFail": True,
              "steps": [{"cmd": "status"}, {"log": {}}, {"cmd": "saves"}, {"log": {}}]}
        fake = FakeMain(answers(status=(0, {}, ERR), saves=(0, {}, OK_LINE)), log=self.log)
        code, res = self.run_test(sc, fake)
        self.assertEqual([s["status"] for s in res["steps"]], ["pass", "fail", "pass", "fail"])

    def test_a_new_log_from_a_restart_is_read_from_its_start(self):
        write(self.log, OK_LINE * 50)

        def main(argv):
            if "restart" in argv:  # the game writes a new, shorter log
                os.remove(self.log)
                write(self.log, "[2026-11-23 01:00:00Z - MESSAGE  - Main Thread      - Main           ]+ new\n"
                      + ERR)
            print("{}")
            return 0
        sc = {"steps": [{"cmd": "restart --new --size tiny --no-kill"}, {"log": {}}]}
        code, res = self.run_test(sc, main)
        self.assertEqual(code, 5, res)
        self.assertEqual(res["steps"][1]["matches"], 1)
        self.assertEqual(res["steps"][1]["newLogs"], 1)

    def test_no_log_at_the_start_then_one(self):
        def main(argv):
            write(self.log, ERR)
            print("{}")
            return 0
        code, res = self.run_test({"steps": [{"cmd": "launch --new"}, {"log": {}}]}, main)
        self.assertEqual(code, 5, res)
        self.assertEqual(res["steps"][1]["matches"], 1, "a log that appears is read from its start")

    def test_no_log_is_an_error(self):
        code, res = self.run_test({"steps": [{"log": {}}]}, FakeMain({}))
        self.assertEqual(code, 2, res)
        self.assertEqual(res["steps"][0]["status"], "error")
        self.assertIn("no game log", res["steps"][0]["why"])

    def test_a_line_being_written_waits_for_its_end(self):
        write(self.log, "")
        w = T.LogWatch(lambda: self.log)
        w.start()
        with open(self.log, "a", encoding="utf-8") as f:
            f.write(ERR[:20])
        w.scan()
        self.assertEqual(w.entries(), [])
        with open(self.log, "a", encoding="utf-8") as f:
            f.write(ERR[20:])
        w.scan()
        self.assertEqual(w.entries(), [ERR.rstrip("\n")])


class ScenarioOnFakeGameTest(unittest.TestCase):
    """The real tf3ctl.main runs each step against tests/fake_game.lua (the real content/remote.script.lua)."""

    @classmethod
    def setUpClass(cls):
        # test_tf3ctl's tearDownModule removes its folders (the configuration file, XDG_RUNTIME_DIR, the run's
        # temp folder) when the run moves on to the next module: this class makes its own, so it passes alone and
        # in the whole run
        os.makedirs(tempfile.gettempdir(), exist_ok=True)
        cls.root = tempfile.mkdtemp()
        keys = ("TF3_REMOTE_DIR", "TF3_LOG", "TF3CTL_CONFIG", "XDG_RUNTIME_DIR", "XDG_STATE_HOME")
        cls.old = {k: os.environ.get(k) for k in keys}
        cfg = os.path.join(cls.root, "config.json")
        with open(cfg, "w", encoding="utf-8") as f:
            json.dump(base.CONFIGURED, f)
        os.environ["TF3CTL_CONFIG"] = cfg
        for k, sub in (("XDG_RUNTIME_DIR", "runtime"), ("XDG_STATE_HOME", "state")):
            os.makedirs(os.path.join(cls.root, sub))
            os.environ[k] = os.path.join(cls.root, sub)
        cls.dir = os.path.join(cls.root, "recordings")
        cls.game = subprocess.Popen(["luajit", os.path.join(ROOT, "tests", "fake_game.lua"), cls.root, "120"],
                                    stderr=subprocess.PIPE, text=True)
        deadline = time.time() + 10
        while not glob.glob(os.path.join(cls.dir, "remote_probe__cmd_*.lua")):
            if time.time() > deadline:
                raise RuntimeError("the fake game did not start")
            time.sleep(0.05)
        os.environ["TF3_REMOTE_DIR"] = cls.dir
        cls.log = os.path.join(cls.root, "stdout.txt")
        write(cls.log, OK_LINE + ERR)  # an error from before the scenario
        os.environ["TF3_LOG"] = cls.log

    @classmethod
    def tearDownClass(cls):
        cls.game.kill()
        cls.game.wait()
        cls.game.stderr.close()
        for k, v in cls.old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        shutil.rmtree(cls.root, ignore_errors=True)

    def test_a_scenario_through_main(self):
        sc = {"name": "fake game", "steps": [
            {"cmd": "status", "expect": [{"path": "ok", "op": "eq", "value": True},
                                         {"path": "state.date.year", "op": "eq", "value": 1900}]},
            {"cmd": "saves", "expect": [{"path": "saves[0].saveName", "op": "eq", "value": "probe"},
                                        {"path": "saves", "op": "len", "value": 2}]},
            {"cmd": "info missing", "exit": 1, "expect": {"path": "error", "op": "contains", "value": "no save named"}},
            {"cmd": ["build", "--res", "road_bridge_ramp::/road_bridge_ramp/ramp.con", "--at", "300,40", "--dry-run"],
             "expect": [{"path": "dryRun", "op": "eq", "value": True}, {"path": "checked", "op": "eq", "value": False}]},
            {"cmd": "steps 500 --dry-run"},
            {"log": {}},
        ]}
        path = os.path.join(self.root, "sc.json")
        write(path, json.dumps(sc))
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = tf3ctl.main(["--owner", "scenario-test", "test", path])
        res = json.loads(out.getvalue())
        self.assertEqual(code, 0, json.dumps(res, indent=1))
        self.assertEqual([s["status"] for s in res["steps"]], ["pass"] * 6)
        self.assertEqual(res["steps"][2]["exit"], 1)
        # a failing check through main: exit 5
        sc["steps"] = [{"cmd": "status", "expect": {"path": "state.date.year", "op": "gt", "value": 1900}}]
        write(path, json.dumps(sc))
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = tf3ctl.main(["--owner", "scenario-test", "test", path])
        self.assertEqual(code, 5, out.getvalue())

    def test_main_refuses_a_skip_flag(self):
        path = os.path.join(self.root, "sc2.json")
        write(path, json.dumps({"steps": [{"cmd": "speed 16 --force"}]}))
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = tf3ctl.main(["test", path])
        self.assertEqual(code, 2)
        self.assertIn("--force skips", json.loads(out.getvalue())["error"])


if __name__ == "__main__":
    unittest.main()
