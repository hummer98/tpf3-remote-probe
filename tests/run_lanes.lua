-- Tests of lanes (content/remote_lanes.lua): a road or track piece's lanes, and around --lanes. Run by
-- tests/run.lua with its helpers: dofile(...)(t). The engine's side is tests/fake_game.lua (installAround's things,
-- their transportModes given by name and turned into the engine's map there).
return function(t)
	local test, eq, truthy, fake, core = t.test, t.eq, t.truthy, t.fake, t.core
	local newGame, send, frames, final, FIRST, SAVES, root = t.newGame, t.send, t.frames, t.final, t.FIRST, t.SAVES, t.root
	local L = dofile(root .. "/content/remote_lanes.lua")

	local function lane(fwd, off, w, modes) return { forward = fwd, offset = off, width = w, speed = 13.89, transportModes = modes } end
	local WALK, ROAD = { "PERSON", "CARGO" }, { "CAR", "BUS", "TRUCK" }
	local ETRAM = { "CAR", "BUS", "TRUCK", "TRAM", "ELECTRIC_TRAM" }
	local function edge(x0, y, tpl, lanes, extra)
		local be = { roadType = "STREET", type = "NORMAL", roadTemplate = tpl, node0 = 1, node1 = 2,
			position0 = { x = x0, y = y, z = 0 }, position1 = { x = x0 + 100, y = y, z = 0 }, laneConfigs = lanes }
		for k, v in pairs(extra or {}) do be[k] = v end
		return be
	end
	-- a vector as the engine's userdata: # and [i] only
	local function vector(list)
		local u = newproxy(true)
		local mt = getmetatable(u)
		mt.__len = function() return #list end
		mt.__index = function(_, i) return list[i] end
		return u
	end
	local THINGS = {
		-- the base's electric tram street: track on the outer road lanes (2 and 5), with its transport network
		[701] = { box = { 0, -8, 0, 100, 8, 1 }, comps = {
			BASE_EDGE = edge(0, 0, "town_new_medium_tram_electrified.lua", fake.TRAM_ELECTRIC_LANES(), { distance = 100 }),
			BASE_EDGE_STREET = {},
			TRANSPORT_NETWORK = { edges = {
				{ transportModes = WALK, speedLimit = 13.89, geometry = { length = 100, width = 3, type = 3, cubicOffsetSpline = { offset = -10.35 } } },
				{ transportModes = ETRAM, speedLimit = 13.89, geometry = { length = 100.5, width = 5 } } } } } },
		-- an approach with the track in the middle (two tram-only lanes), electric, in a tunnel
		[702] = { box = { 0, 20, 0, 100, 36, 1 }, comps = { BASE_EDGE = edge(0, 28, "approach.lua", {
			lane(false, 0, 3, WALK), lane(false, 0, 4, ROAD), lane(false, 0, 3.5, { "TRAM", "ELECTRIC_TRAM" }),
			lane(true, 0, 3.5, { "TRAM", "ELECTRIC_TRAM" }), lane(true, 0, 4, ROAD), lane(true, 0, 3, WALK) },
			{ type = "TUNNEL" }) } },
		-- no tram, a bus lane on the right; BASE_EDGE_STREET with TF2's fields (read as they are)
		[703] = { box = { 0, 40, 0, 100, 56, 1 }, comps = {
			BASE_EDGE = edge(0, 48, "town_new_medium_bus.lua", { lane(false, 0, 3, WALK), lane(false, 0, 4, ROAD),
				lane(true, 0, 4, ROAD), lane(true, 0, 4, { "BUS" }), lane(true, 0, 3, WALK) }),
			BASE_EDGE_STREET = { streetType = 5, tramTrackType = 0, hasBus = true } } },
		-- tram track without wires
		[704] = { box = { 0, 60, 0, 100, 76, 1 }, comps = { BASE_EDGE = edge(0, 68, "town_old_medium_tram.lua", {
			lane(false, 0, 3, WALK), lane(false, 0, 4, { "CAR", "TRAM" }), lane(true, 0, 4, { "CAR", "TRAM" }), lane(true, 0, 3, WALK) }) } },
		-- a track
		[705] = { box = { 0, 80, 0, 100, 84, 1 }, comps = { BASE_EDGE = edge(0, 82, "standard.lua",
			{ lane(true, 0, 5, { "TRAIN", "ELECTRIC_TRAIN" }) }, { roadType = "TRACK" }) } },
		-- a house: no piece
		[706] = { box = { 10, 100, 0, 20, 110, 8 }, comps = { CONSTRUCTION = { fileName = "building/res.con" } } },
		-- lanes as the engine's userdata vector (left as it is by the fake: modes as the engine's map, CAR BUS TRUCK
		-- by the fake enum's values, TRAM false), one lane's modes not walkable
		[707] = { box = { 0, 120, 0, 100, 130, 1 }, comps = { BASE_EDGE = edge(0, 125, "odd.lua",
			vector({ lane(false, 0, 4, { [2] = true, [3] = true, [4] = true, [5] = false }), lane(true, 0, 4, newproxy(false)) })) } },
		-- an approach with one tram lane in the middle, nudged by its offset
		[710] = { box = { 0, 160, 0, 100, 170, 1 }, comps = { BASE_EDGE = edge(0, 165, "approach1.lua", {
			lane(false, 0.15, 3, WALK), lane(false, -0.25, 4, ROAD), lane(true, 0.3, 4, { "TRAM", "ELECTRIC_TRAM" }),
			lane(true, 0.25, 4, ROAD), lane(true, -0.15, 3, WALK) }) } },
		-- one way, the track on its right lane only, offsets not mirrored (as the base's small one-way tram road)
		[711] = { box = { 0, 180, 0, 100, 190, 1 }, comps = { BASE_EDGE = edge(0, 185, "one_way_tram.lua", {
			lane(true, 0.15, 3, WALK), lane(true, -0.5, 4, ROAD), lane(true, 0.5, 4, ETRAM), lane(true, -0.15, 3, WALK) }),
			BASE_EDGE_STREET = { tramTrackType = 1 } } },
		-- no widths: sides from the numbers alone
		[708] = { box = { 0, 140, 0, 100, 150, 1 }, comps = { BASE_EDGE = edge(0, 145, "nowidth.lua", {
			{ forward = false, transportModes = { "CAR" } }, { forward = true, transportModes = { "CAR" } },
			{ forward = true, transportModes = { "CAR" } } }) } },
	}
	local function lanesGame(things)
		local g = newGame({ saves = SAVES })
		fake.installAround(g, { things = things or THINGS })
		-- the id the engine does not have (99999) must never be asked for a component (the engine asserts)
		local get = api.engine.getComponent
		api.engine.getComponent = function(e, k)
			if e == 99999 then g.crashed = "ASSERT: getComponent of no entity " .. tostring(e); error(g.crashed) end
			return get(e, k)
		end
		frames(g, 1)
		return g
	end
	local function run(g, id, cmd, argsLua)
		send(g, id, cmd, argsLua)
		frames(g, FIRST + 10)
		return final(g, id)
	end
	local function byEdge(list, e) for _, d in ipairs(list or {}) do if d.edge == e or d.id == e then return d end end end

	test("lanes: layout across the piece (widths plus offset, + right) and the piece's summary, pure", function()
		local p, w = L.layout({ { width = 3, offset = 0.15 }, { width = 5, offset = -0.5 }, { width = 4, offset = 0 },
			{ width = 4 }, { width = 5, offset = 0.5 }, { width = 3, offset = -0.15 } })
		eq(w, 24)
		eq(p[1].centre, -10.35); eq(p[2].centre, -7); eq(p[3].centre, -2); eq(p[4].centre, 2); eq(p[5].centre, 7)
		eq(p[6].centre, 10.35); eq(p[2].left, -9.5); eq(p[2].right, -4.5)
		eq(p[2].side, "left"); eq(p[5].side, "right")
		p = L.layout({ { width = 4 }, { width = 4 }, { width = 4 } })
		eq(p[2].side, "middle"); eq(p[2].centre, 0)
		-- a middle lane nudged by its offset stays in the middle (side by the widths alone); centre has the nudge
		p = L.layout({ { width = 4 }, { width = 4, offset = 0.5 }, { width = 4 } })
		eq(p[2].side, "middle"); eq(p[2].centre, 0.5)
		p = L.layout({ { width = 4 }, { width = 4, offset = -0.5 }, { width = 4 } })
		eq(p[2].side, "middle"); eq(p[1].side, "left"); eq(p[3].side, "right")
		p, w = L.layout({ { width = 4 }, {}, { width = 4 } })
		eq(w, nil); eq(p[1].centre, nil); eq(p[1].side, "left"); eq(p[2].side, "middle"); eq(p[3].side, "right")
		eq(#L.layout({}), 0)
		local s = L.summary({ { set = { PERSON = true, CARGO = true } }, { set = { CAR = true, TRAM = true, ELECTRIC_TRAM = true } },
			{ set = { BUS = true } }, { set = {} }, {} })
		eq(s.tramTrackType, "ELECTRIC"); eq(s.tramLanes[1], 2); eq(#s.tramLanes, 1); eq(s.busLanes[1], 3); eq(s.hasBusLane, true)
		eq(s.sidewalks[1], 1); eq(#s.roadLanes, 2)
		eq(L.summary({ { set = { TRAM = true } } }).tramTrackType, "YES")
		eq(L.summary({ { set = { CAR = true } } }).tramTrackType, "NO")
		eq(L.summary({}).tramTrackType, "NO")
		eq(L.summary({ { set = { TRAM_TRACK = true } } }).tramTrackType, "YES", "track alone")
		eq(L.summary({ { set = { ELECTRIC_TRAM_TRACK = true } } }).tramTrackType, "ELECTRIC")
		eq(L.summary({ { set = { CAR = true } }, {} }).tramTrackType, "unknown", "a lane unread")
		eq(L.summary({ { set = { CAR = true }, unnamed = true } }).tramTrackType, "unknown", "a key with no name")
		eq(L.summary({ { set = { TRAM = true } }, {} }).tramTrackType, "YES", "tram found: said")
		s = L.summary({ { set = { PERSON = true } }, { set = { CAR = true } }, { set = { TRAM_TRACK = true } }, { set = { CAR = true } } })
		eq(table.concat(s.vehicleLanes, ","), "2,3,4")
	end)

	test("core.edgeLanesRequest: ids as text or a list, network on by default; bad ids refused; read only", function()
		local r = core.edgeLanesRequest({ edges = " 701, 702 " })
		eq(r.edges[1], 701); eq(r.edges[2], 702); eq(r.network, true)
		r = core.edgeLanesRequest({ edges = { 5 }, network = false })
		eq(r.edges[1], 5); eq(r.network, false)
		eq(core.edgeLanesRequest({ edges = 7 }).edges[1], 7)
		local many = {}
		for i = 1, core.EDGE_LANES_MAX + 1 do many[i] = i end
		for _, bad in ipairs({ { {}, "edges" }, { { edges = "" }, "no entity id" }, { { edges = "a" }, "no entity id" },
			{ { edges = "-1" }, "no entity id" }, { { edges = "1.5" }, "no entity id" }, { { edges = {} }, "edges" },
			{ { edges = many }, "at most" }, { { edges = "1", network = "yes" }, "network" } }) do
			local ok, err = core.edgeLanesRequest(bad[1])
			eq(ok, nil, bad[2]); truthy(tostring(err):find(bad[2], 1, true), tostring(err) .. " / wanted " .. bad[2])
		end
		eq(core.COMMANDS.edgeLanes, true); eq(core.CHANGES_GAME.edgeLanes, nil); eq(core.MENU_COMMANDS.edgeLanes, nil)
		eq(core.aroundRequest({ at = "0,0", lanes = true }).lanes, true)
		eq(core.aroundRequest({ at = "0,0" }).lanes, false)
		local ok, err = core.aroundRequest({ at = "0,0", lanes = "yes" })
		eq(ok, nil); truthy(err:find("lanes", 1, true), err)
	end)

	test("lanes: the base's electric tram street has its track on the outer road lanes, left and right", function()
		local g = lanesGame()
		local a = run(g, 2801, "edgeLanes", '{ edges = "701" }')
		truthy(a.ok, a.error)
		truthy(a.note:find("not checked in a game", 1, true), a.note)
		local d = a.edges[1]
		eq(d.edge, 701); eq(d.roadType, "STREET"); eq(d.edgeType, "NORMAL")
		eq(d.streetType, "town_new_medium_tram_electrified.lua"); eq(d.chord, 100); eq(d.distance, 100)
		eq(d.laneCount, 6); eq(d.width, 24); eq(d.tramTrackType, "ELECTRIC"); eq(d.hasBusLane, false)
		eq(#d.tramLanes, 2); eq(d.tramLanes[1], 2); eq(d.tramLanes[2], 5)
		eq(d.sidewalks[1], 1); eq(d.sidewalks[2], 6); eq(#d.roadLanes, 4)
		local l2, l5 = d.lanes[2], d.lanes[5]
		eq(l2.index, 2); eq(l2.side, "left"); eq(l2.centre, -7); eq(l2.width, 5); eq(l2.offset, -0.5)
		eq(l2.forward, false); eq(l2.direction, "node1->node0"); eq(l2.speed, 13.89); eq(l2.speedKmh, 50)
		eq(table.concat(l2.modes, ","), "BUS,CAR,ELECTRIC_TRAM,TRAM,TRUCK")
		eq(table.concat(l2.modeKeys, ","), "2,3,4,5,6", "the enum's values, as read")
		eq(l5.side, "right"); eq(l5.centre, 7); eq(l5.direction, "node0->node1")
		eq(table.concat(d.lanes[3].modes, ","), "BUS,CAR,TRUCK"); eq(d.lanes[3].centre, -2)
		eq(table.concat(d.lanes[1].modes, ","), "CARGO,PERSON"); eq(d.lanes[1].set, nil, "no working table left in")
		-- the street's own component: none of TF2's fields here
		eq(d.street.tramTrackType, nil); eq(d.street.hasBus, nil)
		-- the transport network's edges, as read
		eq(d.networkCount, 2); eq(d.network[1].index, 0); eq(table.concat(d.network[1].modes, ","), "CARGO,PERSON")
		eq(d.network[1].length, 100); eq(d.network[1].offset, -10.35); eq(d.network[2].width, 5)
		eq(table.concat(d.network[2].modes, ","), "BUS,CAR,ELECTRIC_TRAM,TRAM,TRUCK")
		eq(#g.commands, 0, "nothing sent"); truthy(not g.crashed, g.crashed)
	end)

	test("lanes: an approach with its track in the middle, a road without tram, tram without wires, a track", function()
		local g = lanesGame()
		local a = run(g, 2811, "edgeLanes", '{ edges = "702,703,704,705", network = false }')
		truthy(a.ok, a.error); eq(a.read, 4); eq(a.asked, 4)
		local m = byEdge(a.edges, 702)
		eq(m.edgeType, "TUNNEL"); eq(m.tramTrackType, "ELECTRIC")
		eq(#m.tramLanes, 2); eq(m.tramLanes[1], 3); eq(m.tramLanes[2], 4)
		eq(m.lanes[3].side, "left"); eq(m.lanes[3].centre, -1.75); eq(m.lanes[4].side, "right"); eq(m.lanes[4].centre, 1.75)
		eq(table.concat(m.lanes[3].modes, ","), "ELECTRIC_TRAM,TRAM")
		eq(m.network, nil, "network = false: not read")
		local b = byEdge(a.edges, 703)
		eq(b.tramTrackType, "NO"); eq(#b.tramLanes, 0); eq(b.hasBusLane, true); eq(b.busLanes[1], 4)
		eq(b.lanes[4].side, "right")
		eq(b.street.streetType, 5); eq(b.street.tramTrackType, 0, "no enum TramTrackType in the fake: the value");
		eq(b.street.hasBus, true)
		local c = byEdge(a.edges, 704)
		eq(c.tramTrackType, "YES"); eq(c.tramLanes[1], 2); eq(c.tramLanes[2], 3)
		local tr = byEdge(a.edges, 705)
		eq(tr.roadType, "TRACK"); eq(tr.tramTrackType, "NO"); eq(table.concat(tr.lanes[1].modes, ","), "ELECTRIC_TRAIN,TRAIN")
		eq(tr.lanes[1].side, "middle"); eq(tr.street, nil, "no BASE_EDGE_STREET")
		truthy(not g.crashed, g.crashed)
	end)

	test("lanes: no such entity, no piece, the engine's vectors, modes that cannot be walked, no widths", function()
		local g = lanesGame()
		local a = run(g, 2821, "edgeLanes", '{ edges = "99999,706,707,708" }')
		truthy(a.ok, "some read: ok"); eq(a.read, 2); eq(a.asked, 4)
		local n = byEdge(a.edges, 99999)
		truthy(n.error:find("no entity 99999", 1, true), n.error)
		truthy(byEdge(a.edges, 706).error:find("no BASE_EDGE", 1, true))
		local u = byEdge(a.edges, 707)
		eq(u.laneCount, 2); eq(table.concat(u.lanes[1].modes, ","), "BUS,CAR,TRUCK"); eq(u.lanes[2].modes, "unread")
		eq(u.tramTrackType, "unknown", "a lane's modes unread: not NO")
		eq(u.network, "unread: no TRANSPORT_NETWORK on this piece")
		local w = byEdge(a.edges, 708)
		eq(w.width, nil); eq(w.lanes[1].centre, nil); eq(w.lanes[1].side, "left"); eq(w.lanes[2].side, "middle")
		eq(w.lanes[3].side, "right"); eq(w.lanes[1].speed, nil)
		-- none read: not ok, the first one's reason
		local b = run(g, 2822, "edgeLanes", '{ edges = "99999" }')
		eq(b.ok, false); truthy(b.error:find("no entity", 1, true), b.error)
		local c = run(g, 2823, "edgeLanes", '{ edges = "x" }')
		eq(c.ok, false); truthy(c.error:find("no entity id", 1, true), c.error)
		truthy(not g.crashed, g.crashed)
	end)

	test("lanes: a middle tram lane stays in the middle; one way with track on the right; numbers at each node", function()
		local g = lanesGame()
		api.type.enum.TramTrackType = { NO = 0, YES = 1, ELECTRIC = 2 }
		local a = run(g, 2826, "edgeLanes", '{ edges = "710,711,701", network = false }')
		truthy(a.ok, a.error)
		local m = byEdge(a.edges, 710)
		eq(m.tramLanes[1], 3); eq(#m.tramLanes, 1); eq(m.lanes[3].side, "middle"); eq(m.lanes[3].centre, 0.3)
		eq(m.lanes[3].atNode0, 2); eq(m.lanes[3].atNode1, 2); eq(m.lanes[3].vehicleIndex, 2); eq(m.lanes[3].outer, nil)
		eq(table.concat(m.vehicleLanes, ","), "2,3,4"); eq(m.lanes[2].outer, true)
		local o = byEdge(a.edges, 711)
		eq(o.tramTrackType, "ELECTRIC"); eq(o.tramLanes[1], 3); eq(o.lanes[3].side, "right"); eq(o.lanes[2].side, "left")
		eq(o.lanes[3].atNode0, 2); eq(o.lanes[3].atNode1, 1); eq(o.lanes[3].outer, true)
		eq(o.street.tramTrackType, "YES"); eq(o.tramMismatch, "BASE_EDGE_STREET says YES, the lanes ELECTRIC")
		local b = byEdge(a.edges, 701)
		eq(b.lanes[2].atNode0, 1); eq(b.lanes[2].atNode1, 4); eq(b.lanes[5].atNode1, 1); eq(b.tramMismatch, nil)
		eq(b.lanes[2].outer, true); eq(b.lanes[3].outer, nil)
		api.type.enum.TramTrackType = nil
		truthy(not g.crashed, g.crashed)
	end)

	test("lanes: the TransportMode enum as userdata (no walk over it): names still read", function()
		local g = lanesGame()
		local TM = api.type.enum.TransportMode
		local u = newproxy(true)
		getmetatable(u).__index = function(_, k) return TM[k] end
		api.type.enum.TransportMode = u
		local ok, a = pcall(run, g, 2827, "edgeLanes", '{ edges = "701", network = false }')
		api.type.enum.TransportMode = TM
		truthy(ok, a)
		truthy(a.ok, a.error)
		eq(table.concat(a.edges[1].lanes[2].modes, ","), "BUS,CAR,ELECTRIC_TRAM,TRAM,TRUCK"); eq(a.edges[1].tramTrackType, "ELECTRIC")
		truthy(not g.crashed, g.crashed)
	end)

	test("lanes: tangents, the nodes' points and each end's offset from its node (an end 4.5 m beside node0)", function()
		local things = {
			-- a player's narrow road beside a wide one: position0 4.5 m across from node0 (as read in a game 2026-11-26)
			[712] = { box = { 0, 200, 0, 100, 210, 1 }, comps = { BASE_EDGE = edge(0, 204.5, "town_new_small.lua",
				{ lane(true, 0, 4, ROAD) }, { node0 = 7121, node1 = 7122, position1 = { x = 100, y = 200, z = 1 },
					tangent0 = { x = 100, y = -4.5, z = 1 }, tangent1 = { x = 100.0004, y = -4.5, z = 1 } }) } },
			[7121] = { box = { -1, 199, 0, 1, 201, 1 }, comps = { BASE_NODE = { position = { x = 0, y = 200, z = 0 } } } },
			[7122] = { box = { 99, 199, 0, 101, 201, 1 }, comps = { BASE_NODE = { position = { x = 100, y = 200, z = 1 } } } },
			-- node1 is no entity the engine has: its point and offset left out, nothing asked of it
			[713] = { box = { 0, 220, 0, 100, 230, 1 }, comps = { BASE_EDGE = edge(0, 225, "s.lua", { lane(true, 0, 4, ROAD) },
				{ node0 = 7131, node1 = 99999 }) } },
			[7131] = { box = { -1, 224, 0, 1, 226, 1 }, comps = { BASE_NODE = { position = { x = 0, y = 225 } } } },
		}
		local g = lanesGame(things)
		local a = run(g, 2861, "edgeLanes", '{ edges = "712,713" }')
		truthy(a.ok, a.error)
		truthy(a.note:find("endOffset0", 1, true), a.note)
		local d = byEdge(a.edges, 712)
		eq(d.tangent0.x, 100); eq(d.tangent0.y, -4.5); eq(d.tangent0.z, 1); eq(d.tangent1.x, 100)
		eq(d.node0Position.x, 0); eq(d.node0Position.y, 200); eq(d.node0Position.z, 0)
		eq(d.node1Position.x, 100); eq(d.node1Position.z, 1)
		local o0, o1 = d.endOffset0, d.endOffset1
		eq(o0.x, 0); eq(o0.y, 4.5); eq(o0.z, 0); eq(o0.flat, 4.5); eq(o0.length, 4.5)
		eq(o1.x, 0); eq(o1.y, 0); eq(o1.flat, 0); eq(o1.length, 0)
		local d2 = byEdge(a.edges, 713)
		eq(d2.tangent0, nil, "no tangents read: none given")
		eq(d2.node0Position.x, 0); eq(d2.node0Position.z, nil, "a node without z: none")
		eq(d2.endOffset0.flat, 0); eq(d2.endOffset0.z, nil, "z left out where the node has none")
		eq(d2.node1Position, nil); eq(d2.endOffset1, nil)
		eq(#g.commands, 0, "nothing sent"); truthy(not g.crashed, g.crashed)
	end)

	test("lanes: more lanes than MAX_LANES are cut, as said", function()
		local many = {}
		for i = 1, L.MAX_LANES + 3 do many[i] = lane(true, 0, 3, ROAD) end
		local g = lanesGame({ [709] = { box = { 0, 0, 0, 10, 10, 1 }, comps = { BASE_EDGE = edge(0, 5, "wide.lua", many) } } })
		local a = run(g, 2831, "edgeLanes", '{ edges = "709" }')
		truthy(a.ok, a.error)
		eq(a.edges[1].laneCount, L.MAX_LANES); eq(a.edges[1].lanesTruncated, true)
		truthy(not g.crashed, g.crashed)
	end)

	test("around --lanes: streets and tracks get their lanes, nothing else; without it none", function()
		local g = lanesGame()
		local a = run(g, 2841, "around", '{ at = "50,0", radius = 120, lanes = true }')
		truthy(a.ok, a.error)
		local s = byEdge(a.entities, 701)
		eq(s.kind, "street"); eq(s.lanes.tramTrackType, "ELECTRIC"); eq(s.lanes.tramLanes[1], 2)
		eq(s.lanes.network, nil, "around: no transport network")
		eq(byEdge(a.entities, 705).lanes.roadType, "TRACK")
		eq(byEdge(a.entities, 706).lanes, nil, "a house: no lanes")
		eq(a.lanesRead, 6, "the streets and tracks in the circle: 701-705 and 707 (708 on is past 120 m)"); eq(a.lanesSkipped, nil)
		truthy(a.ms.lanes ~= nil, "its own time")
		truthy(a.lanesNote:find("left to right", 1, true))
		local b = run(g, 2842, "around", '{ at = "50,0", radius = 120 }')
		eq(byEdge(b.entities, 701).lanes, nil); eq(b.lanesRead, nil)
		truthy(not g.crashed, g.crashed)
	end)

	test("around --lanes: past the nearest LANES_MAX pieces, the rest are skipped and counted", function()
		local things = {}
		local MAX = 100 -- remote_around.lua's LANES_MAX
		for i = 1, MAX + 5 do
			things[1000 + i] = { box = { 0, i, 0, 10, i + 0.5, 1 }, comps = { BASE_EDGE = edge(0, i, "s.lua", { lane(true, 0, 3, ROAD) }) } }
		end
		local g = lanesGame(things)
		local a = run(g, 2851, "around", '{ at = "5,0", radius = 200, lanes = true }')
		truthy(a.ok, a.error)
		eq(a.lanesRead, MAX); eq(a.lanesSkipped, 5)
		eq(byEdge(a.entities, 1001).lanes.laneCount, 1, "the nearest has its lanes")
		eq(byEdge(a.entities, 1000 + MAX + 5).lanesSkipped, true)
		truthy(not g.crashed, g.crashed)
	end)
end
