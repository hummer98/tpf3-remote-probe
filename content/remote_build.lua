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

	local NOTE = "not checked in a game yet: look at it (frame) before trusting the answer"

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
		count = count + 1
		local name = r.name or string.format("%s %d", core.BUILD_NAME_PREFIX, count)
		local sp = api.type.SimpleProposal.new()
		local ce = api.type.SimpleProposal.ConstructionEntity.new()
		ce.fileName = res
		ce.params = params
		ce.transf = transfOf(r.x, r.y, z, r.angle)
		ce.name = name
		ce.playerEntity = player()
		-- (a station's or a depot's module slots as the player's menu fills them)
		ce.autoFillSlots = true
		-- the whole list at once: an element written into the engine's list is lost (AoM strawberries.lua, in game
		-- 2026-11-16: "build done", 0 entities)
		sp.constructionsToAdd = { ce }
		local out = { res = res, at = { x = r.x, y = r.y, z = z }, zFrom = zFrom, angle = r.angle, params = params,
			name = name, note = NOTE }
		if r.dryRun then
			-- the engine's own check, without building; makeProposalData is typed for a Proposal (cmd.d.tl), so a
			-- SimpleProposal may be refused: then only the name and the height were checked
			local ok, data = pcall(function() return api.engine.util.proposal.makeProposalData(sp, context()) end)
			out.ok, out.dryRun = true, true
			if ok and data then
				for k, v in pairs(verdict(data)) do out[k] = v end
				out.buildable = not out.critical and not (out.errors and #out.errors > 0)
			else
				out.checked = false
				out.why = "the engine's check of a proposal could not be run here: " .. tostring(data)
			end
			return answer(c.id, out)
		end
		-- (the job is listed once the command is sent: a send that raises is answered by the handler's pcall alone)
		local job = { id = c.id, kind = "place", out = out, started = appTime(), before = balance() }
		api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(sp, context(), false, true), function(data, success, entities)
			-- only plain values leave the callback (the engine's objects belong to it)
			local v = verdict(try(function() return data.resultProposalData end))
			local list = ids(try(function() return data.resultEntities end))
			if #list == 0 then list = ids(entities) end
			job.result = { success = success == true, verdict = v, entities = list }
		end)
		jobs[#jobs + 1] = job
	end

	local function remove(c, r)
		local list = r.remove
		if r.removeAll then
			list = {}
			for e in pairs(built) do list[#list + 1] = e end
			table.sort(list)
			if #list == 0 then
				return fail(c.id, "this load of the probe built nothing (after a load give the ids: those named "
					.. core.BUILD_NAME_PREFIX .. "... are taken)")
			end
		end
		local bad = {}
		for _, e in ipairs(list) do
			local name = nameOf(e)
			if not comp(e, "CONSTRUCTION") then
				bad[#bad + 1] = string.format("%d is no construction", e)
			elseif not core.buildRemovable(e, built, name) then
				bad[#bad + 1] = string.format("%d (%s) was not built by the probe", e, tostring(name))
			end
		end
		if #bad > 0 then return fail(c.id, "nothing removed: " .. table.concat(bad, "; ")) end
		local sp = api.type.SimpleProposal.new()
		sp.constructionsToRemove = list
		local job = { id = c.id, kind = "remove", out = { removed = core.array(list), note = NOTE }, started = appTime(),
			before = balance(), list = list }
		api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(sp, context(), false, true), function(data, success)
			job.result = { success = success == true, verdict = verdict(try(function() return data.resultProposalData end)) }
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
				fail(job.id, string.format("no answer from the engine in %d s (look at the map: it may be built)", RESULT_SEC))
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

	B.built = function() return built end
	return B
end

return M
