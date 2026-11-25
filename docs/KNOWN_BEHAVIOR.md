# Remote Probe: known behaviour, safety notes and what was checked

[日本語](KNOWN_BEHAVIOR.ja.md) · [README](../README.md) · [Command reference](REFERENCE.md) · [For AI agents](../AGENTS.md)

The game's quirks, the sequences that crashed it, the limits, and the dated record of what was checked in a game
and what was not, moved here from the README unchanged. Sections the text names that are not here ("Usage",
"Configuration file", "Implementation notes", a command's own section, ...) are in [REFERENCE.md](REFERENCE.md).

## Safety

- **`newgame` does not work from inside a game.** The base `StartGame` expects no game to be running and TF3
  crashed (2026-11-15). In a save only `newgame --list` and `--dry-run` go (the tool and the mod refuse a
  start). Start new games with `restart --new` or `launch --new`, from the main menu.
- **Use `--via gui` (the default) for vehicle price tests.** `--via cmd` sends bare engine commands and leaves
  `purchaseTime` at 0; the engine does not fill it in, so the vehicle counts as bought at the start of the game and
  costs only its fully depreciated value (store price 48441, spent 261 in one test). The cmd way also must send
  `autoLoadConfig` with one entry per compartment: an empty one hit an engine assertion
  (`UpdateConfigFromModelIds`) that killed the game, uncatchable by `pcall` (2026-11-16). This is fixed in the
  mod, but the cmd ways of `buy` and `line` build engine structures by hand; try them on a small save first.
- **Speed is capped** at the game's own estimate of what it can sustain (`getEstimatedMaximumGameSpeed`, or 4
  before it is known). Above it the simulation falls behind, frames get long and sound breaks up (x8 on a save
  estimated at x5-6). `run` re-checks the estimate every 2 s. `--force` sends the speed as given.
- **Not every window can be opened as a tool.** The notification log's recipe needs parameters its base button
  passes, so pushed as a plain tool it hit a nil call and the GUI reloaded (2026-11-17). `tool notifications`
  therefore fires the base events `openNotificationLog` / `closeNotificationLog` instead. Before pointing `tool
  --module` at another module, check what its base button passes.
- **`quit --kill` and `restart` SIGKILL a game that does not quit**, losing unsaved progress (`restart --no-kill`
  gives up instead). Neither kills a game another `--owner` changed in the last 10 minutes without `--force`.
- **Loading discards unsaved progress**, and a load starts without waiting for the "Start Game" button (the base
  loading page waits for it; `--wait-for-start` keeps that). With `--wait-for-start` the loading screen stops at
  the button until a person clicks it, and meanwhile the mod takes no commands, not even `quit` (the tool never
  clicks it). Use it only with someone at the game. The tool says so on stderr while it waits, the answer
  after the click carries a `note`, and a load that times out names the button as the likely cause.
- `line delete` refuses a line with vehicles unless `--sell-vehicles` is given. It skips the base checks for
  missions and protected entities (it is meant for test saves).
- `stock set`, `steps` and the other debug commands go to any save: only `road --ignore-errors`, `lights --off`,
  `running-costs` writes and `eval --write` check that a test save is loaded. Use the rest on test saves too; their answers
  carry `saveNote` (the save's contents changed, saving keeps it).
- `money` books an "other" journal entry, which shows in the finance tables and charts.
- `buy` can buy models outside their years (the store's availability check is not applied).

## What was checked in game

Checked (build 40444, 2026-11-15 to 2026-11-17):

- `status` answers, also paused (the GUI script keeps running at speed 0). Reading the command file adds no log
  lines; each command adds one. The ESC menu and the in-game loading screen stop it.
- Speeds 8 / 16 / 64 are accepted, but on a mid-size save the rate topped out around x3 on average (x12.7 at most
  over one second), limited by CPU.
- `info` shows mod settings in the same shape as mod presets.
- `load` (also with `--param`; the other mod received the changed setting) loaded in 33 s and started without the
  button. A loaded game starts at speed 0. `save` (2.5 s). `run --until` stops on the date.
- `launch` / `restart` with the menu probe; `newgame` from the main menu (1900, temperate, 32x32).
- `buy --via cmd` and `depots` answer in the expected shape. An earlier version of the gui way bought at the store
  price.
- `frame`.
- `calendar-speed` (2026-11-25, on a flat test map): the default day length read 4000 ms (1x). 0.25 set 16000 ms
  and the date then moved 2 days in 40 s of game time, against 10 at 1x; 0 stopped the date; 1 set 4000 ms again.

Not checked yet:

- The `--via gui` ways of `buy`, `duplicate`, `replace` and `sell` in their current form (run in the speed
  control's recipe), and whether that recipe runs while paused.
- `money`: whether the balance changes in game and the entry stays in the save.
- Line commands beyond the first test (`stations`, `stations --near`, `lines` and a two-stop `line create --via gui`
  worked on a small save): `line update`, `line delete`, `--cargo`, `buy --line` and the `--via cmd` way. Try them on
  a small save first; the details are under Implementation notes.
- `window` and `event` opening windows, the speed label's position and look, `tool` closing a window with `pop`.
- The ×8 / ×16 buttons in game: their look and width beside the base buttons, the lit button, and the speed they set.
- `calendar-speed`: whether the set value shows in the "Calendar Speed" slider in the "Weather and Time" window.
- Whether `app.quit` ends the game without a confirmation dialog.
- `connect`, entirely: see "Connections" under Implementation notes for what may go wrong, riskiest first.
- `build`, entirely (see "One construction on the map"). `road`, entirely (see "One straight road").
- The gui way's own send of a bought vehicle to its line and the refusal's reason; `lines --problems`;
  `stations --catchment`.
- `terrain`, `terrain --probe-api` and `newgame --editor`, entirely (see "The ground in a rectangle").
- `town`, entirely (see "One town").
- `town connections` and `town connect`, entirely (see "Town connections").
- `company` and `company init`, entirely (see the new game's company progression under "Saves and new games").
- `stock` and `steps`, entirely (see "Stocks and simulation steps"): meant for test saves.
- `parcels`, entirely (read only, see "Town building parcels along a road").
- `lanes` and `around --lanes`, entirely (read only, see "A road's lanes").
- `around`, entirely (read only, see "What stands near a point"); `build` / `road` `hits`, `--remove-buildings`,
  `--join-streets` and `joins`; `build --dry-run --engine-check` and `fit`, entirely.
- `persons`, entirely (read only): whether the sim person components and the quality counts read in the GUI script.
- `reach` and `persons --town` / `--destination`, entirely (read only, see "Whether a place can be got to").
- `modhub publish` of an update (see "Uploading a mod"). `modhub status`, `validate` and a first upload were
  checked on 2026-11-22.

## Proposals sent from a game script (a mod's script event)

Checked in game on 2026-11-26.

- A game script's `handleEvent` can send `api.cmd.sendCommand(api.cmd.make.buildProposal(...)` /
  `makeWorldBuildProposalCmd(...), callback)`, and the callback runs. The base's on-road stop (`small_old.con`) was
  placed this way, with `replaceSegment` and a `SimpleStreetProposal.EdgeObject`. The answer's `resultEntities` came
  back empty.
- An edge-object `.con` that holds a subconstruction with a stock (an OUTPUT `stockList`), sent the same way,
  crashed the game natively. No Lua error was logged. Whether the stock is the cause was not isolated.
- An off-road construction (placed with `build`) can hold a station and a stock-only subconstruction (no industry).
  A game script can write that stock's amount.
- A construction built with `build --no-owner` got a road joined to its mouth with `road --from-node`. A line
  through its station could be made, but putting a vehicle on that line was refused with "Unkown" (sic). In the
  picture its mouth showed a no-entry sign. The cause is not known.

## Notes

- **Exchange folder.** `recordings` is used first. The base lists every file in `mod_presets` as a mod preset (no
  extension filter), so files there showed up in the player's preset list; nothing in the base GUI lists
  `recordings` or `keyframes` (the debug camera tool uses them). `saveUserdata` never overwrites a file, so every
  answer gets a new name and the tool removes old ones. `clean` removes every probe file (the current load's hello
  and command file too when no load is running: the game closed or crashed, at the main menu, or starting).
- **Answers.** Every command gets exactly one answer. Exception: when a load or new game replaces the script while
  a command waits, no answer comes and the tool times out. Asynchronous commands (vehicles, lines, money) give up
  after 60 s with what they have; the tool waits 90 s for them. `state` needs no mod: it reads the game's log and
  processes. Lists in answers are written as `[]` when empty.
- **Pickup.** When a command is not picked up and the game is not in a game (by its log), the tool stops after 3
  s with exit code 3 and withdraws the command. The ESC menu and dialogs do not show in the log, so those end as
  "no answer" after 30 s.
- **`run`** ends as `stalled` when the date does not move for 20 s. When the tool exits early (timeout, Ctrl-C) it
  sets speed 0. The answer waits for the pause command's callback (or says `stopConfirmed: false` after 2 s).
- **`save`.** The save callback reports no success, so `ok` means the save is in the list afterwards; `overwrote`
  says whether one of that name existed.
- **Status.** `modParams` lists every enabled mod (`{}` for one without settings), so it shows whether `--add` /
  `--remove` took effect. There is no API to read the enabled mod list at run time.
- **Main menu.** Loading or starting a game from outside React before mod.io is ready sent the base main menu
  into a dialog branch in its recipe body (`GetApi() must not be called in the recipe itself`) and the menu UI
  reloaded (the load went on; 2026-11-16). The menu probe therefore waits up to 30 s for mod.io (while
  `restrictedModeAllowed=false`, 2-3 s after the menu appears, or while mods download) and logs
  `waits: mod.io is not ready` / `waited N s for mod.io`. A second load or new game sent while it waits is
  refused (`still waiting`). A new game from the menu takes the climate's default town names (temperate and
  subarctic: European); the name list is not part of `StartGameParams`. A save loaded by hand stops the menu probe
  as soon as game time can be read, so the in-game probe takes over.
- **`--script`** (found in the game binary, 2026-11-16) takes a resource path (`<mod>::/<file>`). A disk path, or
  a file missing from the base `_content.json`, is "not cached" and the game exits. If `startup.lua` fails to load,
  the game goes on without the menu probe.
- **`quit`.** The probe calls `app.quit` the frame after it answered (after a save in progress). SIGTERM only opens
  the game's quit menu (2026-11-16). `restart` waits 5 s after the game ended before launching, since Steam may
  still count it as running. The game's main thread is named "Main Thread", so `pgrep -x TransportFever3` does not
  find it; the tool looks at command lines.
- **Speed buttons and label.** The base speed buttons are 0/1/2/4 only and select none for other speeds. The mod
  replaces `game_bar_widgets.GameSpeedControl` with a `react-replacement-config` (order 500) and draws the base
  recipe unchanged (`CallOriginalRecipe`), then a second button group with ×8 and ×16, then the label. The extra
  group lights from the same `gameSpeedHelper.getSpeed()` the base buttons use, and its click sends
  `api.cmd.makeGameSetSpeedCmd` from `onValueChange`, where the base buttons send theirs; it does not go through
  the helper's `setSpeed`, which clamps to `api.gui.game.getEstimatedMaximumGameSpeed()`. The helper picks the new
  speed up from the `GAME_SPEED` component on its next step. Note that the base's pause key resumes through the
  helper, so resuming 16x from a pause is clamped like a base button. The buttons hold text (`×8`, `×16`), since the
  base has icons up to 4x only, and are a group of their own beside the base group. A mod that replaced the recipe
  before this one (lower order) is drawn instead of the base buttons and of the ×8 / ×16 group, with the label
  beside it. Time Warp (mod.io 6453396) replaces the same recipe with 8x/16x buttons of its own (order 10) and sets
  the same CSS widths, so only the stylesheet loaded last would size the bar: it is listed in `incompatibilities`
  (the game warns, but can be told to go on). GW Faster Game Speed swaps the module's table at run
  time, and only one of the two takes effect. Mods that replace the whole game bar or `game.tl` with a copy
  (Upkeep Inspector, Buy Industries) still call `game_bar_widgets.GameSpeedControl` and the same
  `GameSpeedHelper`, so the replacement applies there too. UI Overhaul does not touch the speed control. No game
  API is called in the recipe body or its steps: react runs them on worker threads too, and
  `api.util.getApplicationTime` there crashed TF3 with SIGSEGV right after every load (2026-11-15). Game calls
  happen in `react.enqueueJoin` and in the buttons' `onValueChange`, on the main thread.
- **`frame`** takes the last frame of the newest finished chunk of Steam's background recording
  (`userdata/<id>/gamerecordings/video/bg_3493540_*`) with ffmpeg: with the UI, a few seconds old, at the
  recording's resolution, without focusing the window or sending keys. The recording folder is chosen by its last
  written chunk, not by its mtime: Steam trims old chunks out of a stopped recording, which bumps that folder's
  mtime, and once picked a recording stopped 81 minutes earlier. The game's own `takeScreenshot` wrote no file
  in a test (it seems to be for photo mode), so the `screenshot` command was taken out.
- **`window`** opens with `react.fireEvent(nil, "selectEntity", {entity})`, as the base statistics and line
  windows do. Events can only be fired from inside react, so the GUI script writes the request into the GUI save
  data (`api.gui.game.setGuiSaveData`, kept per mod in C++) and the speed buttons' recipe reads it in
  `react.enqueueJoin`. A plain Lua table shared between the two never reached the recipe (they are separate Lua
  states). Requests left from the previous game are dropped on load, so a request sent right after a load may be
  answered "took it as old; not run". The answer waits for the recipe, as `event`'s does.
  With `--manager` (a line by `--line NAME` or `--entity ID`, the company's own only) it fires
  `openVehicleManager` with `{openWithLineEntity = line}` instead, as the line window's "Manage Line" button and the
  statistics' line rows do; the manager selects the line on its next step. Not checked in game yet.
- **`event`** takes a react event name and, as its parameter, a JSON object of plain values. `window`, `event`,
  `tool` and `build-tool`'s events go into a queue in the GUI save data (`opens`), and the recipe fires them one per
  read (every 0.5 s), oldest first. Until 2026-11-22 this was a single slot: of two events sent in the same second
  only the second was fired. The answer comes once the recipe has fired the event and said so (under
  `<mod>.open`), with `"relayed": true` and `relayedInSec` (about 0.5-1 s, plus 0.5 s for each request queued
before it), so a script that sends events one
  after another gets them in that order. The answer is an error when the recipe's `fireEvent` raised
  (`"relayed": true`, "relayed, but ..."), when the recipe did not take it within 10 s (`"relayed": false`: no game
  on screen, the ESC menu or a dialog, or another mod's speed control in its place; it is then dropped and never
  fires later; the 10 s count from when it was queued, so only about 19 can wait at once), or when it was left from
before the recipe's first read (a load). A request still waiting when a game loads gets no answer: tf3ctl gives
up after 20 s with "no answer". Relayed means fired, not that a
  listener acted on it: whether a window opened shows in `frame` or the log.
- **`tool`** pushes the module's tool on the game's tool stack as the base buttons do
  (`gameCtx.toolStack:get():getApi().push(tool, nil, {gameCtx})`). Only tools a module returns can be opened:
  music (`/gui/music_player/music_player.tl`) and calendar (`game_bar_widgets.CalendarEditorTool`); statistics are
  local to `statistics.tl`. `--module` and `--field` point at other modules.
