-- eval and eval --write (content/remote_eval.lua, the eval section of content/remote_core.lua, eval in
-- content/remote_gs.script.lua). Run from tests/run.lua, which hands in its helpers.
return function(h)
	local test, eq, truthy, fake, core = h.test, h.eq, h.truthy, h.fake, h.core
	local send, frames, final, FIRST = h.send, h.frames, h.final, h.FIRST

	local function game(opts, spec)
		opts = opts or {}
		if not opts.gameScriptOff then opts.modParams = { hummer_remote_probe = { gameScript = 2 } } end
		local g = h.vehicleGame(opts)
		fake.installRunningCosts(g, spec)
		return g
	end
	local function run(g, id, cmd, argsLua, n)
		send(g, id, cmd, argsLua)
		frames(g, n or FIRST + 20)
		return final(g, id)
	end
	-- args as tf3ctl sends them: the code quoted, the loaded save named
	local function args(code, extra)
		return string.format("{ code = %q%s }", code, extra or "")
	end
	local function here(code, write, opts)
		local captured = {}
		local env = core.evalEnv({ write = write, captured = captured })
		local r = core.evalRun(code, env, opts)
		r.print = captured.print
		return r, env
	end

	test("core.evalArgs: the code, depth and maxChars in range, gs; evalWrite needs a test save's name", function()
		local a = core.evalArgs({ code = "1" })
		eq(a.code, "1"); eq(a.depth, core.EVAL_DEPTH); eq(a.maxChars, core.EVAL_CHARS); eq(a.gs, false)
		for _, c in ipairs({ false, "", "   \n\t" }) do
			truthy(select(2, core.evalArgs({ code = c or nil })):find("give the Lua code"), tostring(c))
		end
		truthy(select(2, core.evalArgs({})):find("give the Lua code"))
		truthy(select(2, core.evalArgs(nil)):find("give the Lua code"))
		truthy(select(2, core.evalArgs({ code = 5 })):find("give the Lua code"))
		truthy(select(2, core.evalArgs({ code = string.rep("x", core.EVAL_CODE_MAX + 1) })):find("longer than"))
		eq(core.evalArgs({ code = "1", depth = 16 }).depth, 16)
		truthy(select(2, core.evalArgs({ code = "1", depth = 0 })):find("depth"))
		truthy(select(2, core.evalArgs({ code = "1", depth = 17 })):find("depth"))
		truthy(select(2, core.evalArgs({ code = "1", depth = 2.5 })):find("depth"))
		truthy(select(2, core.evalArgs({ code = "1", maxChars = 999 })):find("maxChars"))
		truthy(select(2, core.evalArgs({ code = "1", maxChars = core.EXT_RESULT_MAX + 1 })):find("maxChars"))
		truthy(select(2, core.evalArgs({ code = "1", gs = "yes" })):find("gs must be"))
		eq(core.evalArgs({ code = "1", gs = true }).gs, true)
		-- write: the loaded save's name, by the same rules as the other test-save commands
		local w = core.evalArgs({ code = "1", _testSave = "probe-eval" }, true)
		eq(w.testSave, "probe-eval")
		eq(core.evalArgs({ code = "1", _testSave = "3-probe" }, true).testSave, "3-probe")
		for _, save in ipairs({ "aom-eu-1900", "12-probe", "", false }) do
			local _, e = core.evalArgs({ code = "1", _testSave = save or nil }, true)
			truthy(e and e:find("test saves only"), tostring(save))
		end
		-- (eval itself does not look at the save)
		eq(core.evalArgs({ code = "1", _testSave = "aom-eu-1900" }).code, "1")
	end)

	test("core.evalEnv (read only): no api.cmd, api.gui, writers under api, app, game, io, package, debug", function()
		local r = here("api.cmd == nil and api.gui == nil and api.engine ~= nil")
		eq(r.ok, true, tostring(r.error)); eq(r.value, true)
		for _, name in ipairs(core.EVAL_BLOCKED) do
			local x = here(name)
			eq(x.ok, true); eq(x.value, nil, name .. " is gone")
		end
		eq(here("api.util.getApplicationTime ~= nil").value, true, "readers stay")
		api.util.setTestingFlag = function() error("written") end
		api.util.saveTestingThing = function() error("written") end
		local w = here("api.util.setTestingFlag == nil and api.util.saveTestingThing == nil")
		api.util.setTestingFlag, api.util.saveTestingThing = nil, nil
		eq(w.value, true, "functions named as writers are gone under api")
		eq(here("os.time ~= nil and os.date ~= nil and os.execute == nil and os.remove == nil and os.exit == nil").value, true)
		-- the libraries are views: no write reaches the real tables
		local s = here("string.evalTest = 1")
		eq(s.ok, false); eq(s.kind, "runtime"); truthy(s.error:find("reads only"), s.error); eq(string.evalTest, nil)
		eq(here("api.engine.evalTest = 1").ok, false); eq(api.engine.evalTest, nil)
		eq(here("getmetatable('').__index = nil").ok, false)
		eq(type(getmetatable("").__index), "table", "the strings' metatable untouched")
		eq(here("setmetatable(string, {})").ok, false)
		-- require: no way to the real globals; a module comes back as a view
		truthy(here("require('_G')").error:find("not here"))
		truthy(here("require('debug')").error:find("not here"))
		local m = here("local c = require('hummer_remote_probe::/remote_core.lua') c.EVAL_DEPTH = 1")
		eq(m.ok, false); eq(core.EVAL_DEPTH, 6)
		eq(here("require('hummer_remote_probe::/remote_core.lua').MOD_ID").value, core.MOD_ID)
		-- load: text only, and in this environment
		eq(here("load('return api.cmd == nil')()").value, true)
		eq(here("load(string.dump(function() end))").ok, true)
		eq(here("select(2, load(function() return 'x' end))").value, "eval's load takes a string only")
		-- a global the code makes stays in its environment
		local g, env = here("evalMade = 5 return evalMade")
		eq(g.value, 5); eq(rawget(_G, "evalMade"), nil); eq(rawget(env, "evalMade"), 5)
		eq(here("_G.api.cmd").value, nil, "_G is the environment")
	end)

	test("core.evalEnv (write): every global; app's save entry points raise, its other members are app's", function()
		local saved = #(app.evalSaves or {})
		local r = here("api.cmd ~= nil and io ~= nil and debug ~= nil and game == nil", true)
		eq(r.ok, true, tostring(r.error)); eq(r.value, true)
		for _, n in ipairs(core.EVAL_SAVE_NAMES) do
			local x = here("app." .. n .. "('probe-x')", true)
			eq(x.ok, false, n); truthy(x.error:find(core.EVAL_SAVE_REFUSAL, 1, true), x.error)
			local y = here("app:" .. n .. "('probe-x')", true)
			eq(y.ok, false, n .. " as a method")
		end
		eq(#(app.evalSaves or {}), saved)
		eq(here("type(app.loadUserdata)", true).value, "function")
		eq(here("app.findAllSavegames ~= nil", true).value, true)
		-- a global the code makes stays in its environment
		local _, env = here("evalWritten = 1", true)
		eq(rawget(_G, "evalWritten"), nil); eq(rawget(env, "evalWritten"), 1)
	end)

	test("core.evalRun: an expression or statements, several values, nil, compile and runtime errors", function()
		eq(here("1 + 1").value, 2)
		eq(here("local x = 3 return x * 2").value, 6)
		local p = here("print('a', nil, 3) print('b')")
		eq(p.ok, true); eq(p.n, 0); eq(p.value, nil); eq(table.concat(p.print, "|"), "a\tnil\t3|b")
		local n = here("nil")
		eq(n.ok, true); eq(n.n, 1); eq(n.value, nil)
		local none = here("local x = 1")
		eq(none.ok, true); eq(none.n, 0); eq(none.value, nil)
		local three = here("1, nil, 'x'")
		eq(three.n, 3); eq(three.value, 1); eq(table.concat(three.values, ","), "1,<nil>,x")
		local c = here("x = = 1")
		eq(c.ok, false); eq(c.kind, "compile"); truthy(c.error:find("eval:1"), c.error)
		local e = here("local t = nil return t.x", false, { traceback = debug.traceback })
		eq(e.ok, false); eq(e.kind, "runtime"); truthy(e.error:find("eval:1"), e.error); truthy(e.traceback and e.traceback:find("traceback"), "a traceback")
		eq(here("error('x')").traceback, nil, "none without debug.traceback")
		local tbl = here("error({ code = 5 })")
		eq(tbl.ok, false); eq(tbl.kind, "runtime"); truthy(tbl.error:find("table"), tbl.error)
		local t = here("os.time()", false, { clock = os.clock })
		eq(type(t.ms), "number")
		-- print's lines are capped
		local many = here("for i = 1, " .. (core.EVAL_PRINT_LINES + 10) .. " do print(i) end")
		eq(#many.print, core.EVAL_PRINT_LINES)
		local cap = {}
		local env = core.evalEnv({ captured = cap })
		core.evalRun("print(string.rep('y', " .. (core.EVAL_PRINT_CHARS + 5) .. "))", env)
		eq(cap.printTruncated, true); truthy(#cap.print[1] <= core.EVAL_PRINT_CHARS + 20)
	end)

	test("core.evalDump: cycles, depth, the size budget, userdata, functions, NaN, keys", function()
		local t = { name = "a" }
		t.self = t
		t.list = { t, 2 }
		local d = core.evalDump(t)
		eq(d.value.self, "<cycle>"); eq(d.value.list[1], "<cycle>"); eq(d.value.list[2], 2); eq(d.truncated, false)
		-- a table met twice, not inside itself, is no cycle
		local shared = { 1 }
		eq(core.evalDump({ a = shared, b = shared }).value.b[1], 1)
		local deep = core.evalDump({ { { { 1 } } } }, { depth = 2 })
		eq(deep.value[1][1], "<depth limit: table>"); eq(deep.truncated, true)
		local f = core.evalDump({ f = print, co = coroutine.create(function() end), nan = 0 / 0, inf = 1 / 0, ninf = -1 / 0 })
		eq(f.value.f, "<function>"); eq(f.value.co, "<thread>"); eq(f.value.nan, "nan"); eq(f.value.inf, "inf")
		eq(f.value.ninf, "-inf")
		local keys = core.evalDump({ [1] = "a", [3] = "c", x = 1, [true] = 2 })
		eq(keys.value["1"], "a"); eq(keys.value["3"], "c"); eq(keys.value["true"], 2)
		eq(core.json(core.evalDump({ [1] = "a", ["1"] = "b" }).value), '{"1":"b","1 (2)":"a"}')
		eq(core.json(core.evalDump({}).value), "{}")
		-- the budget: a long string cut, a long list cut, and the whole value checked once more
		local s = core.evalDump(string.rep("a", 5000), { maxChars = 1000 })
		eq(s.truncated, true); truthy(s.value:find("<truncated: %d+ more chars>$"), s.value:sub(-40))
		truthy(#core.json(s.value) <= 1000, #core.json(s.value))
		local big = {}
		for i = 1, 3000 do big[i] = i end
		local l = core.evalDump(big, { maxChars = 1000 })
		eq(l.truncated, true); truthy(l.value[#l.value]:find("<truncated: %d+ more>"), tostring(l.value[#l.value]))
		local r = here("local t = {} for i = 1, 5000 do t['k' .. i] = i end return t", false, { maxChars = 1000 })
		eq(r.truncated, true); truthy(#core.json(r.value) <= 1000, #core.json(r.value))
		-- userdata: walked with pairs when it can be, else as a list, else its tostring
		local u = newproxy(true)
		local mt = getmetatable(u)
		mt.__len = function() return 2 end
		mt.__index = function(_, i) return ({ 10, 20 })[i] end
		local ud = core.evalDump(u)
		eq(ud.value[1], 10); eq(ud.value[2], 20)
		local opaque = newproxy(true)
		getmetatable(opaque).__tostring = function() return "Vec3f(1, 2, 3)" end
		eq(core.evalDump(opaque).value, "Vec3f(1, 2, 3)")
		local raising = newproxy(true)
		getmetatable(raising).__index = function() error("no member") end
		getmetatable(raising).__len = function() error("no length") end
		truthy(type(core.evalDump(raising).value) == "string")
		local ok = pcall(core.json, core.evalDump({ u = u, o = opaque, r = raising }).value)
		eq(ok, true)
		-- a read-only view shows the table it views
		local v = here("{ api = api.util }")
		eq(type(v.value.api.getApplicationTime), "string")
	end)

	test("eval through the game: the value, print, no api.cmd and nothing sent; errors as kind", function()
		local g = game({ gameScriptOff = true })
		local sent = #g.commands
		local a = run(g, 3701, "eval", args("print('hi') return { cmd = api.cmd, t = api.util.getApplicationTime() > 0 }"))
		eq(a.ok, true, tostring(a.error)); eq(a.where, "gui"); eq(a.value.cmd, nil); eq(a.value.t, true)
		eq(a.print[1], "hi"); eq(a.printTruncated, false); eq(type(a.ms), "number"); eq(a.n, 1)
		eq(#g.commands, sent, "no command sent")
		local tried = run(g, 3702, "eval", args("api.cmd.sendCommand(api.cmd.make())"), 20)
		eq(tried.ok, false); eq(tried.kind, "runtime"); truthy(tried.error:find("the code raised"), tried.error)
		eq(#g.commands, sent)
		local c = run(g, 3703, "eval", args("return return"), 20)
		eq(c.ok, false); eq(c.kind, "compile"); truthy(c.error:find("does not compile"), c.error)
		local empty = run(g, 3704, "eval", args(""), 20)
		eq(empty.ok, false); truthy(empty.error:find("give the Lua code"), empty.error)
		local none = run(g, 3705, "eval", "{ }", 20)
		eq(none.ok, false); truthy(none.error:find("give the Lua code"), none.error)
		local n = run(g, 3706, "eval", args("nil"), 20)
		eq(n.ok, true); eq(n.value, nil); eq(n.n, 1)
		-- a cycle and userdata from the engine's side come back as JSON
		local cy = run(g, 3707, "eval", args("local t = {} t.t = t return t"), 20)
		eq(cy.value.t, "<cycle>")
		-- (eval only reads: no "who used the game" entry)
		local st = run(g, 3708, "status", "{ }", 20)
		eq(st.lastAction, nil)
		eq(#g.globalWrites, 0, "no global made: " .. table.concat(g.globalWrites, ","))
	end)

	test("eval --write through the game: test saves only; it runs with every global; app does not save", function()
		local g = game({ gameScriptOff = true })
		local saves = #g.saved
		local refused = run(g, 3711, "evalWrite", args("evalWriteRan = true", ', _testSave = "aom-eu-1900"'))
		eq(refused.ok, false); truthy(refused.error:find("test saves only"), refused.error)
		local missing = run(g, 3712, "evalWrite", args("evalWriteRan = true"), 20)
		eq(missing.ok, false); truthy(missing.error:find("test saves only"), missing.error)
		local sent = #g.commands
		local a = run(g, 3713, "evalWrite", args("api.cmd.sendCommand({ kind = 'evalTest' }) return io ~= nil",
			', _testSave = "probe-eval"'), 20)
		eq(a.ok, true, tostring(a.error)); eq(a.value, true); eq(#g.commands, sent + 1)
		for i, n in ipairs(core.EVAL_SAVE_NAMES) do
			local s = run(g, 3713 + i, "evalWrite", args("app." .. n .. "('probe-eval', function() end)",
				', _testSave = "probe-eval"'), 20)
			eq(s.ok, false, n); truthy(s.error:find(core.EVAL_SAVE_REFUSAL, 1, true), s.error)
		end
		eq(#g.saved, saves, "no save made")
		local st = run(g, 3719, "status", "{ }", 20)
		eq(st.lastAction and st.lastAction.cmd, "evalWrite")
		eq(#g.globalWrites, 0, "no global made: " .. table.concat(g.globalWrites, ","))
	end)

	test("eval --gs: the game script runs the code and answers in its state; refused without gameScript", function()
		local off = game({ gameScriptOff = true })
		local o = run(off, 3721, "eval", args("1", ", gs = true"))
		eq(o.ok, false); truthy(o.error:find("gameScript=2"), o.error); eq(off.runcostEvents, nil, "nothing sent")
		local g = game()
		frames(g, 5)
		truthy(g.gsSubs[core.EVAL_EVENT_READ] and g.gsSubs[core.EVAL_EVENT_WRITE], "subscribed with gameScript on")
		local a = run(g, 3722, "eval", args("print('in gs') return { cmd = api.cmd, n = 2 }", ", gs = true"))
		eq(a.ok, true, tostring(a.error)); eq(a.where, "script"); eq(a.value.n, 2); eq(a.value.cmd, nil)
		eq(a.print[1], "in gs"); eq(type(a.waitedSec), "number")
		eq(g.runcostEvents, 1); eq(g.gsDelivered[1].name, core.EVAL_EVENT_READ)
		eq(g.gsValue.eval.req, 3722)
		-- errors come back the same way
		local e = run(g, 3723, "eval", args("error('gs boom')", ", gs = true"))
		eq(e.ok, false); eq(e.kind, "runtime"); eq(e.where, "script"); truthy(e.error:find("gs boom"), e.error)
		-- write: refused in the GUI before anything is sent, on a person's save
		local events = g.runcostEvents
		local w = run(g, 3724, "evalWrite", args("1", ', gs = true, _testSave = "aom-eu-1900"'), 20)
		eq(w.ok, false); truthy(w.error:find("test saves only"), w.error); eq(g.runcostEvents, events)
		local ok = run(g, 3725, "evalWrite", args("evalGsMade = 1 return api.cmd ~= nil", ', gs = true, _testSave = "probe-eval"'))
		eq(ok.ok, true, tostring(ok.error)); eq(ok.value, true); eq(g.gsDelivered[#g.gsDelivered].name, core.EVAL_EVENT_WRITE)
		eq(rawget(_G, "evalGsMade"), nil)
		eq(#g.globalWrites, 0, "no global made: " .. table.concat(g.globalWrites, ","))
	end)

	test("eval --gs in the game script: a hand-sent request is checked again, a repeat dropped, the answer cleared", function()
		local g = game()
		frames(g, 5)
		local gs, state = g.gs, g.gsState
		-- a write request for a person's save (as script-event could not send it, but another mod's code could)
		local r = core.evalRequest(41, { code = "evalHand = 1", depth = 6, maxChars = 1000, testSave = "aom-eu-1900" }, true)
		gs.handleEvent(nil, state, "", core.RUNCOST_EVENT_ID, core.EVAL_EVENT_WRITE, r)
		eq((g.gsValue or {}).eval, nil, "refused: nothing written"); eq(rawget(_G, "evalHand"), nil)
		-- a request whose write does not match the event's name
		local mixed = core.evalRequest(42, { code = "1", depth = 6, maxChars = 1000, testSave = "probe-x" }, true)
		gs.handleEvent(nil, state, "", core.RUNCOST_EVENT_ID, core.EVAL_EVENT_READ, mixed)
		eq((g.gsValue or {}).eval, nil)
		-- run once; the same req again is dropped
		local once = core.evalRequest(43, { code = "print('x') return 1", depth = 6, maxChars = 1000 }, false)
		gs.handleEvent(nil, state, "", core.RUNCOST_EVENT_ID, core.EVAL_EVENT_READ, once)
		eq(g.gsValue.eval.req, 43); eq(g.gsValue.eval.result.value, 1)
		g.gsValue.eval.result.value = "kept"
		gs.handleEvent(nil, state, "", core.RUNCOST_EVENT_ID, core.EVAL_EVENT_READ, once)
		eq(g.gsValue.eval.result.value, "kept", "not run twice")
		-- the game script is off: nothing runs
		local cleared = core.evalRequestChecked(nil)
		eq(cleared, nil)
		-- cleared after EVAL_KEEP_SEC (update reads the setting again every few seconds)
		g.gsValue.eval.at = os.time() - core.EVAL_KEEP_SEC - 1
		gs._resetForTests()
		gs.update(nil, state, 1 / 30)
		eq(g.gsValue.eval, nil, "cleared")
		-- a fresh answer stays
		gs.handleEvent(nil, state, "", core.RUNCOST_EVENT_ID, core.EVAL_EVENT_READ,
			core.evalRequest(44, { code = "2", depth = 6, maxChars = 1000 }, false))
		gs._resetForTests()
		gs.update(nil, state, 1 / 30)
		eq(g.gsValue.eval.req, 44)
	end)

	test("script-event still refuses the probe's own id (eval --gs goes through eval only)", function()
		local _, err = core.scriptEventRequest({ id = core.RUNCOST_EVENT_ID, name = core.EVAL_EVENT_WRITE, param = {} })
		truthy(err and err:find("probe's own") and err:find("eval %-%-gs"), err)
	end)
end
