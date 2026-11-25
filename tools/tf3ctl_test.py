"""tf3ctl test: run a test scenario (a JSON file of tf3ctl commands with checks) and answer pass or fail.

A scenario is one JSON object:

  {
    "name": "my_mod builds its depot",
    "continueOnFail": false,
    "steps": [
      {"name": "new game", "cmd": ["launch", "--new", "--size", "tiny", "--year", "1900", "--add", "my_mod"]},
      {"cmd": "speed 0"},
      {"cmd": ["build", "--res", "my_mod::/my_depot.con", "--at", "600,40", "--dry-run"],
       "expect": [{"path": "dryRun", "op": "eq", "value": true}]},
      {"cmd": "steps 20"},
      {"cmd": "status", "expect": {"path": "state.date.year", "op": "ge", "value": 1900}},
      {"name": "no errors in the log", "log": {}}
    ]
  }

Each step is one tf3ctl command (`cmd`: the words after `tf3ctl.py`, as a list or as one string split as a shell
would) run through tf3ctl's own main, so every check of tf3ctl's (owner, test saves, coop, the configuration file)
applies as on the command line; the scenario adds none and skips none. Flags that skip a check (SKIP_FLAGS) are
refused in a scenario. A `log` step looks at the game's log written since the scenario started.

Exit codes: 0 every step passed, 5 a step failed, 2 the scenario is broken (nothing is sent then) or a step got no
answer (its command exited 2 or 3), 130 interrupted.
"""
import contextlib
import io
import json
import os
import re
import shlex
import time

EXIT_PASS = 0
EXIT_FAIL = 5  # new: 0-4 are tf3ctl's own (AGENTS.md); a failed check is not one of them
EXIT_BROKEN = 2  # as tf3ctl's "no answer, a tool error"
EXIT_INTERRUPTED = 130

# flags that skip one of tf3ctl's checks: a person types them for one command, a file must not carry them
SKIP_FLAGS = ("--force", "--user-asked", "--other-owner-ok", "--ignore-errors")
# command paths a scenario cannot run, with why (pointer and the uploads as tools/tf3ctl_mcp.py leaves them out)
EXCLUDED = {
    ("test",): "a scenario does not run another scenario",
    ("log",): "log prints text, not JSON: use a log step ({\"log\": {...}})",
    ("pointer",): "moves the X11 pointer of the machine the game runs on; for screenshots made by hand",
    ("modhub", "publish"): "uploads to mod.io: a person runs it",
    ("modhub", "publish-clear"): "clears the mark a failed upload left, after a person checked mod.io",
    ("coop", "start"): "coop loosens the checks for the user's own game: a person starts it beside the user",
}
# options a scenario cannot give, with why: a file runs unattended, so it gets neither looser checks nor a SIGKILL
REFUSED_OPTIONS = (
    ("launch", "coop", True, "--coop starts coop, which loosens the checks: a person starts it beside the user"),
    ("quit", "kill", True, "--kill sends SIGKILL (an unsaved game is lost): quit, or restart --no-kill"),
    ("restart", "no_kill", False, "restart needs --no-kill in a scenario (without it, a game that does not quit "
                                  "gets SIGKILL)"),
    ("window", "close_all", True, "--close-all closes every window of the game, also the player's"),
)
OPS = ("eq", "ne", "gt", "ge", "lt", "le", "exists", "contains", "len")
CMP_OPS = ("eq", "ne", "gt", "ge", "lt", "le")
SCENARIO_KEYS = {"name", "description", "comment", "continueOnFail", "steps"}
STEP_KEYS = {"name", "comment", "cmd", "log", "expect", "exit", "continueOnFail"}
EXPECT_KEYS = {"path", "op", "value", "cmp", "comment"}
LOG_KEYS = {"patterns", "ignore", "require", "max", "comment"}

# what counts as an error in the game's log, each searched in one entry (its "[time - LEVEL - thread ...]" line and
# the indented lines below it): an ERROR line of any thread, an exception entry (the engine's "Exception type: Lua
# error" with its "| Error message: ..." line), and Lua's own error texts. Not "stack traceback": the base's menu
# writes MESSAGE entries with one in a normal start ("Ignoring Set() on expired ReactStateWrap").
DEFAULT_LOG_PATTERNS = (
    r"^\[[^\]\n]*? - ERROR\s+-",
    r"Exception type:",
    r"\bLua error\b",
    r"attempt to (?:index|call|perform arithmetic|compare|concatenate)",
)
LOG_MATCHES_SHOWN = 10
LOG_ENTRY_CHARS = 600
LOG_KEEP_BYTES = 64 * 1024 * 1024  # of the log since the start kept in memory: the oldest goes first past this
LOG_HEAD_BYTES = 256  # the log's first bytes: another start of the game writes another first line (its time)
EXCERPT_CHARS = 2000
STDERR_CHARS = 1000
ACTUAL_CHARS = 300


class ScenarioError(Exception):
    """The scenario cannot be run as written: nothing is sent."""


# ---------------------------------------------------------------------------------------------------------------------
# paths into an answer: name.name[0]["a key"][-1]

_NAME = re.compile(r'[^.\[\]"]+')
_INDEX = re.compile(r'\[(-?\d+)\]')
_QUOTED = re.compile(r'\["((?:[^"\\]|\\.)*)"\]')


def parse_path(path):
    """A path into a JSON answer as a list of keys (str) and indexes (int). "" is the whole answer."""
    if not isinstance(path, str):
        raise ScenarioError("a path is a string, e.g. \"lines[0].vehicles\"")
    out, pos = [], 0
    while pos < len(path):
        dot = pos > 0 and path[pos] == "."
        m = _NAME.match(path, pos + 1 if dot else pos) if dot or pos == 0 else None
        if m:
            out.append(m.group(0))
        elif not dot and _INDEX.match(path, pos):
            m = _INDEX.match(path, pos)
            out.append(int(m.group(1)))
        elif not dot and _QUOTED.match(path, pos):
            m = _QUOTED.match(path, pos)
            try:
                out.append(json.loads('"' + m.group(1) + '"'))
            except ValueError:  # a broken escape such as \q: the file's mistake, not the tool's
                raise ScenarioError("cannot read the quoted key in the path %r at character %d" % (path, pos + 1))
        else:
            raise ScenarioError("cannot read the path %r at character %d" % (path, pos + 1))
        pos = m.end()
    return out


def resolve(answer, keys):
    """(found, value) of keys in answer; found False where a key or index is not there."""
    cur = answer
    for k in keys:
        if isinstance(k, int):
            if not isinstance(cur, list) or not -len(cur) <= k < len(cur):
                return False, None
            cur = cur[k]
        else:
            if not isinstance(cur, dict) or k not in cur:
                return False, None
            cur = cur[k]
    return True, cur


# ---------------------------------------------------------------------------------------------------------------------
# comparisons

def _is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _same(a, b):
    """JSON equality: 1 and 1.0 are equal, true and 1 are not."""
    if isinstance(a, bool) or isinstance(b, bool):
        return isinstance(a, bool) and isinstance(b, bool) and a == b
    if _is_num(a) and _is_num(b):
        return a == b
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(_same(x, y) for x, y in zip(a, b))
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(_same(a[k], b[k]) for k in a)
    return type(a) is type(b) and a == b


def compare(op, actual, value):
    """(passed, why) of actual <op> value for eq ... le; why is None when it passed."""
    if op == "eq":
        return (True, None) if _same(actual, value) else (False, "not equal")
    if op == "ne":
        return (True, None) if not _same(actual, value) else (False, "equal")
    if not ((_is_num(actual) and _is_num(value)) or (isinstance(actual, str) and isinstance(value, str))):
        return False, "%s compares two numbers or two strings" % op
    ok = {"gt": actual > value, "ge": actual >= value, "lt": actual < value, "le": actual <= value}[op]
    return (True, None) if ok else (False, "not %s" % op)


def check_expect(exp, answer):
    """One expect against an answer: a dict for the result (pass, and why when it did not)."""
    path, op = exp.get("path", ""), exp["op"]
    found, actual = resolve(answer, parse_path(path))
    res = {"path": path, "op": op}
    if "value" in exp:
        res["value"] = exp["value"]
    if op == "len":
        res["cmp"] = exp.get("cmp", "eq")
    if op == "exists":
        want = exp.get("value", True)
        res["pass"] = found == want
        if not res["pass"]:
            res["why"] = "the path is there" if found else "no such path in the answer"
        return res
    if not found:
        res.update({"pass": False, "why": "no such path in the answer"})
        return res
    res["actual"] = excerpt(actual, ACTUAL_CHARS)
    if op == "contains":
        v = exp["value"]
        if isinstance(actual, str):
            ok = isinstance(v, str) and v in actual
        elif isinstance(actual, list):
            ok = any(_same(x, v) for x in actual)
        elif isinstance(actual, dict):
            ok = isinstance(v, str) and v in actual
        else:
            res.update({"pass": False, "why": "contains looks in a string, a list or an object's keys"})
            return res
        res["pass"] = ok
        if not ok:
            res["why"] = "not in it"
        return res
    if op == "len":
        if not isinstance(actual, (str, list, dict)):
            res.update({"pass": False, "why": "len counts a string, a list or an object"})
            return res
        res["actual"] = len(actual)
        ok, why = compare(res["cmp"], len(actual), exp["value"])
    else:
        ok, why = compare(op, actual, exp["value"])
    res["pass"] = ok
    if why:
        res["why"] = why
    return res


def excerpt(value, limit):
    """value itself when its JSON is at most limit characters, else the JSON cut there (a string)."""
    text = json.dumps(value, ensure_ascii=False, sort_keys=True)
    if len(text) <= limit:
        return value
    return text[:limit] + "..."


# ---------------------------------------------------------------------------------------------------------------------
# the scenario file

def _argv(cmd, where):
    if isinstance(cmd, str):
        try:
            argv = shlex.split(cmd)
        except ValueError as e:
            raise ScenarioError("%s: cmd cannot be split: %s" % (where, e))
    elif isinstance(cmd, list):
        argv = []
        for w in cmd:
            if isinstance(w, bool) or not isinstance(w, (str, int, float)):
                raise ScenarioError("%s: cmd's words are strings or numbers" % where)
            argv.append(w if isinstance(w, str) else json.dumps(w))
    else:
        raise ScenarioError("%s: cmd is a list of words or one string" % where)
    if not argv:
        raise ScenarioError("%s: cmd is empty" % where)
    if argv[0].startswith("-"):
        raise ScenarioError("%s: cmd starts with the command's name (the tool's own options, such as --owner, go on "
                            "the test command line)" % where)
    for w in argv:
        for flag in SKIP_FLAGS:
            if w == flag or w.startswith(flag + "="):
                raise ScenarioError("%s: %s skips one of tf3ctl's checks and is refused in a scenario (type it for "
                                    "one command when the person asked for it)" % (where, flag))
    return argv


def _check_cmd(argv, where, make_parser):
    """Parses argv with tf3ctl's own parser (nothing is sent) and refuses the commands a scenario cannot run."""
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            ns = make_parser().parse_args(argv)
    except SystemExit:
        msg = err.getvalue().strip().splitlines()
        raise ScenarioError("%s: tf3ctl cannot read the command: %s" % (where, msg[-1] if msg else " ".join(argv)))
    action = getattr(ns, "action", None) if ns.cmd == "modhub" else getattr(ns, "coop_action", None)
    path = (ns.cmd,) + ((action,) if ns.cmd in ("modhub", "coop") and action else ())
    for key in (path, path[:1]):
        if key in EXCLUDED:
            raise ScenarioError("%s: %s is not run from a scenario: %s" % (where, " ".join(key), EXCLUDED[key]))
    for cmd, attr, refused_when, why in REFUSED_OPTIONS:
        if ns.cmd == cmd and bool(getattr(ns, attr, False)) == refused_when:
            raise ScenarioError("%s: %s" % (where, why))
    if getattr(ns, "every", None) is not None and getattr(ns, "count", None) is None:
        raise ScenarioError("%s: --every needs --count in a scenario (else it never ends)" % where)


def _check_regexes(spec, key, where):
    pats = spec.get(key, [])
    if not isinstance(pats, list) or not all(isinstance(p, str) for p in pats):
        raise ScenarioError("%s: log %s is a list of regular expressions" % (where, key))
    for p in pats:
        try:
            re.compile(p)
        except re.error as e:
            raise ScenarioError("%s: log %s %r: %s" % (where, key, p, e))


def _check_expect(exp, where):
    if not isinstance(exp, dict):
        raise ScenarioError("%s: an expect is an object {\"path\", \"op\", \"value\"}" % where)
    extra = set(exp) - EXPECT_KEYS
    if extra:
        raise ScenarioError("%s: unknown keys in expect: %s" % (where, ", ".join(sorted(extra))))
    if exp.get("op") not in OPS:
        raise ScenarioError("%s: op is one of %s" % (where, ", ".join(OPS)))
    parse_path(exp.get("path", ""))
    op = exp["op"]
    if op == "exists":
        if "value" in exp and not isinstance(exp["value"], bool):
            raise ScenarioError("%s: exists takes value true or false (default true)" % where)
    elif "value" not in exp:
        raise ScenarioError("%s: %s needs a value" % (where, op))
    if op == "len":
        if not _is_num(exp["value"]):
            raise ScenarioError("%s: len's value is a number" % where)
        if exp.get("cmp", "eq") not in CMP_OPS:
            raise ScenarioError("%s: len's cmp is one of %s" % (where, ", ".join(CMP_OPS)))
    elif "cmp" in exp:
        raise ScenarioError("%s: cmp goes with op len only" % where)


def validate(sc, make_parser):
    """Checks a scenario's whole form, every command parsed by tf3ctl's parser, before anything is sent. Returns
    the steps as runnable dicts. Raises ScenarioError."""
    if not isinstance(sc, dict):
        raise ScenarioError("a scenario is a JSON object with steps")
    extra = set(sc) - SCENARIO_KEYS
    if extra:
        raise ScenarioError("unknown keys in the scenario: %s" % ", ".join(sorted(extra)))
    if not isinstance(sc.get("continueOnFail", False), bool):
        raise ScenarioError("continueOnFail is true or false")
    steps = sc.get("steps")
    if not isinstance(steps, list):
        raise ScenarioError("the scenario has no steps list")
    if not steps:
        raise ScenarioError("steps is empty: a scenario with nothing to run passes nothing")
    out = []
    for i, st in enumerate(steps, 1):
        where = "step %d" % i
        if not isinstance(st, dict):
            raise ScenarioError("%s is not an object" % where)
        if isinstance(st.get("name"), str):
            where += " (%s)" % st["name"]
        extra = set(st) - STEP_KEYS
        if extra:
            raise ScenarioError("%s: unknown keys: %s" % (where, ", ".join(sorted(extra))))
        if ("cmd" in st) == ("log" in st):
            raise ScenarioError("%s: give cmd or log (one of them)" % where)
        if "name" in st and not isinstance(st["name"], str):
            raise ScenarioError("%s: name is a string" % where)
        if not isinstance(st.get("continueOnFail", False), bool):
            raise ScenarioError("%s: continueOnFail is true or false" % where)
        step = {"index": i, "name": st.get("name"),
                "continueOnFail": st.get("continueOnFail", sc.get("continueOnFail", False))}
        if "log" in st:
            spec = st["log"]
            if spec is True:
                spec = {}
            if not isinstance(spec, dict):
                raise ScenarioError("%s: log is an object (or true)" % where)
            extra = set(spec) - LOG_KEYS
            if extra:
                raise ScenarioError("%s: unknown keys in log: %s" % (where, ", ".join(sorted(extra))))
            for key in ("patterns", "ignore", "require"):
                _check_regexes(spec, key, where)
            if "patterns" in spec and not spec["patterns"]:
                raise ScenarioError("%s: log patterns is empty (leave it out for the default ones)" % where)
            mx = spec.get("max", 0)
            if isinstance(mx, bool) or not isinstance(mx, int) or mx < 0:
                raise ScenarioError("%s: log max is a whole number, 0 or more" % where)
            if "expect" in st or "exit" in st:
                raise ScenarioError("%s: a log step takes no expect or exit" % where)
            step["log"] = spec
        else:
            step["argv"] = _argv(st["cmd"], where)
            _check_cmd(step["argv"], where, make_parser)
            ex = st.get("exit", 0)
            if isinstance(ex, bool) or not isinstance(ex, int) or not 0 <= ex <= 255:
                raise ScenarioError("%s: exit is the exit code the command should give (default 0)" % where)
            step["exit"] = ex
            exps = st.get("expect", [])
            if isinstance(exps, dict):
                exps = [exps]
            if not isinstance(exps, list):
                raise ScenarioError("%s: expect is an object or a list of them" % where)
            for j, exp in enumerate(exps, 1):
                _check_expect(exp, "%s, expect %d" % (where, j))
            step["expect"] = exps
        out.append(step)
    return out


def load_scenario(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except OSError as e:
        raise ScenarioError("cannot read %s: %s" % (path, e.strerror or e))
    except ValueError as e:
        raise ScenarioError("%s is not JSON: %s" % (path, e))


# ---------------------------------------------------------------------------------------------------------------------
# the game's log since the start

class LogWatch:
    """Keeps what the game writes to its log from the scenario's start on. A launch or restart in the scenario
    starts a new log (the old one is copied aside and the file written anew): that is seen as a smaller file,
    another inode or other first bytes, and the new log is read from its start. Read before every step and at every
    log step, so only what the old game wrote between the last read and its end is missed."""

    def __init__(self, path_fn):
        self.path_fn = path_fn
        self.path = self.ino = self.head = None
        self.offset = None
        self.chunks, self.kept = [], 0
        self.dropped = False
        self.rewrites = 0
        self.seen = False

    @staticmethod
    def _look(path):
        try:
            st = os.stat(path)
            with open(path, "rb") as f:
                head = f.read(LOG_HEAD_BYTES)
        except OSError:
            return None
        return st.st_ino, st.st_size, head

    def start(self):
        path = self.path_fn()
        look = self._look(path) if path else None
        if look:
            self.path, self.ino, self.offset, self.head = path, look[0], look[1], look[2]
            self.seen = True

    def scan(self):
        path = self.path_fn()
        look = self._look(path) if path else None
        if not look:
            return
        ino, size, head = look
        if self.offset is None or path != self.path:
            self.offset = 0  # no log at the start (the scenario launched the game), or another file now
        elif ino != self.ino or size < self.offset or head[:len(self.head)] != self.head:
            self.offset = 0
            self.rewrites += 1
        self.path, self.ino, self.head, self.seen = path, ino, head, True
        if size <= self.offset:
            return
        try:
            with open(path, "rb") as f:
                f.seek(self.offset)
                data = f.read(size - self.offset)
        except OSError:
            return
        end = data.rfind(b"\n") + 1  # whole lines only: the rest is read next time
        if end <= 0:
            return
        self.offset += end
        self.chunks.append(data[:end].decode("utf-8", "replace"))
        self.kept += end
        while self.kept > LOG_KEEP_BYTES and len(self.chunks) > 1:
            self.kept -= len(self.chunks.pop(0).encode("utf-8"))
            self.dropped = True

    def entries(self):
        """The log's entries: a "[" line with the indented lines below it."""
        out, cur = [], None
        for chunk in self.chunks:
            for line in chunk.splitlines():
                if line.startswith("[") or cur is None:
                    if cur is not None:
                        out.append(cur)
                    cur = line
                else:
                    cur += "\n" + line
        if cur is not None:
            out.append(cur)
        return out


def run_log_step(step, watch):
    spec = step["log"]
    watch.scan()
    res = {"kind": "log"}
    if not watch.seen:
        res.update({"status": "error", "why": "no game log was found (TF3_LOG, or the game's crash_dump/stdout.txt)"})
        return res
    pats = [re.compile(p) for p in spec.get("patterns", DEFAULT_LOG_PATTERNS)]
    ignore = [re.compile(p) for p in spec.get("ignore", [])]
    entries = watch.entries()
    hits = [e for e in entries if any(p.search(e) for p in pats) and not any(p.search(e) for p in ignore)]
    missing = [p for p in spec.get("require", []) if not any(re.search(p, e) for e in entries)]
    mx = spec.get("max", 0)
    res.update({"entriesRead": len(entries), "matches": len(hits), "max": mx,
                "shown": [e.replace("\n", " ")[:LOG_ENTRY_CHARS] for e in hits[:LOG_MATCHES_SHOWN]]})
    if missing:
        res["missing"] = missing
    if watch.rewrites:
        res["newLogs"] = watch.rewrites
    if watch.dropped:
        res["note"] = "the log since the start was longer than %d MB: the oldest part is not looked at" % (
            LOG_KEEP_BYTES // (1024 * 1024))
    ok = len(hits) <= mx and not missing
    res["status"] = "pass" if ok else "fail"
    if not ok:
        why = []
        if len(hits) > mx:
            why.append("%d error entries in the log (at most %d)" % (len(hits), mx))
        if missing:
            why.append("not in the log: " + ", ".join(missing))
        res["why"] = "; ".join(why)
    return res


# ---------------------------------------------------------------------------------------------------------------------
# running

def parse_stdout(text):
    """(answer, found): one JSON value, else one per line (--every); found False for no output or text."""
    s = text.strip()
    if not s:
        return None, False
    try:
        return json.loads(s), True
    except ValueError:
        pass
    try:
        return [json.loads(line) for line in s.splitlines() if line.strip()], True
    except ValueError:
        return None, False


def run_cmd_step(step, run_main, head, excerpt_chars):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            code = run_main(head + step["argv"])
        except SystemExit as e:  # argparse (checked before, so not expected)
            code = e.code if isinstance(e.code, int) else 2
    answer, found = parse_stdout(out.getvalue())
    res = {"kind": "cmd", "cmd": step["argv"], "exit": code, "expectedExit": step["exit"]}
    if found:
        res["answer"] = excerpt(answer, excerpt_chars)
    elif out.getvalue().strip():
        res["stdout"] = out.getvalue()[:excerpt_chars]
    if err.getvalue().strip():
        res["stderr"] = err.getvalue()[-STDERR_CHARS:]
    if code == EXIT_INTERRUPTED:
        res.update({"status": "interrupted", "why": "interrupted"})
        return res
    checks = [check_expect(exp, answer) if found else
              {"path": exp.get("path", ""), "op": exp["op"], "pass": False, "why": "no answer"}
              for exp in step["expect"]]
    if checks:
        res["checks"] = checks
    whys = []
    if code != step["exit"]:
        whys.append("exit code %s, expected %d" % (code, step["exit"]))
    bad = [c for c in checks if not c["pass"]]
    if bad:
        whys.append("%d of %d checks failed" % (len(bad), len(checks)))
    if code in (2, 3) and code != step["exit"]:
        res["status"] = "error"  # no answer: the tool or the game could not give one
    else:
        res["status"] = "fail" if whys else "pass"
    if whys:
        res["why"] = "; ".join(whys)
    return res


def run_scenario(steps, run_main, log_path, owner=None, other_owner_ok=False, excerpt_chars=EXCERPT_CHARS,
                 clock=time.monotonic):
    """Runs validated steps one after another. Returns (result dict, exit code)."""
    head = (["--owner", owner] if owner else []) + (["--other-owner-ok"] if other_owner_ok else [])
    watch = LogWatch(log_path)
    watch.start()
    started = clock()
    results, stopped = [], None
    for step in steps:
        if stopped:
            results.append({"index": step["index"], "name": step["name"], "status": "skipped"})
            continue
        watch.scan()  # the last step's lines, before a launch or restart may start a new log
        t0 = clock()
        try:
            res = run_log_step(step, watch) if "log" in step else run_cmd_step(step, run_main, head, excerpt_chars)
        except KeyboardInterrupt:  # Ctrl+C outside a command's own wait: still print the steps so far
            res = {"kind": "log" if "log" in step else "cmd", "status": "interrupted", "why": "interrupted"}
        res = dict({"index": step["index"], "name": step["name"]}, **res)
        res["durationSec"] = round(clock() - t0, 3)
        results.append(res)
        if res["status"] == "interrupted" or (res["status"] in ("fail", "error") and not step["continueOnFail"]):
            stopped = res["status"]
    count = {s: sum(1 for r in results if r["status"] == s) for s in ("pass", "fail", "error", "skipped")}
    if any(r["status"] == "interrupted" for r in results):
        verdict, code = "interrupted", EXIT_INTERRUPTED
    elif count["error"]:
        verdict, code = "error", EXIT_BROKEN
    elif count["fail"]:
        verdict, code = "fail", EXIT_FAIL
    else:
        verdict, code = "pass", EXIT_PASS
    out = {"ok": code == EXIT_PASS, "result": verdict, "exitCode": code, "passed": count["pass"],
           "failed": count["fail"], "errors": count["error"], "skipped": count["skipped"],
           "durationSec": round(clock() - started, 3), "steps": results}
    return out, code


def cmd_test(ns, run_main, make_parser, log_path, show):
    """tf3ctl test FILE: prints one JSON object, returns the exit code."""
    try:
        sc = load_scenario(ns.scenario)
        steps = validate(sc, make_parser)
    except ScenarioError as e:
        show({"ok": False, "result": "broken", "exitCode": EXIT_BROKEN, "file": ns.scenario, "error": str(e)})
        return EXIT_BROKEN
    if ns.dry_run:
        show({"ok": True, "result": "checked", "dryRun": True, "exitCode": EXIT_PASS, "file": ns.scenario,
              "name": sc.get("name"),
              "steps": [{k: v for k, v in (("index", s["index"]), ("name", s["name"]), ("cmd", s.get("argv")),
                                           ("exit", s.get("exit")), ("expect", s.get("expect")), ("log", s.get("log")))
                         if v is not None} for s in steps]})
        return EXIT_PASS
    out, code = run_scenario(steps, run_main, log_path, owner=ns.owner, other_owner_ok=ns.other_owner_ok,
                             excerpt_chars=ns.excerpt)
    show(dict({"file": ns.scenario, "name": sc.get("name")}, **out))
    return code


def add_parser(sub):
    t = sub.add_parser("test", help="run a test scenario (a JSON file of tf3ctl commands with checks of their "
                                    "answers and of the game's log): one JSON result; exit 0 all passed, 5 a step "
                                    "failed, 2 a broken scenario or no answer")
    t.add_argument("scenario", metavar="FILE", help="the scenario (JSON; see docs/REFERENCE.md, \"Test scenarios\")")
    t.add_argument("--dry-run", action="store_true", help="only check the scenario (every command parsed); send "
                                                          "nothing")
    t.add_argument("--excerpt", type=int, default=EXCERPT_CHARS, help="characters of each answer kept in the result "
                                                                      "(default %d)" % EXCERPT_CHARS)
    return t
