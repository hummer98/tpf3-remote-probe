-- Offline tests for the remote probe.  luajit tests/run.lua
-- Pure logic (content/remote_core.lua) plus the real content/remote.script.lua over tests/fake_game.lua.
local root = (arg and arg[0] or "tests/run.lua"):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. package.path

local failures, passes = 0, 0
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then passes = passes + 1; print("PASS " .. name)
	else failures = failures + 1; print("FAIL " .. name .. "\n     " .. tostring(err)) end
end
local function eq(a, b, msg)
	if a ~= b then error((msg or "values differ") .. ": " .. tostring(a) .. " ~= " .. tostring(b), 2) end
end
local function truthy(v, msg) if not v then error(msg or "expected a true value", 2) end end

local fake = dofile(root .. "/tests/fake_game.lua")
local core = require "hummer_remote_probe::/remote_core.lua"

---------------------------------------------------------------------------------------------------------------------
-- core

test("json: an empty table marked a list is [], unmarked it stays {}; marking changes nothing else", function()
	eq(core.json(core.array({})), "[]")
	eq(core.json({}), "{}")
	eq(core.json({ a = core.array({}), b = {} }), '{"a":[],"b":{}}')
	eq(core.json(core.array({ 1, 2 })), "[1,2]")
	eq(core.json(core.array({ x = 1 })), '{"x":1}') -- a marked table with keys is still an object
	eq(core.array(nil), nil)
	eq(core.array(5), 5)
end)

test("json: scalars, escapes, arrays, sorted objects, non-finite numbers", function()
	eq(core.json(nil), "null")
	eq(core.json(true), "true")
	eq(core.json(3), "3")
	eq(core.json(0.5), "0.5")
	eq(core.json(0 / 0), "null")
	eq(core.json(math.huge), "null")
	eq(core.json('a"b\\c\n\1'), '"a\\"b\\\\c\\n\\u0001"')
	eq(core.json({ 1, 2, "x" }), '[1,2,"x"]')
	eq(core.json({ b = 1, a = { c = false } }), '{"a":{"c":false},"b":1}')
	eq(core.json({}), "{}")
	eq(core.json({ [1] = "a", [3] = "c" }), '{"1":"a","3":"c"}', "sparse lists are objects")
	eq(core.json("日本"), '"日本"', "UTF-8 passes through")
end)

test("json: cycles do not hang", function()
	local t = {}
	t.self = t
	eq(core.json(t), '{"self":"<cycle>"}')
end)

test("readCommand: new ids only, unknown commands answered with an error", function()
	eq(core.readCommand(nil, 0), nil)
	eq(core.readCommand({ id = 0 }, 0), nil, "the file the mod creates")
	eq(core.readCommand({ id = 5, cmd = "status" }, 5), nil, "already done")
	local c = core.readCommand({ id = 6, cmd = "status" }, 5)
	eq(c.id, 6); eq(c.cmd, "status"); eq(type(c.args), "table")
	local bad = core.readCommand({ id = 7, cmd = "format_disk" }, 6)
	eq(bad.id, 7); truthy(bad.error:find("unknown command"))
	eq(core.readCommand({ id = "8", cmd = "speed", args = "x" }, 0).args.x, nil, "non-table args become {}")
end)

test("speedArg: whole numbers from 0, no cap at the UI's 4x", function()
	eq(core.speedArg(0), 0)
	eq(core.speedArg(64), 64)
	eq(core.speedArg("16"), 16)
	eq(core.speedArg(2.4), 2)
	eq(core.speedArg(-1), nil)
	eq(core.speedArg("fast"), nil)
	eq(core.speedArg(0 / 0), nil)
	eq(core.speedArg(1e9), nil)
end)

test("dates: parse, add months (day clamped), add days across months and years", function()
	local d = core.parseDate("1934-09-01")
	eq(d.year, 1934); eq(d.month, 9); eq(d.day, 1)
	eq(core.parseDate("1934").month, 1)
	eq(core.parseDate("soon"), nil)
	local m = core.addMonths({ year = 1934, month = 1, day = 31 }, 1)
	eq(m.month, 2); eq(m.day, 28)
	m = core.addMonths({ year = 1934, month = 11, day = 5 }, 2)
	eq(m.year, 1935); eq(m.month, 1); eq(m.day, 5)
	local a = core.addDays({ year = 1934, month = 12, day = 30 }, 3)
	eq(a.year, 1935); eq(a.month, 1); eq(a.day, 2)
	a = core.addDays({ year = 1934, month = 2, day = 27 }, 2)
	eq(a.month, 3); eq(a.day, 1)
end)

test("runTarget: months, days, untilDate; refuses targets in the past and bad input", function()
	local now = { date = { year = 1934, month = 7, day = 10 } }
	eq(core.runTarget({ months = 2 }, now).key, 19340910)
	eq(core.runTarget({ days = 25 }, now).key, 19340804)
	eq(core.runTarget({ untilDate = "1935-01-01" }, now).key, 19350101)
	truthy(select(2, core.runTarget({ untilDate = "1934-07-10" }, now)):find("not after"))
	truthy(select(2, core.runTarget({ months = 0 }, now)))
	truthy(select(2, core.runTarget({ months = 1.5 }, now)))
	truthy(select(2, core.runTarget({}, now)))
	truthy(select(2, core.runTarget({ months = 1 }, {})):find("unknown"))
end)

test("reached: compares calendar dates", function()
	local t = core.runTarget({ months = 1 }, { date = { year = 1934, month = 7, day = 10 } })
	eq(core.reached(t, { date = { year = 1934, month = 8, day = 9 } }), false)
	eq(core.reached(t, { date = { year = 1934, month = 8, day = 10 } }), true)
	eq(core.reached(t, { date = { year = 1934, month = 8, day = 12 } }), true, "a frame may skip past the day")
	eq(core.reached(t, {}), false)
end)

test("meter: samples once per real second, summary over the whole run", function()
	local m = core.newMeter(0, 100)
	eq(core.meterStep(m, 8000, 100.5, 10), nil, "under a second")
	eq(core.meterStep(m, 16000, 101, 10), 16)
	eq(core.meterStep(m, 48000, 102, 20), 32)
	local s = core.meterSummary(m, 48000, 102)
	eq(s.realSec, 2); eq(s.gameSec, 48); eq(s.overall, 24)
	eq(s.perSecond.min, 16); eq(s.perSecond.max, 32); eq(s.perSecond.n, 2)
	eq(s.estimatedMax.max, 20)
	eq(core.meterSummary(core.newMeter(0, 5), 0, 5).perSecond, nil)
end)

test("mergeMods: add/remove/set, no duplicates, the probe always stays", function()
	local cur = { "a", "b", "hummer_remote_probe" }
	local r = core.mergeMods(cur, { add = { "c", "a" }, remove = { "b" } }, "hummer_remote_probe")
	eq(table.concat(r, ","), "a,hummer_remote_probe,c")
	r = core.mergeMods(cur, { remove = { "hummer_remote_probe" } }, "hummer_remote_probe")
	eq(table.concat(r, ","), "a,b,hummer_remote_probe", "cannot remove itself")
	r = core.mergeMods({ "a" }, { set = { "x", "y" } }, "hummer_remote_probe")
	eq(table.concat(r, ","), "x,y,hummer_remote_probe", "set replaces the list, probe appended")
	r = core.mergeMods(nil, nil, "hummer_remote_probe")
	eq(table.concat(r, ","), "hummer_remote_probe")
	r = core.mergeMods({ "a", "", 5 }, {}, "p")
	eq(table.concat(r, ","), "a,p", "junk entries dropped")
end)

test("mergeParams: copies, overrides, rejects non-index values, base game key", function()
	local cur = { [""] = { ["map.size"] = 4 }, m = { a = 1, b = 2 } }
	local r = core.mergeParams(cur, { m = { a = 3 }, n = { z = 2 } })
	eq(r.m.a, 3); eq(r.m.b, 2); eq(r.n.z, 2); eq(r[""]["map.size"], 4)
	eq(cur.m.a, 1, "the save's table is untouched")
	r = core.mergeParams(nil, { m = { a = "2" } })
	eq(r.m.a, 2)
	local bad, err = core.mergeParams(cur, { m = { a = 0 } })
	eq(bad, nil); truthy(err:find("1%-based"))
	eq(core.mergeParams(cur, { m = { a = 1.5 } }), nil)
end)

test("size/at/toList/plain: tables and userdata vectors", function()
	local u = newproxy(true)
	local mt = getmetatable(u)
	local items = { "x", "y" }
	mt.__len = function() return #items end
	mt.__index = function(_, i) return items[i] end
	eq(core.size(u), 2); eq(core.at(u, 2), "y")
	eq(table.concat(core.toList(u), ","), "x,y")
	eq(core.size(nil), 0)
	eq(#core.toList({ 1, 2, 3 }), 3)
	local p = core.plain({ m = { a = 1 }, [""] = { k = 2 } })
	eq(p.m.a, 1); eq(p[""].k, 2)
	eq(type(core.plain(u)), "string", "an opaque userdata becomes its tostring")
	eq(core.plain(5), 5)
end)

---------------------------------------------------------------------------------------------------------------------
-- the real script over the fake game

local tmpBase = os.getenv("TMPDIR") or "/tmp"
local function tempDir()
	local d = os.tmpname()
	os.remove(d)
	os.execute("mkdir -p '" .. d .. "'")
	return d
end

-- the game, and g.x = the folder the probe settled on (recordings unless opts.droppingDirs says otherwise)
local function newGame(opts, xdir)
	local g = fake.new(tempDir(), opts)
	g.x = g.dir .. "/" .. (xdir or "recordings")
	return g
end

local function files(dir, pattern)
	local out = {}
	local p = io.popen("ls '" .. dir .. "' 2>/dev/null")
	for name in p:lines() do if name:match(pattern) then out[#out + 1] = name end end
	p:close()
	table.sort(out)
	return out
end

local function readJson(dir, name)
	local f = assert(loadfile(dir .. "/" .. name))
	local env = {}
	setfenv(f, env)
	f()
	return env.data().json
end

local function stampOf(dir)
	local h = files(dir, "^remote_probe__hello_")
	return h[#h]:match("^remote_probe__hello_(.*)%.lua$")
end

-- the same text tools/tf3ctl.py writes (command_text), so the two stay in step
local function send(g, id, cmd, argsLua)
	local f = assert(io.open(g.x .. "/remote_probe__cmd_" .. stampOf(g.x) .. ".lua", "w"))
	f:write(string.format("function data()\nreturn { id = %d, cmd = %q, args = %s }\nend\n", id, cmd, argsLua or "{  }"))
	f:close()
end

local function frames(g, n, dt) for _ = 1, n do g.step(dt) end end

-- the first command after a boot is picked up by the idle poll (every 2 s), later ones within 0.25 s
local FIRST = 80

local function answerText(g, id, tag)
	local name = "remote_probe__res_" .. id .. (tag and ("_" .. tag) or "") .. ".lua"
	local f = io.open(g.x .. "/" .. name)
	if not f then return nil end
	f:close()
	return readJson(g.x, name)
end

local SAVES = {
	{ saveName = "probe", path = "/s/probe.sav", timestamp = 2, size = 1, mods = { "m1", "hummer_remote_probe" },
		modParams = { m1 = { a = 1 }, [""] = { ["map.size"] = 4 } } },
	{ saveName = "bare", path = "/s/bare.sav", timestamp = 1, size = 1, mods = { "m1" } },
}

test("boot: hello and an id-0 command file in the first folder that keeps files", function()
	local g = newGame({ saves = SAVES })
	frames(g, 1)
	eq(#files(g.x, "^remote_probe__hello_"), 1)
	eq(#files(g.x, "^remote_probe__cmd_"), 1)
	local hello = readJson(g.x, files(g.x, "^remote_probe__hello_")[1])
	truthy(hello:find('"version":7'), hello)
	truthy(hello:find('"menu":false'), hello)
	truthy(hello:find('"dir":"recordings"'), hello)
	truthy(g.logs[1]:find("ready"), g.logs[1])
end)

test("status: answers with the game state; the same id is not answered twice", function()
	local g = newGame({ saves = SAVES, maxSpeed = 7 })
	frames(g, 2)
	send(g, 11, "status")
	frames(g, FIRST)
	local a = answerText(g, 11)
	truthy(a and a:find('"ok":true'), a)
	truthy(a:find('"estimatedMaxSpeed":7'), a)
	truthy(a:find('"date":{"day":'), a)
	local n = #g.logs
	frames(g, 200)
	eq(#g.logs, n, "no second run of command 11")
end)

test("unknown command: an _error answer, nothing else happens", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 12, "rm")
	frames(g, FIRST)
	local a = answerText(g, 12, "error")
	truthy(a and a:find("unknown command"), a)
end)

test("speed: capped at the game's estimate unless forced; bad values are refused", function()
	local g = newGame({ saves = SAVES, maxSpeed = 4 })
	frames(g, 2)
	send(g, 13, "speed", "{ speed = 16 }")
	frames(g, FIRST)
	eq(g.speedup, 4, "the estimate")
	truthy(answerText(g, 13):find('"capped":true'))
	truthy(answerText(g, 13):find('"requested":16'))
	send(g, 12, "speed", "{ speed = 16, force = true }")
	frames(g, 20)
	eq(g.speedup, 16, "forced past the estimate")
	send(g, 14, "speed", "{ speed = -3 }")
	frames(g, 20)
	truthy(answerText(g, 14, "error"))
	eq(g.speedup, 16)
end)

test("run: speeds up, stops on the target date with speed 0, reports measured speed", function()
	local g = newGame({ saves = SAVES, maxSpeed = 10 })
	frames(g, 2)
	send(g, 20, "run", "{ months = 6, speed = 64 }")
	local guard = 0
	while not answerText(g, 20) and guard < 20000 do g.step(1 / 30); guard = guard + 1 end
	local a = answerText(g, 20)
	truthy(a, "no answer after " .. guard .. " frames")
	eq(g.speedup, 0, "paused at the end")
	eq(g.commands[1].speed, 10, "64 asked, the game's estimate of 10 sent")
	truthy(a:find('"requested":64'), a)
	-- the command is picked up within the 2 s idle poll, i.e. on 1900-01-01 or -02 at 1x in this fake
	local from = a:match('"from":{"day":(%d+),"month":1,"year":1900}')
	truthy(from, a)
	local d = g.date()
	eq(d.year, 1900); eq(d.month, 7)
	truthy(d.day >= tonumber(from) and d.day <= tonumber(from) + 1, "stopped within a day of the target, on day " .. d.day)
	truthy(a:find('"target":{"day":' .. from .. ',"month":7,"year":1900}'), a)
	-- the fake caps at 10x, as the CPU would: the report must show the real rate, not the request
	local overall = tonumber(a:match('"overall":([%d%.]+)'))
	truthy(overall and overall > 9 and overall < 10.5, "measured x" .. tostring(overall))
	truthy(#files(g.x, "^remote_probe__res_20_p") > 0, "progress answers were written")
end)

test("run: a speed command cancels it with an error answer", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 21, "run", "{ months = 6, speed = 2 }")
	frames(g, FIRST)
	send(g, 22, "speed", "{ speed = 0 }")
	frames(g, 30)
	truthy((answerText(g, 21, "error") or ""):find("cancelled"))
	eq(g.speedup, 0)
	frames(g, 300)
	eq(answerText(g, 21), nil, "no late success answer")
end)

test("run: refuses a target in the past", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 23, "run", '{ untilDate = "1899-01-01" }')
	frames(g, FIRST)
	truthy((answerText(g, 23, "error") or ""):find("not after"))
	eq(g.speedup, 1, "speed untouched")
end)

test("saves and info: list, then the save's mods and params after the async info arrives", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 30, "saves")
	frames(g, FIRST)
	truthy(answerText(g, 30):find('"saveName":"bare"'))
	send(g, 31, "info", '{ save = "probe" }')
	frames(g, 40)
	local a = answerText(g, 31)
	truthy(a and a:find('"mods":%["m1","hummer_remote_probe"%]'), a)
	truthy(a:find('"m1":{"a":1}'), a)
	send(g, 32, "info", '{ save = "nope" }')
	frames(g, 30)
	truthy((answerText(g, 32, "error") or ""):find("no save named"))
end)

test("load dryRun: shows the plan, loads nothing", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 40, "load", '{ save = "bare", mods = { add = { "m2" } }, params = { m1 = { a = 2 } }, dryRun = true }')
	frames(g, FIRST)
	local a = answerText(g, 40)
	truthy(a and a:find('"mods":%["m1","m2","hummer_remote_probe"%]'), a)
	truthy(a:find('"m1":{"a":2}'), a)
	eq(#g.loads, 0)
end)

test("load: ack first, then loadGame with the new mods and params; the probe comes back with a new hello", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	local before = stampOf(g.x)
	send(g, 41, "load", '{ save = "probe", mods = { remove = { "m1" } }, params = { [""] = { ["map.size"] = 2 } } }')
	frames(g, FIRST)
	truthy(answerText(g, 41, "ack"), "ack written")
	eq(#g.loads, 1)
	eq(g.waitedForStart, nil, "no setWaitForStartReadyGame: it would hold the loading screen until a click")
	eq(g.loads[1].id.path, "/s/probe.sav")
	eq(g.loads[1].id.saveGameNamespace, "save")
	local names = {}
	for _, m in ipairs(g.loads[1].info.mods) do names[#names + 1] = m.name end
	eq(table.concat(names, ","), "hummer_remote_probe")
	eq(g.loads[1].info.modParams[""]["map.size"], 2)
	eq(g.loads[1].info.modParams.m1.a, 1, "other params kept")
	frames(g, 3)
	truthy(stampOf(g.x) ~= before, "new hello after the load")
	-- the new game answers commands again, through its own new command file
	send(g, 42, "status")
	frames(g, 80)
	truthy((answerText(g, 42) or ""):find('"map.size":2'), "params of the loaded game")
end)

test("load: bad params answer with an error and load nothing", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 43, "load", '{ save = "probe", params = { m1 = { a = 0 } } }')
	frames(g, FIRST)
	truthy((answerText(g, 43, "error") or ""):find("1%-based"))
	eq(#g.loads, 0)
end)

test("save: saveGame with skipSetName, answered from its callback", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 50, "save", '{ name = "probe-after" }')
	frames(g, FIRST)
	eq(g.saved[1].name, "probe-after")
	eq(g.saved[1].skipSetName, true)
	truthy((answerText(g, 50) or ""):find('"name":"probe%-after"'))
end)

test("a half-written command file is skipped and retried, not fatal", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	local f = assert(io.open(g.x .. "/remote_probe__cmd_" .. stampOf(g.x) .. ".lua", "w"))
	f:write("function data()\nreturn { id = 60, cmd = ")
	f:close()
	frames(g, FIRST) -- an idle poll reads the broken file
	eq(g.script ~= nil, true, "still running")
	send(g, 61, "status")
	frames(g, 60) -- 2 s: would be enough without the back-off
	eq(answerText(g, 61), nil, "backing off after the failed read")
	frames(g, 300) -- the back-off is 10 s
	truthy(answerText(g, 61), "answered after the back-off")
end)

---------------------------------------------------------------------------------------------------------------------
-- fixes after review

test("parseDate: four-digit years, month 1-12, day 1-31", function()
	local d = core.parseDate("19340901")
	eq(d.year, 1934, "YYYYMMDD, not year 19340901"); eq(d.month, 9); eq(d.day, 1)
	eq(core.parseDate("123456789"), nil)
	eq(core.parseDate("1934-13-01"), nil)
	eq(core.parseDate("1934-02-40"), nil)
	eq(core.parseDate("1934-2-5").day, 5)
end)

test("mergeParams: an unreadable engine value is an error, not a silent empty table", function()
	local r, err = core.mergeParams("userdata: 0x1", { m = { a = 1 } })
	eq(r, nil); truthy(err:find("not readable"))
end)

test("boot: falls back to the next folder when recordings keeps nothing, never to the presets first", function()
	local g = newGame({ saves = SAVES, droppingDirs = { "recordings" } }, "keyframes")
	frames(g, 1)
	eq(#files(g.x, "^remote_probe__hello_"), 1)
	eq(#files(g.dir .. "/mod_presets", "^remote_probe__"), 0, "the player's mod preset list stays clean")
	send(g, 70, "status")
	frames(g, FIRST)
	truthy((answerText(g, 70) or ""):find('"dir":"keyframes"'))
end)

test("every command gets a receipt before its answer", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 71, "run", "{ months = 6, speed = 2 }")
	frames(g, FIRST)
	truthy((answerText(g, 71, "got") or ""):find('"got":"run"'))
	eq(answerText(g, 71), nil, "the run itself is still going")
end)

test("run: a second run cancels the first with an error answer", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 72, "run", "{ months = 6, speed = 2 }")
	frames(g, FIRST)
	send(g, 73, "run", "{ days = 3, speed = 2 }")
	frames(g, 30)
	truthy((answerText(g, 72, "error") or ""):find("cancelled: run command 73"))
	frames(g, 200)
	truthy(answerText(g, 73), "the second run finished")
end)

test("run: stops with 'stalled' when game time does not move for 20 s", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 74, "run", "{ months = 6, speed = 8 }")
	frames(g, FIRST)
	g.frozen = true -- paused by a dialog, the player or another mod
	frames(g, 30 * 19)
	eq(answerText(g, 74, "error"), nil, "not yet at 19 s")
	frames(g, 30 * 3)
	truthy((answerText(g, 74, "error") or ""):find("stalled"))
end)

test("run: a refused speed command fails the run at once", function()
	local g = newGame({ saves = SAVES, speedFails = true })
	frames(g, 2)
	send(g, 75, "run", "{ months = 1, speed = 64 }")
	frames(g, FIRST)
	truthy((answerText(g, 75, "error") or ""):find("refused speed"))
end)

test("load: an engine modParams value goes back untouched without --param, and blocks --param", function()
	local g = newGame({ saves = SAVES, opaqueParams = true })
	frames(g, 2)
	send(g, 76, "load", '{ save = "probe", params = { m1 = { a = 2 } } }')
	frames(g, FIRST)
	truthy((answerText(g, 76, "error") or ""):find("not readable"))
	eq(#g.loads, 0)
	send(g, 77, "load", '{ save = "probe" }')
	frames(g, 30)
	eq(#g.loads, 1)
	eq(type(g.loads[1].info.modParams), "userdata", "the save's own object, not a copy")
end)

test("load: waitForStart keeps the base behaviour (Start Game button) on request", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 78, "load", '{ save = "probe", waitForStart = true }')
	frames(g, FIRST)
	eq(g.waitedForStart, true)
end)

test("load: cancels a running run, which answers with an error", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 79, "run", "{ months = 6, speed = 2 }")
	frames(g, FIRST)
	send(g, 80, "load", '{ save = "probe" }')
	frames(g, 30)
	truthy((answerText(g, 79, "error") or ""):find("cancelled: load command 80"))
end)

test("load: nameless mod entries are dropped", function()
	local saves = { { saveName = "s", path = "/s/s.sav", timestamp = 1, size = 1, mods = { "m1", "" } } }
	local g = newGame({ saves = saves })
	frames(g, 2)
	send(g, 81, "load", '{ save = "s", dryRun = true }')
	frames(g, FIRST)
	truthy((answerText(g, 81) or ""):find('"mods":%["m1","hummer_remote_probe"%]'))
end)

test("save: reports an overwrite, and an error when the save is not listed afterwards", function()
	local g = newGame({ saves = { { saveName = "probe", path = "/s/probe.sav", timestamp = 1, size = 1 } } })
	frames(g, 2)
	send(g, 82, "save", '{ name = "probe" }')
	frames(g, FIRST)
	truthy((answerText(g, 82) or ""):find('"overwrote":true'))
	local g2 = newGame({ saveFails = true })
	frames(g2, 2)
	send(g2, 83, "save", '{ name = "new" }')
	frames(g2, FIRST)
	truthy((answerText(g2, 83, "error") or ""):find("not listed"))
end)

test("a deleted command file is made again", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	os.remove(g.x .. "/remote_probe__cmd_" .. stampOf(g.x) .. ".lua")
	frames(g, FIRST)
	eq(#files(g.x, "^remote_probe__cmd_"), 1, "recreated on the next poll")
end)

test("parseDate: days beyond the month's length are refused", function()
	eq(core.parseDate("1934-02-31"), nil)
	eq(core.parseDate("1934-04-31"), nil)
	eq(core.parseDate("1934-02-29").day, 29, "leap days unknown in the game: allowed")
	eq(core.parseDate("1934-12-31").day, 31)
end)

test("run: a save holding game time for 30 s is not a stall", function()
	local g = newGame({ saves = SAVES, saveSeconds = 30 })
	frames(g, 2)
	send(g, 90, "run", "{ months = 6, speed = 2 }")
	frames(g, FIRST)
	send(g, 91, "save", '{ name = "mid-run" }')
	frames(g, 30 * 32)
	truthy(answerText(g, 91), "the save finished")
	eq(answerText(g, 90, "error"), nil, "no stall reported for the save")
	truthy(g.speedup == 2, "the run goes on")
end)

local function runToEnd(g, id)
	local guard = 0
	while not answerText(g, id) and guard < 30000 do g.step(1 / 30); guard = guard + 1 end
	return answerText(g, id), guard
end

test("run: the final answer shows the game paused, after the pause command's result", function()
	local g = newGame({ saves = SAVES, callbackFrames = 5 })
	frames(g, 2)
	send(g, 100, "run", "{ days = 10, speed = 16 }")
	local a = runToEnd(g, 100)
	truthy(a, "answered")
	truthy(a:find('"speedup":0'), "state taken after the pause: " .. a)
	truthy(a:find('"stopConfirmed":true'), a)
end)

test("run: a lost pause callback still gets an answer, marked unconfirmed", function()
	local g = newGame({ saves = SAVES, lostCallbacks = true })
	frames(g, 2)
	send(g, 101, "run", "{ days = 10, speed = 16 }")
	local guard = 0
	while not answerText(g, 101) and g.speedup ~= 0 and guard < 30000 do g.step(1 / 30); guard = guard + 1 end
	eq(g.speedup, 0, "target reached, pause sent")
	frames(g, 30) -- 1 s: still waiting for the callback
	eq(answerText(g, 101), nil, "waits for the callback first")
	frames(g, 45)
	local a = answerText(g, 101)
	truthy(a and a:find('"stopConfirmed":false'), a)
end)

test("run: a load while a finished run waits for the pause result answers the run first", function()
	local g = newGame({ saves = SAVES, callbackFrames = 200 }) -- pause result 6.7 s late
	frames(g, 2)
	send(g, 102, "run", "{ days = 5, speed = 16 }")
	local guard = 0
	-- until the target is reached: the probe has sent the pause and waits for its result
	while not (g.commands[#g.commands] and g.commands[#g.commands].speed == 0) do
		g.step(1 / 30); guard = guard + 1
		assert(guard < 30000, "never reached the target")
	end
	eq(answerText(g, 102), nil, "still waiting for the pause result")
	send(g, 103, "status")
	frames(g, 10)
	truthy((answerText(g, 103) or ""):find('"finishing":true'), "status shows the finishing run")
	send(g, 104, "load", '{ save = "probe" }')
	frames(g, 10)
	local a = answerText(g, 102)
	truthy(a and a:find('"stopConfirmed":false'), "the run answered before the load: " .. tostring(a))
end)

---------------------------------------------------------------------------------------------------------------------
-- settings, poll command, log level, owners

test("options: mod.json indices (1-based from the engine) map to values, defaults otherwise", function()
	local o = core.options(nil)
	eq(o.pollIdle, 2); eq(o.pollActive, 0.25); eq(o.logLevel, 2)
	o = core.options({ pollIdle = 4, pollActive = "1", logLevel = 3 })
	eq(o.pollIdle, 10); eq(o.pollActive, 0.1); eq(o.logLevel, 3)
	eq(core.options({ pollIdle = 9 }).pollIdle, 2, "out of range falls back")
end)

test("pollArgs: ranges, at least one value", function()
	local p = core.pollArgs({ idle = 5 })
	eq(p.idle, 5); eq(p.active, nil)
	eq(core.pollArgs({ active = "0.5" }).active, 0.5)
	truthy(select(2, core.pollArgs({ idle = 30 })):find("between"), "idle capped below the tool's 30 s pickup wait")
	truthy(select(2, core.pollArgs({ active = 0 })))
	truthy(select(2, core.pollArgs({})))
end)

test("owner: a short string or nothing", function()
	eq(core.owner({ _owner = "alice" }), "alice")
	eq(core.owner({}), nil)
	eq(core.owner({ _owner = 5 }), nil)
	eq(#core.owner({ _owner = string.rep("x", 200) }), 64)
end)

local function withProbeParams(p) return { saves = SAVES, modParams = { hummer_remote_probe = p } } end

test("setting: idle poll 1 s answers the first command within 1 s, 10 s does not within 2.7 s", function()
	local g = newGame(withProbeParams({ pollIdle = 1 }))
	frames(g, 2)
	send(g, 110, "status")
	frames(g, 35)
	truthy(answerText(g, 110), "1 s idle poll")
	g = newGame(withProbeParams({ pollIdle = 4 }))
	frames(g, 2)
	send(g, 111, "status")
	frames(g, FIRST)
	eq(answerText(g, 111), nil, "10 s idle poll")
	frames(g, 30 * 9)
	truthy(answerText(g, 111), "answered within 10 s")
end)

test("poll command: changes the intervals until the next load, status shows them, bad values refused", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 112, "poll", "{ idle = 0.5, active = 0.1 }")
	frames(g, FIRST)
	truthy((answerText(g, 112) or ""):find('"poll":{"active":0.1,"idle":0.5}'), answerText(g, 112))
	send(g, 113, "poll", "{ idle = 60 }")
	frames(g, 10)
	truthy((answerText(g, 113, "error") or ""):find("between"))
	frames(g, 30 * 130) -- past the 2 minutes of active polling: the 0.5 s idle interval applies
	send(g, 114, "status")
	frames(g, 20)
	local a = answerText(g, 114)
	truthy(a and a:find('"poll":{"active":0.1,"idle":0.5}'), a)
	send(g, 115, "load", '{ save = "probe" }')
	frames(g, 20)
	send(g, 116, "status")
	frames(g, FIRST)
	truthy((answerText(g, 116) or ""):find('"poll":{"active":0.25,"idle":2}'), "settings again after the load")
end)

test("log level: 1 logs no commands, 3 also logs run progress", function()
	local g = newGame(withProbeParams({ logLevel = 1 }))
	frames(g, 2)
	send(g, 117, "status")
	frames(g, FIRST)
	truthy(answerText(g, 117))
	for _, l in ipairs(g.logs) do truthy(not l:find("command 117"), "logged at level 1: " .. l) end
	truthy(g.logs[1]:find("ready"), "ready is always logged")
	g = newGame(withProbeParams({ logLevel = 3 }))
	frames(g, 2)
	send(g, 118, "run", "{ months = 6, speed = 1 }")
	frames(g, 30 * 20)
	local progress = false
	for _, l in ipairs(g.logs) do progress = progress or l:find("run 118 at ") ~= nil end
	truthy(progress, "progress logged at level 3")
end)

test("owner: a refused or non-game command does not become the last action", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 121, "speed", '{ speed = 2, _owner = "a" }')
	frames(g, FIRST)
	send(g, 122, "speed", '{ speed = -1, _owner = "b" }')
	frames(g, 20)
	send(g, 123, "poll", '{ idle = 1, _owner = "c" }')
	frames(g, 20)
	send(g, 124, "status")
	frames(g, 20)
	truthy((answerText(g, 124) or ""):find('"lastAction":{"cmd":"speed","id":121,"owner":"a"'), answerText(g, 124))
end)

test("log level 3 logs receipts", function()
	local g = newGame(withProbeParams({ logLevel = 3 }))
	frames(g, 2)
	send(g, 125, "status")
	frames(g, FIRST)
	local seen = false
	for _, l in ipairs(g.logs) do seen = seen or l:find("receipt for command 125") ~= nil end
	truthy(seen)
end)

test("owner: run and last game-changing command carry the sender; status does not replace it", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 119, "run", '{ months = 6, speed = 2, _owner = "alice" }')
	frames(g, FIRST)
	send(g, 120, "status", '{ _owner = "bob" }')
	frames(g, 20)
	local a = answerText(g, 120) or ""
	truthy(a:find('"run":{[^}]*"owner":"alice"'), a)
	truthy(a:find('"lastAction":{"cmd":"run","id":119,"owner":"alice"'), a)
	local logged = false
	for _, l in ipairs(g.logs) do logged = logged or l:find("command 119: run from alice") ~= nil end
	truthy(logged, "the sender is in the log")
end)

---------------------------------------------------------------------------------------------------------------------
-- the label beside the speed buttons

-- the game's _ with this mod's Japanese strings.json (a key it does not know comes back unchanged)
local function jaTranslate(key)
	local f = assert(io.open(root .. "/strings.json"))
	local text = f:read("*a"); f:close()
	local v = text:match('"ja"%s*:%s*{.-"' .. key:gsub("%p", "%%%0") .. '"%s*:%s*"(.-)"')
	return v or key
end

test("speedLabel: nothing at the buttons' own speeds, the number and measured rate otherwise", function()
	eq(core.speedLabel(4, 3.1, nil, 6), "")
	eq(core.speedLabel(0, nil, nil, 6), "")
	local l, tip = core.speedLabel(16, 3.24, nil, 6)
	eq(l, "×16 real ×3.2")
	truthy(tip:find("estimated maximum ×6"), tip)
	eq(core.speedLabel(64, 12.7, nil, 0), "×64 real ×13")
	eq(core.speedLabel(8, nil, nil, 0), "×8", "no rate yet")
	eq(core.speedLabel(nil), "")
end)

test("speedLabel: in the player's language through the game's _, English when a translation is missing or broken", function()
	local l, tip = core.speedLabel(16, 3.24, nil, 6, jaTranslate)
	eq(l, "×16 実測×3.2")
	truthy(tip:find("見積もり上限 ×6"), tip)
	truthy(tip:find("指定 ×16", 1, true), tip)
	local function unknown(key) return key end
	eq((core.speedLabel(16, 3.24, nil, 6, unknown)), "×16 real ×3.2")
	local function broken(key) return "no placeholder" end
	eq((core.speedLabel(16, 3.24, nil, 6, broken)), "×16 real ×3.2")
	local function raises() error("no translation here") end
	eq((core.speedLabel(16, 3.24, nil, 6, raises)), "×16 real ×3.2")
	eq(core.label(nil, "k", "fb"), "fb")
end)

test("speedLabel: a remote run shows its target even at 4x, and its owner in the tooltip", function()
	local run = { target = { year = 2045, month = 7, day = 3 }, owner = "alice" }
	local l, tip = core.speedLabel(4, 3.0, run, 6)
	eq(l, "×4 real ×3.0 →2045-07-03")
	truthy(tip:find("alice"), tip)
	truthy(tip:find("run in progress"), tip)
	eq(core.speedLabel(0, nil, run, 6), "→2045-07-03", "paused mid-run: only the target")
end)

test("rateStep: about once a second, smoothed, reset by a load", function()
	local r = core.newRate()
	eq(core.rateStep(r, 0, 10), nil)
	eq(core.rateStep(r, 1000, 10.5), nil, "under a second")
	eq(core.rateStep(r, 4000, 11), 4)
	eq(core.rateStep(r, 6000, 12), 3, "half old, half new")
	eq(core.rateStep(r, 100, 13), 3, "game time went back (a load): start over, keep the shown value")
end)

test("options: speedLabel off is a real choice, not the default", function()
	eq(core.options({ speedLabel = 2 }).speedLabel, false)
	eq(core.options({}).speedLabel, true)
end)

test("run publishes its target for the label and clears it when done", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 130, "run", '{ days = 30, speed = 1, _owner = "me" }')
	frames(g, FIRST)
	local sh = core.shared.run
	truthy(sh and sh.target and sh.owner == "me", "shared while running")
	local guard = 0
	while not answerText(g, 130) and guard < 30000 do g.step(1 / 30); guard = guard + 1 end
	eq(core.shared.run, nil, "cleared at the end")
end)

-- runs fn with api.* and app.* turned into errors, as off the main thread where they may crash the game
function withoutGameApi(fn)
	local realApi, realApp = _G.api, _G.app
	local trap = function(name) return setmetatable({}, { __index = function(_, k)
		error("game API touched off the main thread: " .. name .. "." .. tostring(k), 2) end }) end
	_G.api, _G.app = trap("api"), trap("app")
	local res = { pcall(fn) }
	_G.api, _G.app = realApi, realApp
	if not res[1] then error(res[2], 2) end
	return unpack(res, 2)
end

-- a stand-in for the base GUI modules the speed control script requires. React runs recipes and step functions
-- possibly off the main thread (game API forbidden: withoutGameApi) and joins on the main thread.
local R -- the fake react's bookkeeping: timers, joins, fired events, hook state
local function loadSpeedScript(_, _, previous)
	local replaced = {}
	local base = { "BASE" }
	R = { timers = {}, steps = {}, joins = {}, events = {}, hooks = {}, i = 0 }
	_G._react = { recipeReplace = { BASE_ID = previous } }
	package.preload["::/gui/main/react.lua"] = function() return {
		RegisterRecipe = function(name, fn) return fn end,
		CallOriginalRecipe = function(recipe, p) return { original = recipe, params = p } end,
		GetRecipeId = function(r) return r == base and "BASE_ID" or nil end,
		useState = function(init)
			R.i = R.i + 1
			local k = R.i
			if R.hooks[k] == nil then R.hooks[k] = { v = init } end
			return { old = function() return R.hooks[k].v end, set = function(_, v) R.hooks[k].v = v end }
		end,
		useRef = function()
			R.i = R.i + 1
			local k = R.i
			if R.hooks[k] == nil then R.hooks[k] = {} end
			return { get = function() return R.hooks[k].v end, set = function(_, v) R.hooks[k].v = v end }
		end,
		onStepTimer = function(fn) R.timers[1] = fn end,
		onStep = function(fn) R.steps[1] = fn end,
		enqueueJoin = function(fn) R.joins[#R.joins + 1] = fn end,
		fireEvent = function(target, name, param) R.events[#R.events + 1] = { name = name, param = param } end,
	} end
	package.preload["::/gui/main/builtin.lua"] = function() return {
		TextView = function(t) return { kind = "text", t = t } end,
		BoxLayout = function(t) return { kind = "box", t = t } end,
		ToggleButtonGroup = function(t) return { kind = "toggle", t = t } end,
		type = { Orientation = { Horizontal = "h" } },
	} end
	package.preload["::/gui/game_bar/game_bar_widgets.tl"] = function() return { GameSpeedControl = base } end
	for _, k in ipairs({ "::/gui/main/react.lua", "::/gui/main/builtin.lua", "::/gui/game_bar/game_bar_widgets.tl" }) do
		package.loaded[k] = nil
	end
	_G.data = nil
	-- a fresh remote_core, as in game where the recipe lives in another Lua state: nothing may come through
	-- a shared Lua table
	package.loaded["hummer_remote_probe::/remote_core.lua"] = nil
	return withoutGameApi(function()
		dofile(root .. "/content/gui/remote_speed.script.lua")
		local exports = _G.data()
		exports.install({ ReplaceRecipe = function(a, b) replaced[#replaced + 1] = { a, b } end })
		return exports, replaced, base
	end)
end

-- one frame: render and step without game API (worker thread), then the joins with it (main thread)
local function frame(control, params)
	R.i = 0
	local node = withoutGameApi(function() return control(params or {}) end)
	withoutGameApi(function() if R.timers[1] then R.timers[1]() end end)
	withoutGameApi(function() if R.steps[1] then R.steps[1]() end end)
	local joins = R.joins
	R.joins = {}
	-- the join runs in the recipe's react state: what loads only there (vehicle_react_util.tl) loads now
	fake.inReact = true
	local ok, err = pcall(function() for _, j in ipairs(joins) do j() end end)
	fake.inReact = false
	if not ok then error(err, 2) end
	return node
end

local function publish(t) fake.guiSave.hummer_remote_probe = t end

test("speed control: replaces the base recipe, draws the base buttons, the label from the GUI save data", function()
	local exports, replaced, base = loadSpeedScript()
	eq(#replaced, 1)
	eq(replaced[1][1], base); eq(replaced[1][2], exports.SpeedControl)
	publish({ label = "×16 実測×3.2", tip = "tip" })
	frame(exports.SpeedControl, { gameSpeedHelper = "h" }) -- the join reads it
	local kids = frame(exports.SpeedControl, { gameSpeedHelper = "h" }).t.children
	eq(kids[1].original, base, "the base buttons first")
	eq(kids[1].params.gameSpeedHelper, "h", "with the same params")
	eq(kids[2].kind, "toggle", "then the ×8 / ×16 buttons")
	eq(kids[3].kind, "text")
	eq(kids[3].t.text, "×16 実測×3.2")
	eq(kids[3].t.meta.tooltip, "tip")
	eq(kids[3].t.meta.mouseTransparent, false, "the label takes the mouse for its tooltip")
	publish(nil)
end)

test("speed control: opens a requested window once, never one left in the save from the last game", function()
	local exports = loadSpeedScript()
	publish({ label = "", open = { seq = 5, entity = 1234 } }) -- what the loaded save still holds
	frame(exports.SpeedControl)
	frame(exports.SpeedControl)
	eq(#R.events, 0, "the old request is not opened")
	publish({ label = "", open = { seq = 6, entity = 777 } })
	frame(exports.SpeedControl)
	eq(#R.events, 1)
	eq(R.events[1].name, "selectEntity"); eq(R.events[1].param.entity, 777); eq(R.events[1].param.stack, false)
	frame(exports.SpeedControl)
	eq(#R.events, 1, "opened once")
	publish(nil)
end)

test("speed control: the speedButtons setting hides only the ×8 / ×16; label and window requests go on", function()
	local exports = loadSpeedScript()
	publish({ label = "×16 実測×3.2", tip = "tip", buttons = false })
	frame(exports.SpeedControl, { gameSpeedHelper = "h" })
	local kids = frame(exports.SpeedControl, { gameSpeedHelper = "h" }).t.children
	eq(#kids, 2)
	truthy(kids[1].original ~= nil, "the base buttons stay")
	eq(kids[2].kind, "text", "the label right after the base buttons")
	eq(kids[2].t.text, "×16 実測×3.2")
	local before = #R.events
	publish({ label = "", buttons = false, open = { seq = 41, entity = 4242 } })
	frame(exports.SpeedControl)
	eq(#R.events, before + 1, "a window request is still carried out")
	eq(R.events[#R.events].param.entity, 4242)
	publish({ label = "", buttons = true })
	frame(exports.SpeedControl)
	eq(frame(exports.SpeedControl).t.children[2].kind, "toggle", "shown again when the setting is back")
	publish(nil)
end)

test("speed control: another mod's replacement is drawn instead of the base buttons", function()
	local other = function(p) return { other = true, params = p } end
	local exports = loadSpeedScript(nil, false, other)
	publish({ label = "×4 →2045-07-03" })
	frame(exports.SpeedControl, { gameSpeedHelper = "h" })
	local kids = frame(exports.SpeedControl, { gameSpeedHelper = "h" }).t.children
	eq(kids[1].other, true, "the other mod's buttons kept")
	eq(kids[1].params.gameSpeedHelper, "h")
	eq(kids[2].kind, "text", "with the label beside them, not our ×8 / ×16 (Time Warp's would show twice)")
	eq(#kids, 2)
	publish(nil)
	_G._react = nil
	exports = loadSpeedScript()
	_G._react = nil -- no _react at all: the base buttons, no error
	eq(frame(exports.SpeedControl).t.children[1].original ~= nil, true)
end)

test("speed control: a second install, or a second copy, never draws itself as the previous buttons", function()
	local exports = loadSpeedScript()
	_G._react.recipeReplace.BASE_ID = exports.SpeedControl -- what the first install left there
	exports.install({ ReplaceRecipe = function() end })
	eq(frame(exports.SpeedControl).t.children[1].original ~= nil, true, "the base buttons, not itself")
	local old = exports.SpeedControl
	local again = loadSpeedScript(nil, false, old)
	eq(frame(again.SpeedControl).t.children[1].original ~= nil, true, "not the old copy either")
end)

test("speed control: nothing published, junk published, or the GUI API failing: the buttons alone, no label", function()
	local exports = loadSpeedScript()
	publish(nil)
	frame(exports.SpeedControl)
	eq(#frame(exports.SpeedControl).t.children, 2)
	publish("not a table")
	frame(exports.SpeedControl)
	eq(#frame(exports.SpeedControl).t.children, 2)
	local real = api.gui.game.getGuiSaveData
	api.gui.game.getGuiSaveData = function() error("restricted") end
	frame(exports.SpeedControl)
	api.gui.game.getGuiSaveData = real
	eq(#frame(exports.SpeedControl).t.children, 2)
	publish(nil)
end)

-- a stand-in for game.tl's GameSpeedHelper: getSpeed is what it last asked for (what lights a button), setSpeed
-- the base buttons' way (clamped in game, recorded here)
local function fakeHelper(speed)
	local h = { speed = speed, enabled = true, set = {} }
	local a = {
		getSpeed = function() return h.speed end,
		isEnabled = function() return h.enabled end,
		setSpeed = function(n) h.set[#h.set + 1] = n end,
	}
	h.ref = { get = function() return { getApi = function() return a end } end }
	return h
end

-- api.cmd as the game's: the speed commands sent, in order. The estimated maximum is low (3), as on a big map.
local function recordSpeedCmds(fn)
	local realApi = _G.api
	local sent = {}
	_G.api = setmetatable({
		cmd = {
			makeGameSetSpeedCmd = function(n) return { kind = "speed", speed = n } end,
			sendCommand = function(c) sent[#sent + 1] = c.speed end,
		},
		gui = { game = { getEstimatedMaximumGameSpeed = function() return 3 end } },
	}, { __index = realApi })
	local ok, err = pcall(fn)
	_G.api = realApi
	if not ok then error(err, 2) end
	return sent
end

test("speed control: ×8 and ×16 send that speed, beyond the game's estimated maximum", function()
	local exports = loadSpeedScript()
	local h = fakeHelper(1)
	local params = { gameSpeedHelper = h.ref }
	frame(exports.SpeedControl, params)
	local group = frame(exports.SpeedControl, params).t.children[2]
	eq(group.kind, "toggle")
	eq(#group.t.buttons, 2)
	eq(group.t.meta.class, "hummer-remote-speed-buttons", "the class the CSS matches")
	eq(group.t.buttons[1].content.t.text, "×8"); eq(group.t.buttons[2].content.t.text, "×16")
	eq(group.t.buttons[1].meta.tooltip, "Speed: 8x", "English without the game's _")
	eq(group.t.buttons[2].meta.tooltip, "Speed: 16x")
	truthy(group.t.buttons[1].content.t.meta.class:find("hummer%-remote%-speed%-button"))
	-- the click: on the main thread, as the base buttons' onValueChange
	local cmds = recordSpeedCmds(function()
		group.t.onValueChange(1)
		group.t.onValueChange(2)
		group.t.onValueChange(-1) -- a deselect, or an index of nothing: no command
		group.t.onValueChange(3)
	end)
	eq(#cmds, 2)
	eq(cmds[1], 8); eq(cmds[2], 16, "not capped at the estimated maximum")
	eq(#h.set, 0, "not through the helper, which clamps")
end)

test("speed control: the lit ×8 / ×16 button follows the helper's speed; the base buttons are left alone", function()
	local exports = loadSpeedScript()
	local h = fakeHelper(8)
	local params = { gameSpeedHelper = h.ref }
	local function group() frame(exports.SpeedControl, params); return frame(exports.SpeedControl, params).t.children end
	local kids = group()
	eq(kids[2].t.selected, 1, "×8 lit")
	eq(kids[2].t.deselectAllowed, false)
	eq(kids[1].original ~= nil, true, "the base buttons, drawn by the base recipe")
	eq(kids[1].params, params, "with the params unchanged")
	h.speed = 16
	eq(group()[2].t.selected, 2, "×16 lit")
	for _, s in ipairs({ 0, 1, 2, 4, 3, 32 }) do
		h.speed = s
		kids = group()
		eq(kids[2].t.selected, -1, "none lit at " .. s)
		eq(kids[2].t.deselectAllowed, true)
	end
	eq(#h.set, 0, "nothing set by drawing")
	h.enabled = false
	eq(group()[2].t.meta.enabled, false, "disabled with the base buttons (tutorials)")
	h.enabled = true
	eq(group()[2].t.meta.enabled, true)
	h.speed = 16
	group()
	h.ref = { get = function() error("not mounted") end }
	params.gameSpeedHelper = h.ref
	eq(group()[2].t.selected, 2, "a failing helper: the last speed kept, no error")
end)

test("speed control: the ×8 / ×16 tooltips come from strings.json in the game's language", function()
	local exports = loadSpeedScript()
	local ja = { hummer_remote_probe_tip_button = "速度: %s倍" }
	_G._ = function(k) return ja[k] or k end
	local ok, kids = pcall(function()
		frame(exports.SpeedControl, {})
		return frame(exports.SpeedControl, {}).t.children
	end)
	_G._ = nil
	truthy(ok, tostring(kids))
	eq(kids[2].t.buttons[1].meta.tooltip, "速度: 8倍")
	eq(kids[2].t.buttons[2].meta.tooltip, "速度: 16倍")
	eq(kids[2].t.selected, -1, "no helper in the params: none lit, no error")
end)

test("label text and window requests are written by the guiUpdate script into the GUI save data", function()
	local g = newGame({ saves = SAVES, maxSpeed = 40 })
	frames(g, 2)
	g.speedup = 16
	frames(g, 30 * 3)
	local d = fake.guiSave.hummer_remote_probe
	truthy(d and d.label:find("^×16"), d and d.label)
	g.speedup = 4
	frames(g, 30)
	eq(fake.guiSave.hummer_remote_probe.label, "", "at a button's own speed: nothing to add")
	local g2 = newGame({ saves = SAVES, modParams = { hummer_remote_probe = { speedLabel = 2 } } })
	frames(g2, 2)
	g2.speedup = 16
	frames(g2, 30 * 2)
	eq(fake.guiSave.hummer_remote_probe.label, "", "setting off: no label")
end)

test("the guiUpdate script publishes the speedButtons setting for the speed control", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	frames(g, 30 * 2)
	eq(fake.guiSave.hummer_remote_probe.buttons, true, "default: shown")
	local g2 = newGame({ saves = SAVES, modParams = { hummer_remote_probe = { speedButtons = 2 } } })
	frames(g2, 2)
	eq(fake.guiSave.hummer_remote_probe.buttons, false, "hidden from the first frames, before any label step")
	frames(g2, 30 * 2)
	eq(fake.guiSave.hummer_remote_probe.buttons, false, "setting hide")
	eq(core.uiRequest(fake.guiSave.hummer_remote_probe).buttons, false, "and the speed control reads it as hidden")
end)

test("the guiUpdate script passes the game's _ to the label: Japanese in a Japanese game", function()
	local saved = rawget(_G, "_")
	_G._ = jaTranslate
	local ok, err = pcall(function()
		local g = newGame({ saves = SAVES, maxSpeed = 40 })
		frames(g, 2)
		g.speedup = 16
		frames(g, 30 * 3)
		local d = fake.guiSave.hummer_remote_probe
		truthy(d and d.label:find("実測×", 1, true), d and d.label)
		truthy(d.tip:find("指定 ×16", 1, true), d.tip)
	end)
	_G._ = saved
	assert(ok, err)
end)

test("status shows the GUI save data read back; a failing setGuiSaveData is logged once", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 196, "status")
	frames(g, FIRST)
	truthy((answerText(g, 196) or ""):find('"ui":{[^}]*"label":""'), answerText(g, 196))
	local real = api.gui.game.setGuiSaveData
	api.gui.game.setGuiSaveData = function() error("unknown key") end
	g.speedup = 16
	frames(g, 30 * 3)
	api.gui.game.setGuiSaveData = real
	local n = 0
	for _, l in ipairs(g.logs) do if l:find("setGuiSaveData failed") then n = n + 1 end end
	eq(n, 1, "logged once")
end)

test("load clears a label and a request the save carried over", function()
	fake.guiSave.hummer_remote_probe = { label = "×16 old", open = { seq = 3, entity = 9 } }
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	eq(fake.guiSave.hummer_remote_probe.label, "")
	eq(fake.guiSave.hummer_remote_probe.open, false)
end)

local ENT = { TOWN = { 11, 12 }, LINE = { 21 }, TRANSPORT_VEHICLE = { 31 }, STATION_GROUP = { 41 }, INDUSTRY = { 51 } }
local NAMES = { [11] = "Emsworth", [12] = "Emsworth Bay", [21] = "Bus 1", [31] = "Bus 1 #1", [41] = "Central", [51] = "Coal mine" }

test("entities: lists a kind with names, filtered and sorted", function()
	local g = newGame({ saves = SAVES, entities = ENT, names = NAMES })
	frames(g, 2)
	send(g, 190, "entities", '{ kind = "town", grep = "bay" }')
	frames(g, FIRST)
	local a = answerText(g, 190) or ""
	truthy(a:find('"entities":%[{"id":12,"name":"Emsworth Bay"}%]') and a:find('"total":2'), a)
	send(g, 191, "entities", '{ kind = "planet" }')
	frames(g, 20)
	truthy(answerText(g, 191, "error"))
	-- industries carry their construction (an upgrade's script-event addresses it), left out when unknown
	-- 51 has one, 52 none (-1), 53 an error: only 51 carries the key. Every id answers 5100 for towns here, so a
	-- town must not get one either.
	local g2 = newGame({ saves = SAVES, entities = { TOWN = { 11 }, INDUSTRY = { 51, 52, 53 } },
		names = { [11] = "Emsworth", [51] = "Coal mine", [52] = "Farm", [53] = "Mill" } })
	frames(g2, 2)
	local sys = api.engine.system -- the second game's fake engine
	local realScs = sys.streetConnectorSystem
	sys.streetConnectorSystem = setmetatable({ getConstructionEntityForSubconstruction = function(e)
		if e == 53 then error("broken") end
		return (e == 51 or e == 11) and 5100 or -1 end }, { __index = realScs })
	local ok, err = pcall(function()
		send(g2, 194, "entities", '{ kind = "industry" }')
		frames(g2, FIRST)
		send(g2, 195, "entities", '{ kind = "town" }')
		frames(g2, 20)
	end)
	sys.streetConnectorSystem = realScs
	assert(ok, err)
	local b = answerText(g2, 194) or ""
	truthy(b:find('{"construction":5100,"id":51,"name":"Coal mine"}', 1, true), b)
	truthy(b:find('{"id":52,"name":"Farm"}', 1, true), "none: left out: " .. b)
	truthy(b:find('{"id":53,"name":"Mill"}', 1, true), "an error: left out: " .. b)
	truthy(not (answerText(g2, 195) or ""):find("construction", 1, true), "towns have none")
end)

test("window: by name or id, publishes the request, focuses the camera on demand, closes all", function()
	local g = newGame({ saves = SAVES, entities = ENT, names = NAMES })
	frames(g, 2)
	send(g, 192, "window", '{ kind = "town", name = "emsworth", focus = true }')
	frames(g, FIRST)
	local a = answerText(g, 192) or ""
	truthy(a:find('"entity":11') and a:find('"name":"Emsworth"'), "exact name wins over the longer one: " .. a)
	eq(fake.guiSave.hummer_remote_probe.open.entity, 11)
	eq(g.focused, 11)
	local seq = fake.guiSave.hummer_remote_probe.open.seq
	send(g, 193, "window", '{ entity = 31 }')
	frames(g, 20)
	eq(fake.guiSave.hummer_remote_probe.open.entity, 31)
	truthy(fake.guiSave.hummer_remote_probe.open.seq > seq, "a new request number")
	send(g, 194, "window", '{ kind = "town", name = "worth" }')
	frames(g, 20)
	truthy((answerText(g, 194, "error") or ""):find("2 matches"), answerText(g, 194, "error"))
	send(g, 195, "window", "{ closeAll = true }")
	frames(g, 20)
	eq(g.closedAll, 1)
end)

test("window --manager: a line by name or id goes to the line manager, never its own window", function()
	local ent = { TOWN = { 11 }, LINE = { 21, 22 }, TRANSPORT_VEHICLE = { 31 } }
	local names = { [11] = "Emsworth", [21] = "Bus 1", [22] = "Bus 10", [31] = "Bus 1 #1" }
	local g = newGame({ saves = SAVES, entities = ent, names = names })
	frames(g, 2)
	send(g, 196, "window", '{ kind = "line", name = "bus 1", manager = true }')
	frames(g, FIRST)
	local a = answerText(g, 196) or ""
	truthy(a:find('"entity":21') and a:find('"manager":true') and a:find('"name":"Bus 1"'), "exact name wins: " .. a)
	local open = fake.guiSave.hummer_remote_probe.open
	eq(open.manager, 21); eq(open.entity, nil, "not the line's own window too")
	local seq = open.seq
	send(g, 197, "window", '{ entity = 22, manager = true, focus = true }')
	frames(g, 20)
	open = fake.guiSave.hummer_remote_probe.open
	eq(open.manager, 22); truthy(open.seq > seq, "a new request number"); eq(g.focused, 22)
	truthy((answerText(g, 197) or ""):find('"name":"Bus 10"'), answerText(g, 197))
	seq = open.seq
	-- a vehicle's id, an id that is nobody's, another kind, a name that fits two lines, no line at all: refused,
	-- and nothing is published for the speed control to open
	send(g, 198, "window", '{ entity = 31, manager = true }'); frames(g, 20)
	send(g, 199, "window", '{ entity = 999, manager = true }'); frames(g, 20)
	send(g, 200, "window", '{ kind = "town", name = "Emsworth", manager = true }'); frames(g, 20)
	send(g, 201, "window", '{ kind = "line", name = "bus", manager = true }'); frames(g, 20)
	send(g, 202, "window", '{ kind = "line", name = "tram", manager = true }'); frames(g, 20)
	truthy((answerText(g, 198, "error") or ""):find("not one of the company's lines"), answerText(g, 198, "error"))
	truthy((answerText(g, 199, "error") or ""):find("not one of the company's lines"), answerText(g, 199, "error"))
	truthy((answerText(g, 200, "error") or ""):find("manager opens a line"), answerText(g, 200, "error"))
	truthy((answerText(g, 201, "error") or ""):find("2 matches"), answerText(g, 201, "error"))
	truthy((answerText(g, 202, "error") or ""):find("no match"), answerText(g, 202, "error"))
	eq(fake.guiSave.hummer_remote_probe.open.seq, seq, "no request published for a refused one")
	-- without manager the same line opens its own window, as before
	send(g, 203, "window", '{ kind = "line", name = "bus 1" }')
	frames(g, 20)
	open = fake.guiSave.hummer_remote_probe.open
	eq(open.entity, 21); eq(open.manager, nil)
	truthy(not (answerText(g, 203) or ""):find("manager", 1, true), answerText(g, 203))
end)

test("uiRequest: manager is a line id (a whole positive number) or left out", function()
	eq(core.uiRequest({ open = { seq = 1, manager = 21 } }).open.manager, 21)
	eq(core.uiRequest({ open = { seq = 1, manager = "21" } }).open.manager, 21)
	for _, bad in ipairs({ "x", -1, 0, 1.5, math.huge, 0 / 0, {}, false }) do
		eq(core.uiRequest({ open = { seq = 1, manager = bad } }).open.manager, nil, "manager " .. tostring(bad))
	end
	eq(core.uiRequest({ open = { seq = 1 } }).open.manager, nil)
end)

test("core loads where _G is not a plain table (TF3 GUI Lua) and still shares a table", function()
	for _, weird in ipairs({ "nil", "userdata", "locked" }) do
		local chunk = assert(loadfile(root .. "/content/remote_core.lua"))
		local env = setmetatable({}, { __index = _G })
		if weird == "nil" then
			env._G = false
		elseif weird == "userdata" then
			env._G = newproxy(true)
		else
			env._G = setmetatable({}, { __newindex = function() error("globals are locked") end })
		end
		setfenv(chunk, env)
		local ok, m = pcall(chunk)
		truthy(ok, weird .. ": " .. tostring(m))
		eq(type(m.shared), "table", weird)
	end
end)

test("speed css: widens every right-hand layer by the same amount and styles the buttons and the label", function()
	package.preload["::/gui/main/stylesheetutil.lua"] = function() return {
		makeAdder = function(result) return function(sel, rule) result[#result + 1] = { sel, rule } end end,
	} end
	package.loaded["::/gui/main/stylesheetutil.lua"] = nil
	_G.data = nil
	local rules = withoutGameApi(function()
		dofile(root .. "/content/gui/remote_speed.css.lua")
		return _G.data()
	end)
	local widths = {}
	for _, r in ipairs(rules) do widths[r[1]] = r[2].size and r[2].size[1] end
	-- the label (170) and the ×8 / ×16 buttons (2 x 32 + a 4 px gap)
	local extra = 170 + 68
	eq(widths["R::GameBarMenuRight !game-speed"], 330 + extra)
	eq(widths["R::GameBarMenuRight !music-player"], 380 + extra)
	eq(widths["R::GameBarMenuRight !cameras"], 508 + extra)
	eq(widths["R::GameBarMenuRight !statistics"], 508 + extra)
	eq(widths["R::GameBarMenuRight TextView!hummer-remote-speed-button"], 28, "×16 fits")
	-- the group by the class the script gives it
	local script = io.open(root .. "/content/gui/remote_speed.script.lua"):read("*a")
	truthy(script:find('class = "hummer-remote-speed-buttons"', 1, true), "the script's class")
	local found = false
	for _, r in ipairs(rules) do
		if r[1] == "R::GameBarMenuRight ToggleButtonGroup!hummer-remote-speed-buttons" then found = r[2] end
	end
	truthy(found and found.margin, "the ×8 / ×16 group's rule")
	truthy(rules[#rules][1]:find("hummer%-remote%-speed"))
end)

---------------------------------------------------------------------------------------------------------------------
-- new game

local CAT = {
	["temperate.clima"] = { economy = "temperate.eco", generators = { "temperate.gen", "temperate_hills.gen" } },
	["dry.clima"] = { economy = "dry.eco", generators = { "dry.gen" } },
}

test("parseSize and matchName", function()
	eq(select(1, core.parseSize("tiny")), 16)
	local x, y = core.parseSize("40x24")
	eq(x, 40); eq(y, 24)
	eq(select(1, core.parseSize(nil)), 32, "small by default")
	truthy(select(2, core.parseSize("huge")))
	truthy(select(2, core.parseSize("2x2")))
	eq(core.matchName({ "temperate.clima", "dry.clima" }, "temperate"), "temperate.clima")
	eq(core.matchName({ "a/temperate.clima" }, "temperate.clima"), "a/temperate.clima")
	eq(core.matchName({ "x.gen", "x.clima" }, "x"), nil, "ambiguous")
end)

test("newGamePlan: defaults, the running game's mods and numeric params, the probe always in", function()
	local p = core.newGamePlan({}, { climates = CAT, mods = { "m1" }, selfId = "hummer_remote_probe", time = 7,
		modParams = { [""] = { ["map.size"] = 4, isMapEditor = false }, m1 = { a = 2 } } })
	eq(p.climate, "temperate.clima"); eq(p.generator, "temperate.gen", "the first by order")
	eq(p.economy, "temperate.eco"); eq(p.numTiles[1], 32); eq(p.year, 1900)
	eq(p.towns, true); eq(p.industries, true); eq(p.seed, "remote_probe_7")
	eq(table.concat(p.mods, ","), "m1,hummer_remote_probe")
	eq(p.modParams[""]["map.size"], 4); eq(p.modParams[""].isMapEditor, nil, "only integers")
	eq(p.modParams.m1.a, 2)
end)

test("newGamePlan: choices and refusals", function()
	local ctx = { climates = CAT, mods = {}, modParams = {}, selfId = "p" }
	local p = core.newGamePlan({ climate = "dry", size = "tiny", year = 1950, seed = "s", towns = false,
		mods = { add = { "x" } }, params = { x = { k = 3 } } }, ctx)
	eq(p.climate, "dry.clima"); eq(p.generator, "dry.gen"); eq(p.numTiles[2], 16); eq(p.year, 1950)
	eq(p.towns, false); eq(p.industries, true); eq(p.seed, "s"); eq(p.modParams.x.k, 3)
	eq(core.newGamePlan({ generator = "temperate_hills" }, ctx).generator, "temperate_hills.gen")
	truthy(select(2, core.newGamePlan({ climate = "arctic" }, ctx)):find("known: dry.clima, temperate.clima"))
	truthy(select(2, core.newGamePlan({ generator = "nope" }, ctx)):find("known: temperate.gen"))
	truthy(select(2, core.newGamePlan({ year = 1750 }, ctx)))
	truthy(select(2, core.newGamePlan({ params = { x = { k = 0 } } }, ctx)))
	truthy(select(2, core.newGamePlan({}, { climates = {} })))
end)

test("newgame list: climates with generators in the base page's order, import generators left out", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 140, "newgame", "{ list = true }")
	frames(g, FIRST)
	local a = answerText(g, 140) or ""
	truthy(a:find('"generators":%["temperate.gen","temperate_hills.gen"%]'), a)
	truthy(not a:find("temperate_import"), "import generator excluded")
end)

test("newgame dryRun: the plan only", function()
	local g = newGame({ saves = SAVES, modParams = { example_mod = { extraDemand = 2 } } })
	frames(g, 2)
	send(g, 141, "newgame", '{ size = "tiny", dryRun = true, params = { example_mod = { treePollution = 3 } } }')
	frames(g, FIRST)
	local a = answerText(g, 141) or ""
	truthy(a:find('"dryRun":true') and a:find('"treePollution":3') and a:find('"extraDemand":2'), a)
	eq(#g.started, 0)
end)

test("newgame: ack, then startGame with the plan; the probe answers again in the new game", function()
	local g = newGame({ saves = SAVES, modParams = { m1 = { a = 1 } } })
	frames(g, 2)
	local before = stampOf(g.x)
	send(g, 142, "newgame", '{ size = "tiny", year = 1920, seed = "abc", industries = false, unsafe = true }')
	frames(g, FIRST)
	truthy(answerText(g, 142, "ack"), "ack")
	eq(#g.started, 1)
	local p = g.started[1]
	eq(p.numTiles.x, 16); eq(p.climateGenerator, "temperate.clima"); eq(p.terrainGenerator, "temperate.gen")
	eq(p.economy, "temperate.eco"); eq(p.startDate.year, 1920); eq(p.seed, "abc")
	eq(p.generateTowns, true); eq(p.generateIndustries, false); eq(p.isMapEditor, false)
	eq(table.concat(p.mods, ","), "m1,hummer_remote_probe")
	eq(g.waitedForStart, nil, "no Start Game button wait")
	frames(g, 3)
	truthy(stampOf(g.x) ~= before, "new hello")
	send(g, 143, "status")
	frames(g, FIRST)
	truthy((answerText(g, 143) or ""):find('"year":1920'), "the new game answers")
end)

test("newgame: a refused startGame is an error answer; a running run is cancelled first", function()
	local g = newGame({ saves = SAVES, startFails = true })
	frames(g, 2)
	send(g, 144, "run", "{ months = 6, speed = 2 }")
	frames(g, FIRST)
	send(g, 145, "newgame", "{ unsafe = true }")
	frames(g, 30)
	truthy((answerText(g, 144, "error") or ""):find("cancelled: newgame command 145"))
	truthy((answerText(g, 145, "error") or ""):find("startGame refused"))
end)

test("newgame: placement for towns and industries as the base page builds it", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 146, "newgame", '{ size = "tiny", unsafe = true }')
	frames(g, FIRST)
	local L = g.started[1].locationsConfig
	truthy(L, "locationsConfig set")
	eq(L.town.maxNumberPerArea, 0.2); eq(L.industry.absoluteMinimum, 24); eq(L.makeInitialStreets, true)
end)

test("newgame / load: an answer when the call returns but the game does not change", function()
	local g = newGame({ saves = SAVES, startNoop = true })
	frames(g, 2)
	send(g, 147, "newgame", "{ unsafe = true }")
	frames(g, FIRST)
	truthy(answerText(g, 147, "ack"))
	eq(answerText(g, 147, "error"), nil, "not before 30 s")
	frames(g, 30 * 31)
	truthy((answerText(g, 147, "error") or ""):find("kept running for 30 s"), answerText(g, 147, "error"))
end)

test("capSpeed: the estimate, the buttons' 4x without one, force and slow speeds untouched", function()
	eq(core.capSpeed(8, 5), 5); eq(core.capSpeed(8, 0), 4); eq(core.capSpeed(8, nil), 4)
	eq(core.capSpeed(8, 5, true), 8); eq(core.capSpeed(3, 5), 3); eq(core.capSpeed(1, 0), 1); eq(core.capSpeed(0, 0), 0)
end)

test("run: follows the game's estimate down and back up, with a hold between changes", function()
	local opts = { saves = SAVES, maxSpeed = 10 }
	local g = newGame(opts)
	frames(g, 2)
	send(g, 150, "run", "{ months = 12, speed = 16 }")
	frames(g, FIRST)
	eq(g.speedup, 10)
	opts.maxSpeed = 3 -- the map got busy
	frames(g, 30 * 3)
	eq(g.speedup, 3, "lowered at the next check")
	opts.maxSpeed = 20
	frames(g, 30 * 3)
	eq(g.speedup, 3, "not raised before the estimate has allowed it for 4 s")
	frames(g, 30 * 4)
	eq(g.speedup, 16, "back up, but not past the 16 asked for")
	opts.maxSpeed = 5
	frames(g, 30 * 3)
	eq(g.speedup, 5, "lowered at once, even right after a raise")
	send(g, 151, "status")
	frames(g, 10)
	truthy((answerText(g, 151) or ""):find('"run":{[^}]*"speed":5'), answerText(g, 151))
end)

test("run: force keeps the asked speed whatever the estimate", function()
	local opts = { saves = SAVES, maxSpeed = 10 }
	local g = newGame(opts)
	frames(g, 2)
	send(g, 152, "run", "{ months = 12, speed = 16, force = true }")
	frames(g, FIRST)
	eq(g.speedup, 16)
	opts.maxSpeed = 2
	frames(g, 30 * 6)
	eq(g.speedup, 16)
end)

test("run: a pause from outside stays a pause, and the run ends as stalled", function()
	local opts = { saves = SAVES, maxSpeed = 10 }
	local g = newGame(opts)
	frames(g, 2)
	send(g, 153, "run", "{ months = 12, speed = 16 }")
	frames(g, FIRST)
	g.speedup = 0 -- the player pressed pause
	opts.maxSpeed = 3
	frames(g, 30 * 10)
	eq(g.speedup, 0, "not restarted by the estimate following")
	frames(g, 30 * 12)
	truthy((answerText(g, 153, "error") or ""):find("stalled"))
end)

test("run: a speed changed from outside (the base UI's own clamp) is brought back to the estimate", function()
	local opts = { saves = SAVES, maxSpeed = 3 }
	local g = newGame(opts)
	frames(g, 2)
	send(g, 154, "run", "{ months = 12, speed = 3 }")
	frames(g, FIRST)
	eq(g.speedup, 3)
	g.speedup = 2 -- the base UI lowered it while the estimate dipped; the estimate is back at 3
	frames(g, 30 * 7)
	eq(g.speedup, 3, "raised again once the estimate allowed it for 4 s")
end)

test("newgame: refused from inside a save (the base's StartGame asserts no game is running)", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 160, "newgame", '{ size = "tiny" }')
	frames(g, FIRST)
	truthy((answerText(g, 160, "error") or ""):find("cannot start from inside a save"))
	eq(#g.started, 0)
end)

test("screenshot: the game's own takeScreenshot with the scale asked; bad scales refused", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 170, "screenshot", "{ scale = 1 }")
	frames(g, FIRST)
	truthy((answerText(g, 170) or ""):find('"scale":1'))
	eq(g.shots, 1)
	send(g, 171, "screenshot", "{ scale = 9 }")
	frames(g, 20)
	truthy((answerText(g, 171, "error") or ""):find("0%-4"))
	send(g, 172, "screenshot", "{ scale = 1.5 }")
	frames(g, 20)
	truthy((answerText(g, 172, "error") or ""):find("0%-4"), "not rounded down")
	eq(g.shots, 1)
end)

test("load / newgame: params for a mod that will not be active are refused, with --add suggested", function()
	eq(table.concat(core.paramsWithoutMods({ x = {}, [""] = {}, m1 = {} }, { "m1" }), ","), "x")
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 180, "load", '{ save = "bare", params = { example_mod = { extraDemand = 2 } } }')
	frames(g, FIRST)
	truthy((answerText(g, 180, "error") or ""):find("not in the mod list: example_mod %(add them with %-%-add"),
		answerText(g, 180, "error"))
	eq(#g.loads, 0)
	send(g, 181, "load", '{ save = "bare", mods = { add = { "example_mod" } }, params = { example_mod = { extraDemand = 2 } } }')
	frames(g, 20)
	eq(#g.loads, 1, "with --add it loads")
	local p, err = core.newGamePlan({ params = { x = { k = 2 } } }, { climates = CAT, mods = {}, modParams = {}, selfId = "p" })
	eq(p, nil); truthy(err:find("not in the mod list: x"))
end)

test("load: a loadGame that changes nothing is reported, without errors in the log (watchReplace defined)", function()
	local g = newGame({ saves = SAVES, loadNoop = true })
	frames(g, 2)
	send(g, 182, "load", '{ save = "probe" }')
	frames(g, FIRST)
	for _, l in ipairs(g.logs) do truthy(not l:find("error"), "logged: " .. l) end
	frames(g, 30 * 31)
	truthy((answerText(g, 182, "error") or ""):find("kept running for 30 s"), answerText(g, 182, "error"))
end)

-- quit, event, tool; the main menu (startup.lua)

test("toolRequest: known names, a module, close; unknown names and nothing refused", function()
	local t = core.toolRequest({ name = "music" })
	eq(t.module, "/gui/music_player/music_player.tl"); eq(t.field, nil); eq(t.close, false)
	t = core.toolRequest({ name = "calendar", close = true })
	eq(t.field, "CalendarEditorTool"); eq(t.close, true)
	t = core.toolRequest({ module = "/x.tl", field = "" })
	eq(t.module, "/x.tl"); eq(t.field, nil, "an empty field is none")
	local none, err = core.toolRequest({ name = "statistics" })
	eq(none, nil); truthy(err:find("known: calendar, music"), err)
	truthy(select(2, core.toolRequest({})))
	truthy(select(2, core.toolRequest(nil)))
	truthy(select(2, core.toolRequest({ module = 5 })))
end)

test("eventRequest: a name and plain params; functions, userdata, cycles and bad names refused", function()
	local e = core.eventRequest({ name = "example_window.show", param = { welcome = true, list = { 1, 2 } } })
	eq(e.name, "example_window.show"); eq(e.param.welcome, true)
	eq(core.eventRequest({ name = "x" }).param, nil, "no param is fine")
	truthy(select(2, core.eventRequest({ name = "" })))
	truthy(select(2, core.eventRequest({})))
	truthy(select(2, core.eventRequest(nil)))
	truthy(select(2, core.eventRequest({ name = "x", param = 5 })):find("must be a table"))
	truthy(select(2, core.eventRequest({ name = "x", param = { f = print } })):find("a function"))
	truthy(select(2, core.eventRequest({ name = "x", param = { u = newproxy(false) } })):find("a userdata"))
	local cyc = {}
	cyc.me = cyc
	truthy(select(2, core.eventRequest({ name = "x", param = cyc })):find("a cycle"))
	local shared = { 1 }
	truthy(core.eventRequest({ name = "x", param = { a = shared, b = shared } }), "the same table twice is no cycle")
end)

test("scriptEventRequest: an id, a name and plain params (an empty table when none)", function()
	local e = core.scriptEventRequest({ id = "hummer_age_of_mobility", name = "industry_upgrades.apply",
		param = { construction = 123, kind = "pollution", step = 3 } })
	eq(e.id, "hummer_age_of_mobility"); eq(e.name, "industry_upgrades.apply"); eq(e.param.step, 3)
	eq(next(core.scriptEventRequest({ id = "m", name = "x" }).param), nil, "no param: an empty table")
	truthy(select(2, core.scriptEventRequest({ name = "x" })):find("id"))
	truthy(select(2, core.scriptEventRequest({ id = "", name = "x" })):find("id"))
	truthy(select(2, core.scriptEventRequest({ id = 5, name = "x" })):find("id"))
	truthy(select(2, core.scriptEventRequest({ id = "m" })):find("name"))
	truthy(select(2, core.scriptEventRequest({ id = "m", name = "x", param = { f = print } })):find("a function"))
	truthy(select(2, core.scriptEventRequest(nil)))
end)

test("scriptEvent: sent as a command at once, not through the speed control; a refusal goes to the log", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	local before = fake.guiSave.hummer_remote_probe and fake.guiSave.hummer_remote_probe.open
	send(g, 210, "scriptEvent", '{ id = "hummer_age_of_mobility", name = "industry_upgrades.apply", param = { construction = 9, step = 3 } }')
	frames(g, FIRST)
	truthy((answerText(g, 210) or ""):find('"event":"industry_upgrades.apply"'), answerText(g, 210, "error"))
	local sent
	for _, c in ipairs(g.commands) do if c.kind == "scriptEvent" then sent = c end end
	truthy(sent, "a script event command")
	eq(sent.id, "hummer_age_of_mobility"); eq(sent.name, "industry_upgrades.apply"); eq(sent.param.construction, 9)
	eq(sent.src, "")
	eq(fake.guiSave.hummer_remote_probe and fake.guiSave.hummer_remote_probe.open, before, "the speed control is not asked")
	send(g, 211, "scriptEvent", '{ name = "x" }')
	frames(g, 20)
	truthy((answerText(g, 211, "error") or ""):find("id"))
	fake.guiSave.hummer_remote_probe = nil
	local g2 = newGame({ saves = SAVES, scriptEventFails = true })
	frames(g2, 2)
	send(g2, 212, "scriptEvent", '{ id = "m", name = "x" }')
	frames(g2, FIRST)
	truthy((answerText(g2, 212) or ""):find('"ok":true'), "answered: the engine's refusal comes later")
	local logged = false
	for _, l in ipairs(g2.logs) do if tostring(l):find("refused by the engine") then logged = true end end
	truthy(logged, "the refusal is logged")
	fake.guiSave.hummer_remote_probe = nil
end)

test("options: speedButtons shown by default, hide is a real choice", function()
	eq(core.options({}).speedButtons, true)
	eq(core.options({ speedButtons = 2 }).speedButtons, false)
	eq(core.options({ speedButtons = 9 }).speedButtons, true, "an unknown index falls back to the default")
end)

test("uiRequest: buttons hidden only by an explicit false", function()
	eq(core.uiRequest(nil).buttons, true)
	eq(core.uiRequest({}).buttons, true, "nothing published yet: shown, as before the setting")
	eq(core.uiRequest({ buttons = false }).buttons, false)
	eq(core.uiRequest({ buttons = true }).buttons, true)
	eq(core.uiRequest({ buttons = "no" }).buttons, true, "anything but false keeps them")
end)

test("uiRequest: carries an event and a tool; malformed ones dropped", function()
	local r = core.uiRequest({ open = { seq = 3, event = { name = "e", param = { a = 1 } }, tool = { module = "/m.tl", field = "F", close = true } } })
	eq(r.open.event.name, "e"); eq(r.open.event.param.a, 1)
	eq(r.open.tool.module, "/m.tl"); eq(r.open.tool.field, "F"); eq(r.open.tool.close, true)
	r = core.uiRequest({ open = { seq = 4, event = { name = 7 }, tool = { module = "" } } })
	eq(r.open.event, nil); eq(r.open.tool, nil); eq(r.open.seq, 4)
end)

test("event and tool: handed to the speed control through the GUI save data", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 200, "event", '{ name = "example_window.show", param = { welcome = true } }')
	frames(g, FIRST)
	truthy((answerText(g, 200) or ""):find('"event":"example_window.show"'), answerText(g, 200))
	local open = fake.guiSave.hummer_remote_probe.open
	eq(open.event.name, "example_window.show"); eq(open.event.param.welcome, true)
	local seq = open.seq
	send(g, 201, "tool", '{ name = "music" }')
	frames(g, 20)
	open = fake.guiSave.hummer_remote_probe.open
	eq(open.tool.module, "/gui/music_player/music_player.tl"); truthy(open.seq > seq, "a new request")
	eq(open.event, nil, "only the newest request")
	send(g, 202, "tool", '{ name = "nope" }')
	frames(g, 20)
	truthy((answerText(g, 202, "error") or ""):find("unknown tool"))
	send(g, 203, "event", '{ name = "x", param = 3 }')
	frames(g, 20)
	truthy((answerText(g, 203, "error") or ""):find("must be a table"))
	fake.guiSave.hummer_remote_probe = nil
end)

test("quit: answered first, app.quit on the next frame, a run cancelled", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 210, "run", '{ days = 300, speed = 4 }')
	frames(g, FIRST)
	send(g, 211, "quit")
	local answeredAt, quitAt
	for i = 1, 20 do
		g.step()
		if not answeredAt and answerText(g, 211) then answeredAt = i end
		if not quitAt and g.quitCalled then quitAt = i end
		if quitAt then break end
	end
	eq(g.quitCalled, 1)
	truthy(answeredAt and quitAt and quitAt > answeredAt, "the answer is on disk a frame before the game quits")
	truthy((answerText(g, 211) or ""):find('"quitting":true'))
	truthy((answerText(g, 210, "error") or ""):find("cancelled: quit command"), answerText(g, 210, "error"))
	frames(g, 5)
	eq(g.quitCalled, 1, "once")
end)

test("menu: startup.lua answers in the main menu with the same files, and says it is the menu", function()
	local g = newGame({ saves = SAVES, menu = true })
	frames(g, 2)
	local hello = readJson(g.x, files(g.x, "^remote_probe__hello_")[1])
	truthy(hello:find('"menu":true'), hello)
	truthy(g.logs[1]:find("ready in the main menu"), g.logs[1])
	send(g, 220, "status")
	frames(g, FIRST)
	truthy((answerText(g, 220) or ""):find('"menu":true'), answerText(g, 220))
	send(g, 221, "saves")
	frames(g, 20)
	truthy((answerText(g, 221) or ""):find('"saveName":"probe"'))
	for i, cmd in ipairs({ "speed", "run", "save", "window", "event", "tool", "entities", "screenshot" }) do
		send(g, 221 + i, cmd, "{ speed = 1, days = 1, name = 'x', kind = 'town' }")
		frames(g, 20)
		truthy((answerText(g, 221 + i, "error") or ""):find("needs a running game"), cmd .. ": " .. tostring(answerText(g, 221 + i, "error")))
	end
	for _, l in ipairs(g.logs) do truthy(not l:find("error %("), "no script errors: " .. l) end
end)

test("menu: newgame starts without unsafe; the menu copy stops and the new game's probe answers", function()
	local g = newGame({ saves = SAVES, menu = true, menuKeepsRunning = true })
	frames(g, 2)
	local menuStamp = stampOf(g.x)
	send(g, 240, "newgame", '{ size = "tiny", year = 1900, mods = { add = { "other_mod" } } }')
	frames(g, FIRST)
	truthy(answerText(g, 240, "ack"), answerText(g, 240, "error"))
	eq(#g.started, 1)
	eq(table.concat(g.started[1].mods, ","), "other_mod,hummer_remote_probe")
	frames(g, 5)
	truthy(stampOf(g.x) ~= menuStamp, "the game's probe wrote a new hello")
	local hello = readJson(g.x, "remote_probe__hello_" .. stampOf(g.x) .. ".lua")
	truthy(hello:find('"menu":false'), hello)
	-- a command in the menu copy's file now goes unanswered (it stopped), even though it is still updated
	local f = assert(io.open(g.x .. "/remote_probe__cmd_" .. menuStamp .. ".lua", "w"))
	f:write('function data()\nreturn { id = 241, cmd = "status", args = {} }\nend\n')
	f:close()
	frames(g, FIRST)
	eq(answerText(g, 241), nil, "the menu copy is off")
	send(g, 242, "status")
	frames(g, FIRST)
	truthy((answerText(g, 242) or ""):find('"menu":false'), "the game's copy answers")
end)

test("menu: load from the main menu, with the save's mods and the probe", function()
	local g = newGame({ saves = SAVES, menu = true })
	frames(g, 2)
	local menuStamp = stampOf(g.x)
	send(g, 250, "load", '{ save = "probe" }')
	frames(g, FIRST)
	truthy(answerText(g, 250, "ack"), answerText(g, 250, "error"))
	eq(#g.loads, 1)
	frames(g, 5)
	truthy(stampOf(g.x) ~= menuStamp)
	for _, l in ipairs(g.logs) do truthy(not l:find("kept running"), "no replace-watch failure: " .. l) end
end)

test("menu: a load waits while mod.io is busy (the base menu breaks then), and goes as soon as it is ready; the wait is logged", function()
	local g = newGame({ saves = SAVES, menu = true, modhub = true })
	g.modhubBusy = true
	frames(g, 2)
	local menuStamp = stampOf(g.x)
	send(g, 251, "load", '{ save = "probe" }')
	frames(g, FIRST)
	truthy(answerText(g, 251, "ack"), answerText(g, 251, "error"))
	eq(#g.loads, 0)
	frames(g, 300) -- 10 s
	eq(#g.loads, 0)
	local said = 0
	for _, l in ipairs(g.logs) do if l:find("waits: mod.io is not ready") then said = said + 1 end end
	eq(said, 1) -- once, not every frame
	g.modhubBusy = false
	frames(g, 1)
	eq(#g.loads, 1)
	local waited = false
	for _, l in ipairs(g.logs) do waited = waited or l:find("waited %d+%.%d s for mod.io") ~= nil end
	truthy(waited)
	frames(g, 30)
	-- the new game's hello (stampOf takes the last name, and stamps do not sort by time)
	local fresh = false
	for _, h in ipairs(files(g.x, "^remote_probe__hello_")) do fresh = fresh or not h:find(menuStamp, 1, true) end
	truthy(fresh)
end)

test("menu: a load waits for mod.io at most 30 s, then loads anyway; no restricted mode yet (the menu's first 2-3 s) is not ready", function()
	local g = newGame({ saves = SAVES, menu = true, modhub = true })
	g.modhubNoRestricted = true
	frames(g, 2)
	send(g, 252, "load", '{ save = "probe" }')
	frames(g, FIRST)
	truthy(answerText(g, 252, "ack"), answerText(g, 252, "error"))
	frames(g, 25 * 30)
	eq(#g.loads, 0)
	frames(g, 10 * 30)
	eq(#g.loads, 1)
	local anyway = false
	for _, l in ipairs(g.logs) do anyway = anyway or l:find("load goes anyway") ~= nil end
	truthy(anyway)
end)

test("menu: an idle mod.io, or no modhub API at all, does not hold a load", function()
	local g = newGame({ saves = SAVES, menu = true, modhub = true })
	frames(g, 2)
	send(g, 253, "load", '{ save = "probe" }')
	frames(g, FIRST)
	eq(#g.loads, 1)
	truthy((g.modhubAsked or 0) > 0)
	for _, l in ipairs(g.logs) do truthy(not l:find("mod.io"), "nothing said when nothing waited: " .. l) end
	local h = newGame({ saves = SAVES, menu = true }) -- api.modhub is nil: said once, and the load goes
	frames(h, 2)
	send(h, 254, "load", '{ save = "probe" }')
	frames(h, FIRST)
	eq(#h.loads, 1)
	local said = 0
	for _, l in ipairs(h.logs) do if l:find("cannot read mod.io's state") then said = said + 1 end end
	eq(said, 1)
end)

test("menu: a new game waits for mod.io the same way (the menu takes the same branch when it starts)", function()
	local g = newGame({ saves = SAVES, menu = true, modhub = true })
	g.modhubNoRestricted = true
	frames(g, 2)
	send(g, 256, "newgame", '{ size = "tiny", year = 1900 }')
	frames(g, FIRST)
	truthy(answerText(g, 256, "ack"), answerText(g, 256, "error"))
	frames(g, 60)
	eq(#g.started, 0)
	g.modhubNoRestricted = false
	frames(g, 1)
	eq(#g.started, 1)
end)

test("menu: while a load waits for mod.io, a second load or a new game is refused, not run over it", function()
	local g = newGame({ saves = SAVES, menu = true, modhub = true })
	g.modhubBusy = true
	frames(g, 2)
	send(g, 257, "load", '{ save = "probe" }')
	frames(g, FIRST)
	truthy(answerText(g, 257, "ack"), answerText(g, 257, "error"))
	send(g, 258, "newgame", '{ size = "tiny", year = 1900 }')
	frames(g, 30)
	local e = answerText(g, 258, "error") or ""
	truthy(e:find("command 257"), e)
	eq(#g.started, 0)
	send(g, 259, "load", '{ save = "probe" }')
	frames(g, 60)
	e = answerText(g, 259, "error") or ""
	truthy(e:find("still waiting"), e)
	eq(#g.loads, 0)
	g.modhubBusy = false
	frames(g, 1)
	eq(#g.loads, 1) -- the first one, once
	eq(#g.started, 0)
end)

test("load inside a save does not look at mod.io: there is no main menu to break", function()
	local g = newGame({ saves = SAVES, modhub = true })
	g.modhubBusy = true
	frames(g, 2)
	send(g, 255, "load", '{ save = "probe" }')
	frames(g, FIRST)
	eq(#g.loads, 1)
	eq(g.modhubAsked, nil)
end)

test("menu: quit works there too", function()
	local g = newGame({ saves = SAVES, menu = true })
	frames(g, 2)
	send(g, 260, "quit")
	frames(g, FIRST)
	eq(g.quitCalled, 1)
	truthy(answerText(g, 260))
end)

test("speed control: fires a requested event and pushes or pops a tool on the game's tool stack", function()
	newGame({ saves = SAVES }) -- the game API of a running game (the menu tests left a menu one)
	local exports = loadSpeedScript()
	local pushed = {}
	local music = { "MUSIC_TOOL" }
	package.preload["/gui/music_player/music_player.tl"] = function() return music end
	package.preload["/gui/game_bar/game_bar_widgets.tl"] = function() return { CalendarEditorTool = { "CAL" } } end
	local stackApi = {
		push = function(def, key, p) pushed[#pushed + 1] = { "push", def, p } end,
		pop = function(def, key) pushed[#pushed + 1] = { "pop", def } end,
	}
	local gameCtx = { toolStack = { get = function() return { getApi = function() return stackApi end } end } }
	local params = { gameCtx = gameCtx }
	publish({ label = "", open = { seq = 1 } })
	frame(exports.SpeedControl, params)
	publish({ label = "", open = { seq = 2, event = { name = "example_window.show", param = { welcome = true } } } })
	frame(exports.SpeedControl, params)
	eq(#R.events, 1); eq(R.events[1].name, "example_window.show"); eq(R.events[1].param.welcome, true)
	publish({ label = "", open = { seq = 3, tool = { module = "/gui/music_player/music_player.tl" } } })
	frame(exports.SpeedControl, params)
	eq(#pushed, 1); eq(pushed[1][1], "push"); eq(pushed[1][2], music); eq(pushed[1][3].gameCtx, gameCtx)
	publish({ label = "", open = { seq = 4, tool = { module = "/gui/game_bar/game_bar_widgets.tl", field = "CalendarEditorTool", close = true } } })
	frame(exports.SpeedControl, params)
	eq(pushed[2][1], "pop"); eq(pushed[2][2][1], "CAL")
	frame(exports.SpeedControl, params)
	eq(#pushed, 2, "each request once")
	publish(nil)
	package.preload["/gui/music_player/music_player.tl"] = nil
end)

test("speed control: a manager request fires openVehicleManager with the line, once", function()
	newGame({ saves = SAVES })
	local exports = loadSpeedScript()
	publish({ label = "", open = { seq = 1, manager = 5 } })
	frame(exports.SpeedControl, {})
	eq(#R.events, 0, "the request left in the save is not opened")
	publish({ label = "", open = { seq = 2, manager = 21 } })
	frame(exports.SpeedControl, {})
	eq(#R.events, 1)
	eq(R.events[1].name, "openVehicleManager"); eq(R.events[1].param.openWithLineEntity, 21)
	frame(exports.SpeedControl, {})
	eq(#R.events, 1, "opened once")
	publish({ label = "", open = { seq = 3, manager = 22, entity = 9 } })
	frame(exports.SpeedControl, {})
	eq(#R.events, 3, "both, if a request ever held both")
	eq(R.events[2].name, "selectEntity"); eq(R.events[3].param.openWithLineEntity, 22)
	publish(nil)
end)

test("speed control: a tool it cannot open is logged once, and nothing breaks", function()
	newGame({ saves = SAVES }) -- the game API of a running game (the menu tests left a menu one)
	local exports = loadSpeedScript()
	local printed = {}
	local realPrint = print
	print = function(s) printed[#printed + 1] = s end
	package.preload["/gui/no_tool.tl"] = function() return "not a table" end
	local ok, err = pcall(function()
		publish({ label = "", open = { seq = 1 } })
		frame(exports.SpeedControl, {})
		publish({ label = "", open = { seq = 2, tool = { module = "/gui/music_player/music_player.tl" } } })
		package.preload["/gui/music_player/music_player.tl"] = function() return { "M" } end
		frame(exports.SpeedControl, {}) -- no gameCtx in the params
		publish({ label = "", open = { seq = 3, tool = { module = "/gui/music_player/music_player.tl" } } })
		frame(exports.SpeedControl, {})
		publish({ label = "", open = { seq = 4, tool = { module = "/gui/no_tool.tl" } } })
		frame(exports.SpeedControl, { gameCtx = {} })
		publish({ label = "x", open = { seq = 5, entity = 9 } })
		frame(exports.SpeedControl, {})
	end)
	print = realPrint
	package.preload["/gui/no_tool.tl"] = nil
	package.preload["/gui/music_player/music_player.tl"] = nil
	publish(nil)
	truthy(ok, err)
	eq(#printed, 2, "one line per distinct failure (the same one twice is logged once): " .. table.concat(printed, " | "))
	truthy(printed[1]:find("no gameCtx"), printed[1])
	truthy(printed[2]:find("is not a tool"), printed[2])
	eq(R.events[#R.events].name, "selectEntity", "a later window request still works")
end)

test("menu: a game loaded by hand (without the probe) stops the menu copy, so no newgame inside a save", function()
	local g = newGame({ saves = SAVES, menu = true, menuKeepsRunning = true })
	frames(g, 2)
	g.menu = false -- someone loaded a save from the menu; its mods lack the probe, so nothing else answers
	frames(g, 2)
	send(g, 270, "newgame", '{ size = "tiny" }')
	frames(g, FIRST)
	eq(#g.started, 0, "no startGame from inside a save")
	eq(answerText(g, 270, "ack"), nil)
	local said
	for _, l in ipairs(g.logs) do said = said or l:find("a game is running; the menu copy stops") end
	truthy(said, "logged why it stopped")
end)

test("quit: waits for a save in progress", function()
	local g = newGame({ saves = SAVES, saveSeconds = 2 })
	frames(g, 2)
	send(g, 280, "save", '{ name = "q" }')
	frames(g, FIRST)
	send(g, 281, "quit")
	frames(g, 20)
	truthy((answerText(g, 281) or ""):find('"afterSave":true'), answerText(g, 281))
	eq(g.quitCalled, nil, "not while saving")
	frames(g, 30 * 3)
	eq(g.quitCalled, 1, "once the save is done")
end)

test("startup.lua: run again in the same Lua state it reuses the probe; a probe that fails to load ends nothing", function()
	local g = newGame({ saves = SAVES, menu = true })
	frames(g, 2)
	local first = g.menuScript
	-- the base reruns a module that returns nothing (remote.script.lua): count how often it runs
	local runs = 0
	package.loaded["hummer_remote_probe::/remote.script.lua"] = nil
	package.preload["hummer_remote_probe::/remote.script.lua"] = function()
		runs = runs + 1
		return assert(loadfile(root .. "/content/remote.script.lua"))()
	end
	local quiet = {}
	local realPrint0 = print
	print = function(x) quiet[#quiet + 1] = x end
	local again = g.asMod(function()
		_G.data = false
		dofile(root .. "/content/startup.lua")
		return _G.data()
	end)
	print = realPrint0
	package.preload["hummer_remote_probe::/remote.script.lua"] = nil
	truthy(again ~= first and again.update, "a new startup table")
	eq(runs, 0, "remote.script.lua did not run again: the probe was made once")
	eq(#quiet, 0, "the probe was reused, not lost: " .. table.concat(quiet, " | "))
	g.menuScript = again
	send(g, 290, "status")
	frames(g, FIRST)
	truthy((answerText(g, 290) or ""):find('"menu":true'), "the same probe still answers")
	eq(#g.globalWrites, 0, "no new globals: " .. table.concat(g.globalWrites, ", "))
	-- a fresh process: nothing kept, and a broken remote.script.lua is logged, not raised
	package.loaded["hummer_remote_probe::/remote.script.lua"] = nil
	package.loaded["hummer_remote_probe::/remote_core.lua"] = nil
	local printed = {}
	local realPrint = print
	print = function(s) printed[#printed + 1] = s end
	package.preload["hummer_remote_probe::/remote.script.lua"] = function() error("broken file") end
	local ok, err = pcall(function()
		_G.data = false
		dofile(root .. "/content/startup.lua")
		local s = _G.data()
		s.handleEvent()
		s.update()
	end)
	print = realPrint
	package.preload["hummer_remote_probe::/remote.script.lua"] = nil
	package.loaded["hummer_remote_probe::/remote.script.lua"] = nil
	truthy(ok, err)
	truthy((printed[1] or ""):find("could not start the probe in the main menu: .*broken file"), printed[1])
end)

test("startup.lua makes no new globals (the base logs each as an error and sends a crash report)", function()
	-- the base's guard, as in ::/base/init.lua: a new key on _G is logged; data is declared up front
	local g = newGame({ saves = SAVES, menu = true })
	frames(g, 2)
	truthy(g.menuScript and g.menuScript.update, "the menu probe started")
	eq(#g.globalWrites, 0, "no new globals at load: " .. table.concat(g.globalWrites, ", "))
	send(g, 295, "status")
	frames(g, FIRST)
	truthy((answerText(g, 295) or ""):find('"menu":true'), answerText(g, 295))
	eq(#g.globalWrites, 0, "none from update either: " .. table.concat(g.globalWrites, ", "))
	-- the guard itself sees one: what the old startup.lua did (data = nil, then a global for the probe)
	g.asMod(function() _G.data = nil; data = function() end; __hummer_remote_probe_test_global = 1 end)
	eq(table.concat(g.globalWrites, ","), "data,__hummer_remote_probe_test_global")
	_G.__hummer_remote_probe_test_global = nil
	_G.data = false
end)

test("menu: newgame takes the base's and each mod's defaults, as the base new-game page; --param on top", function()
	local g = newGame({ saves = SAVES, menu = true, modDescs = {
		[""] = { { key = "guideSystemConfig.tutorial", defaultIndex = 1 }, { key = "map.size", defaultIndex = 2 } },
		other_mod = { { key = "show_window", defaultIndex = 1 } },
		hummer_remote_probe = { { key = "pollIdle", defaultIndex = 1 } }, -- 0-based as in mod.json: all shift by 1
	} })
	frames(g, 2)
	send(g, 300, "newgame", '{ size = "tiny", mods = { add = { "other_mod", "unknown_mod" } }, params = { [""] = { ["guideSystemConfig.tutorial"] = 1 } } }')
	frames(g, FIRST)
	truthy(answerText(g, 300, "ack"), answerText(g, 300, "error"))
	local p = g.started[1].modParams
	eq(p[""]["guideSystemConfig.tutorial"], 1, "--param wins (Off)")
	eq(p[""]["map.size"], 3, "the base default, 1-based")
	eq(p.other_mod.show_window, 2)
	eq(p.hummer_remote_probe.pollIdle, 2)
	eq(next(p.unknown_mod or {}), nil, "a mod without a description gets no params")
	-- descriptions already 1-based (pollIdle 2): no shift
	g = newGame({ saves = SAVES, menu = true, modDescs = {
		[""] = { { key = "map.size", defaultIndex = 3 } }, hummer_remote_probe = { { key = "pollIdle", defaultIndex = 2 } } } })
	frames(g, 2)
	send(g, 301, "newgame", '{ size = "tiny" }')
	frames(g, FIRST)
	eq(g.started[1].modParams[""]["map.size"], 3)
	eq(g.started[1].modParams.hummer_remote_probe.pollIdle, 2)
end)

---------------------------------------------------------------------------------------------------------------------
-- vehicles: buy, duplicate, replace, sell, depots, vehicles

-- a small JSON reader for the answers (strings, numbers, booleans, null, arrays, objects)
local function decode(text)
	local i = 1
	local function ws() i = text:find("[^ \t\r\n]", i) or #text + 1 end
	local value
	local function str()
		local out = {}
		i = i + 1
		while true do
			local c = text:sub(i, i)
			if c == '"' then i = i + 1; return table.concat(out) end
			if c == "\\" then
				local n = text:sub(i + 1, i + 1)
				if n == "u" then out[#out + 1] = string.char(tonumber(text:sub(i + 2, i + 5), 16) % 256); i = i + 6
				else out[#out + 1] = ({ n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" })[n] or n; i = i + 2 end
			else out[#out + 1] = c; i = i + 1 end
		end
	end
	function value()
		ws()
		local c = text:sub(i, i)
		if c == "{" then
			local t = {}
			i = i + 1; ws()
			if text:sub(i, i) == "}" then i = i + 1; return t end
			while true do
				ws(); local k = str(); ws(); i = i + 1 -- ':'
				t[k] = value(); ws()
				local d = text:sub(i, i); i = i + 1
				if d == "}" then return t end
			end
		elseif c == "[" then
			local t = {}
			i = i + 1; ws()
			if text:sub(i, i) == "]" then i = i + 1; return t end
			while true do
				t[#t + 1] = value(); ws()
				local d = text:sub(i, i); i = i + 1
				if d == "]" then return t end
			end
		elseif c == '"' then return str()
		elseif text:sub(i, i + 3) == "true" then i = i + 4; return true
		elseif text:sub(i, i + 4) == "false" then i = i + 5; return false
		elseif text:sub(i, i + 3) == "null" then i = i + 4; return nil
		else
			local num = text:match("^-?[%d%.eE+-]+", i)
			i = i + #num
			return tonumber(num)
		end
	end
	return value()
end

-- the one final answer of a command (plain or _error), decoded, and how many final answers there are
local function final(g, id)
	local a, e = answerText(g, id), answerText(g, id, "error")
	return decode(a or e or "null"), (a and 1 or 0) + (e and 1 or 0)
end

test("core.vehicleArgs: defaults, and every bad value refused with a reason", function()
	local a = core.vehicleArgs("buy", { model = "bus", depot = 301 })
	eq(a.via, "gui"); eq(a.count, 1); eq(a.depot, 301); eq(a.model, "bus")
	eq(core.vehicleArgs("buy", { model = 101, depot = 301, via = "cmd", count = 20, line = 21 }).model, "101")
	for _, bad in ipairs({
		{ "buy", nil, "give the model" },
		{ "buy", { model = "", depot = 1 }, "give the model" },
		{ "buy", { model = "bus" }, "give the depot" },
		{ "buy", { model = "bus", depot = 1, via = "react" }, "via must be gui or cmd" },
		{ "buy", { model = "bus", depot = 1, count = 0 }, "count must be" },
		{ "buy", { model = "bus", depot = 1, count = 21 }, "count must be" },
		{ "buy", { model = "bus", depot = 1, count = 1.5 }, "count must be" },
		{ "buy", { model = "bus", depot = 1, count = "x" }, "count must be" },
		{ "buy", { model = "bus", depot = -1 }, "depot must be an entity id" },
		{ "buy", { model = "bus", depot = "abc" }, "depot must be an entity id" },
		{ "buy", { model = "bus", depot = 1, line = {} }, "line must be an entity id" },
		{ "sell", {}, "give the vehicle" },
		{ "duplicate", { vehicle = 2.5 }, "vehicle must be an entity id" },
		{ "replace", { vehicle = 4 }, "give the model" },
		{ "fly", { vehicle = 4 }, "unknown vehicle command" },
	}) do
		local ok, err = core.vehicleArgs(bad[1], bad[2])
		eq(ok, nil, bad[3])
		truthy(tostring(err):find(bad[3], 1, true), tostring(err) .. " / " .. bad[3])
	end
	eq(core.vehicleArgs("sell", { vehicle = 7 }).vehicle, 7)
end)

test("core.matchModel: id, exact name, file name, unique part; ambiguous ones list candidates", function()
	local list = { { id = 101, name = "vehicle/bus/bus_1900.mdl" }, { id = 102, name = "vehicle/bus/bus_1920.mdl" },
		{ id = 103, name = "vehicle/truck/bus_1900_cargo.mdl" } }
	eq(core.matchModel(list, "102").id, 102)
	eq(core.matchModel(list, 101).id, 101)
	eq(core.matchModel(list, "VEHICLE/BUS/BUS_1920.MDL").id, 102)
	eq(core.matchModel(list, "bus_1900").id, 101, "the file name beats the longer one containing it")
	eq(core.matchModel(list, "cargo").id, 103)
	local hit, err = core.matchModel(list, "bus")
	eq(hit, nil)
	truthy(err:find("3 models match") and err:find("bus_1920.mdl (102)", 1, true), err)
	truthy(select(2, core.matchModel(list, "tram")):find("no vehicle model matches"))
	truthy(select(2, core.matchModel(list, "")):find("give the model"))
	truthy(select(2, core.matchModel(nil, "bus")):find("no vehicle model"))
	eq(core.spent(100, 70), 30); eq(core.spent(70, 100), -30); eq(core.spent(nil, 5), nil); eq(core.spent(5, nil), nil)
end)

local function fleetOf(model, purchaseTime, line)
	return { vehicles = { { part = { modelId = model, reversed = false, compartment2loadConfig = {} }, purchaseTime = purchaseTime,
		maintenanceState = 0.4, autoLoadConfig = {} } }, vehicleGroups = { 1 }, muFileNames = {}, line = line or -1, depot = -1 }
end

-- a game a little into 1900, so a stamped purchaseTime differs from 0
-- a game with the speed control on screen (unless opts.noSpeedControl): each frame the guiUpdate script, then
-- the recipe (render, step timer, join), which runs the gui way of the vehicle commands
local function vehicleGame(opts)
	opts = opts or {}
	opts.saves = opts.saves or SAVES
	local g = newGame(opts)
	if not opts.noSpeedControl then
		local exports = loadSpeedScript()
		local step = g.step
		g.speedControl = exports.SpeedControl
		g.step = function(dt)
			step(dt)
			if not g.speedControlOff then frame(exports.SpeedControl, { gameCtx = {} }) end
		end
	end
	frames(g, 2)
	g.gameTime = 123456
	g.frozen = true -- game time stays, so a stamped purchaseTime is known
	return g
end

test("buy via gui: the base's HandleVehicleChanges stamps purchaseTime; balance, price and value come back", function()
	local g = vehicleGame()
	send(g, 401, "buy", '{ model = "bus_1900", depot = 301, line = 21 }')
	frames(g, FIRST)
	local a, n = final(g, 401)
	eq(n, 1, "one answer")
	eq(a.ok, true, tostring(a.error))
	eq(a.via, "gui"); eq(g.guiChanges, 1)
	eq(a.balanceBefore, 1000000); eq(a.balanceAfter, 970000); eq(a.spent, 30000)
	eq(a.model.id, 101); eq(a.model.fileName, "vehicle/bus/bus_1900.mdl"); eq(a.model.price, 30000); eq(a.storePriceTotal, 30000)
	eq(#a.vehicles, 1)
	local v = a.vehicles[1]
	truthy(a.sentParts[1].purchaseTime > 0, "HandleVehicleChanges stamped the time")
	eq(v.parts[1].purchaseTime, a.sentParts[1].purchaseTime, "the engine keeps what was sent")
	eq(v.parts[1].modelId, 101); eq(v.parts[1].partPrice, 30000)
	eq(v.depreciatedValue, 27000)
	eq(v.line, 21, "the base sent it to the line")
	eq(g.fleet[v.entity].line, 21)
end)

-- regression: TF3 died on the first cmd buy (2026-11-16 13:21 JST, assertion in UpdateConfigFromModelIds) since
-- autoLoadConfig went out empty; the fake now dies the same way on a size mismatch
test("buy and replace via cmd: autoLoadConfig goes out with one entry per compartment, purchaseTime still 0", function()
	local g = vehicleGame({ fleet = { [601] = fleetOf(101, 5) } })
	send(g, 491, "buy", '{ model = "bus_1900", depot = 301, via = "cmd" }')
	frames(g, FIRST)
	local a = final(g, 491)
	eq(g.crashed, nil)
	eq(a.ok, true, tostring(a.error))
	send(g, 492, "replace", '{ vehicle = 601, model = "bus_1920", via = "cmd" }')
	frames(g, FIRST)
	local b = final(g, 492)
	eq(g.crashed, nil)
	eq(b.ok, true, tostring(b.error))
	local seen = 0
	for _, c in ipairs(g.commands) do
		if c.kind == "buy" or c.kind == "replace" then
			seen = seen + 1
			local p = c.config.vehicles[1]
			eq(#p.autoLoadConfig, #p.part.compartment2loadConfig)
			truthy(#p.autoLoadConfig > 0, "the model has compartments")
			if c.kind == "buy" then eq(p.purchaseTime, 0) end
		end
	end
	eq(seen, 2)
end)

test("buy via cmd: purchaseTime 0 goes to the engine; the answer shows sent and read-back values", function()
	local g = vehicleGame()
	send(g, 402, "buy", '{ model = "101", depot = 301, via = "cmd", count = 3, line = 21 }')
	frames(g, FIRST)
	local a = final(g, 402)
	eq(a.ok, true, tostring(a.error))
	eq(a.via, "cmd"); eq(g.guiChanges, nil, "the base module was not used")
	eq(a.sentParts[1].purchaseTime, 0)
	eq(#a.vehicles, 3); eq(a.spent, 90000); eq(a.storePriceTotal, 90000)
	for _, v in ipairs(a.vehicles) do eq(v.parts[1].purchaseTime, 0); eq(v.line, 21) end
	-- an engine that fills it in: the read-back differs from what was sent
	g = vehicleGame({ engineStampsPurchaseTime = true })
	send(g, 403, "buy", '{ model = 101, depot = 301, via = "cmd" }')
	frames(g, FIRST)
	a = final(g, 403)
	eq(a.sentParts[1].purchaseTime, 0)
	truthy(a.vehicles[1].parts[1].purchaseTime > 0, "read back from the engine")
end)

test("buy: not enough money, a failed module load, a bad model and a lost callback each answer once", function()
	for _, via in ipairs({ "gui", "cmd" }) do
		local g = vehicleGame({ balance = 40000 })
		send(g, 410, "buy", string.format('{ model = "bus_1900", depot = 301, count = 2, via = %q }', via))
		frames(g, FIRST)
		local a, n = final(g, 410)
		eq(n, 1)
		eq(a.ok, false, via)
		eq(#a.vehicles, 1, via .. ": the first one was bought")
		eq(#a.failures, 1)
		truthy(a.error:find("money"), a.error)
		eq(a.spent, 30000)
	end
	local g = vehicleGame({ noGuiModule = true })
	send(g, 411, "buy", '{ model = "bus_1900", depot = 301 }')
	frames(g, FIRST)
	local a = final(g, 411)
	eq(a.ok, false)
	truthy(a.error:find("via gui: could not load /gui/line_vehicle_mgmt/vehicle_react_util.tl", 1, true), a.error)
	eq(g.balance, 1000000, "nothing bought, and not by cmd behind the caller's back")
	for _, c in ipairs(g.commands) do truthy(c.kind ~= "buy", "no buy command") end
	send(g, 412, "buy", '{ model = "bus", depot = 301, via = "cmd" }')
	frames(g, 20)
	a = final(g, 412)
	truthy(a.error:find("2 models match"), "the building with bus in its name is no candidate: " .. a.error)
	send(g, 413, "buy", '{ model = "bus_house", depot = 301, via = "cmd" }')
	frames(g, 20)
	truthy(final(g, 413).error:find("no vehicle model matches"))
	g = vehicleGame({ lostCallbacks = true })
	send(g, 414, "buy", '{ model = "bus_1900", depot = 301, via = "cmd" }')
	frames(g, FIRST)
	eq(answerText(g, 414), nil, "still waiting")
	eq(answerText(g, 414, "error"), nil)
	frames(g, 70, 1)
	local b, m = final(g, 414)
	eq(m, 1)
	truthy(b.error:find("no result in 60 s %(0 of 1 arrived%)"), b.error)
	eq(b.balanceBefore, 1000000)
	frames(g, 70, 1)
	eq(select(2, final(g, 414)), 1, "never answered twice")
end)

test("vehicle commands: a base function that raises is one error answer, never a second at the timeout", function()
	for _, cmd in ipairs({ { "buy", '{ model = "bus_1900", depot = 301 }' }, { "sell", "{ vehicle = 601 }" },
		{ "replace", '{ vehicle = 601, model = "bus_1920" }' }, { "duplicate", "{ vehicle = 601 }" } }) do
		local g = vehicleGame({ fleet = { [601] = fleetOf(101, 5) } })
		fake.guiModules["/gui/line_vehicle_mgmt/vehicle_react_util.tl"].HandleVehicleChanges = function() error("boom") end
		-- every answer written, also one the game drops because the file exists (saveUserdata never overwrites)
		local written, save0 = 0, app.saveUserdata
		app.saveUserdata = function(d, name, t)
			if name:find("^remote_probe__res_416_") and not name:find("_got$") then written = written + 1 end
			return save0(d, name, t)
		end
		send(g, 416, cmd[1], cmd[2])
		frames(g, FIRST)
		local a, n = final(g, 416)
		eq(n, 1, cmd[1])
		truthy(a.error:find("boom"), a.error)
		frames(g, 70, 1)
		eq(select(2, final(g, 416)), 1, cmd[1] .. ": answered once")
		eq(written, 1, cmd[1] .. ": one answer written")
		app.saveUserdata = save0
	end
end)

test("buy: the base's vehicle_util.makePart builds the part when it loads", function()
	local g = vehicleGame({ vehicleUtil = true })
	send(g, 415, "buy", '{ model = "bus_1900", depot = 301 }')
	frames(g, FIRST)
	eq(final(g, 415).ok, true)
	eq(g.madeParts, 1)
end)


test("duplicate: a copy with new parts (purchaseTime from now, full maintenance) on the source's line", function()
	local g = vehicleGame({ fleet = { [601] = fleetOf(101, 5, 21) } })
	send(g, 420, "duplicate", "{ vehicle = 601 }")
	frames(g, FIRST)
	local a = final(g, 420)
	eq(a.ok, true, tostring(a.error))
	eq(a.via, "gui"); eq(a.depot, 301); eq(a.line, 21)
	eq(a.source.entity, 601); eq(a.source.parts[1].purchaseTime, 5)
	local v = a.vehicles[1]
	truthy(v.entity ~= 601)
	eq(v.parts[1].purchaseTime, 123456 + 0, "stamped, not the source's 5")
	eq(v.parts[1].maintenanceState, 1)
	eq(v.line, 21); eq(a.spent, 30000)
	send(g, 421, "duplicate", '{ vehicle = 601, via = "cmd", depot = 301 }')
	frames(g, 20)
	a = final(g, 421)
	eq(a.ok, true); eq(a.vehicles[1].parts[1].purchaseTime, 0); eq(a.line, nil, "depot given, no line asked")
	send(g, 422, "duplicate", "{ vehicle = 999 }")
	frames(g, 20)
	truthy(final(g, 422).error:find("no vehicle 999"))
end)

test("replace: the vehicle runs the new model (gui: read back, no callback); cmd refused when gone", function()
	local g = vehicleGame({ fleet = { [601] = fleetOf(101, 5, 21) } })
	send(g, 430, "replace", '{ vehicle = 601, model = "bus_1920" }')
	frames(g, FIRST)
	local a = final(g, 430)
	eq(a.ok, true, tostring(a.error))
	eq(a.before.parts[1].modelId, 101)
	eq(a.vehicles[1].parts[1].modelId, 102)
	eq(a.vehicles[1].parts[1].purchaseTime, 123456)
	eq(a.sentParts[1].purchaseTime, 123456)
	eq(a.spent, 45000); eq(a.model.price, 45000)
	eq(a.vehicles[1].line, 21, "kept its line")
	send(g, 431, "replace", '{ vehicle = 601, model = "truck", via = "cmd" }')
	frames(g, 20)
	a = final(g, 431)
	eq(a.ok, true); eq(a.vehicles[1].parts[1].modelId, 103); eq(a.vehicles[1].parts[1].purchaseTime, 0)
	send(g, 432, "replace", '{ vehicle = 602, model = "truck" }')
	frames(g, 20)
	truthy(final(g, 432).error:find("no vehicle 602"))
end)

test("replace via gui: a vehicle that never changes ends in a timeout error", function()
	local g = vehicleGame({ fleet = { [601] = fleetOf(101, 5) } })
	-- the engine drops the replace: HandleVehicleChanges gives no callback, so only the read-back can tell
	local send0 = api.cmd.sendCommand
	api.cmd.sendCommand = function(cmd, cb) if cmd.kind ~= "replace" then return send0(cmd, cb) end end
	send(g, 433, "replace", '{ vehicle = 601, model = "bus_1920" }')
	frames(g, FIRST)
	frames(g, 70, 1)
	api.cmd.sendCommand = send0
	local a, n = final(g, 433)
	eq(n, 1)
	eq(a.ok, false)
	truthy(a.error:find("no result in 60 s"), a.error)
	eq(a.vehicles[1].parts[1].modelId, 101, "shows the vehicle as it still is")
end)

test("sell: the vehicle is gone and spent is what it brought (negative)", function()
	for _, via in ipairs({ "gui", "cmd" }) do
		local g = vehicleGame({ fleet = { [601] = fleetOf(101, 5) } })
		send(g, 440, "sell", string.format("{ vehicle = 601, via = %q }", via))
		frames(g, FIRST)
		local a = final(g, 440)
		eq(a.ok, true, via .. " " .. tostring(a.error))
		eq(a.sold, true); eq(g.fleet[601], nil)
		eq(a.spent, -27000); eq(a.before.depreciatedValue, 27000)
		eq(a.vehicles[1].gone, true)
	end
	local g = vehicleGame()
	send(g, 441, "sell", "{ vehicle = 601 }")
	frames(g, FIRST)
	truthy(final(g, 441).error:find("no vehicle 601"))
end)

test("depots and vehicles: lists to aim the commands; refused in the main menu", function()
	local g = vehicleGame({ fleet = { [601] = fleetOf(101, 5, 21), [602] = fleetOf(102, 6) },
		depots = { [301] = { carrier = 0, name = "Bus depot" }, [302] = { carrier = 1, name = "Rail depot" } } })
	g.fleet[602].depot = 301
	send(g, 450, "depots", "{  }")
	frames(g, FIRST)
	local a = final(g, 450)
	eq(#a.depots, 2)
	eq(a.depots[1].name, "Bus depot"); eq(a.depots[1].carrier, "ROAD"); eq(a.depots[1].vehicles, 1); eq(a.depots[1].id, 301)
	eq(a.depots[2].carrier, "RAIL")
	send(g, 451, "depots", '{ grep = "rail" }')
	frames(g, 20)
	eq(#final(g, 451).depots, 1)
	send(g, 452, "vehicles", "{ line = 21 }")
	frames(g, 20)
	a = final(g, 452)
	eq(a.total, 1); eq(a.vehicles[1].entity, 601); eq(a.vehicles[1].parts[1].fileName, "vehicle/bus/bus_1900.mdl")
	send(g, 453, "vehicles", "{  }")
	frames(g, 20)
	eq(final(g, 453).total, 2)
	g = newGame({ saves = SAVES, menu = true })
	frames(g, 2)
	send(g, 454, "buy", '{ model = "bus", depot = 301 }')
	frames(g, FIRST)
	truthy(final(g, 454).error:find("needs a running game"))
end)

test("replace via gui: answers once the vehicle holds the parts sent, not on the model alone", function()
	-- the same model again: the model alone says nothing, the purchaseTime stamped by the base does
	local g = vehicleGame({ fleet = { [601] = fleetOf(101, 5) }, callbackFrames = 10 })
	send(g, 460, "replace", '{ vehicle = 601, model = "bus_1900" }')
	frames(g, FIRST)
	local a = final(g, 460)
	eq(a.ok, true, tostring(a.error))
	eq(a.vehicles[1].parts[1].purchaseTime, 123456, "answered after the engine took the new parts")
	eq(a.matchesSent, true)
	-- the parts sent equal the vehicle's own: no way to tell, so no ok
	g = vehicleGame({ fleet = { [601] = fleetOf(101, 123456) } })
	send(g, 461, "replace", '{ vehicle = 601, model = "bus_1900" }')
	frames(g, FIRST)
	a = final(g, 461)
	eq(a.ok, false); eq(a.uncertain, true)
	truthy(a.error:find("cannot tell"), a.error)
end)

test("duplicate: the store price is every part's cost.price, with each part's model", function()
	local f = fleetOf(101, 5, 21)
	f.vehicles[2] = { part = { modelId = 103, reversed = true, compartment2loadConfig = {} }, purchaseTime = 7,
		maintenanceState = 0.4, autoLoadConfig = {} }
	f.vehicleGroups = { 2 }
	local g = vehicleGame({ fleet = { [601] = f } })
	send(g, 462, "duplicate", "{ vehicle = 601 }")
	frames(g, FIRST)
	local a = final(g, 462)
	eq(a.ok, true, tostring(a.error))
	eq(#a.storeParts, 2)
	eq(a.storeParts[1].modelId, 101); eq(a.storeParts[2].modelId, 103)
	eq(a.storeParts[2].priceBefore, 20000)
	eq(a.storePriceTotal, 50000); eq(a.spent, 50000)
	eq(a.model, nil, "no single model for a vehicle of two")
	eq(#a.sentParts, 2); eq(a.sentParts[2].modelId, 103); eq(a.sentParts[2].purchaseTime, 123456)
	eq(#a.vehicles[1].parts, 2)
end)

test("vehicle answers: game time before and after, and a warning when it moved", function()
	local g = vehicleGame()
	send(g, 463, "buy", '{ model = "bus_1900", depot = 301 }')
	frames(g, FIRST)
	local a = final(g, 463)
	eq(a.gameTimeBefore, 123456); eq(a.gameTimeAfter, 123456); eq(a.warning, nil)
	g = vehicleGame()
	g.frozen = false
	send(g, 464, "buy", '{ model = "bus_1900", depot = 301, via = "cmd" }')
	frames(g, FIRST)
	a = final(g, 464)
	truthy(a.gameTimeAfter > a.gameTimeBefore)
	truthy(a.warning and a.warning:find("pause"), tostring(a.warning))
	truthy(a.notes and a.notes[1]:find("purchaseTime sent as 0"), "cmd says what it leaves out")
end)

test("vehicle step: a job that raises is failed once, and the others are answered once", function()
	local answers, fails = {}, {}
	local V = dofile(root .. "/content/remote_vehicles.lua").new({ core = core,
		answer = function(id) answers[id] = (answers[id] or 0) + 1 end,
		fail = function(id) fails[id] = (fails[id] or 0) + 1 end,
		appTime = function() return 0 end, try = function(fn) local ok, v = pcall(fn); return ok and v or nil end,
		say = function() end })
	local function job(id, check)
		return { id = id, kind = "buy", via = "cmd", deadline = 1e9, entities = {}, failures = {}, expected = 1,
			storeParts = {}, lineResult = {}, check = check }
	end
	V.jobs = { job(1, function() return true end), job(2, function() error("boom") end), job(3, function() return true end) }
	for _ = 1, 8 do pcall(V.step) end
	eq(answers[1], 1); eq(answers[3], 1); eq(fails[2], 1); eq(answers[2], nil)
	eq(#V.jobs, 0)
end)

test("buy with a line: answers once the vehicle is on it (gui: the base's own send; cmd: its callback)", function()
	for _, via in ipairs({ "gui", "cmd" }) do
		local g = vehicleGame({ callbackFrames = 5 })
		send(g, 465, "buy", string.format('{ model = "bus_1900", depot = 301, line = 21, via = %q }', via))
		frames(g, FIRST)
		local a = final(g, 465)
		eq(a.ok, true, via .. " " .. tostring(a.error))
		eq(a.vehicles[1].line, 21, via)
		eq(a.setLine[1].ok, true, via)
		eq(a.setLine[1].entity, a.vehicles[1].entity)
	end
end)

test("a result just before the deadline settles instead of timing out", function()
	local g = vehicleGame({ callbackFrames = 59 }) -- in at 59 s, settled at 62 s: past the 60 s deadline
	send(g, 466, "buy", '{ model = "bus_1900", depot = 301, via = "cmd" }')
	frames(g, 75, 1)
	local a, n = final(g, 466)
	eq(n, 1)
	eq(a.ok, true, tostring(a.error))
end)

test("depots: only the company's own", function()
	local g = vehicleGame({ depots = { [301] = { carrier = 0, name = "Ours" }, [302] = { carrier = 0, name = "Theirs", owner = 7 } } })
	send(g, 467, "depots", "{  }")
	frames(g, FIRST)
	local a = final(g, 467)
	eq(#a.depots, 1); eq(a.depots[1].name, "Ours")
end)

test("vehicle answers: cost.price and priceScale before sending and at the answer; a negative price is noted", function()
	local g = vehicleGame({ callbackFrames = 5, models = {
		[101] = { name = "vehicle/bus/bus_1900.mdl", price = 30000, priceScale = 1.5, vehicle = true },
		[104] = { name = "vehicle/bus/bus_scaled.mdl", price = -1, priceScale = 2, vehicle = true } } })
	send(g, 468, "buy", '{ model = "bus_1900", depot = 301, via = "cmd" }')
	for _ = 1, FIRST do
		g.step()
		-- a price mod rewrites the cost once the command is out
		if #g.commands > 0 then g.models[101].price = 33000 end
	end
	local a = final(g, 468)
	eq(a.model.price, 30000); eq(a.model.priceScale, 1.5)
	eq(a.model.priceAtAnswer, 33000); eq(a.model.priceScaleAtAnswer, 1.5)
	eq(a.storePriceTotal, 30000, "the price the command went out with")
	eq(a.storeParts[1].priceAtAnswer, 33000)
	send(g, 469, "buy", '{ model = "bus_scaled", depot = 301, count = 2, via = "cmd" }')
	frames(g, 40)
	a = final(g, 469)
	eq(a.storePriceTotal, -2); eq(a.model.priceScale, 2)
	local noted = false
	for _, n in ipairs(a.notes or {}) do noted = noted or n:find("negative cost.price", 1, true) ~= nil end
	truthy(noted, "a note on the negative price")
end)

test("buy via gui: the guiUpdate script never loads the base module; the speed control runs it and reports", function()
	-- the game's guiUpdate state cannot load vehicle_react_util.tl (react.RegisterRecipe fails there)
	local g = vehicleGame()
	local okLoad = pcall(require, "/gui/line_vehicle_mgmt/vehicle_react_util.tl")
	package.loaded["/gui/line_vehicle_mgmt/vehicle_react_util.tl"] = nil -- the failed load's mark
	eq(okLoad, false, "the fake refuses it outside a react state, as the game")
	send(g, 470, "buy", '{ model = "bus_1900", depot = 301 }')
	frames(g, FIRST)
	local a, n = final(g, 470)
	eq(n, 1); eq(a.ok, true, tostring(a.error)); eq(g.guiChanges, 1)
	local report = fake.guiSave["hummer_remote_probe.vehicles"]
	truthy(report and report.reports[1].id == 470, "the recipe reports under its own key")
	eq(report.reports[1].entities[1], a.vehicles[1].entity, "onBuy named the vehicle")
	eq(a.sentParts[1].purchaseTime, 123456, "from the report: what HandleVehicleChanges stamped")
	eq(fake.guiSave.hummer_remote_probe.vehicles[1], nil, "the request is withdrawn once answered")
end)

test("vehicles via gui: no speed control means a timeout that says so, and nothing bought", function()
	local g = vehicleGame({ noSpeedControl = true })
	send(g, 471, "buy", '{ model = "bus_1900", depot = 301 }')
	frames(g, FIRST)
	frames(g, 70, 1)
	local a, n = final(g, 471)
	eq(n, 1); eq(a.ok, false)
	truthy(a.error:find("no word from the speed control", 1, true), a.error)
	eq(g.balance, 1000000)
end)

test("vehicles via gui: the module failing to load in the recipe is one error answer, not a timeout", function()
	local g = vehicleGame({ noGuiModule = true })
	send(g, 472, "sell", "{ vehicle = 601 }")
	g.fleet[601] = fleetOf(101, 5)
	frames(g, FIRST)
	local a, n = final(g, 472)
	eq(n, 1); eq(a.ok, false)
	truthy(a.error:find("via gui: could not load /gui/line_vehicle_mgmt/vehicle_react_util.tl", 1, true), a.error)
	truthy(g.fleet[601] ~= nil, "not sold, and not by cmd")
end)

test("vehicles via gui: two requests at once both run, each answered with its own vehicle", function()
	local g = vehicleGame({ callbackFrames = 200 })
	send(g, 473, "buy", '{ model = "bus_1900", depot = 301 }')
	frames(g, FIRST)
	eq(select(2, final(g, 473)), 0, "the first still waits")
	send(g, 474, "buy", '{ model = "bus_1920", depot = 301 }')
	frames(g, 300)
	local a, b = final(g, 473), final(g, 474)
	eq(a.ok, true, tostring(a.error)); eq(b.ok, true, tostring(b.error))
	eq(g.guiChanges, 2)
	truthy(a.vehicles[1].entity ~= b.vehicles[1].entity)
	eq(a.vehicles[1].parts[1].modelId, 101); eq(b.vehicles[1].parts[1].modelId, 102)
end)

test("vehicles via gui: requests left in the GUI save data by the last game are never run", function()
	local g = vehicleGame()
	-- a fresh speed control (as after a load) whose first read finds an old request in the save data
	fake.guiSave.hummer_remote_probe.vehicles = { { id = 1, kind = "buy", modelId = 101, count = 1, depot = 301 } }
	local exports = loadSpeedScript()
	g.speedControlOff = true
	frame(exports.SpeedControl, { gameCtx = {} })
	frame(exports.SpeedControl, { gameCtx = {} })
	eq(g.guiChanges, nil, "the old request is not run")
end)

test("vehicles via gui: a report that does not come through still answers from the engine, with a note", function()
	local g = vehicleGame({ foreignKeyFails = true })
	send(g, 475, "buy", '{ model = "bus_1900", depot = 301 }')
	frames(g, FIRST)
	local a, n = final(g, 475)
	eq(n, 1); eq(a.ok, true, tostring(a.error))
	eq(#a.vehicles, 1); eq(a.spent, 30000)
	eq(a.sentParts, nil)
	local noted = false
	for _, x in ipairs(a.notes or {}) do noted = noted or x:find("no report", 1, true) ~= nil end
	truthy(noted, "says the report did not come")
end)

test("depots: the kind from the transport modes (carrier reads OTHER in game), with the raw carrier", function()
	local g = vehicleGame({ depots = { [301] = { name = "Road depot", modes = { "BUS", "TRUCK" } },
		[302] = { name = "Train depot", modes = { "TRAIN", "ELECTRIC_TRAIN" } }, [303] = { name = "Harbour", modes = { "SHIP" } },
		[304] = { name = "Maintenance", modes = {}, maintenancePool = 5 } } })
	send(g, 476, "depots", "{  }")
	frames(g, FIRST)
	local a = final(g, 476)
	local by = {}
	for _, d in ipairs(a.depots) do by[d.name] = d end
	eq(by["Road depot"].kind, "road"); eq(by["Train depot"].kind, "rail"); eq(by.Harbour.kind, "water")
	eq(by.Maintenance.kind, nil); eq(by.Maintenance.maintenancePool, 5)
	eq(by["Road depot"].carrier, "OTHER"); eq(by["Road depot"].carrierRaw, "5")
	eq(by["Road depot"].transportModes[1], "BUS")
end)

test("core.moneyArgs and moneyAmount: one of set and add, numbers in range, never with infinite money", function()
	eq(core.moneyArgs({ set = 1e6 }).set, 1000000)
	eq(core.moneyArgs({ add = "-2500.4" }).add, -2500)
	for _, bad in ipairs({ { nil, "exactly one" }, { { set = 1, add = 2 }, "exactly one" }, { { set = "lots" }, "must be a number" },
		{ { add = {} }, "must be a number" }, { { set = 0 / 0 }, "must be a number" }, { { set = 2 ^ 60 }, "out of range" },
		{ { add = -2 ^ 60 }, "out of range" } }) do
		local a, err = core.moneyArgs(bad[1])
		eq(a, nil); truthy(err:find(bad[2], 1, true), err)
	end
	eq(core.moneyAmount({ set = 1000 }, -784468249), 784469249)
	eq(core.moneyAmount({ add = -5 }, 10), -5)
	local n, err = core.moneyAmount({ set = 1 }, nil)
	eq(n, nil); truthy(err:find("infinite"), err)
	n, err = core.moneyAmount({ add = 2 ^ 53 - 1 }, 10)
	eq(n, nil); truthy(err:find("out of range"), err)
end)

test("money: sets or adds through a journal entry of category OTHER, as the sandbox money editor", function()
	local g = vehicleGame({ balance = -784468249 })
	send(g, 477, "money", "{ set = 10000000 }")
	frames(g, FIRST)
	local a, n = final(g, 477)
	eq(n, 1); eq(a.ok, true, tostring(a.error))
	eq(a.balanceBefore, -784468249); eq(a.balanceAfter, 10000000); eq(a.amount, 794468249); eq(a.callback, true)
	eq(g.journal[1].amount, 794468249); eq(g.journal[1].time, -1); eq(g.journal[1].category.type, 7)
	send(g, 478, "money", "{ add = -500 }")
	frames(g, 20)
	a = final(g, 478)
	eq(a.balanceAfter, 9999500); eq(a.spent, 500)
	g = vehicleGame({ infiniteMoney = true })
	send(g, 479, "money", "{ set = 5 }")
	frames(g, FIRST)
	a = final(g, 479)
	eq(a.ok, false); truthy(a.error:find("infinite"), a.error); eq(g.journal, nil)
	g = vehicleGame({ journalFails = true })
	send(g, 480, "money", "{ add = 5 }")
	frames(g, FIRST)
	a, n = final(g, 480)
	eq(n, 1); eq(a.ok, false); eq(a.callback, false)
	send(g, 481, "money", "{ set = 1, add = 2 }")
	frames(g, 20)
	truthy(final(g, 481).error:find("exactly one"))
	g = newGame({ saves = SAVES, menu = true })
	frames(g, 2)
	send(g, 482, "money", "{ add = 1 }")
	frames(g, FIRST)
	truthy(final(g, 482).error:find("needs a running game"))
end)

test("vehicles via gui: a speed control mounted again (new refs) still runs a waiting request, reports kept", function()
	local g = vehicleGame({ callbackFrames = 200 })
	send(g, 483, "buy", '{ model = "bus_1900", depot = 301 }')
	frames(g, FIRST)
	eq(g.guiChanges, 1)
	-- the same recipe mounted again: its refs start empty, the module (this Lua state) stays
	R.hooks = {}
	send(g, 484, "buy", '{ model = "bus_1920", depot = 301 }')
	frames(g, 300)
	local a, b = final(g, 483), final(g, 484)
	eq(a.ok, true, tostring(a.error)); eq(b.ok, true, tostring(b.error))
	eq(g.guiChanges, 2, "the request after the remount ran")
	local ids = {}
	for _, r in ipairs(fake.guiSave["hummer_remote_probe.vehicles"].reports) do ids[#ids + 1] = r.id end
	eq(table.concat(ids, ","), "483,484", "the first report is still there")
end)

test("vehicles via gui without a report: duplicate and replace still answer from the engine", function()
	local g = vehicleGame({ foreignKeyFails = true, fleet = { [601] = fleetOf(101, 5, 21) } })
	send(g, 485, "duplicate", "{ vehicle = 601 }")
	frames(g, FIRST)
	local a, n = final(g, 485)
	eq(n, 1); eq(a.ok, true, tostring(a.error))
	eq(#a.vehicles, 1); truthy(a.vehicles[1].entity ~= 601); eq(a.vehicles[1].parts[1].modelId, 101)
	eq(a.sentParts, nil)
	send(g, 486, "replace", '{ vehicle = 601, model = "bus_1920" }')
	frames(g, 40)
	a, n = final(g, 486)
	eq(n, 1); eq(a.ok, true, tostring(a.error))
	eq(a.vehicles[1].parts[1].modelId, 102); eq(a.matchesSent, nil, "nothing to match without the report")
end)

test("vehicles without a report: a cmd buy's vehicle is not taken by a gui buy waiting at the same time", function()
	local g = vehicleGame({ foreignKeyFails = true, callbackFrames = 100 })
	send(g, 487, "buy", '{ model = "bus_1900", depot = 301 }')
	frames(g, FIRST)
	send(g, 488, "buy", '{ model = "bus_1900", depot = 301, via = "cmd" }')
	frames(g, 300)
	local a, b = final(g, 487), final(g, 488)
	eq(a.ok, true, tostring(a.error)); eq(b.ok, true, tostring(b.error))
	truthy(a.vehicles[1].entity ~= b.vehicles[1].entity, "each its own vehicle")
end)

test("load: reports the last game left under the report key are cleared, never taken for this game's", function()
	fake.guiSave["hummer_remote_probe.vehicles"] = { reports = { { id = 489, kind = "buy", error = "old" } } }
	local g = vehicleGame()
	eq(#fake.guiSave["hummer_remote_probe.vehicles"].reports, 0)
	send(g, 489, "buy", '{ model = "bus_1900", depot = 301 }')
	frames(g, FIRST)
	local a = final(g, 489)
	eq(a.ok, true, tostring(a.error))
end)

test("depots: carriers through transportModesToCarriers when the engine has it, the modes table otherwise", function()
	local depots = { [301] = { name = "Road depot", modes = { "BUS", "TRUCK" } }, [302] = { name = "Tram depot", modes = { "TRAM" } } }
	local g = vehicleGame({ modesToCarriers = true, depots = depots })
	send(g, 490, "depots", "{  }")
	frames(g, FIRST)
	local a = final(g, 490)
	eq(a.depots[1].carriers[1], "ROAD"); eq(a.depots[1].kind, "road")
	eq(a.depots[2].carriers[1], "TRAM"); eq(a.depots[2].kind, "tram")
	g = vehicleGame({ depots = depots })
	send(g, 491, "depots", "{  }")
	frames(g, FIRST)
	a = final(g, 491)
	eq(a.depots[1].carriers, nil); eq(a.depots[1].kind, "road")
end)

test("money: a set the balance moved past (fares while the game runs) says so", function()
	local g = vehicleGame({ callbackFrames = 5 })
	send(g, 492, "money", "{ set = 5000000 }")
	for _ = 1, FIRST do
		g.step()
		if #g.commands > 0 and not g.fared then g.fared = true; g.balance = g.balance + 1234 end
	end
	local a = final(g, 492)
	eq(a.ok, true, tostring(a.error))
	truthy(a.balanceAfter ~= 5000000)
	local noted = false
	for _, x in ipairs(a.notes or {}) do noted = noted or x:find("set not reached", 1, true) ~= nil end
	truthy(noted, "a note")
end)

---------------------------------------------------------------------------------------------------------------------
-- lines: stations, lines, line create / update / delete

-- a town (11) and station groups: ours (42), nobody's (41, 43, 45, 46), another company's (44); 45 is rail only,
-- 46 has no station. Positions in metres.
local function lineWorld(extra)
	local w = {
		stationGroups = {
			[41] = { name = "Central", stations = { { id = 411, terminals = 2, passenger = true, pos = { 0, 0 } } } },
			[42] = { name = "Harbour", owner = 99, stations = { { id = 421, terminals = 1, passenger = true, pos = { 800, 0 } } } },
			[43] = { name = "Central Market", stations = { { id = 431, terminals = 1, passenger = true, pos = { 3000, 0 } } } },
			[44] = { name = "Rival Halt", owner = 7, stations = { { id = 441, terminals = 1, passenger = true, pos = { 100, 0 } } } },
			[45] = { name = "Freight Yard", stations = { { id = 451, terminals = 2, carriers = { "RAIL" }, pos = { 200, 0 } } } },
			[46] = { name = "Empty", stations = {} },
		},
		positions = { [11] = { 50, 0 } },
		names = { [11] = "Emsworth" },
	}
	for k, v in pairs(extra or {}) do w[k] = v end
	return vehicleGame(w)
end

test("renameRequest: an id and a name that is not blank", function()
	local r = core.renameRequest({ entity = 48064, name = "Chesham" })
	eq(r.entity, 48064); eq(r.name, "Chesham")
	eq(core.renameRequest({ entity = "7", name = "x" }).entity, 7, "an id as text, as JSON may carry it")
	eq(core.renameRequest({ entity = 0, name = "x" }).entity, 0)
	for _, bad in ipairs({ { name = "x" }, { entity = -1, name = "x" }, { entity = 1.5, name = "x" }, { entity = "a", name = "x" } }) do
		truthy(select(2, core.renameRequest(bad)):find("entity"))
	end
	for _, bad in ipairs({ { entity = 1 }, { entity = 1, name = "" }, { entity = 1, name = "  " }, { entity = 1, name = 5 } }) do
		truthy(select(2, core.renameRequest(bad)):find("name"))
	end
	truthy(select(2, core.renameRequest({ entity = 1, name = ("x"):rep(core.MAX_NAME_LEN + 1) })):find("longer"))
	eq(core.renameRequest({ entity = 1, name = ("x"):rep(core.MAX_NAME_LEN) }).name:len(), core.MAX_NAME_LEN)
	truthy(select(2, core.renameRequest(nil)))
end)

test("rename: a station group's name changes through the engine command, read back in the answer", function()
	local g = lineWorld()
	frames(g, 2)
	send(g, 230, "rename", '{ entity = 41, name = "Chesham" }')
	frames(g, FIRST)
	local a = answerText(g, 230) or ""
	truthy(a:find('"name":"Chesham"'), answerText(g, 230, "error"))
	truthy(a:find('"before":"Central"'), a)
	truthy(not a:find('"note"'), "no note when the name reads back as asked")
	eq(api.engine.util.getEntityName(41), "Chesham")
	local sent
	for _, c in ipairs(g.commands) do if c.kind == "setName" then sent = c end end
	eq(sent.entity, 41); eq(sent.name, "Chesham")
	-- refused by the engine (here: an entity the fake cannot name): an error answer, the old name stays
	send(g, 231, "rename", '{ entity = 999, name = "Nowhere" }')
	frames(g, FIRST)
	truthy((answerText(g, 231, "error") or ""):find("refused"), answerText(g, 231))
	-- a bad request is refused before any command is sent
	local n = #g.commands
	send(g, 232, "rename", '{ entity = 41, name = "" }')
	frames(g, FIRST)
	truthy((answerText(g, 232, "error") or ""):find("name"))
	eq(#g.commands, n, "nothing sent")
	-- the engine refuses a name it could take (renameFails): an error, and the old name stays
	local g2 = lineWorld({ renameFails = true })
	frames(g2, 2)
	send(g2, 233, "rename", '{ entity = 41, name = "X" }')
	frames(g2, FIRST)
	truthy((answerText(g2, 233, "error") or ""):find("refused"))
	eq(api.engine.util.getEntityName(41), "Central", "unchanged after a refusal")
	local logged = false
	for _, l in ipairs(g2.logs) do if tostring(l):find("rename 41: refused") then logged = true end end
	truthy(logged, "the refusal is logged")
	-- accepted, but the entity reads back another name (a station id whose group took it): ok, with a note
	local g3 = lineWorld()
	frames(g3, 2)
	local real = api.engine.util.getEntityName
	api.engine.util.getEntityName = function(e) if e == 42 then return "Harbour" end return real(e) end
	send(g3, 234, "rename", '{ entity = 42, name = "Port" }')
	frames(g3, FIRST)
	api.engine.util.getEntityName = real
	local a3 = answerText(g3, 234) or ""
	truthy(a3:find('"ok":true') and a3:find('"requested":"Port"') and a3:find('"note"'), a3)
end)

-- every command the fake engine got of a kind
local function sent(g, kind)
	local out = {}
	for _, c in ipairs(g.commands) do if c.kind == kind then out[#out + 1] = c end end
	return out
end

local function hasNote(a, text)
	for _, n in ipairs(a.notes or {}) do if n:find(text, 1, true) then return true end end
	return false
end

test("core.lineArgs: create, update, delete; empty, single, nil, userdata and malformed stops refused", function()
	local a = core.lineArgs({ action = "create", stops = { "Central", " 42 ", 43 } })
	eq(a.via, "gui"); eq(a.stops[1], "Central"); eq(a.stops[2], 42, "digits are an id"); eq(a.stops[3], 43)
	eq(core.lineArgs({ action = "update", line = 21, name = "[probe] A" }).name, "[probe] A")
	eq(core.lineArgs({ action = "update", line = 21, cargo = 2 }).cargo, "2")
	eq(core.lineArgs({ action = "delete", line = 21, sellVehicles = true }).sellVehicles, true)
	for _, bad in ipairs({
		{ nil, "action must be" },
		{ { action = "make" }, "action must be" },
		{ { action = "create" }, "give the stops" },
		{ { action = "create", stops = {} }, "stops is empty" },
		{ { action = "create", stops = { "Central" } }, "at least 2 stops" },
		{ { action = "create", stops = { "Central", "" } }, "stop 2 is empty" },
		{ { action = "create", stops = { "Central", "   " } }, "stop 2 is empty" },
		{ { action = "create", stops = { "Central", newproxy(true) } }, "got a userdata" },
		{ { action = "create", stops = { "Central", 4.5 } }, "stop 2 must be an entity id" },
		{ { action = "create", stops = { "Central", -1 } }, "stop 2 must be an entity id" },
		{ { action = "create", stops = { "Central", { 41 } } }, "got a table" },
		{ { action = "create", stops = newproxy(true) }, "stops must be a list" },
		{ { action = "create", stops = { a = 1, b = 2 } }, "stops must be a list" },
		{ { action = "create", stops = { [1] = 41, [3] = 42 } }, "stops must be a list" },
		{ { action = "create", stops = { 41, 42 }, line = 21 }, "no line" },
		{ { action = "create", stops = { 41, 42 }, via = "react" }, "via must be" },
		{ { action = "create", stops = { 41, 42 }, name = "" }, "name must be" },
		{ { action = "create", stops = { 41, 42 }, name = newproxy(true) }, "name must be" },
		{ { action = "create", stops = { 41, 42 }, name = string.rep("x", 101) }, "longer than" },
		{ { action = "create", stops = { 41, 42 }, cargo = true }, "cargo must be" },
		{ { action = "update", stops = { 41, 42 } }, "give the line" },
		{ { action = "update", line = 21 }, "give stops, name, cargo, terminals or load modes" },
		{ { action = "update", line = "x", name = "a" }, "line must be an entity id" },
		{ { action = "delete" }, "give the line" },
		{ { action = "delete", line = 21, stops = { 41, 42 } }, "delete takes no" },
		{ { action = "delete", line = 21, terminals = { 0, 0 } }, "delete takes no" },
		{ { action = "delete", line = 21, loadModes = "any" }, "delete takes no" },
	}) do
		local ok, err = core.lineArgs(bad[1])
		eq(ok, nil, bad[2])
		truthy(tostring(err):find(bad[2], 1, true), tostring(err) .. " / " .. bad[2])
	end
	local many = {}
	for i = 1, 51 do many[i] = i end
	truthy(select(2, core.lineArgs({ action = "create", stops = many })):find("more than 50"))
end)

test("core.lineRequests and matchCargo: plain requests only; cargo by id, name, label, unique part", function()
	local list = core.lineRequests({
		{ id = 1, kind = "create", stops = { { stationGroup = 41 }, { stationGroup = "42" } }, name = "A", cargo = 2 },
		{ id = 2, kind = "update", line = 21, stops = { { stationGroup = 41 }, { bad = true } } }, -- a bad stop: dropped
		{ id = 3, kind = "update" }, -- no line
		{ id = 4, kind = "delete", line = 21 }, -- not a gui kind
		{ id = 5, kind = "update", line = 21, cargo = 1, name = newproxy(true) },
		"junk", { kind = "create" },
	})
	eq(#list, 2)
	eq(list[1].stops[2].stationGroup, 42); eq(list[1].cargo, 2); eq(list[1].name, "A")
	eq(list[2].id, 5); eq(list[2].stops, nil); eq(list[2].name, nil, "only a string name goes")
	eq(#core.lineRequests(nil), 0); eq(#core.lineRequests(newproxy(true)), 0)
	local cargo = { { id = 0, name = "PASSENGERS", label = "Passengers" }, { id = 1, name = "COAL", label = "Coal" },
		{ id = 2, name = "GRAIN", label = "Grain" }, { id = 3, name = "COAL_TAR", label = "Coal tar" } }
	eq(core.matchCargo(cargo, "grain").id, 2)
	eq(core.matchCargo(cargo, "Coal").id, 1, "an exact label beats the longer one")
	eq(core.matchCargo(cargo, 2).id, 2); eq(core.matchCargo(cargo, "0").id, 0)
	eq(core.matchCargo(cargo, "rai").id, 2)
	truthy(select(2, core.matchCargo(cargo, "o")):find("cargo types match"))
	truthy(select(2, core.matchCargo(cargo, "milk")):find("no cargo type matches"))
	truthy(select(2, core.matchCargo(nil, "")):find("give the cargo"))
	eq(core.radiusArg(nil), 1000); eq(core.radiusArg("250"), 250)
	for _, bad in ipairs({ 0, -5, "x", 1e9, 0 / 0 }) do eq(core.radiusArg(bad), nil, tostring(bad)) end
end)

test("stations: the company's and nobody's groups with stations, platforms, carriers; --name; --near and radius", function()
	local g = lineWorld()
	send(g, 601, "stations", "{  }")
	frames(g, FIRST)
	local a = final(g, 601)
	eq(a.ok, true, tostring(a.error))
	local names = {}
	for _, s in ipairs(a.stations) do names[#names + 1] = s.name end
	eq(table.concat(names, ","), "Central,Central Market,Empty,Freight Yard,Harbour", "Rival Halt is another company's")
	local central = a.stations[1]
	eq(central.id, 41); eq(central.stations, 1); eq(central.terminals, 2); eq(central.carriers[1], "ROAD")
	eq(central.owner, "none"); eq(a.stations[5].owner, "player"); eq(a.stations[4].carriers[1], "RAIL")
	eq(central.position.x, 0); eq(central.stationIds, nil)
	send(g, 602, "stations", '{ name = "CENT" }')
	frames(g, 10)
	eq(#final(g, 602).stations, 2)
	send(g, 603, "stations", "{ near = 11, radius = 800 }")
	frames(g, 10)
	local b = final(g, 603)
	names = {}
	for _, s in ipairs(b.stations) do names[#names + 1] = s.name .. "@" .. s.distance end
	eq(table.concat(names, ","), "Central@50,Freight Yard@150,Harbour@750", "nearest first, the rival's left out")
	eq(b.radius, 800); eq(b.centre.x, 50)
	send(g, 604, "stations", "{ near = 11 }")
	frames(g, 10)
	eq(#final(g, 604).stations, 3, "1000 m by default")
	send(g, 605, "stations", "{ near = 12 }")
	frames(g, 10)
	truthy(final(g, 605).error:find("has no position"))
	send(g, 606, "stations", '{ near = 11, radius = -1 }')
	frames(g, 10)
	truthy(final(g, 606).error:find("radius must be"))
	send(g, 607, "stations", '{ near = "x" }')
	frames(g, 10)
	truthy(final(g, 607).error:find("near must be an entity id"))
end)

test("line create via gui: the base's line_util builds it; stops, platforms and name read back from the engine", function()
	local g = lineWorld()
	send(g, 610, "line", '{ action = "create", stops = { "Central", 42 } }')
	frames(g, FIRST)
	local a, n = final(g, 610)
	eq(n, 1); eq(a.ok, true, tostring(a.error))
	eq(a.via, "gui"); truthy((g.lineUtilCalls or 0) > 0, "line_util ran")
	truthy(a.line and g.lines[a.line], "the new line's entity")
	eq(a.name, "Line 1", "the base's makeLineName")
	eq(#a.stops, 2)
	eq(a.stops[1].stationGroup, 41); eq(a.stops[1].name, "Central"); eq(a.stops[1].station, 0)
	eq(a.stops[1].terminal, 1, "the engine's assignment (getBestLineAssignment)"); eq(a.stops[1].stationEntity, 411)
	eq(a.stops[2].stationGroup, 42); eq(a.stops[2].name, "Harbour")
	eq(a.sentStops[1].terminal, 1, "the recipe's report")
	eq(a.loads[1], "PASSENGERS", "autoLoadConfig: passengers at passenger stations")
	eq(a.vehicles, 0)
	truthy(hasNote(a, "via gui"), "says it ran in the speed control")
	eq(#sent(g, "lineCreate"), 1)
	eq(g.crashed, nil)
	eq(fake.guiSave.hummer_remote_probe.lines[1], nil, "the request is withdrawn once answered")
end)

test("line create via cmd: the probe's own stops, the engine's platforms, the name asked for", function()
	local g = lineWorld()
	send(g, 611, "line", '{ action = "create", stops = { 41, 43 }, name = "[probe] cmd", via = "cmd" }')
	frames(g, FIRST)
	local a, n = final(g, 611)
	eq(n, 1); eq(a.ok, true, tostring(a.error))
	eq(a.via, "cmd"); eq(g.lineUtilCalls, nil, "no base module")
	eq(a.name, "[probe] cmd"); eq(a.sentName, "[probe] cmd")
	eq(a.stops[1].terminal, 1); eq(a.stops[2].stationGroup, 43)
	eq(a.loads[1], "PASSENGERS")
	truthy(hasNote(a, "via cmd"), "the cmd note")
	local cmd = sent(g, "lineCreate")[1]
	eq(cmd.line.reservationPriority, 1.0)
	eq(#cmd.line.stops[1].stopConfig.load, 3, "one entry per cargo type, as the base's makeIdvector")
	eq(cmd.line.stops[1].maxAdditionalWaitingTime, 30, "road: the base's 30 s")
end)

test("line create: unknown, ambiguous, foreign, platformless and carrier-less stops are refused before sending", function()
	local g = lineWorld()
	local cases = {
		{ '{ "Central", "Nowhere" }', 'no match for "Nowhere"' },
		{ '{ "Cent", 42 }', '2 matches for "Cent"' },
		{ '{ 41, 999 }', "999 is no station group or station" },
		{ '{ 41, 44 }', "belongs to another company" },
		{ '{ 41, "Rival Halt" }', "belongs to another company" },
		{ '{ 41, 46 }', "has no station with a platform" },
		{ '{ 41, 45 }', "share no carrier" },
		{ '{ 41 }', "at least 2 stops" },
		{ '{ }', "stops is empty" },
	}
	for i, c in ipairs(cases) do
		for _, via in ipairs({ "gui", "cmd" }) do
			local id = 620 + i * 2 + (via == "cmd" and 1 or 0)
			send(g, id, "line", string.format('{ action = "create", stops = %s, via = %q }', c[1], via))
			frames(g, i == 1 and via == "gui" and FIRST or 10)
			local a, n = final(g, id)
			eq(n, 1, c[2]); eq(a.ok, false, c[2])
			truthy(tostring(a.error):find(c[2], 1, true), tostring(a.error) .. " / " .. c[2])
		end
	end
	eq(#sent(g, "lineCreate"), 0, "nothing sent")
	eq(g.crashed, nil)
	-- a station entity stands for its group
	send(g, 650, "line", '{ action = "create", stops = { 411, 421 }, via = "cmd" }')
	frames(g, 10)
	local a = final(g, 650)
	eq(a.ok, true, tostring(a.error)); eq(a.stops[1].stationGroup, 41); eq(a.stops[2].stationGroup, 42)
end)

test("line create: no platform from the engine is 0/0 as the base does (noted via cmd), never a -1 sent", function()
	for _, via in ipairs({ "gui", "cmd" }) do
		local g = lineWorld({ noAssignment = true })
		send(g, 651, "line", string.format('{ action = "create", stops = { 41, 42 }, via = %q }', via))
		frames(g, FIRST)
		local a = final(g, 651)
		eq(a.ok, true, via .. " " .. tostring(a.error))
		eq(a.stops[1].station, 0, via); eq(a.stops[1].terminal, 0, via)
		if via == "cmd" then truthy(hasNote(a, "found no platform"), "noted") end
		eq(g.crashed, nil, via)
	end
end)

test("line_configs.checkStops: a stop without a platform, or one past the station's, never goes out", function()
	local g = lineWorld()
	local lc = require "hummer_remote_probe::/line_configs.lua"
	truthy(lc.checkStops({ { stationGroup = 41, station = 0, terminal = 1 }, { stationGroup = 42, station = 0, terminal = 0 } }))
	for _, c in ipairs({
		{ { { stationGroup = 41, station = -1, terminal = 0 } }, "no platform was assigned" },
		{ { { stationGroup = 41, station = 0, terminal = -1 } }, "no platform was assigned" },
		{ { { stationGroup = 41, station = 1, terminal = 0 } }, "does not exist (1 stations)" },
		{ { { stationGroup = 41, station = 0, terminal = 2 } }, "does not exist (2 terminals)" },
		{ { { stationGroup = 46, station = 0, terminal = 0 } }, "does not exist (0 stations)" },
		{ { { stationGroup = nil, station = 0, terminal = 0 } }, "no platform" },
		{ {}, "no stops" },
		{ nil, "no stops" },
	}) do
		local ok, err = lc.checkStops(c[1])
		eq(ok, nil, c[2]); truthy(tostring(err):find(c[2], 1, true), tostring(err))
	end
	eq(g.crashed, nil)
end)

-- a line 21 at Central (terminal 1) and Harbour, with two vehicles
local function lineWithVehicles(extra)
	extra = extra or {}
	extra.lines = { [21] = { name = "Bus 1", stops = { { stationGroup = 41, station = 0, terminal = 1 },
		{ stationGroup = 42, station = 0, terminal = 0 } } } }
	local caps = { 30, 0, 0 } -- passengers only, per cargo type (id + 1)
	local v1, v2 = fleetOf(101, 5, 21), fleetOf(101, 5, 21)
	v1.capacities, v2.capacities = caps, caps
	extra.fleet = { [601] = v1, [602] = v2 }
	return lineWorld(extra)
end

test("lines: name, stops with their station groups' names, vehicles, what is loaded and what they carry", function()
	local g = lineWithVehicles()
	send(g, 660, "lines", "{  }")
	frames(g, FIRST)
	local a = final(g, 660)
	eq(a.ok, true, tostring(a.error)); eq(#a.lines, 1)
	local l = a.lines[1]
	eq(l.id, 21); eq(l.name, "Bus 1"); eq(l.vehicles, 2); eq(l.vehicleIds[1], 601)
	eq(l.stops[1].name, "Central"); eq(l.stops[1].terminal, 1); eq(l.stops[2].stationGroup, 42)
	eq(l.vehicleCargo[1], "PASSENGERS"); eq(#l.vehicleCargo, 1); eq(l.carriers[1], "ROAD")
	send(g, 661, "lines", '{ name = "tram" }')
	frames(g, 10)
	eq(next(final(g, 661).lines), nil, "filtered out")
end)

test("lines / stations: empty lists go out as [], not {} (seen in game 2026-11-17)", function()
	local g = lineWorld({})
	send(g, 662, "lines", "{  }")
	frames(g, FIRST)
	local t = answerText(g, 662) or ""
	truthy(t:find('\\"lines\\":%[%]') or t:find('"lines":%[%]'), t)
	local h = lineWorld({ lines = { [21] = { name = "Bus 1", stops = { { stationGroup = 41, station = 0, terminal = 1 },
		{ stationGroup = 42, station = 0, terminal = 0 } } } } })
	send(h, 664, "lines", "{  }")
	frames(h, FIRST)
	local u = answerText(h, 664) or ""
	for _, key in ipairs({ "vehicleIds", "vehicleCargo" }) do
		truthy(u:find('\\"' .. key .. '\\":%[%]') or u:find('"' .. key .. '":%[%]'), key .. " in " .. u)
	end
	send(h, 665, "stations", '{ name = "nothing like this" }')
	frames(h, 10)
	local v = answerText(h, 665) or ""
	truthy(v:find('\\"stations\\":%[%]') or v:find('"stations":%[%]'), v)
end)

test("line update: stops added keep the old stops' platforms; a rename alone; cargo as the cargo filter sets it", function()
	for _, via in ipairs({ "gui", "cmd" }) do
		local g = lineWithVehicles()
		send(g, 670, "line", string.format('{ action = "update", line = 21, stops = { 41, 42, 43 }, name = "[probe] Bus", via = %q }', via))
		frames(g, FIRST)
		local a, n = final(g, 670)
		eq(n, 1); eq(a.ok, true, via .. " " .. tostring(a.error))
		eq(a.line, 21); eq(#a.stops, 3, via); eq(a.stops[3].stationGroup, 43)
		eq(a.stops[1].terminal, 1, via .. ": Central keeps its platform")
		eq(a.name, "[probe] Bus", via); eq(a.before.name, "Bus 1"); eq(#a.before.stops, 2)
		eq(#sent(g, "setName"), 1, "the base's makeEntitySetNameCmd")
		send(g, 671, "line", string.format('{ action = "update", line = 21, name = "renamed", via = %q }', via))
		frames(g, 10)
		local b = final(g, 671)
		eq(b.ok, true, tostring(b.error)); eq(b.name, "renamed"); eq(#sent(g, "lineUpdate"), 1, "a rename alone sends no line")
		send(g, 672, "line", string.format('{ action = "update", line = 21, cargo = "grain", via = %q }', via))
		frames(g, 10)
		local c = final(g, 672)
		eq(c.ok, true, via .. " " .. tostring(c.error))
		eq(#c.loads, 1); eq(c.loads[1], "GRAIN", via); eq(c.customFilters, true)
		eq(#c.stops, 3, "the stops stay")
		eq(g.crashed, nil, via)
	end
end)

test("line update: an unknown line, someone else's, an unknown cargo and refusals answer once with an error", function()
	local g = lineWithVehicles({ renameFails = true })
	send(g, 680, "line", '{ action = "update", line = 999, name = "x" }')
	frames(g, FIRST)
	truthy(final(g, 680).error:find("no line 999"))
	g.lines[77] = { name = "theirs", stops = {} }
	-- 77 is a line, but not in getLinesForPlayer
	local real = api.engine.system.lineSystem.getLinesForPlayer
	api.engine.system.lineSystem.getLinesForPlayer = function() return { 21 } end
	send(g, 681, "line", '{ action = "update", line = 77, name = "x" }')
	frames(g, 10)
	api.engine.system.lineSystem.getLinesForPlayer = real
	g.lines[77] = nil
	truthy(final(g, 681).error:find("is not the company's"))
	send(g, 682, "line", '{ action = "update", line = 21, cargo = "milk" }')
	frames(g, 10)
	truthy(final(g, 682).error:find("no cargo type matches"))
	send(g, 683, "line", '{ action = "update", line = 21, name = "y" }')
	frames(g, 10)
	local a, n = final(g, 683)
	eq(n, 1); eq(a.ok, false); truthy(a.error:find("refused the name"), a.error)
end)

test("line delete: refused with vehicles unless sellVehicles, which sells them first as the line manager does", function()
	local g = lineWithVehicles()
	send(g, 690, "line", '{ action = "delete", line = 21 }')
	frames(g, FIRST)
	local a = final(g, 690)
	eq(a.ok, false); truthy(a.error:find("has 2 vehicles"), a.error)
	eq(#sent(g, "lineDestroy"), 0); truthy(g.lines[21])
	send(g, 691, "line", '{ action = "delete", line = 21, sellVehicles = true }')
	frames(g, 10)
	local b, n = final(g, 691)
	eq(n, 1); eq(b.ok, true, tostring(b.error)); eq(b.removed, true); eq(b.via, "cmd")
	eq(#b.soldVehicles, 2); eq(g.fleet[601], nil); eq(g.lines[21], nil)
	eq(b.before.name, "Bus 1")
	-- an empty line goes without the flag
	local g2 = lineWorld({ lines = { [22] = { name = "empty", stops = { { stationGroup = 41 }, { stationGroup = 42 } } } } })
	send(g2, 692, "line", '{ action = "delete", line = 22 }')
	frames(g2, FIRST)
	eq(final(g2, 692).ok, true); eq(g2.lines[22], nil)
end)

test("line via gui: line_util not loading is one error answer and no cmd fallback; no speed control is a timeout", function()
	local g = lineWorld({ noLineUtil = true })
	send(g, 700, "line", '{ action = "create", stops = { 41, 42 } }')
	frames(g, FIRST)
	local a, n = final(g, 700)
	eq(n, 1); eq(a.ok, false)
	truthy(a.error:find("could not load /gui/line_vehicle_mgmt/line_util.tl", 1, true), a.error)
	eq(#sent(g, "lineCreate"), 0)
	local g2 = lineWorld({ noSpeedControl = true })
	send(g2, 701, "line", '{ action = "create", stops = { 41, 42 } }')
	frames(g2, FIRST)
	frames(g2, 70, 1)
	local b, m = final(g2, 701)
	eq(m, 1); eq(b.ok, false); truthy(b.error:find("no word from the speed control", 1, true), b.error)
	eq(next(g2.lines), nil)
end)

test("line via gui: requests left by the last game are never run; the engine refusing is an error", function()
	local g = lineWorld()
	fake.guiSave.hummer_remote_probe.lines = { { id = 1, kind = "create", stops = { { stationGroup = 41 }, { stationGroup = 42 } } } }
	local exports = loadSpeedScript()
	g.speedControlOff = true
	frame(exports.SpeedControl, { gameCtx = {} })
	frame(exports.SpeedControl, { gameCtx = {} })
	eq(next(g.lines), nil, "the old request is not run")
	local g2 = lineWorld({ lineFails = true })
	send(g2, 702, "line", '{ action = "create", stops = { 41, 42 } }')
	frames(g2, FIRST)
	local a, n = final(g2, 702)
	eq(n, 1); eq(a.ok, false); truthy(a.error:find("refused the line"), a.error)
end)

test("line via gui: a report that does not come through still answers from the engine, with a note", function()
	local g = lineWorld({ foreignKeyFails = true })
	send(g, 703, "line", '{ action = "create", stops = { 41, 42 }, name = "[probe] r" }')
	frames(g, FIRST)
	local a, n = final(g, 703)
	eq(n, 1); eq(a.ok, true, tostring(a.error))
	truthy(a.line and g.lines[a.line], "found as the company's new line at those stops")
	eq(a.sentStops, nil); truthy(hasNote(a, "no report"))
	send(g, 704, "line", string.format('{ action = "update", line = %d, stops = { 42, 41, 43 } }', a.line))
	frames(g, 20)
	local b = final(g, 704)
	eq(b.ok, true, tostring(b.error)); eq(b.stops[3].stationGroup, 43)
end)

-- after review (2026-11-17)
test("line --cargo: a platform that cannot take the cargo is refused before sending (gui and cmd)", function()
	for _, via in ipairs({ "gui", "cmd" }) do
		local groups = lineWorld().groups
		groups[41].stations[1].kind = "passenger"
		local g = lineWorld({ stationGroups = groups })
		send(g, 730, "line", string.format('{ action = "create", stops = { 41, 42 }, cargo = "coal", via = %q }', via))
		frames(g, FIRST)
		local a, n = final(g, 730)
		eq(n, 1); eq(a.ok, false, via)
		truthy(tostring(a.error):find("takes no cargo", 1, true), tostring(a.error))
		eq(#sent(g, "lineCreate"), 0, via)
		send(g, 731, "line", string.format('{ action = "create", stops = { 41, 42 }, cargo = "passengers", via = %q }', via))
		frames(g, 10)
		eq(final(g, 731).ok, true, via .. ": passengers are fine there")
	end
end)

test("line --cargo: load only at the stops that give the cargo, so the destination unloads it (BUG 2026-11-19)", function()
	-- the base's cargo_util, faked: Central (411) has coal in an output stock, Central Market (431) takes it
	local CU = "::/gui/main/cargo_util.tl"
	local function withCargoUtil(outputs, f)
		-- outputs[station] = { [cargo] = "output" | "storage" }: storage counts only with skipStorage false
		package.loaded[CU] = { getInputOutputStocksForStation = function(station, skipStorage)
			local out = {}
			for c, kind in pairs(outputs[station] or {}) do
				if kind == "output" or (kind == "storage" and not skipStorage) then out[c] = true end
			end
			return {}, 0, out, 0
		end }
		local ok, err = pcall(f)
		package.loaded[CU] = nil
		assert(ok, err)
	end
	for _, via in ipairs({ "gui", "cmd" }) do
		withCargoUtil({ [411] = { [1] = "output" } }, function()
			local g = lineWorld()
			send(g, 760, "line", string.format('{ action = "create", stops = { 41, 43 }, cargo = "coal", via = %q }', via))
			frames(g, FIRST)
			local a = final(g, 760)
			eq(a.ok, true, via .. " " .. tostring(a.error))
			local stops = sent(g, "lineCreate")[1].line.stops
			eq(stops[1].stopConfig.load[2], true, via .. ": loaded where it is made")
			eq(stops[2].stopConfig.load[2], false, via .. ": not at the destination, so it is unloaded there")
			eq(#stops[2].stopConfig.load, 3, "still one entry per cargo type")
			eq(sent(g, "lineCreate")[1].line.customFilters, true)
		end)
		withCargoUtil({}, function()
			local g = lineWorld()
			send(g, 761, "line", string.format('{ action = "create", stops = { 41, 43 }, cargo = "coal", via = %q }', via))
			frames(g, FIRST)
			local a = final(g, 761)
			eq(a.ok, false, via)
			truthy(tostring(a.error):find("no stop gives", 1, true), tostring(a.error))
			eq(#sent(g, "lineCreate"), 0, via .. ": nothing sent")
		end)
	end
end)

test("line --cargo: a warehouse gives what it stores; passengers load everywhere; unreadable stops load, with a note", function()
	local CU = "::/gui/main/cargo_util.tl"
	local function fakeCU(outputs)
		package.loaded[CU] = { getInputOutputStocksForStation = function(station, skipStorage)
			local out = {}
			for c, kind in pairs(outputs[station] or {}) do
				if kind == "output" or (kind == "storage" and not skipStorage) then out[c] = true end
			end
			return {}, 0, out, 0
		end }
	end
	-- a warehouse (storage stock) at Central: it gives coal, as in the base's keepCargo (skipStorage false)
	fakeCU({ [411] = { [1] = "storage" } })
	local g = lineWorld()
	send(g, 770, "line", '{ action = "create", stops = { 41, 43 }, cargo = "coal", via = "gui" }')
	frames(g, FIRST)
	eq(final(g, 770).ok, true, tostring(final(g, 770).error))
	local stops = sent(g, "lineCreate")[1].line.stops
	eq(stops[1].stopConfig.load[2], true, "the warehouse loads"); eq(stops[2].stopConfig.load[2], false)
	-- passengers: every stop, whatever the stocks say
	fakeCU({})
	g = lineWorld()
	send(g, 771, "line", '{ action = "create", stops = { 41, 43 }, cargo = "passengers", via = "gui" }')
	frames(g, FIRST)
	eq(final(g, 771).ok, true, tostring(final(g, 771).error))
	stops = sent(g, "lineCreate")[1].line.stops
	eq(stops[1].stopConfig.load[1], true); eq(stops[2].stopConfig.load[1], true)
	-- no cargo_util at all (the cmd way's Lua state may lack it): every stop loads, as before, and the answer says so
	package.loaded[CU] = nil
	package.preload[CU] = function() error("not cached") end
	g = lineWorld()
	send(g, 772, "line", '{ action = "create", stops = { 41, 43 }, cargo = "coal", via = "cmd" }')
	frames(g, FIRST)
	local a = final(g, 772)
	eq(a.ok, true, tostring(a.error))
	stops = sent(g, "lineCreate")[1].line.stops
	eq(stops[1].stopConfig.load[2], true); eq(stops[2].stopConfig.load[2], true)
	truthy(hasNote(a, "could not be read"), "the fallback is in the notes")
	package.preload[CU] = nil
end)

test("line_configs.applyCargo: a stop that cannot be told loads; a platform that does not load gives nothing", function()
	local lc = require "hummer_remote_probe::/line_configs.lua"
	eq(lc.stopGives({ stationGroup = 41, station = 0 }, 1, nil), nil, "no cargo_util: cannot be told")
	local cu = { getInputOutputStocksForStation = function() return {}, 0, { [1] = true }, 0 end }
	eq(lc.stopGives({ stationGroup = 46, station = 0 }, 1, cu), nil, "no station: cannot be told")
	local boom = { getInputOutputStocksForStation = function() error("broken") end }
	eq(lc.stopGives({ stationGroup = 41, station = 0, terminal = 0 }, 1, boom), nil, "an error: cannot be told")
end)

test("line update via cmd: the engine assigns platforms only when a stop has none, as autoAssignTerminals", function()
	local g = lineWithVehicles({ reassign = true })
	send(g, 732, "line", '{ action = "update", line = 21, stops = { 42, 41 }, via = "cmd" }')
	frames(g, FIRST)
	local a = final(g, 732)
	eq(a.ok, true, tostring(a.error)); eq(g.assignCalls, nil, "a reorder asks nothing")
	eq(a.stops[2].terminal, 1, "Central keeps its platform")
	send(g, 733, "line", '{ action = "update", line = 21, stops = { 42, 41, 43 }, via = "cmd" }')
	frames(g, 10)
	local b = final(g, 733)
	eq(b.ok, true, tostring(b.error)); eq(g.assignCalls, 1)
	eq(b.stops[2].terminal, 0, "the engine may move a kept stop then, as in the base")
end)

test("line stops: the same station group twice in a row, or last and first, is refused", function()
	local g = lineWorld()
	for i, stops in ipairs({ "{ 41, 41, 42 }", "{ 41, 42, 41 }", '{ "Central", 411 }' }) do
		send(g, 740 + i, "line", string.format('{ action = "create", stops = %s, via = "cmd" }', stops))
		frames(g, i == 1 and FIRST or 10)
		local a = final(g, 740 + i)
		eq(a.ok, false, stops); truthy(tostring(a.error):find("neighbours", 1, true), tostring(a.error))
	end
	send(g, 745, "line", '{ action = "create", stops = { 41, 42, 41, 43 }, via = "cmd" }')
	frames(g, 10)
	eq(final(g, 745).ok, true, "a group may come back later in the round")
	eq(#sent(g, "lineCreate"), 1)
end)

test("line via gui without reports: two creates at the same stops each get their own line", function()
	local g = lineWorld({ foreignKeyFails = true, callbackFrames = 30 })
	send(g, 750, "line", '{ action = "create", stops = { 41, 42 } }')
	frames(g, FIRST)
	send(g, 751, "line", '{ action = "create", stops = { 41, 42 } }')
	frames(g, 120)
	local a, b = final(g, 750), final(g, 751)
	eq(a.ok, true, tostring(a.error)); eq(b.ok, true, tostring(b.error))
	truthy(a.line ~= b.line, "not the same line twice")
end)

test("a line made and a vehicle bought onto it: buy --line answers with the vehicle's id, lines counts it", function()
	local g = lineWorld()
	send(g, 710, "line", '{ action = "create", stops = { 41, 42 }, name = "[probe] run" }')
	frames(g, FIRST)
	local l = final(g, 710)
	eq(l.ok, true, tostring(l.error))
	send(g, 711, "buy", string.format('{ model = "bus_1900", depot = 301, line = %d }', l.line))
	frames(g, 20)
	local b = final(g, 711)
	eq(b.ok, true, tostring(b.error))
	eq(#b.vehicleIds, 1); eq(b.vehicleIds[1], b.vehicles[1].entity); eq(b.vehicles[1].line, l.line)
	send(g, 712, "lines", '{ name = "[probe]" }')
	frames(g, 10)
	local ls = final(g, 712)
	eq(ls.lines[1].vehicles, 1); eq(ls.lines[1].vehicleIds[1], b.vehicleIds[1])
end)

-- harbours: Port A (47) a station with a truck bay (terminal 0, ROAD) and two piers (1 and 2, WATER), the second
-- with a tag, transfer speeds and a vehicle edge; Port B (48) two piers; Port C (49) a truck bay and a pier. Line
-- 23 runs a ship between Port A's pier 1 and Port C's pier.
local function portWorld(extra)
	extra = extra or {}
	local w = {
		stationGroups = {
			[47] = { name = "Port A", stations = { { id = 471, terminals = 3, kind = "cargo", carriers = { "ROAD", "WATER" },
				terminalCarriers = { { "ROAD" }, { "WATER" }, { "WATER" } }, pos = { 0, 0 },
				terminalInfo = { [3] = { tag = 2003, cargoTransferSpeeds = { { length = 40, loadSpeedModifier = 1.5 } },
					transportModes = { [10] = true, [12] = true, [0] = false }, capacity = 50,
					vehicleEdges = { { edgeId = { entity = 900, index = 1 }, param = 0.5 } } },
					[2] = { vehicleEdges = { { edgeId = { entity = 900, index = 5 }, param = 0 } } } } } } },
			[48] = { name = "Port B", stations = { { id = 481, terminals = 2, kind = "cargo", carriers = { "WATER" }, pos = { 900, 0 },
				terminalInfo = { [1] = { tag = newproxy(false), cargoTransferSpeeds = newproxy(false) } } } } },
			[49] = { name = "Port C", stations = { { id = 491, terminals = 2, kind = "cargo", carriers = { "ROAD", "WATER" },
				terminalCarriers = { { "ROAD" }, { "WATER" } }, pos = { 1800, 0 } } } },
			[41] = { name = "Central", stations = { { id = 411, terminals = 2, passenger = true, pos = { 0, 500 } } } },
		},
		networks = { [900] = { edges = { { geometry = { x = 1, y = 2 } }, { geometry = { x = 10, y = 20 } } } } },
	}
	for k, v in pairs(extra) do w[k] = v end
	return vehicleGame(w)
end

test("core.lineArgs: terminals for every stop or none; load modes one per stop or one for all", function()
	local a = core.lineArgs({ action = "create", stops = { 47, 48 }, terminals = { { station = 0, terminal = 2 }, "0:1" },
		loadModes = "ANY" })
	eq(a.terminals[1].station, 0); eq(a.terminals[1].terminal, 2); eq(a.terminals[2].terminal, 1)
	eq(a.loadModeAll, 1); eq(a.loadModes, nil)
	a = core.lineArgs({ action = "create", stops = { 47, 48 }, terminals = { 2, "1" }, loadModes = { "available", "full_load_all" } })
	eq(a.terminals[1].station, 0, "a bare number is station 0's terminal"); eq(a.terminals[2].terminal, 1)
	eq(a.loadModes[1], 0); eq(a.loadModes[2], 2)
	eq(core.lineArgs({ action = "create", stops = { 47, 48 }, loadModes = { 0, 2 } }).loadModes[2], 2)
	eq(core.lineArgs({ action = "update", line = 23, loadModes = "all" }).loadModeAll, 2, "an update of the line's own stops")
	eq(#core.lineArgs({ action = "update", line = 23, terminals = { 1, 1 } }).terminals, 2)
	eq(core.lineArgs({ action = "create", stops = { 47, 48 } }).terminals, nil, "none given: none sent")
	for _, bad in ipairs({
		{ { action = "create", stops = { 47, 48 }, terminals = { 2 } }, "give a terminal for every stop (2 stops, 1 terminals)" },
		{ { action = "create", stops = { 47, 48 }, terminals = { 2, 1, 0 } }, "give a terminal for every stop" },
		{ { action = "create", stops = { 47, 48 }, terminals = { [1] = 2, [3] = 1 } }, "terminals must be a list" },
		{ { action = "create", stops = { 47, 48 }, terminals = {} }, "terminals must be a list" },
		{ { action = "create", stops = { 47, 48 }, terminals = newproxy(true) }, "terminals must be a list" },
		{ { action = "create", stops = { 47, 48 }, terminals = 2 }, "terminals must be a list" },
		{ { action = "create", stops = { 47, 48 }, terminals = { 2, -1 } }, "terminal 2 must be" },
		{ { action = "create", stops = { 47, 48 }, terminals = { 2, 1.5 } }, "terminal 2 must be" },
		{ { action = "create", stops = { 47, 48 }, terminals = { 2, "a:1" } }, "terminal 2 must be" },
		{ { action = "create", stops = { 47, 48 }, terminals = { 2, newproxy(true) } }, "terminal 2 must be" },
		{ { action = "create", stops = { 47, 48 }, terminals = { 2, { station = 0 } } }, "terminal 2 must be" },
		{ { action = "create", stops = { 47, 48 }, terminals = { 2, 0 / 0 } }, "terminal 2 must be" },
		{ { action = "create", stops = { 47, 48 }, loadModes = "legacy_unload_only" }, "must be available, any or all" },
		{ { action = "create", stops = { 47, 48 }, loadModes = 3 }, "must be available, any or all" },
		{ { action = "create", stops = { 47, 48 }, loadModes = "fast" }, "must be available, any or all" },
		{ { action = "create", stops = { 47, 48 }, loadModes = true }, "must be available, any or all" },
		{ { action = "create", stops = { 47, 48 }, loadModes = newproxy(true) }, "must be available, any or all" },
		{ { action = "create", stops = { 47, 48 }, loadModes = {} }, "loadModes must be one mode" },
		{ { action = "create", stops = { 47, 48 }, loadModes = { "any" } }, "one load mode for every stop" },
		{ { action = "create", stops = { 47, 48 }, loadModes = { "any", 7 } }, "load mode 2 must be" },
	}) do
		local ok, err = core.lineArgs(bad[1])
		eq(ok, nil, bad[2])
		truthy(tostring(err):find(bad[2], 1, true), tostring(err) .. " / " .. bad[2])
	end
	-- the requests the speed control takes: a malformed or short terminals / loadModes list drops the request whole
	local list = core.lineRequests({
		{ id = 1, kind = "create", stops = { { stationGroup = 47 }, { stationGroup = 48 } },
			terminals = { { station = 0, terminal = 2 }, { station = 0, terminal = 1 } }, loadModes = { 1, 2 }, carriers = { 4 } },
		{ id = 2, kind = "create", stops = { { stationGroup = 47 }, { stationGroup = 48 } }, terminals = { { station = 0, terminal = 2 } } },
		{ id = 3, kind = "create", stops = { { stationGroup = 47 }, { stationGroup = 48 } }, terminals = { { station = 0 }, { station = 0, terminal = 1 } } },
		{ id = 4, kind = "create", stops = { { stationGroup = 47 }, { stationGroup = 48 } }, loadModes = { 1, 3 } },
		{ id = 5, kind = "update", line = 23, loadModes = { 2, 2 } },
		{ id = 6, kind = "create", stops = { { stationGroup = 47 }, { stationGroup = 48 } }, terminals = newproxy(true) },
	})
	eq(#list, 2)
	eq(list[1].terminals[1].terminal, 2); eq(list[1].loadModes[2], 2); eq(list[1].carriers[1], 4)
	eq(list[2].id, 5); eq(list[2].loadModes[1], 2); eq(list[2].terminals, nil)
end)

test("line create --terminals: every stop at the platform given, no assignment asked; load modes set (gui and cmd)", function()
	for _, via in ipairs({ "gui", "cmd" }) do
		local g = portWorld()
		send(g, 730, "line", string.format('{ action = "create", stops = { 47, 48 }, terminals = { "0:2", "0:1" }, ' ..
			'loadModes = { "all", "available" }, via = %q }', via))
		frames(g, FIRST)
		local a, n = final(g, 730)
		eq(n, 1); eq(a.ok, true, via .. " " .. tostring(a.error))
		eq(a.stops[1].terminal, 2, via); eq(a.stops[2].terminal, 1, via)
		eq(a.stops[1].loadMode, 2, via); eq(a.stops[2].loadMode, 0, via)
		eq(a.sentStops[1].terminal, 2, via)
		eq(g.assignCalls, nil, via .. ": the engine's assignment is not asked, so it cannot move them")
		eq(g.lines[a.line].stops[1].loadMode, 2, via .. ": what the engine holds")
		eq(g.crashed, nil, via)
		-- the same without terminals: the engine assigns, as before
		send(g, 731, "line", string.format('{ action = "create", stops = { 47, 48 }, via = %q }', via))
		frames(g, 10)
		local b = final(g, 731)
		eq(b.ok, true, via .. " " .. tostring(b.error))
		truthy((g.assignCalls or 0) > 0, via .. ": assigned by the engine")
		eq(b.stops[1].terminal, 2, via .. ": the fake engine's pick (the last terminal)"); eq(b.stops[1].loadMode, 0, via)
	end
end)

test("line create --terminals: out of range, unreadable carriers and carriers that do not match are refused unsent", function()
	for _, via in ipairs({ "gui", "cmd" }) do
		local g = portWorld()
		local cases = {
			{ '{ "0:5", "0:1" }', "terminal 5 of station 471 (station group 47) does not exist (3 terminals" },
			{ '{ "1:0", "0:1" }', "station 1 of station group 47 does not exist (1 stations)" },
			{ '{ "0:2", "0:2" }', "terminal 2 of station 481 (station group 48) does not exist (2 terminals" },
			{ '{ "0:0", "0:1" }', "share no carrier (stop 1 0:0 ROAD; stop 2 0:1 WATER)" },
			{ '{ "0:2" }', "give a terminal for every stop" },
		}
		for i, c in ipairs(cases) do
			local id = 740 + i
			send(g, id, "line", string.format('{ action = "create", stops = { 47, 48 }, terminals = %s, via = %q }', c[1], via))
			frames(g, i == 1 and FIRST or 10)
			local a, n = final(g, id)
			eq(n, 1, c[2]); eq(a.ok, false, c[2])
			truthy(tostring(a.error):find(c[2], 1, true), via .. ": " .. tostring(a.error) .. " / " .. c[2])
		end
		eq(#sent(g, "lineCreate"), 0, via .. ": nothing sent")
		eq(g.crashed, nil, via .. ": never asked the engine about a platform that does not exist")
	end
	-- carriers that cannot be read: refused, since whether a ship can stop there is unknown
	local g = portWorld()
	local real = api.engine.system.stationGroupSystem.getCarriers
	api.engine.system.stationGroupSystem.getCarriers = function(gid, st, te)
		if st ~= nil and st >= 0 then error("no carriers here") end
		return real(gid, st, te)
	end
	send(g, 749, "line", '{ action = "create", stops = { 47, 48 }, terminals = { "0:2", "0:1" }, via = "cmd" }')
	frames(g, FIRST)
	local a = final(g, 749)
	api.engine.system.stationGroupSystem.getCarriers = real
	eq(a.ok, false); truthy(tostring(a.error):find("could not be read", 1, true), tostring(a.error))
	eq(#sent(g, "lineCreate"), 0)
end)

test("line_configs: the platforms are checked again where the line is built, and a stop it moves is not sent", function()
	local g = portWorld()
	local lc = require "hummer_remote_probe::/line_configs.lua"
	local stops = { { stationGroup = 47 }, { stationGroup = 48 } }
	-- out of range in cmdLine (the station changed after the guiUpdate script looked): an error, no engine call
	local ok, err = pcall(lc.cmdLine, { kind = "create", stops = stops, terminals = { { station = 0, terminal = 9 }, { station = 0, terminal = 1 } } })
	eq(ok, false); truthy(tostring(err):find("does not exist", 1, true), tostring(err))
	ok, err = pcall(lc.cmdLine, { kind = "create", stops = stops, terminals = { { station = 0, terminal = 0 }, { station = 0, terminal = 1 } } })
	eq(ok, false); truthy(tostring(err):find("share no carrier", 1, true), tostring(err))
	ok, err = pcall(lc.cmdLine, { kind = "create", stops = stops, terminals = { { station = 0, terminal = 2 } } })
	eq(ok, false); truthy(tostring(err):find("for every stop", 1, true), tostring(err))
	-- the vehicles' carrier (r.carriers) must be among those of the platforms
	ok, err = pcall(lc.cmdLine, { kind = "create", stops = stops, terminals = { { station = 0, terminal = 2 }, { station = 0, terminal = 1 } },
		carriers = { api.type.enum.Carrier.ROAD } })
	eq(ok, false); truthy(tostring(err):find("the line's vehicles run on ROAD", 1, true), tostring(err))
	local line = lc.cmdLine({ kind = "create", stops = stops, terminals = { { station = 0, terminal = 2 }, { station = 0, terminal = 1 } },
		loadModes = { 1, 1 } })
	eq(line.stops[1].terminal, 2); eq(line.stops[2].loadMode, 1)
	-- checkRequested: a stop the builder moved, or a load mode it dropped, does not go
	local r = { terminals = { { station = 0, terminal = 2 }, { station = 0, terminal = 1 } }, loadModes = { 1, 1 } }
	truthy(lc.checkRequested({ { stationGroup = 47, station = 0, terminal = 2, loadMode = 1 }, { stationGroup = 48, station = 0, terminal = 1, loadMode = 1 } }, r))
	ok, err = lc.checkRequested({ { stationGroup = 47, station = 0, terminal = 1, loadMode = 1 }, { stationGroup = 48, station = 0, terminal = 1, loadMode = 1 } }, r)
	eq(ok, nil); truthy(err:find("not 0:2 as asked", 1, true), err)
	ok, err = lc.checkRequested({ { stationGroup = 47, station = 0, terminal = 2, loadMode = 0 }, { stationGroup = 48, station = 0, terminal = 1, loadMode = 1 } }, r)
	eq(ok, nil); truthy(err:find("load mode 0, not 1", 1, true), err)
	truthy(lc.checkRequested({ { stationGroup = 47, station = 0, terminal = 2, loadMode = newproxy(true) },
		{ stationGroup = 48, station = 0, terminal = 1 } }, r), "a load mode that is no number cannot be compared")
	truthy(lc.checkRequested({ { stationGroup = 47, station = 0, terminal = 0 } }, {}), "nothing asked: nothing to hold")
	eq(lc.checkTerminals({}, {}), nil); eq(lc.checkTerminals(nil, nil), nil)
	eq(g.crashed, nil)
end)

test("line via gui: the platforms are checked before the base's line_util reads them (autoLoadConfig, getTerminal)", function()
	local g = portWorld()
	local lc = require "hummer_remote_probe::/line_configs.lua"
	local function perform(r)
		fake.inReact = true
		local report = {}
		local ok, err = pcall(lc.performGui, require, r, report)
		fake.inReact = false
		return ok, err, report
	end
	-- the port lost a pier after the guiUpdate script checked: refused before line_util reads past the end
	local ok, err = perform({ id = 1, kind = "create", stops = { { stationGroup = 47 }, { stationGroup = 48 } },
		terminals = { { station = 0, terminal = 9 }, { station = 0, terminal = 1 } } })
	eq(ok, false); truthy(tostring(err):find("terminal 9 of station 471", 1, true), tostring(err))
	eq(g.crashed, nil, "line_util never read it")
	ok, err = perform({ id = 2, kind = "create", stops = { { stationGroup = 47 }, { stationGroup = 48 } },
		terminals = { { station = 0, terminal = 2 }, { station = 0, terminal = 1 } }, carriers = { api.type.enum.Carrier.ROAD } })
	eq(ok, false); truthy(tostring(err):find("run on ROAD", 1, true), tostring(err))
	local report
	ok, err, report = perform({ id = 3, kind = "create", stops = { { stationGroup = 47 }, { stationGroup = 48 } },
		terminals = { { station = 0, terminal = 2 }, { station = 0, terminal = 1 } }, loadModes = { 2, 0 } })
	eq(ok, true, tostring(err)); eq(report.sentStops[1].terminal, 2)
	eq(#sent(g, "lineCreate"), 1, "only the good one"); eq(g.crashed, nil)
end)

test("line update --terminals: a line with vehicles whose first stop's carriers cannot be read is refused", function()
	local g = portWorld({ lines = { [23] = { name = "Ship 1", stops = { { stationGroup = 47, station = 0, terminal = 1 },
		{ stationGroup = 49, station = 0, terminal = 1 } } } }, fleet = { [601] = fleetOf(101, 5, 23) } })
	local real = api.engine.system.stationGroupSystem.getCarriers
	api.engine.system.stationGroupSystem.getCarriers = function(gid, st, te)
		if gid == 47 and st == 0 and te == 1 then error("unreadable") end
		return real(gid, st, te)
	end
	send(g, 755, "line", '{ action = "update", line = 23, terminals = { "0:2", "0:1" }, via = "cmd" }')
	frames(g, FIRST)
	local a = final(g, 755)
	api.engine.system.stationGroupSystem.getCarriers = real
	eq(a.ok, false); truthy(tostring(a.error):find("first stop could not be read", 1, true), tostring(a.error))
	eq(#sent(g, "lineUpdate"), 0)
end)

test("line update --terminals / --load-mode: the line's own stops, the vehicles' carrier held (gui and cmd)", function()
	for _, via in ipairs({ "gui", "cmd" }) do
		local ship = fleetOf(101, 5, 23)
		local g = portWorld({ lines = { [23] = { name = "Ship 1", stops = { { stationGroup = 47, station = 0, terminal = 1,
			waypoints = { { tag = 1 } } }, { stationGroup = 49, station = 0, terminal = 1 } } } }, fleet = { [601] = ship } })
		send(g, 750, "line", string.format('{ action = "update", line = 23, terminals = { "0:2", "0:1" }, loadModes = "any", via = %q }', via))
		frames(g, FIRST)
		local a, n = final(g, 750)
		eq(n, 1); eq(a.ok, true, via .. " " .. tostring(a.error))
		eq(a.stops[1].terminal, 2, via); eq(a.stops[1].loadMode, 1, via); eq(a.stops[2].loadMode, 1, via)
		eq(a.before.stops[1].terminal, 1)
		-- (the fake line_util drops waypoints, which the base keeps through its waypointMap: cmd only)
		if via == "cmd" then eq(#g.lines[23].stops[1].waypoints, 1, "an update of the line's own stops keeps its waypoints") end
		-- both truck bays share ROAD, but the line's ship runs on WATER
		send(g, 751, "line", string.format('{ action = "update", line = 23, terminals = { "0:0", "0:0" }, via = %q }', via))
		frames(g, 10)
		local b = final(g, 751)
		eq(b.ok, false); truthy(tostring(b.error):find("the line's vehicles run on WATER", 1, true), tostring(b.error))
		send(g, 752, "line", string.format('{ action = "update", line = 23, terminals = { "0:1" }, via = %q }', via))
		frames(g, 10)
		truthy(tostring(final(g, 752).error):find("give a terminal for every stop (2 stops, 1 terminals)", 1, true))
		send(g, 753, "line", string.format('{ action = "update", line = 23, loadModes = { "any" }, via = %q }', via))
		frames(g, 10)
		truthy(tostring(final(g, 753).error):find("one load mode for every stop", 1, true))
		eq(#sent(g, "lineUpdate"), 1, via .. ": only the good one sent")
		eq(g.crashed, nil, via)
	end
end)

test("stations: each platform with tag, position, load flags, transfer speeds and carriers; nil what cannot be read", function()
	local g = portWorld()
	send(g, 760, "stations", '{ name = "Port A" }')
	frames(g, FIRST)
	local a = final(g, 760)
	eq(a.ok, true, tostring(a.error))
	local p = a.stations[1].platforms
	eq(#p, 3)
	eq(p[1].station, 0); eq(p[1].terminal, 0); eq(p[1].stationEntity, 471); eq(p[1].carriers[1], "ROAD")
	eq(p[1].tag, 1); eq(p[1].position, nil, "no vehicle edge"); eq(p[1].cargoTransferSpeeds, nil, "none to read")
	eq(p[1].cargoLoad, true); eq(p[1].passengersLoad, false)
	eq(p[2].position, nil, "an edge index past the network's end is not read")
	eq(p[3].tag, 2003); eq(p[3].carriers[1], "WATER")
	eq(p[3].position.x, 10.5); eq(p[3].position.y, 20)
	eq(p[3].cargoTransferSpeeds[1].length, 40); eq(p[3].cargoTransferSpeeds[1].loadSpeedModifier, 1.5)
	eq(table.concat(p[3].transportModes, ","), "SHIP,SMALL_SHIP", "a large pier: only the modes that are on, by name")
	eq(p[3].capacity, 50); eq(p[1].transportModes, nil, "none to read"); eq(p[1].capacity, nil)
	send(g, 761, "stations", '{ name = "Central" }')
	frames(g, 10)
	local c = final(g, 761).stations[1].platforms
	eq(#c, 2); eq(c[1].cargoLoad, nil, "flags the engine does not give are nil"); eq(c[2].terminal, 1)
	send(g, 762, "stations", '{ name = "Port B" }')
	frames(g, 10)
	local b = final(g, 762).stations[1].platforms
	eq(b[1].tag, nil, "a tag that is no number"); eq(b[1].cargoTransferSpeeds, nil, "a value without a length")
	eq(b[2].cargoTransferSpeeds, nil); eq(b[2].tag, 2)
	eq(g.crashed, nil)
end)

test("line commands are refused in the main menu", function()
	local g = newGame({ saves = SAVES, menu = true })
	frames(g, 2)
	send(g, 720, "line", '{ action = "create", stops = { 41, 42 } }')
	frames(g, FIRST)
	truthy(final(g, 720).error:find("needs a running game"))
end)

---------------------------------------------------------------------------------------------------------------------
-- connect: a track or road between two ends through Track Connector (tests/fake_tc.lua stands in for it)

local fakeTc = dofile(root .. "/tests/fake_tc.lua")
local connectMod = require "hummer_remote_probe::/remote_connect.lua"

-- Track ends 101 (at 0,0, facing +x) and 103 (at 1000,0, facing -x); a junction node 110 (three pieces); a station
-- group 42 "Harbour" whose construction 301 has a platform track 203 with free ends 105 and 106; a town building
-- 401 and a road 204 (nodes 107-108) across the straight line at x = 500; a road dead end 121.
local function connectWorld(tcOpts, gameOpts)
	tcOpts = tcOpts or {}
	local w = { strict = true,
		nodes = { [100] = { -100, 0, 10 }, [101] = { 0, 0, 10 }, [103] = { 1000, 0, 20 }, [104] = { 1100, 0, 20 },
			[105] = { 1000, 500, 20 }, [106] = { 1100, 500, 20 }, [107] = { 500, -200, 0 }, [108] = { 500, 200, 0 },
			[110] = { -300, 0, 10 }, [111] = { -400, 0, 10 }, [112] = { -300, 100, 10 }, [120] = { 0, 900, 5 }, [121] = { 100, 900, 5 } },
		edges = { [201] = { node0 = 100, node1 = 101 }, [202] = { node0 = 104, node1 = 103 }, [203] = { node0 = 105, node1 = 106 },
			[204] = { node0 = 107, node1 = 108, road = true }, [205] = { node0 = 110, node1 = 100 }, [206] = { node0 = 111, node1 = 110 },
			[207] = { node0 = 112, node1 = 110 }, [208] = { node0 = 120, node1 = 121, road = true, template = fakeTc.TOWN } },
		constructions = { [301] = { box = { 990, 490, 1110, 510 }, stations = { 421 }, frozenEdges = { 203 } } },
		townBuildings = { [401] = { box = { 480, -20, 520, 20 } } },
		stationConstruction = { [421] = 301 },
	}
	for k, v in pairs(tcOpts) do w[k] = v end
	gameOpts = gameOpts or {}
	gameOpts.saves = gameOpts.saves or SAVES
	gameOpts.stationGroups = gameOpts.stationGroups or {
		[42] = { name = "Harbour", stations = { { id = 421, terminals = 2, carriers = { "RAIL" }, pos = { 1050, 500 } } } },
		[43] = { name = "Harbour Goods", stations = { { id = 431, terminals = 1, carriers = { "RAIL" }, pos = { 3000, 3000 } } } } }
	local g = newGame(gameOpts)
	fakeTc.install(g, w)
	frames(g, 2)
	return g
end

-- runs a connect to its final answer (dt: seconds per frame)
local function connectRun(g, id, argsLua, n, dt)
	send(g, id, "connect", argsLua)
	frames(g, n or FIRST + 100, dt)
	return final(g, id)
end

test("core.connectArgs: defaults, ids and names, and every bad value refused with a reason", function()
	local a = core.connectArgs({ from = 101, to = " Harbour " })
	eq(a.from, 101); eq(a.to, "Harbour"); eq(a.road, false); eq(a.track, "standard"); eq(a.build, false)
	eq(a.bridges, true); eq(a.tunnels, true); eq(a.timeout, 120); eq(a.slope, nil); eq(a.radius, nil)
	eq(core.connectArgs({ from = "101", to = 103, slope = 2.5 }).slope, 0.025, "slope in percent, kept as a ratio")
	eq(core.connectArgs({ from = 1, to = 2, road = true }).template, nil)
	eq(core.connectArgs({ from = 1, to = 2, road = true, template = fakeTc.TOWN }).template, fakeTc.TOWN)
	eq(core.connectArgs({ from = 1, to = 2, build = true, clear = true }).clear, true)
	eq(core.connectArgs({ from = 1, to = 2, bridges = false }).bridges, false)
	for _, bad in ipairs({
		{ nil, "from must be" },
		{ { to = 2 }, "got nothing" },
		{ { from = 1 }, "to must be" },
		{ { from = "", to = 2 }, "from is empty" },
		{ { from = "  ", to = 2 }, "from is empty" },
		{ { from = newproxy(true), to = 2 }, "got a userdata" },
		{ { from = 1.5, to = 2 }, "from must be an entity id" },
		{ { from = 0 / 0, to = 2 }, "from must be an entity id" },
		{ { from = -1, to = 2 }, "from must be an entity id" },
		{ { from = 0, to = 2 }, "from must be an entity id" },
		{ { from = 2 ^ 31, to = 2 }, "from must be an entity id" },
		{ { from = 1, to = "99999999999" }, "to must be an entity id" },
		{ { from = { 1 }, to = 2 }, "got a table" },
		{ { from = 5, to = "5" }, "the same" },
		{ { from = 1, to = 2, track = "maglev" }, "track must be" },
		{ { from = 1, to = 2, track = newproxy(true) }, "track must be" },
		{ { from = 1, to = 2, template = fakeTc.TOWN }, "template goes with road" },
		{ { from = 1, to = 2, road = true, track = "standard" }, "track goes with tracks" },
		{ { from = 1, to = 2, road = true, electric = true }, "electric goes with tracks" },
		{ { from = 1, to = 2, road = true, template = "town_medium" }, "full resource name" },
		{ { from = 1, to = 2, road = "yes" }, "road must be true or false" },
		{ { from = 1, to = 2, build = 1 }, "build must be true or false" },
		{ { from = 1, to = 2, slope = 0 }, "slope (%) must be" },
		{ { from = 1, to = 2, slope = 16 }, "slope (%) must be" },
		{ { from = 1, to = 2, slope = "steep" }, "slope (%) must be" },
		{ { from = 1, to = 2, slope = 0 / 0 }, "slope (%) must be" },
		{ { from = 1, to = 2, slope = newproxy(true) }, "slope (%) must be" },
		{ { from = 1, to = 2, radius = 10 }, "radius (m) must be" },
		{ { from = 1, to = 2, clear = true }, "goes with build" },
		{ { from = 1, to = 2, timeout = 5 }, "timeout (s) must be" },
		{ { from = 1, to = 2, timeout = 4000 }, "timeout (s) must be" },
	}) do
		local ok, err = core.connectArgs(bad[1])
		eq(ok, nil, bad[2])
		truthy(tostring(err):find(bad[2], 1, true), tostring(err) .. " / " .. bad[2])
	end
	truthy(core.COMMANDS.connect and core.CHANGES_GAME.connect, "a command that changes the game")
	eq(core.MENU_COMMANDS.connect, nil, "not in the main menu")
end)

test("connect.routeOf / routeProblem / routeSummary: one entry per point, kinds, bad numbers and loose ends", function()
	local pts = { { x = 0, y = 0, z = 10, tx = 1, ty = 0, slope = 0.01, s = 0, edgeType = "normal" },
		{ x = 100, y = 0, z = 11, tx = 1, ty = 0, slope = 0.01, s = 100, edgeType = "bridge" },
		{ x = 200, y = 0, z = 12, tx = 1, ty = 0, slope = 0.01, s = 200, edgeType = "tunnel" },
		{ x = 300, y = 0, z = 13, tx = 1, ty = 0, s = 300, edgeType = "normal" } }
	local r = connectMod.routeOf(pts, 101, 103, { length = 300, straight = 299, bridge = 100, tunnel = 100, steepest = 0.01 })
	eq(r.fromNode, 101); eq(r.toNode, 103); eq(#r.x, 4); eq(r.kind[1], 0); eq(r.kind[2], 1); eq(r.kind[3], 2)
	eq(r.slope[4], 0, "a missing slope is 0, not nil"); eq(r.level[3], 0); eq(r.levelCount, 0); eq(r.length, 300)
	eq(r.maxCut, 0, "missing stats are 0")
	eq(connectMod.routeOf(pts, 1, 2, nil).length, 300, "without stats: the last point's distance")
	local a, b = { x = 0, y = 0 }, { x = 300, y = 0 }
	eq(connectMod.routeProblem(r, a, b), nil)
	truthy(connectMod.routeProblem(r, a, { x = 400, y = 0 }):find("ends 100.0 m from the target"))
	local bad = connectMod.routeOf({ pts[1], pts[2] }, 1, 2)
	bad.z[2] = 0 / 0
	truthy(connectMod.routeProblem(bad, a, { x = 100, y = 0 }):find("bad number"))
	local zero = connectMod.routeOf({ pts[1], pts[1] }, 1, 2)
	truthy(connectMod.routeProblem(zero, a, a):find("no length"))
	truthy(connectMod.routeProblem(connectMod.routeOf({ pts[1] }, 1, 2), a, a):find("fewer than 2"))
	local sum = connectMod.routeSummary(r)
	eq(sum.points, 4); eq(sum.pieces, 3); eq(sum.pieceKinds.bridge, 1); eq(sum.pieceKinds.tunnel, 1); eq(sum.steepestPercent, 1)
end)

test("connect dry run: events in Track Connector's order, its verdict and cost, nothing built", function()
	local g = connectWorld({ planSteps = 120 })
	local before = g.balance
	send(g, 800, "connect", "{ from = 101, to = 103 }")
	frames(g, FIRST + 200)
	local a, n = final(g, 800)
	eq(n, 1, "one final answer")
	eq(a.ok, true, tostring(a.error)); eq(a.buildable, true); eq(a.dryRun, true); eq(a.mode, "track")
	eq(table.concat(g.tc.events, ","), "tc_settings,tc_setFromEnd,tc_setToEnd,tc_route,tc_estimate")
	eq(a.from.node, 101); eq(a.to.node, 103); eq(a.template, fakeTc.STANDARD)
	eq(a.estimate.cost, 1000 * a.route.points); eq(a.preview.ok, true); eq(a.route.length, 1000)
	eq(a.settings.maxSlope, 0.025, "Track Connector's track defaults"); eq(a.settings.minRadius, 300)
	eq(a.settings.track, fakeTc.STANDARD); eq(a.settings.avoidBuildings, true)
	eq(a.tc.mod, "ethan_track_connector"); eq(a.tc.writtenFor.revision, 3); eq(a.tc.gameScript, 777)
	eq(g.tc.askedScript, "ethan_track_connector::/track_connector/track_connector.gs")
	eq(g.balance, before, "a dry run costs nothing"); eq(g.tc.built, nil)
	truthy(answerText(g, 800, "p1"), "a progress answer while planning")
	truthy(decode(answerText(g, 800, "p1")).running)
	local plan = g.tc.plans[1]
	eq(plan.start.x, 0); eq(plan.goal.x, 1000)
	truthy(math.abs(plan.start.heading) < 1e-9, "leaves the end along its outward direction (+x)")
	truthy(math.abs(math.abs(plan.goal.heading)) < 1e-9, "arrives against the target's outward direction (-x)")
	eq(plan.S.levelCrossings, false); eq(plan.S.tracks, 1); eq(plan.S.allowBridges, true)
	truthy(plan.budget >= 0.006 and plan.budget <= 0.03, "a frame's slice as Track Connector's own tool takes")
	truthy(plan.steps >= 120, "spread over frames")
	eq(g.tc.simplified, 1)
	eq(g.crashed, nil)
end)

test("connect: the route Track Connector gets has its Route shape (single track, no level crossings)", function()
	local g = connectWorld({ kinds = function(i, n) return i == 10 and "bridge" or (i == 12 and "tunnel" or "normal") end })
	local a = connectRun(g, 801, "{ from = 101, to = 103 }")
	eq(a.ok, true, tostring(a.error))
	local r = g.tc.state.route
	eq(r.fromNode, 101); eq(r.toNode, 103)
	local n = #r.x
	for _, k in ipairs({ "y", "z", "tx", "ty", "slope", "kind", "level" }) do eq(#r[k], n, k .. " has one entry per point") end
	eq(r.x[1], 0); eq(r.x[n], 1000); eq(r.z[1], 10); eq(r.z[n], 20)
	eq(r.kind[10], 1); eq(r.kind[12], 2); eq(r.kind[1], 0); eq(r.levelCount, 0); eq(r.level[5], 0)
	eq(r.length, 1000); eq(r.twinOffset, nil)
	eq(a.route.pieceKinds.bridge, 1); eq(a.route.pieceKinds.tunnel, 1)
	eq(g.tc.state.estimates.remote_probe_801.n, n, "the estimate is about this route")
end)

test("connect world: heights, water, buildings and roads as the planner sees them; the ends' own pieces left out", function()
	local g = connectWorld({ height = function(x, y) return x < -2000 and -5 or 10 + x / 100 end,
		water = function(x, y) return x < -2000 end, waterLevel = 0, planSteps = 1000 })
	send(g, 802, "connect", "{ from = 101, to = 'Harbour' }")
	frames(g, FIRST + 70)
	local w = g.tc.plans[1].world
	truthy(w, "planning started")
	eq(w.height(300, 0), 13); eq(w.ground(300, 0), 13)
	eq(w.water(300, 0), false); eq(w.water(-3000, 0), true)
	eq(w.height(-3000, 0), 6.5, "over water: the surface plus room for a bridge"); eq(w.ground(-3000, 0), -5)
	eq(w.blocked(500, 0), true, "the town building"); eq(w.blocked(300, 300), false)
	eq(w.blocked(5000, 0), true, "outside the map")
	eq(w.crossing(500, 150), true, "the road"); eq(w.crossing(300, 300), false)
	eq(w.crossing(-200, 0), true, "the piece behind the end's own one (205) is a crossing")
	eq(w.crossing(-50, 0), false, "the end's own piece (201) is none")
	eq(w.crossing(-2, 0), false, "the end's own piece right at the end is none")
	eq(w.crossing(1050, 500), false, "the target station's platform track is excluded")
	eq(w.blocked(1050, 500), true, "but its construction still blocks")
	eq(w.blocked(1000, 500), false, "except at the end node"); eq(w.blocked(992, 500), false, "and out of the end it points from")
	eq(w.blocked(1000, 489), true, "beside the end, inside the station's room, it blocks")
	truthy(w.bounds and w.bounds[1] == -3920, "bounds a little inside the map")
	eq(g.crashed, nil)
end)

test("connect ends: node, station group by name, station, construction; junctions, roads and non-nodes refused", function()
	local g = connectWorld()
	local a = connectRun(g, 803, "{ from = 101, to = 'harb' }")
	truthy(a.error:find("2 matches"), tostring(a.error))
	a = connectRun(g, 804, "{ from = 101, to = 'Harbour' }")
	eq(a.ok, true, tostring(a.error)); eq(a.to.kind, "station group"); eq(a.to.entity, 42); eq(a.to.node, 105, "the platform end that faces the start")
	eq(#a.to.freeEnds, 2)
	for i, case in ipairs({
		{ "{ from = 101, to = 421 }", true, "station" },
		{ "{ from = 101, to = 301 }", true, "construction" },
		{ "{ from = 110, to = 103 }", "node 110 is not a free track end (3 track" },
		{ "{ from = 101, to = 121 }", "node 121 is not a free track end (0 track and 1 road" },
		{ "{ from = 201, to = 103 }", "201 is no node, station" },
		{ "{ from = 101, to = 99999 }", "99999 is no node" },
		{ "{ from = 101, to = 'Nowhere' }", 'no match for "Nowhere"' },
		{ "{ from = 101, to = 43 }", "has no free platform track end" },
		{ "{ from = 101, to = 101 }", "the same" },
	}) do
		local r = connectRun(g, 805 + i, case[1], 120)
		if case[2] == true then
			eq(r.ok, true, case[1] .. ": " .. tostring(r.error)); eq(r.to.kind, case[3])
		else
			eq(r.ok, false, case[1]); truthy(tostring(r.error):find(case[2], 1, true), case[1] .. ": " .. tostring(r.error))
		end
	end
	eq(g.crashed, nil, "no street-system call on an entity that is no node")
end)

test("connect road: road ends, the start road's own type and lanes, the road's slope limit", function()
	local g = connectWorld({ maxSlopeBuild = 0.05 })
	g.tc.nodes[122], g.tc.nodes[123] = { 900, 900, 5 }, { 1000, 900, 5 }
	g.tc.edges[209] = { node0 = 123, node1 = 122, road = true }
	local a = connectRun(g, 820, "{ from = 121, to = 122, road = true }")
	eq(a.ok, true, tostring(a.error)); eq(a.mode, "road")
	eq(a.template, fakeTc.TOWN, "the same as the start road"); eq(a.settings.laneFrom, 208, "its lanes copied")
	eq(a.settings.maxSlope, 0.05, "6 % lowered to what the road type allows"); eq(a.settings.minRadius, 100)
	truthy(a.notes and a.notes[1]:find("planned at its 5.0%", 1, true), "said so")
	a = connectRun(g, 821, string.format("{ from = 121, to = 122, road = true, template = %q }", fakeTc.COUNTRY))
	eq(a.template, fakeTc.COUNTRY); eq(a.settings.laneFrom, nil)
	a = connectRun(g, 822, string.format("{ from = 121, to = 122, road = true, template = %q }", fakeTc.STANDARD))
	truthy(a.error:find("no road type"), tostring(a.error))
	a = connectRun(g, 823, "{ from = 101, to = 122, road = true }")
	truthy(a.error:find("not a free road end"), tostring(a.error))
	a = connectRun(g, 824, string.format("{ from = 101, to = 103, track = %q }", fakeTc.COUNTRY))
	truthy(a.error:find("road type"), tostring(a.error))
end)

test("connect: a route the game would refuse is not ok and says why; build sends nothing unless clear can help", function()
	local g = connectWorld({ blocked = true, clearable = true })
	local a = connectRun(g, 830, "{ from = 101, to = 103 }")
	eq(a.ok, false); eq(a.buildable, false)
	truthy(a.error:find("houses in the way", 1, true) and a.error:find("add clear"), a.error)
	eq(a.estimate.clear, true); eq(a.estimate.clearCount, 2); eq(a.preview.ok, false)
	a = connectRun(g, 831, "{ from = 101, to = 103, build = true }")
	eq(a.ok, false); truthy(a.error:find("not built"), a.error)
	for _, e in ipairs(g.tc.events) do truthy(e ~= "tc_build", "no build sent") end
	local before = g.balance
	a = connectRun(g, 832, "{ from = 101, to = 103, build = true, clear = true }")
	eq(a.ok, true, tostring(a.error)); eq(g.tc.events[#g.tc.events], "tc_build")
	eq(g.commands[#g.commands].param.clear, true)
	truthy(g.balance < before)
	g = connectWorld({ blocked = true })
	a = connectRun(g, 833, "{ from = 101, to = 103, build = true, clear = true }")
	truthy(a.error:find("not built"), a.error)
end)

test("connect --build: built, new pieces and nodes, cost measured by the balance (a mod's extra charge too)", function()
	local g = connectWorld({ extraCost = 777 })
	g.balance = 500000
	local a = connectRun(g, 840, "{ from = 101, to = 103, build = true }")
	eq(a.ok, true, tostring(a.error)); eq(a.dryRun, false)
	local b = a.build
	eq(b.tc.ok, true); eq(b.balanceBefore, 500000)
	eq(b.spent, a.estimate.cost + 777); eq(b.beyondEstimate, 777, "what another mod charged after the build")
	eq(#b.newEdges, a.route.pieces); eq(#b.newNodes, a.route.points - 2)
	eq(b.joined.from, true); eq(b.joined.to, true)
	truthy(b.warning, "the game kept running meanwhile (not paused in this test)")
	eq(g.tc.state.builds, 1)
end)

test("connect --build: not enough money, refused by Track Connector, with its reason", function()
	local g = connectWorld()
	g.balance = 50
	local a = connectRun(g, 841, "{ from = 101, to = 103, build = true }")
	eq(a.ok, false); truthy(a.error:find("balance 50 below cost", 1, true), a.error)
	eq(a.build.spent, 0); eq(#a.build.newEdges, 0); eq(g.balance, 50)
end)

test("connect --build: an outcome Track Connector's state never got is told by the pieces that are there", function()
	local g = connectWorld({ lateCallback = true })
	local a = connectRun(g, 842, "{ from = 101, to = 103, build = true }", FIRST + 250)
	eq(a.ok, true, tostring(a.error)); truthy(a.notes[#a.notes]:find("nothing happened"))
	g = connectWorld({ buildFails = true })
	a = connectRun(g, 843, "{ from = 101, to = 103, build = true }")
	eq(a.ok, false); truthy(a.error:find("the engine said no", 1, true), a.error)
end)

test("connect without Track Connector: its modules missing, its game script not running, another release", function()
	local g = connectWorld({ noTc = true })
	local a = connectRun(g, 850, "{ from = 101, to = 103 }")
	truthy(a.error:find("Track Connector %(ethan_track_connector%) is not available") and a.error:find("Enable the mod"), a.error)
	g = connectWorld({ noScript = true })
	a = connectRun(g, 851, "{ from = 101, to = 103 }")
	truthy(a.error:find("game script is not running"), a.error)
	g = connectWorld({ oldTc = true })
	a = connectRun(g, 852, "{ from = 101, to = 103 }")
	truthy(a.error:find("lack newJob"), a.error)
	eq(#g.tc.events, 0, "nothing sent")
end)

test("connect: planner timeouts, failures and an answer that never comes each end in one error answer", function()
	local g = connectWorld({ planForever = true })
	local a = connectRun(g, 860, "{ from = 101, to = 103, timeout = 10 }", 200, 0.1)
	eq(a.ok, false); truthy(a.error:find("timed out after 10 s while planning"), a.error)
	eq(#g.tc.events, 0)
	-- the next connect may go once the first ended
	g.tc.opts.planForever = false
	a = connectRun(g, 861, "{ from = 101, to = 103 }")
	eq(a.ok, true, tostring(a.error))
	g = connectWorld({ noRoute = true })
	a = connectRun(g, 862, "{ from = 101, to = 103 }")
	truthy(a.error:find("^no route: fake planner: gave up"), a.error); truthy(a.plan.searchSteps == nil)
	g = connectWorld({ planError = true })
	a = connectRun(g, 863, "{ from = 101, to = 103 }")
	truthy(a.error:find("the planner failed: .*boom"), a.error)
	g = connectWorld({ tcSilent = true })
	local _, n
	a, n = connectRun(g, 864, "{ from = 101, to = 103 }", 450, 0.1)
	eq(n, 1); truthy(a.error:find("did not answer in 30 s"), a.error); eq(a.route.length, 1000)
	g = connectWorld({ refuseEvents = true })
	a = connectRun(g, 865, "{ from = 101, to = 103 }")
	truthy(a.error:find("refused the event command"), a.error)
end)

test("connect: one at a time; a player using Track Connector meanwhile ends the command instead of a wrong answer", function()
	local g = connectWorld({ planSteps = 200 })
	send(g, 870, "connect", "{ from = 101, to = 103 }")
	frames(g, FIRST)
	send(g, 871, "connect", "{ from = 101, to = 'Harbour' }")
	frames(g, 20)
	local b = final(g, 871)
	truthy(b.error:find("connect 870 is still running"), tostring(b.error))
	frames(g, 250)
	eq(final(g, 870).ok, true)
	eq(#g.tc.plans, 1, "the second never planned")
	g = connectWorld({ stealAfter = "tc_route" })
	local a = connectRun(g, 872, "{ from = 101, to = 103, build = true }")
	truthy(a.error:find("someone used its tool"), a.error)
	for _, e in ipairs(g.tc.events) do truthy(e ~= "tc_build", "no build sent") end
end)

test("connect: an end that goes while the route is planned is caught before anything reaches the game", function()
	local g = connectWorld({ planSteps = 30 })
	send(g, 880, "connect", "{ from = 101, to = 103 }")
	frames(g, FIRST)
	-- the player builds on the target: a second piece at node 103
	g.tc.nodes[130] = { 1000, 100, 20 }
	g.tc.edges[230] = { node0 = 103, node1 = 130 }
	frames(g, 120)
	local a = final(g, 880)
	truthy(a.error:find("node 103 is no longer a free end"), tostring(a.error))
	eq(#g.tc.events, 0); eq(g.crashed, nil)
end)

test("connect: a state that is not a table, and a planner route with a bad number, are errors, not crashes", function()
	local g = connectWorld()
	local real = api.engine.getComponent
	api.engine.getComponent = function(e, k)
		if k == "GAME_SCRIPT" then return { state = newproxy(true) } end
		return real(e, k)
	end
	local a = connectRun(g, 890, "{ from = 101, to = 103 }", 450, 0.1)
	truthy(a.error:find("did not answer"), a.error)
	api.engine.getComponent = real
	g = connectWorld({ kinds = function() return "normal" end })
	local simplify = g.tc.planner.simplify
	g.tc.planner.simplify = function(r) local out = simplify(r); out[3].z = 0 / 0; return out end
	a = connectRun(g, 891, "{ from = 101, to = 103 }")
	truthy(a.error:find("cannot go to the game: route point 3 has a bad number"), a.error)
	eq(#g.tc.events, 0)
end)

test("connect track types: a short name the game lacks is refused, not quietly built as standard track", function()
	local g = connectWorld()
	local cases = {
		{ "track = 'high_speed'", "::/infrastructure/track/high_speed/high_speed.street_template" },
		{ "electric = true", "::/infrastructure/track/standard/standard_catenary.street_template" },
		{ "track = 'simple'", "no simple track type" },
		{ "track = 'high_speed', electric = true", "no high_speed electric track type" },
		{ string.format("track = %q, electric = true", fakeTc.STANDARD), "electric goes with the short track names" },
		{ "track = '::/infrastructure/track/maglev/maglev.street_template'", "no track template" },
	}
	for i, c in ipairs(cases) do
		local a = connectRun(g, 900 + i, "{ from = 101, to = 103, " .. c[1] .. " }")
		if c[2]:sub(1, 3) == "::/" then
			eq(a.ok, true, c[1] .. ": " .. tostring(a.error)); eq(a.template, c[2]); eq(a.settings.track, c[2])
		else
			truthy(tostring(a.error):find(c[2], 1, true), c[1] .. ": " .. tostring(a.error))
		end
	end
end)

test("connect road: a start road whose type cannot be read is built as the default road, and said so", function()
	local g = connectWorld()
	g.tc.nodes[122], g.tc.nodes[123] = { 900, 900, 5 }, { 1000, 900, 5 }
	g.tc.edges[209] = { node0 = 123, node1 = 122, road = true }
	g.tc.edges[208].template = nil
	local a = connectRun(g, 910, "{ from = 121, to = 122, road = true }")
	eq(a.ok, true, tostring(a.error)); eq(a.template, fakeTc.COUNTRY); eq(a.settings.laneFrom, nil)
	truthy(a.notes and a.notes[1]:find("could not be read"), "said so")
end)

test("connect map: the blocks along the way are read a few per frame before planning, others when asked", function()
	local g = connectWorld({ planSteps = 1000 })
	send(g, 911, "connect", "{ from = 101, to = 103 }")
	frames(g, FIRST + 70)
	eq(#g.tc.plans, 1, "planning started")
	truthy(g.tc.plans[1].frameAtStart > 3, "after some frames")
	local w = g.tc.plans[1].world
	local before = g.tc.octreeCalls
	eq(w.blocked(3000, 3000), false)
	eq(g.tc.octreeCalls, before + 1, "a block outside the band is read when asked")
	w.blocked(3010, 3010)
	eq(g.tc.octreeCalls, before + 1, "and only once")
	frames(g, 1100)
	local a = final(g, 911)
	eq(a.ok, true, tostring(a.error))
	local plan = g.tc.plans[1]
	truthy(plan.octreeAtStart >= a.plan.map.preload, "every block along the way read before the planner's first step")
	truthy(a.plan.map.preload > 6 * 3, "more blocks than one frame reads: spread over frames")
	truthy(a.plan.map.preload > 20 and a.plan.map.blocks >= a.plan.map.preload, tostring(a.plan.map.preload))
	truthy(a.plan.mapSeconds ~= nil)
end)

test("connect --build: a failure whose text is still empty says the short outcome, not nothing", function()
	local g = connectWorld({ buildFails = "quiet" })
	local a = connectRun(g, 912, "{ from = 101, to = 103, build = true }")
	eq(a.ok, false); truthy(a.error:find("did not build it: [fake] build refused", 1, true), a.error)
end)

test("connect: a time-out in each phase (map, the game script's check, the build) is one error naming the phase", function()
	local g = connectWorld()
	package.loaded["hummer_remote_probe::/remote_connect.lua"].TUNE.blocksPerFrame = 0
	local a, n = connectRun(g, 920, "{ from = 101, to = 103, timeout = 10 }", 200, 0.1)
	eq(n, 1); truthy(a.error:find("timed out after 10 s while mapping"), a.error); eq(#g.tc.plans, 0)
	package.loaded["hummer_remote_probe::/remote_connect.lua"].TUNE.blocksPerFrame = 6
	g = connectWorld({ tcSilent = true })
	a, n = connectRun(g, 921, "{ from = 101, to = 103, timeout = 10 }", 200, 0.1)
	eq(n, 1); truthy(a.error:find("timed out after 10 s while checking"), a.error); eq(a.route.points, 21)
	g = connectWorld({ dropBuild = true })
	a, n = connectRun(g, 922, "{ from = 101, to = 103, build = true, timeout = 10 }", 200, 0.1)
	eq(n, 1); truthy(a.error:find("timed out after 10 s while building") and a.error:find("may still happen"), a.error)
end)

test("connect map: cells cover every block to its edge (no gap at the east and north 2 m)", function()
	local g = connectWorld({ townBuildings = { [401] = { box = { 197, 50, 199.6, 55 } }, [402] = { box = { 50, 397.5, 55, 399.8 } } },
		planSteps = 1000 })
	send(g, 925, "connect", "{ from = 101, to = 103 }")
	frames(g, FIRST + 70)
	local w = g.tc.plans[1].world
	eq(w.blocked(199.5, 52), true, "the last metre of block 0 eastwards")
	eq(w.blocked(199.9, 52), true)
	eq(w.blocked(52, 399.7), true, "the last metre of block 1 northwards")
	eq(w.blocked(201, 52), true, "the building's room reaches into the next block too")
	eq(w.blocked(205, 52), false, "and no further")
	eq(w.blocked(52, 405), false)
end)

test("connect: points or pieces without a direction are refused, never sent", function()
	local p = { { x = 0, y = 0, z = 0, tx = 1, ty = 0, s = 0 }, { x = 100, y = 0, z = 0, tx = 0, ty = 0, s = 100 } }
	truthy(connectMod.routeProblem(connectMod.routeOf(p, 1, 2), { x = 0, y = 0 }, { x = 100, y = 0 }):find("point 2 has no direction"))
	local g = connectWorld()
	g.tc.nodes[140], g.tc.nodes[141] = { 2000, 0, 0 }, { 2000, 0, 0 }
	g.tc.edges[240] = { node0 = 141, node1 = 140 }
	local a = connectRun(g, 926, "{ from = 101, to = 140 }")
	truthy(a.error:find("node 140: its piece has no direction"), tostring(a.error))
	eq(#g.tc.events, 0)
	local cp = connectMod.controlPoints({ x = 0, y = 0, z = 0 }, { x = 90, y = 0, z = 0 }, { x = 90, y = 0, z = 9 }, { x = 90, y = 0, z = 0 })
	local mid = connectMod.curvePoint(cp, 0.5)
	eq(mid.x, 45); eq(mid.z, 4.5); eq(connectMod.curvePoint(cp, 1).x, 90)
end)

test("connect --build: a player taking over Track Connector during the build is told, not taken for this build", function()
	local g = connectWorld({ stealAfter = "tc_build" })
	local a = connectRun(g, 927, "{ from = 101, to = 103, build = true }")
	eq(a.ok, false); truthy(a.error:find("shows other ends after the build"), a.error)
	truthy(a.build and #a.build.newEdges > 0, "what was found is still in the answer")
end)

test("connect: ids that are no entity are never looked up (the strict fake ends the game on such a lookup)", function()
	local g = connectWorld()
	for i, id in ipairs({ 99999, 2 ^ 31 - 1, 123456789 }) do
		local a = connectRun(g, 930 + i, string.format("{ from = 101, to = %d }", id))
		truthy(a.error:find("is no node, station"), tostring(a.error))
	end
	eq(g.crashed, nil)
end)

test("connect ends: a station's construction found around it when the engine's lookup is missing or says none", function()
	local g = connectWorld({ stationConstruction = {} })
	local a = connectRun(g, 940, "{ from = 101, to = 42 }")
	eq(a.ok, true, tostring(a.error)); eq(a.to.node, 105)
	api.engine.system.streetConnectorSystem.getConstructionEntityForStation = nil
	a = connectRun(g, 941, "{ from = 101, to = 421 }", 120)
	eq(a.ok, true, tostring(a.error)); eq(a.to.kind, "station")
end)

test("connect: a route in Track Connector's state that is not this command's (another point count) ends it", function()
	local g = connectWorld({ alterRoute = true })
	local a = connectRun(g, 942, "{ from = 101, to = 103, build = true }")
	truthy(a.error:find("someone used its tool"), a.error)
	for _, e in ipairs(g.tc.events) do truthy(e ~= "tc_build", "no build sent") end
end)

test("connect map: blocks read off the band inside the planner's coroutine let the frame go every few reads", function()
	local far = {}
	for i = 1, 10 do far[i] = { 3000, -3000 + i * 200 } end -- (ten blocks, inside the map, off the band)
	local g = connectWorld({ coroutine = true, farPoints = far })
	local tune = package.loaded["hummer_remote_probe::/remote_connect.lua"].TUNE
	tune.lateBlocksPerSlice = 1 -- a wait after every late block
	local a = connectRun(g, 950, "{ from = 101, to = 103 }")
	eq(a.ok, true, tostring(a.error))
	eq(a.plan.map.yields, 10, "one wait per block read late"); eq(a.plan.map.lateBlocks, 10)
	truthy(g.tc.plans[1].resumes >= 10 + 3, "the planner went on over later frames")
	eq(g.tc.plans[1].farDone, 10, "and finished what it was doing")
	g = connectWorld({ coroutine = true, farPoints = far })
	a = connectRun(g, 951, "{ from = 101, to = 103 }")
	eq(a.ok, true, tostring(a.error)); eq(a.plan.map.yields, 3, "the default: a wait after every 3 (10 reads)")
	-- outside a coroutine the same reads just go on
	g = connectWorld({ farPoints = far })
	package.loaded["hummer_remote_probe::/remote_connect.lua"].TUNE.lateBlocksPerSlice = 1
	a = connectRun(g, 952, "{ from = 101, to = 103 }")
	eq(a.ok, true, tostring(a.error)); eq(a.plan.map.yields, 0); eq(a.plan.map.lateBlocks, 10)
	truthy(g.logs[#g.logs]:find("read 10 blocks in one slice", 1, true) or table.concat(g.logs, "\n"):find("read 10 blocks in one slice", 1, true),
		"said in the log")
end)

test("connect ends: the way out of a curved piece's end follows its curve there, not the piece's chord", function()
	local g = connectWorld()
	-- a quarter circle of radius 100 from (2000, 0) heading +y to (1900, 100) heading -x: its end at 151 points -x
	local k = 4 / 3 * (math.sqrt(2) - 1) * 100 * 3
	g.tc.nodes[150], g.tc.nodes[151] = { 2000, 0, 0 }, { 1900, 100, 0 }
	g.tc.edges[250] = { node0 = 150, node1 = 151, t0 = { x = 0, y = k, z = 0 }, t1 = { x = -k, y = 0, z = 0 } }
	local a = connectRun(g, 953, "{ from = 151, to = 103 }", FIRST + 100)
	local plan = g.tc.plans[#g.tc.plans]
	truthy(plan and math.abs(plan.start.heading - math.pi) < 0.002, "leaves heading -x: " .. tostring(plan and plan.start.heading))
	eq(a.from.node, 151)
end)

test("connect: the same place given twice in other words is refused (name and id, station and its group)", function()
	local g = connectWorld()
	for i, c in ipairs({ "{ from = 'Harbour', to = 42 }", "{ from = 421, to = 42 }", "{ from = 301, to = 'Harbour' }" }) do
		local a = connectRun(g, 960 + i, c)
		truthy(tostring(a.error):find("the same place"), c .. ": " .. tostring(a.error))
	end
	eq(#g.tc.plans, 0); eq(g.crashed, nil)
end)

test("connect helpers: years a type can be built in, entrance roads, an end's mouth", function()
	local av = connectMod.availableIn
	eq(av({ yearFrom = 0, yearTo = 0 }, 1909), true, "0: no limit")
	eq(av({ yearFrom = 1940, yearTo = 0 }, 1939), false); eq(av({ yearFrom = 1940, yearTo = 0 }, 1940), true)
	eq(av({ yearFrom = 0, yearTo = 1940 }, 1939), true); eq(av({ yearFrom = 0, yearTo = 1940 }, 1940), false, "yearTo: the first year without")
	eq(av({ yearFrom = -1, yearTo = -1 }, 1909), false, "-1: never (the base game's industry roads)")
	eq(av(nil, 1909), true, "nothing known: yes"); eq(av({ yearFrom = 1940 }, nil), true, "no year known: yes")
	eq(connectMod.availabilityText({ yearFrom = 1940, yearTo = 0 }), "from 1940")
	eq(connectMod.availabilityText({ yearFrom = 0, yearTo = 1925 }), "until 1924")
	eq(connectMod.availabilityText({ yearFrom = 1900, yearTo = 1925 }), "from 1900 until 1924")
	eq(connectMod.availabilityText({ yearFrom = -1, yearTo = -1 }), "never")
	eq(connectMod.availabilityText({ yearFrom = 0, yearTo = 0 }), "always"); eq(connectMod.availabilityText(nil), "always")
	eq(connectMod.isEntranceRoad(fakeTc.ENTRANCE), true); eq(connectMod.isEntranceRoad(fakeTc.COUNTRY), false)
	eq(connectMod.isEntranceRoad(nil), false)
	local ml = connectMod.mouthLength
	eq(ml(0, 0, 1, 0, nil), 20, "nothing around: the least"); eq(ml(0, 0, 1, 0, {}), 20)
	eq(ml(0, 0, 1, 0, { { -10, -10, 30, 10 } }), 40, "out of the box it lies in, and 10 m on")
	eq(ml(0, 0, -1, 0, { { -10, -10, 30, 10 } }), 20, "pointing out the near side: the least")
	eq(ml(0, 0, 1, 0, { { 5, -10, 300, 10 } }), 20, "a box the end is not in is in the way, not opened")
	eq(ml(0, 0, 1, 0, { { -10, -10, 1000, 10 } }), 150, "at most 150 m")
	local d = math.sqrt(0.5)
	eq(math.floor(ml(0, 0, d, d, { { -10, -10, 50, 20 } }) * 100 + 0.5) / 100, 38.28, "diagonal: the side it meets first")
	local m = { x = 0, y = 0, dx = 1, dy = 0, len = 40 }
	eq(connectMod.inMouth(m, -9, 0), true, "round the node"); eq(connectMod.inMouth(m, -11, 0), false, "but not behind it")
	eq(connectMod.inMouth(m, 30, 10), true, "the wedge widens out"); eq(connectMod.inMouth(m, 30, 11), false)
	eq(connectMod.inMouth(m, 41, 0), false, "and ends")
end)

-- an industry: its construction 501 (with the entrance road 260 from 160 to the free end 161, of the entrance road
-- type) and a part of it without a CONSTRUCTION component (502, as the engine keeps an industry) whose box the end
-- lies in; and a plain road end 122 to go to
local function industryWorld(opts)
	local w = { constructions = { [301] = { box = { 990, 490, 1110, 510 }, stations = { 421 }, frozenEdges = { 203 } },
			[501] = { box = { 0, 1400, 190, 1600 }, frozenEdges = { 260 } } },
		industries = { [502] = { box = { 50, 1420, 230, 1580 } } }, availability = fakeTc.BASE_YEARS, year = 1909, planSteps = 1000 }
	for k, v in pairs(opts or {}) do w[k] = v end
	local g = connectWorld(w)
	g.tc.nodes[160], g.tc.nodes[161] = { 100, 1500, 5 }, { 200, 1500, 5 }
	g.tc.edges[260] = { node0 = 160, node1 = 161, road = true, template = fakeTc.ENTRANCE }
	g.tc.nodes[122], g.tc.nodes[123] = { 900, 900, 5 }, { 1000, 900, 5 }
	g.tc.edges[209] = { node0 = 123, node1 = 122, road = true }
	return g
end

test("connect world: an end's own industry still blocks, only the mouth of the end is open", function()
	local g = industryWorld()
	send(g, 970, "connect", "{ from = 161, to = 122, road = true }")
	frames(g, FIRST + 70)
	local w = g.tc.plans[1] and g.tc.plans[1].world
	truthy(w, "planning started")
	eq(w.blocked(100, 1450), true, "the industry's construction, though the end's road belongs to it")
	eq(w.blocked(215, 1430), true, "its part without a CONSTRUCTION component (outside the construction's box)")
	eq(w.blocked(200, 1500), false, "the end node"); eq(w.blocked(192, 1500), false, "and round it")
	eq(w.blocked(225, 1500), false, "out the way the end points, through the box it lies in")
	eq(w.blocked(225, 1525), true, "beside that way, in the box")
	eq(w.blocked(400, 1500), false, "open land")
	eq(w.crossing(150, 1500), false, "the end's own road is no crossing")
	frames(g, 1100)
	local a = final(g, 970)
	eq(a.ok, true, tostring(a.error))
	eq(a.plan.map.mouths.from.length, 44, "out of the part's box (234) and 10 m on"); eq(a.plan.map.mouths.from.inside, 1)
	eq(a.plan.map.mouths.to.length, 20); eq(a.plan.map.mouths.to.inside, 0)
	eq(a.plan.map.endConstructions, 1); eq(a.plan.map.leftOutPieces, 2)
	eq(g.crashed, nil)
end)

test("connect road: from an entrance road the default is a plain road of the game's year, without its lanes", function()
	local g = industryWorld({ planSteps = 3 })
	local a = connectRun(g, 971, "{ from = 161, to = 122, road = true }")
	eq(a.ok, true, tostring(a.error)); eq(a.year, 1909)
	eq(a.template, fakeTc.OLD_COUNTRY, "1909: the old medium country road (the new one is from 1940)")
	eq(a.settings.track, fakeTc.OLD_COUNTRY); eq(a.settings.laneFrom, nil, "the entrance road's lanes are not copied")
	truthy(a.notes and a.notes[1]:find("entrance road", 1, true) and a.notes[1]:find("built as " .. fakeTc.OLD_COUNTRY, 1, true),
		tostring(a.notes and a.notes[1]))
	g = industryWorld({ planSteps = 3, year = 1950 })
	a = connectRun(g, 972, "{ from = 161, to = 122, road = true }")
	eq(a.template, fakeTc.COUNTRY, "1950: the new one")
	-- an ordinary start road whose type is past its years: a road of this year instead
	g = industryWorld({ planSteps = 3, year = 1950, availability = { [fakeTc.TOWN] = { yearFrom = 0, yearTo = 1930 } } })
	g.tc.edges[209].template = fakeTc.TOWN
	a = connectRun(g, 973, "{ from = 122, to = 161, road = true }")
	eq(a.template, fakeTc.COUNTRY); eq(a.settings.laneFrom, nil)
	truthy(a.notes[1]:find("until 1929, not in 1950", 1, true), a.notes[1])
	-- and one of this year is kept, lanes and all
	g = industryWorld({ planSteps = 3, year = 1920 })
	g.tc.edges[209].template = fakeTc.TOWN
	a = connectRun(g, 974, "{ from = 122, to = 161, road = true }")
	eq(a.template, fakeTc.TOWN); eq(a.settings.laneFrom, 209); eq(a.notes, nil)
	-- none of the defaults to be had: refused, asking for a template
	g = industryWorld({ planSteps = 3, year = 1909, availability = { [fakeTc.OLD_COUNTRY] = { yearFrom = 1930, yearTo = 0 },
		[fakeTc.COUNTRY] = { yearFrom = 1940, yearTo = 0 } } })
	a = connectRun(g, 975, "{ from = 161, to = 122, road = true }")
	truthy(tostring(a.error):find("none of the default road types can be built in 1909: give template", 1, true), tostring(a.error))
	eq(#g.tc.plans, 0)
end)

test("connect: years or availability that cannot be read are said; an end inside a site is named when no route is found", function()
	local g = industryWorld({ planSteps = 3, noAvailability = true })
	local a = connectRun(g, 984, "{ from = 161, to = 122, road = true }")
	eq(a.ok, true, tostring(a.error)); eq(a.template, fakeTc.COUNTRY, "nothing known of the years: the first choice")
	truthy(a.notes and a.notes[1]:find("could not be read: not checked against the year", 1, true), tostring(a.notes and a.notes[1]))
	g = industryWorld({ planSteps = 3, noRoute = true })
	a = connectRun(g, 985, "{ from = 161, to = 122, road = true }")
	truthy(tostring(a.error):find("no route"), tostring(a.error))
	local said = false
	for _, n in ipairs(a.notes or {}) do said = said or n:find("the from end lies inside 1 building", 1, true) ~= nil end
	truthy(said, "the trapped end named")
	for _, n in ipairs(a.notes or {}) do truthy(not n:find("the to end", 1, true), "the free end not") end
end)

test("connect road: a template out of its years or an entrance road is refused before anything is sent", function()
	local g = industryWorld({ planSteps = 3 })
	local a = connectRun(g, 976, string.format("{ from = 161, to = 122, road = true, template = %q }", fakeTc.COUNTRY))
	truthy(tostring(a.error):find("is to be had from 1940, not in 1909", 1, true) and a.error:find(fakeTc.OLD_COUNTRY, 1, true),
		tostring(a.error))
	a = connectRun(g, 977, string.format("{ from = 161, to = 122, road = true, template = %q }", fakeTc.ENTRANCE))
	truthy(tostring(a.error):find("entrance road, not a road type a player builds", 1, true), tostring(a.error))
	eq(#g.tc.plans, 0); eq(#g.tc.events, 0)
	a = connectRun(g, 978, string.format("{ from = 161, to = 122, road = true, template = %q }", fakeTc.OLD_COUNTRY))
	eq(a.ok, true, tostring(a.error)); eq(a.template, fakeTc.OLD_COUNTRY)
	-- tracks: only a note (whether the game refuses such a track from a script is not known)
	g = connectWorld({ year = 1909, availability = { [fakeTc.STANDARD] = { yearFrom = 1930, yearTo = 0 } } })
	a = connectRun(g, 979, "{ from = 101, to = 103 }")
	eq(a.ok, true, tostring(a.error)); eq(a.template, fakeTc.STANDARD)
	truthy(a.notes and a.notes[1]:find("is to be had from 1930, and the year is 1909", 1, true), tostring(a.notes and a.notes[1]))
end)

test("connect: a dry run refused without a cost says the game refused it before pricing it", function()
	local g = connectWorld({ blocked = true, cost = 0 })
	local a = connectRun(g, 980, "{ from = 101, to = 103 }")
	eq(a.ok, false)
	local said = false
	for _, n in ipairs(a.notes or {}) do said = said or n:find("refused the route before pricing it", 1, true) ~= nil end
	truthy(said, "noted")
	g = connectWorld({ blocked = true })
	a = connectRun(g, 981, "{ from = 101, to = 103 }")
	eq(a.notes, nil, "a priced refusal needs no such note")
end)

test("connect map: the planner's whole search area is read before it starts, so it reads nothing late", function()
	local g = connectWorld({ planSteps = 1000 })
	send(g, 982, "connect", "{ from = 101, to = 103 }")
	frames(g, FIRST + 70)
	local w = g.tc.plans[1] and g.tc.plans[1].world
	truthy(w, "planning started")
	local before = g.tc.octreeCalls
	w.blocked(2450, 1450); w.blocked(-1450, -1450)
	eq(g.tc.octreeCalls, before, "1.5 km round the ends already read")
	w.blocked(2700, 0)
	eq(g.tc.octreeCalls, before + 1, "further out: read when asked")
	frames(g, 1100)
	local a = final(g, 982)
	eq(a.ok, true, tostring(a.error))
	-- (x -1500..2500 and y -1500..1500: blocks -8..12 by -8..7)
	eq(a.plan.map.preload, 21 * 16); eq(a.plan.map.lateBlocks, 1, "only the one asked for above")
	-- the map's edge bounds the area: near the edge fewer blocks
	g = connectWorld({ planSteps = 3, bounds = { -1000, -1000, 2000, 1000 } })
	a = connectRun(g, 983, "{ from = 101, to = 103 }", FIRST + 100)
	eq(a.ok, true, tostring(a.error))
	-- (inside the map's inset: -920..1920 by -920..920, blocks -5..9 by -5..4)
	eq(a.plan.map.preload, 15 * 10)
end)

test("connect is refused in the main menu", function()
	local g = newGame({ saves = SAVES, menu = true })
	frames(g, 2)
	send(g, 895, "connect", "{ from = 101, to = 103 }")
	frames(g, FIRST)
	truthy(final(g, 895).error:find("needs a running game"))
end)

test("cameraTarget / numberList: kept values, NaN, infinity and out-of-range refused", function()
	local cur = { x = 1, y = 2, distance = 300, angle = 0.1, pitch = 0.5 }
	local t = core.cameraTarget(cur, core.numberList("10,20", 5))
	eq(t.x, 10); eq(t.y, 20); eq(t.distance, 300); eq(t.pitch, 0.5)
	t = core.cameraTarget(cur, core.numberList("10,20,800,1,-0.3", 5))
	eq(t.distance, 800); eq(t.angle, 1); eq(t.pitch, -0.3)
	truthy(select(2, core.numberList("1,nan", 5)))
	truthy(select(2, core.numberList("1,inf", 5)))
	truthy(select(2, core.numberList("1,,2", 5)), "an empty part")
	truthy(select(2, core.numberList("1,2,3,4,5,6", 5)))
	truthy(select(2, core.numberList(nil, 5)))
	truthy(select(2, core.cameraTarget(cur, { 1 })), "x alone")
	truthy(select(2, core.cameraTarget(cur, { 1, 2, 0 })), "distance 0")
	truthy(select(2, core.cameraTarget(cur, { 1, 2, 300, 7 })), "angle past a turn")
	truthy(select(2, core.cameraTarget(cur, { 1, 2, 300, 0, 2 })), "pitch past a quarter turn")
	truthy(select(2, core.cameraTarget(cur, { 2e6, 2 })), "far off the map")
	truthy(select(2, core.cameraTarget({ x = 0, y = 0, distance = 0 / 0, angle = 0, pitch = 0 }, { 1, 2 })), "a NaN kept from the game")
end)

test("camera: reads, sets (rest kept), focuses an entity or a point; answers the values read back", function()
	local g = newGame({ saves = SAVES, lines = { [7] = { name = "L" } } })
	frames(g, 2)
	send(g, 900, "camera")
	frames(g, FIRST)
	local a = final(g, 900)
	eq(a.camera.x, 0); eq(a.camera.distance, 500); eq(a.camera.angle, 0.5); eq(a.camera.heightAboveTerrain, 250); eq(a.moved, false)
	send(g, 901, "camera", '{ set = "10,20,800" }')
	frames(g, 20)
	a = final(g, 901)
	eq(a.camera.x, 10); eq(a.camera.y, 20); eq(a.camera.distance, 800); eq(a.camera.angle, 0.5, "kept"); eq(a.camera.pitch, 0.6, "kept")
	send(g, 902, "camera", '{ focus = "5,6,7", distance = 300 }')
	frames(g, 20)
	a = final(g, 902)
	eq(a.camera.x, 5); eq(a.camera.distance, 300); eq(g.focusedAt.z, 7)
	send(g, 903, "camera", "{ entity = 7 }")
	frames(g, 20)
	eq(g.focused, 7); eq(final(g, 903).camera.x, 107)
	for i, args in ipairs({ "{ entity = 99999 }", '{ set = "1,nan" }', '{ set = "1,2,0" }', '{ focus = "1,2" }',
		'{ focus = "1,2,3", distance = -1 }', '{ set = "1,2", entity = 7 }' }) do
		send(g, 903 + i, "camera", args)
		frames(g, 20)
		truthy(final(g, 903 + i).error, args)
	end
	eq(g.cam.x, 107, "refused ones left the camera alone")
end)

test("camera is refused in the main menu", function()
	local g = newGame({ saves = SAVES, menu = true })
	frames(g, 2)
	send(g, 920, "camera")
	frames(g, FIRST)
	truthy(final(g, 920).error:find("needs a running game"))
end)

test("buildToolRequest: tag with a template; bad res, template and seconds refused", function()
	local r = core.buildToolRequest({ res = "a.con" })
	eq(r.tag, "a.con"); eq(r.seconds, 60)
	eq(core.buildToolRequest({ res = "a.con", template = 2, seconds = 10 }).tag, "a.con@2")
	truthy(select(2, core.buildToolRequest({})))
	truthy(select(2, core.buildToolRequest(nil)))
	truthy(select(2, core.buildToolRequest({ res = "a.con@2" })), "the template goes in template")
	truthy(select(2, core.buildToolRequest({ res = "a.con", template = 1.5 })))
	truthy(select(2, core.buildToolRequest({ res = "a.con", seconds = 1e9 })))
	truthy(select(2, core.buildToolRequest({ res = "a.con", seconds = 0 / 0 })))
	eq(#core.menuFilter(nil).enabledItems, 0)
end)

-- the events the speed control would see: each new open.seq, in order, with the game time it appeared
local function watchEvents(g, n, dt)
	local seen = {}
	local last = ((fake.guiSave.hummer_remote_probe or {}).open or {}).seq
	for _ = 1, n do
		g.step(dt)
		local o = (fake.guiSave.hummer_remote_probe or {}).open
		if type(o) == "table" and o.seq ~= last then
			last = o.seq
			seen[#seen + 1] = { name = o.event and o.event.name, param = o.event and o.event.param, t = g.time }
		end
	end
	return seen
end

test("build-tool: filter, then the tab after the gap, then the filter cleared on time by the mod alone", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 930, "buildTool", '{ res = "station/street/bus_stop.con", template = 1, seconds = 5 }')
	local ev = watchEvents(g, FIRST + 30 * 10)
	local a = final(g, 930)
	eq(a.tag, "station/street/bus_stop.con@1"); truthy(a.clearInSec > 5); truthy(#a.notes > 0)
	eq(#ev, 3, "filter, select, clear")
	eq(ev[1].name, "setMenuFilter"); eq(ev[1].param.enabledItems[1], "station/street/bus_stop.con@1")
	eq(ev[2].name, "constructionMenuSelectTabForConstruction"); eq(ev[2].param.resName, "station/street/bus_stop.con")
	truthy(ev[2].t - ev[1].t >= 1, "the speed control reads every 0.5 s: a second between")
	eq(ev[3].name, "setMenuFilter"); eq(#ev[3].param.enabledItems, 0, "cleared without any tool around")
	truthy(ev[3].t - ev[2].t >= 5 - 0.1)
	eq(watchEvents(g, 30 * 10)[1], nil, "nothing more")
	fake.guiSave.hummer_remote_probe = nil
end)

test("build-tool --close clears at once and drops the pending select; unknown res refused", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 940, "buildTool", '{ res = "station/street/bus_stop.con" }')
	frames(g, FIRST)
	send(g, 941, "buildTool", "{ close = true }")
	local ev = watchEvents(g, 30 * 3)
	eq(final(g, 941).closed, true)
	eq(#ev, 1, "only the clear: no select after it"); eq(#ev[1].param.enabledItems, 0)
	eq(watchEvents(g, 30 * 70)[1], nil, "and no clear later")
	send(g, 942, "buildTool", '{ res = "nope.con" }')
	ev = watchEvents(g, 30 * 3)
	truthy(final(g, 942).error:find("no such construction")); eq(#ev, 0)
	fake.guiSave.hummer_remote_probe = nil
end)

test("buildToolRequest: menu alone, menu with res; unknown menu and template without res refused", function()
	local r = core.buildToolRequest({ menu = "rail" })
	eq(r.menu, "openRail"); eq(r.res, nil); eq(r.tag, nil)
	r = core.buildToolRequest({ menu = "road", res = "a.con", template = 0 })
	eq(r.menu, "openRoad"); eq(r.tag, "a.con@0"); eq(r.seconds, 60)
	truthy(select(2, core.buildToolRequest({ menu = "nope" })):find("rail"), "the error names the menus")
	truthy(select(2, core.buildToolRequest({ menu = 3 })))
	truthy(select(2, core.buildToolRequest({ menu = "rail", template = 1 })))
	truthy(select(2, core.buildToolRequest({ menu = "rail", res = "" })))
	for k, v in pairs(core.BUILD_MENUS) do eq(v, "open" .. k:sub(1, 1):upper() .. k:sub(2)) end
end)

test("build-tool --menu: the toolbar event alone, nothing after it", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 950, "buildTool", '{ menu = "rail" }')
	local ev = watchEvents(g, FIRST + 30 * 5)
	local a = final(g, 950)
	eq(a.ok, true); eq(a.menuEvent, "openRail"); eq(a.clearInSec, nil)
	eq(#ev, 1); eq(ev[1].name, "openRail")
	eq(watchEvents(g, 30 * 70)[1], nil, "no filter to clear")
	fake.guiSave.hummer_remote_probe = nil
end)

test("build-tool --menu with res: open, filter, select a gap apart, then the clear", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 951, "buildTool", '{ menu = "road", res = "station/street/bus_stop.con", seconds = 5 }')
	local ev = watchEvents(g, FIRST + 30 * 12)
	local a = final(g, 951)
	eq(a.menuEvent, "openRoad"); truthy(a.clearInSec >= 5 + 2 * core.BUILD_TOOL_GAP - 0.01)
	eq(#ev, 4, "open, filter, select, clear")
	eq(ev[1].name, "openRoad"); eq(ev[2].name, "setMenuFilter"); eq(ev[2].param.enabledItems[1], "station/street/bus_stop.con")
	eq(ev[3].name, "constructionMenuSelectTabForConstruction"); eq(ev[4].name, "setMenuFilter")
	eq(#ev[4].param.enabledItems, 0)
	truthy(ev[2].t - ev[1].t >= 1 and ev[3].t - ev[2].t >= 1, "a gap between each")
	truthy(ev[4].t - ev[3].t >= 5 - 0.1)
	fake.guiSave.hummer_remote_probe = nil
end)

test("build-tool --menu alone after a --res: the earlier filter is still cleared, before the menu opens", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 954, "buildTool", '{ res = "station/street/bus_stop.con" }')
	local ev = watchEvents(g, FIRST + 30 * 3)
	eq(ev[1].name, "setMenuFilter"); eq(ev[1].param.enabledItems[1], "station/street/bus_stop.con")
	send(g, 955, "buildTool", '{ menu = "rail" }')
	ev = watchEvents(g, FIRST + 30 * 5)
	eq(#ev, 2, "the clear, then the menu")
	eq(ev[1].name, "setMenuFilter"); eq(#ev[1].param.enabledItems, 0)
	eq(ev[2].name, "openRail"); truthy(ev[2].t - ev[1].t >= 1)
	eq(watchEvents(g, 30 * 70)[1], nil, "nothing left after it")
	fake.guiSave.hummer_remote_probe = nil
end)

test("build-tool --close while the menu's queue is pending drops the rest", function()
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	send(g, 952, "buildTool", '{ menu = "road", res = "station/street/bus_stop.con" }')
	local first = watchEvents(g, FIRST)
	eq(first[1] and first[1].name, "openRoad")
	send(g, 953, "buildTool", "{ close = true }")
	local ev = watchEvents(g, 30 * 70)
	eq(#ev, 1, "only the clear"); eq(ev[1].name, "setMenuFilter"); eq(#ev[1].param.enabledItems, 0)
	fake.guiSave.hummer_remote_probe = nil
end)

---------------------------------------------------------------------------------------------------------------------
-- industryWorkers: an industry's workers, as the base's window and its workers script count them
local function workersGame(extra)
	local o = { saves = SAVES, entities = { TOWN = { 11, 12 } }, names = { [11] = "Emsworth", [12] = "Havant" },
		positions = { [11] = { 0, 0 }, [12] = { 5000, 0 } },
		townCapacities = { [11] = { 140, 20, 30 }, [12] = { 0, 15, 40 } },
		industries = {
			[51] = { name = "Coal mine", construction = 5100, capacity = 12, workers = 5, productivity = 1.8, pos = { 300, 0 } },
			[52] = { name = "Farm", capacity = 8, workers = 0, productivity = 1, pos = { 4800, 0 } },
			[53] = { name = "Oil well" }, -- no capacity, no stock list, no position
		},
		workersState = { industriesState = { [51] = { lastVisitors = {
			{ entity = { entity = 9001 }, time = 4000 }, { entity = { entity = 9002 }, time = 6500 } } } } } }
	for k, v in pairs(extra or {}) do o[k] = v end
	local g = newGame(o)
	frames(g, 2)
	return g
end

test("industryWorkers: capacity, destination sims, last visitors, productivity and the nearest town", function()
	local g = workersGame()
	send(g, 1201, "industryWorkers", "{  }")
	frames(g, FIRST)
	local a = final(g, 1201)
	eq(a.ok, true); eq(a.total, 3); eq(#a.industries, 3)
	eq(a.workersScript.ok, true); eq(a.workersScript.name, "::/industries/industry_workers.gs")
	local by = {}
	for _, e in ipairs(a.industries) do by[e.name] = e end
	local m = by["Coal mine"]
	eq(m.id, 51); eq(m.construction, 5100); eq(m.capacity, 12); eq(m.boostAt, 6); eq(m.workers, 5)
	eq(m.lastVisitors, 2); eq(m.lastVisitTime, 6500); eq(m.productivity, 1.8)
	eq(m.town.id, 11); eq(m.town.name, "Emsworth"); eq(m.town.distance, 300); eq(m.town.population, 140)
	local f = by["Farm"]
	eq(f.lastVisitors, 0, "no entry in the state: nobody arrived, as the base reads it"); eq(f.lastVisitTime, nil)
	eq(f.workers, 0); eq(f.construction, nil)
	eq(f.town.id, 12); eq(f.town.population, 40, "no residents: the larger of the other two, as the town HUD")
	local o = by["Oil well"]
	eq(o.capacity, nil); eq(o.productivity, nil); eq(o.town, nil, "no position: no town")
	eq(o.workers, nil, "no capacity: the destination lookup is not made (the base makes it only with one)")
	eq(#g.commands, 0, "read only: no command sent")
end)

test("industryWorkers: one industry, an unknown id, a bad id, no industries", function()
	local g = workersGame()
	send(g, 1210, "industryWorkers", "{ entity = 52 }")
	frames(g, FIRST)
	local a = final(g, 1210)
	eq(a.ok, true); eq(#a.industries, 1); eq(a.industries[1].id, 52); eq(a.total, 3)
	send(g, 1211, "industryWorkers", "{ entity = 999 }")
	frames(g, 20)
	a = final(g, 1211)
	eq(a.ok, false); truthy(a.error:find("no industry", 1, true), a.error)
	send(g, 1212, "industryWorkers", '{ entity = "x" }')
	frames(g, 20)
	a = final(g, 1212)
	eq(a.ok, false); truthy(a.error:find("entity must be", 1, true), a.error)
	local g2 = newGame({ saves = SAVES })
	frames(g2, 2)
	send(g2, 1213, "industryWorkers", "{  }")
	frames(g2, FIRST)
	a = final(g2, 1213)
	eq(a.ok, true); eq(a.total, 0); eq(#a.industries, 0)
	truthy(answerText(g2, 1213):find('"industries":[]', 1, true), "an empty list, not {}")
end)

test("industryWorkers: without the workers script or its state, the rest still answers", function()
	for _, case in ipairs({ { "none", "is not running" }, { "nostate", "no state" } }) do
		local g = workersGame({ workersScript = case[1] })
		send(g, 1220, "industryWorkers", "{ entity = 51 }")
		frames(g, FIRST)
		local a = final(g, 1220)
		eq(a.ok, true, case[1]); eq(a.workersScript.ok, false)
		truthy(a.workersScript.error:find(case[2], 1, true), a.workersScript.error)
		eq(a.industries[1].lastVisitors, nil); eq(a.industries[1].workers, 5); eq(a.industries[1].capacity, 12)
	end
	-- an entry that does not read as a table: that industry carries why, the answer stays ok
	local g = workersGame({ workersState = { industriesState = { [51] = 7 } } })
	send(g, 1221, "industryWorkers", "{ entity = 51 }")
	frames(g, FIRST)
	local a = final(g, 1221)
	eq(a.ok, true); eq(a.industries[1].lastVisitors, nil); truthy(a.industries[1].lastVisitorsError)
	-- the destination lookup failing (an engine error) leaves workers out instead of failing the command
	local g3 = workersGame()
	local sps = api.engine.system.simPersonSystem
	api.engine.system.simPersonSystem = { getSimPersonsForDestination = function() error("boom") end }
	local ok, err = pcall(function()
		send(g3, 1222, "industryWorkers", "{ entity = 51 }")
		frames(g3, FIRST)
	end)
	api.engine.system.simPersonSystem = sps
	assert(ok, err)
	a = final(g3, 1222)
	eq(a.ok, true); eq(a.industries[1].workers, nil); eq(a.industries[1].lastVisitors, 2)
end)

---------------------------------------------------------------------------------------------------------------------
-- industryStocks: an industry's stocks, rules and its construction's params
local function stocksGame(extra)
	local o = { saves = SAVES,
		industries = {
			[51] = { name = "Coal mine", construction = 5100, productivity = 1.5, thrownAwayCargo = 3,
				stocks = { { type = 1, cargoType = 1, capacity = 400, count = 37 },
					{ type = 0, cargoType = -1, mixedTypes = true, cargoTypes = { 1, 2 }, classes = { "#any" }, capacity = 50,
						count = 4, consumeFrequency = 0.5 } },
				rules = { { input = { { 0, 0 } }, output = { [1] = 2 }, capacity = 100 },
					{ input = { { 0, 1 } }, output = {}, booster = true, boostFactor = 0.25 } } },
			[52] = { name = "Farm", construction = 5200, stocks = {} }, -- an empty stock list
			[53] = { name = "Oil well" }, -- no stock list, no construction
			[54] = { name = "Farm 2", construction = 5400, productivity = 1 }, -- a construction without params
		},
		constructionComps = {
			[5100] = { fileName = "industry/coal_mine.con", params = { hummer_aom_upg_pollution = "", hummer_aom_upg_boost = 2,
				hummer_aom_upg_group = { 1, 2 }, industrialCapacity = 3, year = 1900, seed = 7, modules = { [5] = "x" } } },
			[5200] = { fileName = "industry/farm.con", params = { seed = 1 }, noNative = true },
			[5400] = { fileName = "industry/farm.con" },
		} }
	for k, v in pairs(extra or {}) do o[k] = v end
	local g = newGame(o)
	frames(g, 2)
	return g
end

test("industryStocks: stocks with cargo and counts, rules, modifiers and the AoM params", function()
	local g = stocksGame()
	send(g, 1301, "industryStocks", "{  }")
	frames(g, FIRST)
	local a = final(g, 1301)
	eq(a.ok, true); eq(a.total, 4); eq(#a.industries, 4)
	local by = {}
	for _, e in ipairs(a.industries) do by[e.name] = e end
	local m = by["Coal mine"]
	eq(m.id, 51); eq(m.construction, 5100); eq(m.fileName, "industry/coal_mine.con")
	eq(m.productivity, 1.5); eq(m.thrownAwayCargo, 3)
	eq(#m.stocks, 2)
	local s1, s2 = m.stocks[1], m.stocks[2]
	eq(s1.index, 1); eq(s1.stockId, 0); eq(s1.type, 1); eq(s1.typeName, "OutputStock"); eq(s1.cargoType, 1)
	eq(s1.cargo.fileName, "COAL"); eq(s1.cargo.name, "Coal"); eq(s1.capacity, 400); eq(s1.count, 37)
	eq(s1.stockCargoTypes[1].cargoType, 1); eq(s1.mixedTypes, false)
	eq(s2.typeName, "InputStock"); eq(s2.cargoType, -1); eq(s2.cargo, nil, "-1: no cargo type, no lookup")
	eq(s2.mixedTypes, true); eq(#s2.stockCargoTypes, 2); eq(s2.stockCargoTypes[2].cargo.name, "Grain"); eq(s2.cargoClasses[1], "#any")
	eq(s2.count, 4); eq(s2.consumeFrequency, 0.5)
	eq(#m.rules, 2)
	eq(m.rules[1].output[1].cargoType, 1); eq(m.rules[1].output[1].amount, 2); eq(m.rules[1].output[1].cargo.fileName, "COAL")
	eq(m.rules[2].booster, true); eq(m.rules[2].boostFactor, 0.25); eq(m.rules[2].input[1][2], 1)
	eq(m.aomParams.hummer_aom_upg_pollution, "", "an empty string stays an empty string")
	eq(m.aomParams.hummer_aom_upg_boost, 2); eq(m.aomParams.hummer_aom_upg_group[2], 2)
	eq(m.params.industrialCapacity, 3); eq(m.params.year, 1900); eq(m.params.seed, nil, "not asked for")
	eq(m.allParams, nil, "only with allParams")
	local txt = answerText(g, 1301)
	truthy(txt:find('"hummer_aom_upg_pollution":""', 1, true), "the empty string is in the JSON")
	truthy(txt:find('"output":[]', 1, true), "a rule without outputs: an empty list")
	local f = by["Farm"]
	eq(#f.stocks, 0); truthy(txt:find('"stocks":[]', 1, true), "no stocks: an empty list")
	truthy(txt:find('"aomParams":{}', 1, true), "no AoM keys: an empty object, not []")
	eq(f.fileName, "industry/farm.con"); eq(next(f.aomParams), nil, "no AoM keys"); eq(f.params.seed, nil)
	local o = by["Oil well"]
	eq(o.stocks, nil); truthy(o.stockListError); eq(o.fileName, nil); eq(o.aomParams, nil)
	local f2 = by["Farm 2"]
	eq(f2.fileName, "industry/farm.con"); eq(next(f2.aomParams), nil); eq(#f2.stocks, 0)
	eq(#g.commands, 0, "read only: no command sent")
end)

test("industryStocks: one industry, grep, allParams, an unknown id, a bad id, no industries", function()
	local g = stocksGame()
	send(g, 1310, "industryStocks", "{ entity = 51, allParams = true }")
	frames(g, FIRST)
	local a = final(g, 1310)
	eq(a.ok, true); eq(#a.industries, 1); eq(a.industries[1].id, 51)
	eq(a.industries[1].allParams.seed, 7); eq(a.industries[1].allParams.modules["5"] or a.industries[1].allParams.modules[5], "x")
	eq(a.industries[1].allParams.hummer_aom_upg_pollution, "")
	send(g, 1311, "industryStocks", '{ grep = "FARM" }')
	frames(g, 20)
	a = final(g, 1311)
	eq(a.ok, true); eq(#a.industries, 2); eq(a.total, 4)
	send(g, 1312, "industryStocks", '{ grep = "nothing" }')
	frames(g, 20)
	a = final(g, 1312)
	eq(a.ok, true); eq(#a.industries, 0)
	send(g, 1313, "industryStocks", '{ entity = 51, grep = "farm" }')
	frames(g, 20)
	a = final(g, 1313)
	eq(a.ok, true); eq(#a.industries, 0, "a known id the grep leaves out: no error")
	send(g, 1314, "industryStocks", "{ entity = 999 }")
	frames(g, 20)
	a = final(g, 1314)
	eq(a.ok, false); truthy(a.error:find("no industry", 1, true), a.error)
	send(g, 1315, "industryStocks", '{ entity = "x" }')
	frames(g, 20)
	a = final(g, 1315)
	eq(a.ok, false); truthy(a.error:find("entity must be", 1, true), a.error)
	local g2 = newGame({ saves = SAVES })
	frames(g2, 2)
	send(g2, 1316, "industryStocks", "{  }")
	frames(g2, FIRST)
	a = final(g2, 1316)
	eq(a.ok, true); eq(a.total, 0); eq(#a.industries, 0)
	truthy(answerText(g2, 1316):find('"industries":[]', 1, true), "an empty list, not {}")
end)

test("industryStocks: a construction the engine does not give, a failing count", function()
	local g = stocksGame({ constructionComps = {} })
	local sys = api.engine.system.simEntityAtStockSystem
	api.engine.system.simEntityAtStockSystem = { getStockCount = function() error("boom") end }
	local ok, err = pcall(function()
		send(g, 1320, "industryStocks", "{ entity = 51 }")
		frames(g, FIRST)
	end)
	api.engine.system.simEntityAtStockSystem = sys
	assert(ok, err)
	local a = final(g, 1320)
	eq(a.ok, true); local m = a.industries[1]
	truthy(m.constructionError); eq(m.fileName, nil); eq(m.aomParams, nil)
	eq(#m.stocks, 2); eq(m.stocks[1].count, nil); eq(m.stocks[1].capacity, 400)
end)

test("core: industryStocks helpers", function()
	local a = core.industryStocksArgs(nil)
	eq(a.entity, nil); eq(a.grep, nil); eq(a.allParams, false)
	a = core.industryStocksArgs({ entity = "52", grep = "Mine", allParams = true })
	eq(a.entity, 52); eq(a.grep, "mine"); eq(a.allParams, true)
	for _, bad in ipairs({ { entity = -1 }, { grep = "" }, { grep = 5 }, { allParams = "yes" } }) do
		truthy(not core.industryStocksArgs(bad))
	end
	local p = core.pickParams({ hummer_aom_upg_a = "", hummer_aom_upg_b = { x = 1 }, upgrade = 0, other = 1, [3] = "n" })
	eq(p.prefixed.hummer_aom_upg_a, ""); eq(p.prefixed.hummer_aom_upg_b.x, 1); eq(p.other.upgrade, 0); eq(p.other.other, nil)
	eq(next(core.pickParams(nil).prefixed), nil); eq(next(core.pickParams("x").other), nil)
	local cyc = {}; cyc.self = cyc
	local pc = core.pickParams({ hummer_aom_upg_c = cyc })
	truthy(core.json(pc), "a cycle does not loop")
	local r = core.ruleOf({ input = { { 1, 0 } }, output = { [7] = 3, [2] = 1 }, booster = "x" })
	eq(r.booster, nil); eq(r.output[1].cargoType, 2); eq(r.output[2].cargoType, 7); eq(r.input[1][1], 1)
	r = core.ruleOf(nil)
	eq(#r.input, 0); eq(#r.output, 0)
end)

test("core: industryWorkers helpers", function()
	eq(next(core.industryWorkersArgs(nil)), nil); eq(core.industryWorkersArgs({ entity = "52" }).entity, 52)
	for _, bad in ipairs({ -1, 1.5, "x", 2 ^ 40 }) do truthy(not core.industryWorkersArgs({ entity = bad }), tostring(bad)) end
	eq(core.workersEntry(nil, { industriesState = { [5] = { lastVisitors = {} } } }, 5).lastVisitors[1], nil)
	eq(core.workersEntry(nil, { industriesState = {} }, 5), false)
	eq(core.workersEntry(nil, {}, 5), false)
	local e, why = core.workersEntry(nil, nil, 5)
	eq(e, nil); truthy(why)
	e, why = core.workersEntry({ findPath = function() error("assert") end }, nil, 5)
	eq(e, nil); truthy(why:find("findPath", 1, true))
	eq(core.visitorsOf(false), 0); eq(core.visitorsOf({}), 0)
	eq(select(2, core.visitorsOf({ lastVisitors = { { time = 3 }, { time = 9 }, {} } })), 9)
	eq(core.townPopulation(nil), nil); eq(core.townPopulation({}), nil)
	eq(core.townPopulation({ 5, 1, 2 }), 5); eq(core.townPopulation({ 0, 7, 2 }), 7)
	eq(core.nearest(nil, { { position = { x = 0, y = 0 } } }), nil); eq(core.nearest({ x = 0, y = 0 }, {}), nil)
	local t, d = core.nearest({ x = 0, y = 0 }, { { id = 1 }, { id = 2, position = { x = 3, y = 4 } } })
	eq(t.id, 2); eq(d, 5)
end)

---------------------------------------------------------------------------------------------------------------------
-- models and vehicles --state (read only): the ship rebalance's measures

test("core: modelsArgs and vehicleListArgs; every bad value refused with a reason", function()
	local a = core.modelsArgs(nil)
	eq(a.limit, 200); eq(a.grep, nil); eq(a.carrier, nil)
	a = core.modelsArgs({ grep = "Ship", carrier = "water", limit = 5 })
	eq(a.grep, "ship"); eq(a.carrier, "WATER"); eq(a.limit, 5)
	eq(core.modelsArgs({ grep = 701 }).grep, "701")
	eq(core.modelsArgs({ limit = core.MODELS_MAX }).limit, 1000)
	for _, bad in ipairs({ { grep = "" }, { grep = {} }, { carrier = "" }, { carrier = 4 }, { limit = 0 }, { limit = 1.5 },
		{ limit = "x" }, { limit = 1001 } }) do
		local ok, err = core.modelsArgs(bad)
		eq(ok, nil); truthy(type(err) == "string")
	end
	local v = core.vehicleListArgs(nil)
	eq(v.limit, 200); eq(v.state, false); eq(v.entities, nil); eq(v.line, nil)
	eq(core.vehicleListArgs({ limit = "lots" }).limit, 200, "a limit that is no number is the default, as before")
	v = core.vehicleListArgs({ line = "21", entities = { 601, "602" }, state = true, since = 100 })
	eq(v.line, 21); eq(v.entities[2], 602); eq(v.state, true); eq(v.since, 100)
	v = core.vehicleListArgs({ entities = { 601, 601, 602 }, state = true, since = 5.7 })
	eq(#v.entities, 2, "a vehicle named twice is answered once"); eq(v.since, 5, "calculateBalance takes an integer")
	for _, bad in ipairs({
		{ { line = "x" }, "line must be an entity id" },
		{ { entities = 601 }, "entities must be a list" },
		{ { entities = {} }, "at least one" },
		{ { entities = { -1 } }, "entities must be a list" },
		{ { entities = { 1.5 } }, "entities must be a list" },
		{ { state = "yes" }, "state must be true or false" },
		{ { since = 5 }, "since goes with state" },
		{ { since = -1, state = true }, "since must be" },
	}) do
		local ok, err = core.vehicleListArgs(bad[1])
		eq(ok, nil, bad[2]); truthy(tostring(err):find(bad[2], 1, true), tostring(err))
	end
	local many = {}
	for i = 1, core.MAX_VEHICLE_ENTITIES + 1 do many[i] = i end
	truthy(select(2, core.vehicleListArgs({ entities = many })):find("at most"))
end)

test("core: storeCapacities sums as the store; cargoIds and enumName", function()
	-- one compartment that carries BULK 120 or GOODS 40 (a cargo in both configs counts once, the larger), and one
	-- of passengers
	local per, total = core.storeCapacities({ { { capacity = 120, cargoTypes = { 1, 2 } }, { capacity = 40, cargoTypes = { 3, 2 } } },
		{ { capacity = 20, cargoTypes = { 0 } } } })
	eq(per[1], 120); eq(per[2], 120); eq(per[3], 40); eq(per[0], 20); eq(total, 140)
	per, total = core.storeCapacities({ {}, { { capacity = 5, cargoTypes = {} } } })
	eq(next(per), nil, "empty compartments: nothing"); eq(total, 0)
	per, total = core.storeCapacities(nil)
	eq(next(per), nil); eq(total, 0)
	local ids = core.cargoIds({ [3] = "C", [0] = "P", [1] = "A", x = "no" })
	eq(table.concat(ids, ","), "0,1,3"); eq(#core.cargoIds(nil), 0)
	local E = { A = 1, B = 2 }
	eq(core.enumName(E, { "A", "B" }, 2), "B"); eq(core.enumName(E, { "A", "B" }, 9), "9"); eq(core.enumName(E, { "A" }, nil), nil)
	eq(core.enumName(setmetatable({}, { __index = function() error("no") end }), { "A" }, 1), "1", "a raising enum is no crash")
end)

-- cargo types with classes, ships with the base's metadata shapes, and the edge cases
local SHIP_CARGO = { [0] = { name = "PASSENGERS", label = "Passengers", classes = { "PASSENGERS" } },
	[1] = { name = "COAL", label = "Coal", classes = { "BULK" } }, [2] = { name = "GRAIN", label = "Grain", classes = { "BULK" } },
	[3] = { name = "GOODS", label = "Goods", classes = { "GOODS" } }, [4] = { name = "FISH", label = "Fish", classes = {} } }
local function loadConfig(cap, classes, types)
	return { cargoEntry = { capacity = cap, cargoTypeSet = { cargoClassesIncluded = classes or {}, cargoClassesExcluded = {},
		cargoTypesIncluded = types or {}, cargoTypesExcluded = {} } } }
end
local SHIP_MODELS = {
	[701] = { name = "vehicle/ship/votrans_universal.mdl", price = 2400000, vehicle = true, meta = {
		maintenance = { runningCosts = 400000, lifespan = 36525 },
		description = { name = "Votrans Universal" }, availability = { yearFrom = 1935, yearTo = 1990 },
		waterVehicle = { topSpeed = 9.1667, weightEmpty = 900, weightMaxPayload = 3000, availPower = 1000000 },
		transportVehicle = { carrier = 4, transportModes = { 12 }, loadSpeed = 20, compartments = {
			{ loadConfigs = { loadConfig(120, { "BULK" }), loadConfig(40, { "FLATBED", "GOODS" }) } } } } } },
	[702] = { name = "vehicle/ship/ps_trillium.mdl", price = 3000000, priceScale = 2, vehicle = true, meta = {
		maintenance = { runningCosts = 250000, runningCostScale = 3, lifespan = 36525 },
		description = { name = "PS Trillium" },
		waterVehicle = { topSpeed = 9.7222 },
		transportVehicle = { carrier = 4, transportModes = { 10 }, loadSpeed = 15, arrivalDelay = 2, departureDelay = 3,
			compartments = { { loadConfigs = { loadConfig(50, { "PASSENGERS" }) } } } } } },
	-- a ship whose compartments are empty, and one with a price the base's formula left negative
	[703] = { name = "vehicle/ship/empty_hull.mdl", price = -1, vehicle = true, meta = {
		waterVehicle = { topSpeed = 5 },
		transportVehicle = { carrier = 4, transportModes = { 12, 99 }, loadSpeed = 10, compartments = {} } } },
	[704] = { name = "vehicle/ship/fish_boat.mdl", price = 100000, vehicle = true, meta = {
		waterVehicle = { topSpeed = 8 },
		transportVehicle = { carrier = 4, transportModes = { 12 }, loadSpeed = 10, compartments = {
			{ loadConfigs = { loadConfig(10, {}, { "FISH" }) } }, { loadConfigs = {} } } } } },
	[101] = { name = "vehicle/bus/bus_1900.mdl", price = 30000, vehicle = true, meta = {
		landVehicle = { topSpeed = 10 }, transportVehicle = { carrier = 0, transportModes = { 3 }, loadSpeed = 4,
			compartments = { { loadConfigs = { loadConfig(30, { "PASSENGERS" }) } } } } } },
	[201] = { name = "vehicle/ship/no_metadata.mdl", noMetadata = true },
	[200] = { name = "building/ship_house.mdl", price = 1 },
}

local function modelsGame(extra)
	local opts = { models = SHIP_MODELS, cargoTypes = SHIP_CARGO }
	for k, v in pairs(extra or {}) do opts[k] = v end
	local g = vehicleGame(opts)
	return g
end

test("models: the store's price and running costs, speed, loadSpeed and capacity per cargo type, read only", function()
	local g = modelsGame()
	local balance = g.balance
	send(g, 701, "models", '{ grep = "ship" }')
	frames(g, FIRST)
	local a = final(g, 701)
	eq(a.ok, true, tostring(a.error))
	eq(a.total, 4, "the four ships with transportVehicle; not the model without metadata nor the building")
	local names = {}
	for _, m in ipairs(a.models) do names[#names + 1] = m.fileName end
	eq(table.concat(names, ","), "vehicle/ship/empty_hull.mdl,vehicle/ship/fish_boat.mdl,vehicle/ship/ps_trillium.mdl," ..
		"vehicle/ship/votrans_universal.mdl", "sorted by file name")
	local v = a.models[4]
	eq(v.id, 701); eq(v.name, "Votrans Universal"); eq(v.price, 2400000); eq(v.priceScale, nil)
	eq(v.runningCosts, 400000); eq(v.runningCostScale, nil); eq(v.lifespan, 36525)
	eq(v.carrier, "WATER"); eq(v.transportModes[1], "SMALL_SHIP"); eq(v.loadSpeed, 20)
	eq(v.topSpeed, 9.1667); eq(v.topSpeedKmh, 33); eq(v.yearFrom, 1935); eq(v.yearTo, 1990)
	eq(v.water.weightMaxPayload, 3000); eq(v.water.type, nil); eq(v.water.small, true, "SMALL_SHIP")
	eq(#v.compartments, 1); eq(#v.compartments[1].loadConfigs, 2)
	eq(v.compartments[1].loadConfigs[2].capacity, 40); eq(v.compartments[1].loadConfigs[2].cargoClassesIncluded[2], "GOODS")
	-- per cargo type as the store: BULK 120 (coal, grain), GOODS 40; total 120 (one compartment)
	eq(#v.capacities, 3); eq(v.capacities[1].cargo, "COAL"); eq(v.capacities[1].capacity, 120)
	eq(v.capacities[3].cargoType, 3); eq(v.capacities[3].capacity, 40); eq(v.totalCapacity, 120)
	local t = a.models[3]
	eq(t.priceScale, 2); eq(t.runningCostScale, 3); eq(t.water.small, false); eq(t.transportModes[1], "SHIP")
	eq(t.arrivalDelay, 2); eq(t.departureDelay, 3); eq(t.capacities[1].cargo, "PASSENGERS"); eq(t.topSpeedKmh, 35)
	local e = a.models[1]
	eq(#e.compartments, 0); eq(#e.capacities, 0); eq(e.totalCapacity, 0); eq(e.runningCosts, nil, "no maintenance: nil")
	eq(e.transportModes[2], "99", "an unknown mode shows as its value"); truthy(e.notes and e.notes[1]:find("negative"))
	local raw = answerText(g, 701)
	truthy(raw:find('"compartments":[]', 1, true), "an empty list reads as []")
	local f = a.models[2]
	eq(#f.compartments, 2); eq(#f.compartments[2].loadConfigs, 0); eq(f.capacities[1].cargo, "FISH"); eq(f.totalCapacity, 10)
	eq(g.balance, balance, "nothing bought")
	eq(#g.commands, 0, "no engine command sent")
end)

test("models: grep by shown name and id, carrier, limit; nothing matched is an empty list", function()
	local g = modelsGame()
	send(g, 710, "models", '{ grep = "trillium" }')
	frames(g, FIRST)
	eq(final(g, 710).models[1].id, 702)
	send(g, 711, "models", '{ grep = "votrans universal" }')
	frames(g, 20)
	eq(final(g, 711).models[1].id, 701, "the shown name")
	-- the models are walked once per load: one added later (none is, in a game) does not show up
	g.models[705] = { name = "vehicle/ship/trillium_late.mdl", price = 1, vehicle = true }
	send(g, 718, "models", '{ grep = "trillium" }')
	frames(g, 20)
	eq(final(g, 718).total, 1, "the index from the first call")
	send(g, 712, "models", '{ grep = "704" }')
	frames(g, 20)
	eq(final(g, 712).models[1].fileName, "vehicle/ship/fish_boat.mdl", "digits: the id")
	send(g, 713, "models", '{ carrier = "road" }')
	frames(g, 20)
	local a = final(g, 713)
	eq(a.total, 1); eq(a.models[1].id, 101); eq(a.models[1].topSpeed, 10, "a land vehicle's speed")
	send(g, 714, "models", '{ carrier = "water", limit = 2 }')
	frames(g, 20)
	a = final(g, 714)
	eq(a.total, 4); eq(#a.models, 2, "details only up to the limit")
	send(g, 715, "models", '{ grep = "zeppelin" }')
	frames(g, 20)
	a = final(g, 715)
	eq(a.ok, true); eq(a.total, 0)
	truthy(answerText(g, 715):find('"models":[]', 1, true), "nothing matched: []")
	send(g, 716, "models", '{ limit = 0 }')
	frames(g, 20)
	truthy(final(g, 716).error:find("limit must be"))
	g = newGame({ saves = SAVES, menu = true })
	frames(g, 2)
	send(g, 717, "models", "{  }")
	frames(g, FIRST)
	truthy(final(g, 717).error:find("needs a running game"))
end)

-- a ship on line 21 (Central -> Harbour), in port at Harbour (stop index 1), doors opened at game time 120000
local function shipFleet()
	local f = fleetOf(701, 5, 21)
	f.capacities = { 0, 120, 120, 40, 0 }
	f.live = { speed = 0, runningCost = 401000.5, maintenance = 0.9, loaded = { [1] = 60 }, fields = {
		state = 2, loadState = 3, userStopped = false, sellOnArrival = false, noPath = false, autoDeparture = true,
		doorsOpen = true, doorsTime = 120000, daysAtTerminal = 1, daysInDepot = 0, stopIndex = 1,
		arrivalStationTerminal = { station = 0, terminal = 0 }, arrivalStationTerminalLocked = true,
		lineStopDepartures = { 90000, 60000 }, lastLineStopDeparture = 90000, sectionTimes = { 28.5, 30 },
		visitedStops = { 0, 1 }, timeUntilNextScheduledDeparture = 0, timeUntilCloseDoors = 4.5, timeUntilDeparture = 6,
		timeUntilNextLoad = { 0, 0.5, 0, 0, 0 }, timeUntilNextUnload = { 0, 0, 0, 0, 0 },
		loadSpeedModifiers = { {}, { vehicleOverlength = 0, stockCompatibility = 1, vehicleCompatibility = 0.5,
			vehicleIncompatibility = 0 }, {}, { vehicleOverlength = 0.25 }, {} } } }
	return f
end

local OLD_VEHICLE_KEYS = "depot,depreciatedValue,entity,line,name,parts"

local function keysOf(t)
	local ks = {}
	for k in pairs(t) do ks[#ks + 1] = k end
	table.sort(ks)
	return table.concat(ks, ",")
end

test("vehicles --state: the engine's stop fields, cargo on board, running cost and balance, read only", function()
	local g = modelsGame({ fleet = { [601] = shipFleet(), [602] = fleetOf(101, 6) },
		lines = { [21] = { name = "Ships", stops = { { stationGroup = 41 }, { stationGroup = 42 } } } },
		stationGroups = { [41] = { name = "Central", stations = { { id = 411, terminals = 1 } } },
			[42] = { name = "Harbour", stations = { { id = 421, terminals = 1 } } } },
		vehicleBalances = { [601] = { { 1000, 500 }, { 125000, -300 }, { 129000, -200 } } } })
	g.gameTime = 130000
	local balance = g.balance
	send(g, 720, "vehicles", "{ state = true, since = 125000, entities = { 601 } }")
	frames(g, FIRST)
	local a = final(g, 720)
	eq(a.ok, true, tostring(a.error))
	eq(a.gameTime, 130000); eq(a.since, 125000); eq(a.total, 1); eq(#a.missing, 0)
	local v = a.vehicles[1]
	eq(v.entity, 601); eq(v.parts[1].modelId, 701, "the old fields are still there")
	local s = v.state
	eq(s.state, "AT_TERMINAL"); eq(s.loadState, "Loading"); eq(s.doorsOpen, true); eq(s.doorsTime, 120000)
	eq(s.sinceDoors, 10000); eq(s.stopIndex, 1); eq(s.stop.stationGroup, 42); eq(s.stop.name, "Harbour")
	eq(s.arrivalStationTerminal.terminal, 0); eq(s.arrivalStationTerminalLocked, true)
	eq(s.lineStopDepartures[1], 90000); eq(s.lineStopDepartures[2], 60000); eq(s.lastLineStopDeparture, 90000)
	eq(s.sectionTimes[1], 28.5); eq(s.visitedStops[2], 1)
	eq(s.timeUntilCloseDoors, 4.5); eq(s.timeUntilDeparture, 6); eq(s.timeUntilNextScheduledDeparture, 0)
	eq(#s.timeUntilNextLoad, 1); eq(s.timeUntilNextLoad[1].cargo, "COAL"); eq(s.timeUntilNextLoad[1].seconds, 0.5)
	eq(#s.timeUntilNextUnload, 0)
	eq(#s.loadSpeedModifiers, 3, "the cargo types it has room for"); eq(s.loadSpeedModifiers[1].cargo, "COAL")
	eq(s.loadSpeedModifiers[1].vehicleCompatibility, 0.5); eq(s.loadSpeedModifiers[1].totalPenalty, 1)
	eq(s.loadSpeedModifiers[3].cargo, "GOODS"); eq(s.loadSpeedModifiers[3].vehicleOverlength, 0.25)
	eq(s.loadSpeedModifiers[3].totalPenalty, 1.25)
	eq(#s.cargo, 3, "the cargo types it has room for"); eq(s.cargo[1].cargo, "COAL"); eq(s.cargo[1].capacity, 120)
	eq(s.cargo[1].count, 60); eq(s.cargo[3].cargo, "GOODS"); eq(s.cargo[3].count, 0)
	eq(s.runningCostPerYear, 401000.5); eq(s.maintenanceState, 0.9); eq(s.speed, 0)
	eq(s.balanceSince, -500); eq(s.balanceLastYear, 0, "the whole journal of the fake falls in the last year")
	eq(s.autoDeparture, true); eq(s.userStopped, false)
	eq(g.balance, balance); eq(#g.commands, 0, "no engine command sent")
	eq(g.outOfRange, nil, "no engine vector read past its end")
end)

test("vehicles --state: en route, short vectors are not read past their end, modifiers only at a terminal", function()
	local f = shipFleet()
	f.live.fields.state, f.live.fields.loadState, f.live.fields.doorsOpen = 1, 0, false
	f.live.fields.timeUntilNextLoad, f.live.fields.timeUntilNextUnload = { 0, 3 }, {}
	f.capacities = { 0, 120 }
	local g = modelsGame({ fleet = { [601] = f } })
	send(g, 725, "vehicles", "{ state = true, entities = { 601 } }")
	frames(g, FIRST)
	local s = final(g, 725).vehicles[1].state
	eq(s.state, "EN_ROUTE"); eq(s.loadState, "None"); eq(s.doorsOpen, false)
	eq(#s.loadSpeedModifiers, 0, "not at a terminal: not read"); eq(#s.timeUntilNextLoad, 1); eq(s.timeUntilNextLoad[1].seconds, 3)
	eq(#s.cargo, 1); eq(s.cargo[1].cargo, "COAL")
	eq(g.outOfRange, nil, "no engine vector read past its end")
end)

test("vehicles --state without entities: at most MAX_VEHICLE_ENTITIES per answer; total counts them all", function()
	local fleet = {}
	for i = 1, core.MAX_VEHICLE_ENTITIES + 3 do fleet[700 + i] = fleetOf(101, i) end
	local g = modelsGame({ fleet = fleet })
	send(g, 726, "vehicles", "{ state = true }")
	frames(g, FIRST)
	local a = final(g, 726)
	eq(a.total, core.MAX_VEHICLE_ENTITIES + 3); eq(#a.vehicles, core.MAX_VEHICLE_ENTITIES)
	send(g, 727, "vehicles", "{  }")
	frames(g, 20)
	eq(#final(g, 727).vehicles, core.MAX_VEHICLE_ENTITIES + 3, "without state the limit is as before (200)")
end)

test("vehicles: without the new args the answer keeps its old shape; gone and foreign vehicles are missing", function()
	local g = modelsGame({ fleet = { [601] = shipFleet(), [602] = fleetOf(101, 6) }, names = { [601] = "Ship 1", [602] = "Bus 2" } })
	send(g, 730, "vehicles", "{  }")
	frames(g, FIRST)
	local a = final(g, 730)
	eq(keysOf(a), "id,ok,total,vehicles", "no new top-level keys")
	for _, v in ipairs(a.vehicles) do eq(keysOf(v), OLD_VEHICLE_KEYS, "no new keys per vehicle") end
	eq(keysOf(a.vehicles[1].parts[1]), "fileName,maintenanceState,modelId,partPrice,purchaseTime")
	-- a vehicle that is gone (sold, replaced) and one that is not ours: listed under missing, not an error
	send(g, 731, "vehicles", "{ state = true, entities = { 602, 999 } }")
	frames(g, 20)
	a = final(g, 731)
	eq(a.ok, true); eq(a.total, 1); eq(a.missing[1], 999); eq(a.vehicles[1].entity, 602)
	local s = a.vehicles[1].state
	eq(s.state, nil, "no state fields in the fake: nil, not an error"); eq(s.stop, nil); eq(#s.lineStopDepartures, 0)
	eq(#s.cargo, 0, "no capacities: no cargo"); eq(s.runningCostPerYear, 1234.5)
	g.fleet[602] = nil
	send(g, 732, "vehicles", "{ state = true, entities = { 602 } }")
	frames(g, 20)
	a = final(g, 732)
	eq(a.ok, true); eq(a.total, 0); eq(a.missing[1], 602)
	truthy(answerText(g, 732):find('"vehicles":[]', 1, true))
	send(g, 733, "vehicles", "{ since = 5 }")
	frames(g, 20)
	truthy(final(g, 733).error:find("since goes with state"))
	send(g, 734, "vehicles", '{ line = "x" }')
	frames(g, 20)
	truthy(final(g, 734).error:find("line must be an entity id"), "the old refusal as it was")
end)

---------------------------------------------------------------------------------------------------------------------
-- persons: who is aboard a vehicle (or uses a line), their happiness and expected arrival, read only

-- ship 601 on line 21 (Central -> Harbour), en route; game time 130000. 9001 happy, due at 140000; 9002 unhappy
-- and past its expected arrival (125000), its components userdata as the engine's; 9003 aboard without a
-- SIM_PERSON; 9004 waits at Central for line 21 since 100000
local function personsGame(extra)
	local opts = { fleet = { [601] = shipFleet(), [602] = fleetOf(101, 6) },
		lines = { [21] = { name = "Ships", stops = { { stationGroup = 41 }, { stationGroup = 42 } } } },
		stationGroups = { [41] = { name = "Central", stations = { { id = 411, terminals = 1 } } },
			[42] = { name = "Harbour", stations = { { id = 421, terminals = 1 } } } },
		persons = {
			[9001] = { happiness = 0.8, destinations = { 11, 12, 13 }, targetOrAtEntity = 12,
				atVehicle = { vehicle = 601, part = 0, place = 3, expectedArrivalTime = 140000 },
				trip = { line = 21, lineStop0 = 0, lineStop1 = 1, vehicle = 601, roundTripCounter = 0 } },
			[9002] = { happiness = 0.4, good = false, userdata = true, destinations = { 11, -1, 14 }, targetOrAtEntity = 14,
				atVehicle = { vehicle = 601, part = 1, place = 0, expectedArrivalTime = 125000 },
				trip = { line = 21, lineStop0 = 0, lineStop1 = 1, vehicle = 601, roundTripCounter = 0 } },
			[9003] = { noSimPerson = true, atVehicle = { vehicle = 601, part = 0, place = 4, expectedArrivalTime = 150000 },
				trip = { line = 21, lineStop0 = 0, lineStop1 = 1, vehicle = 601 } },
			[9004] = { happiness = 0.6, atTerminal = { line = 21, lineStop0 = 0, lineStop1 = 1, arrivalTime = 100000, vehicle = -1 } },
		},
		quality = { vehicle = { [601] = { countTotal = 3, countBad = 1, averageQuality = 0.6, isVeryBad = false } },
			line = { [21] = { countTotal = 4, countBad = 1, averageQuality = 0.65, isVeryBad = false } },
			stop = { [21] = { [0] = { countTotal = 1, countBad = 0, averageQuality = 0.6, isVeryBad = false } } },
			group = { [41] = { countTotal = 7, countBad = 2, averageQuality = 0.55, isVeryBad = false } } } }
	for k, v in pairs(extra or {}) do opts[k] = v end
	local g = modelsGame(opts)
	g.gameTime = 130000
	return g
end

test("persons --vehicle: happiness, expected arrival against the game time, the engine's counts, read only", function()
	local g = personsGame()
	local balance = g.balance
	send(g, 740, "persons", "{ vehicle = 601 }")
	frames(g, FIRST)
	local a = final(g, 740)
	eq(a.ok, true, tostring(a.error))
	eq(a.gameTime, 130000); eq(a.vehicle, 601); eq(a.line, 21); eq(a.total, 3); eq(#a.persons, 3); eq(a.missing, nil)
	eq(a.unhappyBelow, 0.5)
	local p1, p2, p3 = a.persons[1], a.persons[2], a.persons[3]
	eq(p1.id, 9001); eq(p1.happiness, 0.8); eq(p1.good, true); eq(p1.where, "vehicle"); eq(p1.targetOrAtEntity, 12)
	eq(p1.destinations[2], 12); eq(p1.atVehicle.vehicle, 601); eq(p1.atVehicle.place, 3)
	eq(p1.atVehicle.expectedArrivalTime, 140000); eq(p1.untilArrival, 10000); eq(p1.late, false)
	eq(p1.trip.line, 21); eq(p1.trip.lineStop1, 1); eq(p1.atTerminal, nil)
	eq(p2.id, 9002); eq(p2.happiness, 0.4, "read through userdata components"); eq(p2.good, false)
	eq(p2.untilArrival, -5000); eq(p2.late, true); eq(p2.destinations[2], -1); eq(p2.destinations[3], 14)
	eq(p3.id, 9003); truthy(p3.error:find("no SIM_PERSON")); eq(p3.happiness, nil); eq(p3.atVehicle, nil)
	local sm = a.summary
	eq(sm.count, 3); eq(sm.withHappiness, 2); eq(sm.unhappy, 1); eq(sm.late, 1); eq(sm.of, 3); eq(sm.total, 3)
	truthy(math.abs(sm.meanHappiness - 0.6) < 1e-9); eq(sm.minHappiness, 0.4); eq(sm.maxHappiness, 0.8)
	local q = a.quality
	eq(q.vehicle.total, 3); eq(q.vehicle.bad, 1); eq(q.vehicle.averageQuality, 0.6); eq(q.vehicle.veryBad, false)
	eq(q.line.total, 4); eq(#q.stops, 2); eq(q.stops[1].stopIndex, 0); eq(q.stops[1].name, "Central")
	eq(q.stops[1].waiting.total, 1); eq(q.stops[1].stationGroupWaiting.bad, 2)
	eq(q.stops[2].stationGroup, 42); eq(q.stops[2].waiting.total, 0); eq(q.stops[2].waiting.averageQuality, nil, "nobody: none")
	eq(g.balance, balance); eq(#g.commands, 0, "no engine command sent"); eq(g.crashed, nil)
	eq(a.vehicleState.state, "AT_TERMINAL"); eq(a.vehicleState.stopIndex, 1); eq(a.vehicleState.speed, 0)
	send(g, 741, "status", "{  }")
	frames(g, 20)
	eq(final(g, 741).lastAction, nil, "read only: not recorded as using the game")
	eq(core.CHANGES_GAME.persons, nil); eq(core.COMMANDS.persons, true)
end)

test("persons: limit, a line's riders and waiting ones, nobody aboard, a vehicle gone or foreign", function()
	local g = personsGame()
	send(g, 745, "persons", "{ vehicle = 601, limit = 1 }")
	frames(g, FIRST)
	local a = final(g, 745)
	eq(a.total, 3); eq(#a.persons, 1); eq(a.summary.count, 1, "the summary is over the listed ones")
	eq(a.summary.of, 1, "and says so"); eq(a.summary.total, 3)
	send(g, 746, "persons", "{ line = 21 }")
	frames(g, 20)
	a = final(g, 746)
	eq(a.ok, true, tostring(a.error)); eq(a.vehicle, nil); eq(a.line, 21); eq(a.total, 4)
	local w = a.persons[4]
	eq(w.id, 9004); eq(w.where, "terminal"); eq(w.atTerminal.arrivalTime, 100000); eq(w.atTerminal.sinceArrival, 30000)
	eq(w.atTerminal.vehicle, nil, "-1: none"); eq(w.late, nil); eq(a.quality.vehicle, nil); eq(a.quality.line.total, 4)
	eq(w.atTerminal.late, false, "30 s of waiting: within the base's 2 min"); eq(a.summary.lateWaiting, 0)
	eq(a.vehicleState, nil)
	for i = 2, #a.persons do truthy(a.persons[i - 1].id < a.persons[i].id, "listed by id") end
	-- 602: the company's bus, nobody aboard and on no line
	send(g, 747, "persons", "{ vehicle = 602 }")
	frames(g, 20)
	a = final(g, 747)
	eq(a.ok, true); eq(a.total, 0); eq(a.line, nil); eq(a.missing, nil)
	truthy(answerText(g, 747):find('"persons":[]', 1, true), "nobody: []")
	eq(a.quality.vehicle.total, 0); eq(a.quality.vehicle.averageQuality, nil); eq(a.quality.stops, nil)
	eq(a.summary.count, 0); eq(a.summary.meanHappiness, nil)
	-- a vehicle that is gone, or no vehicle of the company: missing, not an error (a poll goes on)
	local mapCalls = g.mapCalls
	send(g, 748, "persons", "{ vehicle = 999 }")
	frames(g, 20)
	a = final(g, 748)
	eq(a.ok, true); eq(a.missing, true); eq(a.total, 0); eq(g.mapCalls, mapCalls, "no engine lookup for it")
	eq(a.summary.of, 0); eq(a.summary.total, 0)
	truthy(answerText(g, 748):find('"persons":[]', 1, true))
	send(g, 749, "persons", "{ line = 77 }")
	frames(g, 20)
	truthy(final(g, 749).error:find("not one of the company's lines"))
	eq(g.crashed, nil, "no engine lookup with an id it does not know")
end)

test("persons: a negative expected arrival is none: no late, no untilArrival", function()
	local g = personsGame()
	g.persons[9001].atVehicle.expectedArrivalTime = -1
	send(g, 765, "persons", "{ vehicle = 601 }")
	frames(g, FIRST)
	local p = final(g, 765).persons[1]
	eq(p.id, 9001); eq(p.atVehicle.expectedArrivalTime, -1); eq(p.late, nil); eq(p.untilArrival, nil)
	eq(final(g, 765).summary.late, 1, "only 9002, whose arrival is past")
end)

test("persons: long waits, a trip without SIM_PERSON_AT_VEHICLE, no game time, counts that fail", function()
	local g = personsGame()
	g.persons[9004].atTerminal.arrivalTime = 5000 -- 125 s waiting
	g.persons[9005] = { happiness = 0.7, trip = { line = 21, lineStop0 = 0, lineStop1 = 1, vehicle = 601 } }
	send(g, 770, "persons", "{ line = 21 }")
	frames(g, FIRST)
	local a = final(g, 770)
	local byId = {}
	for _, p in ipairs(a.persons) do byId[p.id] = p end
	eq(byId[9004].atTerminal.late, true); eq(a.summary.lateWaiting, 1)
	eq(byId[9005].where, "vehicle"); eq(byId[9005].atVehicle, nil); eq(byId[9005].late, nil); eq(byId[9005].trip.vehicle, 601)
	-- no game time: no untilArrival, no late, the rest as before
	local getComponent = api.engine.getComponent
	api.engine.getComponent = function(e, kind)
		if kind == "GAME_TIME" then error("no world") end
		return getComponent(e, kind)
	end
	api.engine.util.cargo.getCargoQualityDataForVehicle = function() error("boom") end
	send(g, 771, "persons", "{ vehicle = 601 }")
	frames(g, 20)
	a = final(g, 771)
	eq(a.ok, true, tostring(a.error)); eq(a.gameTime, nil); eq(a.persons[1].happiness, 0.8)
	eq(a.persons[1].atVehicle.expectedArrivalTime, 140000); eq(a.persons[1].untilArrival, nil); eq(a.persons[1].late, nil)
	eq(a.quality.vehicle, nil, "a count that fails is left out"); eq(a.quality.line.total, 4)
	eq(g.crashed, nil)
end)

test("persons: bad args refused; no persons map from the engine; the main menu", function()
	local g = personsGame()
	local bad = { { "{  }", "give the vehicle" }, { "{ vehicle = 601, line = 21 }", "not both" },
		{ '{ vehicle = "x" }', "vehicle must be an entity id" }, { "{ vehicle = -1 }", "vehicle must be" },
		{ "{ line = 1.5 }", "line must be" }, { "{ vehicle = 601, limit = 0 }", "limit must be" },
		{ "{ vehicle = 601, limit = 5000 }", "limit must be" } }
	for i, b in ipairs(bad) do
		send(g, 750 + i, "persons", b[1])
		frames(g, i == 1 and FIRST or 20)
		local a = final(g, 750 + i)
		truthy(a.ok ~= true and a.error and a.error:find(b[2], 1, true), b[1] .. " -> " .. tostring(a.error))
	end
	-- the engine's map call failing: the answer says so, the counts still come
	api.engine.system.simEntityAtVehicleSystem.getVehicle2Cargo2SimEntitesMap = function() error("boom") end
	send(g, 760, "persons", "{ vehicle = 601 }")
	frames(g, 20)
	local a = final(g, 760)
	eq(a.ok, true); eq(a.total, 0); truthy(a.personsError:find("getVehicle2Cargo2SimEntitesMap")); eq(a.quality.vehicle.total, 3)
	g = newGame({ saves = SAVES, menu = true })
	frames(g, 2)
	send(g, 761, "persons", "{ vehicle = 601 }")
	frames(g, FIRST)
	truthy(final(g, 761).error:find("needs a running game"))
end)

test("core: persons helpers (args, CargoQualityData as userdata, summary)", function()
	local a = core.personsArgs({ vehicle = "601" })
	eq(a.vehicle, 601); eq(a.limit, core.PERSONS_LIMIT); eq(a.line, nil)
	eq(core.personsArgs({ line = 21, limit = 7 }).limit, 7)
	for _, b in ipairs({ {}, { vehicle = 2 ^ 40 }, { vehicle = 1, line = 2 }, { line = "x" }, { vehicle = 1, limit = 1.5 } }) do
		truthy(not core.personsArgs(b))
	end
	truthy(not core.personsArgs(nil))
	eq(core.qualityOf(nil), nil)
	local u = newproxy(true)
	local t = { countTotal = 5, countBad = 2, averageQuality = 0.7, isVeryBad = true }
	getmetatable(u).__index = function(_, k) return t[k] end
	local q = core.qualityOf(u)
	eq(q.total, 5); eq(q.bad, 2); eq(q.averageQuality, 0.7); eq(q.veryBad, true)
	local locked = newproxy(true)
	getmetatable(locked).__index = function() error("locked") end
	eq(core.qualityOf(locked), nil, "nothing reads: nil, not an error")
	local s = core.personSummary(nil)
	eq(s.count, 0); eq(s.meanHappiness, nil)
	s = core.personSummary({ { happiness = 0 / 0 }, { happiness = 0.5, late = true }, { error = "x" } })
	eq(s.count, 3); eq(s.withHappiness, 1, "NaN is no happiness"); eq(s.unhappy, 0, "0.5 is not below 0.5"); eq(s.late, 1)
	eq(s.meanHappiness, 0.5)
	-- a cycle in a person does not trip the summary
	local cyc = { happiness = 0.2 }
	cyc.self = cyc
	eq(core.personSummary({ cyc }).unhappy, 1)
end)

print(string.format("\n%d passed, %d failed", passes, failures))
os.exit(failures == 0 and 0 or 1)
