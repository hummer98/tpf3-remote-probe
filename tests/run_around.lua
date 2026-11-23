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
		truthy(d.ok, d.error); truthy(d.engineContext:find("gatherBuildings true", 1, true), d.engineContext)
		truthy(d.removeBuildingsNote:find("own context", 1, true), d.removeBuildingsNote)
		truthy(not rg.crashed, rg.crashed)
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
end
