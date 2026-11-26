-- Tests of track (track pieces by coordinates: core.trackRequest / trackBatchRequest, remote_build.lua B.track).
-- Run by tests/run.lua with its helpers: dofile(...)(t). The engine's side is tests/fake_game.lua (installBuild):
-- it asserts what the engine is taken to assert (ids, a piece's kind against its roadType and template, a tunnel's
-- typeIndex, a piece's ends at its nodes).
return function(t)
	local test, eq, truthy, core = t.test, t.eq, t.truthy, t.core
	local send, frames, final, FIRST, buildWorld = t.send, t.frames, t.final, t.FIRST, t.buildWorld

	local SIMPLE = "::/infrastructure/track/simple/simple.street_template"
	local STANDARD = "::/infrastructure/track/standard/standard.street_template"
	local HIGH = "::/infrastructure/track/high_speed/high_speed.street_template"
	local TOWN = "::/infrastructure/street/town/town_new_small.street_template"
	local TUNNEL_A = "::/infrastructure/tunnel/tunnel_a.tunnel"
	-- a flat map at height 0 with the base's three tracks (standard from 1930, high_speed from 1980) and a town road;
	-- a track already there: nodes 8201 (0, 100, 0) and 8202 (100, 100, 0), its piece 8300; a road's node 8001
	local function trackWorld(spec)
		spec = spec or {}
		spec.streets = spec.streets or { [SIMPLE] = { roadType = "TRACK", cost = 3 },
			[STANDARD] = { roadType = "TRACK", yearFrom = 1930, cost = 4 }, [HIGH] = { roadType = "TRACK", yearFrom = 1980 },
			[TOWN] = { cost = 5 } }
		spec.year = spec.year or 1935
		spec.height = spec.height or function() return 0 end
		spec.roads = spec.roads or { nodes = { [8201] = { x = 0, y = 100, z = 0 }, [8202] = { x = 100, y = 100, z = 0 },
			[8001] = { x = 300, y = 300, z = 0 }, [8002] = { x = 400, y = 300, z = 0 } },
			edges = { [8300] = { node0 = 8201, node1 = 8202, roadType = "TRACK", roadTemplate = SIMPLE },
				[8100] = { node0 = 8001, node1 = 8002 } } }
		return buildWorld(spec)
	end
	local function trackRun(g, id, argsLua, n)
		send(g, id, "track", argsLua)
		frames(g, n or FIRST + 20)
		return final(g, id)
	end
	local function streetOf(cmd)
		return getmetatable(getmetatable(cmd.proposal).store.streetProposal).store
	end
	local function near(a, b, tol) return math.abs(a - b) <= (tol or 1e-6) end
	-- the acceptance batch: two tracks 5 m apart, 15 m under the ground, and a branch off the first at @sw (x 100)
	-- turning 30 degrees over a chord of about 36 m (a radius of about 70 m)
	local Z = -15
	local BRANCH_TO = { 135, -9.378 }
	local ACCEPT = string.format([[{ batch = {
		{ from = { 0, 0, %d }, toNode = "@sw", to = { 100, 0, %d }, type = "simple", tunnel = "tunnel_a" },
		{ fromNode = "@sw", to = { 200, 0, %d }, type = "simple", tunnel = "tunnel_a" },
		{ from = { 0, 5, %d }, to = { 200, 5, %d }, type = "simple", tunnel = "tunnel_a" },
		{ fromNode = "@sw", tangentFrom = { 1, 0 }, to = { %g, %g, %d }, tangentTo = { 0.866, -0.5 }, type = "simple",
			tunnel = "tunnel_a" },
	} }]], Z, Z, Z, Z, Z, BRANCH_TO[1], BRANCH_TO[2], Z)

	test("core.trackRequest: one piece, type required, a tunnel's ends need z; road's own options refused", function()
		local r = core.trackRequest({ from = "0,0", to = { 50, 0, -15 }, type = " simple ", tunnel = nil })
		truthy(r, "valid"); eq(r.type, "simple"); eq(r.track, true); eq(r.snap, 0, "no joining by distance")
		eq(r.tunnel, nil); eq(r.dryRun, false)
		r = core.trackRequest({ from = "0,0,-15", to = "50,0,-15", type = "simple", tunnel = " tunnel_a ", dryRun = true,
			engineCheck = true, tangentTo = "1,0.2" })
		eq(r.tunnel, "tunnel_a"); eq(r.engineCheck, true); eq(r.tangentTo[2], 0.2)
		eq(core.trackRequest({ fromNode = 8201, to = "50,0,-15", type = "simple", tunnel = "tunnel_a" }).fromNode, 8201,
			"an existing node's height is its own")
		for _, bad in ipairs({
			{ nil, "give from" }, { {}, "give from" },
			{ { from = "0,0", to = "50,0" }, "give type" },
			{ { from = "0,0", to = "50,0", type = "" }, "type must be" },
			{ { from = "0,0", to = "50,0", type = 5 }, "type must be" },
			{ { from = "0,0", to = "50,0,-15", type = "simple", tunnel = "tunnel_a" }, "from needs z with tunnel" },
			{ { from = "0,0,-15", to = "50,0", type = "simple", tunnel = "tunnel_a" }, "to needs z with tunnel" },
			{ { from = "0,0,1", to = "50,0,1", type = "simple", tunnel = "" }, "tunnel must be" },
			{ { from = "0,0,1", to = "50,0,1", type = "simple", tunnel = "@x" }, "tunnel must be" },
			{ { from = "0,0", to = "50,0", type = "simple", snap = 5 }, "snap goes with road only" },
			{ { from = "0,0", to = "50,0", type = "simple", bridge = "concrete" }, "bridge goes with road only" },
			{ { from = "0,0", to = "50,0", type = "simple", alignToEdge = "from" }, "alignToEdge goes with road only" },
			{ { from = "0,0", to = "50,0", type = "simple", removeFields = true }, "removeFields goes with road only" },
			{ { from = "0,0", to = "50,0", type = "simple", ignoreErrors = true }, "ignoreErrors goes with road only" },
			{ { from = "0,0", to = "50,0", type = "simple", engineCheck = true }, "engineCheck goes with dryRun" },
			{ { fromNode = "@a", to = "50,0", type = "simple" }, "a name @a goes with batch only" },
			{ { batch = {} }, "batch goes with trackBatchRequest" },
		}) do
			local ok, err = core.trackRequest(bad[1])
			eq(ok, nil, bad[2]); truthy(tostring(err):find(bad[2], 1, true), tostring(err) .. " / " .. bad[2])
		end
		truthy(core.COMMANDS.track and core.CHANGES_GAME.track and not core.MENU_COMMANDS.track)
	end)

	test("core.trackBatchRequest: the parallel pair and the branch at a shared @name; every bad batch refused", function()
		local r = core.trackBatchRequest({ batch = {
			{ from = { 0, 0, -15 }, toNode = "@sw", to = { 100, 0, -15 }, type = "simple", tunnel = "tunnel_a" },
			{ fromNode = "@sw", to = { 200, 0, -15 }, type = "simple", tunnel = "tunnel_a" },
			{ from = { 0, 5, -15 }, to = { 200, 5, -15 }, type = "standard" },
		}, dryRun = true })
		truthy(r, "valid"); eq(#r.pieces, 3); eq(r.track, true); eq(r.dryRun, true)
		eq(r.pieces[1].type, "simple"); eq(r.pieces[1].tunnel, "tunnel_a"); eq(r.pieces[3].tunnel, nil)
		eq(r.pieces[2].fromNode, "@sw"); eq(r.named["@sw"].z, -15); eq(r.pieces[2].snap, 0)
		local max = {}
		for i = 1, core.TRACK_BATCH_MAX + 1 do max[i] = { from = { i * 10, 0 }, to = { i * 10 + 5, 0 }, type = "simple" } end
		for _, bad in ipairs({
			{ { batch = "x" }, "batch must be a list" },
			{ { batch = {} }, "batch is empty" },
			{ { batch = max }, "at most " .. core.TRACK_BATCH_MAX },
			{ { batch = { { from = "0,0", to = "1,0", type = "simple" } }, type = "simple" }, "type goes in each piece" },
			{ { batch = { { from = "0,0", to = "1,0", type = "simple" } }, snap = 0 }, "snap goes with road only" },
			{ { batch = { { from = "0,0", to = "10,0", type = "simple", snap = 0 } } }, "piece 1: unknown key snap" },
			{ { batch = { { from = "0,0", to = "10,0", type = "simple", bridge = "concrete" } } }, "unknown key bridge" },
			{ { batch = { { from = "0,0", to = "10,0" } } }, "piece 1: give type" },
			{ { batch = { { from = "0,0", to = "10,0", type = "simple" }, 5 } }, "piece 2: not a table" },
			{ { batch = { { fromNode = "@nowhere", to = "10,0", type = "simple" } } }, "node @nowhere: no end gives its point" },
			{ { batch = { { from = "0,0", toNode = "@a", to = "10,0", type = "simple" },
				{ fromNode = "@a", to = "20,0,-15", type = "simple", tunnel = "tunnel_a" } } }, "node @a needs z with tunnel" },
			{ { batch = { { from = "0,0,-15", to = "10,0", type = "simple", tunnel = "tunnel_a" } } }, "piece 1: to needs z" },
			{ { batch = { { from = "0,0", toNode = "@a", to = "10,0", type = "simple" },
				{ from = "0,9", to = "10,9", type = "simple" } } }, "node @a is named at one end only" },
		}) do
			local ok, err = core.trackBatchRequest(bad[1])
			eq(ok, nil, bad[2]); truthy(tostring(err):find(bad[2], 1, true), tostring(err) .. " / " .. bad[2])
		end
		-- (z given at the named node's other end is enough)
		truthy(core.trackBatchRequest({ batch = { { from = "0,0,-15", toNode = "@a", to = "10,0,-15", type = "simple" },
			{ fromNode = "@a", to = "20,0,-15", type = "simple", tunnel = "tunnel_a" } } }))
	end)

	test("core.arcRadius: chord / (2 sin(theta/2)); nil for a straight piece or no numbers", function()
		truthy(near(core.arcRadius(100, 60), 100), tostring(core.arcRadius(100, 60)))
		truthy(near(core.arcRadius(36.23, 30), 70, 0.01), tostring(core.arcRadius(36.23, 30)))
		eq(core.arcRadius(100, 0), nil); eq(core.arcRadius(0, 30), nil); eq(core.arcRadius(nil, 30), nil)
		eq(core.arcRadius(100, 0 / 0), nil); eq(core.arcRadius("100", 30), nil)
	end)

	test("track: one piece on the ground: type 1, roadType TRACK, the template's lanes and distance, no set-ups; its edge id", function()
		local g = trackWorld()
		local a, n = trackRun(g, 3001, '{ from = "0,0", to = "60,0", type = "simple" }')
		eq(n, 1); truthy(a.ok, a.error); eq(a.track, true)
		eq(a.template, SIMPLE); eq(a.from.z, 0); eq(a.from.zFrom, "terrain"); eq(a.tunnel, nil)
		truthy(a.edge and a.edge > 0, "the edge id"); eq(#a.edges, 1); eq(a.edges[1], a.edge)
		eq(a.distanceBuilt, 5, "the template's trackDistance kept on the piece"); truthy(a.note:find("not checked in a game yet", 1, true))
		local cmd = g.buildCmds[#g.buildCmds]
		local st = streetOf(cmd)
		eq(#st.nodesToAdd, 2); eq(#st.edgesToAdd, 1); eq(#(st.nodeConfigsToAdd or {}), 0, "no junction set-ups")
		local e = st.edgesToAdd[1]
		eq(e.type, 1); eq(e.comp.roadType, 1); eq(e.comp.type, 0); eq(e.comp.typeIndex, -1); eq(e.comp.distance, 5)
		eq(e.comp.roadTemplate, SIMPLE); eq(e.comp.node0, -1); eq(e.comp.node1, -2); eq(e.entity, -3)
		eq(g.edges[a.edge].roadType, "TRACK"); truthy(not g.crashed, g.crashed)
		-- a base track's other names, and the year: high_speed is not to be had in 1935
		a = trackRun(g, 3002, '{ from = "0,30", to = "60,30", type = "standard.street_template" }')
		truthy(a.ok, a.error); eq(a.template, STANDARD)
		a = trackRun(g, 3003, '{ from = "0,40", to = "60,40", type = "high_speed" }')
		eq(a.ok, false); truthy(a.error:find("not to be had in 1935", 1, true), a.error)
	end)

	test("track: underground with a tunnel type: BaseEdgeType TUNNEL, typeIndex the type's id, read back as sent", function()
		local g = trackWorld()
		local a = trackRun(g, 3010, '{ from = "0,0,-15", to = "80,0,-15", type = "simple", tunnel = "tunnel_a" }')
		truthy(a.ok, a.error)
		eq(a.tunnel.name, TUNNEL_A); eq(a.tunnel.id, 30); eq(a.tunnel.carriesRail, true)
		eq(a.tunnel.built.edgeType, "TUNNEL"); eq(a.tunnel.built.typeIndex, 30); eq(a.tunnel.built.asSent, true)
		eq(a.from.z, -15); eq(a.from.zFrom, "given")
		local e = streetOf(g.buildCmds[#g.buildCmds]).edgesToAdd[1]
		eq(e.comp.type, 2); eq(e.comp.typeIndex, 30); eq(e.comp.position0.z, -15); eq(e.comp.position1.z, -15)
		truthy(not g.crashed, g.crashed)
		-- the resName itself, and the fallback one folder deeper (road_tunnel_ramp's, for the base's other path)
		a = trackRun(g, 3011, string.format('{ from = "0,20,-15", to = "80,20,-15", type = "simple", tunnel = %q }', TUNNEL_A))
		truthy(a.ok, a.error); eq(a.tunnel.id, 30)
		local g2 = trackWorld({ tunnels = { ["::/infrastructure/tunnel/tunnel/tunnel_a.tunnel"] = { carriers = { "RAIL" } } } })
		a = trackRun(g2, 3012, '{ from = "0,0,-15", to = "80,0,-15", type = "simple", tunnel = "tunnel_a" }')
		truthy(a.ok, a.error); eq(a.tunnel.name, "::/infrastructure/tunnel/tunnel/tunnel_a.tunnel")
	end)

	test("track --batch: the parallel pair 5 m apart and a branch off one, 15 m under: one proposal, the edges, the shared node", function()
		local g = trackWorld()
		local a, n = trackRun(g, 3020, ACCEPT)
		eq(n, 1); truthy(a.ok, a.error); eq(a.batch, true); eq(a.track, true)
		eq(#a.pieces, 4); eq(#a.pieceEdges, 4)
		for i = 1, 4 do truthy(type(a.pieceEdges[i]) == "number" and a.pieceEdges[i] > 0, "piece " .. i .. "'s edge") end
		truthy(a.namedNodes and a.namedNodes["@sw"], "the shared node's id")
		eq(#g.buildCmds, 1, "one proposal")
		local st = streetOf(g.buildCmds[1])
		eq(#st.edgesToAdd, 4); eq(#st.nodesToAdd, 6, "the pair's four ends, @sw, the branch's far end, the 200 m end")
		eq(#(st.nodeConfigsToAdd or {}), 0)
		for _, e in ipairs(st.edgesToAdd) do
			eq(e.type, 1); eq(e.comp.type, 2); eq(e.comp.typeIndex, 30); eq(e.comp.position0.z, Z); eq(e.comp.position1.z, Z)
		end
		-- the branch: three pieces meet at @sw (a switch, no set-up sent: said), its radius about 70 m
		local br = a.pieces[4]
		eq(br.from.name, "@sw"); eq(br.from.meeting, 3); truthy(br.from.switchNote:find("not checked in a game yet", 1, true))
		truthy(br.curved); truthy(near(br.turnDeg, 30, 0.1), tostring(br.turnDeg))
		truthy(br.radiusApprox > 60 and br.radiusApprox < 80, tostring(br.radiusApprox)); eq(br.radiusWarning, nil)
		-- the pair 5 m apart: the engine's pieces read back
		local p1, p3 = g.edges[a.pieceEdges[1]], g.edges[a.pieceEdges[3]]
		truthy(near(g.nodes[p3.node0].y - g.nodes[p1.node0].y, 5), "5 m apart")
		eq(g.edges[a.pieceEdges[4]].node0, a.namedNodes["@sw"])
		truthy(not g.crashed, g.crashed)
	end)

	test("track: --dry-run (nothing sent), --engine-check (the engine's verdict) and --collision-detail", function()
		local g = trackWorld()
		local a = trackRun(g, 3030, (ACCEPT:gsub("} }$", "}, dryRun = true }")))
		truthy(a.ok, a.error); eq(a.dryRun, true); eq(a.checked, false); eq(#g.buildCmds, 0); eq(g.proposalDataCalls, 0)
		a = trackRun(g, 3031, (ACCEPT:gsub("} }$", "}, dryRun = true, engineCheck = true }")))
		truthy(a.ok, a.error); eq(a.checked, true); eq(a.verdict, "buildable"); eq(#g.buildCmds, 0)
		truthy(g.proposalDataCalls > 0); eq(a.edgesSent, 4)
		a = trackRun(g, 3032, '{ from = "0,0,-15", to = "80,0,-15", type = "simple", tunnel = "tunnel_a", dryRun = true, ' ..
			'engineCheck = true, collisionDetail = true }')
		truthy(a.ok, a.error); eq(a.checked, true); truthy(a.collisionDetail ~= nil, "the detail")
		truthy(not g.crashed, g.crashed)
	end)

	test("track: the engine refuses (a collision): the answer says its words, dry run and build", function()
		local g = trackWorld({ blocked = function(x, y) return (x > 20 and x < 60 and math.abs(y) < 3) and 777 or nil end })
		local a = trackRun(g, 3040, '{ from = "0,0,-15", to = "80,0,-15", type = "simple", tunnel = "tunnel_a", dryRun = true, ' ..
			'engineCheck = true }')
		eq(a.ok, false); truthy(a.error:find("the engine would refuse it", 1, true), a.error)
		truthy(a.error:find("Collision", 1, true), a.error)
		a = trackRun(g, 3041, '{ from = "0,0,-15", to = "80,0,-15", type = "simple", tunnel = "tunnel_a" }')
		eq(a.ok, false); truthy(a.error:find("the engine refused it", 1, true), a.error)
		truthy(a.error:find("Collision", 1, true), a.error); eq(#a.edges, 0)
		truthy(not g.crashed, g.crashed)
	end)

	test("track: an existing track node joined by its id; a road's node, a point on a node and other ends refused", function()
		local g = trackWorld()
		local a = trackRun(g, 3050, '{ fromNode = 8202, to = "160,100", type = "simple" }')
		truthy(a.ok, a.error); eq(a.from.node, 8202); eq(a.from.pieces, 1)
		local e = streetOf(g.buildCmds[#g.buildCmds]).edgesToAdd[1]
		eq(e.comp.node0, 8202); eq(#streetOf(g.buildCmds[#g.buildCmds]).nodesToAdd, 1)
		eq(g.edges[a.edge].node0, 8202); truthy(not g.crashed, g.crashed)
		for _, bad in ipairs({
			{ '{ fromNode = 8001, to = "500,300", type = "simple" }', "node 8001 has no track piece" },
			{ '{ fromNode = 9999, to = "500,300", type = "simple" }', "node 9999" },
			{ '{ fromNode = 8201, from = "1,100", to = "-60,100", type = "simple" }', "goes with road only" },
			{ '{ from = "0,100", to = "-60,100", type = "simple" }', "would be on node 8201" },
			{ '{ fromNode = 8201, toNode = 8201, type = "simple" }', "both ends are node 8201" },
			{ '{ from = "0,0", to = "0.5,0", type = "simple" }', "at least 1 m" },
		}) do
			a = trackRun(g, 3050 + _, bad[1])
			eq(a.ok, false, bad[2]); truthy(tostring(a.error):find(bad[2], 1, true), tostring(a.error) .. " / " .. bad[2])
		end
		truthy(not g.crashed, g.crashed)
	end)

	test("track: a missing or wrong type and tunnel type refused before sending", function()
		local g = trackWorld({ tunnels = { [TUNNEL_A] = { carriers = { "RAIL" } },
			["::/infrastructure/tunnel/tunnel_a_car.tunnel"] = { carriers = { "ROAD" } },
			["::/infrastructure/tunnel/mystery.tunnel"] = { noCarriers = true } } })
		for _, bad in ipairs({
			{ '{ from = "0,0", to = "60,0", type = "nope" }', "no street template nope" },
			{ '{ from = "0,0", to = "60,0", type = "town_new_small" }', "no street template town_new_small" },
			{ string.format('{ from = "0,0", to = "60,0", type = %q }', TOWN), "is a road (RoadType STREET), not a track" },
			{ '{ from = "0,0,-15", to = "60,0,-15", type = "simple", tunnel = "nope" }', "no tunnel type nope" },
			{ '{ from = "0,0,-15", to = "60,0,-15", type = "simple", tunnel = "tunnel_a_car" }', "carries ROAD, not RAIL" },
		}) do
			local a = trackRun(g, 3060 + _, bad[1])
			eq(a.ok, false, bad[2]); truthy(tostring(a.error):find(bad[2], 1, true), tostring(a.error) .. " / " .. bad[2])
		end
		eq(#g.buildCmds, 0, "nothing sent")
		-- the tunnel types there are listed when one is not found
		local a = trackRun(g, 3066, '{ from = "0,0,-15", to = "60,0,-15", type = "simple", tunnel = "nope" }')
		truthy(a.error:find(TUNNEL_A, 1, true), a.error)
		-- carriers that cannot be read: said, not refused
		a = trackRun(g, 3067, '{ from = "0,0,-15", to = "60,0,-15", type = "simple", tunnel = "mystery" }')
		truthy(a.ok, a.error); truthy(a.tunnel.carriersNote:find("could not be read", 1, true))
		truthy(not g.crashed, g.crashed)
	end)

	test("track: a radius below the template's minCurveRadiusBuild is warned, not refused; no trackDistance: none sent", function()
		local g = trackWorld({ streets = { [SIMPLE] = { roadType = "TRACK", noTrackDistance = true } } })
		local a = trackRun(g, 3070, '{ from = "0,0", tangentFrom = "1,0", to = "20,10", tangentTo = "0,1", type = "simple" }')
		truthy(a.ok, a.error); truthy(a.radiusApprox < 55, tostring(a.radiusApprox))
		truthy(a.radiusWarning:find("minCurveRadiusBuild 55", 1, true), a.radiusWarning)
		truthy(a.trackDistanceNote:find("could not be read", 1, true))
		eq(streetOf(g.buildCmds[#g.buildCmds]).edgesToAdd[1].comp.distance, nil)
		truthy(not g.crashed, g.crashed)
	end)

	test("fake: a track piece sent as a street, or a tunnel with a bridge's index, is an assertion", function()
		-- (the fake's own checks, so that the track command's records are seen to be what it asserts)
		local g = trackWorld()
		local sp = api.type.SimpleProposal.new()
		local n0, n1 = api.type.NodeAndEntity.new(), api.type.NodeAndEntity.new()
		n0.entity, n1.entity = -1, -2
		n0.comp.position, n1.comp.position = api.type.Vec3f.new(0, 0, 0), api.type.Vec3f.new(50, 0, 0)
		local e = api.type.SegmentAndEntity.new()
		e.entity, e.type = -3, 0
		e.comp.node0, e.comp.node1 = -1, -2
		e.comp.position0, e.comp.position1 = api.type.Vec3f.new(0, 0, 0), api.type.Vec3f.new(50, 0, 0)
		e.comp.roadType, e.comp.roadTemplate, e.comp.laneConfigs = 1, SIMPLE, g.townLanes()
		sp.streetProposal.nodesToAdd, sp.streetProposal.edgesToAdd = { n0, n1 }, { e }
		local ok, err = pcall(api.engine.util.proposal.makeProposalData, sp, nil)
		eq(ok, false); truthy(tostring(err):find("SegmentAndEntity type 0", 1, true), tostring(err))
		g = trackWorld()
		e.type, e.comp.type, e.comp.typeIndex = 1, 2, 10
		sp.streetProposal.edgesToAdd = { e }
		ok, err = pcall(api.engine.util.proposal.makeProposalData, sp, nil)
		eq(ok, false); truthy(tostring(err):find("tunnel type index 10", 1, true), tostring(err))
	end)

	test("track --batch: a switch at an existing node is warned (road crashed there), one at a new node is not", function()
		local g = trackWorld()
		local a = trackRun(g, 3080, '{ batch = { { fromNode = 8202, to = "160,100", type = "simple" }, ' ..
			'{ fromNode = 8202, tangentFrom = "1,0", to = "150,80", tangentTo = "0.8,-0.6", type = "simple" } } }')
		truthy(a.ok, a.error)
		for i = 1, 2 do
			eq(a.pieces[i].from.meeting, 3, "the piece there and the two new ones")
			truthy(a.pieces[i].from.existingSwitchWarning:find("crashed", 1, true), "said loudly")
		end
		truthy(not g.crashed, g.crashed)
		local b = trackRun(g, 3081, ACCEPT)
		truthy(b.ok, b.error); eq(b.pieces[4].from.meeting, 3); eq(b.pieces[4].from.existingSwitchWarning, nil)
	end)

	test("track: no callback in time: the pieces built are looked for between their ends and answered", function()
		local g = trackWorld({ lostCallback = true })
		send(g, 3090, "track", '{ from = "0,0", to = "60,0", type = "simple" }')
		frames(g, FIRST); frames(g, 40, 1)
		local a = final(g, 3090)
		truthy(a and a.ok, a and a.error); truthy(a.edge, "found between its ends")
		truthy(tostring(a.why):find("no answer from the engine", 1, true), tostring(a.why))
		-- lost and not built (in the way, no callback): an error, not a success
		g = trackWorld({ lostCallback = true, blocked = function() return 1 end })
		send(g, 3091, "track", '{ from = "0,0", to = "60,0", type = "simple" }')
		frames(g, FIRST); frames(g, 40, 1)
		a = final(g, 3091)
		eq(a.ok, false); truthy(tostring(a.error):find("no track piece between the ends", 1, true), tostring(a.error))
	end)
end
