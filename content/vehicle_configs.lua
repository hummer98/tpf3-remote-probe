-- Vehicle configs as the base builds them, and the gui way of the vehicle commands. Required by both Lua states
-- of the remote probe: the guiUpdate script (remote_vehicles.lua: the cmd way, and what it reads back) and the
-- speed control's react recipe (gui/remote_speed.script.lua: the gui way).
--
-- Why the gui way runs in the recipe: the base's vehicle_react_util.tl registers a react recipe when it loads,
-- and react.RegisterRecipe fails in the guiUpdate state ("react.lua:298: table index is nil", 2026-11-16 12:24
-- JST: the recipe id comes from the react backend, which only react states have). The vehicle store itself runs
-- in a react state, and other base modules (music_player.tl) load in our recipe's join.
local M = {}

M.VEHICLE_UTIL = "/gui/line_vehicle_mgmt/vehicle_util.tl"
M.VEHICLE_REACT_UTIL = "/gui/line_vehicle_mgmt/vehicle_react_util.tl"

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

-- one part as the store builds it (vehicle_util.makePart); the base function itself when it loads
function M.makePart(req, modelId)
	local okU, vu = pcall(req, M.VEHICLE_UTIL)
	if okU and type(vu) == "table" and type(vu.makePart) == "function" then return vu.makePart(modelId, true, nil) end
	local part = api.type.TransportVehiclePart.new()
	part.part.modelId = modelId
	local tv = api.res.modelRep.get(modelId).metadata.transportVehicle
	local lcs = {}
	for _ in ipairs(toList(tv.compartments)) do
		local lc = api.type.LoadConfig.new()
		lc.loadConfigIndex = 0
		lcs[#lcs + 1] = lc
	end
	part.part.reversed = false
	part.part.compartment2loadConfig = lcs
	return part
end

-- a single-model vehicle, as the store's buy button makes it
function M.newConfig(req, modelId)
	local config = api.type.TransportVehicleConfig.new()
	config.vehicles = { M.makePart(req, modelId) }
	config.vehicleGroups = { 1 } -- not a multiple unit
	config.muFileNames = {}
	return config
end

-- as manager_window.tl duplicateVehicles: a copy of the vehicle's config whose parts are new. Returns the config
-- and the parts' model ids.
function M.cloneConfig(vehicleConfig)
	local config = api.type.TransportVehicleConfig.new(vehicleConfig)
	local parts, modelIds = {}, {}
	for _, p in ipairs(toList(config.vehicles)) do
		p.purchaseTime = 0
		p.maintenanceState = 1
		parts[#parts + 1] = p
		modelIds[#modelIds + 1] = tonumber(p.part.modelId)
	end
	config.vehicles = parts
	return config, modelIds
end

-- autoLoadConfig as HandleVehicleChanges sets it: one true per compartment. The engine asserts that both lists
-- have the same size (UpdateConfigFromModelIds, vehicle_util_engine.cpp:353) and the assertion kills the game,
-- uncatchable by pcall: a cmd buy sent with it empty crashed TF3 (2026-11-16 13:21 JST). So the cmd way
-- leaves out only the purchaseTime stamp, which is what it is there to test.
function M.fitAutoLoad(config)
	local parts = {}
	for _, p in ipairs(toList(config.vehicles)) do
		local n = #toList(p.part.compartment2loadConfig)
		local list = {}
		for i = 1, n do list[i] = true end
		p.autoLoadConfig = list
		parts[#parts + 1] = p
	end
	config.vehicles = parts
	return config
end

-- { modelId, purchaseTime } per part, in order: a pair, so a part without one of them cannot shift the rest
function M.partsOf(list)
	local out = {}
	for _, p in ipairs(toList(list)) do
		local part = field(p, "part")
		out[#out + 1] = { modelId = tonumber(part and field(part, "modelId")), purchaseTime = tonumber(field(p, "purchaseTime")) }
	end
	return out
end

-- Failure.Reason (api/type.d.tl, 40444) by name, and the base line manager's text for the ones it names
-- (manager_window.tl, cannotAssignToLine). "Unkown" is the engine's own spelling.
M.FAILURE_REASONS = { "Unkown", "NoPath", "NoElectric", "NoTram", "NoTramButTramTrack", "NoTramTrackButRail", "NoRail",
	"NoRoad", "NoSmallAircraft", "NoSmallShip" }
M.FAILURE_TEXTS = { NoElectric = "Missing electric tracks.", NoTram = "Missing tram tracks.",
	NoTramButTramTrack = "Incompatible tracks.", NoTramTrackButRail = "Missing tram support on tracks.",
	NoSmallAircraft = "No path for big airplanes.", NoSmallShip = "No path for big ships." }

-- a Failure.Reason value by name; unknown: the value as text, so a new value shows up instead of vanishing
function M.failureName(v)
	if v == nil then return nil end
	local okE, enum = pcall(function() return api.type.Failure.Reason end)
	for _, n in ipairs(M.FAILURE_REASONS) do
		local ok, x = pcall(function() return enum[n] end)
		if okE and ok and x ~= nil and x == v then return n end
	end
	return tostring(v)
end

-- why the engine would not put vehicle e on line: the base line manager asks the same after a refused
-- makeVehicleSetLineCmd (getFailedPathReason, fullLine true). { reason, message, position } or { reasonError }.
function M.failedPathReason(e, line)
	local ok, f = pcall(function() return api.engine.util.line.getFailedPathReason(e, line, true) end)
	if not ok then return { reasonError = tostring(f) } end
	if f == nil then return { reasonError = "getFailedPathReason gave nothing" } end
	local out = {}
	local okR, v = pcall(function() return f.reason end)
	out.reason = okR and M.failureName(v) or nil
	out.message = out.reason and M.FAILURE_TEXTS[out.reason] or nil
	local okP, pos = pcall(function()
		local p = f.pos
		if p == nil then return nil end
		local x, y, z = tonumber(p.x), tonumber(p.y), tonumber(p.z)
		if not (x and y) then return nil end
		return { x = x, y = y, z = z }
	end)
	if okP then out.position = pos end
	return out
end

-- vehicle e onto line, as the base's HandleVehicleChanges sends it after a buy (makeVehicleSetLineCmd, first stop
-- 0), but with a callback that keeps the engine's answer: the base's only logs it. report.setLine gets one entry
-- per vehicle: { entity, line } at once, ok (true / false) when the answer is in, and on a refusal the reason.
function M.sendToLine(report, e, line)
	report.setLine = report.setLine or {}
	local entry = { entity = e, line = line }
	report.setLine[#report.setLine + 1] = entry
	local ok, err = pcall(function()
		api.cmd.sendCommand(api.cmd.makeVehicleSetLineCmd(e, line, 0), function(_, success)
			if success == true then
				entry.ok = true
				return
			end
			entry.ok = false
			local okF, f = pcall(M.failedPathReason, e, line)
			if okF then
				for k, v in pairs(f) do entry[k] = v end
			else
				entry.reasonError = tostring(f)
			end
		end)
	end)
	if not ok then
		entry.ok = false
		entry.sendError = tostring(err)
	end
end

-- The gui way of one request (core.vehicleRequests): the base's HandleVehicleChanges, called as the vehicle store
-- (buy, replace, sell) and the clone button (duplicate) call it. Main thread only (the recipe's join).
-- report: { sentParts, entities, failures, setLine } filled now and by the callbacks later; error when the request
-- could not be sent at all (the module does not load, the vehicle is gone).
-- A line: the base gets none (-1), and the vehicle goes onto it from onBuy here (sendToLine): the base sends it
-- the same way, but its callback only logs a refusal (vehicle_react_util.tl), and a refused ship stayed in its
-- depot with no word why (2026-11-22). The buy itself (purchaseTime, autoload) is still the base's.
function M.performGui(req, r, report)
	local ok, vru = pcall(req, M.VEHICLE_REACT_UTIL)
	if not ok then error("could not load " .. M.VEHICLE_REACT_UTIL .. ": " .. tostring(vru), 0) end
	if type(vru) ~= "table" or type(vru.HandleVehicleChanges) ~= "function" then
		error(M.VEHICLE_REACT_UTIL .. " has no HandleVehicleChanges", 0)
	end
	report.entities, report.failures = report.entities or {}, report.failures or {}
	local onBuy = function(results)
		for _, x in ipairs(toList(results)) do
			local e = tonumber(toList(x)[1])
			report.entities[#report.entities + 1] = e
			if e and r.line and r.line >= 0 and (r.kind == "buy" or r.kind == "duplicate") then
				pcall(M.sendToLine, report, e, r.line)
			end
		end
	end
	local onFail = function(reason) report.failures[#report.failures + 1] = tostring(reason) end
	local config, changes
	if r.kind == "buy" or r.kind == "duplicate" then
		local entity = -1 -- the store marks a new vehicle with a negative entity; the clone button with -source-1
		if r.kind == "buy" then
			config = M.newConfig(req, r.modelId)
		else
			local tv = api.engine.getComponent(r.vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
			if not tv then error("no vehicle " .. tostring(r.vehicle), 0) end
			config = M.cloneConfig(tv.transportVehicleConfig)
			entity = -r.vehicle - 1
		end
		changes = {}
		for _ = 1, r.count or 1 do changes[#changes + 1] = { vehicleEntity = entity, config = config } end
		vru.HandleVehicleChanges(changes, {},
			-- no line for the base: onBuy sends the vehicle (sendToLine), with stop 0 as the base would (the line
			-- manager works its first stop out by its send scheme; the store gives none)
			function() return { -1, r.depot } end,
			function() return 0 end,
			onBuy, onFail)
	elseif r.kind == "replace" then
		config = M.newConfig(req, r.modelId)
		vru.HandleVehicleChanges({ { vehicleEntity = r.vehicle, config = config } }, {},
			function() return { -1, -1 } end, nil, nil, nil)
	else -- sell: an empty config is the store's way to say "sell" (no protected entities given: nothing is kept)
		config = api.type.TransportVehicleConfig.new()
		config.vehicles = {}
		vru.HandleVehicleChanges({ { vehicleEntity = r.vehicle, config = config } }, {},
			function() return { -1, -1 } end, nil, nil, nil)
	end
	-- HandleVehicleChanges stamped these (purchaseTime) into the config it sent
	if r.kind ~= "sell" then report.sentParts = M.partsOf(field(config, "vehicles")) end
end

return M
