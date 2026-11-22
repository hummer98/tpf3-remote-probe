-- Tests of the diagnosis of stations --catchment (content/remote_catchment.lua), run by tests/run.lua with its
-- helpers: dofile(...)(t). The engine's side is tests/fake_game.lua (the stations, their catchables) with
-- tests/fake_reach.lua over it (the towns, buildings, the stations' circles and terminals, the walking graph).
return function(t)
	local test, eq, truthy, core = t.test, t.eq, t.truthy, t.core
	local send, frames, final, FIRST, vehicleGame, root = t.send, t.frames, t.final, t.FIRST, t.vehicleGame, t.root
	local C = require "hummer_remote_probe::/remote_catchment.lua"
	local fakeReach = dofile(root .. "/tests/fake_reach.lua")

	test("catchment diagnosis, pure: areas, circles and their frame, the nearest rim, radii, the line", function()
		local a = C.areaOf({ position = { x = 10, y = 20, z = 0 }, radius = 150 }, core)
		eq(a.x, 10); eq(a.y, 20); eq(a.radius, 150)
		a = C.areaOf({ position = { 1, 2, 3 }, radius = 50 }, core); eq(a.x, 1); eq(a.y, 2)
		eq(C.areaOf({ position = { x = 1, y = 2 }, radius = 0 }, core), nil, "no radius")
		eq(C.areaOf({ radius = 10 }, core), nil, "no position"); eq(C.areaOf(nil, core), nil)
		eq(C.areaOf({ position = { x = 0 / 0, y = 1 }, radius = 10 }, core), nil, "nan")
		local u = newproxy(true)
		getmetatable(u).__index = function(_, k) if type(k) == "number" then error("ASSERT: read by number") end end
		eq(C.areaOf({ position = u, radius = 10 }, core), nil, "an engine object is never read by number")
		-- through a transf: turned a quarter (x' = -y, y' = x) and moved to 1000, 0
		local tf = { 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 1000, 0, 0, 1 }
		local x, y = C.transform(tf, 0, 50); eq(x, 950); eq(y, 0)
		local ct = C.circles(5, { { x = 0, y = 50, radius = 60 } }, { x = 1000, y = 0 }, tf)
		eq(ct[1].frame, "construction"); eq(ct[1].x, 950); eq(ct[1].readY, 50)
		ct = C.circles(5, { { x = 990, y = 0, radius = 60 } }, { x = 1000, y = 0 }, tf)
		eq(ct[1].frame, "world", "as read is nearer the station"); eq(ct[1].x, 990)
		eq(C.circles(5, { { x = 0, y = 50, radius = 60 } }, nil, tf)[1].frame, "construction", "no position: the base's frame")
		local cs
		cs = C.circles(5, { { x = 0, y = 0, radius = 150 }, { x = 5000, y = 0, radius = 150 } }, { x = 10, y = 0 })
		eq(cs[1].frame, "world"); eq(cs[2].frame, "station", "far from the station: round it")
		eq(cs[2].x, 10); eq(cs[2].readX, 5000)
		eq(C.circles(5, { { x = 5000, y = 0, radius = 150 } }, nil)[1].frame, "world", "no position: as read")
		local out, c, d = C.nearestCircle({ x = 300, y = 0 }, { { x = 0, y = 0, radius = 150 }, { x = 400, y = 0, radius = 50 } })
		eq(out, 50); eq(c.radius, 50); eq(d, 100)
		eq(C.nearestCircle({ x = 0, y = 0 }, {}), nil)
		eq(C.radiusText({ { radius = 150 } }), "150 m"); eq(C.radiusText({ { radius = 150 }, { radius = 250 } }), "150-250 m")
		eq(C.radiusText({}), nil)
		local base = { circles = { { radius = 150 } }, buildingsRead = 3, townsTotal = 1,
			inCircle = { total = 0, notCaught = 0, residential = 0, commercial = 0, industrial = 0 },
			nearest = { residential = { distance = 312, outside = 162, townName = "Emsworth" } } }
		eq(C.diagnosis(base), "0 town buildings in the circle (150 m); nearest residential 312 m (162 m outside the circle) in Emsworth")
		base.inCircle = { total = 12, notCaught = 12, residential = 12, commercial = 0, industrial = 0 }
		base.walk = { checked = 12, noPath = 12, control = { checked = 0, found = 0 } }
		eq(C.diagnosis(base), "12 town buildings in the circle (150 m: residential 12), 12 not in the engine's catchment; on foot 12 of 12 checked have no path to the station " ..
			"(no caught building to try the search on: a missing path is unverified)")
		base.walk.control = { checked = 2, found = 0 }
		truthy(C.diagnosis(base):find("not to be trusted", 1, true))
		base.walk = { checked = 3, noPath = 1, found = 1, unknown = 1, truncated = "the searches took 310 ms",
			control = { checked = 0, found = 0 } }
		local line = C.diagnosis(base)
		truthy(line:find("on foot 1 of 3 checked have no path to the station (1 with a path, 1 could not be searched)", 1, true), line)
		truthy(line:find("stopped: the searches took 310 ms", 1, true), line)
		truthy(line:find("a missing path is unverified", 1, true), line)
		base.walk = { checked = 2, noPath = 0, found = 0, unknown = 2, control = { checked = 0, found = 0 } }
		line = C.diagnosis(base)
		truthy(line:find("0 of 2 checked have no path to the station (2 could not be searched)", 1, true), line)
		truthy(not line:find("unverified", 1, true), "no missing path: nothing to verify")
		base.inCircle = { total = 2, notCaught = 2, residential = 0, commercial = 0, industrial = 0, unknownKind = 2 }
		base.walk = nil
		truthy(C.diagnosis(base):find("(150 m: unknown kind 2)", 1, true), C.diagnosis(base))
		base.inCircle = { total = 0, notCaught = 0, residential = 0, commercial = 0, industrial = 0 }
		base.nearest = {}
		truthy(C.diagnosis(base):find("no building of a known kind", 1, true), C.diagnosis(base))
		base.inCircle = { total = 1, notCaught = 0, residential = 0, commercial = 1, industrial = 0 }
		base.cargoOnly = true
		truthy(C.diagnosis(base):find("all in the engine's cargo catchment", 1, true), C.diagnosis(base))
		base.cargoOnly = nil
		base.inCircle.notCaught = 0
		truthy(C.diagnosis(base):find("all in the engine's catchment", 1, true))
		eq(C.diagnosis({ buildingsRead = 0, townsTotal = 0 }), "no towns on the map: nothing to catch but industries")
		truthy(C.diagnosis({ circles = {}, buildingsRead = 1, townsTotal = 1, nearest = { commercial = { distance = 80 } } })
			:find("no catchment circle read", 1, true))
	end)

	-- Emsworth (11) round 0,0: 1101 a house at 60,0 (no walking link), 1102 a house at -80,40 (caught, linked),
	-- 1103 a shop at 130,0 (not caught, linked), 1104 a works at -400,0; 1105 a house far away at 400,1000.
	-- Stations: Edge (61/611) at 0,0 with a 150 m circle; Far (62/621) at 522,0 with 150 m; Harbour (63/631) with two
	-- circles, 150 m at 0,1000 and 250 m at 200,1000; Bare (64/641) at 0,-2000 with none; Odd (65/651) at 0,3000
	-- whose circle reads as 0,0 (taken round the station)
	local function world(extra)
		extra = extra or {}
		local w = {
			stationGroups = {
				[61] = { name = "Edge", stations = { { id = 611, passenger = true, pos = { 0, 0 } } } },
				[62] = { name = "Far", stations = { { id = 621, passenger = true, pos = { 522, 0 } } } },
				[63] = { name = "Harbour", stations = { { id = 631, passenger = true, pos = { 100, 1000 } } } },
				[64] = { name = "Bare", stations = { { id = 641, passenger = true, pos = { 0, -2000 } } } },
				[65] = { name = "Odd", stations = { { id = 651, passenger = true, pos = { 0, 3000 } } } },
				[66] = { name = "Turned", stations = { { id = 661, passenger = true, pos = { -3000, 0 } } } },
				[67] = { name = "Goods", stations = { { id = 671, kind = "cargo", pos = { 0, 0 } } } },
			},
			catchables = { [611] = { passengers = { 1102 } }, [631] = { passengers = { 1105 } }, [671] = { cargo = { 1103 } } },
		}
		local g = vehicleGame(w)
		local spec = {
			towns = extra.noTowns and {} or { [11] = "Emsworth", [12] = "Westbourne", [13] = extra.unplacedTown and "Nowhere" or nil },
			buildings = extra.noTowns and {} or {
				[1101] = { town = 11, kind = "RESIDENTIAL", capacity = 10, personNodes = { "800:1" } },
				[1102] = { town = 11, kind = "RESIDENTIAL", capacity = 6, personNodes = { "800:2" } },
				[1103] = { town = 11, kind = "COMMERCIAL", capacity = 4, personNodes = { "800:3" } },
				[1104] = { town = 11, kind = "INDUSTRIAL", capacity = 8, personNodes = { "800:4" } },
				[1105] = { town = 11, kind = "RESIDENTIAL", capacity = 3, personNodes = { "800:5" } },
				[1106] = { town = 11, kind = "RESIDENTIAL", capacity = 3, personNodes = { "800:6" } },
				[1201] = { town = 12, kind = "RESIDENTIAL", capacity = 3, personNodes = { "810:1" } },
				[1301] = extra.unplacedTown and { town = 13, kind = "COMMERCIAL", capacity = 3 } or nil,
			},
			stations = {
				[611] = { terminals = { { personNodes = { "800:9" } } }, catchmentAreas = { { 0, 0, 150 } } },
				[621] = { terminals = { { personNodes = { "801:9" } } }, catchmentAreas = { { 522, 0, 150 } } },
				[631] = { terminals = { { personNodes = { "802:9" } } }, catchmentAreas = { { 0, 1000, 150 }, { 200, 1000, 250 } } },
				[641] = { terminals = { { personNodes = { "803:9" } } } },
				[651] = { terminals = { { personNodes = { "804:9" } } }, catchmentAreas = { { 0, 0, 150 } } },
				-- a side building's 60 m circle, as the base gives it: in the construction's frame
				[661] = { terminals = { { personNodes = { "805:9" } } }, catchmentAreas = { { 0, 50, 60 } } },
				[671] = { terminals = { { cargo = true } }, catchmentAreas = { { 0, 0, 150 } } },
			},
			positions = { [11] = { 0, 0 }, [1101] = { 60, 0 }, [1102] = { -80, 40 }, [1103] = { 130, 0 }, [1104] = { -400, 0 },
				[1105] = { 400, 1000 }, [611] = { 0, 0 }, [621] = { 522, 0 }, [631] = { 100, 1000 }, [641] = { 0, -2000 },
				[651] = { 0, 3000 }, [661] = { -3000, 0 }, [671] = { 0, 0 }, [1106] = { -3080, 0 }, [12] = { 6000, 0 },
				[1201] = { 6000, 0 }, [1301] = { -20, 0 } },
			-- 661's construction turned a quarter and moved to -3000, 0: its circle's centre is -3050, 0
			constructions = { [6601] = { stations = { 661 }, transf = { 0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, -3000, 0, 0, 1 } } },
			stationConstruction = { [661] = 6601 },
			graph = { walk = { ["800:2"] = { "800:9" }, ["800:3"] = { "800:9" } } },
			userdata = extra.userdata, areaShape = extra.areaShape, pathError = extra.pathError,
		}
		fakeReach.install(g, spec)
		return g
	end
	local nextId = 5000
	local function run(g, argsLua, first)
		nextId = nextId + 1
		send(g, nextId, "stations", argsLua)
		frames(g, first and FIRST or 20)
		return final(g, nextId)
	end

	test("stations --catchment: houses in the circle the engine does not count, and which of them have no path on foot", function()
		local g = world()
		local a = run(g, "{ catchment = 61 }", true)
		eq(a.ok, true, tostring(a.error))
		local c = a.catchment
		eq(c.passengers.towns[1].buildings, 1, "the counts as before: the engine's catchables")
		eq(c.radiusSource, C.SOURCE_ENGINE); eq(#c.circles, 1); eq(c.circles[1].radius, 150); eq(c.circles[1].frame, "world")
		eq(c.circles[1].station, 611)
		local n = c.near
		eq(n.buildingsRead, 7); eq(n.townsTotal, 2); eq(n.towns[1].name, "Emsworth"); eq(n.towns[2].name, "Westbourne")
		eq(n.towns[1].distance, 0); eq(n.towns[2].distance, 6000, "nearest first")
		eq(n.inCircle.total, 3); eq(n.inCircle.residential, 2); eq(n.inCircle.commercial, 1); eq(n.inCircle.caught, 1)
		eq(n.inCircle.notCaught, 2)
		eq(n.notCaught[1].building, 1101, "the deepest in the circle first"); eq(n.notCaught[1].walk, "none")
		eq(n.notCaught[2].building, 1103); eq(n.notCaught[2].walk, "path")
		eq(n.walk.checked, 2); eq(n.walk.noPath, 1); eq(n.walk.found, 1)
		eq(n.walk.control.checked, 1); eq(n.walk.control.found, 1, "the caught house has its path")
		eq(n.nearest.residential.outside, -90); eq(n.nearest.industrial.outside, 250); eq(n.nearest.industrial.townName, "Emsworth")
		eq(c.diagnosis, "3 town buildings in the circle (150 m: residential 2, commercial 1), 2 not in the engine's catchment; " ..
			"on foot 1 of 2 checked have no path to the station (1 with a path)")
		eq(g.crashed, nil)
		-- paths 0: no search
		local before = g.reachCalls.path
		local b = run(g, "{ catchment = 61, paths = 0 }")
		eq(b.ok, true, tostring(b.error)); eq(b.catchment.near.walk.checked, 0); eq(g.reachCalls.path, before)
		truthy(b.catchment.diagnosis:find("no walking check", 1, true), b.catchment.diagnosis)
		-- paths 1: one search for the not-caught, plus the control
		local p = run(g, "{ catchment = 61, paths = 1 }")
		eq(p.catchment.near.walk.checked, 1); eq(g.reachCalls.path, before + 2)
	end)

	test("stations --catchment: a station 300 m off the town says the circle is empty and how far the nearest are", function()
		local g = world()
		local a = run(g, "{ catchment = 62 }", true)
		eq(a.ok, true, tostring(a.error))
		local c = a.catchment
		eq(c.near.inCircle.total, 0); eq(c.passengers.entities, 0)
		eq(c.near.nearest.residential.building, 1101); eq(c.near.nearest.residential.distance, 462)
		eq(c.near.nearest.residential.outside, 312); eq(c.near.nearest.commercial.outside, 242)
		eq(c.diagnosis, "0 town buildings in the circle (150 m); nearest residential 462 m (312 m outside the circle) in Emsworth, " ..
			"nearest commercial 392 m (242 m outside the circle) in Emsworth, nearest industrial 922 m (772 m outside the circle) in Emsworth")
		eq(c.near.walk.checked, 0, "nothing to walk from"); eq(g.reachCalls.path, 0)
		eq(g.crashed, nil)
	end)

	test("stations --catchment: two circles of a harbour, a station with none (and --radius), one read far off", function()
		for _, shape in ipairs({ "vec", "list" }) do
			local g = world({ areaShape = shape })
			local a = run(g, "{ catchment = 63 }", true)
			eq(a.ok, true, tostring(a.error))
			local c = a.catchment
			eq(#c.circles, 2); eq(c.circles[2].radius, 250)
			eq(c.near.inCircle.total, 1, "the house 200 m from the second circle's centre"); eq(c.near.inCircle.caught, 1)
			truthy(c.diagnosis:find("(150-250 m: residential 1), all in the engine's catchment", 1, true), c.diagnosis)
			eq(g.crashed, nil, shape)
		end
		local g = world()
		local b = run(g, "{ catchment = 64 }", true)
		eq(b.ok, true, tostring(b.error)); eq(#b.catchment.circles, 0)
		truthy(b.catchment.radiusSource:find("none", 1, true)); truthy(b.catchment.diagnosis:find("no catchment circle read", 1, true))
		eq(b.catchment.near.nearest.residential.outside, nil); eq(b.catchment.near.nearest.residential.distance, 2001)
		local r = run(g, "{ catchment = 64, radius = 200 }")
		eq(r.catchment.radiusSource, C.SOURCE_GIVEN); eq(r.catchment.circles[1].radius, 200)
		truthy(r.catchment.diagnosis:find("0 town buildings in the circle (200 m)", 1, true), r.catchment.diagnosis)
		local o = run(g, "{ catchment = 651 }")
		eq(o.ok, true, tostring(o.error)); eq(o.catchment.circles[1].frame, "station"); eq(o.catchment.circles[1].y, 3000)
		eq(o.catchment.near.inCircle.total, 0, "round the station, not round 0,0")
		eq(g.crashed, nil)
	end)

	test("stations --catchment: no towns on the map; a walking search that raises; bad radius and paths", function()
		local g = world({ noTowns = true })
		local a = run(g, "{ catchment = 61 }", true)
		eq(a.ok, true, tostring(a.error)); eq(a.catchment.near.townsTotal, 0); eq(a.catchment.near.buildingsRead, 0)
		eq(a.catchment.diagnosis, "no towns on the map: nothing to catch but industries")
		local h = world({ pathError = true })
		local b = run(h, "{ catchment = 61 }", true)
		eq(b.ok, true, tostring(b.error)); eq(b.catchment.near.walk.unknown, 2)
		truthy(tostring(b.catchment.near.notCaught[1].why):find("path boom", 1, true))
		for _, bad in ipairs({ "{ catchment = 61, radius = 0 }", "{ catchment = 61, radius = 2001 }", "{ catchment = 61, paths = -1 }",
			"{ catchment = 61, paths = 51 }", "{ catchment = 61, paths = 1.5 }" }) do
			local x = run(h, bad)
			eq(x.ok, false, bad)
		end
		eq(h.crashed, nil)
	end)

	test("stations --catchment: the buildings read stop at BUILDINGS_READ, the towns at TOWNS_READ", function()
		local g = world()
		local keepB, keepT = C.BUILDINGS_READ, C.TOWNS_READ
		C.BUILDINGS_READ = 2
		local ok, err = pcall(function()
			local a = run(g, "{ catchment = 61 }", true)
			eq(a.ok, true, tostring(a.error)); eq(a.catchment.near.buildingsRead, 2); eq(a.catchment.near.truncated, true)
			C.BUILDINGS_READ, C.TOWNS_READ = keepB, 0
			local b = run(g, "{ catchment = 61 }")
			eq(b.catchment.near.buildingsRead, 0); eq(#b.catchment.near.towns, 0)
		end)
		C.BUILDINGS_READ, C.TOWNS_READ = keepB, keepT
		assert(ok, err)
	end)
	test("stations --catchment: a circle in its construction's frame, a cargo station, a town with no position", function()
		local g = world()
		-- the side building's circle read as 0,50: through the construction's transf at -3050,0; the house at -3080,0
		-- is 30 m from it (and 80 m from the station's box centre: out of 60 m were the circle taken round that)
		local a = run(g, "{ catchment = 66 }", true)
		eq(a.ok, true, tostring(a.error))
		local c = a.catchment
		eq(c.circles[1].frame, "construction"); eq(c.circles[1].x, -3050); eq(c.circles[1].readY, 50)
		eq(c.near.inCircle.total, 1); eq(c.near.notCaught[1].building, 1106)
		truthy(c.diagnosis:find("(60 m: residential 1)", 1, true), c.diagnosis)
		-- a cargo station: held against its cargo catchables, no walking
		local before = g.reachCalls.path
		local k = run(g, "{ catchment = 67 }")
		eq(k.ok, true, tostring(k.error)); eq(k.catchment.near.cargoOnly, true)
		eq(k.catchment.near.inCircle.caught, 1, "the shop by its stock list"); eq(k.catchment.near.inCircle.notCaught, 2)
		eq(k.catchment.near.walk.checked, 0); eq(g.reachCalls.path, before)
		truthy(k.catchment.diagnosis:find("2 not in the engine's cargo catchment; no walking check: a cargo station", 1, true),
			k.catchment.diagnosis)
		-- only the nearest town is read when TOWNS_READ is 1; every town when one has no position
		local keep = C.TOWNS_READ
		local ok, err = pcall(function()
			C.TOWNS_READ = 1
			local one = run(g, "{ catchment = 61, paths = 0 }")
			eq(#one.catchment.near.towns, 1); eq(one.catchment.near.towns[1].name, "Emsworth")
			local h = world({ unplacedTown = true })
			local u = run(h, "{ catchment = 61, paths = 0 }", true)
			eq(u.catchment.near.townsUnplaced, 1); eq(#u.catchment.near.towns, 3, "all read")
			eq(u.catchment.near.towns[3].name, "Nowhere", "the town with no position last")
			eq(u.catchment.near.inCircle.commercial, 2, "its shop at -20,0 counted"); eq(h.crashed, nil)
		end)
		C.TOWNS_READ = keep
		assert(ok, err)
		eq(g.crashed, nil)
	end)
end
