-- eval for the remote probe: a piece of Lua run in the running game, its value read back as JSON (the rules and the
-- environments are in remote_core.lua, "eval"). eval reads only; evalWrite runs with every global, test saves
-- only. Both run here, in the GUI's Lua state, or with gs in the game script's (remote_gs.script.lua): sent as a
-- script event, answered in the script's state, which guiUpdate hands this script (as runningCostsSet), so only
-- with the mod setting gameScript on.
local M = {}

local NO_GS = "gs runs the code in the game script, which listens only with the mod setting gameScript on: "
	.. "launch / load with --param hummer_remote_probe:gameScript=2 (tf3ctl refuses that on a person's save): nothing run"

-- ctx: core, answer(id, payload, tag), failWith(id, msg, extra), appTime(), fineTime(), try(fn), say(msg, level),
-- gsState() -> the game script's state handed to guiUpdate
function M.new(ctx)
	local core, answer, failWith, appTime, try, say = ctx.core, ctx.answer, ctx.failWith, ctx.appTime, ctx.try, ctx.say
	local job = nil
	local T = {}

	local function gameScriptOn()
		local all = try(function() return api.engine.config.getModParams() end)
		return core.options(all and core.field(all, core.MOD_ID) or nil).gameScript == true
	end

	local function name(write) return write and "evalWrite" or "eval" end

	-- the answer of one run (core.evalHere's, or the game script's), as an answer or an error answer
	local function reply(id, write, r, where, extra)
		local p = { value = r.value, values = r.values, n = r.n, ms = r.ms, truncated = r.truncated, print = r.print,
			printTruncated = r.printTruncated, where = where, kind = r.kind, traceback = r.traceback }
		for k, v in pairs(extra or {}) do p[k] = v end
		if type(p.print) == "table" then core.array(p.print) end
		if r.ok then
			p.ok = true
			say(name(write) .. " (command " .. id .. ") ran in the " .. where, write and 1 or 2)
			return answer(id, p)
		end
		return failWith(id, (r.kind == "compile" and "the code does not compile: " or "the code raised: ")
			.. tostring(r.error), p)
	end

	local function send(event, request)
		local okM, cmd = pcall(function()
			return api.cmd.makeScriptingSendEventCmd("", core.RUNCOST_EVENT_ID, event, request)
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

	local function run(c, write)
		local a, err = core.evalArgs(c.args, write)
		if not a then return failWith(c.id, err) end
		if not a.gs then
			local r = core.evalHere(a, write, { clock = ctx.fineTime })
			return reply(c.id, write, r, "gui")
		end
		if job then
			return failWith(c.id, name(job.write) .. " (command " .. job.id .. ") is still waiting for the game script: "
				.. "send again once it has answered")
		end
		if not gameScriptOn() then return failWith(c.id, NO_GS) end
		local j = { id = c.id, write = write, startedAt = appTime(), deadline = appTime() + core.EVAL_WAIT_SEC }
		j.request = core.evalRequest(c.id, a, write)
		job = j
		local ok, serr = send(write and core.EVAL_EVENT_WRITE or core.EVAL_EVENT_READ, j.request)
		if not ok then
			job = nil
			return failWith(c.id, serr .. ": nothing run")
		end
	end

	function T.eval(c) return run(c, false) end
	function T.evalWrite(c) return run(c, true) end

	function T.step()
		local j = job
		if j == nil then return end
		local ok, err = pcall(function()
			if j.called and j.success == false then
				job = nil
				return failWith(j.id, "the engine refused the script event (its callback said no success): nothing run")
			end
			local st = ctx.gsState()
			local s = st and try(function() return st:get() end)
			local r = type(s) == "table" and type(s.eval) == "table" and s.eval or nil
			if r and tonumber(r.req) == j.id then
				job = nil
				local res = type(r.result) == "table" and r.result or { ok = false, kind = "runtime", error = "no result" }
				return reply(j.id, j.write, res, "script", { waitedSec = appTime() - j.startedAt })
			end
			if appTime() > j.deadline then
				job = nil
				failWith(j.id, "no answer from the game script after " .. core.EVAL_WAIT_SEC .. " s (it subscribes a few "
					.. "seconds after a load with gameScript on; is the game paused? not known whether the engine runs "
					.. "script events then)" .. (j.write and ". Whether it ran shows in the log (log --grep \"game script\")"
					or ""))
			end
		end)
		if not ok then
			if job == j then job = nil end
			failWith(j.id, err)
		end
	end

	function T.reset() job = nil end

	T.handlers = { eval = T.eval, evalWrite = T.evalWrite }
	return T
end

return M
