-- Remote probe: lets a tool outside the game (tools/tf3ctl.py) set the game speed beyond the UI's 4x, run until a
-- date, list, inspect, load (with other mods or mod settings) and save games, so a mod's in-game checks can run
-- without someone at the keyboard. It exists to find out which of these work and how fast the game can go.
--
-- GUI Lua has no io and no sockets: everything goes through app.saveUserdata / app.loadUserdata in a folder the
-- game owns (the first of DIRS where a saved file loads back). saveUserdata never overwrites a file (seen by the
-- Network Data Bridge mod and in mod_presets/standard_modN), so every answer gets a new name and the tool, which
-- has plain file access, replaces the command file and deletes old answers. Files "<name>.lua":
--   remote_probe__hello_<stamp>       written once per load: who we are and the game state; the tool waits for a
--                                      new one after a load
--   remote_probe__cmd_<stamp>         created here with id 0, then rewritten by the tool:
--                                      { id = <n>, cmd = "<name>", args = { ... } }; a new id is a new command
--   remote_probe__res_<id>[_<tag>]    answers: { id = <n>, json = "<json>" }; tag = p<k> for progress, ack for the
--                                      first answer of a load
local MOD = (getOwningModId and getOwningModId()) or "hummer_remote_probe"
local core = (ug_require or require)(MOD .. "::/remote_core.lua")

-- recordings first: the base lists every file of mod_presets as a mod preset (mod_selector_page.tl,
-- getAllModPresets, no extension filter), so files there showed up in the player's preset list. Nothing in
-- the base GUI lists recordings or keyframes (the debug camera tool uses them); mod_presets stays the last resort.
local DIRS = { "recordings", "keyframes", "mod_presets" }
local ACTIVE_SEC = 120
local PROGRESS_SEC = 15
local ASYNC_TIMEOUT_SEC = 60
local STALL_SEC = 20 -- real seconds without game time moving before a run gives up
local ERROR_FORGET_SEC = 600
local CAP_CHECK_SEC = 2 -- how often a run compares its speed with the game's estimate
local CAP_HOLD_SEC = 4 -- how long the estimate must allow a higher speed before a run raises it
local STOP_CONFIRM_SEC = 2 -- how long a finished run waits for the pause command's callback

local G = { phase = "init", frames = 0, lastId = 0, nextPoll = 0, lastCmdAt = -1e9, failures = 0, tasks = {} }

-- mod settings, read once per load; pollIdle / pollActive can be changed by the poll command until the next load
local function readOptions()
	local ok, all = pcall(function() return api.engine.config.getModParams() end)
	G.options = core.options(ok and all and core.field(all, MOD) or nil)
	G.pollIdle, G.pollActive = G.options.pollIdle, G.options.pollActive
end

-- level 1: always (ready, loads, errors); 2: each command; 3: progress and receipts too
local function say(msg, level)
	if (level or 1) > ((G.options and G.options.logLevel) or 2) then return end
	local text = core.LOG .. msg
	if debugPrint then pcall(debugPrint, text) else print(text) end
end

local function appTime()
	local ok, t = pcall(api.util.getApplicationTime)
	if ok and type(t) == "number" then return t end
	return os.clock()
end

-- seconds on a clock that moves within a frame, for how long a read took (around's ms, catchment's readMs, a
-- search's time budget): getApplicationTime stays the same all through one frame (around and catchment read 0 ms
-- every time, 2026-11-23), and os.clock is the process's CPU time on Linux. api.type.Clock counts microseconds
-- from when it was made (api/type.d.tl); appTime when it cannot be made or read.
local fineClock = nil
local function fineTime()
	if fineClock == nil then
		local ok, c = pcall(function() return api.type.Clock.new() end)
		fineClock = (ok and c ~= nil) and c or false
	end
	if fineClock then
		local ok, us = pcall(function() return fineClock:getTime() end)
		if ok and tonumber(us) then return tonumber(us) / 1e6 end
		-- (never mixed with appTime afterwards: the two count from different starts)
		fineClock = false
	end
	return appTime()
end

local function try(fn)
	local ok, v = pcall(fn)
	if ok then return v end
	return nil
end

---------------------------------------------------------------------------------------------------------------------
-- files

local function trySave(name, tbl)
	return pcall(function() app.saveUserdata(G.dir, name, tbl) end)
end

local function answer(id, payload, tag)
	payload.id = id
	local name = core.PREFIX .. "res_" .. string.format("%d", id) .. (tag and ("_" .. tag) or "")
	local ok, err = trySave(name, { id = id, json = core.json(payload) })
	if not ok then say("could not write " .. name .. ": " .. tostring(err)) end
end

-- What the speed control (gui/remote_speed.script.lua) shows and does: the label text and a window to open.
-- Handed over in the GUI save data, which the game keeps per mod in C++: the recipe runs in a Lua state of its
-- own (a shared Lua table never reached it, 2026-11-15 22:49 JST) and reads it in react.enqueueJoin, on the main
-- thread. Written only when it changes; cleared at each load, since the game also saves it into the savegame.
local function publishUi(fields)
	if G.menu then return end -- no game, so no speed control to read it (and no GUI save data to write)
	G.ui = G.ui or {}
	for k, v in pairs(fields) do G.ui[k] = v end
	local text = core.json(G.ui)
	if text == G.uiSent then return end
	local copy = {}
	for k, v in pairs(G.ui) do copy[k] = v end
	local ok, err = pcall(function() api.gui.game.setGuiSaveData(MOD, copy) end)
	if ok then
		G.uiSent = text
	elseif not G.uiWarned then
		G.uiWarned = true -- once: the label and window requests would otherwise vanish without a word
		say("setGuiSaveData failed, so no speed label and no windows: " .. tostring(err))
	end
end

-- what the GUI save data holds now (status shows it, to check in game that the hand-over works)
local function uiReadBack()
	local ok, d = pcall(function() return api.gui.game.getGuiSaveData(MOD) end)
	if not ok then return { error = tostring(d) } end
	return core.plain(d)
end

---------------------------------------------------------------------------------------------------------------------
-- window, event and tool requests: queued in the GUI save data (opens), run by the speed control one per read in
-- the order sent, and answered once its report (OPEN_REPORT_KEY) says it ran. One slot used to hold them, so a
-- second request within the same read wrote over the first (2026-11-22 18:30 JST: of hints_set and hint_reset sent
-- in the same second, only hint_reset reached AoM), and the answer said ok before anything had run.

local OPEN_REPORT_KEY = MOD .. ".open"

local function publishOpens()
	local list = {}
	for i, p in ipairs(G.opens or {}) do list[i] = p.open end
	publishUi({ opens = list })
end

-- open: { entity / manager / event / tool }. done(report, waited) with report nil when the speed control did not
-- take it within core.OPEN_RELAY_SEC (else { error, skipped }); nil done: nobody waits (the build tool's events).
-- Returns the request number.
local function queueOpen(open, done)
	G.uiSeq = (G.uiSeq or (os.time and os.time() or 0) * 1000) + 1
	open.seq = G.uiSeq
	G.opens = G.opens or {}
	G.opens[#G.opens + 1] = { open = open, done = done, at = appTime(), deadline = appTime() + core.OPEN_RELAY_SEC }
	publishOpens()
	return open.seq
end

-- each frame: the requests the speed control has reported on, or that waited too long, leave the queue and are
-- answered (a dropped one is not run later, so the answer stays true)
local function stepOpens()
	if not G.opens or #G.opens == 0 then return end
	local reports = core.openReports(try(function() return api.gui.game.getGuiSaveData(OPEN_REPORT_KEY) end))
	local t, keep, changed = appTime(), {}, false
	for _, p in ipairs(G.opens) do
		local r = reports[p.open.seq]
		if r or t >= p.deadline then
			changed = true
			if not r then say("window/event request " .. p.open.seq .. ": the speed control did not take it in "
				.. core.OPEN_RELAY_SEC .. " s; dropped", 1) end
			if p.done then
				local ok, err = pcall(p.done, r, t - p.at)
				if not ok then say("window/event answer: " .. tostring(err)) end
			end
		else
			keep[#keep + 1] = p
		end
	end
	if changed then
		G.opens = keep
		publishOpens()
	end
end

-- extra: more fields of the error answer (other mods' commands, remote_modext.lua, say what kind of error it was)
local function failWith(id, msg, extra)
	G.failedId = id
	say("command " .. tostring(id) .. " failed: " .. tostring(msg))
	local p = { ok = false, error = tostring(msg) }
	for k, v in pairs(extra or {}) do if p[k] == nil then p[k] = v end end
	answer(id, p, "error")
end

local function fail(id, msg) return failWith(id, msg) end

---------------------------------------------------------------------------------------------------------------------
-- game state

local function world() return api.engine.util.getWorld() end

local function now()
	local t = { appTime = appTime(), frames = G.frames }
	local gt = try(function() return api.engine.getComponent(world(), api.type.ComponentType.GAME_TIME) end)
	t.gameTime = gt and tonumber(try(function() return gt.gameTime end)) or 0
	local sp = try(function() return api.engine.getComponent(world(), api.type.ComponentType.GAME_SPEED) end)
	if sp then
		t.speedup = tonumber(try(function() return sp.speedup end))
		t.millisPerDay = tonumber(try(function() return sp.millisPerDay end))
	end
	t.estimatedMaxSpeed = tonumber(try(function() return api.gui.game.getEstimatedMaximumGameSpeed() end))
	local d = try(function() return api.engine.util.getCalendarDate(t.gameTime) end)
	if d then
		t.date = { year = tonumber(try(function() return d.year end)), month = tonumber(try(function() return d.month end)),
			day = tonumber(try(function() return d.day end)) }
	end
	return t
end

local function setSpeed(n, onDone)
	api.cmd.sendCommand(api.cmd.makeGameSetSpeedCmd(n), function(_, success)
		if onDone then onDone(success) end
	end)
end

local function modParamsNow()
	return core.plain(try(function() return api.engine.config.getModParams() end))
end

---------------------------------------------------------------------------------------------------------------------
-- savegames

local function namespace() return app.SaveGameNamespace.getSavegame() end

local function listSaves()
	local out = {}
	for _, s in ipairs(core.toList(app.findAllSavegames(namespace()))) do
		out[#out + 1] = { saveName = core.field(s, "saveName"), path = core.field(s, "path"),
			timestamp = core.field(s, "timestamp"), size = core.field(s, "size") }
	end
	return out
end

-- by saveName, or by path; nil and the candidates' count when nothing matches
local function findSave(name)
	if type(name) ~= "string" or name == "" then return nil, "give the save's name" end
	local saves = core.toList(app.findAllSavegames(namespace()))
	for _, s in ipairs(saves) do
		if core.field(s, "saveName") == name or core.field(s, "path") == name then
			local id = api.type.SavegameId.new()
			id.path = core.field(s, "path")
			id.saveGameName = core.field(s, "saveName")
			id.saveGameNamespace = namespace()
			return id
		end
	end
	return nil, string.format("no save named %q (%d saves; try the saves command)", name, #saves)
end

local function modNames(mods)
	local out = {}
	for _, m in ipairs(core.toList(mods)) do
		-- a nameless entry would go back to loadGame as "userdata: 0x..." and name a mod that does not exist
		local name = core.field(m, "name")
		if type(name) == "string" and name ~= "" then out[#out + 1] = name end
	end
	return out
end

-- the save's SaveGameData arrives asynchronously, as in the base load page; onData runs on a later frame
local function withSaveData(id, saveName, onData)
	local saveId, err = findSave(saveName)
	if not saveId then return fail(id, err) end
	local async = app.getSavegameInfo(saveId)
	G.tasks[#G.tasks + 1] = { id = id, async = async, saveId = saveId, onData = onData, started = appTime() }
end

local function stepTasks()
	local keep = {}
	for _, t in ipairs(G.tasks) do
		local done = try(function() return t.async:isCompleted() end)
		if done then
			local ok, err = pcall(function() t.onData(t.async:get(), t.saveId) end)
			if not ok then fail(t.id, err) end
		elseif appTime() - t.started > ASYNC_TIMEOUT_SEC then
			pcall(function() t.async:abort() end)
			fail(t.id, "the save's info did not arrive in " .. ASYNC_TIMEOUT_SEC .. " s")
		else
			keep[#keep + 1] = t
		end
	end
	G.tasks = keep
end

---------------------------------------------------------------------------------------------------------------------
-- commands

local handlers = {}
local finishRun
local modhub -- remote_modhub.lua, made further down (load, newgame and quit, defined before it, cancel its job)

-- (defined before stepLoad and stepStart, which call it: a local defined later is a nil global there,
-- which raised on every load, 2026-11-15 22:10-22:14 JST)
-- after loadGame / startGame this script's game should end: if it keeps running, nothing happened, and the tool
-- (already acked) would wait for its whole timeout. The old script does not run while the new game loads.
local REPLACE_WATCH_SEC = 30

local function watchReplace(id, what)
	G.replaceWatch = { id = id, what = what, deadline = appTime() + REPLACE_WATCH_SEC }
end

-- in the main menu (startup.lua) this script may go on running while the game loads, and maybe in it too:
-- its work is done once a game is on its way, and the new game's own copy answers from then on
local function afterReplace(id, what)
	if G.menu then
		G.phase = "off"
		say(what .. " called from the main menu; the menu copy stops here")
		return
	end
	watchReplace(id, what)
end

local function stepReplaceWatch()
	local w = G.replaceWatch
	if w and appTime() >= w.deadline then
		G.replaceWatch = nil
		fail(w.id, string.format("%s returned but this game kept running for %d s: nothing was loaded", w.what,
			REPLACE_WATCH_SEC))
	end
end


-- what the speed label beside the buttons shows (gui/remote_speed.script.lua), when it shares this Lua state
local function publishRun(r)
	core.shared.run = r and { target = r.target.date, owner = r.owner } or nil
end

local function runInfo()
	if G.finishing then return { id = G.finishing.id, finishing = true, owner = G.finishing.owner } end
	return G.run and { id = G.run.id, target = G.run.target.date, speed = G.run.speed, owner = G.run.owner } or nil
end

-- every run gets exactly one final answer: a run that something else ends answers with an error saying why
local function cancelRun(reason)
	-- a run that already reached its target and waits for the pause result answers first: a load ends this
	-- script, and a later speed command would show up in its state
	if G.finishing then finishRun(G.finishing, false) end
	local r = G.run
	if not r then return end
	G.run = nil
	publishRun(nil)
	answer(r.id, { ok = false, error = "cancelled: " .. reason, summary = r.summary() }, "error")
end

-- whether this game is the map editor: as the GUI says (api.gui.game.isMapEditor) and as the base's mod params
-- hold it (modParams[""].isMapEditor); either may be nil when it cannot be read
local function mapEditorNow()
	local gui = try(function() return api.gui.game.isMapEditor() end)
	local params = modParamsNow()
	local base = type(params) == "table" and params[""] or nil
	local mp = type(base) == "table" and base.isMapEditor or nil
	local function flag(v) if v == true or v == false then return v end return nil end
	return { gui = flag(gui), modParams = flag(mp) }
end

function handlers.status(c)
	local t = now()
	answer(c.id, { ok = true, version = core.VERSION, mod = MOD, stamp = G.stamp, dir = G.dir, menu = G.menu == true, state = t,
		defaultSavegameId = try(function() return api.gui.game.getDefaultSavegameId() end),
		modParams = modParamsNow(), run = runInfo(), poll = { idle = G.pollIdle, active = G.pollActive },
		ui = (not G.menu) and uiReadBack() or nil,
		logLevel = G.options.logLevel, lastAction = G.lastAction, mapEditor = (not G.menu) and mapEditorNow() or nil })
end

function handlers.speed(c)
	local n = core.speedArg(c.args.speed)
	if n == nil then return fail(c.id, "speed must be a whole number >= 0") end
	cancelRun("speed command " .. c.id)
	local sent = core.capSpeed(n, now().estimatedMaxSpeed, c.args.force == true)
	setSpeed(sent, function(success)
		answer(c.id, { ok = success == true, speed = sent, requested = n, capped = sent ~= n, state = now() })
	end)
end

-- calendar speed (remote_core.lua, calendarInfo): the base's 0.25x-4x slider, GAME_SPEED.millisPerDay
local CAL_WAIT_SEC = 5 -- after the command's callback, how long to wait for the component to show the sent value
G.calWaits = {}

local function calendarNow()
	local sp = try(function() return api.engine.getComponent(world(), api.type.ComponentType.GAME_SPEED) end)
	local ms = sp and tonumber(try(function() return sp.millisPerDay end)) or nil
	local def = tonumber(try(function() return api.util.getDefaultDayDuration() end))
	return core.calendarInfo(ms, def)
end

-- reads only: no command is sent
function handlers.calendarSpeed(c)
	local cal = calendarNow()
	if cal.millisPerDay == nil then return fail(c.id, "cannot read GAME_SPEED.millisPerDay") end
	answer(c.id, { ok = true, calendar = cal, steps = core.CALENDAR_FACTORS, state = now() })
end

-- as the slider: makeGameSetCalendarSpeedCmd(millisPerDay). It leaves a run alone (it does not touch the
-- simulation speed), but a calendar at 0 stands, so a run toward a date never gets there
function handlers.calendarSpeedSet(c)
	local before = calendarNow()
	if before.millisPerDay == nil then return fail(c.id, "cannot read GAME_SPEED.millisPerDay") end
	local ms, err = core.calendarSpeedArg(c.args, before.defaultDayMs)
	if ms == nil then return fail(c.id, err) end
	local w = { id = c.id, before = before, sent = ms, requested = { factor = c.args.factor, millisPerDay = c.args.millisPerDay },
		started = appTime() }
	-- queued only once the command is out: if making or sending it throws, the caller's pcall answers the error,
	-- and a queued wait would answer the same id a second time when it ran out
	api.cmd.sendCommand(api.cmd.makeGameSetCalendarSpeedCmd(ms), function(_, success)
		w.success = success == true
		w.calledAt = appTime()
	end)
	G.calWaits[#G.calWaits + 1] = w
end

-- answers each calendarSpeedSet once the component shows the sent value, the engine refused it, or the wait ran out
local function stepCalendar()
	if #G.calWaits == 0 then return end
	local keep = {}
	for _, w in ipairs(G.calWaits) do
		local after = calendarNow()
		local base = { before = w.before, after = after, sent = w.sent, requested = w.requested }
		if w.success == false then
			failWith(w.id, "the engine refused the calendar speed command", base)
		elseif w.success == true and after.millisPerDay == w.sent then
			base.ok = true; base.state = now()
			answer(w.id, base)
		elseif appTime() - (w.calledAt or w.started) > CAL_WAIT_SEC then
			failWith(w.id, w.success and ("the command was accepted, but millisPerDay did not become the sent value in "
				.. CAL_WAIT_SEC .. " s") or ("no answer from the engine to the command in " .. CAL_WAIT_SEC .. " s"), base)
		else
			keep[#keep + 1] = w
		end
	end
	G.calWaits = keep
end

function handlers.run(c)
	local t = now()
	local target, err = core.runTarget(c.args, t)
	if not target then return fail(c.id, err) end
	local n = core.speedArg(c.args.speed or 4)
	if n == nil or n < 1 then return fail(c.id, "speed must be a whole number >= 1") end
	cancelRun("run command " .. c.id)
	local meter = core.newMeter(t.gameTime, t.appTime)
	local force = c.args.force == true
	local sent = core.capSpeed(n, t.estimatedMaxSpeed, force)
	-- requested: what was asked; speed: what is sent now, following the game's estimate (stepRun)
	local run = { id = c.id, owner = core.owner(c.args), target = target, requested = n, speed = sent, force = force,
		meter = meter, startDate = t.date, nextProgress = t.appTime + PROGRESS_SEC, progress = 0,
		lastGameTime = t.gameTime, movedAt = t.appTime, nextCap = t.appTime + CAP_CHECK_SEC, speedChanges = 0 }
	run.summary = function()
		local s = now()
		return { from = run.startDate, to = s.date, target = target.date, speed = run.speed, requested = run.requested,
			speedChanges = run.speedChanges, measured = core.meterSummary(meter, s.gameTime, s.appTime), state = s }
	end
	G.run = run
	publishRun(run)
	setSpeed(sent, function(success)
		if success ~= true and G.run == run then
			G.run = nil
			publishRun(nil)
			fail(c.id, "the game refused speed " .. sent)
		end
	end)
	say(string.format("run %d: speed %d (asked %d) until %d-%02d-%02d", c.id, sent, n, target.date.year,
		target.date.month, target.date.day), 2)
end

-- f: a run that reached its target; confirmed: the pause command's callback said success
finishRun = function(f, confirmed)
	G.finishing = nil
	local s = f.summary
	s.state = now()
	s.stopConfirmed = confirmed
	answer(f.id, s)
	say(string.format("run %d done: %.0f game s in %.1f real s (x%.1f)%s", f.id, s.measured.gameSec,
		s.measured.realSec, s.measured.overall or 0, confirmed and "" or ", pause not confirmed"), 2)
end

local function stepFinish()
	local f = G.finishing
	if f and appTime() >= f.deadline then finishRun(f, false) end
end

local function stepRun()
	local r = G.run
	if not r then return end
	local t = now()
	core.meterStep(r.meter, t.gameTime, t.appTime, t.estimatedMaxSpeed)
	-- Compared with the game's live speed, not the last one sent: the base UI clamps 2-4 by itself
	-- (game.tl), and a pause by the player, a dialog or another mod must stay a pause (then the stall
	-- detector below reports it). Lower at once, since an overloaded game stutters; raise only after the
	-- estimate has allowed it for CAP_HOLD_SEC, so a flickering estimate does not change the speed every check.
	local live = t.speedup
	if not r.force and live and live > 0 and t.appTime >= r.nextCap then
		r.nextCap = t.appTime + CAP_CHECK_SEC
		local want = core.capSpeed(r.requested, t.estimatedMaxSpeed, false)
		local change = false
		if want < live then
			change, r.raiseSince = true, nil
		elseif want > live then
			r.raiseSince = r.raiseSince or t.appTime
			change = t.appTime - r.raiseSince >= CAP_HOLD_SEC
		else
			r.raiseSince = nil
		end
		if change then
			say(string.format("run %d: speed %d -> %d (game estimate x%s)", r.id, live, want,
				tostring(t.estimatedMaxSpeed)), 3)
			r.speed, r.raiseSince, r.speedChanges = want, nil, r.speedChanges + 1
			setSpeed(want)
		end
	end
	if t.gameTime ~= r.lastGameTime or G.saving then
		-- a save may hold game time for a while; that is not the run being stuck
		r.lastGameTime, r.movedAt = t.gameTime, t.appTime
	end
	if core.reached(r.target, t) then
		G.run = nil
		publishRun(nil)
		-- the measurement ends here; the answer waits for the pause command, so its state shows speed 0. A lost
		-- callback must not leave the tool waiting: stepFinish answers anyway after STOP_CONFIRM_SEC.
		local s = r.summary()
		s.ok = true
		local f = { id = r.id, owner = r.owner, summary = s, deadline = t.appTime + STOP_CONFIRM_SEC }
		G.finishing = f
		setSpeed(0, function(success)
			if G.finishing == f then finishRun(f, success == true) end
		end)
	elseif t.appTime - r.movedAt > STALL_SEC then
		-- paused by the player, a dialog or another mod, or a refused speed: say so instead of waiting for an hour
		G.run = nil
		publishRun(nil)
		local s = r.summary()
		s.ok, s.error = false, string.format("stalled: game time did not move for %d s (speed now %s)", STALL_SEC,
			tostring(t.speedup))
		answer(r.id, s, "error")
		say("run " .. r.id .. " stalled")
	elseif t.appTime >= r.nextProgress then
		r.nextProgress = t.appTime + PROGRESS_SEC
		r.progress = r.progress + 1
		local s = r.summary()
		s.ok, s.running = true, true
		answer(r.id, s, "p" .. r.progress)
		say(string.format("run %d at %d-%02d-%02d, x%.1f", r.id, s.state.date and s.state.date.year or 0,
			s.state.date and s.state.date.month or 0, s.state.date and s.state.date.day or 0, s.measured.overall or 0), 3)
	end
end

-- args: idle and/or active seconds, until the next load (then the mod settings apply again)
function handlers.poll(c)
	local p, err = core.pollArgs(c.args)
	if not p then return fail(c.id, err) end
	G.pollIdle = p.idle or G.pollIdle
	G.pollActive = p.active or G.pollActive
	answer(c.id, { ok = true, poll = { idle = G.pollIdle, active = G.pollActive } })
	say(string.format("polling: idle %g s, active %g s", G.pollIdle, G.pollActive), 2)
end

-- towns, lines, vehicles, stations, industries, warehouses: { id, name } (vehicles, stations and lines: the
-- player's own)
local function entitiesOf(kind)
	local CT = api.type.ComponentType
	local player = try(function() return api.engine.util.getPlayer() end)
	if player == nil and kind ~= "town" and kind ~= "industry" and kind ~= "warehouse" then
		error("the player's company is unknown")
	end
	local ids
	if kind == "town" then
		ids = api.engine.getEntitiesWithComponent(CT.TOWN)
	elseif kind == "line" then
		ids = api.engine.system.lineSystem.getLinesForPlayer(player)
	elseif kind == "vehicle" then
		ids = api.engine.getEntitiesWithComponent(CT.TRANSPORT_VEHICLE, { requireOwnedByPlayer = player })
	elseif kind == "station" then
		-- no owner filter: a single-player game, and the owner may sit on the stations rather than the group
		ids = api.engine.getEntitiesWithComponent(CT.STATION_GROUP)
	elseif kind == "industry" then
		ids = api.engine.getEntitiesWithComponent(CT.INDUSTRY)
	elseif kind == "warehouse" then
		-- no owner filter, as industries: whose it is shows in its window, not here
		if CT.WAREHOUSE == nil then error("this game has no ComponentType.WAREHOUSE") end
		ids = api.engine.getEntitiesWithComponent(CT.WAREHOUSE)
	end
	local out = {}
	for _, id in ipairs(core.toList(ids)) do
		local name = try(function() return api.engine.util.getEntityName(id) end)
		if type(name) ~= "string" or name == "" then
			name = try(function() return api.engine.getComponent(id, CT.NAME).name end)
		end
		local e = { id = id, name = tostring(name or "") }
		-- industries: their construction too, which mods' scripts address (a rebuild, an upgrade's script-event),
		-- not always the id next to the industry's
		if kind == "industry" then
			e.construction = try(function()
				return api.engine.system.streetConnectorSystem.getConstructionEntityForSubconstruction(id)
			end)
			if type(e.construction) ~= "number" or e.construction < 0 then e.construction = nil end
		end
		-- warehouses: the construction build gives (WAREHOUSE.construction) and the stock list entity that stock
		-- list / stock set use (WAREHOUSE.stockList; both take the construction too), with its stocks' count and
		-- capacity in all (a warehouse's stocks come from its modules: none, no stocks)
		if kind == "warehouse" then
			local w = try(function() return api.engine.getComponent(id, CT.WAREHOUSE) end)
			local con, sl = tonumber(core.field(w, "construction")), tonumber(core.field(w, "stockList"))
			e.construction = con and con >= 0 and con or nil
			if sl and sl >= 0 and try(function() return api.engine.entityExists(sl) end) == true then
				e.stockList = sl
				local list = try(function() return api.engine.getComponent(sl, CT.STOCK_LIST) end)
				if list ~= nil then
					local n, cap = 0, 0
					for _, st in ipairs(core.toList(core.field(list, "stocks"))) do
						n, cap = n + 1, cap + (tonumber(core.field(st, "capacity")) or 0)
					end
					e.stocks, e.capacity = n, cap
				end
			end
		end
		out[#out + 1] = e
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

-- args: kind, grep (substring, any case), limit
function handlers.entities(c)
	local kind = c.args.kind
	if not core.ENTITY_KINDS[kind] then return fail(c.id, "kind must be town, line, vehicle, station, industry or warehouse") end
	local list, out = entitiesOf(kind), {}
	local grep = type(c.args.grep) == "string" and c.args.grep:lower() or nil
	local limit = tonumber(c.args.limit) or 200
	for _, e in ipairs(list) do
		if not grep or e.name:lower():find(grep, 1, true) then
			if #out < limit then out[#out + 1] = e end
		end
	end
	answer(c.id, { ok = true, kind = kind, total = #list, entities = out })
end

-- a window, event or tool request queued for the speed control, answered once it ran: payload (ok = true) with
-- relayed = true, or an error answer saying why it did not run (relayed = false) or what failed when it did
local function queueAnswered(c, open, payload)
	local seq
	seq = queueOpen(open, function(r, waited)
		payload.seq = seq
		if r == nil or r.skipped then
			payload.ok, payload.relayed, payload.note = false, false, nil
			payload.error = r == nil and ("the speed control did not take it in " .. core.OPEN_RELAY_SEC .. " s (no game on "
				.. "screen, the ESC menu or a dialog, or another mod's speed control in place of this one); not run, and "
				.. "it will not run later")
				or "the speed control was built again after it was sent (a load?) and took it as old; not run"
			return answer(c.id, payload, "error")
		end
		payload.relayed, payload.relayedInSec = true, waited
		if r.error then
			payload.ok, payload.note = false, nil
			payload.error = "relayed, but " .. r.error
			return answer(c.id, payload, "error")
		end
		answer(c.id, payload)
	end)
	return seq
end

-- args: kind + name, or entity (id); focus (camera); closeAll; manager (a line, opened in the line manager
-- instead of its own window). The window itself is opened by the speed control (gui/remote_speed.script.lua) with
-- react.fireEvent(nil, "selectEntity", ...), as the base statistics and line windows do, or "openVehicleManager"
-- as their "Manage Line" buttons do: events need a react context, which this script does not have.
function handlers.window(c)
	if c.args.closeAll then
		local okC, errC = pcall(function() api.gui.closeAllWindows() end)
		if not okC then return fail(c.id, "closeAllWindows: " .. tostring(errC)) end
		return answer(c.id, { ok = true, closedAll = true })
	end
	local manager = c.args.manager == true
	if manager and c.args.kind ~= nil and c.args.kind ~= "line" then
		return fail(c.id, "manager opens a line: give kind line and name, or the line's entity")
	end
	local entity, name = tonumber(c.args.entity), nil
	if not entity then
		local kind = c.args.kind
		if not core.ENTITY_KINDS[kind] then return fail(c.id, "give entity, or kind (town, line, vehicle, station, industry, warehouse) and name") end
		local hit, err = core.matchEntity(entitiesOf(kind), c.args.name)
		if not hit then return fail(c.id, err) end
		entity, name = hit.id, hit.name
	elseif manager then
		-- the base offers "Manage Line" on the company's own lines only; another id would open the manager with
		-- nothing selected (or the base's step would fail on it), which looks like success on the screen
		for _, e in ipairs(entitiesOf("line")) do
			if e.id == entity then name = e.name end
		end
		if name == nil then return fail(c.id, "entity " .. tostring(entity) .. " is not one of the company's lines (tf3ctl lines)") end
	end
	-- answered once the speed control has fired the event that opens it (within about a second)
	local payload = { ok = true, entity = entity, name = name, focused = c.args.focus == true, manager = manager or nil,
		note = manager and "whether the manager selected the line shows only on the screen" or nil }
	queueAnswered(c, manager and { manager = entity } or { entity = entity }, payload)
	if c.args.focus then
		local okF, errF = pcall(function() api.gui.camera.focusEntity(entity) end)
		if not okF then say("focusEntity: " .. tostring(errF)) end
	end
end

-- args: name (react event), param. Fired by the speed control (a react context), like the window command:
-- e.g. "example_window.show" { welcome = true } opens another mod's window without that mod's help
function handlers.event(c)
	local ev, err = core.eventRequest(c.args)
	if not ev then return fail(c.id, err) end
	queueAnswered(c, { event = ev }, { ok = true, event = ev.name,
		note = "fired by the speed control (relayed); whether a listener acted on it shows only on the screen or in the log" })
end

-- args: id, name, param. Sent to the game scripts at once (a command, as a mod's button sends it), not through
-- the speed control: a game script listens to commands, not react events. Whether a script took it shows only in
-- its log
function handlers.scriptEvent(c)
	local ev, err = core.scriptEventRequest(c.args)
	if not ev then return fail(c.id, err) end
	api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd("", ev.id, ev.name, ev.param), function(_, success)
		if success == false then say("script event " .. ev.id .. " " .. ev.name .. ": refused by the engine", 1) end
	end)
	answer(c.id, { ok = true, id = ev.id, event = ev.name,
		note = "sent; whether the game script acted on it shows only in its log (tf3ctl log --grep ...)" })
end

-- args: entity, name. Answered from the command's callback, with the name read back, since the engine may refuse
-- (an entity that has no name of its own and no stem) or keep the old one
function handlers.rename(c)
	local r, err = core.renameRequest(c.args)
	if not r then return fail(c.id, err) end
	local before = try(function() return api.engine.util.getEntityName(r.entity) end)
	api.cmd.sendCommand(api.cmd.makeEntitySetNameCmd(r.entity, r.name), function(_, success)
		local after = try(function() return api.engine.util.getEntityName(r.entity) end)
		if success == false then
			say("rename " .. r.entity .. ": refused by the engine", 1)
			return answer(c.id, { ok = false, error = "the engine refused the name (makeEntitySetNameCmd failed)",
				entity = r.entity, before = before }, "error")
		end
		-- a station's id renames its group (the stem), so the station itself may read back otherwise
		local note = after ~= r.name and "the entity reads back another name: give the station group's id (stations) to check" or nil
		answer(c.id, { ok = true, entity = r.entity, requested = r.name, before = before, name = after, note = note })
	end)
end

-- args: name (music, calendar) or module + field; close. Pushed onto (or popped from) the game's tool stack by
-- the speed control, as the base's own buttons do
function handlers.tool(c)
	local t, err = core.toolRequest(c.args)
	if not t then return fail(c.id, err) end
	queueAnswered(c, { tool = t }, { ok = true, module = t.module, field = t.field, close = t.close,
		note = "pushed (or popped) by the speed control (relayed); whether the window shows is on the screen only" })
end

-- camera: x, y, distance, angle, pitch (getCameraData's Vec5f) and the height above the terrain
local function cameraNow()
	local cam = api.gui.camera
	local v = cam.getCameraData()
	local h = try(function() return cam.getHeightAboveTerrain() end)
	return { x = v.x, y = v.y, distance = v.z, angle = v.w, pitch = v.q, heightAboveTerrain = h }
end

-- args: none (read), set (x,y[,distance[,angle[,pitch]]], the rest kept), entity, or focus (x,y,z) + distance.
-- A GUI API on the main thread (this script runs there). Answers what the camera reads after the move.
function handlers.camera(c)
	local a, cam = c.args, api.gui.camera
	local given = (a.set ~= nil and 1 or 0) + (a.entity ~= nil and 1 or 0) + (a.focus ~= nil and 1 or 0)
	if given > 1 then return fail(c.id, "give one of set, entity or focus") end
	if a.set ~= nil then
		local set, err = core.numberList(a.set, 5)
		if not set then return fail(c.id, "set: " .. err) end
		local t, errT = core.cameraTarget(cameraNow(), set)
		if not t then return fail(c.id, errT) end
		cam.setCameraData(api.type.Vec5f.new(t.x, t.y, t.distance, t.angle, t.pitch))
	elseif a.entity ~= nil then
		local e = tonumber(a.entity)
		if not e or e ~= math.floor(e) or not api.engine.entityExists(e) then return fail(c.id, "no such entity: " .. tostring(a.entity)) end
		cam.focusEntity(e)
	elseif a.focus ~= nil then
		local p, err = core.numberList(a.focus, 3)
		if not p or #p ~= 3 then return fail(c.id, "focus: " .. (err or "give x,y,z")) end
		local d = tonumber(a.distance)
		if a.distance ~= nil and d == nil then return fail(c.id, "distance must be a number") end
		local L = core.CAMERA_LIMITS
		if d == nil then d = cameraNow().distance end
		if math.abs(p[1]) > L.xy or math.abs(p[2]) > L.xy or math.abs(p[3]) > L.xy
			or not (d >= L.distance[1] and d <= L.distance[2]) then -- not (..) also refuses a NaN
			return fail(c.id, string.format("focus within %g, distance %g-%g", L.xy, L.distance[1], L.distance[2]))
		end
		cam.focusPosition(api.type.Vec3f.new(p[1], p[2], p[3]), d)
	end
	answer(c.id, { ok = true, camera = cameraNow(), moved = given == 1 })
end

-- build tool: base events through the speed control (as event): the toolbar's menu event, then the filter and the
-- tab select; G.buildTool holds what is left to send.
-- The filter is the construction menu's (game.tl setMenuFilter); it is undone here on time, so a tool that died
-- midway does not leave the menu showing one building. A load or a quit builds a new GUI, without the filter.
local function sendEvent(name, param)
	queueOpen({ event = { name = name, param = param } }, nil)
end

local function clearBuildFilter(why)
	sendEvent("setMenuFilter", core.menuFilter(nil))
	say("build tool: menu filter cleared (" .. why .. ")", 2)
	G.buildTool = nil
end

-- G.buildTool.queue: the events still to send, each at its own time (one per GAP, so the menu opens before the
-- next); clearAt: when the filter goes, if one was set
local function stepBuildTool()
	local b = G.buildTool
	if not b then return end
	local t = appTime()
	local nextEv = b.queue[1]
	if nextEv then
		if t >= nextEv.at then
			table.remove(b.queue, 1)
			sendEvent(nextEv.name, nextEv.param)
			if not b.clearAt and not b.queue[1] then G.buildTool = nil end
		end
	elseif b.clearAt and t >= b.clearAt then
		clearBuildFilter("after " .. b.seconds .. " s")
	end
end

-- args: res, template, seconds, menu; or close
function handlers.buildTool(c)
	if c.args.close then
		local was = G.buildTool ~= nil
		clearBuildFilter("close command")
		return answer(c.id, { ok = true, closed = true, wasOpen = was })
	end
	local r, err = core.buildToolRequest(c.args)
	if not r then return fail(c.id, err) end
	if r.res then
		local idx = try(function() return api.res.constructionRep.find(r.res) end)
		if type(idx) ~= "number" or idx < 0 then return fail(c.id, "no such construction: " .. r.res) end
	end
	local events = {}
	-- a filter from an earlier request still waiting for its clear: a menu alone would drop that clear, so it goes
	-- first (with res, the new filter replaces it and gets its own clear)
	if not r.res and G.buildTool and G.buildTool.clearAt then
		events[#events + 1] = { name = "setMenuFilter", param = core.menuFilter(nil) }
	end
	if r.menu then events[#events + 1] = { name = r.menu, param = {} } end
	if r.res then
		events[#events + 1] = { name = "setMenuFilter", param = core.menuFilter(r.tag) }
		events[#events + 1] = { name = "constructionMenuSelectTabForConstruction", param = { resName = r.res } }
	end
	local t = appTime()
	for i, ev in ipairs(events) do ev.at = t + (i - 1) * core.BUILD_TOOL_GAP end
	local first = table.remove(events, 1)
	sendEvent(first.name, first.param)
	local clearIn = r.res and (#events * core.BUILD_TOOL_GAP + r.seconds) or nil
	G.buildTool = (r.res or events[1]) and { queue = events, seconds = r.seconds, clearAt = clearIn and t + clearIn } or nil
	local notes = { "the placement preview shows only with the mouse pointer over the 3D view (tf3ctl pointer)" }
	if r.res then
		table.insert(notes, 1, "a building not available in this year is not listed: the tab then opens without it")
		table.insert(notes, 2, "module tabs (dynamic) are not covered")
	end
	if r.menu then
		notes[#notes + 1] = "the menu opens on its first item; with res, the filter and the select follow"
		notes[#notes + 1] = "a menu whose toolbar button this game mode lacks (town, industry, tracks, warehouses) "
			.. "may have no listener: then nothing opens"
	end
	answer(c.id, { ok = true, tag = r.tag, menuEvent = r.menu, clearInSec = clearIn,
		clearAtUnix = clearIn and os.time and (os.time() + math.ceil(clearIn)) or nil, notes = notes })
end

-- answered first; the game quits on the next frame, once the answer is on disk
function handlers.quit(c)
	local held = modhub.blocks()
	if held then return fail(c.id, "quit " .. held) end
	cancelRun("quit command " .. c.id)
	modhub.cancel("quit command " .. c.id)
	answer(c.id, { ok = true, quitting = true, afterSave = G.saving == true })
	G.pendingQuit = c.id
end

-- the menu copy (startup.lua) in a game someone loaded by hand: the game may go on calling it there, and a
-- newgame from inside a save crashes the game. A game exists once it has a game time (none in the main menu).
local function stepMenuGone()
	if not G.menu then return end
	local gt = try(function() return api.engine.getComponent(world(), api.type.ComponentType.GAME_TIME) end)
	if gt ~= nil then
		G.phase = "off"
		say("a game is running; the menu copy stops here")
	end
end

local function stepQuit()
	if not G.pendingQuit then return end
	-- not in the middle of app.saveGame: the save would be cut off
	if G.saving then return end
	local id = G.pendingQuit
	G.pendingQuit = nil
	say("quitting for command " .. id)
	local ok, err = pcall(function() app.quit() end)
	if not ok then say("app.quit failed: " .. tostring(err)) end
end

function handlers.saves(c)
	answer(c.id, { ok = true, saves = listSaves() })
end

function handlers.info(c)
	withSaveData(c.id, c.args.save, function(data)
		local info = core.field(data, "info")
		answer(c.id, { ok = true, save = c.args.save, mods = modNames(core.field(info, "mods")),
			modParams = core.plain(core.field(info, "modParams")), campaign = core.field(info, "campaign"),
			mission = core.field(info, "mission") })
	end)
end

-- args: save, mods = { set | add | remove }, params = { [modId] = { [key] = index } }, dryRun, waitForStart
-- In the main menu a load or a new game waits until mod.io is ready. When a load starts while the menu shows
-- another page, the base MainMenu recipe switches itself to its progress page from the recipe body (main_menu.tl,
-- "if progress:old()[2] ~= ''"). If mod.io is not ready then, setPage takes its dialog branch, which calls getApi()
-- there: "GetApi() must not be called in the recipe itself", ReactFramework::Step() failed, the menu UI reloads
-- (2026-11-16 14:53:47Z, a tf3ctl load 2 s after the menu came up). "Not ready" is mostly the first 2-3 s of the
-- menu: mod.io logs "restrictedModeAllowed=false" on entering it and "=true" once its check is done; the failed
-- load fell in that window, the good ones after it. So allowRestrictedMode == false is the case that matters;
-- busy (downloads) is the base's other one. The base's own load buttons switch to the progress page first and
-- load from its onMount, so they never take that branch; the probe runs outside React and cannot. After
-- MENU_LOAD_WAIT_SEC it goes anyway: the reload did no harm, the load went on.
local MENU_LOAD_WAIT_SEC = 30

-- the base's test (main_menu.tl isBusyWithModManagement / isRestrictedModeAllowed) on the publishing backend
-- (mod_manager_react_util.getModPublishBackendId); nil when api.modhub cannot be read
local function modhubNotReady()
	local ok, v = pcall(function()
		for _, b in ipairs(api.modhub.getBackendIDs()) do
			local caps = api.modhub.getCapabilities(b)
			if not caps.isInfoOnly then
				return caps.allowRestrictedMode == false or api.modhub.getModManagementState(b).busy == true
			end
		end
		return false
	end)
	if ok then return v end
	return nil, v
end

-- p: G.pendingLoad or G.pendingStart. True when it may go now; logs only when it had to wait or could not tell.
local function menuMayReplace(p, what)
	if not G.menu then return true end
	local notReady, err = modhubNotReady()
	if notReady == nil then
		if not G.saidNoModhub then
			G.saidNoModhub = true
			say("cannot read mod.io's state (" .. tostring(err) .. "): " .. what .. " goes without waiting for it")
		end
		return true
	end
	if notReady then
		p.waitSince = p.waitSince or appTime()
		if appTime() - p.waitSince < MENU_LOAD_WAIT_SEC then
			if not p.saidWait then
				p.saidWait = true
				say(what .. " for command " .. p.id .. " waits: mod.io is not ready, and the menu fails to switch pages then")
			end
			return false
		end
		say("mod.io still not ready after " .. MENU_LOAD_WAIT_SEC .. " s: " .. what .. " goes anyway (the menu UI may reload once)")
		return true
	end
	if p.waitSince then say(what .. " for command " .. p.id .. " waited " .. string.format("%.1f", appTime() - p.waitSince) .. " s for mod.io") end
	return true
end

-- a load or new game still waiting for mod.io: a second one would overwrite it and leave its tool without an answer
local function waitingReplace()
	local p = G.pendingLoad or G.pendingStart
	if not p then return nil end
	return "command " .. p.id .. " (" .. (G.pendingLoad and "load" or "new game") .. ") is still waiting to replace the game; try again"
end

function handlers.load(c)
	withSaveData(c.id, c.args.save, function(data, saveId)
		local info = api.type.SaveGameDetails.new(core.field(data, "info"))
		local mods = core.mergeMods(modNames(core.field(info, "mods")), c.args.mods, MOD)
		local orphan = core.paramsWithoutModsError(c.args.params, mods)
		if orphan then return fail(c.id, orphan) end
		local params
		if c.args.params ~= nil and next(c.args.params) ~= nil then
			local err
			params, err = core.mergeParams(core.plain(core.field(info, "modParams")), c.args.params)
			if not params then return fail(c.id, err) end
		end
		local list = {}
		for _, name in ipairs(mods) do
			local m = api.type.ModId.new()
			m.name = name
			list[#list + 1] = m
		end
		info.mods = list
		-- without --param the save's own value goes back untouched, whatever type the engine uses for it
		if params then info.modParams = params end
		local plan = { ok = true, save = c.args.save, mods = mods,
			modParams = params or core.plain(core.field(info, "modParams")), dryRun = c.args.dryRun == true }
		if c.args.dryRun then return answer(c.id, plan) end
		local busy = waitingReplace() or (modhub.blocks() and ("load " .. modhub.blocks()))
		if busy then return fail(c.id, busy) end
		cancelRun("load command " .. c.id)
		modhub.cancel("load command " .. c.id)
		plan.loading = true
		answer(c.id, plan, "ack")
		-- load on the next frame, after the answer is on disk: the load ends this script's game
		G.pendingLoad = { id = c.id, saveId = saveId, info = info, waitForStart = c.args.waitForStart == true }
	end)
end

local function stepLoad()
	local p = G.pendingLoad
	if not p then return end
	if not menuMayReplace(p, "load") then return end
	G.pendingLoad = nil
	say("loading for command " .. p.id)
	local ok, err = pcall(function()
		-- the base load pages call this first, but it makes the loading screen wait for a click on "Start Game"
		-- (progress_page.tl): unattended loads skip it
		if p.waitForStart then app.setWaitForStartReadyGame() end
		app.loadGame(p.saveId, false, p.info)
	end)
	if ok then afterReplace(p.id, "loadGame") else fail(p.id, "loadGame: " .. tostring(err)) end
end

---------------------------------------------------------------------------------------------------------------------
-- new game

-- climates with their economy and terrain generators, picked as the base new-game page does
-- (new_game_react_util.gatherMapConfig: visible, not editor-only, not an import generator, by order)
local function keysOf(rep)
	local all = rep.getAll()
	local keys = {}
	local ok = pcall(function() for k in pairs(all) do keys[#keys + 1] = k end end)
	if not ok or #keys == 0 then
		for _, v in ipairs(core.toList(all)) do keys[#keys + 1] = v end
	end
	return keys
end

local function climateCatalog()
	local climates = {}
	for _, k in ipairs(keysOf(app.res.climateRep)) do
		local name = app.res.climateRep.getName(k)
		local desc = app.res.climateRep.get(k)
		climates[name] = { economy = core.field(desc, "economy"), generators = {} }
	end
	local found = {}
	for _, k in ipairs(keysOf(app.res.terrainGeneratorRep)) do
		local g = app.res.terrainGeneratorRep.get(k)
		local climate = core.field(g, "climate")
		if climates[climate] and core.field(g, "visible") and not core.field(g, "editorOnly")
			and not core.field(g, "isImportGenerator") then
			found[climate] = found[climate] or {}
			table.insert(found[climate], { name = app.res.terrainGeneratorRep.getName(k), order = core.field(g, "order") or 0 })
		end
	end
	for climate, list in pairs(found) do
		table.sort(list, function(a, b) return a.order < b.order end)
		for _, g in ipairs(list) do table.insert(climates[climate].generators, g.name) end
	end
	return climates
end

-- { [""] = base defaults, [mod] = its defaults } from the mods' descriptions (mod.json params), as the base
-- new-game page does: { [key] = defaultIndex }. A mod the profile does not know gets none.
local function defaultParams(mods)
	local out = {}
	local rep = try(function() return app.getUserProfile():getModRep() end)
	if not rep then
		say("no mod repository in the user profile: the game's defaults are left to the engine")
		return out
	end
	local names = { "" }
	for _, m in ipairs(mods) do names[#names + 1] = m end
	-- the base page passes defaultIndex straight on, and mod params are 1-based indices; mod.json's defaultIndex
	-- is 0-based. Which one the description holds is not documented: this mod's own pollIdle tells (mod.json 1
	-- = 2 s, the second value), and every default is shifted to the 1-based form the game uses.
	local shift = 0
	local own = try(function()
		local id = (api.type.mod and api.type.mod.ModId or api.type.ModId).new()
		id.name = MOD
		for _, p in ipairs(core.toList(core.field(rep:getModDesc(id), "params"))) do
			if core.field(p, "key") == "pollIdle" then return tonumber(core.field(p, "defaultIndex")) end
		end
	end)
	if own == 1 then shift = 1 elseif own ~= 2 then
		say("cannot tell how the mod descriptions count defaults (pollIdle " .. tostring(own) .. "); taken as 1-based")
	end
	for _, name in ipairs(names) do
		local desc = try(function()
			local id = (api.type.mod and api.type.mod.ModId or api.type.ModId).new()
			id.name = name
			return rep:getModDesc(id)
		end)
		local params = desc and core.toList(core.field(desc, "params")) or {}
		local t = {}
		for _, p in ipairs(params) do
			local key, idx = core.field(p, "key"), tonumber(core.field(p, "defaultIndex"))
			if type(key) == "string" and idx then t[key] = idx + shift end
		end
		out[name] = t
	end
	return out
end

-- the official mods installed (core.officialMods: ug_*), from the user profile's mod repository
local function officialMods()
	local names = {}
	local list = try(function() return app.getUserProfile():getModRep():getInstalledMods() end)
	for _, id in ipairs(core.toList(list)) do
		local n = core.field(id, "name")
		if type(n) == "string" then names[#names + 1] = n end
	end
	return core.officialMods(names)
end

-- the base's difficulty_util (what the base new-game page computes the densities with), or nil and why. Its
-- getScale only reads tables; a failed load leaves remote_core's copy of them (newGameStart)
local function difficultyUtil()
	local ok, du = pcall(ug_require or require, core.DIFFICULTY_UTIL)
	if ok and type(du) == "table" and type(du.getScale) == "function" then return du end
	return nil, ok and ("not a module: " .. type(du)) or tostring(du)
end

-- args: climate, generator, size, year, seed, towns, industries, mods, params, list, dryRun, editor (the map
-- editor: StartGameParams.isMapEditor)
function handlers.newgame(c)
	local catalog = climateCatalog()
	-- this script only runs inside a save, and there app.startGame hits the base's StartGame assertion
	-- `!m_game` and crashes the game (2026-11-15): only the list and the plan are safe
	if not G.menu and not c.args.list and not c.args.dryRun then
		return fail(c.id, "newgame cannot start from inside a save: the base's StartGame asserts that no game is "
			.. "running and the game crashes (list and dryRun still work; start a new game from the main menu)")
	end
	if c.args.list then return answer(c.id, { ok = true, climates = catalog, sizes = core.MAP_SIZES }) end
	local current, mods
	if c.args.editor then
		-- a map keeps the mods it was made with: the official ones and the probe, not the running game's (args.mods
		-- still add and remove), with their defaults as in the menu
		mods = officialMods()
		current = defaultParams(core.mergeMods(mods, c.args.mods, MOD))
	elseif G.menu then
		-- no game to take them from: the defaults, as the base new-game page builds them
		-- (new_game_react_util.makeDefaultBaseModParams). Without the base's own params the game started with
		-- no money and the tutorial on (2026-11-16).
		mods = {}
		current = defaultParams(core.mergeMods({}, c.args.mods, MOD))
	else
		current = core.plain(try(function() return api.engine.config.getModParams() end))
		if type(current) ~= "table" then current = {} end
		mods = {}
		for k in pairs(current) do if k ~= "" then mods[#mods + 1] = k end end
		table.sort(mods)
	end
	local plan, err = core.newGamePlan(c.args, { climates = catalog, mods = mods, modParams = current, selfId = MOD,
		time = os.time and os.time() or 0 })
	if not plan then return fail(c.id, err) end
	-- the densities, start time and clouds as the base new-game page derives them from the base params
	local du, duError = difficultyUtil()
	local start, warnings = core.newGameStart(plan.modParams[""], du, duError)
	plan.locations, plan.timeOfDaySeconds, plan.cloudCoverage = start.locations, start.timeOfDaySeconds,
		start.cloudCoverage
	plan.startLevels, plan.locationsSource = start.levels, start.source
	if #warnings == 0 then warnings = nil else
		for _, w in ipairs(warnings) do say("newgame: " .. w) end
	end
	if c.args.dryRun then return answer(c.id, { ok = true, dryRun = true, plan = plan, warnings = warnings }) end
	local busy = waitingReplace() or (modhub.blocks() and ("newgame " .. modhub.blocks()))
	if busy then return fail(c.id, busy) end
	cancelRun("newgame command " .. c.id)
	modhub.cancel("newgame command " .. c.id)
	answer(c.id, { ok = true, starting = true, plan = plan, warnings = warnings }, "ack")
	-- start on the next frame, after the answer is on disk: starting ends this script's game
	G.pendingStart = { id = c.id, plan = plan }
end

-- town and industry placement as the base new-game page builds it (new_game_or_map_settings_page.tl,
-- makeMapPreviewInputs), from the plan's values (core.newGameStart): without it the generator may place none
local function locationsFor(v)
	local L = api.type.BaseConfig.Locations.new()
	L.town.maxNumberPerArea = v.maxNumberPerArea
	L.town.allowInRoughTerrain = v.allowInRoughTerrain
	L.town.townFrequency = v.townFrequency
	L.town.populationDensity = v.populationDensity
	L.industry.absoluteMinimum = v.absoluteMinimum
	L.industry.industryProductivity = v.industryProductivity
	L.industry.industryDensity = v.industryDensity
	L.makeInitialStreets = v.makeInitialStreets
	return L
end

local function stepStart()
	local s = G.pendingStart
	if not s then return end
	if not menuMayReplace(s, "new game") then return end
	G.pendingStart = nil
	local plan = s.plan
	say("starting a new game for command " .. s.id)
	local ok, err = pcall(function()
		local p = api.type.StartGameParams.new()
		p.numTiles = api.type.Vec2i.new(plan.numTiles[1], plan.numTiles[2])
		p.climateGenerator = plan.climate
		p.terrainGenerator = plan.generator
		p.economy = plan.economy
		p.mods = plan.mods
		p.modParams = plan.modParams
		p.seed = plan.seed
		p.startDate = api.type.Date.new(plan.year, 1, 1)
		-- the menu's start for the base params' time-of-day and weather modes (14:00, clear by default)
		p.startTimeOfDaySeconds = plan.timeOfDaySeconds
		p.startCloudCoverage = plan.cloudCoverage
		p.isMapEditor = plan.editor == true
		p.generateTowns = plan.towns
		p.generateIndustries = plan.industries
		p.generateAssets = true
		local okL, loc = pcall(locationsFor, plan.locations)
		if okL then p.locationsConfig = loc else say("locationsConfig not set: " .. tostring(loc)) end
		-- no setWaitForStartReadyGame: it would hold the loading screen until a click (see stepLoad)
		app.startGame(p)
	end)
	if ok then afterReplace(s.id, "startGame") else fail(s.id, "startGame: " .. tostring(err)) end
end

local function saveExists(name)
	for _, s in ipairs(listSaves()) do
		if s.saveName == name then return true end
	end
	return false
end

function handlers.save(c)
	local name = c.args.name
	if type(name) ~= "string" or name == "" then return fail(c.id, "give the save's name") end
	local started = appTime()
	local existed = saveExists(name)
	-- skipSetName: the player's default save name stays as it was. The callback tells nothing about success, so the
	-- answer checks that the save is listed afterwards.
	G.saving = true
	app.saveGame(name, function()
		G.saving = nil
		local found = saveExists(name)
		answer(c.id, { ok = found, error = (not found) and "the save is not listed after saving" or nil, name = name,
			overwrote = existed, seconds = appTime() - started, state = now() }, (not found) and "error" or nil)
	end, false, true)
end

---------------------------------------------------------------------------------------------------------------------

-- vehicles (remote_vehicles.lua): a new copy with each load of this script, so jobs of the previous game never
-- answer into this one
local vehicles = (ug_require or require)(MOD .. "::/remote_vehicles.lua").new({ core = core, answer = answer, fail = fail,
	appTime = appTime, try = try, say = say, publishUi = publishUi, mod = MOD })
for k, fn in pairs(vehicles.handlers) do handlers[k] = fn end
-- lines (remote_lines.lua): stations, lines and line, the same way
local lines = (ug_require or require)(MOD .. "::/remote_lines.lua").new({ core = core, answer = answer, fail = fail,
	appTime = appTime, fineTime = fineTime, try = try, say = say, publishUi = publishUi, mod = MOD })
for k, fn in pairs(lines.handlers) do handlers[k] = fn end
-- connect (remote_connect.lua): a track or road between two ends, through the Track Connector mod
local connect = (ug_require or require)(MOD .. "::/remote_connect.lua").new({ core = core, answer = answer, fail = fail,
	appTime = appTime, try = try, say = say, mod = MOD })
for k, fn in pairs(connect.handlers) do handlers[k] = fn end
-- build (remote_build.lua): one construction put on the map, or ones the probe built taken away
local build = (ug_require or require)(MOD .. "::/remote_build.lua").new({ core = core, answer = answer, fail = fail,
	appTime = appTime, try = try, say = say })
handlers.build = build.handle
handlers.water = build.water
handlers.road = build.road
handlers.roadInspect = build.roadInspect -- (read only)
handlers.lightsOff = build.lightsOff -- (test saves only: a junction's traffic light taken off)
-- around (remote_around.lua): read only, what stands near a point (kinds, names, boxes; constructions' mouths);
-- its describe also names what a refused build or road collided with
-- lanes (remote_lanes.lua): read only, a road or track piece's lanes (modes, side, speed, width) and tram track;
-- around --lanes adds them to its streets and tracks
local lanesMod = (ug_require or require)(MOD .. "::/remote_lanes.lua")
local lanes = lanesMod.new({ core = core, answer = answer, fail = fail, try = try })
for k, fn in pairs(lanes.handlers) do handlers[k] = fn end
local around = (ug_require or require)(MOD .. "::/remote_around.lua").new({ core = core, answer = answer, fail = fail,
	try = try, appTime = fineTime, construction = build.describe,
	lanes = function(e) return lanes.read(e) end, lanesNote = lanesMod.NOTE })
for k, fn in pairs(around.handlers) do handlers[k] = fn end
build.setDescribeHits(around.describe)
-- terrain (remote_terrain.lua, terrain_work.lua): a rectangle made flat or a slope; terrainApi looks at the functions
local terrain = (ug_require or require)(MOD .. "::/remote_terrain.lua").new({ core = core, answer = answer, fail = fail,
	appTime = appTime, try = try, say = say, publishUi = publishUi, mod = MOD,
	work = (ug_require or require)(MOD .. "::/terrain_work.lua"),
	towns = function() return entitiesOf("town") end })
handlers.terrain = terrain.handle
handlers.terrainApi = terrain.api
-- town (remote_town.lua, town_work.lua): one town at a point, with its first needs
local town = (ug_require or require)(MOD .. "::/remote_town.lua").new({ core = core, answer = answer, fail = fail,
	appTime = appTime, try = try, say = say, publishUi = publishUi, mod = MOD,
	work = (ug_require or require)(MOD .. "::/town_work.lua"),
	towns = function() return entitiesOf("town") end, posOf = function(e) return lines.posOf(e) end })
handlers.town = town.handle
-- debug (remote_debug.lua): api.cmd.debug's stock amount and simulation steps, and stockList to read the stocks
local debugCmds = (ug_require or require)(MOD .. "::/remote_debug.lua").new({ core = core, answer = answer, fail = fail,
	appTime = appTime, try = try, say = say })
for k, fn in pairs(debugCmds.handlers) do handlers[k] = fn end
-- town develop / town size (remote_town_grow.lua): buildings added at a point, a town's size factors set
local townGrow = (ug_require or require)(MOD .. "::/remote_town_grow.lua").new({ core = core, answer = answer,
	fail = fail, appTime = appTime, try = try, say = say })
for k, fn in pairs(townGrow.handlers) do handlers[k] = fn end
-- company / company init (remote_company.lua): the base's company progression read, and its new-game event sent by
-- hand to a game newgame started (app.startGame sends none)
local company = (ug_require or require)(MOD .. "::/remote_company.lua").new({ core = core, answer = answer, fail = fail,
	appTime = appTime, try = try, say = say, mapEditor = function()
		local m = mapEditorNow()
		return m.gui == true or m.modParams == true
	end })
for k, fn in pairs(company.handlers) do handlers[k] = fn end
-- town connections / town connect (remote_town_connect.lua): the towns' connections and the industries' towns read,
-- and the map editor's auto-detect and Generate
local townConnect = (ug_require or require)(MOD .. "::/remote_town_connect.lua").new({ core = core, answer = answer,
	fail = fail, appTime = appTime, try = try, say = say, towns = function() return entitiesOf("town") end,
	industries = function() return entitiesOf("industry") end })
for k, fn in pairs(townConnect.handlers) do handlers[k] = fn end
-- parcels (remote_parcels.lua): read only, the town building parcels on each side of a road piece
local parcels = (ug_require or require)(MOD .. "::/remote_parcels.lua").new({ core = core, answer = answer, fail = fail,
	try = try, say = say })
for k, fn in pairs(parcels.handlers) do handlers[k] = fn end
-- My Mods (remote_modhub.lua): the staging area, validate and the one upload, in the main menu only
modhub = (ug_require or require)(MOD .. "::/remote_modhub.lua").new({ core = core, answer = answer, fail = fail,
	appTime = appTime, try = try, say = say })
for k, fn in pairs(modhub.handlers) do handlers[k] = fn end
-- reach (remote_reach.lua): read only, whether a place can be got to (the engine's targets, town problems, a path)
local reach = (ug_require or require)(MOD .. "::/remote_reach.lua").new({ core = core, answer = answer, fail = fail,
	try = try, appTime = fineTime, say = say, posOf = function(e) return lines.posOf(e) end,
	modeNames = lanesMod.modeNames, tmNamer = lanesMod.tmNamer })
handlers.reach = reach.handle
-- running costs and finance (remote_runcost.lua): a model's running-cost fields read and (test saves) written, through
-- the game script (remote_gs.script.lua) whose state guiUpdate is handed
local runcost = (ug_require or require)(MOD .. "::/remote_runcost.lua").new({ core = core, answer = answer, fail = fail,
	appTime = appTime, try = try, say = say, findModel = vehicles.findModel, gsState = function() return G.gsState end })
for k, fn in pairs(runcost.handlers) do handlers[k] = fn end
-- other mods' commands (remote_modext.lua): modList reads which mods ship remote_probe_ext.lua and their commands;
-- modRead / modChange call one, in this GUI state
local modext = (ug_require or require)(MOD .. "::/remote_modext.lua").new({ core = core, answer = answer,
	failWith = failWith, appTime = appTime, fineTime = fineTime, try = try, say = say, now = now, mod = MOD,
	installed = function()
		local names = {}
		local list = try(function() return app.getUserProfile():getModRep():getInstalledMods() end)
		for _, id in ipairs(core.toList(list)) do
			local n = core.field(id, "name")
			if type(n) == "string" then names[#names + 1] = n end
		end
		return names
	end,
	modParams = function() return core.plain(try(function() return api.engine.config.getModParams() end)) end })
for k, fn in pairs(modext.handlers) do handlers[k] = fn end
lines.walkBetween = reach.walkBetween -- (stations --catchment: whether a building can be walked to its station)

-- args: entity (one industry; none: all). Read only. Per industry: its capacity (PERSON_CAPACITY), the sims that
-- have it as their destination (what the base window shows as n/capacity, entity_window_util.tl
-- WorkplacesProgressBarWidget), the last visitors the base's workers script counts for the productivity boost
-- (industry_productivity_util.getVisitors), the productivity (STOCK_LIST), and the nearest town with its
-- population. Whatever cannot be read is left out, with the reason where it is the workers script.
-- lastVisitors is the count the boost goes by (isIndustryWorkersBoosted: #getVisitors); the base window's list
-- also drops sims that are gone (entityChanged0), so it may show fewer. Towns' positions: their bounding volume,
-- as stations --near reads one (not checked in game for towns).
function handlers.industryWorkers(c)
	local args, err = core.industryWorkersArgs(c.args)
	if not args then return fail(c.id, err) end
	local CT = api.type.ComponentType
	local function comp(e, kind) return try(function() return api.engine.getComponent(e, CT[kind]) end) end
	local all = entitiesOf("industry")
	local list = all
	if args.entity then
		-- only ids the engine lists as industries reach a component lookup (an unknown id may assert)
		list = {}
		for _, e in ipairs(all) do if e.id == args.entity then list[1] = e end end
		if #list == 0 then return fail(c.id, "entity " .. args.entity .. " is no industry (entities --kind industry lists them)") end
	end
	-- the workers script, once
	local script = { name = core.WORKERS_SCRIPT }
	local stateNative, plainState
	local se = tonumber(try(function() return api.engine.system.gameScriptSystem.getEntityForGameScript(core.WORKERS_SCRIPT) end))
	if se == nil or se < 0 then
		script.error = "the game script " .. core.WORKERS_SCRIPT .. " is not running"
	else
		local gs = comp(se, "GAME_SCRIPT")
		if gs == nil then
			script.error = "the game script's entity " .. se .. " has no GAME_SCRIPT component"
		else
			-- state_native as the base GUI reads it; the plain copy only without it
			stateNative = core.field(gs, "state_native")
			if stateNative == nil then plainState = core.field(gs, "state") end
			if stateNative == nil and type(plainState) ~= "table" then script.error = "the game script has no state yet" end
		end
	end
	script.ok = script.error == nil
	-- towns: position and population, once
	local LU = try(function() return api.type.enum.LandUseType end)
	local function luIdx(k, d) local v = tonumber(LU and core.field(LU, k)) return v and v + 1 or d end
	local idx = { residential = luIdx("RESIDENTIAL", 1), commercial = luIdx("COMMERCIAL", 2), industrial = luIdx("INDUSTRIAL", 3) }
	local capsMap = try(function() return api.engine.system.townBuildingSystem.getTown2personCapacitiesMap() end)
	local towns = {}
	for _, t in ipairs(entitiesOf("town")) do
		t.position = lines.posOf(t.id)
		towns[#towns + 1] = t
	end
	local out = {}
	for _, ind in ipairs(list) do
		local e = { id = ind.id, name = ind.name, construction = ind.construction }
		local pc = comp(ind.id, "PERSON_CAPACITY")
		e.capacity = tonumber(pc and core.field(pc, "capacity"))
		if e.capacity then e.boostAt = e.capacity * core.WORKERS_BOOST_FRACTION end
		-- only with a capacity, as the base asks (statistic_industries.tl, entity_window_util.tl): what the engine
		-- does for an entity without one is unknown, and an assertion is past pcall
		if pc ~= nil then
			local dest = try(function() return api.engine.system.simPersonSystem.getSimPersonsForDestination(ind.id) end)
			if dest ~= nil then e.workers = core.size(dest) end
		end
		if script.ok then
			local entry, why = core.workersEntry(stateNative, plainState, ind.id)
			if entry == nil then
				e.lastVisitorsError = why
			else
				e.lastVisitors, e.lastVisitTime = core.visitorsOf(entry)
			end
		end
		local sl = comp(ind.id, "STOCK_LIST")
		e.productivity = tonumber(core.field(core.field(sl, "modifiers"), "productivity"))
		local pos = lines.posOf(ind.id)
		local town, dist = core.nearest(pos, towns)
		if town then
			e.town = { id = town.id, name = town.name, distance = dist,
				population = core.townPopulation(capsMap ~= nil and core.field(capsMap, town.id) or nil, idx) }
		end
		out[#out + 1] = e
	end
	answer(c.id, { ok = true, total = #all, industries = core.array(out), workersScript = script })
end

-- args: entity (one industry; none: all), grep (a part of the name), allParams. Read only. Per industry: its
-- construction's fileName and params (the hummer_aom_upg_ keys and a few others; all with allParams), and its stock
-- list as the base's industry window reads it (industry_util.tl): each stock's cargo type, capacity and the count
-- waiting there (simEntityAtStockSystem.getStockCount, asked only for the stocks the list has), the rules (inputs,
-- outputs, booster and boostFactor) and the modifiers. Whatever cannot be read is left out. Params deeper than
-- core.plain goes (5 levels) come back as strings; a table keyed 1..n reads as a JSON list.
function handlers.industryStocks(c)
	local args, err = core.industryStocksArgs(c.args)
	if not args then return fail(c.id, err) end
	local CT = api.type.ComponentType
	local function comp(e, kind) return try(function() return api.engine.getComponent(e, CT[kind]) end) end
	local all = entitiesOf("industry")
	local list = {}
	for _, e in ipairs(all) do
		-- only ids the engine lists as industries reach a component lookup (an unknown id may assert)
		if (args.entity == nil or e.id == args.entity) and (args.grep == nil or e.name:lower():find(args.grep, 1, true)) then
			list[#list + 1] = e
		end
	end
	if args.entity and #list == 0 then
		local known = false
		for _, e in ipairs(all) do if e.id == args.entity then known = true end end
		if not known then return fail(c.id, "entity " .. args.entity .. " is no industry (entities --kind industry lists them)") end
	end
	-- cargo types: resource names from getAll (get is asked only for ids it lists: an unknown id may assert)
	local cargoFiles = {}
	pcall(function()
		for id, name in pairs(api.res.cargoTypeRep.getAll(true)) do cargoFiles[tonumber(id)] = tostring(name) end
	end)
	local labels = {}
	local function cargo(id)
		if id == nil or cargoFiles[id] == nil then return nil end
		if labels[id] == nil then
			local l = try(function() return api.res.cargoTypeRep.get(id).name end)
			labels[id] = type(l) == "string" and l or false
		end
		return { fileName = cargoFiles[id], name = labels[id] or nil }
	end
	local SLT = try(function() return api.type.enum.StockListType end)
	local typeNames = {}
	for _, k in ipairs({ "InputStock", "OutputStock", "StorageStock" }) do
		local v = tonumber(SLT and core.field(SLT, k))
		if v then typeNames[v] = k end
	end
	local out = {}
	for _, ind in ipairs(list) do
		local e = { id = ind.id, name = ind.name, construction = ind.construction }
		-- the construction: only one the engine gave for this industry
		if ind.construction then
			local cc = comp(ind.construction, "CONSTRUCTION")
			if cc == nil then
				e.constructionError = "no CONSTRUCTION component"
			else
				local fn = core.field(cc, "fileName")
				e.fileName = fn ~= nil and tostring(fn) or nil
				-- params_native as AoM's upgrades read them (world.lua M.params); the params record only without it
				local params
				local pn = core.field(cc, "params_native")
				if pn ~= nil then
					local ok, t = pcall(function() return pn:asTable() end)
					if ok and type(t) == "table" then params = t end
				end
				if params == nil then
					local p = core.plain(core.field(cc, "params"))
					if type(p) == "table" then params = p end
				end
				if params == nil then
					e.paramsError = "the params did not read as a table"
				else
					local picked = core.pickParams(params)
					e.aomParams, e.params = picked.prefixed, picked.other
					if args.allParams then e.allParams = core.plain(params) end
				end
			end
		end
		-- the stock list: the industry's own, as the base's window reads it (getComponent(entity, STOCK_LIST))
		local sl = comp(ind.id, "STOCK_LIST")
		if sl == nil then
			e.stockListError = "no STOCK_LIST component"
		else
			e.productivity = tonumber(core.field(core.field(sl, "modifiers"), "productivity"))
			e.thrownAwayCargo = tonumber(core.field(sl, "thrownAwayCargo"))
			local datas = core.field(sl, "stockDatas")
			local stocks = {}
			local stockList = core.toList(core.field(sl, "stocks"))
			for i, st in ipairs(stockList) do
				local t = tonumber(core.field(st, "type"))
				local s = { index = i, stockId = i - 1, type = t, typeName = t and typeNames[t] or nil,
					cargoType = tonumber(core.field(st, "cargoType")), capacity = tonumber(core.field(st, "capacity")),
					mixedTypes = core.field(st, "mixedTypes"), tag = tonumber(core.field(st, "tag")),
					loadSpeedModifier = tonumber(core.field(st, "loadSpeedModifier")),
					consumeFrequency = tonumber(core.field(core.at(datas, i), "consumeFrequency")) }
				if type(s.mixedTypes) ~= "boolean" then s.mixedTypes = nil end
				s.cargo = cargo(s.cargoType)
				-- the cargo types the stock takes, as the base's cargo_util.tl asks for each stock (cargoType is -1
				-- for a mixed one; the debug panel then shows its cargo classes)
				local ids = {}
				for _, id in ipairs(core.toList(try(function() return api.engine.util.stock.getStockCargoTypes(ind.id, i - 1) end))) do
					local n = tonumber(id)
					if n then ids[#ids + 1] = { cargoType = n, cargo = cargo(n) } end
				end
				s.stockCargoTypes = core.array(ids)
				local classes = {}
				for _, cl in ipairs(core.toList(core.field(core.field(st, "cargoTypes"), "cargoClassesIncluded"))) do
					classes[#classes + 1] = tostring(cl)
				end
				if #classes > 0 then s.cargoClasses = classes end
				-- the count: only for a stock the list has (stock ids are 0-based, as the base asks)
				s.count = tonumber(try(function() return api.engine.system.simEntityAtStockSystem.getStockCount(ind.id, i - 1) end))
				stocks[#stocks + 1] = s
			end
			e.stocks = core.array(stocks)
			local rules = {}
			for _, r in ipairs(core.toList(core.field(sl, "rules"))) do rules[#rules + 1] = core.ruleOf(r, cargo) end
			e.rules = core.array(rules)
		end
		out[#out + 1] = e
	end
	answer(c.id, { ok = true, total = #all, industries = core.array(out) })
end

---------------------------------------------------------------------------------------------------------------------

local function init()
	readOptions()
	publishRun(nil) -- a run of the previous game does not carry over
	G.ui, G.uiSent = nil, nil
	G.opens = {} -- a new GUI: requests of the last game are not this one's
	G.buildTool = nil -- a new GUI: no filter left to clear
	-- the save may hold the last game's label and requests; buttons now, not at the first label step, so a game
	-- set to hide them never shows them
	publishUi({ label = "", tip = "", open = false, opens = {}, vehicles = {}, lines = {}, terrain = {}, town = {},
		buttons = G.options.speedButtons ~= false })
	if not G.menu then
		pcall(function() api.gui.game.setGuiSaveData(OPEN_REPORT_KEY, { done = {} }) end)
		vehicles.reset()
		lines.reset()
		connect.reset()
		build.reset()
		terrain.reset()
		town.reset()
		townGrow.reset()
		company.reset()
		townConnect.reset()
		runcost.reset()
		modext.reset()
	end
	if type(app) ~= "table" and type(app) ~= "userdata" then
		say("app is not available; off")
		G.phase = "off"
		return
	end
	local stamp = string.format("%d_%d", os.time and os.time() or 0, math.floor(appTime() * 1000) % 1000000)
	local hello = { version = core.VERSION, mod = MOD, stamp = stamp }
	for _, dir in ipairs(DIRS) do
		G.dir = dir
		local name = core.PREFIX .. "hello_" .. stamp
		hello.json = core.json({ version = core.VERSION, mod = MOD, stamp = stamp, dir = dir, menu = G.menu == true, state = now(),
			defaultSavegameId = try(function() return api.gui.game.getDefaultSavegameId() end), modParams = modParamsNow() })
		trySave(name, hello)
		local back = try(function() return app.loadUserdata(dir, name) end)
		if back and core.field(back, "stamp") == stamp then
			G.stamp = stamp
			G.cmdName = core.PREFIX .. "cmd_" .. stamp
			-- the command file must exist before it is polled: loading a missing file logs an error each time
			trySave(G.cmdName, { id = 0 })
			G.phase = "idle"
			say("ready" .. (G.menu and " in the main menu" or "") .. "; folder <user data>/" .. dir .. ", stamp " .. stamp)
			return
		end
	end
	say("no userdata folder kept a saved file; off")
	G.phase = "off"
end

local function poll()
	local t = appTime()
	if t < G.nextPoll then return end
	G.nextPoll = t + ((t - G.lastCmdAt < ACTIVE_SEC or G.run) and G.pollActive or G.pollIdle)
	local raw = try(function() return app.loadUserdata(G.dir, G.cmdName) end)
	if raw == nil then
		G.nextPoll = t + 10 -- missing or half-written: each failed load logs an error, so back off
		-- a missing file (deleted by hand or by a tool of another game instance) is made again; a half-written one
		-- stays, since saveUserdata does not overwrite, until the tool finishes rewriting it
		trySave(G.cmdName, { id = 0 })
		return
	end
	local c = core.readCommand(raw, G.lastId)
	if not c then return end
	G.lastId = c.id
	G.lastCmdAt = t
	-- the interval above was chosen before this command arrived: a follow-up must not wait the idle interval
	G.nextPoll = t + G.pollActive
	if c.error then return fail(c.id, c.error) end
	-- a receipt first: the tool may only write its next command once this one is picked up, since there is a
	-- single command file
	answer(c.id, { ok = true, got = c.cmd }, "got")
	say("receipt for command " .. c.id, 3)
	local owner = core.owner(c.args)
	local other = core.otherOwnerOk(c.args)
	-- a command sent to a game another owner started is logged even at log level 1: whoever reads the log later
	-- must see it
	say("command " .. c.id .. ": " .. c.cmd .. (owner and (" from " .. owner) or "")
		.. (other and (" (--other-owner-ok: the game of " .. other .. ")") or ""), other and 1 or 2)
	if G.menu and not core.MENU_COMMANDS[c.cmd] then
		return fail(c.id, c.cmd .. " needs a running game; in the main menu: load, newgame, saves, info, status, quit, modhub")
	end
	if not G.menu and core.MENU_ONLY[c.cmd] then
		return fail(c.id, c.cmd .. " works only in the main menu (My Mods' publish helper is a privileged API, made in "
			.. "the menu's Lua state); quit to the menu or use launch without a save")
	end
	local misplaced = core.ignoreErrorsMisplaced(c.cmd, c.args)
	if misplaced then return fail(c.id, misplaced) end
	local ok, err = pcall(handlers[c.cmd], c)
	if not ok then fail(c.id, err) end
	-- what status shows as "who used the game last": commands that change it and were not refused (a load
	-- refused later, when the save's info arrives, still counts: it was about to change the game)
	if ok and G.failedId ~= c.id and core.CHANGES_GAME[c.cmd] then
		G.lastAction = { id = c.id, cmd = c.cmd, owner = owner, unixTime = os.time and os.time() or nil }
	end
end

-- the label text, made here because this runs on the main thread: the recipe must not call api.util / api.gui
-- outside its join (getApplicationTime crashed the game from a worker thread)
local LABEL_SEC = 0.5
local labelRate = core.newRate()

local function stepLabel()
	local t = appTime()
	if t < (G.nextLabel or 0) then return end
	G.nextLabel = t + LABEL_SEC
	publishUi({ buttons = G.options.speedButtons ~= false })
	if not G.options.speedLabel then
		publishUi({ label = "", tip = "" })
		return
	end
	local s = now()
	local measured = core.rateStep(labelRate, s.gameTime, s.appTime)
	local run = G.run and { target = G.run.target.date, owner = G.run.owner } or nil
	-- _ is the game's translation function in GUI Lua (a plain global; nil in tests)
	local label, tip = core.speedLabel(s.speedup, measured, run, s.estimatedMaxSpeed, _)
	publishUi({ label = label, tip = tip })
end

local function step()
	G.frames = G.frames + 1
	stepMenuGone()
	if G.phase == "off" then return end
	if G.phase == "init" then return init() end
	stepQuit()
	stepLoad()
	stepStart()
	stepReplaceWatch()
	if G.phase == "off" then return end
	poll()
	stepTasks()
	if G.menu then return modhub.step() end -- no game to run, and no label to show
	vehicles.step()
	lines.step()
	connect.step()
	build.step()
	terrain.step()
	town.step()
	debugCmds.step()
	townGrow.step()
	company.step()
	townConnect.step()
	runcost.step()
	modext.step()
	stepFinish()
	stepRun()
	stepCalendar()
	stepBuildTool()
	stepOpens()
	stepLabel()
end

local script = {}

-- startup.lua: this copy runs in the main menu, before any game (the game launched with --script)
function script.setMenu()
	G.menu = true
end

-- state: the game script's (remote.gs.lua, read only here), which remote_gs.script.lua answers runningCostsSet in;
-- nil in the main menu (startup.lua calls this without it)
function script.guiUpdate(_userParams, state)
	G.gsState = state
	if G.phase == "off" then return end
	local ok, err = pcall(step)
	if not ok then
		-- scattered errors over a long session must not add up to "off"; a burst still does
		if appTime() - (G.lastErrorAt or -1e9) > ERROR_FORGET_SEC then G.failures = 0 end
		G.lastErrorAt = appTime()
		G.failures = G.failures + 1
		say("error (" .. G.failures .. "): " .. tostring(err))
		if G.failures >= 20 then
			G.phase = "off"
			pcall(publishUi, { label = "", tip = "" }) -- no stale label while nothing updates it
			say("too many errors; off until the next load")
		end
	end
end

function data()
	return script
end
