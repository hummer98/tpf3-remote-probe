-- Tests of strips (content/remote_strips.lua): the engine's parallel strips of tracks, read only. Run by tests/run.lua
-- with its helpers: dofile(...)(t). The engine's side is tests/fake_game.lua (installAround's things for the pieces,
-- nodes and strips, installStrips for baseParallelStripSystem, parallelStrip and getNodeTrackSegments).
return function(t)
	local test, eq, truthy, fake, core = t.test, t.eq, t.truthy, t.fake, t.core
	local newGame, send, frames, final, FIRST, SAVES, root = t.newGame, t.send, t.frames, t.final, t.FIRST, t.SAVES, t.root
	local S = dofile(root .. "/content/remote_strips.lua")

	local function near(a, b, tol, msg)
		truthy(type(a) == "number" and math.abs(a - b) <= (tol or 1e-3),
			(msg or "") .. ": " .. tostring(a) .. " wanted " .. tostring(b))
	end
	local function v(x, y, z) return { x = x, y = y, z = z or 0 } end
	-- a track piece from p0 to p1 with tangents t0, t1 (straight when not given), its box round both ends
	local function track(n0, n1, p0, p1, t0, t1, kind)
		t0 = t0 or v(p1.x - p0.x, p1.y - p0.y, p1.z - p0.z)
		t1 = t1 or t0
		return { box = { math.min(p0.x, p1.x) - 1, math.min(p0.y, p1.y) - 1, -20, math.max(p0.x, p1.x) + 1,
			math.max(p0.y, p1.y) + 1, 20 }, comps = { BASE_EDGE = { roadType = "TRACK", type = kind or "NORMAL",
			typeIndex = kind == "TUNNEL" and 0 or -1, node0 = n0, node1 = n1, position0 = p0, position1 = p1,
			tangent0 = t0, tangent1 = t1, laneConfigs = { {}, {}, {} } } } }
	end
	local K = 4 * 100 * math.tan(math.pi / 8) -- a Hermite quarter circle of radius 100
	-- a matrix as the engine's Mat4f: its translation only
	local function mat(x, y, z) return { getTransl = function() return v(x, y, z) end } end
	local function world()
		return {
			-- a double track tunnel along +x: track A at y = 0, track B 5 m to its right (y = -5)
			[801] = track(11, 12, v(0, 0, -10), v(100, 0, -10), nil, nil, "TUNNEL"),
			[802] = track(13, 14, v(0, -5, -10), v(100, -5, -10), nil, nil, "TUNNEL"),
			-- a branch: from track A's middle a quarter circle to the left, on a bridge piece
			[806] = track(12, 15, v(100, 0, 0), v(200, 100, 0), v(K, 0, 0), v(0, K, 0), "BRIDGE"),
			-- a street: not a track (left out of --at)
			[807] = { box = { 0, 30, 0, 100, 34, 1 }, comps = { BASE_EDGE = { roadType = "STREET", type = "NORMAL",
				node0 = 16, node1 = 17, position0 = v(0, 32), position1 = v(100, 32), tangent0 = v(100, 0),
				tangent1 = v(100, 0) }, BASE_EDGE_STREET = {} } },
			-- a track with no curve fields (nil fields), in a strip of its own
			[808] = { box = { 500, 500, 0, 510, 510, 1 }, comps = { BASE_EDGE = { roadType = "TRACK", node0 = 18 } } },
			-- a track in no strip
			[809] = track(19, 20, v(1000, 0), v(1100, 0)),
			-- a house
			[810] = { box = { 2000, 2000, 0, 2010, 2010, 8 }, comps = { CONSTRUCTION = { fileName = "res.con" } } },
			-- nodes
			[11] = { comps = { BASE_NODE = {} } }, [12] = { comps = { BASE_NODE = {} } }, [13] = { comps = { BASE_NODE = {} } },
			[14] = { comps = { BASE_NODE = {} } }, [15] = { comps = { BASE_NODE = {} } }, [18] = { comps = { BASE_NODE = {} } },
			[19] = { comps = { BASE_NODE = {} } }, [20] = { comps = { BASE_NODE = {} } },
			-- the strips
			-- (a range group is a section cut across: both tracks side by side in one group)
			[901] = { comps = { BASE_PARALLEL_STRIP = { rangeGroups = {
				{ { edge = 801, bounds = { 0, 1 } }, { edge = 802, bounds = { 0, 1 } } } } } } },
			-- two sections one after the other: 801's second half, then 806 from 801's end node
			[903] = { comps = { BASE_PARALLEL_STRIP = { rangeGroups = {
				{ { edge = 801, bounds = { 0.5, 1 } } }, { { edge = 806, bounds = { 0, 1 } } } } },
				BRIDGE = { intervals = { { splines = { {}, {} }, railingModels = { { 77, mat(150, 20, 1) }, { 78, mat(160, 30, 1) } } } } } } },
			-- an empty strip: no range groups
			[904] = { comps = { BASE_PARALLEL_STRIP = { rangeGroups = {} } } },
			-- a strip whose component lacks its fields (nil fields), and a range with no bounds
			[905] = { comps = { BASE_PARALLEL_STRIP = {} } },
			[906] = { comps = { BASE_PARALLEL_STRIP = { rangeGroups = { { { edge = 808 } } } } } },
		}
	end
	local SPEC = {
		strips = { [801] = { 901, 903 }, [802] = { 901 }, [806] = { 903 }, [808] = { 905, 906 }, [809] = {} },
		info = { [901] = { carrier = "RAIL", edgeType = "TUNNEL", edgeTypeIndex = 0 },
			[903] = { carrier = "RAIL", edgeType = "BRIDGE", edgeTypeIndex = 2 }, [904] = { carrier = "RAIL" },
			[905] = {}, [906] = { carrier = "RAIL", edgeType = "NORMAL" } },
		nodeTracks = { [11] = { 800, 801 }, [12] = { 801, 806 }, [13] = { 802, 803, 804 }, [14] = { 802 },
			[15] = { 806 }, [18] = { 808 } },
		modelNames = { [77] = "railroad/tunnel_wall.mdl" },
	}
	local function stripsGame(spec, things)
		local g = newGame({ saves = SAVES })
		fake.installAround(g, { things = things or world() })
		local sp = {}
		for k, x in pairs(SPEC) do sp[k] = x end
		for k, x in pairs(spec or {}) do sp[k] = x end
		fake.installStrips(g, sp)
		frames(g, 1)
		return g
	end
	local function run(g, id, argsLua)
		send(g, id, "strips", argsLua)
		frames(g, FIRST + 10)
		return final(g, id)
	end
	local function byKey(list, k, val) for _, d in ipairs(list or {}) do if d[k] == val then return d end end end

	test("strips: the pure helpers (Hermite point, length, turn, across, ends)", function()
		local c = { p0 = v(0, 0), p1 = v(100, 0), t0 = v(100, 0), t1 = v(100, 0) }
		local m = S.measure(c, 0, 1)
		near(m.length, 100, 1e-6, "straight"); near(m.turn, 0, 1e-9, "no turn"); near(m.maxCurvature, 0, 1e-9)
		near(S.measure(c, 0.25, 0.75).length, 50, 1e-6, "half")
		near(S.measure(c, 1, 0.5).length, 50, 1e-6, "backwards: still a length")
		local q = { p0 = v(0, 0), p1 = v(100, 100), t0 = v(K, 0), t1 = v(0, K) }
		m = S.measure(q, 0, 1, 64)
		near(m.length, math.pi * 50, 0.2, "quarter circle"); near(math.deg(m.turn), 90, 0.5, "+ to the left")
		near(m.maxCurvature, 0.01, 0.001, "1/R")
		near(math.deg(S.measure(q, 1, 0, 64).turn), -90, 0.5, "read backwards: the other way")
		eq(S.measure({ p0 = v(0, 0), p1 = v(0 / 0, 0), t0 = v(1, 0), t1 = v(1, 0) }, 0, 1), nil, "NaN")
		eq(S.measure({ p0 = v(0, 0), p1 = nil, t0 = v(1, 0), t1 = v(1, 0) }, 0, 1), nil, "missing")
		local p = S.point(q, 1); near(p.x, 100); near(p.y, 100)
		eq(S.across(v(0, 0), v(1, 0), v(3, -5)), 5, "right: +"); eq(S.across(v(0, 0), v(1, 0), v(0, 5)), -5)
		eq(S.across(v(0, 0), v(0, 0), v(0, 5)), nil, "no direction")
		eq(S.endOf(0), "node0"); eq(S.endOf(1), "node1"); eq(S.endOf(0.00001), "node0"); eq(S.endOf(0.5), nil)
		eq(S.endOf(nil), nil)
		eq(S.endKind(1), "deadEnd"); eq(S.endKind(0), "deadEnd"); eq(S.endKind(2), "continues")
		eq(S.endKind(3), "junction"); eq(S.endKind(nil), "unknown")
	end)

	test("core.stripsRequest: edges or at, radius and limit checked; read only", function()
		local r = core.stripsRequest({ edges = "801, 802" })
		eq(r.edges[1], 801); eq(r.edges[2], 802); eq(r.limit, core.STRIPS_LIMIT.default); eq(r.x, nil)
		r = core.stripsRequest({ at = { 10, -20 }, radius = 50, limit = 3 })
		eq(r.x, 10); eq(r.y, -20); eq(r.radius, 50); eq(r.limit, 3); eq(r.edges, nil)
		eq(core.stripsRequest({ at = "1,2" }).radius, core.STRIPS_RADIUS.default)
		local many = {}
		for i = 1, core.STRIPS_EDGES_MAX + 1 do many[i] = i end
		for _, bad in ipairs({ { {}, "give edges" }, { { edges = "1", at = "0,0" }, "not both" },
			{ { edges = "a" }, "no entity id" }, { { edges = many }, "at most" }, { { at = "1" }, "x,y" },
			{ { at = "a,b" }, "at" }, { { at = "0,0", radius = 0 }, "radius" },
			{ { at = "0,0", radius = core.STRIPS_RADIUS.max + 1 }, "radius" }, { { at = "0,0", radius = 0 / 0 }, "radius" },
			{ { edges = "1", limit = 0 }, "limit" }, { { edges = "1", limit = core.STRIPS_LIMIT.max + 1 }, "limit" },
			{ { edges = "1", limit = 1.5 }, "limit" }, { { at = { 1e9, 0 } }, "within" } }) do
			local ok, err = core.stripsRequest(bad[1])
			eq(ok, nil, bad[2]); truthy(tostring(err):find(bad[2], 1, true), tostring(err) .. " / wanted " .. bad[2])
		end
		eq(core.COMMANDS.strips, true); eq(core.CHANGES_GAME.strips, nil); eq(core.MENU_COMMANDS.strips, nil)
	end)

	test("strips: a double track tunnel, one section with both tracks, their ends and its kind", function()
		local g = stripsGame()
		local a = run(g, 3101, '{ edges = "802" }')
		truthy(a.ok, a.error); eq(a.where, "gui"); truthy(a.note:find("Not checked in a game yet", 1, true), a.note)
		truthy(a.note:find("one section of the strip cut across", 1, true), a.note)
		eq(a.stripCount, 1); eq(a.stripsRead, 1); eq(a.asked[1].edge, 802); eq(a.asked[1].strips[1], 901)
		local s = a.strips[1]
		eq(s.strip, 901); eq(s.stripInfo.carrier, "RAIL"); eq(s.stripInfo.edgeType, "TUNNEL"); eq(s.stripInfo.edgeTypeIndex, 0)
		eq(s.isTunnel, true); eq(s.isBridge, false); eq(s.groupCount, 1); eq(s.laneType, "unread")
		local g1 = s.groups[1]
		local A, B = g1.ranges[1], g1.ranges[2]
		eq(table.concat(g1.edges, ","), "801,802"); eq(g1.rangeCount, 2); eq(g1.length, 100); eq(s.length, 100)
		eq(g1.lengthMin, 100); eq(g1.lengthMax, 100); eq(A.share, 1); eq(B.length, 100)
		eq(A.across, 0); eq(B.across, 5, "track B 5 m to the right"); eq(g1.width, 5)
		eq(g1.curvature.mean, 0); eq(g1.curvature.turnDeg, 0)
		eq(A.from.z, -10); eq(A.bounds[1], 0); eq(A.bounds[2], 1)
		-- ends: A begins where the track goes on, ends at the branch; B begins at a junction, ends at a dead end
		eq(A.ends[1].kind, "continues"); eq(A.ends[1].node, 11); eq(A.ends[1].trackPieces, 2)
		eq(A.ends[2].kind, "continues"); eq(A.ends[2].node, 12)
		eq(B.ends[1].kind, "junction"); eq(B.ends[1].trackPieces, 3); eq(B.ends[2].kind, "deadEnd"); eq(B.ends[2].node, 14)
		eq(#s.deadEnds, 1); eq(s.deadEnds[1].group, 1); eq(s.deadEnds[1].at, "end"); eq(s.deadEnds[1].node, 14)
		eq(s.deadEnds[1].edge, 802); eq(#g1.joins, 0); eq(s.groupsInOrder, nil, "one group: no order")
		eq(#s.edgeShares, 2); eq(s.edgeShares[2].edge, 802); eq(s.edgeShares[2].share, 1); eq(s.edgeShares[2].groups[1], 1)
		-- as read
		eq(s.rangeGroups[1][2].edge, 802); eq(s.rangeGroups[1][2].bounds[2], 1)
		eq(s.bridge, "none (no BRIDGE component read)"); eq(#s.unread, 0)
		-- the pieces used, and what is never read
		eq(#a.pieces, 2); eq(a.pieces[1].edge, 801); eq(a.pieces[1].type, "TUNNEL"); eq(a.pieces[1].track, true)
		eq(a.pieces[1].laneCount, 3); eq(a.pieces[1].length, 100)
		truthy(a.unread[1]:find("lane.type", 1, true), a.unread[1]); eq(#a.unread, #S.NEVER_READ)
		eq(#g.commands, 0, "nothing sent"); truthy(not g.crashed, g.crashed)
	end)

	test("strips: a branch (a piece in two strips), part of a piece, a curve, a bridge's placed pieces", function()
		local g = stripsGame()
		local a = run(g, 3111, '{ edges = "801,806" }')
		truthy(a.ok, a.error); eq(a.stripCount, 2, "each strip once"); eq(#a.asked, 2)
		eq(table.concat(a.asked[1].strips, ","), "901,903"); eq(a.asked[2].strips[1], 903)
		local s = byKey(a.strips, "strip", 903)
		eq(s.isBridge, true); eq(s.isTunnel, false); eq(s.stripInfo.edgeType, "BRIDGE")
		eq(s.groupCount, 2)
		local g1, g2 = s.groups[1], s.groups[2]
		eq(g1.edges[1], 801); eq(g2.edges[1], 806); eq(g1.ranges[1].length, 50, "half of 801"); eq(g1.ranges[1].share, 0.5)
		near(g2.ranges[1].length, math.pi * 50, 0.5, "the quarter circle"); near(s.length, 50 + math.pi * 50, 0.5, "sections added")
		eq(g1.length, 50); near(g2.length, math.pi * 50, 0.5)
		near(g2.curvature.turnDeg, 90, 1, "left"); truthy(g2.curvature.mean > 0); near(g2.curvature.maxAbs, 0.01, 0.002)
		eq(g1.curvature.turnDeg, 0); truthy(s.curvatureMean > 0)
		eq(g1.ranges[1].from.x, 50); eq(g2.ranges[1].to.y, 100); eq(g1.width, 0); eq(g1.ranges[1].across, 0)
		local e1, e2 = g1.ranges[1].ends, g2.ranges[1].ends
		eq(e1[1].kind, "insidePiece"); eq(e1[1].bound, 0.5); eq(e1[1].node, nil)
		eq(e1[2].kind, "joinsGroup", "801's end node is 806's start"); eq(e1[2].node, 12); eq(e1[2].joins[1], 2)
		eq(e2[1].kind, "joinsGroup"); eq(e2[1].joins[1], 1)
		eq(e2[2].kind, "deadEnd"); eq(e2[2].node, 15); eq(#s.deadEnds, 1); eq(s.deadEnds[1].edge, 806)
		eq(g1.joins[1], 2); eq(g2.joins[1], 1); eq(s.groupsInOrder, true)
		eq(s.bridge.intervals, 1); eq(s.bridge.list[1].splines, 2); eq(s.bridge.list[1].railingModels, 2)
		local m = s.bridge.list[1].models
		eq(m[1].model, 77); eq(m[1].name, "railroad/tunnel_wall.mdl"); eq(m[1].at.x, 150); eq(m[2].name, nil, "no name read")
		truthy(not g.crashed, g.crashed)
	end)

	test("strips --at: the track pieces near a point (not streets, not houses), and nothing in the radius", function()
		local g = stripsGame()
		local a = run(g, 3121, '{ at = "50,-2", radius = 10 }')
		truthy(a.ok, a.error); eq(a.scan.radius, 10); eq(a.scan.tracks, 2); eq(#a.asked, 2)
		eq(a.asked[1].edge, 801); eq(a.asked[2].edge, 802); eq(a.stripCount, 2)
		local b = run(g, 3122, '{ at = { 50, 32 }, radius = 3 }')
		truthy(b.ok, b.error); eq(b.scan.pieces, 1, "the street seen"); eq(b.scan.tracks, 0, "and left out"); eq(#b.strips, 0)
		local c = run(g, 3123, '{ at = "-3000,-3000", radius = 5 }')
		truthy(c.ok, c.error); eq(c.scan.pieces, 0); eq(#c.asked, 0); eq(#c.strips, 0); eq(c.stripCount, 0)
		local d = run(g, 3124, '{ at = "1050,0", radius = 5 }')
		eq(d.asked[1].edge, 809); eq(#d.asked[1].strips, 0, "a track in no strip"); eq(#d.strips, 0)
		truthy(not g.crashed, g.crashed)
	end)

	test("strips: no such piece, not a piece, an empty strip, nil fields, getStrips failing", function()
		local g = stripsGame({ strips = { [801] = { 904 }, [808] = { 905, 906 } }, getStripsRaises = { [802] = true } })
		local a = run(g, 3131, '{ edges = "99999" }')
		eq(a.ok, false); truthy(a.error:find("no such piece: 99999", 1, true), a.error); eq(a.missing[1], 99999)
		eq(g.stripCalls.getStrips, 0, "the engine not asked")
		local b = run(g, 3132, '{ edges = "99999,810,801,802,808" }')
		truthy(b.ok, "some read: ok"); eq(b.missing[1], 99999)
		truthy(byKey(b.asked, "edge", 810).error:find("no BASE_EDGE", 1, true))
		truthy(byKey(b.asked, "edge", 802).error:find("getStrips failed", 1, true))
		local e = byKey(b.strips, "strip", 904)
		eq(e.groupCount, 0); eq(#e.groups, 0); eq(e.length, nil); eq(#e.deadEnds, 0); eq(e.stripInfo.edgeType, nil)
		truthy(table.concat(e.unread, "|"):find("stripInfo.edgeType", 1, true))
		local n = byKey(b.strips, "strip", 905)
		truthy(table.concat(n.unread, "|"):find("BASE_PARALLEL_STRIP.rangeGroups", 1, true), table.concat(n.unread, "|"))
		truthy(table.concat(n.unread, "|"):find("stripInfo.carrier", 1, true))
		local r = byKey(b.strips, "strip", 906)
		eq(r.groups[1].edges[1], 808); eq(r.groups[1].length, nil); truthy(r.groups[1].lengthWhy)
		truthy(table.concat(r.unread, "|"):find("bounds", 1, true))
		truthy(table.concat(b.unread, "|"):find("position0/1", 1, true), "the piece's curve listed")
		eq(byKey(b.pieces, "edge", 808).length, nil)
		truthy(not g.crashed, g.crashed)
	end)

	test("strips: the engine's userdata, the limit, and no strip system in this state", function()
		local g = stripsGame({ userdata = true })
		local a = run(g, 3141, '{ edges = "801" }')
		truthy(a.ok, a.error); eq(a.stripCount, 2)
		local s = byKey(a.strips, "strip", 903)
		eq(s.stripInfo.carrier, "RAIL"); eq(s.groups[2].edges[1], 806); eq(s.groups[1].ranges[1].ends[2].joins[1], 2); eq(s.bridge.list[1].models[1].at.y, 20)
		local l = run(g, 3142, '{ edges = "801", limit = 1 }')
		eq(l.stripCount, 1); eq(l.stripsTruncated, true)
		truthy(not g.crashed, g.crashed)
		local ng = stripsGame({ noSystem = true })
		local n = run(ng, 3143, '{ edges = "801" }')
		eq(n.ok, false); truthy(n.error:find("strips --gs", 1, true), n.error)
		local bad = run(ng, 3144, '{ edges = "a" }')
		eq(bad.ok, false); truthy(bad.error:find("no entity id", 1, true), bad.error)
		local nu = stripsGame({ noUtil = true })
		local u = run(nu, 3145, '{ edges = "802" }')
		truthy(u.ok, u.error); truthy(table.concat(u.strips[1].unread, "|"):find("parallelStrip.getStripInfo", 1, true))
		eq(u.strips[1].isTunnel, nil); eq(u.strips[1].groups[1].ranges[2].across, 5)
		truthy(not ng.crashed and not nu.crashed)
	end)

	test("strips: review fixes (a curve near the point, the octree's cap, the clock, a bound unread, no enum)", function()
		-- a piece bulging 75 m off its chord: the curve passes (50, 1075), the chord does not come near it
		local w = world()
		w[820] = track(40, 41, v(0, 1000), v(100, 1000), v(0, 300), v(0, -300))
		w[820].box = { -1, 999, -20, 101, 1080, 20 }
		near(S.nearest(w[820].comps.BASE_EDGE and { p0 = v(0, 1000), p1 = v(100, 1000), t0 = v(0, 300),
			t1 = v(0, -300) }, 50, 1075), 0, 0.5, "on the curve")
		local g = stripsGame({ strips = { [820] = {} }, nodeTracks = { [40] = { 820 }, [41] = { 820 } } }, w)
		local a = run(g, 3151, '{ at = "50,1075", radius = 10 }')
		truthy(a.ok, a.error); eq(a.scan.tracks, 1, "found by its curve"); eq(a.asked[1].edge, 820)
		-- more found than the octree list holds: counted
		local small = setmetatable({ AROUND_SCAN_MAX = 1 }, { __index = core })
		local b = S.run({ at = { 50, -2 }, radius = 10 }, { core = small })
		truthy(b.ok, b.error); eq(b.scan.dropped, 1); eq(b.scan.tracks, 1)
		-- the clock: past the budget after the first look, nothing more read
		local n = 0
		local late = function() n = n + 1; return n == 1 and 0 or 10 end
		local c = S.run({ edges = { 801, 802 } }, { clock = late })
		eq(c.timeUp, true); eq(#c.asked, 0); eq(c.stripCount, 0)
		-- in the scan too, looked at every 200 pieces
		local many = world()
		for i = 1, 450 do many[20000 + i] = { box = { 0, 2000, -1, 1, 2001, 1 }, comps = {} } end
		local mg = stripsGame({}, many)
		n = 0
		local d = S.run({ at = { 0, 2000 }, radius = 5 }, { clock = late })
		eq(d.timeUp, true); eq(d.scan.timeTruncated, true); eq(d.scan.looked, 199)
		-- a bound that did not read: false in the array, not a hole
		local e = S.run({ edges = { 808 } }, {})
		local r = byKey(e.strips, "strip", 906)
		eq(r.rangeGroups[1][1].bounds[1], false); eq(r.groups[1].ranges[1].bounds[2], false)
		truthy(core.json(r.rangeGroups):find("[false,false]", 1, true), core.json(r.rangeGroups))
		-- no RoadType.STREET in this state: a track told by its having no street component, and said so
		local RT = api.type.enum.RoadType
		api.type.enum.RoadType = { TRACK = RT.TRACK } -- (the fake reads TRACK through it; only STREET missing)
		local okF, f = pcall(S.run, { edges = { 802 } }, {})
		api.type.enum.RoadType = RT
		truthy(okF, tostring(f)); truthy(f.pieces[1], core.json(f)); eq(f.pieces[1].track, true)
		truthy(table.concat(f.unread, "|"):find("RoadType.STREET", 1, true), table.concat(f.unread, "|"))
		truthy(not g.crashed and not mg.crashed)
	end)

	-- the shape measured in a game (2026-11-26, probe-flat-base-2): tunnel tracks 2669 (0,0 -> 100,0) and 2671
	-- (100,0 -> 200,0) end to end, 2673 (0,5 -> 200,5) beside them, and 2674 branching off at 100,0 (36.641 m, 30
	-- degrees to the right) in a strip of its own. The engine gave strip 2686's rangeGroups as
	-- [[2669 0-1, 2673 0-0.5], [2671 0-1, 2673 0.5-1]]: a group is a section cut across, 2673 split between two
	local function measuredWorld()
		local w = world()
		local R, th = 70, math.rad(30)
		local Kb = 4 * R * math.tan(th / 4) -- a Hermite arc of 30 degrees, radius 70
		w[2669] = track(31, 32, v(0, 0, -15), v(100, 0, -15), nil, nil, "TUNNEL")
		w[2671] = track(32, 33, v(100, 0, -15), v(200, 0, -15), nil, nil, "TUNNEL")
		w[2673] = track(34, 35, v(0, 5, -15), v(200, 5, -15), nil, nil, "TUNNEL")
		w[2674] = track(32, 36, v(100, 0, -15), v(100 + R * math.sin(th), -R * (1 - math.cos(th)), -15),
			v(Kb, 0, 0), v(Kb * math.cos(th), -Kb * math.sin(th), 0), "TUNNEL")
		for n = 31, 36 do w[n] = { comps = { BASE_NODE = {} } } end
		w[2686] = { comps = { BASE_PARALLEL_STRIP = { rangeGroups = {
			{ { edge = 2669, bounds = { 0, 1 } }, { edge = 2673, bounds = { 0, 0.5 } } },
			{ { edge = 2671, bounds = { 0, 1 } }, { edge = 2673, bounds = { 0.5, 1 } } } } } } }
		w[2684] = { comps = { BASE_PARALLEL_STRIP = { rangeGroups = { { { edge = 2674, bounds = { 0, 1 } } } } } } }
		-- an empty group among others, and an empty group alone (edge cases, not seen in a game)
		w[2690] = { comps = { BASE_PARALLEL_STRIP = { rangeGroups = { {}, { { edge = 2669, bounds = { 0, 1 } } } } } } }
		w[2691] = { comps = { BASE_PARALLEL_STRIP = { rangeGroups = { {} } } } }
		return w
	end
	local MEASURED = {
		strips = { [2669] = { 2686 }, [2671] = { 2686 }, [2673] = { 2686 }, [2674] = { 2684 } },
		info = { [2686] = { carrier = "RAIL", edgeType = "TUNNEL", edgeTypeIndex = 1 },
			[2684] = { carrier = "RAIL", edgeType = "TUNNEL", edgeTypeIndex = 1 }, [2690] = {}, [2691] = {} },
		nodeTracks = { [31] = { 2669 }, [32] = { 2669, 2671, 2674 }, [33] = { 2671 }, [34] = { 2673 }, [35] = { 2673 },
			[36] = { 2674 } },
	}

	test("strips: the shape measured in a game, sections cut across, a piece split between two of them", function()
		local g = stripsGame(MEASURED, measuredWorld())
		local a = run(g, 3161, '{ edges = "2669,2674" }')
		truthy(a.ok, a.error); eq(a.stripCount, 2)
		local s = byKey(a.strips, "strip", 2686)
		eq(s.isTunnel, true); eq(s.stripInfo.edgeTypeIndex, 1); eq(s.groupCount, 2); eq(s.laneType, "unread")
		local g1, g2 = s.groups[1], s.groups[2]
		eq(table.concat(g1.edges, ","), "2669,2673"); eq(table.concat(g2.edges, ","), "2671,2673")
		-- each section's length along the strip, and the strip's: the sections added up
		eq(g1.length, 100); eq(g2.length, 100); eq(g1.lengthMin, 100); eq(g1.lengthMax, 100); eq(s.length, 200)
		eq(g1.ranges[2].length, 100, "half of 2673"); eq(g1.ranges[2].share, 0.5); eq(g1.ranges[1].share, 1)
		-- across: 2673 lies 5 m to the left of 2669 (and of 2671) looking along them
		eq(g1.ranges[1].across, 0); eq(g1.ranges[2].across, -5); eq(g2.ranges[2].across, -5); eq(g1.width, 5); eq(g2.width, 5)
		eq(g1.ranges[2].from.y, 5); eq(g1.ranges[2].to.x, 100); eq(g2.ranges[2].from.x, 100)
		-- ends: where a section meets the next (the same node, or the same cut through a piece) and where the strip ends
		local e69, e73a, e71, e73b = g1.ranges[1].ends, g1.ranges[2].ends, g2.ranges[1].ends, g2.ranges[2].ends
		eq(e69[1].kind, "deadEnd"); eq(e69[1].node, 31)
		eq(e69[2].kind, "joinsGroup", "the node 2671 starts at"); eq(e69[2].node, 32); eq(e69[2].joins[1], 2)
		eq(e69[2].trackPieces, 3, "the branch counted, but the strip goes on")
		eq(e73a[1].kind, "deadEnd"); eq(e73a[2].kind, "joinsGroup", "the same cut through 2673"); eq(e73a[2].bound, 0.5)
		eq(e73a[2].node, nil); eq(e73a[2].joins[1], 2)
		eq(e71[1].kind, "joinsGroup"); eq(e71[1].joins[1], 1); eq(e71[2].kind, "deadEnd"); eq(e71[2].node, 33)
		eq(e73b[1].kind, "joinsGroup"); eq(e73b[1].bound, 0.5); eq(e73b[2].kind, "deadEnd"); eq(e73b[2].node, 35)
		eq(#s.deadEnds, 4); eq(g1.joins[1], 2); eq(#g1.joins, 1); eq(g2.joins[1], 1); eq(s.groupsInOrder, true)
		-- each piece's share of the strip: 2673 half in each group, whole in all
		local sh = byKey(s.edgeShares, "edge", 2673)
		eq(sh.share, 1); eq(table.concat(sh.groups, ","), "1,2"); eq(byKey(s.edgeShares, "edge", 2669).share, 1)
		eq(#s.edgeShares, 3)
		-- as read
		eq(s.rangeGroups[2][2].edge, 2673); eq(s.rangeGroups[2][2].bounds[1], 0.5)
		-- the branch: a strip of its own, one group of one piece
		local b = byKey(a.strips, "strip", 2684)
		eq(b.groupCount, 1); eq(#b.groups[1].ranges, 1); near(b.length, 36.652, 0.05, "the 30 degree arc")
		near(b.groups[1].curvature.turnDeg, -30, 0.5, "to the right"); eq(b.groups[1].width, 0)
		eq(b.groups[1].ranges[1].across, 0); eq(#b.groups[1].joins, 0); eq(b.groupsInOrder, nil)
		eq(b.groups[1].ranges[1].ends[1].kind, "junction"); eq(b.groups[1].ranges[1].ends[2].kind, "deadEnd")
		-- an empty group: nothing measured in it, the strip's length from the rest; an empty group alone: no length
		local stripsOf = function(sp)
			local gg = stripsGame({ strips = sp, info = MEASURED.info, nodeTracks = MEASURED.nodeTracks }, measuredWorld())
			return gg, run(gg, 3162, '{ edges = "2669" }')
		end
		local g3, d = stripsOf({ [2669] = { 2690, 2691 } })
		truthy(d.ok, d.error)
		local e = byKey(d.strips, "strip", 2690)
		eq(e.groupCount, 2); eq(e.groups[1].rangeCount, 0); eq(#e.groups[1].ranges, 0); eq(e.groups[1].length, nil)
		eq(e.groups[1].width, nil); eq(e.groups[1].acrossWhy, nil); eq(e.groups[1].lengthWhy, nil); eq(e.length, 100)
		eq(e.groups[2].ranges[1].ends[2].kind, "junction", "no section after it in this strip")
		eq(e.groupsInOrder, false, "group 1 joins nothing")
		local f = byKey(d.strips, "strip", 2691)
		eq(f.groupCount, 1); eq(f.length, nil); eq(#f.edgeShares, 0); eq(#f.deadEnds, 0)
		local ok, js = pcall(core.json, d)
		truthy(ok, tostring(js))
		truthy(not g.crashed and not g3.crashed, g.crashed or g3.crashed)
	end)

	test("strips: across or length that cannot be worked out is said so (a piece with no curve beside one)", function()
		local w = world()
		w[2692] = { comps = { BASE_PARALLEL_STRIP = { rangeGroups = {
			{ { edge = 801, bounds = { 0, 1 } }, { edge = 808, bounds = { 0, 1 } } } } } } }
		local g = stripsGame({ strips = { [801] = { 2692 } }, info = { [2692] = { carrier = "RAIL" } } }, w)
		local a = run(g, 3171, '{ edges = "801" }')
		truthy(a.ok, a.error)
		local gr = a.strips[1].groups[1]
		eq(gr.ranges[1].across, 0); eq(gr.ranges[2].across, nil); eq(gr.width, nil); truthy(gr.acrossWhy)
		eq(gr.length, nil); truthy(gr.lengthWhy); eq(a.strips[1].length, nil)
		truthy(not g.crashed, g.crashed)
	end)

	test("strips: run() as eval --gs calls it (where gs, os.time), the same answer", function()
		local g = stripsGame()
		local a = S.run({ edges = { 802 } }, { where = "gs" })
		truthy(a.ok, a.error); eq(a.where, "gs"); eq(a.strips[1].strip, 901); eq(a.strips[1].groups[1].ranges[2].across, 5)
		local bad = S.run({}, { where = "gs" })
		eq(bad.ok, false); eq(bad.where, "gs")
		local ok, js = pcall(core.json, a)
		truthy(ok, tostring(js))
		truthy(not g.crashed, g.crashed)
	end)
end
