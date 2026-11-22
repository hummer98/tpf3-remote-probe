-- town connections / town connect: which towns the engine counts as connected, which town each industry belongs to,
-- and the map editor's two connection commands, for maps made for tests.
--
-- What the engine has (api tealdef and map_editor.tl, read 2026-11-23):
-- - The connections are between towns, not between a town and an industry: a map's townConnections
--   (api.engine.terrain.makeMapFromGame(false, true, false, false), as the editor's Connections tab reads them) are
--   pairs of indices into the map's towns, each town with its entity in .existing. The component behind them
--   (TownConnection: entity0, entity1, time, valid) has no ComponentType in the API.
-- - An industry's town is the closest one (streetConnectorSystem.getConstructionClosestTown of its construction;
--   getTownClosestConstructions the other way round).
-- - api.cmd.makeTownAutoDetectConnectionsCmd(townEntities): "tries to detect if an existing connection between towns
--   exists" over the roads there are (the editor's Auto-detect connections). It builds nothing.
-- - api.cmd.makeTownConnectWithIndustriesCmd(townEntities, connections, keep): "generates a new street network
--   connecting the given towns and all existing industries" (the editor's Generate; it "always connects
--   industries"). connections: index pairs into townEntities; keep false removes the street connections there are.
--   No list of industries goes in: all of them are connected.
--
-- Both commands only in the guiUpdate state here (as town develop), and test saves only. The editor's numbering of
-- the index pairs (0 or 1 based) is taken from the map's own pairs where they tell, else from indexBase.
--
-- Not checked in a game yet (written 2026-11-23): whether makeMapFromGame and these commands work in a game outside
-- the map editor, and what build makes of a map's roads.
local M = {}

local RESULT_SEC = 120 -- a street network for every industry may take a while
local SETTLE_FRAMES = 5

local NOTE = "not checked in a game yet: test saves only; look at the map (frame) and town connections again"

M.FUNCTIONS = { map = "api.engine.terrain.makeMapFromGame", defaults = "api.engine.mapgen.getDefaultTownConnections",
	auto = "api.cmd.makeTownAutoDetectConnectionsCmd", build = "api.cmd.makeTownConnectWithIndustriesCmd",
	send = "api.cmd.sendCommand" }

-- ctx: core, answer(id, payload, tag), fail(id, msg), appTime(), try(fn), say(msg, level),
-- towns() -> { { id, name } }, industries() -> { { id, name, construction } }
function M.new(ctx)
	local core, answer, fail, appTime, try, say = ctx.core, ctx.answer, ctx.fail, ctx.appTime, ctx.try, ctx.say
	local job = nil

	local function functions()
		local out = {}
		for k, path in pairs(M.FUNCTIONS) do out[k] = core.debugFunction(path) ~= nil end
		return out
	end

	local function pairList(v)
		local out = {}
		for _, p in ipairs(core.toList(v)) do
			out[#out + 1] = { tonumber(core.at(p, 1)), tonumber(core.at(p, 2)) }
		end
		return out
	end

	-- the map's towns in its order { entity, name, x, y }, its connections (index pairs) and the map itself
	local function mapState()
		local ok, map = pcall(function() return api.engine.terrain.makeMapFromGame(false, true, false, false) end)
		if not ok then return nil, "makeMapFromGame raised: " .. tostring(map) end
		if map == nil then return nil, "makeMapFromGame gave nothing" end
		local towns = {}
		for _, t in ipairs(core.toList(core.field(map, "towns"))) do
			local p = core.field(t, "pos")
			towns[#towns + 1] = { entity = tonumber(core.field(t, "existing")), name = core.field(t, "name"),
				x = p and tonumber(core.field(p, "x")) or nil, y = p and tonumber(core.field(p, "y")) or nil }
		end
		return { map = map, towns = towns, connections = pairList(core.field(map, "townConnections")) }
	end

	local function defaultPairs(ms)
		local ok, v = pcall(function() return api.engine.mapgen.getDefaultTownConnections(core.field(ms.map, "towns")) end)
		if not ok then return nil, tostring(v) end
		return pairList(v)
	end

	local function closestTown(construction)
		if construction == nil then return nil end
		local t = tonumber(try(function()
			return api.engine.system.streetConnectorSystem.getConstructionClosestTown(construction) end))
		if t == nil or t < 0 then return nil end
		return t
	end

	-- everything read: towns with their connected towns and industries; base from the map's pairs
	local function read(only, indexBase)
		local out = { functions = functions() }
		local names = {}
		for _, t in ipairs(ctx.towns()) do names[t.id] = t.name end
		local ms, err = mapState()
		if not ms then out.mapError = err end
		local base = ms and core.townIndexBase({ ms.connections }, #ms.towns) or nil
		out.indexBase = base or indexBase
		out.indexBaseFrom = base ~= nil and "map" or (indexBase ~= nil and "given" or nil)
		local resolved = ms and core.townPairsResolved(ms.connections, ms.towns, out.indexBase) or {}
		local rows, byId = {}, {}
		local list = ms and ms.towns or {}
		if not ms then for _, t in ipairs(ctx.towns()) do list[#list + 1] = { entity = t.id, name = t.name } end end
		for i, t in ipairs(list) do
			local row = { id = t.entity, name = names[t.entity] or t.name, mapIndex = ms and i or nil, x = t.x, y = t.y,
				connectedTowns = {}, industries = {} }
			if t.entity then byId[t.entity] = row end
			if only == nil or t.entity == only then rows[#rows + 1] = row end
		end
		for _, p in ipairs(resolved) do
			local a, b = p.from and byId[p.from], p.to and byId[p.to]
			if a and b then
				a.connectedTowns[#a.connectedTowns + 1] = { id = b.id, name = b.name }
				b.connectedTowns[#b.connectedTowns + 1] = { id = a.id, name = a.name }
			end
		end
		local unassigned = {}
		for _, ind in ipairs(ctx.industries()) do
			local t = closestTown(ind.construction)
			local entry = { id = ind.id, name = ind.name, construction = ind.construction }
			if t and byId[t] then
				local l = byId[t].industries
				l[#l + 1] = entry
			elseif only == nil then
				entry.closestTown = t
				unassigned[#unassigned + 1] = entry
			end
		end
		for _, r in ipairs(rows) do core.array(r.connectedTowns); core.array(r.industries) end
		out.towns = core.array(rows)
		out.industriesWithoutTown = only == nil and core.array(unassigned) or nil
		out.connections = core.array(resolved)
		return out, ms
	end

	local T = {}

	function T.show(c)
		local r, err = core.townConnectionsRequest(c.args)
		if not r then return fail(c.id, err) end
		if r.entity then
			local known = false
			for _, t in ipairs(ctx.towns()) do if t.id == r.entity then known = true end end
			if not known then return fail(c.id, "entity " .. r.entity .. " is no town (entities --kind town)") end
		end
		local out = read(r.entity)
		out.ok = true
		out.note = "connections are between towns (the map's townConnections); an industry's town is the closest one "
			.. "(getConstructionClosestTown)"
		answer(c.id, out)
	end

	function T.connect(c)
		local r, err = core.townConnectRequest(c.args)
		if not r then return fail(c.id, err) end
		if job then return fail(c.id, "town connect (command " .. job.id .. ") is still running: send again once it has answered") end
		local before, ms = read(nil, r.indexBase)
		local out = { ok = true, cmd = "townConnect", mode = r.auto and "auto" or "build", dryRun = r.dryRun or nil,
			keep = r.build and r.keep or nil, before = before, note = NOTE }
		if not ms then return fail(c.id, "the map could not be copied from the game: " .. tostring(before.mapError)) end
		-- only ids the map lists as towns reach the engine (an unknown id may assert)
		local need, make
		if r.auto then
			local list = {}
			if r.entities then
				local inMap = {}
				for _, t in ipairs(ms.towns) do if t.entity then inMap[t.entity] = true end end
				for _, e in ipairs(r.entities) do
					if not inMap[e] then return fail(c.id, "entity " .. e .. " is no town of this map (town connections lists them)") end
					list[#list + 1] = e
				end
			else
				for _, t in ipairs(ms.towns) do if t.entity then list[#list + 1] = t.entity end end
			end
			out.townEntities = core.array(list)
			need = "auto"
			make = function() return api.cmd.makeTownAutoDetectConnectionsCmd(list) end
		else
			local defaults
			if r.default then
				local d, derr = defaultPairs(ms)
				if not d then return fail(c.id, "getDefaultTownConnections raised: " .. derr) end
				defaults = d
				out.defaults = core.array(core.townPairsResolved(d, ms.towns, before.indexBase))
			end
			local base = core.townIndexBase({ ms.connections, defaults or {} }, #ms.towns) or r.indexBase
			local towns = {}
			for _, t in ipairs(ms.towns) do if t.entity then towns[#towns + 1] = t end end
			local plan, perr = core.townConnectPlan(r, towns, ms.connections, defaults, base)
			if not plan then return fail(c.id, perr) end
			out.indexBase = base
			out.townEntities = core.array(plan.townEntities)
			out.connectionsSent = core.array(plan.connections)
			out.pairs = core.array(plan.pairs)
			out.dropped = plan.dropped > 0 and plan.dropped or nil
			if #plan.townEntities == 0 then return fail(c.id, "no towns on this map") end
			need = "build"
			make = function()
				return api.cmd.makeTownConnectWithIndustriesCmd(plan.townEntities, plan.connections, r.keep)
			end
		end
		if r.dryRun then
			out.sent = false
			return answer(c.id, out)
		end
		if not before.functions[need] then return fail(c.id, M.FUNCTIONS[need] .. " is not there (nil) in this game") end
		local okM, cmd = pcall(make)
		if not okM or cmd == nil then return fail(c.id, "making the command failed: " .. tostring(cmd)) end
		local j = { id = c.id, out = out, r = r, startedAt = appTime(), deadline = appTime() + RESULT_SEC }
		job = j
		local okS, serr = pcall(function()
			api.cmd.sendCommand(cmd, function(_, success)
				if job == j then j.called, j.success = true, success end
			end)
		end)
		if not okS then
			job = nil
			return fail(c.id, "sendCommand raised: " .. tostring(serr))
		end
		out.sent = true
		say("town connect " .. out.mode .. " (command " .. c.id .. "): sent", 2)
	end

	local function finish(j)
		job = nil
		local out = j.out
		out.after = read(nil, j.r.indexBase)
		out.waitedSec = appTime() - j.startedAt
		out.engineSuccess = j.success
		if j.error then
			out.ok, out.error = false, j.error
		elseif j.success == false then
			out.ok, out.error = false, "the engine refused the command (its callback said no success)"
		end
		if out.ok == false then
			say("town connect (command " .. j.id .. "): " .. out.error, 1)
			return answer(j.id, out, "error")
		end
		answer(j.id, out)
	end

	function T.step()
		local j = job
		if j == nil then return end
		local ok, err = pcall(function()
			if j.settle then
				j.settle = j.settle - 1
				if j.settle <= 0 then finish(j) end
				return
			end
			if j.called then j.settle = SETTLE_FRAMES; return end
			if appTime() > j.deadline then
				j.error = "no callback from the engine in " .. RESULT_SEC .. " s (sent; whether it ran is not known)"
				j.settle = 1
			end
		end)
		if not ok then
			if job == j then job = nil end
			fail(j.id, err)
		end
	end

	function T.reset() job = nil end

	T.handlers = { townConnections = T.show, townConnect = T.connect }
	return T
end

return M
