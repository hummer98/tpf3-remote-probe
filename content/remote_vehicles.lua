-- Buying, cloning, replacing and selling vehicles for the remote probe (buy, duplicate, replace, sell), and the
-- depot and vehicle lists to aim them (depots, vehicles). Made to test mods that change vehicle prices: each
-- answer has the balance before and after, the models' cost as the store reads it (metadata.cost), read before
-- sending and again when answering (a price mod may rewrite it), and every part's purchaseTime and the vehicle's
-- depreciated value as the engine holds them afterwards.
--
-- Two ways, chosen by args.via, and the answer says which ran:
--   gui (default): the base's vehicle_react_util.HandleVehicleChanges, which the vehicle store and the clone
--     button call. It stamps the current game time as purchaseTime on parts that have none, turns autoload on,
--     and only then sends the engine command. It cannot load in this guiUpdate state (react.RegisterRecipe
--     fails here, 2026-11-16 12:24 JST), so the request goes to the speed control's react recipe through the
--     GUI save data (publishUi "vehicles"), which runs it in its join (vehicle_configs.performGui) and reports
--     back under its own key (REPORT_KEY): what it sent, the base's onBuy/onFail, or why it could not send.
--     The result itself is read from the engine here (new vehicles, changed parts, a vehicle gone), so a report
--     that does not come through costs the details, not the answer. A mod that replaces the module's file
--     reaches it; one that patches the store's copy at run time may not.
--   cmd: the engine command alone (makeVehicleBuyCmd and friends), parts as built, purchaseTime 0 included,
--     to see whether the engine fills it in by itself. autoLoadConfig is set as the base does (vc.fitAutoLoad):
--     left empty, it crashed the game.
-- A failure to load the base module is an error, never a silent switch to cmd: the two differ in what is tested.
--
-- Commands answer once their result is in: the engine's callback (cmd; gui buy and clone through onBuy/onFail),
-- or, where HandleVehicleChanges takes no callback (gui replace and sell, and the base's own send to a line), once
-- the vehicle shows the change. The balance after is read a few frames later, so a cost booked after the callback
-- is in it. A result that never comes ends in an error answer after ASYNC_TIMEOUT_SEC, with what had arrived.
-- Every command gets one answer, except when a load ends this script first: its jobs go with it.
local M = {}

local ASYNC_TIMEOUT_SEC = 60
local SETTLE_FRAMES = 3
local CARRIERS = { "ROAD", "RAIL", "TRAM", "AIR", "WATER", "OTHER" }
-- a depot's kind from the transport modes it takes: its carrier field read OTHER for all 49 depots of a save
-- (2026-11-16 12:24 JST), and the base never reads it (it goes by transportModes, entity_window_hud.tl)
local MODE_KINDS = { { "BUS", "road" }, { "TRUCK", "road" }, { "CAR", "road" }, { "TRAM", "tram" },
	{ "ELECTRIC_TRAM", "tram" }, { "TRAIN", "rail" }, { "ELECTRIC_TRAIN", "rail" }, { "SHIP", "water" },
	{ "SMALL_SHIP", "water" }, { "AIRCRAFT", "air" }, { "SMALL_AIRCRAFT", "air" }, { "HELICOPTER", "air" } }
local MOVED_WARNING = "game time moved during the command: the balance difference may include fares and running " ..
	"costs; pause the game for exact prices"
local CMD_NOTE = "via cmd: purchaseTime sent as 0 (the store's way stamps it); autoLoadConfig set as the store does, since the engine dies on a size mismatch"
local GUI_NOTE = "via gui: run by the speed control (the speed buttons' react recipe), so it needs a game on " ..
	"screen with the speed buttons; the result is read back from the engine"
local NO_REPORT_NOTE = "via gui: no report from the speed control came through: sentParts unknown (the vehicles " ..
	"show what the engine holds)"
local NEGATIVE_PRICE_NOTE = "a model has a negative cost.price: storePriceTotal is price x count as the store sums " ..
	"it (vehicle_store_window.tl); the engine's charge is in spent"

-- ctx: core, answer(id, payload, tag), fail(id, msg), appTime(), try(fn), say(msg, level)
function M.new(ctx)
	local core, answer, fail, appTime, try, say = ctx.core, ctx.answer, ctx.fail, ctx.appTime, ctx.try, ctx.say
	local req = ctx.require or ug_require or require
	local MOD = ctx.mod or core.MOD_ID
	local vc = req(MOD .. "::/vehicle_configs.lua")
	local REPORT_KEY = MOD .. ".vehicles"
	local publishUi = ctx.publishUi or function() end
	local V = { jobs = {}, frames = 0, requests = {}, claimed = {} }
	local handlers = {}

	local function CT() return api.type.ComponentType end
	local function player() return api.engine.util.getPlayer() end
	local function balance()
		return tonumber(try(function() return api.engine.util.finance.getPlayersBalance(player()) end))
	end
	local function gameTime()
		local gt = try(function() return api.engine.getComponent(api.engine.util.getWorld(), CT().GAME_TIME) end)
		return gt and tonumber(try(function() return gt.gameTime end)) or nil
	end

	local function modelName(id) return try(function() return api.res.modelRep.getName(id) end) end
	-- metadata.cost as it is now: the store reads price (vehicle_store_window.tl); priceScale is what a model
	-- with a negative price goes by (and what a price mod may change instead)
	local function costOf(id)
		local cost = try(function() return api.res.modelRep.get(id).metadata.cost end)
		return { price = cost and tonumber(core.field(cost, "price")) or nil,
			priceScale = cost and tonumber(core.field(cost, "priceScale")) or nil }
	end
	local function modelInfo(id)
		local c = costOf(id)
		return { id = id, fileName = modelName(id), price = c.price, priceScale = c.priceScale }
	end

	-- the vehicle models, by id and resource name, for the model argument
	local function vehicleModels(query)
		local all = try(function() return api.res.modelRep.getAll() end)
		if not all then error("api.res.modelRep.getAll failed", 0) end
		local q = tostring(query):lower()
		local list, digits = {}, q:match("^%d+$") and tonumber(q)
		local ok = pcall(function()
			for id, name in pairs(all) do
				-- only candidates need their metadata read: there are thousands of models
				local n = tostring(name):lower()
				if id == digits or n:find(q, 1, true) then
					local tv = try(function() return api.res.modelRep.get(id).metadata.transportVehicle end)
					if tv then list[#list + 1] = { id = id, name = tostring(name) } end
				end
			end
		end)
		if not ok then error("could not walk api.res.modelRep.getAll()", 0) end
		return list
	end

	local function findModel(query)
		local hit, err = core.matchModel(vehicleModels(query), query)
		if not hit then error(err, 0) end
		return hit.id
	end

	local function newConfig(modelId) return vc.newConfig(req, modelId) end
	local partsOf = vc.partsOf
	local function configParts(config) return partsOf(core.field(config, "vehicles")) end

	-- the same parts in the same order (modelId and purchaseTime)
	local function sameParts(a, b)
		if a == nil or b == nil or #a ~= #b then return false end
		for i = 1, #a do
			if a[i].modelId ~= b[i].modelId or a[i].purchaseTime ~= b[i].purchaseTime then return false end
		end
		return true
	end

	local function vehicleComponent(e)
		return try(function() return api.engine.getComponent(e, CT().TRANSPORT_VEHICLE) end)
	end

	-- the vehicle as the engine holds it now; nil when it is gone
	local function vehicleInfo(e)
		local tv = vehicleComponent(e)
		if not tv then return nil end
		local parts = {}
		for _, p in ipairs(core.toList(try(function() return tv.transportVehicleConfig.vehicles end))) do
			local id = tonumber(try(function() return p.part.modelId end))
			parts[#parts + 1] = { modelId = id, fileName = id and modelName(id) or nil,
				purchaseTime = tonumber(core.field(p, "purchaseTime")), maintenanceState = tonumber(core.field(p, "maintenanceState")),
				partPrice = tonumber(try(function() return api.engine.util.vehicle.getPartPrice(p) end)) }
		end
		local name = try(function() return api.engine.util.getEntityName(e) end)
		return { entity = e, name = type(name) == "string" and name or nil, line = tonumber(core.field(tv, "line")),
			depot = tonumber(core.field(tv, "depot")), parts = parts,
			depreciatedValue = tonumber(try(function() return api.engine.util.vehicle.getDepreciatedValue(e) end)) }
	end

	local function partsNow(e)
		local tv = vehicleComponent(e)
		return tv and partsOf(try(function() return tv.transportVehicleConfig.vehicles end)) or nil
	end

	-- the gui requests the speed control has to run: published as a list, so two commands in one frame both go
	local function publishRequests()
		local list = {}
		for _, r in pairs(V.requests) do list[#list + 1] = r end
		table.sort(list, function(a, b) return a.id < b.id end)
		publishUi({ vehicles = list })
	end

	-- the speed control's report on request id, or nil (not yet, or the hand-over does not work)
	local function reportOf(id)
		local d = try(function() return api.gui.game.getGuiSaveData(REPORT_KEY) end)
		if type(d) ~= "table" or type(d.reports) ~= "table" then return nil end
		for _, r in ipairs(d.reports) do
			if type(r) == "table" and tonumber(r.id) == id then return r end
		end
		return nil
	end

	-- what the report says, taken into the job once per new piece: sentParts, the base's failures, the
	-- entities onBuy gave, and an error when the request could not be sent at all
	local function absorb(job)
		if job.via ~= "gui" then return end
		local r = reportOf(job.id)
		if not r then return end
		job.picked = true
		if type(r.sentParts) == "table" then job.sentParts = core.plain(r.sentParts) end
		if r.error ~= nil and not job.reportError then
			job.reportError = "via gui: " .. tostring(r.error)
			job.failures[#job.failures + 1] = job.reportError
		end
		local fs = type(r.failures) == "table" and r.failures or {}
		for i = (job.failuresTaken or 0) + 1, #fs do job.failures[#job.failures + 1] = tostring(fs[i]) end
		job.failuresTaken = math.max(job.failuresTaken or 0, #fs)
		for _, e in ipairs(type(r.entities) == "table" and r.entities or {}) do
			e = tonumber(e)
			if e and not job.entitySet[e] then
				job.entitySet[e] = true
				job.entities[#job.entities + 1] = e
			end
		end
	end

	local function ownVehicles()
		local set = {}
		for _, e in ipairs(core.toList(try(function()
			return api.engine.getEntitiesWithComponent(CT().TRANSPORT_VEHICLE, { requireOwnedByPlayer = player() })
		end))) do set[e] = true end
		return set
	end

	-- gui buy and clone without a report (the hand-over did not come through): the new vehicles are those the
	-- company did not have before the request, of the models asked for, not taken by another job. In a paused
	-- game (as price tests run) nothing else buys. With a report, its onBuy entities are the answer instead:
	-- two jobs at once would otherwise take each other's vehicles.
	local function newVehicles(job)
		if job.picked or #job.entities >= job.expected then return end
		local want = {}
		for _, p in ipairs(job.storeParts) do want[#want + 1] = p.modelId end
		-- a vehicle another waiting job has (a cmd buy's result) is not this one's
		local taken = {}
		for _, other in ipairs(V.jobs) do
			if other ~= job then for _, e in ipairs(other.entities) do taken[e] = true end end
		end
		local found = {}
		for e in pairs(ownVehicles()) do
			if not job.known[e] and not job.entitySet[e] and not V.claimed[e] and not taken[e] then found[#found + 1] = e end
		end
		table.sort(found)
		for _, e in ipairs(found) do
			if #job.entities >= job.expected then break end
			local parts = partsNow(e) or {}
			local same = #parts == #want
			for i = 1, #want do same = same and parts[i].modelId == want[i] end
			if same then
				V.claimed[e] = true
				job.entitySet[e] = true
				job.entities[#job.entities + 1] = e
			end
		end
	end

	-- hand a gui request to the speed control
	local function submit(job, request)
		request.id = job.id
		job.request = request
		V.requests[job.id] = request
		publishRequests()
	end

	local function retire(job)
		for _, e in ipairs(job.entities) do V.claimed[e] = nil end
		if job.request and V.requests[job.id] then
			V.requests[job.id] = nil
			publishRequests()
		end
	end

	-- at each load: the reports the last game's speed control left in the GUI save data (also kept in the save)
	-- are not this game's
	function V.reset()
		local ok = pcall(function() api.gui.game.setGuiSaveData(REPORT_KEY, { reports = {} }) end)
		return ok
	end

	-- a command waiting for its result. job.check() (optional) says whether it is in; job.finish(payload) adds
	-- what is read after settling. modelIds: the models of the parts being bought, one per part (prices).
	local function newJob(c, kind, a, modelIds)
		local job = { id = c.id, kind = kind, via = a.via, deadline = appTime() + ASYNC_TIMEOUT_SEC,
			balanceBefore = balance(), gameTimeBefore = gameTime(), entities = {}, entitySet = {}, failures = {},
			expected = a.count or 1, line = a.line, lineResult = {} }
		job.storeParts = {}
		for _, id in ipairs(modelIds or {}) do
			local m = modelInfo(id)
			job.storeParts[#job.storeParts + 1] = { modelId = id, fileName = m.fileName, priceBefore = m.price,
				priceScaleBefore = m.priceScale }
		end
		return job
	end

	-- send runs the base function or the engine commands; the job waits for its result only once that went
	-- through: one that raised is answered by the caller's error, and a waiting job would answer a second time
	local function start(job, send)
		send()
		V.jobs[#V.jobs + 1] = job
	end

	-- the cost of every part as the store sums it for a vehicle of new parts (vehicle_store_window.tl, Modify:
	-- cost.price of each part whose purchaseTime is 0), before sending and now, x count
	local function prices(job, out)
		if #job.storeParts == 0 then return end
		local total, negative = 0, false
		for _, p in ipairs(job.storeParts) do
			local now = costOf(p.modelId)
			p.priceAtAnswer, p.priceScaleAtAnswer = now.price, now.priceScale
			if p.priceBefore == nil then total = nil end
			if total then total = total + p.priceBefore end
			negative = negative or (p.priceBefore or 0) < 0 or (now.price or 0) < 0
		end
		out.storeParts = job.storeParts
		out.storePriceTotal = total and total * job.expected or nil
		if negative then out.notes[#out.notes + 1] = NEGATIVE_PRICE_NOTE end
		if job.storeParts[1] and #job.storeParts == 1 then
			local p = job.storeParts[1]
			-- the single model of a buy or replace, with both readings of its cost
			out.model = { id = p.modelId, fileName = p.fileName, price = p.priceBefore, priceScale = p.priceScaleBefore,
				priceAtAnswer = p.priceAtAnswer, priceScaleAtAnswer = p.priceScaleAtAnswer }
		end
	end

	local function payloadOf(job)
		local after, timeAfter = balance(), gameTime()
		local out = { ok = true, cmd = job.kind, via = job.via, balanceBefore = job.balanceBefore, balanceAfter = after,
			spent = core.spent(job.balanceBefore, after), gameTimeBefore = job.gameTimeBefore, gameTimeAfter = timeAfter,
			count = job.expected, sentParts = job.sentParts, vehicles = core.array({}), notes = core.array({}) }
		prices(job, out)
		if job.gameTimeBefore and timeAfter and timeAfter ~= job.gameTimeBefore then out.warning = MOVED_WARNING end
		if job.via == "cmd" and job.kind ~= "sell" and job.kind ~= "money" then out.notes[#out.notes + 1] = CMD_NOTE end
		if job.via == "gui" then
			out.notes[#out.notes + 1] = GUI_NOTE
			if not job.picked and job.kind ~= "sell" then out.notes[#out.notes + 1] = NO_REPORT_NOTE end
		end
		for _, e in ipairs(job.entities) do out.vehicles[#out.vehicles + 1] = vehicleInfo(e) or { entity = e, gone = true } end
		-- the new vehicles' ids alone, for a caller that goes on with them (a line test: which vehicles to watch)
		if job.kind == "buy" or job.kind == "duplicate" then out.vehicleIds = core.array(job.entities or {}) end
		if job.line then
			out.setLine = core.array({})
			for _, e in ipairs(job.entities) do
				local r = job.lineResult[e]
				out.setLine[#out.setLine + 1] = { entity = e, line = job.line, ok = r == true, pending = r == nil or nil }
			end
		end
		if #job.failures > 0 then out.failures = job.failures end
		if #out.notes == 0 then out.notes = nil end
		if job.finish then job.finish(out) end
		return out
	end

	-- every vehicle bought is on its line (or the engine refused that), when a line was asked for. gui: the base
	-- sends the vehicle to the line with no callback for us, so it is in once the vehicle says so.
	local function linesIn(job)
		if not job.line then return true end
		for _, e in ipairs(job.entities) do
			if job.lineResult[e] == nil then
				local info = vehicleInfo(e)
				if info and info.line == job.line then job.lineResult[e] = true end
			end
			if job.lineResult[e] == nil then return false end
		end
		return true
	end

	local function done(job) return #job.entities + #job.failures >= job.expected and linesIn(job) end

	local function stepJob(job)
		absorb(job)
		if not job.settleAt and (job.check and job.check() or (not job.check and done(job))) then
			job.settleAt = V.frames + SETTLE_FRAMES
		end
		-- once the result is in, the settling frames come first: a result just before the deadline is no timeout
		if job.settleAt then
			if V.frames < job.settleAt then return false end
			local out = payloadOf(job)
			if #job.failures > 0 or out.ok == false then
				out.ok = false
				out.error = out.error or table.concat(job.failures, "; ")
			end
			answer(job.id, out, (not out.ok) and "error" or nil)
			return true
		end
		if appTime() <= job.deadline then return false end
		-- what had arrived, so a slow game still shows the vehicles it bought
		local ok, out = pcall(payloadOf, job)
		if not ok then out = { readError = tostring(out) } end
		out.ok = false
		out.error = string.format("no result in %d s (%d of %d arrived%s)%s", ASYNC_TIMEOUT_SEC,
			#job.entities + #job.failures, job.expected, job.line and ", or not yet on the line" or "",
			(job.via == "gui" and not job.picked) and "; via gui: no word from the speed control, which runs it: " ..
				"is a game on screen with the speed buttons? (its report may also not come through: unverified)" or "")
		answer(job.id, out, "error")
		return true
	end

	-- each job on its own: one that raises gets its one error answer and goes, and the others are not held up
	-- (nor answered again: a raise mid-loop used to keep the jobs already answered in this frame)
	function V.step()
		V.frames = V.frames + 1
		local keep = {}
		for _, job in ipairs(V.jobs) do
			local ok, finished = pcall(stepJob, job)
			if not ok then
				fail(job.id, finished)
			end
			if ok and not finished then
				keep[#keep + 1] = job
			else
				pcall(retire, job)
			end
		end
		V.jobs = keep
	end

	-- buy and duplicate: new vehicles from config at depot (onto line when given)
	local function buyNew(job, config, depot, line, sourceEntity)
		if job.via == "gui" then
			job.known = ownVehicles()
			job.check = function()
				if job.reportError then return true end
				newVehicles(job)
				return done(job)
			end
			submit(job, { kind = sourceEntity and "duplicate" or "buy", modelId = job.modelId, count = job.expected,
				depot = depot, line = line, vehicle = sourceEntity })
		else
			vc.fitAutoLoad(config)
			job.sentParts = configParts(config)
			for _ = 1, job.expected do
				api.cmd.sendCommand(api.cmd.makeVehicleBuyCmd(player(), depot, config), function(res, success)
					if not success then
						job.failures[#job.failures + 1] = "the buy command failed (not enough money, or the depot does not take this model)"
						return
					end
					local e = tonumber(core.field(res, "resultVehicleEntity"))
					job.entities[#job.entities + 1] = e
					if line and e then
						api.cmd.sendCommand(api.cmd.makeVehicleSetLineCmd(e, line, 0), function(_, ok)
							job.lineResult[e] = ok == true
							if ok ~= true then job.failures[#job.failures + 1] = "could not send vehicle " .. e .. " to line " .. line end
						end)
					end
				end)
			end
		end
	end

	-- args: model, depot, line, count, via
	function handlers.buy(c)
		local a, err = core.vehicleArgs("buy", c.args)
		if not a then return fail(c.id, err) end
		local modelId = findModel(a.model)
		local config = a.via == "cmd" and newConfig(modelId) or nil
		local job = newJob(c, "buy", a, { modelId })
		job.depot, job.modelId = a.depot, modelId
		start(job, function() buyNew(job, config, a.depot, a.line, nil) end)
		say(string.format("buy %d: %s x%d at depot %d via %s", c.id, tostring(job.storeParts[1].fileName), a.count, a.depot, a.via), 2)
	end

	-- args: vehicle, depot / line (default: the engine's best for that vehicle, as the clone button), via
	function handlers.duplicate(c)
		local a, err = core.vehicleArgs("duplicate", c.args)
		if not a then return fail(c.id, err) end
		local tv = vehicleComponent(a.vehicle)
		if not tv then return fail(c.id, "no vehicle " .. a.vehicle) end
		-- as manager_window.tl duplicateVehicles: a copy whose parts are new (gui: the speed control makes its own)
		local config, modelIds = vc.cloneConfig(tv.transportVehicleConfig)
		local line, depot = a.line, a.depot
		if depot == nil then
			local best = try(function() return api.engine.util.vehicle.findBestLineAndDepotForVehicle(a.vehicle) end)
			depot = tonumber(core.at(best, 2))
			if line == nil then line = tonumber(core.at(best, 1)) end
			if line and line < 0 then line = nil end
			if depot == nil or depot < 0 then return fail(c.id, "no depot found for vehicle " .. a.vehicle .. "; give one") end
		end
		local job = newJob(c, "duplicate", { via = a.via, line = line }, modelIds)
		job.source, job.depot = vehicleInfo(a.vehicle), depot
		job.finish = function(out) out.source, out.depot, out.line = job.source, job.depot, job.line end
		start(job, function() buyNew(job, config, depot, line, a.vehicle) end)
	end

	-- args: vehicle, model, via. The gui way takes no callback: done once the vehicle holds the parts that were
	-- sent, or other parts than before. A replace by the same parts (same model, same purchaseTime) cannot be
	-- told from none: answered with uncertain = true and ok = false, never a guessed ok.
	function handlers.replace(c)
		local a, err = core.vehicleArgs("replace", c.args)
		if not a then return fail(c.id, err) end
		local before = vehicleInfo(a.vehicle)
		if not before then return fail(c.id, "no vehicle " .. a.vehicle) end
		local beforeParts = partsNow(a.vehicle)
		local modelId = findModel(a.model)
		local config = a.via == "cmd" and newConfig(modelId) or nil
		local job = newJob(c, "replace", { via = a.via }, { modelId })
		job.entities, job.before = { a.vehicle }, before
		job.finish = function(out)
			out.before = job.before
			if job.uncertain then
				out.ok, out.uncertain = false, true
				out.error = "cannot tell whether the replace went through: the parts sent equal the vehicle's own " ..
					"(same model and purchaseTime); look at the vehicle"
			elseif job.via == "gui" and job.sentParts then
				out.matchesSent = sameParts(partsNow(a.vehicle), job.sentParts)
			end
		end
		-- the engine's answer to a cmd; a refusal is a failure, and either way the result is in
		local result
		job.check = function()
			if a.via == "gui" then
				if job.reportError then return true end
				-- what the speed control sent, once its report is in; until then what HandleVehicleChanges will
				-- send: the model with the game time as purchaseTime (paused: the time stays)
				local sent = job.sentParts or { { modelId = modelId, purchaseTime = job.gameTimeBefore } }
				if sameParts(sent, beforeParts) then
					job.uncertain = true
					return true
				end
				local now = partsNow(a.vehicle)
				return sameParts(now, sent) or (now ~= nil and not sameParts(now, beforeParts))
			end
			if result == false and not job.refused then
				job.refused = true
				job.failures[#job.failures + 1] = "the replace command failed"
			end
			return result ~= nil
		end
		start(job, function()
			if a.via == "gui" then
				submit(job, { kind = "replace", modelId = modelId, vehicle = a.vehicle })
			else
				job.sentParts = configParts(config)
				vc.fitAutoLoad(config)
				api.cmd.sendCommand(api.cmd.makeVehicleReplaceCmd(a.vehicle, config), function(_, success) result = success == true end)
			end
		end)
	end

	-- args: vehicle, via. Done once the vehicle is gone; spent is then negative (what the sale brought).
	function handlers.sell(c)
		local a, err = core.vehicleArgs("sell", c.args)
		if not a then return fail(c.id, err) end
		local before = vehicleInfo(a.vehicle)
		if not before then return fail(c.id, "no vehicle " .. a.vehicle) end
		local job = newJob(c, "sell", { via = a.via })
		job.before, job.entities = before, { a.vehicle }
		job.finish = function(out)
			out.before = job.before
			out.sold = vehicleComponent(a.vehicle) == nil
			if not out.sold then
				out.ok = false
				out.error = #job.failures > 0 and table.concat(job.failures, "; ") or "the vehicle is still there"
			end
		end
		local result
		job.check = function()
			if a.via == "gui" then return job.reportError ~= nil or vehicleComponent(a.vehicle) == nil end
			if result == false and not job.refused then
				job.refused = true
				job.failures[#job.failures + 1] = "the sell command failed"
			end
			return result ~= nil
		end
		start(job, function()
			if a.via == "gui" then
				submit(job, { kind = "sell", vehicle = a.vehicle })
			else
				api.cmd.sendCommand(api.cmd.makeVehicleSellCmd({ a.vehicle }), function(_, success) result = success == true end)
			end
		end)
	end

	local function enumOf(name) return try(function() return api.type.enum[name] end) end
	local function carrierName(v)
		local enum = enumOf("Carrier")
		for _, n in ipairs(CARRIERS) do
			if enum and try(function() return enum[n] end) == v then return n end
		end
		return tostring(v)
	end

	-- the transport modes a depot takes (by name), and the kind they make (road, tram, rail, water, air)
	local function depotModes(d)
		local modes = d and try(function() return d.transportModes end)
		local enum = enumOf("TransportMode")
		local names, kinds, seen = {}, {}, {}
		if modes == nil or enum == nil then return names, nil end
		for _, mk in ipairs(MODE_KINDS) do
			local v = try(function() return enum[mk[1]] end)
			if v ~= nil and try(function() return modes[v] end) == true then
				names[#names + 1] = mk[1]
				if not seen[mk[2]] then seen[mk[2]] = true; kinds[#kinds + 1] = mk[2] end
			end
		end
		return names, #kinds > 0 and table.concat(kinds, "+") or nil
	end

	-- the depot's carriers as the base's statistics work them out (statistics_react_util.tl,
	-- areCarriersContainedInTransportModes): the modes it takes, through transportModesToCarriers. nil when that
	-- fails (unverified in game), and MODE_KINDS gives the kind instead.
	local function depotCarriers(d)
		local ok, out = pcall(function()
			local modes = {}
			for mode, val in pairs(d.transportModes) do if val then modes[#modes + 1] = mode end end
			local list = {}
			for _, c in ipairs(core.toList(api.engine.util.transport.transportModesToCarriers(modes))) do
				list[#list + 1] = carrierName(c)
			end
			return list
		end)
		if ok and type(out) == "table" and #out > 0 then return out end
		return nil
	end

	-- args: grep (substring of the name, any case). The company's own depots, as the line manager lists them
	-- (manager_window.tl: requireOwnedByPlayer)
	function handlers.depots(c)
		local ids = core.toList(api.engine.getEntitiesWithComponent(CT().VEHICLE_DEPOT, { requireOwnedByPlayer = player() }))
		local grep = type(c.args.grep) == "string" and c.args.grep:lower() or nil
		local out = {}
		for _, e in ipairs(ids) do
			local d = try(function() return api.engine.getComponent(e, CT().VEHICLE_DEPOT) end)
			local name = try(function() return api.engine.util.getEntityName(e) end)
			name = type(name) == "string" and name or ""
			if not grep or name:lower():find(grep, 1, true) then
				local raw = d and core.field(d, "carrier")
				local modes, kind = depotModes(d)
				local carriers = d and depotCarriers(d) or nil
				if carriers then kind = table.concat(carriers, "+"):lower() end
				-- carrierRaw: what the engine gave, so a wrong name can be told from a wrong reading
				out[#out + 1] = { id = e, name = name, kind = kind, transportModes = modes, carriers = carriers,
					carrier = d and carrierName(raw) or nil, carrierRaw = raw ~= nil and tostring(raw) or nil,
					maintenancePool = d and tonumber(core.field(d, "maintenancePool")) or nil,
					vehicles = core.size(try(function() return api.engine.system.transportVehicleSystem.getDepotVehicles(e) end)) }
			end
		end
		table.sort(out, function(x, y) return x.name < y.name end)
		answer(c.id, { ok = true, depots = core.array(out) })
	end

	-- args: line (only its vehicles), limit
	function handlers.vehicles(c)
		local line = c.args.line ~= nil and tonumber(c.args.line) or nil
		if c.args.line ~= nil and line == nil then return fail(c.id, "line must be an entity id") end
		local ids = core.toList(api.engine.getEntitiesWithComponent(CT().TRANSPORT_VEHICLE, { requireOwnedByPlayer = player() }))
		local limit = tonumber(c.args.limit) or 200
		local out, total = {}, 0
		for _, e in ipairs(ids) do
			local info = vehicleInfo(e)
			if info and (line == nil or info.line == line) then
				total = total + 1
				if #out < limit then out[#out + 1] = info end
			end
		end
		answer(c.id, { ok = true, total = total, vehicles = core.array(out) })
	end

	-- args: set (the balance to have) or add. As the sandbox money editor (game_bar.tl MoneyDisplay): a journal
	-- entry of category OTHER for the difference, booked with makeJournalBookAssetCmd. Not with infinite money.
	function handlers.money(c)
		local a, err = core.moneyArgs(c.args)
		if not a then return fail(c.id, err) end
		local before = balance()
		local amount, err2 = core.moneyAmount(a, before)
		if not amount then return fail(c.id, err2) end
		local entry = api.type.JournalEntry.new()
		entry.amount = amount
		entry.time = -1
		entry.category.type = api.type.JournalEntry.Type.OTHER
		local job = newJob(c, "money", { via = "cmd" })
		local result
		job.check = function() return result ~= nil end
		job.finish = function(out)
			out.vehicles, out.count, out.via = nil, nil, nil
			out.set, out.add, out.amount, out.callback = a.set, a.add, amount, result
			if result ~= true then out.ok, out.error = false, "the journal command failed" end
			if result == true and a.set ~= nil and out.balanceAfter ~= a.set then
				out.notes = out.notes or {}
				out.notes[#out.notes + 1] = "set not reached: the balance moved on (game time went on, fares and costs " ..
					"came in); pause the game for an exact balance"
			end
		end
		start(job, function()
			api.cmd.sendCommand(api.cmd.makeJournalBookAssetCmd(player(), entry), function(_, success) result = success == true end)
		end)
		say(string.format("money %d: %s%d (amount %d)", c.id, a.set and "set " or "add ", a.set or a.add, amount), 2)
	end

	V.handlers = handlers
	return V
end

return M
