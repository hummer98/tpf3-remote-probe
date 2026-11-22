-- A stand-in for the Track Connector mod and for the parts of the game the connect command reads, laid over a
-- game of tests/fake_game.lua. Track Connector's own files are Teal (.tl), which luajit cannot load, so its
-- planner and proposal modules are fakes with the same functions, and its game script is a fake that takes the
-- same events and writes the same state fields.
--   local tc = dofile("tests/fake_tc.lua"); tc.install(g, opts)   (after fake.new, before the first command)
-- opts (all optional):
--   nodes = { [id] = { x, y, z } }, edges = { [id] = { node0, node1, road = true (a street), template } },
--   constructions = { [id] = { box = { x0, y0, x1, y1 }, stations = { ids }, frozenEdges = { ids }, depots = { depot
--     entities (the fake game's opts.depots) }, frozenNodes = { ids } } },
--   townBuildings = { [id] = { box } }, stationConstruction = { [station] = construction },
--   industries = { [id] = { box } } (an industry's part without a CONSTRUCTION component: INDUSTRY + SUBCONSTRUCTION),
--   year (what api.engine.util.getYear gives; none: no such function), availability = { [template] = { yearFrom, yearTo } },
--   height = fn(x, y), water = fn(x, y), waterLevel, bounds = { x0, y0, x1, y1 }
--   noTc (modules do not load), noScript (no game script entity), oldTc (a planner without newJob)
--   planSteps (frames the planner takes), planForever, noRoute, planError, kinds = fn(i, n) -> edgeType
--   tcDelayFrames (frames before the game script takes an event), tcSilent (it never does)
--   blocked (the dry run refuses), clearable (but fine once town buildings go), cost, extraCost (charged on top),
--   buildFails, lateCallback (the state keeps "nothing happened"), stealAfter = event name (a player picks
--   other ends right after it), refuseEvents (the event command fails)
local M = {}

local here = (debug.getinfo(1, "S").source:match("^@(.*)/tests/[^/]*$")) or "."

local function copy(v)
	if type(v) ~= "table" then return v end
	local c = {}
	for k, x in pairs(v) do c[k] = copy(x) end
	return c
end

M.STANDARD = "::/infrastructure/track/standard/standard.street_template"
M.COUNTRY = "::/infrastructure/street/country/country_new_medium.street_template"
M.TOWN = "::/infrastructure/street/town/town_medium.street_template"
M.OLD_COUNTRY = "::/infrastructure/street/country/country_old_medium.street_template"
M.ENTRANCE = "::/infrastructure/street/constructions/ind_entrance_old_country.street_template"
-- the base game's years for those (yearTo is the first year without it); a test passes them as opts.availability
M.BASE_YEARS = { [M.COUNTRY] = { yearFrom = 1940, yearTo = 0 }, [M.OLD_COUNTRY] = { yearFrom = 0, yearTo = 1940 },
	[M.ENTRANCE] = { yearFrom = 0, yearTo = 1925 } }
M.STREETS = { [M.COUNTRY] = true, [M.TOWN] = true, [M.OLD_COUNTRY] = true, [M.ENTRANCE] = true }
-- the short track names the fake game knows, and their templates (no simple track, no electric high-speed track)
M.SHORT_NAMES = {
	standard = { plain = M.STANDARD, electric = "::/infrastructure/track/standard/standard_catenary.street_template" },
	high_speed = { plain = "::/infrastructure/track/high_speed/high_speed.street_template" },
}
-- every street template the fake game has
M.TEMPLATES = {}
for name in pairs(M.STREETS) do M.TEMPLATES[name] = true end
for _, kinds in pairs(M.SHORT_NAMES) do for _, name in pairs(kinds) do M.TEMPLATES[name] = true end end

-- the modules require gives for Track Connector's paths (M.current: what the installed game has)
M.current = nil
table.insert(package.loaders or package.searchers, 2, function(name)
	if not name:match("^ethan_track_connector::/") then return nil end
	local t = M.current
	if t == nil or t.opts.noTc then return "\n\tno such mod file " .. name end
	if name:match("tc_planner%.script%.tl$") then return function() return t.planner end end
	if name:match("tc_proposal%.script%.tl$") then return function() return t.proposals end end
end)

function M.install(g, opts)
	opts = opts or {}
	package.loaded["ethan_track_connector::/track_connector/tc_planner.script.tl"] = nil
	package.loaded["ethan_track_connector::/track_connector/tc_proposal.script.tl"] = nil
	local t = { opts = opts, events = {}, queue = {}, state = {}, plans = {}, simplified = 0, worldCalls = {} }
	M.current = t
	g.tc = t
	local nodes, edges = copy(opts.nodes or {}), copy(opts.edges or {})
	local cons, tbs, inds = opts.constructions or {}, opts.townBuildings or {}, opts.industries or {}
	t.nodes, t.edges = nodes, edges
	local nextId = 9000

	local CT = api.type.ComponentType
	for _, k in ipairs({ "BASE_NODE", "BASE_EDGE", "CONSTRUCTION", "TOWN_BUILDING", "INDUSTRY", "SUBCONSTRUCTION", "TERRAIN",
		"GAME_SCRIPT" }) do CT[k] = k end
	api.type.enum.RoadType = { STREET = 0, TRACK = 1 }
	api.type.Box3 = { new = function(lo, hi) return { min = lo, max = hi } end }
	api.type.Vec2f = { new = function(x, y) return { x = x, y = y } end }

	local function segsAt(n, street)
		local out = {}
		for e, ed in pairs(edges) do
			if (ed.node0 == n or ed.node1 == n) and (ed.road == true) == street then out[#out + 1] = e end
		end
		table.sort(out)
		return out
	end
	local function edgeComp(e)
		local ed = edges[e]
		local p0, p1 = nodes[ed.node0], nodes[ed.node1]
		local d = { x = p1[1] - p0[1], y = p1[2] - p0[2], z = (p1[3] or 0) - (p0[3] or 0) }
		return { node0 = ed.node0, node1 = ed.node1, position0 = { x = p0[1], y = p0[2], z = p0[3] or 0 },
			-- (t0 / t1: a curved piece's tangents; else a straight one's)
			position1 = { x = p1[1], y = p1[2], z = p1[3] or 0 }, tangent0 = copy(ed.t0) or d, tangent1 = copy(ed.t1) or copy(d),
			roadType = ed.road and 0 or 1, type = 0, laneConfigs = ed.lanes or {}, roadTemplate = ed.template }
	end
	local function boxOf(e)
		if nodes[e] then local p = nodes[e] return { p[1] - 1, p[2] - 1, p[1] + 1, p[2] + 1 } end
		if edges[e] then
			local a, b = nodes[edges[e].node0], nodes[edges[e].node1]
			return { math.min(a[1], b[1]) - 3, math.min(a[2], b[2]) - 3, math.max(a[1], b[1]) + 3, math.max(a[2], b[2]) + 3 }
		end
		if cons[e] then return cons[e].box end
		if tbs[e] then return tbs[e].box end
		if inds[e] then return inds[e].box end
	end

	local baseComp, baseExists = api.engine.getComponent, api.engine.entityExists
	local strict -- (below: it needs to know every entity)
	api.engine.getComponent = function(e, kind)
		strict(e, "getComponent")
		if kind == "BASE_NODE" then
			local p = nodes[e]
			return p and { position = { x = p[1], y = p[2], z = p[3] or 0 } } or nil
		elseif kind == "BASE_EDGE" then
			return edges[e] and edgeComp(e) or nil
		elseif kind == "CONSTRUCTION" then
			local c = cons[e]
			-- not one of Track Connector's: the fake game's (an industry's construction, industryStocks)
			if not c then return baseComp(e, kind) end
			return { stations = copy(c.stations or {}), frozenEdges = copy(c.frozenEdges or {}), depots = copy(c.depots or {}),
				frozenNodes = copy(c.frozenNodes or {}) }
		elseif kind == "TOWN_BUILDING" then
			return tbs[e] and {} or nil
		elseif kind == "INDUSTRY" or kind == "SUBCONSTRUCTION" then
			return inds[e] and {} or nil
		elseif kind == "TERRAIN" then
			return e == 1 and { waterLevel = opts.waterLevel or 0 } or nil
		elseif kind == "GAME_SCRIPT" and e == 777 then
			-- the engine hands out a copy of the state: a change to it reaches nothing
			return (e == 777 and not opts.noScript) and { state = copy(t.state) } or nil
		elseif kind == "BOUNDING_VOLUME" and (cons[e] or tbs[e] or inds[e]) then
			local b = boxOf(e)
			return { bbox = { min = { x = b[1], y = b[2], z = 0 }, max = { x = b[3], y = b[4], z = 10 } } }
		end
		return baseComp(e, kind)
	end
	-- the world (1), the game script's entity (777), stations, and what this file and the fake game hold
	local function known(e)
		return nodes[e] ~= nil or edges[e] ~= nil or cons[e] ~= nil or tbs[e] ~= nil or inds[e] ~= nil or e == 1
			or (e == 777 and not opts.noScript)
			or baseExists(e) or baseComp(e, "STATION") ~= nil
	end
	api.engine.entityExists = known
	-- opts.strict: a lookup on an entity that does not exist ends the game, as the worst the real one may do
	strict = function(e, what)
		if opts.strict and not known(e) then
			g.crashed = "ASSERT: " .. what .. " on " .. tostring(e) .. ", which does not exist"
			error(g.crashed)
		end
	end
	local baseName = api.engine.util.getEntityName
	api.engine.util.getEntityName = function(e) strict(e, "getEntityName"); return baseName(e) end
	api.engine.terrain = {
		getBoundingBox = function()
			local b = opts.bounds or { -4000, -4000, 4000, 4000 }
			return { min = { x = b[1], y = b[2] }, max = { x = b[3], y = b[4] } }
		end,
		getHeightAt = function(v) t.worldCalls.height = (t.worldCalls.height or 0) + 1; return opts.height and opts.height(v.x, v.y) or 0 end,
		isOnWater = function(v) return opts.water ~= nil and opts.water(v.x, v.y) == true end,
	}
	local sys = api.engine.system
	-- the engine dies when asked about the pieces of an entity that is not a node (an assertion, not an error)
	local function nodeOnly(n)
		if not nodes[n] then
			g.crashed = "ASSERT: street segments asked for " .. tostring(n) .. ", which is no node"
			error(g.crashed)
		end
	end
	sys.streetSystem = {
		getNodeTrackSegments = function(n) nodeOnly(n); return segsAt(n, false) end,
		getNodeStreetSegments = function(n) nodeOnly(n); return segsAt(n, true) end,
	}
	local otherScs = sys.streetConnectorSystem
	sys.streetConnectorSystem = {
		getConstructionEntityForSubconstruction = otherScs and otherScs.getConstructionEntityForSubconstruction,
		getConstructionEntityForEdge = function(e)
			for c, x in pairs(cons) do for _, f in ipairs(x.frozenEdges or {}) do if f == e then return c end end end
			return -1
		end,
		getConstructionEntityForStation = function(st) return (opts.stationConstruction or {})[st] or -1 end,
		-- a depot's construction: the one listing it in depots (an entity that does not exist: an assertion)
		getConstructionEntityForDepot = function(d)
			if not known(d) then g.crashed = "ASSERT: getConstructionEntityForDepot on " .. tostring(d); error(g.crashed) end
			for c, x in pairs(cons) do for _, e in ipairs(x.depots or {}) do if e == d then return c end end end
			return -1
		end,
	}
	sys.octreeSystem = { findIntersectingEntities = function(box, cb)
		t.octreeCalls = (t.octreeCalls or 0) + 1
		local ids = {}
		for _, set in ipairs({ nodes, edges, cons, tbs, inds }) do for e in pairs(set) do ids[#ids + 1] = e end end
		table.sort(ids)
		for _, e in ipairs(ids) do
			local b = boxOf(e)
			if b and b[3] >= box.min.x and b[1] <= box.max.x and b[4] >= box.min.y and b[2] <= box.max.y then
				cb(e, { bbox = { min = { x = b[1], y = b[2], z = 0 }, max = { x = b[3], y = b[4], z = 10 } } })
			end
		end
	end }
	local otherScripts = sys.gameScriptSystem -- the fake game's (the base's workers script)
	sys.gameScriptSystem = { getEntityForGameScript = function(name)
		if name == "::/industries/industry_workers.gs" and otherScripts then return otherScripts.getEntityForGameScript(name) end
		t.askedScript = name
		if opts.noScript then return -1 end
		return 777
	end }
	-- (ids: each template's place in the sorted list of names)
	local tplNames = {}
	for name in pairs(M.TEMPLATES) do tplNames[#tplNames + 1] = name end
	table.sort(tplNames)
	api.res.streetTemplateRep = {
		find = function(name)
			for i, n in ipairs(tplNames) do if n == name then return i end end
			return -1
		end,
		get = function(id)
			local av = (opts.availability or {})[tplNames[id]]
			-- (opts.noAvailability: a template without one, as an unreadable field)
			if opts.noAvailability then return { maxSlopeBuild = opts.maxSlopeBuild or 0.1 } end
			return { maxSlopeBuild = opts.maxSlopeBuild or 0.1, availability = av and copy(av) or { yearFrom = 0, yearTo = 0 } }
		end,
	}
	api.engine.util.getYear = opts.year and function() return opts.year end or nil

	-----------------------------------------------------------------------------------------------------------------
	-- Track Connector's modules

	t.planner = {
		defaults = function() return { minRadius = 300, maxSlope = 0.025 } end,
		-- the fake's pick: the pair with the smallest sum of the two angles (in radians) between each end's outward
		-- direction and the way to the other end; the nearer pair on a tie
		bestPair = function(a, b)
			local function angle(dx, dy, vx, vy)
				local c = (dx * vx + dy * vy) / math.sqrt(vx * vx + vy * vy)
				return math.acos(math.max(-1, math.min(1, c)))
			end
			local pick, ba, bb
			for _, x in ipairs(a) do
				for _, y in ipairs(b) do
					local vx, vy = y.x - x.x, y.y - x.y
					if vx * vx + vy * vy > 0.25 then
						local cost = { angle(x.dx, x.dy, vx, vy) + angle(y.dx, y.dy, -vx, -vy), vx * vx + vy * vy }
						if not pick or cost[1] < pick[1] - 1e-9 or (math.abs(cost[1] - pick[1]) <= 1e-9 and cost[2] < pick[2]) then
							pick, ba, bb = cost, x, y
						end
					end
				end
			end
			return ba, bb
		end,
		simplify = function(route) t.simplified = t.simplified + 1; return route end,
		newJob = (not opts.oldTc) and function(start, goal, S, world)
			local plan = { start = start, goal = goal, S = S, world = world, steps = 0, octreeAtStart = t.octreeCalls or 0,
				frameAtStart = g.frameCount }
			t.plans[#t.plans + 1] = plan
			-- (the fields the probe reads of a planner job; the fake sets them as it goes)
			local job = {}
			job.done, job.ok, job.progress = false, false, 0
			job.message, job.stats = "fake planner: started", {}
			-- opts.coroutine: the work runs in a coroutine that step resumes, as in the real planner, and the map is
			-- also asked about opts.farPoints (blocks off the prepared band) on the first step
			local co
			local function stepBody(self, budget)
				plan.steps, plan.budget = plan.steps + 1, budget
				if opts.farPoints and plan.steps == 1 then
					for _, q in ipairs(opts.farPoints) do world.blocked(q[1], q[2]); plan.farDone = (plan.farDone or 0) + 1 end
				end
				if opts.planError then error("boom in the planner") end
				-- what the real planner asks: the map along the straight line
				local L = math.sqrt((goal.x - start.x) ^ 2 + (goal.y - start.y) ^ 2)
				local n = math.max(2, math.ceil(L / 50) + 1)
				for i = 1, n do
					local u = (i - 1) / (n - 1)
					local x, y = start.x + (goal.x - start.x) * u, start.y + (goal.y - start.y) * u
					world.height(x, y); world.water(x, y); world.blocked(x, y); world.crossing(x, y)
				end
				self.progress = math.min(1, plan.steps / (opts.planSteps or 3))
				if opts.planForever or plan.steps < (opts.planSteps or 3) then return end
				self.done = true
				if opts.noRoute then self.ok, self.message = false, "fake planner: gave up, every way is shut" return end
				local pts = {}
				local ux, uy = (goal.x - start.x) / L, (goal.y - start.y) / L
				local sl = (goal.z - start.z) / L
				for i = 1, n do
					local u = (i - 1) / (n - 1)
					pts[i] = { x = start.x + (goal.x - start.x) * u, y = start.y + (goal.y - start.y) * u, z = start.z + (goal.z - start.z) * u,
						tx = ux, ty = uy, slope = sl, s = L * u, edgeType = opts.kinds and opts.kinds(i, n) or "normal" }
				end
				self.ok, self.route, self.message = true, pts, "route found"
				self.stats = { length = L, straight = L, bridge = 0, tunnel = 0, steepest = math.abs(sl), maxCut = 0, maxFill = 0, expanded = 1234 }
				self.progress = 1
			end
			if opts.coroutine then
				job.step = function(self, budget)
					plan.resumes = (plan.resumes or 0) + 1
					co = co or coroutine.create(function()
						while true do
							stepBody(self, budget)
							if self.done then return end
							coroutine.yield()
						end
					end)
					local ok, err = coroutine.resume(co)
					if not ok then error(err) end
				end
			else
				job.step = stepBody
			end
			return job
		end or nil,
	}
	t.proposals = {
		-- what the real one is seen to do: a known full name stays, a short name becomes its template from the
		-- fake's list, and anything it cannot find becomes the standard track without a word
		templateName = function(track, electric)
			if M.TEMPLATES[track] then return track end
			local kinds = M.SHORT_NAMES[track]
			return kinds and kinds[electric and "electric" or "plain"] or M.STANDARD
		end,
		isStreet = function(name) return M.STREETS[name] == true end,
	}

	-----------------------------------------------------------------------------------------------------------------
	-- Track Connector's game script: the events, as its handleEvent takes them

	-- a free end as its game script takes one when picked (one piece of a kind, none of the other)
	local function freeAt(n)
		if nodes[n] == nil then return false end
		local tr, st = #segsAt(n, false), #segsAt(n, true)
		return (tr == 1 and st == 0) or (tr == 0 and st == 1)
	end
	-- and when a route arrives: picked as free then, and still at most one track piece (its isFreeEnd)
	local function stillFree(sel, n)
		return sel ~= nil and sel.node == n and #(sel.ends or {}) > 0 and nodes[n] ~= nil and #segsAt(n, false) <= 1
	end
	-- a new pick or new settings make everything worked out before stale
	local function forget(s)
		for _, k in ipairs({ "route", "preview", "build", "estimates" }) do s[k] = nil end
	end
	-- the outcome of a build as the probe reads it
	local function outcome(ok, short, summary) return { ok = ok, short = short, summary = summary } end
	local on = {}
	on.tc_settings = function(s, p)
		s.settings = copy(p)
		forget(s)
	end
	local function pick(side)
		return function(s, p)
			s[side] = { node = p.node, name = p.name, ends = freeAt(p.node) and { { node = p.node } } or {} }
			forget(s)
		end
	end
	on.tc_setFromEnd, on.tc_setToEnd = pick("from"), pick("to")
	on.tc_route = function(s, p)
		local r = p.route
		s.build, s.route = nil, nil
		local cost = opts.cost or 1000 * #r.x
		if not (stillFree(s.from, r.fromNode) and stillFree(s.to, r.toNode)) then
			s.preview = outcome(false, "[fake] stale ends", "[fake] an end is not the one picked, or not free")
		elseif opts.blocked then
			s.route = copy(r)
			s.preview = outcome(false, "[fake] refused", "[fake] dry run $" .. cost .. ", refused")
		else
			s.route = copy(r)
			s.preview = outcome(true, string.format("%.1f km, $%d", r.length / 1000, cost), "[fake] dry run $" .. cost .. ", fine")
		end
	end
	on.tc_estimate = function(s, p)
		local r = p.route
		local est = { ok = not opts.blocked, cost = opts.cost or 1000 * #r.x, n = #r.x, len = r.length, errors = "" }
		if opts.blocked then
			est.errors, est.problem, est.blockers = "[fake] collision", "[fake] houses in the way", "[fake] house 4711"
			if opts.clearable then est.clear, est.clearCost, est.clearCount = true, (opts.cost or 1000 * #r.x) + 500, 2 end
		end
		s.estimates = s.estimates or {}
		s.estimates[p.key] = est
	end
	on.tc_build = function(s, p)
		s.builds = (s.builds or 0) + 1
		local r = s.route
		if r == nil then s.build = outcome(false, "[fake] no route", "[fake] no route held") return end
		local cost = opts.cost or 1000 * #r.x
		if opts.blocked and not (p.clear and opts.clearable) then
			s.build = outcome(false, "[fake] build refused", "[fake] houses in the way")
			return
		end
		if g.balance < cost then
			s.build = outcome(false, "[fake] too dear", string.format("[fake] balance %d below cost %d", g.balance, cost))
			return
		end
		if opts.buildFails then
			-- (buildFails = "quiet": the outcome as it starts out, before its text is filled in)
			s.build = opts.buildFails == "quiet" and outcome(false, "[fake] build refused", "")
				or outcome(false, "build failed", "[fake] the engine said no")
			return
		end
		g.balance = g.balance - cost - (opts.extraCost or 0)
		-- the new pieces: a node at every inner point, joined to the two ends
		local prev = r.fromNode
		for i = 2, #r.x do
			local n = r.toNode
			if i < #r.x then
				nextId = nextId + 1
				n = nextId
				nodes[n] = { r.x[i], r.y[i], r.z[i] }
			end
			nextId = nextId + 1
			edges[nextId] = { node0 = prev, node1 = n, road = opts.roadBuild }
			t.built = (t.built or 0) + 1
			prev = n
		end
		-- (lateCallback: the outcome still reads as before its build command's callback; the probe goes by that text)
		s.build = opts.lateCallback and outcome(false, "nothing happened", "") or outcome(true, "[fake] built $" .. cost, "[fake] built $" .. cost)
		s.route, s.preview = nil, nil
	end
	local function handle(ev)
		local s, p = t.state, ev.param
		t.events[#t.events + 1] = ev.name
		if on[ev.name] then on[ev.name](s, p) end
		if opts.alterRoute and ev.name == "tc_route" and s.route then
			-- someone else's route between the same ends (one point fewer)
			for _, f in ipairs({ "x", "y", "z", "tx", "ty", "slope", "kind", "level" }) do table.remove(s.route[f]) end
		end
		if opts.stealAfter == ev.name then
			-- a player picks other ends with the tool right then
			s.from = { node = 1, name = "someone else's end", ends = {} }
			for _, k in ipairs({ "route", "preview", "estimates" }) do s[k] = nil end
		end
	end

	api.cmd.makeScriptingSendEventCmd = function(src, id, name, param)
		return { kind = "tcEvent", src = src, id = id, name = name, param = copy(param) }
	end
	local baseSend = api.cmd.sendCommand
	api.cmd.sendCommand = function(cmd, cb)
		if cmd.kind ~= "tcEvent" then return baseSend(cmd, cb) end
		g.commands[#g.commands + 1] = cmd
		t.sent = t.sent or {}
		t.sent[#t.sent + 1] = cmd.name
		if opts.refuseEvents then
			if cb then cb(cmd, false) end
			return
		end
		-- only the game script's own id is taken (its handleEvent: id ~= "TrackConnector" returns at once)
		-- (opts.dropBuild: the build event goes astray)
		if cmd.id == "TrackConnector" and not opts.tcSilent and not (opts.dropBuild and cmd.name == "tc_build") then t.queue[#t.queue + 1] = { frames = opts.tcDelayFrames or 1, ev = cmd } end
		if cb then cb(cmd, true) end
	end
	local baseStep = g.step
	g.step = function(dt)
		g.frameCount = (g.frameCount or 0) + 1
		local keep = {}
		for _, q in ipairs(t.queue) do
			q.frames = q.frames - 1
			if q.frames <= 0 then handle(q.ev) else keep[#keep + 1] = q end
		end
		t.queue = keep
		baseStep(dt)
	end
	return t
end

return M
