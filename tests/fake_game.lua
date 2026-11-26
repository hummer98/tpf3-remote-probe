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

-- other mods' remote_probe_ext.lua (remote_modext.lua): M.extMods[modId] = the file's text, { file = path }, or a
-- table to hand out as it is; a mod not listed has no such file. A text that does not compile fails the require
-- with the compiler's message, as a broken file would.
M.extMods = {}
table.insert(package.loaders or package.searchers, 2, function(name)
	local modId = name:match("^([^:]+)::/remote_probe_ext%.lua$")
	if not modId or modId == "hummer_remote_probe" then return nil end
	local src = M.extMods[modId]
	if src == nil then return "\n\tno file " .. name .. " (fake: the mod ships none)" end
	if type(src) == "table" and src.file then
		local fn, err = loadfile(src.file)
		if not fn then error("error loading module '" .. name .. "':\n\t" .. tostring(err), 0) end
		return fn
	end
	if type(src) == "string" then
		local fn, err = loadstring(src, "=" .. name)
		if not fn then error("error loading module '" .. name .. "':\n\t" .. tostring(err), 0) end
		return fn
	end
	return function() return src end
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

M.object, M.vector = object, vector

-- a bound engine function as the game has it: a table with __call, not a function, whose getmetatable gives false
-- (api.engine.getComponent, forEachEntityWithComponent, ...: type "table" in the game's GUI Lua, 2026-11-26).
-- Without it, code that takes them for functions (or views them as plain tables) passes here and fails in the game.
function M.callable(fn)
	return setmetatable({}, { __call = function(_, ...) return fn(...) end, __metatable = false })
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
	-- PublishSettings: its fields can be set, as the engine's; a field it does not have is an error. updateMetadata
	-- starts true (the engine's start value is not documented): an update that sends false must set it
	local SETTINGS = { changeLog = "", updateMetadata = true, setPublic = false, isSavegame = false,
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
		started = {}, menu = opts.menu == true, mapEditor = opts.mapEditor == true,
		-- the calendar slider's value (GAME_SPEED.millisPerDay), apart from the simulation's speedup as in the game;
		-- opts.millisPerDay to start elsewhere. The fake's dates do not follow it (dateOf counts DAY_TICKS)
		millisPerDay = opts.millisPerDay or DAY_TICKS }
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
	local multipleUnits = opts.multipleUnits or {}
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
	g.industries = industries -- (installDebug sets their stocks)
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
			if s.forceUnload ~= nil then cfg.forceUnload = s.forceUnload end
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
			-- a forceUnload that is no boolean (StopConfig.forceUnload : boolean, engine.d.tl): what the engine does
			-- with one is not known, so the fake takes the worse
			if type(cfg.forceUnload) ~= "boolean" then
				g.crashed = "ASSERT: stop config of line stop " .. i .. " has forceUnload " .. tostring(cfg.forceUnload)
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
			-- the groups (TransportVehicleConfig, type.d.tl: "The sum of all entries must be the total of vehicles"),
			-- a multiple unit's group as its file lists it, and muFileNames empty (a single model, as the store sends
			-- it) or one per group: what the engine does with a mismatch is not known, the fake takes the worse
			local groups, names, sum = cmd.config.vehicleGroups or {}, cmd.config.muFileNames or {}, 0
			for _, n in ipairs(groups) do
				if n < 1 then g.crashed = "Assertion: a vehicle group of " .. tostring(n); error(g.crashed) end
				sum = sum + n
			end
			if sum ~= #cmd.config.vehicles then
				g.crashed = string.format("Assertion: vehicleGroups sum to %d for %d vehicles", sum, #cmd.config.vehicles)
				error(g.crashed)
			end
			if #names ~= 0 and #names ~= #groups then
				g.crashed = string.format("Assertion: %d muFileNames for %d vehicleGroups", #names, #groups)
				error(g.crashed)
			end
			local first = 1
			for i, n in ipairs(groups) do
				local fileName = names[i]
				if fileName and fileName ~= "" then
					local mu
					for _, m in pairs(multipleUnits) do if m.fileName == fileName then mu = m end end
					if not mu or #mu.vehicles ~= n then
						g.crashed = "Assertion: group " .. i .. " is not multiple unit " .. tostring(fileName)
						error(g.crashed)
					end
					for k, v in ipairs(mu.vehicles) do
						local p = cmd.config.vehicles[first + k - 1]
						local m = models[p.part.modelId]
						if not m or m.name:match("([^/]+)$") ~= v.name:match("([^/]+)$") or p.part.reversed ~= (v.forward ~= true) then
							g.crashed = string.format("Assertion: part %d is not car %d of %s", first + k - 1, k, fileName)
							error(g.crashed)
						end
					end
				end
				first = first + n
			end
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
		-- opts.installed: the mods installed (getInstalledMods, as ModIds with a name)
		getUserProfile = function() return { getModRep = function() return { getModDesc = function(_, id)
			local d = (opts.modDescs or { [""] = { { key = "guideSystemConfig.tutorial", defaultIndex = 1 } } })[id.name]
			return d and { params = d } or nil
		end, getInstalledMods = function()
			local out = {}
			for i, n in ipairs(opts.installed or {}) do out[i] = { name = n } end
			return out
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
			getDefaultYearDuration = function() return 365 * DAY_TICKS end,
			-- opts.noDefaultDay: the function is missing (a factor cannot be turned into millisPerDay then)
			getDefaultDayDuration = (not opts.noDefaultDay) and function() return DAY_TICKS end or nil },
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
					-- an entry's third value: its maintenance type (the 5th argument keeps only those)
					calculateBalance = function(list, from, to, maintenanceIncomeOnly, maintenanceType)
						g.balanceAsked = { list = copy(list), from = from, to = to, only = maintenanceIncomeOnly,
							maintenanceType = maintenanceType }
						if opts.balanceRaises then error("std::exception") end
						local sum = 0
						for _, e in ipairs(list) do
							for _, j in ipairs((opts.vehicleBalances or {})[e] or {}) do
								if j[1] >= from and j[1] <= to and (maintenanceType == nil or j[3] == maintenanceType) then
									sum = sum + j[2]
								end
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
				townBuildingSystem = { getTown2personCapacitiesMap = function() return copy(opts.townCapacities or {}) end,
					getPersonCapacity2townBuildingMap = function()
						local m = {}
						for b, t in pairs(opts.townBuildings or {}) do m[t.personCapacity or b] = b end
						return m
					end,
					getTown2BuildingMap = function()
						g.town2BuildingAsked = (g.town2BuildingAsked or 0) + 1
						local m = {}
						for b, t in pairs(opts.townBuildings or {}) do
							local town = t.town or -1
							m[town] = m[town] or {}
							table.insert(m[town], b)
						end
						return m
					end },
				-- opts.catchables = { [station] = { passengers = { entities }, cargo = { entities } } }; a station the
				-- engine does not have: its assertion
				catchmentAreaSystem = { getStationCatchables = function(st, cargo)
					if not stationOf[st] then g.crashed = "ASSERT: no station " .. tostring(st); error(g.crashed) end
					local c = (opts.catchables or {})[st] or {}
					return copy((cargo and c.cargo) or (not cargo and c.passengers) or {})
				end },
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
				return g.lines[e] ~= nil or g.fleet[e] ~= nil or groups[e] ~= nil or industries[e] ~= nil or depots[e] ~= nil
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
				-- town buildings (stations --catchment): opts.townBuildings = { [building] = { town, kind = "RESIDENTIAL",
				-- capacity, personCapacity (its PersonCapacity entity, default the building), stockList } }
				local tb = (opts.townBuildings or {})[e]
				if kind == "TOWN_BUILDING" and tb then
					return { town = tb.town or -1, personCapacity = tb.personCapacity or e, stockList = tb.stockList or -1 }
				end
				if kind == "PERSON_CAPACITY" and tb then
					return { type = api.type.enum.LandUseType[tb.kind or "RESIDENTIAL"], capacity = tb.capacity or 0 }
				end
				if kind == "INDUSTRY" and industries[e] then
					return { stockList = industries[e].stockList or -1, construction = industries[e].construction or -1 }
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
				if kind == "GAME_SPEED" then return { speedup = g.speedup, millisPerDay = g.millisPerDay } end
			end,
			config = { getModParams = function() inGame("getModParams"); return g.modParams end },
		},
		type = {
			-- a clock that moves within a frame (getApplicationTime stays the same all through one, as the game's):
			-- each getTime moves it on by g.clockStepUs (0 unless a test sets it), from g.time when made
			Clock = { new = function()
				local t0 = (g.time or 0) * 1e6
				local us = 0
				return { getTime = function(self)
					us = us + (g.clockStepUs or 0)
					return math.floor((g.time or 0) * 1e6 - t0 + us)
				end }
			end },
			enum = { Carrier = { ROAD = 0, RAIL = 1, TRAM = 2, AIR = 3, WATER = 4, OTHER = 5 },
				TransportMode = { PERSON = 0, CARGO = 1, CAR = 2, BUS = 3, TRUCK = 4, TRAM = 5, ELECTRIC_TRAM = 6, TRAIN = 7,
					ELECTRIC_TRAIN = 8, AIRCRAFT = 9, SHIP = 10, SMALL_AIRCRAFT = 11, SMALL_SHIP = 12, HELICOPTER = 13,
					TRAM_TRACK = 14, ELECTRIC_TRAM_TRACK = 15 },
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
				STATION_GROUP = "STATION_GROUP", INDUSTRY = "INDUSTRY", TOWN_BUILDING = "TOWN_BUILDING", NAME = "NAME", STATION = "STATION", LINE = "LINE",
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
			-- the engine's command data holds an int (CmdData::GameSetCalendarSpeed): a non-integer raises
			makeGameSetCalendarSpeedCmd = function(n)
				if opts.calendarCmdFails then error("makeGameSetCalendarSpeedCmd: refused") end
				if type(n) ~= "number" or n ~= math.floor(n) then error("makeGameSetCalendarSpeedCmd: integer expected, got " .. tostring(n)) end
				return { kind = "calendarSpeed", millisPerDay = n }
			end,
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
					-- opts.calendarStuck: accepted, but the component keeps its value
					if cmd.kind == "calendarSpeed" then
						if not opts.calendarStuck then g.millisPerDay = cmd.millisPerDay end
						return true
					end
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
		}, multipleUnitRep = {
			-- opts.multipleUnits = { [id] = { fileName, name, vehicles = { { name, forward } } } } (a .mu.lua as loaded);
			-- broken = true: get raises, as for a file that did not load
			-- mu.invisible: only getAll(true) lists it; opts.muGetAllNoNames: getAll's values are no names (true),
			-- so only getName tells them; opts.muNoGetName: getName gives nothing
			getAll = function(includeInvisible)
				local out = {}
				for id, mu in pairs(multipleUnits) do
					if includeInvisible == true or not mu.invisible then
						out[id] = opts.muGetAllNoNames and true or mu.fileName
					end
				end
				return out
			end,
			getName = function(id)
				if opts.muNoGetName then return nil end
				return multipleUnits[id] and multipleUnits[id].fileName
			end,
			get = function(id)
				local mu = multipleUnits[id]
				if mu and mu.broken then error("multiple unit " .. tostring(id) .. " did not load") end
				return mu and copy(mu) or nil
			end,
		}, modelRep = {
			getAll = function()
				local out = {}
				for id, m in pairs(models) do out[id] = m.name end
				return out
			end,
			getName = function(id) return models[id] and models[id].name end,
			-- by resource name, as a .mu.lua names its cars ("x_front.mdl", the folder left out): the full name or the
			-- file name; -1 when there is none (what the engine gives is not known; the probe takes nil and < 0 alike)
			find = function(name)
				name = tostring(name)
				for id, m in pairs(models) do if m.name == name then return id end end
				for id, m in pairs(models) do if m.name:match("([^/]+)$") == name then return id end end
				return -1
			end,
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
			focusPosition = function(p, d) g.cam.x, g.cam.y, g.cam.z, g.cam.distance = p.x, p.y, p.z, d; g.focusedAt = p end,
			getHeightAboveTerrain = function() return g.cam.distance * 0.5 end,
			-- free camera: the eye is the centre (its height from focusPosition, else 0) moved out by distance along
			-- angle and pitch (remote_core.eyeLookTarget's way: which way the game turns them is not known)
			getEye = function()
				inGame("getEye")
				local c = g.cam
				local cp = math.cos(c.pitch or 0)
				return { x = c.x + c.distance * cp * math.cos(c.angle or 0), y = c.y + c.distance * cp * math.sin(c.angle or 0),
					z = (c.z or 0) + c.distance * math.sin(c.pitch or 0) }
			end,
			getCenter = function() inGame("getCenter"); return { x = g.cam.x, y = g.cam.y, z = g.cam.z or 0 } end,
			toggleFreeCamera = function()
				inGame("toggleFreeCamera")
				g.freeCam = not g.freeCam
				g.freeCamToggles = (g.freeCamToggles or 0) + 1
			end,
			isFreeCameraMouseAttached = function() inGame("isFreeCameraMouseAttached"); return g.freeCamMouse == true end,
			toggleFreeCameraMouseAttachment = function()
				inGame("toggleFreeCameraMouseAttachment")
				g.freeCamMouse = not g.freeCamMouse
			end,
			-- the cockpit (free_cam_options.FreeCamTool's push / pop): an entity that is not there brings the game
			-- down, as an engine assertion would (what the game does with one is not known; the mod must not send it)
			enterFollowCameraCockpit = function(e)
				inGame("enterFollowCameraCockpit")
				if not api.engine.entityExists(e) then
					g.crashed = "ASSERT: enterFollowCameraCockpit of no entity " .. tostring(e)
					error(g.crashed)
				end
				g.cockpit, g.cockpitEnters = e, (g.cockpitEnters or 0) + 1
			end,
			leaveFollowCameraCockpit = function()
				inGame("leaveFollowCameraCockpit")
				g.cockpit, g.cockpitLeaves = nil, (g.cockpitLeaves or 0) + 1
			end,
			-- { entity, revision }: the cockpit's vehicle, -1 when none
			getFollowEntity = function() inGame("getFollowEntity"); return { g.cockpit or -1, 0 } end,
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
			-- the map editor: a game started with isMapEditor (or opts.mapEditor)
			isMapEditor = function() inGame("isMapEditor"); return g.mapEditor == true end,
		} },
	}
	-- the engine's bound functions are tables with __call (M.callable). forEachEntityWithComponent(fn, kind) calls
	-- fn(entity, component) for the lines and vehicles here; like the binding, a callback that is no function and a
	-- kind that is no component type (a table) are errors
	api.engine.getComponent = M.callable(api.engine.getComponent)
	api.engine.entityExists = M.callable(api.engine.entityExists)
	api.engine.forEachEntityWithComponent = M.callable(function(fn, kind)
		inGame("forEachEntityWithComponent")
		if type(fn) ~= "function" then error("bad argument #1 to 'forEachEntityWithComponent' (function expected, got " .. type(fn) .. ")") end
		if type(kind) == "table" then error("bad argument #2 to 'forEachEntityWithComponent' (ComponentType expected, got table)") end
		local of = ({ LINE = g.lines, TRANSPORT_VEHICLE = g.fleet })[kind] or {}
		local ids = {}
		for e in pairs(of) do ids[#ids + 1] = e end
		table.sort(ids)
		for _, e in ipairs(ids) do fn(e, api.engine.getComponent(e, kind)) end
	end)
	if opts.modhub then M.installModhub(g, opts.modhub == true and {} or opts.modhub) end

	-- the base's vehicle_react_util.HandleVehicleChanges, as in 40444 (stamp, autoload, then the engine command);
	-- opts.noGuiModule: it does not load. opts.vehicleUtil: vehicle_util.tl loads too (else the probe builds parts)
	M.guiModules = {}
	-- the base's difficulty_util.tl getScale, as in 40444 (only the three new-game densities): 1.0 outside the
	-- range, and like the real one it errors on a nil level. opts.noDifficultyUtil: it does not load (as when the
	-- probe looked it up with a missing require, 2026-11-22); opts.difficultyUtil: this module instead
	if opts.difficultyUtil then
		M.guiModules["/base/difficulty_util.tl"] = opts.difficultyUtil
	elseif not opts.noDifficultyUtil then
		local scales = {
			["locations.towns.frequency"] = { 0.2, 0.3, 0.4, 0.65, 1.0 },
			["locations.towns.populationDensity"] = { 0.5, 0.75, 1.0, 1.5, 2.0 },
			["locations.industry.initialIndustryDensity"] = { 2 / 3, 5 / 6, 1.0, 6 / 5, 3 / 2 },
		}
		M.guiModules["/base/difficulty_util.tl"] = { getScale = function(key, level)
			local s = scales[key]
			if s == nil then return 1.0 end
			if #s < level or level < 1 then return 1.0 end
			return s[level]
		end }
	end
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
					-- a copy of the engine's StopConfig, as the base (api.type.Line.StopConfig.new(v.stopConfig))
					alternativeTerminals = s.alternativeTerminals, passThroughStopData = { stopConfig = api.type.Line.StopConfig.new(s.stopConfig),
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
		package.loaded["/base/difficulty_util.tl"] = nil
		package.loaded["/gui/line_vehicle_mgmt/vehicle_react_util.tl"] = nil
		package.loaded["/gui/line_vehicle_mgmt/line_util.tl"] = nil
		package.loaded["hummer_remote_probe::/remote_lines.lua"] = nil
		package.loaded["hummer_remote_probe::/remote_connect.lua"] = nil
		package.loaded["hummer_remote_probe::/line_configs.lua"] = nil
		package.loaded["/gui/line_vehicle_mgmt/vehicle_util.tl"] = nil
		package.loaded["hummer_remote_probe::/remote_vehicles.lua"] = nil
		package.loaded["hummer_remote_probe::/vehicle_configs.lua"] = nil
		package.loaded["hummer_remote_probe::/remote_core.lua"] = nil
		package.loaded["hummer_remote_probe::/remote_debug.lua"] = nil
		package.loaded["hummer_remote_probe::/remote_town_grow.lua"] = nil
		package.loaded["hummer_remote_probe::/remote_company.lua"] = nil
		package.loaded["hummer_remote_probe::/remote_town_connect.lua"] = nil
		package.loaded["hummer_remote_probe::/remote_parcels.lua"] = nil
		package.loaded["hummer_remote_probe::/remote_runcost.lua"] = nil
		package.loaded["hummer_remote_probe::/remote_reach.lua"] = nil
		package.loaded["hummer_remote_probe::/remote_modext.lua"] = nil
		package.loaded["hummer_remote_probe::/remote_eval.lua"] = nil
		for k in pairs(package.loaded) do
			if type(k) == "string" and k:match("::/remote_probe_ext%.lua$") then package.loaded[k] = nil end
		end
		M.extMods = opts.extMods or {}
		package.loaded["hummer_remote_probe::/remote.script.lua"] = nil
		-- M.coreSetup(core): a test run's changes to this game's own copy of remote_core.lua (its fallbacks for what
		-- tf3ctl's configuration sends)
		if M.coreSetup then M.coreSetup(require("hummer_remote_probe::/remote_core.lua")) end
		-- opts.modhub.firstUploadOf: a folder the tests upload as new although the mod holds it to a mod.io page
		-- (MODHUB_PUBLISHED_IDS), taken out of that table in this game's own copy of remote_core.lua
		if type(opts.modhub) == "table" and opts.modhub.firstUploadOf then
			require("hummer_remote_probe::/remote_core.lua").MODHUB_PUBLISHED_IDS[opts.modhub.firstUploadOf] = nil
		end
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
			g.mapEditor = p.isMapEditor == true
			g.gameTime = ((p.startDate.year - 1900) * 365) * DAY_TICKS
			g.time = g.time + 5
			g.menu = false
			if g.onStart then g.onStart(p) end
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
		-- (g.gsReadOnly: the probe's game script state, as the engine hands guiUpdate; installRunningCosts sets it)
		if g.script then g.script.guiUpdate(nil, g.gsReadOnly) end
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
-- spec.sendRaises: sendCommand raises (this text). A cons entry's scriptFails / otherResult: the engine says
-- success and builds nothing (no entities / only one that is no construction), as a failing update script does;
-- notInResult: built, but left out of the result's entities.
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
-- and makeProposalData takes a SimpleProposal alone or with a Context (Overpass Builder's notes: build 40408 takes a
-- SimpleProposal on the GUI thread, though engine/util.d.tl:939 types it for a Proposal) and gives what a build's
-- callback would, building nothing (g.proposalDataCalls); spec.noSimpleProposalData: it raises for a SimpleProposal
-- (as bus_loops' notes say it does); spec.proposalDataOneArg: it raises when a Context is given too;
-- spec.proposalDataTwoArgs: it raises without a Context.
-- spec.landOnly(x, y) -> true: a construction there is refused ("陸上に配置", the game's word for "place on land":
-- 2026-11-23, a construction at the map's edge over water) by the build and by makeProposalData with a Context, never
-- by makeProposalData alone (the engine's own context said buildable there); spec.landOnlyBuildOnly: by the build
-- alone. spec.silentCallback: the build's callback carries critical but no messages, warnings or infos (as the
-- refusal on water came back, the reason only in the log); spec.noErrorState: its ProposalData has no errorState;
-- spec.infosOnly: its reason is in errorState.infos, messages empty. spec.landOnlyOwnOnly: the other way round, only
-- makeProposalData alone refuses it (the stricter of a dry run's two verdicts). spec.landInfos(x, y) -> true: the
-- engine's word for it goes in errorState.infos only, critical false, in every context (makeProposalData alone or
-- with a Context, and the build's callback), and the build is refused all the same (2026-11-23: road_depot at
-- (0, 3600) over water: the engine check said critical false, infos "陸上に配置", collisions 6; the build was refused,
-- its errorState critical false with the same infos, the log "ProposalData error: 陸上に配置");
-- spec.landInfosBuildOnly: not in makeProposalData alone (the engine's own context); spec.landInfosOwnOnly: only there
-- spec.softBlocked(x, y): a road piece's collision named with critical false: refused without ignoreErrors, built
-- with it; spec.ignoreCritical: ignoreErrors builds past a critical error too (the API says it does not);
-- spec.softBlockedCon(x, y): the same for a construction at its point (2026-11-26: a road depot over a road's node
-- and a new piece, the check critical false with messages "衝突" and the build refused for it)
-- The octree finds the constructions in g.built by their transf's position.
-- A construction's shape may have free pieces (shape.free = { { i, j } }: an industry's arms, street_cross_01 / 02,
-- not among its frozenEdges) and frozen nodes (shape.frozenNodes = { i }: CONSTRUCTION.frozenNodes, the inner end
-- of a stub). streetConnectorSystem.getConstructionEntityForNode gives the construction for the nodes of its frozen
-- pieces (the mouth too) and -1 for the far ends of free pieces (spec.armEndsOwned: those too); spec.noNodeOwner:
-- it is not there (the probe goes through getConstructionEntityForEdge: the construction for its frozen pieces, -1
-- for its free ones). A construction's nodes have a set-up with no lane connections (a bus terminal's mouth read so
-- in a game, 2026-11-26); one that is not frozen takes a set-up removed and added as a town node does (a guess: not
-- checked in a game yet). Like the engine (a guess from Overpass Builder's refusal): a frozen node's set-up removed
-- or added is an assertion; a piece to a frozen node, or a new node on an old node (within 0.01 m), is refused
-- (Construction not possible).
function M.installBuild(g, spec)
	spec = spec or {}
	local cons = spec.cons or {}
	g.built, g.buildCmds, g.nodes, g.edges = {}, {}, {}, {}
	local names = {}
	local CT = api.type.ComponentType
	CT.BASE_NODE, CT.BASE_EDGE, CT.CONSTRUCTION = "BASE_NODE", "BASE_EDGE", "CONSTRUCTION"
	CT.BASE_NODE_CONFIG = not spec.noNodeConfigType and "BASE_NODE_CONFIG" or nil
	CT.STATION, CT.TERRAIN = CT.STATION or "STATION", CT.TERRAIN or "TERRAIN"
	g.buildStations, g.buildWarehouses, g.buildStockLists = {}, {}, {}
	CT.WAREHOUSE = CT.WAREHOUSE or "WAREHOUSE"
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
		-- streetProposal: a record of its own, reached through the proposal (its lists assigned whole, as above)
		return record({ constructionsToAdd = {}, constructionsToRemove = {}, old2new = {},
			streetProposal = record({ nodesToAdd = {}, edgesToAdd = {}, nodesToRemove = {}, edgesToRemove = {},
				nodeConfigsToAdd = {}, nodeConfigsToRemove = {} }) })
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

	-- roads (the road command): spec.streets = { [resName] = { roadType = "STREET" / "TRACK", yearFrom, yearTo, cost
	-- (per metre), style, noLanes, modesUnread, perSide (2: two road lanes each way) } } (streetTemplateRep); spec.year (api.engine.util.getYear); spec.roads = {
	-- nodes = { [id] = { x, y, z } }, edges = { [id] = { node0, node1[, tangent0, tangent1 = { x, y, z }] } } }: a road network already there;
	-- spec.noStreetResults: the callback names no entity of a built road. A street proposal whose piece names a
	-- node that neither exists nor is added, or a template the rep does not know, is an assertion; a piece without
	-- lanes is refused. g.streetCmds: every piece sent, as plain values.
	-- Junction set-ups (BASE_NODE_CONFIG): the network's nodes have one, but those in spec.roads.noConfig; a node a
	-- street proposal adds has one only when its nodeConfigsToAdd names it (a script's road has none, as in the
	-- game); a construction's own nodes have one (the engine adds them: "Added node config" in its proposal's log).
	-- A piece joined to a node without one that already has two pieces is an assertion (2026-11-23 in the game:
	-- Engine.h:322 GetComponentDataIndex, BaseNodeConfig; the two-piece condition is a guess from that one crash,
	-- and the game died in the simulation after applying, the fake dies on sending, refused or not; that a
	-- script's nodes have none is from Track Connector's notes, not read in a game). spec.nodeConfigRaises: reading one raises;
	-- spec.noNodeConfigType: no BASE_NODE_CONFIG component type.
	local streets = spec.streets or {}
	-- a town road's lanes, left to right from node0 to node1: a sidewalk, a road lane each way, a sidewalk (the
	-- network's pieces have them too, unless they name their own)
	-- (the game's TransportMode enum: the base fake's, else these)
	api.type.enum.TransportMode = api.type.enum.TransportMode or { PERSON = 0, CARGO = 1, CAR = 2, BUS = 3, TRUCK = 4, TRAM = 5, ELECTRIC_TRAM = 6 }
	local function townLanes(unread, perSide)
		local TM = api.type.enum.TransportMode
		local function road(fwd) return { speed = 14, width = 3, forward = fwd, transportModes = { [TM.CAR] = true, [TM.BUS] = true, [TM.TRUCK] = true } } end
		local function walk(fwd) return { speed = 1.5, width = 2, forward = fwd, transportModes = { [TM.PERSON] = true } } end
		local lanes = { walk(true), road(false), road(true), walk(false) }
		-- (perSide 2: two road lanes each way)
		if perSide == 2 then lanes = { walk(true), road(false), road(false), road(true), road(true), walk(false) } end
		-- (perSide "oneWay": two road lanes, both node0 -> node1, as a one-way road)
		if perSide == "oneWay" then lanes = { walk(true), road(true), road(true), walk(false) } end
		-- (unread: modes that are no map, so that they cannot be read)
		if unread then for _, l in ipairs(lanes) do l.transportModes = "?" end end
		return lanes
	end
	g.townLanes = townLanes
	api.type.LaneConnection = { new = function() return { segment0 = -1, lane0 = 0, segment1 = -1, lane1 = 0, withRoad = false, withTram = false } end }
	api.type.BaseNodeLaneConnectionAndEntity = { new = function()
		return { entity = 0, comp = { laneConnections = {}, crosswalks = {}, doubleSlipSwitch = false } }
	end }
	local streetNames = {}
	for name in pairs(streets) do streetNames[#streetNames + 1] = name end
	table.sort(streetNames)
	api.type.enum.RoadType = { STREET = 0, TRACK = 1 }
	api.type.enum.BaseEdgeType = { NORMAL = 0, BRIDGE = 1, TUNNEL = 2 }
	api.type.NodeAndEntity = { new = function() return { entity = 0, comp = { position = { x = 0, y = 0, z = 0 } } } end }
	api.type.SegmentAndEntity = { new = function()
		return { entity = 0, type = -1, comp = { node0 = -1, node1 = -1, type = 0, typeIndex = -1, laneConfigs = {} },
			streetEdge = {} }
	end }
	api.type.PlayerOwned = { new = function() return { player = -1 } end }
	api.res.streetTemplateRep = {
		find = function(name) for i, n in ipairs(streetNames) do if n == name then return i end end return -1 end,
		get = function(idx)
			local name = streetNames[idx]
			if not name then crash("streetTemplateRep.get(" .. tostring(idx) .. ")") end
			local s = streets[name]
			local RT = api.type.enum.RoadType
			return { roadType = RT and RT[s.roadType or "STREET"] or nil, streetStyle = s.style or (name .. ".style"),
				availability = { yearFrom = s.yearFrom or 0, yearTo = s.yearTo or 0 }, cost = s.cost or 10,
				laneConfigs = s.noLanes and {} or townLanes(s.modesUnread, s.perSide),
				-- (a track's: the base tracks' 5 m and 55 m, standard.lua; spec.streets[name].trackDistance /
				-- minCurveRadius set them, noTrackDistance leaves it out)
				trackDistance = s.roadType == "TRACK" and not s.noTrackDistance and (s.trackDistance or 5) or nil,
				minCurveRadiusBuild = s.roadType == "TRACK" and (s.minCurveRadius or 55) or nil }
		end,
	}
	-- bridge types (road --bridge): spec.bridges = { [resName] = { carriers = { "ROAD", ... }, yearFrom, yearTo,
	-- noCarriers (none to read) } }; by default the base's concrete (rail and road) and a rail-only one, and the pier
	-- spike's pillarless type. getAll gives { [id] = name } as the game's (res.d.tl)
	local bridges = spec.bridges or {
		["::/infrastructure/bridge/concrete.bridge"] = { carriers = { "RAIL", "ROAD" } },
		["::/infrastructure/bridge/rail_only.bridge"] = { carriers = { "RAIL" } },
		["hummer_pier_spike::/infrastructure/bridge/hps_pillarless.bridge"] = { carriers = { "RAIL", "ROAD" } },
	}
	local bridgeNames = {}
	for name in pairs(bridges) do bridgeNames[#bridgeNames + 1] = name end
	table.sort(bridgeNames)
	g.bridgeNames = bridgeNames
	-- (ids from 10, so that a bridge id is never taken for a street template's)
	api.res.bridgeTypeRep = {
		find = function(name) for i, n in ipairs(bridgeNames) do if n == name then return 9 + i end end return -1 end,
		get = function(idx)
			local name = bridgeNames[idx - 9]
			if not name then crash("bridgeTypeRep.get(" .. tostring(idx) .. ")") end
			local b = bridges[name]
			local cs
			if not b.noCarriers then
				cs = {}
				for _, k in ipairs(b.carriers or {}) do cs[#cs + 1] = api.type.enum.Carrier[k] end
			end
			return { carriers = cs, availability = { yearFrom = b.yearFrom or 0, yearTo = b.yearTo or 0 } }
		end,
		getAll = function() local out = {} for i, n in ipairs(bridgeNames) do out[9 + i] = n end return out end,
	}
	-- tunnel types (track --tunnel): spec.tunnels = { [resName] = { carriers, yearFrom, yearTo, noCarriers } }, as the
	-- bridges; by default the base's rail tunnel and its road one (res/config: tunnel_a carries RAIL, tunnel_a_car
	-- ROAD). Ids from 30, so that one is never taken for a bridge's or a template's. tunnelTypeRep is a ResTypeRep of
	-- BridgeType (res.d.tl)
	local tunnels = spec.tunnels or {
		["::/infrastructure/tunnel/tunnel_a.tunnel"] = { carriers = { "RAIL" } },
		["::/infrastructure/tunnel/tunnel_a_car.tunnel"] = { carriers = { "ROAD" } },
	}
	local tunnelNames = {}
	for name in pairs(tunnels) do tunnelNames[#tunnelNames + 1] = name end
	table.sort(tunnelNames)
	g.tunnelNames = tunnelNames
	api.res.tunnelTypeRep = {
		find = function(name) for i, n in ipairs(tunnelNames) do if n == name then return 29 + i end end return -1 end,
		get = function(idx)
			local name = tunnelNames[idx - 29]
			if not name then crash("tunnelTypeRep.get(" .. tostring(idx) .. ")") end
			local t = tunnels[name]
			local cs
			if not t.noCarriers then
				cs = {}
				for _, k in ipairs(t.carriers or {}) do cs[#cs + 1] = api.type.enum.Carrier[k] end
			end
			return { carriers = cs, availability = { yearFrom = t.yearFrom or 0, yearTo = t.yearTo or 0 } }
		end,
		getAll = function() local out = {} for i, n in ipairs(tunnelNames) do out[29 + i] = n end return out end,
	}
	api.engine.util.getYear = function() return spec.year end
	g.streetCmds = {}
	for id, n in pairs((spec.roads or {}).nodes or {}) do g.nodes[id] = copy(n) end
	for id, e in pairs((spec.roads or {}).edges or {}) do g.edges[id] = copy(e) end
	g.nodeConfig, g.nodeConns = {}, {}
	for id in pairs(g.nodes) do g.nodeConfig[id] = not ((spec.roads or {}).noConfig or {})[id] end
	-- spec.roads.conns = { [node] = { connections } }: a set-up's own connections; spec.roads.lights = { [node] =
	-- true }: a set-up with traffic light states
	for id, cs in pairs((spec.roads or {}).conns or {}) do g.nodeConns[id] = copy(cs) end
	local lights = (spec.roads or {}).lights or {}
	-- traffic lights (lights --off): the set-up's trafficLightPreference (type.d.tl TrafficLightPreference; the
	-- numbers are the fake's own, the game's are not read), YES where spec.roads.lights names the node, else AUTO;
	-- spec.roads.lightPrefs = { [node] = "NO" / "YES" / "AUTO" } sets one. createTrafficLightProposal (engine/util.d.tl)
	-- asserts, as the engine might (a guess), on a node without a set-up, a config that is not one (the window
	-- sends a clone of the set-up's), or a preference that is none of the enum's. Applied, the node takes the
	-- preference and the config's phases as sent (the window's None keeps the phases; its Reset to Default sends
	-- none): NO alone leaves them, so road still refuses it.
	-- g.lightCmds: every traffic light proposal sent, as plain values. spec.noTrafficLightProposal: not there;
	-- spec.lightsRefused: the engine refuses it (critical, "Not possible")
	api.type.enum.TrafficLightPreference = api.type.enum.TrafficLightPreference or { YES = 0, NO = 1, AUTO = 2 }
	local TLP = api.type.enum.TrafficLightPreference
	g.lightPref, g.lightCmds = {}, {}
	for id in pairs(g.nodes) do g.lightPref[id] = lights[id] and TLP.YES or TLP.AUTO end
	for id, k in pairs((spec.roads or {}).lightPrefs or {}) do g.lightPref[id] = TLP[k] end
	-- (over a street system installed before, Track Connector's fake: its nodes and lookups are kept)
	local oldStreets = api.engine.system.streetSystem or {}
	local streetSystem = {}
	for k, f in pairs(oldStreets) do streetSystem[k] = f end
	api.engine.system.streetSystem = streetSystem
	-- the track pieces at a node (an edge of roadType TRACK), as getNodeStreetSegments below
	streetSystem.getNodeTrackSegments = function(n)
		if not g.nodes[n] and oldStreets.getNodeTrackSegments then return oldStreets.getNodeTrackSegments(n) end
		if not g.nodes[n] then crash("getNodeTrackSegments: no node " .. tostring(n)) end
		local out = {}
		for e, ed in pairs(g.edges) do
			if (ed.node0 == n or ed.node1 == n) and ed.roadType == "TRACK" then out[#out + 1] = e end
		end
		table.sort(out)
		return out
	end
	streetSystem.getNodeStreetSegments = function(n)
		g.streetSegmentCalls = (g.streetSegmentCalls or 0) + 1
		if not g.nodes[n] and oldStreets.getNodeStreetSegments then return oldStreets.getNodeStreetSegments(n) end
		if not g.nodes[n] then crash("getNodeStreetSegments: no node " .. tostring(n)) end
		local out = {}
		for e, ed in pairs(g.edges) do
			if (ed.node0 == n or ed.node1 == n) and ed.roadType ~= "TRACK" then out[#out + 1] = e end
		end
		table.sort(out)
		return out
	end

	g.conNode, g.conEdge, g.frozenNode = {}, {}, {}
	-- (the road network's nodes and pieces and the constructions exist, as entityExists says)
	local existsBefore = api.engine.entityExists
	api.engine.entityExists = function(e)
		if g.nodes[e] or g.edges[e] or g.built[e] then return true end
		return existsBefore and existsBefore(e) or false
	end
	api.engine.system.streetConnectorSystem = api.engine.system.streetConnectorSystem or {}
	local scs = api.engine.system.streetConnectorSystem
	local conForEdge = scs.getConstructionEntityForEdge
	scs.getConstructionEntityForEdge = function(e)
		if g.conEdge[e] then return g.conEdge[e] end
		if g.edges[e] then return -1 end
		if conForEdge then return conForEdge(e) end
		crash("getConstructionEntityForEdge: no edge " .. tostring(e))
	end
	if spec.noNodeOwner then
		scs.getConstructionEntityForNode = nil
	else
		scs.getConstructionEntityForNode = function(n)
			if not g.nodes[n] then crash("getConstructionEntityForNode: no node " .. tostring(n)) end
			return g.conNode[n] or -1
		end
	end

	-- what the engine makes of a proposal: errors, collisions, cost (and the constructions to add, as plain values)
	-- ctx: the proposal's Context (its gatherFields: a field in the way is removed, a warning, instead of a collision)
	local function evaluate(p, dry, ctx)
		local st = getmetatable(p).store
		if st.trafficLight then
			local data = { errorState = { critical = false, messages = {}, warnings = {} }, collisionInfo = { collisionEntities = {} },
				costs = 0 }
			if spec.lightsRefused then
				data.errorState.critical = true
				table.insert(data.errorState.messages, "Not possible")
			end
			return data, {}, {}
		end
		local adds, removes = {}, copy(st.constructionsToRemove or {})
		local data = { errorState = { critical = false, messages = {}, warnings = {} }, collisionInfo = { collisionEntities = {} },
			costs = 0 }
		local street = getmetatable(st.streetProposal).store
		local newNodes = {}
		-- the new entities' ids: -1, -2, ... over nodes and pieces, each once (type.d.tl SimpleStreetProposal: "entity
		-- id will be decreasing starting from -1 for all new entities"); what the engine does with others is not
		-- known: taken for an assertion here
		local idsSeen, idCount = {}, 0
		for _, list in ipairs({ street.nodesToAdd or {}, street.edgesToAdd or {} }) do
			for _, x in ipairs(list) do
				if type(x.entity) ~= "number" or x.entity >= 0 then crash("street proposal: new entity id " .. tostring(x.entity)) end
				if idsSeen[x.entity] then crash("street proposal: entity id " .. tostring(x.entity) .. " twice") end
				idsSeen[x.entity] = true
				idCount = idCount + 1
			end
		end
		for i = 1, idCount do
			if not idsSeen[-i] then crash("street proposal: new entity ids are not -1 .. -" .. idCount .. " (no " .. -i .. ")") end
		end
		for _, n in ipairs(street.nodesToAdd or {}) do
			local q = n.comp.position
			-- (two new nodes on one point: refused as a new node on an old one, a guess at the engine's)
			for _, o in pairs(newNodes) do
				if (o.x - q.x) ^ 2 + (o.y - q.y) ^ 2 + (o.z - q.z) ^ 2 <= 0.0001 then
					data.errorState.critical = true
					table.insert(data.errorState.messages, "Construction not possible")
				end
			end
			newNodes[n.entity] = n.comp.position
			for _, o in pairs(g.nodes) do
				if (o.x - q.x) ^ 2 + (o.y - q.y) ^ 2 + (o.z - q.z) ^ 2 <= 0.0001 then
					data.errorState.critical = true
					table.insert(data.errorState.messages, "Construction not possible")
				end
			end
		end
		-- junction set-ups (as the engine might assert; the checks are a guess): a set-up removed must be there; one
		-- added to a node that keeps one, twice, or to no node, dies; a connection must name a piece at that node and
		-- a lane it has
		local removing, adding = {}, {}
		for _, n in ipairs(street.nodeConfigsToRemove or {}) do
			if g.frozenNode[n] then crash("nodeConfigsToRemove: node " .. tostring(n) .. " is a construction's frozen node") end
			if not (g.nodes[n] and g.nodeConfig[n]) then crash("nodeConfigsToRemove: node " .. tostring(n) .. " has no set-up") end
			removing[n] = true
		end
		local newEdges = {}
		for _, e in ipairs(street.edgesToAdd or {}) do newEdges[e.entity] = e.comp end
		for _, nc in ipairs(street.nodeConfigsToAdd or {}) do
			local n = nc.entity
			if not (newNodes[n] or g.nodes[n]) then crash("nodeConfigsToAdd: no node " .. tostring(n)) end
			if adding[n] then crash("nodeConfigsToAdd: node " .. tostring(n) .. " twice") end
			if g.frozenNode[n] then crash("nodeConfigsToAdd: node " .. tostring(n) .. " is a construction's frozen node") end
			if g.nodes[n] and g.nodeConfig[n] and not removing[n] then crash("nodeConfigsToAdd: node " .. tostring(n) .. " keeps its set-up") end
			adding[n] = true
			for _, lc in ipairs((nc.comp or {}).laneConnections or {}) do
				for _, sl in ipairs({ { lc.segment0, lc.lane0 }, { lc.segment1, lc.lane1 } }) do
					local seg = newEdges[sl[1]] or g.edges[sl[1]]
					if not seg or not (seg.node0 == n or seg.node1 == n) then
						crash("lane connection at node " .. tostring(n) .. ": piece " .. tostring(sl[1]) .. " is not there")
					end
					local lanes = seg.laneConfigs or townLanes()
					if type(sl[2]) ~= "number" or sl[2] < 0 or sl[2] >= #lanes then
						crash("lane connection at node " .. tostring(n) .. ": lane " .. tostring(sl[2]) .. " of piece " .. tostring(sl[1]))
					end
				end
			end
		end
		for _, e in ipairs(street.edgesToAdd or {}) do
			local c = e.comp
			for _, k in ipairs({ "node0", "node1" }) do
				if not (g.nodes[c[k]] or newNodes[c[k]]) then crash("street proposal: no node " .. tostring(c[k])) end
				-- (a road's piece only: whether a track piece at such a node asserts is not known; the track
				-- command sends no set-ups, as parallel_tracks and nova's elevated rail do not)
				if g.nodes[c[k]] and not g.nodeConfig[c[k]] and c.roadType ~= api.type.enum.RoadType.TRACK then
					local n = 0
					for _, ed in pairs(g.edges) do if ed.node0 == c[k] or ed.node1 == c[k] then n = n + 1 end end
					if n >= 2 then crash("GetComponentDataIndex: node " .. tostring(c[k]) .. " has no BaseNodeConfig") end
				end
			end
			-- a piece's end where its node is (a guess at what the engine asserts; Track Connector sends its pieces'
			-- positions at their nodes'). An existing node's end may sit beside it (a player's road in a game had
			-- position0 4.5 m off node0, read 2026-11-26): here up to OFFSET_CRASH_M on the map, a guess (the engine's
			-- own limit is not known; the probe refuses past 12 m before it sends). A new node's end stays at it
			local OFFSET_CRASH_M = 12.5
			for _, kk in ipairs({ { "node0", "position0" }, { "node1", "position1" } }) do
				local q, at = newNodes[c[kk[1]]] or g.nodes[c[kk[1]]], c[kk[2]]
				if q and at then
					local flat2 = (q.x - at.x) ^ 2 + (q.y - at.y) ^ 2
					local off = flat2 + (q.z - at.z) ^ 2 > 0.0001
					if off and (newNodes[c[kk[1]]] or flat2 > OFFSET_CRASH_M ^ 2) then
						crash("street proposal: " .. kk[2] .. " is not at " .. kk[1] .. " " .. tostring(c[kk[1]]))
					end
				end
			end
			if not streets[c.roadTemplate] then crash("street proposal: no template " .. tostring(c.roadTemplate)) end
			-- the piece's kind (SegmentAndEntity type: 0 street, 1 track, type.d.tl), its roadType and its template's
			-- agree (a guess at what the engine asserts; a script's road sends type 0 and STREET). A piece with no
			-- roadType (the tests' hand-made ones) and type -1 (the record's own) are let be, as before
			local RT = api.type.enum.RoadType
			local tplType = RT[streets[c.roadTemplate].roadType or "STREET"]
			if c.roadType ~= nil and c.roadType ~= tplType then
				crash("street proposal: roadType " .. tostring(c.roadType) .. " with template " .. tostring(c.roadTemplate))
			end
			if e.type ~= nil and e.type ~= -1 and e.type ~= (c.roadType or tplType) then
				crash("street proposal: SegmentAndEntity type " .. tostring(e.type) .. " with roadType " .. tostring(c.roadType or tplType))
			end
			-- the edge type and its typeIndex (a guess at what the engine asserts: a bridge whose index is no bridge
			-- type's, a plain piece with an index)
			local BET = api.type.enum.BaseEdgeType
			if c.type == BET.BRIDGE then
				if not bridgeNames[(c.typeIndex or -1) - 9] then crash("street proposal: bridge type index " .. tostring(c.typeIndex)) end
			elseif c.type == BET.TUNNEL then
				if not tunnelNames[(c.typeIndex or -1) - 29] then crash("street proposal: tunnel type index " .. tostring(c.typeIndex)) end
			elseif c.type == BET.NORMAL then
				if c.typeIndex ~= -1 then crash("street proposal: a plain piece with typeIndex " .. tostring(c.typeIndex)) end
			else
				crash("street proposal: edge type " .. tostring(c.type))
			end
			-- a tangent not finite or of length 0 (the curve has no way there): taken for an assertion (a guess; the
			-- engine's own check is not known). The tests' hand-made pieces send none
			for _, k in ipairs({ "tangent0", "tangent1" }) do
				local t = c[k]
				local l = t and math.sqrt((t.x or 0) ^ 2 + (t.y or 0) ^ 2 + (t.z or 0) ^ 2)
				if t and not (l == l and l ~= math.huge and l > 1e-9) then crash("street proposal: " .. k .. " of no length") end
			end
			if not dry then g.streetCmds[#g.streetCmds + 1] = copy(e) end
			for _, k in ipairs({ "node0", "node1" }) do
				if g.frozenNode[c[k]] then
					data.errorState.critical = true
					table.insert(data.errorState.messages, "Construction not possible")
				end
			end
			if #(c.laneConfigs or {}) == 0 then
				data.errorState.critical = true
				table.insert(data.errorState.messages, "Invalid lane configuration")
			end
			local p0, p1 = c.position0, c.position1
			local len = math.sqrt((p1.x - p0.x) ^ 2 + (p1.y - p0.y) ^ 2 + (p1.z - p0.z) ^ 2)
			data.costs = data.costs + math.floor(len * (streets[c.roadTemplate].cost or 10))
			local hit = spec.blocked and spec.blocked((p0.x + p1.x) / 2, (p0.y + p1.y) / 2)
			if hit then
				data.errorState.critical = true
				table.insert(data.errorState.messages, "Collision")
				table.insert(data.collisionInfo.collisionEntities, { entity = hit })
			end
			-- spec.softBlocked(x, y): a collision the engine names with critical false (what ignoreErrors builds past)
			local soft = spec.softBlocked and spec.softBlocked((p0.x + p1.x) / 2, (p0.y + p1.y) / 2)
			if soft then
				table.insert(data.errorState.messages, "Collision")
				table.insert(data.collisionInfo.collisionEntities, { entity = soft })
			end
			-- (spec.landInfos for a street piece too, at its middle)
			if spec.landInfos and spec.landInfos((p0.x + p1.x) / 2, (p0.y + p1.y) / 2)
				and not (spec.landInfosBuildOnly and ctx and ctx.engineOwn) then
				data.errorState.infos = data.errorState.infos or {}
				table.insert(data.errorState.infos, "陸上に配置")
				data.infosRefuse = true
			end
			-- spec.fields(x, y) -> { field entities } in the piece's way: with the Context's gatherFields they are
			-- removed (a warning: "N fields will be removed", the game's "3 個の畑が取り除かれます"), else a collision
			-- with each (2026-11-23 in a game: a forest's fields, refused with gatherFields off)
			local fl = spec.fields and spec.fields((p0.x + p1.x) / 2, (p0.y + p1.y) / 2)
			if fl and #fl > 0 then
				if ctx and ctx.gatherFields then
					table.insert(data.errorState.warnings, #fl .. " fields will be removed")
					-- (removed only when the proposal is applied: apply counts them)
					data.fieldsGone = (data.fieldsGone or 0) + #fl
				else
					data.errorState.critical = true
					table.insert(data.errorState.messages, "Collision")
					for _, f in ipairs(fl) do table.insert(data.collisionInfo.collisionEntities, { entity = f }) end
				end
			end
		end
		for _, ce in ipairs(st.constructionsToAdd or {}) do
			local c = cons[ce.fileName]
			if not c then crash("no construction " .. tostring(ce.fileName)) end
			if type(ce.transf) ~= "table" or not ce.transf.mat4f then crash("transf is no Mat4f") end
			adds[#adds + 1] = ce
			-- its box (c.box = { x0, y0, x1, y1, height } in its own frame, default 20 m square, 10 m high), turned and
			-- put where it is asked, axis aligned (ProposalData.toAddData[i].boundingVolume)
			do
				local lb = c.box or { -10, -10, 10, 10, 10 }
				local t = ce.transf
				local xs, ys = {}, {}
				for _, p in ipairs({ { lb[1], lb[2] }, { lb[3], lb[2] }, { lb[3], lb[4] }, { lb[1], lb[4] } }) do
					xs[#xs + 1] = t[13] + t[1] * p[1] + t[5] * p[2]
					ys[#ys + 1] = t[14] + t[2] * p[1] + t[6] * p[2]
				end
				data.toAddData = data.toAddData or {}
				table.insert(data.toAddData, { boundingVolume = { bbox = {
					min = { x = math.min(unpack(xs)), y = math.min(unpack(ys)), z = t[15] },
					max = { x = math.max(unpack(xs)), y = math.max(unpack(ys)), z = t[15] + (lb[5] or 10) } } } })
			end
			data.costs = data.costs + (c.cost or 0)
			local hit = spec.blocked and spec.blocked(ce.transf[13], ce.transf[14])
			if hit then
				data.errorState.critical = true
				table.insert(data.errorState.messages, "Collision")
				table.insert(data.collisionInfo.collisionEntities, { entity = hit })
			end
			local soft = spec.softBlockedCon and spec.softBlockedCon(ce.transf[13], ce.transf[14])
			if soft then
				table.insert(data.errorState.messages, "衝突")
				table.insert(data.collisionInfo.collisionEntities, { entity = soft })
			end
			local onWater = spec.landOnly and spec.landOnly(ce.transf[13], ce.transf[14])
			local own = ctx and ctx.engineOwn
			if onWater and (spec.landOnlyOwnOnly and own or not spec.landOnlyOwnOnly and not own
				and not (dry and spec.landOnlyBuildOnly)) then
				data.errorState.critical = true
				table.insert(data.errorState.messages, "陸上に配置")
			end
			if spec.landInfos and spec.landInfos(ce.transf[13], ce.transf[14]) and not (spec.landInfosBuildOnly and own) and not (spec.landInfosOwnOnly and not own) then
				data.errorState.infos = data.errorState.infos or {}
				table.insert(data.errorState.infos, "陸上に配置")
				data.infosRefuse = true
			end
			-- spec.houses(x, y) -> { town building ids } in its way: with the Context's gatherBuildings they go
			-- (CollisionInfo.buildingEntities, a guess of the engine's), else a collision with each
			local hs = spec.houses and spec.houses(ce.transf[13], ce.transf[14])
			if hs and #hs > 0 then
				if ctx and ctx.gatherBuildings then
					data.collisionInfo.buildingEntities = data.collisionInfo.buildingEntities or {}
					for _, h in ipairs(hs) do table.insert(data.collisionInfo.buildingEntities, h) end
				else
					data.errorState.critical = true
					table.insert(data.errorState.messages, "Collision")
					for _, h in ipairs(hs) do table.insert(data.collisionInfo.collisionEntities, { entity = h }) end
				end
			end
		end
		for _, e in ipairs(removes) do
			if not g.built[e] then crash("no construction " .. tostring(e) .. " to remove") end
		end
		if data.costs > 0 and g.balance < data.costs then
			data.errorState.critical = true
			table.insert(data.errorState.messages, "Not enough money")
		end
		-- spec.proposalData(data, dry, ctx) -> the ProposalData handed out instead (the engine's userdata shapes for
		-- collisionDetail: vectors, maps, fields that raise; M.object / M.vector make them)
		if spec.proposalData then data = spec.proposalData(data, dry, ctx) or data end
		return data, adds, removes
	end

	g.proposalDataCalls = 0
	-- (createTrafficLightProposal: below, after makeProposalData)
	api.engine.util.proposal = { makeProposalData = function(p, ctx)
		g.proposalDataCalls = g.proposalDataCalls + 1
		if spec.noSimpleProposalData then
			error("bad argument #1 to 'makeProposalData' (Proposal expected, got SimpleProposal)")
		end
		if spec.proposalDataOneArg and ctx ~= nil then error("bad argument #2 to 'makeProposalData' (no such overload)") end
		if spec.proposalDataTwoArgs and ctx == nil then error("bad argument #2 to 'makeProposalData' (Context expected)") end
		if type(p) ~= "userdata" then crash("makeProposalData: no proposal") end
		-- (nothing built, nothing paid: plain values, as the engine's ProposalData reads)
		-- (the proposal alone: the GUI's own context, taken to gather fields from the game's answer, a warning that
		-- fields go where the build with gatherFields off collided, 2026-11-23: a guess at why, not read; with a
		-- Context: that one)
		return (evaluate(p, true, ctx or { gatherFields = true, engineOwn = true }))
	end }
	if not spec.noTrafficLightProposal then
		api.engine.util.proposal.createTrafficLightProposal = function(e, config, pref)
			if not (g.nodes[e] and g.nodeConfig[e]) then crash("createTrafficLightProposal: node " .. tostring(e) .. " has no set-up") end
			if type(config) ~= "table" or not config.cloned then crash("createTrafficLightProposal: no TrafficLightConfig") end
			local known = false
			for _, v in pairs(TLP) do if v == pref then known = true end end
			if not known then crash("createTrafficLightProposal: preference " .. tostring(pref)) end
			local u = newproxy(true)
			getmetatable(u).store = { trafficLight = { entity = e, preference = pref,
				config = { states = copy(config.states), trafficLightType = config.trafficLightType } } }
			return u
		end
	end
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
		-- pieces where any part of their line is in the box; nodes are not in the octree (as in the game, by
		-- nova's builder.lua)
		local function inside(x, y) return x >= box.min.x and x <= box.max.x and y >= box.min.y and y <= box.max.y end
		for e, ed in pairs(g.edges) do
			local a, b = g.nodes[ed.node0], g.nodes[ed.node1]
			if a and b then
				for i = 0, 40 do
					local t = i / 40
					if inside(a.x + t * (b.x - a.x), a.y + t * (b.y - a.y)) then cb(e); break end
				end
			end
		end
	end }
	-- api.engine.util.octree.findEntitiesInCircle (engine/util.d.tl UtilOctree): the pieces (BASE_EDGE) whose
	-- straight line comes within r of the centre; other component types: none. spec.noOctreeUtil: not there
	if not spec.noOctreeUtil then
		api.engine.util.octree = { findEntitiesInCircle = function(c, r, kind)
			if type(c) ~= "table" or c.x == nil then crash("findEntitiesInCircle: no Vec2f") end
			g.circleCalls = (g.circleCalls or 0) + 1
			local out = {}
			if kind ~= "BASE_EDGE" then return out end
			for e, ed in pairs(g.edges) do
				local a, b = g.nodes[ed.node0], g.nodes[ed.node1]
				if a and b then
					local dx, dy = b.x - a.x, b.y - a.y
					local l2 = dx * dx + dy * dy
					-- spec.octreeGap = m: a piece's shape drawn back m from a node where two or more pieces meet (a
					-- town road's seam, an industry's T: what the octree met in the game, 2026-11-23, a guess at why)
					local t0, t1 = 0, 1
					if spec.octreeGap and l2 > 0 then
						local function joined(n)
							local k = 0
							for _, o in pairs(g.edges) do if o.node0 == n or o.node1 == n then k = k + 1 end end
							return k >= 2
						end
						local f = spec.octreeGap / math.sqrt(l2)
						if joined(ed.node0) then t0 = math.min(0.5, f) end
						if joined(ed.node1) then t1 = math.max(0.5, 1 - f) end
					end
					local t = l2 > 0 and math.max(t0, math.min(t1, ((c.x - a.x) * dx + (c.y - a.y) * dy) / l2)) or 0
					local px, py = a.x + t * dx, a.y + t * dy
					if (px - c.x) ^ 2 + (py - c.y) ^ 2 <= r * r then out[#out + 1] = e end
				end
			end
			table.sort(out)
			return out
		end }
	end

	local function apply(cmd)
		local data, adds, removes = evaluate(cmd.proposal, false, cmd.context)
		local tl = getmetatable(cmd.proposal).store.trafficLight
		if tl then
			g.lightCmds[#g.lightCmds + 1] = { entity = tl.entity, preference = tl.preference, config = copy(tl.config),
				context = cmd.context, ignoreErrors = cmd.ignoreErrors, playerInitiated = cmd.playerInitiated }
			if data.errorState.critical then return false, data, {} end
			g.lightPref[tl.entity] = tl.preference
			lights[tl.entity] = #(tl.config.states or {}) > 0 or nil
			return true, data, {}
		end
		-- spec.refuseBuild: every build refused, whatever makeProposalData says (with silentCallback: no reason)
		if spec.refuseBuild then data.errorState.critical = true end
		-- ignoreErrors (cmd.d.tl: "enabling the building of the proposal even if non-critical errors are
		-- triggered"): a critical error refuses it all the same, unless spec.ignoreCritical (whether the engine
		-- really keeps to that is not known); non-critical ones (spec.softBlocked, spec.landInfos) refuse it only
		-- without ignoreErrors
		if data.errorState.critical and not (cmd.ignoreErrors and spec.ignoreCritical) then return false, data, {} end
		if #data.errorState.messages > 0 and not cmd.ignoreErrors then return false, data, {} end
		-- (spec.landInfos: refused with critical false, the reason in infos only)
		if data.infosRefuse and not cmd.ignoreErrors then return false, data, {} end
		if data.fieldsGone then g.fieldsRemoved = (g.fieldsRemoved or 0) + data.fieldsGone end
		-- a construction whose own script fails its check (scriptFails): the engine logs "Error during construction
		-- update" and still says success, with no errors, no entities, nothing paid and nothing built (2026-11-22, a
		-- harbour); otherResult: success with only another entity (a node) and no construction among them
		for _, ce in ipairs(adds) do
			local c = cons[ce.fileName]
			if c.scriptFails or c.otherResult then
				local empty = { errorState = { critical = false, messages = {}, warnings = {} },
					collisionInfo = { collisionEntities = {} }, costs = 0 }
				local results = {}
				if c.otherResult then g.nextEntity = g.nextEntity + 1; results[1] = { g.nextEntity, 1 } end
				return true, empty, results
			end
		end
		g.balance = g.balance - data.costs
		local results = {}
		for _, e in ipairs(removes) do
			for _, edge in ipairs(g.built[e].frozenEdges) do
				local ed = g.edges[edge]
				g.nodes[ed.node0], g.nodes[ed.node1], g.edges[edge] = nil, nil, nil
			end
			for _, edge in ipairs(g.built[e].freeEdges or {}) do g.edges[edge] = nil end
			for _, n in ipairs(g.built[e].nodeIds or {}) do g.nodes[n], g.conNode[n], g.frozenNode[n] = nil, nil, nil end
			g.built[e], names[e] = nil, nil
		end
		-- a street proposal: new nodes, then the pieces between them
		local street = getmetatable(getmetatable(cmd.proposal).store.streetProposal).store
		local idOf = {}
		for _, n in ipairs(street.nodesToAdd or {}) do
			g.nextEntity = g.nextEntity + 1
			idOf[n.entity] = g.nextEntity
			g.nodes[g.nextEntity] = copy(n.comp.position)
			g.nodeConfig[g.nextEntity] = false
			if not spec.noStreetResults then results[#results + 1] = { g.nextEntity, 1 } end
		end
		for _, e in ipairs(street.edgesToAdd or {}) do
			g.nextEntity = g.nextEntity + 1
			idOf[e.entity] = g.nextEntity
			local c = e.comp
			g.edges[g.nextEntity] = { node0 = idOf[c.node0] or c.node0, node1 = idOf[c.node1] or c.node1,
				roadTemplate = c.roadTemplate, roadType = c.roadType == 1 and "TRACK" or "STREET", player = e.playerOwned and e.playerOwned.player,
				laneConfigs = copy(c.laneConfigs), tangent0 = copy(c.tangent0), tangent1 = copy(c.tangent1),
				distance = c.distance }
			-- (a bridge keeps its edge type and index, as the engine's BASE_EDGE; a plain piece as before)
			if c.type ~= api.type.enum.BaseEdgeType.NORMAL then
				g.edges[g.nextEntity].type, g.edges[g.nextEntity].typeIndex = c.type, c.typeIndex
			end
			if not spec.noStreetResults then results[#results + 1] = { g.nextEntity, 1 } end
		end
		-- the set-ups, their pieces' new ids in place (g.nodeConns: plain connections)
		for _, n in ipairs(street.nodeConfigsToRemove or {}) do g.nodeConfig[n], g.nodeConns[n] = false, nil end
		for _, nc in ipairs(street.nodeConfigsToAdd or {}) do
			local n = idOf[nc.entity] or nc.entity
			local conns = {}
			for _, lc in ipairs((nc.comp or {}).laneConnections or {}) do
				conns[#conns + 1] = { segment0 = idOf[lc.segment0] or lc.segment0, lane0 = lc.lane0,
					segment1 = idOf[lc.segment1] or lc.segment1, lane1 = lc.lane1, withRoad = lc.withRoad, withTram = lc.withTram }
			end
			g.nodeConfig[n], g.nodeConns[n] = true, conns
		end
		for _, ce in ipairs(adds) do
			local c, t = cons[ce.fileName], ce.transf
			g.nextEntity = g.nextEntity + 1
			local e = g.nextEntity
			local nodeIds, edgeIds = {}, {}
			local cs, sn = t[1], t[2]
			-- (a guess of the engine's, for build --join-streets: with the Context's cleanupStreetGraph a node of the
			-- construction that is not frozen and lies on an old road node, within 0.01 m, becomes that node)
			local frozenIdx = {}
			for _, i in ipairs((c.shape or {}).frozenNodes or {}) do frozenIdx[i] = true end
			for i, n in ipairs((c.shape or {}).nodes or {}) do
				local q = { x = t[13] + cs * n[1] - sn * n[2], y = t[14] + sn * n[1] + cs * n[2], z = t[15] + (n[3] or 0) }
				local old
				if cmd.context and cmd.context.cleanupStreetGraph and not frozenIdx[i] then
					for id, o in pairs(g.nodes) do
						if not g.conNode[id] and (o.x - q.x) ^ 2 + (o.y - q.y) ^ 2 + (o.z - q.z) ^ 2 <= 0.0001 then old = id end
					end
				end
				if old then
					nodeIds[i] = old
				else
					g.nextEntity = g.nextEntity + 1
					nodeIds[i] = g.nextEntity
					g.nodes[g.nextEntity] = q
					g.nodeConfig[g.nextEntity] = true
				end
			end
			for _, ed in ipairs((c.shape or {}).edges or {}) do
				g.nextEntity = g.nextEntity + 1
				edgeIds[#edgeIds + 1] = g.nextEntity
				-- (ed.track: a track piece, as a station's)
				g.edges[g.nextEntity] = { node0 = nodeIds[ed[1]], node1 = nodeIds[ed[2]], roadType = ed.track and "TRACK" or nil }
				g.conEdge[g.nextEntity] = e
				g.conNode[nodeIds[ed[1]]], g.conNode[nodeIds[ed[2]]] = e, e
			end
			local freeIds = {}
			for _, ed in ipairs((c.shape or {}).free or {}) do
				g.nextEntity = g.nextEntity + 1
				freeIds[#freeIds + 1] = g.nextEntity
				g.edges[g.nextEntity] = { node0 = nodeIds[ed[1]], node1 = nodeIds[ed[2]], roadType = ed.track and "TRACK" or nil }
				if spec.armEndsOwned then
					for _, k in ipairs({ 1, 2 }) do g.conNode[nodeIds[ed[k]]] = g.conNode[nodeIds[ed[k]]] or e end
				end
			end
			local frozenNodes = {}
			for _, i in ipairs((c.shape or {}).frozenNodes or {}) do
				frozenNodes[#frozenNodes + 1] = nodeIds[i]
				g.frozenNode[nodeIds[i]] = e
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
			-- c.warehouse: a warehouse's subconstruction (WAREHOUSE { stockList, construction }) and its stock list
			-- entity, as warehouse.script.lua's one subconstruction holds all its stocks
			local subs = {}
			if c.warehouse then
				local wh, sl = g.nextEntity + 1, g.nextEntity + 2
				g.nextEntity = sl
				subs[1] = wh
				g.buildWarehouses[wh] = { stockList = sl, construction = e }
				g.buildStockLists[sl] = true
			end
			g.built[e] = { fileName = ce.fileName, params = copy(ce.params), transf = copy(t), name = ce.name,
				player = ce.playerEntity, autoFillSlots = ce.autoFillSlots, frozenEdges = edgeIds, depots = depots,
				freeEdges = freeIds, frozenNodes = frozenNodes, nodeIds = nodeIds,
				stations = stations, subconstructions = subs }
			if ce.name ~= "" then names[e] = ce.name end
			if not c.notInResult then results[#results + 1] = { e, 1 } end
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
			if spec.silentCallback or spec.infosOnly then
				local es = data.errorState
				data.errorState = { critical = es.critical, messages = {}, warnings = {},
					infos = spec.infosOnly and copy(es.messages) or {} }
			elseif spec.noErrorState then
				data.errorState = nil
			end
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
				transf = copy(b.transf), frozenEdges = copy(b.frozenEdges), frozenNodes = (not spec.noFrozenNodes) and copy(b.frozenNodes or {}) or nil,
				depots = copy(b.depots), stations = copy(b.stations or {}), industries = {},
				subconstructions = copy(b.subconstructions or {}) }
		end
		if g.buildWarehouses[e] then
			if kind == "WAREHOUSE" then return copy(g.buildWarehouses[e]) end
			return nil
		end
		if kind == "STATION" and g.buildStations[e] then
			local t = {}
			for i = 1, g.buildStations[e].terminals do t[i] = { tag = i } end
			return { terminals = t }
		end
		if kind == "TERRAIN" and e == 1 and spec.waterLevel ~= nil then return { waterLevel = spec.waterLevel } end
		if kind == "BASE_EDGE" and g.edges[e] then
			-- roadType as the engine's enum (a construction's own pieces: roads); spec.edgeRoadTypeUnread: none
			local be = copy(g.edges[e])
			be.laneConfigs = be.laneConfigs or townLanes()
			be.roadType = (not spec.edgeRoadTypeUnread) and api.type.enum.RoadType[g.edges[e].roadType or "STREET"] or nil
			return be
		end
		if kind == "BASE_NODE" and g.nodes[e] then return { position = copy(g.nodes[e]) } end
		if kind == "BASE_NODE_CONFIG" and g.nodes[e] then
			g.nodeConfigReads = (g.nodeConfigReads or 0) + 1
			if spec.nodeConfigRaises then error("getComponent: BASE_NODE_CONFIG") end
			if g.nodeConfig[e] then
				-- (the config's clone: TrafficLightConfig.clone, engine.d.tl, called as the window does, config:clone())
				local function clone(c) return { states = copy(c.states), trafficLightType = c.trafficLightType, cloned = true } end
				return { laneConnections = copy(g.nodeConns[e] or {}), crosswalks = {}, doubleSlipSwitch = false,
					trafficLightPreference = g.lightPref[e] or TLP.AUTO,
					trafficLightConfig = { states = lights[e] and { { duration = 30 } } or {}, trafficLightType = 0,
						clone = spec.lightCloneRaises and function() error("clone") end or clone } }
			end
			return nil
		end
		return getComponent(e, kind)
	end
	local getName = api.engine.util.getEntityName
	api.engine.util.getEntityName = function(e)
		if names[e] then return names[e] end
		return getName(e)
	end
	local exists = api.engine.entityExists
	api.engine.entityExists = function(e)
		return g.built[e] ~= nil or g.buildWarehouses[e] ~= nil or g.buildStockLists[e] ~= nil or exists(e)
	end
	g.buildNames = names
	return makeCmd
end

-- The engine's side of the terrain command (makeMapFromGame, makeWorldReplaceTerrainCmd), for remote_terrain.lua.
-- spec.tiles = { tx, ty } (default 2 x 2: 512 m, 129 points a row of 4 m), the map centred on 0, 0;
-- spec.height(x, y): the heights it starts with (default 10); spec.waterLevel (default 0);
-- spec.entities = { [id] = { kind = "BASE_EDGE" | "CONSTRUCTION" | ..., x, y } }: what the octree finds;
-- spec.reactOnly: the terrain functions are there only in a react state (M.inReact): nil in the guiUpdate state;
-- spec.replaceFails: the callback says no success, nothing changes; spec.lostCallback: no callback;
-- spec.townsInMap: makeMapFromGame lists a town even without towns asked for; spec.vectorHeights: the heightmap read
-- is an engine vector (userdata with # and [i]); spec.box = { x0, y0, x1, y1 }: getBoundingBox gives this instead
-- (a larger map than the heights); spec.sendRaises: sendCommand raises on the replacement (this text).
-- api.type.Map.new(map) copies a GameMap (anything else is an assertion).
-- Like the engine: GameMap.heightmap hands out a copy on each read (an element written into it is lost; only a whole
-- table assigned counts), a map that lists towns is an assertion in ReplaceTerrain, so is a heightmap of the wrong
-- size. g.heights: the engine's heights; g.terrainCmds: each replacement sent; g.seedTexts, g.materialReloads.
-- spec.callableApi: the api entries the replacement uses are callable tables (a __call, type() says "table"), as the
-- engine's api entries are: each one calls the function it wraps. spec.opaqueApi (with it): the metatable cannot be
-- read from outside (getmetatable gives a string, as a __metatable field does), so isCallable is false for them.
function M.installTerrain(g, spec)
	spec = spec or {}
	local function callableIf(f)
		if not spec.callableApi and not spec.opaqueApi then return f end
		local mt = { __call = function(_, ...) return f(...) end }
		if spec.opaqueApi then mt.__metatable = "locked" end
		return setmetatable({}, mt)
	end
	local tx, ty = (spec.tiles or {})[1] or 2, (spec.tiles or {})[2] or 2
	local step = 4
	local w, h = tx * 256 / step + 1, ty * 256 / step + 1
	local minX, minY = -tx * 128, -ty * 128
	g.heights = {}
	for j = 0, h - 1 do
		for i = 0, w - 1 do
			g.heights[j * w + i + 1] = spec.height and spec.height(minX + i * step, minY + j * step) or 10
		end
	end
	g.terrainCmds, g.seedTexts, g.materialReloads = {}, {}, 0
	local level = spec.waterLevel or 0
	local function crash(msg) g.crashed = "ASSERT: " .. msg; error(g.crashed) end
	api.type.Vec2f = api.type.Vec2f or { new = function(x, y) return { x = x, y = y } end }
	api.type.Vec3f = api.type.Vec3f or { new = function(x, y, z) return { x = x, y = y, z = z } end }
	api.type.Box3 = api.type.Box3 or { new = function(lo, hi) return { min = lo, max = hi } end }
	local maps = setmetatable({}, { __mode = "k" })
	local function newMap(withHeights, towns, from)
		local store = from and copy(from) or { heightmap = withHeights and copy(g.heights) or {}, numTilesX = tx,
			numTilesY = ty, levels = 1, offsetZ = -100, waterLevel = level, climateId = "temperate",
			resolution = { x = step, y = step, z = 0.05 }, towns = towns or {}, industries = {} }
		local u = newproxy(true)
		local mt = getmetatable(u)
		mt.__index = function(_, k)
			if store[k] == nil then error("no field " .. tostring(k)) end
			if k == "heightmap" and spec.vectorHeights then
				local c = copy(store.heightmap)
				local v = newproxy(true)
				getmetatable(v).__len = function() return #c end
				getmetatable(v).__index = function(_, i) return c[i] end
				return v
			end
			return type(store[k]) == "table" and copy(store[k]) or store[k]
		end
		mt.__newindex = function(_, k, v)
			if store[k] == nil then error("no field " .. tostring(k)) end
			store[k] = type(v) == "table" and copy(v) or v
		end
		maps[u] = store
		return u
	end
	local function heightAt(x, y)
		local fi, fj = (x - minX) / step, (y - minY) / step
		local i0, j0 = math.max(0, math.min(w - 2, math.floor(fi))), math.max(0, math.min(h - 2, math.floor(fj)))
		local ax, ay = fi - i0, fj - j0
		local function at(i, j) return g.heights[j * w + i + 1] end
		return (1 - ay) * ((1 - ax) * at(i0, j0) + ax * at(i0 + 1, j0)) + ay * ((1 - ax) * at(i0, j0 + 1) + ax * at(i0 + 1, j0 + 1))
	end
	local hidden = {
		makeMapFromGame = function(wH, wT, wI, wA)
			return newMap(wH, (wT or spec.townsInMap) and { { name = "Town" } } or {})
		end,
		getBoundingBox = function()
			local b = spec.box
			if b then return { min = { x = b[1], y = b[2] }, max = { x = b[3], y = b[4] } } end
			return { min = { x = minX, y = minY }, max = { x = minX + (w - 1) * step, y = minY + (h - 1) * step } }
		end,
	}
	local terrain = {
		getHeightAt = function(v) return heightAt(v.x, v.y) end,
		isValidCoordinate = function(v)
			return v.x >= minX and v.y >= minY and v.x <= minX + (w - 1) * step and v.y <= minY + (h - 1) * step
		end,
		isOnWater = function(v) return heightAt(v.x, v.y) < level end,
	}
	for k, f in pairs(hidden) do hidden[k] = callableIf(f) end
	local function shown(k) return hidden[k] ~= nil and (not spec.reactOnly or M.inReact) end
	api.engine.terrain = setmetatable(terrain, { __index = function(_, k) if shown(k) then return hidden[k] end end })
	local cfg = { terrainConfig = true }
	api.res.getBaseConfig = callableIf(function() return { terrain = cfg } end)
	g.mapCopies = 0
	api.type.Map = { new = callableIf(function(m)
		if not maps[m] then crash("Map.new: no GameMap") end
		g.mapCopies = g.mapCopies + 1
		return newMap(nil, nil, maps[m])
	end) }
	api.engine.mapgen = { createTowns = function() return { toAdd = {} } end, createIndustries = function() return { toAdd = {} } end }
	api.gui.map = { setMapSeedText = function(t) g.seedTexts[#g.seedTexts + 1] = t end,
		reloadMaterialIndexManagerPipeline = function() g.materialReloads = g.materialReloads + 1 end }
	local replaceCmd = function(map, terrainConfig, seed, world, keepAssets)
		if not maps[map] then crash("makeWorldReplaceTerrainCmd: no GameMap") end
		if terrainConfig ~= cfg then crash("makeWorldReplaceTerrainCmd: no terrain config") end
		local st = maps[map]
		return { kind = "replaceTerrain", heights = copy(st.heightmap), towns = copy(st.towns), seed = seed,
			world = world, keepAssets = keepAssets }
	end
	replaceCmd = callableIf(replaceCmd)
	if spec.reactOnly then
		setmetatable(api.cmd, { __index = function(_, k) if k == "makeWorldReplaceTerrainCmd" and M.inReact then return replaceCmd end end })
	else
		api.cmd.makeWorldReplaceTerrainCmd = replaceCmd
	end
	local send = api.cmd.sendCommand
	api.cmd.sendCommand = function(cmd, cb)
		if type(cmd) ~= "table" or cmd.kind ~= "replaceTerrain" then return send(cmd, cb) end
		if spec.sendRaises then error("sendCommand: " .. spec.sendRaises) end
		g.commands[#g.commands + 1] = cmd
		if #cmd.towns > 0 then crash("terrain_util::ReplaceTerrain: Assertion 'map.towns.empty()' failed") end
		if #cmd.heights ~= w * h then crash("ReplaceTerrain: heightmap of " .. #cmd.heights .. " values, " .. w * h .. " wanted") end
		g.terrainCmds[#g.terrainCmds + 1] = cmd
		if not spec.replaceFails then g.heights = copy(cmd.heights) end
		if cb and not spec.lostCallback then cb({}, not spec.replaceFails) end
	end
	api.cmd.sendCommand = callableIf(api.cmd.sendCommand)
	-- what stands on the map
	local ents = spec.entities or {}
	api.engine.system = api.engine.system or {}
	local oldOctree = api.engine.system.octreeSystem
	api.engine.system.octreeSystem = { findIntersectingEntities = function(box, cb)
		if oldOctree then oldOctree.findIntersectingEntities(box, cb) end
		for e, b in pairs(ents) do
			if b.x >= box.min.x and b.x <= box.max.x and b.y >= box.min.y and b.y <= box.max.y then cb(e) end
		end
	end }
	local CT = api.type.ComponentType
	for _, k in ipairs({ "BASE_EDGE", "BASE_NODE", "CONSTRUCTION", "TOWN_BUILDING", "INDUSTRY", "SUBCONSTRUCTION" }) do
		CT[k] = CT[k] or k
	end
	local exists = api.engine.entityExists
	api.engine.entityExists = function(e)
		if ents[e] then return true end
		for _, t in ipairs(api.engine.getEntitiesWithComponent(CT.TOWN) or {}) do if t == e then return true end end
		return exists(e)
	end
	local getComponent = api.engine.getComponent
	api.engine.getComponent = function(e, kind)
		if ents[e] then return ents[e].kind == kind and {} or nil end
		return getComponent(e, kind)
	end
end

-- The engine's side of the town command (mapgen.createTowns, makeTownCreateCmd, makeTownUpdateCargoNeedsCmd), for
-- remote_town.lua. api.type.Map.Town.new gives a strict record (an unknown field is an error, as the engine's);
-- createTowns asserts on anything that is not one, and gives one TownInfo per town (its initialLandUseCapacities
-- spec.capacities, default 100 / 50 / 50 times the size factor; spec.noRoom: 0, 0, 0). spec.toRemove: createTowns
-- also lists these town ids to remove. spec.createRaises: createTowns raises this text (as the engine on a place it
-- cannot take). spec.createFails: the create callback says no success. spec.reactOnly: createTowns and
-- makeTownCreateCmd are there only in a react state. spec.needsFromMap: the new town takes landUse2CargoNeeds as
-- its first needs (default: it gets none, as RWMI saw). spec.needsFails: the needs command's callback says no.
-- spec.noNeedsCmd: no makeTownUpdateCargoNeedsCmd. spec.callbackFrames: the create runs, and its callback comes,
-- that many frames later (as queued commands); spec.lostCallback: it runs but no callback comes.
-- spec.noValidCheck: no isValidCoordinate. spec.lostTown: the create says success but makes no town.
-- The shapes are checked as the engine's types have them (sizeFactors 3 numbers, landUse2CargoNeeds keyed by
-- LandUseType values with { name, weight } pairs, initialLandUseCapacities 3 whole numbers, cargo type ids whole
-- numbers of known cargo types): anything else is an assertion. The economy: spec.categories ({ [name] = { tier, landUses } }),
-- spec.cargo ({ [id] = category }). g.townProposals: each createTowns call's towns; g.townCmds: each create sent;
-- g.townNeedsCmds: each needs command; g.newTowns: the ids made; g.townNeeds[e]: a town's cargoNeeds.
function M.installTown(g, spec)
	spec = spec or {}
	local CT = api.type.ComponentType
	CT.TOWN = CT.TOWN or "TOWN"
	local LU = api.type.enum.LandUseType
	local function crash(msg) g.crashed = "ASSERT: " .. msg; error(g.crashed) end
	api.type.Vec2f = api.type.Vec2f or { new = function(x, y) return { x = x, y = y } end }
	g.townProposals, g.townCmds, g.townNeedsCmds, g.newTowns, g.townNeeds = {}, {}, {}, {}, {}
	local townNames, townPos, townCaps = {}, {}, {}
	local cargo -- (the economy's, below)
	local records = setmetatable({}, { __mode = "k" })
	local FIELDS = { pos = true, name = true, sizeFactors = true, landUse2CargoNeeds = true, existing = true }
	api.type.Map = api.type.Map or {}
	api.type.Map.Town = { new = function()
		local store = { existing = -1, sizeFactors = {}, landUse2CargoNeeds = {}, name = "" }
		local u = newproxy(true)
		local mt = getmetatable(u)
		mt.__index = function(_, k) if not FIELDS[k] then error("Town: no field " .. tostring(k)) end return store[k] end
		mt.__newindex = function(_, k, v)
			if not FIELDS[k] then error("Town: no field " .. tostring(k)) end
			if k == "sizeFactors" then
				if type(v) ~= "table" or #v ~= 3 then crash("Town.sizeFactors: 3 numbers") end
				for i = 1, 3 do if type(v[i]) ~= "number" then crash("Town.sizeFactors: 3 numbers") end end
			elseif k == "landUse2CargoNeeds" then
				if type(v) ~= "table" then crash("Town.landUse2CargoNeeds: a map") end
				for lu, list in pairs(v) do
					if lu ~= LU.RESIDENTIAL and lu ~= LU.COMMERCIAL and lu ~= LU.INDUSTRIAL then
						crash("Town.landUse2CargoNeeds: key " .. tostring(lu) .. " is no LandUseType")
					end
					for _, pair in ipairs(list) do
						if type(pair) ~= "table" or type(pair[1]) ~= "string" or type(pair[2]) ~= "number" then
							crash("Town.landUse2CargoNeeds: { name, weight } pairs")
						end
					end
				end
			elseif k == "name" and type(v) ~= "string" then crash("Town.name: a string")
			elseif k == "existing" and type(v) ~= "number" then crash("Town.existing: an entity")
			end
			store[k] = copy(v)
		end
		records[u] = store
		return u
	end }
	local infos = setmetatable({}, { __mode = "k" })
	local createTowns = function(seed, list)
		if type(seed) ~= "string" then crash("createTowns: no seed") end
		local proposal, out = {}, {}
		for _, t in ipairs(list) do
			local st = records[t]
			if not st then crash("createTowns: not a GameMap.Town") end
			proposal[#proposal + 1] = copy(st)
		end
		g.townProposals[#g.townProposals + 1] = proposal
		if spec.createRaises then error(spec.createRaises) end
		for _, st in ipairs(proposal) do
			local f = st.sizeFactors[1] or 1
			local caps = spec.noRoom and { 0, 0, 0 } or copy(spec.capacities) or { 100 * f, 50 * f, 50 * f }
			local info = { name = st.name, position = { x = st.pos.x, y = st.pos.y }, initialLandUseCapacities = caps,
				landUse2CargoNeedsCategories = copy(st.landUse2CargoNeeds), majorStreetAngle = 0.5,
				initialMajorStreetAngle = 0.5, capacityScalingFactor = 1 }
			infos[info] = true
			out[#out + 1] = info
		end
		return { toAdd = out, toRemove = copy(spec.toRemove or {}) }
	end
	local createCmd = function(list)
		local towns = {}
		for _, info in ipairs(list) do
			if not infos[info] then crash("makeTownCreateCmd: not a TownInfo from createTowns") end
			local caps = info.initialLandUseCapacities
			if type(caps) ~= "table" or #caps ~= 3 then crash("TownInfo.initialLandUseCapacities: 3 integers") end
			for i = 1, 3 do
				if type(caps[i]) ~= "number" or caps[i] ~= math.floor(caps[i]) then crash("TownInfo.initialLandUseCapacities: 3 integers") end
			end
			towns[#towns + 1] = copy(info)
		end
		return { kind = "townCreate", towns = towns }
	end
	api.engine.mapgen = api.engine.mapgen or {}
	if spec.reactOnly then
		setmetatable(api.engine.mapgen, { __index = function(_, k) if k == "createTowns" and M.inReact then return createTowns end end })
		api.engine.mapgen.createTowns = nil
		local mt = getmetatable(api.cmd) or {}
		local prev = mt.__index
		mt.__index = function(t, k)
			if k == "makeTownCreateCmd" then return M.inReact and createCmd or nil end
			if type(prev) == "function" then return prev(t, k) end
			return prev and prev[k]
		end
		setmetatable(api.cmd, mt)
	else
		api.engine.mapgen.createTowns = createTowns
		api.cmd.makeTownCreateCmd = createCmd
	end
	if not spec.noNeedsCmd then
		api.cmd.makeTownUpdateCargoNeedsCmd = function(e, needs, update)
			if type(needs) ~= "table" or type(update) ~= "boolean" then crash("makeTownUpdateCargoNeedsCmd: needs, update") end
			for k = 1, 3 do
				for _, id in ipairs(needs[k] or {}) do
					if type(id) ~= "number" or id ~= math.floor(id) or not cargo[id] then
						crash("makeTownUpdateCargoNeedsCmd: " .. tostring(id) .. " is no cargo type id")
					end
				end
			end
			return { kind = "townNeeds", town = e, needs = copy(needs), update = update }
		end
	end
	-- the economy
	local categories = spec.categories or { vegetables = { tier = 0, landUses = { LU.COMMERCIAL } },
		fish = { tier = 0, landUses = { LU.COMMERCIAL } }, planks = { tier = 0, landUses = { LU.INDUSTRIAL } },
		bricks = { tier = 0, landUses = { LU.INDUSTRIAL } }, tools = { tier = 1, landUses = { LU.COMMERCIAL } } }
	cargo = spec.cargo or { [11] = "fish", [12] = "vegetables", [13] = "planks", [14] = "bricks", [15] = "tools" }
	api.res.economyRep = { find = function(id) return id == "eco" and 4 or -1 end,
		get = function(i) if i ~= 4 then crash("economyRep.get " .. tostring(i)) end return { cargoCategories = copy(categories) } end }
	local baseConfig = api.res.getBaseConfig
	api.res.getBaseConfig = function()
		local c = baseConfig and baseConfig() or {}
		c.economyId = "eco"
		return c
	end
	local getAll, get = api.res.cargoTypeRep.getAll, api.res.cargoTypeRep.get
	api.res.cargoTypeRep.getAll = function()
		local out = getAll()
		for id, cat in pairs(cargo) do out[id] = cat:upper() end
		return out
	end
	api.res.cargoTypeRep.get = function(id)
		if cargo[id] then return { name = cargo[id], category = cargo[id] } end
		return get(id)
	end
	-- the commands
	local send = api.cmd.sendCommand
	api.cmd.sendCommand = function(cmd, cb)
		if type(cmd) ~= "table" or (cmd.kind ~= "townCreate" and cmd.kind ~= "townNeeds") then return send(cmd, cb) end
		g.commands[#g.commands + 1] = cmd
		if cmd.kind == "townNeeds" then
			g.townNeedsCmds[#g.townNeedsCmds + 1] = cmd
			if not townNames[cmd.town] then crash("makeTownUpdateCargoNeedsCmd: no town " .. tostring(cmd.town)) end
			if not spec.needsFails then
				local n = {}
				for k = 1, 3 do
					n[k] = {}
					for _, id in ipairs(cmd.needs[k] or {}) do n[k][#n[k] + 1] = { id, 1 } end
				end
				g.townNeeds[cmd.town] = n
			end
			if cb then cb(cmd, not spec.needsFails) end
			return
		end
		g.townCmds[#g.townCmds + 1] = cmd
		local function run()
		if spec.createFails then if cb and not spec.lostCallback then cb(cmd, false, {}) end return end
		local made = {}
		for _, t in ipairs(spec.lostTown and {} or cmd.towns) do
			g.nextEntity = g.nextEntity + 1
			local e = g.nextEntity
			g.newTowns[#g.newTowns + 1] = e
			townNames[e], townPos[e] = t.name, t.position
			local caps = t.initialLandUseCapacities
			townCaps[e] = { caps[1] or 0, caps[2] or 0, caps[3] or 0 }
			local n = { {}, {}, {} }
			if spec.needsFromMap then
				local idOf = {}
				for id, cat in pairs(cargo) do idOf[cat] = id end
				for lu, list in pairs(t.landUse2CargoNeedsCategories or {}) do
					for _, pair in ipairs(list) do table.insert(n[lu + 1], { idOf[pair[1]], pair[2] }) end
				end
			end
			g.townNeeds[e] = n
			made[#made + 1] = { e, 1 }
		end
		if cb and not spec.lostCallback then cb(cmd, true, made) end
		end
		if spec.callbackFrames then
			g.callbacks[#g.callbacks + 1] = { frames = spec.callbackFrames, fn = run }
		else
			run()
		end
	end
	local getEntities = api.engine.getEntitiesWithComponent
	api.engine.getEntitiesWithComponent = function(kind, filter)
		local list = getEntities(kind, filter)
		if kind ~= CT.TOWN then return list end
		local out = copy(list or {})
		for _, e in ipairs(g.newTowns) do out[#out + 1] = e end
		return out
	end
	local getName = api.engine.util.getEntityName
	api.engine.util.getEntityName = function(e) return townNames[e] or getName(e) end
	local getComponent = api.engine.getComponent
	api.engine.getComponent = function(e, kind)
		if townNames[e] then
			if kind == CT.TOWN then return { cargoNeeds = copy(g.townNeeds[e]) } end
			if kind == "BOUNDING_VOLUME" then
				local p = townPos[e]
				return { bbox = { min = { x = p.x - 100, y = p.y - 100, z = 0 }, max = { x = p.x + 100, y = p.y + 100, z = 20 } } }
			end
			return nil
		end
		return getComponent(e, kind)
	end
	local tbs = api.engine.system.townBuildingSystem
	local capsMap = tbs.getTown2personCapacitiesMap
	tbs.getTown2personCapacitiesMap = function()
		local m = capsMap()
		for e, c in pairs(townCaps) do m[e] = copy(c) end
		return m
	end
	api.engine.terrain = api.engine.terrain or {}
	if spec.noValidCheck then
		api.engine.terrain.isValidCoordinate = nil
	elseif api.engine.terrain.isValidCoordinate == nil then
		api.engine.terrain.isValidCoordinate = function(v) return math.abs(v.x) <= 2048 and math.abs(v.y) <= 2048 end
	end
end

M.dateOf = dateOf
M.DAY_TICKS = DAY_TICKS

-- The engine's side of the debug commands (remote_debug.lua): api.cmd.debug's makeStockSetCargoAmountCmd and
-- makeGamePerformSimulationStepsCmd, the stocks of entities that are no industry (stations), and the GAME_TIME
-- update count. spec.stockLists = { [entity] = { stocks = { { type, cargoType, capacity, count, cargoTypes = { ids },
-- byCargo = { [cargo] = n } } } } }; spec.owners = { [entity] = { kind = "INDUSTRY"|"TOWN_BUILDING", stockList } }
-- (an owner whose own entity has no STOCK_LIST). spec.missing = { stockSet = true, steps = true }: that function nil;
-- spec.callableApi / opaqueApi: the functions as callable tables (opaque: their metatable locked, as the engine's);
-- spec.refuse = { stockSet = true, steps = true }: the callback says no success; spec.makeRaises / sendRaises: this
-- text raised; spec.noCallback: the callback never comes; spec.stepMs: game time per step (200);
-- spec.stepsPerFrame: the steps run on after the callback, this many a frame (as the engine runs them on), and
-- spec.stepsStall: no more of them run after that many (a game that stops part way).
-- g.debugCmds: every debug command sent, as made (nargs: the arguments make got). A stock id or cargo the list does
-- not have, or a load set into a vehicle whose line is none (-1, not a number), is the engine's assertion (g.crashed).
function M.installDebug(g, spec)
	spec = spec or {}
	local lists = spec.stockLists or {}
	local owners = spec.owners or {}
	-- spec.constructions = { [entity] = { subconstructions = { ids }, industries = { ids }, townBuildings = { ids } } }:
	-- a construction's CONSTRUCTION (a warehouse's: its one subconstruction, an owner of kind WAREHOUSE with
	-- stockList and construction). Asking getComponent of an id none of this knows, nor the base fake, is the
	-- engine's assertion (g.crashed) when spec.strictIds is set.
	local cons = spec.constructions or {}
	api.type.ComponentType.WAREHOUSE = api.type.ComponentType.WAREHOUSE or "WAREHOUSE"
	g.debugCmds, g.updateCount = {}, g.updateCount or 1000
	local function crash(msg) g.crashed = msg; error(msg) end
	local function callable(f)
		if not spec.callableApi and not spec.opaqueApi then return f end
		local mt = { __call = function(_, ...) return f(...) end }
		if spec.opaqueApi then mt.__metatable = "locked" end
		return setmetatable({}, mt)
	end
	local missing = spec.missing or {}
	local debug = {}
	if not missing.stockSet then
		debug.makeStockSetCargoAmountCmd = callable(function(...)
			if spec.makeRaises then error(spec.makeRaises) end
			local e, stock, amount, cargo = ...
			return { kind = "debugStock", entity = e, stock = stock, amount = amount, cargoType = cargo, nargs = select("#", ...) }
		end)
	end
	if not missing.steps then
		debug.makeGamePerformSimulationStepsCmd = callable(function(...)
			if spec.makeRaises then error(spec.makeRaises) end
			return { kind = "debugSteps", amount = (...), nargs = select("#", ...) }
		end)
	end
	api.cmd.debug = debug
	local cargoId = {}
	for id, name in pairs(api.res.cargoTypeRep.getAll()) do cargoId[name] = id end
	-- the stock as this fake holds it: a stockLists entry, else the industry's (the base fake's getStockCount)
	local function stockOf(e, id)
		local l = lists[e]
		if l then
			local st = l.stocks[id + 1]
			if not st then crash("ASSERT: no stock " .. tostring(id) .. " at " .. tostring(e)) end
			return st
		end
		return nil
	end
	local function apply(cmd)
		if cmd.kind == "debugSteps" then
			if (spec.refuse or {}).steps then return false end
			if spec.stepsPerFrame then
				g.pendingSteps = (g.pendingSteps or 0) + cmd.amount
			else
				g.gameTime = g.gameTime + cmd.amount * (spec.stepMs or 200)
				g.updateCount = g.updateCount + cmd.amount
			end
			return true
		end
		if (spec.refuse or {}).stockSet then return false end
		-- stock -1 at a stock list (a mixed stock's cargo, by its name): the first of its stocks that takes the
		-- cargo gets it (which one the engine takes is not known; spec.minusOneCrashes: the engine's assertion;
		-- spec.minusOneIgnoresName: the name not taken either, the stock's default cargo type gets it)
		if cmd.stock == -1 and lists[cmd.entity] then
			if spec.minusOneCrashes then crash("ASSERT: stock -1 at stock list " .. tostring(cmd.entity)) end
			-- spec.minusOneDoesNothing: success, and nothing changes (a warehouse's mixed stock in a game, 2026-11-23)
			if spec.minusOneDoesNothing then return true end
			local id = cargoId[cmd.cargoType]
			if id == nil then crash("ASSERT: no cargo type " .. tostring(cmd.cargoType)) end
			for _, st in ipairs(lists[cmd.entity].stocks) do
				local takes = st.cargoTypes or (st.cargoType and st.cargoType >= 0 and { st.cargoType }) or {}
				for _, c in ipairs(takes) do
					if c == id then
						st.byCargo = st.byCargo or {}
						if spec.minusOneIgnoresName then id = st.default or takes[#takes] end
						st.byCargo[id] = cmd.amount
						local sum = 0
						for _, n in pairs(st.byCargo) do sum = sum + n end
						st.count = sum
						return true
					end
				end
			end
			return true -- (nothing takes it: nothing changes)
		end
		-- stock -1 at an industry of the base fake: its first stock that takes the cargo
		if cmd.stock == -1 and g.industries[cmd.entity] and not g.fleet[cmd.entity] then
			local id = cargoId[cmd.cargoType]
			if id == nil then crash("ASSERT: no cargo type " .. tostring(cmd.cargoType)) end
			for _, st in ipairs(g.industries[cmd.entity].stocks or {}) do
				for _, c in ipairs(st.cargoTypes or { st.cargoType }) do
					if c == id then
						-- per cargo type from now on (a mixed input holds each apart)
						if not st.byCargo then
							st.byCargo = {}
							for _, o in ipairs(st.cargoTypes or {}) do st.byCargo[o] = 0 end
							st.byCargo[st.cargoTypes and st.cargoTypes[1] or id] = st.count or 0
						end
						st.byCargo[id] = cmd.amount
						local sum = 0
						for _, n in pairs(st.byCargo) do sum = sum + n end
						st.count = sum
						return true
					end
				end
			end
			return true
		end
		if cmd.stock == -1 then
			local c = g.fleet[cmd.entity]
			if not c then crash("ASSERT: no transport vehicle " .. tostring(cmd.entity)) end
			-- a load into a vehicle with no line: the engine's fatal assertion (DataLogger.cpp:573, 2026-11-24). The
			-- game's is not stopped by pcall (it froze): a test must check g.crashed, not only an answer's ok = false
			if type(c.line) ~= "number" or c.line < 0 then
				crash("ASSERT: DataLogger.cpp:573 transportVehicle.line.GetId() >= 0 at " .. tostring(cmd.entity))
			end
			local id = cargoId[cmd.cargoType]
			if id == nil then crash("ASSERT: no cargo type " .. tostring(cmd.cargoType)) end
			c.live = c.live or {}
			c.live.loaded = c.live.loaded or {}
			c.live.loaded[id] = cmd.amount
			return true
		end
		local st = stockOf(cmd.entity, cmd.stock)
		if st == nil then
			-- an industry's own stock (the base fake's opts.industries): through its getStockCount's table
			local ok = pcall(api.engine.system.simEntityAtStockSystem.getStockCount, cmd.entity, cmd.stock)
			if not ok then crash("ASSERT: no stock " .. tostring(cmd.stock) .. " at " .. tostring(cmd.entity)) end
			g.industries[cmd.entity].stocks[cmd.stock + 1].count = cmd.amount
			return true
		end
		if cmd.cargoType ~= nil then
			if cargoId[cmd.cargoType] == nil then crash("ASSERT: no cargo type " .. tostring(cmd.cargoType)) end
			st.byCargo = st.byCargo or {}
			-- a mixed stock by its stock id: the name is not taken, the amount goes to its default cargo type (st.default,
			-- else its last; as a game's warehouse put grain asked as bricks, 2026-11-23)
			local into = cargoId[cmd.cargoType]
			if (st.cargoType == nil or st.cargoType < 0) and st.cargoTypes and #st.cargoTypes > 0 then
				into = st.default or st.cargoTypes[#st.cargoTypes]
			end
			st.byCargo[into] = cmd.amount
			local sum = 0
			for _, n in pairs(st.byCargo) do sum = sum + n end
			st.count = sum
		else
			st.count = cmd.amount
		end
		return true
	end
	if spec.stepsPerFrame then
		local step = g.step
		g.stepsRun = 0
		g.step = function(dt)
			step(dt)
			local n = math.min(g.pendingSteps or 0, spec.stepsPerFrame)
			if spec.stepsStall then n = math.max(0, math.min(n, spec.stepsStall - g.stepsRun)) end
			if n > 0 then
				g.pendingSteps, g.stepsRun = g.pendingSteps - n, g.stepsRun + n
				g.gameTime = g.gameTime + n * (spec.stepMs or 200)
				g.updateCount = g.updateCount + n
			end
		end
	end
	local send = api.cmd.sendCommand
	api.cmd.sendCommand = function(cmd, cb)
		if type(cmd) ~= "table" or (cmd.kind ~= "debugStock" and cmd.kind ~= "debugSteps") then return send(cmd, cb) end
		if spec.sendRaises then error("sendCommand: " .. spec.sendRaises) end
		g.commands[#g.commands + 1] = cmd
		g.debugCmds[#g.debugCmds + 1] = cmd
		local success = apply(cmd)
		if cb and not spec.noCallback then cb(cmd, success) end
	end
	-- the stock lists and their owners
	local exists, getComponent = api.engine.entityExists, api.engine.getComponent
	api.engine.entityExists = function(e) return lists[e] ~= nil or owners[e] ~= nil or cons[e] ~= nil or exists(e) end
	api.engine.getComponent = function(e, kind)
		if kind == "GAME_TIME" then
			local t = getComponent(e, kind)
			t.updateCount, t.tickCount = g.updateCount, g.updateCount + 7
			return t
		end
		if spec.strictIds and e ~= api.engine.util.getWorld() and not api.engine.entityExists(e) then crash("ASSERT: getComponent of no entity " .. tostring(e)) end
		local cc = cons[e]
		if cc then
			if kind == "CONSTRUCTION" then
				return { fileName = cc.fileName or "::/warehouses/warehouse.con", subconstructions = copy(cc.subconstructions or {}),
					industries = copy(cc.industries or {}), townBuildings = copy(cc.townBuildings or {}) }
			end
			return nil
		end
		local l = lists[e]
		if kind == "STOCK_LIST" and l then
			local stocks = {}
			for k, st in ipairs(l.stocks) do
				stocks[k] = { type = st.type or 0, cargoType = st.cargoType or -1, capacity = st.capacity or 0 }
			end
			return { stocks = stocks }
		end
		local o = owners[e]
		if o and kind == o.kind then return { stockList = o.stockList, construction = o.construction } end
		if o or l then return nil end
		return getComponent(e, kind)
	end
	-- warehouses (entities --kind warehouse): the owners of kind WAREHOUSE
	local withComponent = api.engine.getEntitiesWithComponent
	api.engine.getEntitiesWithComponent = function(kind, filter)
		if kind == "WAREHOUSE" then
			local ids = {}
			for e, ow in pairs(owners) do if ow.kind == "WAREHOUSE" then ids[#ids + 1] = e end end
			table.sort(ids)
			return ids
		end
		return withComponent(kind, filter)
	end
	local sys = api.engine.system.simEntityAtStockSystem
	local count = sys.getStockCount
	sys.getStockCount = function(e, id)
		local st = stockOf(e, id)
		if st then return st.count or 0 end
		return count(e, id)
	end
	sys.getStockCountForCargoType = function(e, id, cargo)
		local st = stockOf(e, id)
		if st then return (st.byCargo or {})[cargo] or 0 end
		-- an industry's (the base fake's): its count per cargo type once one was set by name, else its whole count
		-- for a cargo type the stock takes, else 0
		local ist = g.industries[e] and (g.industries[e].stocks or {})[id + 1]
		if ist and ist.byCargo then return ist.byCargo[cargo] or 0 end
		local n = count(e, id)
		for _, c in ipairs(api.engine.util.stock.getStockCargoTypes(e, id)) do if c == cargo then return n end end
		return 0
	end
	local cargoTypesOf = api.engine.util.stock.getStockCargoTypes
	api.engine.util.stock.getStockCargoTypes = function(e, id)
		local st = stockOf(e, id)
		if st then return st.cargoTypes or (st.cargoType and st.cargoType >= 0 and { st.cargoType }) or {} end
		return cargoTypesOf(e, id)
	end
end

-- What stands on the map for around (remote_around.lua) and for naming a build's collisions: spec.things =
-- { [id] = { box = { x0, y0, z0, x1, y1, z1 }, name = "...", comps = { KIND = { fields } } } }. The octree's
-- findIntersectingEntities gives each thing whose box meets the box asked, with its bounding volume (as the engine's
-- callback, engine/system.d.tl); spec.notInOctree = { [id] = true }: not given (trees, if their asset groups are not
-- in it). BOUNDING_VOLUME reads the box too. Over what was installed before (the build's fake): its things are still
-- found. g.aroundCalls counts the octree walks. spec.octreeRaises: the walk raises.
-- the lanes of the base's town_new_medium_tram_electrified (its street template): sidewalk, road with electric
-- tram track, road, road, road with track, sidewalk; transportModes by name (installAround makes the engine's map)
function M.TRAM_ELECTRIC_LANES()
	local function lane(fwd, off, w, h, modes) return { forward = fwd, offset = off, width = w, height = h, speed = 13.89, transportModes = modes } end
	return { lane(false, 0.15, 3, 0.15, { "PERSON", "CARGO" }), lane(false, -0.5, 5, 0, { "CAR", "BUS", "TRUCK", "TRAM", "ELECTRIC_TRAM" }),
		lane(false, 0, 4, 0, { "CAR", "BUS", "TRUCK" }), lane(true, 0, 4, 0, { "CAR", "BUS", "TRUCK" }),
		lane(true, 0.5, 5, 0, { "CAR", "BUS", "TRUCK", "TRAM", "ELECTRIC_TRAM" }), lane(true, -0.15, 3, 0.15, { "PERSON", "CARGO" }) }
end

function M.installAround(g, spec)
	spec = spec or {}
	local things = spec.things or {}
	g.aroundCalls = 0
	local CT = api.type.ComponentType
	-- (these types are added to the whole fake game, also the e2e one tools/tf3ctl.py's tests run against: a module
	-- that takes a path by whether a type is there goes the path the game's own types give)
	for _, k in ipairs({ "BASE_EDGE", "BASE_NODE", "BASE_EDGE_STREET", "TRANSPORT_NETWORK", "CONSTRUCTION", "TOWN_BUILDING", "INDUSTRY",
		"SUBCONSTRUCTION", "FIELD", "TOWN", "ASSET_GROUP", "TRANSPORT_VEHICLE", "SIM_PERSON", "ANIMAL",
		"MODEL_INSTANCE_LIST", "BOUNDING_VOLUME", "TERRAIN", "WORLD", "EMISSION_GRID" }) do CT[k] = CT[k] or k end
	api.type.enum = api.type.enum or {}
	api.type.enum.RoadType = api.type.enum.RoadType or { STREET = 0, TRACK = 1 }
	api.type.enum.BaseEdgeType = api.type.enum.BaseEdgeType or { NORMAL = 0, BRIDGE = 1, TUNNEL = 2 }
	api.type.Box3 = api.type.Box3 or { new = function(lo, hi) return { min = lo, max = hi } end }
	api.type.Vec3f = api.type.Vec3f or { new = function(x, y, z) return { x = x, y = y, z = z } end }
	local function bvOf(t)
		local b = t.box
		return { bbox = { min = { x = b[1], y = b[2], z = b[3] }, max = { x = b[4], y = b[5], z = b[6] } } }
	end
	api.engine.system = api.engine.system or {}
	local oldOctree = api.engine.system.octreeSystem
	api.engine.system.octreeSystem = { findIntersectingEntities = function(box, cb)
		g.aroundCalls = g.aroundCalls + 1
		if spec.octreeRaises then error("octree gone") end
		if oldOctree then oldOctree.findIntersectingEntities(box, cb) end
		local ids = {}
		for e in pairs(things) do ids[#ids + 1] = e end
		table.sort(ids)
		for _, e in ipairs(ids) do
			local t = things[e]
			local b = t.box
			if b and not (spec.notInOctree or {})[e] and b[4] >= box.min.x and b[1] <= box.max.x
				and b[5] >= box.min.y and b[2] <= box.max.y then
				cb(e, bvOf(t))
			end
		end
	end }
	local exists = api.engine.entityExists
	api.engine.entityExists = function(e) return things[e] ~= nil or exists(e) end
	local getComponent = api.engine.getComponent
	api.engine.getComponent = function(e, kind)
		local t = things[e]
		if t then
			if kind == "BOUNDING_VOLUME" and t.box then return bvOf(t) end
			local c = t.comps and t.comps[kind]
			if c and kind == "BASE_EDGE" and type(c.roadType) == "string" then
				c = copy(c); c.roadType = api.type.enum.RoadType[c.roadType]
			end
			if c and kind == "BASE_EDGE" and type(c.type) == "string" then
				c = copy(c); c.type = (api.type.enum.BaseEdgeType or {})[c.type]
			end
			-- lanes' and network edges' transportModes given as names (as a street template writes them): the
			-- engine's map, keyed by the TransportMode enum's values; a lane list given as userdata stays as it is
			local function modeMap(list)
				if type(list) ~= "table" or type(list[1]) ~= "string" then return list end
				local m = {}
				for _, n in ipairs(list) do m[api.type.enum.TransportMode[n]] = true end
				return m
			end
			if c and kind == "BASE_EDGE" and type(c.laneConfigs) == "table" then
				c = copy(c)
				for _, lc in ipairs(c.laneConfigs) do lc.transportModes = modeMap(lc.transportModes) end
			end
			if c and kind == "TRANSPORT_NETWORK" and type(c.edges) == "table" then
				c = copy(c)
				for _, ed in ipairs(c.edges) do ed.transportModes = modeMap(ed.transportModes) end
			end
			return c
		end
		return getComponent(e, kind)
	end
	api.engine.util = api.engine.util or {}
	local getName = api.engine.util.getEntityName
	api.engine.util.getEntityName = function(e)
		if things[e] then return things[e].name or "" end
		return getName and getName(e) or ""
	end
	local sc = api.engine.system.streetConnectorSystem or {}
	api.engine.system.streetConnectorSystem = sc
	local conFor = sc.getConstructionEntityForEdge
	sc.getConstructionEntityForEdge = function(e)
		local t = things[e]
		if t then return t.construction or -1 end
		if conFor then return conFor(e) end
		return -1
	end
end


-- The engine's side of strips (remote_strips.lua): the parallel strips of tracks, over installAround's things (call
-- installAround first: the pieces, their nodes and the strips are things there, the strips with comps
-- BASE_PARALLEL_STRIP { rangeGroups = { { { edge, bounds = { b0, b1 } }, ... }, ... } } and BRIDGE { intervals }).
-- spec.strips = { [edge] = { strip, ... } } (getStrips), spec.info = { [strip] = { carrier = "RAIL", edgeType =
-- "TUNNEL", edgeTypeIndex = 0 } } (getStripInfo; isTunnel / isBridge from its edgeType, spec.tunnel / spec.bridge
-- = { [strip] = bool } over it), spec.nodeTracks = { [node] = { edge, ... } } (getNodeTrackSegments).
-- The engine's assertions, as the other fakes (a guess of where it asserts): getStrips of an entity that does not
-- exist, getStripInfo / isTunnel / isBridge of one that is not a strip, getNodeTrackSegments of one that is not a
-- node, getComponent of an entity that does not exist: g.crashed and an error.
-- spec.noSystem: no baseParallelStripSystem in this Lua state (the GUI's might not have it); spec.noUtil: no
-- api.engine.util.parallelStrip; spec.userdata: the strip components given as the engine's userdata (# and [i] or
-- .key only, no pairs); spec.getStripsRaises = { [edge] = true }: getStrips errors without a crash.
function M.installStrips(g, spec)
	spec = spec or {}
	g.stripCalls = { getStrips = 0, getStripInfo = 0, isTunnel = 0, isBridge = 0, getNodeTrackSegments = 0 }
	local CT = api.type.ComponentType
	CT.BASE_PARALLEL_STRIP = CT.BASE_PARALLEL_STRIP or "BASE_PARALLEL_STRIP"
	CT.BRIDGE = CT.BRIDGE or "BRIDGE"
	api.type.enum.Carrier = api.type.enum.Carrier or { ROAD = 0, RAIL = 1, TRAM = 2, OTHER = 3, AIR = 4, WATER = 5 }
	local function crash(msg) g.crashed = "ASSERT: " .. msg; error(g.crashed) end
	local strips, info, nodeTracks = spec.strips or {}, spec.info or {}, spec.nodeTracks or {}
	local isStrip = {}
	for s in pairs(info) do isStrip[s] = true end
	for _, list in pairs(strips) do for _, s in ipairs(list) do isStrip[s] = true end end
	-- a table as the engine's userdata: [i], .key, # and methods by name only
	local function ud(v)
		if type(v) ~= "table" or not spec.userdata then return v end
		local u = newproxy(true)
		local mt = getmetatable(u)
		mt.__index = function(_, k)
			local x = v[k]
			if x == nil and type(k) == "string" and not (k == "getTransl") then error("no field " .. k) end
			return type(x) == "table" and ud(x) or x
		end
		mt.__len = function() return #v end
		return u
	end
	local exists = api.engine.entityExists
	local getComponent = api.engine.getComponent
	api.engine.getComponent = function(e, kind)
		-- (only the kinds strips asks for: the rest of the fake game asks for others of entities it makes up)
		local mine = kind == "BASE_EDGE" or kind == "BASE_PARALLEL_STRIP" or kind == "BRIDGE"
		if mine and not exists(e) then crash("getComponent of no entity " .. tostring(e)) end
		local c = getComponent(e, kind)
		if kind == "BASE_PARALLEL_STRIP" or kind == "BRIDGE" then return ud(c) end
		return c
	end
	local util = api.engine.util
	if not spec.noSystem then
		api.engine.system.baseParallelStripSystem = { getStrips = function(e)
			g.stripCalls.getStrips = g.stripCalls.getStrips + 1
			if not exists(e) then crash("getStrips of no entity " .. tostring(e)) end
			if (spec.getStripsRaises or {})[e] then error("getStrips: not now") end
			local out = {}
			for i, s in ipairs(strips[e] or {}) do out[i] = s end
			return spec.userdata and ud(out) or out
		end }
	else
		api.engine.system.baseParallelStripSystem = nil
	end
	local function strip(s, what)
		g.stripCalls[what] = g.stripCalls[what] + 1
		if not isStrip[s] then crash(what .. " of " .. tostring(s) .. ", not a strip") end
	end
	if not spec.noUtil then
		util.parallelStrip = {
			getStripInfo = function(s)
				strip(s, "getStripInfo")
				local i = info[s] or {}
				local out = { carrier = i.carrier and api.type.enum.Carrier[i.carrier],
					edgeType = i.edgeType and api.type.enum.BaseEdgeType[i.edgeType], edgeTypeIndex = i.edgeTypeIndex }
				return spec.userdata and ud(out) or out
			end,
			isTunnel = function(s)
				strip(s, "isTunnel")
				if (spec.tunnel or {})[s] ~= nil then return spec.tunnel[s] end
				return (info[s] or {}).edgeType == "TUNNEL"
			end,
			isBridge = function(s)
				strip(s, "isBridge")
				if (spec.bridge or {})[s] ~= nil then return spec.bridge[s] end
				return (info[s] or {}).edgeType == "BRIDGE"
			end,
		}
	else
		util.parallelStrip = nil
	end
	api.engine.system.streetSystem = api.engine.system.streetSystem or {}
	local oldTracks = api.engine.system.streetSystem.getNodeTrackSegments
	api.engine.system.streetSystem.getNodeTrackSegments = function(n)
		g.stripCalls.getNodeTrackSegments = g.stripCalls.getNodeTrackSegments + 1
		if nodeTracks[n] then
			local out = {}
			for i, e in ipairs(nodeTracks[n]) do out[i] = e end
			return out
		end
		if oldTracks then return oldTracks(n) end
		crash("getNodeTrackSegments: no node " .. tostring(n))
	end
	api.res = api.res or {}
	api.res.modelRep = api.res.modelRep or {}
	local getName = api.res.modelRep.getName
	api.res.modelRep.getName = function(id)
		if (spec.modelNames or {})[id] then return spec.modelNames[id] end
		if getName then return getName(id) end
		error("no model " .. tostring(id))
	end
end


-- The engine's side of parcels (remote_parcels.lua): road pieces, their nodes, parcels and the buildings on them.
-- spec.nodes = { [node] = { x, y, z } }; spec.edges = { [edge] = { node0, node1, street (default true),
-- construction (default -1) } }; spec.parcels = { [parcel] = { edge, left (boolean), faces = { { { x, y, z }, ... } },
-- curveParam, offset, building } }: each parcel goes into its edge's ParcelData, on the side its left says
-- (spec.swapSide = { [parcel] = true }: listed on the other side than its flag, to see the mismatch count).
-- spec.fields = { left = "leftEntities", right = "rightParcels" }: the ParcelData's field names (as type.d.tl);
-- spec.noMap: getSegment2ParcelData is not there (getParcelData is); spec.noParcelType: no ComponentType.PARCEL;
-- spec.noBuildingMap; spec.userdata: the map, the ParcelData and its lists as userdata, as the engine's.
-- Only edges with a parcel are in the map (a piece in a construction may have none). Asking getParcelData for a
-- piece that is no street, getConstructionEntityForEdge for something that is no piece, or getComponent for a
-- piece / node / parcel id the engine does not have, is the engine's assertion (g.crashed).
-- g.parcelCalls: { segmentMap, parcelData, buildingMap, circle } counts.
function M.installParcels(g, spec)
	spec = spec or {}
	local nodes, edges, parcels = spec.nodes or {}, spec.edges or {}, spec.parcels or {}
	local fields = spec.fields or { left = "leftEntities", right = "rightParcels" }
	g.parcelCalls = { segmentMap = 0, parcelData = 0, buildingMap = 0, circle = 0 }
	local function crash(msg) g.crashed = msg; error(msg) end
	local function asUserdata(t)
		local u = newproxy(true)
		getmetatable(u).__index = function(_, k) return t[k] end
		getmetatable(u).__len = function() return #t end
		return u
	end
	local function wrap(t) if spec.userdata then return asUserdata(t) end return t end
	local CT = api.type.ComponentType
	CT.BASE_EDGE, CT.BASE_NODE, CT.BASE_EDGE_STREET = "BASE_EDGE", "BASE_NODE", "BASE_EDGE_STREET"
	if not spec.noParcelType then CT.PARCEL = "PARCEL" end
	-- the parcel data per edge, in id order
	local function dataOf(e)
		local l, r = {}, {}
		local ids = {}
		for p in pairs(parcels) do ids[#ids + 1] = p end
		table.sort(ids)
		for _, p in ipairs(ids) do
			local pc = parcels[p]
			if pc.edge == e then
				local left = pc.left == true
				if (spec.swapSide or {})[p] then left = not left end
				table.insert(left and l or r, p)
			end
		end
		if #l + #r == 0 then return nil end
		return wrap({ [fields.left] = wrap(l), [fields.right] = wrap(r) })
	end
	local sys = api.engine.system
	sys.parcelSystem = {
		getParcelData = function(e)
			g.parcelCalls.parcelData = g.parcelCalls.parcelData + 1
			local ed = edges[e]
			if not ed or ed.street == false then crash("ASSERT: getParcelData for " .. tostring(e) .. ", no street") end
			return dataOf(e) or wrap({ [fields.left] = wrap({}), [fields.right] = wrap({}) })
		end,
	}
	if not spec.noMap then
		sys.parcelSystem.getSegment2ParcelData = function()
			g.parcelCalls.segmentMap = g.parcelCalls.segmentMap + 1
			local m = {}
			for e in pairs(edges) do m[e] = dataOf(e) end
			return wrap(m)
		end
	end
	sys.townBuildingSystem = sys.townBuildingSystem or {}
	if not spec.noBuildingMap then
		sys.townBuildingSystem.getParcel2BuildingMap = function()
			g.parcelCalls.buildingMap = g.parcelCalls.buildingMap + 1
			local m = {}
			for p, pc in pairs(parcels) do if pc.building then m[p] = pc.building end end
			return wrap(m)
		end
	end
	sys.streetConnectorSystem = sys.streetConnectorSystem or {}
	local conFor = sys.streetConnectorSystem.getConstructionEntityForEdge
	sys.streetConnectorSystem.getConstructionEntityForEdge = function(e)
		if edges[e] then return edges[e].construction or -1 end
		if conFor then return conFor(e) end
		crash("ASSERT: getConstructionEntityForEdge for " .. tostring(e) .. ", no edge")
	end
	local exists, getComponent = api.engine.entityExists, api.engine.getComponent
	api.engine.entityExists = function(e)
		return nodes[e] ~= nil or edges[e] ~= nil or parcels[e] ~= nil or exists(e)
	end
	api.engine.getComponent = function(e, kind)
		if kind == "BASE_NODE" and nodes[e] then
			local n = nodes[e]
			return { position = { x = n[1], y = n[2], z = n[3] } }
		end
		if kind == "BASE_EDGE" and edges[e] then return { node0 = edges[e].node0, node1 = edges[e].node1, type = 0 } end
		if kind == "BASE_EDGE_STREET" and edges[e] then
			if edges[e].street == false then return nil end
			return { precedenceNode0 = 0, precedenceNode1 = 0 }
		end
		if kind == "PARCEL" and parcels[e] then
			local pc = parcels[e]
			local faces = {}
			for i, f in ipairs(pc.faces or {}) do
				local pts = {}
				for j, p in ipairs(f) do pts[j] = { x = p[1], y = p[2], z = p[3] } end
				faces[i] = { points = wrap(pts), collision = {} }
			end
			return { streetSegment = pc.edge, left = pc.left == true, curveParam = pc.curveParam or 0,
				offset = pc.offset or 0, faces = wrap(faces) }
		end
		if nodes[e] or edges[e] or parcels[e] then return nil end
		-- (what an earlier install has, e.g. the build fake's pieces, which its entityExists does not list, is its own)
		local v = getComponent(e, kind)
		if v == nil and (kind == "BASE_EDGE" or kind == "BASE_NODE" or kind == "PARCEL" or kind == "BASE_EDGE_STREET")
			and not exists(e) then
			crash("ASSERT: getComponent " .. tostring(kind) .. " of a missing entity " .. tostring(e))
		end
		return v
	end
	-- the octree: the pieces with an end in the circle, or found by what was installed before
	api.engine.util = api.engine.util or {}
	local oldOctree = api.engine.util.octree
	api.engine.util.octree = { findEntitiesInCircle = function(c, r, kind)
		g.parcelCalls.circle = g.parcelCalls.circle + 1
		local out = {}
		if oldOctree and oldOctree.findEntitiesInCircle then
			for _, e in ipairs(oldOctree.findEntitiesInCircle(c, r, kind) or {}) do out[#out + 1] = e end
		end
		if kind ~= "BASE_EDGE" then return out end
		for e, ed in pairs(edges) do
			for _, n in ipairs({ ed.node0, ed.node1 }) do
				local p = nodes[n]
				if p and math.sqrt((p[1] - c.x) ^ 2 + (p[2] - c.y) ^ 2) <= r then out[#out + 1] = e break end
			end
		end
		return out
	end }
	api.type.Vec2f = api.type.Vec2f or { new = function(x, y) return { x = x, y = y } end }
end

-- The engine's side of town develop / town size (remote_town_grow.lua): makeTownDevelopAtCmd and
-- makeTownUpdateSizeCmd, towns with a TOWN component and town buildings with a bounding box. g's opts.townBuildings
-- (stations --catchment's shape, plus pos = { x, y }) is where new buildings go.
-- spec.towns = { [entity] = { sizeFactors = { r, c, i }, initial = { r, c, i } } }. A develop adds one building of
-- the nearest town (by spec.townPos) at the point, its kind going round residential, commercial, industrial, and with
-- upgrade nothing new (the levels only); updateAll adds one building per factor step over 1. spec.missing =
-- { develop = true, size = true, vec2f = true }: that function nil; spec.refuse = { develop = true | n, size = true }:
-- the callback says no success (n: only the n-th develop); spec.makeRaises / sendRaises: this text raised;
-- spec.noCallback: never a callback; spec.callableApi: the functions as locked callable tables. The arguments are
-- checked as the types have them (a Vec2f from api.type.Vec2f.new, booleans, 3 numbers, a town entity): anything else
-- is the engine's assertion (g.crashed). g.townGrowCmds: every command sent, as made.
function M.installTownGrow(g, opts, spec)
	spec = spec or {}
	opts.townBuildings = opts.townBuildings or {}
	local towns = spec.towns or {}
	local missing = spec.missing or {}
	g.townGrowCmds = {}
	local function crash(msg) g.crashed = "ASSERT: " .. msg; error(g.crashed) end
	local function callable(f)
		if not spec.callableApi then return f end
		return setmetatable({}, { __call = function(_, ...) return f(...) end, __metatable = "locked" })
	end
	local vecs = setmetatable({}, { __mode = "k" })
	api.type.Vec2f = nil
	if not missing.vec2f then
		api.type.Vec2f = { new = callable(function(x, y)
			if type(x) ~= "number" or type(y) ~= "number" then crash("Vec2f.new: two numbers") end
			local v = { x = x, y = y }
			vecs[v] = true
			return v
		end) }
	end
	api.cmd.makeTownDevelopAtCmd = not missing.develop and callable(function(...)
		if spec.makeRaises then error(spec.makeRaises) end
		local pos, streets, upgrade = ...
		if not vecs[pos] then crash("makeTownDevelopAtCmd: position is no Vec2f") end
		if type(streets) ~= "boolean" or type(upgrade) ~= "boolean" then crash("makeTownDevelopAtCmd: booleans") end
		return { kind = "townDevelop", position = { x = pos.x, y = pos.y }, developStreets = streets,
			upgradeBuildings = upgrade, nargs = select("#", ...) }
	end) or nil
	api.cmd.makeTownUpdateSizeCmd = not missing.size and callable(function(...)
		if spec.makeRaises then error(spec.makeRaises) end
		local e, f, all = ...
		if not towns[e] then crash("makeTownUpdateSizeCmd: no town " .. tostring(e)) end
		if type(f) ~= "table" or #f ~= 3 then crash("makeTownUpdateSizeCmd: 3 size factors") end
		for i = 1, 3 do if type(f[i]) ~= "number" then crash("makeTownUpdateSizeCmd: 3 numbers") end end
		if type(all) ~= "boolean" then crash("makeTownUpdateSizeCmd: updateAllBuildings a boolean") end
		return { kind = "townSize", townEntity = e, landUseSizeFactors = copy(f), updateAllBuildings = all,
			nargs = select("#", ...) }
	end) or nil
	local nextId, kinds, developed = 90001, { "RESIDENTIAL", "COMMERCIAL", "INDUSTRIAL" }, 0
	local function addBuilding(town, x, y)
		local b = nextId
		nextId = nextId + 1
		local n = 0
		for _ in pairs(opts.townBuildings) do n = n + 1 end
		opts.townBuildings[b] = { town = town, kind = kinds[n % 3 + 1], capacity = 4, pos = { x = x, y = y } }
	end
	local function apply(cmd)
		if cmd.kind == "townDevelop" then
			developed = developed + 1
			local r = (spec.refuse or {}).develop
			if r == true or r == developed then return false end
			if cmd.upgradeBuildings then return true end
			local best, bd
			for t, p in pairs(spec.townPos or {}) do
				local d = (p.x - cmd.position.x) ^ 2 + (p.y - cmd.position.y) ^ 2
				if not bd or d < bd then best, bd = t, d end
			end
			if best then addBuilding(best, cmd.position.x, cmd.position.y) end
			return true
		end
		if (spec.refuse or {}).size then return false end
		local t = towns[cmd.townEntity]
		local old = t.sizeFactors
		t.sizeFactors = copy(cmd.landUseSizeFactors)
		if cmd.updateAllBuildings then
			for i = 1, 3 do
				for _ = 1, math.max(0, math.floor(cmd.landUseSizeFactors[i] - (old[i] or 1))) do
					addBuilding(cmd.townEntity, 0, 0)
				end
			end
		end
		return true
	end
	local send = api.cmd.sendCommand
	api.cmd.sendCommand = function(cmd, cb)
		if type(cmd) ~= "table" or (cmd.kind ~= "townDevelop" and cmd.kind ~= "townSize") then return send(cmd, cb) end
		if spec.sendRaises then error("sendCommand: " .. spec.sendRaises) end
		g.townGrowCmds[#g.townGrowCmds + 1] = cmd
		local success = apply(cmd)
		if cb and not spec.noCallback then cb(cmd, success) end
	end
	local exists, getComponent = api.engine.entityExists, api.engine.getComponent
	api.engine.entityExists = function(e) return towns[e] ~= nil or opts.townBuildings[e] ~= nil or exists(e) end
	api.engine.getComponent = function(e, kind)
		if kind == "TOWN" then
			local t = towns[e]
			if not t then return nil end
			return { sizeFactors = copy(t.sizeFactors or { 1, 1, 1 }), initialLandUseCapacities = copy(t.initial or { 100, 50, 50 }),
				developmentActive = true }
		end
		if kind == "BOUNDING_VOLUME" then
			local tb = opts.townBuildings[e]
			if tb and tb.pos then
				return { bbox = { min = { x = tb.pos.x - 5, y = tb.pos.y - 5, z = 0 }, max = { x = tb.pos.x + 5, y = tb.pos.y + 5, z = 10 } } }
			end
		end
		return getComponent(e, kind)
	end
end

-- real-time mode for the Python end-to-end test
-- The base's company scripts (remote_company.lua): company.gs and company_progression.gs as GAME_SCRIPT entities
-- with a .state, and what the base's handlers do with initNewGameFromMap (game_mechanics/company, read 2026-11-23).
-- spec.company / spec.growth: their states at the start (nil: {}; false: that script not running). spec.delivers (default true): a sent initNewGameFromMap with src "" and
-- id "" reaches the scripts: company gets basePopulation = the residential capacities summed (as
-- computeWorldPopulation) and companyStates = {}, growth an empty companyState; spec.growthPlayer: then also the
-- player's entry (as company_growth's update makes it). spec.refuse: the callback says no success.
-- spec.mission: hasStartedAsMission. g.companyEvents: every script event sent with id "".
-- An event of another id, or a name the base has no start for, changes nothing. A newgame (app.startGame) gets the
-- start event, as measured 2026-11-23: basePopulation = the towns' population then (0 with no towns: set
-- opts.townCapacities before the start), an empty company_growth state; spec.startWithoutEvent: no event, {}.
-- The start event's effect is the same function as a sent one's (company, growth from opts.townCapacities now).
M.COMPANY_ENTITY, M.GROWTH_ENTITY = 4501, 4502
function M.installCompany(g, opts, spec)
	spec = spec or {}
	local st = { company = spec.company, growth = spec.growth }
	if st.company == nil then st.company = {} end
	if st.growth == nil then st.growth = {} end
	g.companyState = st
	g.companyEvents = {}
	local function startEvent()
		local pop = 0
		for _, caps in pairs(opts.townCapacities or {}) do pop = pop + (caps[1] or 0) end
		if st.company then
			st.company = { companyStates = {}, basePopulation = pop, version = 4 }
			g.speedup = 1 -- company.script sends makeGameSetSpeedCmd(1) on this event
		end
		if st.growth then
			-- the event sets { companyState = {} }; read back empty in a game (growth.initialized stayed false, e2e
			-- 2026-11-23). spec.growthPlayer: the entry company_growth's update makes again at once
			st.growth = {}
			if spec.growthPlayer then st.growth = { companyState = { [99] = copy(spec.growthPlayer) } } end
		end
	end
	g.onStart = function()
		if spec.startWithoutEvent then st.company, st.growth = {}, {} else startEvent() end
	end
	local gss = api.engine.system.gameScriptSystem
	local getEntity = gss.getEntityForGameScript
	gss.getEntityForGameScript = function(name)
		if name == "::/game_mechanics/company/company.gs" then return st.company == false and -1 or M.COMPANY_ENTITY end
		-- the base's util spells it without the slash (company_progression_util.tl)
		if name == "::game_mechanics/company/company_progression.gs" then
			return st.growth == false and -1 or M.GROWTH_ENTITY
		end
		return getEntity(name)
	end
	local getComponent = api.engine.getComponent
	api.engine.getComponent = function(e, kind)
		if kind == "GAME_SCRIPT" and e == M.COMPANY_ENTITY and st.company then return { state = copy(st.company) } end
		if kind == "GAME_SCRIPT" and e == M.GROWTH_ENTITY and st.growth then return { state = copy(st.growth) } end
		return getComponent(e, kind)
	end
	api.engine.util.hasStartedAsMission = function() return spec.mission == true end
	local send = api.cmd.sendCommand
	api.cmd.sendCommand = function(cmd, cb)
		-- (fake_tc.lua makes script events of its own kind, tcEvent)
		local ev = type(cmd) == "table" and (cmd.kind == "scriptEvent" or cmd.kind == "tcEvent")
		if not ev or cmd.id ~= "" then return send(cmd, cb) end
		g.commands[#g.commands + 1] = cmd
		g.companyEvents[#g.companyEvents + 1] = cmd
		if spec.refuse then if cb then cb(cmd, false) end return end
		if cmd.src == "" and cmd.name == "initNewGameFromMap" and spec.delivers ~= false then startEvent() end
		if cb then cb(cmd, true) end
	end
end

-- The engine's side of town connections / town connect (remote_town_connect.lua). spec.towns: the map's towns in
-- its order { { entity, name, x, y } }; spec.connections: the map's townConnections, index pairs in spec.base's
-- numbering (default 0); spec.defaults: what getDefaultTownConnections gives; spec.detect: the connections an auto
-- detect leaves; spec.closest = { [construction] = town }; spec.missing = { map, defaults, auto, build = true }: nil;
-- spec.refuse: the callback says no success; spec.noCallback. The commands check what the engine would assert: towns
-- that are towns, index pairs in range in spec.base's numbering, keep a boolean (anything else: g.crashed). A build
-- adds its connections to the map (and keep false removes the others). g.townConnectCmds: every command sent.
function M.installTownConnect(g, opts, spec)
	spec = spec or {}
	local base = spec.base or 0
	local missing = spec.missing or {}
	local conns = copy(spec.connections or {})
	g.townConnectCmds = {}
	local function crash(msg) g.crashed = "ASSERT: " .. msg; error(g.crashed) end
	local isTown = {}
	for _, t in ipairs(spec.towns or {}) do isTown[t.entity] = true end
	local function mapIndex(e)
		for i, t in ipairs(spec.towns or {}) do if t.entity == e then return i - 1 + base end end
	end
	api.engine.terrain = api.engine.terrain or {}
	api.engine.terrain.makeMapFromGame = not missing.map and function(h, towns, inds, assets)
		if h ~= false or towns ~= true then crash("makeMapFromGame: this fake knows (false, true, ...) only") end
		local list = {}
		for i, t in ipairs(spec.towns or {}) do
			list[i] = { existing = t.entity, name = t.name, pos = { x = t.x or 0, y = t.y or 0 } }
		end
		return { towns = list, townConnections = copy(conns) }
	end or nil
	api.engine.mapgen = api.engine.mapgen or {}
	api.engine.mapgen.getDefaultTownConnections = not missing.defaults and function(towns)
		if type(towns) ~= "table" then crash("getDefaultTownConnections: a town list") end
		return copy(spec.defaults or {})
	end or nil
	local sc = api.engine.system.streetConnectorSystem
	sc.getConstructionClosestTown = function(c) return (spec.closest or {})[c] or -1 end
	local function townList(list)
		if type(list) ~= "table" then crash("a list of towns") end
		for _, e in ipairs(list) do if not isTown[e] then crash("no town " .. tostring(e)) end end
	end
	api.cmd.makeTownAutoDetectConnectionsCmd = not missing.auto and function(list)
		townList(list)
		return { kind = "townAutoDetect", townEntities = copy(list) }
	end or nil
	api.cmd.makeTownConnectWithIndustriesCmd = not missing.build and function(list, cs, keep)
		townList(list)
		if type(keep) ~= "boolean" then crash("keep: a boolean") end
		for _, p in ipairs(cs) do
			for k = 1, 2 do
				local i = p[k]
				if type(i) ~= "number" or i < base or i > #list - 1 + base then crash("connection index out of range: " .. tostring(i)) end
			end
		end
		return { kind = "townConnectBuild", townEntities = copy(list), connections = copy(cs), keep = keep }
	end or nil
	local send = api.cmd.sendCommand
	api.cmd.sendCommand = function(cmd, cb)
		if type(cmd) ~= "table" or (cmd.kind ~= "townAutoDetect" and cmd.kind ~= "townConnectBuild") then
			return send(cmd, cb)
		end
		g.commands[#g.commands + 1] = cmd
		g.townConnectCmds[#g.townConnectCmds + 1] = cmd
		if spec.noCallback then return end
		if spec.refuse then if cb then cb(cmd, false) end return end
		if cmd.kind == "townAutoDetect" then
			conns = copy(spec.detect or conns)
		else
			if not cmd.keep then conns = {} end
			for _, p in ipairs(cmd.connections) do
				local a, b = cmd.townEntities[p[1] + 1 - base], cmd.townEntities[p[2] + 1 - base]
				conns[#conns + 1] = { mapIndex(a), mapIndex(b) }
			end
		end
		if cb then cb(cmd, true) end
	end
end

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
	}, firstUploadOf = "hummer_force_unload_default_1" } or nil
	-- modhub-update: the force unload one is on mod.io already (mod 6543965, public) and an upload updates it
	if arg[4] == "modhub-update" then
		modhub = { fileidDir = dir .. "/staging_area", staging = {
			{ folder = "hummer_force_unload_default_1", title = "Force Unload by Default", modhubId = "6543965",
				details = { visible = true, title = "Auto Force Unload", modId = "6543965", version = "10001" },
				publish = { modId = "6543965" } },
			{ folder = "example_mod_1", title = "Example" },
		} }
	end
	local g = M.new(dir, { saves = saves, maxSpeed = 40, menu = arg[3] == "menu", modhub = modhub,
		-- the sample of a mod's own commands (examples/remote_probe_ext_sample), for tf3ctl mod
		installed = { "example_mod", "hummer_remote_probe_ext_sample" },
		extMods = { hummer_remote_probe_ext_sample = { file = here .. "/examples/remote_probe_ext_sample/content/remote_probe_ext.lua" } },
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
		water = function(x) return x >= 1000 end, waterLevel = 5,
		streets = { ["::/infrastructure/street/town/town_old_medium.street_template"] = { yearTo = 1940, cost = 10 },
			["::/infrastructure/street/town/town_new_medium.street_template"] = { yearFrom = 1940, cost = 20 } } })
	-- the debug commands (stock set, steps): the industry's stocks, 200 ms of game time a step; a warehouse
	-- (construction 46840, its subconstruction 46841 with WAREHOUSE, stock list 46842: a universal stock and a
	-- specialized one)
	M.installDebug(g, { stepsPerFrame = 5,
		constructions = { [46840] = { subconstructions = { 46841 } } },
		owners = { [46841] = { kind = "WAREHOUSE", stockList = 46842, construction = 46840 } },
		stockLists = { [46842] = { stocks = {
			{ type = 2, cargoType = -1, cargoTypes = { 1, 2 }, capacity = 1000, count = 0, byCargo = {} },
			{ type = 2, cargoType = 2, capacity = 500, count = 0 } } } } })
	-- the base's company scripts: a save with its state (basePopulation 500); a newgame gets the start event
	-- town connections: the two towns in the map's order, not connected; the coal mine is Emsworth's
	M.installTownConnect(g, {}, { towns = { { entity = 11, name = "Emsworth" }, { entity = 12, name = "Emsworth Bay", x = 2000 } },
		connections = {}, defaults = { { 0, 1 } }, closest = { [5100] = 11 } })
	M.installCompany(g, { townCapacities = { [11] = { 140, 20, 30 } } },
		{ company = { basePopulation = 500, companyStates = {}, version = 3 }, growth = { companyState = {} } })
	-- parcels: a street 9010 with two parcels on the left (one built on) and one on the right, and a piece 9011 of
	-- construction 9900 with none, far from the build fake's pieces (y 5000)
	M.installParcels(g, { nodes = { [9001] = { 0, 5000, 0 }, [9002] = { 100, 5000, 0 }, [9003] = { 200, 5000, 0 } },
		edges = { [9010] = { node0 = 9001, node1 = 9002 }, [9011] = { node0 = 9002, node1 = 9003, construction = 9900 } },
		parcels = { [9101] = { edge = 9010, left = true, faces = { { { 0, 5005, 0 }, { 10, 5005, 0 }, { 10, 5025, 0 }, { 0, 5025, 0 } } } },
			[9102] = { edge = 9010, left = true, building = 9201 }, [9103] = { edge = 9010, left = false } } })
	-- around: a house of town 9700 (its building 9601 and construction 9602) and a field, far from the rest (y 7000)
	M.installAround(g, { things = {
		[9601] = { box = { 10, 7010, 0, 25, 7025, 10 }, comps = { TOWN_BUILDING = { town = 9700, construction = 9602 } } },
		[9602] = { box = { 10, 7010, 0, 25, 7025, 10 }, comps = { CONSTRUCTION = { fileName = "building/res.con" } } },
		[9604] = { box = { 60, 7000, 0, 100, 7040, 0.5 }, comps = { FIELD = {} } },
		[9700] = { box = { -300, 6700, 0, 300, 7300, 30 }, name = "Fakeham", comps = { TOWN = {} } },
		-- lanes: an electric tram street (the base's town_new_medium_tram_electrified lanes: track on the outer
		-- road lanes), west to east at y 7400
		[9620] = { box = { -50, 7392, 0, 50, 7408, 1 }, comps = { BASE_EDGE = { roadType = "STREET", type = "NORMAL",
			roadTemplate = "town_new_medium_tram_electrified.lua", node0 = 9621, node1 = 9622,
			position0 = { x = -50, y = 7400, z = 0 }, position1 = { x = 50, y = 7400, z = 0 },
			laneConfigs = M.TRAM_ELECTRIC_LANES() }, BASE_EDGE_STREET = {} } } } })
	-- strips: a double track tunnel at y 7600 (track 9630 at y 7600, track 9631 5 m to its right), one strip 9640
	-- with one range group holding both (a group is a section cut across, as seen in a game 2026-11-26); the second
	-- track ends in a dead end
	local function tunnelTrack(n0, n1, y)
		return { box = { -50, y - 1, -20, 50, y + 1, 0 }, comps = { BASE_EDGE = { roadType = "TRACK", type = "TUNNEL",
			typeIndex = 0, node0 = n0, node1 = n1, position0 = { x = -50, y = y, z = -10 },
			position1 = { x = 50, y = y, z = -10 }, tangent0 = { x = 100, y = 0, z = 0 }, tangent1 = { x = 100, y = 0, z = 0 } } } }
	end
	M.installAround(g, { things = {
		[9630] = tunnelTrack(9632, 9633, 7600), [9631] = tunnelTrack(9634, 9635, 7595),
		[9632] = { comps = {} }, [9633] = { comps = {} }, [9634] = { comps = {} }, [9635] = { comps = {} },
		[9640] = { comps = { BASE_PARALLEL_STRIP = { rangeGroups = { { { edge = 9630, bounds = { 0, 1 } },
			{ edge = 9631, bounds = { 0, 1 } } } } } } } } })
	M.installStrips(g, { strips = { [9630] = { 9640 }, [9631] = { 9640 } },
		info = { [9640] = { carrier = "RAIL", edgeType = "TUNNEL", edgeTypeIndex = 0 } },
		nodeTracks = { [9632] = { 9630, 9629 }, [9633] = { 9630, 9628 }, [9634] = { 9631, 9627 }, [9635] = { 9631 } } })
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

-- Running costs (remote_runcost.lua) and the probe's game script (remote_gs.script.lua). The models' metadata
-- becomes one object per model, the resource of the process: what one Lua state writes, the other reads (as
-- price_probe saw in game, 2026-11-16). spec.maintenance = { [id] = { runningCosts, ... } } (default for each
-- vehicle model: lifespan 20, runningCosts price / 6, runningCostScale 1, maintenanceScale 1, penalty 0.1);
-- spec.readOnly = "gui" | "script" | "both": a write from that state raises the engine's "cannot write to read only
-- member" (seen for street costs, 2026-11-16); spec.copies: get hands out a copy (a write does not stick);
-- spec.noDelivery: script events never reach the game script; spec.finance = { header = { "1899", "1900" },
-- rows = { ROAD = { { type, maintenance, construction, values } } }, total, balance } for computeFinanceTable
-- (TRAM gives ROAD's rows unless given); spec.financeRaises. g.luaState is "script" while the game script runs.
-- getRunningCost: the sum over the vehicle's parts of runningCosts x runningCostScale, read now.
M.JOURNAL = {
	Type = { LOAN = 0, INTEREST = 1, CONSTRUCTION = 2, ACQUISITION = 3, MAINTENANCE = 4, INCOME = 5, OTHER = 7, SUBSIDY = 8 },
	Maintenance = { VEHICLE = 0, INFRASTRUCTURE = 1, OTHER = 2, VEHICLE_MAINTENANCE = 3 },
	Construction = { STREET = 0, TRACK = 1, SIGNAL = 2, STATION = 3, DEPOT = 4, BULLDOZER = 5, WAREHOUSE = 6, OTHER = 7 },
	Carrier = { ROAD = 0, RAIL = 1, TRAM = 2, OTHER = 3, AIR = 4, WATER = 5 },
}
function M.installRunningCosts(g, spec)
	spec = spec or {}
	local here = (debug.getinfo(1, "S").source:match("^@(.*)/tests/") or ".")
	g.luaState = "gui"
	local meta = {}
	local function readOnlyHere()
		local ro = spec.readOnly
		return ro == "both" or ro == g.luaState
	end
	local function guarded(t, what)
		local u = newproxy(true)
		local mt = getmetatable(u)
		mt.__index = function(_, k) return t[k] end
		mt.__newindex = function(_, k, v)
			if readOnlyHere() then error("cannot write to read only member '" .. tostring(k) .. "'", 0) end
			if t[k] == nil then error("no member named '" .. tostring(k) .. "' in " .. what, 0) end
			t[k] = tonumber(v) or v
		end
		return u, t
	end
	local function metaOf(id)
		if meta[id] then return meta[id] end
		local m = g.models[id]
		if not m then return nil end
		local mt = copy((spec.maintenance or {})[id] or {})
		local defaults = { lifespan = 20, runningCosts = (m.price or 0) / 6, runningCostScale = 1, maintenanceScale = 1,
			topSpeedMaintenanceFactorPenaltyPerLevel = 0.1 }
		for k, v in pairs(defaults) do if mt[k] == nil then mt[k] = v end end
		local maint, raw = guarded(mt, "Maintenance")
		local cost, rawCost = guarded({ price = m.price, priceScale = m.priceScale or 1 }, "Cost")
		meta[id] = { metadata = { cost = cost, maintenance = maint,
			transportVehicle = m.vehicle and { compartments = { {}, {} } } or nil }, raw = raw, rawCost = rawCost }
		return meta[id]
	end
	g.runningCostMeta = function(id) local m = metaOf(id); return m and m.raw end
	local rep = api.res.modelRep
	rep.get = function(id)
		local m = metaOf(id)
		if not m then return nil end
		if spec.copies then
			return { metadata = { cost = copy(m.rawCost), maintenance = copy(m.raw),
				transportVehicle = m.metadata.transportVehicle } }
		end
		return { metadata = m.metadata }
	end
	api.engine.util.vehicle.getRunningCost = function(e)
		local c = g.fleet[e]
		if not c then error("ASSERT: no transport vehicle " .. tostring(e)) end
		local sum = 0
		for _, p in ipairs(c.vehicles) do
			local m = metaOf(p.part.modelId)
			sum = sum + m.raw.runningCosts * m.raw.runningCostScale
		end
		return sum
	end
	for k, v in pairs(M.JOURNAL) do api.type.JournalEntry[k] = v end
	api.type.ChartConfig = { new = function() return { interval = 0, count = 0, minCount = 0, yStepScale = 1 } end }
	api.engine.util.finance.computeFinanceTable = function(player, config)
		g.financeAsked = { player = player, count = config.count }
		if spec.financeRaises then error("std::exception") end
		local f = spec.finance or {}
		local rows = copy(f.rows or {})
		if rows.TRAM == nil then rows.TRAM = rows.ROAD end
		local keys = {}
		local fd = { header = copy(f.header or { "1899", "1900" }), total = copy(f.total or {}), balance = copy(f.balance or {}) }
		function fd.foreach_transport(self, fn, carrier)
			assert(self == fd, "foreach_transport is a method")
			for name, c in pairs(M.JOURNAL.Carrier) do
				if c == carrier then
					for _, r in ipairs(rows[name] or {}) do
						local key = #keys + 1
						keys[key] = { M.JOURNAL.Type[r.type], r.maintenance and M.JOURNAL.Maintenance[r.maintenance] or 0,
							r.construction and M.JOURNAL.Construction[r.construction] or 0 }
						fn(key, copy(r.values or {}))
					end
				end
			end
		end
		function fd.unfoldKey(self, key)
			assert(self == fd, "unfoldKey is a method")
			return keys[key]
		end
		return fd
	end
	-- the game script: loaded as the engine would, with its own state
	_G.data = nil
	dofile(here .. "/content/remote_gs.script.lua")
	local gs = _G.data()
	_G.data = nil
	g.gs = gs
	g.gsValue, g.gsSubs, g.gsDelivered = nil, {}, {}
	local state = {
		get = function() return copy(g.gsValue) end,
		set = function(_, v) g.gsValue = copy(v) end,
		hasEventSubscriptions = function() return next(g.gsSubs) ~= nil end,
		subscribeToEvent = function(_, name) g.gsSubs[name] = true end,
		subscribeToAllEvents = function() g.gsSubs["*"] = true end,
		subscribeToNoEvents = function() g.gsSubs = {} end,
	}
	state.get = function(self) assert(self == state, "get is a method"); return copy(g.gsValue) end
	g.gsState = state
	local ro = {}
	ro.get = function(self) assert(self == ro, "get is a method"); return copy(g.gsValue) end
	g.gsReadOnly = ro
	local function asScript(fn, ...)
		local was = g.luaState
		g.luaState = "script"
		local ok, err = pcall(fn, ...)
		g.luaState = was
		if not ok then error(err, 0) end
	end
	local pending = {}
	local send = api.cmd.sendCommand
	api.cmd.sendCommand = function(cmd, cb)
		if type(cmd) == "table" and cmd.kind == "scriptEvent" and cmd.id == "hummer_remote_probe.runningCosts" then
			g.runcostEvents = (g.runcostEvents or 0) + 1
			if (g.gsSubs[cmd.name] or g.gsSubs["*"]) and not spec.noDelivery then pending[#pending + 1] = copy(cmd) end
		end
		return send(cmd, cb)
	end
	local step = g.step
	g.step = function(dt)
		-- the game script first (its update, then the commands of the last frame), as the engine runs it
		if not g.menu then
			asScript(gs.update, nil, state, dt or 1 / 30)
			local due = pending
			pending = {}
			for _, cmd in ipairs(due) do
				g.gsDelivered[#g.gsDelivered + 1] = cmd
				asScript(gs.handleEvent, nil, state, cmd.src, cmd.id, cmd.name, cmd.param)
			end
		end
		return step(dt)
	end
end

return M
