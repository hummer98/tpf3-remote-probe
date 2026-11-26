-- strips (read only): the engine's parallel strips of tracks, the pieces a tunnel's or bridge's walls and railings
-- are made along. For each strip: what kind (carrier, edge type, tunnel, bridge), its range groups as read (each
-- group a section of the strip cut across: the tracks side by side in it, with the fraction of each piece it
-- takes), each section's length and curvature worked out from the pieces' curves, how far each track lies across
-- from the section's first, each range's ends (into another section, a dead end, the track going on, a junction,
-- or inside a piece), which sections join which, the BRIDGE component's placed pieces (when the strip has one), and
-- the fields that could not be read. Used by the strips command: given pieces (--edge) or every track piece near a
-- point (--at, --radius). Read in the GUI's Lua state, or in the probe's game script through eval --gs (tf3ctl strips
-- --gs): run() is the same in both, and the answer's where says which.
--
-- What is read (api/tealdef):
--   api.engine.system.baseParallelStripSystem.getStrips(edge) : {Entity} (engine/system.d.tl BaseParallelStripSystem;
--     a piece can be in more than one strip)
--   api.engine.util.parallelStrip.getStripInfo(strip) : StripInfo { carrier (Carrier: ROAD, RAIL, TRAM, OTHER, AIR,
--     WATER), edgeType (BaseEdgeType: NORMAL, BRIDGE, TUNNEL), edgeTypeIndex }, isTunnel(strip), isBridge(strip)
--     (engine/util.d.tl UtilParallelStrip)
--   BASE_PARALLEL_STRIP (engine.d.tl BaseParallelStrip): rangeGroups ({{BaseEdgeRange}}, rangeGroups_native when
--     that does not read); BaseEdgeRange { edge, bounds {number, number} } ("a fraction of a base edge")
--   BRIDGE (engine.d.tl Bridge): intervals ({Interval { splines {{Vec3f}}, railingModels {{integer, Mat4f}} }})
--   BASE_EDGE of each piece: type, typeIndex, roadType, node0 / node1, position0 / 1, tangent0 / 1, laneConfigs
--   api.engine.system.streetSystem.getNodeTrackSegments(node) at a strip's ends (one piece there: a dead end)
--   for --at: api.engine.system.octreeSystem.findIntersectingEntities over the square round the circle, as around
-- Not read, as no component or call gives them (the engine hands them to the tunnel's updateFn only, research
-- 2026-11-14): each lane's type (the bits that close the side walls), the railing intervals and their dead-end
-- intervals, railingWidth, beginNeedEntry / endNeedEntry. The answer's unread lists them, with every field above
-- that did not read.
-- Every engine call is in pcall and asked only about entities the engine says exist. Nothing is sent or changed.
--
-- Measured in a game (2026-11-26, probe-flat-base-2: tunnel tracks 2669 0,0-100,0 and 2671 100,0-200,0 end to end,
-- 2673 0,5-200,5 beside them, 2674 branching off at 100,0): 2669, 2671 and 2673 share strip 2686, whose rangeGroups
-- are [[2669 0-1, 2673 0-0.5], [2671 0-1, 2673 0.5-1]]; the branch is strip 2684 of its own. So a range group is
-- one section of the strip cut across (the tracks side by side there), not one track along the strip, and a piece
-- can be split between sections.
-- Guesses (said in the answer's note): a piece's curve is the cubic Hermite of position0 / 1 and tangent0 / 1, and a
-- range's bounds are that curve's parameter; across is measured between the ranges' middles; the groups are read in
-- their order along the strip (groupsInOrder says whether each joins the next, it is not taken for granted).
local M = {}

M.MOD = "hummer_remote_probe"
M.STRIPS_MAX = 40 -- strips per answer (more: cut, stripsTruncated)
M.GROUPS_MAX = 64 -- range groups per strip read (each a section along it: a long strip has many)
M.RANGES_MAX = 64 -- ranges per group read
M.INTERVALS_MAX = 16 -- BRIDGE intervals per strip read
M.MODELS_MAX = 8 -- placed pieces per interval given (the count is always given)
M.SAMPLES = 16 -- steps along a range for its length and curvature (Simpson's rule: even)
M.TIME_MS = 2000 -- the most one answer reads for (the whole read runs in one frame)
M.EPS = 1e-4 -- a bound this near 0 or 1 is the piece's end
M.NOTE = "read only. A range group is one section of the strip cut across: the tracks side by side in it, a " ..
	"piece longer than a section split between groups (seen in a game 2026-11-26). Not checked in a game yet: a " ..
	"piece's curve as the Hermite of position0/1 and tangent0/1, a range's bounds as its parameter, across between " ..
	"the ranges' middles (+ to the right of the group's first range looking along it), the groups' order along the " ..
	"strip (groupsInOrder: whether each joins the next). lane.type, the railing intervals and their dead-end " ..
	"intervals are given to the tunnel's updateFn only and are not read (unread)"
-- what is never read, whichever strip (see the head of the file)
M.NEVER_READ = { "lane.type (given to the tunnel's updateFn only)",
	"railingIntervals (given to the tunnel's updateFn only; length and curvature here are worked out)",
	"beginDeadEndIntervals / endDeadEndIntervals (given to the tunnel's updateFn only; ends here are worked out)",
	"railingWidth, beginNeedEntry, endNeedEntry (given to the tunnel's updateFn only)" }

local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end
local function r3(v) return finite(v) and math.floor(v * 1000 + 0.5) / 1000 or nil end
local function r6(v) return finite(v) and math.floor(v * 1e6 + 0.5) / 1e6 or nil end

---------------------------------------------------------------------------------------------------------------------
-- pure geometry (tested without a game)

-- a cubic Hermite's first and second derivative at t (p0, p1, t0, t1: { x, y, z })
local function d1(c, t, k)
	return (6 * t * t - 6 * t) * c.p0[k] + (3 * t * t - 4 * t + 1) * c.t0[k] + (-6 * t * t + 6 * t) * c.p1[k]
		+ (3 * t * t - 2 * t) * c.t1[k]
end
local function d2(c, t, k)
	return (12 * t - 6) * c.p0[k] + (6 * t - 4) * c.t0[k] + (-12 * t + 6) * c.p1[k] + (6 * t - 2) * c.t1[k]
end
function M.point(c, t)
	local h00, h10 = 2 * t ^ 3 - 3 * t ^ 2 + 1, t ^ 3 - 2 * t ^ 2 + t
	local h01, h11 = -2 * t ^ 3 + 3 * t ^ 2, t ^ 3 - t ^ 2
	local out = {}
	for _, k in ipairs({ "x", "y", "z" }) do
		out[k] = h00 * c.p0[k] + h10 * c.t0[k] + h01 * c.p1[k] + h11 * c.t1[k]
	end
	return out
end
function M.direction(c, t) return { x = d1(c, t, "x"), y = d1(c, t, "y"), z = d1(c, t, "z") } end

-- a curve from b0 to b1 (either way round): length (3D, m), turn (signed, radians, plan view: + to the left),
-- curvature samples (1/m, plan view, + to the left) as mean (turn / plan length) and the largest |curvature|.
-- nil when the curve is not all finite numbers
function M.measure(c, b0, b1, n)
	n = n or M.SAMPLES
	if n % 2 == 1 then n = n + 1 end
	-- (by name: a list with a nil in it would stop ipairs early)
	for _, k in ipairs({ "p0", "p1", "t0", "t1" }) do
		local v = c[k]
		if not (v and finite(v.x) and finite(v.y) and finite(v.z)) then return nil end
	end
	if not (finite(b0) and finite(b1)) then return nil end
	local h = (b1 - b0) / n
	local len, plan, turn, maxK = 0, 0, 0, 0
	for i = 0, n do
		local t = b0 + i * h
		local x1, y1, z1 = d1(c, t, "x"), d1(c, t, "y"), d1(c, t, "z")
		local x2, y2 = d2(c, t, "x"), d2(c, t, "y")
		local s3 = math.sqrt(x1 * x1 + y1 * y1 + z1 * z1)
		local s2sq = x1 * x1 + y1 * y1
		local s2 = math.sqrt(s2sq)
		local w = (i == 0 or i == n) and 1 or (i % 2 == 1 and 4 or 2)
		len = len + w * s3
		plan = plan + w * s2
		-- dθ/dt = (x'y'' - y'x'') / (x'^2 + y'^2); κ = that / |p'|
		if s2sq > 1e-12 then
			turn = turn + w * (x1 * y2 - y1 * x2) / s2sq
			local k = math.abs((x1 * y2 - y1 * x2) / (s2sq * s2))
			if k > maxK then maxK = k end
		end
	end
	local f = math.abs(h) / 3
	len, plan = len * f, plan * f
	turn = turn * h / 3 -- (signed: a range read backwards turns the other way)
	return { length = len, plan = plan, turn = turn, maxCurvature = maxK }
end

-- the across offset of point q from a line through a with direction d (plan view): + to the right
function M.across(a, d, q)
	local L = math.sqrt(d.x * d.x + d.y * d.y)
	if not (L > 1e-9) then return nil end
	return ((q.x - a.x) * d.y - (q.y - a.y) * d.x) / L
end

-- the least plan distance from (x, y) to the curve, along SAMPLES straight steps
function M.nearest(c, x, y, n)
	n = n or M.SAMPLES
	local best, prev = math.huge, M.point(c, 0)
	for i = 1, n do
		local q = M.point(c, i / n)
		local a, b = { x = prev.x, y = prev.y }, { x = q.x, y = q.y }
		local dx, dy = b.x - a.x, b.y - a.y
		local L2 = dx * dx + dy * dy
		local t = L2 > 0 and math.max(0, math.min(1, ((x - a.x) * dx + (y - a.y) * dy) / L2)) or 0
		local px, py = a.x + t * dx - x, a.y + t * dy - y
		local d = math.sqrt(px * px + py * py)
		if d < best then best = d end
		prev = q
	end
	return best
end

-- a range's end at bound b: "node0" (b = 0), "node1" (b = 1) or nil (inside the piece)
function M.endOf(b)
	if not finite(b) then return nil end
	if math.abs(b) <= M.EPS then return "node0" end
	if math.abs(b - 1) <= M.EPS then return "node1" end
	return nil
end

-- what an end is from the count of track pieces at its node: 1 dead end, 2 the track goes on, more a junction
function M.endKind(count)
	if count == nil then return "unknown" end
	if count <= 1 then return "deadEnd" end
	if count == 2 then return "continues" end
	return "junction"
end

---------------------------------------------------------------------------------------------------------------------
-- reading the engine (global api: the GUI's, or the game script's when run through eval --gs)

local function coreOf(opts)
	if opts and opts.core then return opts.core end
	return (ug_require or require)(M.MOD .. "::/remote_core.lua")
end

local function try(fn)
	local ok, v = pcall(fn)
	if ok then return v end
	return nil
end

-- args (core.stripsRequest's) -> the answer (a plain table). opts: core, clock (seconds), where ("gui" / "gs")
function M.run(args, opts)
	opts = opts or {}
	local core = coreOf(opts)
	local where = opts.where or "gui"
	local r, err = core.stripsRequest(args)
	if not r then return { ok = false, error = err, where = where } end
	-- (os.time in a game script, as os.clock there is the process's CPU time: whole seconds, so ms is rough)
	local clock = opts.clock or function() return os.time() end
	local t0 = clock()
	local field, size, at = core.field, core.size, core.at

	local function ctOf(kind) return try(function() return api.type.ComponentType[kind] end) end
	local function exists(e)
		return type(e) == "number" and e >= 0 and try(function() return api.engine.entityExists(e) end) == true
	end
	local function comp(e, kind)
		local k = ctOf(kind)
		if k == nil then return nil end
		return try(function() return api.engine.getComponent(e, k) end)
	end
	-- an enum value's name, from the declared names (no walk over the enum)
	local function nameIn(enumName, names, v)
		if v == nil then return nil end
		local enum = try(function() return api.type.enum[enumName] end)
		if enum then
			for _, n in ipairs(names) do
				if try(function() return enum[n] end) == v then return n end
			end
		end
		return tonumber(v) or tostring(v)
	end
	local CARRIERS = { "ROAD", "RAIL", "TRAM", "OTHER", "AIR", "WATER" }
	local EDGE_TYPES = { "NORMAL", "BRIDGE", "TUNNEL" }
	local function vec(v)
		local x, y, z = tonumber(field(v, "x")), tonumber(field(v, "y")), tonumber(field(v, "z"))
		if not (finite(x) and finite(y)) then return nil end
		return { x = x, y = y, z = finite(z) and z or 0 }
	end
	local function rv(v) return v and { x = r3(v.x), y = r3(v.y), z = r3(v.z) } or nil end

	local unread = {}
	local function miss(what) unread[what] = true end

	-- the pieces, each read once
	local pieces = {}
	local function piece(e)
		if pieces[e] ~= nil then return pieces[e] or nil end
		if not exists(e) then pieces[e] = false; return nil end
		local be = comp(e, "BASE_EDGE")
		if be == nil then pieces[e] = false; return nil end
		local p = { edge = e }
		p.type = nameIn("BaseEdgeType", EDGE_TYPES, field(be, "type"))
		p.typeIndex = tonumber(field(be, "typeIndex"))
		local rt = field(be, "roadType")
		local street = try(function() return api.type.enum.RoadType.STREET end)
		if rt ~= nil and street ~= nil then p.track = rt ~= street
		else
			-- without roadType or the enum: a piece with no street component is a track
			if rt ~= nil then miss("api.type.enum.RoadType.STREET (track told by BASE_EDGE_STREET instead)") end
			p.track = comp(e, "BASE_EDGE_STREET") == nil
		end
		p.node0, p.node1 = tonumber(field(be, "node0")), tonumber(field(be, "node1"))
		local c = { p0 = vec(field(be, "position0")), p1 = vec(field(be, "position1")),
			t0 = vec(field(be, "tangent0")), t1 = vec(field(be, "tangent1")) }
		if c.p0 and c.p1 and c.t0 and c.t1 then p.curve = c else miss("BASE_EDGE position0/1, tangent0/1 (piece " .. e .. ")") end
		p.laneCount = size(field(be, "laneConfigs"))
		pieces[e] = p
		return p
	end
	local function pieceOut(p)
		local c = p.curve
		local m = c and M.measure(c, 0, 1)
		return { edge = p.edge, type = p.type, typeIndex = p.typeIndex, track = p.track, node0 = p.node0, node1 = p.node1,
			from = c and rv(c.p0), to = c and rv(c.p1), tangent0 = c and rv(c.t0), tangent1 = c and rv(c.t1),
			length = m and r3(m.length), laneCount = p.laneCount }
	end

	-- the track pieces at a node: their count, nil when not readable
	local segCache = {}
	local function trackCount(n)
		if n == nil then return nil end
		if segCache[n] ~= nil then return segCache[n] or nil end
		local v = exists(n) and try(function() return api.engine.system.streetSystem.getNodeTrackSegments(n) end)
		segCache[n] = v and size(v) or false
		if not v then miss("streetSystem.getNodeTrackSegments (node " .. n .. ")") end
		return segCache[n] or nil
	end

	local timeUp = false
	-- the pieces to start from
	local starts, scan = {}, nil
	if r.edges then
		for _, e in ipairs(r.edges) do starts[#starts + 1] = e end
	else
		scan = { at = { x = r.x, y = r.y }, radius = r.radius, pieces = 0, tracks = 0 }
		local found, dropped = {}, 0
		local okW, errW = pcall(function()
			local box = api.type.Box3.new(api.type.Vec3f.new(r.x - r.radius, r.y - r.radius, -1000),
				api.type.Vec3f.new(r.x + r.radius, r.y + r.radius, 5000))
			api.engine.system.octreeSystem.findIntersectingEntities(box, function(e)
				e = tonumber(e)
				if e then
					if #found < core.AROUND_SCAN_MAX then found[#found + 1] = e else dropped = dropped + 1 end
				end
			end)
		end)
		if not okW then
			return { ok = false, where = where, error = "the octree could not be read: " .. tostring(errW), note = M.NOTE }
		end
		table.sort(found)
		-- more than the octree list holds: "no track here" could be "not all looked at"
		if dropped > 0 then scan.dropped = dropped end
		local seen = {}
		for i, e in ipairs(found) do
			-- the whole read is one frame: look at the clock now and then, as around does
			if i % 200 == 0 and (clock() - t0) * 1000 > M.TIME_MS then
				timeUp = true; scan.timeTruncated = true; scan.looked = i - 1; break
			end
			if not seen[e] then
				seen[e] = true
				local p = piece(e)
				if p then
					scan.pieces = scan.pieces + 1
					local c = p.curve
					if p.track and c and M.nearest(c, r.x, r.y) <= r.radius then
						scan.tracks = scan.tracks + 1
						starts[#starts + 1] = e
					end
				end
			end
		end
	end

	local sys = try(function() return api.engine.system.baseParallelStripSystem end)
	local util = try(function() return api.engine.util.parallelStrip end)
	if sys == nil or try(function() return sys.getStrips end) == nil then
		return { ok = false, where = where, note = M.NOTE, scan = scan,
			error = "api.engine.system.baseParallelStripSystem.getStrips is not in this Lua state" ..
				(where == "gui" and " (try strips --gs: the game script's state)" or "") }
	end

	-- the strips of each piece asked for, each strip once, in the order first met
	local stripIds, stripOf, byEdge, missing = {}, {}, {}, {}
	for _, e in ipairs(starts) do
		if (clock() - t0) * 1000 > M.TIME_MS then timeUp = true; break end
		local entry = { edge = e }
		if not exists(e) then
			entry.error = "no such entity"
			missing[#missing + 1] = e
		elseif comp(e, "BASE_EDGE") == nil then
			entry.error = "not a road or track piece (no BASE_EDGE)"
		else
			local ok, list = pcall(function() return sys.getStrips(e) end)
			if not ok then
				entry.error = "getStrips failed: " .. tostring(list)
			else
				local ids = {}
				for i = 1, size(list) do
					local s = tonumber(at(list, i))
					if s then
						ids[#ids + 1] = s
						if not stripOf[s] then stripOf[s] = true; stripIds[#stripIds + 1] = s end
					end
				end
				entry.strips = core.array(ids)
			end
		end
		byEdge[#byEdge + 1] = entry
	end
	local truncated = #stripIds > r.limit
	while #stripIds > r.limit do table.remove(stripIds) end

	local function readStrip(s)
		local out = { strip = s }
		local here = {}
		local function un(what) here[#here + 1] = what end
		if not exists(s) then out.error = "the strip is not an entity the engine has"; return out end
		-- kind
		local info = util and try(function() return util.getStripInfo(s) end)
		if info ~= nil then
			out.stripInfo = { carrier = nameIn("Carrier", CARRIERS, field(info, "carrier")),
				edgeType = nameIn("BaseEdgeType", EDGE_TYPES, field(info, "edgeType")),
				edgeTypeIndex = tonumber(field(info, "edgeTypeIndex")) }
			for _, k in ipairs({ "carrier", "edgeType", "edgeTypeIndex" }) do
				if out.stripInfo[k] == nil then un("stripInfo." .. k) end
			end
		else
			un("parallelStrip.getStripInfo")
		end
		local tun = util and try(function() return util.isTunnel(s) end)
		if type(tun) == "boolean" then out.isTunnel = tun else un("parallelStrip.isTunnel") end
		local bri = util and try(function() return util.isBridge(s) end)
		if type(bri) == "boolean" then out.isBridge = bri else un("parallelStrip.isBridge") end
		-- range groups. Measured 2026-11-26 (three tunnel tracks, 2669 and 2671 end to end beside 2673 twice as
		-- long): rangeGroups = [[2669 0-1, 2673 0-0.5], [2671 0-1, 2673 0.5-1]]. So a group is one section of the
		-- strip, cut across: the ranges of the tracks side by side in it, and a piece longer than a section is in
		-- more than one group, a part in each. A group is not one track along the strip.
		local bps = comp(s, "BASE_PARALLEL_STRIP")
		local rg = bps and field(bps, "rangeGroups")
		if rg == nil and bps then rg = field(bps, "rangeGroups_native"); out.groupsFrom = rg ~= nil and "rangeGroups_native" or nil end
		if bps == nil then un("BASE_PARALLEL_STRIP")
		elseif rg == nil then un("BASE_PARALLEL_STRIP.rangeGroups") end
		local groups, raw = {}, {}
		local nG = size(rg)
		out.groupCount = nG
		if nG > M.GROUPS_MAX then out.groupsTruncated = true end
		-- first pass: each range as read, measured on its piece's curve
		for gi = 1, math.min(nG, M.GROUPS_MAX) do
			local grp = at(rg, gi)
			local g = { group = gi, edges = {}, ranges = {} }
			local rawG = {}
			local nR = size(grp)
			g.rangeCount = nR
			if nR > M.RANGES_MAX then g.rangesTruncated = true end
			for ri = 1, math.min(nR, M.RANGES_MAX) do
				local rr = at(grp, ri)
				local e = tonumber(field(rr, "edge"))
				local bounds = field(rr, "bounds")
				local b0, b1 = tonumber(at(bounds, 1)), tonumber(at(bounds, 2))
				-- a bound that did not read is false, not a hole (a hole would break the JSON array)
				local bb = { r6(b0) or false, r6(b1) or false }
				rawG[#rawG + 1] = { edge = e, bounds = core.array({ bb[1], bb[2] }) }
				local one = { edge = e, bounds = core.array({ bb[1], bb[2] }),
					share = finite(b0) and finite(b1) and r6(math.abs(b1 - b0)) or nil }
				if e == nil then un("rangeGroups[" .. gi .. "][" .. ri .. "].edge") end
				if b0 == nil or b1 == nil then un("rangeGroups[" .. gi .. "][" .. ri .. "].bounds") end
				g.edges[#g.edges + 1] = e
				local p = e and piece(e)
				if e and not p then one.error = "the piece does not exist or has no BASE_EDGE" end
				local m = p and p.curve and b0 and b1 and M.measure(p.curve, b0, b1)
				if m then one.length = r3(m.length) end
				if p and p.curve and b0 and b1 then
					one.from, one.to = rv(M.point(p.curve, b0)), rv(M.point(p.curve, b1))
					-- the middle of the range and the way it runs there (bounds read 1 to 0: the other way)
					local mid = (b0 + b1) / 2
					local dir = M.direction(p.curve, mid)
					if b1 < b0 then dir = { x = -dir.x, y = -dir.y, z = -dir.z } end
					one._mid, one._dir = M.point(p.curve, mid), dir
				end
				one._m, one._p, one._b = m, p, { b0, b1 }
				g.ranges[#g.ranges + 1] = one
			end
			groups[#groups + 1] = g
			raw[#raw + 1] = core.array(rawG)
		end
		-- every range end in the strip, to tell an end shared with another group (the strip goes on into the next
		-- section) from an end of the strip
		local endsAll = {}
		for _, g in ipairs(groups) do
			for _, one in ipairs(g.ranges) do
				for k = 1, 2 do
					local b = one._b[k]
					local side = M.endOf(b)
					endsAll[#endsAll + 1] = { group = g.group, edge = one.edge, bound = b,
						node = side and one._p and one._p[side] or nil }
				end
			end
		end
		local function joinsOf(gi, e, b, node)
			local found = {}
			for _, x in ipairs(endsAll) do
				if x.group ~= gi and not found[x.group] then
					local sameCut = e ~= nil and x.edge == e and finite(b) and finite(x.bound) and math.abs(x.bound - b) <= M.EPS
					if sameCut or (node ~= nil and x.node == node) then found[x.group] = true end
				end
			end
			local list = {}
			for k in pairs(found) do list[#list + 1] = k end
			table.sort(list)
			return list
		end
		-- second pass: each section's length, curvature and width, each range's across and ends
		local totalLen, totalTurn, totalPlan, allMeasured, anyMeasured = 0, 0, 0, true, false
		local shares, shareOrder = {}, {}
		local dead = {}
		for _, g in ipairs(groups) do
			local nR = #g.ranges
			local len, lmin, lmax, plan, turn, maxK, measured = 0, nil, nil, 0, 0, 0, nR > 0
			-- (the first range's middle kept apart: its working fields are cleared as the loop passes it)
			local refMid, refDir = g.ranges[1] and g.ranges[1]._mid, g.ranges[1] and g.ranges[1]._dir
			local lo, hi, acrossOk = 0, 0, nR > 0
			local joins = {}
			for _, one in ipairs(g.ranges) do
				local m = one._m
				if m then
					len, plan, turn = len + m.length, plan + m.plan, turn + m.turn
					lmin = (lmin == nil or m.length < lmin) and m.length or lmin
					lmax = (lmax == nil or m.length > lmax) and m.length or lmax
					if m.maxCurvature > maxK then maxK = m.maxCurvature end
				else
					measured = false
				end
				-- across: from the group's first range, at the middles of both, + to the right looking along the
				-- first one (a straight line through its middle: right for parallel tracks, rough on a tight curve)
				local a = refMid and refDir and one._mid and M.across(refMid, refDir, one._mid)
				if a then
					one.across = r3(a)
					if a < lo then lo = a end
					if a > hi then hi = a end
				else
					acrossOk = false
				end
				local function endAt(k, which)
					local b = one._b[k]
					local side = M.endOf(b)
					local d = { at = which, edge = one.edge, bound = r6(b) }
					local node = side and one._p and one._p[side] or nil
					d.node = node
					if side then d.trackPieces = trackCount(node) end
					local j = joinsOf(g.group, one.edge, b, node)
					if #j > 0 then
						d.kind = "joinsGroup"
						d.joins = core.array(j)
						for _, x in ipairs(j) do joins[x] = true end
					elseif side == nil then
						d.kind = b and "insidePiece" or "unknown"
					else
						d.kind = M.endKind(d.trackPieces)
					end
					if d.kind == "deadEnd" then dead[#dead + 1] = { group = g.group, at = which, node = node, edge = one.edge } end
					return d
				end
				one.ends = core.array({ endAt(1, "begin"), endAt(2, "end") })
				if one.edge then
					local sh = shares[one.edge]
					if not sh then
						sh = { edge = one.edge, groups = {}, share = 0 }
						shares[one.edge] = sh; shareOrder[#shareOrder + 1] = sh
					end
					sh.groups[#sh.groups + 1] = g.group
					sh.share = one.share and sh.share and sh.share + one.share or false
				end
				one._mid, one._dir, one._m, one._p, one._b = nil, nil, nil, nil, nil
			end
			if measured then
				-- the section's length along the strip: the mean of its tracks' (side by side on a curve the outer
				-- one is longer: lengthMin / lengthMax)
				g.length = r3(len / nR)
				g.lengthMin, g.lengthMax = r3(lmin), r3(lmax)
				g.curvature = { mean = plan > 0 and r6(turn / plan) or nil, maxAbs = r6(maxK), turnDeg = r3(math.deg(turn / nR)) }
				totalLen, totalTurn, totalPlan = totalLen + len / nR, totalTurn + turn / nR, totalPlan + plan / nR
				anyMeasured = true
			elseif nR > 0 then
				g.lengthWhy = "a piece's curve or a range's bounds did not read"
				allMeasured = false
			end
			if acrossOk then
				g.width = r3(hi - lo)
			elseif nR > 0 then
				g.acrossWhy = "a range's middle could not be worked out (its piece's curve or bounds did not read)"
			end
			local jl = {}
			for k in pairs(joins) do jl[#jl + 1] = k end
			table.sort(jl)
			g.joins = core.array(jl)
			g.edges = core.array(g.edges)
			g.ranges = core.array(g.ranges)
		end
		out.groups = core.array(groups)
		out.rangeGroups = core.array(raw) -- (as read: edge and bounds only)
		-- the strip as a whole: its sections' lengths added up (nil when one did not measure; an empty group adds
		-- nothing)
		out.length = allMeasured and anyMeasured and r3(totalLen) or nil
		out.curvatureMean = totalPlan > 0 and r6(totalTurn / totalPlan) or nil
		-- the groups as read one after another along the strip: each joins the next (nil with fewer than two)
		if #groups >= 2 then
			local chain = true
			for i = 1, #groups - 1 do
				local ok = false
				for _, x in ipairs(groups[i].joins) do if x == i + 1 then ok = true end end
				if not ok then chain = false end
			end
			out.groupsInOrder = chain
		end
		local sl = {}
		for _, sh in ipairs(shareOrder) do
			sl[#sl + 1] = { edge = sh.edge, groups = core.array(sh.groups), share = sh.share and r6(sh.share) or nil }
		end
		out.edgeShares = core.array(sl)
		out.deadEnds = core.array(dead)
		out.laneType = "unread"
		-- BRIDGE: the placed pieces (a tunnel's walls, if tunnels carry it)
		local br = comp(s, "BRIDGE")
		if br == nil then
			out.bridge = "none (no BRIDGE component read)"
		else
			local iv = field(br, "intervals")
			local nI = size(iv)
			local list = {}
			for ii = 1, math.min(nI, M.INTERVALS_MAX) do
				local one = at(iv, ii)
				local models = field(one, "railingModels")
				local nM = size(models)
				local shown = {}
				for mi = 1, math.min(nM, M.MODELS_MAX) do
					local m = at(models, mi)
					local id = tonumber(at(m, 1))
					local mat = at(m, 2)
					local pos = try(function() local v = mat:getTransl(); return { x = r3(v.x), y = r3(v.y), z = r3(v.z) } end)
					local name = id and try(function() return api.res.modelRep.getName(id) end)
					shown[#shown + 1] = { model = id, name = type(name) == "string" and name or nil, at = pos }
				end
				list[#list + 1] = { splines = size(field(one, "splines")), railingModels = nM, models = core.array(shown),
					modelsTruncated = nM > M.MODELS_MAX or nil }
			end
			out.bridge = { intervals = nI, list = core.array(list), intervalsTruncated = nI > M.INTERVALS_MAX or nil }
		end
		out.unread = core.array(here)
		return out
	end

	local strips = {}
	for _, s in ipairs(stripIds) do
		if (clock() - t0) * 1000 > M.TIME_MS then timeUp = true; break end
		local ok, d = pcall(readStrip, s)
		strips[#strips + 1] = ok and d or { strip = s, error = tostring(d) }
	end
	-- the pieces met, in id order
	local ids = {}
	for e, p in pairs(pieces) do if p then ids[#ids + 1] = e end end
	table.sort(ids)
	local plist = {}
	local used = {}
	for _, st in ipairs(strips) do
		for _, g in ipairs(st.groups or {}) do for _, e in ipairs(g.edges) do used[e] = true end end
	end
	for _, e in ipairs(starts) do used[e] = true end
	for _, e in ipairs(ids) do if used[e] then plist[#plist + 1] = pieceOut(pieces[e]) end end
	local never = {}
	for _, w in ipairs(M.NEVER_READ) do never[#never + 1] = w end
	local others = {}
	for w in pairs(unread) do others[#others + 1] = w end
	table.sort(others)
	for _, w in ipairs(others) do never[#never + 1] = w end
	local okCount = 0
	for _, st in ipairs(strips) do if not st.error then okCount = okCount + 1 end end
	-- pieces asked for by id, none of which the engine has: nothing was read
	local none = r.edges and #missing == #r.edges
	return { ok = not none, error = none and ("no such piece: " .. table.concat(missing, ", ")) or nil, where = where, strips = core.array(strips), stripCount = #strips, stripsRead = okCount,
		stripsTruncated = truncated or nil, timeUp = timeUp or nil, asked = core.array(byEdge),
		missing = #missing > 0 and core.array(missing) or nil, pieces = core.array(plist), scan = scan,
		unread = core.array(never), ms = math.floor((clock() - t0) * 1000 + 0.5), note = M.NOTE }
end

-- the GUI's handler. ctx: core, answer, fail, appTime (seconds)
function M.new(ctx)
	local core, answer, fail = ctx.core, ctx.answer, ctx.fail
	local H = {}
	function H.strips(c)
		local res = M.run(c.args, { core = core, clock = ctx.appTime, where = "gui" })
		if res.ok == false and res.error and not res.note then return fail(c.id, res.error) end
		answer(c.id, res)
	end
	return { handlers = H }
end

return M
