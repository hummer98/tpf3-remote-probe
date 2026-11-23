-- The engine's side of reach (content/remote_reach.lua) and of persons --town / --destination, installed over a
-- fake game of tests/fake_game.lua (fake.new). Kept in a file of its own, next to the fakes others change.
--
-- spec.towns = { [town] = name }; spec.buildings = { [b] = { town, kind = "RESIDENTIAL" | "COMMERCIAL" | "INDUSTRIAL"
--   (nil: no PERSON_CAPACITY), capacity, pc (a PersonCapacity entity of its own, which holds the PERSON_CAPACITY
--   instead) } }; spec.industries = { [i] = { name, construction, capacity } } (PERSON_CAPACITY INDUSTRIAL);
-- spec.constructions = { [c] = { industries = {}, townBuildings = {}, stations = {}, transf = { 16 numbers } } };
-- spec.targets = { { entries = { { entity, capacity, walk, drive, lines, edgeWalk = { tn, index }, edgeDrive } } },
--   ... }: getTargetsByLandUse's lists in order (spec.targetsShape = "list": the lists without the targets field;
--   spec.noTargets: the function is not there; spec.targetsError: it raises);
-- spec.tn = { [tnEntity] = { edges = { { n0, n1, modes = { "CAR", "PERSON" } } ... }, nodes = N } }: transport
--   network entities; a node is { entity, index } written "tn:index" in spec.graph; n0 / n1 an index within the
--   entity, or "e:i" for a node of another (a piece's lane ending in its junction's network); modes: the edge's
--   transportModes (none: an empty map); nodes: how many nodes its network has;
-- spec.edges = { [e] = { node0, node1 } }: road pieces (BASE_EDGE); spec.baseNodes = { [n] = true }: junctions
--   (BASE_NODE); give them a spec.tn entry for their networks and spec.positions for their places;
-- api.type.NodeId.new(entity, index) is there (spec.noNodeIdNew: not); spec.modesAsNumbers: transportModes values
--   1 instead of true; spec.modesOpaque: transportModes a userdata that does not read;
-- spec.graph = { walk = { ["a:0"] = { "a:1", ... } }, drive = { ... } }: directed links per mode (PERSON: walk, CAR:
--   drive); findPathNodeToNode does a breadth-first search and gives the edges as { { { entity = tn, index = k },
--   true } ... } (the tn of the node it reached);
-- spec.stations = { [st] = { terminals = { { personNodes = { "a:0" }, vehicleNode = "a:1" } }, catchmentAreas =
--   { { x, y, radius } } } };
-- spec.circle = { { x, y, node = "a:0" } }: the nodes findTransportNetworkNodesInCircle finds;
-- spec.positions = { [e] = { x, y } } (BOUNDING_VOLUME);
-- spec.problems = { { towns = { 11, 12 }, problem = "Disconnected" } };
-- spec.persons = { [p] = { home, destinations, walkDrive = { n, n }, lines = { n, n } } }: getSimPersonsForDestination
--   gives those with the entity among their destinations (the entity must hold a PERSON_CAPACITY: else the engine's
--   assertion, g.crashed);
-- spec.targetsShape also "zeroBased" (Lua tables from 0, lists and entries), "byName" ({ COMMERCIAL = , INDUSTRIAL =
-- }), "flat" (the entries in one list), "opaque" (a userdata with neither # nor pairs);
-- "indexOnly" / "indexOnly0" / "metaGetter" / "noBinding" / "getter" / "twoValues" / "pairNothing" (read by name
-- only: see there);
-- spec.buildings[b].personNodes = { "tn:i" }: its PERSON_CAPACITY's personNodes; spec.pathError: the search raises;
-- spec.userdata: the engine's answers as userdata. Asking getComponent for an entity the engine does not have, or
-- reading an engine vector past its end, is the engine's assertion (g.crashed).
-- g.reachCalls = { targets, problems, path, circle, forDestination } counts; g.pathModes: the modes of each search.
local M = {}

function M.install(g, spec)
	spec = spec or {}
	g.reachCalls = { targets = 0, problems = 0, path = 0, circle = 0, forDestination = 0 }
	g.pathModes = {}
	local function crash(msg) g.crashed = msg; error(msg) end
	local function asUserdata(t)
		local u = newproxy(true)
		getmetatable(u).__index = function(_, k)
			if type(k) == "number" and (k < 1 or k > #t) then crash("ASSERT: vector read past its end: " .. k) end
			return t[k]
		end
		getmetatable(u).__len = function() return #t end
		return u
	end
	local function wrap(t) if spec.userdata then return asUserdata(t) end return t end
	local towns, buildings, industries = spec.towns or {}, spec.buildings or {}, spec.industries or {}
	local cons, tn, stations = spec.constructions or {}, spec.tn or {}, spec.stations or {}
	local positions, persons = spec.positions or {}, spec.persons or {}
	local pcOwner = {}
	for b, x in pairs(buildings) do if x.pc then pcOwner[x.pc] = b end end
	local LU = api.type.enum.LandUseType
	local TM = api.type.enum.TransportMode
	api.type.enum.TownProblem = { Disconnected = 0, Overlength = 1 }
	local CT = api.type.ComponentType
	for _, k in ipairs({ "TOWN", "TOWN_BUILDING", "PERSON_CAPACITY", "CONSTRUCTION", "INDUSTRY", "STATION",
		"STATION_GROUP", "TRANSPORT_NETWORK", "BOUNDING_VOLUME", "BASE_EDGE", "BASE_NODE" }) do CT[k] = CT[k] or k end
	local edgesB, baseNodes = spec.edges or {}, spec.baseNodes or {}
	api.type.Vec2f = api.type.Vec2f or { new = function(x, y) return { x = x, y = y } end }
	local function node(s)
		local e, i = s:match("^(%d+):(%d+)$")
		return wrap({ entity = tonumber(e), index = tonumber(i) })
	end
	local function key(n) return tostring(n.entity) .. ":" .. tostring(n.index) end
	local function known(e)
		return towns[e] ~= nil or buildings[e] ~= nil or pcOwner[e] ~= nil or industries[e] ~= nil or cons[e] ~= nil
			or tn[e] ~= nil or stations[e] ~= nil or persons[e] ~= nil or edgesB[e] ~= nil or baseNodes[e] ~= nil
	end
	api.type.NodeId = api.type.NodeId or {}
	api.type.NodeId.new = not spec.noNodeIdNew and function(e, i)
		if type(e) ~= "number" or type(i) ~= "number" then crash("NodeId.new: not (entity, index)") end
		return wrap({ entity = e, index = i })
	end or nil

	local exists, getComponent, getEntities = api.engine.entityExists, api.engine.getComponent,
		api.engine.getEntitiesWithComponent
	api.engine.entityExists = function(e) return known(e) or exists(e) end
	api.engine.getEntitiesWithComponent = function(kind, filter)
		if kind == "TOWN" and spec.towns then
			local ids = {}
			for t in pairs(towns) do ids[#ids + 1] = t end
			table.sort(ids)
			return wrap(ids)
		end
		return getEntities(kind, filter)
	end
	api.engine.getComponent = function(e, kind)
		if not known(e) then return getComponent(e, kind) end
		if kind == "TOWN" then return towns[e] and {} or nil end
		local b = buildings[e]
		if kind == "TOWN_BUILDING" then
			return b and wrap({ town = b.town or -1, personCapacity = b.pc or e, stockList = -1 }) or nil
		end
		if kind == "PERSON_CAPACITY" then
			if b and b.kind and not b.pc then
				local pn = {}
				for j, x in ipairs(b.personNodes or {}) do pn[j] = node(x) end
				return wrap({ type = LU[b.kind], capacity = b.capacity or 0, personNodes = wrap(pn), vehicleNodes = wrap({}) })
			end
			local ob = pcOwner[e] and buildings[pcOwner[e]]
			if ob and ob.kind then return wrap({ type = LU[ob.kind], capacity = ob.capacity or 0 }) end
			if industries[e] and industries[e].capacity then return wrap({ type = LU.INDUSTRIAL, capacity = industries[e].capacity }) end
			return nil
		end
		if kind == "INDUSTRY" then return industries[e] and wrap({ stockList = -1 }) or nil end
		if kind == "CONSTRUCTION" and cons[e] then
			local c = cons[e]
			return wrap({ industries = wrap(c.industries or {}), townBuildings = wrap(c.townBuildings or {}),
				stations = wrap(c.stations or {}), fileName = "x.con", transf = c.transf and wrap(c.transf) or nil })
		end
		if kind == "STATION" and stations[e] then
			local ts = {}
			for i, t in ipairs(stations[e].terminals or {}) do
				local pn = {}
				for j, s in ipairs(t.personNodes or {}) do pn[j] = node(s) end
				ts[i] = wrap({ personNodes = wrap(pn), vehicleNodeId = t.vehicleNode and node(t.vehicleNode) or nil })
				-- t.cargo: a cargo terminal (its load flags read so); else no flags
				if t.cargo then
					ts[i] = wrap({ personNodes = wrap(pn), passengersLoad = false, passengersUnload = false, cargoLoad = true,
						cargoUnload = true })
				end
			end
			-- catchmentAreas = { { x, y, r } }: CatchmentArea { position (a Vec3f; spec.areaShape "list": { x, y, z }),
			-- radius }
			local areas = {}
			for i, a in ipairs(stations[e].catchmentAreas or {}) do
				local pos = spec.areaShape == "list" and wrap({ a[1], a[2], 0 }) or wrap({ x = a[1], y = a[2], z = 0 })
				areas[i] = wrap({ position = pos, radius = a[3] })
			end
			return wrap({ terminals = wrap(ts), cargo = false, catchmentAreas = wrap(areas) })
		end
		if kind == "TRANSPORT_NETWORK" and tn[e] then
			local edges = {}
			local function at(x) return node(type(x) == "string" and x or (e .. ":" .. x)) end
			for i, ed in ipairs(tn[e].edges or {}) do
				local tm = {}
				for _, m in ipairs(ed.modes or {}) do tm[TM[m]] = spec.modesAsNumbers and 1 or true end
				-- spec.modesOpaque: a map that neither pairs nor indexes (the engine's, should it be so)
				if spec.modesOpaque then
					tm = newproxy(true)
					getmetatable(tm).__index = function() error("no index") end
				end
				edges[i] = wrap({ conns = wrap({ at(ed[1]), at(ed[2]) }), transportModes = tm })
			end
			local nodes = {}
			for i = 1, tn[e].nodes or 0 do nodes[i] = wrap({ position = { x = 0, y = 0, z = 0 } }) end
			return wrap({ nodes = wrap(nodes), edges = wrap(edges) })
		end
		if kind == "BASE_EDGE" and edgesB[e] then
			return wrap({ node0 = edgesB[e][1], node1 = edgesB[e][2], type = 0 })
		end
		if kind == "BASE_NODE" and baseNodes[e] then return wrap({ position = { x = 0, y = 0, z = 0 } }) end
		if kind == "BOUNDING_VOLUME" and positions[e] then
			local p = positions[e]
			return { bbox = { min = { x = p[1] - 5, y = p[2] - 5, z = 0 }, max = { x = p[1] + 5, y = p[2] + 5, z = 0 } } }
		end
		if kind == "SIM_PERSON" and persons[e] then
			local p = persons[e]
			return wrap({ happiness = p.happiness or 0.8, destinations = wrap(p.destinations or { p.home or -1, -1, -1 }),
				targetOrAtEntity = -1, lastMoveMode = 0, cargoType = 0,
				landUse2ReachableWalkDrive = p.walkDrive and wrap(p.walkDrive) or nil,
				landUse2ReachableLines = p.lines and wrap(p.lines) or nil })
		end
		if persons[e] then return nil end
		return nil
	end

	local names = api.engine.util.getEntityName
	api.engine.util.getEntityName = function(e)
		if towns[e] then return towns[e] end
		if industries[e] then return industries[e].name end
		return names(e)
	end

	-- pathfinding
	api.engine.util.pathfinding = {}
	if not spec.noTargets then
		api.engine.util.pathfinding.getTargetsByLandUse = function()
			g.reachCalls.targets = g.reachCalls.targets + 1
			if spec.targetsError then error("targets boom") end
			local lists = {}
			for i, l in ipairs(spec.targets or {}) do
				local entries = {}
				for j, x in ipairs(l.entries or {}) do
					entries[j] = wrap({ entity = x.entity, capacity = x.capacity or 0, freeCapacity = x.free or 0,
						destinationWeight = 1, isReachableWalk = x.walk == true, isReachableDrive = x.drive == true,
						isReachableLines = x.lines == true,
						edgeWalk = x.edgeWalk and wrap({ x.edgeWalk[1], x.edgeWalk[2] }) or wrap({ -1, -1 }),
						edgeDrive = x.edgeDrive and wrap({ x.edgeDrive[1], x.edgeDrive[2] }) or wrap({ -1, -1 }) })
				end
				lists[i] = wrap({ entries = wrap(entries), edges = wrap({}) })
			end
			if spec.targetsShape == "list" then return wrap(lists) end
			-- Lua tables from 0, the lists and their entries (as C++ arrays turned into tables may come)
			local function from0(t) local o = {}; for i, x in ipairs(t) do o[i - 1] = x end; return o end
			if spec.targetsShape == "zeroBased" then
				local o = {}
				for i, l in ipairs(lists) do o[i - 1] = { entries = from0(l.entries), edges = {} } end
				return { targets = o }
			end
			if spec.targetsShape == "byName" then
				return { COMMERCIAL = lists[1], INDUSTRIAL = lists[2] }
			end
			if spec.targetsShape == "flat" then
				local o = {}
				for _, l in ipairs(lists) do for _, e in ipairs(l.entries) do o[#o + 1] = e end end
				return wrap(o)
			end
			-- userdata read by pairs only: no __len (pairsOnly) or one that says 0 (lenZero), at each level
			if spec.targetsShape == "pairsOnly" or spec.targetsShape == "lenZero" then
				local function po(t)
					local u = newproxy(true)
					local m = getmetatable(u)
					m.__index = function(_, k)
						if type(k) == "number" then crash("ASSERT: index read of a pairs-only object: " .. k) end
						return t[k]
					end
					m.__pairs = function() return next, t, nil end
					if spec.targetsShape == "lenZero" then m.__len = function() return 0 end end
					return u
				end
				local o = {}
				for i, l in ipairs(lists) do
					local es = {}
					for j, e in ipairs(l.entries) do es[j] = e end
					o[i] = po({ entries = po(es), edges = po({}) })
				end
				return po({ targets = po(o) })
			end
			-- a TargetData that reads by nothing, round an empty vector of entries (shape "emptyInside")
			if spec.targetsShape == "emptyInside" then
				local u = newproxy(true)
				getmetatable(u).__index = function(_, k)
					if k == "entries" then return asUserdata({}) end
					error("no field " .. tostring(k))
				end
				return { targets = asUserdata({ u, u }) }
			end
			-- objects read by name only (an __index function; no __len, no pairs), as the game's TargetsByLandUse:
			-- indexOnly (its targets a pair from 1), indexOnly0 (from 0), metaGetter (targets only as a getter kept in
			-- the metatable), noBinding (reading targets raises)
			local function byName(t, extra)
				local u = newproxy(true)
				local m = getmetatable(u)
				m.__index = function(self, k)
					if spec.targetsShape == "noBinding" and k == "targets" then error("no Lua binding for targets") end
					-- a pair from 0 read past its end: the engine's assertion
					if spec.targetsShape == "indexOnly0" and type(k) == "number" and t.isPair and (k < 0 or k > 1) then
						crash("ASSERT: pair read past its end: " .. k)
					end
					if spec.targetsShape == "twoValues" and k == "targets" then return t.first, t.second end
					return t[k]
				end
				m.__tostring = function() return "TargetsByLandUse: 0x2" end
				for k, v in pairs(extra or {}) do m[k] = v end
				return u
			end
			if spec.targetsShape == "indexOnly" or spec.targetsShape == "indexOnly0" or spec.targetsShape == "noBinding" then
				local pair = {}
				local base = spec.targetsShape == "indexOnly0" and 0 or 1
				for i, l in ipairs(lists) do
					pair[i - 1 + base] = byName({ entries = asUserdata(l.entries), edges = asUserdata({}) })
				end
				pair.isPair = true
				return byName({ targets = byName(pair) })
			end
			-- getter: targets a member function (called with the object only; without it, a null read: a crash);
			-- twoValues: targets read gives the two TargetData as two values; pairNothing: a pair nothing reads by number
			local function tds()
				local o = {}
				for i, l in ipairs(lists) do o[i] = byName({ entries = asUserdata(l.entries) }) end
				return o
			end
			if spec.targetsShape == "getter" then
				local root
				root = byName({ targets = function(self)
					if self ~= root then crash("ASSERT: member function called without its object") end
					return byName(tds())
				end })
				return root
			end
			if spec.targetsShape == "twoValues" then
				local o = tds()
				return byName({ first = o[1], second = o[2] })
			end
			if spec.targetsShape == "pairNothing" then
				return byName({ targets = byName({}) })
			end
			if spec.targetsShape == "metaGetter" then
				local pair = {}
				for i, l in ipairs(lists) do pair[i] = byName({ entries = asUserdata(l.entries) }) end
				return byName({}, { targets = function(self) return byName(pair) end })
			end
			if spec.targetsShape == "opaque" then
				-- an object with neither # nor pairs, whose index raises
				local u = newproxy(true)
				getmetatable(u).__index = function(_, k) error("no field " .. tostring(k)) end
				getmetatable(u).__tostring = function() return "TargetsByLandUse: 0x1" end
				return u
			end
			return { targets = wrap(lists) }
		end
	end
	api.engine.util.pathfinding.findPathNodeToNode = function(from, to, modes)
		g.reachCalls.path = g.reachCalls.path + 1
		local m = modes[1]
		g.pathModes[#g.pathModes + 1] = m
		if spec.pathError then error("path boom") end
		local graph = (spec.graph or {})[m == TM.PERSON and "walk" or (m == TM.CAR and "drive") or "?"] or {}
		local goal, queue, seen = {}, {}, {}
		for i = 1, #to do goal[key(to[i])] = true end
		for i = 1, #from do
			local k = key(from[i])
			if not seen[k] then seen[k] = { prev = nil }; queue[#queue + 1] = k end
		end
		local head = 1
		while head <= #queue do
			local k = queue[head]; head = head + 1
			if goal[k] and seen[k].prev then
				local path = {}
				while seen[k].prev do
					local e = tonumber(k:match("^(%d+):"))
					table.insert(path, 1, wrap({ wrap({ entity = e, index = 0 }), true }))
					k = seen[k].prev
				end
				return wrap(path)
			end
			for _, n in ipairs(graph[k] or {}) do
				if not seen[n] then seen[n] = { prev = k }; queue[#queue + 1] = n end
			end
		end
		return wrap({})
	end
	api.engine.util.town = api.engine.util.town or {}
	api.engine.util.town.getTownProblems = function()
		g.reachCalls.problems = g.reachCalls.problems + 1
		local out = {}
		for i, p in ipairs(spec.problems or {}) do
			out[i] = wrap({ wrap(p.towns), api.type.enum.TownProblem[p.problem] })
		end
		return wrap(out)
	end
	api.engine.util.octree = api.engine.util.octree or {}
	api.engine.util.octree.findTransportNetworkNodesInCircle = function(c, r)
		g.reachCalls.circle = g.reachCalls.circle + 1
		if type(c) ~= "table" or c.x == nil then crash("findTransportNetworkNodesInCircle: no Vec2f") end
		local out = {}
		for _, n in ipairs(spec.circle or {}) do
			if (n[1] - c.x) ^ 2 + (n[2] - c.y) ^ 2 <= r * r then out[#out + 1] = node(n.node) end
		end
		return wrap(out)
	end

	-- the town's buildings, and who has a destination
	local sys = api.engine.system
	sys.townBuildingSystem = sys.townBuildingSystem or {}
	local t2b = sys.townBuildingSystem.getTown2BuildingMap
	sys.townBuildingSystem.getTown2BuildingMap = function()
		if not spec.towns then return t2b and t2b() or {} end
		local m = {}
		for t in pairs(towns) do m[t] = {} end
		local ids = {}
		for b in pairs(buildings) do ids[#ids + 1] = b end
		table.sort(ids)
		for _, b in ipairs(ids) do
			local t = buildings[b].town
			if m[t] then m[t][#m[t] + 1] = b end
		end
		for t, l in pairs(m) do m[t] = wrap(l) end
		return m
	end
	sys.streetConnectorSystem = sys.streetConnectorSystem or {}
	local sub = sys.streetConnectorSystem.getConstructionEntityForSubconstruction
	sys.streetConnectorSystem.getConstructionEntityForSubconstruction = function(e)
		if industries[e] then return industries[e].construction or -1 end
		return sub and sub(e) or -1
	end
	-- spec.stationConstruction = { [station] = construction }
	sys.streetConnectorSystem.getConstructionEntityForStation = function(st)
		if not stations[st] then crash("ASSERT: construction of " .. tostring(st) .. ", no station") end
		return (spec.stationConstruction or {})[st] or -1
	end
	sys.streetConnectorSystem.getConstructionClosestTown = function(c)
		if not cons[c] then crash("ASSERT: closest town of " .. tostring(c) .. ", no construction") end
		return cons[c].town or -1
	end
	sys.simPersonSystem = sys.simPersonSystem or {}
	local forDest = sys.simPersonSystem.getSimPersonsForDestination
	sys.simPersonSystem.getSimPersonsForDestination = function(e)
		if not known(e) then return forDest(e) end
		g.reachCalls.forDestination = g.reachCalls.forDestination + 1
		if api.engine.getComponent(e, "PERSON_CAPACITY") == nil then crash("ASSERT: no person capacity for " .. tostring(e)) end
		local ids = {}
		for p, x in pairs(persons) do
			for _, d in ipairs(x.destinations or { x.home }) do if d == e then ids[#ids + 1] = p; break end end
		end
		table.sort(ids)
		return wrap(ids)
	end
	api.engine.util.cargo = api.engine.util.cargo or {}
	local good = api.engine.util.cargo.isGoodQuality
	api.engine.util.cargo.isGoodQuality = function(e)
		if persons[e] then return (persons[e].happiness or 0.8) >= 0.5 end
		return good(e)
	end
end

return M
