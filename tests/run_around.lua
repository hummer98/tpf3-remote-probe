-- Tests of around (content/remote_around.lua), the names of what a refused build or road collided with, and
-- build / road --remove-buildings and build --join-streets. Run by tests/run.lua with its helpers: dofile(...)(t).
-- The engine's side is tests/fake_game.lua (installAround over installBuild).
return function(t)
	local test, eq, truthy, fake, core = t.test, t.eq, t.truthy, t.fake, t.core
	local newGame, send, frames, final, FIRST, SAVES = t.newGame, t.send, t.frames, t.final, t.FIRST, t.SAVES
	local buildWorld, buildRun, roadWorld, roadRun, RAMP = t.buildWorld, t.buildRun, t.roadWorld, t.roadRun, t.RAMP

	-- the edge of a town round (0, 0): a street along y = 0, a track up x = 0 from y 50, a house (town building 601
	-- of town 700, its construction 602), a bus station (603), a field (604), a tree not in the octree (605), a
	-- person walking (606), the town itself (700), and something far off (800)
	local THINGS = {
		[501] = { box = { -100, -4, 0, 100, 4, 1 }, comps = { BASE_EDGE = { roadType = "STREET", roadTemplate = "town_new_medium.lua",
			position0 = { x = -100, y = 0, z = 0 }, position1 = { x = 100, y = 0, z = 0 }, node0 = 1, node1 = 2 } } },
		[502] = { box = { -2, 50, 0, 2, 150, 1 }, comps = { BASE_EDGE = { roadType = "TRACK", roadTemplate = "standard.lua",
			position0 = { x = 0, y = 50, z = 0 }, position1 = { x = 0, y = 150, z = 0 } } } },
		[601] = { box = { 20, 10, 0, 35, 25, 12 }, comps = { TOWN_BUILDING = { town = 700, construction = 602 } } },
		[602] = { box = { 20, 10, 0, 35, 25, 12 }, comps = { CONSTRUCTION = { fileName = "building/era_a/res_1.con" } } },
		[603] = { box = { -60, 20, 0, -20, 40, 6 }, name = "Probe Stn",
			comps = { CONSTRUCTION = { fileName = "station/street/bus_station.con", stations = { 9 } } } },
		[604] = { box = { 60, 30, 0, 140, 90, 0.5 }, comps = { FIELD = {} } },
		[605] = { box = { 5, -30, 0, 9, -26, 10 }, comps = { ASSET_GROUP = {} } },
		[606] = { box = { 4, 4, 0, 5, 5, 2 }, comps = { SIM_PERSON = {} } },
		[700] = { box = { -500, -500, 0, 500, 500, 50 }, name = "Chesham", comps = { TOWN = {} } },
		[800] = { box = { 1000, 1000, 0, 1010, 1010, 5 }, comps = { CONSTRUCTION = { fileName = "x.con" } } },
	}
	local function aroundGame(spec)
		local g = newGame({ saves = SAVES })
		spec = spec or {}
		spec.things = spec.things or THINGS
		spec.notInOctree = spec.notInOctree or { [605] = true }
		fake.installAround(g, spec)
		frames(g, 1)
		return g
	end
	local function aroundRun(g, id, argsLua)
		send(g, id, "around", argsLua)
		frames(g, FIRST + 10)
		return final(g, id)
	end
	local function byId(list, id)
		for _, d in ipairs(list or {}) do if d.id == id then return d end end
	end

	test("core.aroundRequest: at, radius, kinds, limit, and what is refused; read only, in a game", function()
		local r = core.aroundRequest({ at = "10,-20" })
		eq(r.x, 10); eq(r.y, -20); eq(r.radius, core.AROUND_RADIUS.default); eq(r.limit, core.AROUND_LIMIT.default)
		eq(r.kinds.street, true); eq(r.kinds.node, nil, "nodes off by default"); eq(r.kinds.moving, nil)
		r = core.aroundRequest({ at = { 1, 2, 3 }, radius = 50, kinds = " station, field ", limit = 5 })
		eq(r.radius, 50); eq(r.limit, 5); eq(r.kinds.station, true); eq(r.kinds.field, true); eq(r.kinds.street, nil)
		r = core.aroundRequest({ at = "0,0", kinds = { "all" } })
		for _, k in ipairs(core.AROUND_KINDS) do eq(r.kinds[k], true, k) end
		for _, bad in ipairs({ { {}, "give at" }, { { at = "1" }, "x,y" }, { { at = "a,1" }, "finite" },
			{ { at = "0,1e9" }, "within" }, { { at = "0,0", radius = 0 }, "radius" },
			{ { at = "0,0", radius = core.AROUND_RADIUS.max + 1 }, "radius" }, { { at = "0,0", radius = "x" }, "radius" },
			{ { at = "0,0", limit = 0 }, "limit" }, { { at = "0,0", limit = 1.5 }, "limit" },
			{ { at = "0,0", kinds = "house" }, "unknown kind" }, { { at = "0,0", kinds = 5 }, "kinds" },
			{ { at = "0,0", kinds = {} }, "kinds" } }) do
			local ok, err = core.aroundRequest(bad[1])
			eq(ok, nil, bad[2]); truthy(tostring(err):find(bad[2], 1, true), tostring(err) .. " / wanted " .. bad[2])
		end
		eq(core.COMMANDS.around, true); eq(core.CHANGES_GAME.around, nil); eq(core.MENU_COMMANDS.around, nil)
	end)

	test("core: distances to a box and a segment, a bbox read, a transf's angle and a point in its frame", function()
		local b = { x0 = 0, y0 = 0, x1 = 10, y1 = 10 }
		eq(core.distToBox(5, 5, b), 0); eq(core.distToBox(13, 14, b), 5); eq(core.distToBox(-3, 5, b), 3)
		eq(core.distToSegment(5, 3, { x = 0, y = 0 }, { x = 10, y = 0 }), 3)
		eq(core.distToSegment(13, 4, { x = 0, y = 0 }, { x = 10, y = 0 }), 5, "past the end: to the end")
		eq(core.distToSegment(3, 4, { x = 0, y = 0 }, { x = 0, y = 0 }), 5, "a point")
		local bx = core.boxOf({ min = { x = 5, y = 1, z = 0 }, max = { x = 2, y = 3, z = 4 } })
		eq(bx.x0, 2); eq(bx.x1, 5); eq(bx.z1, 4)
		eq(core.boxOf(nil), nil); eq(core.boxOf({ min = { x = 0 / 0, y = 0 }, max = { x = 1, y = 1 } }), nil)
		eq(core.transfAngle(1, 0), 0); truthy(math.abs(core.transfAngle(0, 1) - math.pi / 2) < 1e-9)
		eq(core.transfAngle(0, 0), nil); eq(core.transfAngle(nil, 1), nil)
		local l = core.toLocal({ x = 100, y = 200, z = 5, angle = math.pi / 2 }, 100, 210, 6)
		eq(l.dx, 10); eq(l.dy, 0); eq(l.dz, 1, "turned a quarter: its x axis points north")
		l = core.toLocal({ x = 0, y = 0 }, 3, -4)
		eq(l.dx, 3); eq(l.dy, -4); eq(l.dz, nil)
	end)

	test("around: a town's edge: houses, streets, tracks, a station, a field, the town, nearest first, with boxes; nothing sent", function()
		local g = aroundGame()
		local a = aroundRun(g, 2701, '{ at = "0,10", radius = 120 }')
		truthy(a.ok, a.error)
		truthy(a.note:find("guess", 1, true) and a.note:find("trees", 1, true), a.note)
		eq(a.radius, 120); eq(a.at.x, 0)
		local st = byId(a.entities, 501)
		eq(st.kind, "street"); eq(st.template, "town_new_medium.lua"); eq(st.halfWidth, core.AROUND_HALF_WIDTH.street)
		eq(st.dist, 4, "10 m from the line, less its half width"); eq(st.from.x, -100); eq(st.to.x, 100)
		eq(st.box.x0, -100); eq(st.sizeX, 200)
		local tr = byId(a.entities, 502)
		eq(tr.kind, "track"); eq(tr.dist, 40 - core.AROUND_HALF_WIDTH.track)
		local h = byId(a.entities, 601)
		eq(h.kind, "town_building"); eq(h.town, 700); eq(h.townName, "Chesham"); eq(h.construction, 602)
		eq(h.x, 27.5); eq(h.y, 17.5); eq(h.sizeX, 15); eq(h.sizeY, 15); eq(h.height, 12); eq(h.dist, 20)
		local hc = byId(a.entities, 602)
		eq(hc.kind, "town_building", "the house's construction: the town's building"); eq(hc.building, 601)
		eq(hc.townName, "Chesham"); eq(hc.fileName, "building/era_a/res_1.con")
		local s = byId(a.entities, 603)
		eq(s.kind, "station"); eq(s.name, "Probe Stn"); eq(s.stations[1], 9)
		truthy(math.abs(s.dist - math.sqrt(500)) < 1e-9, "20 m west and 10 m north of its corner")
		eq(byId(a.entities, 604).kind, "field")
		local town = byId(a.entities, 700)
		eq(town.kind, "town"); eq(town.name, "Chesham"); eq(town.dist, 0)
		eq(byId(a.entities, 605), nil, "the tree is not in the octree: not listed")
		eq(byId(a.entities, 606), nil, "what moves: off by default")
		eq(byId(a.entities, 800), nil, "far off")
		-- nearest first
		for i = 2, #a.entities do truthy(a.entities[i - 1].dist <= a.entities[i].dist, "sorted") end
		eq(a.counts.town_building, 2); eq(a.counts.street, 1); eq(a.total, #a.entities); eq(a.truncated, false)
		truthy(a.ms and a.ms.total ~= nil and a.ms.octree ~= nil, "the time it took")
		eq(a.scanned, 8, "what the octree gave in the square (not the tree, not the far one)")
		eq(#g.commands, 0, "nothing sent"); truthy(not g.crashed, g.crashed)
	end)

	test("around: the map's own boxes (the map's size, whatever their components) are map, off unless asked", function()
		local things = {}
		for k, v in pairs(THINGS) do things[k] = v end
		-- as a game's entity 2 (kind other, 14,336 m square), and map-sized boxes with TERRAIN / EMISSION_GRID (map by size)
		things[2] = { box = { -7168, -7168, -100, 7168, 7168, 2000 }, comps = {} }
		things[3] = { box = { -7168, -7168, -100, 7168, 7168, 900 }, comps = { TERRAIN = {} } }
		things[4] = { box = { -7168, -7168, 0, 7168, 7168, 1 }, comps = { EMISSION_GRID = {} } }
		-- large but no map: an airport-sized construction stays what it is
		things[5] = { box = { -900, -700, 0, 900, 700, 30 }, comps = { CONSTRUCTION = { fileName = "airport.con" } } }
		local g = aroundGame({ things = things })
		local a = aroundRun(g, 2741, '{ at = "0,10", radius = 120 }')
		truthy(a.ok, a.error)
		eq(byId(a.entities, 2), nil, "the map-sized box: off by default"); eq(byId(a.entities, 3), nil); eq(byId(a.entities, 4), nil)
		eq(byId(a.entities, 5).kind, "construction")
		eq(byId(a.entities, 700).kind, "town", "the town is listed as a town")
		local b = aroundRun(g, 2742, '{ at = "0,10", radius = 120, kinds = "map" }')
		truthy(b.ok, b.error); eq(#b.entities, 3)
		eq(byId(b.entities, 2).kind, "map"); eq(byId(b.entities, 2).mapOf, "other")
		eq(byId(b.entities, 3).kind, "map"); eq(byId(b.entities, 4).kind, "map"); eq(b.counts.map, 3)
		-- a town as large stays a town (fit skips towns by their kind)
		things[6] = { box = { -3000, -3000, 0, 3000, 3000, 50 }, name = "Bigtown", comps = { TOWN = {} } }
		local c = aroundRun(aroundGame({ things = things }), 2744, '{ at = "0,10", radius = 120 }')
		eq(byId(c.entities, 6).kind, "town")
		truthy(not g.crashed, g.crashed)
	end)

	test("around: its ms are read on a clock that moves within the frame (not 0 when the read took time)", function()
		local g = aroundGame()
		g.clockStepUs = 2000 -- 2 ms each time the clock is read
		local a = aroundRun(g, 2743, '{ at = "0,10", radius = 120 }')
		truthy(a.ok, a.error)
		truthy(a.ms.octree > 0 and a.ms.classify > 0 and a.ms.total >= a.ms.octree + a.ms.classify, a.ms.total)
	end)

	test("around: kinds, all, limit, a small radius, an octree that raises, bad arguments", function()
		local g = aroundGame()
		local a = aroundRun(g, 2711, '{ at = "0,10", radius = 120, kinds = "station,field" }')
		truthy(a.ok, a.error); eq(#a.entities, 2); eq(a.entities[1].id, 603); eq(a.entities[2].id, 604)
		eq(a.kinds[1], "station")
		local b = aroundRun(g, 2712, '{ at = "0,10", radius = 120, kinds = "all" }')
		eq(byId(b.entities, 606).kind, "moving"); eq(byId(b.entities, 606).component, "SIM_PERSON")
		local c = aroundRun(g, 2713, '{ at = "0,10", radius = 120, limit = 2 }')
		eq(#c.entities, 2); eq(c.truncated, true); truthy(c.total > 2)
		local d = aroundRun(g, 2714, '{ at = "27,17", radius = 1 }')
		eq(#d.entities, 3, "the house, its construction and the town"); eq(d.entities[1].dist, 0)
		local x = aroundRun(g, 2715, '{ at = "0,10", radius = 0 }')
		eq(x.ok, false); truthy(x.error:find("radius"), x.error)
		local r = aroundGame({ octreeRaises = true })
		local e = aroundRun(r, 2716, '{ at = "0,0" }')
		eq(e.ok, false); truthy(e.error:find("octree"), e.error)
		truthy(not g.crashed, g.crashed)
	end)

	test("build refused: what it collided with, by kind, name, place and box; around there lists the same id", function()
		local g = buildWorld({ blocked = function(x) return x > 1000 and 601 or nil end })
		fake.installAround(g, { things = THINGS })
		local a = buildRun(g, 2721, string.format('{ res = %q, at = "2000,0" }', RAMP))
		eq(a.ok, false); eq(a.collisions[1], 601)
		eq(#a.hits, 1)
		local h = a.hits[1]
		eq(h.id, 601); eq(h.kind, "town_building"); eq(h.townName, "Chesham"); eq(h.x, 27.5); eq(h.box.x1, 35)
		truthy(h.dist and h.dist > 1900, "the distance from the point asked")
		-- the acceptance: around at the house finds the id the refusal named
		send(g, 2723, "around", '{ at = "27,17", radius = 30 }')
		frames(g, FIRST + 10)
		local c = final(g, 2723)
		truthy(c.ok, c.error); truthy(byId(c.entities, 601), "the collision's id is in the list")
		truthy(not g.crashed, g.crashed)
		-- (a new fake game replaces the api: after the first one is done with)
		-- an id the engine no longer has: said so, the rest still read
		local g2 = buildWorld({ blocked = function(x) return x > 1000 and 999999 or nil end })
		fake.installAround(g2, { things = THINGS })
		local b = buildRun(g2, 2722, string.format('{ res = %q, at = "2000,0" }', RAMP))
		eq(b.ok, false); eq(b.hits[1].kind, "gone"); truthy(b.hits[1].error:find("no entity"))
		truthy(not g2.crashed, g2.crashed)
	end)

	test("road refused (a build and a dry run's engine check): the hits named from the piece's middle", function()
		local g = roadWorld({ blocked = function(x, y) return y > 1000 and 501 or nil end })
		fake.installAround(g, { things = THINGS })
		local a = roadRun(g, 2731, '{ from = "0,1500", to = "0,1600" }')
		eq(a.ok, false); eq(a.collisions[1], 501); eq(a.hits[1].kind, "street"); eq(a.hits[1].template, "town_new_medium.lua")
		truthy(math.abs(a.hits[1].dist - (1550 - 6)) < 1e-6, tostring(a.hits[1].dist))
		local d = roadRun(g, 2732, '{ from = "0,1500", to = "0,1600", dryRun = true, engineCheck = true }')
		eq(d.ok, false); eq(d.hits[1].id, 501)
		truthy(not g.crashed, g.crashed)
	end)

	test("build / road --remove-buildings and build --join-streets: the Context's gatherBuildings, cleanupStreetGraph", function()
		eq(core.buildRequest({ res = "a.con", at = "0,0", removeBuildings = true, joinStreets = true }).joinStreets, true)
		truthy(select(2, core.buildRequest({ res = "a.con", at = "0,0", joinStreets = "yes" })):find("joinStreets"))
		eq(core.roadRequest({ from = "0,0", to = "10,0", removeBuildings = true }).removeBuildings, true)
		truthy(select(2, core.roadRequest({ from = "0,0", to = "10,0", removeBuildings = 1 })):find("removeBuildings"))
		local g = buildWorld()
		local a = buildRun(g, 2741, string.format('{ res = %q, at = "0,0" }', RAMP))
		truthy(a.ok, a.error)
		local ctx = g.buildCmds[#g.buildCmds].context
		eq(ctx.gatherBuildings, false); eq(ctx.cleanupStreetGraph, false); eq(a.removeBuildings, nil)
		a = buildRun(g, 2742, string.format('{ res = %q, at = "500,0", removeBuildings = true, joinStreets = true }', RAMP))
		truthy(a.ok, a.error)
		ctx = g.buildCmds[#g.buildCmds].context
		eq(ctx.gatherBuildings, true); eq(ctx.cleanupStreetGraph, true); eq(ctx.gatherFields, false)
		eq(a.removeBuildings, true); eq(a.joinStreets, true); truthy(a.contextNote:find("not checked"), a.contextNote)
		local rg = roadWorld()
		local r = roadRun(rg, 2743, '{ from = "0,500", to = "0,600", removeBuildings = true }')
		truthy(r.ok, r.error); eq(rg.buildCmds[#rg.buildCmds].context.gatherBuildings, true); eq(r.removeBuildings, true)
		truthy(not g.crashed, g.crashed)
	end)

	test("--remove-buildings: houses in the way go (buildingsInWay); without it a collision named in hits; dry runs", function()
		truthy(select(2, core.buildRequest({ res = "a.con", at = "0,0", dryRun = true, joinStreets = true })):find("dryRun"))
		local g = buildWorld({ houses = function(x) return x > 1000 and { 601 } or nil end })
		fake.installAround(g, { things = THINGS })
		local a = buildRun(g, 2745, string.format('{ res = %q, at = "2000,0" }', RAMP))
		eq(a.ok, false); eq(a.collisions[1], 601); eq(a.hits[1].kind, "town_building"); eq(a.buildingsInWay, nil)
		local b = buildRun(g, 2746, string.format('{ res = %q, at = "2000,0", removeBuildings = true }', RAMP))
		truthy(b.ok, b.error); eq(b.buildingsInWay[1], 601); eq(b.collisions, nil)
		truthy(not g.crashed, g.crashed)
		-- a road's dry run judged in the engine's own context: said that gatherBuildings did not apply
		local rg = roadWorld()
		local d = roadRun(rg, 2747, '{ from = "0,500", to = "0,600", dryRun = true, engineCheck = true, removeBuildings = true }')
		truthy(d.ok, d.error); eq(d.engineContext, "the build's"); eq(d.removeBuildingsNote, nil)
		truthy(not rg.crashed, rg.crashed)
		-- where only the proposal alone answers: said that gatherBuildings did not apply
		rg = roadWorld({ proposalDataOneArg = true })
		d = roadRun(rg, 2751, '{ from = "0,500", to = "0,600", dryRun = true, engineCheck = true, removeBuildings = true }')
		truthy(d.ok, d.error); truthy(d.engineContext:find("gatherBuildings true", 1, true), d.engineContext)
		truthy(d.removeBuildingsNote:find("own context", 1, true), d.removeBuildingsNote)
		truthy(not rg.crashed, rg.crashed)
	end)

	test("build --dry-run --engine-check: the engine's verdict and the box it takes (footprint); nothing built", function()
		eq(core.buildRequest({ res = "a.con", at = "0,0", dryRun = true, engineCheck = true }).engineCheck, true)
		truthy(select(2, core.buildRequest({ res = "a.con", at = "0,0", engineCheck = true })):find("dryRun"))
		truthy(select(2, core.buildRequest({ res = "a.con", at = "0,0", dryRun = true, engineCheck = 1 })):find("engineCheck"))
		local g = buildWorld({ blocked = function(x) return x > 1000 and 601 or nil end })
		fake.installAround(g, { things = THINGS })
		local calls = g.proposalDataCalls
		local a = buildRun(g, 2748, string.format('{ res = %q, at = "100,50", angle = %s, dryRun = true, engineCheck = true }',
			RAMP, math.pi / 2))
		truthy(a.ok, a.error); eq(a.buildable, true); eq(a.verdict, "buildable"); eq(a.checked, true)
		eq(g.proposalDataCalls, calls + 2, "asked once in each context"); eq(next(g.built), nil, "nothing built"); eq(#g.buildCmds, 0)
		-- the fake's 20 m square, turned a quarter: the same square round the point
		eq(a.footprint.x0, -10); eq(a.footprint.x1, 10); eq(a.footprint.y1, 10); eq(a.footprint.height, 10)
		-- a 40 x 10 box turned 30 degrees: its world box from the four turned corners
		local g3 = buildWorld({ cons = { [RAMP] = { cost = 1, box = { -20, -5, 20, 5, 8 } } } })
		local r3 = buildRun(g3, 2750, string.format('{ res = %q, at = "0,0", angle = %s, dryRun = true, engineCheck = true }',
			RAMP, math.pi / 6))
		truthy(r3.ok, r3.error)
		local hx = 20 * math.cos(math.pi / 6) + 5 * math.sin(math.pi / 6)
		local hy = 20 * math.sin(math.pi / 6) + 5 * math.cos(math.pi / 6)
		truthy(math.abs(r3.footprint.x1 - hx) < 1e-6 and math.abs(r3.footprint.y0 + hy) < 1e-6,
			string.format("%g %g / %g %g", r3.footprint.x1, r3.footprint.y0, hx, -hy))
		eq(r3.footprint.height, 8)
		-- (a new fake game replaces the api: g again for what follows)
		g = buildWorld({ blocked = function(x) return x > 1000 and 601 or nil end })
		fake.installAround(g, { things = THINGS })
		local b = buildRun(g, 2749, string.format('{ res = %q, at = "2000,0", dryRun = true, engineCheck = true }', RAMP))
		eq(b.ok, false); eq(b.buildable, false); eq(b.collisions[1], 601); eq(b.hits[1].kind, "town_building")
		truthy(b.error:find("dry run"), b.error)
		truthy(not g.crashed, g.crashed)
	end)

	-- a depot with a stub: its inner end frozen, its mouth 10 m out along its y axis (local 0, -10)
	local DEPOT = "::/depots/road/road_depot.con"
	local function depotWorld()
		local spec = { cons = { [DEPOT] = { cost = 100, depots = 1, shape = { nodes = { { 0, 0, 0 }, { 0, -10, 0 } },
			edges = { { 1, 2 } }, frozenNodes = { 1 } } } },
			roads = { nodes = { [8001] = { x = 100, y = 0, z = 0 }, [8002] = { x = 0, y = 0, z = 0 } },
				edges = { [8100] = { node0 = 8002, node1 = 8001 } } },
			height = function() return 0 end }
		return roadWorld(spec)
	end

	test("build: the mouths' place in the construction's frame, joined, and the old node a mouth took (--join-streets)", function()
		local g = depotWorld()
		-- turned a quarter, at (300, 300): the mouth is local (0, -10), at (310, 300) in the world
		local a = buildRun(g, 2751, string.format('{ res = %q, at = "300,300", angle = %s }', DEPOT, math.pi / 2))
		truthy(a.ok, a.error)
		local d = a.construction
		truthy(math.abs(d.at.angle - math.pi / 2) < 1e-6); eq(d.at.x, 300)
		local m = d.connectable[1]
		eq(m.kind, "mouth"); eq(m["local"].dx, 0); eq(m["local"].dy, -10)
		truthy(math.abs(m.x - 310) < 1e-6, tostring(m.x)); eq(m.joined, nil, "nothing joined to it")
		eq(a.joins[1].node, m.node); eq(a.joins[1].wasThere, false); eq(#a.joins[1].nodesHere, 0)
		-- unturned, its mouth right on the old road's end 8002 (0, 0): without --join-streets a new node beside it
		local b = buildRun(g, 2752, string.format('{ res = %q, at = "0,10" }', DEPOT))
		truthy(b.ok, b.error)
		local j = b.joins[1]
		eq(j.wasThere, false); eq(j.nodesHere[1].node, 8002, "the old node at the same spot, another entity")
		eq(j.nodesHere[1].d, 0); eq(j.nodesHere[1].wasThere, true)
		buildRun(g, 2753, string.format('{ remove = %d }', b.entity))
		-- with it (the fake's guess of the engine): the mouth is the old node, the old road joined to it
		local c = buildRun(g, 2754, string.format('{ res = %q, at = "0,10", joinStreets = true }', DEPOT))
		truthy(c.ok, c.error)
		j = c.joins[1]
		eq(j.node, 8002); eq(j.wasThere, true); eq(j.joined, true); eq(j.joinedPieces[1], 8100); eq(#j.nodesHere, 0)
		truthy(not g.crashed, g.crashed)
	end)

	test("around: a construction's ends and mouths in its own frame (as build's answer)", function()
		local g = depotWorld()
		local a = buildRun(g, 2761, string.format('{ res = %q, at = "300,300" }', DEPOT))
		truthy(a.ok, a.error)
		fake.installAround(g, { things = {} })
		send(g, 2762, "around", '{ at = "300,300", radius = 30 }')
		frames(g, FIRST + 10)
		local r = final(g, 2762)
		truthy(r.ok, r.error)
		local d = byId(r.entities, a.entity)
		eq(d.kind, "depot"); eq(d.place.x, 300); eq(d.mouths[1].kind, "mouth"); eq(d.mouths[1]["local"].dy, -10)
		eq(#d.ends, 2)
		truthy(not g.crashed, g.crashed)
	end)

	-- 2026-11-23 (probe-flat-base, a construction at (2600, 3600) over the map's edge water): the dry run's engine
	-- check said buildable, the build was refused "no message" while the game's log had "ProposalData error: 陸上に配置"
	test("build refused with no message in the callback: what was read, the engine asked again; the dry run's two contexts", function()
		local WET = function(x) return x > 2500 end
		local g = buildWorld({ landOnly = WET, silentCallback = true })
		-- the dry run asks both contexts: the engine's own says buildable, the build's refuses; the stricter wins
		local d = buildRun(g, 2770, string.format('{ res = %q, at = "2600,3600", dryRun = true, engineCheck = true }', RAMP))
		eq(d.ok, false); eq(d.verdict, "refused"); eq(d.contextsDisagree, true); eq(d.engineContext, "the build's")
		eq(d.engineContexts.own.verdict, "buildable"); eq(d.engineContexts.build.verdict, "refused")
		eq(d.engineContexts.build.errors[1], "陸上に配置")
		truthy(d.error:find("would refuse it: 陸上に配置", 1, true), d.error)
		truthy(d.contextsNote:find("the build's context: refused (陸上に配置)", 1, true), d.contextsNote)
		-- the build: its callback has no message; the same proposal asked again gives the engine's reason
		local calls = g.proposalDataCalls
		local a = buildRun(g, 2771, string.format('{ res = %q, at = "2600,3600" }', RAMP))
		eq(a.ok, false); eq(#g.buildCmds, 1); eq(next(g.built), nil)
		truthy(a.error:find("refused it: 陸上に配置 (asked again", 1, true), a.error)
		truthy(a.errorStateRead:find("resultProposalData.errorState: critical true, messages 0, warnings 0, infos 0", 1, true),
			a.errorStateRead)
		eq(a.recheck.form, "SimpleProposal, Context"); eq(a.recheck.build.errors[1], "陸上に配置")
		eq(g.proposalDataCalls, calls + 2, "asked again once in each context")
		-- a refusal with its message (a collision) is not asked again
		local g2 = buildWorld({ blocked = function(x) return x > 1000 and 601 or nil end })
		local b = buildRun(g2, 2772, string.format('{ res = %q, at = "2000,0" }', RAMP))
		eq(b.ok, false); truthy(b.error:find("refused it: Collision", 1, true), b.error); eq(b.recheck, nil)
		eq(g2.proposalDataCalls, 0)
		truthy(b.errorStateRead:find("messages 1", 1, true), b.errorStateRead)
		truthy(not g.crashed, g.crashed); truthy(not g2.crashed, g2.crashed)
	end)

	test("build refused: no message anywhere says which fields were read; infos; no errorState; asked again buildable", function()
		local WET = function(x) return x > 2500 end
		-- refused by the build only: asked again, makeProposalData says buildable; the fields read are named
		local g = buildWorld({ landOnly = WET, landOnlyBuildOnly = true, silentCallback = true })
		local a = buildRun(g, 2773, string.format('{ res = %q, at = "2600,3600" }', RAMP))
		eq(a.ok, false)
		truthy(a.error:find("refused it: no message (resultProposalData.errorState: critical true, messages 0, " ..
			"warnings 0, infos 0)", 1, true), a.error)
		eq(a.recheck.build.verdict, "buildable"); truthy(a.recheckNote:find("proposalLog", 1, true), a.recheckNote)
		-- no errorState at all
		g = buildWorld({ landOnly = WET, landOnlyBuildOnly = true, noErrorState = true })
		a = buildRun(g, 2774, string.format('{ res = %q, at = "2600,3600" }', RAMP))
		eq(a.ok, false); truthy(a.error:find("no message (resultProposalData.errorState: none)", 1, true), a.error)
		-- the reason in infos only
		g = buildWorld({ landOnly = WET, landOnlyBuildOnly = true, infosOnly = true })
		a = buildRun(g, 2775, string.format('{ res = %q, at = "2600,3600" }', RAMP))
		eq(a.ok, false); truthy(a.error:find("refused it: no message; infos: 陸上に配置", 1, true), a.error)
		eq(a.infos[1], "陸上に配置"); eq(a.recheck, nil)
		-- asking again raises (both forms): said, the answer still the refusal
		g = buildWorld({ landOnly = WET, landOnlyBuildOnly = true, silentCallback = true, noSimpleProposalData = true })
		a = buildRun(g, 2776, string.format('{ res = %q, at = "2600,3600" }', RAMP))
		eq(a.ok, false); truthy(a.recheck.raised:find("Proposal expected", 1, true), tostring(a.recheck.raised))
		truthy(a.error:find("no message (", 1, true), a.error)
		-- reading the callback's data raises: nothing read, said so
		g = buildWorld({ landOnly = WET, landOnlyBuildOnly = true, raiseInCallback = true, noSimpleProposalData = true })
		a = buildRun(g, 2777, string.format('{ res = %q, at = "2600,3600" }', RAMP))
		eq(a.ok, false); truthy(a.error:find("no message (resultProposalData: none)", 1, true), a.error)
		truthy(not g.crashed, g.crashed)
	end)

	-- 2026-11-23 (probe-flat-base): road_depot at (0, 3600) over water. The engine check said buildable,
	-- critical false in both contexts, with infos "陸上に配置" and 6 collisions; the build was refused, its errorState
	-- critical false with the same infos. infos with critical not set are a refusal (by the field, not the words)
	test("build / road --dry-run --engine-check: infos only (critical not set) refuse it; without infos as before", function()
		local WET = function(x, y) return y > 3000 end
		local g = buildWorld({ landInfos = WET })
		local d = buildRun(g, 2790, string.format('{ res = %q, at = "0,3600", dryRun = true, engineCheck = true }', RAMP))
		eq(d.ok, false); eq(d.buildable, false); eq(d.verdict, "refused"); eq(d.critical, nil, "the engine's critical kept")
		eq(d.infosRefusal, true); eq(d.infos[1], "陸上に配置")
		truthy(d.error:find("would refuse it: 陸上に配置 (errorState.infos, critical not set", 1, true), d.error)
		eq(d.engineContexts.own.verdict, "refused"); eq(d.engineContexts.build.verdict, "refused")
		eq(d.engineContexts.build.infosRefusal, true); eq(d.contextsDisagree, nil)
		truthy(d.footprint, "the box still given (fit takes its box from it)")
		eq(#g.buildCmds, 0, "nothing sent")
		-- the build: refused as the engine does, its reason the infos
		local a = buildRun(g, 2791, string.format('{ res = %q, at = "0,3600" }', RAMP))
		eq(a.ok, false); truthy(a.error:find("refused it: no message; infos: 陸上に配置", 1, true), a.error)
		eq(next(g.built), nil)
		-- on land: no infos, as before (buildable, no infosRefusal)
		d = buildRun(g, 2792, string.format('{ res = %q, at = "0,100", dryRun = true, engineCheck = true }', RAMP))
		truthy(d.ok, d.error); eq(d.verdict, "buildable"); eq(d.buildable, true); eq(d.infosRefusal, nil); eq(d.infos, nil)
		-- infos in the engine's own context only (the Context form raises): refused all the same
		local g1 = buildWorld({ landInfos = WET, proposalDataOneArg = true })
		d = buildRun(g1, 2793, string.format('{ res = %q, at = "0,3600", dryRun = true, engineCheck = true }', RAMP))
		eq(d.ok, false); eq(d.verdict, "refused"); eq(d.engineCheck, "makeProposalData (SimpleProposal)"); eq(d.caution, nil)
		-- a road over water: the same
		local r = roadWorld({ landInfos = WET })
		local a2 = roadRun(r, 2794, '{ from = "0,3500", to = "0,3600", dryRun = true, engineCheck = true }')
		eq(a2.ok, false); eq(a2.verdict, "refused"); eq(a2.infosRefusal, true)
		truthy(a2.error:find("陸上に配置 (errorState.infos", 1, true), a2.error)
		a2 = roadRun(r, 2795, '{ from = "0,500", to = "0,600", dryRun = true, engineCheck = true }')
		truthy(a2.ok, a2.error); eq(a2.verdict, "buildable"); eq(a2.infosRefusal, nil)
		truthy(not g.crashed, g.crashed); truthy(not g1.crashed, g1.crashed); truthy(not r.crashed, r.crashed)
	end)

	-- only one context with infos (the build's refuses, the engine's own does not): the stricter, the infos named
	-- in contextsNote; a build refused with no message asked again picks the infos refusal
	test("engine-check: infos in the build's context only; the recheck of a silent refusal takes infos", function()
		local WET = function(x, y) return y > 3000 end
		local g = buildWorld({ landInfos = WET, landInfosBuildOnly = true })
		local d = buildRun(g, 2796, string.format('{ res = %q, at = "0,3600", dryRun = true, engineCheck = true }', RAMP))
		eq(d.ok, false); eq(d.verdict, "refused"); eq(d.contextsDisagree, true)
		eq(d.engineContexts.own.verdict, "buildable"); eq(d.engineContexts.build.verdict, "refused")
		truthy(d.contextsNote:find("the build's context: refused (infos: 陸上に配置)", 1, true), d.contextsNote)
		-- the build's callback silent: asked again, the infos are its reason
		g = buildWorld({ landInfos = WET, silentCallback = true })
		local a = buildRun(g, 2797, string.format('{ res = %q, at = "0,3600" }', RAMP))
		eq(a.ok, false); truthy(a.error:find("refused it: no message; infos: 陸上に配置 (asked again", 1, true), a.error)
		-- the other way round: infos in the engine's own context only, the build's buildable: the stricter (own)
		g = buildWorld({ landInfos = WET, landInfosOwnOnly = true })
		d = buildRun(g, 2798, string.format('{ res = %q, at = "0,3600", dryRun = true, engineCheck = true }', RAMP))
		eq(d.ok, false); eq(d.verdict, "refused"); eq(d.engineCheck, "makeProposalData (SimpleProposal)")
		eq(d.engineContexts.build.verdict, "buildable"); eq(d.engineContexts.own.infosRefusal, true)
		-- and the build there goes through (the fake's build is the build's context): no infosRefusal on its answer
		a = buildRun(g, 2799, string.format('{ res = %q, at = "0,3600" }', RAMP))
		truthy(a.ok, a.error); eq(a.infosRefusal, nil)
		-- critical and infos together: a critical refusal, its message the reason, no infosRefusal
		g = buildWorld({ landInfos = WET, blocked = function(x, y) return y > 3000 and 601 or nil end })
		d = buildRun(g, 2800, string.format('{ res = %q, at = "0,3600", dryRun = true, engineCheck = true }', RAMP))
		eq(d.ok, false); eq(d.critical, true); eq(d.infosRefusal, nil)
		truthy(d.error:find("would refuse it: Collision (dry run", 1, true), d.error)
		-- a road over fields and water: refused for the infos, the fields' warning kept
		local FIELDS = { 9594 }
		local r = roadWorld({ landInfos = WET, fields = function(x, y) if y > 3000 then return FIELDS end end })
		local b = roadRun(r, 2801, '{ from = "0,3500", to = "0,3600", dryRun = true, engineCheck = true, removeFields = true }')
		eq(b.ok, false); eq(b.verdict, "refused"); eq(b.infosRefusal, true); eq(b.warnings[1], "1 fields will be removed")
		truthy(b.error:find("陸上に配置 (errorState.infos", 1, true), b.error)
		truthy(not g.crashed, g.crashed); truthy(not r.crashed, r.crashed)
	end)

	test("build --dry-run --engine-check: refused in the engine's own context only, the stricter verdict", function()
		local g = buildWorld({ landOnly = function(x) return x > 2500 end, landOnlyOwnOnly = true })
		local d = buildRun(g, 2778, string.format('{ res = %q, at = "2600,3600", dryRun = true, engineCheck = true }', RAMP))
		eq(d.ok, false); eq(d.verdict, "refused"); eq(d.contextsDisagree, true)
		eq(d.engineCheck, "makeProposalData (SimpleProposal)"); eq(d.engineContexts.build.verdict, "buildable")
		eq(d.caution, nil)
		-- the build (the build's context) goes through
		local a = buildRun(g, 2779, string.format('{ res = %q, at = "2600,3600" }', RAMP))
		truthy(a.ok, a.error)
		truthy(not g.crashed, g.crashed)
	end)

	test("road refused with no message in the callback: asked again, the engine's reason", function()
		local g = roadWorld({ blocked = function(x, y) return y > 1000 and 4343 or nil end, silentCallback = true })
		local a = roadRun(g, 2780, '{ from = "0,1500", to = "0,1600" }')
		eq(a.ok, false); truthy(a.error:find("refused it: Collision (asked again", 1, true), a.error)
		truthy(a.errorStateRead:find("messages 0", 1, true), a.errorStateRead); eq(a.collisions[1], 4343)
		truthy(not g.crashed, g.crashed)
	end)

	test("build / road refused with no message, asked again: only a refusal is a reason; the engine's own named", function()
		-- the build's context says buildable, the engine's own refuses: its message, named as the own context's
		local g = buildWorld({ landOnly = function(x) return x > 2500 end, landOnlyOwnOnly = true, refuseBuild = true,
			silentCallback = true })
		local a = buildRun(g, 2781, string.format('{ res = %q, at = "2600,3600" }', RAMP))
		eq(a.ok, false)
		truthy(a.error:find("refused it: 陸上に配置 (asked again with makeProposalData, in the engine's own context", 1, true),
			a.error)
		-- a road whose recheck only warns (fields gathered): no reason taken from the warning, a note instead
		local FIELDS = function(x, y) if y > 1000 and y < 1200 then return { 9594 } end end
		local rg = roadWorld({ fields = FIELDS, refuseBuild = true, silentCallback = true })
		local r = roadRun(rg, 2782, '{ from = "60,1000", to = "60,1129.5", removeFields = true }')
		eq(r.ok, false); truthy(r.error:find("refused it: no message (", 1, true), r.error)
		eq(r.recheck.build.verdict, "buildable with warnings"); truthy(r.recheckNote, "a note when asked again finds no refusal")
		eq(rg.buildCmds[#rg.buildCmds].context.gatherFields, true)
		truthy(not g.crashed, g.crashed); truthy(not rg.crashed, rg.crashed)
	end)

	-- 2026-11-26 (probe-flat-base-t2): fit said buildable for a road depot over a road's node (17078) and a piece
	-- just built (33354); the build was refused "衝突" twice. Its dry run: critical false, messages ["衝突"], the two
	-- in collisionEntities. A message with critical not set refuses a build sent without ignoreErrors, so the check
	-- says refused for it too
	test("build / road --dry-run --engine-check: messages with critical not set refuse it, as the build is refused", function()
		local SOFT = function(x, y) return y > 3000 and 17078 or nil end
		local g = buildWorld({ softBlockedCon = SOFT })
		local d = buildRun(g, 2810, string.format('{ res = %q, at = "0,3600", dryRun = true, engineCheck = true }', RAMP))
		eq(d.ok, false); eq(d.buildable, false); eq(d.verdict, "refused"); eq(d.critical, nil, "the engine's critical kept")
		eq(d.errorsRefusal, true); eq(d.errors[1], "衝突"); eq(d.collisions[1], 17078)
		truthy(d.error:find("would refuse it: 衝突 (errorState.messages, critical not set", 1, true), d.error)
		eq(d.engineContexts.own.verdict, "refused"); eq(d.engineContexts.build.verdict, "refused")
		eq(d.engineContexts.build.errorsRefusal, true)
		truthy(d.footprint, "the box still given")
		eq(#g.buildCmds, 0, "nothing sent")
		-- the build there: refused by the engine, as the check said
		local a = buildRun(g, 2811, string.format('{ res = %q, at = "0,3600" }', RAMP))
		eq(a.ok, false); truthy(a.error:find("refused it: 衝突", 1, true), a.error); eq(next(g.built), nil)
		-- away from it: buildable, no errorsRefusal, and it is built
		d = buildRun(g, 2812, string.format('{ res = %q, at = "0,100", dryRun = true, engineCheck = true }', RAMP))
		truthy(d.ok, d.error); eq(d.verdict, "buildable"); eq(d.buildable, true); eq(d.errorsRefusal, nil)
		a = buildRun(g, 2813, string.format('{ res = %q, at = "0,100" }', RAMP))
		truthy(a.ok, a.error); eq(a.errorsRefusal, nil)
		-- critical with messages: a critical refusal, no errorsRefusal
		g = buildWorld({ blocked = function(x, y) return y > 3000 and 601 or nil end })
		d = buildRun(g, 2814, string.format('{ res = %q, at = "0,3600", dryRun = true, engineCheck = true }', RAMP))
		eq(d.ok, false); eq(d.critical, true); eq(d.errorsRefusal, nil)
		truthy(d.error:find("would refuse it: Collision (dry run", 1, true), d.error)
		-- a road piece over a soft collision: its dry run refused too (the build without --ignore-errors is)
		local r = roadWorld({ softBlocked = function(x, y) return y > 1000 and 4343 or nil end })
		local b = roadRun(r, 2815, '{ from = "0,1500", to = "0,1600", dryRun = true, engineCheck = true }')
		eq(b.ok, false); eq(b.verdict, "refused"); eq(b.buildable, false); eq(b.errorsRefusal, true)
		truthy(b.error:find("Collision (errorState.messages, critical not set", 1, true), b.error)
		local rb = roadRun(r, 2816, '{ from = "0,1500", to = "0,1600" }')
		eq(rb.ok, false)
		truthy(not g.crashed, g.crashed); truthy(not r.crashed, r.crashed)
	end)
end
