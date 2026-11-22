-- parcels (read only): the town building parcels on the left and right of a road piece (edge), or of the road
-- pieces in a rectangle, for telling whether towns may build along a piece (e.g. one a construction let go of).
-- core.parcelsRequest has the arguments.
--
-- What is read (api/tealdef: engine/system.d.tl ParcelSystem, type.d.tl ParcelData, engine.d.tl Parcel):
--   api.engine.system.parcelSystem.getSegment2ParcelData() once: a map of road piece -> its ParcelData (the two
--     lists of parcel entities, left and right). A piece the map does not have has no parcels: 0 and 0.
--     Only when that map cannot be read, getParcelData(edge), and then only for a street piece (BASE_EDGE_STREET):
--     what it does for a piece without parcel data is not known, and an assertion is past pcall.
--   each parcel's PARCEL component (left, curveParam, offset, faces; not in the ComponentType list of the
--     tealdef, so only when api.type.ComponentType.PARCEL is there), for its position and area
--   api.engine.system.townBuildingSystem.getParcel2BuildingMap() once: which parcels have a building
--   the piece: BASE_EDGE (node0 / node1, their BASE_NODE positions), BASE_EDGE_STREET (a street),
--     streetConnectorSystem.getConstructionEntityForEdge (the construction it belongs to, -1: none)
-- Every engine call is in pcall and asked only about entities the engine says exist (an unknown id may assert).
-- Nothing is sent: no command, no GUI save data.
--
-- Not checked in a game yet (written 2026-11-23): the answers say so.
local M = {}

local NOTE = "read only; not checked in a game yet: the ParcelData field names and the PARCEL component are " ..
	"read as the tealdef has them (fields: which ones were there)"

-- ctx: core, answer(id, payload, tag), fail(id, msg), try(fn), say(msg, level)
function M.new(ctx)
	local core, answer, fail, try = ctx.core, ctx.answer, ctx.fail, ctx.try

	local function CT() return api.type.ComponentType end
	local function ctOf(kind) return try(function() return CT()[kind] end) end
	local function exists(e)
		return type(e) == "number" and e >= 0 and try(function() return api.engine.entityExists(e) end) == true
	end
	-- a component of an entity known to exist; nil when the kind is not there or the entity has none
	local function comp(e, kind)
		local k = ctOf(kind)
		if k == nil or not exists(e) then return nil end
		return try(function() return api.engine.getComponent(e, k) end)
	end
	local function nodePos(n)
		n = tonumber(n)
		local bn = n and comp(n, "BASE_NODE")
		local p = bn and core.field(bn, "position")
		local x, y, z = tonumber(core.field(p, "x")), tonumber(core.field(p, "y")), tonumber(core.field(p, "z"))
		if not (x and y) then return nil end
		return { x = x, y = y, z = z }
	end

	-- the engine's maps, read once per command
	local function readMaps()
		local m = {}
		m.segments = try(function() return api.engine.system.parcelSystem.getSegment2ParcelData() end)
		m.buildings = try(function() return api.engine.system.townBuildingSystem.getParcel2BuildingMap() end)
		m.parcelType = ctOf("PARCEL") ~= nil
		m.source = m.segments ~= nil and "getSegment2ParcelData" or "getParcelData"
		return m
	end

	-- the ParcelData of a piece: from the map, else (no map) getParcelData for a street piece. -> data (nil: none),
	-- inMap (true / false / nil when there is no map), why (when nothing could be asked)
	local function parcelData(maps, edge, street)
		if maps.segments ~= nil then
			local pd = try(function() return maps.segments[edge] end)
			return pd, pd ~= nil
		end
		if street ~= true then return nil, nil, "not a street piece: getParcelData is asked only for streets" end
		local pd = try(function() return api.engine.system.parcelSystem.getParcelData(edge) end)
		if pd == nil then return nil, nil, "getParcelData gave nothing" end
		return pd, nil
	end

	-- one parcel: its building, side flag, position and area (PARCEL), as far as they read
	local function parcelEntry(maps, p)
		local e = { id = p }
		if maps.buildings ~= nil then
			local b = tonumber(try(function() return maps.buildings[p] end))
			e.building = (b and b >= 0) and b or nil
		end
		if maps.parcelType then
			local pc = comp(p, "PARCEL")
			if pc ~= nil then
				local left = core.field(pc, "left")
				if type(left) == "boolean" then e.left = left end
				e.streetSegment = tonumber(core.field(pc, "streetSegment"))
				e.curveParam = tonumber(core.field(pc, "curveParam"))
				e.offset = tonumber(core.field(pc, "offset"))
				local f = core.faceSummary(core.field(pc, "faces"))
				if f then e.x, e.y, e.z, e.area, e.faces = f.x, f.y, f.z, f.area, f.faces end
			end
		end
		return e
	end

	local function sideOf(maps, ids, list)
		local s = { count = #ids, built = maps.buildings ~= nil and 0 or nil }
		local entries, area = {}, 0
		for _, p in ipairs(ids) do
			local e = parcelEntry(maps, p)
			if s.built and e.building then s.built = s.built + 1 end
			if e.area then area = area + e.area end
			entries[#entries + 1] = e
		end
		if maps.parcelType then s.area = math.floor(area * 100 + 0.5) / 100 end
		if list then s.parcels = core.array(entries) end
		return s, entries
	end

	-- one piece: what it is, and its parcels on each side. -> the entry, or nil and why
	local function edgeEntry(maps, edge, list)
		if not exists(edge) then return nil, "no such entity: " .. edge end
		local be = comp(edge, "BASE_EDGE")
		if be == nil then return nil, "entity " .. edge .. " is no road piece (no BASE_EDGE)" end
		local e = { edge = edge }
		local hasStreetType = ctOf("BASE_EDGE_STREET") ~= nil
		if hasStreetType then e.street = comp(edge, "BASE_EDGE_STREET") ~= nil end
		e.node0, e.node1 = tonumber(core.field(be, "node0")), tonumber(core.field(be, "node1"))
		e.from, e.to = nodePos(e.node0), nodePos(e.node1)
		if e.from and e.to then
			e.length = math.floor(math.sqrt((e.to.x - e.from.x) ^ 2 + (e.to.y - e.from.y) ^ 2) * 10 + 0.5) / 10
		end
		local con = tonumber(try(function() return api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(edge) end))
		if con ~= nil then
			e.inConstruction = con >= 0
			e.construction = con >= 0 and con or nil
		end
		local pd, inMap, why = parcelData(maps, edge, e.street)
		e.inParcelMap = inMap
		if why then e.parcelError = why end
		local leftIds, rightIds, fields = core.parcelSides(pd)
		e.fields = core.array(fields)
		-- data there but none of the known field names: its keys (or what it prints as), so a wrong name does not
		-- pass for "no parcels"
		if pd ~= nil and #fields == 0 then
			local keys = {}
			pcall(function() for k in pairs(pd) do keys[#keys + 1] = tostring(k) end end)
			table.sort(keys)
			e.unreadParcelData = #keys > 0 and core.array(keys) or tostring(pd)
		end
		local lEntries, rEntries
		e.left, lEntries = sideOf(maps, leftIds, list)
		e.right, rEntries = sideOf(maps, rightIds, list)
		-- the parcels' own side flag against the list they are in (PARCEL.left): a check on the field names
		local mismatch, flagged = 0, 0
		for _, x in ipairs(lEntries) do if x.left ~= nil then flagged = flagged + 1; if x.left ~= true then mismatch = mismatch + 1 end end end
		for _, x in ipairs(rEntries) do if x.left ~= nil then flagged = flagged + 1; if x.left ~= false then mismatch = mismatch + 1 end end end
		if flagged > 0 then e.sideMismatch = mismatch end
		return e
	end

	-- the road pieces near the rect (the octree: pieces whose box meets the circle round it), kept when an end or
	-- the middle is in it. -> sorted ids
	local function edgesIn(rect)
		local cx, cy = (rect.x0 + rect.x1) / 2, (rect.y0 + rect.y1) / 2
		local r = math.sqrt((rect.x1 - rect.x0) ^ 2 + (rect.y1 - rect.y0) ^ 2) / 2 + 1
		local found, seen = {}, {}
		local function take(e)
			e = tonumber(e)
			if e and not seen[e] then seen[e] = true; found[#found + 1] = e end
		end
		local k = ctOf("BASE_EDGE")
		local list = k ~= nil and try(function()
			return api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(cx, cy), r, k)
		end) or nil
		if list ~= nil then
			for _, e in ipairs(core.toList(list)) do take(e) end
		else
			pcall(function()
				local box = api.type.Box3.new(api.type.Vec3f.new(rect.x0, rect.y0, -1000), api.type.Vec3f.new(rect.x1, rect.y1, 5000))
				api.engine.system.octreeSystem.findIntersectingEntities(box, function(e) take(e) end)
			end)
		end
		local out = {}
		for _, e in ipairs(found) do
			local be = comp(e, "BASE_EDGE")
			if be ~= nil then
				local a, b = nodePos(core.field(be, "node0")), nodePos(core.field(be, "node1"))
				local mid = a and b and { x = (a.x + b.x) / 2, y = (a.y + b.y) / 2 } or nil
				if core.inRect(a, rect) or core.inRect(b, rect) or core.inRect(mid, rect) then out[#out + 1] = e end
			end
		end
		table.sort(out)
		return out
	end

	local H = {}
	function H.parcels(c)
		local r, err = core.parcelsRequest(c.args)
		if not r then return fail(c.id, err) end
		local maps = readMaps()
		local head = { ok = true, source = maps.source, parcelComponent = maps.parcelType,
			buildingMap = maps.buildings ~= nil, note = NOTE }
		if r.edge then
			local e, eerr = edgeEntry(maps, r.edge, r.list)
			if not e then return fail(c.id, eerr) end
			head.edges = core.array({ e })
			return answer(c.id, head)
		end
		local ids = edgesIn(r.rect)
		local out, totals = {}, { edges = 0, streets = 0, withParcels = 0, left = 0, right = 0, built = 0, inConstruction = 0,
			unreadParcelData = 0 }
		for _, id in ipairs(ids) do
			local e = edgeEntry(maps, id, r.list)
			-- tracks have no parcels: streets only (or every piece when the street kind cannot be told)
			if e and e.street ~= false then
				totals.edges = totals.edges + 1
				if e.street then totals.streets = totals.streets + 1 end
				if e.left.count + e.right.count > 0 then totals.withParcels = totals.withParcels + 1 end
				totals.left, totals.right = totals.left + e.left.count, totals.right + e.right.count
				totals.built = totals.built + (e.left.built or 0) + (e.right.built or 0)
				if e.inConstruction then totals.inConstruction = totals.inConstruction + 1 end
				if e.unreadParcelData then totals.unreadParcelData = totals.unreadParcelData + 1 end
				if #out < core.PARCELS_MAX_EDGES then out[#out + 1] = e end
			end
		end
		head.rect = r.rect
		head.edges = core.array(out)
		head.totals = totals
		head.truncated = totals.edges > #out
		answer(c.id, head)
	end

	return { handlers = H }
end

return M
