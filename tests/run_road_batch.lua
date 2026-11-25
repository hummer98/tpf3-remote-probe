-- Tests of road --batch (several road pieces in one SimpleProposal: core.roadBatchRequest, remote_build.lua
-- B.road). Run by tests/run.lua with its helpers: dofile(...)(t). The engine's side is tests/fake_game.lua
-- (installBuild): it asserts what the engine is taken to assert (ids, a set-up's lanes, a piece's ends at its nodes).
return function(t)
	local test, eq, truthy, core = t.test, t.eq, t.truthy, t.core
	local send, frames, final, FIRST = t.send, t.frames, t.final, t.FIRST
	local roadWorld, roadRun, forestWorld, nodeAt = t.roadWorld, t.roadRun, t.forestWorld, t.nodeAt

	-- the street proposal a build (or a dry run's engine check) sent, as plain lists
	local function streetOf(cmd)
		return getmetatable(getmetatable(cmd.proposal).store.streetProposal).store
	end
	-- a value written out with its keys in order, so that two proposals can be compared as text
	local function canon(v, seen)
		if type(v) == "function" then return "function" end
		if type(v) ~= "table" then return tostring(v) end
		seen = seen or {}
		if seen[v] then return "<loop>" end
		seen[v] = true
		local keys = {}
		for k in pairs(v) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		local out = {}
		for _, k in ipairs(keys) do out[#out + 1] = tostring(k) .. "=" .. canon(v[k], seen) end
		seen[v] = nil
		return "{" .. table.concat(out, ",") .. "}"
	end
	local function proposalText(cmd)
		local st = streetOf(cmd)
		return canon({ nodes = st.nodesToAdd, edges = st.edgesToAdd, add = st.nodeConfigsToAdd, remove = st.nodeConfigsToRemove })
	end
	local function has(list, s0, l0, s1, l1)
		for _, c in ipairs(list or {}) do
			if c.segment0 == s0 and c.lane0 == l0 and c.segment1 == s1 and c.lane1 == l1 and c.withRoad then return true end
		end
		return false
	end
	local function flat() return 0 end

	test("core.roadBatchRequest: pieces with road's values, fromNode / toNode (ids and @names), the options beside them", function()
		local r = core.roadBatchRequest({ batch = {
			{ from = "0,0", to = "100,0", type = " town_new_small ", snap = 0, tangentFrom = "1,0.1" },
			{ fromNode = 8001, toNode = "@a", to = { 100, 50, 3 } },
			{ fromNode = " @a ", to = "200,50" },
		}, dryRun = true, engineCheck = true, removeFields = true })
		truthy(r, "valid")
		eq(r.batch, true); eq(#r.pieces, 3); eq(r.dryRun, true); eq(r.engineCheck, true); eq(r.removeFields, true)
		eq(r.ignoreErrors, false); eq(r.removeBuildings, false)
		eq(r.pieces[1].type, "town_new_small"); eq(r.pieces[1].snap, 0); eq(r.pieces[1].tangentFrom[2], 0.1)
		eq(r.pieces[2].fromNode, 8001); eq(r.pieces[2].from, nil); eq(r.pieces[2].toNode, "@a"); eq(r.pieces[2].snap, 5)
		eq(r.pieces[3].fromNode, "@a", "trimmed"); eq(r.pieces[3].from, nil)
		eq(r.named["@a"].x, 100); eq(r.named["@a"].y, 50); eq(r.named["@a"].z, 3); eq(r.named["@a"].at, "piece 2 to")
		-- the same point again is fine (within 0.01 m), and z from the one end that gives it
		r = core.roadBatchRequest({ batch = { { from = "0,0", to = "10,0", toNode = "@b" },
			{ from = "10.005,0,7", fromNode = "@b", to = "20,0" } } })
		truthy(r); eq(r.named["@b"].z, 7)
		-- ignoreErrors and its fences, as road's
		r = core.roadBatchRequest({ batch = { { from = "0,0", to = "10,0" } }, ignoreErrors = true, _testSave = "probe-x" })
		eq(r.ignoreErrors, true); eq(r.testSave, "probe-x")
		for _, bad in ipairs({
			{ { batch = "x" }, "batch must be a list" },
			{ { batch = {} }, "batch is empty" },
			{ { batch = { { from = "0,0", to = "1,0" }, x = 1 } }, "not a table with other keys" },
			{ { batch = { [1] = { from = "0,0", to = "1,0" }, [3] = { from = "0,0", to = "1,0" } } }, "not a table with other keys" },
			{ { batch = { { from = "0,0", to = "10,0" } }, type = "town_new_small" }, "type goes in each piece of batch" },
			{ { batch = { { from = "0,0", to = "10,0" } }, from = "0,0" }, "from goes in each piece" },
			{ { batch = { { from = "0,0", to = "10,0", dryRun = true } } }, "piece 1: dryRun goes for the whole batch" },
			{ { batch = { { from = "0,0", to = "10,0", ignoreErrors = true } } }, "ignoreErrors goes for the whole batch" },
			{ { batch = { { from = "0,0", to = "10,0", ["tangent-from"] = "1,0" } } }, "unknown key tangent-from" },
			{ { batch = { { from = "0,0", to = "10,0" }, 5 } }, "piece 2: not a table" },
			{ { batch = { { from = "0,0", to = "10,0" }, { from = "0,0" } } }, "piece 2: give to" },
			{ { batch = { { from = "0,0", to = "10,0", snap = 99 } } }, "piece 1: snap must be" },
			{ { batch = { { fromNode = -1, to = "10,0" } } }, "fromNode must be a node's entity id" },
			{ { batch = { { fromNode = 1.5, to = "10,0" } } }, "fromNode must be" },
			{ { batch = { { fromNode = "a", to = "10,0" } } }, "a name for a new node" },
			{ { batch = { { fromNode = "@a b", to = "10,0" } } }, "a name for a new node" },
			{ { batch = { { fromNode = "@" .. string.rep("x", 33), to = "10,0" } } }, "a name for a new node" },
			{ { batch = { { fromNode = 7, toNode = 7 } } }, "piece 1: both ends are node 7" },
			{ { batch = { { from = "0,0", fromNode = "@a", to = "1,0", toNode = "@a" } } }, "both ends are node @a" },
			{ { batch = { { from = "0,0", to = "10,0", toNode = "@a" }, { from = "10.5,0", fromNode = "@a", to = "20,0" } } },
				"node @a: piece 2 from (10.5,0) is 0.500 m from piece 1 to (10,0)" },
			{ { batch = { { from = "0,0", to = "10,0,1", toNode = "@a" }, { from = "10,0,2", fromNode = "@a", to = "20,0" } } },
				"node @a: piece 2 from gives z 2, piece 1 to z 1" },
			{ { batch = { { from = "0,0", toNode = "@a" }, { fromNode = "@a", to = "20,0" } } }, "node @a: no end gives its point" },
			{ { batch = { { from = "0,0", to = "10,0", toNode = "@a" }, { from = "20,0", to = "30,0" } } }, "named at one end only" },
			{ { batch = { { from = "0,0", to = "3000,0", toNode = "@a" }, { fromNode = "@a", to = "3000,10" } } }, "at most 2000 m" },
			{ { batch = { { from = "0,0", to = "10,0", toNode = "@a" }, { fromNode = "@a", to = "3000,0" } } },
				"piece 2: from and to are 2990 m apart" },
			{ { batch = { { from = "0,0", to = "10,0" } }, engineCheck = true }, "engineCheck goes with dryRun only" },
			{ { batch = { { from = "0,0", to = "10,0" } }, ignoreErrors = true, _testSave = "aom-eu-1900" }, "test saves only" },
			{ { batch = { { from = "0,0", to = "10,0" } }, ignoreErrors = true }, "test saves only" },
			{ { batch = { { from = "0,0", to = "10,0" } }, ignoreErrors = "yes", _testSave = "probe-x" }, "ignoreErrors must be true or false" },
		}) do
			local ok, err = core.roadBatchRequest(bad[1])
			eq(ok, nil, bad[2]); truthy(tostring(err):find(bad[2], 1, true), tostring(err) .. " / " .. bad[2])
		end
		-- the most: ROAD_BATCH_MAX pieces; one more refused
		local list = {}
		for i = 1, core.ROAD_BATCH_MAX do list[i] = { from = { i * 20, 0 }, to = { i * 20, 50 } } end
		truthy(core.roadBatchRequest({ batch = list }))
		list[#list + 1] = { from = "0,500", to = "0,600" }
		local no, why = core.roadBatchRequest({ batch = list })
		eq(no, nil); truthy(why:find("batch has 17 pieces: at most 16", 1, true), why)
		-- an existing node's id with a point beside it: both kept (how far is checked where the node is known)
		r = core.roadBatchRequest({ batch = { { from = "0,4.5", fromNode = 8001, to = "10,0" } } })
		eq(r.pieces[1].fromNode, 8001); eq(r.pieces[1].from[2], 4.5)
		-- road (one piece) takes an existing node's id too, alone or with a point; node names are the batch's
		r = core.roadRequest({ fromNode = 8001, to = "10,0" })
		eq(r.fromNode, 8001); eq(r.from, nil)
		r = core.roadRequest({ fromNode = 8001, from = "0,4.5", to = "10,0", toNode = 8002 })
		eq(r.fromNode, 8001); eq(r.from[2], 4.5); eq(r.toNode, 8002)
		for _, bad in ipairs({
			{ { fromNode = "@a", to = "10,0" }, "a name @a goes with batch only" },
			{ { fromNode = -1, to = "10,0" }, "fromNode must be a node's entity id (0 or more)" },
			{ { fromNode = 1.5, to = "10,0" }, "fromNode must be" },
			{ { fromNode = true, to = "10,0" }, "a name @a goes with batch only" },
			{ { to = "10,0" }, "give from: x,y[,z] in metres (no z: the terrain's height there) (or fromNode)" },
			{ {}, "give from" },
		}) do
			no, why = core.roadRequest(bad[1])
			eq(no, nil, bad[2]); truthy(tostring(why):find(bad[2], 1, true), tostring(why) .. " / " .. bad[2])
		end
		eq(core.roadRequest(nil), nil, "nil args: refused, no error")
		-- road itself as before
		r = core.roadRequest({ from = "1,2", to = "30,4", tangentTo = "1,0" })
		eq(r.from[1], 1); eq(r.tangentTo[1], 1); eq(r.batch, nil); eq(r.fromNode, nil)
	end)

	test("road --batch: empty, too many, a bad piece: refused by the mod with nothing sent or asked", function()
		local g = roadWorld({ height = flat })
		local many = {}
		for i = 1, core.ROAD_BATCH_MAX + 1 do many[i] = string.format('{ from = "%d,500", to = "%d,600" }', i * 20, i * 20) end
		for i, args in ipairs({
			'{ batch = {} }',
			'{ batch = { ' .. table.concat(many, ", ") .. ' } }',
			'{ batch = { { from = "0,500", to = "0,600" }, { from = "0,700" } } }',
			'{ batch = { { from = "0,500", to = "0,600" } }, dryRun = true, engineCheck = true, ignoreErrors = true }',
		}) do
			local a, n = roadRun(g, 2000 + i, args)
			eq(n, 1); eq(a.ok, false, args); truthy(tostring(a.error):find("nothing sent", 1, true) or
				tostring(a.error):find("test saves only", 1, true), tostring(a.error))
		end
		eq(#g.buildCmds, 0, "nothing sent"); eq(g.proposalDataCalls, 0, "nothing asked")
		truthy(not g.crashed, g.crashed)
	end)

	test("road --batch: two pieces from one old dead end go in one proposal; ids -1, -2 for the nodes, -3, -4 for the pieces", function()
		local g = roadWorld({ height = flat, roads = { nodes = { [8001] = { x = 100, y = 0, z = 0 }, [8002] = { x = 0, y = 0, z = 0 } },
			edges = { [8100] = { node0 = 8002, node1 = 8001 } } } })
		local bal = g.balance
		local a, n = roadRun(g, 2010, '{ batch = { { from = "100,0", to = "200,-20" }, { fromNode = 8001, to = "200,20" } } }')
		eq(n, 1); truthy(a.ok, a.error)
		eq(#g.buildCmds, 1, "one proposal"); eq(#g.streetCmds, 2, "two pieces in it")
		local st = streetOf(g.buildCmds[1])
		eq(#st.edgesToAdd, 2); eq(#st.nodesToAdd, 2)
		eq(st.nodesToAdd[1].entity, -1); eq(st.nodesToAdd[2].entity, -2)
		eq(st.edgesToAdd[1].entity, -3); eq(st.edgesToAdd[2].entity, -4)
		eq(st.edgesToAdd[1].comp.node0, 8001, "snapped"); eq(st.edgesToAdd[2].comp.node0, 8001, "by its id")
		eq(st.edgesToAdd[1].comp.node1, -1); eq(st.edgesToAdd[2].comp.node1, -2)
		-- the old node's set-up: taken off once, added once, with both new pieces joined to the old one (a junction of
		-- three: 8100's arriving lane into each new piece's leaving one, each new piece's arriving lane into 8100's
		-- and the other new piece's leaving one)
		eq(#st.nodeConfigsToRemove, 1); eq(st.nodeConfigsToRemove[1], 8001)
		local at8001
		for _, nc in ipairs(st.nodeConfigsToAdd) do if nc.entity == 8001 then truthy(not at8001, "once"); at8001 = nc end end
		truthy(at8001); eq(#st.nodeConfigsToAdd, 3, "8001 and the two new dead ends")
		eq(#at8001.comp.laneConnections, 6)
		truthy(has(at8001.comp.laneConnections, 8100, 1, -3, 2) and has(at8001.comp.laneConnections, 8100, 1, -4, 2))
		truthy(has(at8001.comp.laneConnections, -3, 1, -4, 2) and has(at8001.comp.laneConnections, -4, 1, -3, 2),
			"the new pieces joined to each other too")
		-- the answer: the batch's pieces, each its edge and its ends as built; the proposal by its ids
		eq(a.batch, true); eq(#a.pieces, 2); eq(a.edgesSent, 2); eq(a.newNodes, 2); eq(a.nodeConfigs, 3)
		eq(a.pieces[1].from.node, 8001); eq(a.pieces[2].from.node, 8001); eq(a.pieces[2].from.byId, true)
		eq(a.pieces[1].from.sharedBy, 2); eq(a.pieces[1].from.laneRules, 6)
		truthy(a.pieces[1].edge and a.pieces[2].edge and a.pieces[1].edge ~= a.pieces[2].edge)
		eq(g.edges[a.pieces[1].edge].node0, 8001); eq(g.edges[a.pieces[2].edge].node0, 8001)
		eq(a.pieces[1].node0, 8001); eq(a.pieces[2].node1, g.edges[a.pieces[2].edge].node1)
		eq(#a.edges, 2); eq(#a.nodes, 2); eq(a.pieceEdges[1], a.pieces[1].edge)
		eq(a.proposal.nodes[1].id, 8001); eq(a.proposal.nodes[1].existing, true); eq(#a.proposal.nodes[1].ends, 2)
		eq(a.proposal.edges[2].id, -4); eq(a.proposal.edges[2].node0, 8001); eq(a.proposal.edges[2].node1, -2)
		-- as built: 8001 with all six connections
		eq(#g.nodeConns[8001], 6)
		eq(a.cost, 2 * math.floor(math.sqrt(100 ^ 2 + 20 ^ 2) * 10)); eq(g.balance, bal - a.cost)
		truthy(a.note:find("not checked in a game", 1, true))
		truthy(not g.crashed, g.crashed)
	end)

	test("road --batch: a named new node (@a) is one node with one negative id; its pieces joined lane for lane", function()
		local g = roadWorld({ height = flat, roads = { nodes = {}, edges = {} } })
		local a = roadRun(g, 2020, '{ batch = { { from = "0,0", to = "100,0", toNode = "@a" }, ' ..
			'{ fromNode = "@a", to = "200,0" }, { fromNode = "@a", to = "100,100", snap = 0 } } }')
		truthy(a.ok, a.error)
		local st = streetOf(g.buildCmds[1])
		-- nodes: piece 1 from (-1), @a (-2), piece 2 to (-3), piece 3 to (-4); pieces -5, -6, -7
		eq(#st.nodesToAdd, 4)
		eq(st.nodesToAdd[2].entity, -2); eq(st.nodesToAdd[2].comp.position.x, 100)
		eq(st.edgesToAdd[1].comp.node1, -2); eq(st.edgesToAdd[2].comp.node0, -2); eq(st.edgesToAdd[3].comp.node0, -2)
		eq(st.edgesToAdd[3].entity, -7)
		-- @a: three pieces meet: a junction (each arriving road lane to each leaving one of the others)
		local atA
		for _, nc in ipairs(st.nodeConfigsToAdd) do if nc.entity == -2 then atA = nc end end
		eq(#atA.comp.laneConnections, 6)
		truthy(has(atA.comp.laneConnections, -5, 1, -6, 2) and has(atA.comp.laneConnections, -6, 1, -5, 2))
		-- built: one node for @a, all three pieces at it
		local m = a.namedNodes["@a"]
		truthy(m and g.nodes[m], tostring(m))
		eq(g.edges[a.pieces[1].edge].node1, m); eq(g.edges[a.pieces[2].edge].node0, m); eq(g.edges[a.pieces[3].edge].node0, m)
		eq(#g.nodeConns[m], 6)
		eq(a.pieces[1].to.name, "@a"); eq(a.pieces[2].from.name, "@a"); eq(a.pieces[2].from.sharedBy, 3)
		eq(a.proposal.nodes[2].name, "@a"); eq(a.proposal.nodes[2].id, -2); eq(#a.proposal.nodes[2].ends, 3)
		-- two pieces only: a seam, lane for lane (as the game's own road nodes)
		g = roadWorld({ height = flat, roads = { nodes = {}, edges = {} } })
		a = roadRun(g, 2021, '{ batch = { { from = "0,0", to = "100,0", toNode = "@m" }, { fromNode = "@m", to = "200,0" } } }')
		truthy(a.ok, a.error)
		st = streetOf(g.buildCmds[1])
		for _, nc in ipairs(st.nodeConfigsToAdd) do if nc.entity == -2 then atA = nc end end
		eq(#atA.comp.laneConnections, 2, "one lane each way, straight on")
		truthy(has(atA.comp.laneConnections, -4, 1, -5, 2) and has(atA.comp.laneConnections, -5, 1, -4, 2))
		truthy(not g.crashed, g.crashed)
	end)

	test("road --batch: two one-way two-lane roads out of a four-lane street's end: one proposal", function()
		local WIDE = "::/infrastructure/street/town/town_new_large.street_template"
		local ONEWAY = "::/infrastructure/street/town/one_way_town_new_medium.street_template"
		local g = roadWorld({ height = flat, streets = { [WIDE] = { cost = 10, perSide = 2 }, [ONEWAY] = { cost = 10, perSide = "oneWay" } },
			roads = { nodes = { [8001] = { x = 100, y = 0, z = 0 }, [8002] = { x = 0, y = 0, z = 0 } },
				edges = { [8100] = { node0 = 8002, node1 = 8001, laneConfigs = nil, roadTemplate = WIDE } } } })
		-- (the wide street's own lanes: two each way)
		g.edges[8100].laneConfigs = g.townLanes(false, 2)
		local a = roadRun(g, 2030, string.format('{ batch = { { fromNode = 8001, to = "300,-12", type = %q, tangentFrom = "1,0" }, ' ..
			'{ fromNode = 8001, to = "300,12", type = %q, tangentFrom = "1,0" } } }', ONEWAY, ONEWAY))
		truthy(a.ok, a.error); eq(#g.buildCmds, 1)
		-- 8100's two lanes arriving at 8001 into each of the four leaving it (the one-way lanes leave, none arrive)
		local st = streetOf(g.buildCmds[1])
		local cfg = st.nodeConfigsToAdd[1]
		eq(cfg.entity, 8001); eq(#cfg.comp.laneConnections, 8)
		truthy(has(cfg.comp.laneConnections, 8100, 1, -3, 1) and has(cfg.comp.laneConnections, 8100, 2, -4, 2))
		eq(a.pieces[1].curved, true); eq(a.pieces[1].from.kinkDeg, 0, "straight on out of the wide street")
		truthy(not g.crashed, g.crashed)
	end)

	test("road --batch: a bridge piece beside a plain one (each its own edge type), removeBuildings for the whole", function()
		local PILLARLESS = "hummer_pier_spike::/infrastructure/bridge/hps_pillarless.bridge"
		local g = roadWorld({ height = flat, roads = { nodes = {}, edges = {} },
			bridges = { [PILLARLESS] = { carriers = { "ROAD" } } } })
		local a = roadRun(g, 2090, string.format('{ batch = { { from = "0,0,10", to = "100,0,10", toNode = "@a", bridge = %q }, ' ..
			'{ fromNode = "@a", to = "200,0" } }, removeBuildings = true }', PILLARLESS))
		truthy(a.ok, a.error)
		local st = streetOf(g.buildCmds[1])
		eq(st.edgesToAdd[1].comp.type, 1, "BRIDGE"); truthy(st.edgesToAdd[1].comp.typeIndex >= 0)
		eq(st.edgesToAdd[2].comp.type, 0, "NORMAL"); eq(st.edgesToAdd[2].comp.typeIndex, -1)
		eq(a.pieces[1].bridge.built.asSent, true); eq(a.pieces[2].bridge, nil)
		eq(g.buildCmds[1].context.gatherBuildings, true); eq(a.removeBuildings, true)
		truthy(not g.crashed, g.crashed)
	end)

	test("road --batch as tf3ctl writes it (to_lua of road_batch_args): ids as whole numbers, a name, floats", function()
		local g = roadWorld({ height = function() return 2 end })
		-- (tools/tf3ctl.py to_lua of road --batch with from-node 8001 and a node @a: the text it writes)
		local a = roadRun(g, 2080, '{ ["batch"] = { { ["to"] = { 300.0, -12.0 }, ["tangentFrom"] = { 1.0, 0.0 }, ' ..
			'["fromNode"] = 8001 }, { ["from"] = { 100.0, 50.0 }, ["to"] = { 300.0, 62.0 }, ["toNode"] = "@a", ["snap"] = 0.0 }, ' ..
			'{ ["to"] = { 400.0, 62.0 }, ["fromNode"] = "@a" } } }')
		truthy(a.ok, a.error); eq(#a.pieces, 3); eq(a.pieces[1].from.node, 8001); eq(a.pieces[3].from.name, "@a")
		eq(g.edges[a.pieces[2].edge].node1, g.edges[a.pieces[3].edge].node0, "one node for @a")
		truthy(not g.crashed, g.crashed)
	end)

	test("road --batch of one piece: the very proposal road sends (straight, joined, curved, a bridge-less type)", function()
		for i, args in ipairs({
			'from = "102,1", to = "200,0"',
			'from = "0,500", to = "0,600", snap = 0',
			'from = "102,1", to = "200,60", tangentTo = "1,0", type = "town_new_small"',
			'from = "102,1", to = "200,0", alignToEdge = "from"',
		}) do
			-- (one game at a time: a fake game installs the api it answers to)
			local g1 = roadWorld({ year = 1950, height = flat })
			local a1 = roadRun(g1, 2040 + i, '{ ' .. args .. ' }')
			local g2 = roadWorld({ year = 1950, height = flat })
			local a2 = roadRun(g2, 2040 + i, '{ batch = { { ' .. args .. ' } } }')
			truthy(a1.ok and a2.ok, tostring(a1.error) .. " / " .. tostring(a2.error))
			eq(#g1.buildCmds, 1); eq(#g2.buildCmds, 1)
			eq(proposalText(g2.buildCmds[1]), proposalText(g1.buildCmds[1]), args)
			eq(canon(g2.buildCmds[1].context), canon(g1.buildCmds[1].context)); eq(g2.buildCmds[1].ignoreErrors, g1.buildCmds[1].ignoreErrors)
			-- the piece's own answer the same as road's
			for _, k in ipairs({ "template", "length", "curved", "edge", "node0", "node1" }) do eq(a2.pieces[1][k], a1[k], k) end
			eq(canon(a2.pieces[1].tangent1), canon(a1.tangent1)); eq(a2.pieces[1].from.node, a1.from.node)
			eq(a2.newNodes, a1.newNodes); eq(a2.nodeConfigs, a1.nodeConfigs); eq(a2.cost, a1.cost)
		end
	end)

	test("road --batch: new ends on one point need one name; an old node by a wrong id; two pieces on the same nodes", function()
		local g = roadWorld({ height = flat, roads = { nodes = { [8001] = { x = 100, y = 0, z = 0 }, [8002] = { x = 0, y = 0, z = 0 },
			[8003] = { x = 300, y = 300, z = 0 }, [8006] = { x = 400, y = 300, z = 0 } },
			edges = { [8100] = { node0 = 8002, node1 = 8001 }, [8102] = { node0 = 8003, node1 = 8006, roadType = "TRACK" } }, noConfig = { [8002] = true } } })
		for i, c in ipairs({
			{ '{ batch = { { from = "0,500", to = "100,500" }, { from = "100,500", to = "200,500" } } }',
				"piece 1 to and piece 2 from would be two new nodes 0.00 m apart" },
			{ '{ batch = { { from = "0,500", to = "100,500", toNode = "@a" }, { fromNode = "@a", to = "200,500" }, ' ..
				'{ from = "100,500", fromNode = "@b", to = "300,500" }, { fromNode = "@b", to = "300,600" } } }',
				"piece 1 to and piece 3 from would be two new nodes" },
			{ '{ batch = { { fromNode = 9999, to = "100,500" } } }', "piece 1 from: node 9999: no such entity" },
			{ '{ batch = { { fromNode = 8002, to = "100,500" } } }', "piece 1 from: node 8002 has no junction set-up" },
			{ '{ batch = { { fromNode = 8001, to = "100,500" }, { from = "100,500", to = "100,0" } } }', "would be two new nodes" },
			{ '{ batch = { { fromNode = 8001, to = "100,500", toNode = "@a" }, { fromNode = "@a", toNode = 8001 } } }',
				"pieces 1 and 2 join the same two nodes" },
			{ '{ batch = { { from = "0,500", to = "100,500", toNode = "@a" }, { fromNode = "@a", to = "200,500", alignToEdge = "from" } } }',
				"piece 2 from: alignToEdge needs a road node" },
			-- an end by its id: as far off as a snap could never be; a track node; an id that is no entity
			{ '{ batch = { { fromNode = 8001, to = "2200,0" } } }', "piece 1: from and to are 2100 m apart: at most 2000 m" },
			{ '{ batch = { { fromNode = 8003, to = "300,400" } } }', "node 8003 has no road piece" },
			-- a named node on an old node: refused as any new node there
			{ '{ batch = { { from = "0,500", to = "100,0", toNode = "@a" }, { fromNode = "@a", to = "200,0" } } }',
				"piece 1 to: node @a: a new node here would be on node 8001" },
		}) do
			local a = roadRun(g, 2050 + i, c[1])
			eq(a.ok, false, c[2]); truthy(tostring(a.error):find(c[2], 1, true), tostring(a.error) .. " / " .. c[2])
		end
		eq(#g.buildCmds, 0, "nothing sent"); eq(g.proposalDataCalls, 0, "nothing asked")
		truthy(not g.crashed, g.crashed)
	end)

	-- one piece of a batch hitting a fence keeps the whole batch back: no proposal made, nothing asked or sent, and
	-- the answer names the piece and the fence (2026-11-24, the coordinator's condition)
	test("road --batch: one fenced piece of three (piece 2) keeps all three back: nothing made, asked or sent", function()
		local ROADS = { nodes = { [8001] = { x = 100, y = 0, z = 0 }, [8002] = { x = 0, y = 0, z = 0 },
			[8004] = { x = 100, y = 300, z = 0 }, [8005] = { x = 0, y = 300, z = 0 } },
			edges = { [8100] = { node0 = 8002, node1 = 8001 }, [8101] = { node0 = 8005, node1 = 8004 } },
			lights = { [8001] = true }, noConfig = { [8004] = true } }
		local OK1, OK3 = '{ from = "500,500", to = "600,500" }', '{ from = "500,700", to = "600,700" }'
		for i, c in ipairs({
			-- traffic lights at the node piece 2 joins (by its id, and by a snap)
			{ '{ fromNode = 8001, to = "200,0" }', "", "piece 2 from: node 8001 has traffic lights" },
			{ '{ from = "101,0", to = "200,50" }', "", "piece 2 from: node 8001 has traffic lights" },
			-- a node without a junction set-up
			{ '{ fromNode = 8004, to = "200,300" }', "", "piece 2 from: node 8004 has no junction set-up" },
			-- a bad value of piece 2 (core's check of the elements)
			{ '{ from = "0,900", to = "100,900", snap = 99 }', "", "piece 2: snap must be" },
			-- --ignore-errors without a test save's name: the whole batch's fence
			{ '{ from = "0,900", to = "100,900" }', ', ignoreErrors = true, _testSave = "aom-eu-1900"', "test saves only" },
			-- a dry run flag inside piece 2
			{ '{ from = "0,900", to = "100,900", dryRun = true }', "", "piece 2: dryRun goes for the whole batch" },
		}) do
			local g = roadWorld({ height = flat, roads = ROADS })
			local a, n = roadRun(g, 2100 + i, '{ batch = { ' .. OK1 .. ', ' .. c[1] .. ', ' .. OK3 .. ' }' .. c[2] .. ' }')
			eq(n, 1); eq(a.ok, false, c[3]); truthy(tostring(a.error):find(c[3], 1, true), tostring(a.error) .. " / " .. c[3])
			eq(#g.buildCmds, 0, "nothing sent: " .. c[3]); eq(#g.streetCmds, 0); eq(g.proposalDataCalls, 0, "nothing asked")
			eq(a.pieces, nil, "no plan in the answer: refused before it")
			truthy(not g.crashed, g.crashed)
		end
		-- a construction's node under --ignore-errors (the force's own fence) as piece 2 of three
		local fg, b = forestWorld()
		local mouth = nodeAt(b.construction.connectable, "mouth")
		local sent, asked = #fg.buildCmds, fg.proposalDataCalls
		local a = roadRun(fg, 2110, string.format('{ batch = { { from = "400,400", to = "400,500" }, { fromNode = %d, ' ..
			'to = "300,350" }, { from = "450,400", to = "450,500" } }, ignoreErrors = true, _testSave = "probe-x" }', mouth.node))
		eq(a.ok, false); truthy(tostring(a.error):find("piece 2 from: node " .. mouth.node .. " is construction", 1, true), tostring(a.error))
		eq(#fg.buildCmds, sent, "nothing sent"); eq(fg.proposalDataCalls, asked, "nothing asked")
		truthy(not fg.crashed, fg.crashed)
	end)

	test("road --batch: the fences of road: traffic lights at a shared node, --ignore-errors and its save, a construction's node", function()
		-- traffic lights at the old node: refused, nothing sent
		local g = roadWorld({ height = flat, roads = { nodes = { [8001] = { x = 100, y = 0, z = 0 }, [8002] = { x = 0, y = 0, z = 0 } },
			edges = { [8100] = { node0 = 8002, node1 = 8001 } }, lights = { [8001] = true } } })
		local a = roadRun(g, 2060, '{ batch = { { from = "300,300", to = "300,400" }, { fromNode = 8001, to = "200,0" } } }')
		eq(a.ok, false); truthy(tostring(a.error):find("piece 2 from: node 8001 has traffic lights", 1, true), tostring(a.error))
		eq(#g.buildCmds, 0)
		-- --ignore-errors: without a test save's name refused; with one sent forced, the unforced errors told
		g = roadWorld({ height = flat, softBlocked = function(x, y) return y > 1000 and 4343 or nil end })
		local B = '{ batch = { { from = "0,1500", to = "0,1600", toNode = "@a" }, { fromNode = "@a", to = "50,1650" } }'
		for _, save in ipairs({ "nil", '"aom-eu-1900"', '""' }) do
			a = roadRun(g, 2061, B .. ', ignoreErrors = true, _testSave = ' .. save .. ' }')
			eq(a.ok, false); truthy(a.error:find("test saves only", 1, true), a.error)
		end
		eq(#g.buildCmds, 0); eq(g.proposalDataCalls, 0)
		a = roadRun(g, 2062, B .. ' }')
		eq(a.ok, false, "unforced: refused"); eq(g.buildCmds[1].ignoreErrors, false)
		a = roadRun(g, 2063, B .. ', ignoreErrors = true, _testSave = "probe-flat-base" }')
		truthy(a.ok, a.error); eq(g.buildCmds[2].ignoreErrors, true); eq(a.ignoredErrors, true); eq(a.testSave, "probe-flat-base")
		eq(a.unforced.errors[1], "Collision"); eq(a.unforced.refused, true)
		truthy(a.pieces[1].edge and a.pieces[2].edge)
		-- the forced dry run: asked, nothing sent
		local sent = #g.buildCmds
		a = roadRun(g, 2064, '{ batch = { { from = "500,1500", to = "500,1600", toNode = "@a" }, { fromNode = "@a", ' ..
			'to = "550,1650" } }, dryRun = true, engineCheck = true, ignoreErrors = true, _testSave = "probe-x" }')
		eq(a.dryRun, true, tostring(a.error)); eq(a.ignoredErrors, false); eq(#g.buildCmds, sent)
		-- a construction's node among the batch's ends: not forced (as road); unforced it joins
		local fg, b = forestWorld()
		local mouth = nodeAt(b.construction.connectable, "mouth")
		sent = #fg.buildCmds
		a = roadRun(fg, 2065, string.format('{ batch = { { from = "400,400", to = "400,500" }, { fromNode = %d, to = "300,350" } }, ' ..
			'ignoreErrors = true, _testSave = "probe-x" }', mouth.node))
		eq(a.ok, false); truthy(tostring(a.error):find("piece 2 from: node " .. mouth.node .. " is construction", 1, true), tostring(a.error))
		eq(#fg.buildCmds, sent, "nothing sent")
		truthy(not g.crashed and not fg.crashed, tostring(g.crashed or fg.crashed))
	end)

	test("road --batch --dry-run (with and without --engine-check): the plan, nothing sent; a refusal's hits; no ids in the result", function()
		local g = roadWorld({ height = flat, blocked = function(x, y) return y > 1000 and 4343 or nil end })
		local B = '{ batch = { { from = "0,500", to = "100,500", toNode = "@a" }, { fromNode = "@a", to = "200,500" } }'
		local a = roadRun(g, 2070, B .. ', dryRun = true }')
		truthy(a.ok, a.error); eq(a.checked, false); eq(g.proposalDataCalls, 0); eq(#g.buildCmds, 0)
		eq(#a.pieces, 2); eq(a.proposal.nodes[2].name, "@a"); eq(a.proposal.edges[1].node1, -2)
		a = roadRun(g, 2071, B .. ', dryRun = true, engineCheck = true }')
		truthy(a.ok, a.error); eq(a.checked, true); eq(a.buildable, true); truthy(g.proposalDataCalls > 0); eq(#g.buildCmds, 0)
		eq(#g.streetCmds, 0, "nothing built")
		-- one piece of two in the way: the whole proposal refused (a dry run, and a build), what is in the way said
		local C = '{ batch = { { from = "0,500", to = "0,600", toNode = "@a" }, { fromNode = "@a", to = "0,1500" } }'
		a = roadRun(g, 2072, C .. ', dryRun = true, engineCheck = true }')
		eq(a.ok, false); eq(a.buildable, false); truthy(a.error:find("Collision", 1, true), a.error)
		a = roadRun(g, 2073, C .. ' }')
		eq(a.ok, false); truthy(a.error:find("Collision", 1, true), a.error); eq(#g.buildCmds, 1); eq(a.pieces[1].edge, nil); eq(a.pieces[2].edge, nil)
		eq(g.edges[5001], nil, "nothing built")
		truthy(a.hits ~= nil or a.hitsError ~= nil or a.collisions ~= nil)
		-- no ids in the result: each piece found between its ends
		g = roadWorld({ height = flat, noStreetResults = true })
		a = roadRun(g, 2074, B .. ' }')
		truthy(a.ok, a.error); truthy(a.pieces[1].edge and a.pieces[2].edge, "found")
		truthy(a.pieces[1].why:find("found between the ends", 1, true)); eq(#a.edges, 2)
		truthy(not g.crashed, g.crashed)
	end)

	-- an existing node's id with a point beside it (fromNode with from): the piece's end at that point, its node the
	-- old one (a player's road had position0 4.5 m off node0, read 2026-11-26; the engine's side not checked yet)
	test("road (and --batch): fromNode with a point 4.5 m beside it: position0 there, node0 the node; endOffset said", function()
		local function world()
			return roadWorld({ height = flat, roads = { nodes = { [8001] = { x = 100, y = 0, z = 2 }, [8002] = { x = 0, y = 0, z = 2 } },
				edges = { [8100] = { node0 = 8002, node1 = 8001 } } } })
		end
		-- the dry run: nothing sent, the offset in the answer
		local g = world()
		local a = roadRun(g, 2101, '{ fromNode = 8001, from = "100,4.5", to = "200,4.5,2", dryRun = true }')
		truthy(a.ok, a.error); eq(#g.buildCmds, 0)
		eq(a.from.node, 8001); eq(a.from.byId, true); eq(a.from.x, 100, "the end's x, y, z stay the node's"); eq(a.from.y, 0)
		eq(a.from.position.x, 100); eq(a.from.position.y, 4.5); eq(a.from.position.z, 2); eq(a.from.position.zFrom, "node")
		eq(a.from.endOffset.x, 0); eq(a.from.endOffset.y, 4.5); eq(a.from.endOffset.z, 0); eq(a.from.endOffset.flat, 4.5)
		eq(a.to.endOffset, nil); eq(a.length, 100, "between the piece's points")
		truthy(a.offsetNote and a.offsetNote:find("not checked in a game yet", 1, true), tostring(a.offsetNote))
		-- the build: position0 at the point, node0 the node; the curve straight along the chord between the points
		a = roadRun(g, 2102, '{ fromNode = 8001, from = "100,4.5", to = "200,4.5,2" }')
		truthy(a.ok, a.error); eq(#g.buildCmds, 1)
		local e = streetOf(g.buildCmds[1]).edgesToAdd[1].comp
		eq(e.node0, 8001); eq(e.position0.x, 100); eq(e.position0.y, 4.5); eq(e.position0.z, 2)
		eq(e.position1.y, 4.5); eq(e.tangent0.x, 100); eq(e.tangent0.y, 0); eq(e.tangent1.y, 0)
		eq(a.from.endOffset.flat, 4.5); truthy(a.edge, "read back built"); eq(g.edges[a.edge].node0, 8001)
		truthy(not g.crashed, g.crashed)
		-- the same piece in a batch (and the to end beside its node, z given): the same proposal as road's
		g = world()
		local a1 = roadRun(g, 2103, '{ fromNode = 8001, from = "100,4.5", to = "200,4.5" }')
		local g2 = world()
		local a2 = roadRun(g2, 2103, '{ batch = { { fromNode = 8001, from = "100,4.5", to = "200,4.5" } } }')
		truthy(a1.ok and a2.ok, tostring(a1.error) .. " / " .. tostring(a2.error))
		eq(proposalText(g2.buildCmds[1]), proposalText(g.buildCmds[1]))
		eq(canon(a2.pieces[1].from.endOffset), canon(a1.from.endOffset)); truthy(a2.pieces[1].offsetNote)
		g = world()
		a = roadRun(g, 2104, '{ batch = { { from = "-100,0", toNode = 8002, to = "0,-3,5" } } }')
		truthy(a.ok, a.error)
		e = streetOf(g.buildCmds[1]).edgesToAdd[1].comp
		eq(e.node1, 8002); eq(e.position1.y, -3); eq(e.position1.z, 5)
		eq(a.pieces[1].to.position.zFrom, "given"); eq(a.pieces[1].to.endOffset.z, 3); eq(a.pieces[1].to.endOffset.flat, 3)
		truthy(not g.crashed and not g2.crashed, tostring(g.crashed or g2.crashed))
	end)

	test("road (and --batch): a point more than 12 m from its node is refused, nothing sent; 12 m is taken", function()
		local g = roadWorld({ height = flat })
		for i, args in ipairs({ '{ fromNode = 8001, from = "100,12.5", to = "200,12.5" }',
			'{ batch = { { fromNode = 8001, from = "100,12.5", to = "200,12.5" } } }',
			'{ fromNode = 8001, from = "100,12.5", to = "200,12.5", dryRun = true }' }) do
			local a = roadRun(g, 2110 + i, args)
			eq(a.ok, false, args); truthy(a.error:find("is 12.50 m from node 8001", 1, true), a.error)
			truthy(a.error:find("at most 12 m", 1, true), a.error)
		end
		eq(#g.buildCmds, 0, "nothing sent"); eq(g.proposalDataCalls or 0, 0, "nothing asked")
		local a = roadRun(g, 2114, '{ fromNode = 8001, from = "100,12", to = "200,12" }')
		truthy(a.ok, a.error); eq(a.from.endOffset.flat, 12); truthy(not g.crashed, g.crashed)
	end)

	test("road: fromNode alone is as before (the node's own point, no offset); a node id that is no node refused", function()
		for i, args in ipairs({ 'fromNode = 8001, to = "200,20"', 'fromNode = 8001, to = "200,20", tangentTo = "1,0"' }) do
			local g1 = roadWorld({ height = flat })
			local a1 = roadRun(g1, 2120 + i, '{ ' .. args .. ' }')
			local g2 = roadWorld({ height = flat })
			local a2 = roadRun(g2, 2120 + i, '{ batch = { { ' .. args .. ' } } }')
			truthy(a1.ok and a2.ok, tostring(a1.error) .. " / " .. tostring(a2.error))
			eq(proposalText(g2.buildCmds[1]), proposalText(g1.buildCmds[1]), args)
			eq(a1.from.position, nil); eq(a1.from.endOffset, nil); eq(a1.offsetNote, nil)
			local e = streetOf(g1.buildCmds[1]).edgesToAdd[1].comp
			eq(e.node0, 8001); eq(e.position0.x, 100); eq(e.position0.y, 0); eq(e.position0.z, 2)
		end
		local g = roadWorld({ height = flat })
		local a = roadRun(g, 2125, '{ fromNode = 4242, from = "0,0", to = "200,20" }')
		eq(a.ok, false); eq(#g.buildCmds, 0)
		a = roadRun(g, 2126, '{ fromNode = 8001, toNode = 8001 }')
		eq(a.ok, false); truthy(a.error:find("both ends are node 8001", 1, true), a.error); eq(#g.buildCmds, 0)
		truthy(not g.crashed, g.crashed)
	end)

	test("core.endOffset: the difference and its lengths; nil and empty refused quietly; z left out when missing", function()
		local o = core.endOffset({ x = 103, y = 4, z = 1 }, { x = 100, y = 0, z = 0 })
		eq(o.x, 3); eq(o.y, 4); eq(o.z, 1); eq(o.flat, 5); eq(o.length, math.floor(math.sqrt(26) * 1000 + 0.5) / 1000)
		o = core.endOffset({ x = 1, y = 1 }, { x = 0, y = 0, z = 5 })
		eq(o.z, nil); eq(o.length, o.flat)
		eq(core.endOffset(nil, { x = 0, y = 0 }), nil); eq(core.endOffset({}, {}), nil)
		eq(core.endOffset({ x = 0 / 0, y = 0 }, { x = 0, y = 0 }), nil); eq(core.endOffset({ x = 1, y = 1 }, "x"), nil)
		eq(core.ROAD_END_OFFSET_MAX, 12)
	end)
end
