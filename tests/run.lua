-- Offline tests for the remote probe.  luajit tests/run.lua
-- Pure logic (content/remote_core.lua) plus the real content/remote.script.lua over tests/fake_game.lua.
local root = (arg and arg[0] or "tests/run.lua"):match("^(.*)/tests/[^/]*$") or "."
package.path = root .. "/?.lua;" .. package.path

-- Every fake game gets a folder of its own (some hundred a run). They all go into one folder for this run, which is
-- removed at the end whatever happens: os.tmpname's /tmp is a small tmpfs, and once a run left ~500 folders behind
-- each time until /tmp ran out of inodes. The folder is under $REMOTE_PROBE_TEST_TMP, else $TMPDIR unless that is in
-- /tmp, else tests/.tmp (gitignored) -- /tmp only when REMOTE_PROBE_TEST_TMP asks for it. This file runs itself under
-- xpcall so a failing test or an error outside a test still cleans up. A run that was killed leaves its folder: the
-- next run removes such folders once they are a day old.
if not RP_TEST_RUN_DIR then
	local function shq(s)
		assert(not s:find("'", 1, true), "a quote in the test folder's path: " .. s)
		return "'" .. s .. "'"
	end
	-- 0 in Lua 5.1, true in LuaJIT built with 5.2 compatibility
	local function run(cmd) local r = os.execute(cmd); return r == 0 or r == true end
	local function env(name) local v = os.getenv(name); if v and v ~= "" then return v end end
	local tmpdir = env("TMPDIR")
	if tmpdir and (tmpdir == "/tmp" or tmpdir:find("^/tmp/")) then tmpdir = nil end
	local base = (env("REMOTE_PROBE_TEST_TMP") or tmpdir or (root .. "/tests/.tmp")):gsub("/+$", "")
	base = base .. "/remote_probe_tests"
	-- folders of killed runs (this suite's run-* and the Python suite's py-*), a day old so a running one is never hit
	os.execute("find " .. shq(base) .. " -mindepth 1 -maxdepth 1 -type d \\( -name 'run-*' -o -name 'py-*' \\)"
		.. " -mmin +1440 -exec rm -rf {} + 2>/dev/null")
	math.randomseed(os.time() + math.floor(os.clock() * 1e6))
	for _ = 1, 100 do
		local d = string.format("%s/run-%d-%06d", base, os.time(), math.random(0, 999999))
		-- mkdir without -p fails when it exists: the folder is this run's alone. base is made again each time, as
		-- another run that just finished may have removed it
		if run("mkdir -p " .. shq(base) .. " && mkdir " .. shq(d) .. " 2>/dev/null") then RP_TEST_RUN_DIR = d; break end
	end
	assert(RP_TEST_RUN_DIR, "cannot make a folder for this run under " .. base)
	local ok, err = xpcall(function() return dofile(root .. "/tests/run.lua") end, debug.traceback)
	local d = RP_TEST_RUN_DIR
	if d:match("/remote_probe_tests/run%-%d+%-%d+$") then os.execute("rm -rf " .. shq(d)) end
	os.execute("rmdir " .. shq(base) .. " 2>/dev/null") -- only when no other run is using it
	if not ok then print("ERROR outside a test\n" .. tostring(err)); os.exit(2) end
	os.exit(RP_TEST_FAILURES == 0 and 0 or 1)
end

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

-- a new folder under this run's folder (see the top): removed with it at the end
local tempCount = 0
local function tempDir()
	tempCount = tempCount + 1
	local d = RP_TEST_RUN_DIR .. "/g" .. tempCount
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
	eq(core.otherOwnerOk({ _otherOwnerOk = "bob" }), "bob")
	eq(core.otherOwnerOk({ _owner = "alice" }), nil)
	eq(core.otherOwnerOk({ _otherOwnerOk = true }), nil)
	eq(core.otherOwnerOk(nil), nil)
	eq(#core.otherOwnerOk({ _otherOwnerOk = string.rep("x", 200) }), 64)
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
		fireEvent = function(target, name, param)
			if R.failEvent == name then error("no listener took it") end
			R.events[#R.events + 1] = { name = name, param = param }
		end,
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

-- a game with the speed control on screen: each frame the guiUpdate script, then the recipe (render, step timer,
-- join), so window, event and tool requests run and their commands get answered. g.speedControlOff: not mounted
-- (no game on screen)
local function speedGame(opts)
	opts = opts or {}
	opts.saves = opts.saves or SAVES
	local g = newGame(opts)
	local exports = loadSpeedScript()
	local step = g.step
	g.speedControl = exports.SpeedControl
	g.step = function(dt)
		step(dt)
		if not g.speedControlOff then frame(exports.SpeedControl, opts.params or { gameCtx = {} }) end
	end
	return g
end

-- the requests waiting in the GUI save data for the speed control (opens), oldest first
local function opensNow() return ((fake.guiSave.hummer_remote_probe or {}).opens) or {} end

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
	publish({ label = "", opens = { { seq = 5, entity = 1234 } } }) -- what the loaded save still holds
	frame(exports.SpeedControl)
	frame(exports.SpeedControl)
	eq(#R.events, 0, "the old request is not opened")
	eq(fake.guiSave["hummer_remote_probe.open"].done[1].skipped, true, "and reported as skipped")
	publish({ label = "", opens = { { seq = 5, entity = 1234 }, { seq = 6, entity = 777 } } })
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
	publish({ label = "", buttons = false, opens = { { seq = 41, entity = 4242 } } })
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
	fake.guiSave.hummer_remote_probe = { label = "×16 old", open = { seq = 3, entity = 9 }, opens = { { seq = 4, entity = 9 } } }
	fake.guiSave["hummer_remote_probe.open"] = { done = { { seq = 4 } } }
	local g = newGame({ saves = SAVES })
	frames(g, 2)
	eq(fake.guiSave.hummer_remote_probe.label, "")
	eq(fake.guiSave.hummer_remote_probe.open, false, "the single slot of earlier versions is cleared too")
	eq(#fake.guiSave.hummer_remote_probe.opens, 0)
	eq(#fake.guiSave["hummer_remote_probe.open"].done, 0, "and the last game's reports")
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

test("window: by name or id, opened by the speed control, focuses the camera on demand, closes all", function()
	local g = speedGame({ saves = SAVES, entities = ENT, names = NAMES })
	frames(g, 2)
	send(g, 192, "window", '{ kind = "town", name = "emsworth", focus = true }')
	frames(g, FIRST)
	local a = answerText(g, 192) or ""
	truthy(a:find('"entity":11') and a:find('"name":"Emsworth"'), "exact name wins over the longer one: " .. a)
	truthy(a:find('"relayed":true'), "answered once the speed control opened it: " .. a)
	eq(R.events[#R.events].name, "selectEntity"); eq(R.events[#R.events].param.entity, 11)
	eq(g.focused, 11)
	local seq = final(g, 192).seq
	send(g, 193, "window", '{ entity = 31 }')
	frames(g, 20)
	eq(R.events[#R.events].param.entity, 31)
	truthy(final(g, 193).seq > seq, "a new request number")
	eq(#opensNow(), 0, "nothing left waiting")
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
	local g = speedGame({ saves = SAVES, entities = ent, names = names })
	frames(g, 2)
	send(g, 196, "window", '{ kind = "line", name = "bus 1", manager = true }')
	frames(g, FIRST)
	local a = answerText(g, 196) or ""
	truthy(a:find('"entity":21') and a:find('"manager":true') and a:find('"name":"Bus 1"'), "exact name wins: " .. a)
	eq(#R.events, 1, "not the line's own window too")
	eq(R.events[1].name, "openVehicleManager"); eq(R.events[1].param.openWithLineEntity, 21)
	local seq = final(g, 196).seq
	send(g, 197, "window", '{ entity = 22, manager = true, focus = true }')
	frames(g, 20)
	eq(R.events[2].param.openWithLineEntity, 22); truthy(final(g, 197).seq > seq, "a new request number"); eq(g.focused, 22)
	truthy((answerText(g, 197) or ""):find('"name":"Bus 10"'), answerText(g, 197))
	local fired = #R.events
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
	eq(#R.events, fired, "nothing opened for a refused one")
	-- without manager the same line opens its own window, as before
	send(g, 203, "window", '{ kind = "line", name = "bus 1" }')
	frames(g, 20)
	eq(#R.events, fired + 1); eq(R.events[fired + 1].name, "selectEntity"); eq(R.events[fired + 1].param.entity, 21)
	truthy(not (answerText(g, 203) or ""):find("manager", 1, true), answerText(g, 203))
end)

test("uiRequest: manager is a line id (a whole positive number) or left out", function()
	eq(core.uiRequest({ opens = { { seq = 1, manager = 21 } } }).opens[1].manager, 21)
	eq(core.openRequest({ seq = 1, manager = "21" }).manager, 21)
	for _, bad in ipairs({ "x", -1, 0, 1.5, math.huge, 0 / 0, {}, false }) do
		eq(core.openRequest({ seq = 1, manager = bad }).manager, nil, "manager " .. tostring(bad))
	end
	eq(core.openRequest({ seq = 1 }).manager, nil)
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
	local before = #opensNow()
	send(g, 210, "scriptEvent", '{ id = "hummer_age_of_mobility", name = "industry_upgrades.apply", param = { construction = 9, step = 3 } }')
	frames(g, FIRST)
	truthy((answerText(g, 210) or ""):find('"event":"industry_upgrades.apply"'), answerText(g, 210, "error"))
	local sent
	for _, c in ipairs(g.commands) do if c.kind == "scriptEvent" then sent = c end end
	truthy(sent, "a script event command")
	eq(sent.id, "hummer_age_of_mobility"); eq(sent.name, "industry_upgrades.apply"); eq(sent.param.construction, 9)
	eq(sent.src, "")
	eq(#opensNow(), before, "the speed control is not asked")
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
	local r = core.uiRequest({ opens = { { seq = 3, event = { name = "e", param = { a = 1 } }, tool = { module = "/m.tl", field = "F", close = true } } } }).opens[1]
	eq(r.event.name, "e"); eq(r.event.param.a, 1)
	eq(r.tool.module, "/m.tl"); eq(r.tool.field, "F"); eq(r.tool.close, true)
	r = core.openRequest({ seq = 4, event = { name = 7 }, tool = { module = "" } })
	eq(r.event, nil); eq(r.tool, nil); eq(r.seq, 4)
end)

test("openRequests: oldest first, entries without a request number left out; the old single slot is ignored", function()
	local list = core.uiRequest({ opens = { { seq = 9, entity = 2 }, { entity = 3 }, "x", { seq = 7, event = { name = "a" } } },
		open = { seq = 99, entity = 5 } }).opens
	eq(#list, 2); eq(list[1].seq, 7); eq(list[1].event.name, "a"); eq(list[2].seq, 9)
	eq(#core.uiRequest(nil).opens, 0); eq(#core.uiRequest({ opens = "no" }).opens, 0)
	local rep = core.openReports({ done = { { seq = 7 }, { seq = 9, error = "boom" }, { seq = 11, skipped = true }, { error = "x" }, 3 } })
	truthy(rep[7] and rep[7].error == nil and not rep[7].skipped)
	eq(rep[9].error, "boom"); eq(rep[11].skipped, true); eq(rep[8], nil)
	eq(next(core.openReports(nil)), nil); eq(next(core.openReports({ done = 1 })), nil)
end)

test("event and tool: handed to the speed control through the GUI save data, answered once relayed", function()
	local g = speedGame({ saves = SAVES })
	frames(g, 2)
	g.speedControlOff = true -- held back, to see the request wait
	send(g, 200, "event", '{ name = "example_window.show", param = { welcome = true } }')
	frames(g, FIRST)
	eq(answerText(g, 200), nil, "no answer before the speed control fired it")
	local open = opensNow()[1]
	eq(open.event.name, "example_window.show"); eq(open.event.param.welcome, true)
	g.speedControlOff = false
	frames(g, 5)
	local a = final(g, 200)
	eq(a.ok, true); eq(a.event, "example_window.show"); eq(a.relayed, true); eq(a.seq, open.seq)
	truthy(a.relayedInSec > 0, "it waited")
	eq(R.events[#R.events].name, "example_window.show")
	local seq = open.seq
	package.preload["/gui/evq_tool.tl"] = function() return { "T" } end
	send(g, 201, "tool", '{ module = "/gui/evq_tool.tl" }')
	frames(g, 20)
	package.preload["/gui/evq_tool.tl"], package.loaded["/gui/evq_tool.tl"] = nil, nil
	local b = final(g, 201)
	eq(b.ok, false, "the speed control's params here have no tool stack")
	eq(b.relayed, true); truthy(b.error:find("no gameCtx.toolStack"), b.error); truthy(b.seq > seq, "a new request")
	send(g, 202, "tool", '{ name = "nope" }')
	frames(g, 20)
	truthy((answerText(g, 202, "error") or ""):find("unknown tool"))
	send(g, 203, "event", '{ name = "x", param = 3 }')
	frames(g, 20)
	truthy((answerText(g, 203, "error") or ""):find("must be a table"))
	fake.guiSave.hummer_remote_probe = nil
end)

-- 2026-11-22 18:30 JST: two events sent in the same second, and only the second reached the other mod (one slot,
-- written over before the speed control read it)
test("event: two sent before the speed control's next read both go, in the order sent, each answered with the relay mark", function()
	local g = speedGame({ saves = SAVES })
	frames(g, 2)
	send(g, 300, "status") -- any command first: the idle poll (2 s) would otherwise space the two apart
	frames(g, FIRST)
	local fired = #R.events
	-- the guiUpdate script takes one command per poll; two handlers run in one frame here, as two polls before
	-- the speed control's next read would leave it
	g.speedControlOff = true
	send(g, 301, "event", '{ name = "aom_window.hints_set", param = { on = false } }')
	frames(g, 10)
	send(g, 302, "event", '{ name = "aom_window.hint_reset", param = { hint = "all" } }')
	frames(g, 10)
	eq(#opensNow(), 2, "both wait in the queue")
	eq(answerText(g, 301), nil); eq(answerText(g, 302), nil)
	g.speedControlOff = false
	frames(g, 1)
	eq(#R.events, fired + 1, "one per read of the speed control")
	frames(g, 5)
	eq(#R.events, fired + 2, "then the other")
	eq(R.events[fired + 1].name, "aom_window.hints_set"); eq(R.events[fired + 1].param.on, false)
	eq(R.events[fired + 2].name, "aom_window.hint_reset"); eq(R.events[fired + 2].param.hint, "all")
	local a, na = final(g, 301)
	local b, nb = final(g, 302)
	eq(na, 1); eq(nb, 1)
	eq(a.ok, true); eq(a.relayed, true); eq(a.event, "aom_window.hints_set")
	eq(b.ok, true); eq(b.relayed, true); eq(b.event, "aom_window.hint_reset")
	truthy(a.seq < b.seq, "numbered in the order sent")
	eq(#opensNow(), 0, "the queue is empty again")
	frames(g, 30)
	eq(#R.events, fired + 2, "each fired once")
	fake.guiSave.hummer_remote_probe = nil
end)

test("speed control: two requests in one read both fire, oldest first, one per read", function()
	newGame({ saves = SAVES }) -- the game API of a running game
	local exports = loadSpeedScript()
	publish({ label = "", opens = {} })
	frame(exports.SpeedControl)
	publish({ label = "", opens = { { seq = 11, event = { name = "a" } }, { seq = 12, event = { name = "b" } } } })
	frame(exports.SpeedControl)
	frame(exports.SpeedControl)
	frame(exports.SpeedControl)
	eq(#R.events, 2); eq(R.events[1].name, "a"); eq(R.events[2].name, "b")
	local done = fake.guiSave["hummer_remote_probe.open"].done
	eq(done[#done - 1].seq, 11); eq(done[#done].seq, 12); eq(done[#done].error, nil)
	-- one the speed control finds in an order other than sent still goes oldest first
	publish({ label = "", opens = { { seq = 14, event = { name = "d" } }, { seq = 13, event = { name = "c" } } } })
	frame(exports.SpeedControl)
	frame(exports.SpeedControl)
	eq(R.events[3].name, "c"); eq(R.events[4].name, "d")
	publish(nil)
end)

test("event: not relayed when no speed control takes it; an error answer, and it never fires later", function()
	local g = speedGame({ saves = SAVES })
	frames(g, 2)
	g.speedControlOff = true
	send(g, 310, "event", '{ name = "late.one" }')
	frames(g, FIRST)
	eq(answerText(g, 310), nil)
	frames(g, 30 * (core.OPEN_RELAY_SEC + 1))
	local a, n = final(g, 310)
	eq(n, 1); eq(a.ok, false); eq(a.relayed, false)
	truthy(a.error:find("did not take it"), a.error)
	eq(#opensNow(), 0, "dropped from the queue")
	g.speedControlOff = false
	local fired = #R.events
	frames(g, 10)
	eq(#R.events, fired, "not fired after its answer said it was not")
	fake.guiSave.hummer_remote_probe = nil
end)

test("event: one the speed control fails to fire is an error answer with the reason, relayed", function()
	local g = speedGame({ saves = SAVES })
	frames(g, 2)
	R.failEvent = "broken.one"
	send(g, 320, "event", '{ name = "broken.one" }')
	frames(g, FIRST)
	R.failEvent = nil
	local a = final(g, 320)
	eq(a.ok, false); eq(a.relayed, true)
	truthy(a.error:find("relayed, but event broken.one failed"), a.error)
	fake.guiSave.hummer_remote_probe = nil
end)

test("event: a request the speed control finds at its first read is skipped as old, and said so", function()
	local g = speedGame({ saves = SAVES })
	g.speedControlOff = true
	frames(g, 2)
	send(g, 330, "event", '{ name = "before.mount" }')
	frames(g, FIRST)
	eq(#opensNow(), 1)
	g.speedControlOff = false
	frames(g, 5)
	local a = final(g, 330)
	eq(a.ok, false); eq(a.relayed, false); truthy(a.error:find("took it as old"), a.error)
	fake.guiSave.hummer_remote_probe = nil
end)

test("event: a speed control mounted again (new refs) still runs what waits; a run one is not re-reported skipped", function()
	local g = speedGame({ saves = SAVES })
	frames(g, 2)
	g.speedControlOff = true
	send(g, 340, "event", '{ name = "after.remount" }')
	frames(g, FIRST)
	R.hooks = {} -- mounted again: every ref and state starts empty
	g.speedControlOff = false
	frames(g, 5)
	local a = final(g, 340)
	eq(a.ok, true, tostring(a.error)); eq(a.relayed, true)
	eq(R.events[#R.events].name, "after.remount")
	local rep = core.openReports({ done = { { seq = 5 }, { seq = 5, skipped = true } } })
	eq(rep[5].skipped, false, "the first report on a seq stands")
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
	publish({ label = "", opens = { { seq = 1 } } })
	frame(exports.SpeedControl, params)
	publish({ label = "", opens = { { seq = 2, event = { name = "example_window.show", param = { welcome = true } } } } })
	frame(exports.SpeedControl, params)
	eq(#R.events, 1); eq(R.events[1].name, "example_window.show"); eq(R.events[1].param.welcome, true)
	publish({ label = "", opens = { { seq = 3, tool = { module = "/gui/music_player/music_player.tl" } } } })
	frame(exports.SpeedControl, params)
	eq(#pushed, 1); eq(pushed[1][1], "push"); eq(pushed[1][2], music); eq(pushed[1][3].gameCtx, gameCtx)
	publish({ label = "", opens = { { seq = 4, tool = { module = "/gui/game_bar/game_bar_widgets.tl", field = "CalendarEditorTool", close = true } } } })
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
	publish({ label = "", opens = { { seq = 1, manager = 5 } } })
	frame(exports.SpeedControl, {})
	eq(#R.events, 0, "the request left in the save is not opened")
	publish({ label = "", opens = { { seq = 2, manager = 21 } } })
	frame(exports.SpeedControl, {})
	eq(#R.events, 1)
	eq(R.events[1].name, "openVehicleManager"); eq(R.events[1].param.openWithLineEntity, 21)
	frame(exports.SpeedControl, {})
	eq(#R.events, 1, "opened once")
	publish({ label = "", opens = { { seq = 3, manager = 22, entity = 9 } } })
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
		publish({ label = "", opens = { { seq = 1 } } })
		frame(exports.SpeedControl, {})
		publish({ label = "", opens = { { seq = 2, tool = { module = "/gui/music_player/music_player.tl" } } } })
		package.preload["/gui/music_player/music_player.tl"] = function() return { "M" } end
		frame(exports.SpeedControl, {}) -- no gameCtx in the params
		publish({ label = "", opens = { { seq = 3, tool = { module = "/gui/music_player/music_player.tl" } } } })
		frame(exports.SpeedControl, {})
		publish({ label = "", opens = { { seq = 4, tool = { module = "/gui/no_tool.tl" } } } })
		frame(exports.SpeedControl, { gameCtx = {} })
		publish({ label = "x", opens = { { seq = 5, entity = 9 } } })
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
	eq(v.line, 21, "sent to the line (by the probe, after the base bought it)")
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

-- 2026-11-22: a ship bought with --line stayed in its shipyard, and the answer was a 60 s timeout with setLine
-- pending: the base's own send to the line logs a refusal and nothing more. The gui way now gives the base no
-- line and sends the vehicle itself, with a callback that asks getFailedPathReason.
local function setLineCmds(g)
	local out = {}
	for _, c in ipairs(g.commands) do if c.kind == "setLine" then out[#out + 1] = c end end
	return out
end

test("buy --line via gui: the probe's own send to the line, once per vehicle, first stop 0 (bus and train)", function()
	for _, case in ipairs({ { model = "bus_1900", depot = 301 }, { model = "bus_1900", depot = 302, count = 2 } }) do
		local g = vehicleGame({ callbackFrames = 5, depots = { [301] = { name = "Bus depot", modes = { "BUS" } },
			[302] = { name = "Train depot", modes = { "TRAIN" } } } })
		send(g, 470, "buy", string.format('{ model = %q, depot = %d, line = 21, count = %d }', case.model, case.depot, case.count or 1))
		frames(g, FIRST)
		local a, n = final(g, 470)
		eq(n, 1)
		eq(a.ok, true, tostring(a.error))
		local cmds = setLineCmds(g)
		eq(#cmds, case.count or 1, "one send per vehicle, none by the base")
		for i, c in ipairs(cmds) do eq(c.line, 21); eq(c.stop, 0); eq(c.vehicle, a.vehicles[i].entity) end
		for i, v in ipairs(a.vehicles) do
			eq(v.line, 21); eq(a.setLine[i].ok, true); eq(a.setLine[i].reason, nil); eq(a.setLine[i].pending, nil)
		end
		eq(g.failedPathAsked, nil, "no reason asked for a vehicle that went")
	end
end)

test("buy --line via gui refused (NoSmallShip): answered at once with the reason, the base's text and where", function()
	local g = vehicleGame({ callbackFrames = 5, depots = { [303] = { name = "Shipyard", modes = { "SHIP" } } },
		setLineRefused = { reason = "NoSmallShip", pos = { x = 10, y = 20, z = 3 } } })
	send(g, 471, "buy", '{ model = "bus_1900", depot = 303, line = 23, count = 2 }')
	frames(g, FIRST) -- under 3 s of the 60 s deadline
	local a, n = final(g, 471)
	eq(n, 1, "answered before the deadline")
	eq(a.ok, false)
	eq(tostring(a.error):find("no result in", 1, true), nil, tostring(a.error))
	truthy(tostring(a.error):find("NoSmallShip", 1, true), tostring(a.error))
	eq(#a.vehicles, 2, "both vehicles bought, though on no line"); eq(#a.vehicleIds, 2)
	for i, v in ipairs(a.vehicles) do
		eq(v.line, -1)
		local s = a.setLine[i]
		eq(s.entity, v.entity); eq(s.ok, false); eq(s.pending, nil)
		eq(s.reason, "NoSmallShip"); eq(s.message, "No path for big ships.")
		eq(s.position.x, 10); eq(s.position.y, 20); eq(s.position.z, 3)
	end
	eq(g.failedPathAsked[2], 23); eq(g.failedPathAsked[3], true, "fullLine, as the line manager asks")
end)

test("duplicate --line via gui refused: the reason comes back as for a buy; a reason not in the list as text", function()
	local g = vehicleGame({ callbackFrames = 5, fleet = { [601] = fleetOf(101, 5) }, setLineRefused = { reason = "NoPath" } })
	send(g, 472, "duplicate", '{ vehicle = 601, depot = 301, line = 21 }')
	frames(g, FIRST)
	local a = final(g, 472)
	eq(a.ok, false)
	eq(a.setLine[1].reason, "NoPath"); eq(a.setLine[1].message, nil, "the base has no text of its own for NoPath")
	eq(a.setLine[1].position, nil)
	-- an engine value not in Failure.Reason as the probe knows it
	local vc = dofile(root .. "/content/vehicle_configs.lua")
	eq(vc.failureName(api.type.Failure.Reason.NoSmallAircraft), "NoSmallAircraft")
	eq(vc.failureName(newproxy(false)):find("userdata", 1, true) ~= nil, true)
	eq(vc.failureName(nil), nil)
end)

test("buy --line via gui: getFailedPathReason raising, or the send itself raising, still answers once", function()
	local g = vehicleGame({ callbackFrames = 5, setLineRefused = { reason = "NoRoad" }, failedPathRaises = true })
	send(g, 473, "buy", '{ model = "bus_1900", depot = 301, line = 21 }')
	frames(g, FIRST)
	local a, n = final(g, 473)
	eq(n, 1); eq(a.ok, false)
	eq(a.setLine[1].ok, false); eq(a.setLine[1].reason, nil)
	truthy(tostring(a.setLine[1].reasonError):find("no failed path", 1, true), tostring(a.setLine[1].reasonError))
	-- the send raising (vehicle_configs.sendToLine on its own)
	local vc = dofile(root .. "/content/vehicle_configs.lua")
	local real = api.cmd.sendCommand
	api.cmd.sendCommand = function() error("no command queue") end
	local report = {}
	local ok = pcall(vc.sendToLine, report, 5001, 21)
	api.cmd.sendCommand = real
	eq(ok, true)
	eq(report.setLine[1].ok, false); truthy(report.setLine[1].sendError:find("no command queue", 1, true))
end)

test("buy --line via gui: no answer to the send ends in the timeout, setLine pending", function()
	local g = vehicleGame({ lostSetLine = true })
	send(g, 474, "buy", '{ model = "bus_1900", depot = 301, line = 21 }')
	frames(g, 75, 1)
	local a, n = final(g, 474)
	eq(n, 1); eq(a.ok, false)
	truthy(tostring(a.error):find("no result in 60 s", 1, true), tostring(a.error))
	eq(a.setLine[1].pending, true); eq(a.setLine[1].ok, false); eq(a.setLine[1].reason, nil)
	eq(#setLineCmds(g), 1)
end)

test("buy --line via cmd refused: as before (its own failure, no reason asked)", function()
	local g = vehicleGame({ callbackFrames = 5, setLineRefused = { reason = "NoSmallShip" } })
	send(g, 475, "buy", '{ model = "bus_1900", depot = 301, line = 21, via = "cmd" }')
	frames(g, FIRST)
	local a = final(g, 475)
	eq(a.ok, false)
	truthy(tostring(a.error):find("could not send vehicle", 1, true), tostring(a.error))
	eq(a.setLine[1].ok, false); eq(a.setLine[1].reason, nil)
	eq(g.failedPathAsked, nil)
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
		{ { action = "update", line = 21 }, "give stops, name, cargo, terminals, load modes or force unload" },
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

test("lines --problems: each stop's problems as the line manager reads them, platform modes, the mode union", function()
	local g = portWorld({ lines = { [23] = { name = "Ship 1", stops = { { stationGroup = 47, station = 0, terminal = 2 },
			{ stationGroup = 48, station = 0, terminal = 1 } } },
		[24] = { name = "Ship 2", stops = { { stationGroup = 47, station = 0, terminal = 2 }, { stationGroup = 48, station = 0, terminal = 0 } } } },
		lineProblems = { [23] = { { { noPath = true, noPathLocation = { edgeIndex = 4, node = 9001,
			nodePosition = { x = 1, y = 2, z = 0 }, okModes = { "SMALL_SHIP" }, relaxedModes = {}, allowedModes = { "SHIP", "SMALL_SHIP" } } },
			{ incompatibleStop = true } } } },
		lineModes = { [23] = { "SMALL_SHIP", "SHIP" } } })
	send(g, 765, "lines", "{ problems = true, line = 23 }")
	frames(g, FIRST)
	local a = final(g, 765)
	eq(a.ok, true, tostring(a.error))
	eq(#a.lines, 1); eq(a.lines[1].id, 23)
	local p = a.lines[1].problems
	eq(p.count, 2); eq(p.readError, nil)
	eq(table.concat(p.transportModesUnion, ","), "SHIP,SMALL_SHIP")
	local s1, s2 = p.segments[1][1], p.segments[1][2]
	eq(s1.noPath, true); eq(s1.problem, true); eq(s1.incompatibleStop, false)
	eq(s1.noPathLocation.edgeIndex, 4); eq(s1.noPathLocation.node, 9001); eq(s1.noPathLocation.nodePosition.y, 2)
	eq(table.concat(s1.noPathLocation.okModes, ","), "SMALL_SHIP")
	eq(#s1.noPathLocation.relaxedModes, 0)
	eq(table.concat(s1.noPathLocation.allowedModes, ","), "SHIP,SMALL_SHIP")
	eq(s2.incompatibleStop, true); eq(s2.noPathLocation, nil)
	eq(table.concat(a.lines[1].stops[1].transportModes, ","), "SHIP,SMALL_SHIP", "a large pier")
	eq(a.lines[1].stops[2].transportModes, nil, "none to read")
	-- without --problems: as before, no problems and no modes
	send(g, 766, "lines", "{  }")
	frames(g, 10)
	local b = final(g, 766)
	eq(#b.lines, 2); eq(b.lines[1].problems, nil); eq(b.lines[1].stops[1].transportModes, nil)
	-- a line without problems; a line that is not the company's; a bad id
	send(g, 767, "lines", "{ problems = true, line = 24 }")
	frames(g, 10)
	local c = final(g, 767)
	eq(c.lines[1].problems.count, 0); eq(#c.lines[1].problems.segments, 0); eq(#c.lines[1].problems.transportModesUnion, 0)
	send(g, 768, "lines", "{ problems = true, line = 999 }")
	frames(g, 10)
	local d = final(g, 768)
	eq(d.ok, false); truthy(tostring(d.error):find("no line 999", 1, true), tostring(d.error))
	send(g, 769, "lines", '{ line = "x" }')
	frames(g, 10)
	eq(final(g, 769).ok, false)
	eq(g.crashed, nil, "the engine was asked only for the company's lines")
end)

test("lines --problems: an engine call that raises is reported, the rest still read", function()
	local g = portWorld({ lines = { [23] = { name = "Ship 1", stops = { { stationGroup = 47, station = 0, terminal = 2 },
		{ stationGroup = 48, station = 0, terminal = 1 } } } } })
	local real = api.engine.util.line.getDetailedLineProblems
	api.engine.util.line.getDetailedLineProblems = function() error("unreadable") end
	send(g, 770, "lines", "{ problems = true }")
	frames(g, FIRST)
	local a = final(g, 770)
	api.engine.util.line.getDetailedLineProblems = real
	eq(a.ok, true, tostring(a.error))
	truthy(a.lines[1].problems.readError:find("unreadable", 1, true))
	eq(table.concat(a.lines[1].stops[1].transportModes, ","), "SHIP,SMALL_SHIP")
end)

-- stations --catchment: Port A (47, station 471) reaches three buildings of Town 1 (two residential, one
-- commercial, which also takes cargo through its stock list), one of Town 2, the mine (its own id for workers,
-- its stock list for cargo) and an entity the probe cannot place
local function catchmentWorld()
	return portWorld({
		names = { [801] = "Town 1", [802] = "Town 2" },
		industries = { [51] = { name = "Coal mine", capacity = 20, stockList = 5101 } },
		townBuildings = { [7001] = { town = 801, kind = "RESIDENTIAL", capacity = 10 },
			[7002] = { town = 801, kind = "RESIDENTIAL", capacity = 6, personCapacity = 7102 },
			[7003] = { town = 801, kind = "COMMERCIAL", capacity = 4, stockList = 7203 },
			[7004] = { town = 802, kind = "INDUSTRIAL", capacity = 8 } },
		catchables = { [471] = { passengers = { 7001, 7102, 7003, 7004, 51, 7001 }, cargo = { 5101, 7203, 9999 } },
			[481] = { passengers = { 7004 } } },
	})
end

test("stations --catchment: town buildings per town and kind, industries, for passengers and cargo", function()
	local g = catchmentWorld()
	send(g, 775, "stations", "{ catchment = 47 }")
	frames(g, FIRST)
	local a = final(g, 775)
	eq(a.ok, true, tostring(a.error))
	local c = a.catchment
	eq(c.id, 47); eq(c.stationGroup, 47); eq(c.name, "Port A"); eq(c.stations[1], 471)
	local p = c.passengers
	eq(p.entities, 5, "each entity once")
	eq(#p.towns, 2)
	local t1, t2 = p.towns[1], p.towns[2]
	eq(t1.name, "Town 1"); eq(t1.town, 801); eq(t1.buildings, 3); eq(t1.residential, 2); eq(t1.commercial, 1); eq(t1.industrial, 0)
	eq(t1.capacity.residential, 16, "a building found through its PersonCapacity entity counts too"); eq(t1.capacity.commercial, 4)
	eq(t2.name, "Town 2"); eq(t2.industrial, 1); eq(t2.capacity.industrial, 8)
	eq(#p.industries, 1); eq(p.industries[1].id, 51); eq(p.industries[1].name, "Coal mine")
	eq(#p.other, 0)
	local k = c.cargo
	eq(k.entities, 3)
	eq(#k.industries, 1); eq(k.industries[1].id, 51, "the mine by its stock list")
	eq(#k.towns, 1); eq(k.towns[1].commercial, 1, "the shop by its stock list")
	eq(#k.other, 1); eq(k.other[1], 9999)
	-- a station alone: its own catchment, and its group named
	send(g, 776, "stations", "{ catchment = 481 }")
	frames(g, 10)
	local b = final(g, 776)
	eq(b.ok, true, tostring(b.error))
	eq(b.catchment.stationGroup, 48); eq(b.catchment.passengers.towns[1].name, "Town 2")
	eq(b.catchment.cargo.entities, 0); eq(#b.catchment.cargo.towns, 0)
	eq(g.crashed, nil, "only stations the engine has were asked about")
end)

test("stations --catchment: an id that is no station or group, or no id, is refused before the engine is asked", function()
	local g = catchmentWorld()
	send(g, 777, "stations", "{ catchment = 12345 }")
	frames(g, FIRST)
	local a = final(g, 777)
	eq(a.ok, false); truthy(tostring(a.error):find("no station group or station", 1, true), tostring(a.error))
	send(g, 778, "stations", '{ catchment = "47" }')
	frames(g, 10)
	eq(final(g, 778).ok, false)
	eq(g.crashed, nil)
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

-- forceUnload per stop (Line.Stop.stopConfig.forceUnload): set, cleared and read back; a count that does not match
-- the line, another company's line and a builder that drops it are refused
local function shipLine(extra)
	local w = { lines = { [23] = { name = "Ship 1", stops = {
		{ stationGroup = 47, station = 0, terminal = 1, forceUnload = false, loads = { [1] = true }, waypoints = { { tag = 1 } } },
		{ stationGroup = 49, station = 0, terminal = 1, forceUnload = false } } } },
		fleet = { [601] = fleetOf(101, 5, 23) } }
	for k, v in pairs(extra or {}) do w[k] = v end
	return portWorld(w)
end

test("core.lineArgs / lineRequests: forceUnload one 0/1 per stop, never one for all; malformed refused", function()
	local a = core.lineArgs({ action = "update", line = 23, forceUnload = { 0, true, "1", false } })
	eq(a.forceUnload[1], false); eq(a.forceUnload[2], true); eq(a.forceUnload[3], true); eq(a.forceUnload[4], false)
	eq(core.lineArgs({ action = "create", stops = { 47, 48 }, forceUnload = { 1, 0 } }).forceUnload[1], true)
	eq(core.lineArgs({ action = "update", line = 23, name = "x" }).forceUnload, nil, "not given: nil, as before")
	for _, bad in ipairs({
		{ { action = "update", line = 23, forceUnload = true }, "forceUnload must be a list" },
		{ { action = "update", line = 23, forceUnload = 1 }, "forceUnload must be a list" },
		{ { action = "update", line = 23, forceUnload = {} }, "forceUnload must be a list" },
		{ { action = "update", line = 23, forceUnload = { a = 1 } }, "forceUnload must be a list" },
		{ { action = "update", line = 23, forceUnload = { 0, 2 } }, "force unload 2 must be 0 or 1" },
		{ { action = "update", line = 23, forceUnload = { 0, "yes" } }, "force unload 2 must be 0 or 1" },
		{ { action = "update", line = 23, forceUnload = { newproxy(true), 0 } }, "got a userdata" },
		{ { action = "create", stops = { 47, 48 }, forceUnload = { 1 } }, "one force unload value for every stop (2 stops, 1 values)" },
		{ { action = "create", stops = { 47, 48 }, forceUnload = { 1, 0, 1 } }, "(2 stops, 3 values)" },
		{ { action = "delete", line = 23, forceUnload = { 0, 1 } }, "delete takes no" },
	}) do
		local ok, err = core.lineArgs(bad[1])
		eq(ok, nil, bad[2])
		truthy(tostring(err):find(bad[2], 1, true), tostring(err) .. " / " .. bad[2])
	end
	local list = core.lineRequests({
		{ id = 1, kind = "update", line = 23, forceUnload = { false, true } },
		{ id = 2, kind = "update", line = 23, forceUnload = { 0, 1 } },
		{ id = 3, kind = "create", stops = { { stationGroup = 47 }, { stationGroup = 48 } }, forceUnload = { true } },
		{ id = 4, kind = "update", line = 23, forceUnload = {} },
		{ id = 5, kind = "update", line = 23 },
	})
	eq(#list, 2, "the malformed ones are left out whole"); eq(list[1].id, 1); eq(list[1].forceUnload[2], true)
	eq(list[1].forceUnload[1], false); eq(list[2].id, 5); eq(list[2].forceUnload, nil)
end)

test("line update --force-unload: set and cleared per stop, the rest of the stop kept, lines reads it (gui and cmd)", function()
	for _, via in ipairs({ "gui", "cmd" }) do
		local g = shipLine()
		send(g, 770, "line", string.format('{ action = "update", line = 23, forceUnload = { false, true }, via = %q }', via))
		frames(g, FIRST)
		local a, n = final(g, 770)
		eq(n, 1); eq(a.ok, true, via .. " " .. tostring(a.error))
		eq(a.stops[1].forceUnload, false, via); eq(a.stops[2].forceUnload, true, via)
		eq(a.before.stops[2].forceUnload, false, via .. ": before")
		local held = g.lines[23].stops
		eq(held[1].stopConfig.forceUnload, false, via .. ": what the engine holds")
		eq(held[2].stopConfig.forceUnload, true, via)
		eq(held[1].stopConfig.load[2], true, via .. ": the stop's loads are kept"); eq(held[2].stopConfig.load[2], false, via)
		eq(held[1].terminal, 1, via .. ": the platform kept"); eq(held[2].loadMode, 0, via)
		eq(g.lines[23].customFilters, false, via .. ": the cargo filter flag is not turned on by this alone")
		if via == "cmd" then eq(#held[1].waypoints, 1, "the line's own stops keep their waypoints") end
		eq(g.assignCalls, nil, via .. ": no platform assignment asked")
		-- lines: forceUnload and the other StopConfig flags per stop, the stop's loads and waiting times
		send(g, 771, "lines", "{ line = 23 }")
		frames(g, 10)
		local l = final(g, 771).lines[1]
		eq(l.stops[2].forceUnload, true, via); eq(l.stops[1].forceUnload, false, via)
		eq(l.stops[1].destroyForConfigChange, false); eq(l.stops[1].destroyForRefresh, false)
		eq(#l.stops[1].stopLoads, 1); eq(l.stops[1].stopLoads[1].cargo, "COAL"); eq(l.stops[1].stopLoads[1].maxLoad, 1)
		eq(#l.stops[2].stopLoads, 0); eq(l.stops[1].maxAdditionalWaitingTime, 60)
		truthy(answerText(g, 771):find('"stopLoads":[]', 1, true), "a stop that loads nothing: []")
		-- cleared again
		send(g, 772, "line", string.format('{ action = "update", line = 23, forceUnload = { 0, 0 }, via = %q }', via))
		frames(g, 10)
		local b = final(g, 772)
		eq(b.ok, true, via .. " " .. tostring(b.error)); eq(b.stops[2].forceUnload, false, via)
		eq(g.lines[23].stops[2].stopConfig.forceUnload, false, via)
		-- a count that does not match the line's stops: refused, nothing sent
		send(g, 773, "line", string.format('{ action = "update", line = 23, forceUnload = { 1 }, via = %q }', via))
		frames(g, 10)
		truthy(tostring(final(g, 773).error):find("one force unload value for every stop (2 stops, 1 values)", 1, true))
		send(g, 774, "line", string.format('{ action = "update", line = 23, forceUnload = { 1, 1, 1 }, via = %q }', via))
		frames(g, 10)
		truthy(tostring(final(g, 774).error):find("(2 stops, 3 values)", 1, true))
		-- with new stops: the count is of those
		send(g, 775, "line", string.format('{ action = "update", line = 23, stops = { 47, 49 }, forceUnload = { 1, 0, 0 }, via = %q }', via))
		frames(g, 10)
		truthy(tostring(final(g, 775).error):find("(2 stops, 3 values)", 1, true))
		eq(#sent(g, "lineUpdate"), 2, via .. ": only the good ones sent")
		eq(g.crashed, nil, via)
	end
end)

test("line update --force-unload with --stops, with --cargo; the stop's maxLoad and destroy flags kept (gui and cmd)", function()
	for _, via in ipairs({ "gui", "cmd" }) do
		local g = shipLine()
		local cfg1 = g.lines[23].stops[1].stopConfig
		cfg1.maxLoad[2], cfg1.destroyForConfigChange, cfg1.destroyForRefresh = 0.5, true, true
		-- --force-unload alone: only forceUnload changes on the stop's config
		send(g, 800, "line", string.format('{ action = "update", line = 23, forceUnload = { 1, 0 }, via = %q }', via))
		frames(g, FIRST)
		local a = final(g, 800)
		eq(a.ok, true, via .. " " .. tostring(a.error))
		local held = g.lines[23].stops[1].stopConfig
		eq(held.forceUnload, true, via); eq(held.maxLoad[2], 0.5, via .. ": maxLoad kept")
		eq(held.destroyForConfigChange, true, via); eq(held.destroyForRefresh, true, via)
		eq(held.load[2], true, via .. ": the loads kept")
		eq(a.stops[1].destroyForRefresh, true, via .. ": read back"); eq(a.stops[1].stopLoads[1].maxLoad, 0.5, via)
		-- with --stops: a kept stop keeps its config, a new one gets the base's, each with the forceUnload asked
		send(g, 801, "line", string.format('{ action = "update", line = 23, stops = { 47, 49, 48 }, ' ..
			'forceUnload = { 0, 1, 1 }, via = %q }', via))
		frames(g, 10)
		local b = final(g, 801)
		eq(b.ok, true, via .. " " .. tostring(b.error)); eq(#b.stops, 3, via); eq(b.stops[3].stationGroup, 48, via)
		eq(b.stops[1].forceUnload, false, via); eq(b.stops[2].forceUnload, true, via); eq(b.stops[3].forceUnload, true, via)
		local s1 = g.lines[23].stops[1].stopConfig
		eq(s1.maxLoad[2], 0.5, via .. ": the kept stop's maxLoad"); eq(s1.destroyForRefresh, true, via)
		eq(g.lines[23].stops[3].stopConfig.forceUnload, true, via .. ": the new stop")
		-- with --cargo: the cargo filter's loads and maxLoad, and the forceUnload asked
		send(g, 802, "line", string.format('{ action = "update", line = 23, cargo = "coal", forceUnload = { 1, 0, 1 }, via = %q }', via))
		frames(g, 10)
		local c = final(g, 802)
		eq(c.ok, true, via .. " " .. tostring(c.error)); eq(c.loads[1], "COAL", via); eq(c.customFilters, true, via)
		eq(c.stops[1].forceUnload, true, via); eq(c.stops[2].forceUnload, false, via); eq(c.stops[3].forceUnload, true, via)
		eq(g.lines[23].stops[1].stopConfig.destroyForRefresh, true, via .. ": --cargo keeps the destroy flags too")
		eq(g.crashed, nil, via)
	end
end)

test("line update --force-unload: another company's line is refused; create sets it on new stops (gui and cmd)", function()
	local g = shipLine()
	g.lines[77] = { name = "theirs", stops = {} }
	local real = api.engine.system.lineSystem.getLinesForPlayer
	api.engine.system.lineSystem.getLinesForPlayer = function() return { 23 } end
	send(g, 780, "line", '{ action = "update", line = 77, forceUnload = { 1, 1 } }')
	frames(g, FIRST)
	api.engine.system.lineSystem.getLinesForPlayer = real
	g.lines[77] = nil
	truthy(tostring(final(g, 780).error):find("is not the company's", 1, true))
	eq(#sent(g, "lineUpdate"), 0)
	for _, via in ipairs({ "gui", "cmd" }) do
		local p = portWorld()
		send(p, 781, "line", string.format('{ action = "create", stops = { 47, 48 }, terminals = { "0:2", "0:1" }, ' ..
			'forceUnload = { 0, 1 }, via = %q }', via))
		frames(p, FIRST)
		local a = final(p, 781)
		eq(a.ok, true, via .. " " .. tostring(a.error))
		eq(a.stops[1].forceUnload, false, via); eq(a.stops[2].forceUnload, true, via)
		eq(p.lines[a.line].stops[2].stopConfig.forceUnload, true, via)
		-- without it: the base's makeNewStop's false, as before
		send(p, 782, "line", string.format('{ action = "create", stops = { 47, 48 }, terminals = { "0:2", "0:1" }, via = %q }', via))
		frames(p, 10)
		local b = final(p, 782)
		eq(b.ok, true, via .. " " .. tostring(b.error)); eq(b.stops[2].forceUnload, false, via)
		eq(p.crashed, nil, via)
	end
end)

test("line_configs: forceUnload goes on as a copy of the StopConfig; a builder that drops it does not send", function()
	local g = shipLine()
	local lc = require "hummer_remote_probe::/line_configs.lua"
	local cfg = { load = { false, true }, maxLoad = { 1, 0.5 }, forceUnload = false, destroyForConfigChange = true, destroyForRefresh = false }
	local c2 = lc.withForceUnload(cfg, true)
	eq(c2.forceUnload, true); eq(cfg.forceUnload, false, "the one given is not written into")
	eq(c2.maxLoad[2], 0.5); eq(c2.destroyForConfigChange, true)
	local line = lc.cmdLine({ kind = "update", line = 23, forceUnload = { true, false } })
	eq(line.stops[1].stopConfig.forceUnload, true); eq(line.stops[2].stopConfig.forceUnload, false)
	eq(g.lines[23].stops[1].stopConfig.forceUnload, false, "nothing changed in the engine before the command")
	local ok, err = pcall(lc.cmdLine, { kind = "update", line = 23, forceUnload = { true } })
	eq(ok, false); truthy(tostring(err):find("a force unload value for every stop", 1, true), tostring(err))
	local r = { forceUnload = { true, false } }
	truthy(lc.checkRequested({ { stopConfig = { forceUnload = true } }, { stopConfig = { forceUnload = false } } }, r))
	ok, err = lc.checkRequested({ { stopConfig = { forceUnload = true } }, { stopConfig = { forceUnload = true } } }, r)
	eq(ok, nil); truthy(err:find("stop 2: built with force unload true, not false", 1, true), err)
	ok, err = lc.checkRequested({ { stopConfig = { forceUnload = true } }, {} }, r)
	eq(ok, nil); truthy(err:find("built with force unload nil", 1, true), err)
	ok, err = lc.checkRequested({ { stopConfig = { forceUnload = true } } }, r)
	eq(ok, nil); truthy(err:find("not one per stop", 1, true), err)
	eq(g.crashed, nil)
end)

test("lines: a stop without a StopConfig or waiting times reads as nil, not an error", function()
	local g = shipLine()
	g.lines[23].stops[2].stopConfig = nil
	g.lines[23].stops[2].maxAdditionalWaitingTime = nil
	send(g, 790, "lines", "{ line = 23 }")
	frames(g, FIRST)
	local a = final(g, 790)
	eq(a.ok, true, tostring(a.error))
	local s = a.lines[1].stops[2]
	eq(s.forceUnload, nil); eq(s.destroyForRefresh, nil); eq(#s.stopLoads, 0); eq(s.maxAdditionalWaitingTime, nil)
	eq(a.lines[1].stops[1].forceUnload, false)
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

-- the events the speed control would see: each new request in opens, in order, with the game time it appeared
local function watchEvents(g, n, dt)
	local seen = {}
	local last = -1
	for _, o in ipairs(opensNow()) do last = math.max(last, o.seq) end
	for _ = 1, n do
		g.step(dt)
		for _, o in ipairs(opensNow()) do
			if o.seq > last then
				last = o.seq
				seen[#seen + 1] = { name = o.event and o.event.name, param = o.event and o.event.param, t = g.time }
			end
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

test("build-tool with the speed control on screen: all four events fire, in order, none written over", function()
	local g = speedGame({ saves = SAVES })
	frames(g, 2)
	local fired = #R.events
	send(g, 956, "buildTool", '{ menu = "road", res = "station/street/bus_stop.con", seconds = 5 }')
	frames(g, FIRST + 30 * 12)
	eq(final(g, 956).ok, true, tostring(final(g, 956).error))
	local names = {}
	for i = fired + 1, #R.events do names[#names + 1] = R.events[i].name end
	eq(table.concat(names, ","), "openRoad,setMenuFilter,constructionMenuSelectTabForConstruction,setMenuFilter")
	eq(#opensNow(), 0)
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

test("vehicles --state --at-terminal: only the vehicles in port, each answer with the game time of its read", function()
	local enRoute = shipFleet()
	enRoute.live.fields.state = 1
	local g = modelsGame({ fleet = { [601] = shipFleet(), [602] = enRoute, [603] = fleetOf(101, 6) } })
	g.gameTime = 130000
	send(g, 735, "vehicles", "{ state = true, atTerminal = true }")
	frames(g, FIRST)
	local a = final(g, 735)
	eq(a.ok, true, tostring(a.error)); eq(a.atTerminal, true); eq(a.gameTime, 130000); eq(a.stateUnknown, 0)
	eq(a.total, 1, "total counts only those at a terminal"); eq(#a.vehicles, 1); eq(a.vehicles[1].entity, 601)
	eq(a.vehicles[1].state.state, "AT_TERMINAL")
	-- with entities: one not in port is neither listed nor missing; a gone one is still missing
	send(g, 736, "vehicles", "{ state = true, atTerminal = true, entities = { 601, 602, 999 } }")
	frames(g, 20)
	a = final(g, 736)
	eq(a.total, 1); eq(a.vehicles[1].entity, 601); eq(#a.missing, 1); eq(a.missing[1], 999)
	-- the game time moves between two reads: each answer has its own
	g.gameTime = 131500
	send(g, 737, "vehicles", "{ state = true, entities = { 601 } }")
	frames(g, 20)
	a = final(g, 737)
	eq(a.atTerminal, nil, "not asked: no key"); eq(a.stateUnknown, nil); eq(a.total, 1)
	truthy(a.gameTime >= 131500, "the game time of this read, not the last one: " .. tostring(a.gameTime))
	eq(a.vehicles[1].state.sinceDoors, a.gameTime - 120000, "sinceDoors from the same game time")
	-- nobody in port: an empty list
	g.fleet[601].live.fields.state = 3
	send(g, 738, "vehicles", "{ state = true, atTerminal = true }")
	frames(g, 20)
	a = final(g, 738)
	eq(a.total, 0); truthy(answerText(g, 738):find('"vehicles":[]', 1, true))
	-- atTerminal goes with state; not a boolean is refused
	send(g, 739, "vehicles", "{ atTerminal = true }")
	frames(g, 20)
	truthy(tostring(final(g, 739).error):find("atTerminal goes with state", 1, true))
	send(g, 740, "vehicles", '{ state = true, atTerminal = "yes" }')
	frames(g, 20)
	truthy(tostring(final(g, 740).error):find("atTerminal must be true or false", 1, true))
	eq(#g.commands, 0, "read only")
end)

test("vehicles --at-terminal: a state that cannot be read leaves the vehicle out, not the answer", function()
	local g = modelsGame({ fleet = { [601] = shipFleet() } })
	local real = api.type.enum.TransportVehicleState
	api.type.enum.TransportVehicleState = nil
	send(g, 745, "vehicles", "{ state = true, atTerminal = true }")
	frames(g, FIRST)
	local a = final(g, 745)
	api.type.enum.TransportVehicleState = real
	eq(a.ok, true, tostring(a.error)); eq(a.total, 0, "cannot be told: not listed as in port")
	eq(a.stateUnknown, 1, "and counted, so an empty list is not read as nobody in port")
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

---------------------------------------------------------------------------------------------------------------------
-- modhub (My Mods in the main menu): status and validate; nothing uploads

local STAGING = {
	{ folder = "hummer_construction_altitude_tooltip_1", title = "Construction Altitude Tooltip", modhubId = "6400001",
		details = { visible = true, title = "Construction Altitude Tooltip", modId = "6400001", version = "3" } },
	{ folder = "hummer_cursor_altitude_tooltip_1", title = "Cursor Altitude Tooltip", modhubId = "6400002",
		details = { visible = true, title = "Cursor Altitude Tooltip", modId = "6400002" } },
	{ folder = "hummer_industry_pollution_display_1", title = "Industry Pollution Display", modhubId = "6500003",
		details = { visible = true, title = "Industry Pollution Display", modId = "6500003" },
		result = { messages = {
			{ level = "Warning", file = "res/a.lua", message = "unused file" },
			{ level = "Error", file = "res/b.dds", message = "texture too big for console", consoleOnly = true },
			{ level = "Warning", file = "res/c.lua", message = "deprecated call" },
		}, criticalPc = false, criticalConsole = false, levelPc = "Warning", levelConsole = "Error" } },
	{ folder = "example_mod_1", title = "Example" },
	{ folder = "hummer_proto_models_1" }, -- no title: nil reads as nothing
}

local function modhubGame(spec, opts)
	opts = opts or {}
	local ms = spec or {}
	if ms.staging == nil then ms.staging = STAGING end
	-- force unload without a mod.io id in the staging list: the tests' new mod, so the game's copy of the core
	-- drops it from MODHUB_PUBLISHED_IDS (firstUploadOf). A refusal by that table shows only where a test keeps it:
	-- give firstUploadOf yourself, or a staging entry with a modhubId
	for _, e in ipairs(ms.staging) do
		if e.folder == "hummer_force_unload_default_1" and e.modhubId == nil and ms.firstUploadOf == nil then
			ms.firstUploadOf = e.folder
		end
	end
	local g = newGame({ saves = SAVES, menu = opts.inGame ~= true, modhub = ms })
	frames(g, 2)
	return g
end

local function modOf(a, folder)
	for _, m in ipairs(a.mods or {}) do if m.folder == folder then return m end end
end

-- every test of this part ends with this: the helper's upload and change methods record each call
local function noUploads(g)
	eq(#(g.forbidden or {}), 0, "upload / change methods called: " .. table.concat(g.forbidden or {}, ", "))
	eq(#(g.publishCalls or {}), 0, "publish called")
	eq(#(g.abortPublishes or {}), 0, "abortPublish called")
	eq(g.settingsMade or 0, 0, "PublishSettings made")
end

test("modhub core: folder names, status and validate args, the allowed folders", function()
	eq(core.stagingFolder("StagingArea,hummer_x_1"), "hummer_x_1")
	eq(core.stagingFolder("hummer_x_1"), "hummer_x_1")
	eq(core.stagingFolder(""), nil); eq(core.stagingFolder(nil), nil); eq(core.stagingFolder(5), nil)
	eq(core.stagingFolder(newproxy(true)), nil, "userdata is no folder")
	eq(core.modhubStatusArgs(nil).wait, 30)
	eq(core.modhubStatusArgs({ wait = 0 }).wait, 0)
	eq(core.modhubStatusArgs({ folder = "a_1" }).folder, "a_1")
	truthy(select(2, core.modhubStatusArgs({ wait = 121 })))
	truthy(select(2, core.modhubStatusArgs({ wait = 0 / 0 })))
	truthy(select(2, core.modhubStatusArgs({ folder = "../x" })):find("plain folder"))
	truthy(select(2, core.modhubStatusArgs({ folder = "StagingArea,x" })):find("plain folder"))
	truthy(select(2, core.modhubStatusArgs({ folder = newproxy(true) })))
	local v = core.modhubValidateArgs({ folder = "hummer_industry_pollution_display_1" })
	eq(v.timeout, 300); eq(v.messages, 50)
	for _, f in ipairs({ "hummer_construction_altitude_tooltip_1", "hummer_cursor_altitude_tooltip_1",
		"hummer_industry_pollution_display_1", "hummer_force_unload_default_1" }) do
		truthy(core.modhubValidateArgs({ folder = f }), f)
	end
	for _, f in ipairs({ "example_mod_1", "hummer_proto_models_1", "road_tunnel_ramp_1", "hummer_force_unload_default" }) do
		local ok, err = core.modhubValidateArgs({ folder = f })
		eq(ok, nil, f); truthy(err:find("only these staging folders"), err)
	end
	truthy(select(2, core.modhubValidateArgs({})):find("give a staging folder"))
	truthy(select(2, core.modhubValidateArgs(nil)))
	truthy(select(2, core.modhubValidateArgs({ folder = "hummer_force_unload_default_1", timeout = 0 })))
	truthy(select(2, core.modhubValidateArgs({ folder = "hummer_force_unload_default_1", timeout = 1801 })))
	truthy(select(2, core.modhubValidateArgs({ folder = "hummer_force_unload_default_1", messages = 1.5 })))
	eq(core.modhubValidateArgs({ folder = "hummer_force_unload_default_1", messages = 0 }).messages, 0)
end)

test("modhub core: validationSummary counts as the base page, lists the first messages, takes nil", function()
	eq(core.validationSummary(nil), nil)
	eq(core.validationSummary(newproxy(true)), nil)
	local s = core.validationSummary({ messages = {} })
	eq(s.text, "Validation: No Issues Found"); eq(s.messageCount, 0); eq(core.json(s.messages), "[]")
	s = core.validationSummary({ messages = { { level = "Critical" }, { level = "Error", consoleOnly = true },
		{ level = "Warning" }, { level = "Message" }, "junk" }, criticalPc = true, levelConsole = "Critical" }, 2)
	eq(s.counts.critical, 1); eq(s.counts.error, 1); eq(s.counts.warning, 1); eq(s.counts.other, 2)
	eq(s.counts.consoleOnly, 1); eq(s.messageCount, 5); eq(#s.messages, 2); eq(s.truncated, true)
	eq(s.text, "Validation: 1 Critical Issues"); eq(s.criticalPc, true); eq(s.levelConsole, "Critical")
	eq(core.validationSummary({ messages = { { level = "Error" }, { level = "Warning" } } }).text,
		"Validation: 1 Errors, 1 Warnings")
	eq(core.validationSummary({ messages = { { level = "Warning" } } }).text, "Validation: 1 Warnings")
	local cyc = { level = "Error" }
	cyc.self = cyc
	eq(core.validationSummary({ messages = { cyc } }).counts.error, 1, "a cycle does not trip it")
	eq(core.validationSummary({ messages = "x" }).messageCount, 0)
end)

test("modhub status in the main menu: the helper, mod.io's state and every staging mod, without names", function()
	local g = modhubGame()
	send(g, 1301, "modhubStatus", "{ }")
	frames(g, FIRST)
	local text = answerText(g, 1301)
	truthy(text, answerText(g, 1301, "error"))
	local a = decode(text)
	eq(a.ok, true); eq(a.privileged, true); eq(a.helper, true); eq(g.helpersMade, 1)
	eq(a.backends.publish, 2); eq(a.backends.staging, 1); eq(a.backends.stagingFrom, "getBackendIdForSource")
	eq(a.modio.loggedIn, true); eq(a.modio.management.busy, false); eq(a.modio.allowModUpload, true)
	eq(a.anyStagingMods, true); eq(#a.mods, 5)
	local ipd = modOf(a, "hummer_industry_pollution_display_1")
	eq(ipd.state, "Ready"); eq(ipd.modhubId.valid, true); eq(ipd.modhubId.value, "6500003")
	eq(ipd.hasModhubDetails, true); eq(ipd.modhubDetails.visible, true); eq(ipd.upload, "update")
	eq(ipd.validateAllowed, true); eq(ipd.title, "Industry Pollution Display")
	eq(ipd.validation.hasResult, false)
	local ex = modOf(a, "example_mod_1")
	eq(ex.modhubId.valid, false); eq(ex.hasModhubDetails, false); eq(ex.upload, "new"); eq(ex.validateAllowed, false)
	local proto = modOf(a, "hummer_proto_models_1")
	eq(proto.title, nil); eq(proto.state, "Ready")
	truthy(not text:find("someone", 1, true) and not text:find("Someone", 1, true), "no user or author names: " .. text)
	eq(#g.validateCalls, 0, "status validates nothing")
	-- the helper is made once per menu probe; update() runs every frame from then on
	local updates = g.helperUpdates
	truthy(updates > 0)
	send(g, 1302, "modhubStatus", '{ folder = "example_mod_1", wait = 0 }')
	frames(g, 10)
	a = final(g, 1302)
	eq(a.ok, true); eq(#a.mods, 1); eq(a.mods[1].folder, "example_mod_1"); eq(g.helpersMade, 1)
	truthy(g.helperUpdates > updates)
	send(g, 1303, "modhubStatus", '{ folder = "nope_1", wait = 0 }')
	frames(g, 10)
	a = final(g, 1303)
	eq(a.ok, false); truthy(a.error:find("no staging mod in folder nope_1"), a.error)
	noUploads(g)
end)

test("modhub status waits for the sync with mod.io, and says when it gave up waiting", function()
	local staging = { { folder = "hummer_industry_pollution_display_1", modhubId = "6500003", syncFrames = 200,
		details = { visible = false } } }
	local g = modhubGame({ staging = staging })
	send(g, 1305, "modhubStatus", '{ wait = 30 }')
	frames(g, FIRST)
	eq(final(g, 1305), nil, "still in Sync: no answer yet")
	frames(g, 200)
	local a = final(g, 1305)
	eq(a.ok, true); eq(a.mods[1].state, "Ready"); eq(a.timedOut, nil); eq(a.mods[1].modhubDetails.visible, false)
	staging[1].staysInSync = true
	g = modhubGame({ staging = staging })
	send(g, 1306, "modhubStatus", '{ wait = 2 }')
	frames(g, FIRST + 90)
	a = final(g, 1306)
	eq(a.ok, true); eq(a.mods[1].state, "Sync"); eq(a.mods[1].upload, nil, "nothing to say while in Sync")
	truthy((a.timedOut or ""):find("sync"), tostring(a.timedOut))
	noUploads(g)
end)

test("modhub: the ids may carry the source (StagingArea,<folder>); the staging backend falls back to the info-only one", function()
	local g = modhubGame({ prefix = "StagingArea,", noSource = true })
	send(g, 1308, "modhubStatus", "{ }")
	frames(g, FIRST)
	local a = final(g, 1308)
	eq(a.ok, true); eq(a.backends.staging, 1); eq(a.backends.stagingFrom, "infoOnly")
	local ipd = modOf(a, "hummer_industry_pollution_display_1")
	eq(ipd.value, "StagingArea,hummer_industry_pollution_display_1"); eq(ipd.state, "Ready")
	send(g, 1309, "modhubValidate", '{ folder = "hummer_industry_pollution_display_1" }')
	frames(g, 30)
	a = final(g, 1309)
	eq(a.ok, true, a.error); eq(g.validateCalls[1], "StagingArea,hummer_industry_pollution_display_1")
	noUploads(g)
end)

test("modhub: where the helper cannot be made (privileged), the game's error comes back as it is; validate stops there", function()
	local g = modhubGame({ privileged = false })
	send(g, 1311, "modhubStatus", "{ }")
	frames(g, FIRST)
	local text = answerText(g, 1311, "error")
	truthy(text, answerText(g, 1311))
	local a = decode(text)
	eq(a.ok, false); eq(a.helper, false); eq(a.privileged, false)
	truthy(a.helperError:find("API can only be used by privileged (non-moddable) scripts", 1, true), a.helperError)
	truthy(a.error:find("ModPublishHelper.new failed: ", 1, true), a.error)
	eq(#a.mods, 5, "the staging list is still read")
	eq(modOf(a, "hummer_industry_pollution_display_1").state, nil, "no helper: no state")
	send(g, 1312, "modhubValidate", '{ folder = "hummer_industry_pollution_display_1" }')
	frames(g, 10)
	a = final(g, 1312)
	eq(a.ok, false); truthy(a.error:find("API can only be used by privileged", 1, true), a.error)
	eq(#g.validateCalls, 0); eq(g.helpersMade, 0)
	local logged = 0
	for _, l in ipairs(g.logs) do if l:find("^%[remote_probe%] ModPublishHelper.new failed") then logged = logged + 1 end end
	eq(logged, 1, "tried and logged once, not on every command")
	-- a helper that comes back as nothing is the same stop
	g = modhubGame({ newReturnsNil = true })
	send(g, 1313, "modhubValidate", '{ folder = "hummer_industry_pollution_display_1" }')
	frames(g, FIRST)
	a = final(g, 1313)
	eq(a.ok, false); truthy(a.error:find("returned nothing"), a.error)
	noUploads(g)
end)

test("modhub validate: the base's validate, polled with update(); the result as the page counts it, PC and console", function()
	local g = modhubGame()
	send(g, 1315, "modhubValidate", '{ folder = "hummer_industry_pollution_display_1", messages = 2 }')
	frames(g, FIRST)
	local a = final(g, 1315)
	truthy(a, "answered")
	eq(a.ok, true, a.error); eq(a.folder, "hummer_industry_pollution_display_1"); eq(a.state, "Ready")
	eq(#g.validateCalls, 1); eq(g.validateCalls[1], "hummer_industry_pollution_display_1")
	local r = a.result
	eq(r.criticalPc, false); eq(r.criticalConsole, false); eq(r.levelPc, "Warning"); eq(r.levelConsole, "Error")
	eq(r.counts.warning, 2); eq(r.counts.error, 1); eq(r.counts.consoleOnly, 1); eq(r.messageCount, 3)
	eq(#r.messages, 2); eq(r.truncated, true); eq(r.messages[1].file, "res/a.lua")
	eq(r.text, "Validation: 1 Errors, 2 Warnings")
	eq(a.note, nil)
	-- status shows the last result's counts afterwards
	send(g, 1316, "modhubStatus", '{ folder = "hummer_industry_pollution_display_1", wait = 0 }')
	frames(g, 10)
	local s = final(g, 1316)
	eq(s.mods[1].validation.hasResult, true); eq(s.mods[1].validation.result.counts.error, 1)
	eq(#s.mods[1].validation.result.messages, 0, "status lists no messages")
	noUploads(g)
end)

test("modhub validate: progress while it runs; a validation past its timeout is aborted (a validation, never an upload)", function()
	local staging = { { folder = "hummer_force_unload_default_1", title = "Force Unload", validateUpdates = 100000 } }
	local g = modhubGame({ staging = staging })
	send(g, 1318, "modhubValidate", '{ folder = "hummer_force_unload_default_1", timeout = 20 }')
	frames(g, FIRST + 30 * 16)
	local p = answerText(g, 1318, "p1")
	truthy(p, "a progress answer")
	local pa = decode(p)
	eq(pa.running, true); eq(pa.phase, "validating"); eq(pa.task, "Checking files"); truthy(pa.progress >= 0)
	eq(final(g, 1318), nil, "not done")
	frames(g, 30 * 6)
	local a = final(g, 1318)
	eq(a.ok, false); truthy(a.error:find("timed out after 20 s"), a.error)
	eq(g.abortValidations, 1)
	noUploads(g)
end)

test("modhub validate refuses folders outside its list, before making anything", function()
	local g = modhubGame()
	for i, f in ipairs({ "example_mod_1", "hummer_proto_models_1", "../hummer_industry_pollution_display_1" }) do
		send(g, 1320 + i, "modhubValidate", string.format("{ folder = %q }", f))
		frames(g, i == 1 and FIRST or 10)
		local a = final(g, 1320 + i)
		eq(a.ok, false, f)
		truthy(a.error:find("only these staging folders") or a.error:find("plain folder"), a.error)
	end
	eq(g.helpersMade, 0); eq(#g.validateCalls, 0)
	-- an allowed folder that is not in the staging area
	send(g, 1324, "modhubValidate", '{ folder = "hummer_force_unload_default_1" }')
	frames(g, 10)
	local a = final(g, 1324)
	eq(a.ok, false); truthy(a.error:find("no staging mod in folder hummer_force_unload_default_1"), a.error)
	truthy(a.error:find("example_mod_1", 1, true), "names what is there: " .. a.error)
	eq(#g.validateCalls, 0)
	noUploads(g)
end)

test("modhub commands are refused inside a save (no privileged API there); nothing is made", function()
	local g = newGame({ saves = SAVES, modhub = { staging = STAGING } })
	frames(g, 2)
	send(g, 1326, "modhubStatus", "{ }")
	frames(g, FIRST)
	local a = final(g, 1326)
	eq(a.ok, false); truthy(a.error:find("works only in the main menu"), a.error)
	send(g, 1327, "modhubValidate", '{ folder = "hummer_industry_pollution_display_1" }')
	frames(g, 10)
	a = final(g, 1327)
	eq(a.ok, false); truthy(a.error:find("works only in the main menu"), a.error)
	eq(g.helpersMade, 0); eq(#g.validateCalls, 0)
	noUploads(g)
end)

test("modhub validate waits while mod.io is busy or not ready, goes once it is, and gives up after 30 s", function()
	local g = modhubGame()
	g.modhubBusy = true
	send(g, 1330, "modhubValidate", '{ folder = "hummer_industry_pollution_display_1" }')
	frames(g, FIRST + 30 * 5)
	eq(final(g, 1330), nil, "waiting")
	eq(g.helpersMade, 0, "no helper while mod.io is busy")
	g.modhubBusy = false
	frames(g, 30)
	local a = final(g, 1330)
	eq(a.ok, true, a.error); eq(#g.validateCalls, 1)
	for _, case in ipairs({ "modhubUploading", "modhubNotInitialized", "modhubNoRestricted" }) do
		local h = modhubGame()
		h[case] = true
		send(h, 1331, "modhubValidate", '{ folder = "hummer_industry_pollution_display_1" }')
		frames(h, FIRST + 30 * 31)
		a = final(h, 1331)
		eq(a.ok, false, case); truthy(a.error:find("after 30 s; try again later"), case .. ": " .. a.error)
		eq(#h.validateCalls, 0, case); eq(h.helpersMade, 0, case)
		noUploads(h)
	end
	-- status does not wait with wait = 0: it says why there is no helper yet
	local h = modhubGame()
	h.modhubBusy = true
	send(h, 1332, "modhubStatus", '{ wait = 0 }')
	frames(h, FIRST)
	a = final(h, 1332)
	eq(a.ok, false); eq(a.helper, false); truthy(a.notReady:find("busy"), a.notReady)
	truthy(a.error:find("no helper yet"), a.error); eq(a.modio.management.busy, true)
	eq(a.helperError, nil, "not a failure of the helper")
	noUploads(h)
end)

test("modhub validate: a mod that an upload has (Publishing / HasResult), or that never leaves Sync, is not validated", function()
	for _, st in ipairs({ "Publishing", "HasResult" }) do
		local g = modhubGame({ staging = { { folder = "hummer_force_unload_default_1", state = st } } })
		send(g, 1334, "modhubValidate", '{ folder = "hummer_force_unload_default_1" }')
		frames(g, FIRST)
		local a = final(g, 1334)
		eq(a.ok, false, st); truthy(a.error:find(st .. ", not Ready"), a.error)
		eq(#g.validateCalls, 0); noUploads(g)
	end
	local g = modhubGame({ staging = { { folder = "hummer_force_unload_default_1", staysInSync = true } } })
	send(g, 1335, "modhubValidate", '{ folder = "hummer_force_unload_default_1" }')
	frames(g, FIRST + 30 * 61)
	local a = final(g, 1335)
	eq(a.ok, false); truthy(a.error:find("still Sync after 60 s"), a.error)
	eq(#g.validateCalls, 0); noUploads(g)
end)

test("modhub: one job at a time; quit aborts a running validation and answers it", function()
	local g = modhubGame({ staging = { { folder = "hummer_force_unload_default_1", validateUpdates = 100000 } } })
	send(g, 1337, "modhubValidate", '{ folder = "hummer_force_unload_default_1" }')
	frames(g, FIRST)
	send(g, 1338, "modhubStatus", '{ wait = 0 }')
	frames(g, 10)
	local a = final(g, 1338)
	eq(a.ok, false); truthy(a.error:find("command 1337 %(modhubValidate%) is still running"), a.error)
	send(g, 1339, "quit")
	frames(g, 10)
	a = final(g, 1337)
	eq(a.ok, false); truthy(a.error:find("cancelled by quit command 1339"), a.error)
	eq(g.abortValidations, 1)
	noUploads(g)
end)

test("modhub without api.modhub (or an unreadable one) answers an error, not a crash", function()
	local g = newGame({ saves = SAVES, menu = true })
	frames(g, 2)
	send(g, 1341, "modhubStatus", "{ }")
	frames(g, FIRST)
	local a = final(g, 1341)
	eq(a.ok, false); truthy(a.error:find("api.modhub cannot be read"), a.error)
	send(g, 1342, "modhubValidate", '{ folder = "hummer_industry_pollution_display_1" }')
	frames(g, 10)
	a = final(g, 1342)
	eq(a.ok, false); truthy(a.error:find("api.modhub cannot be read"), a.error)
	-- api.modhub whose lists are userdata that raise on reading: the staging list is empty, not an error
	g = modhubGame()
	local locked = newproxy(true)
	getmetatable(locked).__index = function() error("locked") end
	getmetatable(locked).__len = function() error("locked") end
	api.modhub.getInstalledMods = function() return locked end
	send(g, 1343, "modhubStatus", '{ wait = 0 }')
	frames(g, FIRST)
	a = final(g, 1343)
	eq(a.ok, true, a.error); eq(#a.mods, 0); eq(core.json(core.array({})), "[]")
	truthy(answerText(g, 1343):find('"mods":[]', 1, true), "an empty list is []")
	noUploads(g)
end)

test("modhub: a helper just made may not know the staging mods yet: status and validate wait, and never ask it for one it lacks", function()
	local staging = { { folder = "hummer_industry_pollution_display_1", modhubId = "6500003", unknownFrames = 60,
		details = { visible = true } } }
	local g = modhubGame({ staging = staging })
	send(g, 1351, "modhubStatus", '{ wait = 30 }')
	frames(g, FIRST)
	eq(final(g, 1351), nil, "unknown to the helper counts as Sync: still waiting")
	frames(g, 60)
	local a = final(g, 1351)
	eq(a.ok, true, a.error); eq(a.mods[1].inHelper, true); eq(a.mods[1].state, "Ready"); eq(a.timedOut, nil)
	eq(g.asserted or 0, 0, "getStagingModData only after hasStagingMod")
	g = modhubGame({ staging = staging })
	send(g, 1352, "modhubValidate", '{ folder = "hummer_industry_pollution_display_1" }')
	frames(g, FIRST + 90)
	a = final(g, 1352)
	eq(a.ok, true, a and a.error); eq(#g.validateCalls, 1); eq(g.asserted or 0, 0)
	-- one the helper never gets: the sync wait ends it, without asking for it
	staging[1].unknownFrames = 1e9
	g = modhubGame({ staging = staging })
	send(g, 1353, "modhubValidate", '{ folder = "hummer_industry_pollution_display_1" }')
	frames(g, FIRST + 30 * 61)
	a = final(g, 1353)
	eq(a.ok, false); truthy(a.error:find("unknown to the publish helper after 60 s"), a.error)
	eq(#g.validateCalls, 0); eq(g.asserted or 0, 0)
	noUploads(g)
end)

test("modhub validate a second time: the result from before is not taken for this one (results are new userdata each read)", function()
	local staging = { { folder = "hummer_force_unload_default_1", lateStart = true, validateUpdates = 300,
		result = { messages = { { level = "Error", message = "x" } } } } }
	local g = modhubGame({ staging = staging })
	send(g, 1355, "modhubValidate", '{ folder = "hummer_force_unload_default_1" }')
	frames(g, FIRST + 320)
	local a = final(g, 1355)
	eq(a.ok, true, a and a.error); eq(a.result.counts.error, 1)
	staging[1].result = { messages = {} } -- the next run finds nothing
	send(g, 1356, "modhubValidate", '{ folder = "hummer_force_unload_default_1" }')
	frames(g, 30)
	eq(final(g, 1356), nil, "the old result is there and validating not yet seen: not done")
	frames(g, 330)
	a = final(g, 1356)
	eq(a.ok, true, a and a.error); eq(a.result.counts.error, 0, "this run's result"); eq(a.note, nil)
	noUploads(g)
end)

test("modhub validate: --timeout covers the waits for mod.io too, with progress while waiting", function()
	local g = modhubGame()
	g.modhubBusy = true
	send(g, 1358, "modhubValidate", '{ folder = "hummer_industry_pollution_display_1", timeout = 20 }')
	frames(g, FIRST + 30 * 16)
	local p = answerText(g, 1358, "p1")
	truthy(p, "progress while waiting")
	eq(decode(p).phase, "ready")
	frames(g, 30 * 6)
	local a = final(g, 1358)
	eq(a.ok, false); truthy(a.error:find("timed out after 20 s while waiting %(ready%); not validated"), a.error)
	eq(#g.validateCalls, 0); eq(g.helpersMade, 0)
	noUploads(g)
end)

test("one code path uploads: publish, abortPublish and PublishSettings only between the publish path markers of remote_modhub.lua; no other write", function()
	-- comments name them (to say what is left out); code must not, outside the one block
	local onlyInBlock = { "[:.]publish%s*%(", "abortPublish", "PublishSettings" }
	-- the helper's other change methods, and api.modhub's own writes (subscriptions, ratings, reports, logins,
	-- the mode, savegame ids) and what opens a browser or a folder: nowhere. A call through api.modhub itself is
	-- held by the list of allowed reads (the test "api.modhub: only the read functions..."); these names stay here
	-- for the helper's methods and for a write reached by any other way.
	local banned = { "setRemoteModId", "setModDetails", "refreshMod", "LogoImage", "GalleryImage", "setPostPublishFn",
		"openFolder", "stageSavegame", "subscribeModAsync", "unsubscribeModAsync", "forceUninstallModAsync",
		"submitModRatingAsync", "submitModReportAsync", "setModManagementMode", "setModhubModIdForSavegame",
		"logoutAsync", "authenticateUser", "requestEmailAuthCode", "restartModBackendAsync", "specialRefreshModAsync",
		"refreshAsync", "openExternalModPage", "openModhubInstallFolder", "openTermsInBrowser",
		"clearPendingSessionInvalidNotice", "getTermsOfUseAsync" }
	local p = io.popen("find '" .. root .. "/content' -name '*.lua'")
	local n, inBlockCount, blocks = 0, {}, 0
	for path in p:lines() do
		n = n + 1
		local lineNo, inBlock = 0, false
		local isModhub = path:find("/remote_modhub%.lua$") ~= nil
		for line in io.lines(path) do
			lineNo = lineNo + 1
			if isModhub and line:find("^%s*%-%- BEGIN publish path") then
				truthy(not inBlock, "nested marker"); inBlock = true; blocks = blocks + 1
			elseif isModhub and line:find("^%s*%-%- END publish path") then
				truthy(inBlock, "END without BEGIN"); inBlock = false
			end
			local code = line:gsub("%-%-.*$", "")
			for _, pat in ipairs(banned) do
				truthy(not code:find(pat), path .. ":" .. lineNo .. " calls " .. pat .. ": " .. line)
			end
			for _, pat in ipairs(onlyInBlock) do
				if code:find(pat) then
					truthy(inBlock, path .. ":" .. lineNo .. " names " .. pat .. " outside the publish path: " .. line)
					inBlockCount[pat] = (inBlockCount[pat] or 0) + 1
				end
			end
		end
		truthy(not inBlock, path .. ": the publish path is not closed")
	end
	p:close()
	truthy(n >= 10, "read the content files (" .. n .. ")")
	eq(blocks, 1, "one publish path")
	-- one publish call, one clean-up, one settings object
	for _, pat in ipairs(onlyInBlock) do eq(inBlockCount[pat], 1, pat) end
	eq(core.COMMANDS.modhubPublish, true); eq(core.COMMANDS.publish, nil)
end)

---------------------------------------------------------------------------------------------------------------------
-- modhub publish: one new mod, as the page's Upload button

local FU = "hummer_force_unload_default_1"
local CHANGELOG = "First release."
local function fuStaging(extra)
	local e = { folder = FU, title = "Force Unload by Default" }
	for k, v in pairs(extra or {}) do e[k] = v end
	-- with the published mods around it, as in the real staging area
	return { e, STAGING[3], { folder = "example_mod_1", title = "Example" } }
end
-- a core test that takes force unload as a new mod: out of MODHUB_PUBLISHED_IDS for its length
local function unpinnedTest(name, fn)
	test(name, function()
		local keep = core.MODHUB_PUBLISHED_IDS[FU]
		core.MODHUB_PUBLISHED_IDS[FU] = nil
		local ok, err = pcall(fn)
		core.MODHUB_PUBLISHED_IDS[FU] = keep
		if not ok then error(err, 0) end
	end)
end
local function publishCmd(extra)
	local t = { string.format("folder = %q", FU), "public = true", "firstUpload = true",
		string.format("changelog = %q", CHANGELOG) }
	for _, x in ipairs(extra or {}) do t[#t + 1] = x end
	return "{ " .. table.concat(t, ", ") .. " }"
end

unpinnedTest("modhub core: publish args (one folder, first upload only, the visibility given, a changelog) and the validation gate", function()
	local a = core.modhubPublishArgs({ folder = FU, public = true, firstUpload = true, changelog = "x" })
	eq(a.folder, FU); eq(a.public, true); eq(a.timeout, 900); eq(a.dryRun, false); eq(a.messages, 50)
	eq(core.modhubPublishArgs({ folder = FU, public = false, firstUpload = true, changelog = "x", dryRun = true }).public, false)
	-- publish's list is its own: folders validate takes are not taken by that alone (example_mod_1, a typo)
	for _, f in ipairs({ "example_mod_1", "hummer_proto_models_1", "road_tunnel_ramp_1", "hummer_force_unload_default",
		"hummer_cursor_altitude_tooltip", "Hummer_cursor_altitude_tooltip_1" }) do
		local ok, err = core.modhubPublishArgs({ folder = f, public = true, firstUpload = true, changelog = "x" })
		eq(ok, nil, f); truthy(err:find("publish takes only these staging folders: "), err)
	end
	-- the author's mods already on mod.io, for their updates; exactly these four
	local n = 0
	for _ in pairs(core.MODHUB_PUBLISH_FOLDERS) do n = n + 1 end
	eq(n, 4)
	for _, f in ipairs({ FU, "hummer_cursor_altitude_tooltip_1", "hummer_construction_altitude_tooltip_1",
		"hummer_industry_pollution_display_1" }) do
		truthy(core.MODHUB_PUBLISH_FOLDERS[f], f)
		truthy(core.MODHUB_VALIDATE_FOLDERS[f], f .. " is validated too")
	end
	local function why(t) return select(2, core.modhubPublishArgs(t)) end
	truthy(why({ folder = FU, public = true, changelog = "x" }):find("firstUpload"))
	truthy(why({ folder = FU, public = true, firstUpload = "yes", changelog = "x" }):find("firstUpload"))
	truthy(why({ folder = FU, firstUpload = true, changelog = "x" }):find("no default visibility"))
	truthy(why({ folder = FU, public = "yes", firstUpload = true, changelog = "x" }):find("no default visibility"))
	truthy(why({ folder = FU, public = true, firstUpload = true }):find("changelog"))
	truthy(why({ folder = FU, public = true, firstUpload = true, changelog = "  \n" }):find("changelog"))
	truthy(why({ folder = FU, public = true, firstUpload = true, changelog = string.rep("x", 5001) }):find("longer"))
	truthy(why({ folder = FU, public = true, firstUpload = true, changelog = "x", timeout = 3601 }))
	truthy(why({ folder = FU, public = true, firstUpload = true, changelog = "x", dryRun = "yes" }))
	truthy(why({ folder = "../" .. FU, public = true, firstUpload = true, changelog = "x" }):find("plain folder"))
	truthy(why(nil)); truthy(why({ folder = newproxy(true) }))
	-- the gate: no critical issue, no Error / Critical level (the page's "Proceed Anyway" question)
	local ok = { criticalPc = false, criticalConsole = false, levelPc = "Warning", levelConsole = "Message" }
	eq(core.publishValidationBlock(ok), nil)
	truthy(core.publishValidationBlock(nil))
	truthy(core.publishValidationBlock({ criticalPc = true, levelPc = "Critical", levelConsole = "Message" }):find("critical PC"))
	truthy(core.publishValidationBlock({ criticalPc = false, criticalConsole = true, levelPc = "Message", levelConsole = "Critical" }))
	truthy(core.publishValidationBlock({ criticalPc = false, criticalConsole = false, levelPc = "Error", levelConsole = "Message" }):find("levelPc is Error"))
	truthy(core.publishValidationBlock({ criticalPc = false, criticalConsole = false, levelPc = "Message", levelConsole = "Error" }):find("levelConsole"))
	truthy(core.publishValidationBlock({ criticalPc = nil, levelPc = "Message", levelConsole = "Message" }):find("cannot be read"))
	truthy(core.publishValidationBlock({ criticalPc = false, levelPc = nil, levelConsole = "Message" }):find("cannot be read"))
end)

test("modhub publish dry run: validates, checks the mod is new, answers every setting, and never calls publish", function()
	local g = modhubGame({ staging = fuStaging() })
	send(g, 1401, "modhubPublish", publishCmd({ "dryRun = true" }))
	frames(g, FIRST + 60)
	local a = final(g, 1401)
	truthy(a, "answered")
	eq(a.ok, true, a.error); eq(a.dryRun, true); eq(a.wouldPublish, true); eq(a.publishCalled, false)
	eq(a.folder, FU); eq(a.phase, "dryRun")
	eq(a.settings.setPublic, true); eq(a.settings.updateMetadata, true); eq(a.settings.changeLog, CHANGELOG)
	eq(a.settings.isSavegame, false); eq(a.settings.issuesConfirmed, false)
	eq(a.checks.state, "Ready"); eq(a.checks.modhubIdValid, false); eq(a.checks.hasModhubDetails, false)
	eq(a.checks.loggedIn, true); eq(a.checks.allowModUpload, true); eq(a.checks.logoImage, "set")
	eq(a.validation.text, "Validation: No Issues Found")
	eq(#g.validateCalls, 1, "validated first, as the page does")
	-- public = false goes through as false
	send(g, 1402, "modhubPublish", "{ folder = \"" .. FU .. "\", public = false, firstUpload = true, changelog = \"x\", dryRun = true }")
	frames(g, 60)
	a = final(g, 1402)
	eq(a.ok, true, a.error); eq(a.settings.setPublic, false)
	noUploads(g)
end)

test("modhub publish waits while mod.io turns busy after the helper is made (the other mods' sync), then goes on", function()
	local g = modhubGame({ staging = fuStaging({ syncFrames = 100 }) })
	send(g, 1404, "modhubPublish", publishCmd({ "dryRun = true", "timeout = 60" }))
	frames(g, FIRST + 10)
	eq(g.helpersMade, 1, "made while mod.io was idle")
	g.modhubBusy = true
	frames(g, 300)
	eq(final(g, 1404), nil, "waiting, not refused")
	eq(#g.validateCalls, 0)
	g.modhubBusy = false
	frames(g, 60)
	local a = final(g, 1404)
	eq(a.ok, true, a and a.error); eq(a.wouldPublish, true); eq(#g.validateCalls, 1)
	-- busy to the end: the time limit says what it waited for
	g = modhubGame({ staging = fuStaging({ syncFrames = 100 }) })
	send(g, 1405, "modhubPublish", publishCmd({ "timeout = 20" }))
	frames(g, FIRST + 10)
	g.modhubBusy = true
	frames(g, 30 * 21)
	a = final(g, 1405)
	eq(a.ok, false); truthy(a.error:find("timed out after 20 s %(check: mod.io is busy"), a.error)
	truthy(a.error:find("nothing was uploaded"), a.error)
	noUploads(g)
end)

test("modhub publish refuses folders outside its list, and a missing firstUpload or visibility, before making anything", function()
	local g = modhubGame({ staging = fuStaging() })
	local cases = {
		{ "{ folder = \"hummer_proto_models_1\", public = true, firstUpload = true, changelog = \"x\" }", "only these staging folders" },
		{ "{ folder = \"example_mod_1\", public = true, firstUpload = true, changelog = \"x\", dryRun = true }", "only these staging folders" },
		{ "{ folder = \"" .. FU .. "\", public = true, changelog = \"x\" }", "firstUpload" },
		{ "{ folder = \"" .. FU .. "\", firstUpload = true, changelog = \"x\" }", "no default visibility" },
	}
	for i, c in ipairs(cases) do
		send(g, 1405 + i, "modhubPublish", c[1])
		frames(g, i == 1 and FIRST or 10)
		local a = final(g, 1405 + i)
		eq(a.ok, false, c[1]); truthy(a.error:find(c[2]), a.error)
	end
	eq(g.helpersMade, 0); eq(#g.validateCalls, 0)
	noUploads(g)
end)

test("modhub publish refuses a mod with a mod.io id (an update, or one deleted on mod.io), no cover, or nobody logged in", function()
	local cases = {
		{ { modhubId = "7000009", details = { visible = true, modId = "7000009" } }, "already has a mod.io id %(7000009%)" },
		{ { modhubId = "7000009" }, "already has a mod.io id" }, -- the page's "got deleted, a new mod will be created": not here
		{ { logo = false }, "no valid cover image" },
	}
	for _, c in ipairs(cases) do
		for _, dry in ipairs({ true, false }) do
			-- the game's own check, with the pin out of the way (the pin refuses these before the game is asked)
			local g = modhubGame({ staging = fuStaging(c[1]), firstUploadOf = FU })
			send(g, 1411, "modhubPublish", publishCmd(dry and { "dryRun = true" } or nil))
			frames(g, FIRST + 60)
			local a = final(g, 1411)
			eq(a.ok, false, c[2]); truthy(a.error:find(c[2]), a.error); truthy(a.error:find("nothing was uploaded"), a.error)
			eq(a.publishCalled, false)
			noUploads(g)
		end
	end
	local g = modhubGame({ staging = fuStaging() })
	g.modhubLoggedOut = true
	send(g, 1412, "modhubPublish", publishCmd())
	frames(g, FIRST + 60)
	local a = final(g, 1412)
	eq(a.ok, false); truthy(a.error:find("log in"), a.error); eq(a.requiredUserAction, "login")
	eq(#g.validateCalls, 0, "stopped before validating")
	noUploads(g)
end)

test("modhub publish refuses a validation with an Error or Critical level, PC or console", function()
	for _, r in ipairs({
		{ messages = { { level = "Critical", message = "x" } }, criticalPc = true, levelPc = "Critical", levelConsole = "Critical" },
		{ messages = { { level = "Error", message = "x" } }, levelPc = "Error", levelConsole = "Error" },
		{ messages = { { level = "Error", message = "x", consoleOnly = true } }, levelPc = "Message", levelConsole = "Error" },
	}) do
		local g = modhubGame({ staging = fuStaging({ result = r }) })
		send(g, 1414, "modhubPublish", publishCmd())
		frames(g, FIRST + 60)
		local a = final(g, 1414)
		eq(a.ok, false); truthy(a.error:find("nothing was uploaded"), a.error); eq(a.publishCalled, false)
		truthy(a.validation and a.validation.text ~= "Validation: No Issues Found", "the validation is in the answer")
		noUploads(g)
	end
end)

test("modhub publish: the upload as the page's Upload button; progress, the mod.io id, the page's clean-up after the result; once per launch", function()
	local g = modhubGame({ staging = fuStaging({ publish = { frames = 30 * 20, modId = "7123456" } }) })
	send(g, 1416, "modhubPublish", publishCmd({ "timeout = 600" }))
	frames(g, FIRST + 40)
	eq(#g.publishCalls, 1, "publish called once")
	local call = g.publishCalls[1]
	eq(call.value, FU); eq(call.state, "Ready")
	eq(call.settings.setPublic, true); eq(call.settings.updateMetadata, true); eq(call.settings.changeLog, CHANGELOG)
	eq(call.settings.isSavegame, false); eq(call.settings.issuesConfirmed, false); eq(call.settings.additionalMetadata, nil)
	eq(final(g, 1416), nil, "still publishing")
	frames(g, 30 * 16)
	local p, last = nil, nil
	for i = 1, 5 do last = answerText(g, 1416, "p" .. i) or last end
	truthy(last, "progress answers")
	p = decode(last)
	eq(p.running, true); eq(p.phase, "publishing"); eq(p.publishCalled, true); eq(p.state, "Publishing")
	-- held: no quit, load or new game in the middle of an upload
	send(g, 1417, "quit")
	frames(g, 10)
	local q = final(g, 1417)
	eq(q.ok, false); truthy(q.error:find("still Publishing"), q.error); eq(g.quitCalled, nil)
	frames(g, 30 * 6)
	local a = final(g, 1416)
	truthy(a, "answered")
	eq(a.ok, true, a.error); eq(a.publishCalled, true); eq(a.modId, "7123456")
	eq(a.result.success, true); eq(#a.result.partialErrors, 0)
	eq(a.cleanedUp, true); eq(#g.abortPublishes, 1); eq(g.abortPublishes[1].state, "HasResult")
	eq(a.stateAfter, "Ready"); eq(a.modhubIdAfter.valid, true); eq(a.modhubIdAfter.value, "7123456")
	eq(#g.forbidden, 0, table.concat(g.forbidden, ", "))
	-- a second one is refused, dry run or not
	send(g, 1418, "modhubPublish", publishCmd())
	frames(g, 10)
	a = final(g, 1418)
	eq(a.ok, false); truthy(a.error:find("already sent in this launch %(command 1416%)"), a.error)
	send(g, 1419, "modhubPublish", publishCmd({ "dryRun = true" }))
	frames(g, 60)
	a = final(g, 1419)
	eq(a.ok, false); truthy(a.error:find("already has a mod.io id %(7123456%)"), a.error)
	eq(#g.publishCalls, 1)
	send(g, 1420, "modhubStatus", '{ wait = 0 }')
	frames(g, 10)
	a = final(g, 1420)
	eq(a.publishedThisLaunch.id, 1416); eq(a.publishedThisLaunch.outcome, "success")
	-- once there is a result, quit goes
	send(g, 1421, "quit")
	frames(g, 10)
	eq(final(g, 1421).ok, true)
end)

test("modhub publish: a failure comes back with the game's words; the page's clean-up after it; still once per launch", function()
	local g = modhubGame({ staging = fuStaging({ publish = { success = false,
		error = { code = 21012, debugMessage = "The mod name is already taken", localizedMessage = "Name taken" } } }) })
	send(g, 1423, "modhubPublish", publishCmd())
	frames(g, FIRST + 60)
	local a = final(g, 1423)
	eq(a.ok, false); eq(a.publishCalled, true); eq(a.outcome, "failed")
	truthy(a.error:find("Upload Failed: Name taken (code 21012)", 1, true), a.error)
	eq(a.result.success, false); eq(a.result.error.debugMessage, "The mod name is already taken"); eq(a.result.error.code, 21012)
	eq(#g.abortPublishes, 1); eq(g.abortPublishes[1].state, "HasResult"); eq(#g.forbidden, 0, table.concat(g.forbidden, ", "))
	send(g, 1424, "modhubPublish", publishCmd())
	frames(g, 10)
	a = final(g, 1424)
	eq(a.ok, false); truthy(a.error:find("already sent in this launch"), a.error)
	eq(#g.publishCalls, 1)
	-- partial errors: uploaded, but not all of it
	g = modhubGame({ staging = fuStaging({ publish = { partialErrors = { { step = "Gallery", error = { code = 5, localizedMessage = "image" } } } } }) })
	send(g, 1425, "modhubPublish", publishCmd())
	frames(g, FIRST + 60)
	a = final(g, 1425)
	eq(a.ok, false); eq(a.outcome, "partial"); eq(a.modId, "7000001"); truthy(a.error:find("1 partial errors"), a.error)
	eq(a.result.partialErrors[1].step, "Gallery")
	-- publish that raises: counts as the one of this launch
	g = modhubGame({ staging = fuStaging({ publish = { raises = true } }) })
	send(g, 1426, "modhubPublish", publishCmd())
	frames(g, FIRST + 60)
	a = final(g, 1426)
	eq(a.ok, false); truthy(a.error:find("publish raised"), a.error); eq(a.publishCalled, true)
	send(g, 1427, "modhubPublish", publishCmd())
	frames(g, 10)
	truthy(final(g, 1427).error:find("already sent"), "once per launch")
	eq(#g.abortPublishes, 0, "no result: no clean-up")
end)

test("modhub publish past its timeout: outcome unknown, abortPublish never called, quit / load / newgame held while Publishing", function()
	local g = modhubGame({ staging = fuStaging({ publish = { hangs = true } }) })
	send(g, 1430, "modhubPublish", publishCmd({ "timeout = 20" }))
	frames(g, FIRST + 30 * 22)
	local a = final(g, 1430)
	truthy(a, "answered")
	eq(a.ok, false); eq(a.outcome, "unknown"); eq(a.publishCalled, true)
	truthy(a.error:find("outcome is not known"), a.error); truthy(a.error:find("not aborted"), a.error)
	eq(#g.publishCalls, 1); eq(#g.abortPublishes, 0, "never aborted")
	for i, c in ipairs({ { "quit", nil }, { "load", '{ save = "probe" }' }, { "newgame", "{ }" } }) do
		send(g, 1430 + i, c[1], c[2])
		frames(g, 30)
		local r = final(g, 1430 + i)
		eq(r.ok, false, c[1]); truthy(r.error:find("still Publishing"), c[1] .. ": " .. r.error)
	end
	eq(g.quitCalled, nil); eq(g.loadCalled, nil)
	send(g, 1435, "modhubStatus", '{ wait = 0, folder = "' .. FU .. '" }')
	frames(g, 10)
	a = final(g, 1435)
	eq(a.publishedThisLaunch.outcome, "unknown"); eq(a.mods[1].state, "Publishing")
	eq(#g.abortPublishes, 0)
end)

test("modhub publish: refused inside a save; quit while it validates cancels it with nothing uploaded", function()
	local g = newGame({ saves = SAVES, modhub = { staging = fuStaging() } })
	frames(g, 2)
	send(g, 1437, "modhubPublish", publishCmd())
	frames(g, FIRST)
	local a = final(g, 1437)
	eq(a.ok, false); truthy(a.error:find("works only in the main menu"), a.error)
	eq(g.helpersMade, 0); noUploads(g)
	g = modhubGame({ staging = fuStaging({ validateUpdates = 100000 }) })
	send(g, 1438, "modhubPublish", publishCmd())
	frames(g, FIRST + 30)
	send(g, 1439, "quit")
	frames(g, 10)
	a = final(g, 1438)
	eq(a.ok, false); truthy(a.error:find("cancelled by quit command 1439; nothing was uploaded"), a.error)
	eq(final(g, 1439).ok, true); eq(g.abortValidations, 1)
	noUploads(g)
end)

---------------------------------------------------------------------------------------------------------------------
-- modhub publish, an update: the mod.io page of the fileid, as the page's Update button (the same publish call)

local FU_ID = "6543965"
local function fuOnModio(extra)
	local e = { modhubId = FU_ID, details = { visible = true, title = "Auto Force Unload at Drop-off Stops", modId = FU_ID,
		version = "10001" }, publish = { modId = FU_ID } }
	for k, v in pairs(extra or {}) do e[k] = v end
	return fuStaging(e)
end
local function updateCmd(extra)
	local t = { string.format("folder = %q", FU), "public = true", "update = true", string.format("modioId = %q", FU_ID),
		string.format("changelog = %q", "Wording.") }
	for _, x in ipairs(extra or {}) do t[#t + 1] = x end
	return "{ " .. table.concat(t, ", ") .. " }"
end

unpinnedTest("modhub core: an update needs update = true and the mod.io id; a first upload and an update are never both or neither", function()
	local a = core.modhubPublishArgs({ folder = FU, public = true, update = true, modioId = FU_ID, changelog = "x" })
	eq(a.update, true); eq(a.firstUpload, false); eq(a.modioId, FU_ID)
	a = core.modhubPublishArgs({ folder = FU, public = true, firstUpload = true, changelog = "x" })
	eq(a.firstUpload, true); eq(a.update, false); eq(a.modioId, nil)
	local function why(t) return select(2, core.modhubPublishArgs(t)) end
	truthy(why({ folder = FU, public = true, firstUpload = true, update = true, modioId = FU_ID, changelog = "x" }):find("not both"))
	truthy(why({ folder = FU, public = true, changelog = "x" }):find("firstUpload = true %(a new mod%) or update = true"))
	truthy(why({ folder = FU, public = true, update = true, changelog = "x" }):find("needs modioId"))
	for _, bad in ipairs({ "", "65x3965", "6543965 ", 6543965, "123456789012345678901" }) do
		truthy(why({ folder = FU, public = true, update = true, modioId = bad, changelog = "x" }):find("needs modioId"), tostring(bad))
	end
	truthy(why({ folder = FU, public = true, firstUpload = true, modioId = FU_ID, changelog = "x" }):find("only for an update"))
	truthy(why({ folder = FU, public = true, update = "yes", modioId = FU_ID, changelog = "x" }):find("update is true"))
	truthy(why({ folder = FU, public = true, firstUpload = false, update = true, modioId = FU_ID, changelog = "x" }):find("firstUpload is true"))
	truthy(why({ folder = FU, public = true, update = true, modioId = FU_ID }):find("changelog"))
	truthy(why({ folder = FU, public = true, update = true, modioId = FU_ID, changelog = " " }):find("changelog"))
	-- updateMetadata: an update sends it only when asked; a first upload always (false refused there)
	eq(a.updateMetadata, true, "a first upload")
	eq(core.modhubPublishArgs({ folder = FU, public = true, firstUpload = true, changelog = "x",
		updateMetadata = true }).updateMetadata, true)
	eq(core.modhubPublishArgs({ folder = FU, public = true, update = true, modioId = FU_ID, changelog = "x" }).updateMetadata,
		false, "an update, not given")
	eq(core.modhubPublishArgs({ folder = FU, public = true, update = true, modioId = FU_ID, changelog = "x",
		updateMetadata = false }).updateMetadata, false)
	eq(core.modhubPublishArgs({ folder = FU, public = true, update = true, modioId = FU_ID, changelog = "x",
		updateMetadata = true }).updateMetadata, true)
	for _, bad in ipairs({ "true", 1, "yes" }) do
		truthy(why({ folder = FU, public = true, update = true, modioId = FU_ID, changelog = "x",
			updateMetadata = bad }):find("updateMetadata is true or false"), tostring(bad))
	end
	truthy(why({ folder = FU, public = true, firstUpload = true, changelog = "x",
		updateMetadata = false }):find("only for an update"))
	-- the folder list holds for an update too
	truthy(why({ folder = "example_mod_1", public = true, update = true, modioId = "6500003",
		changelog = "x" }):find("only these staging folders"))
end)

unpinnedTest("modhub core: version X.Y.Z only with mod.json's revision, X*10000+Y*100+Z; no version, no additionalMetadata", function()
	local base = { folder = FU, public = true, update = true, modioId = FU_ID, changelog = "x" }
	local function with(t) local c = {}; for k, v in pairs(base) do c[k] = v end; for k, v in pairs(t) do c[k] = v end; return c end
	local a = core.modhubPublishArgs(with({ version = "1.0.3", revision = 10003 }))
	eq(a.version, "1.0.3"); eq(a.revision, 10003)
	eq(core.modhubPublishArgs(with({ version = "0.0.1", revision = 1 })).version, "0.0.1")
	eq(core.modhubPublishArgs(with({ version = "12.34.56", revision = 123456 })).version, "12.34.56")
	a = core.modhubPublishArgs(base)
	eq(a.version, nil); eq(a.revision, nil)
	local function why(t) return select(2, core.modhubPublishArgs(with(t))) end
	truthy(why({ version = "1.0.1", revision = 10003 }):find("version 1.0.1 is revision 10001, but mod.json's revision is 10003 %(that is 1.0.3%)"))
	truthy(why({ version = "0.0.1", revision = 10001 }):find("is 10001"))
	for _, bad in ipairs({ "1.0", "1.0.3.4", "v1.0.3", "1.0.3 ", "01.0.3", "1.00.3", "1.0.03", "1.100.0", "1.0.100",
		"1.-1.0", "a.b.c", "", "1..3", "１.0.3" }) do
		truthy(why({ version = bad, revision = 10003 }), "refused: " .. bad)
	end
	truthy(why({ version = 10003, revision = 10003 }):find("string"))
	truthy(why({ version = "1.0.3" }):find("needs revision"))
	truthy(why({ version = "1.0.3", revision = "10003" }):find("needs revision"))
	truthy(why({ version = "1.0.3", revision = 10003.5 }):find("needs revision"))
	truthy(why({ revision = 10003 }):find("only given with version"))
	-- a first upload takes it as well
	eq(core.modhubPublishArgs({ folder = FU, public = true, firstUpload = true, changelog = "x", version = "1.0.0",
		revision = 10000 }).version, "1.0.0")
end)

test("modhub core: a folder on mod.io is held to its page: no first upload, an update only to its own id", function()
	local ids = { [FU] = "6543965", hummer_cursor_altitude_tooltip_1 = "6523060",
		hummer_construction_altitude_tooltip_1 = "6536988", hummer_industry_pollution_display_1 = "6536959" }
	local n = 0
	for f, id in pairs(core.MODHUB_PUBLISHED_IDS) do
		n = n + 1
		eq(id, ids[f], f); truthy(core.MODHUB_PUBLISH_FOLDERS[f], f .. " is in the publish list")
	end
	eq(n, 4)
	local function why(t) return select(2, core.modhubPublishArgs(t)) end
	for f, id in pairs(ids) do
		local a = core.modhubPublishArgs({ folder = f, public = true, update = true, modioId = id, changelog = "x" })
		truthy(a, f); eq(a.modioId, id)
		truthy(why({ folder = f, public = true, firstUpload = true, changelog = "x" }):find("would make a second page"), f)
		truthy(why({ folder = f, public = true, firstUpload = true, changelog = "x", dryRun = true }):find("second page"), f)
		local other = f == FU and "6523060" or "6543965"
		truthy(why({ folder = f, public = true, update = true, modioId = other, changelog = "x" }):find("is mod.io mod " .. id), f)
	end
	-- in a game: a first upload of a pinned folder is refused before anything is made
	local g = modhubGame({ staging = { { folder = "hummer_industry_pollution_display_1", title = "IPD" } } })
	send(g, 1463, "modhubPublish", (publishCmd({ "dryRun = true" }):gsub(FU, "hummer_industry_pollution_display_1")))
	frames(g, FIRST + 60)
	local a = final(g, 1463)
	eq(a.ok, false); truthy(a.error:find("second page"), a.error); eq(g.helpersMade, 0)
	noUploads(g)
end)

test("modhub publish update with a version: the dry run answers additionalMetadata; the upload sets it on PublishSettings", function()
	local g = modhubGame({ staging = fuOnModio() })
	send(g, 1460, "modhubPublish", updateCmd({ "dryRun = true", "version = \"1.0.3\"", "revision = 10003" }))
	frames(g, FIRST + 60)
	local a = final(g, 1460)
	eq(a.ok, true, a.error); eq(a.publishCalled, false)
	eq(a.settings.additionalMetadata.version, "1.0.3")
	local n = 0
	for _ in pairs(a.settings.additionalMetadata) do n = n + 1 end
	eq(n, 1, "only version")
	noUploads(g)
	-- refused before anything is made when version and revision disagree
	g = modhubGame({ staging = fuOnModio() })
	send(g, 1461, "modhubPublish", updateCmd({ "version = \"1.0.2\"", "revision = 10003" }))
	frames(g, FIRST + 60)
	a = final(g, 1461)
	eq(a.ok, false); truthy(a.error:find("revision is 10003"), a.error)
	eq(g.helpersMade, 0)
	noUploads(g)
	-- the upload
	g = modhubGame({ staging = fuOnModio() })
	send(g, 1462, "modhubPublish", updateCmd({ "version = \"1.0.3\"", "revision = 10003" }))
	frames(g, FIRST + 90)
	eq(#g.publishCalls, 1)
	local s = g.publishCalls[1].settings
	eq(s.additionalMetadata.version, "1.0.3"); eq(s.changeLog, "Wording."); eq(s.isSavegame, false)
	a = final(g, 1462)
	eq(a.ok, true, a.error); eq(a.modId, FU_ID); eq(a.settings.additionalMetadata.version, "1.0.3")
	eq(#g.forbidden, 0, table.concat(g.forbidden, ", "))
end)

test("modhub publish update dry run: the mod.io id, mod.io's name and version, the settings; publish never called", function()
	local g = modhubGame({ staging = fuOnModio() })
	send(g, 1450, "modhubPublish", updateCmd({ "dryRun = true" }))
	frames(g, FIRST + 60)
	local a = final(g, 1450)
	truthy(a, "answered")
	eq(a.ok, true, a.error); eq(a.wouldPublish, true); eq(a.publishCalled, false); eq(a.mode, "update"); eq(a.modioId, FU_ID)
	eq(a.checks.mode, "update"); eq(a.checks.modhubIdValid, true); eq(a.checks.modhubIdValue, FU_ID)
	eq(a.checks.expectedModioId, FU_ID); eq(a.checks.hasModhubDetails, true)
	eq(a.checks.modio.title, "Auto Force Unload at Drop-off Stops"); eq(a.checks.modio.version, "10001")
	eq(a.checks.modio.visible, true); eq(a.checks.modio.modId, FU_ID)
	-- an update keeps the mod.io page's name, summary and description unless asked (updateMetadata = true)
	eq(a.settings.setPublic, true); eq(a.settings.updateMetadata, false); eq(a.settings.changeLog, "Wording.")
	eq(#g.validateCalls, 1, "validated first, as the page does")
	noUploads(g)
	send(g, 1459, "modhubPublish", updateCmd({ "dryRun = true", "updateMetadata = true" }))
	frames(g, 60)
	a = final(g, 1459)
	eq(a.ok, true, a.error); eq(a.settings.updateMetadata, true)
	noUploads(g)
end)

test("modhub publish update refuses another mod.io id, a mod without one, one mod.io lacks, and hiding a public mod", function()
	local cases = {
		{ fuOnModio({ modhubId = "7000009", details = { visible = true, modId = "7000009" } }), nil,
			"mod.io id is 7000009, not 6543965" },
		{ fuStaging(), nil, "has no mod.io id, but an update" }, -- a new mod: the game would make a page
		{ fuOnModio({ details = false }), nil, "holds no details of mod 6543965" }, -- deleted on mod.io (remoteMissing)
		{ fuOnModio({ details = { visible = true, modId = FU_ID, found = false } }), nil, "holds no details" },
		{ fuOnModio({ details = { visible = true, modId = "7000002" } }), nil, "details are of mod 7000002" },
		{ fuOnModio({ details = { visible = true } }), nil, "details are of mod nil" }, -- an id that cannot be read
		{ fuOnModio(), { "public = false" }, "cannot make it hidden" },
		{ fuOnModio({ logo = false }), nil, "no valid cover image" },
	}
	for i, c in ipairs(cases) do
		if c[1][1].details == false then c[1][1].details = nil end
		for _, dry in ipairs({ true, false }) do
			local g = modhubGame({ staging = c[1] })
			local extra = { dry and "dryRun = true" or "timeout = 900" }
			local cmd = updateCmd(extra)
			if c[2] then cmd = cmd:gsub("public = true", c[2][1]) end
			send(g, 1451, "modhubPublish", cmd)
			frames(g, FIRST + 60)
			local a = final(g, 1451)
			eq(a.ok, false, i .. ": " .. c[3]); truthy(a.error:find(c[3]), i .. ": " .. a.error)
			truthy(a.error:find("not updated") or a.error:find("nothing was uploaded"), a.error)
			eq(a.publishCalled, false); eq(a.mode, "update")
			noUploads(g)
		end
	end
	-- a first upload of a mod already on mod.io is refused as before by the game, and names the update (with the
	-- pin out of the way); with the pin, before anything is made
	local g = modhubGame({ staging = fuOnModio(), firstUploadOf = FU })
	send(g, 1452, "modhubPublish", publishCmd())
	frames(g, FIRST + 60)
	local a = final(g, 1452)
	eq(a.ok, false); truthy(a.error:find("already has a mod.io id %(6543965%)"), a.error); eq(a.mode, "firstUpload")
	noUploads(g)
	g = modhubGame({ staging = fuOnModio() })
	send(g, 1452, "modhubPublish", publishCmd())
	frames(g, FIRST + 60)
	a = final(g, 1452)
	eq(a.ok, false); truthy(a.error:find("would make a second page"), a.error); eq(g.helpersMade, 0)
	noUploads(g)
	-- a hidden mod on mod.io may stay hidden or turn public
	for _, pub in ipairs({ "public = false", "public = true" }) do
		g = modhubGame({ staging = fuOnModio({ details = { visible = false, modId = FU_ID } }) })
		send(g, 1453, "modhubPublish", (updateCmd({ "dryRun = true" }):gsub("public = true", pub)))
		frames(g, FIRST + 60)
		a = final(g, 1453)
		eq(a.ok, true, a.error); eq(a.settings.setPublic, pub == "public = true")
		noUploads(g)
	end
end)

test("modhub publish update: one publish call with the page's Update settings; the same mod.io id back; once per launch", function()
	local g = modhubGame({ staging = fuOnModio() })
	send(g, 1455, "modhubPublish", updateCmd())
	frames(g, FIRST + 60)
	eq(#g.publishCalls, 1, "publish called once")
	local call = g.publishCalls[1]
	eq(call.value, FU); eq(call.state, "Ready")
	eq(call.settings.setPublic, true); eq(call.settings.updateMetadata, false); eq(call.settings.changeLog, "Wording.")
	eq(call.settings.isSavegame, false); eq(call.settings.issuesConfirmed, false)
	frames(g, 30)
	local a = final(g, 1455)
	eq(a.ok, true, a.error); eq(a.modId, FU_ID); eq(a.mode, "update"); eq(a.cleanedUp, true)
	eq(#g.forbidden, 0, table.concat(g.forbidden, ", "))
	send(g, 1456, "modhubPublish", updateCmd())
	frames(g, 10)
	truthy(final(g, 1456).error:find("already sent in this launch"), "once per launch")
	eq(#g.publishCalls, 1)
	-- updateMetadata = true asked for: the publish call sends it (the page's fields replace mod.io's)
	g = modhubGame({ staging = fuOnModio() })
	send(g, 1454, "modhubPublish", updateCmd({ "updateMetadata = true" }))
	frames(g, FIRST + 90)
	eq(#g.publishCalls, 1)
	eq(g.publishCalls[1].settings.updateMetadata, true)
	eq(final(g, 1454).ok, true)
	-- the game answered another mod.io id: not a success (a new page may have been made)
	g = modhubGame({ staging = fuOnModio({ publish = { modId = "7000077" } }) })
	send(g, 1457, "modhubPublish", updateCmd())
	frames(g, FIRST + 90)
	a = final(g, 1457)
	eq(a.ok, false); eq(a.outcome, "other id"); eq(a.modId, "7000077")
	truthy(a.error:find("update of mod.io mod 6543965 came back as mod.io mod 7000077"), a.error)
	send(g, 1458, "modhubStatus", '{ wait = 0 }')
	frames(g, 10)
	eq(final(g, 1458).publishedThisLaunch.outcome, "other id")
end)

test("modhub status --folder waits for that mod's sync only; validate waits for its own mod too", function()
	-- in game (2026-11-22) another staging mod stayed in Sync for 120 s and status --folder timed out on it
	local staging = { { folder = "hummer_industry_pollution_display_1", modhubId = "6500003", syncFrames = 30,
		details = { visible = true } }, { folder = "hummer_cursor_altitude_tooltip_1", modhubId = "6400002",
		staysInSync = true, details = { visible = true } } }
	local g = modhubGame({ staging = staging })
	send(g, 1450, "modhubStatus", '{ wait = 30, folder = "hummer_industry_pollution_display_1" }')
	frames(g, FIRST + 40)
	local a = final(g, 1450)
	truthy(a, "answered once its own mod is Ready, the other still in Sync")
	eq(a.ok, true, a.error); eq(a.timedOut, nil); eq(#a.mods, 1); eq(a.mods[1].state, "Ready")
	-- the one asked for stays in Sync: that is what it waits for, and what the answer names
	g = modhubGame({ staging = staging })
	send(g, 1451, "modhubStatus", '{ wait = 2, folder = "hummer_cursor_altitude_tooltip_1" }')
	frames(g, FIRST + 90)
	a = final(g, 1451)
	eq(a.ok, true); eq(a.mods[1].state, "Sync")
	truthy((a.timedOut or ""):find("staging mod hummer_cursor_altitude_tooltip_1"), tostring(a.timedOut))
	-- without a folder, every mod's sync is waited for (as before)
	g = modhubGame({ staging = staging })
	send(g, 1452, "modhubStatus", '{ wait = 2 }')
	frames(g, FIRST + 90)
	a = final(g, 1452)
	truthy((a.timedOut or ""):find("the staging mods"), tostring(a.timedOut))
	-- validate of the Ready mod goes while the other is in Sync
	g = modhubGame({ staging = staging })
	send(g, 1453, "modhubValidate", '{ folder = "hummer_industry_pollution_display_1" }')
	frames(g, FIRST + 30 * 5)
	a = final(g, 1453)
	eq(a.ok, true, a and a.error); eq(#g.validateCalls, 1)
	noUploads(g)
end)

test("modhub: a first step that raises ends its job with one answer; the next command is not refused as busy", function()
	-- the handler's own step, in the frame the command arrives: it ran outside H.step's pcall, so an error
	-- there left H.job behind and the job answered a second time later
	for i, c in ipairs({ { "modhubStatus", '{ wait = 30 }' },
		{ "modhubValidate", '{ folder = "hummer_industry_pollution_display_1" }' },
		{ "modhubPublish", publishCmd() } }) do
		local g = modhubGame({ staging = fuStaging() })
		local gcore = package.loaded["hummer_remote_probe::/remote_core.lua"] -- the game's own, fresh per game
		local real, calls = gcore.toList, 0
		gcore.toList = function(...)
			calls = calls + 1
			if calls == 2 then error("boom in the first step") end -- the first is backends(), in the handler
			return real(...)
		end
		local id = 1454 + 2 * i
		send(g, id, c[1], c[2])
		frames(g, FIRST)
		gcore.toList = real
		truthy(calls >= 2, c[1] .. ": the first step reached the staging list")
		frames(g, 30 * 3)
		local a, n = final(g, id)
		eq(n, 1, c[1] .. ": one final answer"); eq(a.ok, false, c[1])
		truthy(a.error:find("boom in the first step"), c[1] .. ": " .. tostring(a.error))
		send(g, id + 1, "modhubStatus", '{ wait = 0 }')
		frames(g, 10)
		a = final(g, id + 1)
		truthy(not (a.error or ""):find("still running"), c[1] .. ": " .. tostring(a.error))
		noUploads(g)
	end
end)

test("modhub: load and newgame abort a running validation and answer it, as quit does", function()
	for i, c in ipairs({ { "load", '{ save = "probe" }' }, { "newgame", "{ }" } }) do
		local g = modhubGame({ staging = { { folder = "hummer_force_unload_default_1", validateUpdates = 100000 } } })
		local id = 1463 + 2 * i
		send(g, id, "modhubValidate", '{ folder = "hummer_force_unload_default_1" }')
		frames(g, FIRST)
		eq(final(g, id), nil, c[1] .. ": still validating")
		send(g, id + 1, c[1], c[2])
		frames(g, 30)
		local a = final(g, id)
		eq(a.ok, false, c[1]); truthy(a.error:find("cancelled by " .. c[1] .. " command " .. (id + 1)), c[1] .. ": " .. a.error)
		eq(g.abortValidations, 1, c[1])
		noUploads(g)
	end
end)

test("api.modhub: only the read functions on the list are called anywhere in content/", function()
	-- the list is what the probe reads; a write (subscribe, rate, log in, change the mode...) or anything new
	-- must be added here on purpose. Every other use of api.modhub (another name, an alias, an index) fails.
	local allowed = { getBackendIDs = true, getBackendIdForSource = true, getCapabilities = true,
		getInstalledMods = true, getModInfoForInstalledMod = true, getModManagementState = true,
		getUserInfo = true, isInitialized = true }
	local p = io.popen("find '" .. root .. "/content' -name '*.lua'")
	local n, uses = 0, 0
	for path in p:lines() do
		n = n + 1
		local lineNo = 0
		for line in io.lines(path) do
			lineNo = lineNo + 1
			-- api indexed by a string (api["modhub"]) is never allowed: looked for before the strings are blanked
			truthy(not line:gsub("%-%-.*$", ""):find("api%s*%["), path .. ":" .. lineNo .. " indexes api by a key: " .. line)
			-- comments and strings may name anything (error texts say "api.modhub cannot be read"). api.type.modhub
			-- (the helper's type) is not api.modhub: its methods are held by the banned names of the test above.
			local code = line:gsub('"[^"]*"', '""'):gsub("'[^']*'", "''"):gsub("%-%-.*$", "")
			local at = 1
			while true do
				local s, e = code:find("api%s*%.%s*modhub", at)
				if not s then break end
				uses = uses + 1
				local name = code:sub(e + 1):match("^%s*%.%s*([%a_][%w_]*)%s*%(")
				truthy(name and allowed[name], path .. ":" .. lineNo .. " uses api.modhub "
					.. (name and ("." .. name .. ", not on the list") or "other than as a call of a listed function")
					.. ": " .. line)
				at = e + 1
			end
		end
	end
	p:close()
	truthy(n > 5, "found the content files"); truthy(uses >= 10, "found the uses: " .. uses)
end)

---------------------------------------------------------------------------------------------------------------------
-- build: one construction put on the map (a SimpleProposal), and ones the probe built taken away

test("core.buildRequest: res, at (z optional), angle, params, seed, name; remove; every bad value refused", function()
	local r = core.buildRequest({ res = " m::/a/ramp.con ", at = "10,20" })
	eq(r.res, "m::/a/ramp.con"); eq(r.x, 10); eq(r.y, 20); eq(r.z, nil); eq(r.angle, 0); eq(r.seed, 1); eq(r.dryRun, false)
	eq(r.params, nil); eq(r.name, nil)
	local r2 = core.buildRequest({ res = "x.con", at = { 1, 2, 30 }, angle = 1.5, params = { rbr_height = 8, modules = { [1] = { name = "a.module" } } },
		seed = 7, name = "Ramp A", dryRun = true })
	eq(r2.z, 30); eq(r2.angle, 1.5); eq(r2.params.rbr_height, 8); eq(r2.seed, 7); eq(r2.name, "Ramp A"); eq(r2.dryRun, true)
	eq(core.buildRequest({ remove = 5001 }).remove[1], 5001)
	eq(#core.buildRequest({ remove = { 5001, "5002", 5001 } }).remove, 2, "ids as text, each once")
	eq(core.buildRequest({ removeAll = true }).removeAll, true)
	for _, bad in ipairs({
		{ nil, "give res" }, { { res = "", at = "1,2" }, "give res" }, { { res = "a@1", at = "1,2" }, "give res" },
		{ { res = 5, at = "1,2" }, "give res" }, { { res = "a.con" }, "give at" }, { { res = "a.con", at = "1" }, "at least x,y" },
		{ { res = "a.con", at = "1,2,3,4" }, "at most 3" }, { { res = "a.con", at = "a,b" }, "finite" },
		{ { res = "a.con", at = "200000,0" }, "within" }, { { res = "a.con", at = "1,2,9000" }, "z must" },
		{ { res = "a.con", at = "1,2", angle = 7 }, "angle" }, { { res = "a.con", at = "1,2", params = 3 }, "params must" },
		{ { res = "a.con", at = "1,2", params = { 1, 2 } }, "keys must" },
		{ { res = "a.con", at = "1,2", params = { a = function() end } }, "params: holds a function" },
		{ { res = "a.con", at = "1,2", seed = -1 }, "seed" }, { { res = "a.con", at = "1,2", seed = 1.5 }, "seed" },
		{ { res = "a.con", at = "1,2", name = " " }, "name" },
		{ { res = "a.con", at = "1,2", name = ("x"):rep(core.MAX_NAME_LEN + 1) }, "longer" },
		{ { remove = -1 }, "not an entity id" }, { { remove = {} }, "at least one" }, { { remove = 1, res = "a.con" }, "alone" },
		{ { remove = 1, removeAll = true }, "not both" },
	}) do
		local ok, err = core.buildRequest(bad[1])
		eq(ok, nil, bad[2])
		truthy(tostring(err):find(bad[2], 1, true), tostring(err) .. " / wanted " .. bad[2])
	end
	local many = {}
	for i = 1, core.BUILD_LIMITS.remove + 1 do many[i] = i end
	truthy(select(2, core.buildRequest({ remove = many })):find("at most"))
end)

test("core.buildDefaults / buildParams / buildResCandidates / buildRemovable", function()
	local d = core.buildDefaults({ { key = "len", numbers = { 40, 60, 100 }, defaultIndex = 3 }, { key = "kind", defaultIndex = 2 },
		{ key = "", defaultIndex = 1 }, { defaultIndex = 1 }, "junk", { key = "odd", numbers = { 1 }, defaultIndex = 4 } })
	eq(d.len, 100, "numbers[defaultIndex], as the base's menu"); eq(d.kind, 2, "no numbers: the index")
	eq(d.odd, 4, "an index past the numbers: the index"); eq(d[""], nil)
	eq(next(core.buildDefaults(nil)), nil)
	local p = core.buildParams({ len = 100, kind = 2 }, { kind = 5, extra = 1 }, 9)
	eq(p.len, 100); eq(p.kind, 5); eq(p.extra, 1); eq(p.seed, 9); eq(p[core.BUILD_MARK], 1, "the probe's mark")
	eq(core.buildParams({}, { seed = 3 }, 9).seed, 3, "a seed given in params wins")
	local c = core.buildResCandidates("depots/water/x.con.lua")
	eq(c[1], "depots/water/x.con.lua"); eq(c[2], "depots/water/x.con"); eq(c[3], "::/depots/water/x.con")
	eq(#core.buildResCandidates("m::/a.con"), 1, "a mod's name has its ::")
	eq(#core.buildResCandidates("::/a.con"), 1)
	local rec = { res = "m::/r.con", x = 100, y = 200 }
	local function con(t)
		local c = { fileName = "m::/r.con", x = 100, y = 200, name = "Ramp", marked = false }
		for k, v in pairs(t or {}) do c[k] = v end
		return c
	end
	truthy(core.buildRemovable(rec, con()), "what this load built, as built")
	truthy(core.buildRemovable(rec, con({ x = 100.5, y = 199.5 })), "within a metre")
	-- the id given again to something else (a town's building after ours went): refused, with why
	local ok, why = core.buildRemovable(rec, con({ fileName = "::/building/town/house.con", name = "House" }))
	truthy(not ok and why:find("given again"), why)
	truthy(not core.buildRemovable(rec, con({ x = 140 })), "the same file elsewhere")
	truthy(not core.buildRemovable(rec, con({ x = false })), "no position read")
	-- after a load: the name and the mark, both
	truthy(core.buildRemovable(nil, con({ name = core.BUILD_NAME_PREFIX .. " 3", marked = true })))
	truthy(not core.buildRemovable(nil, con({ name = core.BUILD_NAME_PREFIX .. " 3" })), "a probe-build name alone is not enough")
	truthy(not core.buildRemovable(nil, con({ marked = true })), "the mark alone neither")
	truthy(not core.buildRemovable(nil, nil)); truthy(not core.buildRemovable(rec, {}))
	truthy(core.CHANGES_GAME.build and core.COMMANDS.build and not core.MENU_COMMANDS.build)
end)

local RAMP = "road_bridge_ramp::/road_bridge_ramp/ramp.con"
local function buildWorld(spec, gameOpts)
	local g = newGame(gameOpts or { saves = SAVES })
	spec = spec or {}
	spec.cons = spec.cons or {
		[RAMP] = { cost = 5000, params = { { key = "rbr_height", numbers = { 2, 4, 8 }, defaultIndex = 3 },
			{ key = "rbr_side", numbers = { 1, 2 }, defaultIndex = 1 } },
			shape = { nodes = { { 0, 0, 0 }, { 40, 0, 4 }, { 80, 0, 8 } }, edges = { { 1, 2 }, { 2, 3 } } } },
		["::/depots/water/ship_depot.con"] = { cost = 20000, depots = 1 },
	}
	fake.installBuild(g, spec)
	frames(g, 2)
	return g
end
local function buildRun(g, id, argsLua, n)
	send(g, id, "build", argsLua)
	frames(g, n or FIRST + 20)
	return final(g, id)
end

test("build: a ramp at x,y on the terrain, turned, with its defaults; the answer has its id and free ends", function()
	local g = buildWorld({ height = function(x, y) return 0.1 * x end })
	local bal = g.balance
	local a, n = buildRun(g, 900, string.format('{ res = %q, at = "100,200", angle = %s, params = { rbr_side = 2 } }', RAMP, math.pi / 2))
	eq(n, 1, "one final answer")
	truthy(a.ok, a.error)
	eq(a.zFrom, "terrain"); eq(a.at.z, 10, "the terrain's height at 100,200")
	local e = a.entity
	truthy(g.built[e], "built")
	local b = g.built[e]
	eq(b.fileName, RAMP); eq(b.params.rbr_height, 8, "the default"); eq(b.params.rbr_side, 2, "the request's")
	eq(b.params.seed, 1, "a seed"); eq(b.player, 99); eq(b.name, core.BUILD_NAME_PREFIX .. " 1"); eq(b.autoFillSlots, true)
	eq(b.transf[13], 100); eq(b.transf[14], 200); eq(b.transf[15], 10)
	truthy(math.abs(b.transf[1]) < 1e-9 and math.abs(b.transf[2] - 1) < 1e-9, "turned a quarter about z")
	local cmd = g.buildCmds[1]
	eq(cmd.ignoreErrors, false, "errors not ignored"); eq(cmd.playerInitiated, true)
	eq(cmd.context.player, 99); eq(cmd.context.gatherBuildings, false, "nothing knocked down"); eq(cmd.context.gatherFields, false)
	eq(a.cost, 5000); eq(a.spent, 5000); eq(g.balance, bal - 5000)
	-- the ramp's two free ends, its middle node not: turned, so the far end is 80 m up the y axis
	eq(#a.construction.ends, 2)
	local far = a.construction.ends[2]
	truthy(math.abs(far.x - 100) < 1e-6 and math.abs(far.y - 280) < 1e-6 and far.z == 18, "far end " .. tostring(far.x) .. "," .. tostring(far.y))
	eq(a.construction.fileName, RAMP)
	truthy(a.note:find("not checked in a game"))
	-- a given z is used as it is; a second build gets the next name
	local a2 = buildRun(g, 901, string.format('{ res = %q, at = { 500, 0, 42 } }', RAMP))
	truthy(a2.ok, a2.error); eq(a2.zFrom, "given"); eq(g.built[a2.entity].transf[15], 42)
	eq(g.built[a2.entity].name, core.BUILD_NAME_PREFIX .. " 2")
	truthy(not g.crashed, g.crashed)
end)

test("build: a depot's id comes back (to buy at); the base game's name without ::/ is found", function()
	local g = buildWorld()
	local a = buildRun(g, 910, '{ res = "depots/water/ship_depot.con.lua", at = "0,0", name = "Yard" }')
	truthy(a.ok, a.error)
	eq(a.res, "::/depots/water/ship_depot.con")
	eq(#a.construction.depots, 1); eq(a.construction.name, "Yard")
	eq(g.built[a.entity].name, "Yard")
end)

test("build: refused by the engine (collision, money): nothing built, the messages and the collision in the error", function()
	local g = buildWorld({ blocked = function(x) return x > 1000 and 4242 or nil end })
	local a, n = buildRun(g, 920, string.format('{ res = %q, at = "2000,0" }', RAMP))
	eq(n, 1); eq(a.ok, false)
	truthy(a.error:find("refused") and a.error:find("Collision"), a.error)
	eq(a.collisions[1], 4242); eq(a.critical, true)
	eq(next(g.built), nil, "nothing built")
	local logged = false
	for _, l in ipairs(g.logs) do if tostring(l):find("build place %(command 920%): refused") then logged = true end end
	truthy(logged, "the refusal is logged")
	g.balance = 100
	local a2 = buildRun(g, 921, string.format('{ res = %q, at = "0,0" }', RAMP))
	eq(a2.ok, false); truthy(a2.error:find("Not enough money"), a2.error)
	eq(g.balance, 100)
end)

test("build: the engine says success and builds nothing (a construction's script failed): not ok, says why", function()
	local HARBOUR = "::/stations/water/harbor_modular.con"
	local g = buildWorld({ cons = {
		[HARBOUR] = { cost = 90000, scriptFails = true },
		["::/odd.con"] = { cost = 10, otherResult = true },
		["::/free.con"] = { cost = 0 },
		["::/hidden.con"] = { cost = 30, notInResult = true },
	} })
	local bal = g.balance
	local a, n = buildRun(g, 925, string.format('{ res = %q, at = "0,0" }', HARBOUR))
	eq(n, 1, "one final answer")
	eq(a.ok, false, "measured 2026-11-22: ok true came back for a harbour that was not there")
	truthy(a.error:find("nothing was built") and a.error:find("no entities") and a.error:find("nothing was paid")
		and a.error:find("Error during construction update"), a.error)
	eq(a.entity, nil); eq(a.construction, nil); eq(#a.entities, 0); eq(a.cost, 0); eq(a.spent, 0)
	eq(a.why, nil, "no 'built, but' text")
	eq(next(g.built), nil, "nothing built"); eq(g.balance, bal)
	local logged = false
	for _, l in ipairs(g.logs) do if tostring(l):find("build place %(command 925%): nothing built") then logged = true end end
	truthy(logged, "logged")
	truthy(buildRun(g, 926, "{ removeAll = true }").error:find("built nothing"), "nothing listed as the probe's")
	-- an entity that is no construction
	local b = buildRun(g, 927, '{ res = "::/odd.con", at = "0,0" }')
	eq(b.ok, false); truthy(b.error:find("no construction is among"), b.error); eq(#b.entities, 1)
	-- one that stands but cost nothing (a no-costs mod): ok, with a warning
	local c = buildRun(g, 928, '{ res = "::/free.con", at = "0,0" }')
	truthy(c.ok, c.error); truthy(g.built[c.entity], "built")
	truthy(c.warnings[#c.warnings]:find("cost nothing"), tostring(c.warnings[#c.warnings]))
	-- built but not among the result's entities: found by its name near the point, ok and listed as the probe's
	local h = buildRun(g, 929, '{ res = "::/hidden.con", at = "300,0" }')
	truthy(h.ok, h.error); truthy(g.built[h.entity], "built"); truthy(h.why:find("found by its name"), h.why)
	local rm = buildRun(g, 931, "{ removeAll = true }").removed
	eq(#rm, 2, "the free one and this one"); eq(rm[2], h.entity, "removeAll takes it")
	truthy(not g.crashed, g.crashed)
end)

test("build: an unknown name is refused before anything is sent, with names like it", function()
	local g = buildWorld()
	local a = buildRun(g, 930, '{ res = "road_bridge_ramp::/ramp.con", at = "0,0" }')
	eq(a.ok, false)
	truthy(a.error:find("no construction") and a.error:find(RAMP, 1, true), a.error)
	eq(#g.buildCmds, 0, "nothing sent")
	local a2 = buildRun(g, 931, '{ res = "nothing_like_it.con", at = "0,0" }')
	truthy(a2.error:find("no construction") and not a2.error:find("names like it"), a2.error)
	local a3 = buildRun(g, 932, '{ res = "a.con" }')
	truthy(a3.error:find("give at"), a3.error)
	truthy(not g.crashed, g.crashed)
end)

test("build --dry-run: no engine check (makeProposalData takes no SimpleProposal); name, params, height, what is near", function()
	local g = buildWorld()
	local a0 = buildRun(g, 939, string.format('{ res = %q, at = "1000,0" }', RAMP))
	truthy(a0.ok, a0.error)
	local n = #g.buildCmds
	local a = buildRun(g, 940, string.format('{ res = %q, at = "1010,5", dryRun = true, params = { rbr_height = 4 } }', RAMP))
	truthy(a.ok and a.dryRun, a.error)
	eq(a.checked, false); eq(a.buildable, nil, "no verdict: only a build has the engine's"); truthy(a.why:find("only comes with a build"))
	eq(a.params.rbr_height, 4); eq(a.at.z, 0); eq(a.res, RAMP)
	eq(#a.near, 1); eq(a.near[1].entity, a0.entity, "the ramp built before, within the radius")
	eq(g.proposalDataCalls, 0, "makeProposalData is never called")
	eq(#g.buildCmds, n, "no command sent")
	local a2 = buildRun(g, 941, string.format('{ res = %q, at = "5000,0", dryRun = true }', RAMP))
	eq(#a2.near, 0)
	truthy(buildRun(g, 942, '{ res = "x.con", at = "0,0", dryRun = true }').error:find("no construction"), "a wrong name")
end)

test("build remove: only what the probe built, as built (file and place) or by its name and mark; removeAll", function()
	local g = buildWorld()
	local a = buildRun(g, 950, string.format('{ res = %q, at = "0,0" }', RAMP))
	local b = buildRun(g, 951, string.format('{ res = %q, at = "300,0", name = "Mine" }', RAMP))
	-- someone else's construction (named otherwise, no mark) is refused, and with it the whole command
	g.built[7777] = { fileName = RAMP, params = {}, transf = { [13] = 900, [14] = 0 }, frozenEdges = {}, depots = {} }
	g.buildNames[7777] = "Coal mine"
	local r = buildRun(g, 952, string.format("{ remove = { %d, 7777 } }", a.entity))
	eq(r.ok, false); truthy(r.error:find("7777") and r.error:find("not built by the probe"), r.error)
	truthy(g.built[a.entity], "nothing removed when one is refused")
	local r2 = buildRun(g, 953, "{ remove = 123456 }")
	truthy(r2.error:find("no construction"), r2.error)
	local r3 = buildRun(g, 954, string.format("{ remove = %d }", a.entity))
	truthy(r3.ok, r3.error); eq(g.built[a.entity], nil, "removed"); eq(r3.removed[1], a.entity)
	-- regression: ours went without the probe seeing it, and the engine gave its id to a town's building. The
	-- probe's list still holds the id: neither remove nor removeAll may take the house
	local c = buildRun(g, 955, string.format('{ res = %q, at = "600,0" }', RAMP))
	g.built[c.entity] = { fileName = "::/building/town/house.con", params = {}, transf = { [13] = 610, [14] = 3 },
		frozenEdges = {}, depots = {} }
	g.buildNames[c.entity] = "House"
	local r4 = buildRun(g, 956, string.format("{ remove = %d }", c.entity))
	truthy(not r4.ok and r4.error:find("given again"), r4.error)
	truthy(g.built[c.entity], "the house stays")
	-- removeAll: b goes; c (now the house) is forgotten, not removed; the other one was never ours
	local r5 = buildRun(g, 957, "{ removeAll = true }")
	truthy(r5.ok, r5.error); eq(#r5.removed, 1); eq(r5.removed[1], b.entity); eq(g.built[b.entity], nil)
	eq(r5.forgotten[1], c.entity); truthy(g.built[c.entity], "the house stays"); truthy(g.built[7777], "not ours: kept")
	truthy(buildRun(g, 958, "{ removeAll = true }").error:find("built nothing"), "the list is empty now")
	-- after a load the probe's list is empty: a construction named probe-build... with the mark is still its own;
	-- the name alone (a player's own "probe-build" or one without the mark) is not
	local g2 = buildWorld()
	g2.built[8888] = { fileName = RAMP, params = { [core.BUILD_MARK] = 1 }, transf = { [13] = 0, [14] = 0 }, frozenEdges = {}, depots = {} }
	g2.buildNames[8888] = core.BUILD_NAME_PREFIX .. " 4"
	g2.built[8889] = { fileName = RAMP, params = {}, transf = { [13] = 50, [14] = 0 }, frozenEdges = {}, depots = {} }
	g2.buildNames[8889] = core.BUILD_NAME_PREFIX .. " 5"
	truthy(not buildRun(g2, 959, "{ remove = 8889 }").ok, "no mark: refused")
	local r6 = buildRun(g2, 960, "{ remove = 8888 }")
	truthy(r6.ok, r6.error); eq(g2.built[8888], nil); truthy(g2.built[8889])
	truthy(buildRun(g2, 961, "{ removeAll = true }").error:find("built nothing"))
	-- what the probe builds carries the mark, so it can be removed by name after a load
	local d = buildRun(g2, 962, string.format('{ res = %q, at = "900,900" }', RAMP))
	eq(g2.built[d.entity].params[core.BUILD_MARK], 1)
	truthy(not g.crashed and not g2.crashed)
end)

test("build: no callback: found by its name near the point, else an error with the way to find it; the callback guarded", function()
	-- built, but the callback never came: found by its name and file near the point, and the probe's from then on
	local lostSpec = { lostCallback = true }
	local g = buildWorld(lostSpec)
	send(g, 960, "build", string.format('{ res = %q, at = "0,0" }', RAMP))
	frames(g, FIRST + 20)
	eq(final(g, 960), nil, "no answer yet")
	frames(g, 200, 0.2)
	local a = final(g, 960)
	truthy(a and a.ok and a.entity and a.why:find("found by its name"), a and (a.error or a.why))
	truthy(g.built[a.entity])
	lostSpec.lostCallback = false
	local r = buildRun(g, 963, string.format("{ remove = %d }", a.entity))
	truthy(r.ok, "removable as the probe's: " .. tostring(r.error))
	-- refused and no callback (nothing built): an error after the wait, naming what to look for
	local g3 = buildWorld({ lostCallback = true, blocked = function() return 1 end })
	send(g3, 964, "build", string.format('{ res = %q, at = "0,0" }', RAMP))
	frames(g3, FIRST + 20)
	frames(g3, 200, 0.2)
	local e3, n3 = final(g3, 964)
	eq(n3, 1); truthy(e3.error:find("no answer from the engine") and e3.error:find("nothing named probe%-build 1"), e3.error)
	-- a send that raises: one error answer, and no second one when the wait runs out
	local g2 = buildWorld({ sendRaises = "bad proposal" })
	send(g2, 962, "build", string.format('{ res = %q, at = "0,0" }', RAMP))
	frames(g2, FIRST + 20)
	frames(g2, 200, 0.2)
	local e2, n2 = final(g2, 962)
	eq(n2, 1); truthy(e2.error:find("bad proposal"), e2.error)
	local timeouts = 0
	for _, l in ipairs(g2.logs) do if tostring(l):find("no answer from the engine") then timeouts = timeouts + 1 end end
	eq(timeouts, 0, "no job left waiting")
	-- the callback's data raises when read: nothing escapes the callback, and the command still ends
	local g4 = buildWorld({ raiseInCallback = true })
	local a4, n4 = buildRun(g4, 965, string.format('{ res = %q, at = "0,0" }', RAMP))
	eq(n4, 1); truthy(a4 ~= nil, "answered")
	truthy(not g4.crashed)
	local m = newGame({ saves = SAVES, menu = true })
	frames(m, 2)
	send(m, 961, "build", string.format('{ res = %q, at = "0,0" }', RAMP))
	frames(m, FIRST)
	truthy((answerText(m, 961, "error") or ""):find("needs a running game"))
end)

---------------------------------------------------------------------------------------------------------------------
-- build with modules (a modular harbour), with no owner (an industry), and water (read only)

test("core.buildModules: text slot ids become whole numbers; variant 0 by default; bad modules refused", function()
	local m = core.buildModules({ ["12"] = { name = " a.module " }, [3] = { name = "b.module", variant = 2 } })
	eq(m["12"], nil, "no text key left"); eq(m[12].name, "a.module"); eq(m[12].variant, 0); eq(m[3].variant, 2)
	eq(type(next(m)), "number")
	local r = core.buildRequest({ res = "h.con", at = "1,2", params = { size = 1, modules = { ["7"] = { name = "x.module" } } } })
	eq(r.modules, true); eq(r.params.modules[7].name, "x.module"); eq(r.params.size, 1)
	eq(r.fillModules, true, "on by default"); eq(r.noOwner, false)
	local r2 = core.buildRequest({ res = "h.con", at = "1,2", fillModules = false, noOwner = true })
	eq(r2.fillModules, false); eq(r2.noOwner, true); eq(r2.modules, nil, "no modules given")
	for _, bad in ipairs({
		{ "x", "JSON object" }, { { a = { name = "x" } }, "whole numbers" }, { { ["-1"] = { name = "x" } }, "whole numbers" },
		{ { [1.5] = { name = "x" } }, "whole numbers" }, { { ["1"] = { name = "x" }, [1] = { name = "y" } }, "twice" },
		{ { [1] = "x" }, "give the module's name" }, { { [1] = { name = " " } }, "give the module's name" },
		{ { [1] = { name = "x", variant = -1 } }, "variant" }, { { [1] = { name = "x", metadata = 3 } }, "metadata" },
		{ { [1] = { name = "x", updateScript = { params = {} } } }, "updateScript" }, { {}, "at least one module" },
	}) do
		local ok, err = core.buildModules(bad[1])
		eq(ok, nil, bad[2]); truthy(tostring(err):find(bad[2], 1, true), tostring(err) .. " / wanted " .. bad[2])
	end
	truthy(select(2, core.buildRequest({ res = "h.con", at = "1,2", params = { modules = { a = { name = "x" } } } })):find("params.modules"))
	truthy(select(2, core.buildRequest({ res = "h.con", at = "1,2", noOwner = 1 })):find("noOwner"))
	truthy(select(2, core.buildRequest({ res = "h.con", at = "1,2", fillModules = "no" })):find("fillModules"))
	-- fillModule: only what is missing, the desc's own values
	local md = { price = 5 }
	local mod = { name = "x", variant = 0 }
	local f = core.fillModule(mod, { metadata = md, updateScript = { fileName = "s", params = {} } })
	eq(#f, 2); truthy(mod.metadata == md, "the rep's value itself"); eq(mod.updateScript.fileName, "s")
	local own = { name = "x", variant = 0, metadata = { mine = 1 } }
	eq(#core.fillModule(own, { metadata = md }), 0); eq(own.metadata.mine, 1, "a given metadata stays")
end)

test("core.waterRequest: a point or a grid; the grid's points and its limit; waterRows", function()
	local r = core.waterRequest({ at = "10,-20" })
	eq(#r.points, 1); eq(r.points[1].x, 10); eq(r.points[1].y, -20); eq(r.grid, nil)
	local g = core.waterRequest({ grid = "0,0,100,50,50" })
	eq(g.grid.nx, 3); eq(g.grid.ny, 2); eq(#g.points, 6)
	eq(g.points[4].x, 0); eq(g.points[4].y, 50, "row by row, y0 first")
	eq(#core.waterRequest({ grid = { 0, 0, 0, 0, 1 } }).points, 1, "one point")
	local n = core.WATER_MAX_POINTS
	eq(#core.waterRequest({ grid = string.format("0,0,%d,0,1", n - 1) }).points, n, "the limit itself")
	truthy(select(2, core.waterRequest({ grid = string.format("0,0,%d,0,1", n) })):find("at most " .. n))
	for _, bad in ipairs({ { {}, "give at" }, { { at = "1,2", grid = "0,0,1,1,1" }, "give at" }, { { at = "1" }, "x,y" },
		{ { at = "1,2,3" }, "at most 2" }, { { at = "200000,0" }, "within" }, { { grid = "0,0,1,1" }, "x0,y0,x1,y1,step" },
		{ { grid = "5,0,1,1,1" }, "x0 <= x1" }, { { grid = "0,0,1,1,0" }, "step" }, { { grid = "0,0,1,1,-1" }, "step" },
		{ { grid = "0,0,1e6,1,1" }, "within" }, { { at = "a,b" }, "finite" }, { { grid = "0,0,1,1,1e-300" }, "at least" },
		{ { grid = "0,0,1,1,0.05" }, "at least" }, { { grid = "0,0,1,1,inf" }, "finite" } }) do
		local ok, err = core.waterRequest(bad[1])
		eq(ok, nil, bad[2]); truthy(tostring(err):find(bad[2], 1, true), tostring(err) .. " / wanted " .. bad[2])
	end
	local rows = core.waterRows({ { onWater = true }, { onWater = false }, { onWater = nil }, { onWater = true } }, 2)
	eq(rows[1], "~."); eq(rows[2], "?~")
	truthy(core.COMMANDS.water and not core.CHANGES_GAME.water and not core.MENU_COMMANDS.water, "read only, in a game")
end)

local HARBOR = "::/stations/water/harbor_modular.con"
local QUAY = "::/station/water/harbor_quay.module"
local function harborWorld(spec)
	spec = spec or {}
	spec.cons = {
		[HARBOR] = { cost = 30000, stations = 1, params = { { key = "size", numbers = { 1, 2 }, defaultIndex = 1 } },
			-- a terminal per module on a whole-number slot (one under a text key sits on no slot)
			terminals = function(params)
				local n = 0
				for k in pairs(params.modules or {}) do if type(k) == "number" then n = n + 1 end end
				return n
			end },
		[RAMP] = { cost = 5000, params = {} },
		["::/industry/coal_mine.con"] = { cost = 0 },
	}
	spec.modules = spec.modules or {
		[QUAY] = { metadata = { harbor = { quay = true } }, updateScript = { fileName = "construction/harbor_quay.updateFn", params = { n = 1 } } },
		["::/station/water/harbor_crane.module"] = { metadata = { crane = 1 } },
	}
	spec.waterLevel = spec.waterLevel or 5
	spec.water = spec.water or function(x) return x >= 1000 end
	spec.height = spec.height or function(x) return x >= 1000 and -3 or 8 end
	return buildWorld(spec)
end

test("build: a harbour's modules on whole-number slots, autoFillSlots off, metadata filled; terminals in the answer", function()
	local g = harborWorld()
	-- as the tool writes a JSON object: the slot id as text
	local a = buildRun(g, 970, string.format('{ res = %q, at = "990,0", params = { modules = { ["120001"] = { name = %q } } } }', HARBOR, QUAY))
	truthy(a.ok, a.error)
	local b = g.built[a.entity]
	eq(b.autoFillSlots, false, "modules given: only those"); eq(a.autoFillSlots, false)
	local m = b.params.modules[120001]
	truthy(m, "on a whole-number slot"); eq(b.params.modules["120001"], nil)
	eq(m.name, QUAY); eq(m.variant, 0)
	eq(m.metadata.harbor.quay, true, "metadata from moduleRep"); eq(m.updateScript.fileName, "construction/harbor_quay.updateFn")
	eq(m.updateScript.params.n, 1)
	eq(a.params.modules[1].slot, 120001); eq(a.params.modules[1].filled[1], "metadata"); eq(a.params.modules[1].filled[2], "updateScript")
	eq(a.terminals, 1); eq(a.stationTerminals[1].terminals, 1); eq(a.warning, nil)
	truthy(a.modulesNote:find("not checked in a game"))
	-- given metadata stays; fill off sends name and variant only
	local a2 = buildRun(g, 971, string.format('{ res = %q, at = "1200,0", params = { modules = { [5] = { name = %q, variant = 1, metadata = { own = 2 } } } } }', HARBOR, QUAY))
	truthy(a2.ok, a2.error)
	local m2 = g.built[a2.entity].params.modules[5]
	eq(m2.metadata.own, 2); eq(m2.metadata.harbor, nil); eq(m2.variant, 1); eq(m2.updateScript.fileName, "construction/harbor_quay.updateFn")
	local a3 = buildRun(g, 972, string.format('{ res = %q, at = "1400,0", fillModules = false, params = { modules = { [5] = { name = %q } } } }', HARBOR, QUAY))
	truthy(a3.ok, a3.error)
	local m3 = g.built[a3.entity].params.modules[5]
	eq(m3.metadata, nil); eq(m3.updateScript, nil); eq(a3.params.modules[1].filled, nil)
	truthy(a3.moduleWarnings and a3.moduleWarnings[1]:find("slot 5: .* goes without metadata"), "no metadata: warned")
	eq(a.moduleWarnings, nil)
	-- no modules: as before (autoFillSlots on); a station with 0 terminals is warned about
	local a4 = buildRun(g, 973, string.format('{ res = %q, at = "1600,0" }', HARBOR))
	truthy(a4.ok, a4.error)
	eq(g.built[a4.entity].autoFillSlots, true); eq(a4.autoFillSlots, true); eq(a4.modulesNote, nil)
	eq(a4.terminals, 0); truthy(a4.warning and a4.warning:find("0 terminals"), a4.warning)
	-- a construction without stations: no terminals in the answer
	local a5 = buildRun(g, 974, string.format('{ res = %q, at = "0,0" }', RAMP))
	eq(a5.terminals, nil); eq(a5.warning, nil)
	truthy(not g.crashed, g.crashed)
end)

test("build: a module the rep does not know is refused before anything is sent, with names like it", function()
	local g = harborWorld()
	local a = buildRun(g, 975, string.format('{ res = %q, at = "990,0", params = { modules = { [1] = { name = %q }, [2] = { name = "::/station/water/harbor_quai.module" } } } }', HARBOR, QUAY))
	eq(a.ok, false)
	truthy(a.error:find("slot 2: no module ::/station/water/harbor_quai.module", 1, true), a.error)
	truthy(not a.error:find("slot 1"), "the known one is not named")
	truthy(a.error:find("names like it") and a.error:find("harbor_crane.module", 1, true), a.error)
	eq(#g.buildCmds, 0, "nothing sent")
	local a2 = buildRun(g, 976, string.format('{ res = %q, at = "990,0", dryRun = true, params = { modules = { [1] = { name = "zzz" } } } }', HARBOR))
	truthy(a2.error:find("no module zzz"), "the dry run checks the names too: " .. tostring(a2.error))
	local a3 = buildRun(g, 977, string.format('{ res = %q, at = "990,0", params = { modules = { a = { name = %q } } } }', HARBOR, QUAY))
	truthy(a3.error:find("whole numbers"), a3.error)
end)

test("build --no-owner: playerEntity -1 (an industry); the default is the company", function()
	local g = harborWorld()
	local a = buildRun(g, 978, '{ res = "::/industry/coal_mine.con", at = "0,0", noOwner = true }')
	truthy(a.ok, a.error); eq(g.built[a.entity].player, -1); eq(a.owner, "none")
	local a2 = buildRun(g, 979, '{ res = "::/industry/coal_mine.con", at = "300,0" }')
	eq(g.built[a2.entity].player, 99); eq(a2.owner, nil)
end)

test("build --dry-run: the water level and whether the point is water", function()
	local g = harborWorld()
	local a = buildRun(g, 980, string.format('{ res = %q, at = "1100,0", dryRun = true, params = { modules = { ["9"] = { name = %q } } } }', HARBOR, QUAY))
	truthy(a.ok and a.dryRun, a.error)
	eq(a.waterLevel, 5); eq(a.onWater, true); eq(a.params.modules[1].slot, 9); eq(a.params.modules[1].metadata, true)
	local a2 = buildRun(g, 981, string.format('{ res = %q, at = "100,0", dryRun = true }', HARBOR))
	eq(a2.onWater, false); eq(a2.waterLevel, 5)
	eq(#g.buildCmds, 0)
end)

test("water: a point and a grid (water, land, height, depth, rows); the limit; read only, needs a game", function()
	local g = harborWorld()
	send(g, 985, "water", '{ at = "1100,0" }')
	frames(g, FIRST + 2)
	local a = final(g, 985)
	truthy(a and a.ok and a.waterLevel == 5, a and a.error)
	eq(#a.points, 1); eq(a.points[1].onWater, true); eq(a.points[1].height, -3); eq(a.points[1].depth, 8)
	eq(a.water, 1); eq(a.land, 0); eq(a.rows, nil)
	send(g, 986, "water", '{ grid = "900,0,1100,100,100" }')
	frames(g, FIRST + 2)
	local b = final(g, 986)
	eq(#b.points, 6); eq(b.grid.nx, 3); eq(b.grid.ny, 2); eq(b.water, 4); eq(b.land, 2)
	eq(b.rows[1], ".~~"); eq(b.rows[2], ".~~")
	eq(b.points[1].onWater, false); eq(b.points[1].height, 8); eq(b.points[1].depth, nil)
	send(g, 987, "water", '{ grid = "0,0,10000,10000,10" }')
	frames(g, FIRST + 2)
	truthy((answerText(g, 987, "error") or ""):find("at most"), "the limit")
	eq(#g.buildCmds, 0, "nothing built")
	truthy(not g.crashed, g.crashed)
	local m = newGame({ saves = SAVES, menu = true })
	frames(m, 2)
	send(m, 988, "water", '{ at = "0,0" }')
	frames(m, FIRST)
	truthy((answerText(m, 988, "error") or ""):find("needs a running game"))
end)

test("build: a module's metadata that cannot be read refuses it (fill on); an engine map is turned into a table", function()
	local NATIVE, OPAQUE, NODESC = "::/station/water/a_native.module", "::/station/water/b_opaque.module", "::/station/water/c_nodesc.module"
	local g = harborWorld({ modules = {
		[NATIVE] = { metadata = { platform = true }, metadataNative = true, updateScript = { fileName = "s", params = "x" } },
		[OPAQUE] = { metadata = { platform = true }, metadataOpaque = true },
		[NODESC] = { getFails = true },
	} })
	local a = buildRun(g, 990, string.format('{ res = %q, at = "990,0", params = { modules = { [1] = { name = %q } } } }', HARBOR, NATIVE))
	truthy(a.ok, a.error)
	local m = g.built[a.entity].params.modules[1]
	eq(type(m.metadata), "table", "asTable"); eq(m.metadata.platform, true)
	eq(type(m.updateScript.params), "table", "params not a table: empty"); eq(next(m.updateScript.params), nil)
	for i, name in ipairs({ OPAQUE, NODESC }) do
		local n = #g.buildCmds
		local b = buildRun(g, 990 + i, string.format('{ res = %q, at = "990,0", params = { modules = { [7] = { name = %q } } } }', HARBOR, name))
		eq(b.ok, false)
		truthy(b.error:find("nothing sent: slot 7: metadata of " .. name .. " could not be read", 1, true), b.error)
		eq(#g.buildCmds, n, "nothing sent")
	end
	-- metadata given: the desc's is not needed
	local c = buildRun(g, 995, string.format('{ res = %q, at = "1200,0", params = { modules = { [7] = { name = %q, metadata = { platform = false } } } } }', HARBOR, OPAQUE))
	truthy(c.ok, c.error)
	-- fill off: sent without metadata, with a warning
	local d = buildRun(g, 996, string.format('{ res = %q, at = "1400,0", fillModules = false, params = { modules = { [7] = { name = %q } } } }', HARBOR, NODESC))
	truthy(d.ok, d.error); truthy(d.moduleWarnings and d.moduleWarnings[1]:find("without metadata"))
	truthy(not g.crashed, g.crashed)
end)

test("water and the dry run: a point off the map is not asked (isOnWater would assert): onWater nil, ? in the rows", function()
	local g = harborWorld({ bounds = { -2000, -2000, 2000, 2000 } })
	send(g, 997, "water", '{ grid = "1900,0,2100,0,100" }')
	frames(g, FIRST + 2)
	local a = final(g, 997)
	truthy(a and a.ok, a and a.error)
	eq(a.rows[1], "~~?"); eq(a.points[3].onWater, nil); eq(a.points[3].offMap, true); eq(a.offMap, 1)
	eq(a.water, 2); eq(a.land, 0)
	local b = buildRun(g, 998, string.format('{ res = %q, at = "2500,0", dryRun = true }', HARBOR))
	truthy(b.ok, b.error); eq(b.onWater, nil); eq(b.offMap, true)
	truthy(not g.crashed, g.crashed)
end)

-- road: one straight piece. Streets: the base's two medium town roads (old until 1940, new from then), a small
-- one and a track; a road network with a free end at node 8001 (100, 0, 2), its piece 8100 to node 8002
local TOWN_OLD = "::/infrastructure/street/town/town_old_medium.street_template"
local TOWN_NEW = "::/infrastructure/street/town/town_new_medium.street_template"
local TOWN_SMALL = "::/infrastructure/street/town/town_new_small.street_template"
local TRACK_STD = "::/infrastructure/track/standard/standard.street_template"
local function roadWorld(spec)
	spec = spec or {}
	spec.streets = spec.streets or { [TOWN_OLD] = { yearTo = 1940, cost = 10 }, [TOWN_NEW] = { yearFrom = 1940, cost = 20 },
		[TOWN_SMALL] = { yearFrom = 1940, cost = 5 }, [TRACK_STD] = { roadType = "TRACK" } }
	spec.year = spec.year or 1925
	spec.roads = spec.roads or { nodes = { [8001] = { x = 100, y = 0, z = 2 }, [8002] = { x = 0, y = 0, z = 2 },
		[8003] = { x = 300, y = 300, z = 0 } }, edges = { [8100] = { node0 = 8002, node1 = 8001 } } }
	return buildWorld(spec)
end
local function roadRun(g, id, argsLua, n)
	send(g, id, "road", argsLua)
	frames(g, n or FIRST + 20)
	return final(g, id)
end

test("core.roadRequest: from and to (z optional), snap, type, dry run; every bad value refused", function()
	local r = core.roadRequest({ from = "1,2", to = { 3, 4, 5 } })
	eq(r.from[1], 1); eq(r.from[3], nil); eq(r.to[3], 5); eq(r.snap, 5, "the default"); eq(r.type, nil); eq(r.dryRun, false)
	r = core.roadRequest({ from = "1,2", to = "30,4", snap = 0, type = " town_new_small ", dryRun = true })
	eq(r.snap, 0); eq(r.type, "town_new_small"); eq(r.dryRun, true)
	for _, bad in ipairs({
		{ {}, "give from" }, { { from = "1,2" }, "give to" }, { { from = "1", to = "2,3" }, "at least x,y" },
		{ { from = "1,2,3,4", to = "2,3" }, "at most 3" }, { { from = "a,2", to = "2,3" }, "finite" },
		{ { from = "1e9,2", to = "2,3" }, "within" }, { { from = "1,2,9999", to = "2,3" }, "z must be" },
		{ { from = "0,0", to = "3000,0" }, "at most 2000 m" }, { { from = "0,0", to = "1,0", snap = 21 }, "snap must be" },
		{ { from = "0,0", to = "1,0", snap = -1 }, "snap must be" }, { { from = "0,0", to = "1,0", type = "" }, "type must be" },
		{ { from = "0,0", to = "1,0", type = 5 }, "type must be" },
	}) do
		local ok, err = core.roadRequest(bad[1])
		eq(ok, nil, bad[2]); truthy(tostring(err):find(bad[2], 1, true), tostring(err) .. " / " .. bad[2])
	end
	truthy(core.CHANGES_GAME.road and core.COMMANDS.road and not core.MENU_COMMANDS.road)
end)

test("road: from a free road end (snapped) to a new node on the terrain: the town road of the year, the ids, the cost", function()
	local g = roadWorld({ height = function(x) return 0.01 * x end })
	local bal = g.balance
	local a, n = roadRun(g, 950, '{ from = "102,1", to = "200,0" }')
	eq(n, 1); truthy(a.ok, a.error)
	eq(a.template, TOWN_OLD, "1925: the old medium town road"); eq(a.year, 1925)
	eq(a.from.node, 8001, "snapped to the free end")
	-- in three dimensions: the terrain at x 102 is 1.02, the node at z 2
	truthy(math.abs(a.from.snapped - math.sqrt(5 + 0.98 ^ 2)) < 1e-9, tostring(a.from.snapped))
	eq(g.streetSegmentCalls, nil, "the street system is never asked about a node")
	truthy(g.circleCalls > 0, "road pieces found through the octree util")
	eq(a.from.x, 100); eq(a.from.z, 2, "the node's own position")
	eq(a.to.node, nil); eq(a.to.zFrom, "terrain"); eq(a.to.z, 2); eq(a.newNodes, 1)
	truthy(math.abs(a.length - 100) < 1e-9)
	eq(#a.edges, 1); eq(#a.nodes, 1)
	local ed = g.edges[a.edge]
	eq(ed.node0, 8001); eq(ed.node1, a.nodes[1]); eq(a.node0, 8001); eq(a.node1, a.nodes[1])
	eq(ed.roadTemplate, TOWN_OLD); eq(ed.roadType, "STREET"); eq(ed.player, 99, "the company's")
	eq(a.cost, 1000); eq(a.spent, 1000); eq(g.balance, bal - 1000)
	-- what was sent: a straight piece (both tangents the chord), plain, the template's lanes and style
	local sent = g.streetCmds[1]
	eq(sent.type, 0); eq(sent.comp.typeIndex, -1); eq(sent.comp.type, 0); eq(sent.comp.roadType, 0)
	eq(sent.comp.tangent0.x, 100); eq(sent.comp.tangent1.x, 100); eq(sent.comp.tangent0.z, 0)
	eq(#sent.comp.laneConfigs, 4); eq(sent.comp.roadStyle, TOWN_OLD .. ".style")
	eq(sent.entity, -2, "new entities counted down: the node -1, the piece -2"); eq(sent.comp.node1, -1)
	local cmd = g.buildCmds[1]
	eq(cmd.ignoreErrors, false); eq(cmd.context.gatherBuildings, false)
	truthy(a.note:find("not checked in a game"))
	-- 1950: the new one; a type by its file name; both ends new (snap 0)
	g = roadWorld({ year = 1950 })
	a = roadRun(g, 951, '{ from = "0,500", to = "0,600" }')
	truthy(a.ok, a.error); eq(a.template, TOWN_NEW)
	a = roadRun(g, 952, '{ from = "101,0", to = "101,50", snap = 0, type = "town_new_small" }')
	truthy(a.ok, a.error); eq(a.template, TOWN_SMALL); eq(a.from.node, nil, "snap 0: never joined"); eq(a.newNodes, 2)
	truthy(not g.crashed, g.crashed)
end)

test("road: refused before sending (a track type, a year, an unknown type, the same node, too short)", function()
	local g = roadWorld()
	for i, case in ipairs({
		{ '{ from = "0,500", to = "0,600", type = %q }', TRACK_STD, "track type" },
		{ '{ from = "0,500", to = "0,600", type = %q }', "town_new_small", "not to be had in 1925" },
		{ '{ from = "0,500", to = "0,600", type = %q }', "nowhere_road", "no street template nowhere_road" },
		{ '{ from = "100,1", to = "%s" }', "101,-1", "both ends are node 8001" },
		{ '{ from = "0,500", to = "%s", snap = 0 }', "0.5,500", "at least 1 m" },
	}) do
		local before = #g.buildCmds
		local a = roadRun(g, 9530 + i, string.format(case[1], case[2]))
		eq(a.ok, false); truthy(tostring(a.error):find(case[3], 1, true), tostring(a.error) .. " / " .. case[3])
		eq(#g.buildCmds, before, "nothing sent")
	end
	-- a node with no road piece (only track there) is not snapped to
	g = roadWorld({ roads = { nodes = { [8001] = { x = 100, y = 0, z = 2 }, [8002] = { x = 0, y = 0, z = 2 } },
		edges = { [8100] = { node0 = 8002, node1 = 8001, roadType = "TRACK" } } } })
	local a = roadRun(g, 954, '{ from = "101,0", to = "101,80" }')
	truthy(a.ok, a.error); eq(a.from.node, nil, "a track end is no road end")
end)

-- review 2026-11-22: nodes are not in the octree (found through their pieces), snap in three dimensions, a piece
-- there before the build never taken for the new one, a road type that cannot be read never taken for a road
test("road snap: through the road pieces' ends, in three dimensions; track pieces and unread road types left out", function()
	-- a bridge's node 8004 right above the point (z 12) and the free end 8001 3 m away on the ground
	local g = roadWorld({ roads = { nodes = { [8001] = { x = 103, y = 0, z = 0 }, [8002] = { x = 0, y = 0, z = 0 },
		[8004] = { x = 100, y = 0, z = 12 }, [8005] = { x = 100, y = 200, z = 12 } },
		edges = { [8100] = { node0 = 8002, node1 = 8001 }, [8101] = { node0 = 8004, node1 = 8005 } } } })
	local a = roadRun(g, 962, '{ from = "100,0", to = "100,-80" }')
	truthy(a.ok, a.error); eq(a.from.node, 8001, "the ground node 3 m away, not the bridge's 12 m above")
	-- only track there: no node taken, and the street system never asked
	g = roadWorld({ roads = { nodes = { [8001] = { x = 100, y = 0, z = 0 }, [8002] = { x = 0, y = 0, z = 0 } },
		edges = { [8100] = { node0 = 8002, node1 = 8001, roadType = "TRACK" } } } })
	a = roadRun(g, 963, '{ from = "101,0", to = "101,80" }')
	truthy(a.ok, a.error); eq(a.from.node, nil); eq(g.streetSegmentCalls, nil)
	-- a piece whose road type does not read: not a road
	g = roadWorld({ edgeRoadTypeUnread = true, height = function() return 2 end })
	a = roadRun(g, 964, '{ from = "101,0", to = "101,80" }')
	truthy(a.ok, a.error); eq(a.from.node, nil)
	-- without the octree util: the octree system's box, pieces only
	g = roadWorld({ noOctreeUtil = true, height = function() return 2 end })
	a = roadRun(g, 965, '{ from = "101,0", to = "101,80" }')
	truthy(a.ok, a.error); eq(a.from.node, 8001)
end)

-- 2026-11-23 in the game: trunk roads laid one after another (each joined to the last one's new end), then a branch
-- snapped to one of those ends: Engine.h:322 GetComponentDataIndex, the node without BaseNodeConfig. A node a
-- street proposal makes without nodeConfigsToAdd has none (the fake does the same).
test("road snap: a node without a junction set-up (BaseNodeConfig) is never joined: the next one, or refused", function()
	-- the nearest end 8001 (1 m away) without a set-up, 8003 3 m away with one: 8003
	local g = roadWorld({ roads = { nodes = { [8001] = { x = 100, y = 0, z = 0 }, [8002] = { x = 0, y = 0, z = 0 },
		[8003] = { x = 104, y = 0, z = 0 }, [8004] = { x = 200, y = 0, z = 0 } },
		edges = { [8100] = { node0 = 8002, node1 = 8001 }, [8101] = { node0 = 8003, node1 = 8004 } },
		noConfig = { [8001] = true } }, height = function() return 0 end })
	local a = roadRun(g, 970, '{ from = "101,0", to = "101,80" }')
	truthy(a.ok, a.error); eq(a.from.node, 8003, "the next nearest, with a set-up"); eq(a.from.nodeConfig, true)
	eq(a.from.passedOver[1].node, 8001); eq(a.from.passedOver[1].pieces, 1)
	eq(g.edges[a.edge].node0, 8003); eq(a.caution, nil)
	-- only nodes without one within snap: refused, nothing sent (a new node there would sit on it), dry run too
	g = roadWorld({ roads = { nodes = { [8001] = { x = 100, y = 0, z = 0 }, [8002] = { x = 0, y = 0, z = 0 } },
		edges = { [8100] = { node0 = 8002, node1 = 8001 } }, noConfig = { [8001] = true } }, height = function() return 0 end })
	for i, dry in ipairs({ "false", "true" }) do
		a = roadRun(g, 970 + i, '{ from = "102,0", to = "102,80", dryRun = ' .. dry .. ' }')
		eq(a.ok, false, dry); truthy(tostring(a.error):find("from: the road node(s) within snap have no junction set-up", 1, true), tostring(a.error))
		truthy(a.error:find("8001 (2.0 m, 1 piece)", 1, true), a.error)
		eq(#g.buildCmds, 0, "nothing sent")
	end
	-- the far end too; snap 0 never asks
	a = roadRun(g, 973, '{ from = "102,80", to = "101,0" }')
	eq(a.ok, false); truthy(tostring(a.error):find("^to: "), tostring(a.error))
	a = roadRun(g, 974, '{ from = "150,0", to = "150,80", snap = 0 }')
	truthy(a.ok, a.error)
	truthy(not g.crashed, g.crashed)
end)

test("road: new nodes get a junction set-up; a trunk in pieces and a branch to its middle node go through (2026-11-23)", function()
	-- the game's crash: a trunk laid in pieces, then a branch to one of its inner nodes. Now each new node gets a
	-- set-up, each joined node its old one plus the new piece's connections (straight on, or a junction's)
	local g = roadWorld({ roads = { nodes = { [8001] = { x = 0, y = 0, z = 0 }, [8002] = { x = -50, y = 0, z = 0 } },
		edges = { [8100] = { node0 = 8002, node1 = 8001 } } }, height = function() return 0 end })
	local a = roadRun(g, 975, '{ from = "0,0", to = "300,0" }')
	truthy(a.ok, a.error); eq(a.from.node, 8001); eq(a.newNodes, 1); eq(a.caution, nil)
	local e1, m = a.edge, a.nodes[1]
	eq(a.newNodeConfigs[1].node, m); eq(a.newNodeConfigs[1].nodeConfig, true, "read back into the answer")
	eq(#g.nodeConns[m], 0, "a dead end: no connections")
	-- 8001 (8100 + the new piece): straight on, both ways, sidewalks counted (lanes 1 and 2 of 4)
	local cs = g.nodeConns[8001]
	eq(#cs, 2, "one road lane each way")
	local function has(list, s0, l0, s1, l1)
		for _, c in ipairs(list) do
			if c.segment0 == s0 and c.lane0 == l0 and c.segment1 == s1 and c.lane1 == l1 and c.withRoad then return true end
		end
		return false
	end
	-- at 8001: 8100 ends there (node1: lane k is 4 - k), e1 starts there (node0: lane k is k - 1). Arriving on 8100:
	-- its forward road lane (k 3, number 1) -> e1's forward lane (k 3, number 2 = 4 - 1 - 1)
	truthy(has(cs, 8100, 1, e1, 2), "8100 straight on into the new piece")
	truthy(has(cs, e1, 1, 8100, 2), "and back")
	local sent = g.buildCmds[1].proposal
	-- the second piece joins the first one's end (it was refused while new nodes had no set-up)
	a = roadRun(g, 976, '{ from = "300,0", to = "600,0" }')
	truthy(a.ok, a.error); eq(a.from.node, m); eq(a.from.laneRules, 2); eq(a.caution, nil)
	local e2 = a.edge
	eq(#g.nodeConns[m], 2); truthy(has(g.nodeConns[m], e1, 1, e2, 2), "straight on at the trunk's inner node")
	-- a branch to that inner node: a junction (each arriving road lane to each leaving one of the other pieces)
	a = roadRun(g, 977, '{ from = "300,0", to = "300,-200" }')
	truthy(a.ok, a.error); eq(a.from.node, m); eq(a.from.laneRules, 4)
	local e3 = a.edge
	eq(#g.nodeConns[m], 6, "the two straight-on ones kept, four to and from the branch")
	truthy(has(g.nodeConns[m], e1, 1, e3, 2) and has(g.nodeConns[m], e3, 1, e2, 2) and has(g.nodeConns[m], e3, 1, e1, 2))
	-- and a fourth piece to the same node (a junction of four)
	a = roadRun(g, 978, '{ from = "300,0", to = "300,200" }')
	truthy(a.ok, a.error); eq(a.from.laneRules, 6)
	eq(#g.buildCmds, 4); truthy(not g.crashed, g.crashed)
	-- an old node without a set-up (a road built before) is still refused
	g = roadWorld({ roads = { nodes = { [8001] = { x = 0, y = 0, z = 0 }, [8002] = { x = -50, y = 0, z = 0 },
		[8003] = { x = 50, y = 0, z = 0 } }, edges = { [8100] = { node0 = 8002, node1 = 8001 }, [8101] = { node0 = 8001, node1 = 8003 } },
		noConfig = { [8001] = true } }, height = function() return 0 end })
	a = roadRun(g, 979, '{ from = "0,0", to = "0,-200" }')
	eq(a.ok, false); truthy(tostring(a.error):find("no junction set-up", 1, true), tostring(a.error)); eq(#g.buildCmds, 0)
	truthy(not g.crashed, g.crashed)
end)

test("road: set-ups at every way round (ends facing, drawn to an old end); refused where they cannot be made", function()
	local function has(list, s0, l0, s1, l1)
		for _, c in ipairs(list or {}) do
			if c.segment0 == s0 and c.lane0 == l0 and c.segment1 == s1 and c.lane1 == l1 then return true end
		end
		return false
	end
	local function world(extra)
		local roads = { nodes = { [8001] = { x = 0, y = 0, z = 0 }, [8002] = { x = 50, y = 0, z = 0 } },
			edges = { [8100] = { node0 = 8001, node1 = 8002 } } }
		for k, v in pairs(extra or {}) do roads[k] = v end
		return roadWorld({ roads = roads, height = function() return 0 end })
	end
	-- both pieces start at 8001 (node0 to node0): 8100's arriving lane (k 2, backward: number 1) into the new
	-- piece's leaving one (k 3: number 2), and back
	local g = world()
	local a = roadRun(g, 990, '{ from = "0,0", to = "-300,0" }')
	truthy(a.ok, a.error); eq(a.from.node, 8001); eq(a.from.laneRules, 2)
	truthy(has(g.nodeConns[8001], 8100, 1, a.edge, 2) and has(g.nodeConns[8001], a.edge, 1, 8100, 2), "facing ends")
	-- drawn to an old end (the new piece's node1 the joined node): node1 to node0
	g = world()
	a = roadRun(g, 991, '{ from = "-300,0", to = "0,0" }')
	truthy(a.ok, a.error); eq(a.to.node, 8001); eq(a.from.node, nil); eq(a.to.laneRules, 2)
	-- (the new piece's forward lane k 3 arrives at its node1: number 1, into 8100's forward lane k 3 at its node0: number 2)
	truthy(has(g.nodeConns[8001], a.edge, 1, 8100, 2) and has(g.nodeConns[8001], 8100, 1, a.edge, 2), "node1 to node0")
	eq(a.newNodeConfigs[1].nodeConfig, true)
	-- no LaneConnection constructor: plain tables; a set-up record without comp: a new one
	g = world()
	local LC, NE = api.type.LaneConnection, api.type.BaseNodeLaneConnectionAndEntity.new
	api.type.LaneConnection = nil
	api.type.BaseNodeLaneConnectionAndEntity.new = function() return { entity = 0 } end
	a = roadRun(g, 992, '{ from = "0,0", to = "-300,0" }')
	api.type.LaneConnection, api.type.BaseNodeLaneConnectionAndEntity.new = LC, NE
	truthy(a.ok, a.error); eq(#g.nodeConns[8001], 2); eq(a.newNodeConfigs[1].nodeConfig, true)
	-- refused, dry run too, nothing sent: traffic lights, connections numbered otherwise (lane 0 at 8100's node0
	-- is its sidewalk), lanes that do not read
	for i, case in ipairs({
		{ { lights = { [8001] = true } }, "traffic lights" },
		{ { conns = { [8001] = { { segment0 = 8100, lane0 = 0, segment1 = 8100, lane1 = 2, withRoad = true } } } },
			"number lanes otherwise than this command (piece 8100 lane 0" },
	}) do
		g = world(case[1])
		for j, dry in ipairs({ "false", "true" }) do
			a = roadRun(g, 993 + 2 * i + j, '{ from = "0,0", to = "-300,0", dryRun = ' .. dry .. ' }')
			eq(a.ok, false, case[2]); truthy(tostring(a.error):find(case[2], 1, true), tostring(a.error))
			truthy(a.error:find("nothing sent", 1, true), a.error)
		end
		eq(#g.buildCmds, 0)
	end
	-- an old connection numbered as here is kept as it was
	g = world({ conns = { [8001] = { { segment0 = 8100, lane0 = 1, segment1 = 8100, lane1 = 2, withRoad = true } } } })
	a = roadRun(g, 999, '{ from = "0,0", to = "-300,0" }')
	truthy(a.ok, a.error); truthy(has(g.nodeConns[8001], 8100, 1, 8100, 2), "the old one kept"); eq(#g.nodeConns[8001], 3)
	g = roadWorld({ streets = { [TOWN_OLD] = { yearTo = 1940, modesUnread = true } }, height = function() return 0 end })
	a = roadRun(g, 1000, '{ from = "0,500", to = "0,600" }')
	eq(a.ok, false); truthy(tostring(a.error):find("lanes could not be read", 1, true), tostring(a.error)); eq(#g.buildCmds, 0)
	truthy(not g.crashed, g.crashed)
end)

test("road: two lanes each way: straight on is lane for lane (4 connections), a junction every lane to every lane", function()
	local WIDE = "::/infrastructure/street/country/country_new_large.street_template"
	local g = roadWorld({ streets = { [WIDE] = { cost = 10, perSide = 2 } }, roads = { nodes = {}, edges = {} },
		height = function() return 0 end })
	local a = roadRun(g, 1001, string.format('{ from = "0,0", to = "300,0", type = %q }', WIDE))
	truthy(a.ok, a.error)
	local m, e1 = a.nodes[2], a.edge
	a = roadRun(g, 1002, string.format('{ from = "300,0", to = "600,0", type = %q }', WIDE))
	truthy(a.ok, a.error); eq(a.from.node, m); eq(a.from.laneRules, 4, "lane for lane: 2 each way (all to all would be 8)")
	local e2 = a.edge
	-- at m (e1's node1: lane k is 6 - k; e2's node0: k - 1): e1's forward lanes k 4, 5 (numbers 2, 1) into e2's
	-- k 4, 5 (numbers 3, 4 = 6 - 1 - 2, 6 - 1 - 1)
	local function has(s0, l0, s1, l1)
		for _, c in ipairs(g.nodeConns[m]) do
			if c.segment0 == s0 and c.lane0 == l0 and c.segment1 == s1 and c.lane1 == l1 and c.withRoad then return true end
		end
		return false
	end
	truthy(has(e1, 2, e2, 3) and has(e1, 1, e2, 4) and not has(e1, 2, e2, 4), "each lane into its own")
	a = roadRun(g, 1003, string.format('{ from = "300,0", to = "300,-200", type = %q }', WIDE))
	truthy(a.ok, a.error); eq(a.from.laneRules, 16, "2 in x 2 out, to and from each of the two pieces")
	truthy(not g.crashed, g.crashed)
end)

test("road: the fake's set-up checks (a lane out of range, a piece not at the node, a config added twice) die", function()
	local g = roadWorld({ height = function() return 0 end })
	local function sendWith(fill)
		local sp = api.type.SimpleProposal.new()
		local e = api.type.SegmentAndEntity.new()
		e.entity = -1
		e.comp.node0, e.comp.node1 = 8001, 8003
		e.comp.position0, e.comp.position1 = { x = 100, y = 0, z = 2 }, { x = 300, y = 300, z = 0 }
		e.comp.roadTemplate, e.comp.laneConfigs = TOWN_OLD, g.townLanes()
		sp.streetProposal.edgesToAdd = { e }
		fill(sp)
		g.crashed = nil
		return pcall(api.cmd.sendCommand, api.cmd.makeWorldBuildProposalCmd(sp, {}, false, true), function() end)
	end
	local function entry(node, conns)
		local c = api.type.BaseNodeLaneConnectionAndEntity.new()
		c.entity, c.comp.laneConnections = node, conns
		return c
	end
	for _, case in ipairs({
		{ function(sp) sp.streetProposal.nodeConfigsToAdd = { entry(8001, {}) } end, "keeps its set-up" },
		{ function(sp) sp.streetProposal.nodeConfigsToRemove = { 8001 }
			sp.streetProposal.nodeConfigsToAdd = { entry(8001, { { segment0 = -1, lane0 = 4, segment1 = 8100, lane1 = 0 } }) } end, "lane 4" },
		{ function(sp) sp.streetProposal.nodeConfigsToRemove = { 8001 }
			sp.streetProposal.nodeConfigsToAdd = { entry(8001, { { segment0 = 9999, lane0 = 0, segment1 = 8100, lane1 = 0 } }) } end, "is not there" },
		-- the game's crash: a third piece to a node without a set-up that has two
		{ function(sp) g.nodeConfig[8001] = false; g.edges[8101] = { node0 = 8001, node1 = 8002 } end, "GetComponentDataIndex" },
	}) do
		local ok = sendWith(case[1])
		eq(ok, false, case[2]); truthy(tostring(g.crashed):find(case[2], 1, true), tostring(g.crashed))
	end
end)

test("road snap: whether a node has a junction set-up cannot be read: refused, dry run too, nothing sent", function()
	for _, spec in ipairs({ { nodeConfigRaises = true }, { noNodeConfigType = true } }) do
		spec.height = function() return 2 end
		local g = roadWorld(spec)
		for i, dry in ipairs({ "false", "true" }) do
			local a = roadRun(g, 980 + i, '{ from = "102,1", to = "200,0", dryRun = ' .. dry .. ' }')
			eq(a.ok, false, dry)
			truthy(tostring(a.error):find("from: whether road node 8001 (2.2 m away) has its junction set-up", 1, true), tostring(a.error))
		end
		eq(#g.buildCmds, 0)
	end
	-- read as there: joined, no caution
	local g = roadWorld()
	local a = roadRun(g, 983, '{ from = "102,1", to = "200,0" }')
	truthy(a.ok, a.error); eq(a.from.nodeConfig, true); eq(a.caution, nil); truthy(g.nodeConfigReads > 0)
end)

test("road: a template or enum that does not read is refused before sending", function()
	local g = roadWorld()
	local real = api.type.enum.BaseEdgeType
	api.type.enum.BaseEdgeType = nil
	local a = roadRun(g, 966, '{ from = "0,500", to = "0,600" }')
	api.type.enum.BaseEdgeType = real
	eq(a.ok, false); truthy(tostring(a.error):find("BaseEdgeType", 1, true), tostring(a.error)); eq(#g.buildCmds, 0)
	local rt = api.type.enum.RoadType
	api.type.enum.RoadType = nil
	a = roadRun(g, 967, string.format('{ from = "0,500", to = "0,600", type = %q }', TRACK_STD))
	eq(a.ok, false); truthy(tostring(a.error):find("could not be read", 1, true), tostring(a.error))
	a = roadRun(g, 968, '{ from = "0,500", to = "0,600" }')
	api.type.enum.RoadType = rt
	eq(a.ok, false, "no default either: a type that does not read is no road"); eq(#g.buildCmds, 0)
end)

test("road: a piece there before the build is never the new one; built with no new piece found: a warning", function()
	-- an old piece already between the two points, and a build whose result names nothing and adds nothing
	local g = roadWorld({ noStreetResults = true, roads = { nodes = { [8001] = { x = 0, y = 500, z = 0 },
		[8002] = { x = 0, y = 600, z = 0 } }, edges = { [8100] = { node0 = 8001, node1 = 8002 } } } })
	local apply = api.cmd.sendCommand
	api.cmd.sendCommand = function(cmd, cb)
		if type(cmd) == "table" and cmd.kind == "buildProposal" then
			return cb({ resultProposalData = { costs = 0 }, resultEntities = {} }, true, {})
		end
		return apply(cmd, cb)
	end
	local a = roadRun(g, 969, '{ from = "0,500", to = "0,600", snap = 0 }')
	api.cmd.sendCommand = apply
	truthy(a.ok, a.error); eq(a.edge, nil, "the old piece 8100 is not taken")
	truthy(tostring(a.warning):find("no new piece", 1, true), tostring(a.warning))
end)

test("road: refused by the engine (collision, money): nothing built, the messages in the error", function()
	local g = roadWorld({ blocked = function(x, y) return y > 1000 and 4343 or nil end })
	local a, n = roadRun(g, 955, '{ from = "0,1500", to = "0,1600" }')
	eq(n, 1); eq(a.ok, false)
	truthy(a.error:find("Collision"), a.error); eq(a.collisions[1], 4343)
	g.balance = 10
	a = roadRun(g, 956, '{ from = "0,500", to = "0,600" }')
	eq(a.ok, false); truthy(a.error:find("Not enough money"), a.error)
	eq(#g.streetCmds, 2); eq(g.edges[5001], nil)
	-- a template without lanes is refused before sending (its lanes do not read: no set-ups could be made)
	g = roadWorld({ streets = { [TOWN_OLD] = { yearTo = 1940, noLanes = true } } })
	local sentBefore = #g.streetCmds
	a = roadRun(g, 957, '{ from = "0,500", to = "0,600" }')
	eq(a.ok, false); truthy(a.error:find("its lanes could not be read", 1, true), a.error); eq(#g.streetCmds, sentBefore)
end)

test("road --dry-run: the plan, nothing sent; no ids in the result or no callback: the piece found between the ends", function()
	local g = roadWorld()
	local a = roadRun(g, 958, '{ from = "102,1", to = "200,0", dryRun = true }')
	truthy(a.ok, a.error); eq(a.dryRun, true); eq(a.checked, false); eq(a.from.node, 8001); eq(a.template, TOWN_OLD)
	eq(#g.buildCmds, 0)
	g = roadWorld({ noStreetResults = true })
	a = roadRun(g, 959, '{ from = "102,1", to = "200,0" }')
	truthy(a.ok, a.error); truthy(a.edge, "found"); eq(g.edges[a.edge].node0, 8001)
	truthy(tostring(a.why):find("found between the ends", 1, true), tostring(a.why))
	g = roadWorld({ lostCallback = true })
	send(g, 960, "road", '{ from = "102,1", to = "200,0" }')
	frames(g, 40, 1)
	a = final(g, 960)
	truthy(a.ok, a.error); truthy(a.edge); truthy(tostring(a.why):find("no answer from the engine", 1, true))
	-- lost and not built (refused, no callback): an error
	g = roadWorld({ lostCallback = true, blocked = function() return 1 end })
	send(g, 961, "road", '{ from = "0,500", to = "0,600" }')
	frames(g, 40, 1)
	a = final(g, 961)
	eq(a.ok, false); truthy(tostring(a.error):find("no piece between the ends", 1, true), tostring(a.error))
	truthy(not g.crashed, g.crashed)
end)

---------------------------------------------------------------------------------------------------------------------
-- terrain (a rectangle flat or a slope), terrainApi, newgame --editor

test("core.terrainRequest: rect, one of flat / slopeX / slopeY (with base), blend, via; the limits", function()
	local r = core.terrainRequest({ rect = "0,0,100,50", flat = 20 })
	eq(r.mode, "flat"); eq(r.z, 20); eq(r.rect.x1, 100); eq(r.blend, 12.5, "a quarter of 50 m");
	eq(core.terrainRequest({ rect = "0,0,100,100", flat = 1 }).blend, core.TERRAIN_BLEND); eq(r.via, "auto"); eq(r.dryRun, false)
	local s = core.terrainRequest({ rect = { -10, -10, 90, 90 }, slopeX = 5, base = 30, blend = 0, dryRun = true, via = "gui" })
	eq(s.mode, "slopeX"); eq(s.pct, 5); eq(s.base, 30); eq(s.blend, 0); eq(s.dryRun, true); eq(s.via, "gui")
	eq(core.terrainTarget(s, -10, 0), 30, "base at x0"); eq(core.terrainTarget(s, 90, 0), 35, "5 % over 100 m")
	local lo, hi = core.terrainRange(core.terrainRequest({ rect = "0,0,200,100", slopeY = -10, base = 50 }))
	eq(lo, 40); eq(hi, 50)
	local S = core.TERRAIN_MAX_SIDE
	truthy(core.terrainRequest({ rect = string.format("0,0,%d,%d", S, S), flat = 1 }), "the limit itself")
	for _, bad in ipairs({
		{ {}, "give rect" }, { { rect = "0,0,1", flat = 1 }, "x0,y0,x1,y1" }, { { rect = "5,0,1,1", flat = 1 }, "x0 < x1" },
		{ { rect = "0,0,0,10", flat = 1 }, "x0 < x1" }, { { rect = string.format("0,0,%d,10", S + 1), flat = 1 }, "at most " .. S },
		{ { rect = "0,0,10,10" }, "give one of" }, { { rect = "0,0,10,10", flat = 1, slopeX = 2 }, "give one of" },
		{ { rect = "0,0,10,10", flat = "x" }, "finite" }, { { rect = "0,0,10,10", flat = 1, base = 2 }, "no base" },
		{ { rect = "0,0,10,10", slopeX = 5 }, "give base" }, { { rect = "0,0,10,10", slopeY = 101, base = 1 }, "at most 100" },
		{ { rect = "0,0,100,100", flat = 1, blend = -1 }, "blend" }, { { rect = "0,0,100,20", flat = 1, blend = 11 }, "half" },
		{ { rect = "0,0,10,10", flat = 1, via = "cmd" }, "via" }, { { rect = "0,0,10,10", flat = 4000 }, "engine's range" },
		{ { rect = "0,0,1000,10", slopeX = 100, base = 3000, blend = 0 }, "engine's range" }, { { rect = "0,0,1e6,1", flat = 1 }, "within" },
	}) do
		local ok, err = core.terrainRequest(bad[1])
		eq(ok, nil, bad[2]); truthy(tostring(err):find(bad[2], 1, true), tostring(err) .. " / wanted " .. bad[2])
	end
	truthy(core.COMMANDS.terrain and core.CHANGES_GAME.terrain and not core.MENU_COMMANDS.terrain, "changes the game, in a game")
	truthy(core.COMMANDS.terrainApi and not core.CHANGES_GAME.terrainApi and not core.MENU_COMMANDS.terrainApi, "terrainApi only looks")
end)

test("core.terrainGrid / terrainFill: the points in the rect, flat and slope values, the blend, nothing outside", function()
	-- a 3 x 3 tile map would be large; a small grid of the same layout: 11 x 11 points of 4 m from -20, -20
	local info = { minX = -20, minY = -20, maxX = 20, maxY = 20, step = 4, w = 11, h = 11 }
	local function heights() local t = {} for k = 1, 121 do t[k] = 7 end return t end
	local r = core.terrainRequest({ rect = "-6,-6,6,6", flat = 3, blend = 0 })
	local grid = core.terrainGrid(r, info)
	eq(grid.i0, 4); eq(grid.i1, 6); eq(grid.nx, 3); eq(grid.ny, 3); eq(grid.points, 9); eq(grid.x0, -4); eq(grid.x1, 4)
	local H = heights()
	local st = core.terrainFill(H, grid, r, info)
	eq(st.changed, 9); eq(st.before.min, 7); eq(st.written.min, 3); eq(st.written.max, 3)
	for j = 0, 10 do for i = 0, 10 do
		local inside = i >= 4 and i <= 6 and j >= 4 and j <= 6
		eq(H[j * 11 + i + 1], inside and 3 or 7, string.format("point %d,%d", i, j))
	end end
	-- a slope along y: 10 % from y0 = -20 (the map's edge), 0.4 m a point
	local sy = core.terrainRequest({ rect = "-20,-20,20,20", slopeY = 10, base = 50, blend = 0 })
	local H2 = heights()
	core.terrainFill(H2, core.terrainGrid(sy, info), sy, info)
	for j = 0, 10 do eq(H2[j * 11 + 5 + 1], 50 + 0.4 * j, "row " .. j) end
	eq(H2[3 * 11 + 1], H2[3 * 11 + 11], "the same along x")
	-- the blend: the edge stays, blend metres in the full height
	local b = core.terrainRequest({ rect = "-20,-20,20,20", flat = 1, blend = 8 })
	local H3 = heights()
	core.terrainFill(H3, core.terrainGrid(b, info), b, info)
	eq(H3[5 * 11 + 1], 7, "on the edge: as it was"); eq(H3[5 * 11 + 2], 4, "4 m in: half way"); eq(H3[5 * 11 + 3], 1, "8 m in: full")
	eq(H3[5 * 11 + 6], 1)
	-- off the map, and a rect between two points
	truthy(select(2, core.terrainGrid(core.terrainRequest({ rect = "-30,0,0,10", flat = 1 }), info)):find("not inside the map"))
	truthy(select(2, core.terrainGrid(core.terrainRequest({ rect = "1,1,2,2", flat = 1, blend = 0 }), info)):find("no grid point"))
	-- samples: the middle and the full part's corners, on grid points
	local samples = core.terrainSamples(H3, core.terrainGrid(b, info), b, info)
	eq(samples[1].x, 0); eq(samples[1].y, 0); eq(samples[1].expected, 1); eq(samples[2].x, -12); eq(#samples, 5)
end)

test("core.terrainFunctions: type() of each path, nothing called; the needs missing", function()
	local called = false
	local root = { api = { engine = { terrain = { makeMapFromGame = function() called = true end } } } }
	local f, _, missing = core.terrainFunctions(root)
	eq(f["api.engine.terrain.makeMapFromGame"], "function"); eq(f["api.cmd.makeWorldReplaceTerrainCmd"], "nil")
	eq(f["api.type.Map.new"], "nil"); eq(called, false)
	truthy(#missing > 0 and missing[1] == "api.engine.terrain.getBoundingBox", missing[1])
	eq(core.typeAt("a.b", { a = 5 }), "nil", "through a number")
	local o = core.officialMods({ "ug_legacy_ships", "hummer_age_of_mobility", "ug_tgv_pse", "x_ug_y" })
	eq(table.concat(o, ","), "ug_legacy_ships,ug_tgv_pse")
	eq(#core.terrainRequests({ { id = 1, kind = "probe" }, { id = 2, kind = "apply", args = { rect = "0,0,1,1", flat = 1, blend = 0 } },
		{ id = 3, kind = "apply", args = { rect = "0,0,1,1" } }, { kind = "probe" }, { id = 4, kind = "dig" } }), 2)
end)

-- the map editor (unless opts.mapEditor = false) with the speed control on screen and a 512 m map
-- (installTerrain): heights 10, unless spec.height
local function terrainGame(spec, opts)
	opts = opts or {}
	if opts.mapEditor == nil then opts.mapEditor = true end
	local g = vehicleGame(opts)
	fake.installTerrain(g, spec)
	return g
end
local function terrainRun(g, id, argsLua, n)
	send(g, id, "terrain", argsLua)
	frames(g, n or FIRST + 20)
	return final(g, id)
end
local function hAt(g, x, y)
	local i, j = (x + 256) / 4, (y + 256) / 4
	assert(i % 1 == 0 and j % 1 == 0, "not a grid point: " .. x .. "," .. y)
	return g.heights[j * 129 + i + 1]
end

test("core.isCallable: a function, a table or userdata with __call; a plain table or a number is not", function()
	local callable = setmetatable({}, { __call = function() end })
	local u = newproxy(true); getmetatable(u).__call = function() end
	eq(core.isCallable(function() end), true); eq(core.isCallable(callable), true); eq(core.isCallable(u), true)
	eq(core.isCallable({}), false, "a plain table"); eq(core.isCallable(setmetatable({}, {})), false, "a metatable with no __call")
	eq(core.isCallable(5), false); eq(core.isCallable(nil), false); eq(core.isCallable("f"), false)
	-- terrainFunctions: a callable table is there (type "table", callable true), a plain table is there too (not
	-- callable, but not missing: missing means nil), only nil is missing
	local root = { api = { engine = { terrain = { makeMapFromGame = callable, getBoundingBox = {} } } } }
	local f, c, missing = core.terrainFunctions(root)
	eq(f["api.engine.terrain.makeMapFromGame"], "table"); eq(c["api.engine.terrain.makeMapFromGame"], true)
	eq(c["api.engine.terrain.getBoundingBox"], false); eq(f["api.engine.terrain.getBoundingBox"], "table")
	local hit = false
	for _, p in ipairs(missing) do if p == "api.engine.terrain.makeMapFromGame" or p == "api.engine.terrain.getBoundingBox" then hit = true end end
	eq(hit, false, "a table, callable or not, is not missing")
end)

test("core.terrainFunctions: a table whose metatable cannot be read is there; only nil is missing", function()
	-- the engine's api entries: getmetatable gives a non-table (a __metatable field), so isCallable is false
	local opaque = setmetatable({}, { __call = function() end, __metatable = "locked" })
	eq(core.isCallable(opaque), false, "unreadable metatable")
	local root = { api = { engine = { terrain = { makeMapFromGame = opaque, getBoundingBox = opaque } }, cmd = {} } }
	local f, c, missing = core.terrainFunctions(root)
	eq(f["api.engine.terrain.makeMapFromGame"], "table"); eq(c["api.engine.terrain.makeMapFromGame"], false)
	local listed = {}
	for _, p in ipairs(missing) do listed[p] = true end
	eq(listed["api.engine.terrain.makeMapFromGame"], nil, "a table is not missing")
	eq(listed["api.engine.terrain.getBoundingBox"], nil, "a table is not missing")
	eq(listed["api.cmd.makeWorldReplaceTerrainCmd"], true, "nil is missing")
	-- getmetatable itself returning nil (not a table) is the same: there, not missing
	local realGetmetatable = getmetatable
	local ok, err = pcall(function()
		getmetatable = function() return nil end
		local f2, c2, m2 = core.terrainFunctions({ api = { engine = { terrain = { makeMapFromGame = {}, getBoundingBox = {} } }, cmd = {} } })
		eq(f2["api.engine.terrain.makeMapFromGame"], "table"); eq(c2["api.engine.terrain.makeMapFromGame"], false)
		local l2 = {}
		for _, p in ipairs(m2) do l2[p] = true end
		eq(l2["api.engine.terrain.makeMapFromGame"], nil, "getmetatable nil: a table is not missing")
	end)
	getmetatable = realGetmetatable
	if not ok then error(err, 0) end
end)

test("terrain flat: the rect's points at the height, the rest as it was; one replacement, no towns in it; read back", function()
	local g = terrainGame({ height = function(x, y) return 10 + x / 100 end })
	local before = {}
	for k, v in ipairs(g.heights) do before[k] = v end
	local a, n = terrainRun(g, 1001, '{ rect = "-100,-100,100,100", flat = 25 }')
	eq(n, 1, "one final answer")
	truthy(a.ok, a.error)
	eq(a.via, "gui", "auto: the recipe's join"); eq(a.sent, true); eq(a.success, true); eq(a.keepAssets, true)
	eq(g.mapCopies, 1, "copied with Map.new"); eq(a.mapPoints, 129 * 129)
	eq(#g.terrainCmds, 1); eq(#g.terrainCmds[1].towns, 0); eq(g.terrainCmds[1].keepAssets, true)
	eq(#g.seedTexts, 1); eq(g.materialReloads, 1); eq(a.seedText, true); eq(a.reloadMaterials, true)
	eq(a.grid.nx, 51); eq(a.grid.ny, 51); eq(a.grid.points, 2601); eq(a.map.w, 129); eq(a.map.minX, -256)
	eq(a.target.min, 25); eq(a.target.max, 25); eq(a.written.max, 25); eq(a.blend, 16)
	truthy(a.written.min >= 9 and a.written.min < 10, "the blend from the old heights: " .. a.written.min)
	eq(hAt(g, 0, 0), 25); eq(hAt(g, -84, 84), 25, "16 m in: full")
	eq(hAt(g, -100, 0), before[64 * 129 + 39 + 1], "the edge as it was (blend)")
	-- outside: every point as it was
	local diff = 0
	for j = 0, 128 do for i = 0, 128 do
		local x, y = -256 + 4 * i, -256 + 4 * j
		if not (x >= -100 and x <= 100 and y >= -100 and y <= 100) and g.heights[j * 129 + i + 1] ~= before[j * 129 + i + 1] then diff = diff + 1 end
	end end
	eq(diff, 0, "nothing outside the rect changed")
	eq(a.readBackOk, true); eq(a.samples[1].read, 25); eq(a.samples[1].expected, 25)
	truthy(a.note:find("not checked in a game")); eq(a.mapEditor, true)
	eq(a.functionsUpdate["api.engine.terrain.makeMapFromGame"], "function")
	truthy(not g.crashed, g.crashed)
end)

test("terrain slopeX / slopeY: 5 % and 10 % from base at the west / south edge, a sharp edge with blend 0", function()
	local g = terrainGame()
	local a = terrainRun(g, 1002, '{ rect = "0,0,200,100", slopeX = 5, base = 30, blend = 0 }')
	truthy(a.ok, a.error)
	eq(hAt(g, 0, 40), 30); eq(hAt(g, 4, 40), 30.2); eq(hAt(g, 200, 40), 40); eq(hAt(g, 100, 100), 35)
	eq(hAt(g, -4, 40), 10, "west of the rect"); eq(hAt(g, 204, 40), 10, "east of it")
	eq(a.target.min, 30); eq(a.target.max, 40); eq(a.changed, 51 * 26)
	local b = terrainRun(g, 1003, '{ rect = "-200,-200,-100,0", slopeY = 10, base = 50, blend = 0 }')
	truthy(b.ok, b.error)
	eq(hAt(g, -152, -200), 50); eq(hAt(g, -152, -196), 50.4); eq(hAt(g, -152, 0), 70); eq(hAt(g, -200, -100), hAt(g, -100, -100))
	eq(hAt(g, -152, 4), 10, "north of it")
	eq(hAt(g, 100, 40), 35, "the first one stays")
end)

test("terrain: over the limit, off the map or bad values: refused, nothing sent", function()
	local g = terrainGame()
	local a = terrainRun(g, 1004, '{ rect = "-250,-250,850,0", flat = 5 }')
	truthy(a.error and a.error:find("at most 1024"), a.error)
	local b = terrainRun(g, 1005, '{ rect = "200,0,400,100", flat = 5 }')
	truthy(b.error and b.error:find("not inside the map"), b.error)
	local c = terrainRun(g, 1006, '{ rect = "0,0,10,10", slopeX = 5 }')
	truthy(c.error and c.error:find("give base"), c.error)
	eq(#g.terrainCmds, 0); eq(hAt(g, 0, 0), 10)
	truthy(not g.crashed, g.crashed)
end)

test("terrain: a road, a construction or a town in or by the rect: refused, nothing sent (the dry run too)", function()
	local g = terrainGame({ entities = { [7001] = { kind = "BASE_EDGE", x = 50, y = 50 },
		[7002] = { kind = "CONSTRUCTION", x = 104, y = 0 }, [7003] = { kind = "BASE_EDGE", x = 150, y = 0 } } },
		{ entities = { TOWN = { 11 } }, names = { [11] = "Emsworth" }, positions = { [11] = { -400, 0 } } })
	local a = terrainRun(g, 1010, '{ rect = "0,0,100,100", flat = 5 }')
	eq(a.ok, false)
	truthy(a.error:find("nothing sent") and a.error:find("1 roads (7001)", 1, true) and a.error:find("1 constructions (7002)", 1, true), a.error)
	truthy(not a.error:find("7003"), "150 m away is not in the way")
	eq(a.blockers.roads[1], 7001); eq(a.blockers.towns, nil, "the town's box is 600 m away")
	local b = terrainRun(g, 1011, '{ rect = "0,0,100,100", flat = 5, dryRun = true }')
	eq(b.ok, false); truthy(b.error:find("nothing sent"))
	-- a town whose box comes within 200 m
	local c = terrainRun(g, 1012, '{ rect = "-250,-250,-220,-50", flat = 5 }')
	eq(c.ok, false); truthy(c.error:find("1 towns (Emsworth (11))", 1, true), c.error)
	eq(c.blockers.towns[1].name, "Emsworth")
	eq(#g.terrainCmds, 0); eq(hAt(g, 40, 40), 10)
	-- clear ground: goes through
	local d = terrainRun(g, 1013, '{ rect = "0,-200,100,-100", flat = 5 }')
	truthy(d.ok, d.error); eq(#g.terrainCmds, 1)
end)

test("terrain with callable api entries (tables with __call): the update way and the recipe's way both send", function()
	local g = terrainGame({ callableApi = true })
	local a = terrainRun(g, 1060, '{ rect = "-100,-100,100,100", flat = 25, via = "update" }')
	truthy(a.ok, a.error)
	eq(a.via, "update"); eq(a.sent, true); eq(a.success, true); eq(a.readBackOk, true)
	eq(#g.terrainCmds, 1); eq(hAt(g, 0, 0), 25)
	eq(a.functionsUpdate["api.engine.terrain.makeMapFromGame"], "table")
	eq(a.callableUpdate["api.engine.terrain.makeMapFromGame"], true)
	truthy(not g.crashed, g.crashed)
	local r = terrainGame({ callableApi = true, reactOnly = true })
	local b = terrainRun(r, 1061, '{ rect = "-100,-100,100,100", flat = 30 }')
	truthy(b.ok, b.error)
	eq(b.via, "gui"); eq(b.sent, true); eq(b.success, true); eq(b.readBackOk, true)
	eq(#r.terrainCmds, 1); eq(hAt(r, 0, 0), 30)
	eq(b.callableGui["api.engine.terrain.makeMapFromGame"], true)
	eq(b.callableUpdate["api.engine.terrain.makeMapFromGame"], false, "nil in the guiUpdate state")
	truthy(not r.crashed, r.crashed)
	-- terrainApi: the callable flags of both states
	send(r, 1062, "terrainApi")
	frames(r, FIRST + 10)
	local c = final(r, 1062)
	truthy(c and c.ok, c and c.error)
	eq(c.callable.gui["api.engine.terrain.makeMapFromGame"], true); eq(c.callable.update["api.engine.terrain.makeMapFromGame"], false)
	eq(c.callable.gui["api.type.Map.new"], true); eq(c.needs[1], "api.engine.terrain.makeMapFromGame")
	eq(#r.terrainCmds, 1, "nothing called by the probe")
end)

test("terrain with opaque api entries (metatable unreadable): the update way and the recipe's way both send", function()
	local g = terrainGame({ opaqueApi = true })
	local a = terrainRun(g, 1070, '{ rect = "-100,-100,100,100", flat = 35, via = "update" }')
	truthy(a.ok, a.error)
	eq(a.via, "update"); eq(a.sent, true); eq(a.success, true); eq(a.readBackOk, true)
	eq(#g.terrainCmds, 1); eq(hAt(g, 0, 0), 35)
	eq(a.functionsUpdate["api.engine.terrain.makeMapFromGame"], "table")
	eq(a.callableUpdate["api.engine.terrain.makeMapFromGame"], false, "isCallable cannot read it")
	truthy(not g.crashed, g.crashed)
	local r = terrainGame({ opaqueApi = true, reactOnly = true })
	local b = terrainRun(r, 1071, '{ rect = "-100,-100,100,100", flat = 40 }')
	truthy(b.ok, b.error)
	eq(b.via, "gui"); eq(b.sent, true); eq(b.success, true); eq(b.readBackOk, true)
	eq(#r.terrainCmds, 1); eq(hAt(r, 0, 0), 40)
	eq(b.functionsGui["api.engine.terrain.makeMapFromGame"], "table")
	eq(b.functionsUpdate["api.engine.terrain.makeMapFromGame"], "nil", "nil in the guiUpdate state")
	local c = terrainRun(r, 1072, '{ rect = "-100,-100,100,100", flat = 45, via = "update" }')
	eq(c.ok, false); truthy(c.error:find("missing in the guiUpdate state: api.engine.terrain.makeMapFromGame"), c.error)
	truthy(not r.crashed, r.crashed)
end)

test("terrain --dry-run: the numbers, nothing sent, nothing changed", function()
	local g = terrainGame()
	local a = terrainRun(g, 1020, '{ rect = "0,0,100,100", slopeX = 10, base = 0, blend = 0, dryRun = true }')
	truthy(a.ok, a.error)
	eq(a.dryRun, true); eq(a.sent, false); eq(a.success, nil); eq(a.readBackOk, nil)
	eq(a.grid.points, 26 * 26); eq(a.written.min, 0); eq(a.written.max, 10); eq(a.before.min, 10); eq(a.changed, 26 * 25, "the x1 column was 10 already")
	eq(#g.terrainCmds, 0); eq(#g.seedTexts, 0); eq(hAt(g, 100, 0), 10)
end)

test("terrain via gui: where only the recipe's state has the functions, the recipe replaces it; via update refused", function()
	local g = terrainGame({ reactOnly = true })
	local a = terrainRun(g, 1030, '{ rect = "-100,-100,100,100", flat = 25 }')
	truthy(a.ok, a.error)
	eq(a.via, "gui"); eq(a.sent, true); eq(a.success, true); eq(a.readBackOk, true)
	eq(a.functionsUpdate["api.engine.terrain.makeMapFromGame"], "nil"); eq(a.functionsGui["api.engine.terrain.makeMapFromGame"], "function")
	eq(#g.terrainCmds, 1); eq(hAt(g, 0, 0), 25); eq(#g.seedTexts, 1)
	-- the request is taken back: the GUI save data lists none
	eq(#(fake.guiSave.hummer_remote_probe.terrain or {}), 0)
	local d = terrainRun(g, 1031, '{ rect = "-100,-100,100,100", flat = 30, dryRun = true }')
	truthy(d.ok, d.error); eq(d.via, "gui"); eq(d.sent, false); eq(#g.terrainCmds, 1); eq(d.written.max, 30)
	local b = terrainRun(g, 1032, '{ rect = "-100,-100,100,100", flat = 25, via = "update" }')
	eq(b.ok, false); truthy(b.error:find("missing in the guiUpdate state: api.engine.terrain.makeMapFromGame"), b.error)
	-- the speed control gone: no pickup, an error after a while
	g.speedControlOff = true
	local c = terrainRun(g, 1033, '{ rect = "-100,-100,100,100", flat = 25, via = "gui" }', FIRST + 700)
	eq(c.ok, false); truthy(c.error:find("did not take it up"), c.error)
	truthy(not g.crashed, g.crashed)
end)

test("terrainApi: what each state has (type only), the recipe's from its report; without the recipe a note", function()
	local g = terrainGame({ reactOnly = true })
	send(g, 1040, "terrainApi")
	frames(g, FIRST + 10)
	local a = final(g, 1040)
	truthy(a and a.ok, a and a.error)
	eq(a.update["api.engine.terrain.makeMapFromGame"], "nil"); eq(a.gui["api.engine.terrain.makeMapFromGame"], "function")
	eq(a.gui["api.gui.map.setMapSeedText"], "function"); eq(a.gui["api.engine.mapgen.createTowns"], "function")
	eq(a.update["api.type.Map.new"], "function"); eq(a.needs[1], "api.engine.terrain.makeMapFromGame")
	eq(#g.terrainCmds, 0); eq(#g.seedTexts, 0, "nothing called")
	g.speedControlOff = true
	send(g, 1041, "terrainApi")
	frames(g, FIRST + 400)
	local b = final(g, 1041)
	truthy(b.ok and b.gui == nil and b.guiNote:find("did not answer"), b.guiNote)
end)

test("terrain: a refused replacement, a map that lists towns, an engine vector of heights", function()
	local g = terrainGame({ replaceFails = true })
	local a = terrainRun(g, 1050, '{ rect = "0,0,100,100", flat = 5 }')
	eq(a.ok, false); truthy(a.error:find("refused"), a.error); eq(hAt(g, 52, 52), 10)
	local t = terrainGame({ townsInMap = true })
	local b = terrainRun(t, 1051, '{ rect = "0,0,100,100", flat = 5 }')
	eq(b.ok, false); truthy(b.error:find("lists towns"), b.error); eq(#t.terrainCmds, 0)
	truthy(not t.crashed, t.crashed)
	local v = terrainGame({ vectorHeights = true })
	local c = terrainRun(v, 1052, '{ rect = "0,0,100,100", flat = 5 }')
	truthy(c.ok, c.error); eq(hAt(v, 52, 52), 5)
	local m = newGame({ saves = SAVES, menu = true })
	frames(m, 2)
	send(m, 1053, "terrain", '{ rect = "0,0,10,10", flat = 1 }')
	frames(m, FIRST)
	truthy((answerText(m, 1053, "error") or ""):find("needs a running game"))
end)

test("terrain outside the map editor: refused unless inGame; inGame sends without the editor's seed and material calls", function()
	local g = terrainGame(nil, { mapEditor = false })
	local a = terrainRun(g, 1070, '{ rect = "0,0,100,100", flat = 5 }')
	eq(a.ok, false); truthy(a.error:find("not the map editor") and a.error:find("--in-game", 1, true), a.error)
	eq(#g.terrainCmds, 0); eq(hAt(g, 52, 52), 10)
	local d = terrainRun(g, 1071, '{ rect = "0,0,100,100", flat = 5, dryRun = true }')
	truthy(d.ok, "a dry run sends nothing: " .. tostring(d.error)); eq(d.sent, false)
	local b = terrainRun(g, 1072, '{ rect = "0,0,100,100", flat = 5, inGame = true }')
	truthy(b.ok, b.error); eq(b.inGame, true); eq(hAt(g, 52, 52), 5); eq(#g.terrainCmds, 1)
	eq(#g.seedTexts, 0, "setMapSeedText only in the editor"); eq(g.materialReloads, 0)
	truthy(b.seedText:find("not called"), b.seedText)
	truthy(select(2, core.terrainRequest({ rect = "0,0,10,10", flat = 1, inGame = "yes" })):find("inGame"))
	-- via update in the editor, when asked for (and the functions are there)
	local e = terrainGame()
	local c = terrainRun(e, 1073, '{ rect = "0,0,100,100", flat = 7, via = "update" }')
	truthy(c.ok, c.error); eq(c.via, "update"); eq(hAt(e, 52, 52), 7); eq(#e.seedTexts, 1)
end)

test("terrain: a map over the point limit is refused before it is copied; a send that raises is no 'sent'", function()
	eq(core.terrainMapPoints({ min = { x = -4096, y = -4096 }, max = { x = 4096, y = 4096 } }), 2049 * 2049, "a small map")
	truthy(2049 * 2049 <= core.TERRAIN_MAX_MAP_POINTS and 2817 * 2817 > core.TERRAIN_MAX_MAP_POINTS, "small yes, medium no")
	eq(core.terrainMapPoints({ min = {}, max = {} }), nil)
	local g = terrainGame({ box = { -5632, -5632, 5632, 5632 } })
	local a = terrainRun(g, 1080, '{ rect = "0,0,100,100", flat = 5, dryRun = true }')
	eq(a.ok, false); truthy(a.error:find("at most " .. core.TERRAIN_MAX_MAP_POINTS), a.error)
	eq(g.mapCopies, 0, "nothing copied"); eq(#g.terrainCmds, 0)
	local r = terrainGame({ sendRaises = "engine busy" })
	local b = terrainRun(r, 1081, '{ rect = "0,0,100,100", flat = 5 }')
	eq(b.ok, false); truthy(b.error:find("engine busy"), b.error); eq(b.sent, false)
	eq(hAt(r, 52, 52), 10)
	local u = terrainGame({ sendRaises = "engine busy" })
	local c = terrainRun(u, 1082, '{ rect = "0,0,100,100", flat = 5, via = "update" }')
	eq(c.ok, false); truthy(c.error:find("engine busy"), c.error); eq(c.sent, false)
end)

test("terrain: a town whose place cannot be read is a warning, not a refusal; its buildings are still looked for", function()
	local g = terrainGame(nil, { entities = { TOWN = { 12 } }, names = { [12] = "Nowhere" } })
	local a = terrainRun(g, 1090, '{ rect = "0,0,100,100", flat = 5 }')
	truthy(a.ok, a.error)
	truthy(a.warnings and a.warnings[1]:find("town Nowhere (12): its place could not be read", 1, true), a.warnings and a.warnings[1])
	eq(hAt(g, 52, 52), 5)
end)

test("newgame editor: isMapEditor, the official mods and the probe only (not the running game's); status says so", function()
	local g = newGame({ saves = SAVES, mods = { "hummer_age_of_mobility", "hummer_remote_probe" },
		modParams = { hummer_age_of_mobility = { x = 2 } },
		installed = { "hummer_age_of_mobility", "ug_tgv_pse", "ug_legacy_ships", "hummer_remote_probe" } })
	frames(g, 2)
	send(g, 1060, "newgame", '{ size = "tiny", editor = true, dryRun = true }')
	frames(g, FIRST)
	local d = final(g, 1060)
	eq(d.plan.editor, true); eq(table.concat(d.plan.mods, ","), "ug_legacy_ships,ug_tgv_pse,hummer_remote_probe")
	eq(d.plan.modParams.hummer_age_of_mobility, nil, "no params of the game's mods")
	send(g, 1061, "newgame", '{ size = "tiny", editor = true, unsafe = true, mods = { add = { "extra" } } }')
	frames(g, FIRST)
	eq(#g.started, 1)
	eq(g.started[1].isMapEditor, true)
	eq(table.concat(g.started[1].mods, ","), "ug_legacy_ships,ug_tgv_pse,extra,hummer_remote_probe")
	frames(g, 3)
	send(g, 1062, "status")
	frames(g, FIRST)
	local s = final(g, 1062)
	eq(s.mapEditor.gui, true)
	-- the menu way too
	local m = newGame({ saves = SAVES, menu = true, installed = { "ug_tgv_pse" } })
	frames(m, 2)
	send(m, 1063, "newgame", '{ size = "tiny", editor = true }')
	frames(m, FIRST)
	eq(m.started[1].isMapEditor, true); eq(table.concat(m.started[1].mods, ","), "ug_tgv_pse,hummer_remote_probe")
	-- without editor: as before
	local n = newGame({ saves = SAVES })
	frames(n, 2)
	send(n, 1064, "newgame", '{ size = "tiny", unsafe = true }')
	frames(n, FIRST)
	eq(n.started[1].isMapEditor, false)
	send(n, 1065, "status")
	frames(n, FIRST + 5)
	local s2 = final(n, 1065)
	eq(s2.mapEditor.gui, false)
end)

---------------------------------------------------------------------------------------------------------------------
-- town (one town at a point, its first needs)

test("core.townRequest: at, name, size, capacity, needs, via, inGame; the limits", function()
	local r = core.townRequest({ at = "100,-200", name = " Harbourside " })
	eq(r.at.x, 100); eq(r.at.y, -200); eq(r.name, "Harbourside", "trimmed"); eq(r.size, 1); eq(r.capacity, nil)
	eq(r.needs, "auto"); eq(r.via, "auto"); eq(r.inGame, false); eq(r.dryRun, false)
	local s = core.townRequest({ at = { 5, 6 }, name = "B", size = 0.5, capacity = 300, needs = "com:fish, ind:planks",
		via = "update", inGame = true, dryRun = true })
	eq(s.size, 0.5); eq(s.capacity, 300); eq(s.needs.com[1], "fish"); eq(s.needs.ind[1], "planks"); eq(#s.needs.res, 0)
	eq(s.via, "update"); eq(s.inGame, true); eq(s.dryRun, true)
	eq(core.townRequest({ at = "0,0", name = "N", needs = false }).needs, "none")
	eq(core.townRequest({ at = "0,0", name = "N", needs = "none" }).needs, "none")
	eq(core.townRequest({ at = "0,0", name = "N", needs = { com = { "fish", "fish" } } }).needs.com[2], nil, "the same once")
	truthy(core.townRequest({ at = "0,0", name = "N", size = core.TOWN_SIZE[2] }), "the limit itself")
	for _, bad in ipairs({
		{ { name = "N" }, "give at" },
		{ { at = "1", name = "N" }, "x,y" },
		{ { at = "a,b", name = "N" }, "at" },
		{ { at = "0,200000", name = "N" }, "within" },
		{ { at = "0,0" }, "give name" },
		{ { at = "0,0", name = "   " }, "give name" },
		{ { at = "0,0", name = string.rep("x", 65) }, "at most 64" },
		{ { at = "0,0", name = "N", size = 0 }, "size must be" },
		{ { at = "0,0", name = "N", size = 3.5 }, "size must be" },
		{ { at = "0,0", name = "N", size = "big" }, "size must be" },
		{ { at = "0,0", name = "N", capacity = 0 }, "capacity" },
		{ { at = "0,0", name = "N", capacity = 1.5 }, "capacity" },
		{ { at = "0,0", name = "N", capacity = 1001 }, "capacity" },
		{ { at = "0,0", name = "N", needs = "fish" }, "land use:category" },
		{ { at = "0,0", name = "N", needs = "shop:fish" }, "res, com or ind" },
		{ { at = "0,0", name = "N", needs = "com:fi sh" }, "land use:category" },
		{ { at = "0,0", name = "N", needs = "com:a,com:b,com:c,com:d" }, "at most 3" },
		{ { at = "0,0", name = "N", needs = {} }, "none given" },
		{ { at = "0,0", name = "N", needs = 5 }, "needs" },
		{ { at = "0,0", name = "N", via = "cmd" }, "via" },
		{ { at = "0,0", name = "N", inGame = "yes" }, "inGame" },
	}) do
		local ok, err = core.townRequest(bad[1])
		eq(ok, nil, bad[2]); truthy(err and err:find(bad[2], 1, true), tostring(err) .. " / " .. bad[2])
	end
	truthy(core.COMMANDS.town and core.CHANGES_GAME.town and not core.MENU_COMMANDS.town, "changes the game, in a game")
	eq(#core.townRequests({ { id = 1, kind = "apply", args = { at = "0,0", name = "A" }, propose = true },
		{ id = 2, kind = "apply", args = { at = "0,0" } }, { kind = "apply", args = { at = "0,0", name = "A" } },
		{ id = 3, kind = "probe" } }), 1)
	eq(core.townRequests({ { id = 1, kind = "apply", args = { at = "0,0", name = "A" }, propose = true } })[1].propose, true)
end)

test("core.townNeedsPlan / townNeedIds / townNeedsMet / townScaledCapacities", function()
	local LU = { RESIDENTIAL = 0, COMMERCIAL = 1, INDUSTRIAL = 2 }
	local cats = { vegetables = { tier = 0, landUses = { 1 } }, fish = { tier = 0, landUses = { "COMMERCIAL" } },
		planks = { tier = 0, landUses = { 2 } }, tools = { tier = 1, landUses = { 1 } }, oil = { tier = 0, landUses = { 2 } } }
	local cargo = { [11] = "fish", [12] = "vegetables", [13] = "planks", [15] = "tools", [16] = "fish" }
	local n, ids = core.townNeedsPlan("auto", cats, cargo, LU)
	eq(n.com[1], "fish", "the first of tier 0 by name"); eq(#n.com, 1); eq(n.ind[1], "planks", "oil has no cargo type"); eq(#n.res, 0)
	eq(ids[2][1], 11, "the lowest id of the category"); eq(ids[3][1], 13); eq(#ids[1], 0)
	local m, mids = core.townNeedsPlan({ res = {}, com = { "tools", "vegetables" }, ind = {} }, cats, cargo, LU)
	eq(table.concat(m.com, ","), "tools,vegetables"); eq(table.concat(mids[2], ","), "15,12")
	local none, nids = core.townNeedsPlan("none", cats, cargo, LU)
	eq(#none.com + #none.ind, 0); eq(#nids[2], 0)
	local x, err = core.townNeedsPlan({ com = { "gold" } }, cats, cargo, LU)
	eq(x, nil); truthy(err:find('no cargo category "gold"') and err:find("fish, oil, planks"), err)
	local y, err2 = core.townNeedsPlan({ ind = { "oil" } }, cats, cargo, LU)
	eq(y, nil); truthy(err2:find("no cargo type"), err2)
	local have = core.townNeedIds({ {}, { { 11, 1 }, { 12, 0.5 } }, { 13 } })
	eq(table.concat(have[2], ","), "11,12"); eq(have[3][1], 13)
	eq(#core.townNeedIds(nil)[1], 0)
	eq(core.townNeedsMet(have, { {}, { 11 }, { 13 } }), true); eq(core.townNeedsMet(have, { {}, { 15 }, {} }), false)
	eq(core.townNeedsMet({ {}, {}, {} }, { {}, {}, {} }), true)
	local sc = core.townScaledCapacities({ 200, 100, 0 }, 100)
	eq(sc[1], 200); eq(sc[2], 100); eq(sc[3], 0, "the proportions kept, average 100")
	eq(core.townScaledCapacities({ 0, 0, 0 }, 100), nil)
end)

-- the map editor (unless opts.mapEditor = false) with the speed control on screen and the town fakes
local function townGame(spec, opts)
	opts = opts or {}
	if opts.mapEditor == nil then opts.mapEditor = true end
	opts.entities = opts.entities or { TOWN = { 11 } }
	opts.names = opts.names or { [11] = "Oldtown" }
	local g = vehicleGame(opts)
	fake.installTown(g, spec)
	return g
end
local function townRun(g, id, argsLua, n)
	send(g, id, "town", argsLua)
	frames(g, n or FIRST + 30)
	return final(g, id)
end

test("town: placed in the editor via gui; createTowns gets the name, place, size and needs; the answer has the town", function()
	local g = townGame()
	local a = townRun(g, 2001, '{ at = "300,-400", name = "Harbourside", size = 1.5 }')
	truthy(a and a.ok, a and a.error)
	eq(a.via, "gui"); eq(a.sent, true); eq(a.success, true); eq(a.mapEditor, true)
	-- what createTowns got
	eq(#g.townProposals, 1); eq(#g.townProposals[1], 1)
	local t = g.townProposals[1][1]
	eq(t.name, "Harbourside"); eq(t.pos.x, 300); eq(t.pos.y, -400); eq(t.existing, -1)
	eq(table.concat(t.sizeFactors, ","), "1.5,1.5,1.5")
	-- the first needs as category names per land use (COMMERCIAL 1, INDUSTRIAL 2), weight 1
	eq(t.landUse2CargoNeeds[1][1][1], "fish"); eq(t.landUse2CargoNeeds[1][1][2], 1); eq(t.landUse2CargoNeeds[2][1][1], "bricks")
	eq(t.landUse2CargoNeeds[0], nil, "none for the homes")
	-- what was sent: the TownInfo createTowns gave, unchanged
	eq(#g.townCmds, 1); eq(#g.townCmds[1].towns, 1); eq(g.townCmds[1].towns[1].name, "Harbourside")
	eq(table.concat(g.townCmds[1].towns[1].initialLandUseCapacities, ","), "150,75,75")
	-- the answer
	eq(a.entity, g.newTowns[1]); eq(a.townName, "Harbourside"); eq(a.position.x, 300); eq(a.position.y, -400)
	eq(a.population, 150); eq(a.proposal.initialLandUseCapacities[1], 150); eq(a.proposal.majorStreetAngle, 0.5)
	eq(a.needs.com[1], "fish"); eq(a.needs.ind[1], "bricks"); eq(a.needIds[2][1], 11)
	-- the town got no needs from the map's: sent once with the ids, as RWMI, and read back
	eq(#g.townNeedsCmds, 1); eq(g.townNeedsCmds[1].town, a.entity); eq(g.townNeedsCmds[1].needs[2][1], 11)
	eq(g.townNeedsCmds[1].needs[3][1], 14); eq(g.townNeedsCmds[1].update, true)
	eq(a.needsMet, true); truthy(a.needsSet:find("sent"), a.needsSet)
	truthy(a.note:find("not checked in a game"), a.note)
	eq(#(fake.guiSave.hummer_remote_probe.town or {}), 0, "the request taken back")
	truthy(not g.crashed, g.crashed)
end)

test("town: needs the town already took are not sent again; none asked sends none; asked ones by name", function()
	local g = townGame({ needsFromMap = true })
	local a = townRun(g, 2010, '{ at = "0,0", name = "A" }')
	truthy(a.ok, a.error); eq(#g.townNeedsCmds, 0); eq(a.needsMet, true); truthy(a.needsSet:find("not needed"), a.needsSet)
	local b = townRun(g, 2011, '{ at = "500,0", name = "B", needs = "none" }')
	truthy(b.ok, b.error); eq(#g.townNeedsCmds, 0); eq(b.needsSet, "none asked")
	eq(next(g.townProposals[2][1].landUse2CargoNeeds), nil, "no needs in the map's town")
	local h = townGame()
	local c = townRun(h, 2012, '{ at = "0,0", name = "C", needs = "com:vegetables,com:tools,ind:planks" }')
	truthy(c.ok, c.error)
	eq(#h.townProposals[1][1].landUse2CargoNeeds[1], 2)
	eq(table.concat(h.townNeedsCmds[1].needs[2], ","), "12,15"); eq(h.townNeedsCmds[1].needs[3][1], 13)
	local d = townRun(h, 2013, '{ at = "0,0", name = "D", needs = "com:gold" }')
	eq(d.ok, false); truthy(d.error:find('no cargo category "gold"'), d.error); eq(#h.townCmds, 1, "nothing sent")
end)

test("town --dry-run: createTowns' proposal in the editor, nothing sent; outside it without inGame not even that", function()
	local g = townGame()
	local a = townRun(g, 2020, '{ at = "100,100", name = "Dry", capacity = 300, dryRun = true }')
	truthy(a.ok, a.error)
	eq(a.dryRun, true); eq(a.sent, false); eq(a.success, nil); eq(a.entity, nil)
	eq(#g.townProposals, 1); eq(#g.townCmds, 0); eq(#g.townNeedsCmds, 0); eq(#g.newTowns, 0)
	eq(table.concat(a.proposal.scaledCapacities, ","), "450,225,225", "average 300, the engine's proportions")
	local o = townGame(nil, { mapEditor = false })
	local b = townRun(o, 2021, '{ at = "100,100", name = "Dry", dryRun = true }')
	truthy(b.ok, b.error); eq(b.sent, false); eq(#o.townProposals, 0, "createTowns not asked")
	truthy(b.proposalNote:find("not the map editor"), b.proposalNote); eq(b.needs.com[1], "fish")
	local c = townRun(o, 2022, '{ at = "100,100", name = "Dry", dryRun = true, inGame = true }')
	truthy(c.ok, c.error); eq(#o.townProposals, 1); eq(#o.townCmds, 0)
end)

test("town outside the map editor: refused unless inGame; inGame places it", function()
	local g = townGame(nil, { mapEditor = false })
	local a = townRun(g, 2030, '{ at = "0,0", name = "X" }')
	eq(a.ok, false); truthy(a.error:find("not the map editor") and a.error:find("--in-game", 1, true), a.error)
	eq(#g.townProposals, 0); eq(#g.townCmds, 0)
	local b = townRun(g, 2031, '{ at = "0,0", name = "X", inGame = true }')
	truthy(b.ok, b.error); eq(b.inGame, true); eq(#g.townCmds, 1); eq(b.townName, "X")
	-- the capacity scaled into what is sent
	local c = townRun(g, 2032, '{ at = "900,0", name = "Y", inGame = true, capacity = 60 }')
	truthy(c.ok, c.error); eq(table.concat(g.townCmds[2].towns[1].initialLandUseCapacities, ","), "90,45,45")
end)

test("town: the engine's error as it is, no room, a refused command, toRemove never destroyed, off the map", function()
	local g = townGame({ createRaises = "TownGenerator: collides with a street" })
	local a = townRun(g, 2040, '{ at = "0,0", name = "E" }')
	eq(a.ok, false); truthy(a.error:find("TownGenerator: collides with a street", 1, true), a.error); eq(#g.townCmds, 0)
	local n = townGame({ noRoom = true })
	local b = townRun(n, 2041, '{ at = "0,0", name = "E" }')
	eq(b.ok, false); truthy(b.error:find("no room"), b.error); eq(#n.townCmds, 0)
	local f = townGame({ createFails = true })
	local c = townRun(f, 2042, '{ at = "0,0", name = "E" }')
	eq(c.ok, false); truthy(c.error:find("refused"), c.error); eq(c.sent, true); eq(#f.townNeedsCmds, 0)
	local r = townGame({ toRemove = { 11 } })
	local d = townRun(r, 2043, '{ at = "0,0", name = "E" }')
	truthy(d.ok, d.error); eq(d.toRemoveIgnored, 1)
	for _, cmd in ipairs(r.commands) do truthy(cmd.kind ~= "townDestroy", "nothing destroyed") end
	local e = townRun(r, 2044, '{ at = "9000,0", name = "Far" }')
	eq(e.ok, false); truthy(e.error:find("not on the map"), e.error)
	truthy(not g.crashed and not n.crashed and not f.crashed and not r.crashed)
end)

test("town: via gui where only the recipe has the functions; via update refused there, works where it has them", function()
	local g = townGame({ reactOnly = true })
	local a = townRun(g, 2050, '{ at = "0,0", name = "R" }')
	truthy(a.ok, a.error); eq(a.via, "gui"); eq(a.functionsUpdate["api.engine.mapgen.createTowns"], "nil")
	eq(a.functionsGui["api.engine.mapgen.createTowns"], "function"); eq(#g.townCmds, 1)
	local b = townRun(g, 2051, '{ at = "0,0", name = "R", via = "update" }')
	eq(b.ok, false); truthy(b.error:find("missing in the guiUpdate state: api.engine.mapgen.createTowns"), b.error)
	local u = townGame()
	local c = townRun(u, 2052, '{ at = "0,0", name = "U", via = "update" }')
	truthy(c.ok, c.error); eq(c.via, "update"); eq(#u.townCmds, 1); eq(c.needsMet, true)
	-- the speed control gone: no pickup, an error after a while
	u.speedControlOff = true
	local d = townRun(u, 2053, '{ at = "0,0", name = "V" }', FIRST + 700)
	eq(d.ok, false); truthy(d.error:find("did not take it up"), d.error)
	-- the menu: refused
	local m = newGame({ saves = SAVES, menu = true })
	frames(m, 2)
	send(m, 2054, "town", '{ at = "0,0", name = "M" }')
	frames(m, FIRST)
	truthy((answerText(m, 2054, "error") or ""):find("needs a running game"))
end)

test("town: a create callback frames later (the report read again), none at all (timeout), no town made, no map check", function()
	local g = townGame({ callbackFrames = 6 })
	local a = townRun(g, 2070, '{ at = "0,0", name = "Late" }')
	truthy(a and a.ok, a and a.error); eq(a.success, true); eq(a.entity, g.newTowns[1]); eq(a.needsMet, true)
	local l = townGame({ lostCallback = true })
	local b = townRun(l, 2071, '{ at = "0,0", name = "Lost" }', FIRST + 30)
	eq(b, nil, "no answer before the timeout")
	frames(l, 300, 0.25) -- 75 s of application time: past the 60 s for the callback
	b = final(l, 2071)
	eq(b.ok, false); truthy(b.error:find("no answer from the engine"), b.error); eq(b.sent, true)
	local n = townGame({ lostTown = true })
	local c = townRun(n, 2072, '{ at = "0,0", name = "Ghost" }')
	eq(c.ok, false); truthy(c.error:find("new town was not found"), c.error)
	local v = townGame({ noValidCheck = true })
	local d = townRun(v, 2073, '{ at = "0,0", name = "Unchecked" }')
	truthy(d.ok, d.error); truthy(d.warnings and d.warnings[1]:find("could not be checked"), d.warnings and d.warnings[1])
	eq(d.functionsGui["api.engine.terrain.isValidCoordinate"], "nil")
	eq(d.functionsGui["api.cmd.makeTownUpdateCargoNeedsCmd"], "function")
	truthy(not g.crashed and not l.crashed and not n.crashed and not v.crashed)
end)

test("town: the needs ids sent are whole numbers even when the GUI save data hands back floats", function()
	local ids = core.townIntIds({ {}, { 11.0 }, { 13.0, 14 } })
	eq(ids[2][1], 11); eq(#ids[3], 2); eq(#ids[1], 0)
	if math.tointeger then eq(math.type(ids[2][1]), "integer") end
	eq(#core.townIntIds(nil)[2], 0)
end)

test("town: needs refused or the needs command missing are warnings; the town is still answered", function()
	local g = townGame({ needsFails = true })
	local a = townRun(g, 2060, '{ at = "0,0", name = "W" }')
	truthy(a.ok, a.error); eq(a.needsMet, false); truthy(a.needsSet:find("refused"), a.needsSet)
	truthy(a.warnings and a.warnings[1]:find("not those asked"), a.warnings and a.warnings[1])
	local h = townGame({ noNeedsCmd = true })
	local b = townRun(h, 2061, '{ at = "0,0", name = "W" }')
	truthy(b.ok, b.error); truthy(b.needsSet:find("not sent"), b.needsSet); eq(b.entity, h.newTowns[1])
	truthy(not g.crashed and not h.crashed)
end)

---------------------------------------------------------------------------------------------------------------------
-- debug commands (remote_debug.lua): stockList, stockSet, steps

test("core.stockSetRequest / stepsRequest / stockListArgs: ranges and shapes", function()
	local r = core.stockSetRequest({ entity = 51, stock = 0, amount = 100 })
	eq(r.entity, 51); eq(r.stock, 0); eq(r.amount, 100); eq(r.cargo, nil); eq(r.dryRun, false)
	local v = core.stockSetRequest({ entity = "601", stock = -1, amount = "0", cargo = "COAL", dryRun = true })
	eq(v.entity, 601); eq(v.stock, -1); eq(v.amount, 0); eq(v.cargo, "COAL"); eq(v.dryRun, true)
	eq(core.stockSetRequest({ entity = 1, stock = 0, amount = core.STOCK_MAX_AMOUNT }).amount, core.STOCK_MAX_AMOUNT)
	for _, bad in ipairs({
		{ {}, "entity" }, { { entity = -1, stock = 0, amount = 1 }, "entity" }, { { entity = 1.5, stock = 0, amount = 1 }, "entity" },
		{ { entity = "x", stock = 0, amount = 1 }, "entity" }, { { entity = 2 ^ 31, stock = 0, amount = 1 }, "entity" },
		{ { entity = 1, amount = 1 }, "stock" }, { { entity = 1, stock = -2, amount = 1 }, "stock" },
		{ { entity = 1, stock = 0.5, amount = 1 }, "stock" }, { { entity = 1, stock = 1001, amount = 1 }, "stock" },
		{ { entity = 1, stock = 0 }, "amount" }, { { entity = 1, stock = 0, amount = -1 }, "amount" },
		{ { entity = 1, stock = 0, amount = core.STOCK_MAX_AMOUNT + 1 }, "amount" }, { { entity = 1, stock = 0, amount = 2.5 }, "amount" },
		{ { entity = 1, stock = 0, amount = 0 / 0 }, "amount" },
		{ { entity = 1, stock = 0, amount = 1, cargo = "" }, "cargo" }, { { entity = 1, stock = 0, amount = 1, cargo = 5 }, "cargo" },
		{ { entity = 1, stock = 0, amount = 1, cargo = "CO AL" }, "cargo" },
		{ { entity = 1, stock = 0, amount = 1, cargo = ("X"):rep(core.CARGO_NAME_MAX + 1) }, "cargo" },
		{ { entity = 1, stock = -1, amount = 1 }, "needs cargo" },
		{ { entity = 1, stock = 0, amount = 1, dryRun = "yes" }, "dryRun" },
	}) do
		local ok, err = core.stockSetRequest(bad[1])
		eq(ok, nil, bad[2])
		truthy(tostring(err):find(bad[2], 1, true), tostring(err) .. " / " .. bad[2])
	end
	truthy(select(2, core.stockSetRequest(nil)))
	eq(core.stepsRequest({ count = 1 }).count, 1); eq(core.stepsRequest({ count = core.STEPS_MAX }).count, core.STEPS_MAX)
	eq(core.stepsRequest({ count = "5", dryRun = true }).dryRun, true)
	for _, bad in ipairs({ {}, { count = 0 }, { count = core.STEPS_MAX + 1 }, { count = 1.5 }, { count = "x" }, { count = -3 }, { count = 0 / 0 } }) do
		truthy(select(2, core.stepsRequest(bad)):find("count must be"))
	end
	truthy(select(2, core.stepsRequest({ count = 2, dryRun = 1 })):find("dryRun"))
	eq(core.stockListArgs({ entity = 7 }).entity, 7)
	truthy(select(2, core.stockListArgs({})):find("entity"))
	-- stockSet and steps warn other owners (they change the game); stockList only reads
	eq(core.CHANGES_GAME.stockSet, true); eq(core.CHANGES_GAME.steps, true); eq(core.CHANGES_GAME.stockList, nil)
	eq(core.COMMANDS.stockList, true); eq(core.COMMANDS.stockSet, true); eq(core.COMMANDS.steps, true)
	eq(core.MENU_COMMANDS.stockSet, nil); eq(core.MENU_COMMANDS.steps, nil)
end)

test("core.debugFunction: there or not by nil only (a locked callable table counts as there)", function()
	local locked = setmetatable({}, { __call = function() end, __metatable = "locked" })
	truthy(core.debugFunction("api.cmd.debug.f", { api = { cmd = { debug = { f = locked } } } }) ~= nil)
	eq(core.debugFunction("api.cmd.debug.f", { api = { cmd = {} } }), nil)
	eq(core.debugFunction("api.cmd.debug.f", { api = { cmd = { debug = 5 } } }), nil)
end)

-- a game with an industry (51: a coal output stock and a mixed input stock), a station's stock list (411, a group's
-- station), an industry 55 whose stocks are on another entity (56), and a vehicle 601 with room for 30 coal
local function debugGame(spec, opts)
	opts = opts or {}
	opts.industries = opts.industries or {
		[51] = { name = "Coal mine", stocks = { { type = 1, cargoType = 1, capacity = 400, count = 37 },
			{ type = 0, cargoType = -1, cargoTypes = { 1, 2 }, capacity = 50, count = 4 } } },
		[55] = { name = "Farm", stockList = 56 } }
	opts.fleet = opts.fleet or { [601] = { vehicles = {}, line = -1, depot = 301, capacities = { 0, 30 },
		live = { loaded = { [1] = 3 } } },
		[602] = { vehicles = {}, line = -1, depot = 301, capacities = { 40, 30 }, live = { loaded = { [0] = 12 } } } }
	local g = vehicleGame(opts)
	spec = spec or {}
	spec.stockLists = spec.stockLists or {
		[411] = { stocks = { { type = 2, cargoType = -1, cargoTypes = { 1, 2 }, capacity = 200, count = 0, byCargo = {} } } },
		[56] = { stocks = { { type = 0, cargoType = 2, capacity = 80, count = 5 } } } }
	spec.owners = spec.owners or { [77] = { kind = "TOWN_BUILDING", stockList = -1 } } -- a building with none
	fake.installDebug(g, spec)
	g.debugSpec = spec
	g.speedup = 0 -- paused, as steps wants it (the game time stays: frozen)
	return g
end
local function debugRun(g, id, cmd, argsLua, n)
	send(g, id, cmd, argsLua)
	frames(g, n or FIRST + 10)
	return final(g, id)
end

test("stockList: an industry's stocks 0-based with counts per cargo, a station's, an owner's, a vehicle's load", function()
	local g = debugGame()
	local a = debugRun(g, 2201, "stockList", "{ entity = 51 }")
	truthy(a.ok, a.error); eq(a.kind, "stockList"); eq(a.stockList, 51); eq(#a.stocks, 2)
	eq(a.stocks[1].stockId, 0); eq(a.stocks[1].cargo, "COAL"); eq(a.stocks[1].count, 37); eq(a.stocks[1].capacity, 400)
	eq(a.stocks[2].stockId, 1); eq(a.stocks[2].cargoType, -1); eq(#a.stocks[2].cargoTypes, 2)
	eq(a.stocks[2].cargoTypes[2].cargo, "GRAIN")
	local b = debugRun(g, 2202, "stockList", "{ entity = 411 }")
	truthy(b.ok, b.error); eq(b.stockList, 411); eq(b.stocks[1].typeName, "StorageStock"); eq(b.stocks[1].cargoTypes[1].count, 0)
	local o = debugRun(g, 2203, "stockList", "{ entity = 55 }")
	truthy(o.ok, o.error); eq(o.stockList, 56); eq(o.via, "INDUSTRY"); eq(o.stocks[1].count, 5); eq(o.stocks[1].cargo, "GRAIN")
	local v = debugRun(g, 2204, "stockList", "{ entity = 601 }")
	truthy(v.ok, v.error); eq(v.kind, "vehicle"); eq(v.stock, -1); eq(#v.cargo, 1)
	eq(v.cargo[1].cargo, "COAL"); eq(v.cargo[1].capacity, 30); eq(v.cargo[1].count, 3)
	local x = debugRun(g, 2205, "stockList", "{ entity = 99999 }")
	eq(x.ok, false); truthy(x.error:find("no such entity"), x.error)
	local y = debugRun(g, 2206, "stockList", "{ entity = 77 }") -- a town building without a stock list
	eq(y.ok, false); truthy(y.error:find("holds no stock list"), y.error)
	truthy(not g.crashed, g.crashed)
end)

test("stockSet: sent with the stock list's entity, 0-based stock and the amount; read back; cargo only when given", function()
	local g = debugGame()
	local a = debugRun(g, 2211, "stockSet", "{ entity = 51, stock = 0, amount = 100 }")
	truthy(a.ok, a.error); eq(a.sent, true); eq(a.success, true); eq(a.before, 37); eq(a.after, 100)
	local c = g.debugCmds[1]
	eq(c.entity, 51); eq(c.stock, 0); eq(c.amount, 100); eq(c.nargs, 3, "no cargo argument when none is given")
	eq(a.engineResult.kind, "debugStock", "the callback's data comes back")
	-- an owner: the command goes to its stock list's entity
	local o = debugRun(g, 2212, "stockSet", "{ entity = 55, stock = 0, amount = 60 }")
	truthy(o.ok, o.error); eq(g.debugCmds[2].entity, 56); eq(o.stockList, 56); eq(o.before, 5); eq(o.after, 60)
	-- a station's mixed stock, one cargo type
	local s = debugRun(g, 2213, "stockSet", '{ entity = 411, stock = 0, amount = 100, cargo = "COAL" }')
	truthy(s.ok, s.error); eq(g.debugCmds[3].cargoType, "COAL"); eq(g.debugCmds[3].nargs, 4); eq(s.before, 0); eq(s.after, 100)
	-- a vehicle's load: stock -1 and the cargo name
	local v = debugRun(g, 2214, "stockSet", '{ entity = 601, stock = -1, amount = 30, cargo = "COAL" }')
	truthy(v.ok, v.error); eq(v.holder, "vehicle"); eq(g.debugCmds[4].stock, -1); eq(v.before, 3); eq(v.after, 30)
	truthy(not g.crashed, g.crashed)
end)

test("stockSet: what the stock cannot take is refused before anything is sent; dry run sends nothing", function()
	local g = debugGame()
	for i, case in ipairs({
		{ "{ entity = 51, stock = 2, amount = 1 }", "no stock 2" },
		{ "{ entity = 51, stock = -1, amount = 1, cargo = \"COAL\" }", "no stock -1" },
		{ "{ entity = 51, stock = 0, amount = 401 }", "capacity" },
		{ "{ entity = 51, stock = 0, amount = 1, cargo = \"GRAIN\" }", "does not take GRAIN" },
		{ "{ entity = 411, stock = 0, amount = 1, cargo = \"FISH\" }", "does not take FISH" },
		{ "{ entity = 601, stock = 0, amount = 1, cargo = \"COAL\" }", "stock -1" },
		{ "{ entity = 601, stock = -1, amount = 31, cargo = \"COAL\" }", "capacity" },
		{ "{ entity = 601, stock = -1, amount = 1, cargo = \"GRAIN\" }", "no room for GRAIN" },
		{ "{ entity = 99999, stock = 0, amount = 1 }", "no such entity" },
		{ "{ entity = 51, stock = 0, amount = -5 }", "amount must be" },
		{ "{ entity = 51, amount = 5 }", "stock must be" },
	}) do
		local a = debugRun(g, 2220 + i, "stockSet", case[1])
		eq(a.ok, false, case[1]); truthy(tostring(a.error):find(case[2], 1, true), tostring(a.error) .. " / " .. case[2])
	end
	eq(#g.debugCmds, 0, "nothing sent")
	-- passengers: left out of a vehicle's list and refused, as the base's debug panel leaves them out
	local p = debugRun(g, 2236, "stockList", "{ entity = 602 }")
	truthy(p.ok, p.error); eq(#p.cargo, 1); eq(p.cargo[1].cargo, "COAL")
	local q = debugRun(g, 2237, "stockSet", '{ entity = 602, stock = -1, amount = 1, cargo = "PASSENGERS" }')
	eq(q.ok, false); truthy(q.error:find("passengers cannot be set"), q.error)
	-- a mixed stock: the other cargo there counts against the capacity
	g.debugSpec.stockLists[411].stocks[1].byCargo = { [2] = 150 }
	local m = debugRun(g, 2238, "stockSet", '{ entity = 411, stock = 0, amount = 51, cargo = "COAL" }')
	eq(m.ok, false); truthy(m.error:find("other cargo"), m.error)
	eq(#g.debugCmds, 0, "nothing sent")
	local m2 = debugRun(g, 2239, "stockSet", '{ entity = 411, stock = 0, amount = 50, cargo = "COAL", dryRun = true }')
	truthy(m2.ok, m2.error)
	local d = debugRun(g, 2240, "stockSet", "{ entity = 51, stock = 0, amount = 100, dryRun = true }")
	truthy(d.ok, d.error); eq(d.sent, false); eq(d.dryRun, true); eq(d.before, 37); eq(d.functionPresent, true)
	local s = debugRun(g, 2241, "steps", "{ count = 50, dryRun = true }")
	truthy(s.ok, s.error); eq(s.sent, false); eq(s.count, 50)
	eq(#g.debugCmds, 0, "a dry run sends nothing"); eq(g.updateCount, 1000)
	truthy(not g.crashed, g.crashed)
end)

test("steps: sent with the count; the game time and update count before and after", function()
	local g = debugGame({ stepMs = 200 })
	local a = debugRun(g, 2251, "steps", "{ count = 25 }")
	truthy(a.ok, a.error); eq(a.sent, true); eq(a.success, true)
	eq(g.debugCmds[1].amount, 25); eq(g.debugCmds[1].nargs, 1)
	eq(a.before.gameTime, 123456); eq(a.after.gameTime, 123456 + 5000); eq(a.gameTimeDelta, 5000)
	eq(a.updateCountDelta, 25); eq(a.gameTimePerStep, 200)
	truthy(a.before.date and a.before.date.year, "the date too")
	local b = debugRun(g, 2252, "steps", "{ count = 10001 }")
	eq(b.ok, false); truthy(b.error:find("count must be")); eq(#g.debugCmds, 1)
end)

test("core.stepsWaitSec / stepsDone: the wait grows with the count; either mark says the steps all ran", function()
	eq(core.STEP_GAME_TIME, 200)
	eq(core.stepsWaitSec(1), 30); eq(core.stepsWaitSec(1000), 30); eq(core.stepsWaitSec(10000), 200)
	eq(core.stepsWaitSec(5000), 100)
	local b = { gameTime = 1000, updateCount = 50 }
	eq(core.stepsDone(b, { gameTime = 1000 + 64 * 200, updateCount = 50 + 64 }, 100), false)
	eq(select(2, core.stepsDone(b, { gameTime = 1000 + 99 * 200, updateCount = 150 }, 100)), "updateCount")
	eq(select(2, core.stepsDone(b, { gameTime = 1000 + 100 * 200, updateCount = 120 }, 100)), "gameTime")
	-- only one mark readable: that one decides
	eq(core.stepsDone({ gameTime = 0 }, { gameTime = 1000 }, 5), true)
	eq(core.stepsDone({ updateCount = 0 }, { updateCount = 4 }, 5), false)
	eq(core.stepsDone({ gameTime = 0 }, { updateCount = 4 }, 5), nil, "neither at both ends")
	eq(core.stepsDone(nil, nil, 5), nil)
	eq(core.stepsRequest({ count = 3 }).allowRunning, false)
	eq(core.stepsRequest({ count = 3, allowRunning = true }).allowRunning, true)
	truthy(select(2, core.stepsRequest({ count = 3, allowRunning = "yes" })):find("allowRunning"))
end)

test("steps: the answer waits for every step when they run on over many frames after the callback", function()
	local g = debugGame({ stepsPerFrame = 7 })
	send(g, 2281, "steps", "{ count = 1000 }")
	frames(g, FIRST + 2)
	eq(select(2, final(g, 2281)), 0, "not answered while the steps run on")
	truthy(g.stepsRun > 0 and g.stepsRun < 1000, "part of them ran: " .. tostring(g.stepsRun))
	frames(g, 150)
	local a, count = final(g, 2281)
	eq(count, 1, "one answer"); truthy(a.ok, a.error); eq(a.success, true); eq(a.timedOut, false)
	eq(a.updateCountDelta, 1000); eq(a.gameTimeDelta, 1000 * 200); eq(a.gameTimePerStep, 200)
	eq(a.doneBy, "updateCount"); eq(a.waitSec, 30); eq(a.speedup, 0)
	truthy(type(a.waitedSec) == "number" and a.waitedSec > 0, "the seconds waited")
	truthy(a.callbackSec ~= nil and a.callbackSec < a.waitedSec, "the callback came before the last step")
	eq(a.before.gameTime, 123456); eq(a.after.gameTime, 123456 + 200000)
end)

test("steps: a game that stops part way answers at the deadline with what ran and timedOut", function()
	local g = debugGame({ stepsPerFrame = 5, stepsStall = 40 })
	send(g, 2282, "steps", "{ count = 100 }")
	frames(g, FIRST + 40)
	eq(select(2, final(g, 2282)), 0, "still waiting")
	frames(g, 31 * 30, 1 / 30)
	local a, count = final(g, 2282)
	eq(count, 1, "one answer"); eq(a.ok, false); eq(a.timedOut, true); eq(a.success, true)
	eq(a.updateCountDelta, 40); eq(a.gameTimeDelta, 40 * 200)
	truthy(a.error:find("had not all run in 30 s", 1, true), a.error)
	truthy(a.waitedSec >= 30, tostring(a.waitedSec)); truthy(a.stepsPerSec > 0)
	-- the engine runs the rest on: a steps sent meanwhile is refused (it would count them as its own)
	local l = debugRun(g, 2284, "steps", "{ count = 5 }")
	eq(l.ok, false); truthy(l.error:find("timed out and may still be running on", 1, true), l.error)
	eq(#g.debugCmds, 1, "not sent")
	g.debugSpec.stepsStall = nil
	frames(g, 20) -- the rest runs on: then steps are taken again
	local m = debugRun(g, 2285, "steps", "{ count = 5 }")
	truthy(m.ok, m.error); eq(m.updateCountDelta, 5)
	-- no callback at all: the same deadline, timedOut too
	local n = debugGame({ noCallback = true })
	send(n, 2283, "steps", "{ count = 5 }")
	frames(n, FIRST + 10)
	eq(select(2, final(n, 2283)), 0)
	frames(n, 31 * 30, 1 / 30)
	local b = final(n, 2283)
	eq(b.ok, false); eq(b.timedOut, true); truthy(b.error:find("no callback from the engine in 30 s", 1, true), b.error)
	eq(b.updateCountDelta, 5, "what ran by then"); truthy(b.waitedSec >= 30)
end)

test("steps: a second steps while the first waits is refused; the game time mark alone; no speed read", function()
	local g = debugGame({ stepsPerFrame = 3 })
	send(g, 2301, "steps", "{ count = 600 }")
	frames(g, FIRST + 2)
	eq(select(2, final(g, 2301)), 0, "the first still waits")
	send(g, 2302, "steps", "{ count = 5 }")
	frames(g, 10)
	local b = final(g, 2302)
	eq(b.ok, false); truthy(b.error:find("command 2301 is still waiting", 1, true), b.error); eq(#g.debugCmds, 1)
	frames(g, 300)
	local a = final(g, 2301)
	truthy(a.ok, a.error); eq(a.updateCountDelta, 600)
	-- the update count unreadable: the game time decides
	local h = debugGame({ stepsPerFrame = 4 })
	local getComponent = api.engine.getComponent
	api.engine.getComponent = function(e, kind)
		local t = getComponent(e, kind)
		if kind == "GAME_TIME" and t then t.updateCount = nil end
		if kind == "GAME_SPEED" then return nil end
		return t
	end
	local c = debugRun(h, 2303, "steps", "{ count = 40 }", FIRST + 30)
	api.engine.getComponent = getComponent
	truthy(c.ok, c.error); eq(c.doneBy, "gameTime"); eq(c.gameTimeDelta, 40 * 200); eq(c.speedup, nil)
	truthy(c.warning:find("speed could not be read", 1, true), c.warning)
end)

test("steps: refused while the game runs unless allowed; allowed, the answer warns", function()
	local g = debugGame({ stepsPerFrame = 50 })
	g.speedup = 1
	local a = debugRun(g, 2291, "steps", "{ count = 10 }")
	eq(a.ok, false); eq(a.sent, false); truthy(a.error:find("pause it first", 1, true), a.error); eq(#g.debugCmds, 0)
	local d = debugRun(g, 2292, "steps", "{ count = 10, dryRun = true }")
	truthy(d.ok, d.error); eq(d.sent, false); truthy(d.warning:find("would be refused", 1, true), d.warning)
	eq(#g.debugCmds, 0)
	local b = debugRun(g, 2293, "steps", "{ count = 10, allowRunning = true }")
	truthy(b.ok, b.error); eq(b.sent, true); eq(b.speedup, 1); truthy(b.warning:find("while the game ran", 1, true), b.warning)
	truthy(b.updateCountDelta >= 10)
end)

test("debug commands: a function not there is not called; locked callable tables are used", function()
	local g = debugGame({ missing = { stockSet = true, steps = true } })
	local a = debugRun(g, 2261, "stockSet", "{ entity = 51, stock = 0, amount = 100 }")
	eq(a.ok, false); eq(a.sent, false); eq(a.functionPresent, false)
	truthy(a.error:find("makeStockSetCargoAmountCmd is not there", 1, true), a.error)
	local b = debugRun(g, 2262, "steps", "{ count = 5 }")
	eq(b.ok, false); eq(b.sent, false); truthy(b.error:find("makeGamePerformSimulationStepsCmd is not there", 1, true), b.error)
	eq(#g.debugCmds, 0)
	-- the dry run says the function is missing too
	local d = debugRun(g, 2263, "stockSet", "{ entity = 51, stock = 0, amount = 1, dryRun = true }")
	truthy(d.ok); eq(d.functionPresent, false)
	local h = debugGame({ opaqueApi = true })
	local c = debugRun(h, 2264, "steps", "{ count = 3 }")
	truthy(c.ok, c.error); eq(h.debugCmds[1].amount, 3)
	local e = debugRun(h, 2265, "stockSet", "{ entity = 51, stock = 1, amount = 20 }")
	truthy(e.ok, e.error); eq(e.after, 20)
end)

test("debug commands: the engine's refusal, a raise and a missing callback come back as errors", function()
	local g = debugGame({ refuse = { stockSet = true, steps = true } })
	local a = debugRun(g, 2271, "stockSet", "{ entity = 51, stock = 0, amount = 100 }")
	eq(a.ok, false); eq(a.sent, true); eq(a.success, false); truthy(a.error:find("refused"), a.error)
	eq(a.before, 37); eq(a.after, 37)
	local b = debugRun(g, 2272, "steps", "{ count = 5 }")
	eq(b.ok, false); eq(b.success, false); truthy(b.error:find("refused"), b.error)
	local refused = false
	for _, l in ipairs(g.logs) do if tostring(l):find("refused by the engine") then refused = true end end
	truthy(refused, "logged")
	local m = debugGame({ makeRaises = "not allowed in release" })
	local c = debugRun(m, 2273, "steps", "{ count = 5 }")
	eq(c.ok, false); eq(c.sent, false); truthy(c.error:find("not allowed in release", 1, true), c.error)
	local s = debugGame({ sendRaises = "debug commands are disabled" })
	local d = debugRun(s, 2274, "stockSet", "{ entity = 51, stock = 0, amount = 1 }")
	eq(d.ok, false); eq(d.sent, false); truthy(d.error:find("debug commands are disabled", 1, true), d.error)
	local n = debugGame({ noCallback = true })
	n.frozen = false
	send(n, 2275, "stockSet", "{ entity = 51, stock = 0, amount = 1 }")
	frames(n, FIRST + 10)
	eq(select(2, final(n, 2275)), 0, "no answer before the deadline")
	frames(n, 31 * 30, 1 / 30)
	local e, count = final(n, 2275)
	eq(count, 1); eq(e.ok, false); truthy(e.error:find("no callback"), e.error)
	truthy(not g.crashed and not m.crashed and not s.crashed and not n.crashed)
end)

-- town develop / town size (remote_town_grow.lua)
test("core.townDevelopRequest / townSizeRequest: ranges, shapes and defaults", function()
	local r = core.townDevelopRequest({ at = "100,-50" })
	eq(r.at.x, 100); eq(r.at.y, -50); eq(r.count, 1); eq(r.streets, false); eq(r.upgrade, false); eq(r.dryRun, false)
	eq(r.radius, core.TOWN_GROW_RADIUS)
	local v = core.townDevelopRequest({ at = { 1, 2 }, count = core.TOWN_DEVELOP_MAX, streets = true, upgrade = true,
		dryRun = true, radius = 100 })
	eq(v.count, core.TOWN_DEVELOP_MAX); eq(v.streets, true); eq(v.upgrade, true); eq(v.dryRun, true); eq(v.radius, 100)
	for _, bad in ipairs({ {}, { at = "1" }, { at = "1,2,3" }, { at = "a,b" }, { at = "nan,1" }, { at = "1e9,0" },
		{ at = "1,2", count = 0 }, { at = "1,2", count = core.TOWN_DEVELOP_MAX + 1 }, { at = "1,2", count = 1.5 },
		{ at = "1,2", streets = "yes" }, { at = "1,2", upgrade = 1 }, { at = "1,2", dryRun = "true" },
		{ at = "1,2", radius = 0 }, { at = "1,2", radius = core.TOWN_GROW_RADIUS_MAX + 1 } }) do
		local ok, err = core.townDevelopRequest(bad)
		eq(ok, nil); truthy(err, "an error for a bad develop")
	end
	truthy(select(2, core.townDevelopRequest(nil)))
	local s = core.townSizeRequest({ entity = 801, factors = "1.5,1.2,1" })
	eq(s.entity, 801); eq(s.factors[1], 1.5); eq(s.factors[2], 1.2); eq(s.factors[3], 1); eq(s.updateAll, false)
	local s2 = core.townSizeRequest({ entity = "802", factors = { 0, core.TOWN_GROW_SIZE_MAX, 2 }, updateAll = true,
		dryRun = true })
	eq(s2.entity, 802); eq(s2.factors[2], core.TOWN_GROW_SIZE_MAX); eq(s2.updateAll, true); eq(s2.dryRun, true)
	for _, bad in ipairs({ {}, { entity = 801 }, { entity = -1, factors = "1,1,1" }, { entity = 1.5, factors = "1,1,1" },
		{ entity = 801, factors = "1,1" }, { entity = 801, factors = "1,1,1,1" }, { entity = 801, factors = "1,x,1" },
		{ entity = 801, factors = "-0.1,1,1" }, { entity = 801, factors = "1,1," .. (core.TOWN_GROW_SIZE_MAX + 0.1) },
		{ entity = 801, factors = "1,1,1", updateAll = "yes" } }) do
		local ok, err = core.townSizeRequest(bad)
		eq(ok, nil); truthy(err, "an error for a bad size")
	end
	-- both change the game (and warn other owners), neither runs in the main menu
	eq(core.COMMANDS.townDevelop, true); eq(core.COMMANDS.townSize, true)
	eq(core.CHANGES_GAME.townDevelop, true); eq(core.CHANGES_GAME.townSize, true)
	eq(core.MENU_COMMANDS.townDevelop, nil); eq(core.MENU_COMMANDS.townSize, nil)
end)

test("core.townBuildingCounts / townCountDelta: per town, total, near, unknown kinds; empty and nil", function()
	local towns, total, near = core.townBuildingCounts({
		{ town = 801, kind = "residential", capacity = 10, near = true },
		{ town = 801, kind = "commercial", capacity = 4, near = false },
		{ town = 802, kind = nil, near = true }, { kind = "industrial", capacity = 2 } })
	eq(towns[801].buildings, 2); eq(towns[801].residential, 1); eq(towns[801].capacity.residential, 10)
	eq(towns[802].unknownKind, 1); eq(towns[-1].industrial, 1)
	eq(total.buildings, 4); eq(near.buildings, 2); eq(near.residential, 1)
	local _, none = core.townBuildingCounts({})
	eq(none.buildings, 0)
	local _, none2 = core.townBuildingCounts(nil)
	eq(none2.buildings, 0)
	local d = core.townCountDelta({ buildings = 1, residential = 1 }, { buildings = 3, residential = 2, commercial = 1 })
	eq(d.buildings, 2); eq(d.residential, 1); eq(d.commercial, 1); eq(d.industrial, 0)
	eq(core.townCountDelta(nil, {}), nil)
end)

-- two towns: 801 (Harbourside, round 0,0: two buildings by the harbour, one far off) and 802 (Inland, at 3000,0)
local function townGrowGame(spec, opts)
	opts = opts or {}
	opts.entities = opts.entities or { TOWN = { 801, 802 } }
	opts.names = opts.names or { [801] = "Harbourside", [802] = "Inland" }
	opts.townBuildings = opts.townBuildings or {
		[7001] = { town = 801, kind = "RESIDENTIAL", capacity = 10, pos = { x = 50, y = 0 } },
		[7002] = { town = 801, kind = "COMMERCIAL", capacity = 4, pos = { x = 0, y = 100 } },
		[7003] = { town = 801, kind = "RESIDENTIAL", capacity = 8, pos = { x = 900, y = 0 } },
		[7004] = { town = 802, kind = "INDUSTRIAL", capacity = 8, pos = { x = 3000, y = 0 } } }
	local g = vehicleGame(opts)
	spec = spec or {}
	spec.towns = spec.towns or { [801] = { sizeFactors = { 1, 1, 1 } }, [802] = { sizeFactors = { 1.2, 1, 1 } } }
	spec.townPos = spec.townPos or { [801] = { x = 0, y = 0 }, [802] = { x = 3000, y = 0 } }
	fake.installTownGrow(g, opts, spec)
	return g
end
local function townGrowRun(g, id, cmd, argsLua, n)
	send(g, id, cmd, argsLua)
	frames(g, n or FIRST + 20)
	return final(g, id)
end

test("town develop: N commands one after another, each a Vec2f and two booleans; counts before and after", function()
	local g = townGrowGame()
	local a = townGrowRun(g, 2301, "townDevelop", '{ at = { 10, 20 }, count = 4, streets = true }', FIRST + 40)
	truthy(a.ok, a.error); eq(a.sent, 4); eq(a.succeeded, 4); eq(a.failed, 0); eq(a.count, 4)
	eq(#g.townGrowCmds, 4)
	local c = g.townGrowCmds[1]
	eq(c.kind, "townDevelop"); eq(c.position.x, 10); eq(c.position.y, 20); eq(c.developStreets, true)
	eq(c.upgradeBuildings, false); eq(c.nargs, 3)
	eq(a.before.total.buildings, 4); eq(a.after.total.buildings, 8); eq(a.delta.total.buildings, 4)
	-- near: within 250 m of 10,20 (7001 and 7002 before; the 4 new ones at the point after)
	eq(a.before.near.buildings, 2); eq(a.after.near.buildings, 6); eq(a.delta.near.buildings, 4)
	eq(a.before.near.residential, 1); eq(a.before.near.commercial, 1)
	-- only the town that changed is listed, with its name
	eq(#a.towns, 1); eq(a.towns[1].town, 801); eq(a.towns[1].name, "Harbourside"); eq(a.towns[1].delta.buildings, 4)
	eq(a.engineResult.kind, "townDevelop", "the callback's data comes back")
	truthy(a.note:find("not checked in a game"), a.note)
	-- upgrade only: sent, nothing new
	local u = townGrowRun(g, 2302, "townDevelop", '{ at = "10,20", upgrade = true }')
	truthy(u.ok, u.error); eq(g.townGrowCmds[5].upgradeBuildings, true); eq(g.townGrowCmds[5].developStreets, false)
	eq(u.delta.total.buildings, 0); eq(#u.towns, 0)
	truthy(not g.crashed, g.crashed)
end)

test("town develop / size: a dry run sends nothing and shows the counts", function()
	local g = townGrowGame()
	local a = townGrowRun(g, 2311, "townDevelop", '{ at = "0,0", count = 50, dryRun = true }')
	truthy(a.ok, a.error); eq(a.sent, 0); eq(a.dryRun, true); eq(#g.townGrowCmds, 0)
	eq(a.before.total.buildings, 4); eq(a.before.near.buildings, 2); eq(#a.towns, 2, "all towns in a dry run")
	eq(a.functions.develop, true); eq(a.functions.vec2f, true)
	local s = townGrowRun(g, 2312, "townSize", '{ entity = 801, factors = "2,1.5,1", updateAll = true, dryRun = true }')
	truthy(s.ok, s.error); eq(s.sent, 0); eq(#g.townGrowCmds, 0)
	eq(s.townBefore.sizeFactors[1], 1); eq(s.before.buildings, 3); eq(s.name, "Harbourside")
	-- a dry run still says what is missing, without failing
	local m = townGrowGame({ missing = { develop = true } })
	local d = townGrowRun(m, 2313, "townDevelop", '{ at = "0,0", dryRun = true }')
	truthy(d.ok, d.error); eq(d.functions.develop, false)
	truthy(not g.crashed and not m.crashed)
end)

test("town size: the town, a list of 3 numbers and the flag; factors and buildings read back", function()
	local g = townGrowGame()
	local a = townGrowRun(g, 2321, "townSize", '{ entity = 801, factors = "3,1.5,1", updateAll = true }')
	truthy(a.ok, a.error); eq(a.sent, 1); eq(a.succeeded, 1)
	local c = g.townGrowCmds[1]
	eq(c.kind, "townSize"); eq(c.townEntity, 801); eq(#c.landUseSizeFactors, 3); eq(c.landUseSizeFactors[1], 3)
	eq(c.landUseSizeFactors[2], 1.5); eq(c.updateAllBuildings, true); eq(c.nargs, 3)
	eq(a.townBefore.sizeFactors[1], 1); eq(a.townAfter.sizeFactors[1], 3)
	eq(a.before.buildings, 3); eq(a.after.buildings, 5); eq(a.delta.buildings, 2)
	-- not a town, not there: refused before anything is sent (an unknown id may be the engine's assertion)
	local x = townGrowRun(g, 2323, "townSize", '{ entity = 99999, factors = "1,1,1" }')
	eq(x.ok, false); truthy(x.error:find("no such entity"), x.error)
	local y = townGrowRun(g, 2324, "townSize", '{ entity = 7001, factors = "1,1,1" }')
	eq(y.ok, false); truthy(y.error:find("no town"), y.error)
	eq(#g.townGrowCmds, 1)
	truthy(not g.crashed, g.crashed)
	-- a town with no buildings yet: counts of 0, not missing
	-- (a new fake game replaces the global api: the one above is done with)
	local h = townGrowGame(nil, { townBuildings = {} })
	local b = townGrowRun(h, 2322, "townSize", '{ entity = 802, factors = "1,1,1" }')
	truthy(b.ok, b.error); eq(b.before.buildings, 0); eq(b.after.buildings, 0); eq(h.townGrowCmds[1].updateAllBuildings, false)
	truthy(not h.crashed, h.crashed)
end)

test("town develop / size: a missing function, the engine's refusal, a raise and a missing callback", function()
	for _, k in ipairs({ "develop", "vec2f" }) do
		local m = townGrowGame({ missing = { [k] = true } })
		local a = townGrowRun(m, 2331, "townDevelop", '{ at = "0,0", count = 3 }')
		eq(a.ok, false); eq(a.sent, 0); truthy(a.error:find("not there"), a.error); eq(#m.townGrowCmds, 0)
		truthy(not m.crashed, m.crashed)
	end
	local ms = townGrowGame({ missing = { size = true } })
	local s = townGrowRun(ms, 2332, "townSize", '{ entity = 801, factors = "1,1,1" }')
	eq(s.ok, false); eq(s.sent, 0); truthy(s.error:find("makeTownUpdateSizeCmd"), s.error)
	-- the engine says no to the 2nd of 3: the others count, the failure is listed
	local r = townGrowGame({ refuse = { develop = 2 } })
	local a = townGrowRun(r, 2333, "townDevelop", '{ at = "0,0", count = 3 }', FIRST + 40)
	truthy(a.ok, a.error); eq(a.sent, 3); eq(a.succeeded, 2); eq(a.failed, 1); eq(a.failures[1].index, 2)
	eq(a.failures[1].success, false); eq(a.delta.total.buildings, 2)
	-- all refused: an error
	local all = townGrowGame({ refuse = { develop = true, size = true } })
	local b = townGrowRun(all, 2334, "townDevelop", '{ at = "0,0", count = 2 }', FIRST + 40)
	eq(b.ok, false); eq(b.succeeded, 0); eq(b.failed, 2); truthy(b.error:find("refused all 2"), b.error)
	local bs = townGrowRun(all, 2335, "townSize", '{ entity = 801, factors = "2,1,1" }')
	eq(bs.ok, false); truthy(bs.error:find("refused the command"), bs.error); eq(bs.townAfter.sizeFactors[1], 1)
	-- making or sending raises: nothing sent
	local mr = townGrowGame({ makeRaises = "no towns here" })
	local c = townGrowRun(mr, 2336, "townDevelop", '{ at = "0,0", count = 5 }')
	eq(c.ok, false); eq(c.sent, 0); truthy(c.error:find("no towns here", 1, true), c.error)
	local sr = townGrowGame({ sendRaises = "queue closed" })
	local d = townGrowRun(sr, 2337, "townSize", '{ entity = 801, factors = "1,1,1" }')
	eq(d.ok, false); eq(d.sent, 0); truthy(d.error:find("queue closed", 1, true), d.error)
	-- the callable tables the engine has (their metatable locked) are found and called
	local ct = townGrowGame({ callableApi = true })
	local e = townGrowRun(ct, 2338, "townDevelop", '{ at = "0,0", count = 2 }', FIRST + 40)
	truthy(e.ok, e.error); eq(e.succeeded, 2)
	-- no callback: one error at the deadline, not a hang; a new command waits its turn meanwhile
	local n = townGrowGame({ noCallback = true })
	send(n, 2339, "townDevelop", '{ at = "0,0", count = 3 }')
	frames(n, FIRST + 10)
	eq(select(2, final(n, 2339)), 0, "no answer before the deadline")
	local busy = townGrowRun(n, 2340, "townSize", '{ entity = 801, factors = "1,1,1" }')
	eq(busy.ok, false); truthy(busy.error:find("still running"), busy.error)
	frames(n, 31 * 30, 1 / 30)
	local f, count = final(n, 2339)
	eq(count, 1); eq(f.ok, false); eq(f.sent, 1); truthy(f.error:find("no callback"), f.error)
	for _, gg in ipairs({ ms, r, all, mr, sr, ct, n }) do truthy(not gg.crashed, gg.crashed) end
end)

---------------------------------------------------------------------------------------------------------------------
-- parcels (remote_parcels.lua): read only, the town building parcels on each side of a road piece

test("core.parcelsRequest: an edge or a rect, list, and what is refused; read only, in a game", function()
	local r = core.parcelsRequest({ edge = 10 })
	eq(r.edge, 10); eq(r.list, true, "an edge lists its parcels by default"); eq(r.rect, nil)
	eq(core.parcelsRequest({ edge = "12", list = false }).list, false)
	local q = core.parcelsRequest({ rect = "100,50,-20,-10" })
	eq(q.rect.x0, -20); eq(q.rect.x1, 100); eq(q.rect.y0, -10); eq(q.rect.y1, 50, "either corner order")
	eq(q.list, false, "a rect lists none by default")
	eq(core.parcelsRequest({ rect = { 0, 0, 1, 1 }, list = true }).list, true)
	local M = core.PARCELS_RECT_MAX
	truthy(core.parcelsRequest({ rect = string.format("0,0,%d,%d", M, M) }), "the limit itself")
	for _, bad in ipairs({ { {}, "give edge" }, { { edge = 1, rect = "0,0,1,1" }, "give edge" },
		{ { edge = -1 }, "edge must be" }, { { edge = 1.5 }, "edge must be" }, { { edge = "x" }, "edge must be" },
		{ { edge = 2 ^ 31 }, "edge must be" }, { { edge = 1, list = "yes" }, "list must be" },
		{ { rect = "0,0,1" }, "x0,y0,x1,y1" }, { { rect = "0,0,1,1,1" }, "at most 4" }, { { rect = "a,0,1,1" }, "finite" },
		{ { rect = string.format("0,0,%d,1", M + 1) }, "a side" }, { { rect = "0,0,1,1e6" }, "within" },
		{ { rect = 5 }, "commas" } }) do
		local ok, err = core.parcelsRequest(bad[1])
		eq(ok, nil, bad[2]); truthy(tostring(err):find(bad[2], 1, true), tostring(err) .. " / wanted " .. bad[2])
	end
	truthy(select(2, core.parcelsRequest(nil)):find("give edge"))
	eq(core.COMMANDS.parcels, true); eq(core.CHANGES_GAME.parcels, nil); eq(core.MENU_COMMANDS.parcels, nil)
end)

test("core.parcelSides and faceSummary: field spellings, empty data, area and centre from the faces", function()
	local l, r, f = core.parcelSides({ leftEntities = { 1, 2 }, rightParcels = { 3 } })
	eq(#l, 2); eq(#r, 1); eq(r[1], 3); eq(table.concat(f, ","), "leftEntities,rightParcels")
	l, r, f = core.parcelSides({ leftParcels = { 4 }, rightEntities = {} })
	eq(#l, 1); eq(#r, 0); eq(table.concat(f, ","), "leftParcels,rightEntities", "the other spellings")
	l, r, f = core.parcelSides(nil)
	eq(#l, 0); eq(#r, 0); eq(#f, 0)
	l, r, f = core.parcelSides({ other = { 1 } })
	eq(#l + #r, 0); eq(#f, 0, "nothing known: nothing counted")
	local s = core.faceSummary({ { points = { { x = 0, y = 0, z = 1 }, { x = 10, y = 0, z = 1 }, { x = 10, y = 20, z = 1 },
		{ x = 0, y = 20, z = 1 } } } })
	eq(s.area, 200); eq(s.x, 5); eq(s.y, 10); eq(s.z, 1); eq(s.faces, 1); eq(s.points, 4)
	local two = core.faceSummary({ { points = { { x = 0, y = 0 }, { x = 2, y = 0 }, { x = 2, y = 2 } } },
		{ points = { { x = 0, y = 0 }, { x = 0, y = 2 }, { x = 2, y = 2 } } } })
	eq(two.area, 4, "two triangles, either winding"); eq(two.faces, 2)
	eq(core.faceSummary({}), nil); eq(core.faceSummary(nil), nil)
	eq(core.faceSummary({ { points = { { x = 0 / 0, y = 1 } } } }), nil, "no finite point")
	truthy(core.inRect({ x = 0, y = 0 }, { x0 = 0, y0 = 0, x1 = 1, y1 = 1 }), "the edge of the rect is in it")
	eq(core.inRect(nil, { x0 = 0, y0 = 0, x1 = 1, y1 = 1 }), false)
end)

-- a town street 10 (0,0)-(100,0) with parcels 101, 102 on the left (102 built on) and 103 on the right; 11
-- (100,0)-(200,0) a piece of construction 900 with no parcels; 12 (200,0)-(300,0) a track; 13 far away (y 500)
-- with parcel 104 on the right
local function square(x, y, w, d) return { { { x, y, 0 }, { x + w, y, 0 }, { x + w, y + d, 0 }, { x, y + d, 0 } } } end
local function parcelGame(spec)
	spec = spec or {}
	spec.nodes = spec.nodes or { [1] = { 0, 0, 0 }, [2] = { 100, 0, 0 }, [3] = { 200, 0, 0 }, [4] = { 300, 0, 0 },
		[5] = { 0, 500, 0 }, [6] = { 100, 500, 0 } }
	spec.edges = spec.edges or { [10] = { node0 = 1, node1 = 2 }, [11] = { node0 = 2, node1 = 3, construction = 900 },
		[12] = { node0 = 3, node1 = 4, street = false }, [13] = { node0 = 5, node1 = 6 } }
	spec.parcels = spec.parcels or {
		[101] = { edge = 10, left = true, faces = square(0, 5, 10, 20), curveParam = 0.05, offset = 5 },
		[102] = { edge = 10, left = true, faces = square(10, 5, 10, 30), building = 7001 },
		[103] = { edge = 10, left = false, faces = square(0, -25, 10, 20) },
		[104] = { edge = 13, left = false, faces = square(0, 480, 10, 20) } }
	local g = newGame({ saves = SAVES })
	fake.installParcels(g, spec)
	frames(g, 1) -- booted: its hello names the command file
	return g
end
local function parcelRun(g, id, argsLua)
	send(g, id, "parcels", argsLua)
	frames(g, FIRST + 10)
	return final(g, id)
end

test("parcels --edge: a town street's left and right parcels, their buildings, centres and areas; nothing sent", function()
	local g = parcelGame()
	local guiBefore = core.json(fake.guiSave)
	local a = parcelRun(g, 2401, "{ edge = 10 }")
	eq(core.json(fake.guiSave), guiBefore, "no GUI save data written")
	truthy(a.ok, a.error); eq(a.source, "getSegment2ParcelData"); eq(a.parcelComponent, true); eq(a.buildingMap, true)
	truthy(a.note:find("not checked in a game"), a.note)
	eq(#a.edges, 1)
	local e = a.edges[1]
	eq(e.edge, 10); eq(e.street, true); eq(e.inConstruction, false); eq(e.construction, nil); eq(e.inParcelMap, true)
	eq(e.node0, 1); eq(e.node1, 2); eq(e.length, 100); eq(e.from.x, 0); eq(e.to.x, 100)
	eq(table.concat(e.fields, ","), "leftEntities,rightParcels")
	eq(e.left.count, 2); eq(e.right.count, 1); eq(e.left.built, 1); eq(e.right.built, 0)
	eq(e.left.area, 500); eq(e.right.area, 200); eq(e.sideMismatch, 0)
	eq(#e.left.parcels, 2); eq(e.left.parcels[1].id, 101); eq(e.left.parcels[1].building, nil)
	eq(e.left.parcels[1].x, 5); eq(e.left.parcels[1].y, 15); eq(e.left.parcels[1].area, 200)
	eq(e.left.parcels[1].left, true); eq(e.left.parcels[1].streetSegment, 10); eq(e.left.parcels[1].curveParam, 0.05)
	eq(e.left.parcels[2].building, 7001)
	eq(e.right.parcels[1].id, 103); eq(e.right.parcels[1].left, false); eq(e.right.parcels[1].y, -15)
	-- read only: no command went to the engine, and the map was asked once per command
	eq(#g.commands, 0, "nothing sent"); eq(g.parcelCalls.segmentMap, 1); eq(g.parcelCalls.parcelData, 0)
	local b = parcelRun(g, 2402, "{ edge = 10, list = false }")
	truthy(b.ok, b.error); eq(b.edges[1].left.count, 2); eq(b.edges[1].left.parcels, nil, "counts only")
	eq(#g.commands, 0); truthy(not g.crashed, g.crashed)
end)

test("parcels --edge: a construction's piece (0 and 0), a track, an unknown id, a node, bad arguments", function()
	local g = parcelGame()
	local a = parcelRun(g, 2411, "{ edge = 11 }")
	truthy(a.ok, a.error)
	local e = a.edges[1]
	eq(e.inConstruction, true); eq(e.construction, 900); eq(e.inParcelMap, false, "not in the map: no parcels")
	eq(e.left.count, 0); eq(e.right.count, 0); eq(#e.left.parcels, 0); eq(#e.fields, 0); eq(e.sideMismatch, nil)
	local t = parcelRun(g, 2412, "{ edge = 12 }")
	truthy(t.ok, t.error); eq(t.edges[1].street, false); eq(t.edges[1].left.count, 0)
	local x = parcelRun(g, 2413, "{ edge = 99999 }")
	eq(x.ok, false); truthy(x.error:find("no such entity"), x.error)
	local n = parcelRun(g, 2414, "{ edge = 1 }")
	eq(n.ok, false); truthy(n.error:find("no road piece"), n.error)
	local bad = parcelRun(g, 2415, '{ edge = "x" }')
	eq(bad.ok, false); truthy(bad.error:find("edge must be"), bad.error)
	local none = parcelRun(g, 2416, "{  }")
	eq(none.ok, false); truthy(none.error:find("give edge"), none.error)
	eq(#g.commands, 0); truthy(not g.crashed, g.crashed)
end)

test("parcels --rect: the streets with an end or the middle in it, per edge, with totals; tracks left out", function()
	local g = parcelGame()
	local a = parcelRun(g, 2421, '{ rect = "-10,-10,350,10" }')
	truthy(a.ok, a.error); eq(a.rect.x0, -10); eq(a.truncated, false)
	eq(#a.edges, 2); eq(a.edges[1].edge, 10); eq(a.edges[2].edge, 11, "sorted; the track 12 and the far 13 out")
	eq(a.edges[1].left.parcels, nil, "counts only unless list")
	eq(a.totals.edges, 2); eq(a.totals.streets, 2); eq(a.totals.withParcels, 1); eq(a.totals.left, 2)
	eq(a.totals.right, 1); eq(a.totals.built, 1); eq(a.totals.inConstruction, 1)
	eq(g.parcelCalls.segmentMap, 1, "one map for all the pieces")
	local b = parcelRun(g, 2422, '{ rect = "-10,490,50,510", list = true }')
	truthy(b.ok, b.error); eq(#b.edges, 1); eq(b.edges[1].edge, 13, "the middle (50, 500) is in it")
	eq(b.edges[1].right.parcels[1].id, 104)
	local c = parcelRun(g, 2423, '{ rect = "1000,1000,1100,1100" }')
	truthy(c.ok, c.error); eq(#c.edges, 0); eq(c.totals.edges, 0)
	local d = parcelRun(g, 2424, '{ rect = "0,0,5000,1" }')
	eq(d.ok, false); truthy(d.error:find("a side"), d.error)
	eq(#g.commands, 0); truthy(not g.crashed, g.crashed)
end)

test("parcels: the engine's userdata, other field names, no map (getParcelData, streets only), no PARCEL type", function()
	local u = parcelGame({ userdata = true })
	local a = parcelRun(u, 2431, "{ edge = 10 }")
	truthy(a.ok, a.error); eq(a.edges[1].left.count, 2); eq(a.edges[1].right.count, 1); eq(a.edges[1].left.area, 500)
	eq(a.edges[1].left.parcels[2].building, 7001)
	local f = parcelGame({ fields = { left = "leftParcels", right = "rightEntities" } })
	local b = parcelRun(f, 2432, "{ edge = 10 }")
	truthy(b.ok, b.error); eq(b.edges[1].left.count, 2); eq(table.concat(b.edges[1].fields, ","), "leftParcels,rightEntities")
	local nm = parcelGame({ noMap = true })
	local c = parcelRun(nm, 2433, "{ edge = 10 }")
	truthy(c.ok, c.error); eq(c.source, "getParcelData"); eq(c.edges[1].left.count, 2); eq(c.edges[1].inParcelMap, nil)
	local t = parcelRun(nm, 2434, "{ edge = 12 }") -- a track: getParcelData is not asked (an assertion in this fake)
	truthy(t.ok, t.error); truthy(t.edges[1].parcelError:find("not a street"), t.edges[1].parcelError)
	eq(nm.parcelCalls.parcelData, 1, "asked for the street only")
	local np = parcelGame({ noParcelType = true, noBuildingMap = true })
	local d = parcelRun(np, 2435, "{ edge = 10 }")
	truthy(d.ok, d.error); eq(d.parcelComponent, false); eq(d.buildingMap, false); eq(d.edges[1].left.count, 2)
	eq(d.edges[1].left.area, nil); eq(d.edges[1].left.built, nil); eq(d.edges[1].left.parcels[1].x, nil)
	eq(d.edges[1].left.parcels[1].id, 101)
	-- ParcelData with names this does not know: its keys come back, and the rect counts the piece as unread
	local odd = parcelGame({ fields = { left = "lp", right = "rp" } })
	local o = parcelRun(odd, 2437, "{ edge = 10 }")
	truthy(o.ok, o.error); eq(o.edges[1].left.count, 0); eq(o.edges[1].inParcelMap, true)
	eq(table.concat(o.edges[1].unreadParcelData, ","), "lp,rp")
	local or_ = parcelRun(odd, 2438, '{ rect = "-10,-10,350,10" }')
	truthy(or_.ok, or_.error); eq(or_.totals.unreadParcelData, 1)
	eq(a.edges[1].unreadParcelData, nil, "known names: nothing extra")
	local sw = parcelGame({ swapSide = { [103] = true } })
	local e = parcelRun(sw, 2436, "{ edge = 10 }")
	truthy(e.ok, e.error); eq(e.edges[1].left.count, 3); eq(e.edges[1].sideMismatch, 1, "the flag disagrees with the list")
	for _, gg in ipairs({ u, f, nm, np, sw, odd }) do eq(#gg.commands, 0); truthy(not gg.crashed, gg.crashed) end
end)

---------------------------------------------------------------------------------------------------------------------
-- company / company init (remote_company.lua)

local function companyGame(spec, opts)
	opts = opts or {}
	opts.townCapacities = opts.townCapacities or { [801] = { 120, 30, 10 }, [802] = { 80, 0, 5 } }
	local g = vehicleGame(opts)
	fake.installCompany(g, opts, spec)
	return g
end
local function companyRun(g, id, cmd, argsLua, n)
	send(g, id, cmd, argsLua)
	frames(g, n or FIRST + 20)
	return final(g, id)
end

test("core.worldPopulation / companyDiagnosis / companyInitRefusal: sums, states and refusals", function()
	eq(core.worldPopulation({ [1] = { 10, 5, 0 }, [2] = { 3 } }), 13)
	eq(core.worldPopulation({}), 0)
	eq(core.worldPopulation(nil), nil)
	local base = { mapEditor = false, mission = false, company = { running = true, initialized = false },
		growth = { running = true, initialized = false } }
	truthy(core.companyDiagnosis(base):find("initNewGameFromMap"))
	eq(core.companyInitRefusal(base), nil)
	base.company.initialized = true
	truthy(core.companyDiagnosis(base):find("no companyState yet"))
	base.growth.initialized = true
	truthy(core.companyDiagnosis(base):find("as after the base's new%-game page"))
	base.company.basePopulation = 0
	truthy(core.companyDiagnosis(base):find("basePopulation is 0"))
	truthy(core.companyInitRefusal({ mapEditor = true, company = {} }):find("map editor"))
	truthy(core.companyInitRefusal({ mission = true, company = {} }):find("mission"))
	truthy(core.companyInitRefusal({ company = { running = false, script = "x" } }):find("not running"))
	eq(core.companyRankButton(nil), "achievements"); eq(core.companyRankButton({ experience = 0 }), "achievements")
	eq(core.companyRankButton({ experience = 1 }), "rank")
	eq(core.COMMANDS.company, true); eq(core.COMMANDS.companyInit, true)
	eq(core.CHANGES_GAME.company, nil); eq(core.CHANGES_GAME.companyInit, true)
	eq(core.MENU_COMMANDS.company, nil); eq(core.MENU_COMMANDS.companyInit, nil)
end)

test("company: a game newgame started has no basePopulation; read only, nothing sent", function()
	local g = companyGame()
	local a = companyRun(g, 2501, "company")
	truthy(a.ok, a.error); eq(a.company.running, true); eq(a.company.initialized, false)
	eq(a.company.basePopulation, nil); eq(a.growth.initialized, false); eq(a.growth.player, nil)
	eq(a.worldPopulation, 200); eq(a.player, 99); eq(a.mapEditor, false)
	truthy(a.diagnosis:find("company init sends it"), a.diagnosis); eq(a.rankButton, "achievements")
	eq(#g.companyEvents, 0)
	-- a game with its state, as after the base's page: the player's level and multiplier come back
	local h = companyGame({ company = { basePopulation = 500, companyStates = { [99] = {} }, version = 3 },
		growth = { companyState = { [99] = { level = 2, potentialLevel = 3, experience = 900, ticketPriceMultiplier = 1.1 } } } })
	local b = companyRun(h, 2502, "company")
	truthy(b.ok, b.error); eq(b.company.basePopulation, 500); eq(b.company.companies, 1); eq(b.growth.player.level, 2)
	eq(b.growth.player.ticketPriceMultiplier, 1.1); truthy(b.diagnosis:find("have their state")); eq(b.rankButton, "rank")
	-- the scripts not running (nil entities): said, not an error
	local n = companyGame({ company = false, growth = false })
	local c = companyRun(n, 2503, "company")
	truthy(c.ok, c.error); eq(c.company.running, false); eq(c.growth.running, false); truthy(c.diagnosis:find("not running"))
	for _, gg in ipairs({ g, h, n }) do truthy(not gg.crashed, gg.crashed) end
end)

test("company init: sends initNewGameFromMap with src and id empty, answers once basePopulation is there", function()
	local g = companyGame({ growthPlayer = { level = 1, potentialLevel = 1, experience = 200 } })
	local a = companyRun(g, 2511, "companyInit")
	truthy(a.ok, a.error); eq(a.sent, true); eq(#g.companyEvents, 1)
	local e = g.companyEvents[1]
	eq(e.src, ""); eq(e.id, ""); eq(e.name, "initNewGameFromMap"); eq(type(e.param), "table")
	eq(a.before.company.initialized, false); eq(a.after.company.initialized, true)
	eq(a.after.company.basePopulation, 200, "the residential capacities, as computeWorldPopulation")
	eq(a.after.growth.player.level, 1); eq(a.growthNote, nil)
	truthy(a.note:find("test saves only")); truthy(a.note:find("speed to 1"))
	eq(a.after.speedup, 1, "company.script sets speed 1, as a base new game")
	-- again: the state is there, nothing sent
	local b = companyRun(g, 2512, "companyInit")
	truthy(b.ok, b.error); eq(b.sent, false); eq(b.alreadyInitialized, true); eq(#g.companyEvents, 1)
	truthy(not g.crashed, g.crashed)
end)

test("company init: dry run, map editor, mission, no script, refused, not delivered", function()
	local d = companyGame()
	local a = companyRun(d, 2521, "companyInit", "{ dryRun = true }")
	truthy(a.ok, a.error); eq(a.sent, false); eq(a.dryRun, true); eq(#d.companyEvents, 0)
	local ed = companyGame(nil, { mapEditor = true })
	local b = companyRun(ed, 2522, "companyInit")
	eq(b.ok, false); truthy(b.error:find("map editor"), b.error); eq(#ed.companyEvents, 0)
	local mi = companyGame({ mission = true })
	local c = companyRun(mi, 2523, "companyInit")
	eq(c.ok, false); truthy(c.error:find("mission"), c.error); eq(#mi.companyEvents, 0)
	local ns = companyGame({ company = false })
	local n = companyRun(ns, 2524, "companyInit")
	eq(n.ok, false); truthy(n.error:find("not running"), n.error); eq(#ns.companyEvents, 0)
	local rf = companyGame({ refuse = true })
	local r = companyRun(rf, 2525, "companyInit")
	eq(r.ok, false); eq(r.sent, true); truthy(r.error:find("refused"), r.error)
	-- sent, but the state never comes (the event reaches no script): a timeout that says so
	local nd = companyGame({ delivers = false })
	send(nd, 2526, "companyInit")
	frames(nd, FIRST + 20)
	eq(final(nd, 2526), nil, "still waiting")
	frames(nd, 400, 0.1)
	local t = final(nd, 2526)
	eq(t.ok, false); eq(t.sent, true); truthy(t.error:find("did not reach it"), t.error)
	eq(t.after.company.initialized, false)
	-- the timed-out event may still run: another send is refused unless forced
	local t2 = companyRun(nd, 2528, "companyInit")
	eq(t2.ok, false); truthy(t2.error:find("timed out"), t2.error); eq(#nd.companyEvents, 1)
	send(nd, 2529, "companyInit", "{ force = true }")
	frames(nd, FIRST + 20)
	eq(#nd.companyEvents, 2, "forced: sent again")
	local dr = companyRun(nd, 2530, "companyInit", "{ dryRun = true }", FIRST + 400)
	eq(#nd.companyEvents, 2)
	-- delivered, but company_growth has not run its update yet: ok, with the note
	local gp = companyGame()
	local p = companyRun(gp, 2527, "companyInit")
	truthy(p.ok, p.error); eq(p.after.growth.initialized, true); eq(p.after.growth.player, nil); truthy(p.growthNote)
	for _, gg in ipairs({ d, ed, mi, ns, rf, nd, gp }) do truthy(not gg.crashed, gg.crashed) end
end)

test("company init after a newgame: the new game has no state; init gives it its basePopulation", function()
	local g = companyGame({ company = { basePopulation = 500, companyStates = {} }, growth = { companyState = {} } })
	local a = companyRun(g, 2531, "company")
	eq(a.company.basePopulation, 500, "the save had its state")
	send(g, 2532, "newgame", '{ size = "tiny", unsafe = true }')
	frames(g, FIRST + 10)
	local b = companyRun(g, 2533, "company")
	truthy(b.ok, b.error); eq(b.company.initialized, false, "a game app.startGame started: none")
	local c = companyRun(g, 2534, "companyInit")
	truthy(c.ok, c.error); eq(c.sent, true); eq(c.after.company.basePopulation, 200)
	truthy(not g.crashed, g.crashed)
end)

---------------------------------------------------------------------------------------------------------------------
-- town connections / town connect (remote_town_connect.lua)

test("core.townConnectRequest / townIndexBase / townPairsResolved / townConnectPlan", function()
	local r = core.townConnectRequest({ build = true, entities = "801,802", pairs = "801:802", default = true })
	eq(r.build, true); eq(r.auto, false); eq(r.keep, true, "keep by default"); eq(#r.entities, 2); eq(r.pairs[1][2], 802)
	eq(core.townConnectRequest({ build = true, keep = false }).keep, false)
	eq(core.townConnectRequest({ auto = true }).auto, true)
	for _, bad in ipairs({ {}, { auto = true, build = true }, { auto = true, pairs = "1:2" }, { auto = true, keep = true },
		{ build = true, entities = "" }, { build = true, entities = "1,1" }, { build = true, entities = "x" },
		{ build = true, pairs = "1:1" }, { build = true, pairs = "1-2" }, { build = true, pairs = "" },
		{ build = true, indexBase = 2 }, { build = true, keep = "yes" }, { auto = 1 } }) do
		local ok, err = core.townConnectRequest(bad)
		eq(ok, nil); truthy(type(err) == "string" and err ~= "")
	end
	eq(core.townConnectionsRequest({}).entity, nil); eq(core.townConnectionsRequest({ entity = 801 }).entity, 801)
	eq(core.townConnectionsRequest({ entity = -1 }), nil)
	eq(core.townIndexBase({ { { 0, 1 } } }, 3), 0); eq(core.townIndexBase({ { { 2, 3 } } }, 3), 1)
	eq(core.townIndexBase({ { { 1, 2 } } }, 3), nil); eq(core.townIndexBase({ {} }, 2), nil)
	eq(core.townIndexBase({ { { 0, 2 } } }, 2), nil, "0 and n both: not told")
	local towns = { { entity = 801, name = "A" }, { entity = 802, name = "B" }, { entity = 803, name = "C" } }
	local res = core.townPairsResolved({ { 0, 2 }, { 1, 9 } }, towns, 0)
	eq(res[1].from, 801); eq(res[1].to, 803); eq(res[1].toName, "C"); eq(res[2].to, nil, "out of range")
	eq(core.townPairsResolved({ { 1, 2 } }, towns, nil)[1].from, nil)
	-- the plan: the map's pairs, the defaults and the given ones, re-indexed into the chosen towns
	local p = core.townConnectPlan({ entities = { 801, 803 }, pairs = { { 803, 801 } } }, towns, { { 0, 1 } }, nil, 0)
	eq(#p.townEntities, 2); eq(p.townEntities[2], 803); eq(#p.connections, 1)
	eq(p.connections[1][1], 1); eq(p.connections[1][2], 0); eq(p.dropped, 1, "801:802 has a town not chosen")
	local q = core.townConnectPlan({ default = true }, towns, { { 1, 2 } }, { { 2, 1 }, { 2, 3 } }, 1)
	eq(#q.connections, 2, "a pair twice counts once"); eq(q.connections[1][1], 1); eq(q.connections[2][2], 3)
	eq(#core.townConnectPlan({}, towns, {}, nil, nil).connections, 0, "nothing to number: no base needed")
	for _, bad in ipairs({ { { entities = { 999 } }, {}, 0 }, { { pairs = { { 801, 999 } } }, {}, 0 },
		{ { entities = { 801 }, pairs = { { 801, 802 } } }, {}, 0 }, { {}, { { 1, 2 } }, nil },
		{ { pairs = { { 801, 802 } } }, {}, nil } }) do
		local ok, err = core.townConnectPlan(bad[1], towns, bad[2], nil, bad[3])
		eq(ok, nil); truthy(type(err) == "string", tostring(err))
	end
	eq(core.COMMANDS.townConnections, true); eq(core.COMMANDS.townConnect, true)
	eq(core.CHANGES_GAME.townConnections, nil); eq(core.CHANGES_GAME.townConnect, true)
	eq(core.MENU_COMMANDS.townConnect, nil)
end)

-- three towns 801 Alby, 802 Bram, 803 Cove (the map's order), Alby and Bram connected; industries 51 (by Alby) and
-- 52 (nobody's)
local function townConnectGame(spec, opts)
	opts = opts or {}
	opts.entities = opts.entities or { TOWN = { 801, 802, 803 } }
	opts.names = opts.names or { [801] = "Alby", [802] = "Bram", [803] = "Cove" }
	opts.industries = opts.industries or { [51] = { name = "Clay pit", construction = 5100 },
		[52] = { name = "Quarry", construction = 5200 } }
	local g = vehicleGame(opts)
	spec = spec or {}
	spec.towns = spec.towns or { { entity = 801, name = "Alby", x = 0, y = 0 }, { entity = 802, name = "Bram", x = 900, y = 0 },
		{ entity = 803, name = "Cove", x = 0, y = 900 } }
	if spec.connections == nil then spec.connections = { { 0, 1 } } end
	spec.closest = spec.closest or { [5100] = 801 }
	fake.installTownConnect(g, opts, spec)
	return g
end

test("town connections: towns with their connected towns and industries; one town; not a town", function()
	local g = townConnectGame()
	local a = companyRun(g, 2601, "townConnections")
	truthy(a.ok, a.error); eq(a.indexBase, 0); eq(a.indexBaseFrom, "map"); eq(#a.towns, 3)
	local alby = a.towns[1]
	eq(alby.id, 801); eq(alby.mapIndex, 1); eq(alby.connectedTowns[1].id, 802); eq(alby.industries[1].id, 51)
	eq(#a.towns[3].connectedTowns, 0); eq(#a.towns[3].industries, 0)
	eq(#a.industriesWithoutTown, 1); eq(a.industriesWithoutTown[1].id, 52)
	eq(a.connections[1].from, 801); eq(a.connections[1].to, 802)
	local b = companyRun(g, 2602, "townConnections", "{ entity = 802 }")
	truthy(b.ok, b.error); eq(#b.towns, 1); eq(b.towns[1].connectedTowns[1].name, "Alby"); eq(b.industriesWithoutTown, nil)
	local x = companyRun(g, 2603, "townConnections", "{ entity = 51 }")
	eq(x.ok, false); truthy(x.error:find("no town"), x.error)
	eq(#g.townConnectCmds, 0)
	-- no map copy (nil): the towns still listed, without connections
	local m = townConnectGame({ missing = { map = true } })
	local c = companyRun(m, 2604, "townConnections")
	truthy(c.ok, c.error); truthy(c.mapError); eq(#c.towns, 3); eq(#c.connections, 0); eq(c.functions.map, false)
	-- an empty map: no towns, no industries' town
	local e = townConnectGame({ towns = {}, connections = {} }, { entities = { TOWN = {} }, industries = {} })
	local d = companyRun(e, 2605, "townConnections")
	truthy(d.ok, d.error); eq(#d.towns, 0); eq(#d.connections, 0); eq(#d.industriesWithoutTown, 0)
	for _, gg in ipairs({ g, m, e }) do truthy(not gg.crashed, gg.crashed) end
end)

test("town connect auto: the map's towns (or the given ones) sent; connections before and after", function()
	local g = townConnectGame({ detect = { { 0, 1 }, { 1, 2 } } })
	local a = companyRun(g, 2611, "townConnect", "{ auto = true }")
	truthy(a.ok, a.error); eq(a.mode, "auto"); eq(a.sent, true); eq(#g.townConnectCmds, 1)
	local c = g.townConnectCmds[1]
	eq(c.kind, "townAutoDetect"); eq(#c.townEntities, 3); eq(c.townEntities[3], 803)
	eq(#a.before.connections, 1); eq(#a.after.connections, 2); eq(a.after.towns[3].connectedTowns[1].id, 802)
	local b = companyRun(g, 2612, "townConnect", '{ auto = true, entities = "803,801" }')
	truthy(b.ok, b.error); eq(g.townConnectCmds[2].townEntities[1], 803)
	local x = companyRun(g, 2613, "townConnect", '{ auto = true, entities = "51" }')
	eq(x.ok, false); truthy(x.error:find("no town of this map"), x.error); eq(#g.townConnectCmds, 2)
	truthy(not g.crashed, g.crashed)
end)

test("town connect build: the map's pairs, the defaults and given ones, re-indexed; keep; dry run", function()
	local g = townConnectGame({ defaults = { { 1, 2 } } })
	local d = companyRun(g, 2621, "townConnect", '{ build = true, default = true, pairs = "803:801", dryRun = true }')
	truthy(d.ok, d.error); eq(d.sent, false); eq(#g.townConnectCmds, 0); eq(#d.connectionsSent, 3); eq(d.keep, true)
	eq(d.defaults[1].from, 802)
	local a = companyRun(g, 2622, "townConnect", '{ build = true, default = true, pairs = "803:801" }')
	truthy(a.ok, a.error); eq(a.sent, true)
	local c = g.townConnectCmds[1]
	eq(c.kind, "townConnectBuild"); eq(c.keep, true); eq(#c.townEntities, 3); eq(#c.connections, 3)
	eq(c.connections[3][1], 2); eq(c.connections[3][2], 0)
	eq(#a.after.connections, 4, "kept the one there and added three (the fake adds, it does not merge)")
	-- some towns only, keep false
	local b = companyRun(g, 2623, "townConnect", '{ build = true, entities = "801,803", pairs = "801:803", keep = false }')
	truthy(b.ok, b.error); local c2 = g.townConnectCmds[2]
	-- 801:803 given and 803:801 from the map: one pair, in the new list's numbers
	eq(#c2.townEntities, 2); eq(c2.keep, false); eq(#c2.connections, 1)
	eq(c2.connections[1][1] + c2.connections[1][2], 1)
	truthy(b.dropped and b.dropped > 0, "the map's pairs with Bram left out")
	-- no pairs at all: still sent (it connects the industries), with no connections
	local n = townConnectGame({ connections = {} })
	local e = companyRun(n, 2624, "townConnect", "{ build = true }")
	truthy(e.ok, e.error); eq(#n.townConnectCmds[1].connections, 0)
	for _, gg in ipairs({ g, n }) do truthy(not gg.crashed, gg.crashed) end
end)

test("town connect build: the numbering 1-based from the map, unknown without indexBase, given", function()
	local one = townConnectGame({ base = 1, connections = { { 2, 3 } } })
	local a = companyRun(one, 2631, "townConnect", '{ build = true, pairs = "801:802" }')
	truthy(a.ok, a.error); eq(a.indexBase, 1); eq(one.townConnectCmds[1].connections[1][1], 2)
	eq(one.townConnectCmds[1].connections[2][1], 1)
	local unk = townConnectGame({ connections = { { 1, 2 } } })
	local b = companyRun(unk, 2632, "townConnect", "{ build = true }")
	eq(b.ok, false); truthy(b.error:find("indexBase"), b.error); eq(#unk.townConnectCmds, 0)
	local c = companyRun(unk, 2633, "townConnect", "{ build = true, indexBase = 0 }")
	truthy(c.ok, c.error); eq(unk.townConnectCmds[1].connections[1][2], 2)
	for _, gg in ipairs({ one, unk }) do truthy(not gg.crashed, gg.crashed) end
end)

test("town connect: missing functions, refused, no callback, busy, bad pairs", function()
	local m = townConnectGame({ missing = { build = true } })
	local dm = companyRun(m, 2641, "townConnect", "{ build = true, dryRun = true }")
	truthy(dm.ok, "a dry run still answers"); eq(dm.before.functions.build, false)
	local a = companyRun(m, 2642, "townConnect", "{ build = true }")
	eq(a.ok, false); truthy(a.error:find("not there"), a.error)
	local nm = townConnectGame({ missing = { map = true } })
	local b = companyRun(nm, 2643, "townConnect", "{ auto = true }")
	eq(b.ok, false); truthy(b.error:find("could not be copied"), b.error)
	local nd = townConnectGame({ missing = { defaults = true } })
	local d = companyRun(nd, 2648, "townConnect", "{ build = true, default = true }")
	eq(d.ok, false); truthy(d.error:find("getDefaultTownConnections"), d.error)
	local rf = townConnectGame({ refuse = true })
	local r = companyRun(rf, 2644, "townConnect", "{ auto = true }")
	eq(r.ok, false); truthy(r.error:find("refused"), r.error)
	local nc = townConnectGame({ noCallback = true })
	send(nc, 2645, "townConnect", "{ auto = true }")
	frames(nc, FIRST + 10)
	send(nc, 2646, "townConnect", "{ auto = true }")
	frames(nc, FIRST)
	local busy = final(nc, 2646)
	eq(busy.ok, false); truthy(busy.error:find("still running"), busy.error)
	frames(nc, 1300, 0.1)
	local t = final(nc, 2645)
	eq(t.ok, false); truthy(t.error:find("no callback"), t.error)
	-- (a new fake game replaces the global api: a fresh one)
	local bp = townConnectGame()
	local x = companyRun(bp, 2647, "townConnect", '{ build = true, pairs = "801:999" }')
	eq(x.ok, false); truthy(x.error:find("not two towns"), x.error)
	eq(#bp.townConnectCmds, 0)
	for _, gg in ipairs({ m, nm, nd, rf, nc, bp }) do truthy(not gg.crashed, gg.crashed) end
end)

print(string.format("\n%d passed, %d failed", passes, failures))
RP_TEST_FAILURES = failures -- the outer run (top of this file) cleans up and exits with it
