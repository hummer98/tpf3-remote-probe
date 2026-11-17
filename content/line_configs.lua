-- Lines as the base builds them, and the gui way of the line commands. Required by both Lua states of the remote
-- probe: the guiUpdate script (remote_lines.lua: the cmd way, and what it reads back) and the speed control's react
-- recipe (gui/remote_speed.script.lua: the gui way).
--
-- The base line manager (manager_window.tl newLine / addStop / reactLineCommit) builds a line in three steps:
--   1. a path of stops, each new one from line_util.makeNewStop (a StopConfig with one load and maxLoad entry per
--      cargo type, and the waiting time by carrier); stops it keeps are those of the line as it is
--      (line_util.getReactLineFromGameState)
--   2. line_util.autoLoadConfig: which cargo each stop loads (from the stations' stocks), and the platforms of stops
--      that have none (through autoAssignTerminals)
--   3. line_util.autoAssignTerminals: Line.Stop per stop, platforms from lineSystem.getBestLineAssignment, 0/0
--      where that finds none "to prevent ASSERT during command execution"; then makeLineCreateCmd or
--      makeLineUpdateCmd.
-- The gui way calls these functions; the cmd way repeats what matters of them by hand (a fallback in case
-- line_util.tl does not load in the recipe: unverified in game). Both check every stop before sending: the engine
-- asserts on a stop without a platform, and an assertion kills the game, uncatchable by pcall (a vehicle config of
-- the wrong size did, 2026-11-16 13:21 JST).
local M = {}

M.LINE_UTIL = "/gui/line_vehicle_mgmt/line_util.tl"
M.ENTITY_UTIL = "/scripts/entity_util.tl"
-- line colours for the cmd way, which does not load the base's palette (line_colors.gres, read by line_util)
M.COLORS = { { 0.86, 0.2, 0.2 }, { 0.2, 0.5, 0.86 }, { 0.2, 0.7, 0.3 }, { 0.9, 0.6, 0.1 }, { 0.6, 0.3, 0.8 },
	{ 0.1, 0.7, 0.7 }, { 0.85, 0.4, 0.6 }, { 0.5, 0.5, 0.5 } }

local function toList(v)
	if type(v) == "table" then return v end
	local out = {}
	if v == nil then return out end
	-- engine vectors: # and [i] work, ipairs may not
	local ok, n = pcall(function() return #v end)
	if ok and type(n) == "number" then for i = 1, n do out[i] = v[i] end end
	return out
end
M.toList = toList

local function field(t, k)
	local ok, v = pcall(function() return t[k] end)
	if ok then return v end
	return nil
end
M.field = field

local function CT() return api.type.ComponentType end

-- the base's makeIdvector (line_util.tl, cargofilter_window.tl): one value per cargo type of
-- cargoTypeRep.getAll(true), at id + 1. The engine reads these per cargo type, so they are made exactly as the base
-- makes them (same list, same size).
function M.idVector(value)
	local out = {}
	for k in pairs(api.res.cargoTypeRep.getAll(true)) do out[k + 1] = value end
	return out
end

-- load only cargo (a cargo type id), as the cargo filter window sets it for a stop
function M.cargoLoads(cargoId)
	local v = M.idVector(false)
	v[cargoId + 1] = true
	return v
end

-- as cargofilter_window.tl: each stop's StopConfig copied, loading only cargoId at full capacity, and the line
-- marked customFilters (so the base's autoLoadConfig leaves it alone from then on)
-- whether a stop's platform takes cargoId, from its Terminal flags (as line_util.isTerminalCargoTypeAllowed goes
-- by the terminal): passengers need passengersLoad or passengersUnload, any other cargo cargoLoad or cargoUnload.
-- A flag the engine does not give counts as allowed (nothing to go by). Returns true, or nil and why.
function M.terminalTakes(stop, cargoId)
	local group = api.engine.getComponent(field(stop, "stationGroup"), CT().STATION_GROUP)
	local station = toList(group and field(group, "stations"))[(tonumber(field(stop, "station")) or -1) + 1]
	local sc = station and api.engine.getComponent(station, CT().STATION)
	local t = sc and toList(field(sc, "terminals"))[(tonumber(field(stop, "terminal")) or -1) + 1]
	if not t then return true end
	local passenger = cargoId == api.res.cargoTypeRep.getPassengerCargoTypeId()
	local load, unload = field(t, passenger and "passengersLoad" or "cargoLoad"), field(t, passenger and "passengersUnload" or "cargoUnload")
	if load == false and unload == false then return nil, passenger and "takes no passengers" or "takes no cargo" end
	return true
end

function M.applyCargo(comp, cargoId)
	local stops = {}
	for i, s in ipairs(toList(comp.stops)) do
		-- the base never turns on a cargo a platform cannot handle (autoLoadConfig's keepCargo, the cargo filter's
		-- allowed rows); what the engine does with one is unknown, so it is not sent
		local ok, why = M.terminalTakes(s, cargoId)
		if not ok then
			error(string.format("stop %d (station group %s): its platform %s; nothing sent", i, tostring(field(s, "stationGroup")), why), 0)
		end
		local cfg = api.type.Line.StopConfig.new(s.stopConfig)
		cfg.load = M.cargoLoads(cargoId)
		cfg.maxLoad = M.idVector(1)
		s.stopConfig = cfg
		stops[#stops + 1] = s
	end
	comp.stops = stops
	comp.customFilters = true
end

-- { stationGroup, station, terminal } per stop, as numbers
function M.stopsOf(stops)
	local out = {}
	for _, s in ipairs(toList(stops)) do
		out[#out + 1] = { stationGroup = tonumber(field(s, "stationGroup")), station = tonumber(field(s, "station")),
			terminal = tonumber(field(s, "terminal")) }
	end
	return out
end

-- every stop has a station and a terminal that exist. Returns true, or nil and why. The base leaves -1 where the
-- station group has no station (autoAssignTerminals), and the engine asserts on that.
function M.checkStops(stops)
	local list = M.stopsOf(stops)
	if #list == 0 then return nil, "no stops" end
	for i, s in ipairs(list) do
		if not s.stationGroup or not s.station or not s.terminal or s.station < 0 or s.terminal < 0 then
			return nil, string.format("stop %d (station group %s): no platform was assigned (station %s, terminal %s); " ..
				"nothing sent", i, tostring(s.stationGroup), tostring(s.station), tostring(s.terminal))
		end
		local group = api.engine.getComponent(s.stationGroup, CT().STATION_GROUP)
		local stations = toList(group and field(group, "stations"))
		local station = stations[s.station + 1]
		if station == nil then
			return nil, string.format("stop %d: station %d of station group %d does not exist (%d stations); nothing sent",
				i, s.station, s.stationGroup, #stations)
		end
		local sc = api.engine.getComponent(station, CT().STATION)
		local n = #toList(sc and field(sc, "terminals"))
		if s.terminal >= n then
			return nil, string.format("stop %d: terminal %d of station %d does not exist (%d terminals); nothing sent",
				i, s.terminal, station, n)
		end
	end
	return true
end

-- the waiting time the base gives a new stop (line_util.makeNewStop): 30 s where road or tram stop without rail
local function waitingTime(groupId)
	local C = api.type.enum.Carrier
	local road, rail = false, false
	local ok = pcall(function()
		for _, c in ipairs(toList(toList(api.engine.system.stationGroupSystem.getCarriers(groupId, -1, -1))[1])) do
			if c == C.ROAD or c == C.TRAM then road = true end
			if c == C.RAIL then rail = true end
		end
	end)
	return (ok and road and not rail) and 30 or 60
end

-- passengers on at a passenger station, as the base's addPassengerByDefault (line_util.tl); cargo is left to
-- --cargo in the cmd way (the base works it out from the stations' stocks in autoLoadConfig)
local function passengerLoads(groupId)
	local loads = M.idVector(false)
	local group = api.engine.getComponent(groupId, CT().STATION_GROUP)
	for _, st in ipairs(toList(group and field(group, "stations"))) do
		local ok, isPassenger = pcall(function() return api.engine.util.station.isStationOfType(st, false) end)
		if ok and isPassenger then
			loads[api.res.cargoTypeRep.getPassengerCargoTypeId() + 1] = true
			return loads, true
		end
	end
	return loads, false
end

-- a stop at a station group with no platform yet, as makeNewStop + autoAssignTerminals make it before assignment
function M.newStop(groupId)
	local s = api.type.Line.Stop.new()
	s.stationGroup = groupId
	s.station = -1
	s.terminal = -1
	local cfg = api.type.Line.StopConfig.new()
	cfg.load = passengerLoads(groupId)
	cfg.maxLoad = M.idVector(1)
	cfg.forceUnload = false
	s.stopConfig = cfg
	s.alternativeTerminals = {}
	s.maxAdditionalWaitingTime = waitingTime(groupId)
	return s
end

-- The cmd way. r: { kind = "create" | "update", line, stops = { { stationGroup } } or nil, cargo }. Returns the
-- Line component to send and notes (platforms the engine found none for). An update keeps the line's own stop
-- (platform, waiting times, cargo settings) for each requested stop at the same station group, in order, as the
-- line manager keeps the stops it does not touch; waypoints go.
function M.cmdLine(r)
	local old = r.kind == "update" and api.engine.getComponent(r.line, CT().LINE) or nil
	if r.kind == "update" and not old then error("no line " .. tostring(r.line), 0) end
	local comp
	if old then
		comp = api.type.Line.new(old)
	else
		comp = api.type.Line.new()
		comp.reservationPriority = 1.0 -- manager_window.tl newLine
	end
	local notes = {}
	if r.stops then
		local oldStops, used, stops = toList(comp.stops), {}, {}
		for _, want in ipairs(r.stops) do
			local stop
			for i, o in ipairs(oldStops) do
				if not used[i] and tonumber(field(o, "stationGroup")) == want.stationGroup then
					used[i], stop = true, o
					stop.waypoints = {}
					break
				end
			end
			stops[#stops + 1] = stop or M.newStop(want.stationGroup)
		end
		comp.stops = stops
		-- as autoAssignTerminals: only when a stop has no platform, then the engine's assignment for every stop
		-- (allowing changes, so kept stops may move too, as in the base), 0/0 where it has none
		local needed = false
		for _, s in ipairs(stops) do needed = needed or tonumber(s.station) < 0 or tonumber(s.terminal) < 0 end
		local best = needed and toList(api.engine.system.lineSystem.getBestLineAssignment(r.kind == "update" and r.line or -1, comp, true)) or {}
		for k, s in ipairs(needed and stops or {}) do
			local v = best[k]
			local st, te = tonumber(field(v, "station")), tonumber(field(v, "terminal"))
			if st and te and st >= 0 and te >= 0 then
				s.station, s.terminal = st, te
			else
				local group = api.engine.getComponent(s.stationGroup, CT().STATION_GROUP)
				if #toList(group and field(group, "stations")) > 0 then
					s.station, s.terminal = 0, 0
					notes[#notes + 1] = string.format("stop %d: the engine found no platform; station 0 terminal 0 " ..
						"used, as the base does", k)
				end
			end
		end
		comp.stops = stops
	end
	if r.cargo then M.applyCargo(comp, r.cargo) end
	local ok, why = M.checkStops(comp.stops)
	if not ok then error(why, 0) end
	return comp, notes
end

-- The gui way: the line built by the base's line_util as the line manager builds it. Returns the Line component.
local function guiLine(lu, req, r)
	local state
	if r.kind == "update" then
		state = lu.getReactLineFromGameState(r.line)
		if not state then error("no line " .. tostring(r.line), 0) end
	else
		state = { path = {}, reservationPriority = 1.0 } -- manager_window.tl newLine
	end
	if r.stops then
		-- a stop of the line at the same station group keeps its via (platform, settings), as when the line
		-- manager adds a stop; the others are new, as when a station is clicked. Waypoints go.
		local old, used, path = state.path or {}, {}, {}
		for _, want in ipairs(r.stops) do
			local via
			for i, v in ipairs(old) do
				if not used[i] and v.stop and v.stop.stationGroup == want.stationGroup then
					used[i], via = true, v
					break
				end
			end
			path[#path + 1] = via or lu.makeNewStop({ stationGroup = want.stationGroup })
		end
		state.path = path
		-- autoLoadConfig assigns platforms only to stops without one, as after a click
		lu.autoLoadConfig(state)
	end
	local entity = state.entityAndRevision and state.entityAndRevision.entity or nil
	local comp = api.type.Line.new()
	comp.stops = lu.autoAssignTerminals(entity, state.path)
	if state.customFilters ~= nil then comp.customFilters = state.customFilters end
	if state.reservationPriority ~= nil then comp.reservationPriority = state.reservationPriority end
	if r.cargo then M.applyCargo(comp, r.cargo) end
	local ok, why = M.checkStops(comp.stops)
	if not ok then error(why, 0) end
	return comp
end

-- The gui way of one request (core.lineRequests): create or update, through the base's line_util, in the speed
-- control's join (main thread). report: sentStops and sentName now, success and entity from the command's
-- callback later; error when nothing could be sent. Renames and deletes are engine commands in the base too, and
-- go from the guiUpdate script in both ways.
function M.performGui(req, r, report)
	local ok, lu = pcall(req, M.LINE_UTIL)
	if not ok then error("could not load " .. M.LINE_UTIL .. ": " .. tostring(lu), 0) end
	for _, f in ipairs({ "makeNewStop", "autoLoadConfig", "autoAssignTerminals", "getReactLineFromGameState",
		"makeLineName", "makeLineColor" }) do
		if type(lu) ~= "table" or type(lu[f]) ~= "function" then error(M.LINE_UTIL .. " has no " .. f, 0) end
	end
	local comp = guiLine(lu, req, r)
	report.sentStops = M.stopsOf(comp.stops)
	if r.kind == "create" then
		local player = api.engine.util.getPlayer()
		local name = r.name or lu.makeLineName(player)
		report.sentName = name
		api.cmd.sendCommand(api.cmd.makeLineCreateCmd(name, lu.makeLineColor(player), player, comp),
			function(res, success, entities)
				report.success = success == true
				local first = toList(entities)[1]
				report.entity = tonumber(first and toList(first)[1]) or tonumber(field(res, "resultEntity"))
			end)
	else
		api.cmd.sendCommand(api.cmd.makeLineUpdateCmd(r.line, comp), function(_, success) report.success = success == true end)
	end
end

return M
