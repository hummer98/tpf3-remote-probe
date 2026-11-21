-- The engine's part of the terrain command: the map copied from the game, the rectangle's heights written into the
-- copied table, and (no dry run) the whole map sent as api.cmd.makeWorldReplaceTerrainCmd. Required by both Lua
-- states of the remote probe: the guiUpdate script (remote_terrain.lua, the "update" way) and the speed control's
-- react recipe (gui/remote_speed.script.lua, the "gui" way, in its join on the main thread). The base map editor and
-- the terrain mods (Ultimate Terrain Generator, Real World Map Importer) call these from react GUI scripts; whether
-- the guiUpdate state has them is not known, so the caller looks first (core.terrainFunctions) and either way runs
-- this same code. Plain values only go back (the report): the engine's objects stay here.
--
-- As the base map editor before its replacement (map_editor.tl): api.gui.map.setMapSeedText and
-- reloadMaterialIndexManagerPipeline, each in pcall, the report says whether each ran. keepAssets on: the rest of
-- the map keeps its trees and rocks (the map copied without assets). The map copied without towns and industries:
-- a map that lists towns asserts in terrain_util::ReplaceTerrain (UTG's note); towns standing in the world stay.
--
-- Not checked in a game yet (written 2026-11-22).
local MOD = (getOwningModId and getOwningModId()) or "hummer_remote_probe"
local core = (ug_require or require)(MOD .. "::/remote_core.lua")

local M = {}

M.SEED = "" -- the seed text sent with the replacement (as RWT does: only the generator's extras would use it)

local function field(v, k)
	local ok, x = pcall(function() return v[k] end)
	if ok then return x end
	return nil
end

-- the map's grid as core.terrainGrid takes it, from the copied map and the terrain's bounding box. -> info, or nil
-- and why (anything that does not add up is a refusal: a wrong index would write heights somewhere else)
function M.mapInfo(map, box)
	local tx, ty = tonumber(field(map, "numTilesX")), tonumber(field(map, "numTilesY"))
	local res = field(map, "resolution")
	local step = tonumber(res and field(res, "x")) or 4
	if not (tx and ty and tx > 0 and ty > 0) then return nil, "the map's numTilesX / numTilesY could not be read" end
	if step <= 0 then return nil, "the map's resolution is " .. tostring(step) end
	local w, h = tx * 256 / step + 1, ty * 256 / step + 1
	if w % 1 ~= 0 or h % 1 ~= 0 then return nil, string.format("%d x %d tiles do not make a grid of %g m", tx, ty, step) end
	local lo, hi = box and field(box, "min"), box and field(box, "max")
	local minX, minY = tonumber(lo and field(lo, "x")), tonumber(lo and field(lo, "y"))
	local maxX, maxY = tonumber(hi and field(hi, "x")), tonumber(hi and field(hi, "y"))
	if not (minX and minY and maxX and maxY) then return nil, "the terrain's bounding box could not be read" end
	-- the box must span the grid: (w - 1) steps, within one step
	if math.abs((maxX - minX) - (w - 1) * step) > step or math.abs((maxY - minY) - (h - 1) * step) > step then
		return nil, string.format("the terrain's bounding box (%g x %g m) does not match the map's grid (%d x %d points of %g m)",
			maxX - minX, maxY - minY, w, h, step)
	end
	return { minX = minX, minY = minY, maxX = minX + (w - 1) * step, maxY = minY + (h - 1) * step, step = step, w = w, h = h,
		tiles = { tx, ty } }
end

-- the work itself. r: core.terrainRequest's. report gets: functions (what this state has), rect, grid, mode,
-- target, before, written, changed, samples, waterLevel, seedText / reloadMaterials (true / the error), sent; and
-- success from the command's callback (later). An error raised here is the caller's to report.
function M.work(r, report)
	local functions, missing = core.terrainFunctions()
	report.functions = functions
	if #missing > 0 then error("missing here: " .. table.concat(missing, ", "), 0) end
	local map = api.engine.terrain.makeMapFromGame(true, false, false, false)
	if map == nil then error("makeMapFromGame gave nothing", 0) end
	local info, err = M.mapInfo(map, api.engine.terrain.getBoundingBox())
	if not info then error(err, 0) end
	local towns = field(map, "towns")
	if towns ~= nil and core.size(towns) ~= 0 then
		-- (the engine asserts on that: never sent)
		error("the copied map lists towns (makeMapFromGame without towns gave " .. tostring(core.size(towns)) .. ")", 0)
	end
	local grid, gerr = core.terrainGrid(r, info)
	if not grid then error(gerr, 0) end
	local heights = map.heightmap -- one read: a copy of the whole table
	local n = core.size(heights)
	if n ~= info.w * info.h then
		error(string.format("the heightmap has %s values, the grid %d x %d", tostring(n), info.w, info.h), 0)
	end
	if type(heights) ~= "table" then
		-- an engine vector: copied into a Lua table first (the whole table goes back)
		local t = {}
		for k = 1, n do t[k] = heights[k] end
		heights = t
	end
	local stats = core.terrainFill(heights, grid, r, info)
	local lo, hi = core.terrainRange(r)
	report.map = { tiles = info.tiles, step = info.step, w = info.w, h = info.h, minX = info.minX, minY = info.minY,
		maxX = info.maxX, maxY = info.maxY }
	report.grid, report.target = grid, { min = lo, max = hi }
	report.before, report.written, report.changed = stats.before, stats.written, stats.changed
	report.samples = core.terrainSamples(heights, grid, r, info)
	report.waterLevel = tonumber(field(map, "waterLevel"))
	if r.dryRun then
		report.sent = false
		return
	end
	-- the whole table assigned (an element written into map.heightmap is lost)
	map.heightmap = heights
	-- as the base editor before its replacement: each optional, and said whether it ran
	local okS, errS = pcall(function() api.gui.map.setMapSeedText(M.SEED) end)
	report.seedText = okS or tostring(errS)
	local okR, errR = pcall(function() api.gui.map.reloadMaterialIndexManagerPipeline() end)
	report.reloadMaterials = okR or tostring(errR)
	local cmd = api.cmd.makeWorldReplaceTerrainCmd(map, api.res.getBaseConfig().terrain, M.SEED,
		api.engine.util.getWorld(), true)
	report.sent = true
	api.cmd.sendCommand(cmd, function(_, success)
		-- plain values only leave the callback
		report.success = success == true
	end)
end

-- the recipe's side (gui way): a probe looks at the functions there; an apply runs the work
function M.performGui(req, r, report)
	if r.kind == "probe" then
		report.functions = core.terrainFunctions()
		report.done = true
		return
	end
	local args, err = core.terrainRequest(r.args)
	if not args then error(err, 0) end
	M.work(args, report)
	report.done = true
end

return M
