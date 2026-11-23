-- around (read only): what stands near a point, one entry per entity: its kind (street, track, town_building,
-- station, depot, industry, construction, field, asset, town, ...), name (a town building's town, a construction's
-- or an industry's name, a road piece's street type), where it is, the box it takes (the octree's bounding
-- volume: axis aligned, so a turned station or a slanting road reads larger than it is) and how far from the point.
-- core.aroundRequest has the arguments. Also describe(ids, x, y): the same entries for given ids (a build's
-- collisions, remote_build.lua).
--
-- What is read (api/tealdef):
--   api.engine.system.octreeSystem.findIntersectingEntities(Box3, fn(entity, BoundingVolume)) once, over the
--     square round the circle (engine/system.d.tl OctreeSystem); the entities it gives are looked at after the walk
--   per entity, components in this order (the first there decides the kind): BASE_EDGE (roadType: street or track;
--     roadTemplate, position0 / 1; streetConnectorSystem.getConstructionEntityForEdge), BASE_NODE, TOWN_BUILDING
--     (town, construction), CONSTRUCTION (fileName; stations, depots, industries; a building/... file: a town's
--     building), INDUSTRY, SUBCONSTRUCTION, FIELD, TOWN, ASSET_GROUP (trees, rocks), the moving kinds (vehicles,
--     persons, animals), MODEL_INSTANCE_LIST, TERRAIN (terrain), WORLD / EMISSION_GRID (map); none of them: other,
--     or map when its box spans core.AROUND_MAP_SIZE both ways (terrain and map are off unless asked for)
--   for describe: BOUNDING_VOLUME of each id (no octree)
-- Every engine call is in pcall and asked only about entities the engine says exist. Nothing is sent.
--
-- Not checked in a game yet (written 2026-11-23): which entities the octree has (trees? fields?) and whether a
-- town building's box is on its TOWN_BUILDING entity or on its construction. The answer says so.
local M = {}

local NOTE = "read only; not checked in a game yet. Boxes are the octree's bounding volumes (axis aligned: a turned " ..
	"or slanting thing reads larger). Road and track widths are a guess (halfWidth). What the octree does not hold " ..
	"(trees, if their asset groups are not in it) is not listed"

local MOVING = { "TRANSPORT_VEHICLE", "LAND_VEHICLE", "TRAIN", "CARRIAGE", "SHIP", "AIRCRAFT", "SIM_PERSON", "ANIMAL",
	"MODEL_PERSON" }

-- ctx: core, answer(id, payload, tag), fail(id, msg), try(fn), appTime(), construction(e) (optional: remote_build's
-- describe: a construction's place, ends and mouths)
M.MOUTHS_MAX = 50 -- constructions per answer whose ends and mouths are read (nearest first)
function M.new(ctx)
	local core, answer, fail, try, appTime = ctx.core, ctx.answer, ctx.fail, ctx.try, ctx.appTime

	-- a construction's ends and mouths, each with its place in the construction's own frame (local), and where it
	-- stands (place: x, y, z, angle). Only an entry that is a construction (fileName) and not a town's building
	local function addMouths(d)
		if not (ctx.construction and d.fileName and d.kind ~= "town_building") then return false end
		local ok, info = pcall(ctx.construction, d.id)
		if not ok then d.mouthsError = tostring(info); return true end
		if info then d.place, d.ends, d.mouths = info.at, info.ends, info.connectable end
		return true
	end

	local function CT() return api.type.ComponentType end
	local function ctOf(kind) return try(function() return CT()[kind] end) end
	local function exists(e)
		return type(e) == "number" and e >= 0 and try(function() return api.engine.entityExists(e) end) == true
	end
	-- a component of an entity already known to exist
	local function comp(e, kind)
		local k = ctOf(kind)
		if k == nil then return nil end
		return try(function() return api.engine.getComponent(e, k) end)
	end
	local function nameOf(e)
		local n = try(function() return api.engine.util.getEntityName(e) end)
		if type(n) == "string" and n ~= "" then return n end
		return nil
	end
	local function vec(v)
		local x, y, z = tonumber(core.field(v, "x")), tonumber(core.field(v, "y")), tonumber(core.field(v, "z"))
		if not (x and y) then return nil end
		return { x = x, y = y, z = z }
	end
	local function nodePos(n)
		n = tonumber(n)
		local bn = n and exists(n) and comp(n, "BASE_NODE")
		return bn and vec(core.field(bn, "position")) or nil
	end
	local function ids(v)
		local out = {}
		for _, x in ipairs(core.toList(v)) do
			local n = tonumber(x)
			if n then out[#out + 1] = n end
		end
		return out
	end

	-- the kind and what goes with it; townOf: construction -> { building, town } of the town buildings seen
	local function classify(e, townOf)
		local be = comp(e, "BASE_EDGE")
		if be ~= nil then
			local rt = core.field(be, "roadType")
			local enum = try(function() return api.type.enum.RoadType end)
			local street = enum and try(function() return enum.STREET end)
			local kind = "street"
			if rt ~= nil and street ~= nil and rt ~= street then kind = "track"
			elseif rt == nil and comp(e, "BASE_EDGE_STREET") == nil and ctOf("BASE_EDGE_STREET") ~= nil then kind = "track" end
			local a = vec(core.field(be, "position0")) or nodePos(core.field(be, "node0"))
			local b = vec(core.field(be, "position1")) or nodePos(core.field(be, "node1"))
			local con = tonumber(try(function() return api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(e) end))
			local tpl = core.field(be, "roadTemplate")
			return { kind = kind, from = a, to = b, template = tpl ~= nil and tostring(tpl) or nil,
				construction = con and con >= 0 and con or nil, halfWidth = core.AROUND_HALF_WIDTH[kind] }
		end
		if comp(e, "BASE_NODE") ~= nil then return { kind = "node" } end
		local tb = comp(e, "TOWN_BUILDING")
		if tb ~= nil then
			local t = tonumber(core.field(tb, "town"))
			return { kind = "town_building", town = t, townName = t and exists(t) and nameOf(t) or nil,
				construction = tonumber(core.field(tb, "construction")) }
		end
		local c = comp(e, "CONSTRUCTION")
		if c ~= nil then
			local fn = core.field(c, "fileName")
			local file = fn ~= nil and tostring(fn) or ""
			local out = { fileName = fn ~= nil and file or nil }
			local tw = townOf[e]
			local st, dp, ind = ids(core.field(c, "stations")), ids(core.field(c, "depots")), ids(core.field(c, "industries"))
			if tw then
				out.kind, out.building, out.town = "town_building", tw.building, tw.town
				out.townName = tw.town and exists(tw.town) and nameOf(tw.town) or nil
			elseif file:find("^building/") then
				out.kind = "town_building"
			elseif #st > 0 then
				out.kind, out.stations = "station", core.array(st)
			elseif #dp > 0 then
				out.kind, out.depots = "depot", core.array(dp)
			elseif #ind > 0 or comp(e, "INDUSTRY") ~= nil then
				out.kind, out.industries = "industry", #ind > 0 and core.array(ind) or nil
			else
				out.kind = "construction"
			end
			return out
		end
		if comp(e, "INDUSTRY") ~= nil then return { kind = "industry" } end
		if comp(e, "SUBCONSTRUCTION") ~= nil then return { kind = "construction", sub = true } end
		if comp(e, "FIELD") ~= nil then return { kind = "field" } end
		if comp(e, "TOWN") ~= nil then return { kind = "town" } end
		if comp(e, "ASSET_GROUP") ~= nil then return { kind = "asset" } end
		for _, k in ipairs(MOVING) do
			if comp(e, k) ~= nil then return { kind = "moving", component = k } end
		end
		if comp(e, "MODEL_INSTANCE_LIST") ~= nil then return { kind = "model" } end
		if comp(e, "TERRAIN") ~= nil then return { kind = "terrain" } end
		if comp(e, "WORLD") ~= nil or comp(e, "EMISSION_GRID") ~= nil then return { kind = "map" } end
		return { kind = "other" }
	end

	-- one entry: the kind's fields, the name, the box (from bv, else the entity's BOUNDING_VOLUME), the centre and
	-- size, the distance from (px, py)
	local function entry(e, bv, px, py, townOf)
		local d = classify(e, townOf)
		d.id = e
		d.name = d.name or nameOf(e)
		local box = core.boxOf(bv and core.field(bv, "bbox"))
		if not box then
			local own = comp(e, "BOUNDING_VOLUME")
			box = core.boxOf(own and core.field(own, "bbox"))
		end
		if not box and d.from and d.to then
			local h = d.halfWidth or 0
			box = { x0 = math.min(d.from.x, d.to.x) - h, y0 = math.min(d.from.y, d.to.y) - h,
				x1 = math.max(d.from.x, d.to.x) + h, y1 = math.max(d.from.y, d.to.y) + h,
				z0 = d.from.z, z1 = d.to.z, fromEnds = true }
		end
		if not box and d.fileName then
			-- (a construction without a bounding volume read: its point, size unknown)
			local c = comp(e, "CONSTRUCTION")
			local t = c and core.field(c, "transf")
			local x, y, z = tonumber(core.field(t, 13)), tonumber(core.field(t, 14)), tonumber(core.field(t, 15))
			if x and y then box = { x0 = x, y0 = y, x1 = x, y1 = y, z0 = z, z1 = z, pointOnly = true } end
		end
		if not box and d.kind == "node" then
			local p = nodePos(e)
			if p then box = { x0 = p.x, y0 = p.y, x1 = p.x, y1 = p.y, z0 = p.z, z1 = p.z } end
		end
		d.box = box
		if box then
			d.x, d.y = (box.x0 + box.x1) / 2, (box.y0 + box.y1) / 2
			if box.z0 and box.z1 then d.z = (box.z0 + box.z1) / 2; d.height = box.z1 - box.z0 end
			d.sizeX, d.sizeY = box.x1 - box.x0, box.y1 - box.y0
			-- a box the size of the map (entity 2 in a game, 14,336 m square, kind other): the map's own, whatever
			-- its components; what it was read as is kept in mapOf
			if d.kind == "other" and d.sizeX >= core.AROUND_MAP_SIZE and d.sizeY >= core.AROUND_MAP_SIZE then
				d.mapOf, d.kind = d.kind, "map"
			end
		end
		if px then
			if d.from and d.to then
				d.dist = math.max(0, core.distToSegment(px, py, d.from, d.to) - (d.halfWidth or 0))
			elseif box then
				d.dist = core.distToBox(px, py, box)
			end
		end
		return d
	end

	-- the town buildings among ids: construction -> { building, town }
	local function townsOf(list)
		local m = {}
		for _, e in ipairs(list) do
			local tb = comp(e, "TOWN_BUILDING")
			local c = tb and tonumber(core.field(tb, "construction"))
			if c then m[c] = { building = e, town = tonumber(core.field(tb, "town")) } end
		end
		return m
	end

	-- the entries for given ids (those the engine has), nearest to (x, y) first when given
	local function describe(list, x, y)
		local live = {}
		for _, e in ipairs(list or {}) do
			e = tonumber(e)
			if e and exists(e) then live[#live + 1] = e end
		end
		local townOf = townsOf(live)
		local out = {}
		for _, e in ipairs(list or {}) do
			e = tonumber(e)
			if e and exists(e) then
				local ok, d = pcall(entry, e, nil, x, y, townOf)
				if ok then addMouths(d) end
				out[#out + 1] = ok and d or { id = e, kind = "other", error = tostring(d) }
			elseif e then
				out[#out + 1] = { id = e, kind = "gone", error = "the engine has no entity " .. e .. " now" }
			end
		end
		return core.array(out)
	end

	local H = {}
	function H.around(c)
		local r, err = core.aroundRequest(c.args)
		if not r then return fail(c.id, err) end
		local t0 = appTime()
		local found, bvs, dropped = {}, {}, 0
		local okW, errW = pcall(function()
			local box = api.type.Box3.new(api.type.Vec3f.new(r.x - r.radius, r.y - r.radius, -1000),
				api.type.Vec3f.new(r.x + r.radius, r.y + r.radius, 5000))
			api.engine.system.octreeSystem.findIntersectingEntities(box, function(e, bv)
				e = tonumber(e)
				if e and bvs[e] == nil and #found >= core.AROUND_SCAN_MAX then
					dropped = dropped + 1
				elseif e and bvs[e] == nil then
					found[#found + 1] = e
					-- (the box copied out now: the bounding volume may not outlive the callback)
					bvs[e] = core.boxOf(bv and core.field(bv, "bbox")) or false
				end
			end)
		end)
		if not okW then return fail(c.id, "the octree could not be read: " .. tostring(errW)) end
		local t1 = appTime()
		table.sort(found)
		local live = {}
		for _, e in ipairs(found) do if exists(e) then live[#live + 1] = e end end
		local townOf = townsOf(live)
		local list, counts, scanned = {}, {}, #found
		local looked, timeUp = 0, false
		for _, e in ipairs(live) do
			-- (the whole walk runs in one GUI frame: a time limit, so a large circle never holds the game long)
			if looked % 200 == 0 and (appTime() - t1) * 1000 > core.AROUND_TIME_MS then timeUp = true; break end
			looked = looked + 1
			local b = bvs[e]
			local ok, d = pcall(entry, e, b and { bbox = { min = { x = b.x0, y = b.y0, z = b.z0 },
				max = { x = b.x1, y = b.y1, z = b.z1 } } } or nil, r.x, r.y, townOf)
			if ok and d.dist ~= nil and d.dist <= r.radius and r.kinds[d.kind] then
				counts[d.kind] = (counts[d.kind] or 0) + 1
				list[#list + 1] = d
			end
		end
		table.sort(list, function(a, b)
			if a.dist ~= b.dist then return a.dist < b.dist end
			return a.id < b.id
		end)
		local total = #list
		while #list > r.limit do list[#list] = nil end
		local withMouths = 0
		for _, d in ipairs(list) do
			if withMouths >= M.MOUTHS_MAX then break end
			if addMouths(d) then withMouths = withMouths + 1 end
		end
		local t2 = appTime()
		local kinds = {}
		for _, k in ipairs(core.AROUND_KINDS) do if r.kinds[k] then kinds[#kinds + 1] = k end end
		answer(c.id, { ok = true, at = { x = r.x, y = r.y }, radius = r.radius, kinds = core.array(kinds),
			entities = core.array(list), counts = counts, total = total, listed = #list, truncated = total > #list,
			scanned = scanned, scanTruncated = dropped > 0, dropped = dropped > 0 and dropped or nil,
			timeTruncated = timeUp or nil, looked = looked,
			ms = { octree = math.floor((t1 - t0) * 1000 + 0.5), classify = math.floor((t2 - t1) * 1000 + 0.5),
				total = math.floor((t2 - t0) * 1000 + 0.5) },
			note = NOTE })
	end

	return { handlers = H, describe = describe }
end

return M
