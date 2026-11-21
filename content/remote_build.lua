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

	-- a module's desc by its resName (moduleRep), or nil with names that look alike: the same file name, or another
	-- module in the same folder (a harbour's are all in one)
	local function moduleOf(name)
		local idx = tonumber(try(function() return api.res.moduleRep.find(name) end))
		if idx and idx >= 0 then return try(function() return api.res.moduleRep.get(idx) end) or {} end
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

	-- the desc's metadata and updateScript as values the params can carry: metadata is a Lua table already
	-- (ModuleDesc.metadata : table), the ScriptRef an engine record, copied out as { fileName, params }
	local function moduleDesc(d)
		local us = core.field(d, "updateScript")
		local file = us and core.field(us, "fileName")
		local script
		if type(file) == "string" and file ~= "" then
			local p = core.field(us, "params")
			script = { fileName = file, params = type(p) == "table" and p or (p ~= nil and core.plain(p)) or {} }
		end
		local md = core.field(d, "metadata")
		return { metadata = type(md) == "table" and md or nil, updateScript = script }
	end

	-- every module's name checked before anything is sent; with fill, what each lacks filled from its desc.
	-- -> filled ({ [slot] = { field names } }), or nil and why
	local function checkModules(mods, fill)
		local slots = {}
		for k in pairs(mods) do slots[#slots + 1] = k end
		table.sort(slots)
		local filled, bad = {}, {}
		for _, k in ipairs(slots) do
			local m = mods[k]
			local d, like = moduleOf(m.name)
			if not d then
				local msg = string.format("slot %d: no module %s", k, m.name)
				if like and #like > 0 then msg = msg .. " (names like it: " .. table.concat(like, ", ") .. ")" end
				bad[#bad + 1] = msg
			elseif fill then
				filled[k] = core.fillModule(m, moduleDesc(d))
			end
		end
		if #bad > 0 then return nil, "nothing sent: " .. table.concat(bad, "; ") end
		return filled
	end

	local function waterLevel()
		return tonumber(try(function()
			return api.engine.getComponent(api.engine.util.getWorld(), CT().TERRAIN).waterLevel
		end))
	end
	-- true / false, or nil when it could not be read
	local function onWater(x, y)
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
		local filled
		if r.modules then
			-- a module the rep does not know is refused here, not sent (what the engine does with one: not checked)
			local f, merr = checkModules(params.modules, r.fillModules)
			if not f then return fail(c.id, merr) end
			filled = f
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
			modulesNote = r.modules and NOTE_MODULES or nil }
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
			out.waterLevel, out.onWater = waterLevel(), onWater(r.x, r.y)
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
		if job.kind == "place" then
			local cons = {}
			for _, e in ipairs(res.entities) do
				local d = describe(e)
				if d then cons[#cons + 1] = d end
			end
			out.entities = core.array(res.entities)
			if res.success then
				out.entity = cons[1] and cons[1].entity or nil
				out.construction = cons[1]
				for _, d in ipairs(cons) do built[d.entity] = { res = out.res, x = out.at.x, y = out.at.y, z = out.at.z } end
				if not cons[1] then out.why = "built, but no construction came back among the result's entities" end
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
		else
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
		local pts, nWater, nLand = {}, 0, 0
		for _, p in ipairs(r.points) do
			local w, h = onWater(p.x, p.y), heightAt(p.x, p.y)
			if w == true then nWater = nWater + 1 elseif w == false then nLand = nLand + 1 end
			pts[#pts + 1] = { x = p.x, y = p.y, onWater = w, height = h,
				depth = (w and level and h and h < level) and level - h or nil }
		end
		local out = { ok = true, waterLevel = level, points = core.array(pts), water = nWater, land = nLand }
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
