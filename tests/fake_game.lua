-- A stand-in for the parts of the game the remote probe touches, over a real folder, so the real
-- content/remote.script.lua and tools/tf3ctl.py can talk through real files.
--   require: local fake = dofile("tests/fake_game.lua"); local g = fake.new(dir, opts); g.step(dt)
--   command line: luajit tests/fake_game.lua <dir> <seconds> [menu]   (real time, for tests/test_tf3ctl.py;
--                 menu: starts in the main menu with startup.lua, as when launched with --script)
-- Like the game, saveUserdata never overwrites an existing file, and loading a missing file is an error.
local here = (debug.getinfo(1, "S").source:match("^@(.*)/tests/[^/]*$")) or "."

local M = {}
M.guiSave = {}

-- "hummer_remote_probe::/x.lua" -> content/x.lua, as the game resolves a mod's require
table.insert(package.loaders or package.searchers, 2, function(name)
	local rel = name:match("^hummer_remote_probe::/(.*)$")
	if rel then return assert(loadfile(here .. "/content/" .. rel)) end
end)

-- base GUI modules the vehicle commands require (vehicle_react_util.tl, vehicle_util.tl): fakes set per game in
-- M.guiModules; an absent one fails to load, as a missing file would
-- M.reactOnly: modules that load only in a react state (M.inReact, set by a test around a recipe's join), as the
-- game's vehicle_react_util.tl, whose react.RegisterRecipe fails in the guiUpdate state (seen 2026-11-16)
M.guiModules = {}
M.reactOnly = { ["/gui/line_vehicle_mgmt/vehicle_react_util.tl"] = true, ["/gui/line_vehicle_mgmt/line_util.tl"] = true }
table.insert(package.loaders or package.searchers, 2, function(name)
	local m = M.guiModules[name]
	if m and M.reactOnly[name] and not M.inReact then
		return function() error('[string "::/gui/main/react.lua"]:298: table index is nil') end
	end
	if m then return function() return m end end
end)

local function copy(v)
	if type(v) ~= "table" then return v end
	local c = {}
	for k, x in pairs(v) do c[k] = copy(x) end
	return c
end

local MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
local DAY_TICKS = 2000 -- game ms per calendar day in this fake

local function serialize(v, indent)
	local t = type(v)
	if t == "string" then return string.format("%q", v) end
	if t == "number" or t == "boolean" then return tostring(v) end
	if t ~= "table" then return "nil" end
	local parts = {}
	for k, x in pairs(v) do
		local key = type(k) == "number" and ("[" .. k .. "]") or ("[ " .. string.format("%q", k) .. " ]")
		parts[#parts + 1] = indent .. "\t" .. key .. " = " .. serialize(x, indent .. "\t") .. ","
	end
	return "{ \n" .. table.concat(parts, "\n") .. "\n" .. indent .. "}"
end

local function loadData(path)
	local f, err = loadfile(path)
	if not f then error(err) end
	local env = {}
	setfenv(f, env)
	f()
	return env.data()
end

local function dateOf(gameTime)
	local days = math.floor(gameTime / DAY_TICKS)
	local y, m = 1900, 1
	while days >= 365 do days, y = days - 365, y + 1 end
	while days >= MONTH_DAYS[m] do days, m = days - MONTH_DAYS[m], m + 1 end
	return { year = y, month = m, day = days + 1 }
end

-- opts: saves = { { saveName, path, timestamp, size, mods = {...}, modParams = {...} } }, maxSpeed (CPU cap),
-- modParams (of the running game), mods (of the running game)
function M.new(dir, opts)
	opts = opts or {}
	opts.saves = opts.saves or {}
	local g = { dir = dir, time = 1000, gameTime = 0, speedup = 1, logs = {}, commands = {}, loads = {}, saved = {},
		mods = opts.mods or { "hummer_remote_probe" }, modParams = opts.modParams or {}, running = true, callbacks = {},
		started = {}, menu = opts.menu == true }
	-- the main menu (opts.menu, startup.lua): no world, no mod params of a game, no GUI save data
	local function inGame(what) if g.menu then error(what .. " in the main menu") end end

	-- vehicles: opts.models = { [id] = { name, price, vehicle = true } }, opts.fleet = { [entity] = config },
	-- opts.balance, opts.depots = { [entity] = { carrier, name } }. g.fleet holds what the engine has now.
	local models = opts.models or {
		[101] = { name = "vehicle/bus/bus_1900.mdl", price = 30000, vehicle = true },
		[102] = { name = "vehicle/bus/bus_1920.mdl", price = 45000, vehicle = true },
		[103] = { name = "vehicle/truck/truck_1900.mdl", price = 20000, vehicle = true },
		[200] = { name = "building/bus_house.mdl", price = 1 },
	}
	g.models = models -- a test may change a cost, as a price mod rewrites metadata.cost
	g.balance = opts.balance or 1000000
	g.cam = { x = 0, y = 0, distance = 500, angle = 0.5, pitch = 0.6 }
	g.fleet = copy(opts.fleet or {})
	g.nextEntity = 5000
	-- depots: carrier is OTHER (5) unless given, as every depot of a save read in game (2026-11-16); modes: the
	-- transport modes the depot takes (what tells its kind)
	local depots = opts.depots or { [301] = { name = "Bus depot", modes = { "BUS", "TRUCK" } } }
	-- stations and lines: opts.stationGroups = { [group] = { name, owner (nil: nobody's), stations = { { id,
	-- terminals = n, passenger, carriers = { "ROAD" }, pos = { x, y }, owner } } } }; opts.lines = { [line] = { name,
	-- stops = { { stationGroup, station, terminal } } } }; opts.positions = { [entity] = { x, y } } (towns,
	-- industries); opts.cargoTypes = { [id] = { name, label } }. g.lines holds what the engine has now.
	-- industries (industryWorkers): opts.industries = { [entity] = { name, construction, capacity, workers (sims
	-- with it as destination), productivity, pos = { x, y } } }; opts.workersState = the base's workers script's
	-- state ({ industriesState = { [entity] = { lastVisitors = { { entity = {...}, time } } } } }), handed out as a
	-- native table (findPath / asTable) as the engine does; opts.workersScript = "none" (not running) or "nostate";
	-- opts.townCapacities = { [town] = { residential, commercial, industrial } }
	local industries = opts.industries or {}
	local WORKERS_ENTITY = 888
	local function native(t)
		return { findPath = function(_, path)
			local v = t
			for _, k in ipairs(path) do
				if type(v) ~= "table" then return nil end
				v = v[k]
			end
			if type(v) == "table" then return native(v) end
			return v
		end, asTable = function() return copy(t) end }
	end
	local groups = opts.stationGroups or {}
	local stationOf, groupOfStation = {}, {}
	for gid, grp in pairs(groups) do
		for _, st in ipairs(grp.stations or {}) do stationOf[st.id], groupOfStation[st.id] = st, gid end
	end
	local cargoTypes = opts.cargoTypes or { [0] = { name = "PASSENGERS", label = "Passengers" },
		[1] = { name = "COAL", label = "Coal" }, [2] = { name = "GRAIN", label = "Grain" } }
	local cargoCount = 0
	for _ in pairs(cargoTypes) do cargoCount = cargoCount + 1 end
	local function newStopConfig()
		return { load = {}, maxLoad = {}, forceUnload = true, destroyForConfigChange = false, destroyForRefresh = false }
	end
	g.lines = {}
	for e, l in pairs(opts.lines or {}) do
		local stops = {}
		for _, s in ipairs(l.stops or {}) do
			local cfg = newStopConfig()
			for id in pairs(cargoTypes) do cfg.load[id + 1] = s.loads and s.loads[id] == true or false; cfg.maxLoad[id + 1] = 1 end
			stops[#stops + 1] = { stationGroup = s.stationGroup, station = s.station or 0, terminal = s.terminal or 0,
				stopConfig = cfg, alternativeTerminals = {}, waypoints = s.waypoints or {}, maxAdditionalWaitingTime = 60 }
		end
		g.lines[e] = { name = l.name, stops = stops, customFilters = l.customFilters == true, reservationPriority = 1 }
	end
	local function groupCarriers(gid)
		local out, seen = {}, {}
		for _, st in ipairs((groups[gid] or {}).stations or {}) do
			for _, c in ipairs(st.carriers or { "ROAD" }) do
				if not seen[c] then seen[c] = true; out[#out + 1] = api.type.enum.Carrier[c] end
			end
		end
		table.sort(out)
		return out
	end
	-- what the engine asserts on a line (the base sets 0/0 where assignment fails "to prevent ASSERT during
	-- command execution", line_util.tl): a stop without a station and terminal that exist, and cargo vectors of
	-- another size than the cargo types. The game dies on it, so the fake does too.
	local function checkLine(line)
		for i, s in ipairs(line.stops or {}) do
			local grp = groups[s.stationGroup]
			local st = grp and grp.stations[(s.station or -1) + 1]
			if not st or (s.terminal or -1) < 0 or s.terminal >= (st.terminals or 1) then
				g.crashed = "ASSERT: line stop " .. i .. " has no valid station terminal"
				error(g.crashed)
			end
			local cfg = s.stopConfig or {}
			if #(cfg.load or {}) ~= cargoCount or #(cfg.maxLoad or {}) ~= cargoCount then
				g.crashed = "ASSERT: stop config of line stop " .. i .. " is not one entry per cargo type"
				error(g.crashed)
			end
		end
	end
	local function lineVehicleIds(line)
		local out = {}
		for e, c in pairs(g.fleet) do if c.line == line then out[#out + 1] = e end end
		table.sort(out)
		return out
	end
	g.groups, g.cargoTypes = groups, cargoTypes
	local function configPrice(config)
		local sum = 0
		for _, p in ipairs(config.vehicles) do sum = sum + models[p.part.modelId].price end
		return sum
	end
	-- what the engine does with a vehicle command; returns success. opts.buyFails: every buy is refused;
	-- opts.engineStampsPurchaseTime: the engine fills in purchaseTime 0 itself
	local function applyVehicle(cmd)
		-- TF3 asserts this in UpdateConfigFromModelIds (vehicle_util_engine.cpp:353) and dies, uncatchable: a cmd buy
		-- with autoLoadConfig left empty crashed the game, 2026-11-16 13:21 JST
		if cmd.config then
			for _, p in ipairs(cmd.config.vehicles) do
				if #(p.autoLoadConfig or {}) ~= #p.part.compartment2loadConfig then
					g.crashed = "Assertion 'autoLoadConfig.size() == compartment2loadConfig.size()' failed"
					error(g.crashed)
				end
			end
		end
		if cmd.kind == "buy" then
			local price = configPrice(cmd.config)
			if opts.buyFails or not depots[cmd.depot] or g.balance < price then return false end
			g.balance = g.balance - price
			g.nextEntity = g.nextEntity + 1
			local c = copy(cmd.config)
			for _, p in ipairs(c.vehicles) do
				if opts.engineStampsPurchaseTime and p.purchaseTime <= 0 then p.purchaseTime = g.gameTime end
			end
			c.line, c.depot = -1, cmd.depot
			g.fleet[g.nextEntity] = c
			cmd.resultVehicleEntity = g.nextEntity
			return true
		elseif cmd.kind == "replace" then
			local old = g.fleet[cmd.vehicle]
			if not old then return false end
			local c = copy(cmd.config)
			c.line, c.depot = old.line, old.depot
			g.balance = g.balance - configPrice(c)
			g.fleet[cmd.vehicle] = c
			return true
		elseif cmd.kind == "sell" then
			for _, e in ipairs(cmd.vehicles) do
				if not g.fleet[e] then return false end
				g.balance = g.balance + math.floor(configPrice(g.fleet[e]) * 0.9)
				g.fleet[e] = nil
			end
			return true
		elseif cmd.kind == "journal" then
			if opts.journalFails then return false end
			g.journal = g.journal or {}
			g.journal[#g.journal + 1] = cmd.entry
			g.balance = g.balance + cmd.entry.amount
			return true
		elseif cmd.kind == "setLine" then
			if not g.fleet[cmd.vehicle] then return false end
			g.fleet[cmd.vehicle].line = cmd.line
			return true
		elseif cmd.kind == "lineCreate" or cmd.kind == "lineUpdate" then
			checkLine(cmd.line)
			if opts.lineFails then return false end
			local l = copy(cmd.line)
			if cmd.kind == "lineCreate" then
				g.nextEntity = g.nextEntity + 1
				g.lines[g.nextEntity] = { name = cmd.name, color = cmd.color, stops = l.stops, customFilters = l.customFilters == true,
					reservationPriority = l.reservationPriority }
				cmd.resultEntity = g.nextEntity
			else
				local old = g.lines[cmd.lineEntity]
				if not old then return false end
				old.stops, old.customFilters, old.reservationPriority = l.stops, l.customFilters == true, l.reservationPriority
			end
			return true
		elseif cmd.kind == "lineDestroy" then
			-- whether the engine takes a line with vehicles is unknown; the base sells them first, and so the fake
			-- refuses
			if not g.lines[cmd.lineEntity] or #lineVehicleIds(cmd.lineEntity) > 0 then return false end
			g.lines[cmd.lineEntity] = nil
			return true
		elseif cmd.kind == "setName" then
			if opts.renameFails then return false end
			if g.lines[cmd.entity] then g.lines[cmd.entity].name = cmd.name
			elseif groups[cmd.entity] then groups[cmd.entity].name = cmd.name
			else return false end
			return true
		end
		return true
	end
	g.applyVehicle = applyVehicle
	-- the callback's third argument, as the base's create callback reads it (resultEntities[1][1])
	local function resultsOf(cmd, success)
		if success and cmd.resultEntity then return { { cmd.resultEntity, 1 } } end
		return {}
	end

	-- folders as the game has them; opts.droppingDirs lose every file (to exercise the fallback to the next folder)
	local dropping = {}
	for _, d in ipairs(opts.droppingDirs or {}) do dropping[d] = true end
	local function path(d, name)
		os.execute("mkdir -p '" .. dir .. "/" .. d .. "'")
		return dir .. "/" .. d .. "/" .. name .. ".lua"
	end

	_G.debugPrint = function(s) g.logs[#g.logs + 1] = s end
	_G.app = {
		saveUserdata = function(d, name, tbl)
			if dropping[d] then return end
			local p = path(d, name)
			local f = io.open(p, "r")
			if f then f:close(); return end -- the game never overwrites
			f = assert(io.open(p, "w"))
			f:write("function data()\nreturn " .. serialize(tbl, "\t") .. "\nend\n")
			f:close()
		end,
		loadUserdata = function(d, name) return loadData(path(d, name)) end,
		SaveGameNamespace = { getSavegame = function() return "save" end },
		findAllSavegames = function() return opts.saves or {} end,
		getSavegameInfo = function(id)
			local s
			for _, x in ipairs(opts.saves or {}) do if x.path == id.path then s = x end end
			local frames = 0
			return {
				isCompleted = function() frames = frames + 1; return frames > 2 end,
				get = function()
					local mods = {}
					for _, name in ipairs(s.mods or {}) do mods[#mods + 1] = { name = name } end
					local params = s.modParams or {}
					if opts.opaqueParams then params = newproxy(true) end -- an engine map pairs() cannot walk
					return { info = { mods = mods, modParams = params, campaign = "", mission = "" } }
				end,
				abort = function() end,
			}
		end,
		setWaitForStartReadyGame = function() g.waitedForStart = true end,
		quit = function() g.quitCalled = (g.quitCalled or 0) + 1 end,
		-- the mods' descriptions (mod.json params) as the base new-game page reads their defaults
		getUserProfile = function() return { getModRep = function() return { getModDesc = function(_, id)
			local d = (opts.modDescs or { [""] = { { key = "guideSystemConfig.tutorial", defaultIndex = 1 } } })[id.name]
			return d and { params = d } or nil
		end } end } end,
		-- climates and terrain generators as resource reps (ids -> descs), like app.res in the game
		res = {
			climateRep = {
				getAll = function() return { [1] = true, [2] = true } end,
				getName = function(k) return ({ "temperate.clima", "dry.clima" })[k] end,
				get = function(k) return { economy = ({ "temperate.eco", "dry.eco" })[k] } end,
			},
			terrainGeneratorRep = {
				getAll = function() return { [1] = true, [2] = true, [3] = true, [4] = true } end,
				getName = function(k) return ({ "temperate_hills.gen", "temperate.gen", "temperate_import.gen", "dry.gen" })[k] end,
				get = function(k) return ({
					{ climate = "temperate.clima", visible = true, order = 2 },
					{ climate = "temperate.clima", visible = true, order = 1 },
					{ climate = "temperate.clima", visible = true, order = 0, isImportGenerator = true },
					{ climate = "dry.clima", visible = true, order = 1 },
				})[k] end,
			},
		},
		startGame = function(p)
			if opts.startFails then error("startGame refused") end
			g.started[#g.started + 1] = p
			if not opts.startNoop then g.pendingStart = true end -- startNoop: returns, but nothing happens
		end,
		loadGame = function(id, isMapEditor, info)
			g.loads[#g.loads + 1] = { id = id, info = info }
			if not opts.loadNoop then g.pendingLoad = true end -- loadNoop: returns, but nothing happens
		end,
		saveGame = function(name, cb, isMapEditor, skipSetName)
			g.saved[#g.saved + 1] = { name = name, skipSetName = skipSetName }
			if not opts.saveFails then
				local known = false
				for _, x in ipairs(opts.saves) do known = known or x.saveName == name end
				if not known then opts.saves[#opts.saves + 1] = { saveName = name, path = "/s/" .. name .. ".sav", timestamp = 9, size = 1 } end
			end
			g.saveCallback = cb
		end,
	}
	_G.api = {
		util = { getApplicationTime = function() return g.time end },
		-- opts.modhub: an info-only backend and mod.io's publishing one, as the base menu sees them;
		-- g.modhubBusy / g.modhubNoRestricted change what the publishing one says, from frame to frame
		modhub = opts.modhub and {
			getBackendIDs = function() return { 1, 2 } end,
			getCapabilities = function(b) return { isInfoOnly = b == 1, allowRestrictedMode = not g.modhubNoRestricted } end,
			getModManagementState = function(b)
				g.modhubAsked = (g.modhubAsked or 0) + 1
				return { busy = b == 2 and g.modhubBusy == true }
			end,
		} or nil,
		engine = {
			util = {
				getWorld = function() inGame("getWorld"); return 1 end,
				getCalendarDate = function(t) return dateOf(t) end,
				getPlayer = function() return 99 end,
				getEntityName = function(e)
					return (opts.names or {})[e] or (industries[e] and industries[e].name) or (depots[e] and depots[e].name) or (g.lines[e] and g.lines[e].name)
						or (groups[e] and groups[e].name)
				end,
				station = { isStationOfType = function(st, cargo)
					return stationOf[st] ~= nil and (stationOf[st].passenger == true) == (cargo == false)
				end },
				-- opts.modesToCarriers: the engine maps transport modes to carriers (statistics_react_util.tl uses it)
				transport = opts.modesToCarriers and { transportModesToCarriers = function(modes)
					local C, M2 = api.type.enum.Carrier, api.type.enum.TransportMode
					local by = { [M2.BUS] = C.ROAD, [M2.TRUCK] = C.ROAD, [M2.CAR] = C.ROAD, [M2.TRAM] = C.TRAM,
						[M2.ELECTRIC_TRAM] = C.TRAM, [M2.TRAIN] = C.RAIL, [M2.ELECTRIC_TRAIN] = C.RAIL, [M2.SHIP] = C.WATER,
						[M2.SMALL_SHIP] = C.WATER, [M2.AIRCRAFT] = C.AIR, [M2.SMALL_AIRCRAFT] = C.AIR, [M2.HELICOPTER] = C.AIR }
					local out, seen = {}, {}
					for _, m in ipairs(modes) do
						local c = by[m]
						if c and not seen[c] then seen[c] = true; out[#out + 1] = c end
					end
					table.sort(out)
					return out
				end } or nil,
				-- opts.infiniteMoney: nil, as the engine gives for infinite money
				finance = { getPlayersBalance = function() if opts.infiniteMoney then return nil end return g.balance end },
				vehicle = {
					getDepreciatedValue = function(e) return g.fleet[e] and math.floor(configPrice(g.fleet[e]) * 0.9) or 0 end,
					getPartPrice = function(p) return models[p.part.modelId].price end,
					findBestLineAndDepotForVehicle = function(e)
						return { g.fleet[e] and g.fleet[e].line or -1, opts.bestDepot or 301 }
					end,
				},
			},
			-- towns, lines, vehicles, stations, industries for the window command
			getEntitiesWithComponent = function(kind, filter)
				if kind == "TRANSPORT_VEHICLE" and not (opts.entities or {}).TRANSPORT_VEHICLE then
					local ids = {}
					for e in pairs(g.fleet) do ids[#ids + 1] = e end
					table.sort(ids)
					return ids
				end
				if kind == "VEHICLE_DEPOT" then
					-- depots[e].owner: another company's (default: the player's, 99)
					local ids, want = {}, filter and filter.requireOwnedByPlayer
					for e, d in pairs(depots) do
						if want == nil or (d.owner or 99) == want then ids[#ids + 1] = e end
					end
					table.sort(ids)
					return ids
				end
				if kind == "INDUSTRY" and opts.industries then
					local ids = {}
					for e in pairs(industries) do ids[#ids + 1] = e end
					table.sort(ids)
					return ids
				end
				if kind == "STATION_GROUP" and opts.stationGroups then
					local ids = {}
					for e in pairs(groups) do ids[#ids + 1] = e end
					table.sort(ids)
					return ids
				end
				return (opts.entities or {})[kind] or {}
			end,
			system = {
				streetConnectorSystem = { getConstructionEntityForSubconstruction = function(e)
					return industries[e] and industries[e].construction or -1
				end },
				gameScriptSystem = { getEntityForGameScript = function(name)
					if name ~= "::/industries/industry_workers.gs" or opts.workersScript == "none" then return -1 end
					return WORKERS_ENTITY
				end },
				simPersonSystem = { getSimPersonsForDestination = function(e)
					if not (industries[e] and industries[e].capacity) then error("ASSERT: no person capacity for " .. tostring(e)) end
					local ids = {}
					for i = 1, industries[e].workers or 0 do ids[i] = e * 1000 + i end
					return ids
				end },
				townBuildingSystem = { getTown2personCapacitiesMap = function() return copy(opts.townCapacities or {}) end },
				lineSystem = {
					getLinesForPlayer = function()
						local ids = copy((opts.entities or {}).LINE or {})
						for e in pairs(g.lines) do ids[#ids + 1] = e end
						table.sort(ids)
						return ids
					end,
					-- opts.noAssignment: the engine finds no platform for any stop; otherwise a stop without one gets
					-- the first station's last terminal (not 0/0, so a test tells it from the base's fallback)
					getBestLineAssignment = function(e, line, allow)
						g.assignCalls = (g.assignCalls or 0) + 1
						local out = {}
						for i, s in ipairs(line.stops) do
							local grp = groups[s.stationGroup]
							if opts.noAssignment or not grp or #grp.stations == 0 then
								out[i] = { station = -1, terminal = -1 }
							elseif opts.reassign then
								-- allowTerminalChanges: the engine may move a stop that had a platform
								out[i] = { station = 0, terminal = 0 }
							elseif s.station >= 0 and s.terminal >= 0 then
								out[i] = { station = s.station, terminal = s.terminal }
							else
								out[i] = { station = 0, terminal = (grp.stations[1].terminals or 1) - 1 }
							end
						end
						return out
					end,
					getLinesForStationGroup = function(gid)
						local out = {}
						for e, l in pairs(g.lines) do
							local hit = false
							for _, s in ipairs(l.stops) do hit = hit or s.stationGroup == gid end
							if hit then out[#out + 1] = e end
						end
						return out
					end,
				},
				stationGroupSystem = {
					getCarriers = function(gid) return { groupCarriers(gid), {} } end,
					getStationGroup = function(st) return groupOfStation[st] or -1 end,
				},
				transportVehicleSystem = { getDepotVehicles = function(d)
					local out = {}
					for e, c in pairs(g.fleet) do if c.depot == d and c.line == -1 then out[#out + 1] = e end end
					return out
				end, getLineVehicles = lineVehicleIds } },
			entityExists = function(e)
				return g.lines[e] ~= nil or g.fleet[e] ~= nil or groups[e] ~= nil or industries[e] ~= nil
					or (e == WORKERS_ENTITY and opts.workersScript ~= "none")
			end,
			getComponent = function(e, kind)
				inGame("getComponent")
				if kind == "GAME_TIME" then return { gameTime = g.gameTime } end
				if kind == "GAME_SCRIPT" and e == WORKERS_ENTITY then
					if opts.workersScript == "nostate" then return {} end
					return { state_native = native(copy(opts.workersState or {})) }
				end
				if kind == "PERSON_CAPACITY" then
					local i = industries[e]
					return i and i.capacity and { type = 3, capacity = i.capacity } or nil
				end
				if kind == "STOCK_LIST" then
					local i = industries[e]
					return i and i.productivity and { modifiers = { productivity = i.productivity } } or nil
				end
				if kind == "TRANSPORT_VEHICLE" then
					local c = g.fleet[e]
					return c and { transportVehicleConfig = copy(c), line = c.line, depot = c.depot,
						config = { capacities = copy(c.capacities or {}) } } or nil
				end
				if kind == "STATION_GROUP" then
					local grp = groups[e]
					if not grp then return nil end
					local ids = {}
					for _, st in ipairs(grp.stations or {}) do ids[#ids + 1] = st.id end
					return { stations = ids }
				end
				if kind == "STATION" then
					local st = stationOf[e]
					if not st then return nil end
					local t = {}
					-- st.kind "passenger" / "cargo": the terminals' load flags (none given: the probe cannot tell)
					for i = 1, st.terminals or 1 do
						local p, c = st.kind == "passenger", st.kind == "cargo"
						t[i] = { tag = i }
						if st.kind then
							t[i].passengersLoad, t[i].passengersUnload, t[i].cargoLoad, t[i].cargoUnload = p, p, c, c
						end
					end
					return { terminals = t }
				end
				if kind == "PLAYER_OWNED" then
					local o = (groups[e] and groups[e].owner) or (stationOf[e] and stationOf[e].owner)
					return o and { player = o } or nil
				end
				if kind == "BOUNDING_VOLUME" then
					local p = (stationOf[e] and stationOf[e].pos) or (industries[e] and industries[e].pos) or (opts.positions or {})[e]
					if not p then return nil end
					return { bbox = { min = { x = p[1] - 5, y = p[2] - 5, z = 0 }, max = { x = p[1] + 5, y = p[2] + 5, z = 10 } } }
				end
				if kind == "LINE" then
					local l = g.lines[e]
					return l and { stops = copy(l.stops), customFilters = l.customFilters, reservationPriority = l.reservationPriority } or nil
				end
				if kind == "VEHICLE_DEPOT" then
					local d = depots[e]
					if not d then return nil end
					-- transportModes: keyed by the TransportMode enum's values, as the engine's map
					local modes = {}
					for _, m in ipairs(d.modes or {}) do modes[api.type.enum.TransportMode[m]] = true end
					return { carrier = d.carrier or 5, transportModes = modes, maintenancePool = d.maintenancePool or 0 }
				end
				if kind == "GAME_SPEED" then return { speedup = g.speedup, millisPerDay = g.speedup > 0 and DAY_TICKS / g.speedup or 0 } end
			end,
			config = { getModParams = function() inGame("getModParams"); return g.modParams end },
		},
		type = {
			enum = { Carrier = { ROAD = 0, RAIL = 1, TRAM = 2, AIR = 3, WATER = 4, OTHER = 5 },
				TransportMode = { PERSON = 0, CARGO = 1, CAR = 2, BUS = 3, TRUCK = 4, TRAM = 5, ELECTRIC_TRAM = 6, TRAIN = 7,
					ELECTRIC_TRAIN = 8, AIRCRAFT = 9, SHIP = 10, SMALL_AIRCRAFT = 11, SMALL_SHIP = 12, HELICOPTER = 13 },
				LandUseType = { RESIDENTIAL = 0, COMMERCIAL = 1, INDUSTRIAL = 2 } },
			JournalEntry = { new = function() return { amount = 0, time = 0, category = { type = -1 } } end,
				Type = { OTHER = 7 } },
			TransportVehicleConfig = { new = function(src)
				return src and copy(src) or { vehicles = {}, vehicleGroups = {}, muFileNames = {} }
			end },
			TransportVehiclePart = { new = function()
				return { part = { modelId = -1, reversed = false, compartment2loadConfig = {} }, purchaseTime = 0,
					maintenanceState = 1, autoLoadConfig = {} }
			end },
			LoadConfig = { new = function() return { loadConfigIndex = -1 } end },
			Line = setmetatable({
				Stop = { new = function()
					return { stationGroup = -1, station = -1, terminal = -1, stopConfig = newStopConfig(), alternativeTerminals = {},
						waypoints = {}, maxAdditionalWaitingTime = 0 }
				end },
				StopConfig = { new = function(src) return src and copy(src) or newStopConfig() end },
			}, { __index = { new = function(src)
				return src and copy(src) or { stops = {}, customFilters = false, reservationPriority = 0 }
			end } }),
			Vec3f = { new = function(x, y, z) return { x = x, y = y, z = z } end },
			Vec5f = { new = function(x, y, z, w, q) return { x = x, y = y, z = z, w = w, q = q } end },
			ComponentType = { VEHICLE_DEPOT = "VEHICLE_DEPOT", GAME_TIME = "GAME_TIME", GAME_SPEED = "GAME_SPEED", TOWN = "TOWN", TRANSPORT_VEHICLE = "TRANSPORT_VEHICLE",
				STATION_GROUP = "STATION_GROUP", INDUSTRY = "INDUSTRY", NAME = "NAME", STATION = "STATION", LINE = "LINE",
				PLAYER_OWNED = "PLAYER_OWNED", BOUNDING_VOLUME = "BOUNDING_VOLUME", GAME_SCRIPT = "GAME_SCRIPT",
				PERSON_CAPACITY = "PERSON_CAPACITY", STOCK_LIST = "STOCK_LIST" },
			SavegameId = { new = function() return {} end },
			StartGameParams = { new = function() return {} end },
			BaseConfig = { Locations = { new = function() return { town = {}, industry = {} } end } },
			Vec2i = { new = function(x, y) return { x = x, y = y } end },
			Date = { new = function(y, m, d) return { year = y, month = m, day = d } end },
			ModId = { new = function() return {} end },
			SaveGameDetails = { new = function(info)
				local c = {}
				for k, v in pairs(info) do c[k] = v end
				return c
			end },
		},
		cmd = {
			makeGameSetSpeedCmd = function(n) return { kind = "speed", speed = n } end,
			-- the engine copies the config when the command is made: a later change to the Lua value is not sent
			makeVehicleBuyCmd = function(pl, depot, config) return { kind = "buy", player = pl, depot = depot, config = copy(config) } end,
			makeVehicleReplaceCmd = function(e, config) return { kind = "replace", vehicle = e, config = copy(config) } end,
			makeVehicleSellCmd = function(list) return { kind = "sell", vehicles = copy(list) } end,
			makeJournalBookAssetCmd = function(pl, entry) return { kind = "journal", player = pl, entry = copy(entry) } end,
			makeVehicleSetLineCmd = function(e, line, stop) return { kind = "setLine", vehicle = e, line = line, stop = stop } end,
			makeLineCreateCmd = function(name, color, pl, line)
				return { kind = "lineCreate", name = name, color = copy(color), player = pl, line = copy(line) }
			end,
			makeLineUpdateCmd = function(e, line) return { kind = "lineUpdate", lineEntity = e, line = copy(line) } end,
			makeLineDestroyCmd = function(e) return { kind = "lineDestroy", lineEntity = e } end,
			makeEntitySetNameCmd = function(e, name) return { kind = "setName", entity = e, name = name } end,
			makeScriptingSendEventCmd = function(src, id, name, param)
				return { kind = "scriptEvent", src = src, id = id, name = name, param = copy(param) }
			end,
			sendCommand = function(cmd, cb)
				g.commands[#g.commands + 1] = cmd
				if opts.speedFails then
					if cb then cb(nil, false) end
					return
				end
				local function apply()
					if cmd.kind == "speed" then g.speedup = cmd.speed; return true end
					if cmd.kind == "scriptEvent" then return not opts.scriptEventFails end
					return applyVehicle(cmd)
				end
				-- opts.callbackFrames: the command runs, and its result arrives, that many frames later, as commands
				-- are queued in the game. opts.lostCallbacks: the command runs but its result never comes.
				if opts.callbackFrames then
					g.callbacks[#g.callbacks + 1] = { frames = opts.callbackFrames, fn = function()
						local success = apply()
						if cb and not opts.lostCallbacks then cb(cmd, success, resultsOf(cmd, success)) end
					end }
				else
					local success = apply()
					if cb and not opts.lostCallbacks then cb(cmd, success, resultsOf(cmd, success)) end
				end
			end,
		},
		res = { constructionRep = {
			-- index of a construction, -1 when there is none (as ResTypeRep.find)
			find = function(name) return (opts.constructions or { ["station/street/bus_stop.con"] = 3 })[name] or -1 end,
		}, cargoTypeRep = {
			getAll = function()
				local out = {}
				for id, c in pairs(cargoTypes) do out[id] = c.name end
				return out
			end,
			get = function(id) return cargoTypes[id] and { name = cargoTypes[id].label } or nil end,
			getPassengerCargoTypeId = function() return 0 end,
		}, modelRep = {
			getAll = function()
				local out = {}
				for id, m in pairs(models) do out[id] = m.name end
				return out
			end,
			getName = function(id) return models[id] and models[id].name end,
			get = function(id)
				local m = models[id]
				if not m then return nil end
				return { metadata = { cost = { price = m.price, priceScale = m.priceScale },
					transportVehicle = m.vehicle and { compartments = { {}, {} } } or nil } }
			end,
		} },
		gui = {
			spawnEphemeralHudImage = function() end,
			closeAllWindows = function() g.closedAll = (g.closedAll or 0) + 1 end,
			camera = {
			focusEntity = function(e) g.focused = e; g.cam.x, g.cam.y = 100 + e, 200 + e end,
			-- the camera as getCameraData's Vec5f: centre x, y, distance, angle, pitch
			getCameraData = function() local c = g.cam; return { x = c.x, y = c.y, z = c.distance, w = c.angle, q = c.pitch } end,
			setCameraData = function(v) g.cam = { x = v.x, y = v.y, distance = v.z, angle = v.w, pitch = v.q } end,
			focusPosition = function(p, d) g.cam.x, g.cam.y, g.cam.distance = p.x, p.y, d; g.focusedAt = p end,
			getHeightAboveTerrain = function() return g.cam.distance * 0.5 end,
			takeScreenshot = function(scale)
				os.execute("mkdir -p '" .. dir .. "/screenshots'")
				local f = assert(io.open(dir .. "/screenshots/shot_" .. tostring(#g.logs) .. "_" .. tostring(scale) .. ".png", "w"))
				f:write("PNG")
				f:close()
				g.shots = (g.shots or 0) + 1
			end,
		}, game = {
			getEstimatedMaximumGameSpeed = function() return opts.maxSpeed or 0 end,
			-- per-mod GUI save data held by the game (C++): every Lua state sees the same
			-- opts.foreignKeyFails: a key that is not a mod id is refused (whether the game takes one is unverified)
			setGuiSaveData = function(mod, t)
				inGame("setGuiSaveData")
				if opts.foreignKeyFails and mod ~= "hummer_remote_probe" then error("no such mod: " .. mod) end
				M.guiSave[mod] = t
			end,
			getGuiSaveData = function(mod) inGame("getGuiSaveData"); return M.guiSave[mod] end,
			getDefaultSavegameId = function() return "default" end,
		} },
	}

	-- the base's vehicle_react_util.HandleVehicleChanges, as in 40444 (stamp, autoload, then the engine command);
	-- opts.noGuiModule: it does not load. opts.vehicleUtil: vehicle_util.tl loads too (else the probe builds parts)
	M.guiModules = {}
	if not opts.noGuiModule then
		M.guiModules["/gui/line_vehicle_mgmt/vehicle_react_util.tl"] = { HandleVehicleChanges = function(changes, protected,
				getLineAndDepot, getFirstStopToSendTo, onBuy, onFail)
			if not M.inReact then error("HandleVehicleChanges outside a react state") end
			g.guiChanges = (g.guiChanges or 0) + 1
			for _, change in ipairs(changes) do
				for _, p in ipairs(change.config.vehicles) do
					if p.purchaseTime <= 0 then p.purchaseTime = g.gameTime end
					-- listutil.listAssign(#compartment2loadConfig, true), as the base
					p.autoLoadConfig = {}
					for i = 1, #p.part.compartment2loadConfig do p.autoLoadConfig[i] = true end
				end
				if change.vehicleEntity < 0 then
					local ld = getLineAndDepot(change.vehicleEntity)
					if ld[2] >= 0 then
						api.cmd.sendCommand(api.cmd.makeVehicleBuyCmd(api.engine.util.getPlayer(), ld[2], change.config),
							function(cmd, success)
								if not success then
									if onFail then onFail("Could not clone vehicles (not enough money).") end
									return
								end
								if onBuy then
									if ld[1] >= 0 then
										api.cmd.sendCommand(api.cmd.makeVehicleSetLineCmd(cmd.resultVehicleEntity, ld[1],
											getFirstStopToSendTo and getFirstStopToSendTo(cmd.resultVehicleEntity, ld[1]) or 0), function() end)
									end
									onBuy({ { cmd.resultVehicleEntity, 1 } })
								end
							end)
					elseif onFail then
						onFail("Could not find suitable depot.")
					end
				elseif #change.config.vehicles == 0 then
					if protected == nil or not protected[change.vehicleEntity] then
						api.cmd.sendCommand(api.cmd.makeVehicleSellCmd({ change.vehicleEntity }))
					end
				else
					api.cmd.sendCommand(api.cmd.makeVehicleReplaceCmd(change.vehicleEntity, change.config))
				end
			end
		end }
	end
	if opts.vehicleUtil then
		M.guiModules["/gui/line_vehicle_mgmt/vehicle_util.tl"] = { makePart = function(modelId, forward, color)
			g.madeParts = (g.madeParts or 0) + 1
			local part = api.type.TransportVehiclePart.new()
			part.part.modelId = modelId
			part.part.reversed = not forward
			part.part.compartment2loadConfig = { { loadConfigIndex = 0 }, { loadConfigIndex = 0 } }
			return part
		end }
	end

	-- the base's line_util.tl, as in 40444 in what the line commands use (makeNewStop, autoLoadConfig with its
	-- platform assignment, autoAssignTerminals with its 0/0 fallback, getReactLineFromGameState, makeLineName,
	-- makeLineColor); loads only in a react state, as it requires react modules. opts.noLineUtil: it does not load.
	-- autoLoadConfig here only turns passengers on at passenger stations (the base also works out cargo).
	if not opts.noLineUtil then
		local function idVector(v)
			local out = {}
			for k in pairs(api.res.cargoTypeRep.getAll(true)) do out[k + 1] = v end
			return out
		end
		local lu = {}
		lu.makeNewStop = function(details)
			local cfg = api.type.Line.StopConfig.new()
			cfg.load, cfg.maxLoad, cfg.forceUnload = idVector(false), idVector(1), false
			return { stop = { stationGroup = details.stationGroup, station1 = details.stationIndex1, terminal1 = details.terminalIndex1,
				alternativeTerminals = {}, passThroughStopData = { stopConfig = cfg, maxAdditionalWaitingTime = 30 } } }
		end
		lu.autoAssignTerminals = function(entity, path)
			g.lineUtilCalls = (g.lineUtilCalls or 0) + 1
			local comp, auto = api.type.Line.new(), false
			for _, v in ipairs(path) do
				if v.stop then
					local s = api.type.Line.Stop.new()
					s.stationGroup = v.stop.stationGroup
					s.station = v.stop.station1 and v.stop.station1 - 1 or -1
					s.terminal = v.stop.terminal1 and v.stop.terminal1 - 1 or -1
					if s.station < 0 or s.terminal < 0 then auto = true end
					s.stopConfig = v.stop.passThroughStopData.stopConfig
					s.maxAdditionalWaitingTime = v.stop.passThroughStopData.maxAdditionalWaitingTime
					comp.stops[#comp.stops + 1] = s
				end
			end
			if auto then
				local best = api.engine.system.lineSystem.getBestLineAssignment(entity == nil and -1 or entity, comp, true)
				for k, b in ipairs(best) do
					local s = comp.stops[k]
					if b.station >= 0 and b.terminal >= 0 then
						s.station, s.terminal = b.station, b.terminal
					elseif #api.engine.getComponent(s.stationGroup, "STATION_GROUP").stations > 0 then
						s.station, s.terminal = 0, 0 -- "to prevent ASSERT during command execution"
					end
				end
			end
			return comp.stops
		end
		lu.autoLoadConfig = function(line)
			if line.customFilters then return end
			local need = false
			for _, v in ipairs(line.path) do need = need or (v.stop and v.stop.station1 == nil) end
			if need then
				local auto = lu.autoAssignTerminals(line.entityAndRevision and line.entityAndRevision.entity or nil, line.path)
				local i = 1
				for _, v in ipairs(line.path) do
					if v.stop then
						v.stop.station1, v.stop.terminal1 = auto[i].station + 1, auto[i].terminal + 1
						i = i + 1
					end
				end
			end
			for _, v in ipairs(line.path) do
				if v.stop then
					local load = idVector(false)
					for _, st in ipairs(api.engine.getComponent(v.stop.stationGroup, "STATION_GROUP").stations) do
						if api.engine.util.station.isStationOfType(st, false) then load[1] = true end
					end
					v.stop.passThroughStopData.stopConfig.load = load
				end
			end
		end
		lu.getReactLineFromGameState = function(e)
			local l = api.engine.getComponent(e, "LINE")
			if not l then return nil end
			local path = {}
			for _, s in ipairs(l.stops) do
				path[#path + 1] = { stop = { stationGroup = s.stationGroup, station1 = s.station + 1, terminal1 = s.terminal + 1,
					alternativeTerminals = s.alternativeTerminals, passThroughStopData = { stopConfig = s.stopConfig,
					maxAdditionalWaitingTime = s.maxAdditionalWaitingTime } } }
				for _, w in ipairs(s.waypoints or {}) do path[#path + 1] = { waypoint = w } end
			end
			return { entityAndRevision = { entity = e }, path = path, customFilters = l.customFilters,
				reservationPriority = l.reservationPriority }
		end
		lu.makeLineName = function(pl)
			local names = {}
			for _, e in ipairs(api.engine.system.lineSystem.getLinesForPlayer(pl)) do names[api.engine.util.getEntityName(e) or ""] = true end
			for i = 1, 999 do if not names["Line " .. i] then return "Line " .. i end end
			return "New Line"
		end
		lu.makeLineColor = function() return api.type.Vec3f.new(0.2, 0.4, 0.8) end
		M.guiModules["/gui/line_vehicle_mgmt/line_util.tl"] = lu
	end

	-- a fresh copy of the script, as after a game load
	function g.boot()
		package.loaded["/gui/line_vehicle_mgmt/vehicle_react_util.tl"] = nil
		package.loaded["/gui/line_vehicle_mgmt/line_util.tl"] = nil
		package.loaded["hummer_remote_probe::/remote_lines.lua"] = nil
		package.loaded["hummer_remote_probe::/remote_connect.lua"] = nil
		package.loaded["hummer_remote_probe::/line_configs.lua"] = nil
		package.loaded["/gui/line_vehicle_mgmt/vehicle_util.tl"] = nil
		package.loaded["hummer_remote_probe::/remote_vehicles.lua"] = nil
		package.loaded["hummer_remote_probe::/vehicle_configs.lua"] = nil
		package.loaded["hummer_remote_probe::/remote_core.lua"] = nil
		package.loaded["hummer_remote_probe::/remote.script.lua"] = nil
		_G.data = nil
		if g.menu then
			-- launched with --script: the game calls data() and then update() every frame (a new game process:
			-- nothing kept from an earlier one)
			_G.__hummer_remote_probe_menu = nil
			dofile(here .. "/content/startup.lua")
			g.menuScript = _G.data()
			g.script = nil
			return
		end
		dofile(here .. "/content/remote.script.lua")
		g.script = _G.data()
	end

	function g.step(dt)
		dt = dt or 1 / 30
		g.time = g.time + dt
		local eff = (g.frozen or g.saveCallback) and 0 or g.speedup
		if opts.maxSpeed and opts.maxSpeed > 0 then eff = math.min(eff, opts.maxSpeed) end
		g.gameTime = g.gameTime + dt * 1000 * eff
		local due = {}
		for i = #g.callbacks, 1, -1 do
			local c = g.callbacks[i]
			c.frames = c.frames - 1
			if c.frames <= 0 then table.remove(g.callbacks, i); due[#due + 1] = c.fn end
		end
		for _, fn in ipairs(due) do fn() end
		if g.saveCallback then
			-- opts.saveSeconds: a save that holds game time, as a big one may
			g.saveLeft = (g.saveLeft or opts.saveSeconds or 0) - dt
			if g.saveLeft <= 0 then
				local cb = g.saveCallback
				g.saveCallback, g.saveLeft = nil, nil
				cb()
			end
		end
		if g.pendingStart then
			g.pendingStart = nil
			local p = g.started[#g.started]
			local self = false
			for _, m in ipairs(p.mods) do self = self or m == "hummer_remote_probe" end
			g.mods, g.modParams = p.mods, p.modParams
			g.gameTime = ((p.startDate.year - 1900) * 365) * DAY_TICKS
			g.time = g.time + 5
			g.menu = false
			if self then g.boot() else g.script = nil end
		end
		if g.pendingLoad then
			g.pendingLoad = nil
			local info = g.loads[#g.loads].info
			local names, self = {}, false
			for _, m in ipairs(info.mods) do names[#names + 1] = m.name; self = self or m.name == "hummer_remote_probe" end
			g.mods, g.modParams = names, info.modParams
			g.time = g.time + 5 -- a load takes a while; the stamp of the new hello differs
			g.menu = false
			if self then g.boot() else g.script = nil end
		end
		-- the --script copy: in the menu, and (opts.menuKeepsRunning) maybe in the game too
		if g.menuScript and (g.menu or opts.menuKeepsRunning) then g.menuScript.update() end
		if g.script then g.script.guiUpdate() end
	end

	function g.date() return dateOf(g.gameTime) end

	g.boot()
	return g
end

-- the speed control's recipe with a bare react, for the command-line mode (tests/test_tf3ctl.py): rendered once
-- per frame, its step timer and joins run at once, the joins in the react state (M.inReact). tests/run.lua has
-- its own, stricter one (no game API off the main thread).
function M.speedControl()
	local timers, joins, hooks, i = {}, {}, {}, 0
	package.loaded["::/gui/main/react.lua"] = {
		RegisterRecipe = function(_, fn) return fn end,
		CallOriginalRecipe = function() return {} end,
		GetRecipeId = function() return nil end,
		useState = function(init)
			i = i + 1
			local k = i
			if hooks[k] == nil then hooks[k] = { v = init } end
			return { old = function() return hooks[k].v end, set = function(_, v) hooks[k].v = v end }
		end,
		useRef = function()
			i = i + 1
			local k = i
			if hooks[k] == nil then hooks[k] = {} end
			return { get = function() return hooks[k].v end, set = function(_, v) hooks[k].v = v end }
		end,
		onStepTimer = function(fn) timers[1] = fn end,
		onStep = function(fn) timers[2] = fn end,
		enqueueJoin = function(fn) joins[#joins + 1] = fn end,
		fireEvent = function() end,
	}
	package.loaded["::/gui/main/builtin.lua"] = { TextView = function(t) return t end, BoxLayout = function(t) return t end,
		ToggleButtonGroup = function(t) return t end, type = { Orientation = { Horizontal = "h" } } }
	package.loaded["::/gui/game_bar/game_bar_widgets.tl"] = { GameSpeedControl = {} }
	_G._react = _G._react or { recipeReplace = {} }
	_G.data = nil
	dofile(here .. "/content/gui/remote_speed.script.lua")
	local control = _G.data().SpeedControl
	return function()
		i = 0
		control({ gameCtx = {} })
		if timers[1] then timers[1]() end
		if timers[2] then timers[2]() end
		local js = joins
		joins = {}
		M.inReact = true
		for _, j in ipairs(js) do pcall(j) end
		M.inReact = false
	end
end

M.dateOf = dateOf
M.DAY_TICKS = DAY_TICKS

-- real-time mode for the Python end-to-end test
if arg and arg[0] and arg[0]:match("fake_game%.lua$") and arg[1] then
	local ffi = require "ffi"
	ffi.cdef "int usleep(unsigned int usec);"
	local dir, seconds = arg[1], tonumber(arg[2] or "30")
	local saves = {
		{ saveName = "probe", path = dir .. "/save/probe.sav", timestamp = 2, size = 10,
			mods = { "example_mod", "hummer_remote_probe" }, modParams = { example_mod = { treePollution = 1 } } },
		{ saveName = "other", path = dir .. "/save/other.sav", timestamp = 1, size = 10, mods = {} },
	}
	local g = M.new(dir, { saves = saves, maxSpeed = 40, menu = arg[3] == "menu",
		entities = { TOWN = { 11, 12 }, LINE = { 21 } }, names = { [11] = "Emsworth", [12] = "Emsworth Bay", [21] = "Bus 1" },
		positions = { [11] = { 0, 0 } },
		industries = { [51] = { name = "Coal mine", construction = 5100, capacity = 12, workers = 5, productivity = 1, pos = { 300, 0 } } },
		workersState = { industriesState = { [51] = { lastVisitors = { { entity = { entity = 9001 }, time = 4000 } } } } },
		townCapacities = { [11] = { 140, 20, 30 } },
		stationGroups = {
			[41] = { name = "Central", stations = { { id = 411, terminals = 2, passenger = true, pos = { 100, 0 } } } },
			[42] = { name = "Harbour", owner = 99, stations = { { id = 421, terminals = 1, passenger = true, pos = { 900, 0 } } } },
			[44] = { name = "Rival Halt", owner = 7, stations = { { id = 441, terminals = 1, passenger = true, pos = { 50, 0 } } } },
		} })
	-- Track Connector (tests/fake_tc.lua): free track ends 101 (0,0) and 103 (1000,0) for the connect command
	dofile(here .. "/tests/fake_tc.lua").install(g, {
		nodes = { [100] = { -100, 0, 10 }, [101] = { 0, 0, 10 }, [103] = { 1000, 0, 20 }, [104] = { 1100, 0, 20 } },
		edges = { [201] = { node0 = 100, node1 = 101 }, [202] = { node0 = 104, node1 = 103 } } })
	local start = os.clock()
	local wall = 0
	local speedControl
	while wall < seconds do
		g.step(0.02)
		-- the speed buttons appear once a game is on screen (the vehicle commands' gui way runs there)
		if not g.menu and g.script then
			speedControl = speedControl or M.speedControl()
			speedControl()
		end
		if g.quitCalled then break end -- app.quit: the game goes away
		wall = wall + 0.02
		ffi.C.usleep(20000)
	end
	for _, l in ipairs(g.logs) do io.stderr:write(l, "\n") end
end

return M
