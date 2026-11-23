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
	local finishLights, lightsLost, lightPreference -- (the lights command's, below)
	local joinsOf -- (below, before finish)
	local streetEdgesNear -- (below, after place: place and joinsOf call it)
	local engineCheck -- (below, by the road command; place's dry run with engineCheck calls it too)
	local contextsInto -- (below, by engineCheck: both contexts into a dry run's answer)
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

	-- what the engine said about a proposal (ProposalData): copied out as plain values, in the callback itself.
	-- where: what data is, for errorStateRead (which fields were read and what they held: a refusal with no message
	-- says so, 2026-11-23: "陸上に配置" in the game's log, nothing in the answer)
	-- detail (--collision-detail): ProposalData copied out whole as well (core.collisionDetail), here in the callback
	-- or the check, while the engine's object is there
	local function verdict(data, where, detail)
		where = where or "ProposalData"
		local es = data and try(function() return data.errorState end)
		local critical = es and try(function() return es.critical end)
		local errors = es and strings(try(function() return es.messages end)) or nil
		local warnings = es and strings(try(function() return es.warnings end)) or nil
		-- (ErrorState.infos, type.d.tl: a reason may be there when messages is empty)
		local infos = es and strings(try(function() return es.infos end)) or nil
		local read
		if data == nil then
			read = where .. ": none"
		elseif es == nil then
			read = where .. ".errorState: none"
		else
			read = string.format("%s.errorState: critical %s, messages %d, warnings %d, infos %d", where,
				tostring(critical), #errors, #warnings, #infos)
		end
		local col = data and try(function() return data.collisionInfo.collisionEntities end)
		local hit = {}
		for _, d in ipairs(core.toList(col)) do
			local e = tonumber(core.field(d, "entity")) or tonumber(d)
			if e then hit[#hit + 1] = e end
		end
		return {
			critical = critical == true or nil,
			errors = errors,
			warnings = warnings,
			infos = infos and #infos > 0 and infos or nil,
			-- infos with critical not set: taken as a refusal. The engine puts where a construction may stand (on
			-- land, on the coast) there and refuses the build all the same (2026-11-23, P12: a depot over water,
			-- the check critical false with infos "陸上に配置" and the build refused, its errorState the same and the
			-- game's log "ProposalData error: 陸上に配置"). By the field, not its words (they change with the
			-- game's language); infos that do not refuse a build are not seen yet
			infosRefusal = critical ~= true and infos ~= nil and #infos > 0 or nil,
			errorStateRead = read,
			collisions = #hit > 0 and core.array(hit) or nil,
			-- the boxes of the constructions the proposal adds (ProposalData.toAddData[i].boundingVolume, type.d.tl):
			-- how much room one takes where it was asked, before it is built (build --dry-run --engine-check)
			newBoxes = (function()
				local out = {}
				for _, d in ipairs(core.toList(data and try(function() return data.toAddData end))) do
					local b = core.boxOf(core.field(core.field(d, "boundingVolume"), "bbox"))
					if b then out[#out + 1] = b end
				end
				return #out > 0 and core.array(out) or nil
			end)(),
			-- the town buildings the proposal takes away (CollisionInfo.buildingEntities, type.d.tl; with gatherBuildings)
			buildingsInWay = (function()
				local b = ids(data and try(function() return data.collisionInfo.buildingEntities end))
				return #b > 0 and core.array(b) or nil
			end)(),
			cost = data and tonumber(try(function() return data.costs end)) or nil,
			collisionDetail = detail and (function()
				local ok, d = pcall(core.collisionDetail, data, where)
				return ok and d or { from = where, error = tostring(d) }
			end)() or nil,
		}
	end

	-- with --collision-detail: what is in the way described (hits) where a refusal did not already do it, and how
	-- each of its boxes meets the proposal's own (mine: newBoxes, or a road piece's box from its ends), into
	-- out.collisionDetail.overlaps. Nothing without the detail asked
	local function detailHits(out, x, y, mine)
		local d = out.collisionDetail
		if type(d) ~= "table" then return end
		if out.collisions and not out.hits and describeHits then
			local okH, hits = pcall(describeHits, out.collisions, x, y)
			if okH then out.hits = hits else out.hitsError = tostring(hits) end
		end
		if out.hits then
			local okO, o = pcall(core.collisionOverlaps, mine, out.hits)
			if okO then d.overlaps = o else d.overlapsError = tostring(o) end
		end
	end
	-- a road piece's box from its ends (no width: the line between them, its heights)
	local function pieceBox(a, b)
		if not (a and b and a.x and b.x) then return nil end
		return { x0 = math.min(a.x, b.x), y0 = math.min(a.y, b.y), x1 = math.max(a.x, b.x), y1 = math.max(a.y, b.y),
			z0 = (a.z and b.z) and math.min(a.z, b.z) or nil, z1 = (a.z and b.z) and math.max(a.z, b.z) or nil, fromEnds = true }
	end

	-- the engine's reason for a refusal, from a verdict (or an answer it was copied into): its messages, else its
	-- infos or warnings (named so), else "no message" with the fields read (errorStateRead). -> the text, and
	-- whether the engine gave one
	local function reasonOf(v)
		if v.errors and #v.errors > 0 then return table.concat(v.errors, "; "), true end
		if v.infos and #v.infos > 0 then return "no message; infos: " .. table.concat(v.infos, "; "), true end
		if v.warnings and #v.warnings > 0 then return "no message; warnings: " .. table.concat(v.warnings, "; "), true end
		return "no message (" .. tostring(v.errorStateRead or (v.callbackError and ("reading the callback's data " ..
			"raised: " .. v.callbackError)) or "nothing read") .. ")", false
	end

	-- whether a verdict refuses: critical, or infos only (infosRefusal, in verdict above)
	local function refuses(v)
		return v ~= nil and (v.critical == true or v.infosRefusal == true)
	end

	-- the reason a dry run gives for its refusal: reasonOf's, but infos only named as such (critical not set)
	local function dryReason(v)
		if v.critical or not v.infosRefusal then return (reasonOf(v)) end
		return table.concat(v.infos, "; ") .. " (errorState.infos, critical not set: the engine refuses such a " ..
			"build all the same)"
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
		-- the stock lists under it (a warehouse's: { entity, kind = "WAREHOUSE", stockList }), the ids stock list
		-- and stock set take (they take this construction's id too, when there is one): only ids the engine has
		-- reach getComponent, and only component kinds this game has
		local okS, owners = pcall(core.stockOwnersOf, c, function(v, k)
			if v == e or CT()[k] == nil or try(function() return api.engine.entityExists(v) end) ~= true then return nil end
			return comp(v, k)
		end)
		return { entity = e, fileName = tostring(core.field(c, "fileName")), name = nameOf(e), at = place,
			ends = #ends > 0 and core.array(ends) or nil, depots = list("depots"), stations = list("stations"),
			industries = list("industries"), stockLists = okS and #owners > 0 and core.array(owners) or nil,
			connectable = conn, connectableWhy = connWhy }
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
		if r.dryRun and r.engineCheck then
			-- the same proposal a build sends, asked of the engine (makeProposalData) and not sent, as road's: its
			-- verdict, and the box the construction takes (newBoxes; footprint: that box less the point, axis aligned
			-- in the world)
			out.dryRun = true
			local v, form, both = engineCheck(sp, false, r.removeBuildings, r.joinStreets, r.collisionDetail)
			if not v then
				out.ok, out.checked = true, false
				out.engineCheck = "not available: " .. tostring(form)
				return answer(c.id, out)
			end
			for k, val in pairs(v) do out[k] = val end
			out.checked, out.engineCheck = true, "makeProposalData (" .. form .. ")"
			out.engineContext = form == "SimpleProposal" and "the engine's own (the proposal alone)" or "the build's"
			contextsInto(out, both)
			local no = refuses(v)
			if form == "SimpleProposal" and not no and ((v.warnings and #v.warnings > 0) or v.buildingsInWay) then
				-- (as road's: the build gathers no fields or buildings, so what a warning lets through here may be a
				-- collision there)
				out.caution = "judged in the engine's own context, not the build's (no fields or buildings gathered): " ..
					"a warning or buildings in the way here may still refuse the build"
			end
			out.buildable = not no
			out.verdict = no and "refused" or ((v.warnings and #v.warnings > 0) and "buildable with warnings" or "buildable")
			if v.newBoxes and v.newBoxes[1] then
				local b = v.newBoxes[1]
				out.footprint = { x0 = b.x0 - r.x, y0 = b.y0 - r.y, x1 = b.x1 - r.x, y1 = b.y1 - r.y,
					height = (b.z0 and b.z1) and b.z1 - b.z0 or nil, angle = r.angle,
					note = "the engine's box at this point and angle, less the point (axis aligned in the world)" }
			end
			out.balance = balance()
			if no then
				out.ok = false
				out.error = "the engine would refuse it: " .. dryReason(v) .. " (dry run: nothing sent)"
				if out.collisions and describeHits then
					local okH, hits = pcall(describeHits, out.collisions, r.x, r.y)
					if okH then out.hits = hits else out.hitsError = tostring(hits) end
				end
				detailHits(out, r.x, r.y, v.newBoxes)
				return answer(c.id, out, "error")
			end
			detailHits(out, r.x, r.y, v.newBoxes)
			out.ok = true
			return answer(c.id, out)
		end
		if r.dryRun then
			-- the probe's own checks only (no buildable: only a build says that). The engine's makeProposalData is
			-- typed for a Proposal (engine/util.d.tl:939), but Overpass Builder hands it a SimpleProposal on the GUI
			-- thread and the road's dry run does so too (engineCheck, below); this one asks nothing (--engine-check does)
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
		-- (sp and the context's flags kept: a refusal with no message asks the engine again, recheck in finish)
		local job = { id = c.id, kind = "place", out = out, started = appTime(), before = balance(), nodesBefore = nodesBefore,
			sp = sp, ctxArgs = { false, r.removeBuildings, r.joinStreets }, detail = r.collisionDetail }
		api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(sp, context(false, r.removeBuildings, r.joinStreets), false, true), function(data, success, entities)
			-- all of it guarded, as AoM's strawberries.lua: it may run where an error has no one to catch it. Only
			-- plain values leave the callback (the engine's objects belong to it)
			local ok, err = pcall(function()
				local v = verdict(try(function() return data.resultProposalData end), "resultProposalData", job.detail)
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
				job.result = { success = success == true, verdict = verdict(try(function() return data.resultProposalData end), "resultProposalData") }
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
		-- (infosRefusal is a dry run's mark: a build is judged by its success, and one that stood with infos is
		-- no refusal)
		if res.success then out.infosRefusal = nil end
		out.balanceBefore, out.balanceAfter = job.before, balance()
		if out.balanceBefore and out.balanceAfter then out.spent = out.balanceBefore - out.balanceAfter end
		if job.kind == "road" then
			finishRoad(job, out, res)
		elseif job.kind == "lights" then
			finishLights(job, out, res)
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
			local msgs, given = reasonOf(out)
			if not given and job.sp and engineCheck then
				-- the callback carried no reason (2026-11-23: "陸上に配置" only in the game's log): the same proposal
				-- asked of the engine again, in both contexts, on this thread; nothing is sent
				local okR, v, form, both = pcall(engineCheck, job.sp, job.ctxArgs[1], job.ctxArgs[2], job.ctxArgs[3])
				if okR and v then
					out.recheck = { form = form, own = both and both.own, build = both and both.build }
					-- (a refusal only: the build's context's first; the engine's own only when that one alone
					-- refused, and named so)
					local b, o = both and both.build, both and both.own
					local pick = (refuses(b) and b) or (refuses(o) and o) or nil
					local again, gave
					if pick then again, gave = reasonOf(pick) end
					if gave then
						msgs = again .. " (asked again with makeProposalData" .. (pick == o and ", in the engine's own " ..
							"context" or "") .. ": the callback gave no message; " .. tostring(out.errorStateRead) .. ")"
					elseif not pick then
						out.recheckNote = "asked again, makeProposalData says buildable: the build's refusal is not " ..
							"in its check; the game's log (ProposalData error) may say why (tf3ctl adds it: proposalLog)"
					end
				else
					out.recheck = { raised = tostring(okR and form or v) }
				end
			end
			out.error = "the engine refused it: " .. msgs
			if out.collisions and describeHits then
				-- what is in the way, one by one: its kind, name, place and box (remote_around.lua)
				local ref = job.kind == "place" and out.at or (out.from and out.to and
					{ x = (out.from.x + out.to.x) / 2, y = (out.from.y + out.to.y) / 2 }) or out.centre or nil
				local okH, hits = pcall(describeHits, out.collisions, ref and ref.x, ref and ref.y)
				if okH then out.hits = hits else out.hitsError = tostring(hits) end
			end
			if job.detail then
				-- (a road's boxes: its pieces', kept in the job; a batch has no from / to of its own, its centre)
				local ref = job.kind == "place" and out.at or (out.from and out.to and
					{ x = (out.from.x + out.to.x) / 2, y = (out.from.y + out.to.y) / 2 }) or out.centre or {}
				detailHits(out, ref.x, ref.y, job.kind == "place" and out.newBoxes or job.boxes or { pieceBox(out.from, out.to) })
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
		if job.kind == "lights" then return lightsLost(job, why) end
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
	-- With a bridge type (road --bridge): BRIDGE and typeIndex its bridgeTypeRep id, as the game's own pieces hold a
	-- bridge (game_tooltips.tl: BaseEdge.type BRIDGE, bridgeTypeRep.get(typeIndex)). The player's road tool picks
	-- the type itself (streetEdgeBuilder's bridgeTypeId, construction_react_util.tl), so a proposal's piece is taken
	-- not to be turned into a bridge by the engine (a guess, not checked in a game): both are set here.

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

	-- a bridge type by resName, or a base bridge's file name (concrete: ::/infrastructure/bridge/concrete.bridge),
	-- for a road piece: { name, id, carriers, carriesRoad, availability, available }, or nil and why (none of that
	-- name: with some of the names there; one whose carriers read without ROAD). Read only: nothing is sent here
	local BRIDGE_NAMES_SHOWN = 12
	local function bridgeType(given, year)
		local names = { given }
		if not given:find("::", 1, true) then
			names[#names + 1] = "::/infrastructure/bridge/" .. given:gsub("%.bridge$", "") .. ".bridge"
		end
		local idx, name
		for _, n in ipairs(names) do
			local i = tonumber(try(function() return api.res.bridgeTypeRep.find(n) end))
			if i and i >= 0 then idx, name = i, n; break end
		end
		if not idx then
			local all = try(function() return api.res.bridgeTypeRep.getAll() end)
			local there = {}
			pcall(function()
				for _, n in pairs(all) do if type(n) == "string" then there[#there + 1] = n end end
			end)
			table.sort(there)
			local shown = {}
			for i = 1, math.min(#there, BRIDGE_NAMES_SHOWN) do shown[i] = there[i] end
			local list = #there == 0 and "none could be read (bridgeTypeRep.getAll)" or
				string.format("%s%s (%d in all)", table.concat(shown, ", "), #there > #shown and ", ..." or "", #there)
			return nil, "no bridge type " .. given .. " (bridgeTypeRep.find gives -1 for " .. table.concat(names, ", ") ..
				"); the bridge types there: " .. list .. ": nothing sent"
		end
		local t = try(function() return api.res.bridgeTypeRep.get(idx) end)
		local out = { name = name, id = idx }
		-- its carriers as names (ROAD, RAIL): a type without ROAD is refused (a road over a rail-only bridge is not
		-- what the player's tool offers: makeFilterObjectsFn filters by Carrier.ROAD); unread: said, not refused
		local C = try(function() return api.type.enum.Carrier end)
		local cs = t ~= nil and core.field(t, "carriers") or nil
		local okC = C ~= nil and cs ~= nil and pcall(function()
			-- (the names looked up one by one, as remote_lines.lua's carrierName: the game's enum may not iterate)
			local byValue = {}
			for _, k in ipairs({ "ROAD", "RAIL", "TRAM", "AIR", "WATER", "OTHER" }) do
				local v = try(function() return C[k] end)
				if v ~= nil then byValue[v] = k end
			end
			local list, road = {}, false
			for _, c in ipairs(core.toList(cs)) do
				list[#list + 1] = byValue[c] or tostring(c)
				if c == C.ROAD then road = true end
			end
			out.carriers, out.carriesRoad = list, road
		end)
		if not okC or out.carriers == nil then
			out.carriers, out.carriesRoad = nil, nil
			out.carriersNote = "its carriers could not be read: not checked that it carries roads"
		elseif not out.carriesRoad then
			return nil, string.format("bridge type %s carries %s, not ROAD: no road on it: nothing sent", name,
				#out.carriers > 0 and table.concat(out.carriers, ", ") or "nothing")
		end
		local av = t ~= nil and core.field(t, "availability") or nil
		if av ~= nil then
			out.availability = { yearFrom = tonumber(core.field(av, "yearFrom")) or 0, yearTo = tonumber(core.field(av, "yearTo")) or 0 }
			-- (said, not refused: whether the engine refuses a bridge type out of its years in a script's proposal
			-- is not known)
			out.available = availableIn(out.availability, year)
		end
		return out
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
	-- the node's other pieces the same way. straight: whether the node is a seam (two pieces, lane for lane; nil:
	-- one other piece of as many lanes, as when one piece is added). nil when a lane list is missing.
	local function newLaneRules(node, piece, others, straight)
		local function number(p, k) if p.node0 == node then return k - 1 end return #p.lanes - k end
		local function arrives(p, l) return (l.forward and p.node1 == node) or (not l.forward and p.node0 == node) end
		if piece.lanes == nil then return nil end
		for _, o in ipairs(others) do if o.lanes == nil then return nil end end
		local out = {}
		if straight == nil then straight = #others == 1 and #others[1].lanes == #piece.lanes end
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

	-- the connections the new pieces (news, in the proposal's order) add at a node where the pieces others were
	-- (none at a new node): each new piece joined to those before it, so that every pair is joined once. The node is
	-- a seam when two pieces meet there in all (lane for lane, as newLaneRules does for one new piece), a junction
	-- when more do; one piece alone is a dead end (no connections). nil when a lane list is missing.
	local function nodeRules(node, others, news)
		local total = #others + #news
		local before, out = {}, {}
		for _, o in ipairs(others) do before[#before + 1] = o end
		for _, piece in ipairs(news) do
			local straight = total == 2 and #before == 1 and before[1].lanes ~= nil and piece.lanes ~= nil
				and #before[1].lanes == #piece.lanes
			local rules = newLaneRules(node, piece, before, straight)
			if rules == nil then return nil end
			for _, lc in ipairs(rules) do out[#out + 1] = lc end
			before[#before + 1] = piece
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
	-- news: the new pieces at the node (one for road; a batch's every piece that ends there)
	local function planJoin(endp, news)
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
		local rules = nodeRules(node, others, news)
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

	-- the way each road piece at a joined node runs on out past it, on the map: the piece's own tangent there
	-- (BASE_EDGE tangent1 at its node1; tangent0 turned round at its node0: both point node0 -> node1), else (no
	-- tangent, or one of length 0) its chord from its other node. A dead end's one piece: the way straight on out
	-- of it. -> { { edge, x, y, from = "tangent" | "chord" } } (x, y nil when neither reads)
	local function waysAt(node, p)
		local out = {}
		for _, o in ipairs((piecesAt(node, p))) do
			local be = comp(o.entity, "BASE_EDGE")
			local at1 = o.node1 == node
			local t = be and core.field(be, at1 and "tangent1" or "tangent0")
			local tx, ty = tonumber(core.field(t, "x")), tonumber(core.field(t, "y"))
			local w = { edge = o.entity }
			if tx and ty and math.sqrt(tx * tx + ty * ty) >= core.ROAD_MIN_DIR then
				local k = at1 and 1 or -1
				w.x, w.y, w.from = k * tx, k * ty, "tangent"
			else
				local here, other = nodePos(node), nodePos(at1 and o.node0 or o.node1)
				if here and other and math.sqrt((here.x - other.x) ^ 2 + (here.y - other.y) ^ 2) >= core.ROAD_MIN_DIR then
					w.x, w.y, w.from = here.x - other.x, here.y - other.y, "chord"
				end
			end
			out[#out + 1] = w
		end
		return out
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
	local NOTE_CURVE = "one curved piece (tangents given or followed from the road there) as a SimpleStreetProposal; " ..
		"curves are not checked in a game yet: look at it (frame) before trusting the answer"
	local NOTE_FORCE = "for test saves only: skips the engine's checks (sent with ignoreErrors on, the engine builds " ..
		"past its non-critical errors; its API says a critical one still refuses it). unforced: what the engine's check " ..
		"said before (makeProposalData), the errors a build without --ignore-errors would be refused for. Not " ..
		"checked in a game yet whether vehicles take a forced piece, or whether it survives a save and a load"
	local NOTE_BRIDGE = "sent as a bridge piece (BaseEdge type BRIDGE, typeIndex this type's id); not checked in a " ..
		"game yet whether the engine takes it as one (pillars, abutments, a bridge low over the ground): look at it " ..
		"(frame, around --kinds street --lanes)"
	local NOTE_KEEP = "joined to a construction's node: its junction set-up is the construction's and was left as it " ..
		"is (neither removed nor remade); whether the engine joins the new piece's lanes there is not checked in a " ..
		"game yet: look at it, and whether vehicles take the new piece"

	-- what the engine says of a proposal without building it: api.engine.util.proposal.makeProposalData, called
	-- here in the guiUpdate (the GUI thread: Overpass Builder calls it there with a SimpleProposal alone; Track
	-- Connector calls it in its game script with the proposal and a Context). Never from a recipe's body (api.util /
	-- api.gui there killed the game, BUG.md 2026-11-15). Both forms are asked: the proposal alone is judged in the
	-- engine's own context, which is not the build's (it gathered fields where the build collided, 2026-11-23, and
	-- it said buildable on water where the build was refused, "陸上に配置", 2026-11-23); with the build's Context
	-- (player, gatherFields, gatherBuildings, cleanupStreetGraph, as the build sends it) second. Whether that form
	-- judges as the build on the GUI thread is not checked in a game yet. -> the verdict (the build's context's
	-- when it answered, unless only the engine's own refused: the stricter), the form, and both ({ own, build }: each a verdict or { raised }),
	-- or nil and why (not there, or it raised both ways)
	local function summary(v, raised)
		if not v then return { raised = raised } end
		local warned = v.warnings ~= nil and #v.warnings > 0
		return { verdict = refuses(v) and "refused" or (warned and "buildable with warnings" or "buildable"),
			critical = v.critical, errors = v.errors, warnings = v.warnings, infos = v.infos, infosRefusal = v.infosRefusal,
			collisions = v.collisions and #v.collisions or nil, cost = v.cost, errorStateRead = v.errorStateRead }
	end
	function engineCheck(sp, fields, buildings, streets, detail)
		local mpd = try(function() return api.engine.util.proposal.makeProposalData end)
		if mpd == nil then return nil, "api.engine.util.proposal.makeProposalData is not there" end
		-- (the proposal alone first: the form known to work on the GUI thread)
		local ok, data = pcall(mpd, sp)
		local own = ok and data ~= nil and verdict(data, "makeProposalData (proposal)", detail) or nil
		local ownRaised = not own and (ok and "nothing given back" or tostring(data)) or nil
		ok, data = pcall(mpd, sp, context(fields, buildings, streets))
		local mine = ok and data ~= nil and verdict(data, "makeProposalData (proposal, context)", detail) or nil
		local mineRaised = not mine and (ok and "nothing given back" or tostring(data)) or nil
		if not own and not mine then
			return nil, "makeProposalData (proposal): " .. ownRaised .. "; (proposal, context): " .. mineRaised
		end
		local both = { own = summary(own, ownRaised), build = summary(mine, mineRaised) }
		-- (refused in either: the stricter is the verdict, so a dry run never says buildable where one context
		-- refuses; contextsDisagree says so)
		if mine and not (refuses(own) and not refuses(mine)) then return mine, "SimpleProposal, Context", both end
		return own, "SimpleProposal", both
	end

	-- both contexts' verdicts into an answer (a dry run's): engineContexts always; when they differ (refused in one,
	-- buildable in the other, or warnings in one only), contextsDisagree and a note of which the build follows
	function contextsInto(out, both)
		if not both then return end
		-- (a context's words: its messages, else its infos when they refuse it, named so)
		local function why(s)
			if s.errors and #s.errors > 0 then return " (" .. table.concat(s.errors, "; ") .. ")" end
			if s.infosRefusal and s.infos then return " (infos: " .. table.concat(s.infos, "; ") .. ")" end
			return ""
		end
		out.engineContexts = { own = both.own, build = both.build }
		local a, b = both.own, both.build
		if a.verdict and b.verdict and a.verdict ~= b.verdict then
			out.contextsDisagree = true
			out.contextsNote = string.format("the engine's own context (the proposal alone): %s%s; the build's " ..
				"context: %s%s. The verdict here is the stricter of the two; the build is judged in the build's context, but which " ..
				"of the two the engine really applies on the GUI thread is not checked in a game yet",
				a.verdict, why(a), b.verdict, why(b))
		end
	end
	local NOTE_BATCH = "several pieces in one SimpleProposal (road --batch), judged and built together; not checked in a " ..
		"game yet: look at it (frame) before trusting the answer"

	-- an end given as an existing node's id (road --batch fromNode / toNode): that node as it is, never a snap.
	-- Refused as a snap passes over or stops at a node: none there, no road piece at it, or its junction set-up
	-- missing or unread. Whether the entity exists is asked first, as road --inspect-node and lights do before
	-- getComponent (Overpass Builder's way); a node with no road piece (a track node) is not asked of its set-up,
	-- as the snap never asks a track node (streetNodeNear)
	local function nodeEnd(n)
		local exists = try(function() return api.engine.entityExists(n) end)
		if exists == false then return nil, string.format("node %d: no such entity: nothing sent", n) end
		local p = nodePos(n)
		if not p then return nil, string.format("node %d: no such node (no BASE_NODE position): nothing sent", n) end
		local segs = streetSegmentsAt(n)
		if segs and #segs == 0 then
			return nil, string.format("node %d has no road piece (the street system lists none; a track node?): nothing sent", n)
		end
		local s = nodeConfigState(n)
		if s == nil then
			return nil, string.format("whether node %d has its junction set-up (BaseNodeConfig) could not be read; " ..
				"joining a node without one killed the game: nothing sent", n)
		end
		if s == false then
			return nil, string.format("node %d has no junction set-up (BaseNodeConfig): joining one killed the game " ..
				"(Engine.h GetComponentDataIndex): nothing sent", n)
		end
		return { node = n, x = p.x, y = p.y, z = p.z, byId = true, nodeConfig = true, pieces = segs and #segs or nil }
	end

	-- road: one piece (core.roadRequest), or road --batch: several in one SimpleProposal (core.roadBatchRequest),
	-- so that the engine judges them together. Both go the same way here: a batch of one is the proposal road sends.
	-- New entities are numbered -1, -2, ... over nodes and pieces alike (type.d.tl SimpleStreetProposal.nodesToAdd:
	-- "entity id will be decreasing starting from -1 for all new entities"): the new nodes first, in the order the
	-- pieces' ends name them (piece 1 from, piece 1 to, piece 2 from, ...), then the pieces in their order (Track
	-- Connector numbers its pieces first, then its nodes, in one run from -1). An end that names a node shares it:
	-- an existing one (its id, or a snap to it), or a new one by its name (@a)
	function B.road(c)
		local batch = type(c.args) == "table" and c.args.batch ~= nil
		local r, err
		if batch then r, err = core.roadBatchRequest(c.args) else r, err = core.roadRequest(c.args) end
		if not r then return fail(c.id, err) end
		local specs = batch and r.pieces or { r }
		-- a piece's end (or the piece) in a message: from / to for road, "piece 2 from" for a batch
		local function at(i, key)
			if not batch then return key end
			return key and ("piece " .. i .. " " .. key) or ("piece " .. i)
		end
		local function head(i) return batch and ("piece " .. i .. ": ") or "" end
		local year = gameYear()
		local namedEnds = {}
		local function endOf(spec, key)
			local nv = spec[key .. "Node"]
			if type(nv) == "number" then return nodeEnd(nv) end
			if type(nv) == "string" then
				local base = namedEnds[nv]
				if not base then
					local q = r.named[nv]
					-- (a named node is a new node: never snapped; one on an old node is refused as any new end)
					local e, nerr = roadEnd({ q.x, q.y, q.z }, 0)
					if not e then return nil, "node " .. nv .. ": " .. nerr end
					e.name = nv
					base = e
					namedEnds[nv] = base
				end
				-- (each end a table of its own: what is said of it, its bend, is its piece's)
				local own = {}
				for k, v in pairs(base) do own[k] = v end
				return own
			end
			return roadEnd(spec[key], spec.snap)
		end
		local P = {}
		for i, spec in ipairs(specs) do
			local tpl, terr = roadTemplate(spec.type, year)
			if not tpl then return fail(c.id, head(i) .. terr) end
			local a, aerr = endOf(spec, "from")
			if not a then return fail(c.id, at(i, "from") .. ": " .. aerr) end
			local b, berr = endOf(spec, "to")
			if not b then return fail(c.id, at(i, "to") .. ": " .. berr) end
			if a.node and a.node == b.node then
				return fail(c.id, head(i) .. string.format("both ends are node %d: give points further apart (or a smaller snap)", a.node))
			end
			local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
			local length = math.sqrt(dx * dx + dy * dy + dz * dz)
			if length < core.ROAD_LIMITS.minLength then
				return fail(c.id, head(i) .. string.format("the piece would be %.2f m long: at least %g m", length, core.ROAD_LIMITS.minLength))
			end
			-- (core checks it where both points are given; an end given by a node's id is only known here)
			local flatLen = math.sqrt(dx * dx + dy * dy)
			if flatLen > core.ROAD_LIMITS.maxLength then
				return fail(c.id, head(i) .. string.format("from and to are %.0f m apart: at most %g m for one straight " ..
					"piece: nothing sent", flatLen, core.ROAD_LIMITS.maxLength))
			end
			P[i] = { spec = spec, tpl = tpl, a = a, b = b, length = length }
		end
		-- the proposal's nodes, in the order the ends name them: an existing node by its id, a named new node by its
		-- name, any other new end its own
		local nodeList, nodeBy = {}, {}
		local function nodeOf(endp, i, key)
			local k = endp.node or endp.name or endp
			local nd = nodeBy[k]
			if not nd then
				nd = { endp = endp, node = endp.node, name = endp.name, ends = {} }
				nodeBy[k] = nd
				nodeList[#nodeList + 1] = nd
			end
			nd.ends[#nd.ends + 1] = { i, key }
			return nd
		end
		for i, p in ipairs(P) do
			p.n0, p.n1 = nodeOf(p.a, i, "from"), nodeOf(p.b, i, "to")
		end
		if batch then
			-- two new nodes on one point (two ends left unnamed, or two names): the engine refuses a node on another
			-- (as a new node on an old one, roadEnd); one name makes them one node
			for j = 1, #nodeList do
				for k = j + 1, #nodeList do
					local u, v = nodeList[j], nodeList[k]
					if not u.node and not v.node then
						local d = math.sqrt((u.endp.x - v.endp.x) ^ 2 + (u.endp.y - v.endp.y) ^ 2 + (u.endp.z - v.endp.z) ^ 2)
						if d <= SAME_M then
							return fail(c.id, string.format("%s and %s would be two new nodes %.2f m apart: the engine refuses " ..
								"a node on another (Construction Not Possible). Give both ends one name (fromNode / toNode " ..
								"\"@a\") to share one node: nothing sent", at(u.ends[1][1], u.ends[1][2]), at(v.ends[1][1], v.ends[1][2]), d))
						end
					end
				end
			end
			-- two pieces between the same two nodes: one would lie on the other
			for j = 1, #P do
				for k = j + 1, #P do
					local u, v = P[j], P[k]
					if (u.n0 == v.n0 and u.n1 == v.n1) or (u.n0 == v.n1 and u.n1 == v.n0) then
						return fail(c.id, string.format("pieces %d and %d join the same two nodes: give one: nothing sent", j, k))
					end
				end
			end
		end
		local newCount = 0
		for _, nd in ipairs(nodeList) do
			if nd.node then
				nd.id = nd.node
			else
				newCount = newCount + 1
				nd.id = -newCount
			end
		end
		for i, p in ipairs(P) do p.id = -(newCount + i) end
		local normal, streetType = enumOf("BaseEdgeType", "NORMAL"), enumOf("RoadType", "STREET")
		if normal == nil or streetType == nil then
			return fail(c.id, "api.type.enum.BaseEdgeType.NORMAL or RoadType.STREET could not be read: nothing sent")
		end
		for i, p in ipairs(P) do
			-- --bridge: the piece's edge type BRIDGE and its typeIndex the type's id (else NORMAL and -1, as before)
			p.edgeType, p.typeIndex = normal, -1
			local bridge
			if p.spec.bridge then
				local berr2
				bridge, berr2 = bridgeType(p.spec.bridge, year)
				if not bridge then return fail(c.id, at(i, "bridge") .. ": " .. berr2) end
				local be = enumOf("BaseEdgeType", "BRIDGE")
				if be == nil then return fail(c.id, "api.type.enum.BaseEdgeType.BRIDGE could not be read: nothing sent") end
				p.edgeType, p.typeIndex = be, bridge.id
				bridge.note = NOTE_BRIDGE
			end
			p.out = { from = p.a, to = p.b, template = p.tpl.name, length = p.length, year = year, snap = p.spec.snap,
				note = NOTE_ROAD, bridge = bridge }
			p.piece = { entity = p.id, node0 = p.n0.id, node1 = p.n1.id, lanes = lanesOf(p.tpl.lanes) }
			if p.piece.lanes == nil then return fail(c.id, head(i) .. p.tpl.name .. ": its lanes could not be read: nothing sent") end
		end
		local out
		if batch then
			out = { batch = true, year = year, note = NOTE_BATCH }
		else
			out = P[1].out
		end
		local function endOfPiece(e) local p = P[e[1]] return e[2] == "from" and p.a or p.b end
		-- each node: its connections planned now, so that a dry run refuses what a build would. A joined node gets
		-- the new pieces' connections to its pieces and to each other (planJoin), a new node those among the new
		-- pieces at it (none: a dead end; two: lane for lane; more: a junction's)
		for _, nd in ipairs(nodeList) do
			local news = {}
			for _, e in ipairs(nd.ends) do news[#news + 1] = P[e[1]].piece end
			local first = nd.ends[1]
			if nd.node then
				local plan, perr = planJoin(nd.endp, news)
				if not plan then return fail(c.id, at(first[1], first[2]) .. ": " .. perr .. ": nothing sent") end
				nd.plan = plan
				for _, e in ipairs(nd.ends) do
					local endp = endOfPiece(e)
					endp.piecesFrom = plan.via
					if plan.keep then
						endp.construction, endp.constructionFile = plan.keep.construction, plan.keep.fileName
						endp.pieces, endp.nodeConfigKept = plan.pieces, true
						P[e[1]].out.caution = NOTE_KEEP
					else
						endp.laneRules = #plan.rules
					end
					if #nd.ends > 1 then endp.sharedBy = #nd.ends end
				end
			else
				local rules = nodeRules(nd.id, {}, news)
				if rules == nil then
					return fail(c.id, at(first[1], first[2]) .. ": the lanes of the pieces at the new node could not be read: nothing sent")
				end
				nd.rules = rules
				if #nd.ends > 1 then
					for _, e in ipairs(nd.ends) do
						local endp = endOfPiece(e)
						endp.laneRules, endp.sharedBy = #rules, #nd.ends
					end
				end
			end
		end
		local function r3(v) return math.floor(v * 1000 + 0.5) / 1000 end
		for i, p in ipairs(P) do
			local a, b, ps, po = p.a, p.b, p.spec, p.out
			-- the tangents: the way given at an end (tangentFrom / tangentTo), the road's way there (alignToEdge), else
			-- the chord's (a straight piece, as before)
			local aligned, used = {}, {}
			for _, q in ipairs({ { "from", a, ps.alignFrom }, { "to", b, ps.alignTo } }) do
				local key, endp = q[1], q[2]
				-- (the pieces there before: a batch's other new pieces at a shared node are not followed)
				if endp.node then endp.ways = waysAt(endp.node, endp) end
				if q[3] then
					if not endp.node then
						return fail(c.id, at(i, key) .. ": alignToEdge needs a road node at this end (none within snap: a new node " ..
							"has no road to follow): nothing sent")
					end
					local ways, pick = endp.ways, nil
					for _, w in ipairs(ways) do
						for _, id in ipairs(ps.alignEdge or {}) do
							if w.edge == id then
								if pick then return fail(c.id, at(i, key) .. ": alignEdge names two pieces at node " .. endp.node .. ": give one") end
								pick, used[id] = w, true
							end
						end
					end
					if not pick then
						if #ways == 1 then
							pick = ways[1]
						else
							local names = {}
							for _, w in ipairs(ways) do names[#names + 1] = tostring(w.edge) end
							return fail(c.id, string.format("%s: node %d has %d road pieces (%s): which one to follow is not " ..
								"guessed; give it with alignEdge (--align-edge ID): nothing sent", at(i, key), endp.node, #ways,
								#names > 0 and table.concat(names, ", ") or "none read"))
						end
					end
					if pick.x == nil then
						return fail(c.id, string.format("%s: the way of piece %d at node %d could not be read (no tangent, no " ..
							"node positions): nothing sent", at(i, key), pick.edge, endp.node))
					end
					aligned[key] = pick
					endp.alignedTo = { edge = pick.edge, from = pick.from }
				end
			end
			for _, id in ipairs(ps.alignEdge or {}) do
				if not used[id] then
					return fail(c.id, string.format("%salignEdge %d is not one of the road pieces at the end%s aligned: nothing sent",
						head(i), id, (ps.alignFrom and ps.alignTo) and "s" or ""))
				end
			end
			local dir0 = ps.tangentFrom or (aligned.from and { aligned.from.x, aligned.from.y })
			-- (at the to end the road there runs on out past it, so the new piece comes in against that way)
			local dir1 = ps.tangentTo or (aligned.to and { -aligned.to.x, -aligned.to.y })
			local t0, t1, turns = core.roadTangents(a, b, dir0, dir1)
			if not t0 then return fail(c.id, head(i) .. tostring(t1) .. ": nothing sent") end
			p.t0, p.t1 = t0, t1
			po.tangent0 = { x = r3(t0.x), y = r3(t0.y), z = r3(t0.z) }
			po.tangent1 = { x = r3(t1.x), y = r3(t1.y), z = r3(t1.z) }
			po.curved = dir0 ~= nil or dir1 ~= nil
			if po.curved then
				po.note = NOTE_CURVE
				po.turnOffChord = { from = r3(turns[1]), to = r3(turns[2]) }
			end
			-- the bend at each joined end: the angle between the way each piece there runs on out past the node and the
			-- way the new piece leaves the node (0: straight on). The followed piece's (or the only one's) is kinkDeg
			for _, q in ipairs({ { "from", a, { x = t0.x, y = t0.y } }, { "to", b, { x = -t1.x, y = -t1.y } } }) do
				local key, endp, leave = q[1], q[2], q[3]
				if endp.ways then
					local kinks = {}
					for _, w in ipairs(endp.ways) do
						local k = w.x and core.angleDeg(w, leave)
						kinks[#kinks + 1] = { edge = w.edge, kinkDeg = k and r3(k) or nil, wayFrom = w.from }
						if (aligned[key] and aligned[key].edge == w.edge) or (not aligned[key] and #endp.ways == 1) then
							endp.kinkDeg = k and r3(k) or nil
						end
					end
					endp.kinks = kinks
				end
				endp.ways = nil
			end
		end
		-- where the hits are described from: the piece's middle (road), the middle of the pieces' middles (a batch)
		local cx, cy = 0, 0
		for _, p in ipairs(P) do cx, cy = cx + (p.a.x + p.b.x) / 2 / #P, cy + (p.a.y + p.b.y) / 2 / #P end
		-- (--collision-detail) the proposal's own boxes, to meet what is in the way: each piece's from its ends, in
		-- the pieces' order (overlaps' mine is the piece's number)
		local mineBoxes = {}
		for i, p in ipairs(P) do mineBoxes[i] = pieceBox(p.a, p.b) end
		if batch then
			local list = {}
			for _, p in ipairs(P) do list[#list + 1] = p.out end
			out.pieces = core.array(list)
			out.centre = { x = cx, y = cy }
			-- what the proposal holds, by its ids: each node (an existing one's id, a new one's -n with its name or the
			-- end that made it) and each piece between them
			local pn, pe = {}, {}
			for _, nd in ipairs(nodeList) do
				local ends = {}
				for _, e in ipairs(nd.ends) do ends[#ends + 1] = at(e[1], e[2]) end
				pn[#pn + 1] = { id = nd.id, existing = nd.node ~= nil, name = nd.name, x = nd.endp.x, y = nd.endp.y,
					z = nd.endp.z, ends = core.array(ends) }
			end
			for i, p in ipairs(P) do pe[#pe + 1] = { id = p.id, piece = i, node0 = p.n0.id, node1 = p.n1.id } end
			out.proposal = { nodes = core.array(pn), edges = core.array(pe) }
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
		local nodes = {}
		for _, nd in ipairs(nodeList) do
			if not nd.node then
				local n = newRecord("NodeAndEntity")
				n.entity = nd.id
				n.comp.position = api.type.Vec3f.new(nd.endp.x, nd.endp.y, nd.endp.z)
				nodes[#nodes + 1] = n
			end
		end
		local edges = {}
		for _, p in ipairs(P) do
			local a, b, t0, t1 = p.a, p.b, p.t0, p.t1
			local e = newRecord("SegmentAndEntity")
			e.entity = p.id
			e.type = 0 -- 0 street, 1 track
			e.comp.node0, e.comp.node1 = p.n0.id, p.n1.id
			e.comp.position0 = api.type.Vec3f.new(a.x, a.y, a.z)
			e.comp.position1 = api.type.Vec3f.new(b.x, b.y, b.z)
			-- (core.roadTangents: the chord at both ends unless a way was given or followed; both the way node0 ->
			-- node1, as Track Connector's pieces that share a new node: each piece's own way, whichever way the
			-- other piece at the node runs)
			e.comp.tangent0 = api.type.Vec3f.new(t0.x, t0.y, t0.z)
			e.comp.tangent1 = api.type.Vec3f.new(t1.x, t1.y, t1.z)
			e.comp.type = p.edgeType
			e.comp.typeIndex = p.typeIndex
			e.comp.roadType = streetType
			e.comp.roadTemplate = p.tpl.name
			if p.tpl.style ~= nil then e.comp.roadStyle = p.tpl.style end
			if p.tpl.lanes ~= nil then e.comp.laneConfigs = p.tpl.lanes end
			-- the company's (as a player's road): its PlayerOwned, where the type can be made
			pcall(function()
				local po = newRecord("PlayerOwned")
				po.player = player()
				e.playerOwned = po
			end)
			edges[#edges + 1] = e
		end
		-- junction set-ups: each new node its own (a dead end, or the batch's pieces there joined), each joined node
		-- its old one plus the new pieces' connections (straight on where it makes two pieces, a junction's where
		-- more), a construction's node none (its set-up is left as it is). One that cannot be made refuses the
		-- command: nothing is sent (a node left without one, or without the new piece, is what killed the game or
		-- keeps vehicles off the piece)
		local cfgAdd, cfgRemove = {}, {}
		for _, nd in ipairs(nodeList) do
			local first = nd.ends[1]
			local ok, cerr = pcall(function()
				if not nd.node then
					cfgAdd[#cfgAdd + 1] = configEntry(nd.id, nil, nd.rules)
					return
				end
				local plan = nd.plan
				if plan.keep then return end
				-- (the old connections anew: those read from the engine are not to be written, Smart Lanes' notes)
				local conns = {}
				for _, lc in ipairs(core.toList(plan.old.laneConnections)) do
					conns[#conns + 1] = laneConnection(lc.segment0, lc.lane0, lc.segment1, lc.lane1, lc.withRoad, lc.withTram)
				end
				for _, lc in ipairs(plan.rules) do conns[#conns + 1] = lc end
				cfgAdd[#cfgAdd + 1] = configEntry(nd.node, plan.old, conns)
				cfgRemove[#cfgRemove + 1] = nd.node
			end)
			if not ok then
				return fail(c.id, string.format("%s: the junction set-up could not be made (%s): nothing sent",
					at(first[1], first[2]), tostring(cerr)))
			end
		end
		-- whole lists, never an element written into the engine's list (see place)
		sp.streetProposal.nodesToAdd = nodes
		sp.streetProposal.edgesToAdd = edges
		if #cfgAdd > 0 then sp.streetProposal.nodeConfigsToAdd = cfgAdd end
		if #cfgRemove > 0 then sp.streetProposal.nodeConfigsToRemove = cfgRemove end
		out.newNodes, out.nodeConfigs = #nodes, #cfgAdd
		if batch then out.edgesSent = #edges end
		if r.ignoreErrors then
			out.ignoreErrors, out.testSave, out.ignoreErrorsNote = true, r.testSave, NOTE_FORCE
		end
		if r.dryRun then
			-- (engineCheck) the same proposal a build sends, asked of the engine and not sent
			out.dryRun = true
			-- (--ignore-errors with --dry-run: nothing is forced; the verdict below is the unforced one)
			if r.ignoreErrors then out.ignoredErrors = false end
			local v, form, both = engineCheck(sp, r.removeFields, r.removeBuildings, nil, r.collisionDetail)
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
			contextsInto(out, both)
			local no = refuses(v)
			out.buildable = not no
			local warned = v.warnings ~= nil and #v.warnings > 0
			out.verdict = no and "refused" or (warned and "buildable with warnings" or "buildable")
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
			if no then
				out.ok = false
				out.error = "the engine would refuse it: " .. dryReason(v) .. " (dry run: nothing sent)"
				if out.collisions and describeHits then
					local okH, hits = pcall(describeHits, out.collisions, cx, cy)
					if okH then out.hits = hits else out.hitsError = tostring(hits) end
				end
				detailHits(out, cx, cy, mineBoxes)
				return answer(c.id, out, "error")
			end
			detailHits(out, cx, cy, mineBoxes)
			out.ok = true
			return answer(c.id, out)
		end
		out.removeFields = r.removeFields or nil
		if r.removeFields then
			out.removeFieldsNote = "gatherFields on, gatherBuildings off: not checked in a game yet that only fields go " ..
				"and buildings and tracks still refuse it: look at it (frame)"
		end
		-- --ignore-errors: the engine's check first (the same proposal, not sent), so that the answer says what an
		-- unforced build would have been refused for; the probe's own checks above (the junction set-ups: a node
		-- without one killed the game, BUG.md 2026-11-23 01:03) have run all the same and are not skipped
		local force = r.ignoreErrors == true
		if force then
			-- a construction's node (its set-up left as it is, NOTE_KEEP): whether the engine joins the new piece's
			-- lanes there is not checked in a game, and an error it gives there may be what stands between the
			-- game and a node without lanes for the new piece (as the node without a set-up that killed it): not
			-- forced (review 2026-11-24)
			for _, nd in ipairs(nodeList) do
				if nd.plan and nd.plan.keep then
					local first = nd.ends[1]
					return fail(c.id, string.format("%s: node %d is construction %d's (its junction set-up is left as " ..
						"it is): ignoreErrors does not join a construction's node (not checked in a game what the " ..
						"engine makes of it); build it without --ignore-errors: nothing sent", at(first[1], first[2]),
						nd.node, nd.plan.keep.construction))
				end
			end
			local okV, v, form, both = pcall(engineCheck, sp, r.removeFields, r.removeBuildings, nil, r.collisionDetail)
			if okV and v then
				local u = summary(v)
				u.form = form
				-- (whether the unforced build would have been refused: ignoredErrors only says it was sent forced)
				u.refused = refuses(v) or (v.errors ~= nil and #v.errors > 0)
				u.collisionEntities = v.collisions and core.array(v.collisions) or nil
				u.collisionDetail = v.collisionDetail
				out.unforced = u
				if both then out.unforcedContexts = { own = both.own, build = both.build } end
				if v.critical then
					out.unforcedCritical = "the engine's check says critical: makeWorldBuildProposalCmd's ignoreErrors " ..
						"builds past non-critical errors only (api/tealdef/api/cmd.d.tl), so the build may be refused all the same"
				end
				if v.collisions and describeHits then
					local okH, hits = pcall(describeHits, v.collisions, cx, cy)
					if okH then out.unforced.hits = hits else out.unforced.hitsError = tostring(hits) end
				end
				if type(u.collisionDetail) == "table" and u.hits then
					local okO, o = pcall(core.collisionOverlaps, mineBoxes, u.hits)
					if okO then u.collisionDetail.overlaps = o else u.collisionDetail.overlapsError = tostring(o) end
				end
			else
				out.unforced = { unread = tostring(okV and form or v) }
			end
			out.ignoredErrors = true
		end
		local before = {}
		for _, p in ipairs(P) do
			for e in pairs(piecesAround(p.a, p.b)) do before[e] = true end
		end
		local job = { id = c.id, kind = "road", out = out, started = appTime(), before = balance(),
			piecesBefore = before, sp = sp, ctxArgs = { r.removeFields, r.removeBuildings }, batch = batch,
			detail = r.collisionDetail, boxes = r.collisionDetail and mineBoxes or nil }
		if batch then
			job.pieces = {}
			for _, p in ipairs(P) do job.pieces[#job.pieces + 1] = p.out end
		end
		out.removeBuildings = r.removeBuildings or nil
		api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(sp, context(r.removeFields, r.removeBuildings), force, true), function(data, success, entities)
			local ok, cerr = pcall(function()
				local v = verdict(try(function() return data.resultProposalData end), "resultProposalData", job.detail)
				local list = ids(try(function() return data.resultEntities end))
				if #list == 0 then list = ids(entities) end
				job.result = { success = success == true, verdict = v, entities = list }
			end)
			if not ok then job.result = { success = success == true, verdict = { callbackError = tostring(cerr) }, entities = {} } end
		end)
		jobs[#jobs + 1] = job
	end

	-- a junction set-up's trafficLightPreference (engine.d.tl BaseNodeConfig; type.d.tl TrafficLightPreference YES /
	-- NO / AUTO): its name, by the enum's values, and its number; "unread" (and nil) when it does not read, the
	-- number alone as a string when it is none of the three
	local LIGHT_PREFS = { "YES", "NO", "AUTO" }
	function lightPreference(cfg)
		local ok, v = pcall(function() return cfg.trafficLightPreference end)
		if not ok or v == nil then return "unread", nil end
		for _, k in ipairs(LIGHT_PREFS) do
			local e = enumOf("TrafficLightPreference", k)
			if e ~= nil and e == v then return k, tonumber(v) end
		end
		return tostring(v), tonumber(v)
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
				-- whether a light is wanted there (YES / NO / AUTO: lights --off writes NO), its number, and the
				-- light's type
				local pref, prefValue = lightPreference(cfg)
				out.nodeConfig.trafficLightPreference = pref
				out.nodeConfig.trafficLightPreferenceValue = prefValue
				out.nodeConfig.trafficLightType = tonumber(try(function() return cfg.trafficLightConfig.trafficLightType end))
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

	-- a built piece's own nodes, and for a bridge its edge type and typeIndex read back (whether the engine kept it
	-- a bridge of that type; "unread" where they cannot be read), into po
	local function readBack(po, e)
		local be = comp(e, "BASE_EDGE")
		po.node0, po.node1 = tonumber(core.field(be, "node0")), tonumber(core.field(be, "node1"))
		if po.bridge then
			local t, i = be and core.field(be, "type"), be and tonumber(core.field(be, "typeIndex"))
			local names = {}
			for _, k in ipairs({ "NORMAL", "BRIDGE", "TUNNEL" }) do
				local v = enumOf("BaseEdgeType", k)
				if v ~= nil then names[v] = k end
			end
			po.bridge.built = { edgeType = t ~= nil and (names[t] or tostring(t)) or "unread", typeIndex = i or "unread",
				asSent = t ~= nil and names[t] == "BRIDGE" and i == po.bridge.id }
		end
	end

	-- a batch's result: each piece's edge among the result's (its two ends at the piece's, either way round), else
	-- found between its ends; the named nodes' ids as built
	local function finishBatch(job, out, res, edges)
		local function near(p, q) return p and math.sqrt((p.x - q.x) ^ 2 + (p.y - q.y) ^ 2) <= MATCH_M end
		local used, missing, named = {}, 0, {}
		for _, po in ipairs(job.pieces) do
			local found
			for _, e in ipairs(edges) do
				if not used[e] then
					local be = comp(e, "BASE_EDGE")
					local p0, p1 = nodePos(core.field(be, "node0")), nodePos(core.field(be, "node1"))
					if (near(p0, po.from) and near(p1, po.to)) or (near(p0, po.to) and near(p1, po.from)) then found = e; break end
				end
			end
			if not found and res.success then
				local e = pieceBetween(po.from, po.to, job.piecesBefore)
				if e and not used[e] then
					found = e
					po.why = "the result named no piece between its ends: found between the ends"
				end
			end
			if found then
				used[found] = true
				po.edge = found
				readBack(po, found)
				-- (node0 was sent at from, node1 at to: a piece the engine turned round would say so here)
				for _, q in ipairs({ { po.from, po.node0, po.node1 }, { po.to, po.node1, po.node0 } }) do
					local endp, n, other = q[1], q[2], q[3]
					if endp.name and n then
						local pos = nodePos(n)
						if not near(pos, endp) then n = other end
						if named[endp.name] and named[endp.name] ~= n then
							out.namedNodesNote = "a named node came back as more than one node: look at the map"
						end
						named[endp.name] = named[endp.name] or n
					end
				end
			elseif res.success then
				missing = missing + 1
			end
		end
		if res.success and missing > 0 then
			out.warning = string.format("the engine said built, but %d of the %d pieces were not found between their ends " ..
				"(look at the map)", missing, #job.pieces)
		end
		local list = {}
		for _, po in ipairs(job.pieces) do list[#list + 1] = po.edge or false end
		out.pieceEdges = core.array(list)
		if next(named) then out.namedNodes = named end
	end

	-- a road's result: the new piece and nodes among the result's entities, else the piece found between the ends
	finishRoad = function(job, out, res)
		local edges, nodes = {}, {}
		for _, e in ipairs(res.entities) do
			if comp(e, "BASE_EDGE") then edges[#edges + 1] = e elseif comp(e, "BASE_NODE") then nodes[#nodes + 1] = e end
		end
		if not job.batch and res.success and #edges == 0 then
			local e = pieceBetween(out.from, out.to, job.piecesBefore)
			if e then
				edges[1] = e
				out.why = "the result named no piece: found between the ends"
			else
				out.warning = "the engine said built, but no new piece between the ends was found (look at the map)"
			end
		end
		if job.batch then
			finishBatch(job, out, res, edges)
			-- (a piece found between its ends that the result did not name is among the edges too)
			local have = setOf(edges)
			for _, po in ipairs(job.pieces) do
				if po.edge and not have[po.edge] then edges[#edges + 1] = po.edge; have[po.edge] = true end
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
		if job.batch then return end
		out.edge = edges[1]
		if res.success and edges[1] then readBack(out, edges[1]) end
	end

	-- no callback in RESULT_SEC: the piece may still have been built; it is looked for between its ends (a batch's
	-- every piece: the proposal is built whole or not at all, so one found says it was built)
	roadLost = function(job, why)
		local o = job.out
		if job.batch then
			local list = {}
			for _, po in ipairs(job.pieces) do
				local e = pieceBetween(po.from, po.to, job.piecesBefore)
				if e then list[#list + 1] = e end
			end
			if #list == 0 then return fail(job.id, why .. "; no piece between the ends of any of the batch's pieces (look at the map)") end
			job.result = { success = true, verdict = {}, entities = list }
			o.why = string.format("%s; %d of the %d pieces found between their ends", why, #list, #job.pieces)
			return finish(job)
		end
		local e = pieceBetween(o.from, o.to, job.piecesBefore)
		if e then
			job.result = { success = true, verdict = {}, entities = { e } }
			o.why = why .. "; a piece between the ends was found"
			return finish(job)
		end
		return fail(job.id, why .. "; no piece between the ends (look at the map)")
	end

	---------------------------------------------------------------------------------------------------------------
	-- lights --node ID --off (lightsOff): a junction's traffic light taken off as the node's window does it
	-- (base gui/entity_window/double_slip_switch.tl, TrafficLightConfigWidget: makeData copies the set-up's
	-- trafficLightConfig with clone(), its "None" button sets trafficLightPreference NO, its "Reset to Default"
	-- button sets the config's states to {}; both in one proposal here, because the road command refuses a node by
	-- its phases (planJoin reads states, not the preference) and None alone keeps them; makeCmd sends
	-- api.engine.util.proposal.createTrafficLightProposal(node, config, preference) as
	-- api.cmd.makeWorldBuildProposalCmd(proposal, nil, false, true): no Context, ignoreErrors off, player-initiated).
	-- The window offers it only where more than two street pieces meet (view_manager_util.tl
	-- baseNodeCanConfigTrafficLight), so this refuses other nodes; a construction's node is refused too (its set-up
	-- is the construction's; not seen in the window). The road command does not join a node with traffic lights
	-- (planJoin): this is the way to take them off first. Not checked in a game yet (written 2026-11-24).
	local NOTE_LIGHTS = "the node's window's way (its None button: trafficLightPreference NO, and its Reset to Default: " ..
		"the phases emptied, in one proposal sent with createTrafficLightProposal); not checked in a game yet whether " ..
		"the engine keeps both (after: what was read back) and whether road then joins the node: look at it (road " ..
		"--inspect-node)"

	-- what a set-up says of its traffic light, as plain values
	local function lightsOf(cfg)
		local pref, value = lightPreference(cfg)
		return { trafficLightPreference = pref, trafficLightPreferenceValue = value,
			trafficLightStates = tonumber(try(function() return core.size(cfg.trafficLightConfig.states) end)),
			trafficLightType = tonumber(try(function() return cfg.trafficLightConfig.trafficLightType end)) }
	end
	local function lightsNow(n)
		local ok, cfg = pcall(function() return api.engine.getComponent(n, CT().BASE_NODE_CONFIG) end)
		if not ok then return { unread = tostring(cfg) } end
		if cfg == nil then return { unread = "no junction set-up" } end
		return lightsOf(cfg)
	end

	function B.lightsOff(c)
		local r, err = core.lightsOffRequest(c.args)
		if not r then return fail(c.id, err) end
		local n = r.node
		local exists = try(function() return api.engine.entityExists(n) end)
		if exists == false then return fail(c.id, string.format("%d is no entity: nothing sent", n)) end
		local p = nodePos(n)
		if not p then return fail(c.id, string.format("%d is no node (no BASE_NODE position): nothing sent", n)) end
		local NO = enumOf("TrafficLightPreference", "NO")
		if NO == nil then return fail(c.id, "api.type.enum.TrafficLightPreference.NO could not be read: nothing sent") end
		local make = try(function() return api.engine.util.proposal.createTrafficLightProposal end)
		if make == nil then
			return fail(c.id, "api.engine.util.proposal.createTrafficLightProposal is not there: nothing sent")
		end
		local segs = streetSegmentsAt(n)
		if not segs then
			return fail(c.id, "the street pieces at node " .. n .. " could not be read (getNodeStreetSegments): nothing sent")
		end
		if #segs <= 2 then
			return fail(c.id, string.format("node %d has %d street piece%s: the node's window offers traffic lights " ..
				"only where more than two meet (baseNodeCanConfigTrafficLight): nothing sent", n, #segs,
				#segs == 1 and "" or "s"))
		end
		local con, unread = constructionOfNode(n, segs)
		if con then
			return fail(c.id, string.format("node %d is construction %d's (%s): its junction set-up is the " ..
				"construction's, and lights does not change it: nothing sent", n, con.construction, tostring(con.fileName)))
		end
		if unread then
			return fail(c.id, "whether node " .. n .. " is a construction's could not be read (" .. unread .. "): nothing sent")
		end
		local ok, cfg = pcall(function() return api.engine.getComponent(n, CT().BASE_NODE_CONFIG) end)
		if not ok then return fail(c.id, "the junction set-up of node " .. n .. " could not be read: " .. tostring(cfg) .. ": nothing sent") end
		if cfg == nil then return fail(c.id, "node " .. n .. " has no junction set-up (BASE_NODE_CONFIG): nothing sent") end
		local before = lightsOf(cfg)
		local out = { ok = true, node = n, x = p.x, y = p.y, z = p.z, before = before, testSave = r.testSave,
			note = NOTE_LIGHTS }
		local okP, isNo = pcall(function() return cfg.trafficLightPreference == NO end)
		if okP and isNo and before.trafficLightStates == 0 then
			out.changed, out.sent = false, false
			out.why = "its trafficLightPreference is NO already and it has no phases: nothing sent"
			return answer(c.id, out)
		end
		-- (the window's makeData: a copy of the config, the type kept; its phases emptied, as Reset to Default)
		local okC, config = pcall(function() return cfg.trafficLightConfig:clone() end)
		if not okC or config == nil then
			return fail(c.id, "the traffic light config of node " .. n .. " could not be copied (clone): " ..
				tostring(okC and "nothing given back" or config) .. ": nothing sent")
		end
		local okS, serr = pcall(function() config.states = {} end)
		if not okS then
			return fail(c.id, "the traffic light phases of node " .. n .. " could not be emptied: " .. tostring(serr) ..
				": nothing sent")
		end
		local okM, prop = pcall(make, n, config, NO)
		if not okM or prop == nil then
			return fail(c.id, "createTrafficLightProposal: " .. tostring(okM and "nothing given back" or prop) .. ": nothing sent")
		end
		if r.dryRun then
			-- the proposal asked of the engine alone (makeProposalData with no Context, as the window sends none),
			-- never sent
			out.dryRun, out.sent = true, false
			local mpd = try(function() return api.engine.util.proposal.makeProposalData end)
			local okD, data = false, "api.engine.util.proposal.makeProposalData is not there"
			if mpd then okD, data = pcall(mpd, prop) end
			if not okD or data == nil then
				out.checked = false
				out.engineCheck = "not available: " .. tostring(okD and "nothing given back" or data)
				return answer(c.id, out)
			end
			local v = verdict(data, "makeProposalData (proposal)")
			for k, val in pairs(v) do out[k] = val end
			out.checked, out.engineCheck = true, "makeProposalData (proposal)"
			local no = refuses(v)
			out.verdict = no and "refused" or ((v.warnings ~= nil and #v.warnings > 0) and "buildable with warnings" or "buildable")
			if no then
				out.ok = false
				out.error = "the engine would refuse it: " .. dryReason(v) .. " (dry run: nothing sent)"
				return answer(c.id, out, "error")
			end
			return answer(c.id, out)
		end
		local job = { id = c.id, kind = "lights", out = out, started = appTime(), before = balance(), node = n }
		out.sent = true
		api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(prop, nil, false, true), function(data, success, entities)
			local okV, cerr = pcall(function()
				local v = verdict(try(function() return data.resultProposalData end), "resultProposalData")
				job.result = { success = success == true, verdict = v, entities = ids(entities) }
			end)
			if not okV then job.result = { success = success == true, verdict = { callbackError = tostring(cerr) }, entities = {} } end
		end)
		jobs[#jobs + 1] = job
	end

	-- a lights result: the node's light read back (after), and whether it is off now
	finishLights = function(job, out, res)
		local after = lightsNow(job.node)
		out.after = after
		out.off = after.trafficLightPreference == "NO" and after.trafficLightStates == 0
		out.changed = res.success and out.off or false
		if res.success and not out.off then
			out.warning = "the engine said done, but the node reads trafficLightPreference " ..
				tostring(after.trafficLightPreference or after.unread) .. " and " .. tostring(after.trafficLightStates) ..
				" phases, not NO and 0 (road refuses a node with phases; look at it: road --inspect-node)"
		end
	end

	-- no callback in RESULT_SEC: the node is read again; NO there is taken as done
	lightsLost = function(job, why)
		local after = lightsNow(job.node)
		if after.trafficLightPreference == "NO" and after.trafficLightStates == 0 then
			job.result = { success = true, verdict = {}, entities = {} }
			job.out.why = why .. "; the node reads trafficLightPreference NO and no phases"
			return finish(job)
		end
		return fail(job.id, why .. "; the node's trafficLightPreference reads " ..
			tostring(after.trafficLightPreference or after.unread) .. " (look at it: road --inspect-node)")
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
