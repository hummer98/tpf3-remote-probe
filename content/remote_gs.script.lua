-- The remote probe's game script (remote.gs.lua's update and handleEvent). Two jobs: the runningCostsSet write in a
-- game script's Lua state, the way price_probe wrote metadata.cost.price in 2026-11-16 (modelRep.get(id).metadata
-- written in place from a game script: every worker and the GUI saw the new value, and a purchase paid it); and
-- status's luaLoad, this state's load / loadstring / setfenv written into the script's state (writeLuaLoad, below).
--
-- Off unless the mod setting gameScript is on (--param hummer_remote_probe:gameScript=2 at launch / load): off, update
-- only reads the setting now and then and subscribes to nothing; handleEvent returns at once for any event that
-- still reaches it (the base's vehicle_modifier gets the engine's initNewGame before it subscribes, so some events
-- come unsubscribed). A script event sent by a command reaches a game script only when it subscribed to the event's
-- name (GameScriptState.subscribeToEvent; company init's initNewGameFromMap sent by hand did not reach the base's
-- scripts, e2e 2026-11-23). Whether the subscription is kept in the save is not known (price_probe tracked it as
-- if it were); either way it waits for the setting, and tf3ctl refuses gameScript=2 on a load of a person's save.
-- Subscribed again at each read of the setting, without asking hasEventSubscriptions first: other mods found that
-- guard true before their names were in, so they were skipped (harbour_city, celmi timetables, which say the engine
-- dedupes by name). Should a write still come twice, the second is dropped by its req.
--
-- The GUI (remote_runcost.lua) sends makeScriptingSendEventCmd("", RUNCOST_EVENT_ID, RUNCOST_EVENT_WRITE or _READ,
-- request); this answers in the script's state ({ runningCosts = result }), which the GUI reads in guiUpdate. The
-- request is checked again here (a test save's name, the fields), since script-event can send one by hand.
--
-- update and handleEvent run in whichever worker Lua state the engine picks: module locals are per worker (a cache
-- only). No new globals (the base's init.lua refuses them): only data(), which init.lua declares.
local MOD = "hummer_remote_probe"
local req = ug_require or require
local core = req(MOD .. "::/remote_core.lua")

local function say(msg)
	pcall(print, core.LOG .. "game script: " .. msg)
end

-- the setting, read again after RECHECK_SEC of wall clock (a worker may outlive a load; os.time in a game script,
-- as the shared rules say, not os.clock)
local RECHECK_SEC = 5
local cache = { on = false, at = nil }
local function enabled()
	local t = os.time and os.time() or 0
	if cache.at ~= nil and t - cache.at < RECHECK_SEC and t >= cache.at then return cache.on end
	cache.at = t
	local ok, all = pcall(function() return api.engine.config.getModParams() end)
	cache.on = ok and all ~= nil and core.options(core.field(all, MOD)).gameScript == true
	return cache.on
end

local S = {}
local warned = false

-- status's luaLoad (core.luaLoadKinds): this state's own globals, so the closure is written here
local function readGlobal(n)
	if n == "load" then return load elseif n == "loadstring" then return loadstring elseif n == "setfenv" then return setfenv end
end

-- written into the state (luaLoad) for the GUI's status to read, when the setting is read again and only when the
-- value changed (no set every few seconds). Off: nothing written, as for everything else here (status: "unread")
local function writeLuaLoad(state)
	local kinds = core.luaLoadKinds(readGlobal)
	local s = state:get()
	if type(s) ~= "table" then s = {} end
	local had = type(s.luaLoad) == "table" and s.luaLoad or {}
	local same = true
	for _, n in ipairs(core.LUA_LOAD_NAMES) do same = same and had[n] == kinds[n] end
	if same then return end
	s.luaLoad = kinds
	state:set(s)
end

function S.update(_userParams, state, _dt)
	local wasAt = cache.at
	if not enabled() or cache.at == wasAt then return end
	-- (only when the setting was read again: a few calls a minute per worker)
	local ok, err = pcall(function()
		state:subscribeToEvent(core.RUNCOST_EVENT_WRITE)
		state:subscribeToEvent(core.RUNCOST_EVENT_READ)
		if not cache.said then
			cache.said = true
			say("subscribed to " .. core.RUNCOST_EVENT_WRITE .. " and " .. core.RUNCOST_EVENT_READ .. " (gameScript on)")
		end
	end)
	if not ok and not warned then
		warned = true
		say("subscribing failed: " .. tostring(err))
	end
	local okL, errL = pcall(writeLuaLoad, state)
	if not okL and not cache.luaLoadSaid then
		cache.luaLoadSaid = true
		say("luaLoad not written: " .. tostring(errL))
	end
end

local function run(name, param)
	local r, why = core.runningCostRequestChecked(param)
	if not r then
		return { req = type(param) == "table" and tonumber(param.req) or nil, ok = false, refused = true, where = "script",
			error = why }
	end
	local rep = api.res.modelRep
	local out = { req = r.req, model = r.model, where = "script", event = name }
	local before, err = core.readRunningCostFields(rep, r.model)
	out.before = before
	if not before then
		out.ok, out.error = false, err
		return out
	end
	if name == core.RUNCOST_EVENT_READ then
		out.ok = true
		return out
	end
	local targets, terr = core.runningCostTargets(before, r.ops)
	if not targets then
		out.ok, out.error = false, terr
		return out
	end
	out.writes = core.writeRunningCosts(rep, r.model, targets)
	out.after = core.readRunningCostFields(rep, r.model)
	out.ok = true
	for _, w in ipairs(out.writes) do out.ok = out.ok and w.stuck end
	if not out.ok then out.error = "not every field took the value (see writes)" end
	return out
end

function S.handleEvent(_userParams, state, _src, id, name, param)
	if id ~= core.RUNCOST_EVENT_ID then return nil end
	if name ~= core.RUNCOST_EVENT_WRITE and name ~= core.RUNCOST_EVENT_READ then return nil end
	local ok, err = pcall(function()
		if not enabled() then return end
		local s = state:get()
		if type(s) ~= "table" then s = {} end
		local prev = type(s.runningCosts) == "table" and s.runningCosts or nil
		if prev and type(param) == "table" and prev.req ~= nil and prev.req == tonumber(param.req) then
			say("request " .. tostring(prev.req) .. " came again: dropped (a write is never applied twice)")
			return
		end
		local res = run(name, param)
		if res.refused then
			-- (refused before anything was read: no state written, so a refused request leaves the save as it was)
			say("refused: " .. tostring(res.error))
			return
		end
		s.runningCosts = res
		state:set(s)
		local w = res.writes and res.writes[1]
		say(string.format("%s model %s: %s%s", name == core.RUNCOST_EVENT_WRITE and "write" or "read",
			tostring(res.model), res.ok and "ok" or ("failed: " .. tostring(res.error)),
			w and string.format(" (%s %s -> %s, read back %s)", w.field, tostring(w.from), tostring(w.to),
				tostring(w.readBack)) or ""))
	end)
	if not ok then say("handleEvent failed: " .. tostring(err)) end
	return nil
end

-- for tests: a new worker (or a reload) starts with empty module locals
function S._resetForTests()
	cache, warned = { on = false, at = nil }, false
end

function data()
	return S
end
