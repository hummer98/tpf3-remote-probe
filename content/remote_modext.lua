-- Other mods' commands for the remote probe (modList, modRead, modChange; tf3ctl mod --list, tf3ctl mod <modId>
-- <command> [JSON]). A mod that ships core.EXT_FILE ("<modId>::/remote_probe_ext.lua") returns a table of commands
-- from it; this file requires that table at run time, in the GUI Lua state the probe runs in, as remote_connect.lua
-- requires Track Connector's modules: nothing of the other mod is copied here, and a mod that is not enabled for the
-- save has no file to require. The form of the table: core.extTable, and examples/remote_probe_ext_sample.
--
-- Safety: every call into the other mod's code is under pcall, so a Lua error there is an error answer, never an
-- error of the probe's guiUpdate. What pcall cannot catch stays the other mod's: an engine assertion in an api call
-- it makes, or a loop that never ends (there is no debug.sethook in the game to stop one). A command tagged
-- changes is only ever run as modChange, the command name the tool's owner check and the probe's "who used the
-- game" know as changing the game; modRead refuses it without running anything.
local M = {}

-- a synchronous run longer than this is logged (once per call): it holds the GUI frame that long
local SLOW_MS = 500
-- words a require error for a missing file is taken by, when it does not look like the probe's own missing file's
-- (what the game says for one is not seen in game yet)
local MISSING_WORDS = { "not found", "no such file", "cannot find", "could not find", "can't find", "not cached",
	"does not exist", "no file" }

local function plainPattern(s) return (s:gsub("%p", "%%%0")) end

-- ctx: core, answer(id, payload, tag), failWith(id, msg, extra), appTime(), fineTime(), try(fn), say(msg, level),
-- now() (the game state as status shows it), mod (the probe's id), installed() (mod ids the user profile lists),
-- modParams() (the running game's, keyed by mod id), requires (optional: the require functions to try, in order)
function M.new(ctx)
	local core, answer, failWith, try, say = ctx.core, ctx.answer, ctx.failWith, ctx.try, ctx.say
	local appTime, fineTime = ctx.appTime, ctx.fineTime or ctx.appTime
	-- (other mods load their own modules with the plain require; ug_require is for the base's files)
	local reqs = ctx.requires or { require, ug_require }
	local E = { cache = {}, pending = {}, missingShape = nil }
	local handlers = {}

	local function pathOf(modId) return modId .. "::/" .. core.EXT_FILE end

	-- a require error with the path and the mod's id taken out, to compare with the one of a file that is surely
	-- missing (the probe's own, below)
	local function shape(err, path, modId)
		local s = tostring(err):gsub(plainPattern(path), "<path>")
		return (s:gsub(plainPattern(modId), "<mod>"))
	end

	local function requireAll(path)
		local errs = {}
		for _, rq in ipairs(reqs) do
			if type(rq) == "function" then
				local ok, m = pcall(rq, path)
				if ok then return true, m end
				errs[#errs + 1] = tostring(m)
			end
		end
		return false, errs
	end

	local function missingShape()
		if E.missingShape == nil then
			local path = ctx.mod .. "::/remote_probe_ext_none.lua"
			local ok, errs = requireAll(path)
			E.missingShape = (not ok and errs[1]) and shape(errs[1], path, ctx.mod) or false
		end
		return E.missingShape
	end

	local function isMissing(err, path, modId)
		local ms = missingShape()
		if ms and shape(err, path, modId) == ms then return true end
		local low = tostring(err):lower()
		if not low:find(core.EXT_FILE, 1, true) then return false end -- (another file of the mod missing: broken)
		for _, w in ipairs(MISSING_WORDS) do
			if low:find(w, 1, true) then return true end
		end
		return false
	end

	-- { ext = <core.extTable> } | { none = why } | { broken = why }, once per mod and load: a failed require is
	-- tried again by the game's require each time, and each try may log an error
	local function load(modId)
		local hit = E.cache[modId]
		if hit then return hit end
		local path = pathOf(modId)
		local ok, got = requireAll(path)
		local entry
		if not ok then
			local missing = #got > 0
			for _, e in ipairs(got) do
				if not isMissing(e, path, modId) then missing = false end
			end
			local why = table.concat(got, "; ")
			if #got == 0 then why = "no require function to load it with" end
			entry = missing and { none = why } or { broken = why }
		else
			local t, err = core.extTable(got)
			entry = t and { ext = t } or { broken = err }
		end
		E.cache[modId] = entry
		return entry
	end

	-- the mods to look in: those the user profile lists and those with settings in this game, not the probe itself
	-- and not the official ones (ug_*, which ship no such file). Which of them are enabled for this save the GUI
	-- cannot tell; a mod that is not enabled has no file to require.
	local function candidates()
		local seen, out = { [ctx.mod] = true }, {}
		local function add(n)
			if type(n) == "string" and core.extName(n) and not seen[n]
				and n:sub(1, #core.OFFICIAL_PREFIX) ~= core.OFFICIAL_PREFIX then
				seen[n] = true
				out[#out + 1] = n
			end
		end
		for _, n in ipairs((ctx.installed and ctx.installed()) or {}) do add(n) end
		local params = ctx.modParams and ctx.modParams()
		if type(params) == "table" then
			for k in pairs(params) do add(k) end
		end
		table.sort(out)
		return out
	end

	-- args: mod (only that one; none: every candidate). Read only.
	function handlers.modList(c)
		local only = c.args and c.args.mod
		if only ~= nil and not core.extName(only) then return failWith(c.id, "mod must be a mod's id") end
		local list = only and { only } or candidates()
		local mods, broken, none = {}, {}, nil
		for _, id in ipairs(list) do
			local e = load(id)
			if e.ext then
				mods[#mods + 1] = core.extListEntry(id, e.ext)
			elseif e.broken then
				broken[#broken + 1] = { mod = id, error = e.broken }
			elseif only then
				none = e.none
			end
		end
		answer(c.id, { ok = true, mods = core.array(mods), broken = core.array(broken), checked = #list,
			file = core.EXT_FILE, api = core.EXT_API,
			note = only and #mods == 0 and #broken == 0 and (only .. " has no " .. core.EXT_FILE
				.. " that loads (not enabled for this save, or it ships none): " .. tostring(none)) or nil })
	end

	local function failJob(job, kind, msg)
		if job.done then return end
		job.done = true
		say("mod command " .. job.mod .. " " .. job.command .. " (" .. job.id .. "): " .. msg, 1)
		failWith(job.id, msg, { kind = kind, mod = job.mod, command = job.command, tag = job.tag })
	end

	local function deliver(job, res, err)
		if job.done then return end
		if res == nil then
			if err ~= nil then return failJob(job, "error", tostring(err)) end
			return failJob(job, "noAnswer", "the command returned nothing (return a table or a value, or nil and a message)")
		end
		local bad = core.extResultError(res)
		if bad then return failJob(job, "badResult", "the command's answer cannot be written as JSON: " .. bad) end
		local okJ, text = pcall(core.json, res)
		if not okJ then return failJob(job, "badResult", "the command's answer cannot be written as JSON: " .. tostring(text)) end
		if #text > core.EXT_RESULT_MAX then
			return failJob(job, "badResult", string.format("the command's answer is %d characters of JSON, more than %d",
				#text, core.EXT_RESULT_MAX))
		end
		job.done = true
		answer(job.id, { ok = true, mod = job.mod, command = job.command, tag = job.tag, result = res,
			deferred = job.deferred or nil, seconds = appTime() - job.started })
	end

	-- what a command's run(args, ctx) gets as ctx
	local function callCtx(job, c)
		local x = { mod = job.mod, command = job.command, id = job.id, tag = job.tag, owner = core.owner(c.args),
			timeout = job.timeout }
		-- a line in the game's log, with the mod's name; level as the probe's logLevel setting (1 always, 2 default)
		function x.log(msg, level) say("[" .. job.mod .. "] " .. tostring(msg), tonumber(level) or 2) end
		-- fn's value, or nil when it raised
		x.try = try
		-- pcall: true and fn's values, or false and the error
		function x.call(fn, ...) return pcall(fn, ...) end
		-- an empty table that is written as [] (a list) in the answer
		x.array = core.array
		-- the game time, date and speed, as status shows them
		x.now = ctx.now
		x.appTime = appTime
		x.clock = fineTime -- seconds that move within a frame, for how long something took
		function x.exists(e)
			return type(e) == "number" and try(function() return api.engine.entityExists(e) end) == true
		end
		-- a component of an entity that exists, by its ComponentType's name ("NAME", "STATION", ...); nil when
		-- there is none, the entity does not exist or the name is not a ComponentType (a lookup on an id the engine
		-- does not know may assert, so it is never made)
		function x.component(e, kind)
			if not x.exists(e) then return nil end
			local t = try(function() return api.type.ComponentType[kind] end)
			if t == nil then return nil end
			return try(function() return api.engine.getComponent(e, t) end)
		end
		function x.name(e)
			if not x.exists(e) then return nil end
			local n = try(function() return api.engine.util.getEntityName(e) end)
			return type(n) == "string" and n or nil
		end
		-- api.cmd.sendCommand(cmd, onDone(res, success)), with onDone under pcall (an error there is logged, not
		-- raised into the engine's callback). Returns true, or false and why it could not be sent.
		function x.sendCommand(cmd, onDone)
			return pcall(api.cmd.sendCommand, cmd, function(res, success)
				if onDone then
					local ok, err = pcall(onDone, res, success)
					if not ok then say("[" .. job.mod .. "] " .. job.command .. ": the sendCommand callback raised: " .. tostring(err), 1) end
				end
			end)
		end
		-- the answer comes later: returns finish(result) or finish(nil, message), to call once from a callback or a
		-- later frame (the probe answers a timeout error after ctx.timeout seconds; a finish after that is ignored).
		-- What run returns once it deferred is not looked at.
		function x.defer()
			if not job.deferred then
				job.deferred = true
				job.deadline = appTime() + job.timeout
				E.pending[#E.pending + 1] = job
			end
			return function(res, err)
				local ok, e = pcall(deliver, job, res, err)
				if not ok then say("mod command " .. job.mod .. " " .. job.command .. ": could not answer: " .. tostring(e), 1) end
			end
		end
		return x
	end

	local function call(c, asChange)
		local a, err = core.extCallArgs(c.args)
		if not a then return failWith(c.id, err) end
		local e = load(a.mod)
		if e.none then
			return failWith(c.id, a.mod .. " has no " .. core.EXT_FILE .. " that loads (not enabled for this save, or it "
				.. "ships none): " .. e.none, { kind = "noExt", mod = a.mod, command = a.command })
		end
		if e.broken then
			return failWith(c.id, a.mod .. "'s " .. core.EXT_FILE .. " does not work: " .. e.broken,
				{ kind = "broken", mod = a.mod, command = a.command })
		end
		local cmd = e.ext.commands[a.command]
		if not cmd then
			local names = {}
			for n in pairs(e.ext.commands) do names[#names + 1] = n end
			table.sort(names)
			return failWith(c.id, a.mod .. " has no command " .. a.command .. " (its commands: " .. table.concat(names, ", ")
				.. ")", { kind = "noCommand", mod = a.mod, command = a.command })
		end
		if cmd.changes and not asChange then
			-- nothing run: the tool sends it again as modChange, past its owner check
			return failWith(c.id, a.mod .. " " .. a.command .. " changes the game: it is sent as modChange",
				{ kind = "changes", needsChange = true, mod = a.mod, command = a.command, tag = cmd.tag })
		end
		local job = { id = c.id, mod = a.mod, command = a.command, tag = cmd.tag, timeout = a.timeout, started = appTime() }
		local x = callCtx(job, c)
		local t0 = fineTime()
		local ok, res, msg = pcall(cmd.run, a.args, x)
		local ms = (fineTime() - t0) * 1000
		if ms > SLOW_MS then
			say(string.format("mod command %s %s took %.0f ms in one frame", a.mod, a.command, ms), 1)
		end
		if not ok then return failJob(job, "error", "the command raised an error: " .. tostring(res)) end
		if job.deferred then return end -- (finish answers, or the timeout in step)
		deliver(job, res, msg)
	end

	function handlers.modRead(c) return call(c, false) end
	function handlers.modChange(c) return call(c, true) end

	-- deferred answers past their time
	local function step()
		if #E.pending == 0 then return end
		local t, keep = appTime(), {}
		for _, job in ipairs(E.pending) do
			if not job.done and t >= job.deadline then
				failJob(job, "timeout", string.format("no answer within %g s (the command deferred its answer)", job.timeout))
			end
			if not job.done then keep[#keep + 1] = job end
		end
		E.pending = keep
	end

	local self = { handlers = handlers }
	self.step = step
	function self.reset()
		E.cache, E.pending, E.missingShape = {}, {}, nil
	end
	return self
end

return M
