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

	local function context()
		local c = api.type.Context.new()
		c.player = player()
		-- nothing of the player's or a town's is knocked down for it: what is in the way is a refusal
		c.cleanupStreetGraph, c.gatherBuildings, c.gatherFields = false, false, false
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
			cost = data and tonumber(try(function() return data.costs end)) or nil,
		}
	end

	-- the new construction, read back: its file, name, depots / stations / industries, and the free ends of its own
	-- roads and tracks (nodes only one of its pieces reaches, with their positions: a connect --from)
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
		return { entity = e, fileName = tostring(core.field(c, "fileName")), name = nameOf(e),
			ends = #ends > 0 and core.array(ends) or nil, depots = list("depots"), stations = list("stations"),
			industries = list("industries") }
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
			-- the probe's own checks only: the engine's makeProposalData takes a Proposal and has no SimpleProposal
			-- form (engine/util.d.tl:939), so it is not called (no buildable: only a build says that)
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
		local job = { id = c.id, kind = "place", out = out, started = appTime(), before = balance() }
		api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(sp, context(), false, true), function(data, success, entities)
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

	local function nodePos(n)
		local bn = comp(n, "BASE_NODE")
		local p = bn and core.field(bn, "position")
		local x, y, z = tonumber(core.field(p, "x")), tonumber(core.field(p, "y")), tonumber(core.field(p, "z"))
		if not (x and y and z) then return nil end
		return { x = x, y = y, z = z }
	end
	-- the road pieces (BASE_EDGE of roadType STREET) whose box meets a circle of r metres around x, y: the octree
	-- lists edges, not nodes (as nova's elevated_road builder.lua finds road ends: BASE_EDGE by findEntitiesInCircle,
	-- then their node0 / node1). A piece whose road type cannot be read is left out (never taken for a road).
	local function streetEdgesNear(x, y, r)
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

	-- whether a road node carries its junction set-up (BaseNodeConfig: its lane connections, engine.d.tl): true or
	-- false, nil when that cannot be told (no BASE_NODE_CONFIG component type, or the engine raises). A node a
	-- script's street proposal made without nodeConfigsToAdd has none (Track Connector's tc_proposal says so of
	-- roads a script built); a new piece joined to such a node killed the game (2026-11-23: Engine.h:322
	-- GetComponentDataIndex, the node without BaseNodeConfig, right after a road snapped to an earlier road's node)
	local function nodeConfigState(n)
		local ct = try(function() return CT().BASE_NODE_CONFIG end)
		if ct == nil then return nil end
		local ok, v = pcall(function() return api.engine.getComponent(n, ct) end)
		if not ok then return nil end
		return v ~= nil
	end

	-- the nearest end of a road piece within r metres of x, y, z (in three dimensions: a node of a bridge or a
	-- raised road above the point is not taken; no z: on the map's plane) that may be joined, or nil. Only the
	-- street pieces' own nodes are looked at, so no track node is asked about. A node without a junction set-up
	-- (nodeConfigState false) is never taken: the next nearest is; the second value lists the ones passed over
	-- (nearest first), so that a caller can refuse rather than put a new node beside one of them.
	local function streetNodeNear(x, y, z, r)
		local dist, pieces = {}, {}
		for _, e in ipairs(streetEdgesNear(x, y, r)) do
			local be = comp(e, "BASE_EDGE")
			for _, k in ipairs({ "node0", "node1" }) do
				local n = tonumber(core.field(be, k))
				local p = n and nodePos(n)
				if p then
					pieces[n] = (pieces[n] or 0) + 1
					local d = math.sqrt((p.x - x) ^ 2 + (p.y - y) ^ 2 + (z and (p.z - z) ^ 2 or 0))
					if d <= r then dist[n] = d end
				end
			end
		end
		local order = {}
		for n in pairs(dist) do order[#order + 1] = n end
		table.sort(order, function(a, b) if dist[a] ~= dist[b] then return dist[a] < dist[b] end return a < b end)
		local passed = {}
		for _, n in ipairs(order) do
			local cfg = nodeConfigState(n)
			if cfg == false then
				passed[#passed + 1] = { node = n, snapped = dist[n], pieces = pieces[n] }
			else
				local p = nodePos(n)
				local hit = { node = n, x = p.x, y = p.y, z = p.z, snapped = dist[n], pieces = pieces[n],
					nodeConfig = cfg == true and true or "unread" }
				if #passed > 0 then hit.passedOver = passed end
				return hit, passed
			end
		end
		return nil, passed
	end

	-- one end: a road node near it (snap), else a new node at the point (z given, or the terrain's). Refused when
	-- the only road nodes within snap have no junction set-up: joining one can kill the game, and a new node
	-- there would sit on it.
	local function roadEnd(pt, snap)
		local z, zFrom = pt[3], "given"
		if z == nil then z, zFrom = heightAt(pt[1], pt[2]), "terrain" end
		local hit, passed = nil, {}
		if snap > 0 then hit, passed = streetNodeNear(pt[1], pt[2], z, snap) end
		if hit then return hit end
		if #passed > 0 then
			local names = {}
			for _, q in ipairs(passed) do
				names[#names + 1] = string.format("%d (%.1f m, %d piece%s)", q.node, q.snapped, q.pieces, q.pieces == 1 and "" or "s")
			end
			return nil, "the road node(s) within snap have no junction set-up (BaseNodeConfig): " .. table.concat(names, ", ") ..
				". A road this command built ends in such nodes; joining one can kill the game (Engine.h " ..
				"GetComponentDataIndex), and a new node there would sit on it: nothing sent. Join a node of a " ..
				"construction's or a player's road, or build the piece from further away"
		end
		if z == nil then return nil, "the terrain's height could not be read: give z" end
		return { x = pt[1], y = pt[2], z = z, zFrom = zFrom }
	end

	-- an engine record type by name: api.type.X, else api.type.Proposal.X (type.d.tl declares NodeAndEntity and
	-- SegmentAndEntity inside Proposal; mods reach them as api.type.X: which one the game has is not checked)
	local function newRecord(name)
		local t = try(function() return api.type[name] end) or try(function() return api.type.Proposal[name] end)
		if t == nil then error("api.type has no " .. name, 0) end
		return t.new()
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
		for _, q in ipairs({ { "from", a }, { "to", b } }) do
			if q[2].nodeConfig == "unread" then
				out.caution = (out.caution and out.caution .. "; " or "") .. string.format("%s: whether node %d has its " ..
					"junction set-up (BaseNodeConfig) could not be read; joining a node without one can kill the game",
					q[1], q[2].node)
			end
		end
		if r.dryRun then
			out.ok, out.dryRun, out.checked = true, true, false
			out.why = "checked here: the template, the ends (a road node within snap, or the terrain's height) and the " ..
				"length; the engine's check (collisions, terrain, money) only comes with a build"
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
		local n0, n1 = endNode(a), endNode(b)
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
		-- whole lists, never an element written into the engine's list (see place)
		sp.streetProposal.nodesToAdd = nodes
		sp.streetProposal.edgesToAdd = { e }
		out.newNodes = #nodes
		local job = { id = c.id, kind = "road", out = out, started = appTime(), before = balance(),
			piecesBefore = piecesAround(a, b) }
		api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(sp, context(), false, true), function(data, success, entities)
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
	return B
end

return M
