#!/usr/bin/env python3
"""An MCP server (Model Context Protocol, stdio) that offers tf3ctl.py's commands as tools.

A thin wrapper: every tool runs one tf3ctl.py command in a process of its own and returns what it printed (the JSON
answer), its exit code and its stderr. Nothing is added to the commands: the tool list is read from tf3ctl.py's own
argument parser (make_parser), and tf3ctl's own checks (owner, test saves, coop, the configuration file) apply as
on the command line. Standard library only, Python 3.8+: no pip install.

  python3 tools/tf3ctl_mcp.py [--owner NAME] [--tf3ctl PATH] [--python EXE]

--owner (else $TF3CTL_OWNER) is sent with every command. The protocol is JSON-RPC 2.0, one message per line on
stdin and stdout; the server's own notes go to stderr. Calls run one at a time, as tf3ctl's lock wants anyway.

Left out (EXCLUDED): pointer (moves this machine's X11 pointer) and modhub publish / publish-clear (an upload to
mod.io, or clearing the mark of a failed one, is a person's step).
"""
import argparse
import importlib.util
import json
import os
import re
import shlex
import signal
import subprocess
import sys

SERVER_NAME = "tf3ctl"
PROTOCOL_VERSIONS = ("2025-06-18", "2025-03-26", "2024-11-05")  # newest first: the answer when the client's is unknown
TOOL_NAME_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")

# command paths not offered, with why (the tool list says nothing of them; a call is an unknown tool)
EXCLUDED = {
    ("pointer",): "moves the X11 pointer of the machine the game runs on (needs the configuration file's pointer "
                  "switch); for screenshots made by hand",
    ("modhub", "publish"): "uploads to mod.io: a person runs it",
    ("modhub", "publish-clear"): "clears the mark a failed upload left, after a person checked mod.io",
}
# command paths offered with a note at the front of their description
MARKED = {
    ("frame",): "Linux only, and only on the machine the game runs on (it reads Steam's background recording); the "
                "image is written there, at --out.",
    ("log",): "Prints the log's lines as text, not JSON (stdout below).",
}
EXIT_MEANING = {
    0: "ok",
    1: "the game answered with an error (read error)",
    2: "no answer, a tool error, or a configuration file that cannot be read (the reason is on stderr)",
    3: "the game cannot answer where it is (menu, loading, closed): read gameState",
    4: "refused, nothing was sent (read refused); do not retry with a flag that skips the check",
    5: "tf3ctl test: a step of the scenario failed (read steps)",
    130: "interrupted",
}
WAIT_MARGIN_SEC = 240  # past the command's own --timeout values, and its fixed waits (pickup 30 s, a load's ack
#                         90 s) that they leave out: tf3ctl gives up first and says why
STOP_GRACE_SEC = 10  # after SIGINT at the end of the wait: tf3ctl lets its lock go and exits 130

INSTRUCTIONS = (
    "Each tool runs one tf3ctl.py command of Remote Probe (a Transport Fever 3 test harness) and returns its JSON "
    "answer, exit code and stderr. Read AGENTS.md first. Ask the person before the first command that changes the "
    "game; use test saves only (run saves first and save under a new name of your own); no flags that skip a check "
    "(force, user_asked, ignore_errors) unless the person asked. Exit codes: 0 ok, 1 the game answered an error, "
    "2 no answer or tool error, 3 the game cannot answer where it is (read gameState), 4 refused (read refused). "
    "One call at a time."
)


class ArgError(Exception):
    """A tool call's arguments that tf3ctl would not get right: the caller is told, nothing runs."""


def default_tf3ctl():
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "tf3ctl.py")


def load_parser(path):
    """tf3ctl.py's argument parser, from the file itself (imported under a name of its own; importing it runs
    nothing but definitions)."""
    spec = importlib.util.spec_from_file_location("tf3ctl_for_mcp", path)
    if spec is None or spec.loader is None:
        raise OSError("cannot import " + path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.make_parser()


def server_version(path):
    """X.Y.Z from mod.json's revision next to tools/ (X*10000+Y*100+Z), else 0.0.0."""
    try:
        with open(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(path))), "mod.json"),
                  encoding="utf-8") as f:
            rev = int(json.load(f)["revision"])
        return "%d.%d.%d" % (rev // 10000, rev // 100 % 100, rev % 100)
    except (OSError, ValueError, KeyError, TypeError):
        return "0.0.0"


def _subparsers(parser):
    for a in parser._actions:
        if isinstance(a, argparse._SubParsersAction):
            return a
    return None


def _own_actions(parser):
    return [a for a in parser._actions
            if not isinstance(a, (argparse._SubParsersAction, argparse._HelpAction))
            and a.help != argparse.SUPPRESS]


def _prop_name(action):
    if action.option_strings:
        longs = [s for s in action.option_strings if s.startswith("--")] or action.option_strings
        return max(longs, key=len).lstrip("-").replace("-", "_")
    return action.dest.replace("-", "_")


def _help_text(parser, action):
    if not action.help:
        return ""
    try:
        return parser._get_formatter()._expand_help(action)
    except (TypeError, ValueError, KeyError):
        return action.help


def _scalar(action):
    if action.type is int:
        s = {"type": "integer"}
    elif action.type is float:
        s = {"type": "number"}
    else:
        s = {"type": "string"}
    if action.choices is not None:
        s["enum"] = list(action.choices)
        if action.type is str.upper:  # tf3ctl takes any case (--carrier road)
            s["enum"] += [c.lower() for c in action.choices if c.lower() != c]
    return s


def _kind(action):
    if isinstance(action, (argparse._StoreTrueAction, argparse._StoreFalseAction, argparse._StoreConstAction)):
        return "flag"
    if isinstance(action, argparse._AppendAction):
        return "list"
    if isinstance(action, argparse._CountAction):
        return "count"
    if action.option_strings and action.nargs == "?" and action.const is not None:
        return "flag_or_value"  # --mu alone (all), or --mu=NAME
    if action.nargs not in (None, "?"):
        raise ValueError("tf3ctl_mcp does not know nargs=%r (%s)" % (action.nargs, action.dest))
    return "value"


def _schema(parser, action):
    kind = _kind(action)
    if kind == "flag":
        s = {"type": "boolean"}
    elif kind == "count":
        s = {"type": "integer"}
    elif kind == "list":
        s = {"type": "array", "items": _scalar(action)}
    elif kind == "flag_or_value":
        s = {"type": ["boolean", "string"]}
    else:
        s = _scalar(action)
    words = []
    if action.option_strings:
        words.append(max(action.option_strings, key=len) + (" " + action.metavar if action.metavar else ""))
    else:
        words.append(action.metavar or action.dest.upper())
    text = _help_text(parser, action)
    if text:
        words.append(text)
    d = action.default
    if kind != "flag" and d not in (None, [], argparse.SUPPRESS) and "default" not in text:
        words.append("(default %s)" % d)
    if kind == "flag_or_value":
        words.append("(true: the option alone)")
    s["description"] = words[0] + ("" if len(words) == 1 else (" - " if text else " ") + " ".join(words[1:]))
    return s


def _group_notes(parser):
    notes = []
    for g in parser._mutually_exclusive_groups:
        names = [_prop_name(a) for a in g._group_actions if a.help != argparse.SUPPRESS]
        if len(names) > 1:
            notes.append(("Exactly one of: " if g.required else "At most one of: ") + ", ".join(names) + ".")
    return notes


def build_tools(parser):
    """The tools of tf3ctl's parser: one per command, and per action of a command with actions (stock list, stock
    set, ...). A command whose action is optional (town, company) is a tool too, with its own options only.
    Returns (tools in order, {name: spec})."""
    tools, specs = [], {}

    def walk(p, path, help_text):
        sub = _subparsers(p)
        if path and tuple(path) not in EXCLUDED and (sub is None or not sub.required):
            emit(p, path, help_text, sub)
        if sub is None:
            return
        helps = {ca.dest: ca.help for ca in sub._choices_actions}
        for name, child in sub.choices.items():
            walk(child, path + [name], helps.get(name) or "")

    def emit(p, path, help_text, sub):
        name = "_".join(w.replace("-", "_") for w in path)
        if not TOOL_NAME_RE.match(name) or name in specs:
            raise ValueError("tool name %r is not usable or not unique" % name)
        actions = _own_actions(p)
        props, required, order = {}, [], []
        for a in actions:
            pn = _prop_name(a)
            if pn in props:
                raise ValueError("%s: two options named %s" % (name, pn))
            props[pn] = _schema(p, a)
            if (not a.option_strings and a.nargs is None) or (a.option_strings and a.required):
                required.append(pn)
            order.append((pn, a))
        words = []
        if tuple(path) in MARKED:
            words.append(MARKED[tuple(path)])
        if help_text:
            words.append(help_text[0].upper() + help_text[1:] + ("" if help_text.endswith(".") else "."))
        if p.description and path:
            words.append(p.description)
        words.extend(_group_notes(p))
        if sub is not None:
            words.append("Its actions are tools of their own: " + ", ".join(
                name + "_" + c.replace("-", "_") for c in sub.choices if tuple(path) + (c,) not in EXCLUDED) + ".")
        words.append("Runs: tf3ctl.py " + " ".join(path) + " ...")
        schema = {"type": "object", "properties": props, "additionalProperties": False}
        if required:
            schema["required"] = required
        tools.append({"name": name, "description": " ".join(words), "inputSchema": schema})
        specs[name] = {"path": list(path), "actions": order, "props": props}

    walk(parser, [], "")
    return tools, specs


def _as_scalar(pn, value, schema):
    t = schema["type"]
    if isinstance(value, bool) and t != "boolean":
        raise ArgError("%s: expected %s, got a boolean" % (pn, t))
    if t == "integer":
        if isinstance(value, float) and value.is_integer():
            value = int(value)
        if not isinstance(value, int):
            raise ArgError("%s: expected an integer" % pn)
    elif t == "number":
        if not isinstance(value, (int, float)):
            raise ArgError("%s: expected a number" % pn)
    elif t == "string":
        if isinstance(value, (int, float)):
            value = repr(value) if isinstance(value, float) else str(value)
        if not isinstance(value, str):
            raise ArgError("%s: expected a string" % pn)
    if "enum" in schema and value not in schema["enum"]:
        raise ArgError("%s: one of %s" % (pn, ", ".join(str(c) for c in schema["enum"])))
    return str(value)


def build_argv(spec, arguments):
    """tf3ctl's command line (after the global options) for a tool call's arguments. Options go as --name=value, so
    a value that starts with '-' (--at=-100,50) stays a value; positionals go last, after '--' when one starts with
    '-'."""
    if arguments is None:
        arguments = {}
    if not isinstance(arguments, dict):
        raise ArgError("arguments must be an object")
    unknown = sorted(set(arguments) - set(spec["props"]))
    if unknown:
        raise ArgError("unknown argument(s): " + ", ".join(unknown))
    if "every" in spec["props"] and arguments.get("every") is not None and arguments.get("count") is None:
        raise ArgError("give count with every: without it the command samples until it is interrupted and "
                       "never answers")
    opts, positionals, missed_optional = [], [], None
    for pn, a in spec["actions"]:
        schema = spec["props"][pn]
        value = arguments.get(pn)
        if not a.option_strings:
            if value is None:
                if a.nargs is None:
                    raise ArgError("missing argument: " + pn)
                missed_optional = missed_optional or pn
                continue
            if missed_optional:
                raise ArgError("%s needs %s before it" % (pn, missed_optional))
            positionals.append(_as_scalar(pn, value, schema))
            continue
        flag = max((s for s in a.option_strings if s.startswith("--")) or a.option_strings, key=len)
        kind = _kind(a)
        if value is None:
            if a.required:
                raise ArgError("missing argument: " + pn)
            continue
        if kind == "flag":
            if not isinstance(value, bool):
                raise ArgError("%s: expected a boolean" % pn)
            if value:
                opts.append(flag)
        elif kind == "flag_or_value":
            if value is True:
                opts.append(flag)
            elif isinstance(value, str):
                opts.append(flag + "=" + value)
            elif value is not False:
                raise ArgError("%s: expected a boolean or a string" % pn)
        elif kind == "count":
            n = _as_scalar(pn, value, schema)
            opts.extend([flag] * int(n))
        elif kind == "list":
            for item in (value if isinstance(value, list) else [value]):
                opts.append(flag + "=" + _as_scalar(pn, item, schema["items"]))
        else:
            opts.append(flag + "=" + _as_scalar(pn, value, schema))
    argv = list(spec["path"]) + opts
    if any(v.startswith("-") for v in positionals):
        argv.append("--")
    return argv + positionals


def wait_seconds(spec, arguments):
    """How long to wait for tf3ctl: the sum of the command's own --*timeout values (given or their defaults) and a
    margin, so tf3ctl gives up first and says why; None for a command without one (tf3ctl's own waits end it)."""
    total, seen = 0.0, False
    for pn, a in spec["actions"]:
        if pn.endswith("timeout") and spec["props"][pn]["type"] in ("number", "integer"):
            v = (arguments or {}).get(pn, a.default)
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                total += float(v)
                seen = True
    return total + WAIT_MARGIN_SEC if seen else None


def parse_stdout(text):
    """One JSON value (answer), else one per line (answers: --every), else the text itself."""
    s = text.strip()
    if not s:
        return {}
    try:
        return {"answer": json.loads(s)}
    except ValueError:
        pass
    try:
        return {"answers": [json.loads(line) for line in s.splitlines() if line.strip()]}
    except ValueError:
        return {"stdout": text}


def run_tf3ctl(cmd, timeout):
    """(exit code, stdout, stderr). The child gets no stdin (ours is the MCP stream). At the end of the wait it gets
    SIGINT (tf3ctl lets its lock go and exits 130), then a kill."""
    p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        if os.name == "nt":
            p.terminate()
        else:
            p.send_signal(signal.SIGINT)
        try:
            out, err = p.communicate(timeout=STOP_GRACE_SEC)
        except subprocess.TimeoutExpired:
            p.kill()
            out, err = p.communicate()
        err = (err or b"") + ("\n[tf3ctl_mcp] no end after %g s: stopped\n" % timeout).encode()
    return p.returncode, out.decode("utf-8", "replace"), err.decode("utf-8", "replace")


class Server:
    def __init__(self, tf3ctl, python=None, owner=None):
        self.tf3ctl = tf3ctl
        self.python = python or sys.executable
        self.owner = owner
        self.tools, self.specs = build_tools(load_parser(tf3ctl))
        self.version = server_version(tf3ctl)

    def command(self, argv):
        head = [self.python, self.tf3ctl]
        if self.owner:
            head += ["--owner", self.owner]
        return head + argv

    def call_tool(self, name, arguments):
        spec = self.specs[name]
        try:
            argv = build_argv(spec, arguments)
        except ArgError as e:
            return {"content": [{"type": "text", "text": "error: " + str(e)}], "isError": True}
        code, out, err = run_tf3ctl(self.command(argv), wait_seconds(spec, arguments))
        res = {"command": "tf3ctl.py " + " ".join(shlex.quote(w) for w in argv), "exitCode": code,
               "meaning": EXIT_MEANING.get(code, "unknown exit code")}
        res.update(parse_stdout(out))
        if err.strip():
            res["stderr"] = err
        return {"content": [{"type": "text", "text": json.dumps(res, ensure_ascii=False, indent=1)}],
                "isError": code != 0}

    def handle(self, msg):
        """The answer to one JSON-RPC message, or None (a notification, or a response to us)."""
        if not isinstance(msg, dict):
            return error_reply(None, -32600, "a request must be an object")
        has_id = "id" in msg
        mid = msg.get("id")
        if "method" not in msg:
            if "result" in msg or "error" in msg:
                return None  # a response: this server sends no requests
            return error_reply(mid, -32600, "no method")
        method = msg.get("method")
        if msg.get("jsonrpc") != "2.0" or not isinstance(method, str) or (has_id and not isinstance(
                mid, (str, int)) or isinstance(mid, bool)):
            return error_reply(mid if isinstance(mid, (str, int)) else None, -32600, "not a JSON-RPC 2.0 request")
        params = msg.get("params") or {}
        if not has_id:
            return None  # notifications/initialized, notifications/cancelled, ...: nothing to answer
        try:
            if method == "initialize":
                asked = params.get("protocolVersion") if isinstance(params, dict) else None
                return reply(mid, {
                    "protocolVersion": asked if asked in PROTOCOL_VERSIONS else PROTOCOL_VERSIONS[0],
                    "capabilities": {"tools": {"listChanged": False}},
                    "serverInfo": {"name": SERVER_NAME, "version": self.version},
                    "instructions": INSTRUCTIONS})
            if method == "ping":
                return reply(mid, {})
            if method == "tools/list":
                return reply(mid, {"tools": self.tools})
            if method == "tools/call":
                if not isinstance(params, dict) or not isinstance(params.get("name"), str):
                    return error_reply(mid, -32602, "tools/call needs a name")
                if params["name"] not in self.specs:
                    return error_reply(mid, -32602, "unknown tool: " + params["name"])
                return reply(mid, self.call_tool(params["name"], params.get("arguments")))
            return error_reply(mid, -32601, "method not found: " + method)
        except Exception as e:  # one bad call must not end the server
            return error_reply(mid, -32603, "internal error: %s: %s" % (type(e).__name__, e))

    def handle_line(self, line):
        """The text to write back for one line from stdin (None: nothing)."""
        if not line.strip():
            return None
        try:
            msg = json.loads(line)
        except ValueError as e:
            return dumps(error_reply(None, -32700, "parse error: %s" % e))
        if isinstance(msg, list):
            if not msg:
                return dumps(error_reply(None, -32600, "empty batch"))
            out = [r for r in (self.handle(m) for m in msg) if r is not None]
            return dumps(out) if out else None
        r = self.handle(msg)
        return dumps(r) if r is not None else None

    def serve(self, stdin, stdout):
        for raw in stdin:
            text = raw.decode("utf-8", "replace") if isinstance(raw, bytes) else raw
            out = self.handle_line(text)
            if out is not None:
                stdout.write((out + "\n").encode("utf-8"))
                stdout.flush()


def reply(mid, result):
    return {"jsonrpc": "2.0", "id": mid, "result": result}


def error_reply(mid, code, message):
    return {"jsonrpc": "2.0", "id": mid, "error": {"code": code, "message": message}}


def dumps(obj):
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


def main(argv=None):
    ap = argparse.ArgumentParser(description="MCP server (stdio) for tf3ctl.py's commands")
    ap.add_argument("--owner", default=os.environ.get("TF3CTL_OWNER"),
                    help="sent as tf3ctl's --owner with every command (default $TF3CTL_OWNER)")
    ap.add_argument("--tf3ctl", default=default_tf3ctl(), help="tf3ctl.py to run (default: the one beside this file)")
    ap.add_argument("--python", default=sys.executable, help="the Python that runs tf3ctl.py (default: this one)")
    ns = ap.parse_args(argv)
    try:
        server = Server(ns.tf3ctl, ns.python, ns.owner)
    except (OSError, ImportError, SyntaxError, AttributeError, ValueError) as e:
        print("tf3ctl_mcp: cannot read the commands of %s: %s" % (ns.tf3ctl, e), file=sys.stderr)
        return 2
    try:
        server.serve(sys.stdin.buffer, sys.stdout.buffer)
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
