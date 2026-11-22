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
--     cargo docks have none in the base's files). The base gives the position in the construction's frame (the
--     slot's transf); whether the engine keeps it so or turns it into the world's is not known, so both are tried:
--     the position as read and through the construction's transf (streetConnectorSystem
--     .getConstructionEntityForStation, CONSTRUCTION.transf), and the one nearer the station's box centre is taken
--     (frame "world" or "construction"). Without a transf, a centre further than its radius and FAR_M from the
--     station is taken round the station (frame "station").
--   the town buildings (townBuildingSystem.getTown2BuildingMap) of the towns nearest the station (TOWNS_READ, at
--     most BUILDINGS_READ buildings), each one's BOUNDING_VOLUME centre and PERSON_CAPACITY type (LandUseType).
--   a walking path from a building's PersonCapacity personNodes to the station's terminals' personNodes
--     (findPathNodeToNode, PERSON; the reach module's search), for at most PATHS_DEFAULT of the buildings in a
--     circle that the engine does not count, and CONTROLS of those it does (a search that finds none of those
--     either is not to be trusted).
-- A building counts as in a circle when its box centre is: the engine may measure from its door or its street, so a
-- building within EDGE_M of the rim may go either way.
local M = {}

M.TOWNS_READ = 4 -- the towns nearest the station whose buildings are read (all, when one has no position)
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
	-- by number only a plain list: an engine Vec3f read by an index it has not may be the engine's assertion
	if (x == nil or y == nil) and type(p) == "table" then x, y = num(p[1]), num(p[2]) end
	if x == nil or y == nil then return nil end
	return { x = x, y = y, radius = r }
end

-- a point x, y (z 0) through a transf (16 numbers, by column as Mat4f: 13..15 the translation)
function M.transform(tf, x, y)
	return tf[1] * x + tf[5] * y + tf[13], tf[2] * x + tf[6] * y + tf[14]
end

local function far(x, y, pos) return math.sqrt((x - pos.x) ^ 2 + (y - pos.y) ^ 2) end

-- the circles of one station. tf (the construction's transf, or nil) and pos (the station's box centre, or nil):
-- with tf, the centre as read (frame "world") or through tf ("construction"), whichever is nearer pos (no pos:
-- through tf, the base's frame); without tf, as read when near pos, else round pos ("station"). The position as
-- read is kept as readX / readY whenever another is used.
function M.circles(station, areas, pos, tf)
	local out = {}
	for _, a in ipairs(areas) do
		local c = { station = station, radius = a.radius, x = a.x, y = a.y, frame = "world" }
		if tf then
			local tx, ty = M.transform(tf, a.x, a.y)
			if pos == nil or far(tx, ty, pos) < far(a.x, a.y, pos) then
				c.frame, c.readX, c.readY, c.x, c.y = "construction", a.x, a.y, tx, ty
			end
		elseif pos and far(a.x, a.y, pos) > a.radius + M.FAR_M then
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
		if #t == 0 then return "no building of a known kind (LandUseType)" end
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
	if (ic.unknownKind or 0) > 0 then kinds[#kinds + 1] = "unknown kind " .. ic.unknownKind end
	local s = string.format("%d town buildings in the circle (%s: %s)", ic.total, radius, table.concat(kinds, ", "))
	local what = d.cargoOnly and "the engine's cargo catchment" or "the engine's catchment"
	if ic.notCaught == 0 then return s .. ", all in " .. what end
	s = s .. string.format(", %d not in %s", ic.notCaught, what)
	local w = d.walk
	if w and w.checked > 0 then
		local noPath, found, unknown = w.noPath or 0, w.found or 0, w.unknown or 0
		s = s .. string.format("; on foot %d of %d checked have no path to the station", noPath, w.checked)
		local more = {}
		if found > 0 then more[#more + 1] = found .. " with a path" end
		if unknown > 0 then more[#more + 1] = unknown .. " could not be searched" end
		if #more > 0 then s = s .. " (" .. table.concat(more, ", ") .. ")" end
		if w.truncated then s = s .. "; stopped: " .. w.truncated end
		if noPath > 0 then
			if not (w.control and w.control.checked > 0) then
				s = s .. " (no caught building to try the search on: a missing path is unverified)"
			elseif w.control.found == 0 then
				s = s .. " (but the search found none for the caught ones either: not to be trusted)"
			end
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

	-- the transf of a station's construction as 16 numbers, or nil (Mat4f reads by 1..16)
	local function transfOf(st)
		local con = tonumber(try(function() return api.engine.system.streetConnectorSystem.getConstructionEntityForStation(st) end))
		if con == nil or con < 0 then return nil end
		local c = comp(con, "CONSTRUCTION")
		local t = c and core.field(c, "transf")
		if t == nil then return nil end
		local out = {}
		for i = 1, 16 do
			out[i] = num(core.field(t, i))
			if out[i] == nil then return nil end
		end
		return out
	end
	-- whether a station has a passenger terminal: true, false (every terminal's flags read, none for passengers),
	-- or nil (not known)
	local function passengerStation(st)
		local any, known = false, true
		for _, t in ipairs(core.toList(core.field(comp(st, "STATION"), "terminals"))) do
			local l, u = core.field(t, "passengersLoad"), core.field(t, "passengersUnload")
			if l == true or u == true then return true end
			if l == nil and u == nil then known = false end
			any = true
		end
		if any and known then return false end
		return nil
	end

	-- stations: the station ids; caught: { [building] = true } the engine's passenger catchables as buildings;
	-- opts: radius (used when the engine gives no circle), paths (walking searches, 0: none), target (the id the
	-- walking search goes to: the group or the station), caughtCargo (the cargo catchables as buildings: used for
	-- a station with no passenger terminal)
	function D.diagnose(stations, caught, opts)
		opts = opts or {}
		local t0 = now()
		local d = { note = M.NOTE, circles = {}, nearest = {}, towns = {} }
		-- a cargo station: its circle is held against the cargo catchables, and nobody walks to it
		local anyPassenger, allCargo = false, #stations > 0
		for _, st in ipairs(stations) do
			local p = passengerStation(st)
			if p == true then anyPassenger = true end
			if p ~= false then allCargo = false end
		end
		if allCargo and not anyPassenger then d.cargoOnly = true; caught = opts.caughtCargo or {} end
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
			local tf = #areas > 0 and transfOf(st) or nil
			for _, c in ipairs(M.circles(st, areas, pos, tf)) do d.circles[#d.circles + 1] = c end
		end
		-- no station's box: the group's, else the circles' centres
		if #centres == 0 and opts.target then
			local p = posOf(opts.target)
			if p then centres[1] = p end
		end
		if #centres == 0 then
			for _, c in ipairs(d.circles) do centres[#centres + 1] = { x = c.x, y = c.y } end
		end
		if #centres == 0 then d.positionError = "no position for the station (no bounding volume, no circle)" end
		if #d.circles > 0 then
			d.radiusSource = M.SOURCE_ENGINE
		elseif opts.radius and #centres > 0 then
			d.radiusSource = M.SOURCE_GIVEN
			for _, st in ipairs(stations) do
				local p = posOf(st)
				if p then d.circles[#d.circles + 1] = { station = st, x = p.x, y = p.y, radius = opts.radius, frame = "station" } end
			end
			if #d.circles == 0 then
				-- (the group's position: one circle round it)
				d.circles[1] = { station = stations[1], x = centres[1].x, y = centres[1].y, radius = opts.radius, frame = "station" }
			end
		else
			d.radiusSource = "none: the engine gave no circle (STATION.catchmentAreas)"
		end
		-- the distance of a point from the nearest of the stations
		local function fromStations(p)
			local best
			for _, c in ipairs(centres) do
				local x = far(p.x, p.y, c)
				if best == nil or x < best then best = x end
			end
			return best
		end
		-- the towns, nearest first (a town without a position last: then every town is read), and their buildings
		local towns, unplaced = {}, 0
		for _, t in ipairs(core.toList(try(function() return api.engine.getEntitiesWithComponent(CT().TOWN) end))) do
			t = tonumber(t)
			if t then
				local p = posOf(t)
				local x = p and fromStations(p)
				if x == nil then unplaced = unplaced + 1 end
				towns[#towns + 1] = { id = t, d = x or math.huge }
			end
		end
		table.sort(towns, function(a, b) if a.d ~= b.d then return a.d < b.d end return a.id < b.id end)
		d.townsTotal = #towns
		if unplaced > 0 then d.townsUnplaced = unplaced end
		local townsRead = unplaced > 0 and #towns or math.min(#towns, M.TOWNS_READ)
		local map = #towns > 0 and try(function() return api.engine.system.townBuildingSystem.getTown2BuildingMap() end) or nil
		if #towns > 0 and map == nil then d.buildingsError = "townBuildingSystem.getTown2BuildingMap gave nothing" end
		-- the map by pairs, as the other readers of it do (a missing key of an engine map is not known to be safe);
		-- only the lists of the towns read are kept
		local want, lists = {}, {}
		for i = 1, townsRead do want[towns[i].id] = true end
		if map ~= nil then
			pcall(function()
				for k, v in pairs(map) do
					local t = tonumber(k)
					if t and want[t] then lists[t] = core.toList(v) end
				end
			end)
		end
		local read, inside, notCaught, caughtIn = 0, { total = 0, notCaught = 0, unknownKind = 0 }, {}, {}
		for _, k in ipairs(M.KINDS) do inside[k] = 0 end
		local names = {}
		for i = 1, townsRead do
			local t = towns[i].id
			names[t] = nameOf(t)
			local list = lists[t] or {}
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
					if dist == nil then dist = fromStations(p) end
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
		if d.cargoOnly then
			walk.why = "a cargo station: nobody walks to it"
		elseif paths == 0 then
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
				if r.ms and r.ms > (walk.maxMs or -1) then walk.maxMs = r.ms end
				if r.found == false and r.unverified then walk.unverified = (walk.unverified or 0) + 1 end
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
