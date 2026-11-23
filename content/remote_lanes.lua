-- lanes (read only): a road or track piece's lanes, one entry per lane, left to right looking from node0 to node1:
-- which number it is, how far from the piece's middle and on which side, its direction, its transport modes by
-- name (TRAM, ELECTRIC_TRAM, BUS, CAR, PERSON, ...), speed and width; for the piece, its street type, bridge or
-- tunnel, whether it has tram track (none, tram, electric) and bus lanes, and its length. Used by the lanes
-- command (one or more pieces by id, with the transport network's own edges too) and by around --lanes (each
-- street and track listed).
--
-- What is read (api/tealdef, 40444):
--   BASE_EDGE (engine.d.tl BaseEdge): laneConfigs ({LaneConfig}; laneConfig, as declared too, when that is empty),
--     roadTemplate, roadStyle, type (BaseEdgeType: NORMAL, BRIDGE, TUNNEL), roadType, node0 / node1, position0 /
--     position1, distance
--   LaneConfig (type.d.tl): speed, width, height, forward, transportModes ({TransportMode : boolean}), offset
--     ("Offset from center"). The base's street templates give offset as a small nudge (town_new_medium_tram_
--     electrified: sidewalks 0.15 / -0.15, the tram lanes -0.5 / 0.5), not the lane's place: so the place here is
--     worked out from the widths, left to right (as type.d.tl says laneConfigs run), plus offset, + to the right
--     (a guess from those numbers: both sidewalks nudge inwards, both tram lanes outwards)
--   BASE_EDGE_STREET (engine.d.tl BaseEdgeStreet: only precedenceNode0 / 1 declared): streetType, tramTrackType
--     and hasBus are read too where the game has them (TF2 had them), and given as read (street)
--   TRANSPORT_NETWORK (engine.d.tl TransportNetwork; lanes only): edges[] (type.d.tl Edge: transportModes,
--     speedLimit, geometry.length / width / type / cubicOffsetSpline.offset), the engine's order, not matched to
--     laneConfigs here
-- tramTrackType here comes from the lanes: ELECTRIC when a lane has ELECTRIC_TRAM, YES when one has TRAM, NO when
-- none has either (unknown when a lane's modes did not all read as names). A bus lane is a lane with BUS and
-- without CAR. Mode names come from enum[name] for type.d.tl's sixteen names (no walk over the enum).
-- Every engine call is in pcall and asked only about entities the engine says exist. Nothing is sent.
--
-- Not checked in a game yet (written 2026-11-23): whether the game's laneConfigs keep the template's order and
-- offsets, whether transportModes' keys are the enum's values (modeKeys gives them as read), and what
-- TRANSPORT_NETWORK's edges are per lane. The answer's note says so.
local M = {}

M.MAX_LANES = 32 -- lanes per piece read (more: truncated, as no road has so many)
M.MAX_NETWORK = 64 -- transport network edges per piece copied out
M.NOTE = "read only; not checked in a game yet. Lanes run left to right looking from node0 to node1 (type.d.tl); " ..
	"centre is worked out from the widths plus offset, + to the right (a guess from the base's templates); side " ..
	"goes by the widths alone. atNode0 / atNode1 are the numbers road --inspect-node's laneConnections use. " ..
	"tramTrackType comes from the lanes' transport modes. modeKeys are the keys as read (the enum's values)"

local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end
local function r3(v) return finite(v) and math.floor(v * 1000 + 0.5) / 1000 or nil end

-- the places of lanes across the piece: lanes = { { width, offset }, ... } left to right -> per lane
-- { centre, left, right, side } (metres from the middle, + to the right) and the whole width. side ("left",
-- "right" or "middle") goes by the widths alone, not the offset: offset's sign is a guess, and a middle lane
-- nudged by it must not turn left or right; within a quarter of its width of the middle it is "middle".
-- Without every width: side from the lane's number alone (the first half left), no metres.
function M.layout(lanes)
	local n = #lanes
	local total, all = 0, n > 0
	for _, l in ipairs(lanes) do
		if finite(l.width) and l.width >= 0 then total = total + l.width else all = false end
	end
	local out = {}
	local x = -total / 2
	for i, l in ipairs(lanes) do
		local p = {}
		if all then
			local base = x + l.width / 2
			local c = base + (finite(l.offset) and l.offset or 0)
			x = x + l.width
			p.centre, p.left, p.right = r3(c), r3(c - l.width / 2), r3(c + l.width / 2)
			local tol = math.max(l.width / 4, 0.01)
			p.side = (base < -tol and "left") or (base > tol and "right") or "middle"
		else
			local mid = (n + 1) / 2
			p.side = (i < mid and "left") or (i > mid and "right") or "middle"
		end
		out[i] = p
	end
	return out, all and r3(total) or nil
end

-- what goes for the whole piece, from its lanes' mode names ({ [name] = true } per lane, lanes[i].set):
-- tramTrackType, tramLanes, busLanes (BUS without CAR), roadLanes, sidewalks (PERSON without any vehicle)
local VEHICLE = { CAR = true, BUS = true, TRUCK = true, TRAM = true, ELECTRIC_TRAM = true, TRAIN = true,
	ELECTRIC_TRAIN = true }
-- vehicleLanes: the lanes with any vehicle mode, left to right (outer ones first and last). unknown: a lane's
-- mode keys did not all read as names (then NO is not said: "unknown")
function M.summary(lanes)
	local tram, electric, unknown = false, false, false
	local vehicles = {}
	local tramLanes, busLanes, roadLanes, walks = {}, {}, {}, {}
	for i, l in ipairs(lanes) do
		local s = l.set or {}
		if s.ELECTRIC_TRAM or s.ELECTRIC_TRAM_TRACK then electric = true end
		if s.TRAM or s.ELECTRIC_TRAM or s.TRAM_TRACK or s.ELECTRIC_TRAM_TRACK then tram = true; tramLanes[#tramLanes + 1] = i end
		if s.BUS and not s.CAR then busLanes[#busLanes + 1] = i end
		if s.CAR or s.BUS or s.TRUCK then roadLanes[#roadLanes + 1] = i end
		local vehicle = false
		for k in pairs(s) do if VEHICLE[k] or k == "TRAM_TRACK" or k == "ELECTRIC_TRAM_TRACK" then vehicle = true end end
		if vehicle then vehicles[#vehicles + 1] = i end
		if s.PERSON and not vehicle then walks[#walks + 1] = i end
		if l.unnamed or l.set == nil then unknown = true end
	end
	local t = (electric and "ELECTRIC") or (tram and "YES") or (unknown and "unknown") or "NO"
	return { tramTrackType = t, tramLanes = tramLanes, vehicleLanes = vehicles,
		busLanes = busLanes, hasBusLane = #busLanes > 0, roadLanes = roadLanes, sidewalks = walks }
end

-- ctx: core, try(fn), answer(id, payload), fail(id, msg)
function M.new(ctx)
	local core, try, answer, fail = ctx.core, ctx.try, ctx.answer, ctx.fail
	local function CT() return api.type.ComponentType end
	local function ctOf(kind) return try(function() return CT()[kind] end) end
	local function exists(e)
		return type(e) == "number" and e >= 0 and e % 1 == 0 and try(function() return api.engine.entityExists(e) end) == true
	end
	local function comp(e, kind)
		local k = ctOf(kind)
		if k == nil then return nil end
		return try(function() return api.engine.getComponent(e, k) end)
	end
	local function enum(name) return try(function() return api.type.enum[name] end) end
	-- an enum value's name among the names type.d.tl gives it, by t[name] (no walk over the enum: the game's may
	-- be userdata); nil when the enum or the value is not there
	local NAMES = { RoadType = { "STREET", "TRACK" }, BaseEdgeType = { "NORMAL", "BRIDGE", "TUNNEL" },
		TramTrackType = { "NO", "YES", "ELECTRIC" }, GeometryType = { "ARC", "STRAIGHT", "CUBIC_SPLINE", "CUBIC_OFFSET_SPLINE" } }
	local function nameIn(t, v, kind)
		if t == nil or v == nil then return nil end
		for _, n in ipairs(NAMES[kind] or {}) do
			if try(function() return t[n] end) == v then return n end
		end
		return nil
	end
	local function vec(v)
		local x, y, z = tonumber(core.field(v, "x")), tonumber(core.field(v, "y")), tonumber(core.field(v, "z"))
		if not (finite(x) and finite(y)) then return nil end
		return { x = x, y = y, z = finite(z) and z or nil }
	end

	-- a set of transport modes (the engine's map, { [TransportMode] = true }) -> sorted names, { [name] = true },
	-- sorted keys as read; nil when it cannot be walked. A key that is no enum value keeps its key as its name.
	local TM_LIMIT = 64
	-- value -> name of TransportMode, by enum[name] for the names type.d.tl lists (no pairs over the enum: the
	-- game's may be userdata); made once
	local TM_NAMES = { "PERSON", "CARGO", "CAR", "BUS", "TRUCK", "TRAM", "ELECTRIC_TRAM", "TRAIN", "ELECTRIC_TRAIN",
		"AIRCRAFT", "SHIP", "SMALL_AIRCRAFT", "SMALL_SHIP", "HELICOPTER", "TRAM_TRACK", "ELECTRIC_TRAM_TRACK" }
	local tmByValue
	local function tmName(k)
		if tmByValue == nil then
			tmByValue = {}
			local TM = enum("TransportMode")
			for _, n in ipairs(TM_NAMES) do
				local v = TM and try(function() return TM[n] end)
				if v ~= nil and tmByValue[v] == nil then tmByValue[v] = n end
			end
		end
		return tmByValue[k]
	end
	local function modes(m)
		if m == nil then return nil end
		local names, set, keys = {}, {}, {}
		local unnamed, cut = false, false
		local ok = pcall(function()
			local n = 0
			for k, v in pairs(m) do
				n = n + 1
				if n > TM_LIMIT then cut = true; break end
				if v == true or (type(v) == "number" and v ~= 0) then
					local name = type(k) == "string" and k or tmName(k)
					if name == nil then name, unnamed = tostring(k), true end
					if not set[name] then names[#names + 1] = name end
					set[name] = true
					keys[#keys + 1] = k
				end
			end
		end)
		if not ok then return nil end
		table.sort(names)
		table.sort(keys, function(a, b)
			if type(a) == type(b) and (type(a) == "number" or type(a) == "string") then return a < b end
			return tostring(a) < tostring(b)
		end)
		return names, set, keys, unnamed, cut
	end

	-- the lanes of a BASE_EDGE as plain values (see the top), and whether more were there than read
	local function lanesOf(be)
		local raw = core.field(be, "laneConfigs")
		local n = core.size(raw)
		if n == 0 then raw = core.field(be, "laneConfig"); n = core.size(raw) end
		local cut = n > M.MAX_LANES
		local out = {}
		-- (only the first MAX_LANES are copied out: no whole list of a strange piece in one frame)
		for i = 1, math.min(n, M.MAX_LANES) do
			local lc = core.at(raw, i)
			local names, set, keys, unnamed, mcut = modes(core.field(lc, "transportModes"))
			local speed = tonumber(core.field(lc, "speed"))
			local fwd = core.field(lc, "forward")
			local lane = { index = i, width = r3(tonumber(core.field(lc, "width"))),
				offset = r3(tonumber(core.field(lc, "offset"))), height = r3(tonumber(core.field(lc, "height"))),
				direction = (fwd == true and "node0->node1") or (fwd == false and "node1->node0") or nil,
				speed = r3(speed), speedKmh = finite(speed) and math.floor(speed * 3.6 + 0.5) or nil,
				modes = names and core.array(names) or "unread", modeKeys = keys and core.array(keys) or nil, set = set }
			if type(fwd) == "boolean" then lane.forward = fwd end -- (false kept: an and/or would drop it)
			lane.unnamed, lane.modesTruncated = unnamed or nil, mcut or nil
			-- the number road --inspect-node's laneConnections give it (0-based, left to right looking from that
			-- node out along the piece, over every lane): at node0 k - 1, at node1 #lanes - k (set below)
			lane.atNode0 = i - 1
			out[i] = lane
		end
		for i, l in ipairs(out) do l.atNode1 = #out - i end
		return out, cut
	end

	-- the transport network's edges of a piece, as plain values; nil and why when not read
	local function network(e)
		if ctOf("TRANSPORT_NETWORK") == nil then return nil, "no TRANSPORT_NETWORK component type" end
		local tn = comp(e, "TRANSPORT_NETWORK")
		if tn == nil then return nil, "no TRANSPORT_NETWORK on this piece" end
		local edges = core.field(tn, "edges")
		local count = core.size(edges)
		local GT = try(function() return api.type.EdgeGeometry.Type end)
		local out = {}
		for i = 1, math.min(count, M.MAX_NETWORK) do
			local ed = core.at(edges, i)
			local g = core.field(ed, "geometry")
			local gtype = g and core.field(g, "type")
			local names = modes(core.field(ed, "transportModes"))
			local cos = g and core.field(g, "cubicOffsetSpline")
			out[#out + 1] = { index = i - 1, modes = names and core.array(names) or "unread",
				speedLimit = r3(tonumber(core.field(ed, "speedLimit"))),
				length = r3(tonumber(g and core.field(g, "length"))), width = r3(tonumber(g and core.field(g, "width"))),
				geometry = nameIn(GT, gtype, "GeometryType") or (gtype ~= nil and tostring(gtype) or nil),
				offset = r3(tonumber(cos and core.field(cos, "offset"))) }
		end
		return out, nil, count
	end

	-- one piece: the table described at the top, or nil and why. opts.network: also its transport network edges
	local function read(e, opts)
		opts = opts or {}
		if not exists(e) then return nil, string.format("the engine has no entity %s", tostring(e)) end
		local be = comp(e, "BASE_EDGE")
		if be == nil then return nil, string.format("entity %d is no road or track piece (no BASE_EDGE)", e) end
		local out = { edge = e }
		local rt = core.field(be, "roadType")
		out.roadType = nameIn(enum("RoadType"), rt, "RoadType") or (rt ~= nil and tostring(rt) or nil)
		local bt = core.field(be, "type")
		out.edgeType = nameIn(enum("BaseEdgeType"), bt, "BaseEdgeType") or (bt ~= nil and tostring(bt) or nil)
		local tpl, style = core.field(be, "roadTemplate"), core.field(be, "roadStyle")
		out.streetType = tpl ~= nil and tostring(tpl) or nil
		out.roadStyle = style ~= nil and tostring(style) or nil
		out.node0, out.node1 = tonumber(core.field(be, "node0")), tonumber(core.field(be, "node1"))
		local a, b = vec(core.field(be, "position0")), vec(core.field(be, "position1"))
		if a and b then
			out.from, out.to = a, b
			out.chord = r3(math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2 + ((b.z or 0) - (a.z or 0)) ^ 2))
		end
		out.distance = r3(tonumber(core.field(be, "distance")))
		-- what BASE_EDGE_STREET has of the old fields (TF2's), as read
		local bes = comp(e, "BASE_EDGE_STREET")
		if bes ~= nil then
			local s = {}
			local st = core.field(bes, "streetType")
			s.streetType = st ~= nil and (tonumber(st) or tostring(st)) or nil
			local tt = core.field(bes, "tramTrackType")
			s.tramTrackType = tt ~= nil and (nameIn(enum("TramTrackType"), tt, "TramTrackType") or tonumber(tt) or tostring(tt)) or nil
			local hb = core.field(bes, "hasBus")
			s.hasBus = type(hb) == "boolean" and hb or nil
			out.street = s
		end
		local lanes, cut = lanesOf(be)
		local places, width = M.layout(lanes)
		for i, l in ipairs(lanes) do
			local p = places[i]
			l.centre, l.left, l.right, l.side = p.centre, p.left, p.right, p.side
		end
		local sum = M.summary(lanes)
		-- each vehicle lane's place among the vehicle lanes (1 = leftmost), and whether it is an outer one
		for n, k in ipairs(sum.vehicleLanes) do
			lanes[k].vehicleIndex = n
			lanes[k].outer = (n == 1 or n == #sum.vehicleLanes) or nil
		end
		for _, l in ipairs(lanes) do l.set = nil end
		out.lanes = core.array(lanes)
		out.vehicleLanes = core.array(sum.vehicleLanes)
		out.laneCount = #lanes
		out.lanesTruncated = cut or nil
		out.width = width
		out.tramTrackType = sum.tramTrackType
		out.tramLanes, out.busLanes = core.array(sum.tramLanes), core.array(sum.busLanes)
		out.roadLanes, out.sidewalks = core.array(sum.roadLanes), core.array(sum.sidewalks)
		out.hasBusLane = sum.hasBusLane
		if #lanes == 0 then out.why = "no laneConfigs read" end
		-- BASE_EDGE_STREET's own tramTrackType (if the game has it) against the one from the lanes
		if out.street and type(out.street.tramTrackType) == "string" and sum.tramTrackType ~= "unknown"
			and out.street.tramTrackType ~= sum.tramTrackType then
			out.tramMismatch = string.format("BASE_EDGE_STREET says %s, the lanes %s", out.street.tramTrackType, sum.tramTrackType)
		end
		if opts.network then
			local net, why, count = network(e)
			if net then
				out.network = core.array(net)
				out.networkCount = count
				out.networkTruncated = count > #net or nil
			else
				out.network = "unread: " .. why
			end
		end
		return out
	end

	-- the lanes command: each piece asked for, in the order asked (one that cannot be read says why)
	local H = {}
	function H.edgeLanes(c)
		local r, err = core.edgeLanesRequest(c.args)
		if not r then return fail(c.id, err) end
		local list, okCount = {}, 0
		for _, e in ipairs(r.edges) do
			local ok, d, why = pcall(read, e, { network = r.network })
			if ok and d then
				okCount = okCount + 1
				list[#list + 1] = d
			else
				list[#list + 1] = { edge = e, error = ok and why or tostring(d) }
			end
		end
		answer(c.id, { ok = okCount > 0, edges = core.array(list), read = okCount, asked = #r.edges,
			error = okCount == 0 and (list[1] and list[1].error) or nil, note = M.NOTE })
	end

	return { read = read, handlers = H }
end

return M
