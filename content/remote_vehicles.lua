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
local MODE_NAMES = { "PERSON", "CARGO" }
for _, mk in ipairs(MODE_KINDS) do MODE_NAMES[#MODE_NAMES + 1] = mk[1] end
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

	-- the multiple units (.mu.lua, api.res.multipleUnitRep) as { id, name }, and a note on how they were read: the
	-- names are getAll()'s values (getName only as a fallback), and an empty getAll() is tried again with
	-- includeInvisible (getAll(true)), which the note says. The store lists them as rows of their own.
	local function muList()
		local rep = try(function() return api.res.multipleUnitRep end)
		if not rep then error("api.res.multipleUnitRep is not there", 0) end
		local getName = function(id) return api.res.multipleUnitRep.getName(id) end
		local all = try(function() return api.res.multipleUnitRep.getAll() end)
		local list = core.muListFrom(all, getName)
		local note
		if #list == 0 then
			local all2 = try(function() return api.res.multipleUnitRep.getAll(true) end)
			local list2 = core.muListFrom(all2, getName)
			note = string.format("getAll() gave %s, getAll(true) %d", all == nil and "nothing (it failed)" or "none", #list2)
			list = list2
		end
		return list, note
	end

	-- the multiple unit a model argument ending in .mu.lua names (core.matchMu), opened as the store would
	local function findMu(query)
		local list, note = muList()
		local hit, err = core.matchMu(list, query, note)
		if not hit then error(err, 0) end
		local mu, why = vc.muParts(hit.id, hit.name)
		if not mu then error(why, 0) end
		return mu
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
			-- reversed only on a part turned round (a multiple unit's end car, say): a single model's answer keeps its shape
			local rev = try(function() return p.part.reversed end) == true or nil
			parts[#parts + 1] = { modelId = id, fileName = id and modelName(id) or nil, reversed = rev,
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
		-- the engine's answer to each vehicle's send to the line (vehicle_configs.sendToLine): a refusal answers now,
		-- with its reason, instead of waiting out the deadline for a vehicle that stays in its depot
		for _, x in ipairs(type(r.setLine) == "table" and r.setLine or {}) do
			local e = type(x) == "table" and tonumber(x.entity) or nil
			if e and job.line and job.lineResult[e] == nil and (x.ok == true or x.ok == false) then
				job.lineResult[e] = x.ok
				if x.ok == false then
					local why = { reason = x.reason and tostring(x.reason) or nil, message = x.message and tostring(x.message) or nil,
						reasonError = x.reasonError and tostring(x.reasonError) or nil,
						sendError = x.sendError and tostring(x.sendError) or nil }
					if type(x.position) == "table" then
						why.position = { x = tonumber(x.position.x), y = tonumber(x.position.y), z = tonumber(x.position.z) }
					end
					job.lineRefusal[e] = why
					job.lineFailures[#job.lineFailures + 1] = string.format("the engine would not put vehicle %d on line %d: %s",
						e, job.line, why.reason or why.sendError or why.reasonError or "no reason given")
				end
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
			expected = a.count or 1, line = a.line, lineResult = {}, lineRefusal = {}, lineFailures = {} }
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
		if job.mu then
			-- the multiple unit bought: its parts as its file lists them (forward false: turned round)
			local parts = {}
			for i, p in ipairs(job.mu.parts) do parts[i] = { modelId = p.modelId, name = p.name, forward = p.forward } end
			out.multipleUnit = { id = job.mu.id, fileName = job.mu.fileName, name = job.mu.name, parts = core.array(parts) }
		end
		if job.gameTimeBefore and timeAfter and timeAfter ~= job.gameTimeBefore then out.warning = MOVED_WARNING end
		if job.via == "cmd" and job.kind ~= "sell" and job.kind ~= "money" then out.notes[#out.notes + 1] = CMD_NOTE end
		if job.via == "gui" then
			out.notes[#out.notes + 1] = GUI_NOTE
			if not job.picked and job.kind ~= "sell" then out.notes[#out.notes + 1] = NO_REPORT_NOTE end
		end
		for _, e in ipairs(job.entities) do out.vehicles[#out.vehicles + 1] = vehicleInfo(e) or { entity = e, gone = true } end
		if job.mu then
			-- what the engine holds of each train's grouping, so a game test sees the unit was taken as one
			for _, v in ipairs(out.vehicles) do
				local tv = v.entity and not v.gone and vehicleComponent(v.entity)
				if tv then
					local groups, names = {}, {}
					for _, n in ipairs(core.toList(try(function() return tv.transportVehicleConfig.vehicleGroups end))) do
						groups[#groups + 1] = tonumber(n)
					end
					for _, n in ipairs(core.toList(try(function() return tv.transportVehicleConfig.muFileNames end))) do
						names[#names + 1] = tostring(n)
					end
					v.vehicleGroups, v.muFileNames = core.array(groups), core.array(names)
				end
			end
		end
		-- the new vehicles' ids alone, for a caller that goes on with them (a line test: which vehicles to watch)
		if job.kind == "buy" or job.kind == "duplicate" then out.vehicleIds = core.array(job.entities or {}) end
		if job.line then
			out.setLine = core.array({})
			for _, e in ipairs(job.entities) do
				local r = job.lineResult[e]
				local entry = { entity = e, line = job.line, ok = r == true, pending = r == nil or nil }
				-- a refusal (gui): Failure.Reason by name, the base's text for it, where the path ends
				for k, v in pairs((job.lineRefusal or {})[e] or {}) do entry[k] = v end
				out.setLine[#out.setLine + 1] = entry
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
			-- line refusals apart from failures: done() counts failures as vehicles that did not come
			local errors = {}
			for _, f in ipairs(job.failures) do errors[#errors + 1] = f end
			for _, f in ipairs(job.lineFailures or {}) do errors[#errors + 1] = f end
			if #errors > 0 or out.ok == false then
				out.ok = false
				out.error = out.error or table.concat(errors, "; ")
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
				depot = depot, line = line, vehicle = sourceEntity, mu = job.mu and job.mu.id or nil,
				muName = job.mu and job.mu.fileName or nil })
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

	-- args: model, depot, line, count, via. A model ending in .mu.lua is a multiple unit: the whole train its file
	-- lists, as the store's multiple-unit row buys it (gui only, core.vehicleArgs)
	function handlers.buy(c)
		local a, err = core.vehicleArgs("buy", c.args)
		if not a then return fail(c.id, err) end
		if a.mu then
			local mu = findMu(a.model)
			local modelIds = {}
			for i, p in ipairs(mu.parts) do modelIds[i] = p.modelId end
			local job = newJob(c, "buy", a, modelIds)
			job.depot, job.mu = a.depot, mu
			start(job, function() buyNew(job, nil, a.depot, a.line, nil) end)
			say(string.format("buy %d: %s (%d parts) x%d at depot %d via %s", c.id, mu.fileName, #mu.parts, a.count,
				a.depot, a.via), 2)
			return
		end
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

	-- the cargo types as getAll lists them: id -> file name. Engine lookups by cargo id stay within these (an id
	-- the engine does not know is its assertion, as for stocks).
	local function cargoNames()
		local names = {}
		pcall(function()
			-- true: the hidden cargo types too, as the other commands list them
			for id, name in pairs(api.res.cargoTypeRep.getAll(true)) do names[tonumber(id)] = tostring(name) end
		end)
		return names
	end

	local VEHICLE_STATES = { "IN_DEPOT", "EN_ROUTE", "AT_TERMINAL", "GOING_TO_DEPOT" }
	local LOAD_STATES = { "None", "Arrived", "Unloading", "Loading", "WaitForScheduledDeparture", "Departing" }
	local MODIFIER_KEYS = { "vehicleOverlength", "stockCompatibility", "vehicleCompatibility", "vehicleIncompatibility" }

	local function numbers(v)
		local out = {}
		for _, x in ipairs(core.toList(v)) do out[#out + 1] = tonumber(x) end
		return core.array(out)
	end

	-- a per-cargo vector (cargo id + 1) as { cargoType, cargo, <key> = value }, for the cargo types getAll lists;
	-- keep(v, id) picks the entries (default: a number other than 0)
	local function perCargo(vector, key, names, keep)
		keep = keep or function(v) return type(v) == "number" and v ~= 0 end
		local out = {}
		if vector == nil then return core.array(out) end
		-- only within the vector's length: past its end may be the engine's assertion, which pcall does not stop
		local n = core.size(vector)
		for _, id in ipairs(core.cargoIds(names)) do
			local v = id + 1 <= n and core.at(vector, id + 1) or nil
			if keep(v, id) then out[#out + 1] = { cargoType = id, cargo = names[id], [key] = v } end
		end
		return core.array(out)
	end

	-- the stop a vehicle on a line is at or heads to: stopIndex is 0-based (makeVehicleSetLineCmd takes the stop
	-- the same way), so stops[stopIndex + 1]. Unverified in game which of the two it is while en route.
	local function stopOf(line, stopIndex)
		if not line or line < 0 or not stopIndex then return nil end
		local lc = try(function() return api.engine.getComponent(line, CT().LINE) end)
		local s = lc and core.at(core.field(lc, "stops"), stopIndex + 1)
		if s == nil then return nil end
		local sg = tonumber(core.field(s, "stationGroup"))
		local name = sg and try(function() return api.engine.util.getEntityName(sg) end)
		return { stationGroup = sg, name = type(name) == "string" and name or nil,
			station = tonumber(core.field(s, "station")), terminal = tonumber(core.field(s, "terminal")) }
	end

	-- what the engine holds about a running vehicle's stop and money (engine.d.tl TransportVehicle), each read on
	-- its own: one that fails or is not there is left out (nil), not the vehicle. Times: game time as GAME_TIME
	-- gives it (doorsTime, lineStopDepartures, lastLineStopDeparture); the timeUntil* fields are as the engine
	-- counts them down (seconds: unverified). since: a game time for balanceSince.
	local function vehicleState(e, now, since, names)
		local tv = vehicleComponent(e)
		if not tv then return nil end
		local function get(k) return try(function() return tv[k] end) end
		local function bool(k)
			local v = get(k)
			if type(v) == "boolean" then return v end -- false stays false (an and/or would make it nil)
			return nil
		end
		local function num(k) return tonumber(get(k)) end
		local stateEnum = try(function() return api.type.enum.TransportVehicleState end)
		local loadEnum = try(function() return api.type.TransportVehicle.LoadState end)
		local line, stopIndex = tonumber(core.field(tv, "line")), num("stopIndex")
		local ast = get("arrivalStationTerminal")
		local doorsTime = num("doorsTime")
		local st = { state = stateEnum and core.enumName(stateEnum, VEHICLE_STATES, get("state")) or nil,
			loadState = loadEnum and core.enumName(loadEnum, LOAD_STATES, get("loadState")) or nil,
			userStopped = bool("userStopped"), sellOnArrival = bool("sellOnArrival"), noPath = bool("noPath"),
			autoDeparture = bool("autoDeparture"), doorsOpen = bool("doorsOpen"), doorsTime = doorsTime,
			sinceDoors = (now and doorsTime) and now - doorsTime or nil,
			daysAtTerminal = num("daysAtTerminal"), daysInDepot = num("daysInDepot"),
			stopIndex = stopIndex, stop = stopOf(line, stopIndex),
			arrivalStationTerminal = ast and { station = tonumber(core.field(ast, "station")),
				terminal = tonumber(core.field(ast, "terminal")) } or nil,
			arrivalStationTerminalLocked = bool("arrivalStationTerminalLocked"),
			lineStopDepartures = numbers(get("lineStopDepartures")), lastLineStopDeparture = num("lastLineStopDeparture"),
			sectionTimes = numbers(get("sectionTimes")), visitedStops = numbers(get("visitedStops")),
			timeUntilNextScheduledDeparture = num("timeUntilNextScheduledDeparture"),
			timeUntilCloseDoors = num("timeUntilCloseDoors"), timeUntilDeparture = num("timeUntilDeparture"),
			timeUntilNextLoad = perCargo(get("timeUntilNextLoad"), "seconds", names),
			timeUntilNextUnload = perCargo(get("timeUntilNextUnload"), "seconds", names),
			speed = tonumber(try(function() return api.engine.util.vehicle.getSpeed(e) end)),
			maintenanceState = tonumber(try(function() return api.engine.util.vehicle.getVehicleMaintenanceState(e) end)),
			-- per year, as the vehicle window shows it (entity_window_util.tl, rounded there)
			runningCostPerYear = tonumber(try(function() return api.engine.util.vehicle.getRunningCost(e) end)) }
		-- what it carries now, per cargo type it has room for (cargo_util.tl getCargoTypeInfoForVehicle)
		local capacities = try(function() return tv.config.capacities end)
		local cargo, room = {}, {}
		for _, x in ipairs(perCargo(capacities, "capacity", names, function(v) return (tonumber(v) or 0) > 0 end)) do
			x.capacity = tonumber(x.capacity)
			x.count = tonumber(try(function()
				return api.engine.system.simEntityAtVehicleSystem.getVehicleSimEntitiesCountForCargoType(e, x.cargoType)
			end))
			room[x.cargoType] = true
			cargo[#cargo + 1] = x
		end
		st.cargo = core.array(cargo)
		-- the load speed modifiers the engine has for those cargo types at the terminal: read only while at one, as
		-- the vehicle window's tooltip does (cargo_util.tl getCargoTypeInfoForVehicle)
		local mods = {}
		local modVector = st.state == "AT_TERMINAL" and get("loadSpeedModifiers") or nil
		for _, x in ipairs(perCargo(modVector, "m", names, function(v, id) return v ~= nil and room[id] end)) do
			local m = x.m
			local entry = { cargoType = x.cargoType, cargo = x.cargo,
				totalPenalty = tonumber(try(function() return m:getTotalPenalty() end)) }
			for _, k in ipairs(MODIFIER_KEYS) do entry[k] = tonumber(core.field(m, k)) end
			mods[#mods + 1] = entry
		end
		st.loadSpeedModifiers = core.array(mods)
		-- income minus running costs as the statistics' vehicle table sums them (statistic_vehicles.tl: the last
		-- year), and from since when asked
		if now then
			local year = tonumber(try(function() return api.util.getDefaultYearDuration() end))
			if year then
				st.balanceLastYear = tonumber(try(function()
					return api.engine.util.finance.calculateBalance({ e }, math.max(now - year, 0), now, true)
				end))
			end
			if since then
				st.balanceSince = tonumber(try(function()
					return api.engine.util.finance.calculateBalance({ e }, since, now, true)
				end))
			end
		end
		return st
	end

	-- whether the vehicle is at a terminal now (TransportVehicle.state AT_TERMINAL): only the one field read, so
	-- a fleet can be filtered before the full state of the few in port is read. nil when it cannot be told.
	local function atTerminal(e)
		local tv = vehicleComponent(e)
		local enum = try(function() return api.type.enum.TransportVehicleState end)
		local at = enum and try(function() return enum.AT_TERMINAL end)
		if not tv or at == nil then return nil end
		return try(function() return tv.state end) == at
	end

	-- args: line (only its vehicles), limit; entities (only these; gone ones under missing), state (add the
	-- engine's stop and money fields under state, and the game time: GAME_TIME's gameTime, read once for the
	-- answer, so every vehicle in it is of the same frame), since (with state: balanceSince), atTerminal (with
	-- state: only those at a terminal now; total counts them, and one of entities that is not at a terminal is
	-- neither listed nor missing; stateUnknown counts those whose state could not be read). Without the new args the answer is as it always was.
	function handlers.vehicles(c)
		local a, err = core.vehicleListArgs(c.args)
		if not a then return fail(c.id, err) end
		local ids, missing
		if a.entities then
			-- only the ones asked for, and only the company's (as the list): another company's is missing too
			local own = ownVehicles()
			ids, missing = {}, {}
			for _, e in ipairs(a.entities) do
				if own[e] then ids[#ids + 1] = e else missing[#missing + 1] = e end
			end
		else
			ids = core.toList(api.engine.getEntitiesWithComponent(CT().TRANSPORT_VEHICLE, { requireOwnedByPlayer = player() }))
		end
		local now = a.state and gameTime() or nil
		-- the state reads a dozen engine calls per vehicle (two balances among them): without entities, at most
		-- MAX_VEHICLE_ENTITIES of them, so a poll over the whole fleet does not hold up the frame
		local limit = a.limit
		if a.state and not a.entities then limit = math.min(limit, core.MAX_VEHICLE_ENTITIES) end
		local names = a.state and cargoNames() or nil
		local out, total, unknown = {}, 0, 0
		for _, e in ipairs(ids) do
			local info = vehicleInfo(e)
			local here = true
			if info and a.atTerminal and (a.line == nil or info.line == a.line) then
				here = atTerminal(e)
				if here == nil then unknown = unknown + 1 end
			end
			if info and (a.line == nil or info.line == a.line) and here == true then
				total = total + 1
				if #out < limit then
					if a.state then info.state = vehicleState(e, now, a.since, names) end
					out[#out + 1] = info
				end
			elseif not info and missing then
				missing[#missing + 1] = e
			end
		end
		local res = { ok = true, total = total, vehicles = core.array(out) }
		if missing then res.missing = core.array(missing) end
		if a.state then res.gameTime, res.since = now, a.since end
		-- stateUnknown: those left out because their state could not be read, so an empty answer is not taken
		-- for "nobody in port"
		if a.atTerminal then res.atTerminal, res.stateUnknown = true, unknown end
		answer(c.id, res)
	end

	local VEHICLE_KINDS = { "landVehicle", "airVehicle", "waterVehicle" } -- the store's order (getTopSpeed)
	local CARGO_SET_KEYS = { "cargoClassesIncluded", "cargoClassesExcluded", "cargoTypesIncluded", "cargoTypesExcluded" }

	local function strings(v)
		local out = {}
		for _, x in ipairs(core.toList(v)) do out[#out + 1] = tostring(x) end
		return core.array(out)
	end

	local function modeNames(list)
		local enum = enumOf("TransportMode")
		local out = {}
		for _, v in ipairs(core.toList(list)) do
			out[#out + 1] = enum and core.enumName(enum, MODE_NAMES, v) or tostring(v)
		end
		return core.array(out)
	end

	-- a vehicle model as the store reads it (vehicle_store_util.tl makeSingleVehicle / collectVehicleData):
	-- metadata.cost.price and metadata.maintenance.runningCosts (the base fills in a -1 from its formula at load,
	-- model_metadata_util.addCostMetadata, and scales both by the difficulty after, post_run_util), the top speed
	-- of the land, air or water part (m/s), loadSpeed, and the capacity per cargo type summed as the store does.
	-- Each piece on its own: what is not there is nil.
	local function modelDetails(id, names)
		local md = try(function() return api.res.modelRep.get(id).metadata end)
		local function sub(k) return md and try(function() return md[k] end) or nil end
		local cost, mt, tv, desc, avail = sub("cost"), sub("maintenance"), sub("transportVehicle"), sub("description"), sub("availability")
		local name = desc and core.field(desc, "name")
		local m = { id = id, fileName = modelName(id), name = type(name) == "string" and name or nil,
			price = cost and tonumber(core.field(cost, "price")) or nil,
			priceScale = cost and tonumber(core.field(cost, "priceScale")) or nil,
			runningCosts = mt and tonumber(core.field(mt, "runningCosts")) or nil,
			runningCostScale = mt and tonumber(core.field(mt, "runningCostScale")) or nil,
			lifespan = mt and tonumber(core.field(mt, "lifespan")) or nil,
			yearFrom = avail and tonumber(core.field(avail, "yearFrom")) or nil,
			yearTo = avail and tonumber(core.field(avail, "yearTo")) or nil }
		if tv then
			m.carrier = carrierName(core.field(tv, "carrier"))
			m.transportModes = modeNames(core.field(tv, "transportModes"))
			m.loadSpeed = tonumber(core.field(tv, "loadSpeed"))
			m.arrivalDelay = tonumber(core.field(tv, "arrivalDelay"))
			m.departureDelay = tonumber(core.field(tv, "departureDelay"))
		end
		for _, k in ipairs(VEHICLE_KINDS) do
			local v = sub(k)
			if v and m.topSpeed == nil then m.topSpeed = tonumber(core.field(v, "topSpeed")) end
		end
		if m.topSpeed then m.topSpeedKmh = math.floor(m.topSpeed * 36 + 0.5) / 10 end
		local wv = sub("waterVehicle")
		if wv then
			-- type: the .mdl's waterVehicle.type ("SMALL") is turned into transportModes at load
			-- (model_metadata_util.lua) and is not in the engine's record (type.d.tl), so it is nil in game, and
			-- small says it instead: SMALL_SHIP in transportModes
			local t = core.field(wv, "type")
			m.water = { type = t ~= nil and tostring(t) or nil, topSpeed = tonumber(core.field(wv, "topSpeed")),
				weightEmpty = tonumber(core.field(wv, "weightEmpty")),
				weightMaxPayload = tonumber(core.field(wv, "weightMaxPayload")),
				availPower = tonumber(core.field(wv, "availPower")) }
			for _, mode in ipairs(m.transportModes or {}) do
				if mode == "SMALL_SHIP" then m.water.small = true elseif mode == "SHIP" then m.water.small = false end
			end
		end
		-- compartments as they are, and the capacity per cargo type the store makes of them
		local comps, forStore = {}, {}
		for _, comp in ipairs(core.toList(tv and core.field(tv, "compartments"))) do
			local lcs, store = {}, {}
			for _, lc in ipairs(core.toList(core.field(comp, "loadConfigs"))) do
				local entry = core.field(lc, "cargoEntry")
				local set = entry and core.field(entry, "cargoTypeSet")
				local o = { capacity = entry and tonumber(core.field(entry, "capacity")) or nil }
				for _, k in ipairs(CARGO_SET_KEYS) do o[k] = strings(set and core.field(set, k)) end
				local ids = {}
				if set then
					pcall(function()
						api.res.cargoTypeRep.forEachCargoType(set, function(cid) ids[#ids + 1] = tonumber(cid) end)
					end)
				end
				lcs[#lcs + 1] = o
				store[#store + 1] = { capacity = o.capacity, cargoTypes = ids }
			end
			comps[#comps + 1] = { loadConfigs = core.array(lcs) }
			forStore[#forStore + 1] = store
		end
		m.compartments = core.array(comps)
		local per, total = core.storeCapacities(forStore)
		local caps = {}
		for cid, n in pairs(per) do caps[#caps + 1] = { cargoType = cid, cargo = names[cid], capacity = n } end
		table.sort(caps, function(x, y) return x.cargoType < y.cargoType end)
		m.capacities, m.totalCapacity = core.array(caps), total
		if m.price and m.price < 0 then
			m.notes = core.array({ "cost.price is negative: the base's formula did not fill it in (the store shows it as is)" })
		end
		return m
	end

	-- args: grep (a part of the file or shown name, any case; digits: the id too), carrier, limit. Read only: the
	-- vehicle models (metadata.transportVehicle), sorted by file name; details for the first limit of them.
	-- Every model's metadata is looked at once (there are thousands), as the base's post_run_util walks them.
	-- the vehicle models with what the filters need, walked once per load of this script: models do not change
	-- within a game, and a walk looks at thousands of them in one frame
	local function vehicleModelIndex()
		if V.modelIndex then return V.modelIndex end
		local all = try(function() return api.res.modelRep.getAll() end)
		if not all then error("api.res.modelRep.getAll failed", 0) end
		local started, list = appTime(), {}
		local ok = pcall(function()
			for id, fileName in pairs(all) do
				local md = try(function() return api.res.modelRep.get(id).metadata end)
				local tv = md and try(function() return md.transportVehicle end)
				if tv then
					local shown = try(function() return md.description.name end)
					list[#list + 1] = { id = id, fileName = tostring(fileName), carrier = carrierName(core.field(tv, "carrier")),
						shown = type(shown) == "string" and shown:lower() or nil }
				end
			end
		end)
		if not ok then error("could not walk api.res.modelRep.getAll()", 0) end
		table.sort(list, function(x, y) return x.fileName < y.fileName end)
		local took = (tonumber(appTime()) or started) - (tonumber(started) or 0)
		if took > 0.5 then say(string.format("models: walking the models took %.1f s (once per load)", took), 1) end
		V.modelIndex = list
		return list
	end

	-- models --mu: the multiple units (id, file name, shown name, cars), for the name a buy of one takes
	local function multipleUnits(c, a)
		local list, note = muList()
		local hits = {}
		local want = type(a.mu) == "string" and a.mu:lower() or nil
		for _, m in ipairs(list) do
			if not want or tostring(m.name):lower():find(want, 1, true) then hits[#hits + 1] = m end
		end
		local out = {}
		for i = 1, math.min(#hits, a.limit) do
			local m = hits[i]
			local mu = try(function() return api.res.multipleUnitRep.get(m.id) end)
			local title = mu and try(function() return mu.name end)
			local cars = mu and core.toList(try(function() return mu.vehicles end)) or nil
			out[#out + 1] = { id = m.id, fileName = m.name, name = type(title) == "string" and title or nil,
				cars = cars and #cars or nil, buyAs = core.muKey(m.name) .. core.MU_SUFFIX }
		end
		answer(c.id, { ok = true, total = #hits, listed = #list, note = note, multipleUnits = core.array(out) })
	end

	function handlers.models(c)
		local a, err = core.modelsArgs(c.args)
		if not a then return fail(c.id, err) end
		if a.mu then return multipleUnits(c, a) end
		local index = vehicleModelIndex()
		local digits = a.grep and a.grep:match("^%d+$") and tonumber(a.grep)
		local hits = {}
		for _, m in ipairs(index) do
			local keep = a.carrier == nil or m.carrier == a.carrier
			if keep and a.grep then
				keep = m.id == digits or m.fileName:lower():find(a.grep, 1, true) ~= nil
					or (m.shown ~= nil and m.shown:find(a.grep, 1, true) ~= nil)
			end
			if keep then hits[#hits + 1] = m end
		end
		local names, out = cargoNames(), {}
		for i = 1, math.min(#hits, a.limit) do out[#out + 1] = modelDetails(hits[i].id, names) end
		answer(c.id, { ok = true, total = #hits, models = core.array(out) })
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

	-- the persons command (read only). Where it reads from (base GUI and api/engine.d.tl):
	--   who is aboard: simEntityAtVehicleSystem.getVehicle2Cargo2SimEntitesMap()[vehicle][passengers + 1], as the
	--     vehicle window's passenger list does (entity_window_util.tl PassengersWidget); who uses a line:
	--     simPersonSystem.getSimPersonsForLine (system.d.tl: "travelling with the given line"; whether that takes in
	--     those waiting for it is not written there, nor checked in game)
	--   per person: SIM_PERSON (happiness; below 0.5 the base says "Unhappy"), SIM_PERSON_AT_VEHICLE (vehicle,
	--     part, place, expectedArrivalTime), SIM_ENTITY_AT_VEHICLE (line, lineStop0, lineStop1),
	--     SIM_ENTITY_AT_TERMINAL (waiting: line, stops, arrivalTime), util.cargo.isGoodQuality
	--   late: the game time is past expectedArrivalTime, the base person window's test for a falling happiness
	--     (sim_person.tl: gt.gameTime > spav.expectedArrivalTime); so both are game time (ms). Waiting, the
	--     window's test is arrivalTime + 2 min (1000 * 2 * 60 there): atTerminal.late
	--   counts: util.cargo.getCargoQualityDataForVehicle / ForLine / AtStop / AtStationGroup with the passenger
	--     cargo type (vehicle_eow.script.tl, cargo_util.tl, station_group.tl, layer_public_transport.tl)
	-- Each read on its own: one that fails or is not there is left out (nil), not the person or the answer.
	local function personComp(e, kind) return try(function() return api.engine.getComponent(e, CT()[kind]) end) end
	local function entityNum(v)
		local n = tonumber(v)
		if n == nil or n < 0 then return nil end
		return n
	end
	local function personInfo(e, now)
		local p = { id = e }
		local sp = personComp(e, "SIM_PERSON")
		if sp == nil then
			p.error = "no SIM_PERSON component (the person may have just arrived or gone)"
			return p
		end
		p.happiness = tonumber(core.field(sp, "happiness"))
		p.targetOrAtEntity = entityNum(core.field(sp, "targetOrAtEntity"))
		p.destinations = numbers(core.field(sp, "destinations")) -- residence, shopping, work (-1: none)
		p.lastMoveMode = tonumber(core.field(sp, "lastMoveMode"))
		local good = try(function() return api.engine.util.cargo.isGoodQuality(e) end)
		if type(good) == "boolean" then p.good = good end
		local spav = personComp(e, "SIM_PERSON_AT_VEHICLE")
		if spav ~= nil then
			local eta = tonumber(core.field(spav, "expectedArrivalTime"))
			p.atVehicle = { vehicle = entityNum(core.field(spav, "vehicle")), part = tonumber(core.field(spav, "part")),
				place = tonumber(core.field(spav, "place")), expectedArrivalTime = eta }
			-- a negative time is no expected arrival (the base person window tests >= 0 for the car's, sim_person.tl)
			if eta and eta >= 0 and now then
				p.untilArrival = eta - now
				p.late = now > eta
			end
		end
		local seav = personComp(e, "SIM_ENTITY_AT_VEHICLE")
		if seav ~= nil then
			p.trip = { line = entityNum(core.field(seav, "line")), lineStop0 = tonumber(core.field(seav, "lineStop0")),
				lineStop1 = tonumber(core.field(seav, "lineStop1")), vehicle = entityNum(core.field(seav, "vehicle")),
				roundTripCounter = tonumber(core.field(seav, "roundTripCounter")) }
		end
		local seat = personComp(e, "SIM_ENTITY_AT_TERMINAL")
		if seat ~= nil then
			local arrived = tonumber(core.field(seat, "arrivalTime"))
			p.atTerminal = { line = entityNum(core.field(seat, "line")), lineStop0 = tonumber(core.field(seat, "lineStop0")),
				lineStop1 = tonumber(core.field(seat, "lineStop1")), vehicle = entityNum(core.field(seat, "vehicle")),
				arrivalTime = arrived, sinceArrival = (arrived and now) and now - arrived or nil }
			if arrived and now then p.atTerminal.late = now > arrived + core.TERMINAL_GRACE_MS end
		end
		p.where = (spav or seav) and "vehicle" or (seat and "terminal") or "other"
		return p
	end

	local function passengerCargo()
		return tonumber(try(function() return api.res.cargoTypeRep.getPassengerCargoTypeId() end)) or 0
	end

	-- the engine's passenger counts for a line and each of its stops (stop index 0-based, as getCargoQualityDataAtStop
	-- takes it in station_group.tl), with each stop's station group
	local function lineQuality(line, pax)
		local out = { line = core.qualityOf(try(function() return api.engine.util.cargo.getCargoQualityDataForLine(line, pax) end)) }
		local lc = try(function() return api.engine.getComponent(line, CT().LINE) end)
		local stops = {}
		for i, s in ipairs(core.toList(lc and core.field(lc, "stops"))) do
			local sg = entityNum(core.field(s, "stationGroup"))
			local name = sg and try(function() return api.engine.util.getEntityName(sg) end)
			stops[#stops + 1] = { stopIndex = i - 1, stationGroup = sg, name = type(name) == "string" and name or nil,
				waiting = core.qualityOf(try(function() return api.engine.util.cargo.getCargoQualityDataAtStop(line, i - 1, pax) end)),
				stationGroupWaiting = sg and core.qualityOf(try(function()
					return api.engine.util.cargo.getCargoQualityDataAtStationGroup(sg, pax)
				end)) or nil }
		end
		out.stops = core.array(stops)
		return out
	end

	-- args: vehicle (the company's) or line (the company's), limit. Read only. A vehicle that is gone or not the
	-- company's is answered with missing = true and no persons (not an error), so a poll sees a ship sold.
	function handlers.persons(c)
		local a, err = core.personsArgs(c.args)
		if not a then return fail(c.id, err) end
		local now = gameTime()
		local pax = passengerCargo()
		local res = { ok = true, gameTime = now, vehicle = a.vehicle, line = a.line, unhappyBelow = core.UNHAPPY_BELOW }
		local ids
		if a.vehicle then
			-- only the company's vehicles reach a lookup (an unknown id may be the engine's assertion)
			if not ownVehicles()[a.vehicle] then
				res.missing, res.total, res.persons = true, 0, core.array({})
				res.summary = core.personSummary({})
				res.summary.of, res.summary.total = 0, 0
				return answer(c.id, res)
			end
			local tv = vehicleComponent(a.vehicle)
			res.line = entityNum(tv and core.field(tv, "line"))
			-- where the vehicle is in the same answer, so a sample tells at sea from in port without a second call
			-- (the full set is vehicles --state)
			local stateEnum = try(function() return api.type.enum.TransportVehicleState end)
			res.vehicleState = { state = stateEnum and core.enumName(stateEnum, VEHICLE_STATES, core.field(tv, "state")) or nil,
				stopIndex = tonumber(core.field(tv, "stopIndex")),
				speed = tonumber(try(function() return api.engine.util.vehicle.getSpeed(a.vehicle) end)) }
			local map = try(function() return api.engine.system.simEntityAtVehicleSystem.getVehicle2Cargo2SimEntitesMap() end)
			if map == nil then
				res.personsError = "simEntityAtVehicleSystem.getVehicle2Cargo2SimEntitesMap gave nothing"
			end
			-- a vehicle with nobody aboard has no entry in the map (the base reads that as no passengers)
			local byCargo = map ~= nil and core.field(map, a.vehicle) or nil
			ids = core.toList(byCargo ~= nil and core.at(byCargo, pax + 1) or nil)
			res.quality = { vehicle = core.qualityOf(try(function()
				return api.engine.util.cargo.getCargoQualityDataForVehicle(a.vehicle, pax)
			end)) }
		else
			local own = false
			for _, l in ipairs(core.toList(try(function() return api.engine.system.lineSystem.getLinesForPlayer(player()) end))) do
				if tonumber(l) == a.line then own = true end
			end
			if not own then return fail(c.id, "line " .. a.line .. " is not one of the company's lines (the lines command lists them)") end
			ids = core.toList(try(function() return api.engine.system.simPersonSystem.getSimPersonsForLine(a.line) end))
			res.quality = {}
		end
		-- by id: the engine's order is not documented, and with more than limit the same ones should be listed
		-- each time
		local sorted = {}
		for _, e in ipairs(ids) do sorted[#sorted + 1] = tonumber(e) end
		table.sort(sorted)
		ids = sorted
		local out = {}
		for i = 1, math.min(#ids, a.limit) do
			local e = tonumber(ids[i])
			if e then out[#out + 1] = personInfo(e, now) end
		end
		res.total, res.persons = #ids, core.array(out)
		res.summary = core.personSummary(out)
		-- the summary is over the listed ones only: of says how many, total how many there are (--limit 2000 for all)
		res.summary.of, res.summary.total = #out, #ids
		if res.line then
			local lq = lineQuality(res.line, pax)
			res.quality.line, res.quality.stops = lq.line, lq.stops
		end
		answer(c.id, res)
	end

	V.handlers = handlers
	return V
end

return M
