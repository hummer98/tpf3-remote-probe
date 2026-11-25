# AGENTS.md — for AI coding agents using Remote Probe

You are an agent (Claude Code, Codex, or similar) asked to test a Transport Fever 3 mod. This file tells you how
to drive the game with `tools/tf3ctl.py` safely. Start with `README.md`. The full reference is
`docs/REFERENCE.md`; read the section of a command there before you use it for the first time. The game's quirks,
the sequences that crashed it and what was checked in a game are in `docs/KNOWN_BEHAVIOR.md`.

`tools/` below is the one in the folder that holds the tool (a clone or an unzipped release). If the mod came from mod.io, the tool is not in it (mod.io takes no `.py`):
it is a copy from GitHub kept outside the game's mods folder (README, "Install"). Use that copy's path.

## What this is

A small mod (`hummer_remote_probe`) and a command-line tool. The tool writes a command file into the game's
userdata folder; the mod reads it, runs the command, and writes an answer. You never click or press keys.

The loop you run:

1. **Load** – start a new game or a save with the mod under test.
2. **Test** – place assets, make lines or vehicles, run to a date.
3. **Read values** – stations, lines, vehicles, industries, towns, finances, as JSON.
4. **Check the log** – errors, and what the mod printed.

Then fix the mod and go round again.

## Before anything

```
python3 tools/tf3ctl.py status     # does the game answer? where is it (gameState)?
python3 tools/tf3ctl.py config     # which switches are on, and from which file
```

Ask the person before the first command that changes the game. If you share the game with other agents or
people, use `--owner <your name>` on every command.

## Reading answers

- Commands print **one JSON object** on stdout. Parse it; do not scrape text. Exceptions: `log` prints the
  log's lines as text; `vehicles --every` and `persons --every` print one JSON object per line; on exit code `2`
  stdout may be empty and the reason is on stderr.
- Exit codes:
  - `0` ok
  - `1` the game answered with an error (read `error`)
  - `2` no answer, a tool error, or a configuration file that cannot be read (only `config` answers then: run it
    to see what is wrong)
  - `3` the game cannot answer where it is (menu, loading, closed): read `gameState`, try `status` again after a
    while, or start the game with `launch` if it is not running
  - `4` refused, nothing was sent (another owner's game, not a test save, off in the config file, or
    `mod ... --read-only` for a command not tagged `reads`, and a few more: the answer's `refused` says why).
    Do not retry with a flag that skips the check; tell the person why it was refused.
  - `5` (`test` only) a step of the scenario failed (read `steps`)
- The game log's times are UTC.

## A first round

```
python3 tools/tf3ctl.py launch --new --size tiny --year 1900 --add my_mod   # the game not running: starts it, then a new game
python3 tools/tf3ctl.py build --res my_mod::/my_depot.con --at 600,40 --dry-run --engine-check
python3 tools/tf3ctl.py build --res my_mod::/my_depot.con --at 600,40
python3 tools/tf3ctl.py run --until 1900-02-01
python3 tools/tf3ctl.py lines                     # line entity ids, stops, vehicles
python3 tools/tf3ctl.py vehicles --line <id> --state  # after `line create` / `buy`; else `vehicles --state`
python3 tools/tf3ctl.py log --grep my_mod --tail 40   # grep for what the mod prints
python3 tools/tf3ctl.py saves                     # pick a name not in the list
python3 tools/tf3ctl.py save probe-my-mod-1
python3 tools/tf3ctl.py quit
```

- Load a save with mod settings: `load "probe-base" --param my_mod:someSetting=2`. The number is the 1-based
  index into the setting's `values` in mod.json, not the value itself.
- A changed mod file needs a new load; a **new** file needs a restart of the game (the game caches mod files at
  start).
- To find where a construction fits, use `fit` before you pick coordinates by hand; after placing a station,
  read `stations --catchment <id>`.
- To check that people or cargo can get somewhere, use `reach` and `lines --problems`.

## Rules

- **Test saves only.** `save` does not check the name and overwrites a save of the same name silently: run
  `saves` first and use a new name of your own (for example `probe-...`). Never save over a person's save.
  Loading discards unsaved progress.
- **No clicks, no keys, no mouse.** If a check needs the UI to scroll or a button, add a test command to the mod
  (below) instead.
- **No flags that skip a check** unless the person asked for that command: `--other-owner-ok`, `--user-asked`,
  `--force`, `--ignore-errors`.
- **Speed:** `run` and `speed` are capped at the game's own estimate. For checks that do not look at the screen,
  `steps N` (20 steps ≈ 1 game day) is faster; send `speed 0` first. `calendar-speed` is a different thing: the
  base's calendar slider (how long a calendar day lasts), not how fast the simulation runs.
- **Stopping the game:** `quit`. Always use `restart --no-kill`: a plain `restart` (and `quit --kill`) SIGKILLs
  a game that does not quit, and unsaved progress is lost.
- **Debug commands** change the save as no player can: `stock set`, `steps`, `money`, `town develop` / `size` /
  `connect`, `company init`, `running-costs` writes, `lights --off`, `road --ignore-errors`, `eval --write`. Only
  four check the save's name (`road --ignore-errors`, `lights --off`, `running-costs` writes, `eval --write`);
  nothing stops the others on a person's save. Their answers carry `saveNote`.
- **`eval`** (off unless the configuration file has `"eval": true`) runs Lua in the game and returns its value as
  JSON. Plain `eval` is for reading; its environment drops the obvious writers but cannot stop every one
  (an engine object's methods are real), so send only code that reads. `eval --write` has every global and goes
  on test saves only. Neither saves: use `save`. A loop that never ends, or a walk over a huge table, freezes the
  game (there is no timeout), on a person's save too: send only short code that ends quickly.
  Prefer the probe's own commands when one exists.
- `--remove-buildings` on `build` and `road`, and `--remove-fields` on `road`, take town buildings and fields
  away as a player can when building by hand. No `saveNote`; use them on test saves.
- **New games start from the main menu** (`launch --new`, `restart --new`). Inside a game, `newgame` only takes
  `--list` / `--dry-run`.
- **Do not use `--wait-for-start`** unless a person is at the game: the load waits for a click, and meanwhile
  not even `quit` works.
- **Ask first** before `--lang` (it edits the game's profile.lua). Never run `modhub publish` unless asked.
- **Vehicles:** keep the default `--via gui`. Give a vehicle a line before you set its cargo (`stock set`).
- **Windows, events and tools** (`window`, `event`, `tool`) need the speed buttons on screen.
- **One command at a time.** The tool serialises clients with a lock; do not start several game-changing
  commands in parallel.

## Your mod's own test commands

Ship `content/remote_probe_ext.lua` in the mod under test; it returns a table of commands. Then:

```
python3 tools/tf3ctl.py mod --list                  # every mod with commands (runs each such file)
python3 tools/tf3ctl.py mod my_mod hello '{"who": "me"}'
```

`tag = "reads"` is only your mod's own claim: the probe does not check it, and sends such a command without the
owner check. Errors come back as `{ "ok": false, "kind", "error" }`. The file's form, `ctx` and deferred answers
are in "Other mods' commands" in `docs/REFERENCE.md`; a whole example mod is `examples/remote_probe_ext_sample/`.

## Test scenarios

A check you run again and again belongs in a scenario file: `python3 tools/tf3ctl.py --owner NAME test FILE` runs
its commands one by one through the same checks as on the command line, compares their answers with the file's
`expect` and looks at the game's log since the start (a `log` step). Exit `0` passed, `5` a step failed, `2` a
broken file (nothing was sent) or no answer. Read `steps[].why` and `steps[].checks` for what failed. A scenario
cannot carry `--force`, `--user-asked`, `--other-owner-ok` or `--ignore-errors`, start coop, `quit --kill`, or
`restart` without `--no-kill`. Check a new file with `--dry-run`
first. The format is in "Test scenarios" in `docs/REFERENCE.md`; a sample is `examples/test_scenario_sample.json`.

## When something is wrong

- No answer (exit 2): `status`; is the probe enabled for the save? `log --grep remote_probe`.
- The game crashed or froze: run `keep-log` and tell the person before you start the game again.
- A build fails: read the answer's error, try `--dry-run --engine-check`, and look at `around --at x,y`.
- Roads or track do not connect after two tries with the same idea: stop and ask the person to look.

## Platform

Linux is the tested platform. Windows has a minimal, untested port; `frame` and `pointer` are Linux only.
