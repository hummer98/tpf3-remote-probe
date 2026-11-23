-- Tests of reach (content/remote_reach.lua) and persons --town / --destination, run by tests/run.lua with its
-- helpers: dofile(...)(t). The engine's side is tests/fake_reach.lua.
return function(t)
	local test, eq, truthy, fake, core = t.test, t.eq, t.truthy, t.fake, t.core
	local newGame, send, frames, final, FIRST, SAVES = t.newGame, t.send, t.frames, t.final, t.FIRST, t.SAVES
	local root = t.root
	local R = require "hummer_remote_probe::/remote_reach.lua"
	local fakeReach = dofile(root .. "/tests/fake_reach.lua")

	test("reach args: the five forms, one at a time, and what is refused", function()
		eq(R.args({ api = true }).form, "api"); eq(R.args({ problems = true }).form, "problems")
		local a = R.args({ target = 51 }); eq(a.form, "target"); eq(a.target, 51)
		a = R.args({ town = "11", limit = 0 }); eq(a.town, 11); eq(a.limit, 0)
		a = R.args({ from = 41, to = "51" })
		eq(a.form, "path"); eq(a.from.entity, 41); eq(a.to.entity, 51); eq(#a.modes, 2); eq(a.radius, R.RADIUS_DEFAULT)
		a = R.args({ from = "-100.5, 20", to = { 3, 4 }, mode = "walk", radius = 500 })
		eq(a.from.x, -100.5); eq(a.from.y, 20); eq(a.to.x, 3); eq(a.to.y, 4); eq(a.modes[1], "walk"); eq(#a.modes, 1)
		eq(a.radius, 500)
		a = R.args({ from = 1, to = 2, mode = "lines" }); eq(#a.modes, 0); eq(a.linesOnly, true)
		local bad = { { {}, "give one of" }, { nil, "give one of" }, { { api = true, target = 1 }, "one form at a time" },
			{ { target = -1 }, "target must be" }, { { target = 1.5 }, "target must be" }, { { town = "x" }, "town must be" },
			{ { town = 1, limit = 201 }, "limit must be" }, { { town = 1, limit = -1 }, "limit must be" },
			{ { from = 1 }, "both from and to" }, { { to = 1 }, "both from and to" },
			{ { from = "a,b", to = 1 }, "from must be" }, { { from = 1, to = "1,2,3" }, "to must be" },
			{ { from = 1, to = "nan,1" }, "to must be" }, { { from = 1, to = 2, mode = "fly" }, "mode must be" },
			{ { from = 1, to = 2, radius = 0 }, "radius must be" }, { { from = 1, to = 2, radius = 501 }, "radius must be" },
			{ { api = "yes" }, "give one of" } }
		for _, b in ipairs(bad) do
			local ok, err = R.args(b[1])
			truthy(ok == nil and err and err:find(b[2], 1, true), tostring(err) .. " (wanted " .. b[2] .. ")")
		end
		truthy(select(2, R.args({ target = 1, limit = 3 })):find("limit goes with town"))
		eq(core.COMMANDS.reach, true); eq(core.CHANGES_GAME.reach, nil); eq(core.MENU_COMMANDS.reach, nil)
	end)

	test("reach shapes: target lists (targets field, a list, keys from 0), guesses, edges, counts, town problems", function()
		local lists, how = R.targetLists({ targets = { { entries = { { entity = 1 } } }, { entries = {} } } }, core)
		eq(#lists, 2); eq(how, "targets/pairs"); eq(lists[1].key, 1)
		lists, how = R.targetLists({ [0] = { entries = {} }, [1] = { entries = {} }, [2] = { entries = {} } }, core)
		eq(#lists, 3); eq(how, "top/pairs"); eq(lists[1].key, 0, "a table keyed by the land use value: in key order")
		eq(#R.targetLists(nil, core), 0)
		eq(R.landUseGuess(1, 2), "commercial"); eq(R.landUseGuess(2, 2), "industrial"); eq(R.landUseGuess(1, 3), "residential")
		eq(R.landUseGuess(1, 4), nil)
		local idx = R.targetIndex({ targets = { { entries = { { entity = 5 }, { entity = 6 } } }, { { entity = 5 } } } }, core)
		eq(idx.total, 3); eq(#idx.byEntity[5], 2, "an entity in both lists"); eq(idx.byEntity[5][2].key, 2)
		eq(idx.lists[2].entries, 1, "a TargetData that is itself the list of entries")
		eq(R.targetIndex({}, core).total, 0)
		eq(R.edgeOf({ 7, 3 }, core).entity, 7); eq(R.edgeOf({ entity = 7, index = 0 }, core).index, 0)
		eq(R.edgeOf({ -1, -1 }, core), nil, "no edge"); eq(R.edgeOf(nil, core), nil)
		local p = R.entryPlain({ entity = 9, isReachableWalk = true }, core)
		eq(p.entity, 9); eq(p.isReachableWalk, true); eq(p.isReachableLines, nil, "a field that is not there stays out")
		local c = R.reachCounts({ { isReachableWalk = true, isReachableDrive = true }, { isReachableWalk = false, isReachableDrive = false,
			isReachableLines = false }, {} })
		eq(c.targets, 3); eq(c.walk, 1); eq(c.drive, 1); eq(c.lines, 0); eq(c.none, 1); eq(c.unknown, 1)
		eq(R.reachCounts(nil).targets, 0)
		local tp = R.townProblems({ { { 11, 12 }, 0 }, { towns = { 13 }, problem = 1 } }, core, function(v) return v == 0 and "Disconnected" or "Overlength" end)
		eq(#tp, 2); eq(tp[1].towns[2], 12); eq(tp[1].problem, "Disconnected"); eq(tp[2].towns[1], 13); eq(tp[2].problem, "Overlength")
		eq(#R.townProblems(nil, core), 0)
		local s = core.reachSummary({ { reachable = { walkDrive = { 3, 0 }, lines = { 0, 0 } } },
			{ reachable = { walkDrive = { 0, 0 }, lines = { 0, 0 } } }, { reachable = { walkDrive = { 1, 2 }, lines = { 0, 1 } } }, {} })
		eq(s.persons, 3); eq(s.walkDrive[1], 2); eq(s.walkDrive[2], 1); eq(s.lines[2], 1); eq(s.none, 1)
		eq(core.reachSummary({ {} }), nil, "nobody with the counts: nothing"); eq(core.reachSummary(nil), nil)
	end)

	-- Emsworth (11): homes 1101 (its own PERSON_CAPACITY) and 1102 (through its PersonCapacity entity 1192), a shop
	-- 1103 (reachable walking), an industrial building 1104 that is no target; Empty (12): no buildings. Quarry A
	-- (51, construction 5100, closest town 11): a target out of reach every way, its walking edge on network 700,
	-- its driving edge on 702; 52: an industry without workplaces. Station 4100: people wait on 701:0, vehicles stop
	-- at 701:1. Walking 701:0 -> 701:1 only; driving 701:1 -> 702:0. Point (0, 0) has node 701:0.
	local function reachSpec(extra)
		local s = {
			towns = { [11] = "Emsworth", [12] = "Empty" },
			buildings = { [1101] = { town = 11, kind = "RESIDENTIAL", capacity = 10 },
				[1102] = { town = 11, kind = "RESIDENTIAL", capacity = 8, pc = 1192 },
				[1103] = { town = 11, kind = "COMMERCIAL", capacity = 5 }, [1104] = { town = 11, kind = "INDUSTRIAL", capacity = 4 } },
			industries = { [51] = { name = "Quarry A", construction = 5100, capacity = 20 }, [52] = { name = "Depot" } },
			constructions = { [5100] = { industries = { 51 }, town = 11 } },
			targets = { { entries = { { entity = 1103, capacity = 5, walk = true, edgeWalk = { 701, 0 } } } },
				{ entries = { { entity = 51, capacity = 20, walk = false, drive = false, lines = false, edgeWalk = { 700, 0 },
					edgeDrive = { 702, 0 } } } } },
			tn = { [700] = { edges = { { 0, 1 } } }, [701] = { edges = { { 0, 1 } } }, [702] = { edges = { { 0, 1 } } } },
			graph = { walk = { ["701:0"] = { "701:1" } }, drive = { ["701:1"] = { "702:0" } } },
			stations = { [4100] = { terminals = { { personNodes = { "701:0" }, vehicleNode = "701:1" } } } },
			circle = { { 0, 0, node = "701:0" } },
			problems = { { towns = { 11, 12 }, problem = "Disconnected" } },
			persons = { [9001] = { home = 1101, walkDrive = { 3, 0 }, lines = { 0, 0 } },
				[9002] = { home = 1192, walkDrive = { 2, 1 }, lines = { 0, 1 } },
				[9003] = { destinations = { 1101, 1103, 51 }, walkDrive = { 1, 1 }, lines = { 0, 0 } },
				[9004] = { home = 1101 } },
		}
		for k, v in pairs(extra or {}) do s[k] = v end
		return s
	end
	local function reachGame(extra)
		local g = newGame({ saves = SAVES })
		fakeReach.install(g, reachSpec(extra))
		frames(g, 1)
		return g
	end
	local nextId = 3000
	local function run(g, cmd, argsLua, first)
		nextId = nextId + 1
		send(g, nextId, cmd, argsLua)
		frames(g, first and FIRST or 20)
		return final(g, nextId)
	end

	test("reach --target: an industry out of reach every way, its town's problem; by its construction too", function()
		local g = reachGame()
		local guiBefore = core.json(fake.guiSave)
		local a = run(g, "reach", "{ target = 51 }", true)
		truthy(a.ok, a.error); truthy(a.note:find("not checked in a game"), a.note)
		eq(a.found, true); eq(#a.entries, 1); eq(a.landUse, "industrial"); eq(a.capacity, 20)
		local e = a.entries[1]
		eq(e.entity, 51); eq(e.isReachableWalk, false); eq(e.isReachableDrive, false); eq(e.isReachableLines, false)
		eq(e.landUseKey, 2); eq(e.landUseGuess, "industrial"); eq(e.edgeWalk.entity, 700); eq(e.edgeWalk.index, 0)
		eq(a.counts.none, 1); eq(a.targetsTotal, 2); eq(#a.targetLists, 2); eq(a.targetLists[1].landUseGuess, "commercial")
		eq(a.town, 11); eq(a.townName, "Emsworth"); eq(#a.townProblems, 1); eq(a.townProblems[1].problem, "Disconnected")
		eq(a.townProblems[1].with[1], 12)
		local b = run(g, "reach", "{ target = 5100 }")
		truthy(b.ok, b.error); eq(b.found, true); eq(b.entries[1].entity, 51, "the construction's industry")
		truthy(table.concat(b.kinds, ","):find("construction"))
		eq(b.town, 11, "a construction's closest town"); eq(b.townProblems[1].problem, "Disconnected")
		local h = run(g, "reach", "{ target = 1102 }")
		truthy(h.ok, h.error); eq(h.found, false, "a home is no target"); truthy(h.why:find("not among"), h.why)
		eq(h.candidates[2], 1192, "its PersonCapacity entity was looked for too"); eq(h.town, 11)
		local n = run(g, "reach", "{ target = 52 }")
		truthy(n.ok, n.error); eq(n.found, false); eq(#n.entries, 0); eq(n.capacity, nil, "no workplaces")
		local x = run(g, "reach", "{ target = 424242 }")
		eq(x.ok, false); truthy(x.error:find("no such entity"), x.error)
		eq(g.reachCalls.targets, 4, "once a command (none for an id that is not there)")
		eq(core.json(fake.guiSave), guiBefore, "no GUI save data written"); eq(#g.commands, 0); truthy(not g.crashed, g.crashed)
	end)

	test("reach --town: buildings by kind, targets counted, those out of reach first; an empty town; not a town", function()
		local g = reachGame()
		local a = run(g, "reach", "{ town = 11 }", true)
		truthy(a.ok, a.error); eq(a.name, "Emsworth"); eq(a.buildings, 4)
		eq(a.byKind.residential, 2, "1102 by its PersonCapacity entity"); eq(a.byKind.commercial, 1); eq(a.byKind.industrial, 1)
		eq(a.counts.targets, 1); eq(a.counts.walk, 1); eq(a.notTarget, 1, "the industrial building is no target")
		eq(#a.entries, 1); eq(a.entries[1].building, 1103); eq(a.entries[1].kind, "commercial")
		eq(#a.problems, 1); eq(a.problems[1].with[1], 12)
		local z = run(g, "reach", "{ town = 11, limit = 0 }")
		truthy(z.ok, z.error); eq(#z.entries, 0); eq(z.counts.targets, 1, "counted, not listed")
		local e = run(g, "reach", "{ town = 12 }")
		truthy(e.ok, e.error); eq(e.buildings, 0); eq(e.counts.targets, 0); eq(#e.entries, 0); eq(e.problems[1].with[1], 11)
		local n = run(g, "reach", "{ town = 51 }")
		eq(n.ok, false); truthy(n.error:find("is no town"), n.error)
		local p = run(g, "reach", "{ problems = true }")
		truthy(p.ok, p.error); eq(p.count, 1); eq(p.problems[1].names[1], "Emsworth"); eq(p.problems[1].problem, "Disconnected")
		local api_ = run(g, "reach", "{ api = true }")
		truthy(api_.ok); eq(api_.functions.getTargetsByLandUse, "function"); eq(api_.functions.findPath, "nil")
		truthy(not g.crashed, g.crashed); eq(#g.commands, 0)
	end)

	test("reach --from --to: walking and driving searches from a station and a point to an industry; lines mode", function()
		local g = reachGame()
		local a = run(g, "reach", "{ from = 4100, to = 51 }", true)
		truthy(a.ok, a.error)
		local w, d = a.paths.walk, a.paths.drive
		eq(w.found, false, "no footway to the quarry's edge"); eq(w.fromNodes, 1); eq(w.toNodes, 2); eq(w.fromFrom.terminal, 1)
		eq(w.toFrom.target, 2)
		eq(d.found, true); eq(d.edges, 1); eq(d.pieces, 1); eq(d.pieceIds[1], 702)
		eq(a.to.name, "Quarry A"); eq(a.to.targets[1].isReachableWalk, false); eq(a.from.kinds[1], "station")
		eq(a.lines.targetIsReachableLines, false)
		eq(g.pathModes[1], api.type.enum.TransportMode.PERSON); eq(g.pathModes[2], api.type.enum.TransportMode.CAR)
		local p = run(g, "reach", '{ from = "0,0", to = 4100, mode = "walk" }')
		truthy(p.ok, p.error); eq(p.paths.walk.found, true, "point -> the station's waiting nodes")
		eq(p.paths.walk.sameNode, true); eq(p.from.circle.found, 1); eq(p.paths.drive, nil)
		local q = run(g, "reach", '{ from = "500,500", to = 51, mode = "walk" }')
		truthy(q.ok, q.error); eq(q.paths.walk.found, nil, "nothing near the point: no search"); truthy(q.paths.walk.why)
		local calls = g.reachCalls.path
		local l = run(g, "reach", '{ from = 4100, to = 51, mode = "lines" }')
		truthy(l.ok, l.error); eq(next(l.paths), nil); eq(l.lines.targetIsReachableLines, false)
		eq(g.reachCalls.path, calls, "lines: no path search")
		local h = run(g, "reach", '{ from = 4100, to = 1101, mode = "lines" }')
		truthy(h.ok, h.error); eq(h.lines.targetIsReachableLines, nil); truthy(h.lines.note:find("no target"))
		local n = run(g, "reach", "{ from = 52, to = 51 }")
		truthy(n.ok, n.error); eq(n.paths.walk.found, nil); truthy(n.paths.walk.why:find("no nodes"), n.paths.walk.why)
		local x = run(g, "reach", "{ from = 424242, to = 51 }")
		eq(x.ok, false); truthy(x.error:find("no such entity"), x.error)
		local y = run(g, "reach", '{ from = 424242, to = 51, mode = "lines" }')
		eq(y.ok, false); truthy(y.error:find("no such entity"), y.error)
		truthy(not g.crashed, g.crashed); eq(#g.commands, 0)
	end)

	test("reach: the engine's userdata (vectors read within their size), a list without targets, no function", function()
		local g = reachGame({ userdata = true })
		local a = run(g, "reach", "{ target = 51 }", true)
		truthy(a.ok, a.error); eq(a.found, true); eq(a.entries[1].edgeWalk.entity, 700)
		local b = run(g, "reach", "{ from = 4100, to = 51 }")
		truthy(b.ok, b.error); eq(b.paths.drive.found, true); eq(b.paths.walk.found, false)
		local c = run(g, "reach", "{ town = 11 }")
		truthy(c.ok, c.error); eq(c.counts.targets, 1); eq(c.byKind.residential, 2)
		local p = run(g, "reach", "{ problems = true }")
		truthy(p.ok, p.error); eq(p.problems[1].towns[2], 12)
		truthy(not g.crashed, g.crashed)
		-- an edge index past the network's edges: not read (an engine vector read past its end is an assertion here)
		local o = reachGame({ userdata = true, targets = { { entries = {} }, { entries = { { entity = 51, edgeWalk = { 700, 5 } } } } } })
		local r = run(o, "reach", '{ from = 4100, to = 51, mode = "walk" }', true)
		truthy(r.ok, r.error); eq(r.paths.walk.toNodes, 0); truthy(not o.crashed, o.crashed)
		local l = reachGame({ targetsShape = "list" })
		local la = run(l, "reach", "{ target = 51 }", true)
		truthy(la.ok, la.error); eq(la.found, true); eq(la.read, "top/pairs")
		local nt = reachGame({ noTargets = true })
		local na = run(nt, "reach", "{ target = 51 }", true)
		eq(na.ok, false); truthy(na.error:find("getTargetsByLandUse is not there"), na.error)
		local nb = run(nt, "reach", "{ from = 4100, to = \"0,0\", mode = \"walk\" }")
		truthy(nb.ok, nb.error); truthy(nb.targetsError:find("not there")); eq(nb.paths.walk.found, true)
		local te = reachGame({ targetsError = true })
		local ta = run(te, "reach", "{ town = 11 }", true)
		eq(ta.ok, false); truthy(ta.error:find("targets boom"), ta.error)
		for _, gg in ipairs({ o, l, nt, te }) do truthy(not gg.crashed, gg.crashed) end
	end)

	test("reach: getTargetsByLandUse from 0, by name, flat, or not readable (found unknown, raw shape)", function()
		for _, shape in ipairs({ "zeroBased", "byName", "flat" }) do
			local g = reachGame({ targetsShape = shape })
			local a = run(g, "reach", "{ target = 51 }", true)
			truthy(a.ok, a.error); eq(a.found, true, shape); eq(a.targetsRead, true, shape); eq(a.targetsTotal, 2, shape)
			eq(a.entries[1].isReachableWalk, false, shape); eq(a.raw, nil, shape .. ": read, so no raw")
			local t = run(g, "reach", "{ town = 11 }")
			truthy(t.ok, t.error); eq(t.counts.targets, 1, shape .. ": the shop"); eq(t.targetsWhy, nil)
			truthy(not g.crashed, g.crashed)
		end
		for _, shape in ipairs({ "pairsOnly", "lenZero" }) do
			local g = reachGame({ targetsShape = shape })
			local a = run(g, "reach", "{ target = 51 }", true)
			truthy(a.ok, a.error); eq(a.found, true, shape); eq(a.targetsTotal, 2, shape); eq(a.read, "targets/pairs", shape)
			truthy(not g.crashed, g.crashed)
		end
		-- the engine's lists there but empty inside: raw goes down to the entries' size (0), and no building counts
		local ei = reachGame({ targetsShape = "emptyInside" })
		local ea = run(ei, "reach", "{ target = 51 }", true)
		truthy(ea.ok, ea.error); eq(ea.found, nil); eq(ea.raw.fields.targets.size, 2)
		eq(ea.raw.fields.targets.first.fields.entries.size, 0, "the entries' own size, four levels down")
		truthy(#ea.raw.fields.targets.first.meta > 0, "its metatable's keys")
		local et = run(ei, "reach", "{ town = 11 }")
		truthy(et.ok, et.error); eq(et.notTarget, nil, "nothing read: no notTarget count"); truthy(not ei.crashed, ei.crashed)
		-- one list that would not read: an entity missing from the rest is not called no target
		local pa = R.targetIndex({ targets = { { entries = { { entity = 1103 } } }, newproxy(false) } }, core)
		eq(pa.readable, true); eq(pa.partial, true); eq(pa.lists[2].read, "unreadable"); truthy(pa.raw)
		-- read by name only, as the game's TargetsByLandUse (2026-11-23: no # and no pairs on it)
		for shape, read in pairs({ indexOnly = "targets/index1", indexOnly0 = "targets/index0", metaGetter = "targets/index1" }) do
			local g = reachGame({ targetsShape = shape })
			local a = run(g, "reach", "{ target = 51 }", true)
			truthy(a.ok, a.error); eq(a.found, true, shape); eq(a.targetsTotal, 2, shape); eq(a.read, read, shape)
			eq(a.entries[1].landUseGuess, "industrial", shape .. ": the second of the pair")
			local t = run(g, "reach", "{ town = 11 }")
			truthy(t.ok, t.error); eq(t.counts.targets, 1, shape)
			truthy(not g.crashed, g.crashed)
		end
		local ge = reachGame({ targetsShape = "getter" })
		local gea = run(ge, "reach", "{ target = 51 }", true)
		truthy(gea.ok, gea.error); eq(gea.found, true); eq(gea.read, "targets/index1"); truthy(not ge.crashed, ge.crashed)
		local tv = reachGame({ targetsShape = "twoValues" })
		local tva = run(tv, "reach", "{ target = 51 }", true)
		truthy(tva.ok, tva.error); eq(tva.found, true, "the pair as two values"); eq(tva.read, "targets/values")
		eq(tva.entries[1].landUseGuess, "industrial"); truthy(not tv.crashed, tv.crashed)
		local pn = reachGame({ targetsShape = "pairNothing" })
		local pna = run(pn, "reach", "{ target = 51 }", true)
		truthy(pna.ok, pna.error); eq(pna.targetsRead, false)
		eq(pna.raw.probe.at0, "nil"); eq(pna.raw.probe.at1, "nil"); eq(pna.raw.probe.at2, "nil")
		truthy(pna.raw.probe.targets:find("^userdata TargetsByLandUse"), pna.raw.probe.targets)
		local nb = reachGame({ targetsShape = "noBinding" })
		local nba = run(nb, "reach", "{ target = 51 }", true)
		truthy(nba.ok, nba.error); eq(nba.targetsRead, false); eq(nba.found, nil)
		truthy(nba.raw.probe.targets:find("^error: .*no Lua binding"), nba.raw.probe.targets)
		truthy(nba.raw.fieldProbe.targets:find("^error:"), "the field read by name, in raw too")
		eq(nba.raw.text, "TargetsByLandUse: 0x2"); truthy(not nb.crashed, nb.crashed)
		truthy(nba.raw.probe.indexCall:find("^error:"), nba.raw.probe.indexCall)
		eq(nba.raw.probe.other_target, "nil", "other names tried for the next look"); eq(nba.raw.probe.other_0, "nil")
		local z = reachGame({ targetsShape = "zeroBased" })
		eq(run(z, "reach", "{ target = 51 }", true).entries[1].landUseKey, 1, "the second list from 0")
		local b = reachGame({ targetsShape = "byName" })
		local bl = run(b, "reach", "{ target = 51 }", true)
		eq(bl.entries[1].landUseKey, "INDUSTRIAL"); eq(bl.read, "top/pairs")
		local f = reachGame({ targetsShape = "flat" })
		eq(run(f, "reach", "{ target = 51 }", true).read, "top/pairs/flat")
		-- nothing read: no "not a target", and what it was
		for _, shape in ipairs({ "opaque", "empty" }) do
			local o = reachGame(shape == "opaque" and { targetsShape = "opaque" } or { targets = {} })
			local a = run(o, "reach", "{ target = 51 }", true)
			truthy(a.ok, a.error); eq(a.found, nil, shape); eq(a.targetsRead, false); truthy(a.why:find("read as no targets"), a.why)
			truthy(a.raw and a.raw.type, shape .. ": raw")
			local t = run(o, "reach", "{ town = 11 }")
			truthy(t.ok, t.error); eq(t.targetsRead, false); truthy(t.targetsWhy); truthy(t.raw)
			local p = run(o, "reach", '{ from = 4100, to = 51, mode = "walk" }')
			truthy(p.ok, p.error); eq(p.targetsRead, false)
			truthy(not o.crashed, o.crashed)
		end
		local op = reachGame({ targetsShape = "opaque" })
		local r = run(op, "reach", "{ target = 51 }", true).raw
		eq(r.type, "userdata"); eq(r.size, "none"); eq(r.read, "unreadable"); eq(r.text, "TargetsByLandUse: 0x1")
		local d = R.describeRaw({ targets = { [0] = { entries = {} } } }, core)
		eq(d.type, "table"); eq(d.keys[1], "targets:table"); eq(d.fields.targets.keys[1], "0:table")
		eq(d.first.first.keys[1], "entries:table", "three levels down")
		eq(R.describeRaw(nil, core).type, "nil"); eq(R.describeRaw(5, core).value, "5")
		local items, how = R.items({ b = 1, [2] = 2, [0] = 3, a = 4 }, core)
		eq(how, "pairs"); eq(items[1].key, 0); eq(items[2].key, 2); eq(items[3].key, "a"); eq(items[4].key, "b")
	end)

	test("reach --from --to: a home's own doors, a place found by its position, the node cap, a search that fails", function()
		local circle = { { 0, 0, node = "701:0" }, { 300, 300, node = "703:0" } }
		for i = 1, 40 do circle[#circle + 1] = { 1000 + i, 1000, node = "704:" .. i } end
		local g = reachGame({ circle = circle, positions = { [52] = { 300, 300 } },
			buildings = { [1101] = { town = 11, kind = "RESIDENTIAL", capacity = 10, personNodes = { "701:1" } } },
			graph = { walk = { ["701:1"] = { "703:0" } }, drive = {} } })
		local a = run(g, "reach", '{ from = 1101, to = 52, mode = "walk" }', true)
		truthy(a.ok, a.error); local w = a.paths.walk
		eq(w.fromFrom.personCapacity, 1, "the home's personNodes, not a circle"); eq(w.toFrom.circle, 1, "52 by its position")
		eq(a.to.position.x, 300); eq(w.found, true); eq(w.unverified, nil)
		local b = run(g, "reach", '{ from = "1020,1000", to = 52, mode = "walk", radius = 100 }')
		truthy(b.ok, b.error); eq(b.paths.walk.fromNodes, R.PATH_NODES_MAX); eq(b.from.truncated, true); eq(b.from.circle.found, 40)
		eq(b.paths.walk.found, false); eq(b.paths.walk.unverified, true, "a miss is marked until checked in a game")
		local e = reachGame({ pathError = true })
		local c = run(e, "reach", '{ from = 4100, to = 51, mode = "drive" }', true)
		truthy(c.ok, c.error); eq(c.paths.drive.found, nil); truthy(c.paths.drive.why:find("path boom"), c.paths.drive.why)
		for _, gg in ipairs({ g, e }) do truthy(not gg.crashed, gg.crashed) end
	end)

	test("reach in the main menu: refused, needs a game", function()
		local g = newGame({ saves = SAVES, menu = true })
		frames(g, 2)
		send(g, 3990, "reach", "{ api = true }")
		frames(g, FIRST)
		truthy(final(g, 3990).error:find("needs a running game"))
	end)

	test("persons --town / --destination: residents with the counts of what they reach, summary.reach", function()
		local g = reachGame()
		local a = run(g, "persons", "{ town = 11 }", true)
		truthy(a.ok, a.error); eq(a.town, 11); eq(a.total, 4, "homes 1101 and 1192 (1102's PersonCapacity)")
		local byId = {}
		for _, p in ipairs(a.persons) do byId[p.id] = p end
		eq(byId[9001].reachable.walkDrive[1], 3); eq(byId[9002].reachable.lines[2], 1); eq(byId[9004].reachable, nil)
		local s = a.summary.reach
		eq(s.persons, 3); eq(s.walkDrive[1], 3); eq(s.walkDrive[2], 2); eq(s.lines[1], 0); eq(s.lines[2], 1); eq(s.none, 0)
		local d = run(g, "persons", "{ destination = 51 }")
		truthy(d.ok, d.error); eq(d.total, 1); eq(d.persons[1].id, 9003); eq(d.destination, 51)
		local e = run(g, "persons", "{ town = 12 }")
		truthy(e.ok, e.error); eq(e.total, 0); eq(e.summary.reach, nil)
		local bad = { { "{ destination = 52 }", "no person capacity" }, { "{ destination = 424242 }", "no such entity" },
			{ "{ town = 51 }", "is no town" }, { "{ town = 11, line = 1 }", "not both" }, { "{ destination = -2 }", "destination must be" } }
		for _, b in ipairs(bad) do
			local r = run(g, "persons", b[1])
			truthy(r.ok ~= true and r.error and r.error:find(b[2], 1, true), b[1] .. " -> " .. tostring(r.error))
		end
		local u = reachGame({ userdata = true })
		local ua = run(u, "persons", "{ town = 11, limit = 2 }", true)
		truthy(ua.ok, ua.error); eq(ua.total, 4); eq(#ua.persons, 2); eq(ua.summary.reach.persons, 2)
		for _, gg in ipairs({ g, u }) do truthy(not gg.crashed, gg.crashed); eq(#gg.commands, 0) end
	end)

	-- Road pieces and junctions as ends (2026-11-24, aom-ops: a ground road and a bridge piece with no road between
	-- them read as joined with --radius 200-300, the circles round them holding the same nodes). 801 (ground: a CAR
	-- lane 801:0 -> 801:1, a PERSON lane 801:2 -> 801:3) and 802 (bridge: CAR only), 100 m apart, not joined; 900:0
	-- a node of something else between them. 803 and 804 meet at junction 850 (their CAR lanes end in 850:0). 805
	-- leads into 806 by the search (805:1 -> 806:0); junction 851 has no lanes of its own, its node 851:0 leads into
	-- 805:0.
	local function edgeSpec(extra)
		local s = {
			edges = { [801] = { 850, 851 }, [802] = { 852, 853 }, [803] = { 854, 850 }, [804] = { 850, 855 },
				[805] = { 851, 856 }, [806] = { 856, 857 } },
			baseNodes = { [850] = true, [851] = true },
			tn = { [801] = { edges = { { 0, 1, modes = { "CAR" } }, { 2, 3, modes = { "PERSON" } } } },
				[802] = { edges = { { 0, 1, modes = { "CAR" } } } },
				[803] = { edges = { { 0, "850:0", modes = { "CAR" } } } },
				[804] = { edges = { { "850:0", 1, modes = { "CAR" } } } },
				[805] = { edges = { { 0, 1, modes = { "CAR" } } } }, [806] = { edges = { { 0, 1, modes = { "CAR" } } } },
				[850] = { edges = { { 0, 1, modes = { "CAR" } } }, nodes = 2 }, [851] = { nodes = 1 } },
			graph = { walk = {}, drive = { ["801:0"] = { "801:1" }, ["802:0"] = { "802:1" }, ["805:0"] = { "805:1" },
				["805:1"] = { "806:0" }, ["851:0"] = { "805:0" } } },
			positions = { [801] = { 1000, 1000 }, [802] = { 1100, 1000 }, [803] = { 2000, 0 }, [804] = { 2050, 0 } },
			circle = { { 1000, 1000, node = "801:0" }, { 1050, 1000, node = "900:0" }, { 1100, 1000, node = "802:0" } },
		}
		for k, v in pairs(extra or {}) do s[k] = v end
		-- the pieces next to reachSpec's places: its networks, links and circle kept
		local base = reachSpec()
		for _, k in ipairs({ "tn", "positions" }) do
			for e, v in pairs(base[k] or {}) do if s[k][e] == nil then s[k][e] = v end end
		end
		for m, links in pairs(base.graph) do for n, l in pairs(links) do s.graph[m][n] = s.graph[m][n] or l end end
		for _, c in ipairs(base.circle) do s.circle[#s.circle + 1] = c end
		return reachSpec(s)
	end
	local function edgeGame(extra)
		local g = newGame({ saves = SAVES })
		fakeReach.install(g, edgeSpec(extra))
		frames(g, 1)
		return g
	end

	test("reach --from --to pieces: two pieces not joined are not found joined, whatever the radius", function()
		local g = edgeGame()
		for _, r in ipairs({ 40, 300 }) do
			local a = run(g, "reach", "{ from = 801, to = 802, mode = 'drive', radius = " .. r .. " }", r == 40)
			truthy(a.ok, a.error)
			local d = a.paths.drive
			eq(d.found, false, "radius " .. r .. ": no road between them"); eq(d.sameNode, nil); eq(d.trivial, nil)
			eq(d.fromFrom.edge, 2, "the two nodes of the piece's own CAR lane"); eq(d.fromNodes, 2)
			eq(d.fromFrom.circle, nil, "no circle round a piece"); eq(d.toFrom.edge, 2); eq(a.from.circle, nil)
			eq(a.from.kinds[1], "edge"); eq(a.from.edge.node0, 850); eq(a.from.edge.node1, 851)
		end
		eq(g.reachCalls.circle, 0, "no circle asked for")
		-- walking: 801 has a footway lane, 802 none
		local w = run(g, "reach", "{ from = 801, to = 802, mode = 'walk', radius = 300 }")
		truthy(w.ok, w.error); eq(w.paths.walk.found, nil); eq(w.paths.walk.fromNodes, 2, "801's PERSON lane")
		truthy(w.paths.walk.why:find("carries walk", 1, true), w.paths.walk.why)
		truthy(not g.crashed, g.crashed); eq(#g.commands, 0)
	end)

	test("reach --from --to pieces: joined at a junction (a shared node), by the search, and from a junction", function()
		local g = edgeGame()
		local a = run(g, "reach", "{ from = 803, to = 804, mode = 'drive' }", true)
		truthy(a.ok, a.error); eq(a.paths.drive.found, true); eq(a.paths.drive.sameNode, true)
		eq(a.paths.drive.trivial, nil); eq(a.paths.drive.sameNodeFrom, "edge"); eq(a.paths.drive.sameNodeTo, "edge")
		local b = run(g, "reach", "{ from = 805, to = 806, mode = 'drive' }")
		truthy(b.ok, b.error); eq(b.paths.drive.found, true); eq(b.paths.drive.sameNode, nil); eq(b.paths.drive.edges, 1)
		-- a junction: its own lanes' nodes
		local j = run(g, "reach", "{ from = 850, to = 804, mode = 'drive' }")
		truthy(j.ok, j.error); eq(j.from.kinds[1], "node"); eq(j.paths.drive.fromFrom.node, 2)
		eq(j.paths.drive.found, true); eq(j.paths.drive.sameNode, true, "850:0 is where 804 starts")
		-- a junction without lanes: its network's nodes by NodeId.new, not checked for the mode
		local k = run(g, "reach", "{ from = 851, to = 806, mode = 'drive' }")
		truthy(k.ok, k.error); eq(k.paths.drive.fromFrom.node, 1); eq(k.paths.drive.found, true); eq(k.paths.drive.edges, 3)
		eq(k.from.modesUnread, 1)
		local n = edgeGame({ noNodeIdNew = true })
		local m = run(n, "reach", "{ from = 851, to = 806, mode = 'drive' }", true)
		truthy(m.ok, m.error); eq(m.paths.drive.found, nil); truthy(m.paths.drive.why:find("no network nodes on junction 851"), m.paths.drive.why)
		-- a piece without a transport network
		local t = edgeGame({ edges = { [801] = { 850, 851 }, [807] = { 1, 2 } }, positions = { [807] = { 1000, 1000 } } })
		local x = run(t, "reach", "{ from = 807, to = 801, mode = 'drive', radius = 300 }", true)
		truthy(x.ok, x.error); eq(x.paths.drive.found, nil); truthy(x.paths.drive.why:find("no TRANSPORT_NETWORK on piece 807"), x.paths.drive.why)
		-- a junction with lanes, none for the mode: no node for it (not its whole network)
		local jg = edgeGame()
		local jw = run(jg, "reach", "{ from = 850, to = 804, mode = 'walk' }", true)
		truthy(jw.ok, jw.error); eq(jw.paths.walk.found, nil); eq(jw.paths.walk.fromNodes, 0)
		truthy(jw.paths.walk.why:find("none of the 1 network edges of junction 850 carries walk", 1, true), jw.paths.walk.why)
		-- the modes as numbers (as remote_lanes reads them), and as a map that does not read (taken, counted)
		local nb = edgeGame({ modesAsNumbers = true })
		local na = run(nb, "reach", "{ from = 801, to = 802, mode = 'walk' }", true)
		truthy(na.ok, na.error); eq(na.paths.walk.fromNodes, 2, "801's PERSON lane only"); eq(na.from.modesUnread, nil)
		local op = edgeGame({ modesOpaque = true, userdata = true })
		local oa = run(op, "reach", "{ from = 801, to = 802, mode = 'drive', radius = 300 }", true)
		truthy(oa.ok, oa.error); eq(oa.paths.drive.fromNodes, 4, "both lanes taken"); eq(oa.from.modesUnread, 2)
		eq(oa.paths.drive.found, false, "still no road between them")
		for _, gg in ipairs({ g, n, t, jg, nb, op }) do truthy(not gg.crashed, gg.crashed); eq(#gg.commands, 0) end
	end)

	test("reach --from --to: two circles holding the same node are trivial (no search); one end's own node is not", function()
		local g = edgeGame()
		local calls = g.reachCalls.path
		local a = run(g, "reach", "{ from = '1000,1000', to = '1100,1000', mode = 'drive', radius = 300 }", true)
		truthy(a.ok, a.error)
		local d = a.paths.drive
		eq(d.found, nil, "overlapping circles say nothing about a path"); eq(d.trivial, true); eq(d.sameNode, nil)
		truthy(d.why:find("trivial", 1, true), d.why); truthy(d.sharedNode)
		eq(g.reachCalls.path, calls, "no search")
		-- small circles: each holds its own piece's node, and the search says there is no road
		local b = run(g, "reach", "{ from = '1000,1000', to = '1100,1000', mode = 'drive', radius = 40 }")
		truthy(b.ok, b.error); eq(b.paths.drive.found, false); eq(b.paths.drive.trivial, nil)
		-- a point whose circle (the default radius) holds the piece's own node: that is where the piece is (as a point
		-- at a station)
		local c = run(g, "reach", "{ from = '1000,1000', to = 801, mode = 'drive', radius = 40 }")
		truthy(c.ok, c.error); eq(c.paths.drive.found, true); eq(c.paths.drive.sameNode, true)
		eq(c.paths.drive.sameNodeFrom, "circle"); eq(c.paths.drive.sameNodeTo, "edge")
		-- a wider circle round a point by one road reaches the other piece's node (the bridge above it): that node is
		-- left out, the rest of the circle searched, and there is no road
		local calls2 = g.reachCalls.path
		local w = run(g, "reach", "{ from = '1050,1000', to = 802, mode = 'drive', radius = 300 }")
		truthy(w.ok, w.error); eq(w.paths.drive.found, false); eq(w.paths.drive.trivial, nil); eq(w.paths.drive.sameNode, nil)
		eq(w.paths.drive.sharedNode, "802:0"); eq(w.paths.drive.droppedFrom, 1); eq(w.paths.drive.droppedTo, 0)
		eq(g.reachCalls.path, calls2 + 1, "searched"); truthy(w.paths.drive.circleNote:find("flat", 1, true))
		-- (a) two ends' own nodes shared: found, whatever the radius
		local own = run(g, "reach", "{ from = 803, to = 804, mode = 'drive', radius = 300 }")
		truthy(own.ok, own.error); eq(own.paths.drive.found, true); eq(own.paths.drive.sameNode, true)
		eq(own.paths.drive.circleNote, nil, "no circle")
		truthy(not g.crashed, g.crashed); eq(#g.commands, 0)
	end)

	test("reach --from --to: a point with no node at 40 m and the target in a wider circle is searched (no dead end)", function()
		-- a point in a field: nothing within 40 m; at 100 m a footway node 910:0 leading to the shop's 701:0, and
		-- 701:0 itself
		local g = edgeGame({ circle = { { 2060, 2000, node = "910:0" }, { 2070, 2000, node = "701:0" } },
			graph = { walk = { ["910:0"] = { "701:0" } }, drive = {} } })
		local a = run(g, "reach", "{ from = '2000,2000', to = 1103, mode = 'walk', radius = 40 }", true)
		truthy(a.ok, a.error); eq(a.paths.walk.found, nil); truthy(a.paths.walk.why:find("no nodes", 1, true), a.paths.walk.why)
		local b = run(g, "reach", "{ from = '2000,2000', to = 1103, mode = 'walk', radius = 100 }")
		truthy(b.ok, b.error); eq(b.paths.walk.found, true); eq(b.paths.walk.trivial, nil); eq(b.paths.walk.edges, 1)
		eq(b.paths.walk.droppedFrom, 1, "701:0 left out of the point's circle")
		eq(b.paths.walk.fromNodes, 1, "the nodes searched"); truthy(b.paths.walk.wideNote:find("not where the point is", 1, true))
		-- the circle holding nothing but the shop's node: trivial
		local o = edgeGame({ circle = { { 2070, 2000, node = "701:0" } } })
		local c = run(o, "reach", "{ from = '2000,2000', to = 1103, mode = 'walk', radius = 100 }", true)
		truthy(c.ok, c.error); eq(c.paths.walk.found, nil); eq(c.paths.walk.trivial, true); truthy(c.paths.walk.why:find("trivial"))
		for _, gg in ipairs({ g, o }) do truthy(not gg.crashed, gg.crashed); eq(#gg.commands, 0) end
	end)

	test("reach --from --to pieces: transportModes keyed by name, a mode valued 0 or false, conns that give nothing", function()
		-- (e) keys the names
		local s = edgeGame({ modesAsStrings = true })
		local a = run(s, "reach", "{ from = 801, to = 802, mode = 'walk' }", true)
		truthy(a.ok, a.error); eq(a.paths.walk.fromNodes, 2, "801's PERSON lane only"); eq(a.from.modesUnread, nil)
		eq(a.paths.walk.found, nil, "802 has no footway")
		-- (b) a mode there with 0 (numbers) or false: not carried
		for _, nums in ipairs({ true, false }) do
			local tn = edgeSpec().tn
			tn[801] = { edges = { { 0, 1, modes = { "CAR" }, off = { "PERSON" } }, { 2, 3, off = { "PERSON" } } } }
			local z = edgeGame({ tn = tn, modesAsNumbers = nums })
			local r = run(z, "reach", "{ from = 801, to = 802, mode = 'walk' }", true)
			truthy(r.ok, r.error); eq(r.paths.walk.fromNodes, 0)
			truthy(r.paths.walk.why:find("none of the 2 network edges of piece 801 carries walk", 1, true), r.paths.walk.why)
			truthy(not z.crashed, z.crashed)
		end
		-- conns that give no node: told apart from no lane for the mode
		local tn = edgeSpec().tn
		tn[850] = { edges = { { 0, 1, modes = { "CAR" }, noConns = true } }, nodes = 2 }
		local c = edgeGame({ tn = tn })
		local r = run(c, "reach", "{ from = 850, to = 804, mode = 'drive' }", true)
		truthy(r.ok, r.error); eq(r.paths.drive.found, nil)
		truthy(r.paths.drive.why:find("but their conns gave no node", 1, true), r.paths.drive.why)
		local w = run(c, "reach", "{ from = 850, to = 804, mode = 'walk' }")
		truthy(w.paths.walk.why:find("carries walk", 1, true), w.paths.walk.why)
		-- a key that names no mode: not known whether it is the one (taken, counted), not "carries none"
		local un = edgeSpec().tn
		un[802] = { edges = { { 0, 1, modes = { "CAR" }, unnamed = { 99 } } } }
		local u = edgeGame({ tn = un })
		local ur = run(u, "reach", "{ from = 802, to = 801, mode = 'walk' }", true)
		truthy(ur.ok, ur.error); eq(ur.paths.walk.fromNodes, 2); eq(ur.from.modesUnread, 1)
		local ud = run(u, "reach", "{ from = 802, to = 801, mode = 'drive' }")
		eq(ud.paths.drive.fromNodes, 2); eq(ud.from.modesUnread, nil, "CAR named: carried, known")
		truthy(not u.crashed, u.crashed)
		for _, gg in ipairs({ s, c }) do truthy(not gg.crashed, gg.crashed); eq(#gg.commands, 0) end
	end)

	test("reach walkBetween (stations --catchment): trivial and sharedNode passed on; a building to a station as before", function()
		local lanes = require "hummer_remote_probe::/remote_lanes.lua"
		-- 1101 and 1104 hold no nodes of their own: both ends circles round their places, which hold 701:0 only
		local g = edgeGame({ positions = { [1101] = { 0, 0 }, [1104] = { 5, 0 } } })
		local function try(fn) local ok, v = pcall(fn); if ok then return v end return nil end
		local w = R.new({ core = core, answer = function() end, fail = function() end, try = try,
			modeNames = lanes.modeNames, tmNamer = lanes.tmNamer,
			posOf = function(e)
				local bv = api.engine.getComponent(e, "BOUNDING_VOLUME")
				if not bv then return nil end
				return { x = (bv.bbox.min.x + bv.bbox.max.x) / 2, y = (bv.bbox.min.y + bv.bbox.max.y) / 2 }
			end })
		local r = w.walkBetween(1101, 1104)
		eq(r.found, nil); eq(r.trivial, true); eq(r.sharedNode, "701:0"); truthy(r.why:find("trivial"), r.why)
		eq(r.droppedFrom, 1); eq(r.droppedTo, 1, "both ends circles: left out of both"); truthy(r.circleNote)
		-- a building (its circle) to a station's waiting node: found, as before
		local s = w.walkBetween(1101, 4100)
		eq(s.found, true); eq(s.sameNode, true); eq(s.trivial, nil)
		truthy(not g.crashed, g.crashed)
	end)

	test("reach --from --to: buildings, stations and points as before, next to pieces (userdata too)", function()
		for _, ud in ipairs({ false, true }) do
			local g = edgeGame({ userdata = ud })
			local a = run(g, "reach", "{ from = 4100, to = 51 }", true)
			truthy(a.ok, a.error); eq(a.paths.walk.found, false); eq(a.paths.drive.found, true); eq(a.paths.drive.pieceIds[1], 702)
			eq(a.paths.walk.fromFrom.terminal, 1); eq(a.paths.walk.toFrom.target, 2)
			local p = run(g, "reach", "{ from = '0,0', to = 4100, mode = 'walk' }")
			truthy(p.ok, p.error); eq(p.paths.walk.found, true); eq(p.paths.walk.sameNode, true)
			eq(p.paths.walk.sameNodeFrom, "circle"); eq(p.paths.walk.sameNodeTo, "terminal")
			local h = run(g, "reach", "{ from = 1103, to = 4100, mode = 'walk' }")
			truthy(h.ok, h.error); eq(h.paths.walk.found, true, "the shop's edgeWalk 701:0 is the station's waiting node")
			eq(h.paths.walk.sameNodeFrom, "target"); eq(h.from.edge, nil, "a building is no piece")
			truthy(not g.crashed, g.crashed); eq(#g.commands, 0)
		end
	end)
end
