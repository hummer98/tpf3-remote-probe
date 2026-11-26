-- running costs and finance for the remote probe: a vehicle model's running-cost fields read (runningCosts) and
-- written at run time (runningCostsSet), and the finance table and the vehicles' running costs read (finance). Made
-- to measure whether the engine bills a running cost rewritten during a game (2026-11-24): a price mod writes
-- the purchase price into the models but bills the running costs' difference by hand.
--
-- runningCostsSet, test saves only or in coop (tf3ctl names the loaded save in _testSave, and the coop owner in
-- _coop; core.runningCostsArgs refuses without either), writes the fields of metadata.maintenance
-- (core.RUNCOST_WRITABLE) in place:
--   where "script" (default): in the game script (remote_gs.script.lua), through a script event, as price_probe
--     wrote metadata.cost.price; needs the mod setting gameScript on. The game script answers in its state, which
--     guiUpdate hands this script; the GUI reads the model again after it.
--   where "gui": here, in the GUI's Lua state; then, with gameScript on, the game script reads the model back.
-- The answer has every view: before (gui, and the script's own before), the writes (the engine's error word for
-- word, the value read back), after (script, gui), and the company's vehicles of that model with the running cost
-- per year the engine gives for each (getRunningCost, as the vehicle window shows it) before and after.
-- A write lasts for the session: each load reads the models again (the price came back nominal after a load,
-- 2026-11-16).
local M = {}

local CARRIERS = { "ROAD", "RAIL", "TRAM", "WATER", "AIR", "OTHER" }
local TYPE_NAMES = { "LOAN", "INTEREST", "CONSTRUCTION", "ACQUISITION", "MAINTENANCE", "INCOME", "OTHER", "SUBSIDY" }
local MAINT_NAMES = { "VEHICLE", "INFRASTRUCTURE", "OTHER", "VEHICLE_MAINTENANCE" }
local CONSTR_NAMES = { "STREET", "TRACK", "SIGNAL", "STATION", "DEPOT", "BULLDOZER", "WAREHOUSE", "OTHER" }

local WRITE_NOTE = "lasts until the game loads again (each load reads the models anew); whether the engine bills it "
	.. "shows in finance's MAINTENANCE / VEHICLE row over the next months"
local NO_GS_NOTE = "the game script's view is not read: the mod setting gameScript is off (launch / load with "
	.. "--param hummer_remote_probe:gameScript=2)"

-- ctx: core, answer(id, payload, tag), fail(id, msg), appTime(), try(fn), say(msg, level), findModel(query) -> id
-- (raises with why), gsState() -> the game script's state handed to guiUpdate (nil before the first)
function M.new(ctx)
	local core, answer, fail, appTime, try, say = ctx.core, ctx.answer, ctx.fail, ctx.appTime, ctx.try, ctx.say
	local job = nil
	local T = {}

	local function gameScriptOn()
		local all = try(function() return api.engine.config.getModParams() end)
		return core.options(all and core.field(all, core.MOD_ID) or nil).gameScript == true
	end

	local function gameTime()
		local gt = try(function()
			return api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME) end)
		return gt and tonumber(core.field(gt, "gameTime")) or nil
	end

	local function dateOf(t)
		local d = t and try(function() return api.engine.util.getCalendarDate(t) end)
		if not d then return nil end
		return { year = tonumber(core.field(d, "year")), month = tonumber(core.field(d, "month")),
			day = tonumber(core.field(d, "day")) }
	end

	local function ownVehicles()
		local player = try(function() return api.engine.util.getPlayer() end)
		local ids = try(function()
			return api.engine.getEntitiesWithComponent(api.type.ComponentType.TRANSPORT_VEHICLE, { requireOwnedByPlayer = player })
		end)
		local out = {}
		for _, e in ipairs(core.toList(ids)) do out[#out + 1] = tonumber(e) end
		table.sort(out)
		return out
	end

	-- the company's vehicles with a part of this model: entity, parts of it, the running cost per year the engine
	-- gives (getRunningCost: the whole vehicle's), at most limit of them; total counts them all
	local function vehiclesOf(id, limit)
		local out, total = {}, 0
		for _, e in ipairs(ownVehicles()) do
			local tv = try(function() return api.engine.getComponent(e, api.type.ComponentType.TRANSPORT_VEHICLE) end)
			local n = 0
			for _, p in ipairs(core.toList(tv and try(function() return tv.transportVehicleConfig.vehicles end))) do
				if tonumber(try(function() return p.part.modelId end)) == id then n = n + 1 end
			end
			if n > 0 then
				total = total + 1
				if #out < limit then
					out[#out + 1] = { entity = e, parts = n,
						runningCostPerYear = tonumber(try(function() return api.engine.util.vehicle.getRunningCost(e) end)) }
				end
			end
		end
		return core.array(out), total
	end

	local function modelOf(query)
		local id = ctx.findModel(query)
		return { id = id, fileName = try(function() return api.res.modelRep.getName(id) end) }
	end

	function T.read(c)
		local a, err = core.runningCostsArgs(c.args, false)
		if not a then return fail(c.id, err) end
		local m = modelOf(a.model)
		local fields, ferr = core.readRunningCostFields(api.res.modelRep, m.id)
		if not fields then return fail(c.id, ferr) end
		local vs, total = vehiclesOf(m.id, a.limit)
		local writable = {}
		for k in pairs(core.RUNCOST_WRITABLE) do writable[#writable + 1] = "maintenance." .. k end
		table.sort(writable)
		answer(c.id, { ok = true, model = m, view = "gui", fields = fields, vehicles = vs, vehicleCount = total,
			writable = core.array(writable), gameScript = gameScriptOn(), gameTime = gameTime() })
	end

	local function send(name, request)
		local okM, cmd = pcall(function()
			return api.cmd.makeScriptingSendEventCmd("", core.RUNCOST_EVENT_ID, name, request)
		end)
		if not okM or cmd == nil then return false, "makeScriptingSendEventCmd: " .. tostring(cmd) end
		local okS, err = pcall(function()
			api.cmd.sendCommand(cmd, function(_, success)
				if job and job.request == request then job.called, job.success = true, success end
			end)
		end)
		if not okS then return false, "sendCommand: " .. tostring(err) end
		return true
	end

	local function finish(j, ok, err)
		job = nil
		local out = j.out
		out.after = out.after or {}
		out.after.gui = core.readRunningCostFields(api.res.modelRep, j.model)
		out.vehiclesAfter = vehiclesOf(j.model, j.limit)
		out.waitedSec = appTime() - j.startedAt
		if not ok then
			out.ok, out.error = false, err
			say("runningCostsSet (command " .. j.id .. "): " .. tostring(err), 1)
			return answer(j.id, out, "error")
		end
		say("runningCostsSet (command " .. j.id .. "): written in the " .. out.wroteIn .. " for model " .. j.model, 1)
		answer(j.id, out)
	end

	function T.write(c)
		local a, err = core.runningCostsArgs(c.args, true)
		if not a then return fail(c.id, err) end
		if job then
			return fail(c.id, "runningCostsSet (command " .. job.id .. ") is still waiting for the game script: send "
				.. "again once it has answered")
		end
		local gs = gameScriptOn()
		if a.where == "script" and not gs then
			return fail(c.id, "where script needs the game script, which listens only with the mod setting gameScript "
				.. "on: launch / load the test save with --param hummer_remote_probe:gameScript=2 (or use --where gui): "
				.. "nothing written")
		end
		local m = modelOf(a.model)
		local rep = api.res.modelRep
		local before, berr = core.readRunningCostFields(rep, m.id)
		if not before then return fail(c.id, berr) end
		local vs = vehiclesOf(m.id, a.limit)
		local out = { ok = true, model = m, where = a.where, wroteIn = a.where == "script" and "game script" or "gui",
			testSave = a.testSave, coop = a.coop, gameTime = gameTime(), before = { gui = before }, vehiclesBefore = vs,
			note = WRITE_NOTE }
		local j = { id = c.id, model = m.id, limit = a.limit, out = out, startedAt = appTime(),
			deadline = appTime() + core.RUNCOST_WAIT_SEC }
		if a.where == "gui" then
			local targets, terr = core.runningCostTargets(before, a.ops)
			if not targets then return fail(c.id, terr) end
			out.writes = core.writeRunningCosts(rep, m.id, targets)
			for _, w in ipairs(out.writes) do
				if not w.stuck then out.ok, out.error = false, "not every field took the value (see writes)" end
			end
			out.after = { gui = core.readRunningCostFields(rep, m.id) }
			if not gs then
				out.after.scriptNote = NO_GS_NOTE
				job = j
				return finish(j, out.ok, out.error)
			end
			-- the game script reads the model back: does it see what the GUI wrote?
			j.event = core.RUNCOST_EVENT_READ
		else
			j.event = core.RUNCOST_EVENT_WRITE
		end
		j.request = core.runningCostRequest(c.id, m.id, a)
		job = j
		local okS, serr = send(j.event, j.request)
		if not okS then return finish(j, false, serr .. (a.where == "gui" and " (the GUI's write stays)" or
			": nothing written")) end
	end

	function T.step()
		local j = job
		if j == nil then return end
		local ok, err = pcall(function()
			if j.called and j.success == false then
				return finish(j, false, "the engine refused the script event (its callback said no success)")
			end
			local st = ctx.gsState()
			local s = st and try(function() return st:get() end)
			local r = type(s) == "table" and s.runningCosts or nil
			if type(r) == "table" and tonumber(r.req) == j.id then
				local out = j.out
				out.after = out.after or {}
				out.script = { event = r.event, before = r.before, writes = r.writes, after = r.after, error = r.error }
				if j.event == core.RUNCOST_EVENT_WRITE then
					out.before.script, out.writes = r.before, r.writes
					out.after.script = r.after
					return finish(j, r.ok == true, r.ok ~= true and ("the game script: " .. tostring(r.error)) or nil)
				end
				out.after.script = r.before -- (its read: what it sees after the GUI's write)
				if r.ok ~= true then return finish(j, false, "the game script's read: " .. tostring(r.error)) end
				return finish(j, out.ok, out.error)
			end
			if appTime() > j.deadline then
				finish(j, false, "no answer from the game script after " .. core.RUNCOST_WAIT_SEC .. " s (is the "
					.. "game script subscribed? it subscribes a few seconds after a load with gameScript on; does the "
					.. "engine run script events while paused? not known). "
					.. (j.event == core.RUNCOST_EVENT_WRITE and "Whether it wrote shows in the log (log --grep "
						.. "\"game script\") and in runningCosts" or "The GUI's write stays"))
			end
		end)
		if not ok then
			if job == j then job = nil end
			fail(j.id, err)
		end
	end

	-- finance -----------------------------------------------------------------------------------------------------

	local function vecOf(v)
		local out = {}
		local okN, n = pcall(function() return #v end)
		if not okN or type(n) ~= "number" then return out end
		for i = 1, n do
			local okI, x = pcall(function() return v[i] end)
			out[i] = okI and x or nil
		end
		return out
	end

	local function numbers(v)
		local out = {}
		for i, x in pairs(vecOf(v)) do out[i] = tonumber(x) end
		return core.array(out)
	end

	-- the finance table as the base's finance window reads it (finances_table.tl computeFinanceTable; the rows of
	-- a carrier walked first, unfolded after, as AoM's ledger reads it). Per carrier its rows { type, maintenance,
	-- construction, values (one per column, as the header) }; sameAs: a carrier whose rows are an earlier one's to
	-- the unit (TRAM gave ROAD's rows in a game, 2026-11-16). vehicleRunning / vehicleMaintenance: the
	-- MAINTENANCE / VEHICLE and MAINTENANCE / VEHICLE_MAINTENANCE rows per column
	local function financeTable(columns)
		local J = try(function() return api.type.JournalEntry end)
		if not J then return nil, "api.type.JournalEntry is missing" end
		local okC, config = pcall(function()
			local c = api.type.ChartConfig.new()
			c.count = columns
			return c
		end)
		if not okC then return nil, "ChartConfig: " .. tostring(config) end
		local okF, fd = pcall(function()
			return api.engine.util.finance.computeFinanceTable(api.engine.util.getPlayer(), config)
		end)
		if not okF or fd == nil then return nil, "computeFinanceTable: " .. tostring(fd) end
		local header = {}
		for i, h in pairs(vecOf(try(function() return fd.header end))) do header[i] = tostring(h) end
		local out = { header = core.array(header), carriers = {} }
		local seen = {}
		local function enumName(rec, names, v)
			local e = try(function() return J[rec] end)
			return e and core.enumName(e, names, v) or (v ~= nil and tostring(v) or nil)
		end
		for _, carrier in ipairs(CARRIERS) do
			local cj = try(function() return J.Carrier[carrier] end)
			if cj ~= nil then
				local raw = {}
				local okW, werr = pcall(function()
					fd:foreach_transport(function(key, values) raw[#raw + 1] = { key = key, values = numbers(values) } end, cj)
				end)
				local entry = {}
				if not okW then
					entry.error = "foreach_transport: " .. tostring(werr)
				else
					local rows, running, maint = {}, {}, {}
					for _, r in ipairs(raw) do
						local u = try(function() return fd:unfoldKey(r.key) end)
						local t, mt, ct = u and core.field(u, 1), u and core.field(u, 2), u and core.field(u, 3)
						local row = { type = enumName("Type", TYPE_NAMES, t), values = r.values }
						if row.type == "MAINTENANCE" then row.maintenance = enumName("Maintenance", MAINT_NAMES, mt) end
						if row.type == "CONSTRUCTION" or row.maintenance == "INFRASTRUCTURE" then
							row.construction = enumName("Construction", CONSTR_NAMES, ct)
						end
						local sum = row.maintenance == "VEHICLE" and running
							or (row.maintenance == "VEHICLE_MAINTENANCE" and maint) or nil
						if sum then
							for i, v in pairs(r.values) do sum[i] = (sum[i] or 0) + (v or 0) end
						end
						rows[#rows + 1] = row
					end
					entry.rows = core.array(rows)
					entry.vehicleRunning, entry.vehicleMaintenance = core.array(running), core.array(maint)
					local sig = core.json(rows)
					if #rows > 0 and seen[sig] then entry.sameAs = seen[sig] elseif #rows > 0 then seen[sig] = carrier end
				end
				out.carriers[carrier] = entry
			end
		end
		out.total = numbers(try(function() return fd.total end))
		out.balance = numbers(try(function() return fd.balance end))
		return out
	end

	-- calculateBalance over [from, to] with maintenance and income entries only: all of them, the running costs
	-- (Maintenance.VEHICLE) and the vehicle maintenance (VEHICLE_MAINTENANCE); each nil + its error when it fails
	local function balances(list, from, to)
		local J = try(function() return api.type.JournalEntry end)
		local out = {}
		local function one(key, mt)
			local ok, v = pcall(function()
				if mt == nil then return api.engine.util.finance.calculateBalance(list, from, to, true) end
				return api.engine.util.finance.calculateBalance(list, from, to, true, mt)
			end)
			if ok then out[key] = tonumber(v) else out[key .. "Error"] = tostring(v) end
		end
		one("all", nil)
		local function mtOf(name) return J and try(function() return J.Maintenance[name] end) end
		local mv, mm = mtOf("VEHICLE"), mtOf("VEHICLE_MAINTENANCE")
		if mv ~= nil then one("running", mv) else out.runningError = "JournalEntry.Maintenance.VEHICLE is missing" end
		if mm ~= nil then one("maintenance", mm) else out.maintenanceError = "JournalEntry.Maintenance.VEHICLE_MAINTENANCE is missing" end
		return out
	end

	function T.finance(c)
		local a, err = core.financeArgs(c.args)
		if not a then return fail(c.id, err) end
		local now = gameTime()
		if not now then return fail(c.id, "the game time cannot be read") end
		local out = { ok = true, gameTime = now, date = dateOf(now), columns = a.columns }
		local t, terr = financeTable(a.columns)
		out.table, out.tableError = t, terr
		local year = tonumber(try(function() return api.util.getDefaultYearDuration() end))
		local since = a.since
		if since == nil then
			since = math.max(0, math.floor(now - (year or 0) / 12))
			out.sinceNote = "since not given: one twelfth of a year back (getDefaultYearDuration / 12)"
		end
		out.since, out.sinceDate = since, dateOf(since)
		local own = ownVehicles()
		out.fleet = balances(own, since, now)
		out.fleet.vehicles = #own
		if a.vehicles then
			local mine = {}
			for _, e in ipairs(own) do mine[e] = true end
			local list, missing = {}, {}
			for _, e in ipairs(a.vehicles) do
				if mine[e] then
					local b = balances({ e }, since, now)
					b.entity = e
					b.runningCostPerYear = tonumber(try(function() return api.engine.util.vehicle.getRunningCost(e) end))
					list[#list + 1] = b
				else
					missing[#missing + 1] = e
				end
			end
			out.vehicles = core.array(list)
			if #missing > 0 then out.missing = core.array(missing) end
		end
		out.note = "amounts as the engine books them (costs negative); the table's columns are the header's (years); "
			.. "fleet and vehicles: calculateBalance over [since, gameTime], maintenance and income entries only"
		answer(c.id, out)
	end

	function T.reset() job = nil end

	T.handlers = { runningCosts = T.read, runningCostsSet = T.write, finance = T.finance }
	return T
end

return M
