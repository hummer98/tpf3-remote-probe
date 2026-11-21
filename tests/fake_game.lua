-- A stand-in for the parts of the game the remote probe touches, over a real folder, so the real
-- content/remote.script.lua and tools/tf3ctl.py can talk through real files.
--   require: local fake = dofile("tests/fake_game.lua"); local g = fake.new(dir, opts); g.step(dt)
--   command line: luajit tests/fake_game.lua <dir> <seconds> [menu [modhub]]   (real time, for tests/test_tf3ctl.py;
--                 menu: starts in the main menu with startup.lua, as when launched with --script; modhub: with
--                 My Mods' staging area, see installModhub)
-- Like the game, saveUserdata never overwrites an existing file, and loading a missing file is an error.
local here = (debug.getinfo(1, "S").source:match("^@(.*)/tests/[^/]*$")) or "."

local M = {}
M.guiSave = {}

-- "hummer_remote_probe::/x.lua" -> content/x.lua, as the game resolves a mod's require
-- (unlike the game, plain require keeps a module that returns nothing, as true; the game runs it again)
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

-- userdata with fields and methods, as the engine's objects: a missing field reads nil, a write is an error
local function object(fields, methods, name)
	local u = newproxy(true)
	local mt = getmetatable(u)
	mt.__index = function(_, k)
		if methods and methods[k] ~= nil then return methods[k] end
		return fields[k]
	end
	mt.__newindex = function(_, k) error("cannot set " .. tostring(k) .. " on " .. (name or "userdata")) end
	mt.__tostring = function() return name or "userdata" end
	return u
end

-- an engine vector of these values (1-based, # works, no pairs)
local function vector(list)
	local u = newproxy(true)
	local mt = getmetatable(u)
	mt.__len = function() return #list end
	mt.__index = function(_, i) return list[i] end
	mt.__tostring = function() return "vector" end
	return u
end

-- an enum: each name a distinct userdata, compared with ==, as the engine's
local function enum(names, prefix)
	local e = {}
	for _, n in ipairs(names) do e[n] = object({}, nil, prefix .. "." .. n) end
	return e
end

-- My Mods for tests: api.modhub with an info-only backend (1, also the "StagingArea" source's) and mod.io's
-- publishing one (2), as the base menu sees them, plus api.type.modhub.ModPublishHelper.
-- spec: privileged (default true; a helper made where it is not raises the game's own message),
--   staging = { { folder, title, modhubId (mod.io id as text, nil: none), details = { visible, title, found } or
--   nil (not on mod.io), syncFrames (frames in Sync after the helper is made, default 3), state (after the sync,
--   default Ready), validateUpdates (update() calls a validation takes, default 5), result = { messages = { {
--   level, file, message, consoleOnly } }, criticalPc, criticalConsole, levelPc, levelConsole } } },
--   prefix (put before the folder in ModId.value, e.g. "StagingArea,"), noSource (getBackendIdForSource fails),
--   newReturnsNil, logo (false: the local details have no cover, logoImage ""), publish = { frames (frames in
--   Publishing before HasResult, default 5; they pass whether update() is called or not, as the sync), success
--   (default true), modId (mod.io id it gets, default "7000001"), error = { code, debugMessage,
--   localizedMessage } (on failure), partialErrors = { { step, error = {...} } }, hangs (stays in Publishing),
--   raises (publish raises) }, fileidDir (a folder: on success, as the game is taken to, the fake writes
--   <fileidDir>/<folder>/_metadata/mod.io_fileid.txt with the mod.io id; the real game's moment is not known).
-- g.modhubBusy / g.modhubNoRestricted / g.modhubUploading / g.modhubNotInitialized / g.modhubLoggedOut change
-- what the publishing backend says, from frame to frame. g.helpersMade, g.helperUpdates, g.validateCalls,
-- g.abortValidations count the calls; g.publishCalls ({ value, settings = <plain copy>, state }),
-- g.abortPublishes ({ value, state }) and g.settingsMade record the upload; g.forbidden lists every call of a
-- method that changes a staging mod (setRemoteModId, ...), which this probe must never make, and every misuse of
-- the upload (publish when not Ready, abortPublish when not HasResult, a field PublishSettings does not have).
function M.installModhub(g, spec)
	local LogLevel = enum({ "Critical", "Error", "Warning", "Message", "Verbose" }, "LogLevel")
	local State = enum({ "Sync", "Ready", "Publishing", "HasResult" }, "State")
	api.type.enum.LogLevel = LogLevel
	g.helpersMade, g.helperUpdates, g.validateCalls, g.abortValidations, g.forbidden = 0, 0, {}, 0, {}
	g.publishCalls, g.abortPublishes, g.settingsMade = {}, {}, 0
	local privileged = spec.privileged ~= false
	api.util.hasPrivilegedApis = function() return privileged end
	local staging = spec.staging or {}
	local function modId(v)
		return object({ value = v }, { isValid = function() return v ~= nil and v ~= "" end,
			clone = function() return modId(v) end }, "ModId")
	end
	local function valueOf(e) return (spec.prefix or "") .. e.folder end
	local ids = {}
	for _, e in ipairs(staging) do ids[#ids + 1] = modId(valueOf(e)) end
	api.modhub = {
		getBackendIDs = function() return { 1, 2 } end,
		getCapabilities = function(b) return { isInfoOnly = b == 1, allowRestrictedMode = not g.modhubNoRestricted,
			allowModUpload = b == 2 } end,
		getModManagementState = function(b)
			g.modhubAsked = (g.modhubAsked or 0) + 1
			return { busy = b == 2 and g.modhubBusy == true, uploading = b == 2 and g.modhubUploading == true,
				totalPending = g.modhubBusy and 3 or 0, progress = 0 }
		end,
		isInitialized = function() return not g.modhubNotInitialized end,
		getUserInfo = function(b)
			if g.modhubLoggedOut or b ~= 2 then return nil end
			return object({ userName = "someone", displayName = "Someone" }, nil, "UserInfo")
		end,
		getBackendIdForSource = function(src)
			if spec.noSource then error("no backend for source " .. tostring(src)) end
			return src == "StagingArea" and 1 or nil
		end,
		getInstalledMods = function(b) return vector(b == 1 and ids or {}) end,
		getModInfoForInstalledMod = function(b, id)
			for _, e in ipairs(staging) do
				if valueOf(e) == id.value then return object({ title = e.title, visible = e.listVisible ~= false, modId = id }, nil, "ModInfo") end
			end
		end,
	}
	local function makeResult(r)
		if r == nil then return nil end
		local msgs = {}
		for _, m in ipairs(r.messages or {}) do
			msgs[#msgs + 1] = object({ level = LogLevel[m.level or "Warning"], file = m.file, message = m.message,
				context = m.context or "check", consoleOnly = m.consoleOnly == true }, nil, "ModValidatorMessage")
		end
		return object({ messages = vector(msgs), criticalPc = r.criticalPc == true, criticalConsole = r.criticalConsole == true,
			levelPc = LogLevel[r.levelPc or "Message"], levelConsole = LogLevel[r.levelConsole or "Message"],
			cookedPcPath = "", cookedConsolePath = "" }, nil, "ModValidatorResult")
	end
	local function details(d)
		if d == nil then return nil end
		return object({ found = d.found ~= false, author = "someone", modInfo = object({ visible = d.visible == true,
			title = d.title, modId = modId(d.modId), logoImage = d.logoImage,
			releaseInfo = object({ version = d.version }, nil, "ModReleaseInfo") }, nil, "ModInfo") }, nil, "ModDetailsData")
	end
	local function errorCode(e)
		e = e or {}
		return object({ code = e.code or 0, debugMessage = e.debugMessage or "", localizedMessage = e.localizedMessage or "",
			fields = {} }, nil, "ModHubErrorCode")
	end
	local function makePublishResult(p, id)
		local partial = {}
		for _, pe in ipairs(p.partialErrors or {}) do
			partial[#partial + 1] = object({ step = pe.step, error = errorCode(pe.error) }, nil, "PartialUploadError")
		end
		local success = p.success ~= false
		return object({}, {
			isSuccess = function() return success end,
			getData = function()
				if not success then error("assertion: getData of a failed result") end
				return object({ modId = modId(id), partialErrors = vector(partial) }, nil, "UploadModData")
			end,
			getError = function()
				if success then error("assertion: getError of a successful result") end
				return errorCode(p.error)
			end,
		}, "AsyncResult")
	end
	-- PublishSettings: its fields can be set, as the engine's; a field it does not have is an error
	local SETTINGS = { changeLog = "", updateMetadata = false, setPublic = false, isSavegame = false,
		issuesConfirmed = false, additionalMetadata = false }
	local function publishSettings()
		g.settingsMade = g.settingsMade + 1
		local v = {}
		for k, x in pairs(SETTINGS) do v[k] = x end
		v.additionalMetadata = nil
		local u = newproxy(true)
		local mt = getmetatable(u)
		mt.__index = function(_, k)
			if k == "_plain" then local c = {}; for kk, x in pairs(v) do c[kk] = x end; return c end
			if SETTINGS[k] == nil then error("PublishSettings has no field " .. tostring(k)) end
			return v[k]
		end
		mt.__newindex = function(_, k, x)
			if SETTINGS[k] == nil then table.insert(g.forbidden, "PublishSettings." .. tostring(k)); error("no field " .. tostring(k)) end
			v[k] = x
		end
		return u
	end
	local forbiddenNames = { "setRemoteModId", "setModDetails", "refreshMod",
		"addLogoImage", "removeLogoImage", "addGalleryImages", "removeGalleryImage", "moveGalleryImage",
		"setPostPublishFn", "openFolder" }
	api.type.modhub = {
		StagingModData = { State = State },
		PublishSettings = { new = function() return publishSettings() end },
		ModPublishHelper = { new = function(backend)
			if not privileged then error("API can only be used by privileged (non-moddable) scripts") end
			if spec.newReturnsNil then return nil end
			g.helpersMade = g.helpersMade + 1
			local mods = {}
			for _, e in ipairs(staging) do
				mods[valueOf(e)] = { e = e, state = "Sync", syncLeft = e.syncFrames or 3, validating = false, progress = 0,
					unknownLeft = e.unknownFrames or 0 }
			end
			-- the sync with mod.io runs in C++, whether update() is called or not
			g.modhubTick = function()
				for _, m in pairs(mods) do
					if m.unknownLeft > 0 then m.unknownLeft = m.unknownLeft - 1 end
					if m.state == "Sync" and not m.e.staysInSync then
						m.syncLeft = m.syncLeft - 1
						if m.syncLeft <= 0 then m.state = m.e.state or "Ready" end
					end
					local p = m.e.publish or {}
					if m.state == "Publishing" and not p.hangs and m.publishLeft then
						m.publishLeft = m.publishLeft - 1
						if m.publishLeft <= 0 then
							local id = p.modId or "7000001"
							m.state, m.publishResult = "HasResult", makePublishResult(p, id)
							if p.success ~= false and spec.fileidDir then
								local f = io.open(spec.fileidDir .. "/" .. m.e.folder .. "/_metadata/mod.io_fileid.txt", "w")
								if f then f:write(id); f:close() end
							end
							m.resultId = p.success ~= false and id or nil
						end
					end
				end
			end
			-- a mod the helper does not have: the engine is taken to assert (g.asserted), not to raise a Lua error
			-- a pcall could catch. unknownFrames: the first frames after the helper is made, before it has the mod.
			local function mod(id)
				local m = mods[id.value]
				if not m or m.unknownLeft > 0 then
					g.asserted = (g.asserted or 0) + 1
					error("assertion: staging mod not found: " .. tostring(id.value))
				end
				return m
			end
			local methods = {
				hasAnyStagingMods = function() return next(mods) ~= nil end,
				hasStagingMod = function(_, id) local m = mods[id.value]; return m ~= nil and m.unknownLeft == 0 end,
				getStagingModData = function(_, id)
					local m = mod(id)
					return object({ state = State[m.state], modhubId = modId(m.e.modhubId),
						modhubDetails = m.state ~= "Sync" and details(m.e.details) or nil,
						localModhubDetails = details({ title = m.e.title, visible = false,
							logoImage = m.e.logo == false and "" or "_metadata/0.png" }),
						publishResult = m.state == "HasResult" and m.publishResult or nil }, nil, "StagingModData")
				end,
				-- polls the validations (the type: has to be called regularly while one runs)
				update = function()
					g.helperUpdates = g.helperUpdates + 1
					for _, m in pairs(mods) do
						if m.pending then m.pending, m.validating = nil, true end
						if m.validating then
							m.left = m.left - 1
							m.progress = 1 - m.left / (m.e.validateUpdates or 5)
							if m.left <= 0 and not m.e.validationHangs then
								m.validating, m.result = false, m.e.result or {}
							end
						end
					end
				end,
				validate = function(_, id)
					local m = mod(id)
					g.validateCalls[#g.validateCalls + 1] = id.value
					-- lateStart: validating shows only from the next update(), as an async start may
					m.validating, m.left, m.progress = not m.e.lateStart, m.e.validateUpdates or 5, 0
					m.pending = m.e.lateStart
				end,
				abortValidation = function(_, id)
					g.abortValidations = g.abortValidations + 1
					mod(id).validating = false
				end,
				publish = function(_, id, settings)
					local m = mod(id)
					local ok, plain = pcall(function() return settings._plain end)
					g.publishCalls[#g.publishCalls + 1] = { value = id.value, settings = ok and plain or nil, state = m.state }
					if m.state ~= "Ready" then table.insert(g.forbidden, "publish while " .. m.state) end
					local p = m.e.publish or {}
					if p.raises then error("publish failed in C++") end
					m.state, m.publishLeft = "Publishing", p.frames or 5
					return object({}, nil, "AsyncResult")
				end,
				abortPublish = function(_, id)
					local m = mod(id)
					g.abortPublishes[#g.abortPublishes + 1] = { value = id.value, state = m.state }
					if m.state ~= "HasResult" then table.insert(g.forbidden, "abortPublish while " .. m.state) end
					-- a success leaves the mod with its mod.io id (a guess: what the page then shows is not seen)
					if m.resultId then m.e.modhubId = m.resultId end
					m.state, m.publishResult = "Ready", nil
					return object({}, nil, "UniquePendingRequestId")
				end,
				getValidationData = function(_, id)
					local m = mod(id)
					-- a new userdata on each read, as the engine's (no identity to compare)
					return object({ validating = m.validating, progress = m.progress, task = m.validating and "Checking files" or "",
						result = makeResult(m.result) }, nil, "ValidationData")
				end,
			}
			for _, n in ipairs(forbiddenNames) do
				methods[n] = function() table.insert(g.forbidden, n); error(n .. " must never be called by the probe") end
			end
			return object({}, methods, "ModPublishHelper")
		end },
	}
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
	-- industryStocks: industries[e].stocks = { { type, cargoType, capacity, count, mixedTypes, cargoTypes = { ids },
	-- classes = { "#any" }, consumeFrequency } }, .rules = { { input = { { n per stock } }, output = { [cargo] = n },
	-- booster, boostFactor } }; opts.constructionComps = { [construction] = { fileName, params } } (params handed
	-- out as params_native, asTable, as the engine does; noNative = true: only the params record)
	local industries = opts.industries or {}
	-- persons (the persons command): opts.persons = { [entity] = { happiness, destinations = { home, shop, work },
	-- targetOrAtEntity, good (isGoodQuality), atVehicle = { vehicle, part, place, expectedArrivalTime } (also puts
	-- it in getVehicle2Cargo2SimEntitesMap under the passengers), trip = { line, lineStop0, lineStop1, vehicle }
	-- (SIM_ENTITY_AT_VEHICLE), atTerminal = { line, lineStop0, lineStop1, arrivalTime, vehicle }, noSimPerson (its
	-- SIM_PERSON reads nil), userdata (its components come back as userdata, as the engine's) } };
	-- opts.quality = { vehicle = { [e] = q }, line = { [e] = q }, stop = { [line] = { [stopIndex0] = q } },
	-- group = { [g] = q } } with q = { countTotal, countBad, averageQuality, isVeryBad }, handed out as userdata
	local persons = opts.persons or {}
	g.persons = persons
	local function asUserdata(t)
		local u = newproxy(true)
		getmetatable(u).__index = function(_, k) return t[k] end
		getmetatable(u).__len = function() return #t end
		return u
	end
	local function qualityData(t)
		-- nothing known: what the engine gives for nobody there (no averageQuality)
		return asUserdata(copy(t or { countTotal = 0, countBad = 0, isVeryBad = false }))
	end
	local function personComponent(e, kind)
		local p = persons[e]
		if not p then return nil end
		local t
		if kind == "SIM_PERSON" and not p.noSimPerson then
			t = { happiness = p.happiness, destinations = copy(p.destinations or { -1, -1, -1 }),
				targetOrAtEntity = p.targetOrAtEntity or -1, lastMoveMode = p.lastMoveMode or 0, cargoType = 0 }
		elseif kind == "SIM_PERSON_AT_VEHICLE" and p.atVehicle then
			t = copy(p.atVehicle)
		elseif kind == "SIM_ENTITY_AT_VEHICLE" and p.trip then
			t = copy(p.trip)
		elseif kind == "SIM_ENTITY_AT_TERMINAL" and p.atTerminal then
			t = copy(p.atTerminal)
		end
		if t and p.userdata then
			if t.destinations then t.destinations = asUserdata(t.destinations) end
			return asUserdata(t)
		end
		return t
	end
	local constructionComps = opts.constructionComps or {}
	-- a stock id the industry's list does not have: the engine's assertion (past pcall in the game)
	local function stockOf(e, stockId)
		local i = industries[e]
		local st = i and i.stocks and i.stocks[stockId + 1]
		if not st then error("ASSERT: no stock " .. tostring(stockId) .. " at " .. tostring(e)) end
		return st
	end
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
				stopConfig = cfg, alternativeTerminals = {}, waypoints = s.waypoints or {}, maxAdditionalWaitingTime = 60,
				loadMode = s.loadMode or 0 }
		end
		g.lines[e] = { name = l.name, stops = stops, customFilters = l.customFilters == true, reservationPriority = 1 }
	end
	-- one platform's carriers: st.terminalCarriers[i] (1-based) where given, else the station's carriers. A station
	-- or terminal that does not exist is taken as the engine's assertion: nothing says the engine checks, and the
	-- probe must look before it asks.
	local function terminalCarriers(gid, station, terminal)
		local grp = groups[gid]
		local st = grp and (grp.stations or {})[station + 1]
		if not st or terminal < 0 or terminal >= (st.terminals or 1) then
			g.crashed = "ASSERT: getCarriers of station " .. tostring(station) .. " terminal " .. tostring(terminal) ..
				" of station group " .. tostring(gid)
			error(g.crashed)
		end
		local out = {}
		for _, c in ipairs((st.terminalCarriers or {})[terminal + 1] or st.carriers or { "ROAD" }) do
			out[#out + 1] = api.type.enum.Carrier[c]
		end
		table.sort(out)
		return out
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
			-- a load mode outside the LoadMode enum (0..3, engine.d.tl)
			if s.loadMode ~= nil and (type(s.loadMode) ~= "number" or s.loadMode < 0 or s.loadMode > 3 or s.loadMode % 1 ~= 0) then
				g.crashed = "ASSERT: line stop " .. i .. " has load mode " .. tostring(s.loadMode)
				error(g.crashed)
			end
		end
		-- a stop at a platform none of the line's vehicles could use: every platform must share a carrier. Whether
		-- the engine asserts or refuses is not known; the fake takes the worse.
		local common
		for _, s in ipairs(line.stops or {}) do
			local set = {}
			for _, c in ipairs(terminalCarriers(s.stationGroup, s.station, s.terminal)) do set[c] = true end
			if common == nil then
				common = set
			else
				for c in pairs(common) do if not set[c] then common[c] = nil end end
			end
		end
		if common and next(common) == nil then
			g.crashed = "ASSERT: the line's platforms share no carrier"
			error(g.crashed)
		end
	end
	local function lineVehicleIds(line)
		local out = {}
		for e, c in pairs(g.fleet) do if c.line == line then out[#out + 1] = e end end
		table.sort(out)
		return out
	end
	g.groups, g.cargoTypes = groups, cargoTypes
	-- the running state of a vehicle (fleet[e].live = { speed, runningCost, maintenance, loaded = { [cargo] = n },
	-- fields = { ... } }); one that is gone is the engine's assertion
	local function liveOf(e)
		local c = g.fleet[e]
		if not c then error("ASSERT: no transport vehicle " .. tostring(e)) end
		return c.live or {}
	end
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
			-- opts.setLineRefused = { reason = "NoSmallShip", pos = { x, y, z } }: the engine refuses every vehicle,
			-- which stays where it is (getFailedPathReason gives the reason)
			if not g.fleet[cmd.vehicle] or opts.setLineRefused then return false end
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
		util = { getApplicationTime = function() return g.time end,
			getDefaultYearDuration = function() return 365 * DAY_TICKS end },
		-- opts.modhub: see installModhub (after this table)
		engine = {
			util = {
				getWorld = function() inGame("getWorld"); return 1 end,
				getCalendarDate = function(t) return dateOf(t) end,
				getPlayer = function() return 99 end,
				getEntityName = function(e)
					return (opts.names or {})[e] or (industries[e] and industries[e].name) or (depots[e] and depots[e].name) or (g.lines[e] and g.lines[e].name)
						or (groups[e] and groups[e].name)
				end,
				stock = { getStockCargoTypes = function(e, stockId)
					local st = stockOf(e, stockId)
					return copy(st.cargoTypes or (st.cargoType and st.cargoType >= 0 and { st.cargoType }) or {})
				end },
				cargo = {
					isGoodQuality = function(e)
						if not persons[e] then g.crashed = "ASSERT: no sim entity " .. tostring(e); error(g.crashed) end
						if persons[e].good == nil then return (persons[e].happiness or 0) >= 0.5 end
						return persons[e].good
					end,
					getCargoQualityDataForVehicle = function(e, cargo)
						if not g.fleet[e] then g.crashed = "ASSERT: no transport vehicle " .. tostring(e); error(g.crashed) end
						return qualityData(((opts.quality or {}).vehicle or {})[e])
					end,
					getCargoQualityDataForLine = function(l, cargo)
						if not g.lines[l] then g.crashed = "ASSERT: no line " .. tostring(l); error(g.crashed) end
						return qualityData(((opts.quality or {}).line or {})[l])
					end,
					getCargoQualityDataAtStop = function(l, stopIndex, cargo)
						if not (g.lines[l] and g.lines[l].stops[stopIndex + 1]) then
							g.crashed = "ASSERT: no stop " .. tostring(stopIndex) .. " on line " .. tostring(l)
							error(g.crashed)
						end
						return qualityData((((opts.quality or {}).stop or {})[l] or {})[stopIndex])
					end,
					getCargoQualityDataAtStationGroup = function(gid, cargo)
						if not groups[gid] then g.crashed = "ASSERT: no station group " .. tostring(gid); error(g.crashed) end
						return qualityData(((opts.quality or {}).group or {})[gid])
					end,
				},
				station = { isStationOfType = function(st, cargo)
					return stationOf[st] ~= nil and (stationOf[st].passenger == true) == (cargo == false)
				end },
				-- opts.modesToCarriers: the engine maps transport modes to carriers (statistics_react_util.tl uses it)
				-- transport.calcPosition: the fake geometry's x, y (param added to x), z 0
				transport = { calcPosition = function(geo, param)
					if type(geo) ~= "table" or not geo.x then error("no geometry") end
					return { x = geo.x + (param or 0), y = geo.y, z = 0 }
				end, transportModesToCarriers = opts.modesToCarriers and function(modes)
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
				end or nil },
				-- opts.infiniteMoney: nil, as the engine gives for infinite money
				finance = { getPlayersBalance = function() if opts.infiniteMoney then return nil end return g.balance end,
					-- opts.vehicleBalances = { [entity] = { { time, amount } } }: the journal of a vehicle
					calculateBalance = function(list, from, to, maintenanceIncomeOnly)
						g.balanceAsked = { list = copy(list), from = from, to = to, only = maintenanceIncomeOnly }
						local sum = 0
						for _, e in ipairs(list) do
							for _, j in ipairs((opts.vehicleBalances or {})[e] or {}) do
								if j[1] >= from and j[1] <= to then sum = sum + j[2] end
							end
						end
						return sum
					end },
				-- opts.lineProblems = { [line] = { { stop state, ... } per segment } }, a stop state as the engine's
				-- StopState with its mode sets as name lists (noPathLocation = { edgeIndex, node, nodePosition = { x, y,
				-- z }, okModes, relaxedModes, allowedModes }); opts.lineModes = { [line] = { names } }. A line the engine
				-- does not have: its assertion. getFailedPathReason: opts.setLineRefused (reason NoPath when not given);
				-- opts.failedPathRaises: it raises
				line = {
					getFailedPathReason = function(v, l, full)
						g.failedPathAsked = { v, l, full }
						if opts.failedPathRaises then error("ASSERT: no failed path for " .. tostring(v)) end
						local r = opts.setLineRefused or {}
						local p = r.pos and object(copy(r.pos), nil, "Vec3f") or nil
						return object({ reason = api.type.Failure.Reason[r.reason or "NoPath"], pos = p }, nil, "Failure")
					end,
					getDetailedLineProblems = function(l)
						if not g.lines[l] then g.crashed = "ASSERT: no line " .. tostring(l); error(g.crashed) end
						local function modes(list)
							if list == nil then return nil end
							local m = {}
							for _, n in ipairs(list) do m[api.type.enum.TransportMode[n]] = true end
							return m
						end
						local function loc(x)
							if x == nil then return nil end
							return object({ edgeIndex = x.edgeIndex, node = x.node,
								nodePosition = x.nodePosition and object(copy(x.nodePosition), nil, "Vec3f") or nil,
								okModes = modes(x.okModes), relaxedModes = modes(x.relaxedModes), allowedModes = modes(x.allowedModes) },
								nil, "PathProblemLocation")
						end
						local segments = {}
						for i, seg in ipairs((opts.lineProblems or {})[l] or {}) do
							local stops = {}
							for j, st in ipairs(seg) do
								local f = { empty = st.empty == true, noPath = st.noPath == true, duplicateStop = st.duplicateStop == true,
									incompatibleStop = st.incompatibleStop == true, noPathLocation = loc(st.noPathLocation) }
								if st.noPathToAlternative then f.noPathToAlternative = { st.noPathToAlternative[1], loc(st.noPathToAlternative[2]) } end
								if st.noPathFromAlternative then f.noPathFromAlternative = { st.noPathFromAlternative[1], loc(st.noPathFromAlternative[2]) } end
								stops[j] = object(f, nil, "StopState")
							end
							segments[i] = vector(stops)
						end
						return vector(segments)
					end,
					getLineTransportModesUnion = function(l)
						if not g.lines[l] then g.crashed = "ASSERT: no line " .. tostring(l); error(g.crashed) end
						local m = {}
						for _, n in ipairs((opts.lineModes or {})[l] or {}) do m[api.type.enum.TransportMode[n]] = true end
						return m
					end,
				},
				vehicle = {
					getDepreciatedValue = function(e) return g.fleet[e] and math.floor(configPrice(g.fleet[e]) * 0.9) or 0 end,
					getPartPrice = function(p) return models[p.part.modelId].price end,
					-- a vehicle that is gone: the engine's assertion (the probe reads only vehicles it listed)
					getSpeed = function(e) return liveOf(e).speed or 0 end,
					getRunningCost = function(e) return liveOf(e).runningCost or 1234.5 end,
					getVehicleMaintenanceState = function(e) return liveOf(e).maintenance or 1 end,
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
				simEntityAtStockSystem = { getStockCount = function(e, stockId) return stockOf(e, stockId).count or 0 end },
				simPersonSystem = { getSimPersonsForDestination = function(e)
					if not (industries[e] and industries[e].capacity) then error("ASSERT: no person capacity for " .. tostring(e)) end
					local ids = {}
					for i = 1, industries[e].workers or 0 do ids[i] = e * 1000 + i end
					return ids
				end, getSimPersonsForLine = function(line)
					-- a line the engine does not have: taken as its assertion (the probe asks only for the company's)
					if not g.lines[line] then g.crashed = "ASSERT: no line " .. tostring(line); error(g.crashed) end
					local ids = {}
					for e, p in pairs(persons) do
						if (p.trip and p.trip.line == line) or (p.atTerminal and p.atTerminal.line == line) then ids[#ids + 1] = e end
					end
					table.sort(ids)
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
					-- station and terminal -1: the group's carriers; else one platform's (see terminalCarriers)
					getCarriers = function(gid, station, terminal)
						g.carrierCalls = (g.carrierCalls or 0) + 1
						if station ~= nil and station >= 0 then return { terminalCarriers(gid, station, terminal), {} } end
						return { groupCarriers(gid), {} }
					end,
					getStationGroup = function(st) return groupOfStation[st] or -1 end,
				},
				simEntityAtVehicleSystem = { getVehicleSimEntitiesCountForCargoType = function(e, cargo)
					if not cargoTypes[cargo] then error("ASSERT: no cargo type " .. tostring(cargo)) end
					return (liveOf(e).loaded or {})[cargo] or 0
				end, getVehicle2Cargo2SimEntitesMap = function()
					-- vehicle -> { [cargo + 1] = ids }: only vehicles with someone aboard have an entry (the base
					-- checks for nil, entity_window_util.tl PassengersWidget); a userdata map, as the engine's
					g.mapCalls = (g.mapCalls or 0) + 1
					local map = {}
					for e, p in pairs(persons) do
						local v = p.atVehicle and p.atVehicle.vehicle
						if v then
							map[v] = map[v] or { {} }
							table.insert(map[v][1], e)
						end
					end
					for _, byCargo in pairs(map) do table.sort(byCargo[1]) end
					return asUserdata(map)
				end },
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
				if type(kind) == "string" and kind:match("^SIM_") then return personComponent(e, kind) end
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
					if not (i and (i.productivity or i.stocks)) then return nil end
					local stocks, datas = {}, {}
					for k, st in ipairs(i.stocks or {}) do
						stocks[k] = { type = st.type or 0, cargoType = st.cargoType or -1, capacity = st.capacity or 0,
							mixedTypes = st.mixedTypes == true, tag = k, loadSpeedModifier = 1,
							cargoTypes = { cargoClassesIncluded = copy(st.classes or {}) } }
						datas[k] = { consumeFrequency = st.consumeFrequency or 0 }
					end
					return { modifiers = { productivity = i.productivity }, stocks = stocks, stockDatas = datas,
						rules = copy(i.rules or {}), thrownAwayCargo = i.thrownAwayCargo or 0 }
				end
				if kind == "CONSTRUCTION" then
					local cc = constructionComps[e]
					if not cc then return nil end
					local params = copy(cc.params or {})
					return { fileName = cc.fileName, params = params,
						params_native = (not cc.noNative) and cc.params and native(copy(cc.params)) or nil }
				end
				if kind == "TRANSPORT_VEHICLE" then
					local c = g.fleet[e]
					if not c then return nil end
					local tv = { transportVehicleConfig = copy(c), line = c.line, depot = c.depot,
						config = { capacities = copy(c.capacities or {}) } }
					-- c.live: the running vehicle's fields as engine.d.tl names them (state, loadState, doorsTime,
					-- lineStopDepartures, loadSpeedModifiers = { [cargo + 1] = { ... } }, ...), copied in as they are
					for k, v in pairs(c.live and c.live.fields or {}) do
						if k == "loadSpeedModifiers" then
							local mods = {}
							for i, m in pairs(v) do
								local mm = copy(m)
								mods[i] = setmetatable(mm, { __index = { getTotalPenalty = function(self)
									return (self.vehicleOverlength or 0) + (self.vehicleIncompatibility or 0) + 1
								end } })
							end
							tv[k] = mods
						else
							tv[k] = copy(v)
						end
					end
					-- an engine vector read past its end: noted (the engine may assert; core.at's pcall would hide a
					-- Lua error here)
					for k, v in pairs(tv) do
						if type(v) == "table" and (k:match("^timeUntilNext") or k == "loadSpeedModifiers") then
							setmetatable(v, { __index = function(_, i)
								if type(i) == "number" then g.outOfRange = (g.outOfRange or "") .. k .. "[" .. i .. "] " end
							end })
						end
					end
					setmetatable(tv.config.capacities, { __index = function(_, i)
						if type(i) == "number" then g.outOfRange = (g.outOfRange or "") .. "capacities[" .. i .. "] " end
					end })
					return tv
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
					-- st.terminalInfo[i]: fields as the engine's Terminal (tag, the four flags, cargoTransferSpeeds,
					-- vehicleEdges), over the defaults
					for i = 1, st.terminals or 1 do
						local p, c = st.kind == "passenger", st.kind == "cargo"
						t[i] = { tag = i }
						if st.kind then
							t[i].passengersLoad, t[i].passengersUnload, t[i].cargoLoad, t[i].cargoUnload = p, p, c, c
						end
						for k, v in pairs((st.terminalInfo or {})[i] or {}) do t[i][k] = copy(v) end
					end
					return { terminals = t }
				end
				-- opts.networks = { [entity] = { edges = { { geometry = { x, y } } } } }: calcPosition below gives
				-- the geometry's x, y (param added to x)
				if kind == "TRANSPORT_NETWORK" then
					local n = (opts.networks or {})[e]
					return n and copy(n) or nil
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
				LandUseType = { RESIDENTIAL = 0, COMMERCIAL = 1, INDUSTRIAL = 2 },
				TransportVehicleState = { IN_DEPOT = 0, EN_ROUTE = 1, AT_TERMINAL = 2, GOING_TO_DEPOT = 3 },
				StockListType = { InputStock = 0, OutputStock = 1, StorageStock = 2 } },
			TransportVehicle = { LoadState = { None = 0, Arrived = 1, Unloading = 2, Loading = 3,
				WaitForScheduledDeparture = 4, Departing = 5 } },
			Failure = { Reason = enum({ "Unkown", "NoPath", "NoElectric", "NoTram", "NoTramButTramTrack", "NoTramTrackButRail",
				"NoRail", "NoRoad", "NoSmallAircraft", "NoSmallShip" }, "Failure.Reason") },
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
						waypoints = {}, maxAdditionalWaitingTime = 0, loadMode = 0 }
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
				PERSON_CAPACITY = "PERSON_CAPACITY", STOCK_LIST = "STOCK_LIST", CONSTRUCTION = "CONSTRUCTION",
				TRANSPORT_NETWORK = "TRANSPORT_NETWORK", SIM_PERSON = "SIM_PERSON", SIM_PERSON_AT_VEHICLE = "SIM_PERSON_AT_VEHICLE",
				SIM_ENTITY_AT_VEHICLE = "SIM_ENTITY_AT_VEHICLE", SIM_ENTITY_AT_TERMINAL = "SIM_ENTITY_AT_TERMINAL" },
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
				-- opts.lostSetLine: a send to a line neither runs nor answers (the rest of the commands do)
				if opts.lostSetLine and cmd.kind == "setLine" then return end
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
			get = function(id)
				if not cargoTypes[id] then error("ASSERT: no cargo type " .. tostring(id)) end
				return cargoTypes[id] and { name = cargoTypes[id].label } or nil
			end,
			getPassengerCargoTypeId = function() return 0 end,
			-- as the engine: a cargo type is in the set by name (cargoTypesIncluded) or by one of its classes
			-- (cargoTypes[id].classes), and not when excluded either way
			forEachCargoType = function(set, cb)
				local function has(list, x) for _, y in ipairs(list or {}) do if y == x then return true end end return false end
				local ids = {}
				for id in pairs(cargoTypes) do ids[#ids + 1] = id end
				table.sort(ids)
				for _, id in ipairs(ids) do
					local ct, inClass, outClass = cargoTypes[id], false, false
					for _, cl in ipairs(ct.classes or {}) do
						inClass = inClass or has(set.cargoClassesIncluded, cl)
						outClass = outClass or has(set.cargoClassesExcluded, cl)
					end
					if (inClass or has(set.cargoTypesIncluded, ct.name)) and not outClass and not has(set.cargoTypesExcluded, ct.name) then
						cb(id)
					end
				end
			end,
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
				-- m.noMetadata: a model without metadata; m.meta: more of it (maintenance, waterVehicle,
				-- transportVehicle with compartments, description, ...), as the engine holds it after load
				if m.noMetadata then return {} end
				local md = { cost = { price = m.price, priceScale = m.priceScale },
					transportVehicle = m.vehicle and { compartments = { {}, {} } } or nil }
				for k, v in pairs(m.meta or {}) do md[k] = copy(v) end
				return { metadata = md }
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
	if opts.modhub then M.installModhub(g, opts.modhub == true and {} or opts.modhub) end

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
					-- as the base: the via's loadMode, then passThroughStopData's
					if v.stop.loadMode ~= nil then s.loadMode = v.stop.loadMode end
					if v.stop.passThroughStopData.loadMode then s.loadMode = v.stop.passThroughStopData.loadMode end
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
			-- as the base's getTerminal (line_util.tl): stations[station1], terminals[terminal1] read without a look;
			-- past the end of the engine's vectors is taken as its assertion
			for _, v in ipairs(line.path) do
				if v.stop and v.stop.station1 then
					local grp = groups[v.stop.stationGroup]
					local st = grp and (grp.stations or {})[v.stop.station1]
					if not st or not v.stop.terminal1 or v.stop.terminal1 < 1 or v.stop.terminal1 > (st.terminals or 1) then
						g.crashed = "ASSERT: line_util.getTerminal read past the end"
						error(g.crashed)
					end
				end
			end
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
					maxAdditionalWaitingTime = s.maxAdditionalWaitingTime, loadMode = s.loadMode } } }
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

	-- the base's ::/base/init.lua: it declares the globals the game itself uses up front (data = false, ...) and
	-- then puts a __newindex on _G; a mod's file that makes a new global still gets it, but the game logs
	-- "ERROR Global variable in mod ... key = <name>", which goes out as a crash report (2026-11-20, every launch
	-- with --script). The guard runs while the mod's code does (the menu's startup.lua, its update); the keys it
	-- saw are in g.globalWrites.
	g.globalWrites = {}
	function g.asMod(fn, ...)
		local prev = getmetatable(_G)
		setmetatable(_G, { __newindex = function(t, k, v)
			rawset(t, k, v)
			g.globalWrites[#g.globalWrites + 1] = tostring(k)
		end })
		local res = { pcall(fn, ...) }
		setmetatable(_G, prev)
		if not res[1] then error(res[2], 0) end
		return (table.unpack or unpack)(res, 2)
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
			_G.data = false -- as init.lua declares it
			g.menuScript = g.asMod(function()
				dofile(here .. "/content/startup.lua")
				return _G.data()
			end)
			g.script = nil
			return
		end
		dofile(here .. "/content/remote.script.lua")
		g.script = _G.data()
	end

	function g.step(dt)
		dt = dt or 1 / 30
		if g.modhubTick then g.modhubTick() end
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
		if g.menuScript and (g.menu or opts.menuKeepsRunning) then g.asMod(g.menuScript.update) end
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

-- The engine's side of a build (makeWorldBuildProposalCmd with a SimpleProposal), for the build command.
-- spec.cons = { [resName] = { params = { { key, numbers, defaultIndex } }, cost = n, shape = { nodes = { { dx, dy,
-- dz } }, edges = { { i, j } } }, depots = n } }: the constructions the rep knows and what one is made of (its own
-- road pieces, relative to where it stands, unturned); spec.height(x, y): the terrain (0 without);
-- spec.blocked(x, y): something in the way there (an entity id, refused as a collision); spec.lostCallback: the
-- build runs, no callback comes; spec.raiseInCallback: reading the callback's data raises;
-- spec.sendRaises: sendCommand raises (this text).
-- spec.modules = { [resName] = { metadata = {...}, updateScript = { fileName, params } } }: moduleRep (find, get,
-- getAll); a construction's stations = n with terminals = n, or a function(params) -> n per station (a harbour's
-- terminals counted from its modules under whole-number keys only: one under a text key sits on no slot).
-- A module's getFails: moduleRep.get raises; metadataNative: its metadata an engine map (userdata with asTable);
-- metadataOpaque: userdata without asTable.
-- spec.water(x, y) -> true / false: isOnWater; spec.waterLevel: TERRAIN.waterLevel of the world (entity 1);
-- spec.bounds = { x0, y0, x1, y1 }: isValidCoordinate, and isOnWater off the map is an assertion.
-- g.built[e] = { fileName, params, transf, name, player, frozenEdges, ... }; g.buildCmds: every proposal sent.
-- Like the engine: a list element written into a proposal is lost (only a whole list assigned counts), an unknown
-- file name or a transf that is no Mat4f is an assertion (the game would die), a refused proposal builds nothing,
-- and makeProposalData takes no SimpleProposal (engine/util.d.tl:939 types it for a Proposal; g.proposalDataCalls).
-- The octree finds the constructions in g.built by their transf's position.
function M.installBuild(g, spec)
	spec = spec or {}
	local cons = spec.cons or {}
	g.built, g.buildCmds, g.nodes, g.edges = {}, {}, {}, {}
	local names = {}
	local CT = api.type.ComponentType
	CT.BASE_NODE, CT.BASE_EDGE, CT.CONSTRUCTION = "BASE_NODE", "BASE_EDGE", "CONSTRUCTION"
	CT.STATION, CT.TERRAIN = CT.STATION or "STATION", CT.TERRAIN or "TERRAIN"
	g.buildStations = {}
	local function crash(msg) g.crashed = "ASSERT: " .. msg; error(g.crashed) end
	api.type.Vec2f = { new = function(x, y) return { x = x, y = y } end }
	api.type.Vec4f = { new = function(x, y, z, w) return { x, y, z, w } end }
	api.type.Mat4f = { new = function(c1, c2, c3, c4)
		local m = { mat4f = true }
		for i, c in ipairs({ c1, c2, c3, c4 }) do for j = 1, 4 do m[(i - 1) * 4 + j] = c[j] end end
		return m
	end }
	api.type.Context = { new = function() return { player = -1, cleanupStreetGraph = true, gatherBuildings = true,
		gatherFields = true } end }
	-- engine records: fields kept in a hidden table; reading a list hands out a copy (so writing one element of it
	-- is lost), assigning a whole list copies it in
	local function record(fields)
		local store = copy(fields)
		local u = newproxy(true)
		local mt = getmetatable(u)
		mt.__index = function(_, k)
			if fields[k] == nil then error("no field " .. tostring(k)) end
			return type(store[k]) == "table" and copy(store[k]) or store[k]
		end
		mt.__newindex = function(_, k, v)
			if fields[k] == nil then error("no field " .. tostring(k)) end
			if type(v) == "table" then
				local c = {}
				for kk, vv in pairs(v) do c[kk] = (type(vv) == "userdata" and getmetatable(vv).store) and getmetatable(vv).store or copy(vv) end
				v = c
			end
			store[k] = v
		end
		mt.store = store
		return u
	end
	api.type.SimpleProposal = { new = function()
		return record({ constructionsToAdd = {}, constructionsToRemove = {}, old2new = {}, streetProposal = {} })
	end, ConstructionEntity = { new = function()
		return record({ fileName = "", params = {}, transf = {}, name = "", playerEntity = -1, autoFillSlots = false })
	end } }
	api.engine.terrain = { getHeightAt = function(v) return spec.height and spec.height(v.x, v.y) or 0 end,
		isValidCoordinate = function(v)
			local b = spec.bounds
			return not b or (v.x >= b[1] and v.y >= b[2] and v.x <= b[3] and v.y <= b[4])
		end,
		isOnWater = function(v)
			if type(v) ~= "table" or v.x == nil then crash("isOnWater: no Vec2f") end
			if not api.engine.terrain.isValidCoordinate(v) then crash("isOnWater off the map") end
			return spec.water and spec.water(v.x, v.y) == true or false
		end }
	local mods = spec.modules or {}
	local modIndex = {}
	do
		local sorted = {}
		for name in pairs(mods) do sorted[#sorted + 1] = name end
		table.sort(sorted)
		for i, name in ipairs(sorted) do modIndex[i] = name end
	end
	api.res.moduleRep = {
		find = function(name)
			for i, n in ipairs(modIndex) do if n == name then return i end end
			return -1
		end,
		get = function(idx)
			local name = modIndex[idx]
			if not name then crash("moduleRep.get(" .. tostring(idx) .. ")") end
			local m = mods[name]
			if m.getFails then error("moduleRep.get: no desc") end
			local md = m.metadata
			if m.metadataNative or m.metadataOpaque then
				local u = newproxy(true)
				if m.metadataNative then
					getmetatable(u).__index = { asTable = function() return copy(m.metadata) end }
				else
					getmetatable(u).__index = function() error("no field") end
				end
				md = u
			end
			return { fileName = name, metadata = md, updateScript = m.updateScript }
		end,
		getAll = function()
			local out = {}
			for i, n in ipairs(modIndex) do out[i] = n end
			return out
		end,
	}
	-- the names the game had before (opts.constructions, the build tool's) are still found, after the build's own
	local oldFind = api.res.constructionRep.find
	api.res.constructionRep = {
		find = function(name) return cons[name] and 1 or -1 end,
		get = function() crash("constructionRep.get with an index the fake does not track") end,
		getAll = function()
			local out, i = {}, 0
			for name in pairs(cons) do i = i + 1; out[i] = name end
			return out
		end,
	}
	local byIndex = {}
	do
		local i = 0
		local sorted = {}
		for name in pairs(cons) do sorted[#sorted + 1] = name end
		table.sort(sorted)
		for _, name in ipairs(sorted) do i = i + 1; byIndex[i] = name end
		api.res.constructionRep.find = function(name)
			for k, n in ipairs(byIndex) do if n == name then return k end end
			local old = oldFind(name)
			return old >= 0 and 1000 + old or -1
		end
		api.res.constructionRep.get = function(idx)
			if idx >= 1000 then return { params = {} } end
			local c = cons[byIndex[idx]]
			if not c then crash("constructionRep.get(" .. tostring(idx) .. ")") end
			return { params = copy(c.params or {}) }
		end
	end

	-- what the engine makes of a proposal: errors, collisions, cost (and the constructions to add, as plain values)
	local function evaluate(p)
		local st = getmetatable(p).store
		local adds, removes = {}, copy(st.constructionsToRemove or {})
		local data = { errorState = { critical = false, messages = {}, warnings = {} }, collisionInfo = { collisionEntities = {} },
			costs = 0 }
		for _, ce in ipairs(st.constructionsToAdd or {}) do
			local c = cons[ce.fileName]
			if not c then crash("no construction " .. tostring(ce.fileName)) end
			if type(ce.transf) ~= "table" or not ce.transf.mat4f then crash("transf is no Mat4f") end
			adds[#adds + 1] = ce
			data.costs = data.costs + (c.cost or 0)
			local hit = spec.blocked and spec.blocked(ce.transf[13], ce.transf[14])
			if hit then
				data.errorState.critical = true
				table.insert(data.errorState.messages, "Collision")
				table.insert(data.collisionInfo.collisionEntities, { entity = hit })
			end
		end
		for _, e in ipairs(removes) do
			if not g.built[e] then crash("no construction " .. tostring(e) .. " to remove") end
		end
		if data.costs > 0 and g.balance < data.costs then
			data.errorState.critical = true
			table.insert(data.errorState.messages, "Not enough money")
		end
		return data, adds, removes
	end

	g.proposalDataCalls = 0
	api.engine.util.proposal = { makeProposalData = function(p, ctx)
		g.proposalDataCalls = g.proposalDataCalls + 1
		error("bad argument #1 to 'makeProposalData' (Proposal expected, got SimpleProposal)")
	end }
	api.type.Box3 = { new = function(lo, hi) return { min = lo, max = hi } end }
	api.type.Vec3f = api.type.Vec3f or { new = function(x, y, z) return { x = x, y = y, z = z } end }
	api.engine.system = api.engine.system or {}
	-- (over an octree installed before, Track Connector's fake: what it finds is still found)
	local oldOctree = api.engine.system.octreeSystem
	api.engine.system.octreeSystem = { findIntersectingEntities = function(box, cb)
		if oldOctree then oldOctree.findIntersectingEntities(box, cb) end
		for e, b in pairs(g.built) do
			local x, y = b.transf and b.transf[13], b.transf and b.transf[14]
			if x and x >= box.min.x and x <= box.max.x and y >= box.min.y and y <= box.max.y then cb(e) end
		end
	end }

	local function apply(cmd)
		local data, adds, removes = evaluate(cmd.proposal)
		if data.errorState.critical and not cmd.ignoreErrors then return false, data, {} end
		g.balance = g.balance - data.costs
		local results = {}
		for _, e in ipairs(removes) do
			for _, edge in ipairs(g.built[e].frozenEdges) do
				local ed = g.edges[edge]
				g.nodes[ed.node0], g.nodes[ed.node1], g.edges[edge] = nil, nil, nil
			end
			g.built[e], names[e] = nil, nil
		end
		for _, ce in ipairs(adds) do
			local c, t = cons[ce.fileName], ce.transf
			g.nextEntity = g.nextEntity + 1
			local e = g.nextEntity
			local nodeIds, edgeIds = {}, {}
			local cs, sn = t[1], t[2]
			for i, n in ipairs((c.shape or {}).nodes or {}) do
				g.nextEntity = g.nextEntity + 1
				nodeIds[i] = g.nextEntity
				g.nodes[g.nextEntity] = { x = t[13] + cs * n[1] - sn * n[2], y = t[14] + sn * n[1] + cs * n[2], z = t[15] + (n[3] or 0) }
			end
			for _, ed in ipairs((c.shape or {}).edges or {}) do
				g.nextEntity = g.nextEntity + 1
				edgeIds[#edgeIds + 1] = g.nextEntity
				g.edges[g.nextEntity] = { node0 = nodeIds[ed[1]], node1 = nodeIds[ed[2]] }
			end
			local depots = {}
			for _ = 1, c.depots or 0 do g.nextEntity = g.nextEntity + 1; depots[#depots + 1] = g.nextEntity end
			local stations = {}
			for _ = 1, c.stations or 0 do
				g.nextEntity = g.nextEntity + 1
				stations[#stations + 1] = g.nextEntity
				local n = type(c.terminals) == "function" and c.terminals(ce.params) or c.terminals or 0
				g.buildStations[g.nextEntity] = { terminals = n }
			end
			g.built[e] = { fileName = ce.fileName, params = copy(ce.params), transf = copy(t), name = ce.name,
				player = ce.playerEntity, autoFillSlots = ce.autoFillSlots, frozenEdges = edgeIds, depots = depots,
				stations = stations }
			if ce.name ~= "" then names[e] = ce.name end
			results[#results + 1] = { e, 1 }
		end
		return true, data, results
	end

	local makeCmd = api.cmd.makeWorldBuildProposalCmd
	api.cmd.makeWorldBuildProposalCmd = function(p, ctx, ignoreErrors, playerInitiated)
		if type(p) ~= "userdata" then crash("makeWorldBuildProposalCmd: no proposal") end
		return { kind = "buildProposal", proposal = p, context = copy(ctx), ignoreErrors = ignoreErrors,
			playerInitiated = playerInitiated }
	end
	local send = api.cmd.sendCommand
	api.cmd.sendCommand = function(cmd, cb)
		if type(cmd) ~= "table" or cmd.kind ~= "buildProposal" then return send(cmd, cb) end
		if spec.sendRaises then error("sendCommand: " .. spec.sendRaises) end
		g.commands[#g.commands + 1] = cmd
		g.buildCmds[#g.buildCmds + 1] = cmd
		local ok, data, results = apply(cmd)
		if cb and not spec.lostCallback then
			local d = { resultProposalData = data, resultEntities = {} }
			if spec.raiseInCallback then d = setmetatable({}, { __index = function() error("engine data gone") end }) end
			cb(d, ok, results)
		end
	end
	local getComponent = api.engine.getComponent
	api.engine.getComponent = function(e, kind)
		if kind == "CONSTRUCTION" and g.built[e] then
			local b = g.built[e]
			local pn = copy(b.params)
			return { fileName = b.fileName, params = copy(b.params), params_native = { asTable = function() return copy(pn) end },
				transf = copy(b.transf), frozenEdges = copy(b.frozenEdges),
				depots = copy(b.depots), stations = copy(b.stations or {}), industries = {} }
		end
		if kind == "STATION" and g.buildStations[e] then
			local t = {}
			for i = 1, g.buildStations[e].terminals do t[i] = { tag = i } end
			return { terminals = t }
		end
		if kind == "TERRAIN" and e == 1 and spec.waterLevel ~= nil then return { waterLevel = spec.waterLevel } end
		if kind == "BASE_EDGE" and g.edges[e] then return copy(g.edges[e]) end
		if kind == "BASE_NODE" and g.nodes[e] then return { position = copy(g.nodes[e]) } end
		return getComponent(e, kind)
	end
	local getName = api.engine.util.getEntityName
	api.engine.util.getEntityName = function(e)
		if names[e] then return names[e] end
		return getName(e)
	end
	g.buildNames = names
	return makeCmd
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
	-- modhub (4th argument): My Mods with one staging mod validate takes and one it refuses
	-- (the force unload one uploads as mod.io mod 7000001 and leaves its fileid under <dir>/staging_area, where
	-- tf3ctl looks next to the exchange folder)
	local modhub = arg[4] == "modhub" and { fileidDir = dir .. "/staging_area", staging = {
		{ folder = "hummer_force_unload_default_1", title = "Force Unload by Default", validateUpdates = 20,
			result = { messages = { { level = "Warning", file = "content/x.lua", message = "a warning" } },
				levelPc = "Warning", levelConsole = "Warning" } },
		{ folder = "example_mod_1", title = "Example" },
	} } or nil
	local g = M.new(dir, { saves = saves, maxSpeed = 40, menu = arg[3] == "menu", modhub = modhub,
		entities = { TOWN = { 11, 12 }, LINE = { 21 } }, names = { [11] = "Emsworth", [12] = "Emsworth Bay", [21] = "Bus 1" },
		positions = { [11] = { 0, 0 } },
		industries = { [51] = { name = "Coal mine", construction = 5100, capacity = 12, workers = 5, productivity = 1, pos = { 300, 0 },
			stocks = { { type = 1, cargoType = 1, capacity = 400, count = 37 } },
			rules = { { input = { { 0 } }, output = { [1] = 2 }, capacity = 100 } } } },
		constructionComps = { [5100] = { fileName = "industry/coal_mine.con",
			params = { hummer_aom_upg_pollution = "", hummer_aom_upg_boost = 2, year = 1900 } } },
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
	-- build: one ramp the rep knows (two road pieces, its far end 80 m out and 8 m up)
	-- and a modular harbour whose terminals are its modules on whole-number slots; water east of x = 1000, level 5
	M.installBuild(g, { height = function(x) return x >= 1000 and -3 or x / 100 end, cons = {
		["road_bridge_ramp::/road_bridge_ramp/ramp.con"] = { cost = 5000,
			params = { { key = "rbr_height", numbers = { 2, 4, 8 }, defaultIndex = 3 } },
			shape = { nodes = { { 0, 0, 0 }, { 40, 0, 4 }, { 80, 0, 8 } }, edges = { { 1, 2 }, { 2, 3 } } } },
		["::/stations/water/harbor_modular.con"] = { cost = 30000, stations = 1, terminals = function(params)
			local n = 0
			for k in pairs(params.modules or {}) do if type(k) == "number" then n = n + 1 end end
			return n
		end } },
		modules = { ["::/station/water/harbor_quay.module"] = { metadata = { quay = true } } },
		water = function(x) return x >= 1000 end, waterLevel = 5 })
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
