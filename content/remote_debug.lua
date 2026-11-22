-- debug commands: api.cmd.debug's stock amount (makeStockSetCargoAmountCmd) and simulation steps
-- (makeGamePerformSimulationStepsCmd), to cut the waiting on maps made for tests; stockList reads what they change.
-- core.stockSetRequest / stepsRequest have the arguments. Test saves only: they change the game as no player can.
--
-- The stock list is read as the base's debug panel reads it (debug_panel/make_entity_debug_panel.tl): the entity's
-- STOCK_LIST component, stock ids 0-based (its slider sends params.stockId - 1), the count from
-- simEntityAtStockSystem.getStockCount. An industry, town building or warehouse whose own entity has no STOCK_LIST
-- is followed to its stockList entity, as cargo_util.getStockListEntityFromOwner does. A vehicle has no stock list:
-- the panel sets its load with stock -1 and the cargo type's name, per cargo type.
--
-- Sent as rename and build send theirs: api.cmd.sendCommand with a callback, everything round it in pcall. A debug
-- function that is not there (nil) is not called: the answer says so. Whether a release build of the game takes
-- these commands or refuses them is not known: the answer carries the engine's success and what its callback
-- handed back.
--
-- Not checked in a game yet (written 2026-11-22): the answers say so.
local M = {}

local RESULT_SEC = 30 -- for a stock command's callback
local SETTLE_FRAMES = 2 -- after a callback, before the stock or the game time is read again

local NOTE = "debug command, not checked in a game yet: test saves only"
local STEPS_NOTE = "debug command, test saves only: the game runs it (checked 2026-11-22); this wait for all the "
	.. "steps is not checked in a game yet"

-- ctx: core, answer(id, payload, tag), fail(id, msg), appTime(), try(fn), say(msg, level)
function M.new(ctx)
	local core, answer, fail, appTime, try, say = ctx.core, ctx.answer, ctx.fail, ctx.appTime, ctx.try, ctx.say
	local jobs = {}
	-- the last steps that timed out: the engine runs the rest on all the same, so a steps sent meanwhile would count
	-- them as its own. { before, count, untilTime }
	local leftover = nil

	local function CT() return api.type.ComponentType end
	local function comp(e, kind)
		local k = try(function() return CT()[kind] end)
		if k == nil then return nil end
		return try(function() return api.engine.getComponent(e, k) end)
	end

	-- cargo type id -> resource name (the name makeStockSetCargoAmountCmd takes); getAll only, as industryStocks:
	-- get / getName are asked for nothing, since an id the engine does not list may assert
	local function cargoNames()
		local out = {}
		pcall(function()
			for id, name in pairs(api.res.cargoTypeRep.getAll(true)) do out[tonumber(id)] = tostring(name) end
		end)
		return out
	end
	-- passengers are sim persons with destinations: the base's debug panel never sets them, nor does this
	local function passengerId() return tonumber(try(function() return api.res.cargoTypeRep.getPassengerCargoTypeId() end)) end

	local function stockTypeNames()
		local SLT = try(function() return api.type.enum.StockListType end)
		local out = {}
		for _, k in ipairs({ "InputStock", "OutputStock", "StorageStock" }) do
			local v = tonumber(SLT and core.field(SLT, k))
			if v then out[v] = k end
		end
		return out
	end

	-- what holds the stocks of entity e: { kind = "stockList", entity = e, stockList = the stock list entity, via,
	-- stocks = { ... } } or { kind = "vehicle", entity = e, cargo = { ... } }; nil and why
	local function holderOf(e)
		-- only ids the engine has reach a component lookup (an unknown id may assert)
		local exists = try(function() return api.engine.entityExists(e) end)
		if exists ~= true then return nil, "no such entity: " .. e end
		local names = cargoNames()
		local slEntity, sl, via = e, comp(e, "STOCK_LIST"), nil
		if sl == nil then
			for _, k in ipairs({ "INDUSTRY", "TOWN_BUILDING", "WAREHOUSE" }) do
				local s = tonumber(core.field(comp(e, k), "stockList"))
				if s and s >= 0 and s ~= e and try(function() return api.engine.entityExists(s) end) == true then
					local c = comp(s, "STOCK_LIST")
					if c ~= nil then slEntity, sl, via = s, c, k break end
				end
			end
		end
		if sl ~= nil then
			local typeNames = stockTypeNames()
			local stocks = {}
			for i, st in ipairs(core.toList(core.field(sl, "stocks"))) do
				local id = i - 1
				local t = tonumber(core.field(st, "type"))
				local ct = tonumber(core.field(st, "cargoType"))
				local s = { stockId = id, type = t, typeName = t and typeNames[t] or nil, cargoType = ct,
					cargo = ct and names[ct] or nil, capacity = tonumber(core.field(st, "capacity")),
					count = tonumber(try(function()
						return api.engine.system.simEntityAtStockSystem.getStockCount(slEntity, id)
					end)) }
				-- per cargo type the stock takes (a mixed stock's cargoType is -1), as cargo_util.tl asks
				local per = {}
				for _, x in ipairs(core.toList(try(function() return api.engine.util.stock.getStockCargoTypes(slEntity, id) end))) do
					local n = tonumber(x)
					if n and names[n] then
						per[#per + 1] = { cargoType = n, cargo = names[n], count = tonumber(try(function()
							return api.engine.system.simEntityAtStockSystem.getStockCountForCargoType(slEntity, id, n)
						end)) }
					end
				end
				s.cargoTypes = core.array(per)
				stocks[#stocks + 1] = s
			end
			return { kind = "stockList", entity = e, stockList = slEntity, via = via, stocks = core.array(stocks) }
		end
		local tv = comp(e, "TRANSPORT_VEHICLE")
		if tv ~= nil then
			-- what it has room for: config.capacities, one per cargo type (id + 1), read only within its length
			local caps = try(function() return tv.config.capacities end)
			local n = caps ~= nil and core.size(caps) or 0
			local ids, pax = {}, passengerId()
			for id in pairs(names) do if id ~= pax then ids[#ids + 1] = id end end
			table.sort(ids)
			local cargo = {}
			for _, id in ipairs(ids) do
				local cap = id + 1 <= n and tonumber(core.at(caps, id + 1)) or nil
				if cap and cap > 0 then
					cargo[#cargo + 1] = { cargoType = id, cargo = names[id], capacity = cap, count = tonumber(try(function()
						return api.engine.system.simEntityAtVehicleSystem.getVehicleSimEntitiesCountForCargoType(e, id)
					end)) }
				end
			end
			return { kind = "vehicle", entity = e, stock = -1, cargo = core.array(cargo) }
		end
		return nil, "entity " .. e .. " holds no stock list (no STOCK_LIST, no industry, town building or warehouse "
			.. "with one) and is no vehicle"
	end

	-- the count of the stock (or the vehicle's cargo) a request is about, from a holder read
	local function countIn(h, r)
		if h == nil then return nil end
		if h.kind == "vehicle" then
			for _, c in ipairs(h.cargo) do if c.cargo == r.cargo then return c.count end end
			return nil
		end
		local s = h.stocks[r.stock + 1]
		if s == nil then return nil end
		if r.cargo then
			for _, c in ipairs(s.cargoTypes) do if c.cargo == r.cargo then return c.count end end
		end
		return s.count
	end

	-- whether the request fits the holder (an id or cargo the stock does not have may be the engine's assertion,
	-- which pcall does not stop): nil when it does, else why
	local function misfit(h, r)
		local pax = passengerId()
		if r.cargo and pax and cargoNames()[pax] == r.cargo then
			return "passengers cannot be set (sim persons with destinations; the base's debug panel leaves them out)"
		end
		if h.kind == "vehicle" then
			if r.stock ~= -1 then return "a vehicle's load is set with stock -1 (and cargo)" end
			for _, c in ipairs(h.cargo) do
				if c.cargo == r.cargo then
					if r.amount > c.capacity then
						return "amount " .. r.amount .. " is more than the vehicle's capacity for " .. r.cargo .. " (" .. c.capacity .. ")"
					end
					return nil
				end
			end
			local have = {}
			for _, c in ipairs(h.cargo) do have[#have + 1] = c.cargo end
			return "the vehicle has no room for " .. r.cargo .. " (it takes: " .. (#have > 0 and table.concat(have, ", ") or "nothing") .. ")"
		end
		local s = h.stocks[r.stock + 1]
		if r.stock < 0 or s == nil then
			return "no stock " .. r.stock .. " here: its stock list has " .. #h.stocks .. " (ids 0.." .. (#h.stocks - 1) .. ")"
		end
		if s.capacity and r.amount > s.capacity then
			return "amount " .. r.amount .. " is more than stock " .. r.stock .. "'s capacity (" .. s.capacity .. ")"
		end
		if r.cargo then
			local takes, others, hit = {}, 0, false
			for _, c in ipairs(s.cargoTypes) do
				if c.cargo == r.cargo then hit = true else others = others + (c.count or 0) end
				takes[#takes + 1] = c.cargo
			end
			-- a mixed stock holds its cargo types together: the others stay, so they count against the capacity
			if hit and s.capacity and r.amount + others > s.capacity then
				return "amount " .. r.amount .. " and the " .. others .. " of other cargo there are more than stock "
					.. r.stock .. "'s capacity (" .. s.capacity .. ")"
			end
			if hit then return nil end
			return "stock " .. r.stock .. " does not take " .. r.cargo .. " (it takes: "
				.. (#takes > 0 and table.concat(takes, ", ") or "none listed") .. ")"
		end
		return nil
	end

	-- the game speed's speedup (0: paused), nil when it cannot be read
	local function speedup()
		local sp = try(function() return api.engine.getComponent(api.engine.util.getWorld(), CT().GAME_SPEED) end)
		return tonumber(core.field(sp, "speedup"))
	end

	-- the game time, its update count (steps the simulation made) and the date
	local function clock()
		local gt = try(function() return api.engine.getComponent(api.engine.util.getWorld(), CT().GAME_TIME) end)
		local t = { gameTime = tonumber(core.field(gt, "gameTime")), updateCount = tonumber(core.field(gt, "updateCount")),
			tickCount = tonumber(core.field(gt, "tickCount")) }
		local d = t.gameTime and try(function() return api.engine.util.getCalendarDate(t.gameTime) end)
		if d then
			t.date = { year = tonumber(core.field(d, "year")), month = tonumber(core.field(d, "month")),
				day = tonumber(core.field(d, "day")) }
		end
		return t
	end

	-- what the engine's callback handed back, as plain values (for the debug commands: the command's data)
	local function plainResult(res)
		local ok, v = pcall(core.plain, res)
		return ok and v or nil
	end

	-- make (a function returning the command) and send it; job.called / job.success / job.result come from the
	-- callback. -> true, or false and why (nothing sent then)
	local function send(job, make)
		local okM, cmd = pcall(make)
		if not okM then return false, "making the command raised: " .. tostring(cmd) end
		if cmd == nil then return false, "making the command gave nothing (nil)" end
		local okS, err = pcall(function()
			api.cmd.sendCommand(cmd, function(res, success)
				job.called, job.success, job.result = true, success, plainResult(res)
				job.calledAt = appTime()
			end)
		end)
		if not okS then return false, "sendCommand raised: " .. tostring(err) end
		job.sentAt = appTime()
		return true
	end

	local function missingAnswer(id, path, out)
		out.ok, out.sent = false, false
		out.functionPresent = false
		out.error = path .. " is not there (nil) in this game: nothing sent"
		say("command " .. id .. ": " .. path .. " is missing", 1)
		answer(id, out, "error")
	end

	local T = {}

	-- args: entity. Read only.
	function T.stockList(c)
		local r, err = core.stockListArgs(c.args)
		if not r then return fail(c.id, err) end
		local h, herr = holderOf(r.entity)
		if not h then return fail(c.id, herr) end
		h.ok = true
		h.name = try(function() return api.engine.util.getEntityName(r.entity) end)
		if h.kind == "vehicle" then
			h.note = "a vehicle's load is set with stock set --stock -1 --cargo NAME"
		end
		answer(c.id, h)
	end

	-- args: core.stockSetRequest's
	function T.stockSet(c)
		local r, err = core.stockSetRequest(c.args)
		if not r then return fail(c.id, err) end
		local path = core.DEBUG_FUNCTIONS.stockSet
		local h, herr = holderOf(r.entity)
		if not h then return fail(c.id, herr) end
		local why = misfit(h, r)
		if why then return fail(c.id, why) end
		local target = h.kind == "vehicle" and h.entity or h.stockList
		local out = { ok = true, cmd = "stockSet", dryRun = r.dryRun or nil, entity = r.entity, stockList = target,
			holder = h.kind, via = h.via, stock = r.stock, amount = r.amount, cargo = r.cargo,
			before = countIn(h, r), functionPresent = core.debugFunction(path) ~= nil, note = NOTE }
		if r.dryRun then
			out.sent = false
			return answer(c.id, out)
		end
		if not out.functionPresent then return missingAnswer(c.id, path, out) end
		local job = { id = c.id, kind = "stockSet", r = r, out = out, target = target,
			deadline = appTime() + RESULT_SEC }
		local ok, serr = send(job, function()
			local make = api.cmd.debug.makeStockSetCargoAmountCmd
			-- the cargo only when given: the base's panel leaves it out for a stock list's stock
			if r.cargo then return make(target, r.stock, r.amount, r.cargo) end
			return make(target, r.stock, r.amount)
		end)
		if not ok then
			out.ok, out.sent, out.error = false, false, serr
			return answer(c.id, out, "error")
		end
		out.sent = true
		jobs[#jobs + 1] = job
	end

	-- args: core.stepsRequest's
	function T.steps(c)
		local r, err = core.stepsRequest(c.args)
		if not r then return fail(c.id, err) end
		local path = core.DEBUG_FUNCTIONS.steps
		local out = { ok = true, cmd = "steps", dryRun = r.dryRun or nil, count = r.count, before = clock(),
			functionPresent = core.debugFunction(path) ~= nil, speedup = speedup(), waitSec = core.stepsWaitSec(r.count),
			note = STEPS_NOTE }
		-- steps still running on (an earlier one waiting, or one that timed out) move the same counts: refused
		local busy = nil
		for _, j in ipairs(jobs) do
			if j.kind == "steps" then busy = "steps command " .. j.id .. " is still waiting for its steps" end
		end
		if not busy and leftover then
			if appTime() < leftover.untilTime and core.stepsDone(leftover.before, out.before, leftover.count) == false then
				busy = "the " .. leftover.count .. " steps of command " .. leftover.id .. " timed out and may still be "
					.. "running on"
			else
				leftover = nil
			end
		end
		if busy and not r.dryRun then
			out.ok, out.sent = false, false
			out.error = busy .. ": send steps again once they are done"
			return answer(c.id, out, "error")
		elseif busy then
			out.warning = busy
		end
		if out.speedup == nil then
			out.warning = (out.warning and out.warning .. "; " or "") .. "the game speed could not be read: if the "
				.. "game runs, the deltas are not the steps' alone"
		end
		-- a running game moves the update count and the game time on by itself: the marks the answer waits for
		-- would come early, so the count would not be the steps'
		if out.speedup and out.speedup > 0 then
			-- a dry run sends nothing: it says so in its warning instead
			if not r.allowRunning and not r.dryRun then
				out.ok, out.sent = false, false
				out.error = "the game is running (speed " .. out.speedup .. "): pause it first (speed 0), or allow "
					.. "it (allowRunning) and take the counts as the steps' and the game's own together"
				return answer(c.id, out, "error")
			end
			out.warning = (out.warning and out.warning .. "; " or "") .. (r.allowRunning
				and "sent while the game ran (speed " .. out.speedup .. "): the deltas are the steps' and the game's "
					.. "own together, and the wait may end before all the steps ran"
				or "the game is running (speed " .. out.speedup .. "): steps would be refused; pause it first (speed 0)")
		end
		if r.dryRun then
			out.sent = false
			return answer(c.id, out)
		end
		if not out.functionPresent then return missingAnswer(c.id, path, out) end
		-- the deadline covers the callback and the steps after it (they run on over many frames)
		local job = { id = c.id, kind = "steps", r = r, out = out, deadline = appTime() + out.waitSec }
		local ok, serr = send(job, function() return api.cmd.debug.makeGamePerformSimulationStepsCmd(r.count) end)
		if not ok then
			out.ok, out.sent, out.error = false, false, serr
			return answer(c.id, out, "error")
		end
		out.sent = true
		jobs[#jobs + 1] = job
	end

	-- a steps answer's after, deltas, the seconds waited and (with the steps done) steps a second
	local function stepsDeltas(job, now)
		local out = job.out
		out.after = now or clock()
		local b, a = out.before, out.after
		if a.gameTime and b.gameTime then out.gameTimeDelta = a.gameTime - b.gameTime end
		if a.updateCount and b.updateCount then out.updateCountDelta = a.updateCount - b.updateCount end
		if out.gameTimeDelta then out.gameTimePerStep = out.gameTimeDelta / job.r.count end
		out.waitedSec = job.sentAt and appTime() - job.sentAt or nil
		if out.timedOut == nil then out.timedOut = false end
		local ran = out.updateCountDelta or (out.gameTimeDelta and out.gameTimeDelta / core.STEP_GAME_TIME)
		if ran and out.waitedSec and out.waitedSec > 0 then out.stepsPerSec = ran / out.waitedSec end
	end

	local function finish(job, now)
		local out = job.out
		out.success, out.engineResult = job.success, job.result
		out.callbackSec = job.calledAt and job.sentAt and job.calledAt - job.sentAt or nil
		if job.kind == "stockSet" then
			local h = holderOf(job.r.entity)
			out.after = countIn(h, job.r)
			if out.after ~= nil and out.after ~= job.r.amount and job.success == true then
				out.warning = "the stock reads back " .. out.after .. ", not " .. job.r.amount
			end
		else
			stepsDeltas(job, now)
			if out.timedOut and job.success == true then
				leftover = { id = job.id, before = out.before, count = job.r.count, untilTime = appTime() + out.waitSec }
				out.ok = false
				out.error = "the steps had not all run in " .. out.waitSec .. " s: update count +"
					.. tostring(out.updateCountDelta) .. ", game time +" .. tostring(out.gameTimeDelta) .. " of "
					.. job.r.count .. " steps (" .. job.r.count * core.STEP_GAME_TIME .. ")"
				say("steps (command " .. job.id .. "): timed out", 1)
				return answer(job.id, out, "error")
			end
		end
		if job.success ~= true then
			out.ok = false
			out.error = "the engine refused the command (its callback said success = " .. tostring(job.success) .. ")"
			say(job.kind .. " (command " .. job.id .. "): refused by the engine", 1)
			return answer(job.id, out, "error")
		end
		answer(job.id, out)
	end

	-- a steps job after its callback: answered once its steps have all run (core.stepsDone), or at the deadline
	-- with what ran by then. -> true when answered
	local function stepsProgress(job)
		if job.success ~= true then finish(job) return true end
		local now = clock()
		local done, by = core.stepsDone(job.out.before, now, job.r.count)
		if done == nil then
			-- neither mark readable: nothing to wait for, so the callback is the answer
			job.out.warning = (job.out.warning and job.out.warning .. "; " or "")
				.. "neither the update count nor the game time could be read: whether the steps all ran is not known"
			finish(job, now)
			return true
		end
		if done then
			job.out.doneBy = by
			finish(job, now)
			return true
		end
		if appTime() > job.deadline then
			job.out.timedOut = true
			finish(job, now)
			return true
		end
		return false
	end

	function T.step()
		if #jobs == 0 then return end
		local keep = {}
		for _, job in ipairs(jobs) do
			if job.called and job.kind == "steps" then
				local ok, res = pcall(stepsProgress, job)
				if not ok then fail(job.id, res)
				elseif not res then keep[#keep + 1] = job end
			elseif job.called then
				job.settle = (job.settle or SETTLE_FRAMES) - 1
				if job.settle <= 0 then
					local ok, err = pcall(finish, job)
					if not ok then fail(job.id, err) end
				else
					keep[#keep + 1] = job
				end
			elseif appTime() > job.deadline then
				local out = job.out
				out.ok = false
				out.error = "no callback from the engine in " .. (job.kind == "steps" and out.waitSec or RESULT_SEC)
					.. " s (sent; whether it ran is not known)"
				if job.kind == "steps" then
					out.timedOut = true
					stepsDeltas(job)
					-- it may have been sent and run all the same
					leftover = { id = job.id, before = out.before, count = job.r.count, untilTime = appTime() + out.waitSec }
				else out.after = countIn(holderOf(job.r.entity), job.r) end
				answer(job.id, out, "error")
			else
				keep[#keep + 1] = job
			end
		end
		jobs = keep
	end

	T.handlers = { stockList = T.stockList, stockSet = T.stockSet, steps = T.steps }
	return T
end

return M
