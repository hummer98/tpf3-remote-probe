-- Lines for the remote probe: the station and line lists (stations, lines) and making, changing and removing a
-- line (line create / update / delete), so a client can build a line and run vehicles on it without a player.
-- Vehicles go onto a line with buy --line (remote_vehicles.lua).
--
-- Two ways for create and update, chosen by args.via, and the answer says which ran (line_configs.lua has both):
--   gui (default): the base's line_util (makeNewStop, autoLoadConfig, autoAssignTerminals, makeLineName,
--     makeLineColor), as the line manager builds a line. It is a GUI module that requires react ones, so like the
--     vehicle commands' gui way it runs in the speed control's join (publishUi "lines"), and the recipe reports
--     under its own key (REPORT_KEY).
--   cmd: Line.Stop built here, platforms from lineSystem.getBestLineAssignment; cargo is loaded only as --cargo
--     says (the base works it out from the stations' stocks), passengers at passenger stations.
-- A rename (makeEntitySetNameCmd) and a delete (makeLineDestroyCmd) are engine commands in the base too, sent from
-- here either way.
--
-- Every answer is read back from the engine (the line's stops, platforms, name, vehicles), never what was sent.
-- Stops are checked before anything goes out: every stop at a station group of the company (or nobody's), at
-- least two of them, one carrier they share, and after assignment a station and terminal that exist. A stop the
-- engine cannot place asserts, and an assertion takes the game down whatever pcall says. Platforms given by the
-- caller (terminals: every stop or none) are checked to exist and to share a carrier before the engine is asked
-- anything about them (line_configs.checkTerminals).
local M = {}

local ASYNC_TIMEOUT_SEC = 60
local SETTLE_FRAMES = 2
local CARRIERS = { "ROAD", "RAIL", "TRAM", "AIR", "WATER", "OTHER" }
local GUI_NOTE = "via gui: built by the base's line_util in the speed control (the speed buttons' react recipe), " ..
	"so it needs a game on screen with the speed buttons; the result is read back from the engine"
local CMD_NOTE = "via cmd: stops built by the probe; cargo is loaded only with --cargo (passengers at passenger " ..
	"stations), where the base's autoLoadConfig picks it from the stations' stocks"
local NO_REPORT_NOTE = "via gui: no report from the speed control came through: what was sent is unknown (the " ..
	"line shows what the engine holds)"

-- ctx: core, answer(id, payload, tag), fail(id, msg), appTime(), try(fn), say(msg, level), publishUi
function M.new(ctx)
	local core, answer, fail, appTime, try, say = ctx.core, ctx.answer, ctx.fail, ctx.appTime, ctx.try, ctx.say
	local req = ctx.require or ug_require or require
	local MOD = ctx.mod or core.MOD_ID
	local lc = req(MOD .. "::/line_configs.lua")
	local REPORT_KEY = MOD .. ".lines"
	local publishUi = ctx.publishUi or function() end
	local L = { jobs = {}, frames = 0, requests = {}, claimed = {} }
	local handlers = {}
	local perStop

	local function CT() return api.type.ComponentType end
	local function player() return api.engine.util.getPlayer() end
	local function comp(e, kind) return try(function() return api.engine.getComponent(e, CT()[kind]) end) end
	local function nameOf(e)
		local n = try(function() return api.engine.util.getEntityName(e) end)
		return type(n) == "string" and n or nil
	end

	local function carrierName(v)
		local enum = try(function() return api.type.enum.Carrier end)
		for _, n in ipairs(CARRIERS) do
			if enum and try(function() return enum[n] end) == v then return n end
		end
		return tostring(v)
	end

	-- the carriers a station group (or one of its terminals) serves, by name, sorted
	local function carriersOf(group, station, terminal)
		local res = try(function() return api.engine.system.stationGroupSystem.getCarriers(group, station or -1, terminal or -1) end)
		local out = {}
		for _, c in ipairs(core.toList(core.at(res, 1))) do out[#out + 1] = carrierName(c) end
		table.sort(out)
		return out
	end

	-- "player", "none" or "foreign": the PLAYER_OWNED of the station group, else of its stations (the base's
	-- station statistics take groups owned by the player or by nobody, entity_util.isOwnedByPlayerOrNotOwned)
	local function ownerOf(group, stations)
		local me, mine, theirs = player(), false, false
		local function look(e)
			local po = comp(e, "PLAYER_OWNED")
			local p = po and tonumber(core.field(po, "player"))
			if p == nil then return end
			if p == me then mine = true else theirs = true end
		end
		look(group)
		for _, st in ipairs(stations) do look(st) end
		-- one foreign part is enough to keep out: a line through it would be refused or worse
		return theirs and "foreign" or (mine and "player" or "none")
	end

	-- the middle of an entity's bounding box (as the base town and industry windows place an entity), or nil
	local function posOf(e)
		local bv = comp(e, "BOUNDING_VOLUME")
		local bb = bv and core.field(bv, "bbox")
		local lo, hi = bb and core.field(bb, "min"), bb and core.field(bb, "max")
		local x0, y0 = tonumber(lo and core.field(lo, "x")), tonumber(lo and core.field(lo, "y"))
		local x1, y1 = tonumber(hi and core.field(hi, "x")), tonumber(hi and core.field(hi, "y"))
		if not (x0 and y0 and x1 and y1) then return nil end
		return { x = (x0 + x1) / 2, y = (y0 + y1) / 2 }
	end

	local function flag(v)
		if v == true or v == false then return v end
		return nil
	end

	-- where vehicles stop at a terminal: its first vehicle edge's position (EdgePos: edge and param), as the base
	-- finds a waypoint (line_react_util.tl: TRANSPORT_NETWORK edges[index + 1].geometry, transport.calcPosition).
	-- nil when any of it cannot be read; the index is checked first (an engine vector read past its end may assert)
	local function terminalPos(t)
		return try(function()
			local edges = core.field(t, "vehicleEdges")
			if core.size(edges) < 1 then return nil end
			local ep = core.at(edges, 1)
			local id = core.field(ep, "edgeId")
			local ent, idx = tonumber(core.field(id, "entity")), tonumber(core.field(id, "index"))
			if not ent or not idx or idx < 0 then return nil end
			local tn = comp(ent, "TRANSPORT_NETWORK")
			local list = tn and core.field(tn, "edges")
			if idx >= core.size(list) then return nil end
			local geo = core.field(core.at(list, idx + 1), "geometry")
			if geo == nil then return nil end
			local p = api.engine.util.transport.calcPosition(geo, tonumber(core.field(ep, "param")) or 0)
			local x, y, z = tonumber(core.field(p, "x")), tonumber(core.field(p, "y")), tonumber(core.field(p, "z"))
			if not (x and y) then return nil end
			return { x = x, y = y, z = z }
		end)
	end

	-- a terminal's cargoTransferSpeeds: { length, loadSpeedModifier } each; nil when the terminal has none to read
	local function transferSpeeds(t)
		local v = core.field(t, "cargoTransferSpeeds")
		if v == nil or not pcall(function() return #v end) then return nil end
		local out = {}
		for _, x in ipairs(core.toList(v)) do
			out[#out + 1] = { length = tonumber(core.field(x, "length")), loadSpeedModifier = tonumber(core.field(x, "loadSpeedModifier")) }
		end
		return core.array(out)
	end

	-- a terminal's transportModes ({ [TransportMode] = true }) by name, sorted: what tells a large pier (SHIP and
	-- SMALL_SHIP) from a small one (SMALL_SHIP only; medium_pier / small_pier.module.lua), both WATER as carriers.
	-- nil when it cannot be read.
	-- a set of transport modes ({ [TransportMode] = true }, as the engine's maps) by name, sorted; nil when it
	-- cannot be read
	local function modeNames(v)
		if v == nil then return nil end
		local enum = try(function() return api.type.enum.TransportMode end)
		local names = {}
		local ok = pcall(function()
			for m, on in pairs(v) do
				if on == true then
					local n = tostring(m)
					for k, x in pairs(enum or {}) do if x == m then n = k end end
					names[#names + 1] = n
				end
			end
		end)
		if not ok then return nil end
		table.sort(names)
		return core.array(names)
	end
	local function modesOf(t) return modeNames(core.field(t, "transportModes")) end

	-- every platform of a station group, for picking one (line create --terminals): station and terminal 0-based as
	-- a line stop holds them, the terminal's tag (a vanilla harbour's module cell, 1000 * coordI + coordJ:
	-- modules.script.lua), where vehicles stop, the load flags, cargoTransferSpeeds and the carriers it serves.
	-- Read only; what cannot be read is nil.
	local function platformsOf(group, stations)
		local out = {}
		for si, st in ipairs(stations) do
			local sc = comp(st, "STATION")
			for ti, t in ipairs(core.toList(sc and core.field(sc, "terminals"))) do
				local carriers = carriersOf(group, si - 1, ti - 1)
				out[#out + 1] = { station = si - 1, terminal = ti - 1, stationEntity = st, tag = tonumber(core.field(t, "tag")),
					position = terminalPos(t), cargoLoad = flag(core.field(t, "cargoLoad")),
					cargoUnload = flag(core.field(t, "cargoUnload")), passengersLoad = flag(core.field(t, "passengersLoad")),
					passengersUnload = flag(core.field(t, "passengersUnload")), cargoTransferSpeeds = transferSpeeds(t),
					carriers = #carriers > 0 and core.array(carriers) or nil, transportModes = modesOf(t),
					capacity = tonumber(core.field(t, "capacity")) }
			end
		end
		return core.array(out)
	end

	-- one station group as the engine holds it; nil when e is none
	local function groupInfo(e)
		local sg = comp(e, "STATION_GROUP")
		if not sg then return nil end
		local stations = core.toList(core.field(sg, "stations"))
		local terminals = 0
		for _, st in ipairs(stations) do
			local sc = comp(st, "STATION")
			terminals = terminals + core.size(sc and core.field(sc, "terminals"))
		end
		local pos = nil
		for _, st in ipairs(stations) do pos = pos or posOf(st) end
		pos = pos or posOf(e)
		return { id = e, name = nameOf(e) or "", stations = #stations, stationIds = core.array(stations), terminals = terminals,
			carriers = core.array(carriersOf(e)), owner = ownerOf(e, stations), position = pos,
			lines = core.size(try(function() return api.engine.system.lineSystem.getLinesForStationGroup(e) end)) }
	end

	-- the station groups the company may use (its own and nobody's), and the others' names for a clearer refusal
	local function usableGroups()
		local own, foreign = {}, {}
		for _, e in ipairs(core.toList(try(function() return api.engine.getEntitiesWithComponent(CT().STATION_GROUP) end))) do
			local info = groupInfo(e)
			if info then
				if info.owner == "foreign" then foreign[#foreign + 1] = info else own[#own + 1] = info end
			end
		end
		table.sort(own, function(a, b) return a.name < b.name end)
		return own, foreign
	end

	-- one stop as given (core.lineArgs: an id or a name) -> the station group's info, or nil and why
	local function resolveStop(tok, i, own, foreign)
		if type(tok) == "number" then
			local group = tok
			if not comp(tok, "STATION_GROUP") then
				if not comp(tok, "STATION") then return nil, string.format("stop %d: %d is no station group or station", i, tok) end
				group = tonumber(try(function() return api.engine.system.stationGroupSystem.getStationGroup(tok) end))
				if not group or not comp(group, "STATION_GROUP") then
					return nil, string.format("stop %d: station %d has no station group", i, tok)
				end
			end
			local info = groupInfo(group)
			if info.owner == "foreign" then
				return nil, string.format("stop %d: station group %d (%s) belongs to another company", i, group, info.name)
			end
			return info
		end
		local hit, err = core.matchEntity(own, tok)
		if hit then return hit end
		for _, f in ipairs(foreign) do
			if f.name:lower() == tok:lower() then
				return nil, string.format("stop %d: %s (%d) belongs to another company", i, f.name, f.id)
			end
		end
		return nil, string.format("stop %d: %s", i, err)
	end

	-- the stops as station groups, checked: usable, with stations, sharing a carrier. Returns the list of infos.
	local function resolveStops(tokens)
		local own, foreign = usableGroups()
		local out, common = {}, nil
		for i, tok in ipairs(tokens) do
			local info, err = resolveStop(tok, i, own, foreign)
			if not info then return nil, err end
			if info.stations == 0 or info.terminals == 0 then
				return nil, string.format("stop %d: station group %d (%s) has no station with a platform", i, info.id, info.name)
			end
			local set = {}
			for _, c in ipairs(info.carriers) do set[c] = true end
			if common == nil then
				common = set
			else
				for c in pairs(common) do if not set[c] then common[c] = nil end end
			end
			out[#out + 1] = info
		end
		-- the same group twice in a row (the last and the first too: a line runs round) is no trip; what the engine
		-- does with it is unknown
		for i, s in ipairs(out) do
			local nxt = out[i % #out + 1]
			if #out > 1 and nxt.id == s.id then
				return nil, string.format("stops %d and %d are both %s (%d): a line runs round, so neighbours (the last " ..
					"and the first too) must differ", i, i % #out + 1, s.name, s.id)
			end
		end
		if next(common or {}) == nil then
			local each = {}
			for _, s in ipairs(out) do each[#each + 1] = string.format("%s: %s", s.name, table.concat(s.carriers, "+")) end
			return nil, "the stops share no carrier (" .. table.concat(each, "; ") .. "): no vehicle could serve them all"
		end
		return out
	end

	-- the cargo types: { id, name (resource), label (shown name) }
	local function cargoTypes()
		local out = {}
		local all = try(function() return api.res.cargoTypeRep.getAll(true) end)
		pcall(function()
			for id, name in pairs(all) do
				local label = try(function() return api.res.cargoTypeRep.get(id).name end)
				out[#out + 1] = { id = tonumber(id), name = tostring(name), label = type(label) == "string" and label or nil }
			end
		end)
		table.sort(out, function(a, b) return a.id < b.id end)
		return out
	end

	local function cargoName(id, types)
		for _, c in ipairs(types) do if c.id == id then return c.name end end
		return tostring(id)
	end

	local function lineVehicles(line)
		return core.toList(try(function() return api.engine.system.transportVehicleSystem.getLineVehicles(line) end))
	end

	-- the line as the engine holds it; nil when it is gone
	local function lineInfo(e, types)
		local lineComp = comp(e, "LINE")
		if not lineComp then return nil end
		types = types or cargoTypes()
		local stops, loads, loadSet = {}, {}, {}
		for _, s in ipairs(core.toList(core.field(lineComp, "stops"))) do
			local sg, st, te = tonumber(core.field(s, "stationGroup")), tonumber(core.field(s, "station")), tonumber(core.field(s, "terminal"))
			local group = sg and comp(sg, "STATION_GROUP")
			local stationEntity = group and st and core.at(core.field(group, "stations"), st + 1) or nil
			-- loadMode: a number as the base's cargo filter reads it (0 available, 1 any, 2 all); nil if not one
			local lm = core.field(s, "loadMode")
			local cfg = core.field(s, "stopConfig")
			-- the stop's StopConfig flags and waiting times, as the cargo filter window reads them
			-- (cargofilter_window.tl): a boolean or number, nil when the engine gives none
			local function flag(k)
				local v = cfg and core.field(cfg, k)
				if type(v) == "boolean" then return v end
				return nil
			end
			local function num(k) return tonumber(core.field(s, k)) end
			local load = core.toList(cfg and core.field(cfg, "load"))
			local maxLoad = core.toList(cfg and core.field(cfg, "maxLoad"))
			-- this stop's loads: the cargo types it loads, with the fraction of the capacity (maxLoad, 0..1)
			local stopLoads = {}
			for i, on in ipairs(load) do
				if on == true then
					if not loadSet[i - 1] then loadSet[i - 1] = true; loads[#loads + 1] = cargoName(i - 1, types) end
					stopLoads[#stopLoads + 1] = { cargoType = i - 1, cargo = cargoName(i - 1, types), maxLoad = tonumber(maxLoad[i]) }
				end
			end
			stops[#stops + 1] = { stationGroup = sg, name = sg and nameOf(sg) or nil, station = st, terminal = te,
				stationEntity = tonumber(stationEntity), loadMode = type(lm) == "number" and lm or nil,
				forceUnload = flag("forceUnload"), destroyForConfigChange = flag("destroyForConfigChange"),
				destroyForRefresh = flag("destroyForRefresh"), stopLoads = core.array(stopLoads),
				minWaitingTime = num("minWaitingTime"), maxWaitingTime = num("maxWaitingTime"),
				maxAdditionalWaitingTime = num("maxAdditionalWaitingTime") }
		end
		-- what the line's vehicles can carry: their capacities per cargo type (the base vehicle window reads
		-- transportVehicle.config.capacities the same way)
		local vehicles, carry, carrySet = lineVehicles(e), {}, {}
		for _, v in ipairs(vehicles) do
			local tv = comp(v, "TRANSPORT_VEHICLE")
			local caps = core.toList(try(function() return tv.config.capacities end))
			for i, n in ipairs(caps) do
				if (tonumber(n) or 0) > 0 and not carrySet[i - 1] then carrySet[i - 1] = true; carry[#carry + 1] = cargoName(i - 1, types) end
			end
		end
		local first = stops[1]
		return { id = e, name = nameOf(e) or "", stops = core.array(stops), vehicles = #vehicles,
			vehicleIds = core.array(vehicles),
			carriers = core.array(first and first.stationGroup and carriersOf(first.stationGroup, first.station, first.terminal) or {}),
			customFilters = core.field(lineComp, "customFilters") == true, loads = core.array(loads),
			vehicleCargo = core.array(carry) }
	end

	local function ownLines()
		return core.toList(try(function() return api.engine.system.lineSystem.getLinesForPlayer(player()) end))
	end

	-- the ids of resolved stops (groupInfo), in order
	local function idsOf(infos)
		local out = {}
		for _, s in ipairs(infos or {}) do out[#out + 1] = s.id end
		return out
	end
	-- the station groups' ids of a line's stops, in order
	local function groupsOf(stops)
		local out = {}
		for _, s in ipairs(stops or {}) do out[#out + 1] = s.stationGroup end
		return out
	end
	local function sameList(a, b)
		if #a ~= #b then return false end
		for i = 1, #a do if a[i] ~= b[i] then return false end end
		return true
	end

	---------------------------------------------------------------------------------------------------------------
	-- the gui requests, as for the vehicles (remote_vehicles.lua)

	local function publishRequests()
		local list = {}
		for _, r in pairs(L.requests) do list[#list + 1] = r end
		table.sort(list, function(a, b) return a.id < b.id end)
		publishUi({ lines = list })
	end

	local function reportOf(id)
		local d = try(function() return api.gui.game.getGuiSaveData(REPORT_KEY) end)
		if type(d) ~= "table" or type(d.reports) ~= "table" then return nil end
		for _, r in ipairs(d.reports) do
			if type(r) == "table" and tonumber(r.id) == id then return r end
		end
		return nil
	end

	function L.reset()
		return pcall(function() api.gui.game.setGuiSaveData(REPORT_KEY, { reports = {} }) end)
	end

	local function newJob(c, a)
		return { id = c.id, action = a.action, via = a.via, deadline = appTime() + ASYNC_TIMEOUT_SEC, failures = {},
			notes = {} }
	end

	local function retire(job)
		-- claimed lines stay claimed: a create still waiting may have been sent before this line appeared, and
		-- would take it once released
		if L.requests[job.id] then
			L.requests[job.id] = nil
			publishRequests()
		end
	end

	-- the report's news taken into the job: error, success, entity, what was sent
	local function absorb(job)
		if not job.request then return end
		local r = reportOf(job.id)
		if not r then return end
		job.picked = true
		if r.error ~= nil and not job.reportError then
			job.reportError = "via gui: " .. tostring(r.error)
			job.failures[#job.failures + 1] = job.reportError
		end
		if type(r.sentStops) == "table" then job.sentStops = core.plain(r.sentStops) end
		if r.sentName ~= nil then job.sentName = tostring(r.sentName) end
		if r.success ~= nil then job.result = r.success == true end
		if tonumber(r.entity) then job.entity = tonumber(r.entity) end
	end

	local function payloadOf(job)
		local out = { ok = true, cmd = "line", action = job.action, via = job.via, line = job.entity, notes = job.notes,
			sentStops = job.sentStops, sentName = job.sentName }
		if job.via == "gui" and job.request then
			table.insert(out.notes, 1, GUI_NOTE)
			if not job.picked then out.notes[#out.notes + 1] = NO_REPORT_NOTE end
		elseif job.via == "cmd" and job.built then
			table.insert(out.notes, 1, CMD_NOTE)
		end
		if #out.notes == 0 then out.notes = nil end
		if job.entity then
			local info = lineInfo(job.entity)
			if info then
				out.name, out.stops, out.vehicles, out.carriers, out.loads = info.name, info.stops, info.vehicles, info.carriers, info.loads
				out.customFilters = info.customFilters
			end
			out.exists = info ~= nil
		end
		if #job.failures > 0 then out.failures = job.failures end
		if job.finish then job.finish(out) end
		return out
	end

	local function stepJob(job)
		absorb(job)
		if not job.settleAt and job.check() then job.settleAt = L.frames + SETTLE_FRAMES end
		if job.settleAt then
			if L.frames < job.settleAt then return false end
			local out = payloadOf(job)
			if #job.failures > 0 or out.ok == false then
				out.ok = false
				-- the engine's refusal says more than the read-back that follows from it
				out.error = #job.failures > 0 and table.concat(job.failures, "; ") or out.error
			end
			answer(job.id, out, (not out.ok) and "error" or nil)
			return true
		end
		if appTime() <= job.deadline then return false end
		local ok, out = pcall(payloadOf, job)
		if not ok then out = { readError = tostring(out) } end
		out.ok = false
		out.error = string.format("no result in %d s%s", ASYNC_TIMEOUT_SEC,
			(job.request and not job.picked) and "; via gui: no word from the speed control, which builds the line: " ..
				"is a game on screen with the speed buttons? (its report may also not come through: unverified)" or "")
		answer(job.id, out, "error")
		return true
	end

	function L.step()
		L.frames = L.frames + 1
		local keep = {}
		for _, job in ipairs(L.jobs) do
			local ok, finished = pcall(stepJob, job)
			if not ok then fail(job.id, finished) end
			if ok and not finished then keep[#keep + 1] = job else pcall(retire, job) end
		end
		L.jobs = keep
	end

	-- send runs first; a raise is the caller's one error answer, and no job waits to answer a second time
	local function start(job, send)
		send()
		L.jobs[#L.jobs + 1] = job
	end

	---------------------------------------------------------------------------------------------------------------
	-- line create / update / delete

	-- the rename the base's line manager sends (makeEntitySetNameCmd), with its result into job.renamed
	local function sendName(job, line, name)
		api.cmd.sendCommand(api.cmd.makeEntitySetNameCmd(line, name), function(_, success) job.renamed = success == true end)
	end

	local function lineName(name)
		if name then return name end
		-- the base's makeLineName, without its translation: the first free "Line N"
		local names = {}
		for _, e in ipairs(ownLines()) do names[nameOf(e) or ""] = true end
		for i = 1, 999 do
			local n = "Line " .. i
			if not names[n] then return n end
		end
		return "New Line"
	end

	local function lineColor()
		local c = lc.COLORS[(#ownLines() % #lc.COLORS) + 1]
		return api.type.Vec3f.new(c[1], c[2], c[3])
	end

	-- the platforms, load modes and force unload of a request (perStop below) onto a request or cmdLine's argument
	local function withPerStop(r, per)
		r.terminals, r.loadModes, r.carriers, r.forceUnload = per.terminals, per.loadModes, per.carriers, per.forceUnload
		return r
	end

	-- the line's stops read back hold the platforms, load modes and force unload asked for: an error, or nil
	local function perStopDiffers(stopsNow, per)
		for i, s in ipairs(stopsNow or {}) do
			local t = per.terminals and per.terminals[i]
			if t and (s.station ~= t.station or s.terminal ~= t.terminal) then
				return string.format("stop %d is at station %s terminal %s, not %d:%d as asked", i, tostring(s.station),
					tostring(s.terminal), t.station, t.terminal)
			end
			local m = per.loadModes and per.loadModes[i]
			if m and s.loadMode ~= nil and s.loadMode ~= m then
				return string.format("stop %d has load mode %s, not %d as asked", i, tostring(s.loadMode), m)
			end
			local f = per.forceUnload and per.forceUnload[i]
			if f ~= nil and s.forceUnload ~= f then
				return string.format("stop %d has force unload %s, not %s as asked", i, tostring(s.forceUnload), tostring(f))
			end
		end
		return nil
	end

	local function create(c, a, stops, cargoId, per)
		local job = newJob(c, a)
		job.wanted = idsOf(stops)
		local known = {}
		for _, e in ipairs(ownLines()) do known[e] = true end
		job.check = function()
			if job.reportError then return true end
			if job.result == false then
				if not job.refused then
					job.refused = true
					job.failures[#job.failures + 1] = "the engine refused the line (makeLineCreateCmd failed)"
				end
				return true
			end
			-- gui without a report: the new line is the one the company did not have, at the stops asked for
			if job.request and not job.picked and not job.entity then
				for _, e in ipairs(ownLines()) do
					-- a line another create took is not this one's (two creates at the same stops)
					local info = not known[e] and not L.claimed[e] and lineInfo(e)
					if info and not job.entity and sameList(groupsOf(info.stops), job.wanted) then
						job.entity = e
						L.claimed[e] = true
					end
				end
			end
			return job.entity ~= nil and comp(job.entity, "LINE") ~= nil
		end
		job.finish = function(out)
			if out.exists and not sameList(groupsOf(out.stops), job.wanted) then
				out.ok, out.error = false, "the line's stops differ from those asked for"
			end
			if a.name and out.name ~= a.name then
				out.ok, out.error = false, "the line's name is not the one asked for"
			end
			local differs = out.exists and perStopDiffers(out.stops, per)
			if differs then out.ok, out.error = false, differs end
		end
		start(job, function()
			if a.via == "gui" then
				local r = withPerStop({ id = job.id, kind = "create", stops = {}, name = a.name, cargo = cargoId }, per)
				for _, s in ipairs(stops) do r.stops[#r.stops + 1] = { stationGroup = s.id } end
				job.request = r
				L.requests[job.id] = r
				publishRequests()
			else
				local stopList = {}
				for _, s in ipairs(stops) do stopList[#stopList + 1] = { stationGroup = s.id } end
				local line, notes = lc.cmdLine(withPerStop({ kind = "create", stops = stopList, cargo = cargoId }, per))
				for _, n in ipairs(notes) do job.notes[#job.notes + 1] = n end
				job.built, job.sentStops = true, lc.stopsOf(line.stops)
				job.sentName = lineName(a.name)
				api.cmd.sendCommand(api.cmd.makeLineCreateCmd(job.sentName, lineColor(), player(), line),
					function(res, success, entities)
						job.result = success == true
						local first = core.at(entities, 1)
						job.entity = tonumber(first and core.at(first, 1)) or tonumber(core.field(res, "resultEntity"))
					end)
			end
		end)
		say(string.format("line %d: create, %d stops via %s", c.id, #stops, a.via), 2)
	end

	local function update(c, a, stops, cargoId, per)
		local before = lineInfo(a.line)
		local job = newJob(c, a)
		job.entity, job.before = a.line, before
		job.wanted = stops and idsOf(stops) or nil
		local rebuild = stops ~= nil or cargoId ~= nil or per.terminals ~= nil or per.loadModes ~= nil or per.forceUnload ~= nil
		job.check = function()
			if job.reportError then return true end
			if rebuild then
				if job.result == false then
					if not job.refused then
						job.refused = true
						job.failures[#job.failures + 1] = "the engine refused the change (makeLineUpdateCmd failed)"
					end
				elseif job.result == nil then
					-- gui without a report: in once the stops are those asked for and differ from before
					if not (job.request and not job.picked) then return false end
					local now = lineInfo(a.line)
					if not now or not job.wanted or not sameList(groupsOf(now.stops), job.wanted)
						or core.json(now.stops) == core.json(before.stops) then return false end
				end
			end
			if a.name and job.renamed == nil then return false end
			if a.name and job.renamed == false and not job.nameRefused then
				job.nameRefused = true
				job.failures[#job.failures + 1] = "the engine refused the name (makeEntitySetNameCmd failed)"
			end
			return true
		end
		job.finish = function(out)
			out.before = job.before
			if not out.exists then out.ok, out.error = false, "the line is gone" return end
			if job.wanted and not sameList(groupsOf(out.stops), job.wanted) then
				out.ok, out.error = false, "the line's stops differ from those asked for"
			end
			if a.name and out.name ~= a.name then out.ok, out.error = false, "the line's name is not the one asked for" end
			local differs = perStopDiffers(out.stops, per)
			if differs then out.ok, out.error = false, differs end
		end
		start(job, function()
			-- the rename first: a raise after a gui request was published would leave it to run unanswered
			if a.name then
				job.sentName = a.name
				sendName(job, a.line, a.name)
			end
			if rebuild then
				local stopList
				if stops then
					stopList = {}
					for _, s in ipairs(stops) do stopList[#stopList + 1] = { stationGroup = s.id } end
				end
				if a.via == "gui" then
					local r = withPerStop({ id = job.id, kind = "update", line = a.line, stops = stopList, cargo = cargoId }, per)
					job.request = r
					L.requests[job.id] = r
					publishRequests()
				else
					local line, notes = lc.cmdLine(withPerStop({ kind = "update", line = a.line, stops = stopList, cargo = cargoId }, per))
					for _, n in ipairs(notes) do job.notes[#job.notes + 1] = n end
					job.built, job.sentStops = true, lc.stopsOf(line.stops)
					api.cmd.sendCommand(api.cmd.makeLineUpdateCmd(a.line, line), function(_, success) job.result = success == true end)
				end
			end
		end)
	end

	-- as the line manager's delete (manager_window.tl): its vehicles sold first, then makeLineDestroyCmd. The
	-- vehicles go only with sellVehicles: a line is kept from losing them by a stray command.
	local function delete(c, a)
		local before = lineInfo(a.line)
		local vehicles = lineVehicles(a.line)
		if #vehicles > 0 and not a.sellVehicles then
			return fail(c.id, string.format("line %d has %d vehicles: give sellVehicles (--sell-vehicles) to sell them " ..
				"with it, as the line manager's delete does", a.line, #vehicles))
		end
		local job = newJob(c, { action = "delete", via = "cmd" })
		job.before = before
		job.check = function()
			if job.result == false or job.sold == false then
				if not job.refused then
					job.refused = true
					job.failures[#job.failures + 1] = job.sold == false and "the engine refused to sell the line's vehicles" or
						"the engine refused to remove the line (makeLineDestroyCmd failed)"
				end
				return true
			end
			return job.result == true and comp(a.line, "LINE") == nil
		end
		job.finish = function(out)
			out.line, out.before, out.removed = a.line, job.before, comp(a.line, "LINE") == nil
			out.soldVehicles = #vehicles > 0 and vehicles or nil
			if not out.removed then out.ok, out.error = false, out.error or "the line is still there" end
		end
		start(job, function()
			local function destroy()
				api.cmd.sendCommand(api.cmd.makeLineDestroyCmd(a.line), function(_, success) job.result = success == true end)
			end
			if #vehicles > 0 then
				api.cmd.sendCommand(api.cmd.makeVehicleSellCmd(vehicles), function(_, success)
					job.sold = success == true
					if job.sold then destroy() end
				end)
			else
				destroy()
			end
		end)
	end

	-- the platforms (terminals), load modes and force unload of a create or update, one per stop of the line as it
	-- will be (the stops given, or the line's own), checked here so a refusal answers at once; line_configs checks
	-- the platforms again in the Lua state that sends. On an update of a line with vehicles the platforms must serve the carrier
	-- those run on, taken as the base's line_util.getLineCarriers does: from the first stop's platform. Returns
	-- { terminals, loadModes, carriers, forceUnload } (each may be nil), or nil and why.
	function perStop(a, stops)
		local out = {}
		if not (a.terminals or a.loadModes or a.loadModeAll or a.forceUnload) then return out end
		local groups = {}
		local before = a.action == "update" and lineInfo(a.line) or nil
		for _, s in ipairs(stops or (before and before.stops) or {}) do groups[#groups + 1] = { stationGroup = s.id or s.stationGroup } end
		local n = #groups
		if a.terminals and #a.terminals ~= n then
			return nil, string.format("give a terminal for every stop (%d stops, %d terminals): when one stop has none, " ..
				"the base assigns every stop's platform anew (autoAssignTerminals), so some would not hold", n, #a.terminals)
		end
		if a.loadModeAll then
			out.loadModes = {}
			for i = 1, n do out.loadModes[i] = a.loadModeAll end
		elseif a.loadModes then
			if #a.loadModes ~= n then
				return nil, string.format("give one load mode for every stop, or one for all (%d stops, %d load modes)", n, #a.loadModes)
			end
			out.loadModes = a.loadModes
		end
		if a.forceUnload then
			if #a.forceUnload ~= n then
				return nil, string.format("give one force unload value for every stop (%d stops, %d values)", n, #a.forceUnload)
			end
			out.forceUnload = a.forceUnload
		end
		if a.terminals then
			local need
			local first = before and before.stops[1]
			if first and before.vehicles > 0 and first.station and first.terminal then
				need = lc.terminalCarriers(first.stationGroup, first.station, first.terminal)
				-- the vehicles' carrier unknown: whether they could stop at the new platforms cannot be told
				if not need then
					return nil, string.format("the carriers of line %d's first stop could not be read, so whether its %d " ..
						"vehicles can use the platforms given is unknown", a.line, before.vehicles)
				end
			end
			local ok, why = lc.checkTerminals(groups, a.terminals, need)
			if not ok then return nil, why end
			out.terminals = a.terminals
			if need then
				out.carriers = {}
				for k in pairs(need) do out.carriers[#out.carriers + 1] = k end
				table.sort(out.carriers)
			end
		end
		return out
	end

	-- args: action (create, update, delete), line, stops, name, cargo, sellVehicles, via, terminals, loadModes,
	-- forceUnload
	function handlers.line(c)
		local a, err = core.lineArgs(c.args)
		if not a then return fail(c.id, err) end
		if a.line ~= nil and not comp(a.line, "LINE") then return fail(c.id, "no line " .. a.line) end
		if a.line ~= nil then
			local mine = false
			for _, e in ipairs(ownLines()) do mine = mine or e == a.line end
			if not mine then return fail(c.id, "line " .. a.line .. " is not the company's") end
		end
		if a.action == "delete" then return delete(c, a) end
		local stops
		if a.stops then
			local err2
			stops, err2 = resolveStops(a.stops)
			if not stops then return fail(c.id, err2) end
		end
		local cargoId
		if a.cargo then
			local hit, err3 = core.matchCargo(cargoTypes(), a.cargo)
			if not hit then return fail(c.id, err3) end
			cargoId = hit.id
		end
		local per, err4 = perStop(a, stops)
		if not per then return fail(c.id, err4) end
		if a.action == "create" then return create(c, a, stops, cargoId, per) end
		return update(c, a, stops, cargoId, per)
	end

	---------------------------------------------------------------------------------------------------------------
	-- lists

	-- args: name (substring, any case), near (an entity: town, industry, station...), radius (m)
	---------------------------------------------------------------------------------------------------------------
	-- stations --catchment: what a station reaches (read only)

	local LAND_USES = { "RESIDENTIAL", "COMMERCIAL", "INDUSTRIAL" }

	-- The town buildings and industries in the catchment of a station, or of every station of a group: the
	-- engine's getStationCatchables(station, cargo) (engine/system.d.tl CatchmentAreaSystem: the entities holding a
	-- PersonCapacity, for cargo false, or a StockList, for cargo true), which the base reads the same way
	-- (line_util.tl isReallyPassengerStop, cargo_util.tl getInputOutputStocksForStation). Each entity is named by
	-- what holds it: an industry (its own id, or the stockList of an INDUSTRY), else a town building (the
	-- townBuildingSystem's personCapacity map, a TOWN_BUILDING itself, or the stockList of one), else listed as
	-- other. A building's kind: its PERSON_CAPACITY type against the LandUseType enum, as the base town window
	-- compares it (town.tl).
	local function catchment(id)
		local stations, group
		if comp(id, "STATION_GROUP") then
			group = id
			stations = core.toList(core.field(comp(id, "STATION_GROUP"), "stations"))
		elseif comp(id, "STATION") then
			stations = { id }
			group = tonumber(try(function() return api.engine.system.stationGroupSystem.getStationGroup(id) end))
		else
			return nil, string.format("%s is no station group or station", tostring(id))
		end
		local LU = try(function() return api.type.enum.LandUseType end)
		local function landUse(v)
			if v == nil then return nil end
			return core.enumName(LU or {}, LAND_USES, v):lower()
		end
		-- the industries: by id and by their stock list
		local industry, byStock = {}, {}
		for _, e in ipairs(core.toList(try(function() return api.engine.getEntitiesWithComponent(CT().INDUSTRY) end))) do
			industry[e] = true
			local sl = tonumber(core.field(comp(e, "INDUSTRY"), "stockList"))
			if sl then byStock[sl] = e end
		end
		local pc2tb = try(function() return api.engine.system.townBuildingSystem.getPersonCapacity2townBuildingMap() end)
		local stock2tb -- built only when a cargo entity is none of the above (every town building is read for it)
		local function townBuildingOf(e, cargo)
			local tb = pc2tb and tonumber(try(function() return pc2tb[e] end))
			if tb then return tb end
			if comp(e, "TOWN_BUILDING") then return e end
			if not cargo then return nil end
			if stock2tb == nil then
				stock2tb = {}
				local map = try(function() return api.engine.system.townBuildingSystem.getTown2BuildingMap() end)
				pcall(function()
					for _, list in pairs(map) do
						for _, b in ipairs(core.toList(list)) do
							local sl = tonumber(core.field(comp(b, "TOWN_BUILDING"), "stockList"))
							if sl then stock2tb[sl] = b end
						end
					end
				end)
			end
			return stock2tb[e]
		end
		local townNames = {}
		local function townName(t)
			if townNames[t] == nil then townNames[t] = nameOf(t) or false end
			return townNames[t] or nil
		end
		local function side(cargo)
			local seen, towns, townList, inds, other = {}, {}, {}, {}, {}
			local total = 0
			for _, st in ipairs(stations) do
				for _, e in ipairs(core.toList(try(function()
					return api.engine.system.catchmentAreaSystem.getStationCatchables(st, cargo)
				end))) do
					e = tonumber(e)
					if e and not seen[e] then
						seen[e] = true
						total = total + 1
						local ind = industry[e] and e or byStock[e]
						local tb = not ind and townBuildingOf(e, cargo) or nil
						if ind then
							if not seen["i" .. ind] then
								seen["i" .. ind] = true
								inds[#inds + 1] = { id = ind, name = nameOf(ind) }
							end
						elseif tb and not seen["b" .. tb] then
							seen["b" .. tb] = true
							local t = tonumber(core.field(comp(tb, "TOWN_BUILDING"), "town")) or -1
							local row = towns[t]
							if not row then
								row = { town = t >= 0 and t or nil, name = t >= 0 and townName(t) or nil, buildings = 0,
									residential = 0, commercial = 0, industrial = 0, capacity = { residential = 0, commercial = 0, industrial = 0 } }
								towns[t] = row
								townList[#townList + 1] = row
							end
							row.buildings = row.buildings + 1
							local pc = comp(tb, "PERSON_CAPACITY")
							local kind = pc and landUse(core.field(pc, "type"))
							if kind and row[kind] then
								row[kind] = row[kind] + 1
								row.capacity[kind] = row.capacity[kind] + (tonumber(core.field(pc, "capacity")) or 0)
							else
								row.unknownKind = (row.unknownKind or 0) + 1
							end
						elseif not tb then
							other[#other + 1] = e
						end
					end
				end
			end
			table.sort(townList, function(a, b) return (a.name or "") < (b.name or "") end)
			table.sort(inds, function(a, b) return (a.name or "") < (b.name or "") end)
			table.sort(other)
			return { entities = total, towns = core.array(townList), industries = core.array(inds), other = core.array(other) }
		end
		return { id = id, stationGroup = group, name = group and nameOf(group) or nil, stations = core.array(stations),
			passengers = side(false), cargo = side(true) }
	end

	function handlers.stations(c)
		if c.args.catchment ~= nil then
			local id = c.args.catchment
			if type(id) ~= "number" or id ~= math.floor(id) then return fail(c.id, "catchment must be a station or station group id") end
			local out, err = catchment(id)
			if not out then return fail(c.id, err) end
			return answer(c.id, { ok = true, catchment = out })
		end
		local near, radius, centre = c.args.near, nil, nil
		if near ~= nil then
			near = tonumber(near)
			if near == nil then return fail(c.id, "near must be an entity id") end
			local err
			radius, err = core.radiusArg(c.args.radius)
			if not radius then return fail(c.id, err) end
			centre = posOf(near)
			if not centre then return fail(c.id, "entity " .. near .. " has no position (no bounding volume)") end
		end
		local q = type(c.args.name) == "string" and c.args.name:lower() or nil
		local own = usableGroups()
		local out = {}
		for _, g in ipairs(own) do
			local keep = not q or g.name:lower():find(q, 1, true) ~= nil
			if keep and centre then
				if not g.position then
					keep = false
				else
					g.distance = math.floor(math.sqrt((g.position.x - centre.x) ^ 2 + (g.position.y - centre.y) ^ 2) + 0.5)
					keep = g.distance <= radius
				end
			end
			if keep then
				g.platforms = platformsOf(g.id, g.stationIds)
				g.stationIds = nil
				out[#out + 1] = g
			end
		end
		if centre then table.sort(out, function(x, y) return x.distance < y.distance end) end
		answer(c.id, { ok = true, stations = core.array(out), near = near, radius = radius, centre = centre })
	end

	-- a PathProblemLocation (engine/util.d.tl) as plain values; nil when there is none
	local function problemLocation(x)
		if x == nil then return nil end
		local p = core.field(x, "nodePosition")
		local pos = nil
		if p ~= nil then
			local px, py, pz = tonumber(core.field(p, "x")), tonumber(core.field(p, "y")), tonumber(core.field(p, "z"))
			if px and py then pos = { x = px, y = py, z = pz } end
		end
		local node = core.field(x, "node")
		return { edgeIndex = tonumber(core.field(x, "edgeIndex")), node = tonumber(node) or (node ~= nil and tostring(node) or nil),
			nodePosition = pos, okModes = modeNames(core.field(x, "okModes")),
			relaxedModes = modeNames(core.field(x, "relaxedModes")), allowedModes = modeNames(core.field(x, "allowedModes")) }
	end
	-- noPathToAlternative / noPathFromAlternative: { flattenedTerminalIndex, optional location }
	local function alternative(v)
		if v == nil then return nil end
		return { terminal = tonumber(core.at(v, 1)), location = problemLocation(core.at(v, 2)) }
	end

	-- what the line manager reads to mark a line's problems (line_manager_panel.tl, manager_window.tl):
	-- getDetailedLineProblems (per segment, per stop) and getLineTransportModesUnion; and the transport modes of
	-- each stop's platform, which tell a large pier from a small one. Read only; info.stops get transportModes.
	local function lineProblems(e, info)
		local out = { segments = core.array({}), count = 0 }
		local okD, detailed = pcall(function() return api.engine.util.line.getDetailedLineProblems(e) end)
		if not okD then
			out.readError = "getDetailedLineProblems: " .. tostring(detailed)
		else
			for _, seg in ipairs(core.toList(detailed)) do
				local stops = {}
				for _, st in ipairs(core.toList(seg)) do
					local x = { empty = flag(core.field(st, "empty")), noPath = flag(core.field(st, "noPath")),
						duplicateStop = flag(core.field(st, "duplicateStop")), incompatibleStop = flag(core.field(st, "incompatibleStop")),
						noPathLocation = problemLocation(core.field(st, "noPathLocation")),
						noPathToAlternative = alternative(core.field(st, "noPathToAlternative")),
						noPathFromAlternative = alternative(core.field(st, "noPathFromAlternative")) }
					-- what the base counts as a problem of a stop (manager_window.tl)
					x.problem = x.noPath == true or x.duplicateStop == true or x.incompatibleStop == true
						or x.noPathToAlternative ~= nil or x.noPathFromAlternative ~= nil
					if x.problem then out.count = out.count + 1 end
					stops[#stops + 1] = x
				end
				out.segments[#out.segments + 1] = core.array(stops)
			end
		end
		local okU, union = pcall(function() return api.engine.util.line.getLineTransportModesUnion(e) end)
		if okU then
			out.transportModesUnion = modeNames(union)
		else
			out.unionError = "getLineTransportModesUnion: " .. tostring(union)
		end
		for _, s in ipairs(info.stops) do
			local sc = s.stationEntity and comp(s.stationEntity, "STATION")
			local terminals = sc and core.field(sc, "terminals")
			-- the index checked first: an engine vector read past its end may assert
			if s.terminal and s.terminal >= 0 and s.terminal < core.size(terminals) then
				s.transportModes = modesOf(core.at(terminals, s.terminal + 1))
			end
		end
		return out
	end

	-- args: name (substring, any case), line (one line's id), problems (true: each line's problems too)
	function handlers.lines(c)
		local q = type(c.args.name) == "string" and c.args.name:lower() or nil
		local only = c.args.line
		if only ~= nil and (type(only) ~= "number" or only ~= math.floor(only)) then
			return fail(c.id, "line must be an entity id")
		end
		local types = cargoTypes()
		local out = {}
		for _, e in ipairs(ownLines()) do
			if only == nil or e == only then
				local info = lineInfo(e, types)
				if info and (not q or info.name:lower():find(q, 1, true)) then
					if c.args.problems == true then info.problems = lineProblems(e, info) end
					out[#out + 1] = info
				end
			end
		end
		if only ~= nil and #out == 0 then return fail(c.id, "no line " .. tostring(only) .. " of the company") end
		table.sort(out, function(x, y) return x.name < y.name end)
		answer(c.id, { ok = true, lines = core.array(out) })
	end

	L.handlers = handlers
	L.posOf = posOf -- (industryWorkers: the nearest town)
	return L
end

return M
