-- The remote probe's game script (remote.gs.lua's update and handleEvent): one job, the runningCostsSet write in
-- a game script's Lua state, the way price_probe wrote metadata.cost.price in 2026-11-16 (modelRep.get(id).metadata
-- written in place from a game script: every worker and the GUI saw the new value, and a purchase paid it).
--
-- Off unless the mod setting gameScript is on (--param hummer_remote_probe:gameScript=2 at launch / load): off, update
-- only reads the setting now and then and handleEvent hears nothing, since nothing is subscribed. A script event
-- reaches a game script only when it subscribed to the event's name (GameScriptState.subscribeToEvent; the base's
-- vehicle_modifier does so, and company init's initNewGameFromMap sent by hand did not reach the base's scripts,
-- e2e 2026-11-23). The subscription is kept in the save, which is why it waits for the setting: a person's save
-- never gets it.
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

function S.update(_userParams, state, _dt)
	local wasAt = cache.at
	if not enabled() or cache.at == wasAt then return end
	-- (only when the setting was read again: a few calls a minute per worker)
	local ok, err = pcall(function()
		if state:hasEventSubscriptions() then return end
		state:subscribeToEvent(core.RUNCOST_EVENT_WRITE)
		state:subscribeToEvent(core.RUNCOST_EVENT_READ)
		say("subscribed to " .. core.RUNCOST_EVENT_WRITE .. " and " .. core.RUNCOST_EVENT_READ .. " (gameScript on)")
	end)
	if not ok and not warned then
		warned = true
		say("subscribing failed: " .. tostring(err))
	end
end

local function run(name, param)
	local r, why = core.runningCostRequestChecked(param)
	if not r then
		return { req = type(param) == "table" and tonumber(param.req) or nil, ok = false, where = "script", error = why }
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
		local res = run(name, param)
		local s = state:get()
		if type(s) ~= "table" then s = {} end
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
