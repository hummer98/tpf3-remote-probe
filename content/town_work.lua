-- The engine's part of the town command: the needs read from the economy, one GameMap.Town handed to
-- api.engine.mapgen.createTowns for the proposal (TownInfo), and (no dry run) api.cmd.makeTownCreateCmd with it.
-- Required by both Lua states of the remote probe: the guiUpdate script (remote_town.lua, the "update" way) and the
-- speed control's react recipe (gui/remote_speed.script.lua, the "gui" way, in its join on the main thread), where
-- the base map editor (map_editor.tl makeTowns) and Advanced Town Placement call the same functions. Plain values
-- only go back (the report): the engine's objects stay here.
--
-- What createTowns lists to remove (toRemove; the editor destroys those towns before it adds) is counted, never
-- destroyed: this command only adds. Where the place cannot take a town (roads, buildings, water, rough ground),
-- the engine decides: an error it raises comes back as it is, and a proposal with no initial capacity is refused
-- (ATP leaves such places out: the command would leave an empty town).
--
-- Not checked in a game yet (written 2026-11-22).
local MOD = (getOwningModId and getOwningModId()) or "hummer_remote_probe"
local core = (ug_require or require)(MOD .. "::/remote_core.lua")

local M = {}

M.SEED = "remote_probe" -- createTowns' seed text (the editor passes its own; ATP and RWMI a fixed one)

local field = core.field

-- the functions the work needs here: { [path] = type }, and the missing ones (nil)
function M.functions()
	local out, missing = {}, {}
	for _, p in ipairs(core.TOWN_NEEDS) do
		local t = core.typeAt(p)
		out[p] = t
		if t == "nil" then missing[#missing + 1] = p end
	end
	for _, p in ipairs(core.TOWN_LOOKS) do out[p] = core.typeAt(p) end
	return out, missing
end

-- the economy's cargo categories and the cargo types' categories, as plain tables; nil and why when unreadable
local function economy()
	local ok, res = pcall(function()
		local eco = api.res.economyRep.get(api.res.economyRep.find(api.res.getBaseConfig().economyId))
		local cats = {}
		local cc = field(eco, "cargoCategories")
		for name, c in pairs(cc) do
			local uses = {}
			for _, v in ipairs(core.toList(field(c, "landUses"))) do uses[#uses + 1] = v end
			cats[tostring(name)] = { tier = tonumber(field(c, "tier")), landUses = uses }
		end
		local types = {}
		for id in pairs(api.res.cargoTypeRep.getAll()) do
			local okC, cat = pcall(function() return api.res.cargoTypeRep.get(id).category end)
			if okC and type(cat) == "string" and cat ~= "" then types[id] = cat end
		end
		return { cats = cats, types = types }
	end)
	if not ok then return nil, tostring(res) end
	return res
end

local function landUseType()
	local ok, lu = pcall(function() return api.type.enum.LandUseType end)
	if not ok or lu == nil then return nil end
	local out = {}
	for _, k in ipairs({ "RESIDENTIAL", "COMMERCIAL", "INDUSTRIAL" }) do out[k] = field(lu, k) end
	return out
end

-- the work itself. r: core.townRequest's; propose: createTowns may be asked (the map editor, or inGame). report
-- gets: functions, needs (names per land use), needIds (per district, for makeTownUpdateCargoNeedsCmd), proposal
-- (the TownInfo's name, position, initialLandUseCapacities, ...), toRemove (counted, never destroyed), sent; and
-- success, entities from the command's callback (later). An error raised here is the caller's to report.
function M.work(r, report, propose)
	local functions, missing = M.functions()
	report.functions = functions
	if #missing > 0 then error("missing here: " .. table.concat(missing, ", "), 0) end
	local pos = api.type.Vec2f.new(r.at.x, r.at.y)
	-- as the base import, before createTowns: a point off the map is refused; one that cannot be checked is said
	local okV, valid = pcall(function() return api.engine.terrain.isValidCoordinate(pos) end)
	if okV and valid == false then error(string.format("at %g,%g is not on the map", r.at.x, r.at.y), 0) end
	if not okV or (valid ~= true and valid ~= false) then
		report.warnings = { "whether the point is on the map could not be checked (isValidCoordinate: "
			.. tostring(okV and valid or valid) .. ")" }
	end
	-- the needs
	local LU = landUseType()
	local eco, eerr
	if r.needs ~= "none" then eco, eerr = economy() end
	if r.needs ~= "none" and not eco then
		if r.needs ~= "auto" then error("needs: the economy could not be read: " .. tostring(eerr), 0) end
		report.warnings = report.warnings or {}
		table.insert(report.warnings, "no first needs: the economy could not be read (" .. tostring(eerr) .. ")")
	end
	local names, ids = core.townNeedsPlan(eco and r.needs or "none", eco and eco.cats, eco and eco.types, LU)
	if not names then error(ids, 0) end
	report.needs, report.needIds = names, ids
	if not propose then
		report.sent = false
		report.proposalNote = "createTowns not asked: not the map editor and no inGame"
		return
	end
	-- the town, as the base import fills a GameMap.Town (map_editor.tl) and ATP its candidates
	local town = api.type.Map.Town.new()
	town.pos = pos
	town.name = r.name
	town.sizeFactors = { r.size, r.size, r.size }
	local needs = {}
	if LU then
		for _, k in ipairs(core.TOWN_LAND_USES) do
			local list = {}
			for _, cat in ipairs(names[k]) do list[#list + 1] = { cat, 1.0 } end
			local v = LU[core.TOWN_LAND_USE_TYPE[k]]
			if #list > 0 and v ~= nil then needs[v] = list end
		end
	end
	town.landUse2CargoNeeds = needs
	town.existing = -1
	local result = api.engine.mapgen.createTowns(M.SEED, { town })
	if result == nil then error("createTowns gave nothing", 0) end
	local toAdd = core.toList(field(result, "toAdd"))
	report.toRemove = core.size(field(result, "toRemove"))
	if #toAdd ~= 1 then error(string.format("createTowns gave %d towns to add (1 asked)", #toAdd), 0) end
	local info = toAdd[1]
	local caps = core.toList(field(info, "initialLandUseCapacities"))
	local engineCaps = { tonumber(caps[1]) or 0, tonumber(caps[2]) or 0, tonumber(caps[3]) or 0 }
	local p = field(info, "position")
	report.proposal = { name = field(info, "name"), position = { x = tonumber(field(p, "x")), y = tonumber(field(p, "y")) },
		initialLandUseCapacities = engineCaps, capacityScalingFactor = tonumber(field(info, "capacityScalingFactor")),
		majorStreetAngle = tonumber(field(info, "majorStreetAngle")) }
	if engineCaps[1] + engineCaps[2] + engineCaps[3] <= 0 then
		error("createTowns found no room for a town here (initialLandUseCapacities 0, 0, 0): pick another place", 0)
	end
	if r.capacity then
		local scaled = core.townScaledCapacities(engineCaps, r.capacity)
		info.initialLandUseCapacities = scaled
		report.proposal.scaledCapacities = scaled
	end
	if r.dryRun then
		report.sent = false
		return
	end
	local cmd = api.cmd.makeTownCreateCmd({ info })
	report.sent = false
	api.cmd.sendCommand(cmd, function(_, success, entities)
		-- plain values only leave the callback
		local list = {}
		for _, e in ipairs(core.toList(entities)) do
			local id = tonumber(e) or tonumber(core.at(e, 1))
			if id then list[#list + 1] = id end
		end
		report.entities = list
		report.success = success == true
	end)
	-- (only once the send went through: one that raises leaves sent false, and the error is the caller's)
	report.sent = true
end

-- the recipe's side (gui way)
function M.performGui(req, r, report)
	local args, err = core.townRequest(r.args)
	if not args then error(err, 0) end
	M.work(args, report, r.propose == true)
	report.done = true
end

return M
