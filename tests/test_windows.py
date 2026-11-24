"""Windows branches of tools/tf3ctl.py, run on Linux: sys.platform, os.getuid and the Windows-only modules (fcntl's
absence, msvcrt, winreg, ctypes' kernel32, tasklist through subprocess) are mocked. They check the paths and command
lines the tool builds, not that Windows accepts them (there is no Windows machine to run them on)."""
import contextlib
import errno
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import types
import unittest
import unittest.mock

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(ROOT, "tools", "tf3ctl.py")


def load_tool(name="tf3ctl_win", block_fcntl=False):
    """A fresh copy of the module; block_fcntl makes `import fcntl` fail as it does on Windows."""
    spec = importlib.util.spec_from_file_location(name, TOOL)
    mod = importlib.util.module_from_spec(spec)
    patch = unittest.mock.patch.dict(sys.modules, {"fcntl": None}) if block_fcntl else contextlib.nullcontext()
    with patch:
        spec.loader.exec_module(mod)
    return mod


T = load_tool()


def setUpModule():
    # test_tf3ctl (run before this module) points tempfile at its own run folder and removes that folder in its
    # tearDownModule; its atexit removes it again at the end, so making it here again leaves nothing behind
    os.makedirs(tempfile.gettempdir(), exist_ok=True)


@contextlib.contextmanager
def windows(mod=T):
    with unittest.mock.patch.object(mod.sys, "platform", "win32"):
        yield


@contextlib.contextmanager
def no_getuid():
    """os without getuid, as on Windows (os is shared by every module, so it is put back however the test ends)."""
    saved = os.getuid
    del os.getuid
    try:
        yield
    finally:
        os.getuid = saved


def fake_msvcrt(fail_times=0, fail_errno=errno.EDEADLK):
    calls = []
    m = types.ModuleType("msvcrt")
    m.LK_LOCK, m.LK_UNLCK = 1, 0
    state = {"left": fail_times}

    def locking(fd, mode, nbytes):
        calls.append((mode, nbytes, os.lseek(fd, 0, os.SEEK_CUR)))
        if mode == m.LK_LOCK and state["left"] > 0:
            state["left"] -= 1
            raise OSError(fail_errno, "Resource deadlock avoided")
    m.locking = locking
    return m, calls


def fake_winreg(values=None, key_missing=False):
    m = types.ModuleType("winreg")
    m.HKEY_CURRENT_USER = "HKCU"
    opened = []

    @contextlib.contextmanager
    def OpenKey(root, sub):
        opened.append((root, sub))
        if key_missing:
            raise FileNotFoundError(2, "The system cannot find the file specified")
        yield "key"

    def QueryValueEx(key, name):
        if name not in (values or {}):
            raise FileNotFoundError(2, "no value")
        return values[name], 1
    m.OpenKey, m.QueryValueEx, m.opened = OpenKey, QueryValueEx, opened
    return m


class ImportWithoutFcntl(unittest.TestCase):
    def test_import_and_help_without_fcntl(self):
        mod = load_tool("tf3ctl_nofcntl", block_fcntl=True)
        self.assertIsNone(mod.fcntl)
        out = io.StringIO()
        with contextlib.redirect_stdout(out), self.assertRaises(SystemExit) as cm:
            mod.main(["--help"])
        self.assertEqual(cm.exception.code, 0)
        self.assertIn("status", out.getvalue())

    def test_posix_import_keeps_fcntl(self):
        self.assertIsNotNone(T.fcntl)


class LockFile(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.path = os.path.join(self.dir.name, "lock")

    def test_msvcrt_first_byte_and_unlock(self):
        m, calls = fake_msvcrt()
        with unittest.mock.patch.object(T, "fcntl", None), unittest.mock.patch.dict(sys.modules, {"msvcrt": m}):
            with open(self.path, "a") as f:
                f.write("xyz")  # the position is not 0: the lock still has to be on byte 0
                with T.lock_file(f):
                    self.assertEqual(calls, [(m.LK_LOCK, 1, 0)])
        self.assertEqual(calls, [(m.LK_LOCK, 1, 0), (m.LK_UNLCK, 1, 0)])

    def test_msvcrt_retries_after_lk_lock_gives_up(self):
        m, calls = fake_msvcrt(fail_times=3)
        with unittest.mock.patch.object(T, "fcntl", None), unittest.mock.patch.dict(sys.modules, {"msvcrt": m}):
            with open(self.path, "a") as f, T.lock_file(f):
                pass
        self.assertEqual([c[0] for c in calls], [m.LK_LOCK] * 4 + [m.LK_UNLCK])

    def test_msvcrt_other_error_is_raised(self):
        m, calls = fake_msvcrt(fail_times=1, fail_errno=errno.EBADF)
        with unittest.mock.patch.object(T, "fcntl", None), unittest.mock.patch.dict(sys.modules, {"msvcrt": m}):
            with open(self.path, "a") as f, self.assertRaises(OSError):
                with T.lock_file(f):
                    self.fail("locked after a bad descriptor")
        self.assertEqual(len(calls), 1)

    def test_msvcrt_unlocks_when_the_block_raises(self):
        m, calls = fake_msvcrt()
        with unittest.mock.patch.object(T, "fcntl", None), unittest.mock.patch.dict(sys.modules, {"msvcrt": m}):
            with open(self.path, "a") as f, self.assertRaises(KeyError):
                with T.lock_file(f):
                    raise KeyError("x")
        self.assertEqual(calls[-1][0], m.LK_UNLCK)

    def test_three_locks_go_through_lock_file(self):
        m, calls = fake_msvcrt()
        runtime = os.path.join(self.dir.name, "rt")
        os.mkdir(runtime)
        with unittest.mock.patch.object(T, "fcntl", None), unittest.mock.patch.dict(sys.modules, {"msvcrt": m}), \
                unittest.mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": runtime}):
            with T.command_lock(self.dir.name):
                pass
            with T.launched_lock():
                pass
            with T.profile_lock(os.path.join(self.dir.name, "profile.lua")):
                with T.profile_lock(os.path.join(self.dir.name, "profile.lua")):  # re-entrant: no second lock
                    pass
        self.assertEqual([c[0] for c in calls], [m.LK_LOCK, m.LK_UNLCK] * 3)

    def test_posix_flock_still_excludes(self):
        # the Linux path: a second descriptor cannot take the lock while lock_file holds it
        import fcntl
        with open(self.path, "a") as f, T.lock_file(f):
            with open(self.path, "a") as g, self.assertRaises(BlockingIOError):
                fcntl.flock(g, fcntl.LOCK_EX | fcntl.LOCK_NB)
        with open(self.path, "a") as g:
            fcntl.flock(g, fcntl.LOCK_EX | fcntl.LOCK_NB)  # free again


class GamePids(unittest.TestCase):
    def run_tasklist(self, stdout=None, raises=None):
        def fake(argv, **kw):
            self.argv, self.kw = argv, kw
            if raises:
                raise raises
            return subprocess.CompletedProcess(argv, 0, stdout, "")
        with windows(), unittest.mock.patch.object(T.subprocess, "run", fake):
            return T.game_pids()

    def test_rows(self):
        out = ('"TransportFever3.exe","4242","Console","1","2,345,678 K"\n'
               '"TransportFever3.exe","77","Console","1","12 K"\n')
        self.assertEqual(self.run_tasklist(out), [4242, 77])
        self.assertEqual(self.argv, ["tasklist", "/FI", "IMAGENAME eq TransportFever3.exe", "/FO", "CSV", "/NH"])

    def test_no_tasks_info_line(self):
        out = "INFO: No tasks are running which match the specified criteria.\n"
        self.assertEqual(self.run_tasklist(out), [])

    def test_empty_output(self):
        self.assertEqual(self.run_tasklist(""), [])
        self.assertEqual(self.run_tasklist(None), [])

    def test_other_image_and_bad_pid_skipped(self):
        out = '"steam.exe","10","Console","1","1 K"\n"TransportFever3.exe","N/A","Console","1","1 K"\n\n'
        self.assertEqual(self.run_tasklist(out), [])

    def test_tasklist_missing(self):
        self.assertEqual(self.run_tasklist(raises=FileNotFoundError(2, "tasklist")), [])
        self.assertEqual(self.run_tasklist(raises=subprocess.TimeoutExpired("tasklist", 15)), [])

    def test_linux_does_not_run_tasklist(self):
        with unittest.mock.patch.object(T.sys, "platform", "linux"), \
                unittest.mock.patch.object(T.subprocess, "run", side_effect=AssertionError("tasklist")):
            self.assertIsInstance(T.game_pids(), list)


class ProcessStart(unittest.TestCase):
    def kernel32(self, handle=1234, ticks=None, times_ok=True):
        closed = []

        def OpenProcess(access, inherit, pid):
            self.opened = (access, inherit, pid)
            return handle

        def GetProcessTimes(h, creation, exit_, kernel, user):
            if ticks is not None:
                creation._obj.low = ticks & 0xFFFFFFFF
                creation._obj.high = ticks >> 32
            return 1 if times_ok else 0

        def CloseHandle(h):
            closed.append(h)
            return 1
        self.closed = closed
        return types.SimpleNamespace(OpenProcess=OpenProcess, GetProcessTimes=GetProcessTimes,
                                     CloseHandle=CloseHandle)

    def start(self, k32):
        with windows(), unittest.mock.patch.object(T, "windows_kernel32", return_value=k32):
            return T.process_start(4242)

    def test_creation_time_in_unix_seconds(self):
        unix = 1767225600  # 2026-01-01 00:00 UTC
        ticks = (unix + 11644473600) * 10 ** 7
        self.assertAlmostEqual(self.start(self.kernel32(ticks=ticks)), unix, places=3)
        self.assertEqual(self.opened, (0x1000, False, 4242))
        self.assertEqual(self.closed, [1234])

    def test_no_process(self):
        self.assertIsNone(self.start(self.kernel32(handle=None)))
        self.assertEqual(self.closed, [])

    def test_times_fail_still_closes(self):
        self.assertIsNone(self.start(self.kernel32(times_ok=False)))
        self.assertEqual(self.closed, [1234])

    def test_no_kernel32(self):
        with windows(), unittest.mock.patch.object(T, "windows_kernel32", side_effect=AttributeError("WinDLL")):
            self.assertIsNone(T.process_start(1))


class LaunchedPath(unittest.TestCase):
    def test_localappdata(self):
        with no_getuid(), unittest.mock.patch.dict(os.environ, {"LOCALAPPDATA": "/la", "XDG_RUNTIME_DIR": "/x"}):
            self.assertEqual(T.launched_path(), os.path.join("/la", "tf3ctl", "launched.json"))

    def test_no_localappdata(self):
        env = dict(os.environ)
        env.pop("LOCALAPPDATA", None)
        with no_getuid(), unittest.mock.patch.dict(os.environ, env, clear=True):
            self.assertEqual(T.launched_path(),
                             os.path.join(tempfile.gettempdir(), "tf3ctl", "launched.json"))

    def test_linux_unchanged(self):
        with unittest.mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": "/run/user/5"}):
            self.assertEqual(T.launched_path(), "/run/user/5/tf3ctl/launched.json")
        env = dict(os.environ)
        env.pop("XDG_RUNTIME_DIR", None)
        with unittest.mock.patch.dict(os.environ, env, clear=True):
            self.assertEqual(T.launched_path(), "/tmp/tf3ctl-%d/launched.json" % os.getuid())

    def test_record_round_trip_without_uid(self):
        with tempfile.TemporaryDirectory() as d:
            folder = os.path.join(d, "tf3ctl")
            os.mkdir(folder, 0o755)
            with no_getuid(), unittest.mock.patch.dict(os.environ, {"LOCALAPPDATA": d}), \
                    unittest.mock.patch.object(T.os, "chmod", side_effect=AssertionError("chmod")), \
                    unittest.mock.patch.object(T, "OWNER", "tester"):
                got = T.write_launched(4242, cmd="launch")
                self.assertEqual(got["written"], os.path.join(folder, "launched.json"))
                rec, why = T.read_launched()
            self.assertEqual(os.stat(folder).st_mode & 0o777, 0o755)  # no chmod on Windows
            self.assertIsNotNone(rec, why)
            self.assertEqual((rec["owner"], rec["pid"]), ("tester", 4242))

    def test_not_a_folder_still_refused_without_uid(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "tf3ctl")
            open(path, "w").close()
            with no_getuid(), self.assertRaises(OSError):
                T._own_private_dir(path)

    def test_linux_other_owner_refused(self):
        with tempfile.TemporaryDirectory() as d:
            with unittest.mock.patch.object(T.os, "getuid", return_value=os.getuid() + 1):
                with self.assertRaises(OSError):
                    T._own_private_dir(d)


class SteamPaths(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.home = os.path.join(self.dir.name, "home")
        os.mkdir(self.home)

    def make_local(self, steam):
        local = os.path.join(steam, "userdata", "123", T.APP_ID, "local")
        os.makedirs(local)
        return local

    def roots(self, winreg, env):
        with windows(), unittest.mock.patch.dict(sys.modules, {"winreg": winreg}), \
                unittest.mock.patch.dict(os.environ, dict(env, HOME=self.home)):
            return T.userdata_roots()

    def test_registry_and_program_files(self):
        reg_steam = os.path.join(self.dir.name, "Reg Steam")
        pf = os.path.join(self.dir.name, "Program Files (x86)")
        a, b = self.make_local(reg_steam), self.make_local(os.path.join(pf, "Steam"))
        w = fake_winreg({"SteamPath": reg_steam + "/", "SteamExe": reg_steam + "/steam.exe"})
        self.assertEqual(self.roots(w, {"ProgramFiles(x86)": pf}), [a, b])
        self.assertEqual(w.opened, [("HKCU", r"Software\Valve\Steam")])

    def test_registry_key_missing(self):
        pf = os.path.join(self.dir.name, "pf")
        b = self.make_local(os.path.join(pf, "Steam"))
        self.assertEqual(self.roots(fake_winreg(key_missing=True), {"ProgramFiles(x86)": pf}), [b])

    def test_same_folder_once(self):
        pf = os.path.join(self.dir.name, "pf")
        b = self.make_local(os.path.join(pf, "Steam"))
        w = fake_winreg({"SteamPath": os.path.join(pf, "Steam")})
        self.assertEqual(self.roots(w, {"ProgramFiles(x86)": pf}), [b])

    def test_nothing_at_all(self):
        env = {k: v for k, v in os.environ.items() if k != "ProgramFiles(x86)"}
        with windows(), unittest.mock.patch.dict(sys.modules, {"winreg": None}), \
                unittest.mock.patch.dict(os.environ, dict(env, HOME=self.home), clear=True):
            self.assertEqual(T.windows_steam_registry(), {})
            self.assertEqual(T.userdata_roots(), [])

    def test_linux_does_not_ask_the_registry(self):
        w = fake_winreg({"SteamPath": "/nowhere"})
        with unittest.mock.patch.object(T.sys, "platform", "linux"), \
                unittest.mock.patch.dict(sys.modules, {"winreg": w}), \
                unittest.mock.patch.dict(os.environ, {"HOME": self.home}):
            a = self.make_local(os.path.join(self.home, ".local", "share", "Steam"))
            self.assertEqual(T.userdata_roots(), [a])
        self.assertEqual(w.opened, [])


class SteamCommand(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)

    def env(self, value):
        env = {k: v for k, v in os.environ.items() if k not in ("TF3_STEAM", "ProgramFiles(x86)")}
        if value is not None:
            env["TF3_STEAM"] = value
        return unittest.mock.patch.dict(os.environ, env, clear=True)

    def test_file_with_spaces_is_one_argument(self):
        exe = os.path.join(self.dir.name, "Program Files (x86)", "Steam", "steam.exe")
        os.makedirs(os.path.dirname(exe))
        open(exe, "w").close()
        with self.env(exe):
            self.assertEqual(T.steam_command(), [exe])
            with windows():
                self.assertEqual(T.steam_command(), [exe])

    def test_linux_split_unchanged(self):
        with self.env("flatpak run com.valvesoftware.Steam"):
            self.assertEqual(T.steam_command(), ["flatpak", "run", "com.valvesoftware.Steam"])
        with self.env('steam "-silent"'):  # no shell quoting on Linux, as before
            self.assertEqual(T.steam_command(), ["steam", '"-silent"'])
        with self.env(None):
            self.assertEqual(T.steam_command(), ["steam"])

    def test_windows_quoted_path_and_arguments(self):
        with self.env(r'"C:\Program Files (x86)\Steam\steam.exe" -silent'), windows():
            self.assertEqual(T.steam_command(), [r"C:\Program Files (x86)\Steam\steam.exe", "-silent"])

    def test_windows_default_from_registry(self):
        w = fake_winreg({"SteamExe": "c:/program files (x86)/steam/steam.exe"})
        with self.env(None), windows(), unittest.mock.patch.dict(sys.modules, {"winreg": w}):
            self.assertEqual(T.steam_command(), [os.path.normpath("c:/program files (x86)/steam/steam.exe")])

    def test_windows_default_program_files_then_steam(self):
        pf = os.path.join(self.dir.name, "pf")
        with self.env(None), windows(), unittest.mock.patch.dict(sys.modules, {"winreg": fake_winreg(key_missing=True)}):
            self.assertEqual(T.steam_command(), ["steam"])
            os.makedirs(os.path.join(pf, "Steam"))
            open(os.path.join(pf, "Steam", "steam.exe"), "w").close()
            with unittest.mock.patch.dict(os.environ, {"ProgramFiles(x86)": pf}):
                self.assertEqual(T.steam_command(), [os.path.join(pf, "Steam", "steam.exe")])

    def test_blank_is_the_default(self):
        with self.env("  "):
            self.assertEqual(T.steam_command(), ["steam"])

    def test_launch_passes_the_path_whole(self):
        exe = os.path.join(self.dir.name, "My Steam", "steam.exe")
        os.makedirs(os.path.dirname(exe))
        open(exe, "w").close()
        with self.env(exe), unittest.mock.patch.object(T, "game_pids", return_value=[]), \
                unittest.mock.patch.object(T, "remove_launched"), \
                unittest.mock.patch.object(T, "keep_last_log", return_value=None), \
                unittest.mock.patch.object(T.subprocess, "Popen", side_effect=OSError(2, "nope")) as popen:
            with self.assertRaises(T.ToolError) as cm:
                T.launch_game(timeout=1)
        argv = popen.call_args[0][0]
        self.assertEqual(argv[:3], [exe, "-applaunch", T.APP_ID])
        self.assertEqual(argv[3:], ["--script", T.STARTUP_SCRIPT])
        self.assertIn(exe, str(cm.exception))


class ReplaceFile(unittest.TestCase):
    def test_windows_retries_permission_error(self):
        calls = []

        def flaky(src, dst):
            calls.append((src, dst))
            if len(calls) < 3:
                raise PermissionError(13, "in use")
        with windows(), unittest.mock.patch.object(T.os, "replace", flaky), \
                unittest.mock.patch.object(T.time, "sleep") as sleep:
            T.replace_file("a", "b")
        self.assertEqual(len(calls), 3)
        self.assertEqual(sleep.call_count, 2)

    def test_windows_gives_up(self):
        with windows(), unittest.mock.patch.object(T.os, "replace", side_effect=PermissionError(13, "in use")) as r, \
                unittest.mock.patch.object(T.time, "sleep"):
            with self.assertRaises(PermissionError):
                T.replace_file("a", "b")
        self.assertEqual(r.call_count, T.REPLACE_TRIES)

    def test_linux_raises_at_once(self):
        with unittest.mock.patch.object(T.sys, "platform", "linux"), \
                unittest.mock.patch.object(T.os, "replace", side_effect=PermissionError(13, "x")) as r, \
                unittest.mock.patch.object(T.time, "sleep", side_effect=AssertionError("slept")):
            with self.assertRaises(PermissionError):
                T.replace_file("a", "b")
        self.assertEqual(r.call_count, 1)

    def test_other_errors_not_retried(self):
        with windows(), unittest.mock.patch.object(T.os, "replace", side_effect=FileNotFoundError(2, "x")) as r:
            with self.assertRaises(FileNotFoundError):
                T.replace_file("a", "b")
        self.assertEqual(r.call_count, 1)

    def test_real_replace(self):
        with tempfile.TemporaryDirectory() as d:
            a, b = os.path.join(d, "a"), os.path.join(d, "b")
            with open(a, "w") as f:
                f.write("new")
            with open(b, "w") as f:
                f.write("old")
            T.replace_file(a, b)
            with open(b) as f:
                self.assertEqual(f.read(), "new")
            self.assertFalse(os.path.exists(a))


class SmallFixes(unittest.TestCase):
    def test_stdout_log_and_staging_with_trailing_separator(self):
        self.assertEqual(T.stdout_log("/u/local/mod_presets/"), "/u/local/crash_dump/stdout.txt")
        self.assertEqual(T.stdout_log("/u/local/mod_presets"), "/u/local/crash_dump/stdout.txt")
        self.assertEqual(T.staging_dir("/u/local/mod_presets/"), "/u/local/staging_area")

    def test_read_json_reads_utf8(self):
        with unittest.mock.patch.object(T.subprocess, "run",
                                        return_value=subprocess.CompletedProcess([], 0, '{"name":"駅"}', "")) as run:
            self.assertEqual(T.read_json("x.lua"), {"name": "駅"})
        self.assertEqual(run.call_args.kwargs.get("encoding"), "utf-8")

    def test_main_reconfigures_a_non_utf8_console(self):
        class Stream(io.StringIO):
            def __init__(self, encoding):
                super().__init__()
                self._enc, self.asked = encoding, []

            @property
            def encoding(self):
                return self._enc

            def reconfigure(self, **kw):
                self.asked.append(kw)
        out, err = Stream("cp932"), Stream("utf-8")
        with unittest.mock.patch.object(T.sys, "stdout", out), unittest.mock.patch.object(T.sys, "stderr", err):
            with self.assertRaises(SystemExit):
                T.main(["--help"])
        self.assertEqual(out.asked, [{"encoding": "utf-8"}])
        self.assertEqual(err.asked, [])  # already UTF-8 (Linux): left alone

    def kill_with(self, sig):
        killed = []
        with unittest.mock.patch.object(T, "signal", sig), \
                unittest.mock.patch.object(T, "game_pids", return_value=[4242]), \
                unittest.mock.patch.object(T, "send", side_effect=T.ToolError("no answer")), \
                unittest.mock.patch.object(T, "read_pending", return_value=None), \
                unittest.mock.patch.object(T, "recent_other_owner", return_value=None), \
                unittest.mock.patch.object(T, "wait_exit", return_value=True), \
                unittest.mock.patch.object(T.os, "kill", lambda pid, s: killed.append((pid, s))):
            res = T._quit_game(timeout=0, kill=True)
        self.assertEqual(res["how"], "kill")
        return killed

    def test_kill_falls_back_to_sigterm_without_sigkill(self):
        self.assertEqual(self.kill_with(types.SimpleNamespace(SIGTERM=15)), [(4242, 15)])  # Windows' signal

    def test_kill_uses_sigkill_where_there_is_one(self):
        self.assertEqual(self.kill_with(types.SimpleNamespace(SIGTERM=15, SIGKILL=9)), [(4242, 9)])


class MergedCommandsOnWindows(unittest.TestCase):
    """The commands the configuration and mod-extension branches added (config, mod) on the Windows paths: loaded
    without fcntl, no uid, msvcrt for the locks, the configuration file's owner check over modChange."""

    def setUp(self):
        self.mod = load_tool("tf3ctl_win_merged", block_fcntl=True)
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        self.x = os.path.join(self.dir.name, "exchange")
        os.mkdir(self.x)
        open(os.path.join(self.x, self.mod.PREFIX + "hello_1.lua"), "w").close()  # the mod's file names the stamp
        self.cfg = os.path.join(self.dir.name, "config.json")
        self.msvcrt, self.locks = fake_msvcrt()
        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(windows(self.mod))
        stack.enter_context(no_getuid())
        stack.enter_context(unittest.mock.patch.dict(sys.modules, {"msvcrt": self.msvcrt}))
        stack.enter_context(unittest.mock.patch.dict(os.environ, {"LOCALAPPDATA": self.dir.name,
                                                                  "TF3CTL_CONFIG": self.cfg}))
        stack.enter_context(unittest.mock.patch.object(self.mod, "exchange_dir", lambda: self.x))
        stack.enter_context(unittest.mock.patch.object(self.mod, "game_pids", lambda: [4242]))

    def config(self, **cfg):
        with open(self.cfg, "w", encoding="utf-8") as f:
            json.dump(cfg, f)

    def ctl(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = self.mod.main(list(argv))
        return code, (json.loads(out.getvalue()) if out.getvalue().strip() else None), err.getvalue()

    def test_config_runs_without_fcntl(self):
        self.config(ownerCheck=True)
        code, res, err = self.ctl("config")
        self.assertEqual((code, res["file"]["state"], res["config"]["ownerCheck"], err), (0, "file", True, ""))

    def test_mod_change_is_refused_for_another_owner_before_any_lock(self):
        self.config(ownerCheck=True)
        with contextlib.redirect_stderr(io.StringIO()), unittest.mock.patch.object(self.mod, "OWNER", "bob"):
            self.mod.write_launched(4242, cmd="launch")  # %LOCALAPPDATA%\tf3ctl\launched.json, no uid check
        self.assertTrue(os.path.isfile(os.path.join(self.dir.name, "tf3ctl", "launched.json")))
        reads = [{"ok": False, "needsChange": True}]
        with unittest.mock.patch.object(self.mod, "wait_pickup", lambda folder, cid: None), \
                unittest.mock.patch.object(self.mod, "wait_answer", lambda *a, **k: reads.pop(0)):
            code, res, _ = self.ctl("--owner", "alice", "mod", "m", "c")
        self.assertEqual(code, 4)
        self.assertIn("refused 'modChange'", res["error"])
        self.assertEqual(reads, [], "modRead went (it only reads)")
        # modRead took the command lock once (msvcrt), modChange none: it was refused before anything was written
        self.assertEqual([c[0] for c in self.locks], [self.msvcrt.LK_LOCK, self.msvcrt.LK_UNLCK])

    def test_mod_change_of_the_owner_goes_through_lock_file_and_replace_file(self):
        self.config(ownerCheck=True)
        with contextlib.redirect_stderr(io.StringIO()), unittest.mock.patch.object(self.mod, "OWNER", "bob"):
            self.mod.write_launched(4242, cmd="launch")
        answers = [{"ok": False, "needsChange": True}, {"ok": True, "result": 2}]
        replaced = []
        real_replace = self.mod.replace_file
        with unittest.mock.patch.object(self.mod, "wait_pickup", lambda folder, cid: None), \
                unittest.mock.patch.object(self.mod, "wait_answer", lambda *a, **k: answers.pop(0)), \
                unittest.mock.patch.object(self.mod, "replace_file",
                                           lambda src, dst: replaced.append(dst) or real_replace(src, dst)):
            code, res, _ = self.ctl("--owner", "bob", "mod", "m", "c")
        self.assertEqual((code, res["result"]), (0, 2), res)
        self.assertEqual([c[0] for c in self.locks], [self.msvcrt.LK_LOCK, self.msvcrt.LK_UNLCK] * 2)
        cmd_files = [d for d in replaced if os.path.basename(d).startswith(self.mod.PREFIX + "cmd_")]
        self.assertEqual(len(cmd_files), 2, replaced)  # modRead and modChange, each written through replace_file

if __name__ == "__main__":
    unittest.main()
