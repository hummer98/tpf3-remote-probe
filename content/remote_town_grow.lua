-- town develop / town size: buildings added at a point (api.cmd.makeTownDevelopAtCmd(position : Vec2f,
-- developStreets, upgradeBuildings): "new buildings or street segments are added at the given position") and a
-- town's size factors set (api.cmd.makeTownUpdateSizeCmd(townEntity, landUseSizeFactors, updateAllBuildings): the
-- residential, commercial and industrial factors, as the base's town_growth script sends them; updateAllBuildings
-- takes every building to its target capacity). For maps made for tests: a harbour's or station's circle gets its
-- houses and shops without running years of steps. core.townDevelopRequest / townSizeRequest have the arguments.
-- Test saves only: they change the game as no player can.
--
-- Sent as remote_debug.lua sends its commands: api.cmd.sendCommand with a callback, everything round it in pcall,
-- a function that is not there (nil) not called. A develop sends its commands one at a time, the next after the
-- last one's callback (so each sees what the one before it built), and answers once all have come back.
--
-- The counts before and after: the town buildings of every town (townBuildingSystem.getTown2BuildingMap), each
-- one's kind from its PERSON_CAPACITY type against the LandUseType enum, as stations --catchment reads them; for a
-- develop also those whose bounding box centre is within the radius of the point.
--
-- The base's town_growth script sends makeTownUpdateSizeCmd itself from the town's sizeFactors as the town grows
-- (it only raises them), so factors set lower than the script's may be raised again by the game.
--
-- Not checked in a game yet (written 2026-11-22): the answers say so.
local M = {}

local RESULT_SEC = 30 -- for each command's callback
local SETTLE_FRAMES = 5 -- after the last callback, before the buildings are counted again
local SEND_GAP_FRAMES = 1 -- frames between a develop's callback and its next command

local NOTE = "not checked in a game yet: test saves only; the buildings may come over the next frames, so look "
	.. "again (stations --catchment, entities --kind town) before trusting the counts"
local SIZE_NOTE = NOTE .. "; the base's town growth script resends the size from the town's own factors as it "
	.. "grows (raising only)"

local KINDS = { "RESIDENTIAL", "COMMERCIAL", "INDUSTRIAL" }
local MAX_FAILURES_LISTED = 20

-- ctx: core, answer(id, payload, tag), fail(id, msg), appTime(), try(fn), say(msg, level), nameOf(e) (optional)
function M.new(ctx)
	local core, answer, fail, appTime, try, say = ctx.core, ctx.answer, ctx.fail, ctx.appTime, ctx.try, ctx.say
	local nameOf = ctx.nameOf or function(e) return try(function() return api.engine.util.getEntityName(e) end) end
	local job = nil -- one at a time: the counts before and after are a job's own only then

	local function CT() return api.type.ComponentType end
	local function comp(e, kind)
		local k = try(function() return CT()[kind] end)
		if k == nil then return nil end
		return try(function() return api.engine.getComponent(e, k) end)
	end

	local function present(key) return core.debugFunction(core.TOWN_GROW_FUNCTIONS[key]) ~= nil end
	local function functions()
		local out = {}
		for k in pairs(core.TOWN_GROW_FUNCTIONS) do out[k] = present(k) end
		return out
	end

	local function landUse(v)
		if v == nil then return nil end
		local LU = try(function() return api.type.enum.LandUseType end)
		local n = core.enumName(LU or {}, KINDS, v)
		for _, k in ipairs(KINDS) do if n == k then return k:lower() end end
		return nil
	end

	local function centre(e)
		local bv = comp(e, "BOUNDING_VOLUME")
		local bb = bv and core.field(bv, "bbox")
		local lo, hi = bb and core.field(bb, "min"), bb and core.field(bb, "max")
		local x0, y0 = tonumber(lo and core.field(lo, "x")), tonumber(lo and core.field(lo, "y"))
		local x1, y1 = tonumber(hi and core.field(hi, "x")), tonumber(hi and core.field(hi, "y"))
		if not (x0 and y0 and x1 and y1) then return nil end
		return (x0 + x1) / 2, (y0 + y1) / 2
	end

	-- every town building: { town, kind, capacity, near } (near only with a circle). nil when the map cannot be read
	local function buildings(circle)
		local map = try(function() return api.engine.system.townBuildingSystem.getTown2BuildingMap() end)
		if map == nil then return nil end
		local list = {}
		local ok = pcall(function()
			for t, bs in pairs(map) do
				for _, b in ipairs(core.toList(bs)) do
					b = tonumber(b)
					if b then
						local tb = comp(b, "TOWN_BUILDING")
						local pc = comp(b, "PERSON_CAPACITY")
						if pc == nil and tb ~= nil then
							local pe = tonumber(core.field(tb, "personCapacity"))
							if pe and pe >= 0 and pe ~= b then pc = comp(pe, "PERSON_CAPACITY") end
						end
						local row = { town = tonumber(t), kind = pc and landUse(core.field(pc, "type")) or nil,
							capacity = pc and tonumber(core.field(pc, "capacity")) or nil }
						if circle then
							local x, y = centre(b)
							row.near = x ~= nil and ((x - circle.x) ^ 2 + (y - circle.y) ^ 2 <= circle.r ^ 2) or false
						end
						list[#list + 1] = row
					end
				end
			end
		end)
		if not ok then return nil end
		return list
	end

	local function snapshot(circle)
		local list = buildings(circle)
		if list == nil then return nil end
		local towns, total, near = core.townBuildingCounts(list)
		return { towns = towns, total = total, near = circle and near or nil }
	end

	-- the town's size factors, initial capacities and population as the TOWN component and the capacities map
	-- have them
	local function townState(e)
		local t = comp(e, "TOWN")
		if t == nil then return nil end
		local s = { sizeFactors = core.array(core.toList(core.field(t, "sizeFactors"))),
			initialLandUseCapacities = core.array(core.toList(core.field(t, "initialLandUseCapacities"))),
			developmentActive = core.field(t, "developmentActive") }
		local caps = try(function() return api.engine.system.townBuildingSystem.getTown2personCapacitiesMap() end)
		local c = caps ~= nil and core.field(caps, e) or nil
		if c ~= nil then s.personCapacities = core.array(core.toList(c)) end
		return s
	end

	local function plainResult(res)
		local ok, v = pcall(core.plain, res)
		return ok and v or nil
	end

	-- make and send one command; the callback fills job.called / job.success / job.result. -> true, or false and why
	local function send(make)
		local okM, cmd = pcall(make)
		if not okM then return false, "making the command raised: " .. tostring(cmd) end
		if cmd == nil then return false, "making the command gave nothing (nil)" end
		local j = job
		local okS, err = pcall(function()
			api.cmd.sendCommand(cmd, function(res, success)
				if job ~= j then return end -- a late callback of a job already answered
				j.called, j.success, j.result = true, success, plainResult(res)
			end)
		end)
		if not okS then return false, "sendCommand raised: " .. tostring(err) end
		j.deadline = appTime() + RESULT_SEC
		return true
	end

	local function busyAnswer(c, out)
		out.ok, out.sent = false, false
		out.error = "town " .. job.kind .. " (command " .. job.id .. ") is still running: send again once it has answered"
		answer(c.id, out, "error")
	end

	local function missing(out, keys)
		for _, k in ipairs(keys) do
			if not out.functions[k] then return core.TOWN_GROW_FUNCTIONS[k] end
		end
		return nil
	end

	-- the rows of the towns whose counts changed (all of them when asked), with their names
	local function townRows(before, after, all)
		local rows, seen = {}, {}
		local function add(t)
			if seen[t] then return end
			seen[t] = true
			local b, a = before and before.towns[t], after and after.towns[t]
			local d = core.townCountDelta(b or {}, a or {})
			local changed = false
			for _, v in pairs(d) do if v ~= 0 then changed = true end end
			if all or changed then
				rows[#rows + 1] = { town = t >= 0 and t or nil, name = t >= 0 and nameOf(t) or nil, before = b,
					after = a, delta = d }
			end
		end
		for t in pairs(before and before.towns or {}) do add(t) end
		for t in pairs(after and after.towns or {}) do add(t) end
		table.sort(rows, function(x, y) return (x.town or -1) < (y.town or -1) end)
		return core.array(rows)
	end

	local T = {}

	-- args: core.townDevelopRequest's
	function T.develop(c)
		local r, err = core.townDevelopRequest(c.args)
		if not r then return fail(c.id, err) end
		local circle = { x = r.at.x, y = r.at.y, r = r.radius }
		local out = { ok = true, cmd = "townDevelop", dryRun = r.dryRun or nil, at = r.at, streets = r.streets,
			upgrade = r.upgrade, count = r.count, radius = r.radius, functions = functions(), note = NOTE }
		if job then return busyAnswer(c, out) end
		local before = snapshot(circle)
		out.before = before and { total = before.total, near = before.near } or nil
		if before == nil then out.warning = "the town buildings could not be read: no counts" end
		if r.dryRun then
			out.sent = 0
			out.towns = before and townRows(before, nil, true) or nil
			return answer(c.id, out)
		end
		local gone = missing(out, { "develop", "vec2f", "send" })
		if gone then
			out.ok, out.sent = false, 0
			out.error = gone .. " is not there (nil) in this game: nothing sent"
			say("town develop (command " .. c.id .. "): " .. gone .. " is missing", 1)
			return answer(c.id, out, "error")
		end
		job = { id = c.id, kind = "develop", r = r, out = out, before = before, circle = circle, sent = 0, succeeded = 0,
			failed = 0, failures = {}, gap = 0, startedAt = appTime() }
		T.next()
	end

	-- a develop's next command; false when sending failed (the job is answered then)
	function T.next()
		local j, r = job, job.r
		j.called, j.success, j.result = nil, nil, nil
		local ok, serr = send(function()
			return api.cmd.makeTownDevelopAtCmd(api.type.Vec2f.new(r.at.x, r.at.y), r.streets, r.upgrade)
		end)
		if not ok then
			j.sendError = serr
			return false
		end
		j.sent = j.sent + 1
		return true
	end

	-- args: core.townSizeRequest's
	function T.size(c)
		local r, err = core.townSizeRequest(c.args)
		if not r then return fail(c.id, err) end
		local out = { ok = true, cmd = "townSize", dryRun = r.dryRun or nil, entity = r.entity, factors = r.factors,
			updateAll = r.updateAll, functions = functions(), note = SIZE_NOTE }
		if job then return busyAnswer(c, out) end
		-- only an id the engine has, with a TOWN, reaches the command (an unknown id may assert)
		if try(function() return api.engine.entityExists(r.entity) end) ~= true then
			return fail(c.id, "no such entity: " .. r.entity)
		end
		local st = townState(r.entity)
		if st == nil then return fail(c.id, "entity " .. r.entity .. " is no town (no TOWN component)") end
		out.name = nameOf(r.entity)
		out.townBefore = st
		local before = snapshot(nil)
		-- a town with no buildings yet has no row: its counts are 0
		local none = select(2, core.townBuildingCounts({}))
		out.before = before and (before.towns[r.entity] or none) or nil
		if before == nil then out.warning = "the town buildings could not be read: no counts" end
		if r.dryRun then
			out.sent = 0
			return answer(c.id, out)
		end
		local gone = missing(out, { "size", "send" })
		if gone then
			out.ok, out.sent = false, 0
			out.error = gone .. " is not there (nil) in this game: nothing sent"
			say("town size (command " .. c.id .. "): " .. gone .. " is missing", 1)
			return answer(c.id, out, "error")
		end
		job = { id = c.id, kind = "size", r = r, out = out, before = before, sent = 0, succeeded = 0, failed = 0,
			failures = {}, startedAt = appTime() }
		local ok, serr = send(function()
			-- a plain list of 3 numbers, as the base's town_growth script passes the factors
			return api.cmd.makeTownUpdateSizeCmd(r.entity, { r.factors[1], r.factors[2], r.factors[3] }, r.updateAll)
		end)
		if not ok then
			job = nil
			out.ok, out.sent, out.error = false, 0, serr
			return answer(c.id, out, "error")
		end
		job.sent = 1
	end

	local function finish(j)
		job = nil
		local out = j.out
		out.sent, out.succeeded, out.failed = j.sent, j.succeeded, j.failed
		out.failures = #j.failures > 0 and core.array(j.failures) or nil
		out.engineResult = j.firstResult
		out.waitedSec = appTime() - j.startedAt
		local after = snapshot(j.circle)
		if j.kind == "develop" then
			out.after = after and { total = after.total, near = after.near } or nil
			out.delta = after and j.before and { total = core.townCountDelta(j.before.total, after.total),
				near = core.townCountDelta(j.before.near, after.near) } or nil
			out.towns = (after or j.before) and townRows(j.before, after, false) or nil
		else
			out.after = after and (after.towns[j.r.entity] or select(2, core.townBuildingCounts({}))) or nil
			out.delta = core.townCountDelta(out.before, out.after)
			out.townAfter = townState(j.r.entity)
		end
		if j.error then
			out.ok, out.error = false, j.error
			say("town " .. j.kind .. " (command " .. j.id .. "): " .. j.error, 1)
			return answer(j.id, out, "error")
		end
		if j.succeeded == 0 then
			out.ok = false
			out.error = "the engine refused " .. (j.sent == 1 and "the command" or "all " .. j.sent .. " commands")
				.. " (its callback said no success)"
			say("town " .. j.kind .. " (command " .. j.id .. "): refused by the engine", 1)
			return answer(j.id, out, "error")
		end
		answer(j.id, out)
	end

	local function progress()
		local j = job
		if j.settle then
			j.settle = j.settle - 1
			if j.settle <= 0 then finish(j) end
			return
		end
		if j.sendError then
			-- nothing more sent; what was sent before is answered
			j.error = j.sent == 0 and j.sendError or ("after " .. j.sent .. " commands: " .. j.sendError)
			j.settle = j.sent > 0 and SETTLE_FRAMES or 1
			return
		end
		if j.called then
			if j.success == true then j.succeeded = j.succeeded + 1
			else
				j.failed = j.failed + 1
				if #j.failures < MAX_FAILURES_LISTED then
					j.failures[#j.failures + 1] = { index = j.sent, success = j.success, engineResult = j.result }
				end
			end
			if j.firstResult == nil then j.firstResult = j.result end
			j.called = nil
			if j.kind == "develop" and j.sent < j.r.count then
				j.gap = SEND_GAP_FRAMES
			else
				j.settle = SETTLE_FRAMES
			end
			return
		end
		if j.gap and j.gap > 0 then
			j.gap = j.gap - 1
			if j.gap == 0 then T.next() end
			return
		end
		if j.deadline and appTime() > j.deadline then
			j.error = "no callback from the engine in " .. RESULT_SEC .. " s for command " .. j.sent .. " of "
				.. (j.kind == "develop" and j.r.count or 1) .. " (sent; whether it ran is not known)"
			j.settle = 1
		end
	end

	function T.step()
		if job == nil then return end
		local j = job
		local ok, err = pcall(progress)
		if not ok then
			if job == j then job = nil end
			fail(j.id, err)
		end
	end

	-- a load: the job's callbacks will not come
	function T.reset() job = nil end

	T.handlers = { townDevelop = T.develop, townSize = T.size }
	return T
end

return M
