-- One construction (a .con: a depot, a station, an asset, an industry) put on the map for the remote probe (build),
-- and ones the probe put there taken away again (build remove), so a mod's construction can be placed, looked at
-- (frame) and placed again without someone at the mouse. No click and no key: a SimpleProposal with one
-- ConstructionEntity goes to the engine as api.cmd.makeWorldBuildProposalCmd, from guiUpdate, the way a mod's own
-- tool builds (nova auto_piers.script.lua: the same proposal, context and callback from its guiUpdate; AoM's
-- strawberry farm). The engine checks the proposal as it checks the player's: collisions, terrain, money; with
-- ignoreErrors off a refused build is not built, and its messages come back in the callback's resultProposalData.
--
-- Not checked in a game yet (written 2026-11-22): the answer says so.
local M = {}

local RESULT_SEC = 30 -- for the command's callback
local SETTLE_FRAMES = 5 -- before the balance after a build is read: a cost booked after the callback is in it
local MAX_SUGGEST = 12
local NEAR_M = 30 -- the dry run lists constructions this near the point (a rough look, not the engine's check)
local FIND_M = 60 -- after a lost callback, how far from the point the new construction is looked for by its name

-- ctx: core, answer(id, payload, tag), fail(id, msg), appTime(), try(fn), say(msg, level)
function M.new(ctx)
	local core, answer, fail, appTime, try, say = ctx.core, ctx.answer, ctx.fail, ctx.appTime, ctx.try, ctx.say
	local jobs = {}
	local built = {} -- [construction] = { res, x, y, z } for what this load of the probe built
	local count = 0
	local finishRoad, roadLost -- (the road command's, below)
	local joinsOf -- (below, before finish)
	local streetEdgesNear -- (below, after place: place and joinsOf call it)
	local describeHits -- (remote_around.lua's describe, set by the script: B.setDescribeHits)
	local NODES_BEFORE_M = 150

	local function CT() return api.type.ComponentType end
	local function comp(e, kind)
		return try(function() return api.engine.getComponent(e, CT()[kind]) end)
	end
	local function player() return try(function() return api.engine.util.getPlayer() end) end
	local function balance() return tonumber(try(function() return api.engine.util.finance.getPlayersBalance(player()) end)) end
	local function nameOf(e) return try(function() return api.engine.util.getEntityName(e) end) end
	local function strings(v)
		local out = {}
		for _, s in ipairs(core.toList(v)) do out[#out + 1] = tostring(s) end
		return core.array(out)
	end
	-- an entity list as the engine hands it: ids, or { id, revision } pairs (the callback's third argument)
	local function ids(v)
		local out = {}
		for _, x in ipairs(core.toList(v)) do
			local e = tonumber(x) or tonumber(core.field(x, 1))
			if e then out[#out + 1] = e end
		end
		return out
	end

	-- the resName the engine knows, or nil with names that look alike (a mod's file content/<dir>/x.con.lua is
	-- "<modId>::/<dir>/x.con")
	local function resolve(res)
		for _, name in ipairs(core.buildResCandidates(res)) do
			local idx = tonumber(try(function() return api.res.constructionRep.find(name) end))
			if idx and idx >= 0 then return name, idx end
		end
		-- alike: the same file name, or another construction of the same mod
		local stem = (res:gsub("%.lua$", ""):gsub("%.con$", ""):match("([^/:]+)$") or res):lower()
		local mod = res:match("^([^:]+)::")
		local like = {}
		for _, name in pairs(try(function() return api.res.constructionRep.getAll() end) or {}) do
			if type(name) == "string" and (name:lower():find(stem, 1, true)
				or (mod and name:sub(1, #mod + 2) == mod .. "::")) then
				like[#like + 1] = name
			end
		end
		table.sort(like)
		while #like > MAX_SUGGEST do table.remove(like) end
		return nil, nil, like
	end

	-- a module's desc by its resName (moduleRep): the desc, or false when the rep knows the name but get gives
	-- nothing; nil with names that look alike: the same file name, or another module in the same folder (a
	-- harbour's are all in one)
	local function moduleOf(name)
		local idx = tonumber(try(function() return api.res.moduleRep.find(name) end))
		if idx and idx >= 0 then return try(function() return api.res.moduleRep.get(idx) end) or false end
		local stem = (name:gsub("%.lua$", ""):gsub("%.module$", ""):match("([^/:]+)$") or name):lower()
		local dir = name:match("^(.*/)[^/]*$")
		local like = {}
		for _, n in pairs(try(function() return api.res.moduleRep.getAll() end) or {}) do
			if type(n) == "string" and (n:lower():find(stem, 1, true) or (dir and n:sub(1, #dir) == dir)) then
				like[#like + 1] = n
			end
		end
		table.sort(like)
		while #like > MAX_SUGGEST do table.remove(like) end
		return nil, like
	end

	-- the desc's metadata and updateScript as values the params can carry: metadata is a Lua table
	-- (ModuleDesc.metadata : table), or an engine map turned into one with asTable; nil when neither (the caller
	-- refuses then: a harbour's module scripts read mod.metadata.platform unchecked, modules.script.lua). The
	-- ScriptRef is an engine record, copied out as { fileName, params } (params a table, else empty)
	local function moduleDesc(d)
		local us = core.field(d, "updateScript")
		local file = us and core.field(us, "fileName")
		local script
		if type(file) == "string" and file ~= "" then
			local p = core.field(us, "params")
			script = { fileName = file, params = type(p) == "table" and p or {} }
		end
		local md = core.field(d, "metadata")
		if type(md) == "userdata" then
			local ok, t = pcall(function() return md:asTable() end)
			md = ok and t or nil
		end
		return { metadata = type(md) == "table" and md or nil, updateScript = script }
	end

	-- every module's name checked before anything is sent; with fill, what each lacks filled from its desc, and
	-- a module whose metadata is neither given nor readable refused (it would go without one).
	-- -> filled ({ [slot] = { field names } }) and warnings (a list or nil), or nil and why
	local function checkModules(mods, fill)
		local slots = {}
		for k in pairs(mods) do slots[#slots + 1] = k end
		table.sort(slots)
		local filled, bad, warn = {}, {}, {}
		for _, k in ipairs(slots) do
			local m = mods[k]
			local d, like = moduleOf(m.name)
			if d == nil then
				local msg = string.format("slot %d: no module %s", k, m.name)
				if like and #like > 0 then msg = msg .. " (names like it: " .. table.concat(like, ", ") .. ")" end
				bad[#bad + 1] = msg
			elseif fill then
				local desc = d and moduleDesc(d) or {}
				if m.metadata == nil and desc.metadata == nil then
					bad[#bad + 1] = string.format("slot %d: metadata of %s could not be read", k, m.name)
				else
					filled[k] = core.fillModule(m, desc)
				end
			elseif m.metadata == nil then
				warn[#warn + 1] = string.format("slot %d: %s goes without metadata (--no-fill-modules); a module "
					.. "script that reads it may fail", k, m.name)
			end
		end
		if #bad > 0 then return nil, "nothing sent: " .. table.concat(bad, "; ") end
		return filled, #warn > 0 and core.array(warn) or nil
	end

	local function waterLevel()
		return tonumber(try(function()
			return api.engine.getComponent(api.engine.util.getWorld(), CT().TERRAIN).waterLevel
		end))
	end
	-- true / false, or nil when it could not be read; isOnWater is asked only for a point isValidCoordinate takes
	-- (off the map it may assert), so a point off the map, or one that cannot be checked, is nil and the second
	-- value says why ("outside" / "unchecked")
	local function onWater(x, y)
		local valid = try(function() return api.engine.terrain.isValidCoordinate(api.type.Vec2f.new(x, y)) end)
		if valid ~= true then return nil, valid == false and "outside" or "unchecked" end
		local w = try(function() return api.engine.terrain.isOnWater(api.type.Vec2f.new(x, y)) end)
		if w == true or w == false then return w end
		return nil
	end
	local function heightAt(x, y)
		return tonumber(try(function() return api.engine.terrain.getHeightAt(api.type.Vec2f.new(x, y)) end))
	end

	-- the terminals of a construction's stations (STATION.terminals), or nil when it has no station or none reads
	local function terminalsOf(stations)
		local total, per, read = 0, {}, false
		for _, st in ipairs(stations or {}) do
			local sc = comp(st, "STATION")
			local n = sc and core.size(core.field(sc, "terminals"))
			if n then read = true; total = total + n end
			per[#per + 1] = { station = st, terminals = n }
		end
		if not read then return nil end
		return total, core.array(per)
	end

	-- the construction's params as the base's menu starts them (core.buildDefaults)
	local function defaultsOf(idx)
		local desc = try(function() return api.res.constructionRep.get(idx) end)
		local list = {}
		for _, p in ipairs(core.toList(desc and core.field(desc, "params"))) do
			list[#list + 1] = { key = core.field(p, "key"), defaultIndex = core.field(p, "defaultIndex"),
				numbers = core.toList(core.field(p, "numbers")) }
		end
		return core.buildDefaults(list)
	end

	-- a turn about the vertical and the position (the 4th column, transf[13..15], as the engine's constructions)
	local function transfOf(x, y, z, angle)
		local c, s = math.cos(angle), math.sin(angle)
		local V = api.type.Vec4f.new
		return api.type.Mat4f.new(V(c, s, 0, 0), V(-s, c, 0, 0), V(0, 0, 1, 0), V(x, y, z, 1))
	end

	-- fields: let the proposal take farm fields in its way (gatherFields, as Track Connector's and the road upgrade
	-- brush's contexts do; the base's tools warn "fields will be removed" and build). Without it a field in the
	-- way is a collision: a road by a forest was refused so although the dry run had said buildable with that
	-- warning (2026-11-23)
	-- buildings: let it take town buildings in its way (gatherBuildings, as the player's tools do: --remove-buildings);
	-- streets: cleanupStreetGraph (--join-streets: whether a construction's road end put on a node of a road becomes
	-- one node with it, not checked in a game yet)
	local function context(fields, buildings, streets)
		local c = api.type.Context.new()
		c.player = player()
		-- nothing of the player's or a town's is knocked down for it unless asked: what is in the way is a refusal
		c.cleanupStreetGraph, c.gatherBuildings, c.gatherFields = streets == true, buildings == true, fields == true
		return c
	end

	-- what the engine said about a proposal (ProposalData): copied out as plain values, in the callback itself
	local function verdict(data)
		local es = data and try(function() return data.errorState end)
		local col = data and try(function() return data.collisionInfo.collisionEntities end)
		local hit = {}
		for _, d in ipairs(core.toList(col)) do
			local e = tonumber(core.field(d, "entity")) or tonumber(d)
			if e then hit[#hit + 1] = e end
		end
		return {
			critical = es and try(function() return es.critical end) == true or nil,
			errors = es and strings(try(function() return es.messages end)) or nil,
			warnings = es and strings(try(function() return es.warnings end)) or nil,
			collisions = #hit > 0 and core.array(hit) or nil,
			-- the town buildings the proposal takes away (CollisionInfo.buildingEntities, type.d.tl; with gatherBuildings)
			buildingsInWay = (function()
				local b = ids(data and try(function() return data.collisionInfo.buildingEntities end))
				return #b > 0 and core.array(b) or nil
			end)(),
			cost = data and tonumber(try(function() return data.costs end)) or nil,
		}
	end

	local function setOf(list)
		local s = {}
		for _, x in ipairs(list) do s[x] = true end
		return s
	end
	local function nodePos(n)
		local bn = comp(n, "BASE_NODE")
		local p = bn and core.field(bn, "position")
		local x, y, z = tonumber(core.field(p, "x")), tonumber(core.field(p, "y")), tonumber(core.field(p, "z"))
		if not (x and y and z) then return nil end
		return { x = x, y = y, z = z }
	end

	-- the street pieces at a node as the street system lists them (engine/system.d.tl streetSystem
	-- .getNodeStreetSegments, as Track Connector and Smart Lanes read a node): ids, or nil when it is not there or
	-- raises. The octree does not do for this: at a T (an industry's road stub with its two arms) a circle of 1 m
	-- around the node met none of its pieces (2026-11-23, a forest's node 4077; the pieces' shapes drawing back
	-- from the node is a guess).
	local function streetSegmentsAt(n)
		local ok, v = pcall(function() return api.engine.system.streetSystem.getNodeStreetSegments(n) end)
		if not ok or v == nil then return nil end
		return ids(v)
	end

	-- whether a road node carries its junction set-up (BaseNodeConfig: its lane connections, engine.d.tl): true or
	-- false, nil when that cannot be told (no BASE_NODE_CONFIG component type, or the engine raises). A node a
	-- script's street proposal made without nodeConfigsToAdd probably has none (Track Connector's tc_proposal says
	-- so of roads a script built). On 2026-11-23 the game died right after a road snapped to an earlier road's node
	-- (Engine.h:322 GetComponentDataIndex, a node without BaseNodeConfig), when this command sent no set-ups;
	-- joins to such ends with one piece had gone through before. Since then this command gives its new nodes one
	-- (nodeConfigsToAdd, below) and reads it back (the answer's newNodeConfigs).
	local function nodeConfigState(n)
		local ct = try(function() return CT().BASE_NODE_CONFIG end)
		if ct == nil then return nil end
		local ok, v = pcall(function() return api.engine.getComponent(n, ct) end)
		if not ok then return nil end
		return v ~= nil
	end

	-- whether a node is a construction's (an industry's road stub, a station's entrance road): { construction,
	-- fileName, frozen, by } or nil (the second value: why the street connector system could not be asked, else
	-- nil). Asked of the street connector system first (getConstructionEntityForNode, as Overpass Builder and Move
	-- It ask), else through its pieces: a frozen edge of a construction at the node (getConstructionEntityForEdge,
	-- and the edge among that construction's frozenEdges; a construction's free pieces, an industry's arms, are
	-- not counted). frozen: the node is among the construction's frozenNodes (the construction keeps it; a road
	-- to a forest's inner end was refused by the engine, 2026-11-23); when the list does not read, a node whose
	-- pieces are all frozen edges counts as frozen. segs: the node's pieces (streetSegmentsAt).
	local function constructionOfNode(n, segs)
		local sc = try(function() return api.engine.system.streetConnectorSystem end)
		local owner, by, unread
		if sc ~= nil then
			local ok, v = pcall(function() return sc.getConstructionEntityForNode(n) end)
			if ok then
				v = tonumber(v)
				if v and v >= 0 then owner, by = v, "node" end
			else
				unread = "getConstructionEntityForNode: " .. tostring(v)
			end
		else
			unread = "no streetConnectorSystem"
		end
		local edgeAsked = false
		if owner == nil then
			for _, e in ipairs(segs or {}) do
				local ok, v = pcall(function() return sc.getConstructionEntityForEdge(e) end)
				if ok then edgeAsked = true end
				v = ok and tonumber(v) or nil
				if v and v >= 0 then
					local c = comp(v, "CONSTRUCTION")
					-- (a construction that does not read: taken as the node's, so that its set-up is left alone)
					if not c or setOf(ids(core.field(c, "frozenEdges")))[e] then owner, by = v, "frozenEdge"; break end
				end
			end
		end
		-- (unread only when neither way could be asked: the caller refuses then, as for an unread set-up)
		if owner == nil then return nil, (not edgeAsked) and unread or nil end
		local c = comp(owner, "CONSTRUCTION")
		local frozenE = c and setOf(ids(core.field(c, "frozenEdges"))) or {}
		local fn = c and core.field(c, "frozenNodes")
		local frozen
		if fn ~= nil then
			frozen = setOf(ids(fn))[n] == true
		else
			frozen = segs ~= nil and #segs > 0
			for _, e in ipairs(segs or {}) do if not frozenE[e] then frozen = false end end
		end
		return { construction = owner, fileName = c and tostring(core.field(c, "fileName")) or nil, frozen = frozen,
			by = by, frozenNodesUnread = fn == nil or nil }, unread
	end

	-- a node as the answers show it: id, position, how many street pieces meet there, whether it has its set-up
	-- the track pieces at a node (streetSystem.getNodeTrackSegments, engine/system.d.tl:315): ids, or nil when it is
	-- not there or raises. Asked only of a node a construction's track piece names (a node is never asked about
	-- by an id that may be no node: the lookups assume one)
	local function trackSegmentsAt(n)
		local ok, v = pcall(function() return api.engine.system.streetSystem.getNodeTrackSegments(n) end)
		if not ok or v == nil then return nil end
		return ids(v)
	end

	-- a node as the answers show it: id, position, how many pieces of its kind meet there (track: tracks; else
	-- roads), and for a road node whether it has its set-up (a track node's is not asked about)
	local function nodeEntry(n, extra, track)
		local p = nodePos(n) or {}
		local segs = track and trackSegmentsAt(n) or (not track and streetSegmentsAt(n)) or nil
		local out = { node = n, x = p.x, y = p.y, z = p.z, edges = segs and #segs or nil, track = track == true }
		if not track then
			local cfg = nodeConfigState(n)
			out.nodeConfig = cfg == nil and "unread" or cfg
		end
		for k, v in pairs(extra or {}) do out[k] = v end
		return out
	end

	-- where a road or a track can join a construction (road --to, connect --to there): its open ends ("mouth": a
	-- node of a frozen edge that is not among frozenNodes; an industry's road stub ends there in a T with two free
	-- arms, forest.script.lua street_cross_01 / 02; a rail depot's track leaves at one) and the far ends of the
	-- free pieces of the same kind that leave a mouth ("arm": one piece on, the arms' snapNodes end). Each says
	-- track true (a track node) or false (a road node). The ends list (frozen edges only) shows neither the arms
	-- nor their far ends. nil and why when the construction's frozenNodes or the street system cannot be read.
	local function connectableOf(c)
		local fe = ids(core.field(c, "frozenEdges"))
		if #fe == 0 then return nil end
		local fnRaw = core.field(c, "frozenNodes")
		if fnRaw == nil then return nil, "the construction's frozenNodes could not be read" end
		local frozenN, frozenE = setOf(ids(fnRaw)), setOf(fe)
		local mouths, seen = {}, {}
		local street = try(function() return api.type.enum.RoadType.STREET end)
		local trackT = try(function() return api.type.enum.RoadType.TRACK end)
		for _, edge in ipairs(fe) do
			local be = comp(edge, "BASE_EDGE")
			-- (a piece whose kind does not read is left out: neither system is asked about its nodes)
			local rt = be and core.field(be, "roadType")
			local track
			if rt ~= nil and street ~= nil and rt == street then track = false
			elseif rt ~= nil and trackT ~= nil and rt == trackT then track = true end
			if track ~= nil then
				for _, k in ipairs({ "node0", "node1" }) do
					local n = tonumber(core.field(be, k))
					if n and not frozenN[n] and not seen[n] then
						seen[n] = true
						mouths[#mouths + 1] = { node = n, track = track }
					end
				end
			end
		end
		local out, why = {}, nil
		for _, m in ipairs(mouths) do
			local segs
			if m.track then segs = trackSegmentsAt(m.node) else segs = streetSegmentsAt(m.node) end
			-- joined: pieces at the mouth that are not the construction's frozen ones (a road or track joined to it;
			-- also its own free pieces, an industry's arms)
			local others = {}
			for _, s in ipairs(segs or {}) do if not frozenE[s] then others[#others + 1] = s end end
			out[#out + 1] = nodeEntry(m.node, { kind = "mouth", joined = segs ~= nil and #others > 0 or nil,
				joinedPieces = #others > 0 and core.array(others) or nil }, m.track)
			if segs == nil then
				why = (m.track and "streetSystem.getNodeTrackSegments" or "streetSystem.getNodeStreetSegments") ..
					" could not be read: no arms"
			end
			for _, s in ipairs(segs or {}) do
				if not frozenE[s] then
					local be = comp(s, "BASE_EDGE")
					local n0, n1 = tonumber(be and core.field(be, "node0")), tonumber(be and core.field(be, "node1"))
					local far = n0 == m.node and n1 or n0
					if far and far ~= m.node and not seen[far] then
						local entry = nodeEntry(far, { kind = "arm", from = m.node, via = s }, m.track)
						-- (a track arm only when its far end is free: a station or depot built against a line has the
						-- line's next node there, which connect would refuse as no free end)
						if not m.track or entry.edges == 1 then
							seen[far] = true
							out[#out + 1] = entry
						end
					end
				end
			end
		end
		return #out > 0 and core.array(out) or nil, why
	end

	-- the new construction, read back: its file, name, depots / stations / industries, and the free ends of its own
	-- roads and tracks (nodes only one of its pieces reaches, with their positions: a connect --from), and where a
	-- road or a track can join it (connectable: connectableOf)
	local function describe(e)
		local c = comp(e, "CONSTRUCTION")
		if not c then return nil end
		local seen, order = {}, {}
		for _, edge in ipairs(core.toList(core.field(c, "frozenEdges"))) do
			local be = comp(edge, "BASE_EDGE")
			for _, k in ipairs({ "node0", "node1" }) do
				local n = tonumber(be and core.field(be, k))
				if n then
					if not seen[n] then order[#order + 1] = n end
					seen[n] = (seen[n] or 0) + 1
				end
			end
		end
		local ends = {}
		for _, n in ipairs(order) do
			if seen[n] == 1 then
				local bn = comp(n, "BASE_NODE")
				local p = bn and core.field(bn, "position")
				ends[#ends + 1] = { node = n, x = tonumber(core.field(p, "x")), y = tonumber(core.field(p, "y")),
					z = tonumber(core.field(p, "z")) }
			end
		end
		local function list(k)
			local out = ids(core.field(c, k))
			return #out > 0 and core.array(out) or nil
		end
		local okC, conn, connWhy = pcall(connectableOf, c)
		if not okC then conn, connWhy = nil, tostring(conn) end
		-- where it stands and its turn (transf), and each end's place in its own frame (local: dx along its x, dy
		-- along its y): where its road leaves it, wherever it is put
		local t = core.field(c, "transf")
		local tx, ty, tz = tonumber(core.field(t, 13)), tonumber(core.field(t, 14)), tonumber(core.field(t, 15))
		local angle = core.transfAngle(tonumber(core.field(t, 1)), tonumber(core.field(t, 2)))
		local place
		if tx and ty then
			place = { x = tx, y = ty, z = tz, angle = angle }
			for _, list2 in ipairs({ ends, conn or {} }) do
				for _, en in ipairs(list2) do
					if en.x and en.y then en["local"] = core.toLocal(place, en.x, en.y, en.z) end
				end
			end
		end
		return { entity = e, fileName = tostring(core.field(c, "fileName")), name = nameOf(e), at = place,
			ends = #ends > 0 and core.array(ends) or nil, depots = list("depots"), stations = list("stations"),
			industries = list("industries"), connectable = conn, connectableWhy = connWhy }
	end

	-- what the engine has under an id now, for build remove (core.buildRemovable): file, position, name, mark
	local function conInfo(e)
		local c = comp(e, "CONSTRUCTION")
		if not c then return nil end
		local t = core.field(c, "transf")
		local params
		local pn = core.field(c, "params_native")
		if pn ~= nil then
			local ok, tb = pcall(function() return pn:asTable() end)
			if ok and type(tb) == "table" then params = tb end
		end
		local mark = params and params[core.BUILD_MARK]
		if mark == nil then mark = core.field(core.field(c, "params"), core.BUILD_MARK) end
		return { fileName = tostring(core.field(c, "fileName")), x = tonumber(core.field(t, 13)),
			y = tonumber(core.field(t, 14)), name = nameOf(e), marked = tonumber(mark) == 1 }
	end

	-- the constructions whose box meets a square of r metres around x, y (the octree, as remote_connect reads it)
	local function constructionsNear(x, y, r)
		local found, seen = {}, {}
		pcall(function()
			local box = api.type.Box3.new(api.type.Vec3f.new(x - r, y - r, -1000), api.type.Vec3f.new(x + r, y + r, 5000))
			api.engine.system.octreeSystem.findIntersectingEntities(box, function(e)
				e = tonumber(e)
				if e and not seen[e] and comp(e, "CONSTRUCTION") then
					seen[e] = true
					found[#found + 1] = e
				end
			end)
		end)
		table.sort(found)
		return found
	end

	local NOTE = "not checked in a game yet: look at it (frame) before trusting the answer"
	local NOTE_MODULES = "modules with whole-number slot ids, autoFillSlots off; not checked in a game yet"

	local function place(c, r)
		local res, idx, like = resolve(r.res)
		if not res then
			local msg = "no construction " .. r.res .. " (constructionRep.find gives -1 for it and for "
				.. table.concat(core.buildResCandidates(r.res), ", ") .. ")"
			if like and #like > 0 then msg = msg .. "; names like it: " .. table.concat(like, ", ") end
			return fail(c.id, msg)
		end
		local z, zFrom = r.z, "given"
		if z == nil then
			z = tonumber(try(function() return api.engine.terrain.getHeightAt(api.type.Vec2f.new(r.x, r.y)) end))
			zFrom = "terrain"
			if z == nil then return fail(c.id, "the terrain's height at x,y could not be read: give z") end
		end
		local params = core.buildParams(defaultsOf(idx), r.params, r.seed)
		local filled, moduleWarnings
		if r.modules then
			-- a module the rep does not know is refused here, not sent (what the engine does with one: not checked)
			local f, w = checkModules(params.modules, r.fillModules)
			if not f then return fail(c.id, w) end
			filled, moduleWarnings = f, w
		end
		count = count + 1
		local name = r.name or string.format("%s %d", core.BUILD_NAME_PREFIX, count)
		local sp = api.type.SimpleProposal.new()
		local ce = api.type.SimpleProposal.ConstructionEntity.new()
		ce.fileName = res
		ce.params = params
		ce.transf = transfOf(r.x, r.y, z, r.angle)
		ce.name = name
		-- noOwner: no company's (an industry, as AoM's strawberry farm builds one: playerEntity -1)
		ce.playerEntity = r.noOwner and -1 or player()
		-- (a station's or a depot's module slots as the player's menu fills them; with modules given, only those:
		-- AoM's strawberries.lua turns it off when it hands its own)
		ce.autoFillSlots = not r.modules
		-- the whole list at once: an element written into the engine's list is lost (AoM strawberries.lua, in game
		-- 2026-11-16: "build done", 0 entities)
		sp.constructionsToAdd = { ce }
		local shown = params
		if r.modules then
			shown = {}
			for k, v in pairs(params) do shown[k] = v end
			shown.modules = core.moduleSummary(params.modules, filled)
		end
		local out = { res = res, at = { x = r.x, y = r.y, z = z }, zFrom = zFrom, angle = r.angle, params = shown,
			name = name, note = NOTE, autoFillSlots = ce.autoFillSlots, owner = r.noOwner and "none" or nil,
			modulesNote = r.modules and NOTE_MODULES or nil, moduleWarnings = moduleWarnings }
		if r.dryRun then
			-- the probe's own checks only (no buildable: only a build says that). The engine's makeProposalData is
			-- typed for a Proposal (engine/util.d.tl:939), but Overpass Builder hands it a SimpleProposal on the GUI
			-- thread and the road's dry run does so too (engineCheck, below); a construction's is not asked yet
			out.ok, out.dryRun, out.checked = true, true, false
			out.why = "checked here: the name, the params sent and the height; the engine's check (collisions, terrain, "
				.. "money) only comes with a build"
			local near = {}
			for _, e in ipairs(constructionsNear(r.x, r.y, NEAR_M)) do
				local info = conInfo(e)
				near[#near + 1] = { entity = e, fileName = info and info.fileName, name = info and info.name }
			end
			out.nearRadius = NEAR_M
			out.near = core.array(near)
			-- the water there (a harbour stands at the shore): the level, and whether the point itself is water
			local w, off = onWater(r.x, r.y)
			out.waterLevel, out.onWater, out.offMap = waterLevel(), w, off == "outside" or nil
			return answer(c.id, out)
		end
		-- (the job is listed once the command is sent: a send that raises is answered by the handler's pcall alone)
		out.removeBuildings, out.joinStreets = r.removeBuildings or nil, r.joinStreets or nil
		if r.removeBuildings or r.joinStreets then
			out.contextNote = "gatherBuildings " .. tostring(r.removeBuildings == true) .. ", cleanupStreetGraph " ..
				tostring(r.joinStreets == true) .. ": not checked in a game yet what the engine does with them: look at it"
		end
		-- the road nodes there before (so the answer can tell a mouth that took an old node from a new one)
		local nodesBefore = {}
		for _, e in ipairs(streetEdgesNear(r.x, r.y, NODES_BEFORE_M)) do
			local be = comp(e, "BASE_EDGE")
			for _, k in ipairs({ "node0", "node1" }) do
				local n = tonumber(be and core.field(be, k))
				if n then nodesBefore[n] = true end
			end
		end
		local job = { id = c.id, kind = "place", out = out, started = appTime(), before = balance(), nodesBefore = nodesBefore }
		api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(sp, context(false, r.removeBuildings, r.joinStreets), false, true), function(data, success, entities)
			-- all of it guarded, as AoM's strawberries.lua: it may run where an error has no one to catch it. Only
			-- plain values leave the callback (the engine's objects belong to it)
			local ok, err = pcall(function()
				local v = verdict(try(function() return data.resultProposalData end))
				local list = ids(try(function() return data.resultEntities end))
				if #list == 0 then list = ids(entities) end
				job.result = { success = success == true, verdict = v, entities = list }
			end)
			if not ok then job.result = { success = success == true, verdict = { callbackError = tostring(err) }, entities = {} } end
		end)
		jobs[#jobs + 1] = job
	end

	local function remove(c, r)
		local list, forgotten = r.remove, nil
		if r.removeAll then
			-- what this load built and still stands as it was built; the rest is dropped from the list (gone, or the
			-- id given again to something else) and named in the answer, never removed
			list, forgotten = {}, {}
			local all = {}
			for e in pairs(built) do all[#all + 1] = e end
			table.sort(all)
			for _, e in ipairs(all) do
				local info = conInfo(e)
				if info and core.buildRemovable(built[e], info) then
					list[#list + 1] = e
				else
					built[e] = nil
					forgotten[#forgotten + 1] = e
				end
			end
			if #list == 0 then
				return fail(c.id, "this load of the probe built nothing that still stands as built"
					.. (#forgotten > 0 and (" (forgotten: " .. table.concat(forgotten, ", ") .. ")") or "")
					.. "; after a load give the ids: those named " .. core.BUILD_NAME_PREFIX .. "... with the probe's mark are taken")
			end
		end
		local bad = {}
		for _, e in ipairs(list) do
			local info = conInfo(e)
			if not info then
				bad[#bad + 1] = string.format("%d is no construction", e)
			else
				local ok, why = core.buildRemovable(built[e], info)
				if not ok then bad[#bad + 1] = string.format("%d (%s, %s): %s", e, tostring(info.name), info.fileName, why) end
			end
		end
		if #bad > 0 then return fail(c.id, "nothing removed: " .. table.concat(bad, "; ")) end
		local sp = api.type.SimpleProposal.new()
		sp.constructionsToRemove = list
		local job = { id = c.id, kind = "remove", out = { removed = core.array(list), note = NOTE,
			forgotten = forgotten and #forgotten > 0 and core.array(forgotten) or nil }, started = appTime(),
			before = balance(), list = list }
		api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(sp, context(), false, true), function(data, success)
			local ok, err = pcall(function()
				job.result = { success = success == true, verdict = verdict(try(function() return data.resultProposalData end)) }
			end)
			if not ok then job.result = { success = success == true, verdict = { callbackError = tostring(err) } } end
		end)
		jobs[#jobs + 1] = job
	end

	-- each road mouth of a new construction: its node, whether that node was there before the build (an old road's
	-- node the construction took), and the other road nodes within JOIN_M of it (a node beside it, not one with it)
	local JOIN_M = 0.5
	function joinsOf(d, before)
		local out = {}
		for _, m in ipairs(d and d.connectable or {}) do
			if m.kind == "mouth" and m.x and m.y then
				local j = { node = m.node, track = m.track, x = m.x, y = m.y, joined = m.joined,
					joinedPieces = m.joinedPieces, wasThere = before and before[m.node] == true or false }
				if not m.track then
					local near, seen = {}, {}
					for _, e in ipairs(streetEdgesNear(m.x, m.y, 2)) do
						local be = comp(e, "BASE_EDGE")
						for _, k in ipairs({ "node0", "node1" }) do
							local n = tonumber(be and core.field(be, k))
							local p = n and n ~= m.node and not seen[n] and nodePos(n)
							if p then
								seen[n] = true
								local dd = math.sqrt((p.x - m.x) ^ 2 + (p.y - m.y) ^ 2 + ((p.z or 0) - (m.z or 0)) ^ 2)
								if dd <= JOIN_M then near[#near + 1] = { node = n, d = dd, wasThere = before and before[n] == true or false } end
							end
						end
					end
					j.nodesHere = core.array(near)
				end
				out[#out + 1] = j
			end
		end
		return #out > 0 and core.array(out) or nil
	end

	local function finish(job)
		local out, res = job.out, job.result
		for k, v in pairs(res.verdict) do out[k] = v end
		out.balanceBefore, out.balanceAfter = job.before, balance()
		if out.balanceBefore and out.balanceAfter then out.spent = out.balanceBefore - out.balanceAfter end
		if job.kind == "road" then
			finishRoad(job, out, res)
		elseif job.kind == "place" then
			local cons = {}
			for _, e in ipairs(res.entities) do
				local d = describe(e)
				if d then cons[#cons + 1] = d end
			end
			out.entities = core.array(res.entities)
			-- the engine can say success and build nothing: a construction whose update script fails its own check
			-- (2026-11-22, a harbour: "Terminal 2 of station ... not supported by the vehicle node: SHIP" in the
			-- log, "Error during construction update") comes back with success, no errors, no entities, cost 0.
			-- Only a construction read back says it stands: one not among the entities is looked for by its name
			-- near the point first, as after a lost callback
			if res.success and not cons[1] then
				for _, e in ipairs(constructionsNear(out.at.x, out.at.y, FIND_M)) do
					local info = conInfo(e)
					if info and info.name == out.name and info.fileName == out.res and not built[e] then
						local d = describe(e)
						if d then cons[1] = d; out.why = "not among the result's entities; found by its name near the point" end
						break
					end
				end
			end
			if res.success and not cons[1] then
				local why = #res.entities == 0 and "the engine said success but gave back no entities"
					or "the engine said success but no construction is among the entities it gave back"
				if (out.cost or 0) == 0 and (out.spent or 0) == 0 then why = why .. ", and nothing was paid" end
				out.ok = false
				out.error = "nothing was built: " .. why .. " (the construction's own script may have failed: look "
					.. "for \"Error during construction update\" in the game's log)"
				say("build place (command " .. job.id .. "): nothing built: " .. why, 1)
				return answer(job.id, out, "error")
			end
			if res.success then
				out.entity = cons[1].entity
				out.construction = cons[1]
				for _, d in ipairs(cons) do built[d.entity] = { res = out.res, x = out.at.x, y = out.at.y, z = out.at.z } end
				if (out.cost or 0) == 0 and (out.spent or 0) == 0 then
					-- it stands (read back), so it is ok; a free build is real with a no-costs mod, but say so
					local w = out.warnings or core.array({})
					w[#w + 1] = "built, but it cost nothing (cost 0, spent 0): a no-costs mod, or look at it"
					out.warnings = w
				end
				out.joins = joinsOf(cons[1], job.nodesBefore)
				-- a station construction (a harbour) with no terminal: its modules may be on no slot
				local d = cons[1]
				if d and d.stations then
					local total, per = terminalsOf(d.stations)
					out.terminals, out.stationTerminals = total, per
					if total == 0 then
						out.warning = "its stations have 0 terminals: the modules may not be on their slots (look at it)"
					end
				end
			end
		elseif job.kind == "remove" then
			if res.success then
				for _, e in ipairs(job.list) do
					if not comp(e, "CONSTRUCTION") then built[e] = nil end
				end
			end
		end
		if not res.success then
			out.ok = false
			local msgs = out.errors and #out.errors > 0 and table.concat(out.errors, "; ") or "no message"
			out.error = "the engine refused it: " .. msgs
			if out.collisions and describeHits then
				-- what is in the way, one by one: its kind, name, place and box (remote_around.lua)
				local ref = job.kind == "place" and out.at or (out.from and out.to and
					{ x = (out.from.x + out.to.x) / 2, y = (out.from.y + out.to.y) / 2 }) or nil
				local okH, hits = pcall(describeHits, out.collisions, ref and ref.x, ref and ref.y)
				if okH then out.hits = hits else out.hitsError = tostring(hits) end
			end
			if job.kind == "road" and not out.removeFields and out.collisions then
				-- (what a dry run's buildable with warnings meant, 2026-11-23: fields in the way)
				out.hint = "a collision: if it is with farm fields (road --dry-run --engine-check warns that fields will " ..
					"be removed), --remove-fields lets them go; buildings and tracks are still refused"
			end
			say("build " .. job.kind .. " (command " .. job.id .. "): refused: " .. msgs, 1)
			return answer(job.id, out, "error")
		end
		out.ok = true
		answer(job.id, out)
	end

	-- no callback in RESULT_SEC: a place may still have been built. It is looked for near its point by its name
	-- and file (each build gets a name of its own, probe-build N); found, it is the probe's, as if the callback came
	local function lost(job)
		local why = string.format("no answer from the engine in %d s", RESULT_SEC)
		if job.kind == "road" then return roadLost(job, why) end
		if job.kind == "place" then
			local o = job.out
			for _, e in ipairs(constructionsNear(o.at.x, o.at.y, FIND_M)) do
				local info = conInfo(e)
				if info and info.name == o.name and info.fileName == o.res and not built[e] then
					job.result = { success = true, verdict = {}, entities = { e } }
					o.why = why .. "; found by its name " .. o.name .. " near the point"
					return finish(job)
				end
			end
			return fail(job.id, why .. "; nothing named " .. o.name .. " (" .. o.res .. ") within " .. FIND_M
				.. " m of the point. If it shows up later it carries that name: build --remove <id> takes it")
		end
		fail(job.id, why .. " (look at the map: it may be gone)")
	end

	local B = {}

	-- whether a type with this availability ({ yearFrom, yearTo }) can be built in year: 0 is no limit, nil
	-- availability or year is no check (as remote_connect.lua M.availableIn); -1, the base's "never", is never
	local function availableIn(av, year)
		if type(av) ~= "table" or type(year) ~= "number" then return true end
		local from, to = tonumber(av.yearFrom) or 0, tonumber(av.yearTo) or 0
		if from < 0 or to < 0 then return false end
		return (from == 0 or from <= year) and (to == 0 or year < to)
	end

	---------------------------------------------------------------------------------------------------------------
	-- road: one straight road piece between two points, as a SimpleStreetProposal (type.d.tl SimpleStreetProposal:
	-- nodesToAdd and edgesToAdd, new entities counted down from -1), sent like a construction. An end within snap
	-- metres of a node with road pieces is that node (the piece joins the road there); else a new node on the
	-- terrain (or at the z given). The piece is the template's: its lanes, style and type (BaseEdge in engine.d.tl:
	-- roadTemplate, roadStyle, laneConfigs, roadType), NORMAL (typeIndex -1: no bridge or tunnel), the company's.

	-- the town roads a road gets by default, the one to be had this year first (their availability: old until
	-- 1940, new from then; base/content/infrastructure/street.zip, street/town/*.street_template.lua)
	local TOWN_ROADS = {
		"::/infrastructure/street/town/town_new_medium.street_template",
		"::/infrastructure/street/town/town_old_medium.street_template",
	}
	local ROAD_DIRS = { "town", "country", "highway" }
	local MATCH_M = 0.5 -- a piece found after a lost callback: its ends this near the planned ones

	local function enumOf(kind, name) return try(function() return api.type.enum[kind][name] end) end
	local function gameYear()
		local y = tonumber(try(function() return api.engine.util.getYear() end))
		if y then return y end
		local gt = try(function() return api.engine.getComponent(api.engine.util.getWorld(), CT().GAME_TIME).gameTime end)
		local d = gt and try(function() return api.engine.util.getCalendarDate(gt) end)
		return d and tonumber(core.field(d, "year")) or nil
	end

	-- a street template by resName, as plain values (and its lanes as the engine holds them), or nil
	local function templateInfo(name)
		local idx = tonumber(try(function() return api.res.streetTemplateRep.find(name) end))
		if not idx or idx < 0 then return nil end
		local t = try(function() return api.res.streetTemplateRep.get(idx) end)
		if t == nil then return nil end
		local av = core.field(t, "availability")
		-- street only when both the template's road type and the enum read (two nils are no match)
		local rt, street = core.field(t, "roadType"), enumOf("RoadType", "STREET")
		return { name = name, street = rt ~= nil and street ~= nil and rt == street, typeUnread = rt == nil or street == nil,
			style = core.field(t, "streetStyle"), lanes = core.field(t, "laneConfigs"),
			availability = { yearFrom = tonumber(core.field(av, "yearFrom")) or 0, yearTo = tonumber(core.field(av, "yearTo")) or 0 },
			cost = tonumber(core.field(t, "cost")) }
	end

	-- the template to build, or nil and why. given: a resName, or a base road's file name (town_new_small) looked
	-- for among the base's town, country and highway roads.
	local function roadTemplate(given, year)
		if given == nil then
			for _, name in ipairs(TOWN_ROADS) do
				local t = templateInfo(name)
				if t and t.street and availableIn(t.availability, year) then return t end
			end
			return nil, "none of the base town roads (" .. table.concat(TOWN_ROADS, ", ") .. ") is to be had in " .. tostring(year)
		end
		local names = { given }
		if not given:find("::/", 1, true) then
			local stem = given:gsub("%.street_template$", "")
			for _, d in ipairs(ROAD_DIRS) do
				names[#names + 1] = string.format("::/infrastructure/street/%s/%s.street_template", d, stem)
			end
		end
		for _, name in ipairs(names) do
			local t = templateInfo(name)
			if t then
				if t.typeUnread then return nil, name .. ": its road type (or the RoadType enum) could not be read" end
				if not t.street then return nil, name .. " is a track type, not a road" end
				if not availableIn(t.availability, year) then
					return nil, string.format("%s is not to be had in %s (yearFrom %d, yearTo %d)", name, tostring(year),
						t.availability.yearFrom, t.availability.yearTo)
				end
				return t
			end
		end
		return nil, "no street template " .. given .. " (streetTemplateRep.find gives -1 for " .. table.concat(names, ", ") .. ")"
	end

	-- the road pieces (BASE_EDGE of roadType STREET) whose box meets a circle of r metres around x, y: the octree
	-- lists edges, not nodes (as nova's elevated_road builder.lua finds road ends: BASE_EDGE by findEntitiesInCircle,
	-- then their node0 / node1). A piece whose road type cannot be read is left out (never taken for a road).
	function streetEdgesNear(x, y, r)
		local street = enumOf("RoadType", "STREET")
		local out, seen = {}, {}
		local function take(e)
			e = tonumber(e)
			if not e or seen[e] then return end
			seen[e] = true
			local be = comp(e, "BASE_EDGE")
			local rt = be and core.field(be, "roadType")
			if street ~= nil and rt ~= nil and rt == street then out[#out + 1] = e end
		end
		local list = try(function()
			return api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(x, y), r, CT().BASE_EDGE)
		end)
		if list ~= nil then
			for _, e in ipairs(core.toList(list)) do take(e) end
		else
			-- (no octree util: the octree system's box, edges only)
			pcall(function()
				local box = api.type.Box3.new(api.type.Vec3f.new(x - r, y - r, -1000), api.type.Vec3f.new(x + r, y + r, 5000))
				api.engine.system.octreeSystem.findIntersectingEntities(box, function(e) take(e) end)
			end)
		end
		table.sort(out)
		return out
	end

	-- the nearest end of a road piece within r metres of x, y, z (in three dimensions: a node of a bridge or a
	-- raised road above the point is not taken; no z: on the map's plane) that may be joined, or nil. Only the
	-- street pieces' own nodes are looked at, so no track node is asked about. A node without a junction set-up
	-- (nodeConfigState false) is never taken: the next nearest is; the second value lists the ones passed over
	-- (nearest first), so that a caller can refuse rather than put a new node beside one of them. A node whose
	-- set-up cannot be read stops the search (third value): the game would die before any caution was read.
	--
	-- The pieces are looked for SEARCH_EXTRA_M beyond r: a town's road node where two of its pieces meet (a seam)
	-- was not found from a point right on it with a snap of 3 m (2026-11-23, node 4066): the octree's circle met
	-- neither piece there (their shapes drawing back from the node, as at an industry's T, is a guess). The
	-- fourth value: the nearest road node beyond r (or nil), and the search radius, for the answer's snapNote.
	local SEARCH_EXTRA_M = 25
	local function streetNodeNear(x, y, z, r)
		local dist, pieces = {}, {}
		local nearest
		local R = r + SEARCH_EXTRA_M
		for _, e in ipairs(streetEdgesNear(x, y, R)) do
			local be = comp(e, "BASE_EDGE")
			for _, k in ipairs({ "node0", "node1" }) do
				local n = tonumber(core.field(be, k))
				local p = n and nodePos(n)
				if p then
					pieces[n] = (pieces[n] or 0) + 1
					local flat = math.sqrt((p.x - x) ^ 2 + (p.y - y) ^ 2)
					local d = math.sqrt(flat ^ 2 + (z and (p.z - z) ^ 2 or 0))
					if d <= r then
						dist[n] = d
					elseif not nearest or d < nearest.d then
						nearest = { node = n, d = d, flat = flat }
					end
				end
			end
		end
		local around = { nearest = nearest, radius = R }
		local order = {}
		for n in pairs(dist) do order[#order + 1] = n end
		table.sort(order, function(a, b) if dist[a] ~= dist[b] then return dist[a] < dist[b] end return a < b end)
		local passed = {}
		for _, n in ipairs(order) do
			local cfg = nodeConfigState(n)
			if cfg == nil then return nil, passed, { node = n, snapped = dist[n] }, around end
			if cfg == false then
				passed[#passed + 1] = { node = n, snapped = dist[n], pieces = pieces[n] }
			else
				local p = nodePos(n)
				local hit = { node = n, x = p.x, y = p.y, z = p.z, snapped = dist[n], pieces = pieces[n], nodeConfig = true }
				if #passed > 0 then hit.passedOver = passed end
				return hit, passed, nil, around
			end
		end
		return nil, passed, nil, around
	end

	-- an existing road node within SAME_M of a point (in three dimensions), nearest first: { node, d } or nil.
	-- Through the pieces met within NEAR_PIECE_M (the octree has no nodes)
	-- (SAME_M: how near the engine counts as "on" is not known; this one takes a node right on another)
	local SAME_M, NEAR_PIECE_M = 0.1, 30
	local function nodeOnPoint(x, y, z)
		local best
		for _, e in ipairs(streetEdgesNear(x, y, NEAR_PIECE_M)) do
			local be = comp(e, "BASE_EDGE")
			for _, k in ipairs({ "node0", "node1" }) do
				local n = tonumber(be and core.field(be, k))
				local p = n and nodePos(n)
				if p then
					local d = math.sqrt((p.x - x) ^ 2 + (p.y - y) ^ 2 + (p.z - z) ^ 2)
					if d <= SAME_M and (not best or d < best.d) then best = { node = n, d = d } end
				end
			end
		end
		return best
	end

	-- one end: a road node near it (snap), else a new node at the point (z given, or the terrain's). Refused when
	-- the only road nodes within snap have no junction set-up: joining one can kill the game, and a new node
	-- there would sit on it; refused too when whether a node has one cannot be read.
	local function roadEnd(pt, snap)
		local z, zFrom = pt[3], "given"
		if z == nil then z, zFrom = heightAt(pt[1], pt[2]), "terrain" end
		local hit, passed, unread, around = nil, {}, nil, nil
		if snap > 0 then hit, passed, unread, around = streetNodeNear(pt[1], pt[2], z, snap) end
		if unread then
			return nil, string.format("whether road node %d (%.1f m away) has its junction set-up (BaseNodeConfig) " ..
				"could not be read; joining a node without one killed the game: nothing sent", unread.node, unread.snapped)
		end
		if hit then return hit end
		if #passed > 0 then
			local names = {}
			for _, q in ipairs(passed) do
				names[#names + 1] = string.format("%d (%.1f m, %d piece%s)", q.node, q.snapped, q.pieces, q.pieces == 1 and "" or "s")
			end
			return nil, "the road node(s) within snap have no junction set-up (BaseNodeConfig): " .. table.concat(names, ", ") ..
				". A road a script built without set-ups (this command's before 2026-11-23) ends in such nodes; " ..
				"joining one killed the game (Engine.h GetComponentDataIndex), and a new node there would sit by it: " ..
				"nothing sent. Join another node, or put this end well away from that node"
		end
		if z == nil then return nil, "the terrain's height could not be read: give z" end
		-- a new node on an old one: the engine refuses the whole proposal ("Construction Not Possible",
		-- advanced_station_builder's notes; a road ended on a forest's stub end so, 2026-11-23)
		local same = nodeOnPoint(pt[1], pt[2], z)
		if same then
			return nil, string.format("a new node here would be on node %d (%.2f m away): the engine refuses a proposal " ..
				"with a node on another (Construction Not Possible): nothing sent. Join that node (a snap above 0), or " ..
				"move this end", same.node, same.d)
		end
		-- a new node: why no road node was taken, never silently (the nearest one beyond snap, in 3 d and on the map)
		local note
		if snap > 0 then
			local q = around and around.nearest
			if q then
				note = string.format("no road node within snap %g m: the nearest, node %d, is %.2f m away (%.2f m on the " ..
					"map; heights differ when the point's z is the terrain's): a new node", snap, q.node, q.d, q.flat)
			else
				note = string.format("no road piece met within %g m: a new node", around and around.radius or snap)
			end
		end
		return { x = pt[1], y = pt[2], z = z, zFrom = zFrom, snapNote = note }
	end

	-- an engine record type by name: api.type.X, else api.type.Proposal.X (type.d.tl declares NodeAndEntity and
	-- SegmentAndEntity inside Proposal; mods reach them as api.type.X: which one the game has is not checked)
	local function newRecord(name)
		local t = try(function() return api.type[name] end) or try(function() return api.type.Proposal[name] end)
		if t == nil then error("api.type has no " .. name, 0) end
		return t.new()
	end

	---------------------------------------------------------------------------------------------------------------
	-- junction set-ups for the road's ends (SimpleStreetProposal.nodeConfigsToAdd / nodeConfigsToRemove). Written
	-- here from the documented records, not copied: LaneConnection (type.d.tl) joins lane0 of segment0 to lane1 of
	-- segment1, each lane numbered from 0, left to right looking from the node out along its piece, over every
	-- lane of laneConfigs (sidewalks too: Smart Lanes' notes, read in a game); laneConfigs run left to right
	-- looking from node0 to node1, so at node0 lane k (1-based) is k - 1 and at node1 it is #lanes - k. A node where
	-- two pieces meet runs each lane straight on (n to #lanes - 1 - n, as the game's own road nodes do: Track
	-- Connector's and Smart Lanes' notes); a junction joins every arriving road (tram) lane to every leaving road
	-- (tram) lane of the other pieces; a dead end has no connections. Every connection is withRoad, a tram's too
	-- (Track Connector's notes: the game's own rules read so, and tram-only ones left trams unjoined). api.type.LaneConnection.new is not in the
	-- tealdef but there (Smart Lanes' notes); without it, plain tables.

	-- a piece's lanes as plain values: { forward, road, tram } (nil when they cannot be read)
	local function lanesOf(laneConfigs)
		local TM = try(function() return api.type.enum.TransportMode end)
		if TM == nil then return nil end
		local out = {}
		local ok = pcall(function()
			for _, lc in ipairs(core.toList(laneConfigs)) do
				local set = {}
				local m = lc.transportModes
				if m ~= nil then for k, v in pairs(m) do if v == true or v == 1 then set[k] = true end end end
				out[#out + 1] = { forward = lc.forward == true,
					road = set[TM.CAR] == true or set[TM.BUS] == true or set[TM.TRUCK] == true,
					tram = set[TM.TRAM] == true or set[TM.ELECTRIC_TRAM] == true }
			end
		end)
		if not ok or #out == 0 then return nil end
		return out
	end

	-- one lane connection (the engine's record, else a plain table)
	local function laneConnection(s0, l0, s1, l1, road, tram)
		local LC = try(function() return api.type.LaneConnection end)
		local lc = (LC ~= nil and try(function() return LC.new() end)) or {}
		lc.segment0, lc.lane0, lc.segment1, lc.lane1 = s0, l0, s1, l1
		lc.withRoad, lc.withTram = road == true, tram == true
		return lc
	end

	-- the connections a new piece adds at a node: piece = { entity, node0, node1, lanes } (lanes: lanesOf), others:
	-- the node's other pieces the same way. nil when a lane list is missing.
	local function newLaneRules(node, piece, others)
		local function number(p, k) if p.node0 == node then return k - 1 end return #p.lanes - k end
		local function arrives(p, l) return (l.forward and p.node1 == node) or (not l.forward and p.node0 == node) end
		if piece.lanes == nil then return nil end
		for _, o in ipairs(others) do if o.lanes == nil then return nil end end
		local out = {}
		local straight = #others == 1 and #others[1].lanes == #piece.lanes
		for _, o in ipairs(others) do
			for _, pair in ipairs({ { piece, o }, { o, piece } }) do
				local from, to = pair[1], pair[2]
				for k, l in ipairs(from.lanes) do
					if (l.road or l.tram) and arrives(from, l) then
						local n = number(from, k)
						for kk, l2 in ipairs(to.lanes) do
							local both = (l.road and l2.road) or (l.tram and l2.tram)
							if both and not arrives(to, l2) and (not straight or number(to, kk) == #to.lanes - 1 - n) then
								out[#out + 1] = laneConnection(from.entity, n, to.entity, number(to, kk),
									true, l.tram and l2.tram)
							end
						end
					end
				end
			end
		end
		return out
	end

	-- the road pieces at an existing node, as newLaneRules takes them, and how they were found: the street
	-- system's list (getNodeStreetSegments; road pieces only, as the snap takes them), else (no street system, or it
	-- raises) the pieces the octree meets within 1 m of the node that end there
	local function piecesAt(node, p)
		local street = enumOf("RoadType", "STREET")
		local function piece(e)
			local be = comp(e, "BASE_EDGE")
			local n0, n1 = tonumber(be and core.field(be, "node0")), tonumber(be and core.field(be, "node1"))
			if n0 ~= node and n1 ~= node then return nil end
			local rt = be and core.field(be, "roadType")
			if street == nil or rt == nil or rt ~= street then return nil end
			return { entity = e, node0 = n0, node1 = n1, lanes = lanesOf(core.field(be, "laneConfigs")) }
		end
		local out = {}
		local segs = streetSegmentsAt(node)
		if segs then
			for _, e in ipairs(segs) do out[#out + 1] = piece(e) end
			return out, "streetSystem", segs
		end
		for _, e in ipairs(streetEdgesNear(p.x, p.y, 1)) do out[#out + 1] = piece(e) end
		return out, "octree"
	end

	-- a set-up entry for a node: its old set-up (an existing node) or a new one, with these connections
	local function configEntry(entity, old, conns)
		local entry = newRecord("BaseNodeLaneConnectionAndEntity")
		entry.entity = entity
		if old ~= nil then
			entry.comp = old
		elseif entry.comp == nil then
			entry.comp = try(function() return api.type.BaseNodeConfig.new() end) or {}
		end
		entry.comp.laneConnections = conns
		if old == nil then pcall(function() entry.comp.crosswalks = {} end) end
		return entry
	end

	-- what a new piece adds at an existing node: { rules, old } (old: its set-up as read), or nil and why. Refused
	-- (nothing is sent) when the lanes or the set-up do not read, when the node has traffic lights (their states
	-- name lanes; they would not be remade here), or when the node's own connections do not number lanes the way
	-- the rules here do (a vehicle lane counted over all laneConfigs: a number that points at no vehicle lane, or
	-- past the last lane, says the engine counts otherwise, and a wrong number could kill the game)
	--
	-- A construction's node (constructionOfNode: an industry's stub end, the far end of one of its arms when the
	-- engine counts it the construction's) is joined without touching its set-up: { keep = con }. Overpass Builder
	-- refuses before sending any proposal that takes a construction's node set-up off (overpass_probe.script.tl,
	-- "construction-owned"); whether the engine joins the new piece's lanes there itself is not checked in a game.
	-- A construction's frozen node (the stub's inner end) is refused: the engine refused a road joined there.
	local function planJoin(endp, piece)
		local node = endp.node
		local others, via, segs = piecesAt(node, endp)
		if #others == 0 then
			return nil, "no road piece was found at node " .. node .. (via == "octree"
				and " (the street system's getNodeStreetSegments could not be asked; the octree met none within 1 m)"
				or " (the street system lists none)")
		end
		local ids0 = {}
		for _, o in ipairs(others) do ids0[#ids0 + 1] = o.entity end
		local con, conUnread = constructionOfNode(node, segs or ids0)
		if con then
			if con.frozen then
				return nil, string.format("node %d is a frozen node of construction %d (%s): the construction keeps it and " ..
					"the engine refuses a road joined there (Construction Not Possible). Join one of its open ends instead " ..
					"(the build answer's connectable: kind mouth or arm; road --inspect-node %d shows this node)", node,
					con.construction, tostring(con.fileName), node)
			end
			return { keep = con, pieces = #others, via = via }
		end
		if conUnread then
			return nil, "whether node " .. node .. " is a construction's could not be read (" .. conUnread .. "); its " ..
				"set-up is not to be remade if it is"
		end
		local rules = newLaneRules(node, piece, others)
		if rules == nil then return nil, "the lanes of the pieces at node " .. node .. " could not be read" end
		local ok, old = pcall(function() return api.engine.getComponent(node, CT().BASE_NODE_CONFIG) end)
		if not ok or old == nil then return nil, "the junction set-up of node " .. node .. " could not be read" end
		local okL, nStates = pcall(function() return #core.toList(old.trafficLightConfig.states) end)
		if not okL then return nil, "whether node " .. node .. " has traffic lights could not be read" end
		if nStates > 0 then
			return nil, "node " .. node .. " has traffic lights (their states name lanes, and would not be remade here)"
		end
		local byId = {}
		for _, o in ipairs(others) do byId[o.entity] = o end
		local bad
		local okC = pcall(function()
			for _, lc in ipairs(core.toList(old.laneConnections)) do
				for _, sl in ipairs({ { lc.segment0, lc.lane0 }, { lc.segment1, lc.lane1 } }) do
					local o = byId[tonumber(sl[1])]
					local idx = tonumber(sl[2])
					if o and idx then
						local k = o.node0 == node and idx + 1 or #o.lanes - idx
						local l = o.lanes[k]
						if not (l and (l.road or l.tram)) then bad = string.format("piece %d lane %d", o.entity, idx) end
					end
				end
			end
		end)
		if not okC then return nil, "the connections of node " .. node .. " could not be read" end
		if bad then
			return nil, "the connections of node " .. node .. " number lanes otherwise than this command (" .. bad ..
				" is no vehicle lane when all lanes are counted)"
		end
		return { rules = rules, old = old, via = via }
	end

	-- the road pieces near either end and the middle, by id: taken before sending, so a piece found afterwards
	-- is a new one
	local function piecesAround(a, b)
		local set = {}
		local r = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) / 2 + 10
		for _, e in ipairs(streetEdgesNear((a.x + b.x) / 2, (a.y + b.y) / 2, r)) do set[e] = true end
		for _, q in ipairs({ a, b }) do
			for _, e in ipairs(streetEdgesNear(q.x, q.y, 10)) do set[e] = true end
		end
		return set
	end

	-- the piece between the two ends, read back: a road piece not there before (before: piecesAround) whose ends
	-- are at the planned points (after a lost callback, or when the callback gives no ids)
	local function pieceBetween(a, b, before)
		local function near(p, q) return p and math.sqrt((p.x - q.x) ^ 2 + (p.y - q.y) ^ 2) <= MATCH_M end
		for e in pairs(piecesAround(a, b)) do
			if not (before and before[e]) then
				local be = comp(e, "BASE_EDGE")
				local p0, p1 = nodePos(core.field(be, "node0")), nodePos(core.field(be, "node1"))
				if (near(p0, a) and near(p1, b)) or (near(p0, b) and near(p1, a)) then return e end
			end
		end
		return nil
	end

	local NOTE_ROAD = "one straight piece as a SimpleStreetProposal; not checked in a game yet: look at it (frame) " ..
		"before trusting the answer"
	local NOTE_KEEP = "joined to a construction's node: its junction set-up is the construction's and was left as it " ..
		"is (neither removed nor remade); whether the engine joins the new piece's lanes there is not checked in a " ..
		"game yet: look at it, and whether vehicles take the new piece"

	-- what the engine says of a proposal without building it: api.engine.util.proposal.makeProposalData, called
	-- here in the guiUpdate (the GUI thread: Overpass Builder calls it there with a SimpleProposal alone; Track
	-- Connector calls it in its game script with the proposal and a Context, tried second here). Never from a recipe's body (api.util /
	-- api.gui there killed the game, BUG.md 2026-11-15). -> the verdict (as a build's) and the form taken, or nil and
	-- why (not there, or it raised both ways)
	local function engineCheck(sp, fields, buildings)
		local mpd = try(function() return api.engine.util.proposal.makeProposalData end)
		if mpd == nil then return nil, "api.engine.util.proposal.makeProposalData is not there" end
		-- (the proposal alone first: the form Overpass Builder uses on the GUI thread; with a Context only after)
		local ok, data = pcall(mpd, sp)
		if ok and data ~= nil then return verdict(data), "SimpleProposal" end
		local first = ok and "nothing given back" or tostring(data)
		ok, data = pcall(mpd, sp, context(fields, buildings))
		if ok and data ~= nil then return verdict(data), "SimpleProposal, Context" end
		return nil, "makeProposalData (proposal): " .. first .. "; (proposal, context): " ..
			(ok and "nothing given back" or tostring(data))
	end

	function B.road(c)
		local r, err = core.roadRequest(c.args)
		if not r then return fail(c.id, err) end
		local year = gameYear()
		local tpl, terr = roadTemplate(r.type, year)
		if not tpl then return fail(c.id, terr) end
		local a, aerr = roadEnd(r.from, r.snap)
		if not a then return fail(c.id, "from: " .. aerr) end
		local b, berr = roadEnd(r.to, r.snap)
		if not b then return fail(c.id, "to: " .. berr) end
		if a.node and a.node == b.node then
			return fail(c.id, string.format("both ends are node %d: give points further apart (or a smaller snap)", a.node))
		end
		local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
		local length = math.sqrt(dx * dx + dy * dy + dz * dz)
		if length < core.ROAD_LIMITS.minLength then
			return fail(c.id, string.format("the piece would be %.2f m long: at least %g m", length, core.ROAD_LIMITS.minLength))
		end
		local normal, streetType = enumOf("BaseEdgeType", "NORMAL"), enumOf("RoadType", "STREET")
		if normal == nil or streetType == nil then
			return fail(c.id, "api.type.enum.BaseEdgeType.NORMAL or RoadType.STREET could not be read: nothing sent")
		end
		local out = { from = a, to = b, template = tpl.name, length = length, year = year, snap = r.snap, note = NOTE_ROAD }
		-- the ids the proposal will give (endNode below: the new nodes from -1 in the order from, to; then the piece)
		local n0 = a.node or -1
		local n1 = b.node or (a.node and -1 or -2)
		local pieceId = -((a.node and 0 or 1) + (b.node and 0 or 1) + 1)
		local piece = { entity = pieceId, node0 = n0, node1 = n1, lanes = lanesOf(tpl.lanes) }
		if piece.lanes == nil then return fail(c.id, tpl.name .. ": its lanes could not be read: nothing sent") end
		-- each joined node: its connections planned now, so that a dry run refuses what a build would
		local plans = {}
		for _, q in ipairs({ { "from", a }, { "to", b } }) do
			if q[2].node then
				local plan, perr = planJoin(q[2], piece)
				if not plan then return fail(c.id, q[1] .. ": " .. perr .. ": nothing sent") end
				plans[q[1]] = plan
				q[2].piecesFrom = plan.via
				if plan.keep then
					q[2].construction, q[2].constructionFile = plan.keep.construction, plan.keep.fileName
					q[2].pieces, q[2].nodeConfigKept = plan.pieces, true
					out.caution = NOTE_KEEP
				else
					q[2].laneRules = #plan.rules
				end
			end
		end
		if r.dryRun and not r.engineCheck then
			-- the probe's own checks only, nothing made for the engine: a dry run is to be safe to run without asking
			-- for the game (the shared rules), and the engine's evaluation might assert where pcall cannot catch it
			out.ok, out.dryRun, out.checked = true, true, false
			out.engineCheck = "not asked (use --engine-check)"
			out.why = "checked here: the template, the ends (a road node within snap, or the terrain's height), the " ..
				"length and the set-ups planned; the engine's check (collisions, terrain, money) comes with " ..
				"--engine-check or a build"
			return answer(c.id, out)
		end
		local sp = api.type.SimpleProposal.new()
		local nodes, nextId = {}, -1
		local function endNode(e)
			if e.node then return e.node end
			local n = newRecord("NodeAndEntity")
			n.entity = nextId
			n.comp.position = api.type.Vec3f.new(e.x, e.y, e.z)
			nodes[#nodes + 1] = n
			nextId = nextId - 1
			return n.entity
		end
		local en0, en1 = endNode(a), endNode(b)
		if en0 ~= n0 or en1 ~= n1 or nextId ~= pieceId then return fail(c.id, "the ids planned are not the ones given: nothing sent") end
		local e = newRecord("SegmentAndEntity")
		e.entity = nextId
		e.type = 0 -- 0 street, 1 track
		e.comp.node0, e.comp.node1 = n0, n1
		e.comp.position0 = api.type.Vec3f.new(a.x, a.y, a.z)
		e.comp.position1 = api.type.Vec3f.new(b.x, b.y, b.z)
		-- straight: both tangents along the chord, as long as the piece
		e.comp.tangent0 = api.type.Vec3f.new(dx, dy, dz)
		e.comp.tangent1 = api.type.Vec3f.new(dx, dy, dz)
		e.comp.type = normal
		e.comp.typeIndex = -1
		e.comp.roadType = streetType
		e.comp.roadTemplate = tpl.name
		if tpl.style ~= nil then e.comp.roadStyle = tpl.style end
		if tpl.lanes ~= nil then e.comp.laneConfigs = tpl.lanes end
		-- the company's (as a player's road): its PlayerOwned, where the type can be made
		pcall(function()
			local po = newRecord("PlayerOwned")
			po.player = player()
			e.playerOwned = po
		end)
		-- junction set-ups: each new node its own (a dead end), each joined node its old one plus the new piece's
		-- connections (straight on where it makes two pieces, a junction's where more), a construction's node none
		-- (its set-up is left as it is). One that cannot be made refuses the command: nothing is sent (a node left
		-- without one, or without the new piece, is what killed the game or keeps vehicles off the piece)
		local cfgAdd, cfgRemove = {}, {}
		for _, q in ipairs({ { "from", a, n0 }, { "to", b, n1 } }) do
			local key, endp, id = q[1], q[2], q[3]
			local ok, cerr = pcall(function()
				if not endp.node then
					cfgAdd[#cfgAdd + 1] = configEntry(id, nil, {})
					return
				end
				local plan = plans[key]
				if plan.keep then return end
				-- (the old connections anew: those read from the engine are not to be written, Smart Lanes' notes)
				local conns = {}
				for _, lc in ipairs(core.toList(plan.old.laneConnections)) do
					conns[#conns + 1] = laneConnection(lc.segment0, lc.lane0, lc.segment1, lc.lane1, lc.withRoad, lc.withTram)
				end
				for _, lc in ipairs(plan.rules) do conns[#conns + 1] = lc end
				cfgAdd[#cfgAdd + 1] = configEntry(endp.node, plan.old, conns)
				cfgRemove[#cfgRemove + 1] = endp.node
			end)
			if not ok then
				return fail(c.id, string.format("%s: the junction set-up could not be made (%s): nothing sent", key, tostring(cerr)))
			end
		end
		-- whole lists, never an element written into the engine's list (see place)
		sp.streetProposal.nodesToAdd = nodes
		sp.streetProposal.edgesToAdd = { e }
		if #cfgAdd > 0 then sp.streetProposal.nodeConfigsToAdd = cfgAdd end
		if #cfgRemove > 0 then sp.streetProposal.nodeConfigsToRemove = cfgRemove end
		out.newNodes, out.nodeConfigs = #nodes, #cfgAdd
		if r.dryRun then
			-- (engineCheck) the same proposal a build sends, asked of the engine and not sent
			out.dryRun = true
			local v, form = engineCheck(sp, r.removeFields, r.removeBuildings)
			if not v then
				out.ok, out.checked = true, false
				out.engineCheck = "not available: " .. tostring(form)
				out.why = "checked here only: the template, the ends (a road node within snap, or the terrain's height), " ..
					"the length and the set-ups; the engine's check (makeProposalData) could not be had (engineCheck), " ..
					"so collisions, terrain and money only come with a build"
				return answer(c.id, out)
			end
			for k, val in pairs(v) do out[k] = val end
			out.checked, out.engineCheck = true, "makeProposalData (" .. form .. ")"
			out.buildable = not v.critical
			local warned = v.warnings ~= nil and #v.warnings > 0
			out.verdict = v.critical and "refused" or (warned and "buildable with warnings" or "buildable")
			-- the proposal alone is judged in the engine's own context, not the build's: that one gathers fields
			-- (its warning "fields will be removed") where the build, without --remove-fields, does not and collides
			if form == "SimpleProposal" then
				out.engineContext = "the engine's own (the proposal alone): not the build's, whose gatherFields is " ..
					tostring(r.removeFields == true) .. " and gatherBuildings " .. tostring(r.removeBuildings == true)
				if r.removeBuildings then
					out.removeBuildingsNote = "the dry run judged it in the engine's own context, not with gatherBuildings: " ..
						"town buildings it names among the collisions (hits) may still go in the build"
				end
				if warned and not r.removeFields then
					out.caution = "the engine warned (" .. table.concat(v.warnings, "; ") .. ") in its own context; the " ..
						"build gathers no fields and may be refused for what a warning lets through here (a field " ..
						"in the way: a collision). If the warning is that fields will be removed, give --remove-fields"
				elseif warned then
					-- (--remove-fields gathers fields only: a warning of anything else, buildings for one, the build may
					-- still be refused for)
					out.caution = "the engine warned (" .. table.concat(v.warnings, "; ") .. ") in its own context; the " ..
						"build gathers fields (--remove-fields) but no buildings: a warning of anything but fields " ..
						"may still be a collision in the build"
				end
			else
				out.engineContext = "the build's"
			end
			out.balance = balance()
			if v.critical then
				out.ok = false
				local msgs = v.errors and #v.errors > 0 and table.concat(v.errors, "; ") or "no message"
				out.error = "the engine would refuse it: " .. msgs .. " (dry run: nothing sent)"
				if out.collisions and describeHits then
					local okH, hits = pcall(describeHits, out.collisions, (a.x + b.x) / 2, (a.y + b.y) / 2)
					if okH then out.hits = hits else out.hitsError = tostring(hits) end
				end
				return answer(c.id, out, "error")
			end
			out.ok = true
			return answer(c.id, out)
		end
		out.removeFields = r.removeFields or nil
		if r.removeFields then
			out.removeFieldsNote = "gatherFields on, gatherBuildings off: not checked in a game yet that only fields go " ..
				"and buildings and tracks still refuse it: look at it (frame)"
		end
		local job = { id = c.id, kind = "road", out = out, started = appTime(), before = balance(),
			piecesBefore = piecesAround(a, b) }
		out.removeBuildings = r.removeBuildings or nil
		api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(sp, context(r.removeFields, r.removeBuildings), false, true), function(data, success, entities)
			local ok, cerr = pcall(function()
				local v = verdict(try(function() return data.resultProposalData end))
				local list = ids(try(function() return data.resultEntities end))
				if #list == 0 then list = ids(entities) end
				job.result = { success = success == true, verdict = v, entities = list }
			end)
			if not ok then job.result = { success = success == true, verdict = { callbackError = tostring(cerr) }, entities = {} } end
		end)
		jobs[#jobs + 1] = job
	end

	-- road --inspect-node (read only): what the road command reads of a node, as plain values: the street system's
	-- pieces there, the construction it belongs to, its junction set-up, and what the octree meets around it
	local INSPECT_RADII, INSPECT_MAX = { 1, 5, 20 }, 40
	function B.roadInspect(c)
		local r, err = core.roadInspectRequest(c.args)
		if not r then return fail(c.id, err) end
		local n = r.node
		-- (whether it exists first, as Overpass Builder asks before getComponent; no entityExists: not asked)
		local exists = try(function() return api.engine.entityExists(n) end)
		if exists == false then return fail(c.id, string.format("%d is no entity", n)) end
		local p = nodePos(n)
		if not p then return fail(c.id, string.format("%d is no node (no BASE_NODE position)", n)) end
		local out = { ok = true, node = n, x = p.x, y = p.y, z = p.z }
		local street = enumOf("RoadType", "STREET")
		local sc = try(function() return api.engine.system.streetConnectorSystem end)
		local function edgeInfo(e)
			local be = comp(e, "BASE_EDGE")
			local rt = be and core.field(be, "roadType")
			local okO, owner = pcall(function() return sc.getConstructionEntityForEdge(e) end)
			return { edge = e, node0 = tonumber(be and core.field(be, "node0")), node1 = tonumber(be and core.field(be, "node1")),
				street = (rt ~= nil and street ~= nil) and rt == street or nil,
				construction = okO and tonumber(owner) or nil }
		end
		local segs = streetSegmentsAt(n)
		if segs then
			local list = {}
			for _, e in ipairs(segs) do list[#list + 1] = edgeInfo(e) end
			out.streetSegments = core.array(list)
		else
			out.streetSegments = "unread (streetSystem.getNodeStreetSegments is not there or raised)"
		end
		local okN, owner = pcall(function() return sc.getConstructionEntityForNode(n) end)
		out.constructionForNode = okN and tonumber(owner) or ("unread: " .. tostring(owner))
		local con, unread = constructionOfNode(n, segs or {})
		if con then
			out.construction = con
			local cc = comp(con.construction, "CONSTRUCTION")
			out.constructionFrozenNodes = cc and core.array(ids(core.field(cc, "frozenNodes"))) or nil
			out.constructionFrozenEdges = cc and core.array(ids(core.field(cc, "frozenEdges"))) or nil
		end
		out.constructionUnread = unread
		-- the set-up (BaseNodeConfig), copied out as plain values
		local ct = try(function() return CT().BASE_NODE_CONFIG end)
		if ct == nil then
			out.nodeConfig = "unread (no BASE_NODE_CONFIG component type)"
		else
			local okC, cfg = pcall(function() return api.engine.getComponent(n, ct) end)
			if not okC then
				out.nodeConfig = "unread: " .. tostring(cfg)
			elseif cfg == nil then
				out.nodeConfig = false
			else
				local conns = {}
				pcall(function()
					for _, lc in ipairs(core.toList(cfg.laneConnections)) do
						conns[#conns + 1] = { segment0 = tonumber(lc.segment0), lane0 = tonumber(lc.lane0),
							segment1 = tonumber(lc.segment1), lane1 = tonumber(lc.lane1), withRoad = lc.withRoad == true,
							withTram = lc.withTram == true }
					end
				end)
				out.nodeConfig = { laneConnections = core.array(conns),
					crosswalks = tonumber(try(function() return core.size(cfg.crosswalks) end)),
					trafficLightStates = tonumber(try(function() return core.size(cfg.trafficLightConfig.states) end)),
					doubleSlipSwitch = try(function() return cfg.doubleSlipSwitch end) }
			end
		end
		-- the octree's pieces around the node (findEntitiesInCircle, BASE_EDGE; every road type): whether each ends there
		local octree = {}
		for _, rad in ipairs(INSPECT_RADII) do
			local list = try(function()
				return api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(p.x, p.y), rad, CT().BASE_EDGE)
			end)
			if list == nil then
				octree[#octree + 1] = { radius = rad, unread = true }
			else
				local hits, all = {}, ids(list)
				table.sort(all)
				for i, e in ipairs(all) do
					if i > INSPECT_MAX then break end
					local info = edgeInfo(e)
					info.atNode = info.node0 == n or info.node1 == n
					hits[#hits + 1] = info
				end
				octree[#octree + 1] = { radius = rad, count = #all, edges = core.array(hits) }
			end
		end
		out.octree = core.array(octree)
		-- what road would do with this node as an end
		if con and con.frozen then
			out.road = "refused: a construction's frozen node"
		elseif con then
			out.road = "joined, its set-up left as it is (a construction's node)"
		elseif out.nodeConfig == false then
			out.road = "refused: no junction set-up"
		elseif type(out.nodeConfig) ~= "table" then
			out.road = "refused: the set-up could not be read"
		else
			out.road = "joined, its set-up remade with the new piece's connections"
		end
		answer(c.id, out)
	end

	-- a road's result: the new piece and nodes among the result's entities, else the piece found between the ends
	finishRoad = function(job, out, res)
		local edges, nodes = {}, {}
		for _, e in ipairs(res.entities) do
			if comp(e, "BASE_EDGE") then edges[#edges + 1] = e elseif comp(e, "BASE_NODE") then nodes[#nodes + 1] = e end
		end
		if res.success and #edges == 0 then
			local e = pieceBetween(out.from, out.to, job.piecesBefore)
			if e then
				edges[1] = e
				out.why = "the result named no piece: found between the ends"
			else
				out.warning = "the engine said built, but no new piece between the ends was found (look at the map)"
			end
		end
		out.edges, out.nodes = core.array(edges), core.array(nodes)
		-- whether the new nodes got their junction set-up (true / false / "unread"): read back, so that a game
		-- shows the set-ups sent were taken
		if #nodes > 0 then
			local cfg = {}
			for _, n in ipairs(nodes) do
				local s = nodeConfigState(n)
				cfg[#cfg + 1] = { node = n, nodeConfig = s == nil and "unread" or s }
			end
			out.newNodeConfigs = core.array(cfg)
		end
		out.edge = edges[1]
		if res.success and edges[1] then
			local be = comp(edges[1], "BASE_EDGE")
			out.node0, out.node1 = tonumber(core.field(be, "node0")), tonumber(core.field(be, "node1"))
		end
	end

	-- no callback in RESULT_SEC: the piece may still have been built; it is looked for between its ends
	roadLost = function(job, why)
		local o = job.out
		local e = pieceBetween(o.from, o.to, job.piecesBefore)
		if e then
			job.result = { success = true, verdict = {}, entities = { e } }
			o.why = why .. "; a piece between the ends was found"
			return finish(job)
		end
		return fail(job.id, why .. "; no piece between the ends (look at the map)")
	end

	function B.handle(c)
		local r, err = core.buildRequest(c.args)
		if not r then return fail(c.id, err) end
		if r.remove or r.removeAll then return remove(c, r) end
		return place(c, r)
	end

	function B.step()
		if #jobs == 0 then return end
		local keep = {}
		for _, job in ipairs(jobs) do
			if job.result then
				job.settle = (job.settle or 0) + 1
				if job.settle > SETTLE_FRAMES then
					local ok, err = pcall(finish, job)
					if not ok then fail(job.id, err) end
				else
					keep[#keep + 1] = job
				end
			elseif appTime() - job.started > RESULT_SEC then
				local ok, err = pcall(lost, job)
				if not ok then fail(job.id, err) end
			else
				keep[#keep + 1] = job
			end
		end
		jobs = keep
	end

	-- a new game: nothing it built carries over (ids are the old game's), and no job waits for its callback
	function B.reset()
		jobs, built, count = {}, {}, 0
	end

	-- water (read only): the level, and at each point water or land and the terrain's height
	function B.water(c)
		local r, err = core.waterRequest(c.args)
		if not r then return fail(c.id, err) end
		local level = waterLevel()
		local pts, nWater, nLand, nOff = {}, 0, 0, 0
		for _, p in ipairs(r.points) do
			local w, off = onWater(p.x, p.y)
			local h = heightAt(p.x, p.y)
			if w == true then nWater = nWater + 1 elseif w == false then nLand = nLand + 1 end
			if off == "outside" then nOff = nOff + 1 end
			pts[#pts + 1] = { x = p.x, y = p.y, onWater = w, height = h, offMap = off == "outside" or nil,
				depth = (w and level and h and h < level) and level - h or nil }
		end
		local out = { ok = true, waterLevel = level, points = core.array(pts), water = nWater, land = nLand,
			offMap = nOff > 0 and nOff or nil }
		if r.grid then
			out.grid = r.grid
			-- rows from y0 up, each from x0 east: "~" water, "." land, "?" not read
			out.rows = core.waterRows(pts, r.grid.nx)
		end
		if level == nil then out.why = "the water level could not be read (TERRAIN of the world)" end
		answer(c.id, out)
	end

	B.built = function() return built end
	B.setDescribeHits = function(f) describeHits = f end
	B.describe = describe -- (around: a construction's ends and mouths)
	return B
end

return M
