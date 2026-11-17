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

local function fail(id, msg)
	G.failedId = id
	say("command " .. tostring(id) .. " failed: " .. tostring(msg))
	answer(id, { ok = false, error = tostring(msg) }, "error")
end

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

function handlers.status(c)
	local t = now()
	answer(c.id, { ok = true, version = core.VERSION, mod = MOD, stamp = G.stamp, dir = G.dir, menu = G.menu == true, state = t,
		defaultSavegameId = try(function() return api.gui.game.getDefaultSavegameId() end),
		modParams = modParamsNow(), run = runInfo(), poll = { idle = G.pollIdle, active = G.pollActive },
		ui = (not G.menu) and uiReadBack() or nil,
		logLevel = G.options.logLevel, lastAction = G.lastAction })
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

-- args: scale (the base photo mode uses 1: twice the screen size, ~100 MB PNG at 5120x2160). The game writes
-- <userdata>/screenshots/<date>_img_N.png on its own time; the tool waits for the file. A GUI API: safe here,
-- since this script runs on the main thread.
function handlers.screenshot(c)
	local scale = tonumber(c.args.scale or 1)
	if not scale or scale ~= math.floor(scale) or scale < 0 or scale > 4 then return fail(c.id, "scale must be 0-4") end
	api.gui.camera.takeScreenshot(scale)
	answer(c.id, { ok = true, scale = scale, unixTime = os.time and os.time() or nil })
end

-- towns, lines, vehicles, stations, industries: { id, name } (vehicles, stations and lines: the player's own)
local function entitiesOf(kind)
	local CT = api.type.ComponentType
	local player = try(function() return api.engine.util.getPlayer() end)
	if player == nil and kind ~= "town" and kind ~= "industry" then error("the player's company is unknown") end
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
	end
	local out = {}
	for _, id in ipairs(core.toList(ids)) do
		local name = try(function() return api.engine.util.getEntityName(id) end)
		if type(name) ~= "string" or name == "" then
			name = try(function() return api.engine.getComponent(id, CT.NAME).name end)
		end
		out[#out + 1] = { id = id, name = tostring(name or "") }
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

-- args: kind, grep (substring, any case), limit
function handlers.entities(c)
	local kind = c.args.kind
	if not core.ENTITY_KINDS[kind] then return fail(c.id, "kind must be town, line, vehicle, station or industry") end
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

-- args: kind + name, or entity (id); focus (camera); closeAll. The window itself is opened by the speed control
-- (gui/remote_speed.script.lua) with react.fireEvent(nil, "selectEntity", ...), as the base statistics and
-- line windows do: events need a react context, which this script does not have.
function handlers.window(c)
	if c.args.closeAll then
		local okC, errC = pcall(function() api.gui.closeAllWindows() end)
		if not okC then return fail(c.id, "closeAllWindows: " .. tostring(errC)) end
		return answer(c.id, { ok = true, closedAll = true })
	end
	local entity, name = tonumber(c.args.entity), nil
	if not entity then
		local kind = c.args.kind
		if not core.ENTITY_KINDS[kind] then return fail(c.id, "give entity, or kind (town, line, vehicle, station, industry) and name") end
		local hit, err = core.matchEntity(entitiesOf(kind), c.args.name)
		if not hit then return fail(c.id, err) end
		entity, name = hit.id, hit.name
	end
	G.uiSeq = (G.uiSeq or (os.time and os.time() or 0) * 1000) + 1
	publishUi({ open = { seq = G.uiSeq, entity = entity } })
	if c.args.focus then
		local okF, errF = pcall(function() api.gui.camera.focusEntity(entity) end)
		if not okF then say("focusEntity: " .. tostring(errF)) end
	end
	answer(c.id, { ok = true, entity = entity, name = name, seq = G.uiSeq, focused = c.args.focus == true,
		note = "the speed control opens it within about a second; it needs the speed label setting on" })
end

-- args: name (react event), param. Fired by the speed control (a react context), like the window command:
-- e.g. "example_window.show" { welcome = true } opens another mod's window without that mod's help
function handlers.event(c)
	local ev, err = core.eventRequest(c.args)
	if not ev then return fail(c.id, err) end
	G.uiSeq = (G.uiSeq or (os.time and os.time() or 0) * 1000) + 1
	publishUi({ open = { seq = G.uiSeq, event = ev } })
	answer(c.id, { ok = true, event = ev.name, seq = G.uiSeq,
		note = "the speed control fires it within about a second (not checked: look at the screen or the log)" })
end

-- args: name (music, calendar) or module + field; close. Pushed onto (or popped from) the game's tool stack by
-- the speed control, as the base's own buttons do
function handlers.tool(c)
	local t, err = core.toolRequest(c.args)
	if not t then return fail(c.id, err) end
	G.uiSeq = (G.uiSeq or (os.time and os.time() or 0) * 1000) + 1
	publishUi({ open = { seq = G.uiSeq, tool = t } })
	answer(c.id, { ok = true, module = t.module, field = t.field, close = t.close, seq = G.uiSeq,
		note = "the speed control opens it within about a second (not checked: look at the screen or the log)" })
end

-- camera: x, y, distance, angle, pitch (getCameraData's Vec5f) and the height above the terrain
local function cameraNow()
	local cam = api.gui.camera
	local v = cam.getCameraData()
	local h = try(function() return cam.getHeightAboveTerrain() end)
	return { x = v.x, y = v.y, distance = v.z, angle = v.w, pitch = v.q, heightAboveTerrain = h }
end

-- args: none (read), set (x,y[,distance[,angle[,pitch]]], the rest kept), entity, or focus (x,y,z) + distance.
-- A GUI API on the main thread, as screenshot. Answers what the camera reads after the move.
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

-- build tool: two base events through the speed control (as event), G.buildTool holds what is left to send.
-- The filter is the construction menu's (game.tl setMenuFilter); it is undone here on time, so a tool that died
-- midway does not leave the menu showing one building. A load or a quit builds a new GUI, without the filter.
local function sendEvent(name, param)
	G.uiSeq = (G.uiSeq or (os.time and os.time() or 0) * 1000) + 1
	publishUi({ open = { seq = G.uiSeq, event = { name = name, param = param } } })
end

local function clearBuildFilter(why)
	sendEvent("setMenuFilter", core.menuFilter(nil))
	say("build tool: menu filter cleared (" .. why .. ")", 2)
	G.buildTool = nil
end

local function stepBuildTool()
	local b = G.buildTool
	if not b then return end
	local t = appTime()
	if b.selectAt and t >= b.selectAt then
		b.selectAt = nil
		sendEvent("constructionMenuSelectTabForConstruction", { resName = b.res })
	elseif not b.selectAt and t >= b.clearAt then
		clearBuildFilter("after " .. b.seconds .. " s")
	end
end

-- args: res, template, seconds; or close
function handlers.buildTool(c)
	if c.args.close then
		local was = G.buildTool ~= nil
		clearBuildFilter("close command")
		return answer(c.id, { ok = true, closed = true, wasOpen = was })
	end
	local r, err = core.buildToolRequest(c.args)
	if not r then return fail(c.id, err) end
	local idx = try(function() return api.res.constructionRep.find(r.res) end)
	if type(idx) ~= "number" or idx < 0 then return fail(c.id, "no such construction: " .. r.res) end
	sendEvent("setMenuFilter", core.menuFilter(r.tag))
	local t = appTime()
	G.buildTool = { res = r.res, tag = r.tag, seconds = r.seconds, selectAt = t + core.BUILD_TOOL_GAP,
		clearAt = t + core.BUILD_TOOL_GAP + r.seconds }
	answer(c.id, { ok = true, tag = r.tag, clearInSec = core.BUILD_TOOL_GAP + r.seconds,
		clearAtUnix = os.time and (os.time() + math.ceil(core.BUILD_TOOL_GAP + r.seconds)) or nil,
		notes = { "a building not available in this year is not listed: the tab then opens without it",
			"module tabs (dynamic) are not covered",
			"the placement preview shows only with the mouse pointer over the 3D view" } })
end

-- answered first; the game quits on the next frame, once the answer is on disk
function handlers.quit(c)
	cancelRun("quit command " .. c.id)
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
		local busy = waitingReplace()
		if busy then return fail(c.id, busy) end
		cancelRun("load command " .. c.id)
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

-- args: climate, generator, size, year, seed, towns, industries, mods, params, list, dryRun
function handlers.newgame(c)
	local catalog = climateCatalog()
	-- this script only runs inside a save, and there app.startGame hits the base's StartGame assertion
	-- `!m_game` and crashes the game (2026-11-15): only the list and the plan are safe
	if not G.menu and not c.args.list and not c.args.dryRun and not c.args.unsafe then
		return fail(c.id, "newgame cannot start from inside a save: the base's StartGame asserts that no game is "
			.. "running and the game crashes (list and dryRun still work; unsafe = true sends it anyway)")
	end
	if c.args.list then return answer(c.id, { ok = true, climates = catalog, sizes = core.MAP_SIZES }) end
	local current, mods
	if G.menu then
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
	if c.args.dryRun then return answer(c.id, { ok = true, dryRun = true, plan = plan }) end
	local busy = waitingReplace()
	if busy then return fail(c.id, busy) end
	cancelRun("newgame command " .. c.id)
	answer(c.id, { ok = true, starting = true, plan = plan }, "ack")
	-- start on the next frame, after the answer is on disk: starting ends this script's game
	G.pendingStart = { id = c.id, plan = plan }
end

-- town and industry placement as the base new-game page builds it (new_game_or_map_settings_page.tl,
-- makeMapPreviewInputs): without it the generator may place none
local function locationsFor(baseParams)
	local L = api.type.BaseConfig.Locations.new()
	L.town.maxNumberPerArea = 0.2
	L.town.allowInRoughTerrain = false
	L.industry.absoluteMinimum = 24
	L.industry.industryProductivity = 1
	L.makeInitialStreets = true
	local okD, du = pcall(function() return req "/base/difficulty_util.tl" end)
	if okD and du and du.getScale then
		baseParams = baseParams or {}
		L.town.townFrequency = du.getScale("locations.towns.frequency", baseParams["locations.towns.frequency"])
		L.town.populationDensity = du.getScale("locations.towns.populationDensity",
			baseParams["locations.towns.populationDensity"])
		L.industry.industryDensity = du.getScale("locations.industry.initialIndustryDensity",
			baseParams["locations.industry.initialIndustryDensity"])
	else
		say("difficulty_util not available: town and industry densities left at their defaults")
	end
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
		p.startTimeOfDaySeconds = 12 * 3600
		p.startCloudCoverage = 0
		p.isMapEditor = false
		p.generateTowns = plan.towns
		p.generateIndustries = plan.industries
		p.generateAssets = true
		local okL, loc = pcall(locationsFor, plan.modParams[""])
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
	appTime = appTime, try = try, say = say, publishUi = publishUi, mod = MOD })
for k, fn in pairs(lines.handlers) do handlers[k] = fn end
-- connect (remote_connect.lua): a track or road between two ends, through the Track Connector mod
local connect = (ug_require or require)(MOD .. "::/remote_connect.lua").new({ core = core, answer = answer, fail = fail,
	appTime = appTime, try = try, say = say, mod = MOD })
for k, fn in pairs(connect.handlers) do handlers[k] = fn end

---------------------------------------------------------------------------------------------------------------------

local function init()
	readOptions()
	publishRun(nil) -- a run of the previous game does not carry over
	G.ui, G.uiSent = nil, nil
	G.buildTool = nil -- a new GUI: no filter left to clear
	publishUi({ label = "", tip = "", open = false, vehicles = {}, lines = {} }) -- the save may hold the last game's label and requests
	if not G.menu then
		vehicles.reset()
		lines.reset()
		connect.reset()
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
	say("command " .. c.id .. ": " .. c.cmd .. (owner and (" from " .. owner) or ""), 2)
	if G.menu and not core.MENU_COMMANDS[c.cmd] then
		return fail(c.id, c.cmd .. " needs a running game; in the main menu: load, newgame, saves, info, status, quit")
	end
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
	if G.menu then return end -- no game to run, and no label to show
	vehicles.step()
	lines.step()
	connect.step()
	stepFinish()
	stepRun()
	stepBuildTool()
	stepLabel()
end

local script = {}

-- startup.lua: this copy runs in the main menu, before any game (the game launched with --script)
function script.setMenu()
	G.menu = true
end

function script.guiUpdate()
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
