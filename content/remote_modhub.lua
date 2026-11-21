-- My Mods from the main menu for the remote probe (modhubStatus, modhubValidate): the base's MOD hub > My Mods
-- page lists the staging area (<user data>/staging_area/<folder>) and validates and uploads its mods through one
-- C++ object, api.type.modhub.ModPublishHelper (mod_manager_page.tl makes it, mod_manager_react_util.tl calls its
-- methods; no event is fired). This file makes its own one and uses only the reading part of it: the staging
-- mods with their state and what mod.io holds of them, and validate, as the page's Re-Validate button.
--
-- Publishing is not here, and nothing calls publish, abortPublish, setRemoteModId, refreshMod or any setter:
-- an upload can make a second mod page or a public mod, neither undone from the game, so it waits for a person.
--
-- Only in the main menu (startup.lua). ModPublishHelper.new is marked "privileged api, not available to mods"
-- (type/modhub.d.tl); the menu probe was seen reading the equally marked api.modhub functions (one launch,
-- 2026-11-21), so it is expected to work there, but making the helper was never tried in game. When it fails,
-- the error is answered as the game gave it, and validate stops there.
--
-- Making the helper syncs every staging mod with mod.io (StagingModData.state is Sync meanwhile): read requests
-- to mod.io, no writes. The base page makes another helper of its own when a person opens My Mods; the two are
-- not meant to work on the same mod at once, so this is for the menu with nobody at it.
local M = {}

M.READY_SEC = 30 -- s validate waits for mod.io to be ready before it gives up
M.SYNC_SEC = 60 -- s validate waits for its mod to leave Sync
M.FRESH_SEC = 5 -- s without seeing validating: a result that was there before is taken as this run's

function M.new(ctx)
	local core, answer, fail, appTime, try, say = ctx.core, ctx.answer, ctx.fail, ctx.appTime, ctx.try, ctx.say
	local PROGRESS_SEC = ctx.progressSec or 15
	local H = { frames = 0 } -- helper, helperError, job
	local handlers = {}

	local function stateName(s)
		local S = try(function() return api.type.modhub.StagingModData.State end)
		if S == nil then return s ~= nil and tostring(s) or nil end
		return core.enumName(S, core.MODHUB_STATES, s)
	end

	-- LogLevel as the base page reads it (api.type["enum"].LogLevel)
	local function levelName(l)
		local L = try(function() return api.type.enum.LogLevel end)
		if L == nil then return l ~= nil and tostring(l) or nil end
		return core.enumName(L, core.LOG_LEVELS, l)
	end

	local function str(v) return type(v) == "string" and v or nil end
	local function bool(v) if type(v) == "boolean" then return v end return nil end
	local function num(v) return type(v) == "number" and v or nil end

	-- the backends: publish is the one that is not info-only (the base's getModPublishBackendId, which also
	-- complains of a second one); staging is the "StagingArea" source's, else the info-only one (the backend of
	-- the page's My Mods tab)
	local function backends()
		local out = {}
		local ids = try(function() return api.modhub.getBackendIDs() end)
		if ids == nil then return nil, "api.modhub cannot be read here" end
		for _, b in ipairs(core.toList(ids)) do
			local caps = try(function() return api.modhub.getCapabilities(b) end)
			if caps ~= nil then
				if not core.field(caps, "isInfoOnly") then
					if out.publish == nil then out.publish = b else out.morePublish = true end
				elseif out.infoOnly == nil then
					out.infoOnly = b
				end
			end
		end
		out.staging = try(function() return api.modhub.getBackendIdForSource("StagingArea") end)
		out.stagingFrom = "getBackendIdForSource"
		if out.staging == nil then out.staging, out.stagingFrom = out.infoOnly, "infoOnly" end
		return out
	end

	-- mod.io's state as the base menu tests it (isBusyWithModManagement, isRestrictedModeAllowed), and whether
	-- someone is logged in (true / false only: no names). notReady: why the helper should not be made yet.
	local function readiness(b)
		local r = {}
		if b == nil then return r, "no mod.io backend (no backend that is not info-only)" end
		local caps = try(function() return api.modhub.getCapabilities(b) end)
		r.allowModUpload = bool(core.field(caps, "allowModUpload"))
		r.allowRestrictedMode = bool(core.field(caps, "allowRestrictedMode"))
		r.initialized = bool(try(function() return api.modhub.isInitialized(b) end))
		local st = try(function() return api.modhub.getModManagementState(b) end)
		if st ~= nil then
			r.management = { busy = bool(core.field(st, "busy")), uploading = bool(core.field(st, "uploading")),
				totalPending = num(core.field(st, "totalPending")), progress = num(core.field(st, "progress")) }
		end
		local user = try(function() return api.modhub.getUserInfo(b) end)
		r.loggedIn = user ~= nil
		if r.initialized == false then return r, "mod.io is not initialized yet" end
		if r.allowRestrictedMode == false then
			return r, "mod.io has not finished its start-up check yet (restricted mode not allowed)"
		end
		if r.management and (r.management.busy or r.management.uploading) then
			return r, "mod.io is busy" .. (r.management.uploading and " uploading" or "") .. " ("
				.. tostring(r.management.totalPending or "?") .. " pending)"
		end
		if st == nil then return r, "mod.io's management state cannot be read" end
		return r, nil
	end

	-- made once per menu probe; a failure is kept (the same call would fail the same way) and answered as is
	local function helper(publish)
		if H.helper then return H.helper end
		if H.helperError then return nil, H.helperError end
		if publish == nil then return nil, "no mod.io backend to make the helper for" end
		local ok, h = pcall(function() return api.type.modhub.ModPublishHelper.new(publish) end)
		if ok and h ~= nil then
			H.helper = h
			say("made My Mods' publish helper (ModPublishHelper.new) in the main menu")
			return h
		end
		H.helperError = ok and "ModPublishHelper.new returned nothing" or tostring(h)
		say("ModPublishHelper.new failed: " .. H.helperError)
		return nil, H.helperError
	end

	local function details(d)
		if d == nil then return nil end
		local info = core.field(d, "modInfo")
		local rel = core.field(info, "releaseInfo")
		return { found = bool(core.field(d, "found")), visible = bool(core.field(info, "visible")),
			title = str(core.field(info, "title")), modId = str(core.field(core.field(info, "modId"), "value")),
			version = str(core.field(rel, "version")),
			updatedUnixTimestamp = num(core.field(info, "updatedUnixTimestamp")),
			publishedUnixTimestamp = num(core.field(info, "publishedUnixTimestamp")) }
	end

	local function readResult(res)
		if res == nil then return nil end
		local msgs = {}
		for _, m in ipairs(core.toList(core.field(res, "messages"))) do
			msgs[#msgs + 1] = { level = levelName(core.field(m, "level")), file = str(core.field(m, "file")),
				message = str(core.field(m, "message")), context = str(core.field(m, "context")),
				consoleOnly = bool(core.field(m, "consoleOnly")) }
		end
		return { messages = msgs, criticalPc = bool(core.field(res, "criticalPc")),
			criticalConsole = bool(core.field(res, "criticalConsole")), levelPc = levelName(core.field(res, "levelPc")),
			levelConsole = levelName(core.field(res, "levelConsole")) }
	end

	local function validation(h, id, limit)
		local v = try(function() return h:getValidationData(id) end)
		if v == nil then return nil end
		local out = { validating = bool(core.field(v, "validating")), progress = num(core.field(v, "progress")),
			task = str(core.field(v, "task")) }
		local res = core.field(v, "result")
		out.hasResult = res ~= nil
		if res ~= nil and limit then out.result = core.validationSummary(readResult(res), limit) end
		return out, res
	end

	-- the staging mods: their ids from the staging backend, matched to the helper by that id (as the base page
	-- passes modInfo.modId of its My Mods tab)
	local function stagingIds(b)
		if b.staging == nil then return {}, "no staging backend" end
		local ids = try(function() return api.modhub.getInstalledMods(b.staging) end)
		if ids == nil then return {}, "api.modhub.getInstalledMods cannot be read for the staging backend" end
		return core.toList(ids)
	end

	local function readMod(h, b, id, limit)
		local value = str(core.field(id, "value"))
		local e = { value = value, folder = core.stagingFolder(value) }
		e.validateAllowed = e.folder ~= nil and core.MODHUB_VALIDATE_FOLDERS[e.folder] == true
		local info = try(function() return api.modhub.getModInfoForInstalledMod(b.staging, id) end)
		e.title = str(core.field(info, "title"))
		e.listVisible = bool(core.field(info, "visible")) -- the local mod's own visible (mod.json), not mod.io's
		if not h then return e end
		e.inHelper = bool(try(function() return h:hasStagingMod(id) end))
		if not e.inHelper then return e end
		local d = try(function() return h:getStagingModData(id) end)
		if d == nil then e.error = "getStagingModData cannot be read"; return e end
		e.state = stateName(core.field(d, "state"))
		local mid = core.field(d, "modhubId")
		e.modhubId = { valid = bool(try(function() return mid:isValid() end)), value = str(core.field(mid, "value")) }
		e.modhubDetails = details(core.field(d, "modhubDetails"))
		e.hasModhubDetails = e.modhubDetails ~= nil
		e.localModhubDetails = details(core.field(d, "localModhubDetails"))
		-- what the page would say (mod_manager_react_util.tl ModUploadForm): new, update, or deleted on mod.io
		if e.state ~= "Sync" then
			e.upload = (not e.modhubId.valid) and "new" or (e.hasModhubDetails and "update" or "remoteMissing")
		end
		e.validation = validation(h, id, limit)
		return e
	end

	local function findId(b, folder)
		local ids, err = stagingIds(b)
		local seen = {}
		for _, id in ipairs(ids) do
			local f = core.stagingFolder(str(core.field(id, "value")))
			if f == folder then return id end
			seen[#seen + 1] = tostring(f)
		end
		return nil, err or ("no staging mod in folder " .. folder .. " (the staging area has: "
			.. (#seen > 0 and table.concat(seen, ", ") or "none") .. ")")
	end

	local function busyError()
		local j = H.job
		return "command " .. j.id .. " (" .. j.cmd .. ") is still running; try again when it has answered"
	end

	---------------------------------------------------------------------------------------------------------------
	-- status: privileged or not, the helper, the backends, mod.io's state, and every staging mod (or one)

	local function statusAnswer(job, timedOut)
		local b = job.b or {}
		local r, notReady = readiness(b.publish)
		local out = { ok = H.helper ~= nil, privileged = bool(try(function() return api.util.hasPrivilegedApis() end)),
			helper = H.helper ~= nil, helperError = H.helperError, backends = { publish = b.publish, staging = b.staging,
				stagingFrom = b.stagingFrom, infoOnly = b.infoOnly, morePublish = b.morePublish },
			modio = r, notReady = notReady, seconds = appTime() - job.started, timedOut = timedOut }
		if H.helper then out.anyStagingMods = bool(try(function() return H.helper:hasAnyStagingMods() end)) end
		local ids, err = stagingIds(b)
		out.stagingError = err
		local mods = {}
		for _, id in ipairs(ids) do
			local e = readMod(H.helper, b, id, 0)
			if job.args.folder == nil or e.folder == job.args.folder then mods[#mods + 1] = e end
		end
		out.mods = core.array(mods)
		if job.args.folder and #mods == 0 then out.ok, out.error = false, "no staging mod in folder " .. job.args.folder end
		if not H.helper then
			out.error = out.error or (H.helperError and ("ModPublishHelper.new failed: " .. H.helperError))
				or ("no helper yet: " .. tostring(notReady or "mod.io not ready"))
		end
		return out
	end

	local function anySyncing(b)
		for _, id in ipairs((stagingIds(b))) do
			local d = try(function() return H.helper:getStagingModData(id) end)
			if d ~= nil and stateName(core.field(d, "state")) == "Sync" then return true end
		end
		return false
	end

	local function finishStatus(job, timedOut)
		H.job = nil
		local out = statusAnswer(job, timedOut)
		if out.ok then answer(job.id, out) else answer(job.id, out, "error") end
	end

	local function stepStatus(job)
		local over = appTime() - job.started >= job.args.wait
		if not H.helper and not H.helperError then
			local _, notReady = readiness(job.b.publish)
			if notReady and not over then return end
			if notReady then return finishStatus(job, "waiting for mod.io") end
			helper(job.b.publish)
		end
		if H.helper and anySyncing(job.b) and not over then return end
		finishStatus(job, (H.helper and anySyncing(job.b)) and "waiting for the staging mods' sync with mod.io" or nil)
	end

	function handlers.modhubStatus(c)
		local args, err = core.modhubStatusArgs(c.args)
		if not args then return fail(c.id, err) end
		if H.job then return fail(c.id, busyError()) end
		local b, berr = backends()
		if not b then return fail(c.id, berr) end
		H.job = { id = c.id, cmd = c.cmd, args = args, b = b, started = appTime() }
		stepStatus(H.job)
	end

	---------------------------------------------------------------------------------------------------------------
	-- validate: one staging mod, through the helper's validate, polled with update() as the page does

	local function payload(job)
		return { folder = job.args.folder, value = job.value, phase = job.phase, seconds = appTime() - job.started }
	end

	local function endJob(job, out, err)
		H.job = nil
		if err then
			out.ok, out.error = false, err
			answer(job.id, out, "error")
		else
			out.ok = true
			answer(job.id, out)
		end
	end

	local function stepValidate(job)
		local t = appTime() - job.started
		if job.phase == "ready" then
			local _, notReady = readiness(job.b.publish)
			if notReady then
				if t < M.READY_SEC then return end
				return endJob(job, payload(job), notReady .. " after " .. M.READY_SEC .. " s; try again later")
			end
			local h, herr = helper(job.b.publish)
			if not h then return endJob(job, payload(job), "ModPublishHelper.new failed: " .. tostring(herr)) end
			local id, ferr = findId(job.b, job.args.folder)
			if not id then return endJob(job, payload(job), ferr) end
			job.mid, job.value = id, str(core.field(id, "value"))
			if not try(function() return h:hasStagingMod(id) end) then
				return endJob(job, payload(job), "the publish helper does not know staging mod " .. job.args.folder)
			end
			job.phase, job.syncSince = "sync", appTime()
		end
		if job.phase == "sync" then
			local d = try(function() return H.helper:getStagingModData(job.mid) end)
			local s = stateName(core.field(d, "state"))
			if s == "Sync" or s == nil then
				if appTime() - job.syncSince < M.SYNC_SEC then return end
				return endJob(job, payload(job), "the staging mod is still " .. tostring(s or "unreadable") .. " after "
					.. M.SYNC_SEC .. " s (its sync with mod.io)")
			end
			if s ~= "Ready" then
				-- Publishing / HasResult: an upload (by a person on the My Mods page) owns the mod now; this
				-- never touches one
				return endJob(job, payload(job), "the staging mod is " .. s .. ", not Ready: an upload has it; not validated")
			end
			local _, before = validation(H.helper, job.mid, nil)
			job.before = before
			local ok, err = pcall(function() H.helper:validate(job.mid) end)
			if not ok then return endJob(job, payload(job), "validate failed: " .. tostring(err)) end
			say("validating staging mod " .. job.args.folder .. " for command " .. job.id, 2)
			job.phase, job.validateSince = "validating", appTime()
		end
		if job.phase == "validating" then
			if appTime() - job.started > job.args.timeout then
				-- a validation only: aborting it is what the page does when it closes (abortValidation)
				pcall(function() H.helper:abortValidation(job.mid) end)
				local out = payload(job)
				out.validation = validation(H.helper, job.mid, nil)
				return endJob(job, out, "timed out after " .. job.args.timeout .. " s; the validation was aborted")
			end
			local v, res = validation(H.helper, job.mid, nil)
			if v and v.validating then job.sawValidating = true end
			local done = v and not v.validating and res ~= nil
				and (job.sawValidating or job.before == nil or res ~= job.before
					or appTime() - job.validateSince >= M.FRESH_SEC)
			if done then
				local out = payload(job)
				out.result = core.validationSummary(readResult(res), job.args.messages)
				if not job.sawValidating and job.before ~= nil then
					out.note = "validating was never seen true: this may be the result from before"
				end
				local d = try(function() return H.helper:getStagingModData(job.mid) end)
				out.state = stateName(core.field(d, "state"))
				return endJob(job, out)
			end
			if appTime() >= job.nextProgress then
				job.nextProgress = appTime() + PROGRESS_SEC
				job.progressN = job.progressN + 1
				local out = payload(job)
				out.ok, out.running = true, true
				out.progress, out.task = v and v.progress, v and v.task
				answer(job.id, out, "p" .. job.progressN)
			end
		end
	end

	function handlers.modhubValidate(c)
		local args, err = core.modhubValidateArgs(c.args)
		if not args then return fail(c.id, err) end
		if H.job then return fail(c.id, busyError()) end
		if H.helperError then return fail(c.id, "ModPublishHelper.new failed: " .. H.helperError) end
		local b, berr = backends()
		if not b then return fail(c.id, berr) end
		H.job = { id = c.id, cmd = c.cmd, args = args, b = b, started = appTime(), phase = "ready",
			nextProgress = appTime() + PROGRESS_SEC, progressN = 0 }
		stepValidate(H.job)
	end

	---------------------------------------------------------------------------------------------------------------

	-- every frame in the main menu: the helper's update (the page calls it every frame it is open; the type says
	-- it must be called while a validation runs), then the job. An error ends the job, not the probe's frame.
	function H.step()
		H.frames = H.frames + 1
		if H.helper then
			local ok, err = pcall(function() H.helper:update() end)
			if not ok and not H.updateWarned then
				H.updateWarned = true
				say("the publish helper's update failed: " .. tostring(err))
			end
		end
		local job = H.job
		if not job then return end
		local ok, err = pcall(job.cmd == "modhubStatus" and stepStatus or stepValidate, job)
		if not ok and H.job == job then
			H.job = nil
			fail(job.id, err)
		end
	end

	-- a load, new game or quit ends the menu: a running validation is aborted and its command answered
	function H.cancel(reason)
		local job = H.job
		if not job then return end
		if job.phase == "validating" then pcall(function() H.helper:abortValidation(job.mid) end) end
		endJob(job, payload(job), "cancelled by " .. reason)
	end

	H.handlers = handlers
	return H
end

return M
