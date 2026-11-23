-- Tests of build / road --collision-detail (core.collisionDetail, core.collisionOverlaps, remote_build.lua's
-- verdict with detail). Run by tests/run.lua with its helpers: dofile(...)(t). The engine's side is
-- tests/fake_game.lua (installBuild's spec.proposalData hands out engine-like userdata; installAround the boxes).
return function(t)
	local test, eq, truthy, fake, core = t.test, t.eq, t.truthy, t.fake, t.core
	local buildWorld, buildRun, roadWorld, roadRun, RAMP = t.buildWorld, t.buildRun, t.roadWorld, t.roadRun, t.RAMP
	local object, vector = fake.object, fake.vector

	local function has(list, pred)
		for _, x in ipairs(list or {}) do if pred(x) then return x end end
	end
	local function deepEq(a, b, path)
		path = path or "answer"
		if type(a) ~= type(b) then return false, path .. ": " .. type(a) .. " vs " .. type(b) end
		if type(a) ~= "table" then
			if a == b then return true end
			return false, path .. ": " .. tostring(a) .. " vs " .. tostring(b)
		end
		for k, v in pairs(a) do
			local ok, why = deepEq(v, b[k], path .. "." .. tostring(k))
			if not ok then return false, why end
		end
		for k in pairs(b) do if a[k] == nil then return false, path .. "." .. tostring(k) .. ": only in the second" end end
		return true
	end
	-- an engine object one of whose fields raises when read (as a binding that is not there)
	local function raising(fields, bad)
		local u = newproxy(true)
		local mt = getmetatable(u)
		mt.__index = function(_, k)
			if k == bad then error("no member " .. k) end
			return fields[k]
		end
		mt.__tostring = function() return "ErrorState" end
		return u
	end
	local function vec3(x, y, z) return object({ x = x, y = y, z = z }, nil, "Vec3f") end

	-- a ProposalData as the engine's: userdata with vectors, an entity map, one field that raises, one nil
	local function engineData()
		local locs = {}
		for i = 1, 50 do locs[i] = vec3(i, 0, 1) end
		return object({
			collisionInfo = object({
				collisionEntities = vector({ object({ entity = 601, position = vec3(1, 2, 3) }, nil, "EntityData") }),
				autoRemovalEntity2models = { [605] = vector({ vector({ 1, 2 }) }) },
				buildingEntities = vector({}),
				-- removableModules: nil (absent)
			}, nil, "CollisionInfo"),
			errorState = raising({ critical = true, messages = vector({ "Collision" }), warnings = vector({}) }, "infos"),
			toAddData = vector({ object({ boundingVolume = object({ bbox = object({ min = vec3(-10, -10, 20),
				max = vec3(10, 10, 45) }) }), subconstructionDatas = vector({}) }) }),
			toAddData_native = vector({}),
			terrainPreviewHeightModLocations = vector(locs),
			terrainPreviewHeightModCutFill = vector({ object({ x = 1.5, y = -2 }, nil, "Vec2f") }),
			entity2tn = { [9] = object({ nodes = vector({ 1, 2, 3 }), edges = vector({ 1 }), turnaroundEdges = vector({}) }) },
			tpNetLinkProposal = object({ toAdd = vector({}), toRemove = vector({}) }),
			costs = 5000,
			-- (old2new, parallelProposal: nil)
		}, nil, "ProposalData")
	end

	test("core.collisionDetail: the engine's nested fields as plain JSON, cut lists, fields that raise or read nil", function()
		local d = core.collisionDetail(engineData(), "makeProposalData (proposal)")
		eq(d.from, "makeProposalData (proposal)")
		local f = d.fields
		eq(f.collisionInfo.collisionEntities[1].entity, 601)
		eq(f.collisionInfo.autoRemovalEntity2models[1].key, 605)
		eq(f.collisionInfo.autoRemovalEntity2models[1].value[1][2], 2, "a map of lists of pairs")
		eq(#f.collisionInfo.buildingEntities, 0, "an empty vector: an empty list")
		eq(f.errorState.critical, true); eq(f.errorState.messages[1], "Collision")
		local b = f.toAddData[1].boundingVolume.bbox
		eq(b.z0, 20); eq(b.z1, 45); eq(b.x0, -10)
		eq(f.terrainPreviewHeightModCutFill[1].y, -2)
		eq(f.entity2tn[1].key, 9); eq(f.entity2tn[1].value.nodes.size, 3, "a network by its lengths")
		eq(f.costs, 5000)
		eq(f.toAddData_native, nil, "the native twin is not read again")
		-- cut at the limit, and said so
		eq(#f.terrainPreviewHeightModLocations, core.COLLISION_DETAIL_LIMITS.items)
		local cut = has(d.truncated, function(x) return x.path == "terrainPreviewHeightModLocations" end)
		truthy(cut, "the cut is named"); eq(cut.total, 50); eq(cut.kept, core.COLLISION_DETAIL_LIMITS.items)
		-- a field that raises: its name and the error; the rest of the record still read
		local u = has(d.unread, function(x) return x.path == "errorState.infos" end)
		truthy(u and u.error:find("no member infos"), "the raising field named with its error")
		truthy(has(d.absent, function(x) return x == "collisionInfo.removableModules" end), "a nil field named")
		truthy(has(d.absent, function(x) return x == "old2new" end))
		-- a name the types leave out, read on the collision's record
		local gp = has(d.guessed, function(x) return x.path == "collisionInfo.collisionEntities[1].position" end)
		truthy(gp, "a guessed field that reads is listed")
		-- as JSON: lists stay lists ([] when empty)
		local j = core.json(d)
		truthy(j:find('"buildingEntities":%[%]'), j:sub(1, 300))
	end)

	test("core.collisionDetail: depth and value limits, nil and empty data, a list whose # raises, a map that does not walk", function()
		local d = core.collisionDetail(engineData(), "x", { depth = 2 })
		truthy(has(d.truncated, function(x) return x.reason and x.path:find("^collisionInfo.collisionEntities") end),
			"cut by depth, named")
		local v = core.collisionDetail(engineData(), "x", { values = 5 })
		truthy(v.valuesCut, "the value budget said")
		local n = core.collisionDetail(nil, "resultProposalData")
		eq(n.none, true); eq(n.fields, nil)
		local e = core.collisionDetail(object({}, nil, "ProposalData"), "x")
		eq(next(e.fields), nil); truthy(#e.absent >= 9, "every field nil: all named")
		-- a vector whose # raises, a userdata map that pairs cannot walk, a record that is a number
		local badLen = newproxy(true)
		getmetatable(badLen).__len = function() error("len gone") end
		local opaque = newproxy(true)
		getmetatable(opaque).__index = function() return nil end
		local w = core.collisionDetail(object({ toAddData = badLen, old2new = opaque, collisionInfo = 7,
			errorState = object({ messages = vector({ "a", nil }) }) }), "x")
		truthy(has(w.unread, function(x) return x.path == "toAddData" and x.error:find("not a list") end))
		truthy(has(w.unread, function(x) return x.path == "old2new" and x.error:find("not a map") end))
		truthy(has(w.unread, function(x) return x.path:find("^collisionInfo%.") end), "a number read as a record: each field's error")
		-- a plain table's keys the types do not name
		local p = core.collisionDetail({ costs = 1, extra = true }, "x")
		truthy(has(p.unlisted, function(x) return x.keys[1] == "extra" end))
		-- a whole read that raises does not escape
		local okB = pcall(core.collisionDetail, setmetatable({}, { __index = function() error("gone") end }), "x")
		truthy(okB, "never raises")
	end)

	test("core.collisionOverlaps: the overlap on each axis, or the gap; no z when a height is unknown", function()
		local hits = { { id = 501, kind = "street", box = { x0 = -100, y0 = -4, z0 = 0, x1 = 100, y1 = 4, z1 = 1 } } }
		local o = core.collisionOverlaps({ { x0 = -10, y0 = -10, z0 = 20, x1 = 10, y1 = 10, z1 = 45 } }, hits)
		eq(o[1].entity, 501); eq(o[1].meet, false); eq(o[1].gap.z, 19); eq(o[1].overlap.x[1], -10); eq(o[1].overlap.y[2], 4)
		local m = core.collisionOverlaps({ { x0 = -10, y0 = -10, z0 = 0, x1 = 10, y1 = 10, z1 = 45 } }, hits)
		eq(m[1].meet, true); eq(m[1].overlap.z[2], 1)
		local nz = core.collisionOverlaps({ { x0 = -10, y0 = -10, x1 = 10, y1 = 10 } }, hits)
		eq(nz[1].noZ, true); eq(nz[1].meet, true)
		eq(core.collisionOverlaps({}, hits), nil); eq(core.collisionOverlaps(nil, nil), nil)
		eq(core.collisionOverlaps({ {} }, { { id = 1 } }), nil, "no box: nothing")
	end)

	test("core: collisionDetail only with a build or a dry run with engineCheck", function()
		eq(core.buildRequest({ res = "a.con", at = "0,0", collisionDetail = true }).collisionDetail, true)
		eq(core.buildRequest({ res = "a.con", at = "0,0", dryRun = true, engineCheck = true, collisionDetail = true }).collisionDetail, true)
		eq(core.buildRequest({ res = "a.con", at = "0,0" }).collisionDetail, nil)
		truthy(select(2, core.buildRequest({ res = "a.con", at = "0,0", dryRun = true, collisionDetail = true })):find("engineCheck"))
		truthy(select(2, core.buildRequest({ res = "a.con", at = "0,0", collisionDetail = 1 })):find("true or false"))
		eq(core.roadRequest({ from = "0,0", to = "30,0", collisionDetail = true }).collisionDetail, true)
		truthy(select(2, core.roadRequest({ from = "0,0", to = "30,0", dryRun = true, collisionDetail = true })):find("engineCheck"))
	end)

	local HOUSE = { [601] = { box = { 1990, -5, 0, 2010, 5, 12 }, comps = { TOWN_BUILDING = { town = 700, construction = 602 } } },
		[602] = { box = { 1990, -5, 0, 2010, 5, 12 }, comps = { CONSTRUCTION = { fileName = "building/era_a/res_1.con" } } },
		[700] = { box = { -500, -500, 0, 500, 500, 50 }, name = "Chesham", comps = { TOWN = {} } },
		[501] = { box = { -4, 1400, 0, 4, 1700, 1 }, comps = { BASE_EDGE = { roadType = "STREET", roadTemplate = "town_new_medium.lua",
			position0 = { x = 0, y = 1400, z = 0 }, position1 = { x = 0, y = 1700, z = 0 }, node0 = 1, node1 = 2 } } } }

	test("build --dry-run --engine-check --collision-detail: the ProposalData copied out, the boxes met; refused and buildable", function()
		local g = buildWorld({ blocked = function(x) return x > 1000 and 601 or nil end, height = function() return 0 end })
		fake.installAround(g, { things = HOUSE })
		local a = buildRun(g, 3101, string.format('{ res = %q, at = "2000,0,20", dryRun = true, engineCheck = true, ' ..
			'collisionDetail = true }', RAMP))
		eq(a.ok, false); eq(a.collisions[1], 601)
		local d = a.collisionDetail
		truthy(d and d.fields, "the detail is there")
		truthy(d.from:find("makeProposalData"), d.from)
		eq(d.fields.collisionInfo.collisionEntities[1].entity, 601)
		eq(d.fields.errorState.messages[1], "Collision")
		eq(d.fields.toAddData[1].boundingVolume.bbox.z0, 20, "the new box from 20 m")
		-- the house's box (0-12 m) and the construction's (20-30 m): apart by 8 m in z
		local o = d.overlaps[1]
		eq(o.entity, 601); eq(o.mine, 1); eq(o.meet, false); eq(o.gap.z, 8)
		eq(#g.buildCmds, 0, "nothing sent")
		-- buildable, no collisions: the detail all the same, no overlaps
		local b = buildRun(g, 3102, string.format('{ res = %q, at = "100,0", dryRun = true, engineCheck = true, ' ..
			'collisionDetail = true }', RAMP))
		truthy(b.ok, b.error); truthy(b.collisionDetail.fields, "read when buildable too"); eq(b.collisionDetail.overlaps, nil)
		truthy(not g.crashed, g.crashed)
	end)

	test("build refused with --collision-detail: the callback's resultProposalData copied out, its overlaps", function()
		local g = buildWorld({ blocked = function(x) return x > 1000 and 601 or nil end, height = function() return 0 end })
		fake.installAround(g, { things = HOUSE })
		local a = buildRun(g, 3111, string.format('{ res = %q, at = "2000,0", collisionDetail = true }', RAMP))
		eq(a.ok, false)
		eq(a.collisionDetail.from, "resultProposalData")
		eq(a.collisionDetail.fields.collisionInfo.collisionEntities[1].entity, 601)
		eq(a.collisionDetail.overlaps[1].meet, true, "the house's box and the ramp's meet")
		truthy(not g.crashed, g.crashed)
	end)

	test("build --collision-detail with the engine's userdata: the nested fields flat, the raising one named", function()
		local g = buildWorld({ blocked = function(x) return x > 1000 and 601 or nil end,
			proposalData = function() return engineData() end })
		fake.installAround(g, { things = HOUSE })
		local a = buildRun(g, 3121, string.format('{ res = %q, at = "2000,0", dryRun = true, engineCheck = true, ' ..
			'collisionDetail = true }', RAMP))
		local d = a.collisionDetail
		eq(d.fields.collisionInfo.collisionEntities[1].entity, 601)
		truthy(has(d.unread, function(x) return x.path == "errorState.infos" end))
		truthy(has(d.truncated, function(x) return x.path == "terrainPreviewHeightModLocations" end))
		truthy(not g.crashed, g.crashed)
	end)

	test("road --collision-detail: a dry run's check and a refused build; the piece's box from its ends", function()
		local g = roadWorld({ blocked = function(x, y) return y > 1000 and 501 or nil end })
		fake.installAround(g, { things = HOUSE })
		local d = roadRun(g, 3131, '{ from = "0,1500,10", to = "0,1600,10", snap = 0, dryRun = true, engineCheck = true, collisionDetail = true }')
		eq(d.ok, false); eq(d.collisionDetail.fields.collisionInfo.collisionEntities[1].entity, 501)
		local o = d.collisionDetail.overlaps[1]
		eq(o.entity, 501); eq(o.gap.z, 9, "the piece at 10 m, the street's box to 1 m")
		local a = roadRun(g, 3132, '{ from = "0,1500", to = "0,1600", collisionDetail = true }')
		eq(a.ok, false); eq(a.collisionDetail.from, "resultProposalData"); truthy(a.collisionDetail.overlaps)
		-- --ignore-errors: the unforced check carries it
		local f = roadRun(g, 3133, '{ from = "0,1500", to = "0,1600", dryRun = true, engineCheck = true, ignoreErrors = true, ' ..
			'_testSave = "probe-x", collisionDetail = true }')
		truthy(f.collisionDetail and f.collisionDetail.fields, "the forced dry run's own check")
		truthy(not g.crashed, g.crashed)
	end)

	test("without --collision-detail the answers are as before (no detail, nothing else changed)", function()
		local function run(flag, kind)
			local g = kind == "road" and roadWorld({ blocked = function(x, y) return y > 1000 and 501 or nil end })
				or buildWorld({ blocked = function(x) return x > 1000 and 601 or nil end })
			fake.installAround(g, { things = HOUSE })
			local extra = flag and ", collisionDetail = true" or ""
			local out = {}
			if kind == "road" then
				out[1] = roadRun(g, 3141, '{ from = "0,1500", to = "0,1600", dryRun = true, engineCheck = true' .. extra .. ' }')
				out[2] = roadRun(g, 3142, '{ from = "0,1500", to = "0,1600"' .. extra .. ' }')
			else
				out[1] = buildRun(g, 3141, string.format('{ res = %q, at = "2000,0", dryRun = true, engineCheck = true%s }', RAMP, extra))
				out[2] = buildRun(g, 3142, string.format('{ res = %q, at = "2000,0"%s }', RAMP, extra))
			end
			truthy(not g.crashed, g.crashed)
			return out
		end
		for _, kind in ipairs({ "build", "road" }) do
			local plain, detailed = run(false, kind), run(true, kind)
			for i = 1, 2 do
				eq(plain[i].collisionDetail, nil, kind .. " " .. i .. ": no detail unasked")
				truthy(detailed[i].collisionDetail, kind .. " " .. i .. ": the detail asked")
				detailed[i].collisionDetail = nil
				local same, why = deepEq(plain[i], detailed[i])
				truthy(same, kind .. " " .. i .. ": " .. tostring(why))
			end
		end
	end)
end
