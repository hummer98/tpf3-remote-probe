-- A track or road between two ends for the remote probe (connect), planned and built with the Track Connector
-- mod (modId ethan_track_connector), which must be enabled for the save. This file uses that mod's code only
-- through its public modules at run time (require), never a copy of it:
--   * its planner (tc_planner.script.tl) finds the route, here in guiUpdate, a slice of it each frame: the
--     planner runs in a coroutine and yields once its slice is used up;
--   * the planner sees the map only through a World of functions (height, water, blocked, crossing), and this
--     file builds a small one of its own from the engine: terrain heights and water, buildings and
--     constructions as blocked land, existing roads and tracks as crossings;
--   * the route then goes to Track Connector's game script as the same events its own tool sends
--     (tc_settings, tc_setFromEnd, tc_setToEnd, tc_route, tc_estimate, tc_build): the dry run with its cost and
--     the build are done there, by its code, and the outcome is read back from its game script state.
-- Only single tracks (or roads) without level crossings and between two free ends (a node with one piece); a
-- station stands for its free platform ends, of which the pair facing each other best is taken.
--
-- Track Connector keeps one state for everyone: a player using its tool while a connect runs overwrites the
-- picked ends and the route, and the other way round. Every answer of this file is read back, and a state that
-- no longer shows this command's ends and route ends the command with an error instead of a wrong answer.
local M = {}

M.TC_MOD = "ethan_track_connector"
M.TC_PLANNER = "ethan_track_connector::/track_connector/tc_planner.script.tl"
M.TC_PROPOSAL = "ethan_track_connector::/track_connector/tc_proposal.script.tl"
M.TC_GAME_SCRIPT = "ethan_track_connector::/track_connector/track_connector.gs"
M.TC_EVENT_ID = "TrackConnector"
-- the release this was written against (mod.json revision, the version its tool shows); not yet run in a game
M.TC_WRITTEN_FOR = { revision = 3, version = "v1.3" }
M.DEFAULT_STREET = "::/infrastructure/street/country/country_new_medium.street_template"

-- Track Connector's default settings for each of its tools (its route choices, e.g. "Recommended", may plan with
-- others)
M.TRACK_DEFAULTS = { slope = 0.025, radius = 300 }
M.ROAD_DEFAULTS = { slope = 0.06, radius = 100 }

local STEP_BUDGET = 0.015 -- planner seconds per frame (Track Connector's own tool takes 6 to 30 ms)
local PROGRESS_SEC = 3
local TC_WAIT_SEC = 30 -- for the game script's answer to the events
local BUILD_RESULT_SEC = 5 -- a build's outcome is written in the command's callback, which may come later
local SETTLE_FRAMES = 5 -- before the balance after a build is read: a cost booked after the callback is in it
-- the planner's map (see newMap)
-- (GRID divides BLOCK: the cells cover each block to its edge)
local BLOCK, GRID = 200.0, 5.0 -- metres: blocks read through the octree, and the cells marked in them
local BLOCK_PAD = 15.0 -- the octree box is this much larger than the block: half the widest road plus the side room
local Z_LOW, Z_HIGH = -1000, 4000
local HEIGHT_STEP, WATER_STEP = 4.0, 10.0
local PIECE_STEP = 4.0 -- metres between the points marked along a road or track
local TRACK_HALF, ROAD_HALF = 3.0, 5.0 -- the least half width of a track and of a road
local LANE_ROOM = 1.5 -- half width per lane config of a piece
local SIDE_ROOM = 3.0 -- room for the new line beside an existing one
local BUILDING_ROOM = 4.0
local BIGGEST_BUILDING = 1000.0 -- a larger box is a town's lot or a terrain object, not something in the way
local MAP_INSET, END_ROOM = 80.0, 40.0
local BAND_MIN, BAND_SHARE, MAX_PRELOAD = 400.0, 0.3, 3000 -- the blocks read before planning
-- blocks read per frame before planning (a field, so a test can hold the map read back)
-- lateBlocksPerSlice: how many blocks off the band a planner slice reads before it waits for the next frame. A
-- count, not a time: os.clock on Linux is the whole process's CPU time and runs ahead of real time in a game with many
-- threads, and the application time may not move within a frame.
M.TUNE = { blocksPerFrame = 6, lateBlocksPerSlice = 3 }
-- around each end: a station's buildings stand beside its platform ends, so within END_FREE_R nothing built blocks
-- (a platform end may be that close to the station hall); within END_CROSS_R the line it leaves along is no crossing
-- (two cells of the map and a little, so the end's own cell and its neighbour never count)
local END_FREE_R = 75.0
local END_CROSS_R = 2 * 5.0 + 2.0
local LATE_BLOCKS_LOG = 8 -- blocks read during one planner slice above which the log says so (they make it long)
local ENTITY_ROOM = 40.0 -- around a route piece when looking for what a build added
-- the planner's points joined into longer pieces (planner.simplify): longest piece, and how far the joined piece may
-- run from the points it replaces, sideways and in height (m)
-- (120 m: a few pieces per curve; 0.3 m sideways and 0.15 m in height stay well inside a track's width and a
-- cutting's tolerance)
local SIMPLIFY_LONGEST, SIMPLIFY_SIDE, SIMPLIFY_HEIGHT = 120, 0.3, 0.15
-- over water the planner sees the water level plus this: enough for a deck and a rowing boat under it, so it plans a
-- bridge there rather than an embankment into the water
local OVER_WATER = 6.5

local atan2 = math.atan2 or math.atan

---------------------------------------------------------------------------------------------------------------------
-- pure helpers (no game API): tests call them directly

-- planner points -> the route record Track Connector's game script takes: per point its position, direction, grade
-- and what the piece to the next point is (0 plain, 1 bridge, 2 tunnel); one track, so no level crossings (all 0).
-- pts: the simplified points; stats: the planner job's totals (missing ones count 0).
local PIECE_KIND = { bridge = 1, tunnel = 2 }
local ROUTE_TOTALS = { "straight", "bridge", "tunnel", "steepest", "maxCut", "maxFill" }

function M.routeOf(pts, fromNode, toNode, stats)
	stats = stats or {}
	local r = { fromNode = fromNode, toNode = toNode, levelCount = 0 }
	for _, f in ipairs({ "x", "y", "z", "tx", "ty", "slope", "kind", "level" }) do r[f] = {} end
	for i = 1, #pts do
		local q = pts[i]
		r.x[i], r.y[i], r.z[i] = q.x, q.y, q.z
		r.tx[i], r.ty[i] = q.tx, q.ty
		r.slope[i] = q.slope or 0
		r.kind[i] = PIECE_KIND[q.edgeType] or 0
		r.level[i] = 0
	end
	for _, k in ipairs(ROUTE_TOTALS) do r[k] = tonumber(stats[k]) or 0 end
	-- (the planner's own length, else how far along the last point is)
	r.length = tonumber(stats.length) or tonumber(pts[#pts] and pts[#pts].s) or 0
	return r
end

local MIN_PIECE = 0.5 -- metres: a shorter piece is a planner fault, and the engine takes no zero-length edge
local MIN_DIRECTION = 0.5 -- squared length of a point's direction: the planner gives unit vectors

local function finite(v) return type(v) == "number" and v == v and v > -math.huge and v < math.huge end

-- Why the route must not be sent, or nil. Everything the engine would get is checked here first: numbers that are
-- not finite, pieces without length, points without a direction, and ends that are not where the two picked ends
-- are (the new pieces are joined to those nodes).
function M.routeProblem(r, a, b)
	local n = #r.x
	if n < 2 then return "the route has fewer than 2 points" end
	for i = 1, n do
		for _, f in ipairs({ "x", "y", "z", "tx", "ty", "slope" }) do
			if not finite(r[f][i]) then return string.format("route point %d has a bad number (%s)", i, f) end
		end
		if r.tx[i] * r.tx[i] + r.ty[i] * r.ty[i] < MIN_DIRECTION then
			return string.format("route point %d has no direction", i)
		end
		if i > 1 then
			local d = math.sqrt((r.x[i] - r.x[i - 1]) ^ 2 + (r.y[i] - r.y[i - 1]) ^ 2 + (r.z[i] - r.z[i - 1]) ^ 2)
			if d < MIN_PIECE then return string.format("route piece %d has no length (%.2f m)", i - 1, d) end
		end
	end
	for _, c in ipairs({ { 1, a, "starts", "start" }, { n, b, "ends", "target" } }) do
		local gap = math.sqrt((r.x[c[1]] - c[2].x) ^ 2 + (r.y[c[1]] - c[2].y) ^ 2)
		if gap > 1 then return string.format("the route %s %.1f m from the %s end", c[3], gap, c[4]) end
	end
	return nil
end

-- what the answer says about a route
function M.routeSummary(r)
	local kinds = { normal = 0, bridge = 0, tunnel = 0 }
	for i = 1, #r.x - 1 do
		local k = r.kind[i] == 1 and "bridge" or (r.kind[i] == 2 and "tunnel" or "normal")
		kinds[k] = kinds[k] + 1
	end
	local function round(v, d) local m = 10 ^ (d or 0) return math.floor(v * m + 0.5) / m end
	return { points = #r.x, pieces = #r.x - 1, pieceKinds = kinds, length = round(r.length, 1), straight = round(r.straight, 1),
		bridge = round(r.bridge, 1), tunnel = round(r.tunnel, 1), steepestPercent = round(r.steepest * 100, 2),
		maxCut = round(r.maxCut, 1), maxFill = round(r.maxFill, 1),
		start = { x = round(r.x[1], 1), y = round(r.y[1], 1), z = round(r.z[1], 1) },
		finish = { x = round(r.x[#r.x], 1), y = round(r.y[#r.y], 1), z = round(r.z[#r.z], 1) } }
end

-- A piece of road or track as the engine holds it (BASE_EDGE: two end positions and the tangents there) is a cubic
-- curve; written as a Bezier curve its inner control points lie a third of each tangent inside the ends.
local function controlPoints(p0, t0, p1, t1)
	return { p0, { x = p0.x + t0.x / 3, y = p0.y + t0.y / 3, z = (p0.z or 0) + (t0.z or 0) / 3 },
		{ x = p1.x - t1.x / 3, y = p1.y - t1.y / 3, z = (p1.z or 0) - (t1.z or 0) / 3 }, p1 }
end

-- the curve's point at u (0..1), by repeated linear interpolation between the control points (de Casteljau)
local function curvePoint(cp, u)
	local pts = cp
	while #pts > 1 do
		local nxt = {}
		for k = 1, #pts - 1 do
			local a, b = pts[k], pts[k + 1]
			nxt[k] = { x = a.x + (b.x - a.x) * u, y = a.y + (b.y - a.y) * u, z = (a.z or 0) + ((b.z or 0) - (a.z or 0)) * u }
		end
		pts = nxt
	end
	return pts[1]
end
M.controlPoints, M.curvePoint = controlPoints, curvePoint

---------------------------------------------------------------------------------------------------------------------

-- ctx: core, answer(id, payload, tag), fail(id, msg), appTime(), try(fn), say(msg, level), require
function M.new(ctx)
	local core, answer, fail, appTime, try, say = ctx.core, ctx.answer, ctx.fail, ctx.appTime, ctx.try, ctx.say
	-- (Track Connector's own GUI loads its modules with the plain require; ug_require is for the base's files)
	local reqs = ctx.requires or { require, ug_require }
	local C = { job = nil, frames = 0 }
	local handlers = {}

	local function CT() return api.type.ComponentType end
	local function exists(e) return type(e) == "number" and try(function() return api.engine.entityExists(e) end) == true end
	-- Only ever for an entity that exists: an id from the command line may be anything, and what the engine does
	-- with a component lookup on an id it does not know is not known (other lookups on wrong entities assert).
	local function comp(e, kind)
		local t = CT()[kind]
		if t == nil or not exists(e) then return nil end
		return try(function() return api.engine.getComponent(e, t) end)
	end
	local function enum(kind, name) return try(function() return api.type.enum[kind][name] end) end
	local function player() return try(function() return api.engine.util.getPlayer() end) end
	local function balance() return tonumber(try(function() return api.engine.util.finance.getPlayersBalance(player()) end)) end
	local function gameTime()
		local gt = try(function() return api.engine.getComponent(api.engine.util.getWorld(), CT().GAME_TIME) end)
		return tonumber(gt and core.field(gt, "gameTime"))
	end
	local function nameOf(e)
		if not exists(e) then return nil end
		local n = try(function() return api.engine.util.getEntityName(e) end)
		return type(n) == "string" and n or nil
	end
	local function vec(v)
		local x, y, z = tonumber(core.field(v, "x")), tonumber(core.field(v, "y")), tonumber(core.field(v, "z"))
		if not (x and y) then return nil end
		return { x = x, y = y, z = z or 0 }
	end

	---------------------------------------------------------------------------------------------------------------
	-- Track Connector itself

	-- its two modules, or nil and why. Looked up again for each command (require keeps what loaded; this file keeps
	-- nothing of its own between commands).
	local function loadTc()
		local mods, errs = {}, {}
		for key, path in pairs({ planner = M.TC_PLANNER, proposals = M.TC_PROPOSAL }) do
			for _, rq in ipairs(reqs) do
				if type(rq) == "function" and not mods[key] then
					local ok, m = pcall(rq, path)
					if ok and type(m) == "table" then mods[key] = m else errs[#errs + 1] = tostring(m) end
				end
			end
			if not mods[key] then
				return nil, "Track Connector (" .. M.TC_MOD .. ") is not available: " .. path .. " does not load (" ..
					table.concat(errs, "; ") .. "). Enable the mod for this save (on mod.io: Track Connector)."
			end
		end
		local p, pr = mods.planner, mods.proposals
		for _, f in ipairs({ { p, "defaults" }, { p, "newJob" }, { p, "simplify" }, { p, "bestPair" }, { pr, "templateName" },
			{ pr, "isStreet" } }) do
			if type(f[1][f[2]]) ~= "function" then
				return nil, "Track Connector's modules lack " .. f[2] .. ": not the release this was made for (" ..
					M.TC_WRITTEN_FOR.version .. ", revision " .. M.TC_WRITTEN_FOR.revision .. ")"
			end
		end
		return mods
	end

	local function tcScriptEntity()
		local e = try(function() return api.engine.system.gameScriptSystem.getEntityForGameScript(M.TC_GAME_SCRIPT) end)
		e = tonumber(e)
		if e == nil or e < 0 then return nil end
		return e
	end

	-- its game script's state (a plain copy), or nil
	local function tcState()
		local e = tcScriptEntity()
		local gs = e and comp(e, "GAME_SCRIPT")
		local s = gs and core.field(gs, "state")
		if type(s) ~= "table" then return nil end
		return s
	end

	-- which release: the one this was written for. The installed one's own revision is not read (its mod
	-- description is a profile lookup this script has no other use for in a game); a release whose modules lack
	-- what is used here is refused by loadTc
	local function tcRelease()
		return { mod = M.TC_MOD, writtenFor = M.TC_WRITTEN_FOR }
	end

	local function sendEvent(job, name, param)
		job.sent[#job.sent + 1] = name
		api.cmd.sendCommand(api.cmd.makeScriptingSendEventCmd("", M.TC_EVENT_ID, name, param or {}), function(_, success)
			if success == false then job.refused[#job.refused + 1] = name end
		end)
	end

	---------------------------------------------------------------------------------------------------------------
	-- the network: nodes, pieces, constructions

	local function isNode(n) return exists(n) and comp(n, "BASE_NODE") ~= nil end

	-- the street system's lookup of the pieces at a node, by kind
	local SEGMENTS = { [false] = "getNodeTrackSegments", [true] = "getNodeStreetSegments" }

	-- The track (street false) or road pieces at n; none for anything that is not a node, which is never handed
	-- to the street system: its lookups assume a node, and a C++ assertion would end the game.
	local function segments(n, street)
		if not isNode(n) then return {} end
		local ok, segs = pcall(function() return api.engine.system.streetSystem[SEGMENTS[street == true]](n) end)
		return ok and core.toList(segs) or {}
	end

	-- a piece's curve as control points (controlPoints), from its BASE_EDGE; nil when it cannot be read
	local function pieceCurve(be)
		local p0, p1 = vec(core.field(be, "position0")), vec(core.field(be, "position1"))
		if not (p0 and p1) then
			local n0, n1 = comp(core.field(be, "node0"), "BASE_NODE"), comp(core.field(be, "node1"), "BASE_NODE")
			p0, p1 = n0 and vec(core.field(n0, "position")), n1 and vec(core.field(n1, "position"))
		end
		local t0, t1 = vec(core.field(be, "tangent0")), vec(core.field(be, "tangent1"))
		if not (p0 and p1 and t0 and t1) then return nil end
		return controlPoints(p0, t0, p1, t1)
	end

	-- which kind of end a node is, from the pieces there: "track" or "road" when exactly one piece meets it and it
	-- is of that kind, else nil
	local function endKind(pieces)
		local nT, nR = #pieces.track, #pieces.road
		if nT + nR ~= 1 then return nil end
		return nT == 1 and "track" or "road"
	end

	-- A free end at node n of the kind asked for, and the way out of it: from a point a little way into its piece
	-- (INSIDE_U along the piece's curve) towards the node. Returns { node, x, y, z, dx, dy, piece } or nil and why.
	-- (a short chord: on a 100 m curve along a 50 m piece it is within a hundredth of a degree of the tangent)
	local INSIDE_U, MIN_OUTWARD = 0.002, 0.001
	local function freeEnd(n, road)
		if not isNode(n) then return nil, string.format("%s is no node", tostring(n)) end
		local want = road and "road" or "track"
		local pieces = { track = segments(n, false), road = segments(n, true) }
		if endKind(pieces) ~= want then
			return nil, string.format("node %d is not a free %s end (%d track and %d road pieces there; a free %s end has its one %s piece only)",
				n, want, #pieces.track, #pieces.road, want, want)
		end
		local piece = pieces[want][1]
		local be = comp(piece, "BASE_EDGE")
		local bn = comp(n, "BASE_NODE")
		local here = bn and vec(core.field(bn, "position"))
		local cp = be and pieceCurve(be)
		if not (here and cp) then return nil, string.format("node %d: its piece or position cannot be read", n) end
		local engineKind = enum("RoadType", road and "STREET" or "TRACK")
		if engineKind ~= nil and core.field(be, "roadType") ~= engineKind then
			return nil, string.format("node %d: its piece is no %s", n, want)
		end
		local inside = curvePoint(cp, core.field(be, "node0") == n and INSIDE_U or 1 - INSIDE_U)
		local out = { x = here.x - inside.x, y = here.y - inside.y }
		local dist = math.sqrt(out.x ^ 2 + out.y ^ 2)
		if not (dist >= MIN_OUTWARD) then return nil, string.format("node %d: its piece has no direction", n) end
		return { node = n, x = here.x, y = here.y, z = here.z, dx = out.x / dist, dy = out.y / dist, piece = piece }
	end

	-- the construction of a station: the engine's lookup, else a construction around it that lists it
	local function constructionOfStation(st)
		-- (only a station that exists is asked about)
		if not comp(st, "STATION") then return nil end
		local con = tonumber(try(function() return api.engine.system.streetConnectorSystem.getConstructionEntityForStation(st) end))
		if con and con >= 0 and comp(con, "CONSTRUCTION") then return con end
		local bv = comp(st, "BOUNDING_VOLUME")
		local bb = bv and core.field(bv, "bbox")
		local lo, hi = bb and vec(core.field(bb, "min")), bb and vec(core.field(bb, "max"))
		if not (lo and hi) then return nil end
		local found
		pcall(function()
			local box = api.type.Box3.new(api.type.Vec3f.new(lo.x - 50, lo.y - 50, Z_LOW), api.type.Vec3f.new(hi.x + 50, hi.y + 50, Z_HIGH))
			api.engine.system.octreeSystem.findIntersectingEntities(box, function(e)
				if found then return end
				local c = comp(e, "CONSTRUCTION")
				for _, s in ipairs(core.toList(c and core.field(c, "stations"))) do
					if s == st then found = e end
				end
			end)
		end)
		return found
	end

	-- the free ends of a construction's own pieces (a station's platform tracks)
	local function constructionEnds(con, road)
		local c = comp(con, "CONSTRUCTION")
		local ends, seen = {}, {}
		for _, e in ipairs(core.toList(c and core.field(c, "frozenEdges"))) do
			local be = comp(e, "BASE_EDGE")
			for _, n in ipairs(be and { core.field(be, "node0"), core.field(be, "node1") } or {}) do
				n = tonumber(n)
				if n and not seen[n] then
					seen[n] = true
					local fe = freeEnd(n, road)
					if fe then
						fe.construction = con
						ends[#ends + 1] = fe
					end
				end
			end
		end
		table.sort(ends, function(a, b) return a.node < b.node end)
		return ends
	end

	local function stationGroups()
		local out = {}
		for _, e in ipairs(core.toList(try(function() return api.engine.getEntitiesWithComponent(CT().STATION_GROUP) end))) do
			out[#out + 1] = { id = e, name = nameOf(e) or "" }
		end
		return out
	end

	-- an end as given (core.connectArgs: an id or a name) -> { name, entity, kind, ends = { free ends } }, or nil and why
	local function resolveEnd(tok, road, what)
		local id, name = tok, nil
		if type(tok) == "string" then
			local hit, err = core.matchEntity(stationGroups(), tok)
			if not hit then return nil, what .. ": " .. err .. " among the station groups (or give an entity id)" end
			id, name = hit.id, hit.name
		end
		local function out(kind, ends)
			if #ends == 0 then
				return nil, string.format("%s: %s %d (%s) has no free %s end", what, kind, id, name or nameOf(id) or "?",
					road and "road" or "platform track")
			end
			return { name = name or nameOf(id) or (kind .. " " .. id), entity = id, kind = kind, ends = ends }
		end
		if isNode(id) then
			local fe, err = freeEnd(id, road)
			if not fe then return nil, what .. ": " .. err end
			return { name = "node " .. id, entity = id, kind = "node", ends = { fe } }
		end
		local stations
		local sg = comp(id, "STATION_GROUP")
		if sg then
			stations = core.toList(core.field(sg, "stations"))
		elseif comp(id, "STATION") then
			stations = { id }
		elseif comp(id, "CONSTRUCTION") then
			return out("construction", constructionEnds(id, road))
		else
			return nil, string.format("%s: %s is no node, station, station group or station construction", what, tostring(id))
		end
		local ends, seen = {}, {}
		for _, st in ipairs(stations) do
			local con = constructionOfStation(st)
			if con and not seen[con] then
				seen[con] = true
				for _, fe in ipairs(constructionEnds(con, road)) do ends[#ends + 1] = fe end
			end
		end
		return out(sg and "station group" or "station", ends)
	end

	---------------------------------------------------------------------------------------------------------------
	-- the map the planner sees (its World: height, ground, water, blocked, crossing, bounds)
	--
	-- The land is read in square blocks (BLOCK metres) through the octree: each block keeps two sets of GRID-metre
	-- cells, those under a building or construction and those a road or track runs over. The blocks along the
	-- straight line between the ends are read first, a few per frame, before the planner starts (map:readSome);
	-- a block the planner asks about later is read then. Terrain heights and water are asked of the engine per
	-- point and kept.

	-- what the planner may run through at an end: its own piece, and the construction that piece belongs to (or
	-- the station construction the end was found in), with that construction's pieces
	local function endExclusions(e, cons, edges)
		edges[e.piece] = true
		local list = { e.construction }
		if comp(e.piece, "BASE_EDGE") then
			list[#list + 1] = try(function() return api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(e.piece) end)
		end
		for _, con in ipairs(list) do
			con = tonumber(con)
			local c = con and con >= 0 and not cons[con] and comp(con, "CONSTRUCTION")
			if c then
				cons[con] = true
				for _, fe in ipairs(core.toList(core.field(c, "frozenEdges"))) do edges[fe] = true end
			end
		end
	end

	-- a and b: the two ends. Returns the map: map.world for the planner, map.readSome(n) reads up to n of the blocks
	-- along the way (true once all are read), map.stats its counters.
	function C.newMap(a, b)
		local stats = { blocks = 0, entities = 0, buildings = 0, pieces = 0, heights = 0, waterChecks = 0, lateBlocks = 0, yields = 0 }
		local cons, edges = {}, {}
		endExclusions(a, cons, edges)
		endExclusions(b, cons, edges)
		local map = { stats = stats, sliceReads = 0 }

		-- nested tables by x then y: a lookup without building a key
		local function getIn(t, i, j) local r = t[i] return r and r[j] end
		local function putIn(t, i, j, v)
			local r = t[i]
			if not r then r = {}; t[i] = r end
			r[j] = v
		end

		local edge = try(function() return api.engine.terrain.getBoundingBox() end)
		local lo, hi = edge and vec(core.field(edge, "min")), edge and vec(core.field(edge, "max"))
		local bounds
		if lo and hi and hi.x > lo.x and hi.y > lo.y then
			bounds = { lo.x + MAP_INSET, lo.y + MAP_INSET, hi.x - MAP_INSET, hi.y - MAP_INSET }
			-- an end close to the map's edge must stay inside, with room to leave it
			for _, e in ipairs({ a, b }) do
				bounds[1], bounds[2] = math.min(bounds[1], e.x - END_ROOM), math.min(bounds[2], e.y - END_ROOM)
				bounds[3], bounds[4] = math.max(bounds[3], e.x + END_ROOM), math.max(bounds[4], e.y + END_ROOM)
			end
		end
		local function outside(x, y)
			return bounds ~= nil and (x < bounds[1] or x > bounds[3] or y < bounds[2] or y > bounds[4])
		end
		local function closeToEnd(x, y, r)
			local r2 = r * r
			return (x - a.x) ^ 2 + (y - a.y) ^ 2 < r2 or (x - b.x) ^ 2 + (y - b.y) ^ 2 < r2
		end

		local heights, wet = {}, {}
		local function ground(x, y)
			local i, j = math.floor(x / HEIGHT_STEP + 0.5), math.floor(y / HEIGHT_STEP + 0.5)
			local h = getIn(heights, i, j)
			if h == nil then
				h = tonumber(try(function() return api.engine.terrain.getHeightAt(api.type.Vec2f.new(i * HEIGHT_STEP, j * HEIGHT_STEP)) end)) or 0
				putIn(heights, i, j, h)
				stats.heights = stats.heights + 1
			end
			return h
		end
		local function water(x, y)
			local i, j = math.floor(x / WATER_STEP + 0.5), math.floor(y / WATER_STEP + 0.5)
			local w = getIn(wet, i, j)
			if w == nil then
				w = try(function() return api.engine.terrain.isOnWater(api.type.Vec2f.new(i * WATER_STEP, j * WATER_STEP)) end) == true
				putIn(wet, i, j, w)
				stats.waterChecks = stats.waterChecks + 1
			end
			return w
		end
		local waterLevel = tonumber(try(function()
			return api.engine.getComponent(api.engine.util.getWorld(), CT().TERRAIN).waterLevel
		end))

		-- blocks: blocks[bx][by] = { built = { [cell] = true }, roads = { [cell] = true } }, cell = cx * 1000 + cy
		-- within the block
		local blocks = {}
		local CELLS = math.ceil(BLOCK / GRID)
		local function mark(set, bx, by, x0, y0, x1, y1)
			-- the cells of block (bx, by) under the box; a box reaching into the next block is marked there when
			-- that block is read (the octree gives it to every block it touches)
			local ox, oy = bx * BLOCK, by * BLOCK
			local c0, c1 = math.max(0, math.floor((x0 - ox) / GRID)), math.min(CELLS - 1, math.floor((x1 - ox) / GRID))
			local r0, r1 = math.max(0, math.floor((y0 - oy) / GRID)), math.min(CELLS - 1, math.floor((y1 - oy) / GRID))
			for cx = c0, c1 do
				for cy = r0, r1 do set[cx * 1000 + cy] = true end
			end
		end
		-- points along a piece and how far to each side of them it is in the way: LANE_ROOM per lane config (a lane
		-- or a pavement), at least a track's or a road's own MIN_HALF, plus room for the new line beside it
		local function piecePoints(be)
			local cp = pieceCurve(be)
			if not cp then return nil end
			local isTrack = core.field(be, "roadType") == enum("RoadType", "TRACK")
			local half = math.max(isTrack and TRACK_HALF or ROAD_HALF, LANE_ROOM * core.size(core.field(be, "laneConfigs")))
			local chord = math.sqrt((cp[4].x - cp[1].x) ^ 2 + (cp[4].y - cp[1].y) ^ 2)
			local pts = {}
			local n = math.max(2, math.ceil(chord / PIECE_STEP))
			for k = 0, n do pts[#pts + 1] = curvePoint(cp, k / n) end
			return pts, half + SIDE_ROOM
		end
		local function readBlock(bx, by)
			local blk = { built = {}, roads = {} }
			putIn(blocks, bx, by, blk)
			stats.blocks = stats.blocks + 1
			local ox, oy = bx * BLOCK, by * BLOCK
			local hits = {}
			pcall(function()
				local box = api.type.Box3.new(api.type.Vec3f.new(ox - BLOCK_PAD, oy - BLOCK_PAD, Z_LOW),
					api.type.Vec3f.new(ox + BLOCK + BLOCK_PAD, oy + BLOCK + BLOCK_PAD, Z_HIGH))
				api.engine.system.octreeSystem.findIntersectingEntities(box, function(e, bv)
					local bb = bv and core.field(bv, "bbox")
					hits[#hits + 1] = { e, bb and vec(core.field(bb, "min")), bb and vec(core.field(bb, "max")) }
				end)
			end)
			for _, h in ipairs(hits) do
				local e, bmin, bmax = h[1], h[2], h[3]
				stats.entities = stats.entities + 1
				if comp(e, "CONSTRUCTION") or comp(e, "TOWN_BUILDING") then
					if not cons[e] and bmin and bmax and bmax.x - bmin.x <= BIGGEST_BUILDING and bmax.y - bmin.y <= BIGGEST_BUILDING then
						mark(blk.built, bx, by, bmin.x - BUILDING_ROOM, bmin.y - BUILDING_ROOM, bmax.x + BUILDING_ROOM, bmax.y + BUILDING_ROOM)
						stats.buildings = stats.buildings + 1
					end
				elseif not edges[e] then
					local be = comp(e, "BASE_EDGE")
					local pts, r = nil, nil
					if be then pts, r = piecePoints(be) end
					if pts then
						for _, q in ipairs(pts) do mark(blk.roads, bx, by, q.x - r, q.y - r, q.x + r, q.y + r) end
						stats.pieces = stats.pieces + 1
					end
				end
			end
			return blk
		end
		local function cellAt(x, y)
			local bx, by = math.floor(x / BLOCK), math.floor(y / BLOCK)
			local blk = getIn(blocks, bx, by)
			if not blk then
				-- outside the band: read now, inside the planner's slice (counted, see stepPlan)
				blk = readBlock(bx, by)
				map.sliceReads = map.sliceReads + 1
				stats.lateBlocks = stats.lateBlocks + 1
				-- The planner calls the world from inside its own coroutine (job:step resumes it), so after a few such
				-- reads the slice can wait for the next frame right here; the planner goes on from this call when
				-- resumed. Outside a coroutine (a planner without one) it just goes on.
				if map.sliceReads % M.TUNE.lateBlocksPerSlice == 0 then
					local co, isMain = coroutine.running()
					if co and not isMain then
						stats.yields = stats.yields + 1
						coroutine.yield()
					end
				end
			end
			return blk, math.floor((x - bx * BLOCK) / GRID) * 1000 + math.floor((y - by * BLOCK) / GRID)
		end

		-- the blocks within a band around the straight line between the ends, nearest the start first
		local queue, seenQ = {}, {}
		do
			local len = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
			local band = math.max(BAND_MIN, BAND_SHARE * len)
			local n = math.max(1, math.ceil(len / (BLOCK / 2)))
			for k = 0, n do
				local x, y = a.x + (b.x - a.x) * k / n, a.y + (b.y - a.y) * k / n
				for bx = math.floor((x - band) / BLOCK), math.floor((x + band) / BLOCK) do
					for by = math.floor((y - band) / BLOCK), math.floor((y + band) / BLOCK) do
						if not getIn(seenQ, bx, by) and #queue < MAX_PRELOAD then
							putIn(seenQ, bx, by, true)
							queue[#queue + 1] = { bx, by }
						end
					end
				end
			end
		end
		stats.preload = #queue
		local nextQ = 1
		function map.readSome(n)
			for _ = 1, n do
				local q = queue[nextQ]
				if not q then return true end
				nextQ = nextQ + 1
				if not getIn(blocks, q[1], q[2]) then readBlock(q[1], q[2]) end
			end
			return queue[nextQ] == nil
		end
		function map.progress() return #queue == 0 and 1 or (nextQ - 1) / #queue end

		map.world = {
			-- over water the planner sees the water level plus room for a bridge deck, so it bridges, not dives
			height = function(x, y)
				local h = ground(x, y)
				if waterLevel and water(x, y) and h < waterLevel + OVER_WATER then return waterLevel + OVER_WATER end
				return h
			end,
			ground = ground,
			water = water,
			bounds = bounds,
			blocked = function(x, y)
				if outside(x, y) then return true end
				local blk, cell = cellAt(x, y)
				return blk.built[cell] == true and not closeToEnd(x, y, END_FREE_R)
			end,
			crossing = function(x, y)
				local blk, cell = cellAt(x, y)
				return blk.roads[cell] == true and not closeToEnd(x, y, END_CROSS_R)
			end,
		}
		stats.waterLevel = waterLevel
		stats.leftOutConstructions, stats.leftOutPieces = 0, 0
		for _ in pairs(cons) do stats.leftOutConstructions = stats.leftOutConstructions + 1 end
		for _ in pairs(edges) do stats.leftOutPieces = stats.leftOutPieces + 1 end
		return map
	end

	---------------------------------------------------------------------------------------------------------------
	-- the pieces and nodes along a route (what a build adds is the difference before and after)

	-- every piece and node near the route: one octree box per route piece, its chord with room for its bow and the
	-- new pieces' width (ENTITY_ROOM)
	local function routeEntities(r)
		local out = { edges = {}, nodes = {} }
		for i = 2, #r.x do
			local x0, x1 = math.min(r.x[i - 1], r.x[i]) - ENTITY_ROOM, math.max(r.x[i - 1], r.x[i]) + ENTITY_ROOM
			local y0, y1 = math.min(r.y[i - 1], r.y[i]) - ENTITY_ROOM, math.max(r.y[i - 1], r.y[i]) + ENTITY_ROOM
			pcall(function()
				local box = api.type.Box3.new(api.type.Vec3f.new(x0, y0, Z_LOW), api.type.Vec3f.new(x1, y1, Z_HIGH))
				api.engine.system.octreeSystem.findIntersectingEntities(box, function(e)
					if comp(e, "BASE_EDGE") then out.edges[e] = true elseif comp(e, "BASE_NODE") then out.nodes[e] = true end
				end)
			end)
		end
		return out
	end

	local function newIn(before, after)
		local out = {}
		for e in pairs(after) do if not before[e] then out[#out + 1] = e end end
		table.sort(out)
		return core.array(out)
	end

	---------------------------------------------------------------------------------------------------------------
	-- the job: plan, then the events, then (with build) the build

	local function payload(job)
		local out = { ok = false, cmd = "connect", mode = job.road and "road" or "track", template = job.template,
			tc = job.tc, from = job.fromInfo, to = job.toInfo, settings = job.tcSettings, dryRun = not job.args.build,
			seconds = math.floor((appTime() - job.started) * 10 + 0.5) / 10, notes = job.notes }
		if job.planned then out.plan = job.planned end
		if job.route then out.route = M.routeSummary(job.route) end
		if job.preview then out.preview = job.preview end
		if job.estimate then out.estimate = job.estimate end
		if job.buildOut then out.build = job.buildOut end
		if #job.notes == 0 then out.notes = nil end
		return out
	end

	local function finish(job, out, err)
		C.job = nil
		if err then out.ok, out.error = false, err end
		answer(job.id, out, out.ok and nil or "error")
		say(string.format("connect %d: %s", job.id, out.ok and "done" or ("failed: " .. tostring(out.error))), 2)
	end

	local function plainEstimate(e)
		if type(e) ~= "table" then return nil end
		return { ok = e.ok == true, cost = tonumber(e.cost), errors = type(e.errors) == "string" and e.errors ~= "" and e.errors or nil,
			problem = type(e.problem) == "string" and e.problem or nil, blockers = type(e.blockers) == "string" and e.blockers ~= "" and e.blockers or nil,
			clear = e.clear == true or nil, clearCost = tonumber(e.clearCost), clearCount = tonumber(e.clearCount),
			searching = e.searching == true or nil }
	end

	local function plainResult(p)
		if type(p) ~= "table" then return nil end
		local function text(v) return type(v) == "string" and v ~= "" and v or nil end
		return { ok = p.ok == true, short = text(p.short), summary = text(p.summary) }
	end

	-- Track Connector's state still holds this command's ends and route? (a player may use its tool meanwhile)
	local function stateIsOurs(job, s)
		local f, t, r = s.from, s.to, s.route
		if type(f) ~= "table" or type(t) ~= "table" or f.node ~= job.a.node or t.node ~= job.b.node then return false end
		if r ~= nil and (type(r) ~= "table" or r.fromNode ~= job.a.node or r.toNode ~= job.b.node or core.size(r.x) ~= #job.route.x) then
			return false
		end
		return true
	end

	-- A pose for the planner at an end: leaving it, the way the end points out; arriving, the opposite way (the new
	-- line runs into the end).
	local function poseAt(e, arriving)
		local sign = arriving and -1 or 1
		return { x = e.x, y = e.y, z = e.z, heading = atan2(sign * e.dy, sign * e.dx) }
	end

	-- The planner's settings: the command's slope, curves, bridges and tunnels; one track, no level crossings, and
	-- other lines avoided where it can.
	local function plannerSettings(job)
		local S = job.mods.planner.defaults()
		local own = { maxSlope = job.slope, minRadius = job.radius, allowBridges = job.args.bridges,
			allowTunnels = job.args.tunnels, avoidNetworks = true, levelCrossings = false, levelTracks = false,
			twinGap = 0, tracks = 1 }
		for k, v in pairs(own) do S[k] = v end
		return S
	end

	-- Phase "mapping": the land along the way first, a few blocks a frame; then the planner job ("planning").
	local function startPlan(job)
		job.S = plannerSettings(job)
		job.map = C.newMap(job.a, job.b)
		job.world, job.worldStats = job.map.world, job.map.stats
		job.phase = "mapping"
	end

	local function stepMap(job)
		if not job.map.readSome(M.TUNE.blocksPerFrame) then return end
		job.mapSeconds = math.floor((appTime() - job.started) * 10 + 0.5) / 10
		job.plannerJob = job.mods.planner.newJob(poseAt(job.a, false), poseAt(job.b, true), job.S, job.world)
		job.phase, job.planStarted = "planning", appTime()
	end

	local function sendRoute(job)
		local s = job.tcSettings
		sendEvent(job, "tc_settings", s)
		sendEvent(job, "tc_setFromEnd", { node = job.a.node, name = job.fromInfo.name })
		sendEvent(job, "tc_setToEnd", { node = job.b.node, name = job.toInfo.name })
		sendEvent(job, "tc_route", { ok = true, message = "route found", route = job.route })
		sendEvent(job, "tc_estimate", { key = job.key, route = job.route })
		job.phase, job.waitSince = "checking", appTime()
	end

	local function stepPlan(job)
		local pj = job.plannerJob
		local t0 = appTime()
		job.map.sliceReads = 0
		local ok, err = pcall(function() pj:step(STEP_BUDGET) end)
		local late = job.map.sliceReads
		job.planFrames = (job.planFrames or 0) + 1
		local dt = appTime() - t0
		if dt > (job.maxStep or 0) then job.maxStep = dt end
		-- (only a planner that runs without a coroutine reads more than lateBlocksPerSlice in one slice: that makes a
		-- long frame; said once per command, with how long it took)
		if late > LATE_BLOCKS_LOG and not job.saidLate then
			job.saidLate = true
			say(string.format("connect %d: the planner went off the prepared map and read %d blocks in one slice (%.0f ms)",
				job.id, late, dt * 1000))
		end
		if not ok then return finish(job, payload(job), "the planner failed: " .. tostring(err)) end
		if not pj.done then return end
		local js = type(pj.stats) == "table" and pj.stats or {}
		job.planned = { seconds = math.floor((appTime() - job.planStarted) * 10 + 0.5) / 10, frames = job.planFrames,
			longestFrameMs = math.floor((job.maxStep or 0) * 1000 + 0.5), searchSteps = tonumber(js.expanded), mapSeconds = job.mapSeconds,
			map = job.worldStats, message = type(pj.message) == "string" and pj.message or nil,
			slopePercent = job.slope * 100, radius = job.radius }
		if not pj.ok or type(pj.route) ~= "table" or #pj.route < 2 then
			return finish(job, payload(job), "no route: " .. tostring(pj.message or "the planner found none"))
		end
		local okS, pts = pcall(job.mods.planner.simplify, pj.route, SIMPLIFY_LONGEST, SIMPLIFY_SIDE, SIMPLIFY_HEIGHT, job.S.minRadius,
			job.S.maxSlope)
		if not okS or type(pts) ~= "table" then pts = pj.route end
		local r = M.routeOf(pts, job.a.node, job.b.node, js)
		local bad = M.routeProblem(r, job.a, job.b)
		if bad then return finish(job, payload(job), "the planned route cannot go to the game: " .. bad) end
		job.route = r
		-- (planning takes a while, and a player may have built on an end meanwhile: the ends go to the game script by
		-- node id, so each must still be a free end when the route is sent)
		for _, e in ipairs({ job.a, job.b }) do
			if not freeEnd(e.node, job.road) then
				return finish(job, payload(job), string.format("node %d is no longer a free end (it changed while the route was planned)", e.node))
			end
		end
		sendRoute(job)
	end

	local function stepCheck(job)
		if #job.refused > 0 then
			return finish(job, payload(job), "the game refused the event command(s) " .. table.concat(job.refused, ", "))
		end
		local s = tcState()
		local est = s and type(s.estimates) == "table" and s.estimates[job.key] or nil
		if type(est) ~= "table" then
			if appTime() - job.waitSince > TC_WAIT_SEC then
				local other = s and type(s.from) == "table" and (s.from.node ~= job.a.node or type(s.to) ~= "table" or s.to.node ~= job.b.node)
				return finish(job, payload(job), string.format("Track Connector's game script did not answer in %d s %s", TC_WAIT_SEC,
					other and "and its state shows other ends: someone may have used its tool meanwhile (it keeps one state for everyone)"
						or "(is the game paused in a menu, or the mod's game script not running?)"))
			end
			return
		end
		if not stateIsOurs(job, s) then
			return finish(job, payload(job), "Track Connector's state shows other ends or another route: someone used its " ..
				"tool meanwhile (it keeps one state for everyone); try again")
		end
		job.estimate = plainEstimate(est)
		job.preview = plainResult(s.preview)
		local buildable = job.preview ~= nil and job.preview.ok and job.estimate.ok
		local why
		if not buildable then
			why = job.estimate.problem or job.estimate.errors or (job.preview and job.preview.summary)
				or (job.preview == nil and "Track Connector holds no verdict on this route (its own check of the route did not run through)")
				or "the game would refuse it"
			if job.estimate.clear then
				why = why .. string.format(" (buildable for %s if %s town building(s) go: add clear)", tostring(job.estimate.clearCost),
					tostring(job.estimate.clearCount))
			end
		end
		if not job.args.build then
			local out = payload(job)
			out.ok, out.buildable = buildable, buildable
			return finish(job, out, (not buildable) and ("the game would refuse this route: " .. why) or nil)
		end
		local clearing = job.args.clear and job.estimate.clear
		if not buildable and not clearing then
			local out = payload(job)
			out.buildable = false
			return finish(job, out, "not built: the game would refuse this route: " .. why)
		end
		if s.route == nil then return finish(job, payload(job), "not built: Track Connector holds no checked route") end
		job.before = routeEntities(job.route)
		job.balanceBefore, job.gameTimeBefore = balance(), gameTime()
		job.buildsBefore = tonumber(s.builds) or 0
		sendEvent(job, "tc_build", { clear = job.args.clear == true })
		job.phase, job.waitSince = "building", appTime()
	end

	local function stepBuild(job)
		if #job.refused > 0 then
			return finish(job, payload(job), "the game refused the event command(s) " .. table.concat(job.refused, ", "))
		end
		if not job.settleAt then
			local s = tcState()
			local n = s and tonumber(s.builds) or 0
			if n <= job.buildsBefore then
				if appTime() - job.waitSince > TC_WAIT_SEC then
					return finish(job, payload(job), s == nil and string.format("Track Connector's game script state could not " ..
						"be read for %d s after the build was sent (whether it was built is unknown: look at newEdges in the game)", TC_WAIT_SEC)
						or string.format("Track Connector's game script did not take the build in %d s", TC_WAIT_SEC))
				end
				return
			end
			-- (the outcome is only this command's when the state still holds its ends: the tool may have been used)
			if type(s.from) ~= "table" or type(s.to) ~= "table" or s.from.node ~= job.a.node or s.to.node ~= job.b.node then
				job.stolenAtBuild = true
			end
			local res = plainResult(s.build) or { ok = false, short = "no outcome in the state" }
			-- (its outcome is filled in by the build command's callback; "nothing happened" is the text it starts with)
			if not res.ok and res.short == "nothing happened" and appTime() - job.waitSince < BUILD_RESULT_SEC then return end
			job.tcBuild = res
			job.settleAt = C.frames + SETTLE_FRAMES
			return
		end
		if C.frames < job.settleAt then return end
		local after = routeEntities(job.route)
		local bal, gt = balance(), gameTime()
		local b = { tc = job.tcBuild, balanceBefore = job.balanceBefore, balanceAfter = bal, spent = core.spent(job.balanceBefore, bal),
			estimatedCost = job.estimate and job.estimate.cost, newEdges = newIn(job.before.edges, after.edges),
			newNodes = newIn(job.before.nodes, after.nodes), gameTimeBefore = job.gameTimeBefore, gameTimeAfter = gt }
		if b.spent and b.estimatedCost then b.beyondEstimate = b.spent - b.estimatedCost end
		if gt and job.gameTimeBefore and gt ~= job.gameTimeBefore then
			b.warning = "game time moved during the build: spent may include fares and running costs; pause the game for exact costs"
		end
		-- joined: the two ends now carry two pieces each (theirs and the new one)
		b.joined = { from = #segments(job.a.node, job.road) >= 2, to = #segments(job.b.node, job.road) >= 2 }
		job.buildOut = b
		local out = payload(job)
		out.ok, out.buildable = job.tcBuild.ok == true, true
		-- (Track Connector writes the outcome in the build command's callback, after its state may already be
		-- saved: a build whose pieces are there and joined to both ends is built, whatever the state still says)
		if not out.ok and job.tcBuild.short == "nothing happened" and #b.newEdges > 0 and b.joined.from and b.joined.to then
			out.ok = true
			job.notes[#job.notes + 1] = "Track Connector's state still says \"nothing happened\", but new pieces join both ends"
			out.notes = job.notes
		end
		local err
		if job.stolenAtBuild then
			out.ok = false
			err = "Track Connector's state shows other ends after the build: someone used its tool meanwhile, so its " ..
				"outcome may not be this command's (look at newEdges and joined)"
		elseif not out.ok then
			err = "Track Connector did not build it: " .. tostring(job.tcBuild.summary or job.tcBuild.short)
			if #b.newEdges > 0 then
				job.notes[#job.notes + 1] = "yet new pieces showed up along the route: look at newEdges"
				out.notes = job.notes
			end
		end
		finish(job, out, err)
	end

	local function progressOf(job)
		if job.phase == "mapping" then return job.map.progress() end
		if job.plannerJob and not job.plannerJob.done then return tonumber(job.plannerJob.progress) end
		return nil
	end

	-- one frame of the job: its time limit, its phase, its progress answer
	local function stepJob(job)
		if appTime() - job.started > job.args.timeout then
			-- (a build already taken, only waiting for the balance to settle, is answered as built)
			if job.phase == "building" and job.settleAt then
				job.settleAt = 0
				return stepBuild(job)
			end
			local out = payload(job)
			out.phase, out.progress = job.phase, progressOf(job)
			return finish(job, out, string.format("timed out after %g s while %s%s", job.args.timeout, job.phase,
				job.phase == "building" and " (the build may still happen: look at the game)" or ""))
		end
		if job.phase == "mapping" then stepMap(job)
		elseif job.phase == "planning" then stepPlan(job)
		elseif job.phase == "checking" then stepCheck(job)
		elseif job.phase == "building" then stepBuild(job) end
		if C.job == job and appTime() >= job.nextProgress then
			job.nextProgress = appTime() + PROGRESS_SEC
			job.progressN = job.progressN + 1
			local out = payload(job)
			out.ok, out.running, out.phase, out.progress = true, true, job.phase, progressOf(job)
			answer(job.id, out, "p" .. job.progressN)
		end
	end

	-- Everything a job does in a frame runs under one pcall: an error there ends that job with one error answer,
	-- and never the probe's own frame (its runs and label come after this in guiUpdate).
	function C.step()
		C.frames = C.frames + 1
		local job = C.job
		if not job then return end
		local ok, err = pcall(stepJob, job)
		if ok or C.job ~= job then return end
		C.job = nil
		local okP, out = pcall(payload, job)
		if not okP then out = { cmd = "connect" } end
		out.ok, out.error = false, tostring(err)
		answer(job.id, out, "error")
	end

	-- a load ends this script with its job; nothing to answer then (the tool sees the game go)
	function C.reset() C.job = nil end

	-- the template to build, or nil and why; for a road also the piece whose lanes are copied, and a note.
	-- Tracks: Track Connector's own lookup of the short names, which quietly falls back to the standard track when
	-- the name it makes is missing, so the result is checked against the name asked for.
	local function templateFor(a, mods, fromEnd)
		local quiet = function() end
		if not a.road then
			if a.track:find("::/", 1, true) then
				if a.electric then
					return nil, "electric goes with the short track names; for a full resource name give the electrified type itself"
				end
				if tonumber(try(function() return api.res.streetTemplateRep.find(a.track) end) or -1) < 0 then
					return nil, "no track template " .. a.track
				end
				if mods.proposals.isStreet(a.track) then return nil, "track names a road type: for roads give road and template" end
				return a.track
			end
			local tpl = mods.proposals.templateName(a.track, a.electric, quiet)
			local want = string.format("/%s%s.street_template", a.track, a.electric and "_catenary" or "")
			if type(tpl) ~= "string" or tpl:sub(-#want) ~= want then
				return nil, string.format("the game has no %s%s track type (Track Connector would have used %s)", a.track,
					a.electric and " electric" or "", tostring(tpl))
			end
			return tpl
		end
		if a.template then
			if not mods.proposals.isStreet(a.template) then return nil, "template " .. a.template .. " is no road type the game has" end
			return a.template
		end
		-- as Track Connector's road tool by default: the same as the start road, its lanes too (tram tracks on it)
		local be = comp(fromEnd.piece, "BASE_EDGE")
		local own = be and core.field(be, "roadTemplate")
		own = type(own) == "string" and own or (own ~= nil and tostring(own) or nil)
		if own and own ~= "" and mods.proposals.isStreet(own) then return own, fromEnd.piece end
		if mods.proposals.isStreet(M.DEFAULT_STREET) then
			return M.DEFAULT_STREET, nil, "the start road's type could not be read (" .. tostring(own) .. "): built as " ..
				M.DEFAULT_STREET .. ", without copying its lanes"
		end
		return nil, "the start road's type cannot be read and the default road type is missing: give template"
	end

	local function endInfo(r, e)
		local alts = {}
		for _, x in ipairs(r.ends) do alts[#alts + 1] = x.node end
		return { name = r.name, entity = r.entity, kind = r.kind, node = e.node, piece = e.piece,
			position = { x = math.floor(e.x * 10 + 0.5) / 10, y = math.floor(e.y * 10 + 0.5) / 10, z = math.floor(e.z * 10 + 0.5) / 10 },
			freeEnds = #alts > 1 and core.array(alts) or nil }
	end

	-- the steepest grade a street template may be built at (its maxSlopeBuild), or nil
	local function roadGradeLimit(tpl)
		local rep = try(function() return api.res.streetTemplateRep end)
		local id = rep and tonumber(try(function() return rep.find(tpl) end))
		if not id or id < 0 then return nil end
		local v = tonumber(try(function() return rep.get(id).maxSlopeBuild end))
		if v and v > 0 then return v end
		return nil
	end

	-- args: from, to, road, template, track, electric, slope (%), radius, bridges, tunnels, build, clear, timeout
	function handlers.connect(c)
		local a, err = core.connectArgs(c.args)
		if not a then return fail(c.id, err) end
		if C.job then
			return fail(c.id, string.format("connect %d is still running (Track Connector keeps one state, so one at a time)", C.job.id))
		end
		local mods, errT = loadTc()
		if not mods then return fail(c.id, errT) end
		local tcEntity = tcScriptEntity()
		if not tcEntity then
			return fail(c.id, "Track Connector's game script is not running in this game: its modules load, but the save " ..
				"was not loaded with the mod enabled (enable it and load the save again)")
		end
		local from, errF = resolveEnd(a.from, a.road, "from")
		if not from then return fail(c.id, errF) end
		local to, errTo = resolveEnd(a.to, a.road, "to")
		if not to then return fail(c.id, errTo) end
		-- (one place given twice in other words: a name and an id, or a station and its group)
		local same = from.entity == to.entity
		if not same and #from.ends == #to.ends then
			local mine = {}
			for _, e in ipairs(from.ends) do mine[e.node] = true end
			same = true
			for _, e in ipairs(to.ends) do same = same and mine[e.node] == true end
		end
		if same then
			return fail(c.id, string.format("from and to are the same place (%s and %s)", from.name, to.name))
		end
		local ea, eb = mods.planner.bestPair(from.ends, to.ends)
		if not ea or not eb then return fail(c.id, "the two ends are too close together (or the same)") end
		if ea.node == eb.node then return fail(c.id, "from and to are the same end") end
		local tpl, laneFrom, tplNote = templateFor(a, mods, ea)
		if not tpl then return fail(c.id, laneFrom) end
		local d = a.road and M.ROAD_DEFAULTS or M.TRACK_DEFAULTS
		local slope, radius = a.slope or d.slope, a.radius or d.radius
		local notes = { tplNote }
		if a.road then
			-- A road type states the steepest grade it may be built at; a route planned steeper would be refused, so
			-- the planner gets that limit. A type stating none (or nothing readable) leaves the slope as asked.
			local limit = roadGradeLimit(tpl)
			if limit and limit < slope then
				notes[#notes + 1] = string.format("slope %.1f%% is more than %s allows; planned at its %.1f%%", slope * 100, tpl, limit * 100)
				slope = limit
			end
		end
		local release = tcRelease()
		release.gameScript = tcEntity
		local job = { id = c.id, args = a, road = a.road, mods = mods, a = ea, b = eb, template = tpl, slope = slope, radius = radius,
			started = appTime(), nextProgress = appTime() + PROGRESS_SEC, progressN = 0, sent = {}, refused = {}, notes = notes,
			key = "remote_probe_" .. string.format("%d", c.id), tc = release,
			fromInfo = endInfo(from, ea), toInfo = endInfo(to, eb) }
		-- what its game script uses for the dry run and the build (its Settings record)
		job.tcSettings = { maxSlope = slope, minRadius = radius, allowBridges = a.bridges, allowTunnels = a.tunnels,
			avoidBuildings = true, avoidNetworks = true, track = tpl, electric = a.electric, laneFrom = laneFrom }
		local ok, errP = pcall(startPlan, job)
		if not ok then return fail(c.id, "could not start planning: " .. tostring(errP)) end
		say(string.format("connect %d: node %d -> node %d, %s, slope %.1f%%, radius %.0f m%s", c.id, ea.node, eb.node, tpl,
			slope * 100, radius, a.build and ", build" or ""), 2)
		-- (taken on last: anything above that fails is this handler's one error answer, with no job left to answer again)
		C.job = job
	end

	C.handlers = handlers
	return C
end

return M
