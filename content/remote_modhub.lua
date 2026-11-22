-- My Mods from the main menu for the remote probe (modhubStatus, modhubValidate, modhubPublish): the base's MOD hub >
-- My Mods page lists the staging area (<user data>/staging_area/<folder>) and validates and uploads its mods
-- through one C++ object, api.type.modhub.ModPublishHelper (mod_manager_page.tl makes it,
-- mod_manager_react_util.tl calls its methods; no event is fired). This file makes its own one: it reads the
-- staging mods with their state and what mod.io holds of them, validates as the page's Re-Validate button, and
-- uploads one mod as the page's Upload / Update button (ModUploadForm): a new mod, or an update of one already on
-- mod.io. Both are the same call (ModPublishHelper.publish); the page only names the button "Update" when mod.io
-- holds details of the mod (mod_manager_react_util.tl 1813).
--
-- The upload is the only thing here that writes to mod.io, and it is kept to one place in this file (between the
-- "publish path" markers; tests/run.lua checks that no other code names publish, abortPublish or PublishSettings).
-- Nothing calls setRemoteModId, refreshMod or any setter. An upload can make a second mod page or a public mod,
-- neither undone from the game, so publish takes one allowed folder, says every time which of the two it is (a
-- first upload: the mod has no mod.io id and mod.io holds nothing of it; an update: the mod's mod.io id is the one
-- the tool read from _metadata/mod.io_fileid.txt and mod.io holds that mod), a visibility given every time, a
-- validation without issues, and one upload per launch. tools/tf3ctl.py adds the checks Lua cannot make (no io
-- here): the fileid file there or not, the revision, a cover image, and its own mark on disk written before it
-- sends the command.
--
-- Only in the main menu (startup.lua). ModPublishHelper.new is marked "privileged api, not available to mods"
-- (type/modhub.d.tl); it was made there in game (2026-11-22), validate worked, and a first upload went up
-- (mod.io 6543965). An update was not tried in game yet.
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
	local H = { frames = 0 } -- helper, helperError, job, published (the upload of this launch)
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

	local function errorCode(e)
		if e == nil then return nil end
		return { code = num(core.field(e, "code")), debugMessage = str(core.field(e, "debugMessage")),
			localizedMessage = str(core.field(e, "localizedMessage")) }
	end

	-- StagingModData.publishResult once the state is HasResult, read as the base page does (ModUploadForm,
	-- mod_manager_react_util.tl 1421-1446): isSuccess; then the data (the mod.io id, partialErrors) on success,
	-- the error on failure. Each read on its own, so one that raises leaves the others.
	local function publishResult(d)
		local res = core.field(d, "publishResult")
		if res == nil then return nil end
		local out = { success = bool(try(function() return res:isSuccess() end)) }
		if out.success == true then
			local data = try(function() return res:getData() end)
			out.modId = str(core.field(core.field(data, "modId"), "value"))
			local partial = {}
			for _, pe in ipairs(core.toList(core.field(data, "partialErrors"))) do
				partial[#partial + 1] = { step = str(core.field(pe, "step")), error = errorCode(core.field(pe, "error")) }
			end
			out.partialErrors = core.array(partial)
		elseif out.success == false then
			out.error = errorCode(try(function() return res:getError() end))
		end
		return out
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
		if e.state == "HasResult" then e.publishResult = publishResult(d) end
		local logo = core.field(core.field(core.field(d, "localModhubDetails"), "modInfo"), "logoImage")
		if type(logo) == "string" then e.hasLogo = logo ~= "" end
		return e
	end

	-- the first id of that folder the helper knows, else the first of that folder: when the staging backend is
	-- the info-only one, it may also list a mod of the same folder name elsewhere (not seen; a guess)
	local function findId(b, folder)
		local ids, err = stagingIds(b)
		local seen, first = {}, nil
		for _, id in ipairs(ids) do
			local f = core.stagingFolder(str(core.field(id, "value")))
			if f == folder then
				if H.helper and try(function() return H.helper:hasStagingMod(id) end) then return id end
				first = first or id
			end
			seen[#seen + 1] = tostring(f)
		end
		if first then return first end
		return nil, err or ("no staging mod in folder " .. folder .. " (the staging area has: "
			.. (#seen > 0 and table.concat(seen, ", ") or "none") .. ")")
	end

	local function busyError()
		local j = H.job
		return "command " .. j.id .. " (" .. j.cmd .. ") is still running; try again when it has answered"
	end

	-- one step of a job, the first (from its handler) as every later one (H.step): an error ends the job and
	-- answers it. Without this a first step that raised left H.job behind, answered later a second time.
	local function runStep(job, step)
		local ok, err = pcall(step, job)
		if not ok and H.job == job then
			H.job = nil
			fail(job.id, err)
		end
	end

	local function startJob(job, step)
		H.job = job
		runStep(job, step)
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
		if H.published then
			out.publishedThisLaunch = { id = H.published.id, folder = H.published.folder, outcome = H.published.outcome }
		end
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

	-- a mod the helper does not know yet counts as in Sync, as the base page takes it (ModUploadForm: no
	-- hasStagingMod, state Sync); getStagingModData only after hasStagingMod, as the base always asks first (for a
	-- mod it does not have, the engine may assert rather than raise). With a folder, only that folder's mods: another
	-- mod's sync may take minutes (120 s and more in game, 2026-11-22) and says nothing about this one.
	local function anySyncing(b, folder)
		for _, id in ipairs((stagingIds(b))) do
			if folder == nil or core.stagingFolder(str(core.field(id, "value"))) == folder then
				if not try(function() return H.helper:hasStagingMod(id) end) then return true end
				local d = try(function() return H.helper:getStagingModData(id) end)
				if d ~= nil and stateName(core.field(d, "state")) == "Sync" then return true end
			end
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
		local folder = job.args.folder
		if H.helper and anySyncing(job.b, folder) and not over then return end
		finishStatus(job, (H.helper and anySyncing(job.b, folder)) and ("waiting for the sync with mod.io of "
			.. (folder and ("staging mod " .. folder) or "the staging mods")) or nil)
	end

	function handlers.modhubStatus(c)
		local args, err = core.modhubStatusArgs(c.args)
		if not args then return fail(c.id, err) end
		if H.job then return fail(c.id, busyError()) end
		local b, berr = backends()
		if not b then return fail(c.id, berr) end
		startJob({ id = c.id, cmd = c.cmd, args = args, b = b, started = appTime() }, stepStatus)
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

	local function progress(job, v)
		if appTime() < job.nextProgress then return end
		job.nextProgress = appTime() + PROGRESS_SEC
		job.progressN = job.progressN + 1
		local out = payload(job)
		out.ok, out.running = true, true
		out.progress, out.task = v and v.progress, v and v.task
		answer(job.id, out, "p" .. job.progressN)
	end

	local function stepValidate(job)
		local t = appTime() - job.started
		-- --timeout covers the whole command, the waits for mod.io and the sync too, so the tool's own wait
		-- (timeout + a margin) never runs out first; nothing was validated yet in those phases
		if job.phase ~= "validating" and t > job.args.timeout then
			return endJob(job, payload(job), "timed out after " .. job.args.timeout .. " s while waiting ("
				.. job.phase .. "); not validated")
		end
		if job.phase ~= "validating" then progress(job, nil) end
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
			job.phase, job.syncSince = "sync", appTime()
		end
		if job.phase == "sync" then
			-- not known to the helper yet (just made): the same wait as Sync
			local known = try(function() return H.helper:hasStagingMod(job.mid) end)
			local d = known and try(function() return H.helper:getStagingModData(job.mid) end) or nil
			local s = known and stateName(core.field(d, "state")) or "Sync"
			if s == "Sync" or s == nil then
				if appTime() - job.syncSince < M.SYNC_SEC then return end
				return endJob(job, payload(job), "the staging mod is still " .. (known and tostring(s or "unreadable")
					or "unknown to the publish helper") .. " after " .. M.SYNC_SEC .. " s (its sync with mod.io)")
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
			-- the engine likely hands out a new userdata on each read, so the result before cannot be told apart by
			-- identity: without validating seen, a result that was there before waits FRESH_SEC
			local done = v and not v.validating and res ~= nil
				and (job.sawValidating or job.before == nil or appTime() - job.validateSince >= M.FRESH_SEC)
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
			progress(job, v)
		end
	end

	function handlers.modhubValidate(c)
		local args, err = core.modhubValidateArgs(c.args)
		if not args then return fail(c.id, err) end
		if H.job then return fail(c.id, busyError()) end
		if H.helperError then return fail(c.id, "ModPublishHelper.new failed: " .. H.helperError) end
		local b, berr = backends()
		if not b then return fail(c.id, berr) end
		startJob({ id = c.id, cmd = c.cmd, args = args, b = b, started = appTime(), phase = "ready",
			nextProgress = appTime() + PROGRESS_SEC, progressN = 0 }, stepValidate)
	end

	---------------------------------------------------------------------------------------------------------------
	-- publish: one mod to mod.io, new or an update, as the page's Upload / Update button (ModUploadForm,
	-- mod_manager_react_util.tl 1806-1881: one publish call for both). The phases: ready (mod.io), sync (the mod
	-- leaves Sync), check (new or the expected update, logged in, cover; a busy mod.io is waited for), validating (a
	-- fresh validation, as the page validates before it enables the button, 1478-1481), check again, then the dry
	-- run's answer, or publish and its wait (publishing) up to HasResult.

	-- the settings as the page builds them for a mod of the My Mods tab (no params.publishSettings there): new(),
	-- then setPublic = (modhubDetails ~= nil and modhubDetails.modInfo.visible), false for a new mod, which the
	-- "Set Public" check box changes while the mod is not public on mod.io (1466-1471, 1474, 1591-1596; the box is
	-- disabled for a public one, so an update of a public mod stays public: publishChecks refuses public = false
	-- there); updateMetadata = true (1470; the box is disabled for a new mod, 1598-1603; an update keeps the
	-- default, so modinfo.json's name, summary and description go up again); changeLog from the text field
	-- (1605-1609); at the button isSavegame =
	-- params.disableValidator, nil on My Mods (5734-5743), and issuesConfirmed = false when no "Proceed Anyway"
	-- was asked (1822-1826, 1868). additionalMetadata ("merged into the upload's metadata", the page sets it only
	-- for savegames): set only when a version was given, { version = "X.Y.Z" }; whether mod.io's file version
	-- takes it is a trial.
	local function plannedSettings(args)
		return { setPublic = args.public, updateMetadata = true, changeLog = args.changelog, isSavegame = false,
			issuesConfirmed = false, additionalMetadata = args.version and { version = args.version } or nil }
	end

	local function publishPayload(job)
		return { folder = job.args.folder, value = job.value, phase = job.phase, seconds = appTime() - job.started,
			mode = job.args.update and "update" or "firstUpload", modioId = job.args.modioId,
			dryRun = job.args.dryRun, publishCalled = job.publishCalled == true, settings = plannedSettings(job.args),
			checks = job.checks, validation = job.result }
	end

	local function endPublish(job, out, err)
		if job.publishCalled and H.published then H.published.outcome = err and (out.outcome or "failed") or "success" end
		return endJob(job, out, err)
	end

	local function publishProgress(job)
		if appTime() < job.nextProgress then return end
		job.nextProgress = appTime() + PROGRESS_SEC
		job.progressN = job.progressN + 1
		local out = { ok = true, running = true, folder = job.args.folder, phase = job.phase,
			seconds = appTime() - job.started, publishCalled = job.publishCalled == true }
		if job.mid then
			local d = try(function() return H.helper:getStagingModData(job.mid) end)
			out.state = stateName(core.field(d, "state"))
			local v = job.phase == "validating" and validation(H.helper, job.mid, nil) or nil
			out.progress, out.task = v and v.progress, v and v.task
		end
		local r = readiness(job.b.publish)
		out.modio = r.management
		answer(job.id, out, "p" .. job.progressN)
	end

	-- what must hold just before publish (and for the dry run): the mod is Ready; for a first upload it is new to
	-- mod.io (no valid mod.io id, no details); for an update its mod.io id is the one asked for and mod.io holds
	-- that mod (the page's "Update" case: modhubDetails there; without them the page warns the mod got deleted on
	-- mod.io and a new one would be made, which an update must never do); mod.io lets this user upload, and the
	-- cover is there. Returns the checks and the refusal (nil: it may go); a refusal for a login also names the
	-- user action the page would ask for (doRequiredUserAction, 3268-3280).
	local function publishChecks(job)
		local r, notReady = readiness(job.b.publish)
		local d = try(function() return H.helper:getStagingModData(job.mid) end)
		local mid = core.field(d, "modhubId")
		local remote = details(core.field(d, "modhubDetails"))
		local c = { mode = job.args.update and "update" or "firstUpload", state = stateName(core.field(d, "state")),
			loggedIn = r.loggedIn, allowModUpload = r.allowModUpload,
			initialized = r.initialized, busy = r.management and r.management.busy,
			uploading = r.management and r.management.uploading,
			modhubIdValid = bool(try(function() return mid:isValid() end)), modhubIdValue = str(core.field(mid, "value")),
			hasModhubDetails = remote ~= nil, modio = remote }
		local logo = core.field(core.field(core.field(d, "localModhubDetails"), "modInfo"), "logoImage")
		c.logoImage = type(logo) == "string" and (logo ~= "" and "set" or "empty") or "unreadable"
		if d == nil then return c, "getStagingModData cannot be read" end
		if c.state ~= "Ready" then return c, "the staging mod is " .. tostring(c.state) .. ", not Ready" end
		if job.args.update then
			local want = job.args.modioId
			c.expectedModioId = want
			if c.modhubIdValid ~= true then
				return c, c.modhubIdValid == false and ("the staging mod has no mod.io id, but an update of mod.io mod "
					.. want .. " was asked for: the game would make a new mod page") or "the staging mod's mod.io id cannot be read"
			end
			if c.modhubIdValue ~= want then
				return c, "the staging mod's mod.io id is " .. tostring(c.modhubIdValue) .. ", not " .. want
					.. " (_metadata/mod.io_fileid.txt): not updated"
			end
			-- found and the mod.io id must read as expected: one that cannot be read is refused too
			if remote == nil or remote.found ~= true then
				return c, "mod.io holds no details of mod " .. want .. " (deleted on mod.io, or not synced): the game "
					.. "would make a new mod page; not updated"
			end
			if remote.modId ~= want then
				return c, "mod.io's details are of mod " .. tostring(remote.modId) .. ", not " .. want .. ": not updated"
			end
			if remote.visible == true and job.args.public == false then
				return c, "mod " .. want .. " is public on mod.io, and the page cannot make it hidden (its Set Public "
					.. "box is disabled then): give public = true"
			end
		else
			if c.modhubIdValid ~= false then
				return c, c.modhubIdValid and ("the staging mod already has a mod.io id (" .. tostring(c.modhubIdValue)
					.. "): a first upload makes only a new mod; an update is asked without firstUpload")
					or "the staging mod's mod.io id cannot be read"
			end
			if c.hasModhubDetails then return c, "mod.io has details for this staging mod: it is not new" end
		end
		-- mod.io busy (e.g. syncing the other staging mods) passes: waited for, not refused
		if notReady then return c, notReady, nil, true end
		if r.initialized ~= true then return c, "mod.io is not initialized" end
		if r.allowModUpload ~= true then return c, "mod.io does not allow mod uploads here (allowModUpload)" end
		if not r.loggedIn then return c, "nobody is logged in to mod.io: log in on My Mods first", "login" end
		if c.logoImage == "empty" then return c, "no valid cover image found (_metadata/0.png): the page says the same" end
		return c, nil
	end

	-- BEGIN publish path: the only code that uploads (and the page's clean-up after a result). tests/run.lua
	-- allows publish, abortPublish and PublishSettings between these two markers and nowhere else.
	local function sendPublish(job)
		local ok, err = pcall(function()
			local p = plannedSettings(job.args)
			local s = api.type.modhub.PublishSettings.new()
			s.setPublic = p.setPublic
			s.updateMetadata = p.updateMetadata
			s.changeLog = p.changeLog
			s.isSavegame = p.isSavegame
			s.issuesConfirmed = p.issuesConfirmed
			if p.additionalMetadata then s.additionalMetadata = p.additionalMetadata end
			H.helper:publish(job.mid, s)
		end)
		return ok, err
	end

	-- after the result, as the page does: on a failure at once (1422-1424), on a success when the person presses
	-- Ok (1873-1877). Only in HasResult: the page never calls it while Publishing, and in the middle of an upload
	-- it is not known what is left on mod.io.
	local function cleanUpPublish(job)
		local d = try(function() return H.helper:getStagingModData(job.mid) end)
		if stateName(core.field(d, "state")) ~= "HasResult" then return false, "not in HasResult" end
		local ok, err = pcall(function() H.helper:abortPublish(job.mid) end)
		return ok, not ok and tostring(err) or nil
	end
	-- END publish path

	local function stepPublish(job)
		local t = appTime() - job.started
		if job.phase == "publishing" then
			local d = try(function() return H.helper:getStagingModData(job.mid) end)
			local s = stateName(core.field(d, "state"))
			if s == "HasResult" then
				local out = publishPayload(job)
				out.state = s
				out.result = publishResult(d)
				local ok, cerr = cleanUpPublish(job)
				out.cleanedUp, out.cleanUpError = ok, cerr
				local d2 = try(function() return H.helper:getStagingModData(job.mid) end)
				local mid = core.field(d2, "modhubId")
				out.stateAfter = stateName(core.field(d2, "state"))
				out.modhubIdAfter = { valid = bool(try(function() return mid:isValid() end)), value = str(core.field(mid, "value")) }
				local res = out.result or {}
				out.modId = res.modId
				if res.success == true then
					if job.args.update and res.modId ~= job.args.modioId then
						-- an update answered with another mod.io id: a new page may have been made
						out.outcome = "other id"
						return endPublish(job, out, "the update of mod.io mod " .. job.args.modioId .. " came back as mod.io mod "
							.. tostring(res.modId) .. ": look at the account's mods on mod.io")
					end
					local partial = res.partialErrors or {}
					if #partial > 0 then
						out.outcome = "partial"
						return endPublish(job, out, "uploaded as mod.io mod " .. tostring(res.modId) .. ", with "
							.. #partial .. " partial errors (the page's \"Upload Failed\" list)")
					end
					say("published staging mod " .. job.args.folder .. " as mod.io mod " .. tostring(res.modId)
						.. " for command " .. job.id)
					return endPublish(job, out)
				end
				local e = res.error or {}
				out.outcome = "failed"
				say("publishing staging mod " .. job.args.folder .. " failed: " .. tostring(e.debugMessage or e.code))
				return endPublish(job, out, "Upload Failed: " .. tostring(e.localizedMessage or e.debugMessage or "no message")
					.. " (code " .. tostring(e.code) .. ")")
			end
			if t > job.args.timeout then
				-- no abortPublish: the page never calls it in the middle of an upload; the game may still finish it
				local out = publishPayload(job)
				out.state, out.outcome = s, "unknown"
				return endPublish(job, out, "timed out after " .. job.args.timeout .. " s while the upload was " ..
					tostring(s) .. ": the outcome is not known; it was not aborted, and the game may still finish it")
			end
			return publishProgress(job)
		end
		-- before publish: the time limit ends it, nothing sent
		if t > job.args.timeout then
			if job.phase == "validating" then pcall(function() H.helper:abortValidation(job.mid) end) end
			return endPublish(job, publishPayload(job), "timed out after " .. job.args.timeout .. " s (" .. job.phase
				.. (job.waitingFor and (": " .. job.waitingFor) or "") .. "); nothing was uploaded")
		end
		publishProgress(job)
		if job.phase == "ready" then
			local _, notReady = readiness(job.b.publish)
			if notReady then
				if t < M.READY_SEC then return end
				return endPublish(job, publishPayload(job), notReady .. " after " .. M.READY_SEC .. " s; nothing was uploaded")
			end
			local h, herr = helper(job.b.publish)
			if not h then return endPublish(job, publishPayload(job), "ModPublishHelper.new failed: " .. tostring(herr)) end
			local id, ferr = findId(job.b, job.args.folder)
			if not id then return endPublish(job, publishPayload(job), ferr) end
			job.mid, job.value = id, str(core.field(id, "value"))
			job.phase, job.syncSince = "sync", appTime()
		end
		if job.phase == "sync" then
			local known = try(function() return H.helper:hasStagingMod(job.mid) end)
			local d = known and try(function() return H.helper:getStagingModData(job.mid) end) or nil
			local s = known and stateName(core.field(d, "state")) or "Sync"
			if s == "Sync" or s == nil then
				if appTime() - job.syncSince < M.SYNC_SEC then return end
				return endPublish(job, publishPayload(job), "the staging mod is still " .. (known and tostring(s or "unreadable")
					or "unknown to the publish helper") .. " after " .. M.SYNC_SEC .. " s (its sync with mod.io); nothing was uploaded")
			end
			job.phase = "check"
		end
		if job.phase == "check" then
			-- before the validation, and again after it (it takes a while: mod.io may have turned busy, or the
			-- person logged out)
			local checks, why, action, transient = publishChecks(job)
			job.checks = checks
			if transient then job.waitingFor = why; return end
			job.waitingFor = nil
			if why then
				local out = publishPayload(job)
				out.requiredUserAction = action
				return endPublish(job, out, why .. "; nothing was uploaded")
			end
			if not job.result then
				local _, before = validation(H.helper, job.mid, nil)
				job.before = before
				local ok, err = pcall(function() H.helper:validate(job.mid) end)
				if not ok then return endPublish(job, publishPayload(job), "validate failed: " .. tostring(err)) end
				job.phase, job.validateSince = "validating", appTime()
				return
			end
			if job.args.dryRun then
				job.phase = "dryRun"
				local out = publishPayload(job)
				out.wouldPublish = true
				return endPublish(job, out)
			end
			if H.published then
				return endPublish(job, publishPayload(job), "an upload was already sent in this launch (command "
					.. H.published.id .. "); nothing was uploaded")
			end
			-- once per launch, whatever publish does: set before the call, so even one that raises counts
			H.published = { id = job.id, folder = job.args.folder, mid = job.mid, outcome = "publishing" }
			job.publishCalled = true
			local ok, err = sendPublish(job)
			if not ok then
				local out = publishPayload(job)
				out.outcome = "failed"
				return endPublish(job, out, "publish raised: " .. tostring(err) .. " (whether anything reached mod.io is not known)")
			end
			say("publishing staging mod " .. job.args.folder .. " (" .. (job.args.update and ("update of mod.io mod "
				.. job.args.modioId) or "new mod") .. ", public " .. tostring(job.args.public) .. ") for command " .. job.id)
			job.phase = "publishing"
			job.nextProgress = appTime() -- a progress answer at once: the tool sees that publish was called
			return publishProgress(job)
		end
		if job.phase == "validating" then
			local v, res = validation(H.helper, job.mid, nil)
			if v and v.validating then job.sawValidating = true end
			local done = v and not v.validating and res ~= nil
				and (job.sawValidating or job.before == nil or appTime() - job.validateSince >= M.FRESH_SEC)
			if not done then return end
			job.result = core.validationSummary(readResult(res), job.args.messages)
			if not job.sawValidating and job.before ~= nil then
				job.result.note = "validating was never seen true: this may be the result from before"
			end
			local block = core.publishValidationBlock(job.result)
			if block then return endPublish(job, publishPayload(job), block .. "; nothing was uploaded") end
			job.phase = "check"
		end
	end

	function handlers.modhubPublish(c)
		local args, err = core.modhubPublishArgs(c.args)
		if not args then return fail(c.id, err) end
		if H.job then return fail(c.id, busyError()) end
		if H.published and not args.dryRun then
			return fail(c.id, "an upload was already sent in this launch (command " .. H.published.id
				.. "): one per launch; nothing was uploaded")
		end
		if H.helperError then return fail(c.id, "ModPublishHelper.new failed: " .. H.helperError) end
		local b, berr = backends()
		if not b then return fail(c.id, berr) end
		startJob({ id = c.id, cmd = c.cmd, args = args, b = b, started = appTime(), phase = "ready",
			nextProgress = appTime() + PROGRESS_SEC, progressN = 0 }, stepPublish)
	end

	-- why a load, new game or quit must wait: an upload of this launch that has no result yet (a quit in the
	-- middle of it leaves mod.io in a state nobody knows). nil when nothing holds them.
	function H.blocks()
		local p = H.published
		if not p or not H.helper then return nil end
		local job = H.job
		local s
		if job and job.cmd == "modhubPublish" and job.phase == "publishing" then
			s = "Publishing"
		else
			local known = try(function() return H.helper:hasStagingMod(p.mid) end)
			local d = known and try(function() return H.helper:getStagingModData(p.mid) end) or nil
			s = stateName(core.field(d, "state"))
			if s ~= "Publishing" then return nil end
		end
		return "the upload of staging mod " .. p.folder .. " (command " .. p.id .. ") is still " .. s
			.. ": refused until it has a result (modhub status shows it)"
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
		runStep(job, job.cmd == "modhubStatus" and stepStatus or (job.cmd == "modhubPublish" and stepPublish or stepValidate))
	end

	-- a load, new game or quit ends the menu: a running validation is aborted and its command answered. An upload
	-- is not cancelled here: H.blocks holds those commands back while one runs.
	function H.cancel(reason)
		local job = H.job
		if not job then return end
		if job.phase == "validating" then pcall(function() H.helper:abortValidation(job.mid) end) end
		if job.cmd == "modhubPublish" then
			return endPublish(job, publishPayload(job), "cancelled by " .. reason .. (job.publishCalled
				and "; the upload was not aborted, its outcome is not known" or "; nothing was uploaded"))
		end
		endJob(job, payload(job), "cancelled by " .. reason)
	end

	H.handlers = handlers
	return H
end

return M
