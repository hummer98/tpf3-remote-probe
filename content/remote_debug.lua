-- debug commands: api.cmd.debug's stock amount (makeStockSetCargoAmountCmd) and simulation steps
-- (makeGamePerformSimulationStepsCmd), to cut the waiting on maps made for tests; stockList reads what they change.
-- core.stockSetRequest / stepsRequest have the arguments. Test saves only: they change the game as no player can.
--
-- The stock list is read as the base's debug panel reads it (debug_panel/make_entity_debug_panel.tl): the entity's
-- STOCK_LIST component, stock ids 0-based (its slider sends params.stockId - 1), the count from
-- simEntityAtStockSystem.getStockCount. An industry, town building or warehouse whose own entity has no STOCK_LIST
-- is followed to its stockList entity, as cargo_util.getStockListEntityFromOwner does; a construction (a
-- warehouse's, as build gives it) to the one such owner among its subconstructions (core.stockOwnersOf), else to a
-- warehouse whose WAREHOUSE.construction is it (core.warehousesOf). A vehicle
-- has no stock list: the panel sets its load with stock -1 and the cargo type's name, per cargo type.
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
	-- owner and construction (when e is a construction), stocks = { ... } } or { kind = "vehicle", entity = e, cargo = { ... } }; nil and why
	local function holderOf(e)
		-- only ids the engine has reach a component lookup (an unknown id may assert)
		local exists = try(function() return api.engine.entityExists(e) end)
		if exists ~= true then return nil, "no such entity: " .. e end
		local names = cargoNames()
		local slEntity, sl, via = e, comp(e, "STOCK_LIST"), nil
		local owner, construction = nil, nil
		-- an owner's stockList may be the owner itself (a game's warehouse 46841 has stockList 46841, 2026-11-23):
		-- taken, as cargo_util.getStockListEntityFromOwner gives it
		local function follow(o, k)
			local s = tonumber(core.field(comp(o, k), "stockList"))
			if s and s >= 0 and try(function() return api.engine.entityExists(s) end) == true then
				local c = comp(s, "STOCK_LIST")
				if c ~= nil then return s, c end
			end
			return nil
		end
		if sl == nil then
			for _, k in ipairs({ "INDUSTRY", "TOWN_BUILDING", "WAREHOUSE" }) do
				local s, c = follow(e, k)
				if s then slEntity, sl, via = s, c, k break end
			end
		end
		-- a construction (the id build gives, e.g. a warehouse's): the stock list of the owner under it, as the
		-- base opens a warehouse's or an industry's window from its construction (core.stockOwnersOf). More
		-- than one (a construction with two industries): refused, naming them, so that nothing is guessed.
		if sl == nil then
			local con = comp(e, "CONSTRUCTION")
			if con ~= nil then
				local function read(v, k)
					if v == e or try(function() return api.engine.entityExists(v) end) ~= true then return nil end
					return comp(v, k)
				end
				local owners = core.stockOwnersOf(con, read)
				-- none under it: a warehouse that names it as its construction (its subconstructions may not list it)
				if #owners == 0 then
					local ct = try(function() return CT().WAREHOUSE end)
					local ids = ct ~= nil and try(function() return api.engine.getEntitiesWithComponent(ct) end) or nil
					owners = core.warehousesOf(e, ids, read)
				end
				if #owners > 1 then
					local listed = {}
					for _, o in ipairs(owners) do
						listed[#listed + 1] = string.format("%d (%s, stock list %d)", o.entity, o.kind, o.stockList)
					end
					return nil, "construction " .. e .. " has " .. #owners .. " stock lists under it: give one of "
						.. table.concat(listed, ", ")
				end
				construction = e
				if #owners == 1 then
					local s, c = follow(owners[1].entity, owners[1].kind)
					if s then slEntity, sl, via, owner = s, c, "CONSTRUCTION>" .. owners[1].kind, owners[1].entity end
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
			return { kind = "stockList", entity = e, stockList = slEntity, via = via, owner = owner,
				construction = construction, stocks = core.array(stocks) }
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
		if construction then
			return nil, "construction " .. e .. " has no stock list under it (no warehouse, industry or town building "
				.. "among its subconstructions with one, nor a warehouse that names it; a warehouse with no modules "
				.. "has no stocks)"
		end
		return nil, "entity " .. e .. " holds no stock list (no STOCK_LIST, no industry, town building, warehouse "
			.. "or construction with one) and is no vehicle"
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

	-- every count a stock list holder reads: "stock:cargo" (per cargo type) and "stock" (the stock's whole count), so
	-- that what the engine changed can be told from what was asked; nil for a vehicle
	local function snapshot(h)
		if h == nil or h.kind ~= "stockList" then return nil end
		local m = {}
		for _, s in ipairs(h.stocks) do
			m[tostring(s.stockId)] = s.count
			for _, c in ipairs(s.cargoTypes or {}) do m[s.stockId .. ":" .. c.cargo] = c.count end
		end
		return m
	end

	-- the counts that moved between two snapshots and are not the request's: another stock, or (with a cargo) another
	-- cargo in the same stock. -> { { stock, cargo, before, after } } sorted, empty when only the request's moved
	local function strayChanges(before, after, r)
		local out = {}
		if before == nil or after == nil then return out end
		local keys = {}
		for k in pairs(before) do keys[k] = true end
		for k in pairs(after) do keys[k] = true end
		for k in pairs(keys) do
			local b, a = before[k] or 0, after[k] or 0
			if a ~= b then
				local st, cargo = k:match("^(%-?%d+):(.+)$")
				st = tonumber(st or k)
				local mine = st == r.stock and (cargo == nil or r.cargo == nil or cargo == r.cargo)
				if not mine then out[#out + 1] = { stock = st, cargo = cargo, before = b, after = a } end
			end
		end
		table.sort(out, function(x, y)
			if x.stock ~= y.stock then return x.stock < y.stock end
			return (x.cargo or "") < (y.cargo or "")
		end)
		return out
	end

	-- the stock id the command is sent with: a mixed stock's (cargoType -1) cargo goes with stock -1 and its name,
	-- as the base's debug panel sets a vehicle's load per cargo type (make_entity_debug_panel.tl: make(e, -1, v,
	-- cargoName)); with its own stock id the engine did not take the name (grain asked, bricks set, 2026-11-23).
	-- A stock of one cargo type, and a mixed stock without a cargo, go with their stock id, as the panel's slider
	-- sends them (make(entity, stockId - 1, amount)). -> the id, and true when it is the cargo's form
	local function sendStockOf(h, r)
		if h.kind ~= "stockList" or r.cargo == nil then return r.stock, false end
		local s = h.stocks[r.stock + 1]
		if s and (s.cargoType == nil or s.cargoType < 0) then return -1, true end
		return r.stock, false
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
		if #h.stocks == 0 then
			return "its stock list has no stocks (a warehouse gets one from its modules: none, or none with capacity)"
		end
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
		local sendStock, byCargo = sendStockOf(h, r)
		local out = { ok = true, cmd = "stockSet", dryRun = r.dryRun or nil, entity = r.entity, stockList = target,
			holder = h.kind, via = h.via, owner = h.owner, construction = h.construction, stock = r.stock, amount = r.amount, cargo = r.cargo,
			sentStock = sendStock, form = byCargo and "mixed stock: stock -1 with the cargo (not checked in a game yet)" or nil,
			before = countIn(h, r), functionPresent = core.debugFunction(path) ~= nil, note = NOTE }
		if byCargo then
			-- stock -1 names no stock: another stock that takes the cargo too may be the one the engine fills
			local also = {}
			for _, o in ipairs(h.stocks) do
				if o.stockId ~= r.stock then
					for _, c in ipairs(o.cargoTypes or {}) do
						if c.cargo == r.cargo then also[#also + 1] = tostring(o.stockId) end
					end
				end
			end
			if #also > 0 then
				out.warning = "stock " .. table.concat(also, ", ") .. " takes " .. r.cargo .. " too: the engine picks "
					.. "the stock (the answer says which changed)"
			end
		end
		if r.dryRun then
			out.sent = false
			return answer(c.id, out)
		end
		if not out.functionPresent then return missingAnswer(c.id, path, out) end
		local job = { id = c.id, kind = "stockSet", r = r, out = out, target = target, snap = snapshot(h),
			deadline = appTime() + RESULT_SEC }
		local ok, serr = send(job, function()
			local make = api.cmd.debug.makeStockSetCargoAmountCmd
			-- the cargo only when given: the base's panel leaves it out for a stock list's stock
			if r.cargo then return make(target, sendStock, r.amount, r.cargo) end
			return make(target, sendStock, r.amount)
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
				out.warning = (out.warning and out.warning .. "; " or "") .. "the stock reads back " .. out.after
					.. ", not " .. job.r.amount
			end
			-- what else moved (another cargo or stock): the engine put it elsewhere, so ok is not claimed
			local stray = strayChanges(job.snap, snapshot(h), job.r)
			if #stray > 0 then
				out.elsewhere = core.array(stray)
				if job.success == true then
					local parts = {}
					for _, x in ipairs(stray) do
						parts[#parts + 1] = string.format("stock %d%s %s -> %s", x.stock, x.cargo and (" " .. x.cargo) or "",
							tostring(x.before), tostring(x.after))
					end
					out.ok = false
					out.error = "the engine changed what was not asked: " .. table.concat(parts, ", ")
						.. " (asked: stock " .. job.r.stock .. (job.r.cargo and (" " .. job.r.cargo) or "") .. ")"
					say("stockSet (command " .. job.id .. "): changed what was not asked", 1)
					return answer(job.id, out, "error")
				end
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
