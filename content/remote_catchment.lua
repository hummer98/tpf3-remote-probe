-- stations --catchment, why a station catches nobody (read only): the circles of its catchment, the town buildings
-- in and near them, and whether those in a circle that the engine does not count can be walked to. Made after a
-- rail map whose six stations all caught 0: the answer could not tell "too far" from "not connected", and 400 days
-- were run on a road problem that was none (no house was within 150 m of any station).
--
-- What is read (api/tealdef 40444):
--   STATION.catchmentAreas (type.d.tl Station: {CatchmentArea}, CatchmentArea = { position : Vec3f, radius }): one
--     circle per module that has one; the base builds them in constructionutil.addCatchmentCircles from a module's
--     metadata.catchmentPassenger / catchmentCargo.radius at the module's slot (rail main buildings 150 / 175 / 200
--     m, side buildings 50 / 60 / 70, stairs 100; street station entrances 175; small street stops 160 through the
--     edge object's catchmentAreaRadius; harbour passenger docks 150 (25x25) and 250 (50x50, 100x50); the harbour's
--     cargo docks have none in the base's files). Whether the engine keeps the position in the world's frame or
--     the construction's is not known: a circle whose centre is far from the station is taken round the station.
--   the town buildings (townBuildingSystem.getTown2BuildingMap) of the towns nearest the station (TOWNS_READ, at
--     most BUILDINGS_READ buildings), each one's BOUNDING_VOLUME centre and PERSON_CAPACITY type (LandUseType).
--   a walking path from a building's PersonCapacity personNodes to the station's terminals' personNodes
--     (findPathNodeToNode, PERSON; the reach module's search), for at most PATHS_DEFAULT of the buildings in a
--     circle that the engine does not count, and CONTROLS of those it does (a search that finds none of those
--     either is not to be trusted).
-- A building counts as in a circle when its box centre is: the engine may measure from its door or its street, so a
-- building within EDGE_M of the rim may go either way.
local M = {}

M.TOWNS_READ = 4 -- the towns nearest the station whose buildings are read
M.BUILDINGS_READ = 1500 -- buildings read at most (more: not read, truncated says so)
M.PATHS_DEFAULT = 20 -- walking searches for buildings in a circle that the engine does not count
M.PATHS_MAX = 50
M.CONTROLS = 3 -- walking searches for buildings the engine does count
M.PATH_BUDGET_MS = 300 -- the searches stop when they have taken this long together
M.SLOW_MS = 100 -- reading the buildings this long is logged
M.FAR_M = 1000 -- a circle centre further than its radius and this from the station's box centre is not in the world frame
M.EDGE_M = 10
M.KINDS = { "residential", "commercial", "industrial" }
M.SOURCE_ENGINE = "engine: STATION.catchmentAreas"
M.SOURCE_GIVEN = "given: --radius (the engine gave no circle)"
M.NOTE = "not checked in a game yet (2026-11-23): whether STATION.catchmentAreas reads and in which frame, and " ..
	"whether the walking search finds paths between these nodes; a building counts as in a circle by its box centre"

---------------------------------------------------------------------------------------------------------------------
-- pure

local function num(v) local n = tonumber(v); if n == nil or n ~= n or math.abs(n) == math.huge then return nil end; return n end

-- a CatchmentArea's centre and radius: position as a Vec3f (x, y, z) or a list { x, y, z }; nil when unreadable
function M.areaOf(a, core)
	local p = core.field(a, "position")
	local r = num(core.field(a, "radius"))
	if p == nil or r == nil or r <= 0 then return nil end
	local x, y = num(core.field(p, "x")), num(core.field(p, "y"))
	if x == nil or y == nil then x, y = num(core.at(p, 1)), num(core.at(p, 2)) end
	if x == nil or y == nil then return nil end
	return { x = x, y = y, radius = r }
end

-- the circles of one station: its areas, each in the world frame when its centre is near the station's box centre
-- (pos; nil: taken as it is), else round pos (frame "station": the position read is kept as readX / readY)
function M.circles(station, areas, pos)
	local out = {}
	for _, a in ipairs(areas) do
		local c = { station = station, radius = a.radius, x = a.x, y = a.y, frame = "world" }
		if pos and math.sqrt((a.x - pos.x) ^ 2 + (a.y - pos.y) ^ 2) > a.radius + M.FAR_M then
			c.frame, c.readX, c.readY, c.x, c.y = "station", a.x, a.y, pos.x, pos.y
		end
		out[#out + 1] = c
	end
	return out
end

-- how far a point is from the rim of the nearest circle (negative: inside), that distance's circle and the distance
-- to its centre; nil when there is no circle
function M.nearestCircle(p, circles)
	local best, bc, bd
	for _, c in ipairs(circles) do
		local d = math.sqrt((p.x - c.x) ^ 2 + (p.y - c.y) ^ 2)
		if best == nil or d - c.radius < best then best, bc, bd = d - c.radius, c, d end
	end
	return best, bc, bd
end

local function m(v) return string.format("%d m", math.floor(v + 0.5)) end

-- the radii of the circles, as text: "150 m", "150-200 m"
function M.radiusText(circles)
	local lo, hi
	for _, c in ipairs(circles) do
		lo = (lo == nil or c.radius < lo) and c.radius or lo
		hi = (hi == nil or c.radius > hi) and c.radius or hi
	end
	if lo == nil then return nil end
	if math.floor(lo + 0.5) == math.floor(hi + 0.5) then return m(lo) end
	return string.format("%d-%d m", math.floor(lo + 0.5), math.floor(hi + 0.5))
end

-- one line that says why: d is the diagnosis table without its line
function M.diagnosis(d)
	local parts = {}
	local radius = M.radiusText(d.circles or {})
	local function nearestText()
		local t = {}
		for _, k in ipairs(M.KINDS) do
			local n = d.nearest and d.nearest[k]
			if n then
				local s = string.format("nearest %s %s", k, m(n.distance))
				if n.outside ~= nil then
					s = s .. (n.outside > 0 and string.format(" (%s outside the circle)", m(n.outside)) or " (in the circle)")
				end
				if n.townName then s = s .. " in " .. n.townName end
				t[#t + 1] = s
			end
		end
		return table.concat(t, ", ")
	end
	if d.buildingsRead == 0 then
		if d.townsTotal == 0 then return "no towns on the map: nothing to catch but industries" end
		return "no town buildings read near the station" .. (d.buildingsError and (": " .. d.buildingsError) or "")
	end
	if radius == nil then
		parts[#parts + 1] = "no catchment circle read (STATION.catchmentAreas); distances from the station's centre: " ..
			nearestText()
		return table.concat(parts, "; ")
	end
	local ic = d.inCircle
	if ic.total == 0 then
		return string.format("0 town buildings in the circle (%s); %s", radius, nearestText())
	end
	local kinds = {}
	for _, k in ipairs(M.KINDS) do if ic[k] > 0 then kinds[#kinds + 1] = k .. " " .. ic[k] end end
	local s = string.format("%d town buildings in the circle (%s: %s)", ic.total, radius, table.concat(kinds, ", "))
	if ic.notCaught == 0 then return s .. ", all in the engine's catchment" end
	s = s .. string.format(", %d not in the engine's catchment", ic.notCaught)
	local w = d.walk
	if w and w.checked > 0 then
		s = s .. string.format("; on foot %d of %d checked have no path to the station", w.noPath, w.checked)
		if w.control and w.control.checked > 0 and w.control.found == 0 then
			s = s .. " (but the search found none for the caught ones either: not to be trusted)"
		end
	elseif w and w.why then
		s = s .. "; no walking check: " .. w.why
	end
	return s
end

---------------------------------------------------------------------------------------------------------------------
-- the engine's side

-- ctx: core, try(fn), comp(e, kind), posOf(e), nameOf(e), appTime(), say(msg, level), walk() -> the reach module's
-- walkBetween(fromEntity, toEntity) or nil
function M.new(ctx)
	local core, try, comp, posOf, nameOf = ctx.core, ctx.try, ctx.comp, ctx.posOf, ctx.nameOf
	local D = {}

	local function CT() return api.type.ComponentType end
	local function now() return ctx.appTime and ctx.appTime() or nil end
	local function landUse(pc)
		local v = pc and core.field(pc, "type")
		if v == nil then return nil end
		local LU = try(function() return api.type.enum.LandUseType end)
		local n = core.enumName(LU or {}, { "RESIDENTIAL", "COMMERCIAL", "INDUSTRIAL" }, v)
		n = type(n) == "string" and n:lower() or nil
		for _, k in ipairs(M.KINDS) do if n == k then return k end end
		return nil
	end

	-- stations: the station ids; caught: { [building] = true } the engine's passenger catchables as buildings;
	-- opts: radius (used when the engine gives no circle), paths (walking searches, 0: none), target (the id the
	-- walking search goes to: the group or the station)
	function D.diagnose(stations, caught, opts)
		opts = opts or {}
		local t0 = now()
		local d = { note = M.NOTE, circles = {}, nearest = {}, towns = {} }
		-- the circles
		local centres = {}
		for _, st in ipairs(stations) do
			local pos = posOf(st)
			if pos then centres[#centres + 1] = pos end
			local list = core.field(comp(st, "STATION"), "catchmentAreas")
			local areas = {}
			for _, a in ipairs(core.toList(list)) do
				local x = M.areaOf(a, core)
				if x then areas[#areas + 1] = x end
			end
			for _, c in ipairs(M.circles(st, areas, pos)) do d.circles[#d.circles + 1] = c end
		end
		if #d.circles > 0 then
			d.radiusSource = M.SOURCE_ENGINE
		elseif opts.radius and #centres > 0 then
			d.radiusSource = M.SOURCE_GIVEN
			for _, st in ipairs(stations) do
				local p = posOf(st)
				if p then d.circles[#d.circles + 1] = { station = st, x = p.x, y = p.y, radius = opts.radius, frame = "station" } end
			end
		else
			d.radiusSource = "none: the engine gave no circle (STATION.catchmentAreas)"
		end
		local centre = centres[1]
		-- the towns, nearest first (a town without a position last), and their buildings
		local towns = {}
		for _, t in ipairs(core.toList(try(function() return api.engine.getEntitiesWithComponent(CT().TOWN) end))) do
			t = tonumber(t)
			if t then
				local p = posOf(t)
				towns[#towns + 1] = { id = t, d = (p and centre) and math.sqrt((p.x - centre.x) ^ 2 + (p.y - centre.y) ^ 2) or math.huge }
			end
		end
		table.sort(towns, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.id < b.id end)
		d.townsTotal = #towns
		local map = #towns > 0 and try(function() return api.engine.system.townBuildingSystem.getTown2BuildingMap() end) or nil
		if #towns > 0 and map == nil then d.buildingsError = "townBuildingSystem.getTown2BuildingMap gave nothing" end
		-- the map by pairs, as the other readers of it do (a missing key of an engine map is not known to be safe);
		-- only the lists of the towns read are kept
		local want, lists = {}, {}
		for i = 1, math.min(#towns, M.TOWNS_READ) do want[towns[i].id] = true end
		if map ~= nil then
			pcall(function()
				for k, v in pairs(map) do
					local t = tonumber(k)
					if t and want[t] then lists[t] = v end
				end
			end)
		end
		local read, inside, notCaught, caughtIn = 0, { total = 0, notCaught = 0, unknownKind = 0 }, {}, {}
		for _, k in ipairs(M.KINDS) do inside[k] = 0 end
		local names = {}
		for i = 1, math.min(#towns, M.TOWNS_READ) do
			local t = towns[i].id
			names[t] = nameOf(t)
			local list = core.toList(lists[t])
			local row = { town = t, name = names[t], distance = towns[i].d < math.huge and math.floor(towns[i].d + 0.5) or nil,
				buildings = #list, read = 0 }
			d.towns[#d.towns + 1] = row
			for _, b in ipairs(list) do
				b = tonumber(b)
				if read >= M.BUILDINGS_READ then d.truncated = true; break end
				local p = b and posOf(b)
				if p then
					read, row.read = read + 1, row.read + 1
					local tb = comp(b, "TOWN_BUILDING")
					local pcId = tonumber(core.field(tb, "personCapacity"))
					local pc = comp(b, "PERSON_CAPACITY") or (pcId and pcId >= 0 and comp(pcId, "PERSON_CAPACITY")) or nil
					local kind = landUse(pc)
					local outside, circle, dist = M.nearestCircle(p, d.circles)
					if dist == nil and centre then dist = math.sqrt((p.x - centre.x) ^ 2 + (p.y - centre.y) ^ 2) end
					if kind and dist then
						local n = d.nearest[kind]
						local key = outside or dist
						if n == nil or key < n.key then
							d.nearest[kind] = { key = key, building = b, town = t, townName = names[t],
								distance = math.floor(dist + 0.5), radius = circle and circle.radius or nil,
								outside = outside and math.floor(outside + 0.5) or nil, station = circle and circle.station or nil }
						end
					end
					if outside and outside <= 0 then
						inside.total = inside.total + 1
						if kind then inside[kind] = inside[kind] + 1 else inside.unknownKind = inside.unknownKind + 1 end
						if math.abs(outside) <= M.EDGE_M then inside.nearRim = (inside.nearRim or 0) + 1 end
						if caught[b] then
							caughtIn[#caughtIn + 1] = b
						else
							inside.notCaught = inside.notCaught + 1
							notCaught[#notCaught + 1] = { building = b, kind = kind, town = t, rim = math.floor(-outside + 0.5) }
						end
					end
				end
			end
			if d.truncated then break end
		end
		for _, n in pairs(d.nearest) do n.key = nil end
		d.buildingsRead = read
		inside.caught = inside.total - inside.notCaught
		d.inCircle = inside
		d.readMs = t0 and math.floor((now() - t0) * 1000 + 0.5) or nil
		if d.readMs and d.readMs >= M.SLOW_MS and ctx.say then
			ctx.say(string.format("catchment: reading %d buildings of %d towns took %d ms", read, #d.towns, d.readMs), 1)
		end
		-- the ones the engine does not count: nearest the centre first (the clearest cases)
		table.sort(notCaught, function(a, b) if a.rim ~= b.rim then return a.rim > b.rim end return a.building < b.building end)
		local listed = {}
		for i = 1, math.min(#notCaught, M.PATHS_MAX) do listed[i] = notCaught[i] end
		d.notCaught = core.array(listed)
		-- walking
		local paths = opts.paths == nil and M.PATHS_DEFAULT or opts.paths
		local walk = { checked = 0, found = 0, noPath = 0, unknown = 0, limit = paths, control = { checked = 0, found = 0 } }
		local fn = ctx.walk and ctx.walk()
		if paths == 0 then
			walk.why = "not asked (paths 0)"
		elseif #notCaught == 0 then
			walk.why = "every building in the circle is in the engine's catchment"
		elseif fn == nil then
			walk.why = "the reach module's walking search is not there"
		else
			local w0, spent = now(), 0
			local function budgetLeft()
				if w0 == nil then return true end
				spent = math.floor((now() - w0) * 1000 + 0.5)
				return spent < M.PATH_BUDGET_MS
			end
			local target = opts.target or stations[1]
			for i = 1, math.min(#notCaught, paths) do
				if not budgetLeft() then walk.truncated = "the searches took " .. spent .. " ms"; break end
				local x = notCaught[i]
				local r = fn(x.building, target)
				walk.checked = walk.checked + 1
				x.walk = r.found == true and "path" or (r.found == false and "none" or "unknown")
				x.why = r.why
				if r.found == true then walk.found = walk.found + 1
				elseif r.found == false then walk.noPath = walk.noPath + 1
				else walk.unknown = walk.unknown + 1 end
			end
			table.sort(caughtIn)
			for i = 1, math.min(#caughtIn, M.CONTROLS) do
				if not budgetLeft() then break end
				local r = fn(caughtIn[i], target)
				walk.control.checked = walk.control.checked + 1
				if r.found == true then walk.control.found = walk.control.found + 1 end
			end
			walk.ms = w0 and math.floor((now() - w0) * 1000 + 0.5) or nil
		end
		d.walk = walk
		d.circles = core.array(d.circles)
		d.towns = core.array(d.towns)
		d.diagnosis = M.diagnosis(d)
		return d
	end

	return D
end

return M
