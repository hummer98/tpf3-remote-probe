-- Pure logic of the remote probe: no game API here, so tests/run.lua can drive all of it with luajit.
local M = {}

M.VERSION = 7 -- 2: speed and run follow the game's estimate of what it can sustain (args.force overrides)
-- 3: quit, event, tool; runs in the main menu too when the game is launched with --script (startup.lua)
-- 4: buy, duplicate, replace, sell, depots, vehicles
-- 5: money; vehicle commands via gui run in the speed control's react state (guiUpdate cannot require the base
--    module: react.RegisterRecipe fails there, 2026-11-16 12:24 JST)
-- 6: stations, lines, line (create, update, delete)
-- 7: connect (a track or road between two ends, planned and built through the Track Connector mod)
M.MOD_ID = "hummer_remote_probe"
M.PREFIX = "remote_probe__"
M.LOG = "[remote_probe] "

-- cmd -> true; anything else is answered with an error instead of being guessed at
M.COMMANDS = { status = true, speed = true, run = true, saves = true, info = true, load = true, save = true, poll = true,
	newgame = true, screenshot = true, entities = true, window = true, quit = true, event = true, tool = true,
	buy = true, duplicate = true, replace = true, sell = true, depots = true, vehicles = true, money = true,
	stations = true, lines = true, line = true, connect = true, camera = true, buildTool = true }
-- poll only changes how often the mod reads files, not the game: no "who used the game" entry for it
M.CHANGES_GAME = { speed = true, run = true, load = true, save = true, newgame = true, window = true, quit = true,
	event = true, tool = true, buy = true, duplicate = true, replace = true, sell = true, money = true,
	line = true, connect = true, camera = true, buildTool = true } -- camera, as window: what the player sees
-- what works in the main menu (startup.lua): no world and no GUI of a game there, so nothing that reads or
-- shows one. newgame is safe only there (inside a save app.startGame hits the base's StartGame assertion).
M.MENU_COMMANDS = { status = true, saves = true, info = true, load = true, newgame = true, poll = true, quit = true }

---------------------------------------------------------------------------------------------------------------------
-- mod settings (mod.json params): each arrives as a 1-based index into these lists

M.OPTION_VALUES = {
	pollIdle = { 1, 2, 5, 10 }, -- seconds between checks of the command file when nobody asked for a while
	pollActive = { 0.1, 0.25, 0.5, 1 }, -- the same for ACTIVE_SEC after a command and during a run
	logLevel = { 1, 2, 3 }, -- 1 minimal (ready, loads, errors), 2 each command, 3 also progress and receipts
	speedLabel = { true, false }, -- the label beside the speed buttons (gui/remote_speed.script.lua)
}
M.OPTION_DEFAULT = { pollIdle = 2, pollActive = 2, logLevel = 2, speedLabel = 1 }

function M.options(raw)
	local out = {}
	for k, values in pairs(M.OPTION_VALUES) do
		local idx = tonumber(M.field(raw, k))
		-- by index, not "values[idx] or default": a false value (speedLabel off) is a real choice
		if idx == nil or values[idx] == nil then idx = M.OPTION_DEFAULT[k] end
		out[k] = values[idx]
	end
	return out
end

-- poll command: { idle = s, active = s }, either may be missing. The tool gives up on a pickup after 30 s, so the
-- idle interval stays well under that.
M.POLL_LIMITS = { idle = { 0.1, 20 }, active = { 0.05, 5 } }

function M.pollArgs(args)
	local out = {}
	for k, lim in pairs(M.POLL_LIMITS) do
		if args[k] ~= nil then
			local n = tonumber(args[k])
			if n == nil or n ~= n or n < lim[1] or n > lim[2] then
				return nil, string.format("%s must be between %g and %g seconds", k, lim[1], lim[2])
			end
			out[k] = n
		end
	end
	if next(out) == nil then return nil, "give idle and/or active seconds" end
	return out
end

-- who sent a command (tf3ctl --owner): only for showing who is using the game, never for refusing
function M.owner(args)
	local o = args and args._owner
	if type(o) ~= "string" or o == "" then return nil end
	return o:sub(1, 64)
end

---------------------------------------------------------------------------------------------------------------------
-- engine values: lists come back as userdata vectors or Lua tables depending on the call, so read both

function M.size(v)
	if v == nil then return 0 end
	local ok, n = pcall(function() return #v end)
	if ok and type(n) == "number" then return n end
	return 0
end

-- 1-based like the base GUI's ipairs over engine vectors
function M.at(v, i)
	local ok, x = pcall(function() return v[i] end)
	if ok then return x end
	return nil
end

function M.field(t, key)
	local ok, v = pcall(function() return t[key] end)
	if ok then return v end
	return nil
end

function M.toList(v)
	local out = {}
	for i = 1, M.size(v) do out[#out + 1] = M.at(v, i) end
	return out
end

-- a nested key/value structure (modParams: Lua tables or engine maps) as plain tables of strings and numbers
function M.plain(v, depth)
	depth = depth or 0
	local t = type(v)
	if t == "number" or t == "string" or t == "boolean" or t == "nil" then return v end
	if depth > 4 then return tostring(v) end
	local out = {}
	local ok = pcall(function()
		for k, x in pairs(v) do out[k] = M.plain(x, depth + 1) end
	end)
	if not ok or (next(out) == nil and t ~= "table") then return tostring(v) end
	return out
end

---------------------------------------------------------------------------------------------------------------------
-- JSON: the answers carry one JSON string, so the tool needs no reader for the game's own Lua table format

-- An empty Lua table has no shape: the encoder writes it as {} unless it was marked a list here. Answers mark
-- their lists, so "no lines" reads as [] and a tool can always iterate it (2026-11-17: lines, vehicleIds and
-- vehicleCargo came back as {} when empty). Weak keys: marking keeps nothing alive.
local arrays = setmetatable({}, { __mode = "k" })

function M.array(t)
	if type(t) == "table" then arrays[t] = true end
	return t
end

local function isArray(t)
	local n = 0
	for k in pairs(t) do
		if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
		n = n + 1
	end
	for i = 1, n do if t[i] == nil then return false end end
	return true, n
end

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function str(s)
	return '"' .. s:gsub('[%c"\\]', function(c) return ESC[c] or string.format("\\u%04x", c:byte()) end) .. '"'
end

local function enc(v, depth, seen)
	local t = type(v)
	if t == "nil" then return "null" end
	if t == "boolean" then return v and "true" or "false" end
	if t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then return "null" end
		if v % 1 == 0 and v > -1e15 and v < 1e15 then return string.format("%d", v) end
		return string.format("%.14g", v)
	end
	if t == "string" then return str(v) end
	if t ~= "table" then return str(tostring(v)) end
	if depth > 20 or seen[v] then return '"<cycle>"' end
	seen[v] = true
	local out
	local arr, n = isArray(v)
	if arr and n == 0 and arrays[v] then
		out = "[]"
	elseif arr and n > 0 then
		local parts = {}
		for i = 1, n do parts[i] = enc(v[i], depth + 1, seen) end
		out = "[" .. table.concat(parts, ",") .. "]"
	else
		local keys = {}
		for k in pairs(v) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		local parts = {}
		for _, k in ipairs(keys) do parts[#parts + 1] = str(tostring(k)) .. ":" .. enc(v[k], depth + 1, seen) end
		out = "{" .. table.concat(parts, ",") .. "}"
	end
	seen[v] = nil
	return out
end

function M.json(v) return enc(v, 0, {}) end

---------------------------------------------------------------------------------------------------------------------
-- commands

-- raw: the table loadUserdata returned. Returns the command, or nil when there is nothing new to do.
function M.readCommand(raw, lastId)
	if raw == nil then return nil end
	local id = tonumber(M.field(raw, "id"))
	if id == nil or id == 0 or id == lastId then return nil end
	local cmd = M.field(raw, "cmd")
	local args = M.field(raw, "args")
	if type(args) ~= "table" then args = {} end
	if not M.COMMANDS[cmd] then
		return { id = id, cmd = tostring(cmd), args = args, error = "unknown command: " .. tostring(cmd) }
	end
	return { id = id, cmd = cmd, args = args }
end

-- speedup for GameSetSpeed: a whole number >= 0. Nothing caps it here on purpose: finding the real limit is the
-- point of the probe, and the base UI's cap (getEstimatedMaximumGameSpeed) is only a GUI choice.
function M.speedArg(v)
	local n = tonumber(v)
	if n == nil or n ~= n or n < 0 or n > 100000 then return nil end
	return math.floor(n + 0.5)
end

-- Above the game's own estimate (getEstimatedMaximumGameSpeed) the simulation cannot keep up: frames grow long
-- and sound breaks up (x8 on a save estimated at x5-6, 2026-11-15). The base UI caps at the estimate; so does the
-- probe unless forced. Without an estimate yet (0), the base buttons' 4x.
M.BUTTON_MAX_SPEED = 4

function M.capSpeed(requested, estimatedMax, force)
	if force or requested <= 1 then return requested end
	local cap = (estimatedMax and estimatedMax > 0) and estimatedMax or M.BUTTON_MAX_SPEED
	return math.min(requested, cap)
end

---------------------------------------------------------------------------------------------------------------------
-- dates and run targets

local MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

function M.dateKey(d)
	if type(d) ~= "table" or d.year == nil then return nil end
	return (tonumber(d.year) or 0) * 10000 + (tonumber(d.month) or 1) * 100 + (tonumber(d.day) or 1)
end

-- "1934-09-01" / "1934-09" / "1934" -> { year, month, day }
function M.parseDate(s)
	if type(s) == "table" then return M.dateKey(s) and s or nil end
	if type(s) ~= "string" then return nil end
	local y, m, d = s:match("^(%d%d%d%d)%-?(%d?%d?)%-?(%d?%d?)$")
	if not y then return nil end
	local out = { year = tonumber(y), month = tonumber(m) or 1, day = tonumber(d) or 1 }
	if out.month < 1 or out.month > 12 or out.day < 1 then return nil end
	if out.day > (out.month == 2 and 29 or MONTH_DAYS[out.month]) then return nil end
	return out
end

function M.addMonths(d, n)
	local idx = d.year * 12 + (d.month - 1) + n
	local y, m = math.floor(idx / 12), idx % 12 + 1
	return { year = y, month = m, day = math.min(d.day, MONTH_DAYS[m]) }
end

-- calendar days without leap years; off by a day at worst, which a months-long check does not notice
function M.addDays(d, n)
	local y, m, day = d.year, d.month, d.day + n
	while day > MONTH_DAYS[m] do
		day = day - MONTH_DAYS[m]
		m = m + 1
		if m > 12 then m, y = 1, y + 1 end
	end
	return { year = y, month = m, day = day }
end

-- args: { days = n } or { months = n } or { untilDate = "YYYY-MM-DD" }; now.date: the current calendar date.
-- Every target is a calendar date: game ticks per day follow the calendar speed (millisPerDay, which is 0 while
-- paused), so a tick count would drift whenever a mod or the player changes it.
function M.runTarget(args, now)
	if not now.date or not M.dateKey(now.date) then return nil, "current date unknown" end
	local d
	if args.untilDate ~= nil then
		d = M.parseDate(args.untilDate)
		if not d then return nil, "untilDate must be YYYY-MM-DD" end
	elseif args.months ~= nil then
		local n = tonumber(args.months)
		if not n or n < 1 or n % 1 ~= 0 then return nil, "months must be a whole number >= 1" end
		d = M.addMonths(now.date, n)
	elseif args.days ~= nil then
		local n = tonumber(args.days)
		if not n or n < 1 or n % 1 ~= 0 then return nil, "days must be a whole number >= 1" end
		d = M.addDays(now.date, n)
	else
		return nil, "give days, months or untilDate"
	end
	if M.dateKey(d) <= M.dateKey(now.date) then return nil, "the target date is not after the current date" end
	return { date = d, key = M.dateKey(d) }
end

function M.reached(target, now)
	return now.date ~= nil and M.dateKey(now.date) ~= nil and M.dateKey(now.date) >= target.key
end

---------------------------------------------------------------------------------------------------------------------
-- measured speed: game milliseconds per real second, sampled about once a second

function M.newMeter(gameTime, appTime)
	return { t0 = appTime, g0 = gameTime, lastT = appTime, lastG = gameTime, samples = {}, est = {} }
end

-- returns the new sample (x real time) when a second has passed
function M.meterStep(m, gameTime, appTime, estimatedMax)
	if appTime - m.lastT < 1 then return nil end
	local rate = (gameTime - m.lastG) / 1000 / (appTime - m.lastT)
	m.samples[#m.samples + 1] = rate
	if estimatedMax ~= nil then m.est[#m.est + 1] = estimatedMax end
	m.lastT, m.lastG = appTime, gameTime
	return rate
end

local function stats(list)
	if #list == 0 then return nil end
	local lo, hi, sum = math.huge, -math.huge, 0
	for _, v in ipairs(list) do
		lo, hi, sum = math.min(lo, v), math.max(hi, v), sum + v
	end
	return { min = lo, max = hi, mean = sum / #list, n = #list }
end

function M.meterSummary(m, gameTime, appTime)
	local real = appTime - m.t0
	return {
		realSec = real,
		gameSec = (gameTime - m.g0) / 1000,
		overall = real > 0 and (gameTime - m.g0) / 1000 / real or nil,
		perSecond = stats(m.samples),
		estimatedMax = stats(m.est),
	}
end

---------------------------------------------------------------------------------------------------------------------
-- the label next to the speed buttons

-- The base buttons are 0/1/2/4 and show nothing for any other speed; a remote run may also be going at 4x.
-- Shared between the guiUpdate script (writes run) and the speed control (reads it) when both run in the same
-- Lua state; when they do not, the label simply has no run part.
-- Kept in a global rather than this module: a load may run the module again, and the label must still see the
-- run the guiUpdate script publishes.
-- In TF3's GUI Lua _G is not a plain table (rawget(_G, ...) raised at load, 2026-11-15, and the failed
-- module load then repeated every frame), so every step is guarded and falls back to this module's own table.
local SHARED_KEY = "__hummer_remote_probe_shared"
local function sharedTable()
	local ok, t = pcall(function()
		local g = _G
		if type(g) ~= "table" then return nil end
		local s = rawget(g, SHARED_KEY)
		if type(s) ~= "table" then
			s = {}
			rawset(g, SHARED_KEY, s)
		end
		return s
	end)
	if ok and type(t) == "table" then return t end
	return nil
end
M.shared = sharedTable() or {}

local BUTTON_SPEEDS = { [0] = true, [1] = true, [2] = true, [4] = true }

local function fmt(x)
	if x == nil then return "?" end
	if x >= 10 then return string.format("%.0f", x) end
	return string.format("%.1f", x)
end

-- The game's translation of key (strings.json), or fallback when there is none: translate is the game's _
-- (nil outside a GUI state, or in tests), and an unknown key comes back as the key itself.
function M.label(translate, key, fallback)
	if type(translate) ~= "function" then return fallback end
	local ok, v = pcall(translate, key)
	if not ok or type(v) ~= "string" or v == "" or v == key then return fallback end
	return v
end

-- a translated pattern with one %s; a translation that lost or doubled the %s falls back to the English one
local function fill(translate, key, fallback, value)
	local ok, text = pcall(string.format, M.label(translate, key, fallback), value)
	if ok and text:find(value, 1, true) then return text end
	return string.format(fallback, value)
end
M.fill = fill

-- speedup: requested; measured: game seconds per real second over the last second(s), nil when unknown;
-- run: { target = {year, month, day}, owner } or nil; translate: the game's _ (English without it).
-- Returns label, tooltip ("" label = show nothing).
function M.speedLabel(speedup, measured, run, estimatedMax, translate)
	if speedup == nil then return "", "" end
	local unusual = not BUTTON_SPEEDS[speedup]
	if not unusual and not run then return "", "" end
	-- short: the speed row is widened by a fixed amount (gui/remote_speed.css.lua)
	local parts = {}
	if unusual or (run and speedup > 0) then
		parts[#parts + 1] = "×" .. tostring(speedup)
		if speedup > 0 and measured then
			parts[#parts + 1] = fill(translate, "hummer_remote_probe_label_measured", "real ×%s", fmt(measured))
		end
	end
	if run and run.target then
		parts[#parts + 1] = string.format("→%d-%02d-%02d", run.target.year, run.target.month, run.target.day)
	end
	local tip = { fill(translate, "hummer_remote_probe_tip_requested", "Requested ×%s", tostring(speedup)) }
	if measured then
		tip[#tip + 1] = fill(translate, "hummer_remote_probe_tip_measured", "Measured ×%s (last few seconds)", fmt(measured))
	end
	if estimatedMax and estimatedMax > 0 then
		tip[#tip + 1] = fill(translate, "hummer_remote_probe_tip_estimate", "Game's estimated maximum ×%s", tostring(estimatedMax))
	end
	if run then
		tip[#tip + 1] = M.label(translate, "hummer_remote_probe_tip_run", "remote probe run in progress")
			.. (run.owner and (" (" .. run.owner .. ")") or "")
	end
	return table.concat(parts, " "), table.concat(tip, "\n")
end

-- measured speed for the label: a sliding estimate updated about once a second
function M.newRate() return { t = nil, g = nil, rate = nil } end

function M.rateStep(r, gameTime, appTime)
	if r.t == nil or appTime < r.t or gameTime < r.g then
		r.t, r.g = appTime, gameTime -- first sample, or a load reset the clocks
		return r.rate
	end
	local dt = appTime - r.t
	if dt >= 1 then
		local x = (gameTime - r.g) / 1000 / dt
		r.rate = r.rate and (r.rate * 0.5 + x * 0.5) or x
		r.t, r.g = appTime, gameTime
	end
	return r.rate
end

---------------------------------------------------------------------------------------------------------------------
-- loading with other mods or mod settings

-- current: mod id strings of the save. spec: { set = {...} } replaces the list, { add = {...}, remove = {...} }
-- edits it. The probe itself always stays in: without it nobody would answer after the load.
function M.mergeMods(current, spec, selfId)
	spec = spec or {}
	local out, seen = {}, {}
	local function push(id)
		if type(id) == "string" and id ~= "" and not seen[id] then
			seen[id] = true
			out[#out + 1] = id
		end
	end
	local removed = {}
	for _, id in ipairs(spec.remove or {}) do removed[id] = true end
	removed[selfId] = nil
	for _, id in ipairs(spec.set or current or {}) do
		if not removed[id] then push(id) end
	end
	for _, id in ipairs(spec.add or {}) do push(id) end
	push(selfId)
	return out
end

-- params set for mods that will not be active: a --param without --add would be dropped without a word
-- (reported 2026-11-15). Returns the mod ids, sorted; "" (the base game) always counts as active.
function M.paramsWithoutMods(params, mods)
	local active, out = { [""] = true }, {}
	for _, m in ipairs(mods or {}) do active[m] = true end
	for m in pairs(params or {}) do if not active[m] then out[#out + 1] = m end end
	table.sort(out)
	return out
end

function M.paramsWithoutModsError(params, mods)
	local missing = M.paramsWithoutMods(params, mods)
	if #missing == 0 then return nil end
	return "params for mods not in the mod list: " .. table.concat(missing, ", ")
		.. " (add them with --add, or they would be ignored)"
end

-- current: { [modId] = { [key] = index } } (index 1-based, "" = base game). overrides: same shape. Returns a copy:
-- the save's own table is left alone. Values are 1-based indices into the param's values list, as in mod.json.
function M.mergeParams(current, overrides)
	if current ~= nil and type(current) ~= "table" then
		-- an engine map plain() could not walk: merging would drop the base game's settings without a word
		return nil, "the save's modParams are not readable here (" .. tostring(current) .. "); load without --param"
	end
	local out = {}
	for mod, kv in pairs(current or {}) do
		local copy = {}
		if type(kv) == "table" then for k, v in pairs(kv) do copy[k] = v end end
		out[mod] = copy
	end
	for mod, kv in pairs(overrides or {}) do
		out[mod] = out[mod] or {}
		for k, v in pairs(kv) do
			local n = tonumber(v)
			if n == nil or n < 1 or n % 1 ~= 0 then
				return nil, string.format("param %s.%s must be a 1-based index, got %s", mod, k, tostring(v))
			end
			out[mod][k] = n
		end
	end
	return out
end

---------------------------------------------------------------------------------------------------------------------
-- a new game (app.startGame with api.type.StartGameParams)

-- square maps in tiles, as the base new-game page makes them for format 1 (new_game_or_map_settings_page.tl)
M.MAP_SIZES = { tiny = { 16, 16 }, small = { 32, 32 }, medium = { 44, 44 }, large = { 56, 56 }, veryLarge = { 64, 64 } }

function M.parseSize(v)
	if v == nil then v = "small" end
	if M.MAP_SIZES[v] then return M.MAP_SIZES[v][1], M.MAP_SIZES[v][2] end
	local x, y = tostring(v):match("^(%d+)[xX](%d+)$")
	x, y = tonumber(x), tonumber(y)
	if x and y and x >= 4 and y >= 4 and x <= 200 and y <= 200 then return x, y end
	return nil, "size must be tiny, small, medium, large, veryLarge or WxH tiles (4-200)"
end

-- StartGameParams.modParams is {string: {string: integer}}; the running game's params also hold other values
-- (the base game's "isMapEditor" = false)
function M.numericParams(params)
	local out = {}
	for mod, kv in pairs(params or {}) do
		if type(kv) == "table" then
			local copy = {}
			for k, v in pairs(kv) do if type(v) == "number" then copy[k] = v end end
			out[mod] = copy
		end
	end
	return out
end

-- a resource name given loosely: "temperate" matches "temperate", "climates/temperate/temperate.clima", ...
local function baseName(n) return (tostring(n):match("([^/]+)$") or n):gsub("%.[%w_]+$", "") end

function M.matchName(names, wanted)
	if wanted == nil then return nil end
	for _, n in ipairs(names) do if n == wanted then return n end end
	local hits = {}
	for _, n in ipairs(names) do
		if baseName(n) == wanted or baseName(n) == baseName(wanted) then hits[#hits + 1] = n end
	end
	if #hits == 1 then return hits[1] end
	return nil, #hits
end

-- args: climate, generator, size, year, seed, towns, industries, mods { set | add | remove }, params.
-- ctx: climates = { name = { economy = ..., generators = { names in the base page's order } } }, mods (active
-- mod ids), modParams (active), selfId. Returns the plan, or nil and why.
function M.newGamePlan(args, ctx)
	local names = {}
	for n in pairs(ctx.climates or {}) do names[#names + 1] = n end
	table.sort(names)
	if #names == 0 then return nil, "no climate resources found" end
	local climate, n = M.matchName(names, args.climate or "temperate")
	if not climate then
		return nil, string.format("climate %q %s; known: %s", tostring(args.climate or "temperate"),
			(n or 0) > 1 and "is ambiguous" or "not found", table.concat(names, ", "))
	end
	local c = ctx.climates[climate]
	local generator = c.generators[1]
	if args.generator ~= nil then
		local g, gn = M.matchName(c.generators, args.generator)
		if not g then
			return nil, string.format("generator %q %s for %s; known: %s", tostring(args.generator),
				(gn or 0) > 1 and "is ambiguous" or "not found", climate, table.concat(c.generators, ", "))
		end
		generator = g
	end
	if not generator then return nil, "no terrain generator for climate " .. climate end
	local x, y = M.parseSize(args.size)
	if not x then return nil, y end
	local year = tonumber(args.year or 1900)
	if not year or year % 1 ~= 0 or year < 1800 or year > 2100 then return nil, "year must be a whole year 1800-2100" end
	local params, err = M.mergeParams(M.numericParams(ctx.modParams), args.params)
	if not params then return nil, err end
	local mods = M.mergeMods(ctx.mods, args.mods, ctx.selfId)
	local orphan = M.paramsWithoutModsError(args.params, mods)
	if orphan then return nil, orphan end
	return {
		climate = climate, generator = generator, economy = c.economy, numTiles = { x, y }, year = year,
		seed = tostring(args.seed or ("remote_probe_" .. tostring(ctx.time or 0))),
		towns = args.towns ~= false, industries = args.industries ~= false,
		mods = mods, modParams = params,
	}
end

---------------------------------------------------------------------------------------------------------------------
-- towns, lines, vehicles, stations and industries by name (for the window command)

M.ENTITY_KINDS = { town = true, line = true, vehicle = true, station = true, industry = true }

-- list: { { id = n, name = s } }. An exact name (any case) wins; otherwise a unique substring match.
-- Returns the entry, or nil and why (with up to 10 candidates).
function M.matchEntity(list, query)
	if type(query) ~= "string" or query == "" then return nil, "give a name" end
	local q = query:lower()
	local exact, partial = {}, {}
	for _, e in ipairs(list or {}) do
		local n = tostring(e.name or ""):lower()
		if n == q then exact[#exact + 1] = e
		elseif n:find(q, 1, true) then partial[#partial + 1] = e end
	end
	local hits = #exact > 0 and exact or partial
	if #hits == 1 then return hits[1] end
	local names = {}
	for i = 1, math.min(#hits, 10) do names[#names + 1] = string.format("%s (%s)", tostring(hits[i].name), tostring(hits[i].id)) end
	if #hits == 0 then return nil, string.format("no match for %q", query) end
	return nil, string.format("%d matches for %q: %s%s", #hits, query, table.concat(names, ", "), #hits > 10 and ", ..." or "")
end

-- what the speed control's join reads from the GUI save data (api.gui.game.getGuiSaveData): plain values only
function M.uiRequest(d)
	if type(d) ~= "table" then return { label = "", tip = "" } end
	local out = { label = tostring(d.label or ""), tip = tostring(d.tip or "") }
	if type(d.open) == "table" and tonumber(d.open.seq) then
		out.open = { seq = tonumber(d.open.seq), entity = tonumber(d.open.entity) }
		local ev = d.open.event
		if type(ev) == "table" and type(ev.name) == "string" and ev.name ~= "" then
			out.open.event = { name = ev.name, param = ev.param }
		end
		local tool = d.open.tool
		if type(tool) == "table" and type(tool.module) == "string" and tool.module ~= "" then
			out.open.tool = { module = tool.module, field = type(tool.field) == "string" and tool.field or nil,
				close = tool.close == true }
		end
	end
	out.vehicles = M.vehicleRequests(d.vehicles)
	out.lines = M.lineRequests(d.lines)
	return out
end

-- the vehicle requests (gui way) the guiUpdate script hands the speed control: { { id, kind, modelId, count,
-- depot, line, vehicle } }, plain numbers only; anything else is left out rather than guessed at
M.VEHICLE_KINDS = { buy = true, duplicate = true, replace = true, sell = true }
function M.vehicleRequests(list)
	local out = {}
	if type(list) ~= "table" then return out end
	for _, r in ipairs(list) do
		if type(r) == "table" and tonumber(r.id) and M.VEHICLE_KINDS[r.kind] then
			out[#out + 1] = { id = tonumber(r.id), kind = r.kind, modelId = tonumber(r.modelId), count = tonumber(r.count),
				depot = tonumber(r.depot), line = tonumber(r.line), vehicle = tonumber(r.vehicle) }
		end
	end
	return out
end

---------------------------------------------------------------------------------------------------------------------
-- base windows that open as tools (the music player button: getToolStackApi(gameCtx).push(MusicPlayerTool, nil,
-- { gameCtx = gameCtx }), game_bar_widgets.tl). Only tools a module hands out can be reached: the statistics
-- tool, for one, is local to statistics.tl.

M.TOOLS = {
	music = { module = "/gui/music_player/music_player.tl" }, -- the module returns the tool
	calendar = { module = "/gui/game_bar/game_bar_widgets.tl", field = "CalendarEditorTool" },
}

-- args: name (a key of TOOLS) or module (+ field); close. Returns { module, field, close } or nil and why.
function M.toolRequest(args)
	args = type(args) == "table" and args or {}
	local t
	if type(args.module) == "string" and args.module ~= "" then
		t = { module = args.module, field = type(args.field) == "string" and args.field ~= "" and args.field or nil }
	elseif args.name ~= nil then
		local known = M.TOOLS[args.name]
		if not known then
			local names = {}
			for k in pairs(M.TOOLS) do names[#names + 1] = k end
			table.sort(names)
			return nil, string.format("unknown tool %q; known: %s (or give module and field)", tostring(args.name),
				table.concat(names, ", "))
		end
		t = { module = known.module, field = known.field }
	else
		return nil, "give a tool name or a module"
	end
	t.close = args.close == true
	return t
end

-- camera: the API takes any float, and a NaN or a far-off centre would leave the player looking at nothing.
-- Limits from getCameraData read in game: angle is a heading in radians (kept within one turn either way),
-- pitch within a quarter turn, distance a few metres to a whole map away.
M.CAMERA_LIMITS = { xy = 1e6, distance = { 1, 1e5 }, angle = 2 * math.pi, pitch = math.pi / 2 }

local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end

-- "x,y[,distance[,angle[,pitch]]]" or a list -> numbers; missing ones nil
function M.numberList(v, most)
	local list = {}
	if type(v) == "string" then
		for part in (v .. ","):gmatch("([^,]*),") do list[#list + 1] = part end
	elseif type(v) == "table" then
		for i = 1, #v do list[i] = v[i] end
	else
		return nil, "give numbers separated by commas"
	end
	if #list > most then return nil, "at most " .. most .. " numbers" end
	local out = {}
	for i, x in ipairs(list) do
		local n = tonumber(x)
		if not finite(n) then return nil, "not a finite number: " .. tostring(x) end
		out[i] = n
	end
	return out
end

-- cur: { x, y, distance, angle, pitch } now; set: numbers in that order (nil = keep). -> the new five or nil, err
function M.cameraTarget(cur, set)
	local L, keys, out = M.CAMERA_LIMITS, { "x", "y", "distance", "angle", "pitch" }, {}
	if #set < 2 then return nil, "set needs at least x,y" end
	for i, k in ipairs(keys) do
		local v = set[i]
		if v == nil then v = cur[k] end
		if not finite(v) then return nil, k .. " is not a finite number" end
		out[k] = v
	end
	if math.abs(out.x) > L.xy or math.abs(out.y) > L.xy then return nil, "x and y must be within " .. L.xy end
	if out.distance < L.distance[1] or out.distance > L.distance[2] then
		return nil, string.format("distance must be %g-%g", L.distance[1], L.distance[2])
	end
	if math.abs(out.angle) > L.angle then return nil, "angle must be within +-2 pi" end
	if math.abs(out.pitch) > L.pitch then return nil, "pitch must be within +-pi/2" end
	return out
end

-- build tool: the menu filter tag of a construction (construction.tl: resName, or resName@N with a template)
M.BUILD_TOOL_SEC = { default = 60, max = 600 }
M.BUILD_TOOL_GAP = 1.5 -- s between the events: the speed control reads every 0.5 s and keeps only the newest
function M.buildToolRequest(args)
	args = type(args) == "table" and args or {}
	local res = args.res
	if type(res) ~= "string" or res == "" or res:find("@", 1, true) then return nil, "give res (the construction's resName)" end
	local tag = res
	if args.template ~= nil then
		local n = tonumber(args.template)
		if not n or n ~= math.floor(n) or n < 0 or n > 1000 then return nil, "template must be a whole number 0-1000" end
		tag = res .. "@" .. string.format("%d", n)
	end
	local sec = args.seconds == nil and M.BUILD_TOOL_SEC.default or tonumber(args.seconds)
	if not finite(sec) or sec < 5 or sec > M.BUILD_TOOL_SEC.max then
		return nil, "seconds must be 5-" .. M.BUILD_TOOL_SEC.max
	end
	return { res = res, tag = tag, seconds = sec }
end

function M.menuFilter(tag)
	return { enabledItems = tag and { tag } or {}, disabledItems = {}, disabledParams = {} }
end

-- args: name (a react event, e.g. "example_window.show"), param (a table, or nothing). The param goes through the
-- GUI save data, so only plain values: no functions or userdata, no cycles.
function M.eventRequest(args)
	args = type(args) == "table" and args or {}
	if type(args.name) ~= "string" or args.name == "" then return nil, "give the event's name" end
	local seen = {}
	local function plainValue(v, depth)
		local t = type(v)
		if t == "string" or t == "number" or t == "boolean" or v == nil then return true end
		if t ~= "table" then return false, "a " .. t end
		if seen[v] then return false, "a cycle" end
		if depth > 8 then return false, "nesting deeper than 8" end
		seen[v] = true
		for k, x in pairs(v) do
			if type(k) ~= "string" and type(k) ~= "number" then return false, "a " .. type(k) .. " key" end
			local ok, why = plainValue(x, depth + 1)
			if not ok then return false, why end
		end
		seen[v] = nil
		return true
	end
	if args.param ~= nil and type(args.param) ~= "table" then return nil, "param must be a table" end
	local ok, why = plainValue(args.param, 0)
	if not ok then return nil, "param holds " .. why .. ": only plain values go through" end
	return { name = args.name, param = args.param }
end

---------------------------------------------------------------------------------------------------------------------
-- vehicles: buy, duplicate, replace, sell (remote_vehicles.lua does the game side)

-- gui: through the base's vehicle_react_util.HandleVehicleChanges, as the vehicle store and the clone button do
-- (it stamps purchaseTime on new parts); cmd: the engine commands alone, to see what the engine does without it
M.VEHICLE_VIAS = { gui = true, cmd = true }
M.MAX_BUY_COUNT = 20

local function entityArg(v)
	local n = tonumber(v)
	if n == nil or n ~= math.floor(n) or n < 0 then return nil end
	return n
end

-- cmd: buy, duplicate, replace or sell. Returns { via, count, depot, line, vehicle, model } (model: the query as
-- given, matched later against the model list) or nil and why.
function M.vehicleArgs(cmd, args)
	args = type(args) == "table" and args or {}
	local out = { via = args.via == nil and "gui" or args.via }
	if not M.VEHICLE_VIAS[out.via] then return nil, "via must be gui or cmd" end
	for _, k in ipairs({ "depot", "line", "vehicle" }) do
		if args[k] ~= nil then
			out[k] = entityArg(args[k])
			if out[k] == nil then return nil, k .. " must be an entity id (a whole number >= 0)" end
		end
	end
	if cmd == "buy" or cmd == "replace" then
		local m = args.model
		if type(m) == "number" then m = string.format("%d", m) end
		if type(m) ~= "string" or m == "" then return nil, "give the model (its id, or a part of its file name)" end
		out.model = m
	end
	if cmd == "buy" then
		local n = args.count == nil and 1 or tonumber(args.count)
		if n == nil or n ~= math.floor(n) or n < 1 or n > M.MAX_BUY_COUNT then
			return nil, "count must be a whole number from 1 to " .. M.MAX_BUY_COUNT
		end
		out.count = n
		-- the store finds a depot for a new vehicle only when opened from a depot or a line; the probe has
		-- neither, so it asks (the depots command lists them)
		if out.depot == nil then return nil, "give the depot (the depots command lists them)" end
	elseif cmd == "duplicate" or cmd == "replace" or cmd == "sell" then
		if out.vehicle == nil then return nil, "give the vehicle (the vehicles command lists them)" end
	else
		return nil, "unknown vehicle command " .. tostring(cmd)
	end
	return out
end

-- list: { { id = n, name = "vehicle/bus/xx.mdl" } } of vehicle models. An id (as a number or digits) or an exact
-- name wins, then the exact file name without folder and extension, then a unique substring (any case).
function M.matchModel(list, query)
	if type(query) == "number" then query = string.format("%d", query) end
	if type(query) ~= "string" or query == "" then return nil, "give the model" end
	local id = query:match("^%d+$") and tonumber(query)
	local q = query:lower()
	local exact, base, partial = {}, {}, {}
	for _, m in ipairs(list or {}) do
		local n = tostring(m.name or ""):lower()
		if (id and m.id == id) or n == q then exact[#exact + 1] = m
		elseif baseName(n) == q then base[#base + 1] = m
		elseif n:find(q, 1, true) then partial[#partial + 1] = m end
	end
	local hits = #exact > 0 and exact or (#base > 0 and base or partial)
	if #hits == 1 then return hits[1] end
	if #hits == 0 then return nil, string.format("no vehicle model matches %q", query) end
	table.sort(hits, function(a, b) return tostring(a.name) < tostring(b.name) end)
	local names = {}
	for i = 1, math.min(#hits, 10) do names[#names + 1] = string.format("%s (%s)", tostring(hits[i].name), tostring(hits[i].id)) end
	return nil, string.format("%d models match %q: %s%s", #hits, query, table.concat(names, ", "), #hits > 10 and ", ..." or "")
end

-- what the operation cost: positive = paid, negative = earned (a sale). nil when a balance is unknown (the
-- engine returns nil for infinite money).
function M.spent(before, after)
	if type(before) ~= "number" or type(after) ~= "number" then return nil end
	return before - after
end

-- money: args set (the balance to have) or add (to the balance). The amount is a whole number within what a
-- double holds exactly (the engine's llong is wider, but a Lua number past 2^53 is no longer exact).
M.MONEY_LIMIT = 2 ^ 53 - 1

local function moneyValue(v, name)
	local n = type(v) == "number" and v or (type(v) == "string" and tonumber(v) or nil)
	if n == nil or n ~= n then return nil, name .. " must be a number" end
	n = math.floor(n + 0.5) -- the base rounds the amount (game_bar.tl, math_util.round)
	if n > M.MONEY_LIMIT or n < -M.MONEY_LIMIT then return nil, name .. " is out of range (|n| <= 2^53-1)" end
	return n
end

-- Returns { set = n } or { add = n }, or nil and why.
function M.moneyArgs(args)
	args = type(args) == "table" and args or {}
	if (args.set ~= nil) == (args.add ~= nil) then return nil, "give exactly one of set and add" end
	local key = args.set ~= nil and "set" or "add"
	local n, err = moneyValue(args[key], key)
	if not n then return nil, err end
	return { [key] = n }
end

-- the journal amount that takes balance to the target: target - balance (set) or add, within the limit
function M.moneyAmount(a, balance)
	if type(balance) ~= "number" then return nil, "the balance is unknown or infinite (getPlayersBalance gave nil): nothing to change" end
	local amount = a.set ~= nil and (a.set - balance) or a.add
	if amount > M.MONEY_LIMIT or amount < -M.MONEY_LIMIT or balance + amount > M.MONEY_LIMIT or balance + amount < -M.MONEY_LIMIT then
		return nil, "the new balance would be out of range (|n| <= 2^53-1)"
	end
	return amount
end

---------------------------------------------------------------------------------------------------------------------
-- lines: create, update, delete (remote_lines.lua does the game side, line_configs.lua builds the Line)

M.LINE_ACTIONS = { create = true, update = true, delete = true }
M.MAX_LINE_STOPS = 50
M.MAX_NAME_LENGTH = 100

-- one stop as given: a station group or station entity id (a whole number, or digits), or a part of a station
-- group's name. Returns the number or the trimmed string, or nil and why.
local function stopToken(v, i)
	if type(v) == "number" then
		if v ~= math.floor(v) or v < 0 then return nil, string.format("stop %d must be an entity id or a name", i) end
		return v
	end
	if type(v) ~= "string" then return nil, string.format("stop %d must be an entity id or a name (got a %s)", i, type(v)) end
	local s = v:match("^%s*(.-)%s*$")
	if s == "" then return nil, string.format("stop %d is empty", i) end
	if s:match("^%d+$") then return tonumber(s) end
	return s
end

-- args: action, via, line, stops (a list), name, cargo, sellVehicles. Returns { action, via, line, stops, name,
-- cargo, sellVehicles } or nil and why. A line needs two stops: the base makes a one-stop line only on the way to
-- the second click, and nothing runs on it.
function M.lineArgs(args)
	args = type(args) == "table" and args or {}
	if not M.LINE_ACTIONS[args.action] then return nil, "action must be create, update or delete" end
	local out = { action = args.action, via = args.via == nil and "gui" or args.via, sellVehicles = args.sellVehicles == true }
	if not M.VEHICLE_VIAS[out.via] then return nil, "via must be gui or cmd" end
	if args.line ~= nil then
		out.line = entityArg(args.line)
		if out.line == nil then return nil, "line must be an entity id (a whole number >= 0)" end
	end
	if args.name ~= nil then
		if type(args.name) ~= "string" or args.name:match("^%s*$") then return nil, "name must be a non-empty string" end
		if #args.name > M.MAX_NAME_LENGTH then return nil, "name is longer than " .. M.MAX_NAME_LENGTH .. " bytes" end
		out.name = args.name
	end
	if args.cargo ~= nil then
		local c = args.cargo
		if type(c) == "number" then c = string.format("%d", c) end
		if type(c) ~= "string" or c == "" then return nil, "cargo must be a cargo type's id or name" end
		out.cargo = c
	end
	if args.stops ~= nil then
		if type(args.stops) ~= "table" then return nil, "stops must be a list" end
		local n = #args.stops
		for k in pairs(args.stops) do
			if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then return nil, "stops must be a list" end
		end
		if n == 0 then return nil, "stops is empty: give the stations (ids or names)" end
		if n < 2 then return nil, "a line needs at least 2 stops" end
		if n > M.MAX_LINE_STOPS then return nil, "more than " .. M.MAX_LINE_STOPS .. " stops" end
		out.stops = {}
		for i = 1, n do
			local t, err = stopToken(args.stops[i], i)
			if t == nil then return nil, err end
			out.stops[i] = t
		end
	end
	if out.action == "create" then
		if out.line ~= nil then return nil, "create makes a new line: no line" end
		if not out.stops then return nil, "give the stops" end
	else
		if out.line == nil then return nil, "give the line (the lines command lists them)" end
		if out.action == "update" and not (out.stops or out.name or out.cargo) then
			return nil, "give stops, name or cargo to change"
		end
		if out.action == "delete" and (out.stops or out.name or out.cargo) then
			return nil, "delete takes no stops, name or cargo"
		end
	end
	return out
end

-- the line requests (gui way) the guiUpdate script hands the speed control: { { id, kind = "create" | "update",
-- line, name, cargo, stops = { { stationGroup } } } }, plain values only; malformed ones are left out
M.LINE_REQUEST_KINDS = { create = true, update = true }
function M.lineRequests(list)
	local out = {}
	if type(list) ~= "table" then return out end
	for _, r in ipairs(list) do
		if type(r) == "table" and tonumber(r.id) and M.LINE_REQUEST_KINDS[r.kind] then
			local stops, good = nil, true
			if r.stops ~= nil then
				stops = {}
				if type(r.stops) ~= "table" then
					good = false
				else
					for _, s in ipairs(r.stops) do
						local sg = type(s) == "table" and tonumber(s.stationGroup) or nil
						if sg == nil then good = false else stops[#stops + 1] = { stationGroup = sg } end
					end
					if #stops == 0 then good = false end
				end
			end
			if good and (r.kind == "create" or tonumber(r.line)) then
				out[#out + 1] = { id = tonumber(r.id), kind = r.kind, line = tonumber(r.line), stops = stops,
					name = type(r.name) == "string" and r.name or nil, cargo = tonumber(r.cargo) }
			end
		end
	end
	return out
end

-- list: { { id = n, name = "GRAIN", label = "Grain" } } of cargo types. An id, or an exact name or
-- label (any case), wins; then a unique substring of either.
function M.matchCargo(list, query)
	if type(query) == "number" then query = string.format("%d", query) end
	if type(query) ~= "string" or query == "" then return nil, "give the cargo" end
	local id = query:match("^%d+$") and tonumber(query)
	local q = query:lower()
	local exact, partial = {}, {}
	for _, c in ipairs(list or {}) do
		local n, l = tostring(c.name or ""):lower(), tostring(c.label or ""):lower()
		if (id and c.id == id) or n == q or l == q then exact[#exact + 1] = c
		elseif n:find(q, 1, true) or l:find(q, 1, true) then partial[#partial + 1] = c end
	end
	local hits = #exact > 0 and exact or partial
	if #hits == 1 then return hits[1] end
	local names = {}
	for i = 1, math.min(#hits, 10) do names[#names + 1] = string.format("%s (%s)", tostring(hits[i].name), tostring(hits[i].id)) end
	if #hits == 0 then return nil, string.format("no cargo type matches %q", query) end
	return nil, string.format("%d cargo types match %q: %s", #hits, query, table.concat(names, ", "))
end

-- stations near an entity: radius in metres (default 1000). Returns it, or nil and why.
M.DEFAULT_RADIUS = 1000
function M.radiusArg(v)
	if v == nil then return M.DEFAULT_RADIUS end
	local n = tonumber(v)
	if n == nil or n ~= n or n <= 0 or n > 100000 then return nil, "radius must be a number of metres, above 0 and up to 100000" end
	return n
end

---------------------------------------------------------------------------------------------------------------------
-- connect: a track or road between two ends (remote_connect.lua does the game side through Track Connector)

M.CONNECT_TRACKS = { standard = true, high_speed = true, simple = true }
M.CONNECT_TIMEOUT = { default = 120, min = 10, max = 1800 }
-- slope in percent, radius in metres: what the planner and the game can do something with. Track Connector's own
-- lists go from 1 to 8 % (tracks) and 3 to 12 % (roads), 40 to 1500 m.
M.CONNECT_SLOPE = { min = 0.5, max = 15 }
M.CONNECT_RADIUS = { min = 30, max = 5000 }

-- one end as given: an entity id (a node, station, station group or station construction), or a part of a
-- station group's name. Returns the number or the trimmed string, or nil and why.
-- (entity ids are above 0 and fit 32 bits; anything else is refused before it reaches an engine lookup)
M.MAX_ENTITY_ID = 2 ^ 31 - 1
local function endToken(v, what)
	if type(v) == "number" then
		if v ~= v or v ~= math.floor(v) or v < 1 or v > M.MAX_ENTITY_ID then
			return nil, what .. " must be an entity id (1 to 2^31-1) or a station's name"
		end
		return v
	end
	if type(v) ~= "string" then
		return nil, what .. " must be an entity id or a station's name (got " .. (v == nil and "nothing" or ("a " .. type(v))) .. ")"
	end
	local s = v:match("^%s*(.-)%s*$")
	if s == "" then return nil, what .. " is empty" end
	if s:match("^%d+$") then return endToken(tonumber(s), what) end
	return s
end

local function numberIn(v, name, lo, hi)
	local n = tonumber(v)
	if type(v) ~= "number" and type(v) ~= "string" then n = nil end
	if n == nil or n ~= n or n < lo or n > hi then return nil, string.format("%s must be a number from %g to %g", name, lo, hi) end
	return n
end

-- args: from, to, road, template, track, electric, slope (%), radius (m), bridges, tunnels, build, clear, timeout.
-- Returns { from, to, road, template, track, electric, slope (a ratio), radius, bridges, tunnels, build, clear,
-- timeout } (slope and radius nil: the mode's defaults) or nil and why.
function M.connectArgs(args)
	args = type(args) == "table" and args or {}
	local out = { road = args.road == true, electric = args.electric == true, build = args.build == true,
		clear = args.clear == true, bridges = args.bridges ~= false, tunnels = args.tunnels ~= false }
	local err
	out.from, err = endToken(args.from, "from")
	if out.from == nil then return nil, err end
	out.to, err = endToken(args.to, "to")
	if out.to == nil then return nil, err end
	if out.from == out.to then return nil, "from and to are the same" end
	for _, k in ipairs({ "road", "electric", "build", "clear", "bridges", "tunnels" }) do
		if args[k] ~= nil and type(args[k]) ~= "boolean" then return nil, k .. " must be true or false" end
	end
	if out.road then
		if args.track ~= nil then return nil, "track goes with tracks, not with road (give the road type as template)" end
		if out.electric then return nil, "electric goes with tracks, not with road" end
		if args.template ~= nil then
			if type(args.template) ~= "string" or not args.template:find("::/", 1, true) then
				return nil, "template must be a street template's full resource name, e.g. " ..
					"::/infrastructure/street/country/country_new_medium.street_template"
			end
			out.template = args.template
		end
	else
		if args.template ~= nil then return nil, "template goes with road (for tracks give track)" end
		local t = args.track == nil and "standard" or args.track
		if type(t) ~= "string" or not (M.CONNECT_TRACKS[t] or t:find("::/", 1, true)) then
			return nil, "track must be standard, high_speed, simple or a track template's full resource name"
		end
		out.track = t
	end
	if args.slope ~= nil then
		out.slope, err = numberIn(args.slope, "slope (%)", M.CONNECT_SLOPE.min, M.CONNECT_SLOPE.max)
		if not out.slope then return nil, err end
		out.slope = out.slope / 100
	end
	if args.radius ~= nil then
		out.radius, err = numberIn(args.radius, "radius (m)", M.CONNECT_RADIUS.min, M.CONNECT_RADIUS.max)
		if not out.radius then return nil, err end
	end
	if out.clear and not out.build then return nil, "clear (knock down town buildings in the way) goes with build" end
	out.timeout = M.CONNECT_TIMEOUT.default
	if args.timeout ~= nil then
		out.timeout, err = numberIn(args.timeout, "timeout (s)", M.CONNECT_TIMEOUT.min, M.CONNECT_TIMEOUT.max)
		if not out.timeout then return nil, err end
	end
	return out
end

return M
