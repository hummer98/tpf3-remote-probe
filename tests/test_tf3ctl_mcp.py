"""Tests for tools/tf3ctl_mcp.py (the MCP server).  python3 -m unittest discover -s tests

No game: the tool list is checked against the real tools/tf3ctl.py's parser (imported only, never run), and calls go
to a fake tf3ctl.py written here, which prints what it got and exits with the code it is told.
"""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
import unittest.mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TF3CTL = os.path.join(ROOT, "tools", "tf3ctl.py")
SERVER = os.path.join(ROOT, "tools", "tf3ctl_mcp.py")

_spec = importlib.util.spec_from_file_location("tf3ctl_mcp", SERVER)
mcp = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(mcp)


def test_dir():
    """A folder for this test's files: as test_tf3ctl.py picks one (never /tmp unless asked)."""
    base = os.environ.get("TMPDIR")
    if base and (base.rstrip("/") == "/tmp" or base.startswith("/tmp/")):
        base = None
    base = os.path.join(os.environ.get("REMOTE_PROBE_TEST_TMP") or base or os.path.join(ROOT, "tests", ".tmp"),
                        "remote_probe_tests")
    os.makedirs(base, exist_ok=True)
    return tempfile.mkdtemp(prefix="mcp-", dir=base)


FAKE_TF3CTL = textwrap.dedent('''
    import argparse, json, sys, time

    def make_parser():
        p = argparse.ArgumentParser(allow_abbrev=False)
        p.add_argument("--owner")
        p.add_argument("--other-owner-ok", action="store_true")
        sub = p.add_subparsers(dest="cmd", required=True)
        sub.add_parser("status", help="read only: does the game answer")
        e = sub.add_parser("exit", help="exits with a code")
        e.add_argument("code", type=int)
        e.add_argument("--error")
        b = sub.add_parser("echo", help="prints its arguments")
        b.add_argument("name", nargs="?")
        b.add_argument("--at")
        b.add_argument("--add", action="append", default=[])
        b.add_argument("--dry-run", action="store_true")
        b.add_argument("--no-list", dest="list", action="store_false")
        b.add_argument("--speed", type=int, default=4)
        b.add_argument("--via", choices=("gui", "cmd"))
        g = b.add_mutually_exclusive_group()
        g.add_argument("--days", type=int)
        g.add_argument("--months", type=int)
        v = sub.add_parser("vehicles")
        v.add_argument("--every", type=float)
        v.add_argument("--count", type=int)
        s = sub.add_parser("sleep")
        s.add_argument("--timeout", type=float, default=600)
        s.add_argument("--seconds", type=float, default=0)
        sub.add_parser("log")
        po = sub.add_parser("pointer")
        po.add_argument("pos")
        mh = sub.add_parser("modhub")
        ms = mh.add_subparsers(dest="action", required=True)
        ms.add_parser("status")
        ms.add_parser("publish").add_argument("folder")
        ms.add_parser("publish-clear")
        return p

    def main():
        ns = make_parser().parse_args()
        if ns.cmd == "exit":
            if ns.error:
                print("error: " + ns.error, file=sys.stderr)
            print(json.dumps({"ok": ns.code == 0, "code": ns.code}))
            return ns.code
        if ns.cmd == "vehicles":
            for i in range(ns.count or 1):
                print(json.dumps({"ok": True, "sample": i + 1}))
            return 0
        if ns.cmd == "sleep":
            try:
                time.sleep(ns.seconds)
            except KeyboardInterrupt:
                return 130
            print(json.dumps({"ok": True}))
            return 0
        if ns.cmd == "log":
            sys.stdout.write("line one\\nline two\\n")
            return 0
        print(json.dumps({"ok": True, "argv": sys.argv[1:], "stdinClosed": sys.stdin.read() == "",
                          "ns": {k: v for k, v in vars(ns).items()}}))
        return 0

    if __name__ == "__main__":
        sys.exit(main())
''')


class RealParserTools(unittest.TestCase):
    """The tool list made from the real tf3ctl.py."""

    @classmethod
    def setUpClass(cls):
        cls.parser = mcp.load_parser(TF3CTL)
        cls.tools, cls.specs = mcp.build_tools(cls.parser)
        cls.names = [t["name"] for t in cls.tools]

    def test_names_unique_and_valid(self):
        self.assertEqual(len(self.names), len(set(self.names)))
        for n in self.names:
            self.assertRegex(n, mcp.TOOL_NAME_RE)
        self.assertGreater(len(self.names), 60)

    def test_excluded_commands_absent(self):
        for n in ("pointer", "modhub_publish", "modhub_publish_clear", "modhub"):
            self.assertNotIn(n, self.names)
        text = json.dumps(self.tools)
        self.assertNotIn("modhub_publish", text)  # nor named in a parent's list of actions

    def test_expected_tools_present(self):
        for n in ("status", "launch", "run", "load", "save", "quit", "build", "road", "stock_list", "stock_set",
                  "town", "town_develop", "company", "company_init", "line_create", "coop_start", "coop_end",
                  "modhub_status", "modhub_validate", "keep_log", "calendar_speed", "mod", "frame", "log"):
            self.assertIn(n, self.names)
        # a command whose actions are required is only its actions
        for n in ("stock", "line", "coop"):
            self.assertNotIn(n, self.names)

    def test_owner_is_not_a_tool_argument(self):
        for t in self.tools:
            self.assertNotIn("owner", t["inputSchema"]["properties"], t["name"])
            self.assertNotIn("other_owner_ok", t["inputSchema"]["properties"], t["name"])

    def test_schemas_are_objects(self):
        for t in self.tools:
            s = t["inputSchema"]
            self.assertEqual(s["type"], "object")
            self.assertFalse(s["additionalProperties"])
            for pn in s.get("required", []):
                self.assertIn(pn, s["properties"])
            for pn, ps in s["properties"].items():
                types = ps["type"] if isinstance(ps["type"], list) else [ps["type"]]
                for ty in types:
                    self.assertIn(ty, ("string", "integer", "number", "boolean", "array"), (t["name"], pn))
                self.assertTrue(ps.get("description"), (t["name"], pn))

    def test_schema_types(self):
        props = self.specs["launch"]["props"]
        self.assertEqual(props["new"]["type"], "boolean")
        self.assertEqual(props["add"], dict(props["add"], type="array"))
        self.assertEqual(props["year"]["type"], "integer")
        self.assertEqual(props["timeout"]["type"], "number")
        self.assertIn("required", self.tools[self.names.index("info")]["inputSchema"])
        self.assertEqual(self.specs["entities"]["props"]["kind"]["enum"][0], "town")

    def parse(self, name, arguments):
        argv = mcp.build_argv(self.specs[name], arguments)
        return argv, self.parser.parse_args(["--owner", "me"] + argv)

    def test_argv_round_trips_through_real_parser(self):
        argv, ns = self.parse("launch", {"new": True, "add": ["a_mod", "b_mod"], "size": "tiny", "year": 1900,
                                         "param": ["a_mod:x=2"]})
        self.assertEqual((ns.cmd, ns.new, ns.add, ns.size, ns.year, ns.param, ns.owner),
                         ("launch", True, ["a_mod", "b_mod"], "tiny", 1900, ["a_mod:x=2"], "me"))
        _, ns = self.parse("town_develop", {"at": "-100,50", "count": 3, "dry_run": True})
        self.assertEqual((ns.cmd, ns.town_action, ns.grow_at, ns.grow_count, ns.grow_dry_run),
                         ("town", "develop", "-100,50", 3, True))
        _, ns = self.parse("stock_set", {"entity": 12, "stock": -1, "amount": 5, "cargo": "COAL"})
        self.assertEqual((ns.action, ns.entity, ns.stock, ns.amount), ("set", 12, -1, 5))
        _, ns = self.parse("info", {"save": "-odd name"})
        self.assertEqual(ns.save, "-odd name")
        _, ns = self.parse("mod", {"mod_id": "my_mod", "mod_command": "hello", "mod_json": '{"a": 1}',
                                   "read_only": True})
        self.assertEqual((ns.mod_id, ns.mod_command, ns.mod_json, ns.read_only),
                         ("my_mod", "hello", '{"a": 1}', True))
        _, ns = self.parse("calendar_speed", {"factor": 0.25})
        self.assertEqual(ns.factor, 0.25)
        _, ns = self.parse("parcels", {"edge": 9010, "no_list": True})
        self.assertIs(ns.list, False)
        _, ns = self.parse("run", {"months": 2, "speed": 4.0})
        self.assertEqual((ns.months, ns.speed), (2, 4))

    def test_option_alone_or_with_a_value(self):
        """--mu (nargs='?' with a const): true sends the option alone, a string sends its value, false leaves it."""
        self.assertEqual(self.specs["models"]["props"]["mu"]["type"], ["boolean", "string"])
        argv, ns = self.parse("models", {"mu": True})
        self.assertEqual((argv[-1], ns.mu), ("--mu", True))
        _, ns = self.parse("models", {"mu": "shinkansen"})
        self.assertEqual(ns.mu, "shinkansen")
        argv, ns = self.parse("models", {"mu": False})
        self.assertEqual((argv, ns.mu), (["models"], None))
        with self.assertRaises(mcp.ArgError):
            mcp.build_argv(self.specs["models"], {"mu": 3})

    def test_upper_cased_choices_take_any_case(self):
        _, ns = self.parse("models", {"carrier": "water"})
        self.assertEqual(ns.carrier, "WATER")
        _, ns = self.parse("models", {"carrier": "WATER"})
        self.assertEqual(ns.carrier, "WATER")
        with self.assertRaises(mcp.ArgError):
            mcp.build_argv(self.specs["models"], {"carrier": "boat"})

    def test_every_tool_with_no_arguments_builds(self):
        """A tool whose arguments are all optional gives a command line the real parser takes."""
        for name, spec in self.specs.items():
            if self.tools[self.names.index(name)]["inputSchema"].get("required"):
                continue
            argv = mcp.build_argv(spec, {})
            try:
                with contextlib.redirect_stderr(io.StringIO()):
                    self.parser.parse_args(argv)
            except SystemExit:  # a required mutually exclusive group (run: days / months / until) is the tool's to say
                p = self.parser
                for word in spec["path"]:
                    p = mcp._subparsers(p).choices[word]
                groups = [g for g in p._mutually_exclusive_groups if g.required]
                self.assertTrue(groups, name)

    def test_wait_follows_the_commands_timeouts(self):
        self.assertEqual(mcp.wait_seconds(self.specs["launch"], {}), 900 + 240 + mcp.WAIT_MARGIN_SEC)
        self.assertEqual(mcp.wait_seconds(self.specs["restart"], {"timeout": 100}),
                         100 + 240 + 60 + mcp.WAIT_MARGIN_SEC)
        self.assertEqual(mcp.wait_seconds(self.specs["run"], {}), 3600 + mcp.WAIT_MARGIN_SEC)
        self.assertIsNone(mcp.wait_seconds(self.specs["status"], {}))


class BuildArgv(unittest.TestCase):
    def setUp(self):
        d = test_dir()
        self.addCleanup(shutil.rmtree, d, True)
        path = os.path.join(d, "tf3ctl.py")
        with open(path, "w") as f:
            f.write(FAKE_TF3CTL)
        _, self.specs = mcp.build_tools(mcp.load_parser(path))

    def test_unknown_and_wrong_types(self):
        for args in ({"nope": 1}, {"dry_run": "yes"}, {"speed": "fast"}, {"speed": True}, {"speed": 1.5},
                     {"via": "air"}, {"add": [{"x": 1}]}):
            with self.assertRaises(mcp.ArgError, msg=args):
                mcp.build_argv(self.specs["echo"], args)
        with self.assertRaises(mcp.ArgError):
            mcp.build_argv(self.specs["echo"], ["not", "an", "object"])
        with self.assertRaises(mcp.ArgError):
            mcp.build_argv(self.specs["exit"], {})  # required positional

    def test_every_needs_count(self):
        with self.assertRaises(mcp.ArgError):
            mcp.build_argv(self.specs["vehicles"], {"every": 1})
        self.assertEqual(mcp.build_argv(self.specs["vehicles"], {"every": 1, "count": 2}),
                         ["vehicles", "--every=1", "--count=2"])

    def test_shapes(self):
        self.assertEqual(mcp.build_argv(self.specs["echo"], None), ["echo"])
        self.assertEqual(mcp.build_argv(self.specs["echo"], {"add": "one", "dry_run": False, "no_list": True}),
                         ["echo", "--add=one", "--no-list"])
        self.assertEqual(mcp.build_argv(self.specs["echo"], {"name": "-x", "at": "-1,2"}),
                         ["echo", "--at=-1,2", "--", "-x"])
        self.assertEqual(mcp.build_argv(self.specs["echo"], {"name": 7}), ["echo", "7"])

    def test_wait_ends_with_sigint(self):
        d = test_dir()
        self.addCleanup(shutil.rmtree, d, True)
        path = os.path.join(d, "tf3ctl.py")
        with open(path, "w") as f:
            f.write(FAKE_TF3CTL)
        with unittest.mock.patch.object(mcp, "WAIT_MARGIN_SEC", 0.5):
            s = mcp.Server(path)
            res = s.call_tool("sleep", {"timeout": 0, "seconds": 30})
        body = json.loads(res["content"][0]["text"])
        self.assertTrue(res["isError"])
        self.assertIn(body["exitCode"], (130, -2))
        self.assertIn("stopped", body["stderr"])


class StdioServer(unittest.TestCase):
    """The server as a client starts it: a process, JSON-RPC lines on stdin and stdout."""

    def setUp(self):
        d = test_dir()
        self.addCleanup(shutil.rmtree, d, True)
        self.fake = os.path.join(d, "tf3ctl.py")
        with open(self.fake, "w") as f:
            f.write(FAKE_TF3CTL)

    def talk(self, lines, extra=()):
        env = dict(os.environ)
        env.pop("TF3CTL_OWNER", None)
        p = subprocess.run([sys.executable, SERVER, "--tf3ctl", self.fake] + list(extra),
                           input="".join(l + "\n" for l in lines).encode(), stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, timeout=60, env=env)
        self.assertEqual(p.returncode, 0, p.stderr)
        return [json.loads(l) for l in p.stdout.decode().splitlines()]

    @staticmethod
    def req(mid, method, params=None):
        m = {"jsonrpc": "2.0", "id": mid, "method": method}
        if params is not None:
            m["params"] = params
        return json.dumps(m)

    def call(self, mid, name, arguments=None):
        return self.req(mid, "tools/call", {"name": name, "arguments": arguments or {}})

    def test_initialize_list_call(self):
        out = self.talk([
            self.req(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                       "clientInfo": {"name": "test", "version": "0"}}),
            json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}),
            self.req(2, "tools/list"),
            self.call(3, "echo", {"name": "probe-1", "add": ["a", "b"], "dry_run": True}),
            self.req(4, "ping"),
        ], extra=["--owner", "tester"])
        self.assertEqual([m["id"] for m in out], [1, 2, 3, 4])  # nothing for the notification
        init = out[0]["result"]
        self.assertEqual(init["protocolVersion"], "2025-06-18")
        self.assertIn("tools", init["capabilities"])
        self.assertEqual(init["serverInfo"]["name"], "tf3ctl")
        names = [t["name"] for t in out[1]["result"]["tools"]]
        self.assertEqual(sorted(names), ["echo", "exit", "log", "modhub_status", "sleep", "status", "vehicles"])
        res = out[2]["result"]
        self.assertFalse(res["isError"])
        body = json.loads(res["content"][0]["text"])
        self.assertEqual(body["exitCode"], 0)
        self.assertEqual(body["answer"]["argv"],
                         ["--owner", "tester", "echo", "--add=a", "--add=b", "--dry-run", "probe-1"])
        self.assertTrue(body["answer"]["stdinClosed"])
        self.assertEqual(out[3]["result"], {})

    def test_unknown_protocol_version_gets_the_newest(self):
        out = self.talk([self.req(1, "initialize", {"protocolVersion": "1999-01-01"})])
        self.assertEqual(out[0]["result"]["protocolVersion"], mcp.PROTOCOL_VERSIONS[0])

    def test_exit_codes_copied(self):
        lines = [self.call(c, "exit", {"code": c, "error": "why %d" % c}) for c in (0, 1, 2, 3, 4)]
        out = self.talk(lines)
        for c, m in zip((0, 1, 2, 3, 4), out):
            body = json.loads(m["result"]["content"][0]["text"])
            self.assertEqual(body["exitCode"], c)
            self.assertEqual(body["meaning"], mcp.EXIT_MEANING[c])
            self.assertEqual(m["result"]["isError"], c != 0)
            self.assertEqual(body["answer"]["code"], c)
            self.assertIn("why %d" % c, body["stderr"])

    def test_no_owner_sends_none(self):
        out = self.talk([self.call(1, "echo")])
        body = json.loads(out[0]["result"]["content"][0]["text"])
        self.assertEqual(body["answer"]["argv"], ["echo"])

    def test_owner_from_environment(self):
        env = dict(os.environ, TF3CTL_OWNER="from-env")
        p = subprocess.run([sys.executable, SERVER, "--tf3ctl", self.fake], input=(self.call(1, "echo") + "\n")
                           .encode(), stdout=subprocess.PIPE, timeout=60, env=env)
        body = json.loads(json.loads(p.stdout)["result"]["content"][0]["text"])
        self.assertEqual(body["answer"]["argv"][:2], ["--owner", "from-env"])

    def test_lines_and_text_output(self):
        out = self.talk([self.call(1, "vehicles", {"every": 0.5, "count": 3}), self.call(2, "log")])
        body = json.loads(out[0]["result"]["content"][0]["text"])
        self.assertEqual([a["sample"] for a in body["answers"]], [1, 2, 3])
        body = json.loads(out[1]["result"]["content"][0]["text"])
        self.assertEqual(body["stdout"], "line one\nline two\n")

    def test_excluded_and_unknown_tools(self):
        out = self.talk([self.call(1, "pointer", {"pos": "0.5,0.5"}), self.call(2, "modhub_publish", {"folder": "x"}),
                         self.call(3, "modhub_publish_clear"), self.call(4, "no_such_tool")])
        for m in out:
            self.assertEqual(m["error"]["code"], -32602)

    def test_bad_arguments_are_a_tool_error(self):
        out = self.talk([self.call(1, "echo", {"speed": "fast"}), self.call(2, "vehicles", {"every": 1})])
        for m in out:
            self.assertTrue(m["result"]["isError"])
            self.assertTrue(m["result"]["content"][0]["text"].startswith("error: "))

    def test_broken_messages(self):
        out = self.talk([
            "{not json",
            "",
            json.dumps([]),
            json.dumps(5),
            json.dumps({"jsonrpc": "1.0", "id": 7, "method": "ping"}),
            json.dumps({"jsonrpc": "2.0", "id": 8}),
            json.dumps({"jsonrpc": "2.0", "id": 9, "result": {}}),  # a response: no answer
            self.req(10, "resources/list"),
            self.req(11, "tools/call", {"arguments": {}}),
            self.req(12, "tools/call", ["x"]),
            json.dumps([json.loads(self.req(13, "ping")), {"jsonrpc": "2.0", "method": "notifications/x"}]),
            self.req(14, "ping"),  # still serving
        ])
        codes = [(m.get("id") if isinstance(m, dict) else "batch",
                  m["error"]["code"] if isinstance(m, dict) and "error" in m else None) for m in out]
        self.assertEqual(codes, [(None, -32700), (None, -32600), (None, -32600), (7, -32600), (8, -32600),
                                 (10, -32601), (11, -32602), (12, -32602), ("batch", None), (14, None)])
        self.assertEqual(out[8], [{"jsonrpc": "2.0", "id": 13, "result": {}}])

    def test_missing_tf3ctl_exits_2(self):
        p = subprocess.run([sys.executable, SERVER, "--tf3ctl", self.fake + ".missing"], input=b"",
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        self.assertEqual(p.returncode, 2)
        self.assertEqual(p.stdout, b"")
        self.assertIn(b"cannot read the commands", p.stderr)

    def test_real_tf3ctl_lists_without_running_it(self):
        p = subprocess.run([sys.executable, SERVER], input=(self.req(1, "tools/list") + "\n").encode(),
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        names = [t["name"] for t in json.loads(p.stdout)["result"]["tools"]]
        self.assertIn("launch", names)
        self.assertNotIn("pointer", names)


if __name__ == "__main__":
    unittest.main()
