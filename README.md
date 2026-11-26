# Remote Probe for Transport Fever 3

[日本語版 README](README.ja.md) · [Command reference](docs/REFERENCE.md) · [Known behaviour](docs/KNOWN_BEHAVIOR.md) · [For AI agents](AGENTS.md)

A Transport Fever 3 mod (`hummer_remote_probe`) and a command-line tool (`tools/tf3ctl.py`) for **mod authors**:
drive a running game from a shell, a test script or your AI coding agent, and check your mod without someone at
the keyboard.

It is not a bot that plays the game. It is a test harness. The round it is made for:

1. **Load**: start a new game (or load a test save) with your mod and the settings you want to test.
2. **Test**: place your constructions, build roads, buy vehicles, make lines, run the game to a date.
3. **Read values**: stations, lines, vehicles, industries, towns and finances, as JSON.
4. **Read the log**: errors, and what your mod printed.

Then change the mod and go round again.

The game's GUI Lua has no sockets, so the tool and the mod talk through small files in the game's userdata
folder: the tool writes a command, the mod reads it (every 0.25-2 s), runs it and writes the answer. Commands
print one JSON object (exceptions: `log` prints the log's lines, `--every` prints one JSON object per
line, and a tool error prints its reason on stderr only). The tool never clicks or presses keys. Details: "How it works" in the
[reference](docs/REFERENCE.md#how-it-works).

## Requirements

- Transport Fever 3 through Steam (tested on build 40444).
- **Linux**: the tested platform. **Windows**: the tool has code paths for Windows (paths, locks, the process
  list), but it has **not been tested on a Windows machine**; `frame` and `pointer` are Linux only. Reports of what
  works or not are welcome.
- Python 3.8 or newer, and `luajit` on the `PATH`.
- Optional: `ffmpeg` and Steam's background game recording (for `frame`, a still of the screen); the Track
  Connector mod (for `connect`).
- **Not together with Time Warp** (modId `mobarzik_faster_game_speed`): both replace the speed buttons. The mod
  lists it as incompatible, and the game warns when both are enabled.

More in [Requirements](docs/REFERENCE.md#requirements).

## Install

The game's local mods folder is `<Steam>/userdata/<your Steam id>/3493540/local/mods/` (on Linux `<Steam>` is
usually `~/.local/share/Steam`).

**From GitHub** (the mod and the tool in one folder):

```
cd ~/.local/share/Steam/userdata/<your Steam id>/3493540/local/mods/
git clone https://github.com/hummer98/tpf3-remote-probe.git hummer_remote_probe_1
```

The folder must hold `mod.json` directly. Run the tool as `python3 hummer_remote_probe_1/tools/tf3ctl.py ...`
(or put an alias in your shell).

**From mod.io**: subscribe to Remote Probe in the game. The mod.io download holds **only the mod, not the tool**
(mod.io does not take `.py` files), so get the tool from GitHub as well, and put it **outside** both the game's
local mods folder and mod.io's folder: there it would be a second copy of the same modId. Either clone the
repository somewhere else, or unzip the release zip (`hummer_remote_probe_1-vX.Y.Z.zip` on the GitHub releases
page) somewhere else. Use the version the mod.io page shows (`X.Y.Z` below):

```
git clone https://github.com/hummer98/tpf3-remote-probe.git ~/tpf3-remote-probe
git -C ~/tpf3-remote-probe checkout vX.Y.Z
python3 ~/tpf3-remote-probe/tools/tf3ctl.py launch
```

The tool finds the game by itself; it does not need to sit in the mod's folder. mod.io's client rebuilds the
subscribed mod's folder (on Linux under `~/mod.io/common/10640/mods/<number>/`) from scratch on every update, so do
not change anything there.

Then:

1. In the game, enable "Remote Probe" for a save and load it, or let the tool start the game (`launch`, below).
2. Check that it answers: `python3 tools/tf3ctl.py status` (`tools/` is in the folder you cloned or unzipped: the
   mod's own folder from GitHub, or the copy outside the mods folder if you subscribed on mod.io). The game log shows `[remote_probe] ready`.
   Before the mod has run once, `status` (and `state`, `log`) stop with exit code 2 and "no hello file from the
   mod yet": start the game with `launch` (below) first.

## A first round

The commands below are written as `tf3ctl.py`; run them as `python3 tools/tf3ctl.py` from the folder that holds `tools/` (the clone or
the unzipped folder, see Install).
`my_mod` stands for your mod's modId.

```
tf3ctl.py status          # does the game answer? (first time: exit 2 until a launch) date, speed, mods and their settings; gameState
tf3ctl.py config          # which switches are on, and from which file (no file: the defaults)

# the game not running: start it, and a new game from the main menu with your mod
# (already running: `quit` first, or `restart --no-kill --new ...`)
tf3ctl.py launch --new --size tiny --year 1900 --add my_mod

# ask the engine first, then build
tf3ctl.py build --res my_mod::/my_depot.con --at 600,40 --dry-run --engine-check
tf3ctl.py build --res my_mod::/my_depot.con --at 600,40

tf3ctl.py run --until 1900-03-01      # run to a date and pause
tf3ctl.py vehicles --state            # read values (also: lines, stations, industry-stocks, finance, ...)
tf3ctl.py log --grep my_mod --tail 40 # the game log; grep for what your mod prints (times are UTC)
tf3ctl.py quit
```

- `build --res` takes the construction's resource name: a mod's `content/<dir>/x.con.lua` is
  `<modId>::/<dir>/x.con`. `--dry-run --engine-check` builds nothing and returns the engine's errors,
  collisions and cost.
- Load a test save with a mod setting: `load probe-base --param my_mod:someSetting=2` (the number is the
  1-based index into the setting's `values` in `mod.json`).
- A changed mod file is picked up on the next load; a **new** file needs a restart of the game.
- Exit codes: 0 ok, 1 the game answered with an error, 2 no answer / tool error / unreadable configuration file,
  3 the game cannot answer where it is (menu, loading, closed: see `gameState`), 4 refused, nothing sent.

## Commands

One line each; every command has `--help`, and the [reference](docs/REFERENCE.md#usage) has a section for each.

| Group | Commands |
|---|---|
| Time | `status` (date, speed, mods; `luaLoad`: whether load / loadstring / setfenv exist), `speed N` (beyond the UI's 4x, capped at the game's estimate), `pause`, `calendar-speed [0.25]` (the base's calendar slider, 0.25x-4x: read, or set), `run --days / --months / --until` (then pause), `steps N` (simulation steps, a debug command), `poll` (how often the mod reads) |
| Game | `launch` / `restart` (with `--load SAVE` or `--new ...`), `quit`, `load SAVE` (with `--add` / `--remove` / `--param`), `save NAME`, `saves`, `info SAVE` (its mods and settings), `newgame` (from the main menu), `state` (from the game log; works in the menu), `company` |
| Reading | `entities`, `stations` (`--catchment`), `lines` (`--problems`), `depots`, `vehicles` (`--state`), `models`, `persons`, `industry-workers`, `industry-stocks`, `finance`, `running-costs`, `around` (what is near a point), `lanes`, `parcels`, `water`, `reach` (can a place be got to), `stock list` |
| Building (test maps) | `build` (a construction; `--remove`), `fit` (where a construction fits), `road` (a straight or curved piece; `--batch`), `lights --off`, `terrain`, `town` (and `town connections` / `connect` / `develop` / `size`), `connect` (track or road between two ends, with Track Connector) |
| Vehicles, money, lines | `buy`, `duplicate`, `replace`, `sell`, `money`, `line create / update / delete`, `rename` |
| GUI | `window` (open an entity's window), `event` (a react event), `tool` (music, calendar, notifications), `camera`, `build-tool`, `script-event`, `frame` (a still from Steam's recording, Linux), `pointer` (off by default) |
| Your mod's commands | `mod --list`, `mod <modId> <command> [JSON]` (commands your mod ships in `remote_probe_ext.lua`) |
| Test scenarios | `test FILE` (a JSON file of commands with checks of their answers and of the game's log: exit 0 passed, 5 failed) |
| Lua in the game | `eval 'CODE'` (read only, its value as JSON; `--gs` in the game script), `eval --write` (test saves only); off by default (`"eval": true` in the configuration file) |
| Log and files | `log`, `keep-log`, `clean`, `restore-profile` |
| Setups with several clients | `--owner`, `coop`, `config`; `modhub` (My Mods and mod.io uploads from the main menu) |

### Your mod's own commands

A mod can add commands of its own: ship `content/remote_probe_ext.lua` returning a table of commands, and call
them with `tf3ctl.py mod my_mod <command> '{"key": "value"}'`. `examples/remote_probe_ext_sample/` is a whole
example mod. The file's form is in [Other mods' commands](docs/REFERENCE.md#other-mods-commands-mod).

## Configuration file

`tools/tf3ctl.py` reads `$TF3CTL_CONFIG`, else `$XDG_CONFIG_HOME/tf3ctl/config.json`, else
`~/.config/tf3ctl/config.json`. **Without a file the defaults apply**, which suit one person with one game:

| Key | Default | When on / set |
|---|---|---|
| `ownerCheck` | off | game-changing commands go only to the game this `--owner` started |
| `coop` | off | `coop start` / `end`: share the game between a person and one client (needs `ownerCheck`) |
| `testSavePrefixes` | `["probe-"]` | the save names that count as test saves |
| `testSaveDigitFirst` | off | a name starting with one digit (`3-probe`) is a test save too |
| `pointer` | off | the `pointer` command |
| `officialModsByDefault` | off | new games (`launch` / `restart --new`, `newgame`) start with the official mods installed (`ug_*`) |
| `modhub.*` | empty | the folders `modhub validate` / `publish` may take |

`tools/config.example.json` lists every key. A file that cannot be read stops every command except `config`, which
says what is wrong. Details: [Configuration file](docs/REFERENCE.md#configuration-file).

## Safety

Read these before you point the tool, or an agent, at your game.

- **Use test saves.** Loading discards unsaved progress. Several commands change the save as no player can
  (`stock set`, `steps`, `money`, `town develop`, `company init`, ...); only a few of them check that a test save
  is loaded. Their answers carry `saveNote`.
- **`save` overwrites silently.** It does not check the name: a save of the same name is replaced without a
  question. Run `saves` first and use a new name of your own (for example `probe-...`).
- **Autosaves push out other autosaves.** The game keeps only a limited number of autosaves across all saves'
  names. A test game's autosaves count too, so an afternoon of tests can push out the autosaves of your real
  games. While you test, set a long autosave interval (`autosaveIntervalMinutes` in
  `<Steam>/userdata/<your Steam id>/3493540/local/settings.lua`, changed while the game is closed; the number
  kept is `autosaveKeepNumber`) and set it back
  afterwards.
- **No clicks, no keys.** The tool never sends mouse clicks or key presses. If a check needs the UI (a scroll, a
  button), add a test command or event to your mod and send it with `mod` or `event`.
- **Stopping**: use `quit`, and `restart --no-kill`. A plain `restart` and `quit --kill` SIGKILL a game that does
  not quit (unsaved progress is lost).
- **New games start from the main menu** (`launch --new`, `restart --new`). Starting one from inside a game
  crashed it, so there `newgame` only takes `--list` / `--dry-run`.
- **Speed** is capped at the game's own estimate of what it can sustain; above it frames get long and sound
  breaks up.
- **`--wait-for-start`** waits for a person to click "Start Game"; meanwhile not even `quit` works.

The game's quirks, the sequences that crashed it, and the dated record of what was checked in a game and what was
not are in [Known behaviour](docs/KNOWN_BEHAVIOR.md).

## For AI agents

[AGENTS.md](AGENTS.md) is written for coding agents (Claude Code, Codex, ...): how to read the answers, a first
round, and the rules to keep. Point your agent at it.

## MCP server

`tools/tf3ctl_mcp.py` offers the same commands as MCP (Model Context Protocol) tools, for clients that take MCP
servers. It is a thin wrapper over stdio: each tool runs one `tf3ctl.py` command and returns its JSON answer, exit
code and stderr. The tool list is read from `tf3ctl.py`'s own options, and tf3ctl's checks (owner, test saves, coop,
the configuration file) apply as on the command line. Python 3.8+, standard library only. Claude Code and Codex can
also run `tf3ctl.py` directly; the rules in [AGENTS.md](AGENTS.md) are the same either way.

```
claude mcp add tf3ctl -- python3 /path/to/tools/tf3ctl_mcp.py --owner my-agent
```

- `--owner` (else `$TF3CTL_OWNER`) is sent with every command. `--tf3ctl PATH` runs another copy of the tool.
- Tool names are the commands with `_` for `-` and spaces: `keep_log`, `stock_set`, `town_develop`. Arguments are
  the long options without `--` (`dry_run: true`, `add: ["my_mod"]`).
- Left out: `pointer` (it moves this machine's pointer) and `modhub publish` / `publish-clear` (uploading is a
  person's step). `--other-owner-ok` is not offered: on a game
  that a person started, use `coop start` with them. `vehicles` / `persons` with `every` need `count`.
- Calls run one at a time: a long call (`run`) holds the others, and a cancel from the client does not stop it.
- A call waits as long as the command's own `--timeout` values allow. Long commands (`launch`, `run`) may need a
  longer tool timeout in the client (Claude Code: the `MCP_TOOL_TIMEOUT` environment variable, in ms).

## More

- [docs/REFERENCE.md](docs/REFERENCE.md): every command, the configuration file, the mod settings, the
  environment variables, the tests and the implementation notes.
- [docs/KNOWN_BEHAVIOR.md](docs/KNOWN_BEHAVIOR.md): safety notes in full, what was checked in game, notes on the
  game's behaviour.
- [CHANGELOG.md](CHANGELOG.md).
- Tests (no game needed; in a clone from GitHub, the release zip has no `tests/`): `luajit tests/run.lua` and `python3 -m unittest discover -s tests`.

## Bugs and questions

Please open an issue on GitHub: https://github.com/hummer98/tpf3-remote-probe/issues. Say which command, what it
answered (the JSON), and the `[remote_probe]` lines of the game log.

## License

MIT. See [LICENSE](LICENSE.txt).

Track Connector (`ethan_track_connector`) is another author's mod. It is not part of this repository, not covered
by its licence, and not connected with this project; `connect` only loads it from the player's own installation.
