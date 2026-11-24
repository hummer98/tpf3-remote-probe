-- Other mods' commands: modList, modRead, modChange (content/remote_modext.lua, core.extTable / extCallArgs /
-- extResultError), with the sample mod (examples/remote_probe_ext_sample) and broken ones put in tests/fake_game.lua
-- (fake.extMods). Run from tests/run.lua, which hands in its helpers.
return function(h)
	local test, eq, truthy, fake, core, root = h.test, h.eq, h.truthy, h.fake, h.core, h.root
	local newGame, send, frames, final, FIRST = h.newGame, h.send, h.frames, h.final, h.FIRST

	local SAMPLE_ID = "hummer_remote_probe_ext_sample"
	local SAMPLE = { file = root .. "/examples/remote_probe_ext_sample/content/remote_probe_ext.lua" }

	-- the mods of the tests: the sample; one whose file does not compile; one whose file returns nothing; one whose
	-- commands misbehave; one installed without the file; and an official one (never looked in)
	local ODD = [[
local calls = 0
return { api = 1, commands = {
	boom = { tag = "reads", description = "raises", run = function() error("kaboom") end },
	fn = { tag = "reads", run = function() return { f = function() end } end },
	cycle = { tag = "reads", run = function() local t = {}; t.self = t; return t end },
	nan = { tag = "reads", run = function() return { x = 0 / 0 } end },
	nothing = { tag = "reads", run = function() end },
	refuse = { tag = "reads", run = function() return nil, "not today" end },
	plain = { tag = "reads", run = function() return 42 end },
	shared = { tag = "reads", run = function() local s = { 1 }; return { a = s, b = s } end },
	untagged = { run = function() calls = calls + 1; return { calls = calls } end },
	weird = { tag = "sometimes", run = function() calls = calls + 1; return { calls = calls } end },
	hang = { tag = "reads", run = function(_, ctx) ctx.finish = ctx.defer(); _G.MODEXT_LATE = ctx.finish end },
	late = { tag = "changes", run = function(_, ctx)
		local finish = ctx.defer()
		ctx.sendCommand(api.cmd.makeGameSetSpeedCmd(3), function(_, ok) finish({ ok = ok }) end)
	end },
	ctx = { tag = "reads", run = function(args, ctx)
		ctx.log("hello from the ext")
		return { mod = ctx.mod, command = ctx.command, owner = ctx.owner, timeout = ctx.timeout, tag = ctx.tag,
			empty = ctx.array({}), exists = ctx.exists(41), noEntity = ctx.exists(999999), name = ctx.name(41),
			tried = ctx.try(function() error("x") end) == nil, args = args }
	end },
	[ "bad name!" ] = { tag = "reads", run = function() return 1 end },
	norun = { tag = "reads" },
} }
]]
	local function extGame(opts)
		opts = opts or {}
		opts.saves = opts.saves or h.SAVES
		opts.installed = opts.installed or { SAMPLE_ID, "ext_syntax", "ext_nothing", "ext_odd", "no_ext", "ug_official" }
		opts.extMods = opts.extMods or { [SAMPLE_ID] = SAMPLE, ext_syntax = "return { api = 1, commands = {",
			ext_nothing = "local x = 1", ext_odd = ODD, ug_official = "error('an official mod was looked in')",
			ext_newer = "return { api = 99, commands = { a = { run = function() end } } }" }
		opts.stationGroups = opts.stationGroups or { [41] = { name = "Central", stations = { { id = 411, terminals = 1,
			passenger = true, pos = { 100, 0 } } } } }
		local g = newGame(opts)
		frames(g, 1)
		return g
	end
	local function run(g, id, cmd, argsLua, n, dt)
		send(g, id, cmd, argsLua)
		frames(g, n or FIRST, dt)
		return final(g, id)
	end
	local function call(g, id, cmd, mod, command, argsLua, extra)
		return run(g, id, cmd, string.format('{ mod = %q, command = %q, args = %s%s, _owner = "tester" }', mod, command,
			argsLua or "{}", extra or ""))
	end

	test("core.extTable: commands with run, tags (none or unknown: changes), names, api", function()
		truthy(select(2, core.extTable(true)):find("returned boolean"))
		truthy(select(2, core.extTable({ api = 2, commands = {} })):find("this remote probe reads api 1"))
		truthy(select(2, core.extTable({ api = 1.5, commands = {} })):find("whole number"))
		truthy(select(2, core.extTable({ commands = 3 })):find("commands must be a table"))
		truthy(select(2, core.extTable({ commands = { a = { tag = "reads" } } })):find("no usable command.*no run function"))
		local t = assert(core.extTable({ commands = {
			r = { tag = "reads", description = "d", run = print },
			c = { tag = "changes", run = print },
			n = { run = print },
			u = { tag = "READS", run = print },
			["x y"] = { run = print },
			long = { tag = "reads", run = print, description = string.rep("a", 900) },
		} }))
		eq(t.api, 1)
		eq(t.commands.r.changes, false); eq(t.commands.r.tag, "reads"); eq(t.commands.r.description, "d")
		eq(t.commands.c.changes, true)
		eq(t.commands.n.changes, true); eq(t.commands.n.tag, "changes"); truthy(t.commands.n.notes[1]:find("no tag"))
		eq(t.commands.u.changes, true, "a tag is read as written: READS is not reads")
		eq(t.commands["x y"], nil); truthy(t.notes[1]:find("x y"))
		eq(#t.commands.long.description, core.EXT_DESCRIPTION_MAX)
		local entry = core.extListEntry("m", t)
		eq(entry.commands[1].name, "c"); eq(entry.commands[#entry.commands].name, "u", "sorted by name")
	end)

	test("core.extResultError: what JSON cannot hold, by its path; shared tables are fine", function()
		eq(core.extResultError({ a = { 1, 2, { b = "x" } }, n = 1.5, t = true }), nil)
		eq(core.extResultError(0), nil); eq(core.extResultError("s"), nil); eq(core.extResultError(false), nil)
		local s = { 1 }
		eq(core.extResultError({ a = s, b = s }), nil)
		eq(core.extResultError(nil), "result is nil")
		eq(core.extResultError({ a = { print } }), "result.a[1] is a function, which JSON has no form for")
		local c = {}; c.me = c
		truthy(core.extResultError({ c }):find("result%[1%].me is a table that holds itself"))
		truthy(core.extResultError({ x = 0 / 0 }):find("result.x is not a finite number"))
		truthy(core.extResultError({ x = math.huge }):find("not a finite number"))
		truthy(core.extResultError({ [true] = 1 }):find("key of type boolean"))
		truthy(core.extResultError({ [1.5] = 1 }):find("key of type number"))
		truthy(core.extResultError({ u = newproxy() }):find("result.u is a userdata"))
		local deep = {}
		local d = deep
		for _ = 1, 25 do d.n = {}; d = d.n end
		truthy(core.extResultError(deep):find("more than 20 deep"))
	end)

	test("core.extCallArgs: the mod, the command, its arguments (a table), the timeout", function()
		local a = assert(core.extCallArgs({ mod = "m_1", command = "do.it-2", args = { 1 } }))
		eq(a.timeout, core.EXT_TIMEOUT_DEFAULT); eq(a.args[1], 1)
		eq(assert(core.extCallArgs({ mod = "m", command = "c" })).args ~= nil, true)
		truthy(select(2, core.extCallArgs({ command = "c" })):find("mod's id"))
		truthy(select(2, core.extCallArgs({ mod = "m::/x", command = "c" })):find("mod's id"))
		truthy(select(2, core.extCallArgs({ mod = "m" })):find("command's name"))
		truthy(select(2, core.extCallArgs({ mod = "m", command = "c", args = "x" })):find("JSON object or list"))
		truthy(select(2, core.extCallArgs({ mod = "m", command = "c", timeout = 0 })):find("between 1 and 120"))
		truthy(select(2, core.extCallArgs({ mod = "m", command = "c", timeout = 121 })):find("between 1 and 120"))
		eq(assert(core.extCallArgs({ mod = "m", command = "c", timeout = 7 })).timeout, 7)
		for _, cmd in ipairs({ "modList", "modRead", "modChange" }) do truthy(core.COMMANDS[cmd], cmd) end
		eq(core.CHANGES_GAME.modChange, true); eq(core.CHANGES_GAME.modRead, nil); eq(core.CHANGES_GAME.modList, nil)
		eq(core.MENU_COMMANDS.modList, nil, "in a game only")
	end)

	test("the sample's file: two commands, hello reads, speed changes", function()
		local fn = assert(loadfile(SAMPLE.file))
		local t = assert(core.extTable(fn()))
		eq(t.commands.hello.tag, "reads"); eq(t.commands.speed.tag, "changes")
		eq(#t.notes, 0); eq(#t.commands.hello.notes, 0); eq(#t.commands.speed.notes, 0)
	end)

	test("modList: the mods with the file and their commands; broken files apart; mods without it left out", function()
		local g = extGame()
		local a = run(g, 9001, "modList", "{}")
		eq(a.ok, true, a.error)
		eq(a.file, "remote_probe_ext.lua"); eq(a.api, 1)
		eq(a.checked, 5, "the profile's mods but the official one (and the probe itself)")
		local byId = {}
		for _, m in ipairs(a.mods) do byId[m.mod] = m end
		truthy(byId[SAMPLE_ID] and byId.ext_odd, "the sample and ext_odd")
		eq(byId.no_ext, nil)
		local cmds = byId[SAMPLE_ID].commands
		eq(#cmds, 2)
		eq(cmds[1].name, "hello"); eq(cmds[1].tag, "reads"); eq(cmds[1].changes, false)
		truthy(cmds[1].description:find("date"))
		eq(cmds[2].name, "speed"); eq(cmds[2].tag, "changes"); eq(cmds[2].changes, true)
		truthy(#byId.ext_odd.notes >= 2, "the command with a bad name and the one without run are named")
		local broken = {}
		for _, b in ipairs(a.broken) do broken[b.mod] = b.error end
		truthy(broken.ext_syntax and broken.ext_syntax:find("error loading module"), broken.ext_syntax)
		truthy(broken.ext_nothing and broken.ext_nothing:find("returned boolean"), broken.ext_nothing)
		-- only one mod; a mod with no file says so
		local one = run(g, 9002, "modList", string.format("{ mod = %q }", SAMPLE_ID))
		eq(#one.mods, 1); eq(one.checked, 1); eq(one.note, nil)
		local none = run(g, 9003, "modList", '{ mod = "no_ext" }')
		eq(#none.mods, 0); truthy(none.note:find("no_ext has no remote_probe_ext.lua"), none.note)
		local newer = run(g, 9004, "modList", '{ mod = "ext_newer" }')
		truthy(newer.broken[1].error:find("api 99"), newer.broken[1].error)
		eq(run(g, 9005, "modList", '{ mod = "a b" }').ok, false)
		truthy(not g.crashed)
	end)

	test("modRead: a reads command runs and answers; a changes or untagged one is refused, nothing run", function()
		local g = extGame()
		local a = call(g, 9010, "modRead", SAMPLE_ID, "hello", '{ who = "ann", n = { 1, 2 } }')
		eq(a.ok, true, a.error)
		eq(a.mod, SAMPLE_ID); eq(a.command, "hello"); eq(a.tag, "reads")
		eq(a.result.greeting, "hello, ann"); eq(a.result.args.n[2], 2); eq(a.result.from, "tester")
		eq(a.result.date.year, 1900)
		local before = #g.commands
		local r = call(g, 9011, "modRead", SAMPLE_ID, "speed", "{ speed = 0 }")
		eq(r.ok, false); eq(r.kind, "changes"); eq(r.needsChange, true); eq(r.tag, "changes")
		eq(#g.commands, before, "nothing sent to the engine")
		local u = call(g, 9012, "modRead", "ext_odd", "untagged")
		eq(u.needsChange, true, "untagged: changes")
		local w = call(g, 9013, "modRead", "ext_odd", "weird")
		eq(w.needsChange, true, "an unknown tag: changes")
		-- as modChange the untagged one runs, once: the refusal above ran nothing
		local u2 = call(g, 9014, "modChange", "ext_odd", "untagged")
		eq(u2.ok, true, u2.error); eq(u2.result.calls, 1)
	end)

	test("modChange: the sample's speed answers from the command's callback, and counts as the last action", function()
		local g = extGame()
		g.speedup = 2
		local a = call(g, 9020, "modChange", SAMPLE_ID, "speed", "{ speed = 0 }")
		eq(a.ok, true, a.error)
		eq(a.result.speed, 0); eq(a.result.success, true); eq(a.deferred, true)
		eq(g.speedup, 0)
		local s = run(g, 9021, "status", "{}")
		eq(s.lastAction.cmd, "modChange"); eq(s.lastAction.owner, "tester")
		local bad = call(g, 9022, "modChange", SAMPLE_ID, "speed", "{ speed = 9 }")
		eq(bad.ok, false); eq(bad.kind, "error"); truthy(bad.error:find("0 to 4"), bad.error)
		eq(g.speedup, 0)
		-- a read command needs no modChange, but may come as one
		eq(call(g, 9023, "modChange", SAMPLE_ID, "hello").ok, true)
		-- a refused modChange is not the last action
		local s2 = run(g, 9024, "status", "{}")
		eq(s2.lastAction.id, 9023)
		-- a callback a few frames later (as commands queue in the game)
		local g2 = extGame({ callbackFrames = 5 })
		local b = call(g2, 9025, "modChange", "ext_odd", "late")
		eq(b.ok, true, b.error); eq(b.result.ok, true); eq(g2.speedup, 3)
	end)

	test("mod commands: no file, no such command, a broken file, an error, a bad or no answer: error answers", function()
		local g = extGame()
		local function err(id, mod, command, kind, text)
			local a = call(g, id, "modRead", mod, command)
			eq(a.ok, false, mod .. " " .. command); eq(a.kind, kind, mod .. " " .. command .. ": " .. tostring(a.error))
			truthy(a.error:find(text), a.error)
			eq(a.mod, mod)
			return a
		end
		err(9030, "no_ext", "x", "noExt", "no_ext has no remote_probe_ext.lua")
		err(9031, "not_installed", "x", "noExt", "not enabled")
		err(9032, SAMPLE_ID, "nope", "noCommand", "its commands: hello, speed")
		err(9033, "ext_syntax", "x", "broken", "does not work")
		err(9034, "ext_nothing", "x", "broken", "returned boolean")
		err(9035, "ext_odd", "boom", "error", "kaboom")
		err(9036, "ext_odd", "fn", "badResult", "result.f is a function")
		err(9037, "ext_odd", "cycle", "badResult", "holds itself")
		err(9038, "ext_odd", "nan", "badResult", "not a finite number")
		err(9039, "ext_odd", "nothing", "noAnswer", "returned nothing")
		err(9040, "ext_odd", "refuse", "error", "not today")
		err(9041, "ext_odd", "norun", "noCommand", "its commands")
		local p = call(g, 9042, "modRead", "ext_odd", "plain")
		eq(p.ok, true); eq(p.result, 42)
		local sh = call(g, 9043, "modRead", "ext_odd", "shared")
		eq(sh.ok, true); eq(sh.result.b[1], 1)
		eq(run(g, 9044, "modRead", '{ command = "x" }').ok, false)
		-- the probe goes on: the errors were answers, not errors of guiUpdate
		eq(run(g, 9045, "status", "{}").ok, true)
		truthy(not g.crashed)
		local logged = false
		for _, l in ipairs(g.logs) do if l:find("command 9035 failed") then logged = true end end
		truthy(logged, "the failure is in the game's log")
	end)

	test("mod commands: a deferred answer that never comes times out once; a finish after that is ignored", function()
		local g = extGame()
		_G.MODEXT_LATE = nil
		send(g, 9050, "modRead", '{ mod = "ext_odd", command = "hang", timeout = 5 }')
		frames(g, FIRST)
		local a, n = final(g, 9050)
		eq(n, 0, "no answer yet")
		frames(g, 60, 0.1)
		a, n = final(g, 9050)
		eq(n, 1); eq(a.ok, false); eq(a.kind, "timeout"); truthy(a.error:find("within 5 s"), a.error)
		truthy(_G.MODEXT_LATE, "the ext kept its finish")
		_G.MODEXT_LATE({ late = true })
		a, n = final(g, 9050)
		eq(n, 1, "still the one error answer"); eq(a.kind, "timeout")
		_G.MODEXT_LATE = nil
	end)

	test("mod commands: what ctx gives a command (names, owner, array, entities, try, log)", function()
		local g = extGame()
		local a = call(g, 9060, "modRead", "ext_odd", "ctx", "{ 1, 2 }", ", timeout = 9")
		eq(a.ok, true, a.error)
		local r = a.result
		eq(r.mod, "ext_odd"); eq(r.command, "ctx"); eq(r.owner, "tester"); eq(r.timeout, 9); eq(r.tag, "reads")
		eq(r.exists, true); eq(r.noEntity, false); eq(r.name, "Central"); eq(r.tried, true)
		eq(type(r.empty), "table"); eq(next(r.empty), nil)
		eq(r.args[2], 2)
		local text = h.answerText(g, 9060)
		truthy(text:find('"empty":%[%]'), "an empty list is written as []: " .. text)
		local logged = false
		for _, l in ipairs(g.logs) do if l:find("%[ext_odd%] hello from the ext") then logged = true end end
		truthy(logged, "ctx.log writes to the game's log with the mod's name")
	end)

	test("mod commands: in the main menu, refused as needing a game", function()
		local g = newGame({ saves = h.SAVES, menu = true, installed = { SAMPLE_ID }, extMods = { [SAMPLE_ID] = SAMPLE } })
		frames(g, 1)
		local a = run(g, 9070, "modList", "{}")
		eq(a.ok, false); truthy(a.error:find("needs a running game"), a.error)
	end)

	test("mod commands: a missing file told by the probe's own missing file, whatever the game's words", function()
		-- a require whose error for a missing file has none of the usual words: it is still "none", not "broken"
		local said = {}
		local function rq(path)
			if path == "good::/remote_probe_ext.lua" then return { commands = { a = { tag = "reads", run = function() return 1 end } } } end
			if path == "bad::/remote_probe_ext.lua" then error("[string \"bad\"]:3: '=' expected near 'x'") end
			error("resource " .. path .. " is unknown")
		end
		local answers = {}
		local x = dofile(root .. "/content/remote_modext.lua").new({ core = core, mod = "hummer_remote_probe",
			answer = function(id, p) answers[id] = p end,
			failWith = function(id, msg, extra) local p = { ok = false, error = msg }; for k, v in pairs(extra or {}) do p[k] = v end; answers[id] = p end,
			appTime = function() return 0 end, try = function(fn) local ok, v = pcall(fn); return ok and v or nil end,
			say = function(m) said[#said + 1] = m end, now = function() return {} end, requires = { rq },
			installed = function() return { "good", "bad", "other", "hummer_remote_probe" } end })
		x.handlers.modList({ id = 1, args = {} })
		eq(answers[1].checked, 3)
		eq(#answers[1].mods, 1); eq(answers[1].mods[1].mod, "good")
		eq(#answers[1].broken, 1); eq(answers[1].broken[1].mod, "bad")
		x.handlers.modRead({ id = 2, args = { mod = "other", command = "a" } })
		eq(answers[2].kind, "noExt")
		x.handlers.modRead({ id = 3, args = { mod = "good", command = "a" } })
		eq(answers[3].ok, true); eq(answers[3].result, 1)
	end)
end
