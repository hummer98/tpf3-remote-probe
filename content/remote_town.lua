-- town: one town put on the map at a point, with a name, a size and its first cargo needs (core.townRequest has the
-- arguments, town_work.lua the engine's part). For maps made for tests, in the map editor (newgame --editor) or a
-- new test game (inGame): every use seen (the base editor, Advanced Town Placement, Real World Map Importer) is in
-- the map editor.
--
-- Only in the map editor (api.gui.game.isMapEditor()), unless inGame is given. A dry run sends nothing: in the
-- editor or with inGame it shows createTowns' proposal (initialLandUseCapacities for the place), elsewhere only the
-- request and the needs.
--
-- Two ways (via), as terrain: "gui" (and auto, the default) hands the request to the speed control's recipe (its
-- join, where the base editor calls these from react) through the GUI save data; "update" runs town_work in this
-- guiUpdate state, only when asked for.
--
-- After the engine's callback: the new town is the one town id not there before (by name when there are several),
-- and its first needs are read back from its TOWN component. Where they are not what was asked (a town made by a
-- script may get none from landUse2CargoNeeds: RWMI's note), makeTownUpdateCargoNeedsCmd is sent from here with
-- the cargo type ids, as RWMI and the base town window's cargo editor do, and read back again.
--
-- Not checked in a game yet (written 2026-11-22): the answer says so.
local M = {}

local RESULT_SEC = 60 -- for the create command's callback
local PICKUP_SEC = 20 -- for the recipe to report on a gui request (it reads every 0.5 s while a game is on screen)
local NEEDS_SEC = 10 -- for the needs command's callback
local SETTLE_FRAMES = 3 -- after a callback, before the town is looked at

local NOTE = "not checked in a game yet: look at the town (entities --kind town, frame) before trusting it; its "
	.. "buildings come over the next game days, so population starts low"

-- ctx: core, work (town_work.lua), answer(id, payload, tag), fail(id, msg), appTime(), try(fn), say(msg, level),
-- publishUi(fields), towns() -> { { id, name } }, posOf(e) -> { x, y } or nil, mod
function M.new(ctx)
	local core, work, answer, fail, appTime, try, say = ctx.core, ctx.work, ctx.answer, ctx.fail, ctx.appTime, ctx.try, ctx.say
	local publishUi = ctx.publishUi or function() end
	local REPORT_KEY = (ctx.mod or core.MOD_ID) .. ".town"
	local jobs = {}
	local requests = {} -- [id] = the gui request

	local function mapEditor()
		local v = try(function() return api.gui.game.isMapEditor() end)
		if v == true or v == false then return v end
		return nil
	end
	local function towns() return ctx.towns and ctx.towns() or {} end

	local function publishRequests()
		local list = {}
		for _, r in pairs(requests) do list[#list + 1] = r end
		table.sort(list, function(a, b) return a.id < b.id end)
		publishUi({ town = list })
	end
	local function reportOf(id)
		local d = try(function() return api.gui.game.getGuiSaveData(REPORT_KEY) end)
		if type(d) ~= "table" or type(d.reports) ~= "table" then return nil end
		for _, r in ipairs(d.reports) do
			if type(r) == "table" and tonumber(r.id) == id then return core.plain(r) end
		end
		return nil
	end
	local function retire(job)
		if requests[job.id] then
			requests[job.id] = nil
			publishRequests()
		end
	end

	-- the new town: the ids not there before the command (by name when more than one), else from the callback's
	local function findNew(job)
		local fresh, named = {}, {}
		for _, t in ipairs(towns()) do
			if not job.before[t.id] then
				fresh[#fresh + 1] = t
				if t.name == job.r.name then named[#named + 1] = t end
			end
		end
		if #fresh == 1 then return fresh[1] end
		if #named == 1 then return named[1] end
		for _, e in ipairs(job.report and job.report.entities or {}) do
			for _, t in ipairs(fresh) do if t.id == e then return t end end
		end
		return nil, #fresh
	end

	local function needsOf(e)
		local t = try(function() return api.engine.getComponent(e, api.type.ComponentType.TOWN) end)
		if t == nil then return nil end
		return core.townNeedIds(core.field(t, "cargoNeeds"))
	end

	local function populationOf(e)
		local LU = try(function() return api.type.enum.LandUseType end)
		local function luIdx(k, d) local v = tonumber(LU and core.field(LU, k)) return v and v + 1 or d end
		local idx = { residential = luIdx("RESIDENTIAL", 1), commercial = luIdx("COMMERCIAL", 2), industrial = luIdx("INDUSTRIAL", 3) }
		local caps = try(function() return api.engine.system.townBuildingSystem.getTown2personCapacitiesMap() end)
		local c = caps ~= nil and core.field(caps, e) or nil
		local list = c ~= nil and core.toList(c) or nil
		return core.townPopulation(c, idx), list and #list > 0 and list or nil
	end

	-- the work's warnings (from the report) and this side's
	local function allWarnings(job)
		local out = {}
		for _, w in ipairs(job.report and job.report.warnings or {}) do out[#out + 1] = tostring(w) end
		for _, w in ipairs(job.warnings or {}) do out[#out + 1] = w end
		return #out > 0 and out or nil
	end

	local function payload(job)
		local r, rep = job.r, job.report or {}
		return { ok = true, cmd = "town", via = job.via, dryRun = r.dryRun or nil, inGame = r.inGame or nil,
			mapEditor = mapEditor(), at = r.at, name = r.name, size = r.size, capacity = r.capacity,
			needsAsked = r.needs,
			needs = rep.needs, needIds = rep.needIds, functionsUpdate = job.here,
			functionsGui = job.via == "gui" and rep.functions or nil,
			proposal = rep.proposal, proposalNote = rep.proposalNote,
			toRemoveIgnored = rep.toRemove and rep.toRemove > 0 and rep.toRemove or nil,
			sent = rep.sent, success = rep.success, entity = job.town and job.town.id or nil,
			townName = job.town and job.town.name or nil, position = job.position,
			population = job.population, personCapacities = job.capacities,
			needsRead = job.needsRead, needsSet = job.needsSet, needsMet = job.needsMet,
			warnings = allWarnings(job) and core.array(allWarnings(job)) or nil, note = NOTE }
	end

	local function warn(job, msg)
		job.warnings = job.warnings or {}
		job.warnings[#job.warnings + 1] = msg
	end

	local function finish(job)
		retire(job)
		local out = payload(job)
		if out.sent and out.success ~= true then
			out.ok = false
			out.error = "the engine refused the town (its callback said no success)"
			say("town (command " .. job.id .. "): refused", 1)
			return answer(job.id, out, "error")
		end
		answer(job.id, out)
	end

	local function failJob(job, msg)
		retire(job)
		local out = payload(job)
		out.ok, out.error = false, msg
		answer(job.id, out, "error")
	end

	local T = {}

	function T.handle(c)
		local r, err = core.townRequest(c.args)
		if not r then return fail(c.id, err) end
		local editor = mapEditor()
		local job = { id = c.id, r = r, started = appTime(), before = {} }
		job.here = work.functions()
		if not r.dryRun and not r.inGame and editor ~= true then
			job.via = "none"
			return failJob(job, "not the map editor (api.gui.game.isMapEditor() is " .. tostring(editor)
				.. "): whether a town can be made this way in a game is not known. In a new test game give inGame (--in-game)")
		end
		for _, t in ipairs(towns()) do job.before[t.id] = true end
		local propose = editor == true or r.inGame
		local via = r.via == "auto" and "gui" or r.via
		job.via = via
		if via == "update" then
			local _, missing = work.functions()
			if #missing > 0 then return failJob(job, "via update: missing in the guiUpdate state: " .. table.concat(missing, ", ")) end
			job.report = {}
			local ok, werr = pcall(work.work, r, job.report, propose)
			if not ok then return failJob(job, "via update: " .. tostring(werr)) end
			job.report.done = true
			jobs[#jobs + 1] = job
			return
		end
		requests[c.id] = { id = c.id, kind = "apply", args = core.plain(c.args), propose = propose }
		publishRequests()
		jobs[#jobs + 1] = job
	end

	-- after the create callback: the town found, its needs checked (and sent once when not met), then the answer
	local function stepAfter(job)
		job.settle = (job.settle or 0) + 1
		if job.settle <= SETTLE_FRAMES then return false end
		if job.phase == nil then
			local t, n = findNew(job)
			if not t then
				-- the command said success, but no town to answer with: an error, so a test script notices
				failJob(job, string.format("the engine said success, but the new town was not found (%d town ids new "
					.. "since the command): look at entities --kind town", n or 0))
				return true
			end
			job.town = t
			job.position = ctx.posOf and ctx.posOf(t.id) or nil
			local want = core.townIntIds(job.report.needIds)
			job.needsRead = needsOf(t.id)
			job.needsMet = job.needsRead ~= nil and core.townNeedsMet(job.needsRead, want)
			local any = #want[1] + #want[2] + #want[3] > 0
			if job.needsMet or not any then
				job.needsSet = any and "not needed: the town has them" or "none asked"
				job.phase = "done"
			else
				-- as RWMI: cargo type ids per district, every building updated
				local ok, serr = pcall(function()
					api.cmd.sendCommand(api.cmd.makeTownUpdateCargoNeedsCmd(t.id, want, true), function(_, success)
						job.needsResult = success == true
					end)
				end)
				if not ok then
					job.needsSet = "not sent: " .. tostring(serr)
					warn(job, "the town's first needs are not set: " .. job.needsSet)
					job.phase = "done"
				else
					job.phase, job.needsStarted = "needs", appTime()
				end
			end
		end
		if job.phase == "needs" then
			if job.needsResult == nil then
				if appTime() - job.needsStarted > NEEDS_SEC then
					job.needsSet = string.format("no answer in %d s", NEEDS_SEC)
					warn(job, "the town's first needs: " .. job.needsSet)
					job.phase = "done"
				else
					return false
				end
			else
				job.needsSet = job.needsResult and "sent (makeTownUpdateCargoNeedsCmd)" or "refused (makeTownUpdateCargoNeedsCmd)"
				job.phase, job.settle = "readNeeds", 0
				return false
			end
		end
		if job.phase == "readNeeds" then
			job.needsRead = needsOf(job.town.id)
			job.needsMet = job.needsRead ~= nil and core.townNeedsMet(job.needsRead, core.townIntIds(job.report.needIds))
			if not job.needsMet then warn(job, "the town's needs read back are not those asked (needsRead, needIds)") end
			job.phase = "done"
		end
		job.population, job.capacities = populationOf(job.town.id)
		finish(job)
		return true
	end

	local function stepJob(job)
		if job.via == "gui" and not job.picked then
			local rep = reportOf(job.id)
			if rep then
				job.report, job.picked = rep, true
				if rep.error ~= nil then failJob(job, "via gui: " .. tostring(rep.error)); return true end
			elseif appTime() - job.started > PICKUP_SEC then
				failJob(job, string.format("via gui: the speed control's recipe did not take it up in %d s (is a game on screen?)", PICKUP_SEC))
				return true
			else
				return false
			end
		elseif job.via == "gui" then
			-- the callback's result arrives in a later report
			local rep = reportOf(job.id)
			if rep then job.report = rep end
		end
		local rep = job.report
		if rep.done and not rep.sent then finish(job); return true end
		if rep.success == false then finish(job); return true end
		if rep.success == true then return stepAfter(job) end
		if appTime() - job.started > RESULT_SEC then
			failJob(job, string.format("no answer from the engine in %d s (look at the map: entities --kind town)", RESULT_SEC))
			return true
		end
		return false
	end

	function T.step()
		if #jobs == 0 then return end
		local keep = {}
		for _, job in ipairs(jobs) do
			local ok, done = pcall(stepJob, job)
			if not ok then
				retire(job)
				fail(job.id, done)
			elseif not done then
				keep[#keep + 1] = job
			end
		end
		jobs = keep
	end

	-- a new game: no job of the old one answers into it; the recipe's old reports are cleared
	function T.reset()
		jobs, requests = {}, {}
		pcall(function() api.gui.game.setGuiSaveData(REPORT_KEY, { reports = {} }) end)
	end

	return T
end

return M
