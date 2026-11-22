-- reach (read only): whether a place can be got to, as the engine itself keeps it. Made to find out why the people
-- of a town do not go to a workplace (no workers, no passengers): is the workplace a target the engine marks as
-- out of reach on foot, by car, by its lines; does the town have a connection problem; is there a road or footway
-- from one place to the other at all. M.args has the forms; nothing here changes the game.
--
-- What is read (api/tealdef 40444):
--   api.engine.util.pathfinding.getTargetsByLandUse() (engine/util.d.tl UtilPathfinding; typed only "table"): the
--     engine's destinations, TargetsByLandUse.targets[] -> TargetData.entries[] -> TargetDataEntry (type.d.tl:
--     entity, capacity, freeCapacity, edgeWalk, edgeDrive, destinationWeight, isReachableDrive / Walk / Lines).
--     Read once per command, every entry's entity once, the full fields only of the entries asked about: the list
--     has every destination of the map. Which land use each of its lists is, the tealdef does not say; the answer
--     names a guess (landUseGuess) next to the list's own key, and the entity's PERSON_CAPACITY type to check it by.
--   api.engine.util.town.getTownProblems() (UtilTown: {{{town...}, TownProblem}}; Disconnected, Overlength).
--   api.engine.util.pathfinding.findPathNodeToNode(fromNodes, toNodes, modes) (UtilPathfinding: the edges of one
--     path, nothing when there is none; no cost). walk = { TransportMode.PERSON }, drive = { TransportMode.CAR }.
--     Lines have no path search the GUI can call (a person's PathFactoryOutput lives in SimEntityNeedsPath, which
--     is no ComponentType): for lines the answer gives the target's isReachableLines only.
--   the nodes of a place: a target's edgeWalk / edgeDrive (an edge of a TRANSPORT_NETWORK: its conns), a station's
--     terminals (personNodes for walking, vehicleNodeId for driving), else the transport network nodes in a circle
--     round its position or the point given (api.engine.util.octree.findTransportNetworkNodesInCircle).
-- Every engine call is in pcall and asked only about entities the engine says exist, and an engine vector is never
-- read past its size (an unknown id or index may be the engine's assertion, which pcall does not catch).
--
-- Not checked in a game yet (written 2026-11-23): the answers say so (note).
local M = {}

M.NOTE = "read only; not checked in a game yet: getTargetsByLandUse's shape, which land use each of its lists is " ..
	"(landUseGuess), and whether findPathNodeToNode finds walking paths between these nodes"
M.TARGETS_LIST_MAX = 200 -- entries listed by reach --town (counts take them all)
M.TOWN_BUILDINGS_MAX = 5000 -- town buildings read by reach --town (more: counted, not read; truncated says so)
M.PATH_NODES_MAX = 32 -- nodes of each end handed to the path search
M.RADIUS_DEFAULT = 40 -- m: the circle the nodes of a point (or of a place without its own) are taken from
M.RADIUS_MAX = 500
M.PIECES_LISTED = 50 -- the transport network entities of a path listed (pieces counts them all)
M.MODES = { walk = { "PERSON" }, drive = { "CAR" } }
M.PROBLEM_NAMES = { "Disconnected", "Overlength" }
M.LAND_USES = { "RESIDENTIAL", "COMMERCIAL", "INDUSTRIAL" }

---------------------------------------------------------------------------------------------------------------------
-- pure: the arguments and the shapes read

local function entityArg(v, name, maxId)
	local n = tonumber(v)
	if n == nil or n ~= math.floor(n) or n < 0 or n > maxId then
		return nil, name .. " must be an entity id"
	end
	return n
end

-- an end of reach --from / --to: an entity id (a number, or a string of digits) or a point "x,y" ({ x, y } too)
function M.placeArg(v, name, maxId)
	if type(v) == "number" or (type(v) == "string" and v:match("^%s*%d+%s*$")) then
		local e, err = entityArg(v, name, maxId)
		if not e then return nil, err end
		return { entity = e }
	end
	local x, y
	if type(v) == "string" then
		local a, b = v:match("^%s*([-+%d%.eE]+)%s*,%s*([-+%d%.eE]+)%s*$")
		x, y = tonumber(a), tonumber(b)
	elseif type(v) == "table" then
		x, y = tonumber(v[1] or v.x), tonumber(v[2] or v.y)
	end
	if not (x and y) or x ~= x or y ~= y or math.abs(x) == math.huge or math.abs(y) == math.huge then
		return nil, name .. " must be an entity id or a point x,y"
	end
	return { x = x, y = y }
end

-- args: api = true (which functions are there) | problems = true (every town's) | target = entity | town = entity
-- | from + to (entity or "x,y"), mode = walk | drive | all (default all), radius (m). One form a command.
function M.args(args, maxId)
	args = type(args) == "table" and args or {}
	maxId = maxId or (2 ^ 31 - 1)
	local forms = {}
	if args.api == true then forms[#forms + 1] = "api" end
	if args.problems == true then forms[#forms + 1] = "problems" end
	if args.target ~= nil then forms[#forms + 1] = "target" end
	if args.town ~= nil then forms[#forms + 1] = "town" end
	if args.from ~= nil or args.to ~= nil then forms[#forms + 1] = "path" end
	if #forms == 0 then return nil, "give one of: api, problems, target, town, from and to" end
	if #forms > 1 then return nil, "one form at a time (" .. table.concat(forms, ", ") .. ")" end
	local out = { form = forms[1] }
	if out.form == "target" or out.form == "town" then
		local e, err = entityArg(args[out.form], out.form, maxId)
		if not e then return nil, err end
		out[out.form] = e
		if out.form == "town" and args.limit ~= nil then
			local n = tonumber(args.limit)
			if n == nil or n ~= math.floor(n) or n < 0 or n > M.TARGETS_LIST_MAX then
				return nil, "limit must be a whole number from 0 to " .. M.TARGETS_LIST_MAX
			end
			out.limit = n
		end
	elseif out.form == "path" then
		if args.from == nil or args.to == nil then return nil, "give both from and to" end
		local err
		out.from, err = M.placeArg(args.from, "from", maxId)
		if not out.from then return nil, err end
		out.to, err = M.placeArg(args.to, "to", maxId)
		if not out.to then return nil, err end
		local mode = args.mode == nil and "all" or args.mode
		if mode == "all" then
			out.modes = { "walk", "drive" }
		elseif M.MODES[mode] then
			out.modes = { mode }
		elseif mode == "lines" then
			out.modes = {}
			out.linesOnly = true
		else
			return nil, "mode must be walk, drive, lines or all"
		end
		out.radius = M.RADIUS_DEFAULT
		if args.radius ~= nil then
			local r = tonumber(args.radius)
			if r == nil or r ~= r or r <= 0 or r > M.RADIUS_MAX then
				return nil, "radius must be a number of metres above 0, at most " .. M.RADIUS_MAX
			end
			out.radius = r
		end
	end
	return out
end

-- the list's land use, guessed from how many lists there are: TargetsByLandUse.targets is {TargetData, TargetData}
-- in the tealdef (two: commercial and industrial, the places a person goes to from home), three would be all
-- three land uses. ordinal: 1-based place of the list's key among the keys.
function M.landUseGuess(ordinal, count)
	if count == 2 then return ({ "commercial", "industrial" })[ordinal] end
	if count == 3 then return ({ "residential", "commercial", "industrial" })[ordinal] end
	return nil
end

-- the keys and lists of getTargetsByLandUse's answer, in key order: its targets field (TargetsByLandUse) or the
-- table itself; a Lua table by pairs, an engine vector by index. -> { { key, list } ... }, how it was read
function M.targetLists(raw, core)
	if raw == nil then return {}, "nothing" end
	local top = core.field(raw, "targets")
	local how = top ~= nil and "targets" or "top"
	if top == nil then top = raw end
	local out = {}
	if type(top) == "table" then
		local keys = {}
		for k in pairs(top) do if type(k) == "number" then keys[#keys + 1] = k end end
		table.sort(keys)
		for _, k in ipairs(keys) do out[#out + 1] = { key = k, list = top[k] } end
	else
		for i = 1, core.size(top) do out[#out + 1] = { key = i, list = core.at(top, i) } end
	end
	return out, how
end

-- the entries of one TargetData (its entries field, or the list itself when it has none)
function M.entriesOf(td, core)
	local e = core.field(td, "entries")
	if e == nil and core.size(td) > 0 then e = td end
	return core.toList(e)
end

-- an EdgeId as the tealdef types edgeWalk / edgeDrive ({integer, integer}: entity, index), or an EdgeId record
function M.edgeOf(v, core)
	if v == nil then return nil end
	local ent, idx = tonumber(core.field(v, "entity")), tonumber(core.field(v, "index"))
	if ent == nil then ent, idx = tonumber(core.at(v, 1)), tonumber(core.at(v, 2)) end
	if ent == nil or idx == nil or ent < 0 or idx < 0 then return nil end
	return { entity = ent, index = idx }
end

local function flag(v) if v == true or v == false then return v end return nil end

-- a TargetDataEntry as plain values (a field that does not read is left out)
function M.entryPlain(en, core)
	return { entity = tonumber(core.field(en, "entity")), capacity = tonumber(core.field(en, "capacity")),
		freeCapacity = tonumber(core.field(en, "freeCapacity")),
		destinationWeight = tonumber(core.field(en, "destinationWeight")),
		isReachableWalk = flag(core.field(en, "isReachableWalk")), isReachableDrive = flag(core.field(en, "isReachableDrive")),
		isReachableLines = flag(core.field(en, "isReachableLines")),
		edgeWalk = M.edgeOf(core.field(en, "edgeWalk"), core), edgeDrive = M.edgeOf(core.field(en, "edgeDrive"), core) }
end

-- the index of the targets: entity -> { { key, ordinal, entry (the engine's) } ... }, and per list its key, guess
-- and size
function M.targetIndex(raw, core)
	local lists, how = M.targetLists(raw, core)
	local byEntity, info, total = {}, {}, 0
	for ord, l in ipairs(lists) do
		local entries = M.entriesOf(l.list, core)
		info[#info + 1] = { key = l.key, landUseGuess = M.landUseGuess(ord, #lists), entries = #entries }
		for _, en in ipairs(entries) do
			total = total + 1
			local e = tonumber(core.field(en, "entity"))
			if e then
				local t = byEntity[e]
				if not t then t = {}; byEntity[e] = t end
				t[#t + 1] = { key = l.key, ordinal = ord, entry = en }
			end
		end
	end
	return { byEntity = byEntity, lists = info, total = total, how = how, count = #lists }
end

-- counts over plain entries: how many, and how many reachable walking / driving / by lines (and none of them)
function M.reachCounts(entries)
	local out = { targets = 0, walk = 0, drive = 0, lines = 0, none = 0, unknown = 0 }
	for _, e in ipairs(entries or {}) do
		out.targets = out.targets + 1
		if e.isReachableWalk == true then out.walk = out.walk + 1 end
		if e.isReachableDrive == true then out.drive = out.drive + 1 end
		if e.isReachableLines == true then out.lines = out.lines + 1 end
		if e.isReachableWalk == nil and e.isReachableDrive == nil and e.isReachableLines == nil then
			out.unknown = out.unknown + 1
		elseif e.isReachableWalk ~= true and e.isReachableDrive ~= true and e.isReachableLines ~= true then
			out.none = out.none + 1
		end
	end
	return out
end

-- getTownProblems' answer ({ { { town ... }, problem } ... }) as { { towns = { ids }, problem = name } ... };
-- names(v) names a TownProblem value
function M.townProblems(raw, core, names)
	local out = {}
	for _, p in ipairs(core.toList(raw)) do
		local towns = {}
		local list = core.at(p, 1)
		if list == nil then list = core.field(p, "towns") end
		for _, t in ipairs(core.toList(list)) do
			local n = tonumber(t)
			if n then towns[#towns + 1] = n end
		end
		local v = core.at(p, 2)
		if v == nil then v = core.field(p, "problem") end
		out[#out + 1] = { towns = towns, problem = names and names(v) or tostring(v), value = tonumber(v) }
	end
	return out
end

---------------------------------------------------------------------------------------------------------------------
-- the command

-- ctx: core, answer(id, payload, tag), fail(id, msg), try(fn), posOf(entity) -> { x, y } or nil
function M.new(ctx)
	local core, answer, fail, try = ctx.core, ctx.answer, ctx.fail, ctx.try
	local R = {}

	local function CT() return api.type.ComponentType end
	local function ctOf(kind) return try(function() return CT()[kind] end) end
	local function exists(e)
		return type(e) == "number" and e >= 0 and try(function() return api.engine.entityExists(e) end) == true
	end
	-- a component of an entity known to exist; nil when the kind is not there or the entity has none
	local function comp(e, kind)
		local k = ctOf(kind)
		if k == nil or not exists(e) then return nil end
		return try(function() return api.engine.getComponent(e, k) end)
	end
	local function nameOf(e)
		local n = try(function() return api.engine.util.getEntityName(e) end)
		return type(n) == "string" and n ~= "" and n or nil
	end
	local function ids(v)
		local out = {}
		for _, x in ipairs(core.toList(v)) do
			local n = tonumber(x)
			if n and n >= 0 then out[#out + 1] = n end
		end
		return out
	end
	local function towns()
		local set = {}
		for _, t in ipairs(ids(try(function() return api.engine.getEntitiesWithComponent(CT().TOWN) end))) do set[t] = true end
		return set
	end
	local function landUseOf(e)
		local pc = comp(e, "PERSON_CAPACITY")
		if pc == nil then return nil end
		local LU = try(function() return api.type.enum.LandUseType end)
		local v = core.field(pc, "type")
		if v == nil then return nil end
		return core.enumName(LU or {}, M.LAND_USES, v):lower(), tonumber(core.field(pc, "capacity"))
	end
	local function problemName(v)
		if v == nil then return nil end
		local en = try(function() return api.type.enum.TownProblem end)
		return core.enumName(en or {}, M.PROBLEM_NAMES, v)
	end

	local function readTargets()
		local fn = try(function() return api.engine.util.pathfinding.getTargetsByLandUse end)
		if fn == nil then return nil, "api.engine.util.pathfinding.getTargetsByLandUse is not there" end
		local ok, raw = pcall(fn)
		if not ok then return nil, "getTargetsByLandUse: " .. tostring(raw) end
		if raw == nil then return nil, "getTargetsByLandUse gave nothing" end
		return M.targetIndex(raw, core)
	end
	local function readProblems()
		local fn = try(function() return api.engine.util.town.getTownProblems end)
		if fn == nil then return nil, "api.engine.util.town.getTownProblems is not there" end
		local ok, raw = pcall(fn)
		if not ok then return nil, "getTownProblems: " .. tostring(raw) end
		return M.townProblems(raw, core, problemName)
	end
	local function problemsOf(list, town)
		local out = {}
		for _, p in ipairs(list or {}) do
			for _, t in ipairs(p.towns) do
				if t == town then
					local others = {}
					for _, o in ipairs(p.towns) do if o ~= town then others[#others + 1] = o end end
					out[#out + 1] = { problem = p.problem, with = core.array(others) }
					break
				end
			end
		end
		return core.array(out)
	end

	-- the entries of the target index for one entity, as plain values with their list's key and guess
	local function entriesFor(index, e)
		local out = {}
		for _, h in ipairs(index.byEntity[e] or {}) do
			local p = M.entryPlain(h.entry, core)
			p.landUseKey, p.landUseGuess = h.key, M.landUseGuess(h.ordinal, index.count)
			out[#out + 1] = p
		end
		return out
	end

	-- what an entity is, and the entities that may stand for it among the targets: a construction's industries,
	-- town buildings and stations; a town building's PersonCapacity entity; a station group's stations
	local function describe(e)
		local d = { entity = e, name = nameOf(e), kinds = {}, candidates = { e } }
		local function kind(k) d.kinds[#d.kinds + 1] = k end
		local function add(x) for _, c in ipairs(d.candidates) do if c == x then return end end d.candidates[#d.candidates + 1] = x end
		local con = comp(e, "CONSTRUCTION")
		if con ~= nil then
			kind("construction")
			for _, f in ipairs({ "industries", "townBuildings", "stations" }) do
				for _, x in ipairs(ids(core.field(con, f))) do add(x) end
			end
		end
		if comp(e, "INDUSTRY") ~= nil then kind("industry") end
		local tb = comp(e, "TOWN_BUILDING")
		if tb ~= nil then
			kind("townBuilding")
			d.town = tonumber(core.field(tb, "town"))
			local pc = tonumber(core.field(tb, "personCapacity"))
			if pc and pc >= 0 then add(pc) end
		end
		if comp(e, "STATION") ~= nil then kind("station") end
		local sg = comp(e, "STATION_GROUP")
		if sg ~= nil then
			kind("stationGroup")
			for _, x in ipairs(ids(core.field(sg, "stations"))) do add(x) end
		end
		if comp(e, "TOWN") ~= nil then kind("town") end
		d.landUse, d.capacity = landUseOf(e)
		return d
	end

	---------------------------------------------------------------------------------------------------------------
	-- nodes

	local function nodePlain(n)
		local ent, idx = tonumber(core.field(n, "entity")), tonumber(core.field(n, "index"))
		if ent == nil or idx == nil then return nil end
		return { entity = ent, index = idx }
	end
	local function nodeKey(p) return p.entity .. ":" .. p.index end
	-- the node list of an end: the engine's NodeIds (passed back as they came) and their plain ids, no doubles
	local function nodeSet() return { list = {}, plain = {}, seen = {}, from = {} } end
	local function addNode(set, n, why)
		if #set.list >= M.PATH_NODES_MAX then set.truncated = true; return end
		local p = nodePlain(n)
		if p == nil or set.seen[nodeKey(p)] then return end
		set.seen[nodeKey(p)] = true
		set.list[#set.list + 1] = n
		set.plain[#set.plain + 1] = p
		set.from[why] = (set.from[why] or 0) + 1
	end
	-- the two nodes of an edge of a transport network (TRANSPORT_NETWORK edges[index + 1].conns), the index
	-- checked against the size first
	local function edgeNodes(set, edge, why)
		if edge == nil then return end
		local tn = comp(edge.entity, "TRANSPORT_NETWORK")
		local edges = tn and core.field(tn, "edges")
		if edges == nil or edge.index >= core.size(edges) then return end
		local ed = core.at(edges, edge.index + 1)
		for _, n in ipairs(core.toList(ed and core.field(ed, "conns"))) do addNode(set, n, why) end
	end
	local function circleNodes(set, x, y, r)
		local found = try(function()
			return api.engine.util.octree.findTransportNetworkNodesInCircle(api.type.Vec2f.new(x, y), r)
		end)
		if found == nil then set.circleError = "findTransportNetworkNodesInCircle gave nothing"; return end
		set.circle = { x = x, y = y, radius = r, found = core.size(found) }
		for _, n in ipairs(core.toList(found)) do addNode(set, n, "circle") end
	end
	local function terminalNodes(set, station, mode)
		local st = comp(station, "STATION")
		for _, t in ipairs(core.toList(st and core.field(st, "terminals"))) do
			if mode == "walk" then
				for _, n in ipairs(core.toList(core.field(t, "personNodes"))) do addNode(set, n, "terminal") end
			else
				local v = core.field(t, "vehicleNodeId")
				if v ~= nil then addNode(set, v, "terminal") end
			end
		end
	end

	-- one end for one mode: { nodes, plain, from (how many from where), place (what it is) } or nil and why
	local function endNodes(place, mode, index, radius)
		local set = nodeSet()
		if place.entity == nil then
			circleNodes(set, place.x, place.y, radius)
			return set
		end
		local e = place.entity
		if not exists(e) then return nil, "no such entity: " .. e end
		local d = describe(e)
		set.place = d
		local targets = {}
		for _, c in ipairs(d.candidates) do
			for _, p in ipairs(index and entriesFor(index, c) or {}) do targets[#targets + 1] = p end
		end
		set.targets = targets
		for _, p in ipairs(targets) do edgeNodes(set, mode == "walk" and p.edgeWalk or p.edgeDrive, "target") end
		for _, c in ipairs(d.candidates) do
			if comp(c, "STATION") ~= nil then terminalNodes(set, c, mode) end
		end
		if #set.list == 0 then
			local pos = ctx.posOf and ctx.posOf(e)
			if pos then
				set.position = pos
				circleNodes(set, pos.x, pos.y, radius)
			end
		end
		if #set.list == 0 then set.why = "no nodes found for " .. e .. " (not a target, no station, nothing near)" end
		return set
	end

	local function modeSet(mode)
		local TM = try(function() return api.type.enum.TransportMode end)
		local out = {}
		for _, k in ipairs(M.MODES[mode]) do
			local v = TM and core.field(TM, k)
			if v ~= nil then out[#out + 1] = v end
		end
		if #out == 0 then return nil end
		return out
	end

	local function searchPath(from, to, mode)
		local res = { mode = mode, fromNodes = #from.list, toNodes = #to.list }
		if #from.list == 0 or #to.list == 0 then
			res.found = nil
			res.why = from.why or to.why or "no nodes at one end"
			return res
		end
		for k in pairs(from.seen) do
			if to.seen[k] then res.found, res.sameNode, res.edges = true, true, 0; return res end
		end
		local modes = modeSet(mode)
		if modes == nil then res.why = "api.type.enum.TransportMode is not there"; return res end
		local fn = try(function() return api.engine.util.pathfinding.findPathNodeToNode end)
		if fn == nil then res.why = "api.engine.util.pathfinding.findPathNodeToNode is not there"; return res end
		local t0 = ctx.appTime and ctx.appTime()
		local ok, path = pcall(fn, from.list, to.list, modes)
		if t0 then res.ms = math.floor((ctx.appTime() - t0) * 1000 + 0.5) end
		if not ok then res.why = "findPathNodeToNode: " .. tostring(path); return res end
		local list = core.toList(path)
		res.found, res.edges = #list > 0, #list
		local seen, pieces = {}, {}
		for _, step in ipairs(list) do
			local edge = core.at(step, 1)
			if edge == nil then edge = core.field(step, "edgeId") end
			local ent = tonumber(core.field(edge, "entity"))
			if ent and not seen[ent] then seen[ent] = true; pieces[#pieces + 1] = ent end
		end
		res.pieces = #pieces
		local listed = {}
		for i = 1, math.min(#pieces, M.PIECES_LISTED) do listed[i] = pieces[i] end
		res.pieceIds = core.array(listed)
		return res
	end

	local function endInfo(place, set)
		local out = { entity = place.entity, x = place.x, y = place.y }
		if set then
			if set.place then
				out.name, out.kinds, out.landUse = set.place.name, core.array(set.place.kinds), set.place.landUse
				out.town = set.place.town
			end
			out.targets = set.targets and core.array(set.targets) or nil
			out.circle, out.position, out.truncated = set.circle, set.position, set.truncated
		end
		return out
	end

	---------------------------------------------------------------------------------------------------------------
	-- the forms

	local forms = {}

	function forms.api(c)
		local function kindOf(fn) return type(try(fn)) end
		answer(c.id, { ok = true, note = M.NOTE, functions = {
			getTargetsByLandUse = kindOf(function() return api.engine.util.pathfinding.getTargetsByLandUse end),
			findPathNodeToNode = kindOf(function() return api.engine.util.pathfinding.findPathNodeToNode end),
			findPath = kindOf(function() return api.engine.util.pathfinding.findPath end),
			getTownProblems = kindOf(function() return api.engine.util.town.getTownProblems end),
			findTransportNetworkNodesInCircle = kindOf(function() return api.engine.util.octree.findTransportNetworkNodesInCircle end),
			TransportMode = kindOf(function() return api.type.enum.TransportMode end),
			TownProblem = kindOf(function() return api.type.enum.TownProblem end),
		} })
	end

	function forms.problems(c)
		local list, err = readProblems()
		if not list then return fail(c.id, err) end
		for _, p in ipairs(list) do
			local names = {}
			for i, t in ipairs(p.towns) do names[i] = nameOf(t) or "" end
			p.names = core.array(names)
			p.towns = core.array(p.towns)
		end
		answer(c.id, { ok = true, note = M.NOTE, problems = core.array(list), count = #list })
	end

	function forms.target(c, a)
		local e = a.target
		if not exists(e) then return fail(c.id, "no such entity: " .. e) end
		local index, err = readTargets()
		if not index then return fail(c.id, err) end
		local d = describe(e)
		local entries = {}
		for _, x in ipairs(d.candidates) do
			for _, p in ipairs(entriesFor(index, x)) do entries[#entries + 1] = p end
		end
		local res = { ok = true, note = M.NOTE, entity = e, name = d.name, kinds = core.array(d.kinds),
			landUse = d.landUse, capacity = d.capacity, candidates = core.array(d.candidates), town = d.town,
			found = #entries > 0, entries = core.array(entries), counts = M.reachCounts(entries),
			targetLists = core.array(index.lists), targetsTotal = index.total, read = index.how }
		if #entries == 0 then
			res.why = "not among the engine's targets (getTargetsByLandUse): no workplace or shop of a town's people"
		end
		-- the town's problems: the building's own town, else the closest town of an industry's construction
		local town = d.town
		if (town == nil or town < 0) and comp(e, "INDUSTRY") ~= nil then
			town = tonumber(try(function()
				local con = api.engine.system.streetConnectorSystem.getConstructionEntityForSubconstruction(e)
				return con and con >= 0 and api.engine.system.streetConnectorSystem.getConstructionClosestTown(con) or nil
			end))
		end
		if town and town >= 0 then
			res.town, res.townName = town, nameOf(town)
			local probs, perr = readProblems()
			res.townProblems = probs and problemsOf(probs, town) or nil
			res.townProblemsError = perr
		end
		answer(c.id, res)
	end

	function forms.town(c, a)
		local t = a.town
		if not towns()[t] then return fail(c.id, "entity " .. t .. " is no town (entities --kind town lists them)") end
		local index, err = readTargets()
		if not index then return fail(c.id, err) end
		local map = try(function() return api.engine.system.townBuildingSystem.getTown2BuildingMap() end)
		local list = map ~= nil and ids(try(function() return map[t] end)) or {}
		local res = { ok = true, note = M.NOTE, town = t, name = nameOf(t), buildings = #list,
			targetLists = core.array(index.lists), targetsTotal = index.total, read = index.how }
		if map == nil then res.buildingsError = "townBuildingSystem.getTown2BuildingMap gave nothing" end
		local byKind, entries, notTarget = {}, {}, 0
		for i, b in ipairs(list) do
			if i > M.TOWN_BUILDINGS_MAX then res.truncated = true; break end
			local tb = comp(b, "TOWN_BUILDING")
			local pc = tb and tonumber(core.field(tb, "personCapacity"))
			local kind = landUseOf(b) or (pc and pc >= 0 and landUseOf(pc)) or "unknown"
			byKind[kind] = (byKind[kind] or 0) + 1
			local mine = entriesFor(index, b)
			if #mine == 0 and pc and pc >= 0 and pc ~= b then mine = entriesFor(index, pc) end
			if #mine == 0 and kind ~= "residential" then notTarget = notTarget + 1 end
			for _, p in ipairs(mine) do
				p.building, p.kind = b, kind
				entries[#entries + 1] = p
			end
		end
		res.byKind, res.counts, res.notTarget = byKind, M.reachCounts(entries), notTarget
		-- the ones out of reach first (what a person looks for), then by building
		table.sort(entries, function(x, y)
			local rx = (x.isReachableWalk or x.isReachableDrive or x.isReachableLines) and 1 or 0
			local ry = (y.isReachableWalk or y.isReachableDrive or y.isReachableLines) and 1 or 0
			if rx ~= ry then return rx < ry end
			return (x.building or 0) < (y.building or 0)
		end)
		local limit = a.limit or 20
		local listed = {}
		for i = 1, math.min(#entries, limit) do listed[i] = entries[i] end
		res.entries, res.listed = core.array(listed), #listed
		local probs, perr = readProblems()
		res.problems, res.problemsError = probs and problemsOf(probs, t) or nil, perr
		answer(c.id, res)
	end

	function forms.path(c, a)
		local index, ierr
		-- targets give the nodes of a workplace or a shop; a point needs none
		if a.from.entity or a.to.entity then index, ierr = readTargets() end
		local res = { ok = true, note = M.NOTE, radius = a.radius, targetsError = ierr, paths = {} }
		local firstFrom, firstTo
		for _, mode in ipairs(a.modes) do
			local from, ferr = endNodes(a.from, mode, index, a.radius)
			if not from then return fail(c.id, "from: " .. ferr) end
			local to, terr = endNodes(a.to, mode, index, a.radius)
			if not to then return fail(c.id, "to: " .. terr) end
			firstFrom, firstTo = firstFrom or from, firstTo or to
			local p = searchPath(from, to, mode)
			p.fromFrom, p.toFrom = from.from, to.from
			res.paths[mode] = p
		end
		if a.linesOnly then
			-- no path search: the ends as they are, with their targets
			if a.from.entity and not exists(a.from.entity) then return fail(c.id, "from: no such entity: " .. a.from.entity) end
			if a.to.entity and not exists(a.to.entity) then return fail(c.id, "to: no such entity: " .. a.to.entity) end
			firstFrom = a.from.entity and endNodes(a.from, "walk", index, a.radius) or nil
			firstTo = a.to.entity and endNodes(a.to, "walk", index, a.radius) or nil
		end
		res.from, res.to = endInfo(a.from, firstFrom), endInfo(a.to, firstTo)
		-- lines: the engine's own mark on the target (reachable by lines from where its people live), not a search
		local lines = {}
		for _, p in ipairs((firstTo and firstTo.targets) or {}) do
			if p.isReachableLines ~= nil then lines[#lines + 1] = p.isReachableLines end
		end
		if #lines > 0 then
			local any = false
			for _, v in ipairs(lines) do any = any or v end
			res.lines = { targetIsReachableLines = any,
				note = "the engine's isReachableLines of the target at to; there is no line path search to call" }
		else
			res.lines = { note = "to is no target: no isReachableLines to read, and there is no line path search to call" }
		end
		answer(c.id, res)
	end

	function R.handle(c)
		local a, err = M.args(c.args, core.MAX_ENTITY_ID)
		if not a then return fail(c.id, err) end
		return forms[a.form](c, a)
	end

	return R
end

return M
