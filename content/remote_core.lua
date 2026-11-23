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
	stations = true, lines = true, line = true, connect = true, camera = true, buildTool = true, scriptEvent = true, rename = true,
	build = true, industryWorkers = true, industryStocks = true, models = true, persons = true, modhubStatus = true,
	modhubValidate = true, modhubPublish = true, water = true, road = true, roadInspect = true, terrain = true, terrainApi = true,
	town = true, stockList = true, stockSet = true, steps = true, townDevelop = true, townSize = true, parcels = true,
	company = true, companyInit = true, townConnections = true, townConnect = true }
-- poll only changes how often the mod reads files, not the game: no "who used the game" entry for it
M.CHANGES_GAME = { speed = true, run = true, load = true, save = true, newgame = true, window = true, quit = true,
	event = true, tool = true, buy = true, duplicate = true, replace = true, sell = true, money = true,
	line = true, connect = true, camera = true, buildTool = true, scriptEvent = true, rename = true, -- camera, as window: what the player sees
	build = true, road = true, -- (road too) also its dry run: it is how a test save gets changed, so it warns others the same way
	-- modhubValidate changes no save and writes nothing to mod.io, but it runs the game's validator on a staging
	-- mod for minutes, and starting one aborts a validation already running for that mod (the type's own words),
	-- e.g. one a person started on the My Mods page: so others are warned. modhubStatus only reads.
	-- modhubPublish uploads to mod.io (its dry run validates, as modhubValidate)
	modhubValidate = true, modhubPublish = true,
	terrain = true, -- also its dry run, as build's (terrainApi only looks whether functions exist)
	town = true, -- also its dry run (it asks the engine for a town proposal, as the editor's preview)
	-- the debug commands (remote_debug.lua): test saves only; their dry runs too, as build's (stockList only reads)
	stockSet = true, steps = true,
	-- town develop / town size (remote_town_grow.lua): test saves only; their dry runs too, as build's
	townDevelop = true, townSize = true,
	-- company init (remote_company.lua): test saves only, the base's new-game event sent by hand (company only reads)
	companyInit = true,
	-- town connect (remote_town_connect.lua): test saves only; its dry run too (it copies the map from the game, as
	-- town's dry run asks for a proposal). town connections only reads
	townConnect = true }
-- what works in the main menu (startup.lua): no world and no GUI of a game there, so nothing that reads or
-- shows one. newgame is safe only there (inside a save app.startGame hits the base's StartGame assertion).
M.MENU_COMMANDS = { status = true, saves = true, info = true, load = true, newgame = true, poll = true, quit = true,
	modhubStatus = true, modhubValidate = true, modhubPublish = true }
-- what works only in the main menu: My Mods' publish helper is a privileged API (the base makes it in the menu's
-- own privileged Lua state, main_menu.tl); inside a save the probe runs in the game's GUI state, which is not
-- expected to have it, and the base has no My Mods page there either
M.MENU_ONLY = { modhubStatus = true, modhubValidate = true, modhubPublish = true }

-- reach (remote_reach.lua): read only, in a game (kept apart from the table above, which other branches change)
M.COMMANDS.reach = true
-- around (remote_around.lua): read only, in a game
M.COMMANDS.around = true
-- lanes (remote_lanes.lua): read only, in a game
M.COMMANDS.edgeLanes = true

---------------------------------------------------------------------------------------------------------------------
-- mod settings (mod.json params): each arrives as a 1-based index into these lists

M.OPTION_VALUES = {
	pollIdle = { 1, 2, 5, 10 }, -- seconds between checks of the command file when nobody asked for a while
	pollActive = { 0.1, 0.25, 0.5, 1 }, -- the same for ACTIVE_SEC after a command and during a run
	logLevel = { 1, 2, 3 }, -- 1 minimal (ready, loads, errors), 2 each command, 3 also progress and receipts
	speedLabel = { true, false }, -- the label beside the speed buttons (gui/remote_speed.script.lua)
	-- our ×8 / ×16 buttons: off for screenshots, where they are another mod's UI in the bottom bar (05, 2026-11-19)
	speedButtons = { true, false },
}
M.OPTION_DEFAULT = { pollIdle = 2, pollActive = 2, logLevel = 2, speedLabel = 1, speedButtons = 1 }

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

-- tf3ctl --other-owner-ok: the client sent a game-changing command to a game another owner started (or one started
-- outside tf3ctl). The tool refuses that without the option; with it, the log line says so, for whoever reads it later
function M.otherOwnerOk(args)
	local o = args and args._otherOwnerOk
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
		mods = mods, modParams = params, editor = args.editor == true or nil,
	}
end

-- What the base new-game page derives from the base params (new_game_or_map_settings_page.tl makeMapPreviewInputs
-- and startGame2): the town and industry densities through difficulty_util.getScale, the start time and clouds
-- from new_game_react_util's tables. Copies of those tables (base build 40444), used when difficulty_util cannot
-- be loaded: StartGameParams left without them keeps BaseConfig.Locations.new()'s values, which are not the menu's.
M.DIFFICULTY_UTIL = "/base/difficulty_util.tl"
M.DENSITY_SCALES = {
	["locations.towns.frequency"] = { 0.2, 0.3, 0.4, 0.65, 1.0 }, -- level2TownFrequencyFactor
	["locations.towns.populationDensity"] = { 0.5, 0.75, 1.0, 1.5, 2.0 }, -- level2IndustryProductivityFactor
	["locations.industry.initialIndustryDensity"] = { 2 / 3, 5 / 6, 1.0, 6 / 5, 3 / 2 }, -- level2IndustryDensityFactor
}
-- the base mod.json's default for all three (defaultIndex 2, so 3 in the game's 1-based form), for a missing param
M.DENSITY_DEFAULT_LEVEL = 3
M.START_HOURS = { 14, 14, 14, 7, 14, 18, 23 } -- by gameTimeConfig.timeOfDayMode (getInitialTimeOfDayValues)
M.START_CLOUDS = { 0.0, 0.0, 0.25, 0.5 } -- by weatherConfig.dynamicWeather (getInitialCloudCoverageValues)

-- a base param's 1-based level; a missing one is taken as the menu's default (the menu always has one), one
-- outside the range is nil (the base's getScale then gives 1.0)
local function startLevel(base, key, default, count, warnings)
	local v = type(base) == "table" and base[key] or nil
	if v == nil then
		warnings[#warnings + 1] = string.format("base param %s missing: taken as the menu default %d", key, default)
		return default
	end
	if type(v) ~= "number" or v % 1 ~= 0 or v < 1 or v > count then
		warnings[#warnings + 1] = string.format("base param %s = %s is outside 1-%d", key, tostring(v), count)
		return nil
	end
	return v
end

-- base: the plan's modParams[""]; du: the loaded difficulty_util or nil, duError: why it did not load.
-- Returns { locations = { values for BaseConfig.Locations }, timeOfDaySeconds, cloudCoverage, levels, source },
-- and the warnings (a list, empty when everything came out as in the menu).
function M.newGameStart(base, du, duError)
	local warnings = {}
	local source = "difficulty_util"
	if type(du) ~= "table" or type(du.getScale) ~= "function" then
		du = nil
		source = "copy"
		warnings[#warnings + 1] = "difficulty_util not available (" .. tostring(duError or "no getScale")
			.. "): town and industry densities from remote_probe's copy of its tables"
	end
	local levels, scales = {}, {}
	-- a fixed order, so the warnings come in the same order each time (the load failure first)
	for _, key in ipairs({ "locations.towns.frequency", "locations.towns.populationDensity",
		"locations.industry.initialIndustryDensity" }) do
		local list = M.DENSITY_SCALES[key]
		local l = startLevel(base, key, M.DENSITY_DEFAULT_LEVEL, #list, warnings)
		levels[key] = l
		local s
		if du and l then
			local ok, v = pcall(du.getScale, key, l)
			if ok and type(v) == "number" then s = v else
				source = "copy"
				warnings[#warnings + 1] = string.format("difficulty_util.getScale(%s, %d) failed (%s): the copy used",
					key, l, tostring(ok and type(v) or v))
			end
		end
		scales[key] = s or (l and list[l]) or 1.0
	end
	local hours = startLevel(base, "gameTimeConfig.timeOfDayMode", 1, #M.START_HOURS, warnings)
	local clouds = startLevel(base, "weatherConfig.dynamicWeather", 1, #M.START_CLOUDS, warnings)
	levels["gameTimeConfig.timeOfDayMode"], levels["weatherConfig.dynamicWeather"] = hours, clouds
	return {
		locations = {
			townFrequency = scales["locations.towns.frequency"],
			populationDensity = scales["locations.towns.populationDensity"],
			-- the base page's initialIndustryDensityFactor (1.0) times the scale
			industryDensity = 1.0 * scales["locations.industry.initialIndustryDensity"],
			maxNumberPerArea = 0.2, allowInRoughTerrain = false, absoluteMinimum = 24, industryProductivity = 1,
			makeInitialStreets = true,
		},
		-- an out-of-range mode: the first entry (the menu would pass nil)
		timeOfDaySeconds = M.START_HOURS[hours or 1] * 3600,
		cloudCoverage = M.START_CLOUDS[clouds or 1],
		levels = levels, source = source,
	}, warnings
end

---------------------------------------------------------------------------------------------------------------------
-- towns, lines, vehicles, stations, industries and warehouses by name (for the window command)

M.ENTITY_KINDS = { town = true, line = true, vehicle = true, station = true, industry = true, warehouse = true }

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

-- one window, event or tool request (an entry of opens): { seq, entity, manager, event, tool }, plain values only;
-- nil for one without a request number
function M.openRequest(o)
	if type(o) ~= "table" or not tonumber(o.seq) then return nil end
	local out = { seq = tonumber(o.seq), entity = tonumber(o.entity) }
	-- manager: a line to open in the line manager (an entity id, so a whole positive number or nothing)
	local m = tonumber(o.manager)
	if m and m > 0 and m < 2 ^ 53 and m == math.floor(m) then out.manager = m end
	local ev = o.event
	if type(ev) == "table" and type(ev.name) == "string" and ev.name ~= "" then
		out.event = { name = ev.name, param = ev.param }
	end
	local tool = o.tool
	if type(tool) == "table" and type(tool.module) == "string" and tool.module ~= "" then
		out.tool = { module = tool.module, field = type(tool.field) == "string" and tool.field or nil,
			close = tool.close == true }
	end
	return out
end

-- the window, event and tool requests still waiting, oldest (lowest seq) first. A list, not one slot: two
-- requests within one read of the speed control (every 0.5 s) both go, in order, where a single slot kept only
-- the newer (2026-11-22: of two events sent in the same second, only the second reached the other mod)
function M.openRequests(list)
	local out = {}
	if type(list) ~= "table" then return out end
	for _, o in ipairs(list) do
		local r = M.openRequest(o)
		if r then out[#out + 1] = r end
	end
	table.sort(out, function(a, b) return a.seq < b.seq end)
	return out
end

M.OPEN_RELAY_SEC = 10 -- a request the speed control has not taken by then is dropped and answered as not relayed
M.OPEN_REPORTS_KEPT = 20 -- what the speed control did with the last requests, under MOD .. ".open"

-- the speed control's reports (getGuiSaveData(MOD .. ".open")): seq -> { error = text or nil, skipped = bool }.
-- skipped: in the list at the speed control's first read, so taken as left over from the last game, not run
function M.openReports(d)
	local out = {}
	if type(d) ~= "table" or type(d.done) ~= "table" then return out end
	for _, r in ipairs(d.done) do
		local seq = type(r) == "table" and tonumber(r.seq) or nil
		if seq then
			-- the first word on a request stands: a later "skipped" for one already run must not undo it
			out[seq] = out[seq] or { error = r.error ~= nil and tostring(r.error) or nil, skipped = r.skipped == true }
		end
	end
	return out
end

-- what the speed control's join reads from the GUI save data (api.gui.game.getGuiSaveData): plain values only
function M.uiRequest(d)
	if type(d) ~= "table" then return { label = "", tip = "", buttons = true, opens = {} } end
	-- buttons: only an explicit false hides them (no word from the guiUpdate script yet: shown, as before)
	local out = { label = tostring(d.label or ""), tip = tostring(d.tip or ""), buttons = d.buttons ~= false }
	out.opens = M.openRequests(d.opens)
	out.vehicles = M.vehicleRequests(d.vehicles)
	out.lines = M.lineRequests(d.lines)
	out.terrain = M.terrainRequests(d.terrain)
	out.town = M.townRequests(d.town)
	return out
end

-- the vehicle requests (gui way) the guiUpdate script hands the speed control: { { id, kind, modelId, count,
-- depot, line, vehicle, mu } } (mu: a multiple unit's id in multipleUnitRep, bought instead of modelId), plain numbers only; anything else is left out rather than guessed at
M.VEHICLE_KINDS = { buy = true, duplicate = true, replace = true, sell = true }
function M.vehicleRequests(list)
	local out = {}
	if type(list) ~= "table" then return out end
	for _, r in ipairs(list) do
		if type(r) == "table" and tonumber(r.id) and M.VEHICLE_KINDS[r.kind] then
			out[#out + 1] = { id = tonumber(r.id), kind = r.kind, modelId = tonumber(r.modelId), count = tonumber(r.count),
				depot = tonumber(r.depot), line = tonumber(r.line), vehicle = tonumber(r.vehicle), mu = tonumber(r.mu) }
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
M.BUILD_TOOL_GAP = 1.5 -- s between the events: time for the menu to open and draw before the next one (each goes in turn)
-- the toolbar's own events (game_bar.tl eventName): each opens one construction menu tab and picks its first item,
-- which is how the placing tool comes up without a click; the filter alone left the menu closed (2026-11-18)
M.BUILD_MENUS = { road = "openRoad", rail = "openRail", water = "openWater", air = "openAir",
	landscaping = "openLandscaping", town = "openTown", industry = "openIndustry", roads = "openRoads",
	tracks = "openTracks", warehouses = "openWarehouses" }
function M.buildToolRequest(args)
	args = type(args) == "table" and args or {}
	local menu
	if args.menu ~= nil then
		menu = type(args.menu) == "string" and M.BUILD_MENUS[args.menu]
		if not menu then
			local names = {}
			for k in pairs(M.BUILD_MENUS) do names[#names + 1] = k end
			table.sort(names)
			return nil, "menu must be one of " .. table.concat(names, ", ")
		end
	end
	local res = args.res
	if res == nil and menu then
		if args.template ~= nil then return nil, "template needs res" end
		return { menu = menu } -- the menu alone: its first item, no filter to clear
	end
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
	return { res = res, tag = tag, seconds = sec, menu = menu }
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

-- args: id (the script event's id, e.g. a mod's UI id), name, param: a game script event as a GUI component sends
-- it (api.cmd.makeScriptingSendEventCmd), for a mod's game script that only listens to its own buttons. The same
-- checks as eventRequest on the name and the param.
function M.scriptEventRequest(args)
	args = type(args) == "table" and args or {}
	if type(args.id) ~= "string" or args.id == "" then return nil, "give the script event's id (e.g. the mod's UI id)" end
	local ev, err = M.eventRequest(args)
	if not ev then return nil, err end
	return { id = args.id, name = ev.name, param = ev.param or {} }
end

-- args: entity (id), name: a rename as the base's windows send it (api.cmd.makeEntitySetNameCmd). A station's
-- name is its group's, and the engine renames the group when given a station. Names are fixed when a thing is
-- built, in the game's language at the time, so a station built in Japanese stays "… 駅" in an English shot.
M.MAX_NAME_LEN = 200
function M.renameRequest(args)
	args = type(args) == "table" and args or {}
	local e = tonumber(args.entity)
	if e == nil or e ~= math.floor(e) or e < 0 then return nil, "give the entity (an id, e.g. from stations or entities)" end
	local name = args.name
	if type(name) ~= "string" or not name:find("%S") then return nil, "give the new name (not empty)" end
	if #name > M.MAX_NAME_LEN then return nil, "the name is longer than " .. M.MAX_NAME_LEN .. " bytes" end
	return { entity = e, name = name }
end

-- build (remote_build.lua does the game side): one construction put on the map, or ones the probe put there taken
-- away. args: res (the construction's resName), at = "x,y[,z]" or a list (no z: the terrain's height there), angle
-- (radians about the vertical, 0 by default), params (a table, over the construction's defaults), name, seed,
-- dryRun; or remove = an id or a list of ids, or removeAll. The probe names what it builds NAME_PREFIX.. unless a
-- name is given.
M.BUILD_NAME_PREFIX = "probe-build"
M.BUILD_LIMITS = { xy = 100000, z = { -1000, 5000 }, remove = 50 }
function M.buildRequest(args)
	args = type(args) == "table" and args or {}
	if args.remove ~= nil or args.removeAll then
		if args.res ~= nil or args.at ~= nil then return nil, "remove goes alone: no res or at with it" end
		if args.removeAll then
			if args.remove ~= nil then return nil, "give remove or removeAll, not both" end
			return { removeAll = true }
		end
		local list = type(args.remove) == "table" and args.remove or { args.remove }
		local ids, seen = {}, {}
		for _, v in ipairs(list) do
			local e = tonumber(v)
			if e == nil or e ~= math.floor(e) or e < 0 then return nil, "remove: not an entity id: " .. tostring(v) end
			if not seen[e] then seen[e] = true; ids[#ids + 1] = e end
		end
		if #ids == 0 then return nil, "remove: give at least one id" end
		if #ids > M.BUILD_LIMITS.remove then return nil, "remove: at most " .. M.BUILD_LIMITS.remove .. " ids at once" end
		return { remove = ids }
	end
	local res = args.res
	if type(res) ~= "string" or not res:find("%S") or res:find("[%c@]") or #res > 512 then
		return nil, "give res (the construction's resName, e.g. some_mod::/path/thing.con)"
	end
	res = res:match("^%s*(.-)%s*$")
	if args.at == nil then return nil, "give at: x,y[,z] in metres (no z: the terrain's height there)" end
	local at, err = M.numberList(args.at, 3)
	if not at then return nil, "at: " .. err end
	if #at < 2 then return nil, "at needs at least x,y" end
	local L = M.BUILD_LIMITS
	if math.abs(at[1]) > L.xy or math.abs(at[2]) > L.xy then return nil, "x and y must be within " .. L.xy end
	if at[3] ~= nil and (at[3] < L.z[1] or at[3] > L.z[2]) then
		return nil, string.format("z must be %g-%g", L.z[1], L.z[2])
	end
	local angle = args.angle == nil and 0 or tonumber(args.angle)
	if not finite(angle) or math.abs(angle) > 2 * math.pi + 1e-9 then return nil, "angle must be radians within +-2 pi" end
	local params
	if args.params ~= nil then
		if type(args.params) ~= "table" then return nil, "params must be a table (a JSON object)" end
		for k in pairs(args.params) do
			if type(k) ~= "string" then return nil, "params: keys must be names (a JSON object, not a list)" end
		end
		-- the same plain-values check as a react event's param (no userdata, functions or cycles)
		local ev, perr = M.eventRequest({ name = "params", param = args.params })
		if not ev then return nil, "params: " .. tostring(perr):gsub("^param ", "") end
		params = args.params
	end
	local seed = args.seed == nil and 1 or tonumber(args.seed)
	if not finite(seed) or seed ~= math.floor(seed) or seed < 0 or seed > 2147483647 then
		return nil, "seed must be a whole number 0-2147483647"
	end
	local name = args.name
	if name ~= nil then
		if type(name) ~= "string" or not name:find("%S") then return nil, "name must not be empty" end
		if #name > M.MAX_NAME_LEN then return nil, "the name is longer than " .. M.MAX_NAME_LEN .. " bytes" end
	end
	local modules
	if params and params.modules ~= nil then
		local mods, merr = M.buildModules(params.modules)
		if not mods then return nil, "params.modules: " .. merr end
		local p = {}
		for k, v in pairs(params) do p[k] = v end
		p.modules, params, modules = mods, p, true
	end
	for _, k in ipairs({ "fillModules", "noOwner", "removeBuildings", "joinStreets" }) do
		if args[k] ~= nil and type(args[k]) ~= "boolean" then return nil, k .. " must be true or false" end
	end
	if args.engineCheck ~= nil and type(args.engineCheck) ~= "boolean" then return nil, "engineCheck must be true or false" end
	if args.engineCheck == true and args.dryRun ~= true then
		return nil, "engineCheck goes with dryRun only (--engine-check with --dry-run)"
	end
	if args.dryRun == true and (args.removeBuildings == true or args.joinStreets == true) then
		return nil, "removeBuildings and joinStreets go with a build, not with dryRun (a dry run asks the engine nothing)"
	end
	return { res = res, x = at[1], y = at[2], z = at[3], angle = angle, params = params, seed = seed, name = name,
		dryRun = args.dryRun == true, modules = modules, fillModules = args.fillModules ~= false,
		noOwner = args.noOwner == true, removeBuildings = args.removeBuildings == true,
		joinStreets = args.joinStreets == true, engineCheck = args.engineCheck == true }
end

-- A modular construction's params.modules (a harbour's, a station's): { [slot id] = { name, variant, metadata,
-- updateScript } }, keyed by whole numbers (construction_util_serialized.d.tl ModuleUpdateFnParams.modules is
-- {integer : Module}). A JSON object can only have text keys, and the tool writes them as text, so "12" is made
-- 12 here: a module under a text key would sit on no slot. name is the module's resName; variant defaults to 0 (a
-- mod's toll station sends name and variant only, pyt_toll.script.tl); metadata and updateScript, when given, go
-- as they are (remote_build fills those left out from moduleRep). -> the modules, or nil and why.
M.BUILD_MODULE_LIMIT = 500
function M.buildModules(mods)
	if type(mods) ~= "table" then return nil, "a JSON object of slot id -> module" end
	local out, n = {}, 0
	for k, m in pairs(mods) do
		local slot = k
		if type(k) == "string" and k:match("^%d+$") then slot = tonumber(k) end
		if type(slot) ~= "number" or slot ~= math.floor(slot) or slot < 0 or slot > 2 ^ 53 then
			return nil, "slot ids are whole numbers 0 or more, not " .. tostring(k)
		end
		if out[slot] ~= nil then return nil, "slot " .. string.format("%d", slot) .. " is given twice" end
		if type(m) ~= "table" or type(m.name) ~= "string" or not m.name:find("%S") or m.name:find("%c") then
			return nil, string.format("slot %d: give the module's name (its resName, e.g. ...module)", slot)
		end
		local variant = m.variant == nil and 0 or tonumber(m.variant)
		if variant == nil or variant ~= math.floor(variant) or variant < 0 then
			return nil, string.format("slot %d: variant must be a whole number 0 or more", slot)
		end
		if m.metadata ~= nil and type(m.metadata) ~= "table" then
			return nil, string.format("slot %d: metadata must be a table", slot)
		end
		local us = m.updateScript
		if us ~= nil and (type(us) ~= "table" or type(us.fileName) ~= "string"
			or (us.params ~= nil and type(us.params) ~= "table")) then
			return nil, string.format("slot %d: updateScript must be { fileName, params }", slot)
		end
		out[slot] = { name = m.name:match("^%s*(.-)%s*$"), variant = variant, metadata = m.metadata, updateScript = us }
		n = n + 1
		if n > M.BUILD_MODULE_LIMIT then return nil, "at most " .. M.BUILD_MODULE_LIMIT .. " modules" end
	end
	if n == 0 then return nil, "give at least one module (no modules: leave modules out)" end
	return out
end

-- a module's metadata and updateScript left out, filled from the module's own desc (moduleRep.get): the rep's
-- values themselves, so a construction that fills them on its own gets the same. desc: { metadata, updateScript }.
-- -> the names of the fields filled, in order
function M.fillModule(mod, desc)
	local filled = {}
	if type(desc) ~= "table" then return filled end
	for _, k in ipairs({ "metadata", "updateScript" }) do
		if mod[k] == nil and desc[k] ~= nil then
			mod[k] = desc[k]
			filled[#filled + 1] = k
		end
	end
	return filled
end

-- the modules as the answer shows them: slot, name, variant and what was filled (metadata and scripts can be
-- large and hold engine values the answer's JSON need not carry). Sorted by slot.
function M.moduleSummary(mods, filled)
	local slots = {}
	for k in pairs(mods or {}) do slots[#slots + 1] = k end
	table.sort(slots)
	local out = {}
	for _, k in ipairs(slots) do
		local m = mods[k]
		out[#out + 1] = { slot = k, name = m.name, variant = m.variant, metadata = m.metadata ~= nil,
			updateScript = m.updateScript ~= nil, filled = filled and filled[k] and #filled[k] > 0 and M.array(filled[k]) or nil }
	end
	return M.array(out)
end

-- water (read only): the water level and, at a point or on a grid, whether it is water and the terrain's height
-- there, to find a shore for a harbour. args: at = "x,y" or grid = "x0,y0,x1,y1,step" (x0 <= x1, y0 <= y1; at most
-- WATER_MAX_POINTS points). -> { points = { { x, y } }, grid = { x0, y0, x1, y1, step, nx, ny } or nil }
M.WATER_MAX_POINTS = 400
M.WATER_MIN_STEP = 0.1 -- metres: a smaller step makes the point count overflow before the limit is checked
-- a way on the map made one long: { x, y } or nil when it has no length (or is not finite). Scaled by its larger part first, so
-- that a huge dx,dy (1e300) does not overflow into a way of length 0
local function unitWay(x, y)
	-- (NaN checked first: math.max(nan, 1) is 1 in LuaJIT)
	if not (finite(x) and finite(y)) then return nil end
	local m = math.max(math.abs(x), math.abs(y))
	if not (m >= M.ROAD_MIN_DIR) then return nil end
	x, y = x / m, y / m
	local l = math.sqrt(x * x + y * y)
	return { x = x / l, y = y / l }
end
M.unitWay = unitWay

-- road: one straight road piece from one point to another (remote_build.lua B.road). snap: an end within this
-- many metres of a road node joins it (0: never)
M.ROAD_LIMITS = { snap = 20, defaultSnap = 5, minLength = 1, maxLength = 2000 }
function M.roadRequest(args)
	args = type(args) == "table" and args or {}
	local L = M.BUILD_LIMITS
	local ends = {}
	for _, k in ipairs({ "from", "to" }) do
		if args[k] == nil then return nil, "give " .. k .. ": x,y[,z] in metres (no z: the terrain's height there)" end
		local p, err = M.numberList(args[k], 3)
		if not p then return nil, k .. ": " .. err end
		if #p < 2 then return nil, k .. " needs at least x,y" end
		if math.abs(p[1]) > L.xy or math.abs(p[2]) > L.xy then return nil, k .. ": x and y must be within " .. L.xy end
		if p[3] ~= nil and (p[3] < L.z[1] or p[3] > L.z[2]) then
			return nil, string.format("%s: z must be %g-%g", k, L.z[1], L.z[2])
		end
		ends[k] = p
	end
	local R = M.ROAD_LIMITS
	local flat = math.sqrt((ends.to[1] - ends.from[1]) ^ 2 + (ends.to[2] - ends.from[2]) ^ 2)
	if flat > R.maxLength then
		return nil, string.format("from and to are %.0f m apart: at most %g m for one straight piece", flat, R.maxLength)
	end
	local snap = args.snap == nil and R.defaultSnap or tonumber(args.snap)
	if not finite(snap) or snap < 0 or snap > R.snap then return nil, "snap must be 0-" .. R.snap .. " metres" end
	local t = args.type
	if t ~= nil then
		if type(t) ~= "string" or not t:find("%S") or t:find("[%c@]") or #t > 512 then
			return nil, "type must be a street template's resName (or a base road's file name, e.g. town_new_small)"
		end
		t = t:match("^%s*(.-)%s*$")
	end
	-- engineCheck: the dry run asks the engine (makeProposalData); only with a dry run (a build is the engine's own)
	if args.engineCheck == true and args.dryRun ~= true then
		return nil, "engineCheck goes with dryRun only (--engine-check with --dry-run)"
	end
	for _, k in ipairs({ "removeFields", "removeBuildings" }) do
		if args[k] ~= nil and type(args[k]) ~= "boolean" then return nil, k .. " must be true or false" end
	end
	-- a curved piece: the way the road goes at either end (tangentFrom / tangentTo: dx,dy, a direction only, both
	-- pointing the way from -> to), or the way of the road already at a joined end (alignToEdge: from, to or both;
	-- alignEdge: the piece to follow where a node has more than one)
	local dirs = {}
	for _, k in ipairs({ "tangentFrom", "tangentTo" }) do
		if args[k] ~= nil then
			local v, verr = M.numberList(args[k], 2)
			if not v then return nil, k .. ": " .. verr end
			if #v ~= 2 then return nil, k .. " needs dx,dy" end
			if not unitWay(v[1], v[2]) then
				return nil, k .. ": a direction of length 0 (dx,dy both about 0) gives no way"
			end
			dirs[k] = v
		end
	end
	local align = args.alignToEdge
	if align ~= nil and align ~= "from" and align ~= "to" and align ~= "both" then
		return nil, "alignToEdge must be from, to or both"
	end
	local alignFrom, alignTo = align == "from" or align == "both", align == "to" or align == "both"
	if alignFrom and dirs.tangentFrom then return nil, "tangentFrom and alignToEdge " .. align .. " both set the from end's way: give one" end
	if alignTo and dirs.tangentTo then return nil, "tangentTo and alignToEdge " .. align .. " both set the to end's way: give one" end
	local alignEdge
	if args.alignEdge ~= nil then
		if align == nil then return nil, "alignEdge goes with alignToEdge only" end
		local v, verr = M.numberList(type(args.alignEdge) == "number" and { args.alignEdge } or args.alignEdge, 2)
		if not v then return nil, "alignEdge: " .. verr end
		if #v == 0 then return nil, "alignEdge: give a piece's entity id" end
		for _, id in ipairs(v) do
			if id ~= math.floor(id) or id < 0 or id > 2 ^ 31 then return nil, "alignEdge must be pieces' entity ids (0 or more)" end
		end
		if v[2] == v[1] then return nil, "alignEdge names piece " .. v[1] .. " twice: give it once" end
		alignEdge = v
	end
	return { from = ends.from, to = ends.to, snap = snap, type = t, dryRun = args.dryRun == true,
		engineCheck = args.engineCheck == true, removeFields = args.removeFields == true,
		removeBuildings = args.removeBuildings == true, tangentFrom = dirs.tangentFrom, tangentTo = dirs.tangentTo,
		alignFrom = alignFrom, alignTo = alignTo, alignEdge = alignEdge }
end

-- a direction shorter than this is no direction (a tangent given as 0,0, or a piece's tangent that reads as 0)
M.ROAD_MIN_DIR = 1e-6
-- the most a curved piece's end may turn off its chord (degrees): past a right angle the curve runs back behind
-- its own end (a loop or an S folded on itself), which nothing here has seen the engine take
M.ROAD_MAX_TURN = 90

-- the tangents of one road piece from a to b ({ x, y, z } each), as a cubic Hermite curve (BASE_EDGE tangent0 at
-- node0, tangent1 at node1, both the way a -> b). dir0 / dir1: the way at each end on the map ({ dx, dy }, any
-- length) or nil (the chord's). Each tangent is as long on the map as the chord is (the usual length for a
-- Hermite piece; a straight piece's tangents are its chord), and climbs the chord's whole rise (dz): the height
-- runs evenly from a to b as before. -> t0, t1, { turn0, turn1 } (degrees off the chord on the map), or nil and
-- why: no chord on the map to measure a curve by, or an end turned more than ROAD_MAX_TURN.
function M.roadTangents(a, b, dir0, dir1)
	local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
	local flat = math.sqrt(dx * dx + dy * dy)
	if dir0 == nil and dir1 == nil then
		return { x = dx, y = dy, z = dz }, { x = dx, y = dy, z = dz }, { 0, 0 }
	end
	if flat < 1 then return nil, string.format("the ends are %.2f m apart on the map: a curved piece needs at least 1 m", flat) end
	local out, turns = {}, {}
	for i, d in ipairs({ dir0 or false, dir1 or false }) do
		if not d then
			out[i], turns[i] = { x = dx, y = dy, z = dz }, 0
		else
			local u = unitWay(d[1], d[2])
			if not u then return nil, (i == 1 and "from" or "to") .. ": a direction of length 0 (or not finite) gives no way" end
			local ux, uy = u.x, u.y
			local cos = math.max(-1, math.min(1, (ux * dx + uy * dy) / flat))
			local turn = math.deg(math.acos(cos))
			if turn > M.ROAD_MAX_TURN + 1e-9 then
				return nil, string.format("%s: the way there (%.3f,%.3f) turns %.1f degrees off the line from -> to: at most %g " ..
					"(further the curve runs back behind its end); %s", i == 1 and "from" or "to", ux, uy, turn,
					M.ROAD_MAX_TURN, "tangents point the way from -> to at both ends")
			end
			out[i], turns[i] = { x = ux * flat, y = uy * flat, z = dz }, turn
		end
	end
	return out[1], out[2], turns
end

-- the angle in degrees between two ways on the map ({ x, y } each, any length), or nil when one has no length
function M.angleDeg(u, v)
	u, v = unitWay(u.x, u.y), unitWay(v.x, v.y)
	if not (u and v) then return nil end
	return math.deg(math.acos(math.max(-1, math.min(1, u.x * v.x + u.y * v.y))))
end

-- road --inspect-node (read only): one node's id
function M.roadInspectRequest(args)
	args = type(args) == "table" and args or {}
	local n = tonumber(args.node)
	if n == nil or n ~= math.floor(n) or n < 0 or n > 2 ^ 31 then return nil, "node must be a node's entity id (0 or more)" end
	return { node = n }
end

function M.waterRequest(args)
	args = type(args) == "table" and args or {}
	if (args.at == nil) == (args.grid == nil) then return nil, "give at (x,y) or grid (x0,y0,x1,y1,step)" end
	local L = M.BUILD_LIMITS.xy
	if args.at ~= nil then
		local at, err = M.numberList(args.at, 2)
		if not at then return nil, "at: " .. err end
		if #at ~= 2 then return nil, "at needs x,y" end
		if math.abs(at[1]) > L or math.abs(at[2]) > L then return nil, "x and y must be within " .. L end
		return { points = { { x = at[1], y = at[2] } } }
	end
	local g, err = M.numberList(args.grid, 5)
	if not g then return nil, "grid: " .. err end
	if #g ~= 5 then return nil, "grid needs x0,y0,x1,y1,step" end
	local x0, y0, x1, y1, step = g[1], g[2], g[3], g[4], g[5]
	for i = 1, 4 do if math.abs(g[i]) > L then return nil, "grid: x and y must be within " .. L end end
	if x1 < x0 or y1 < y0 then return nil, "grid: x0 <= x1 and y0 <= y1" end
	if step < M.WATER_MIN_STEP then return nil, "grid: step must be at least " .. M.WATER_MIN_STEP .. " m" end
	local nx, ny = math.floor((x1 - x0) / step + 1e-9) + 1, math.floor((y1 - y0) / step + 1e-9) + 1
	if nx * ny > M.WATER_MAX_POINTS then
		return nil, string.format("grid: %d x %d = %d points, at most %d (a larger step or a smaller box)",
			nx, ny, nx * ny, M.WATER_MAX_POINTS)
	end
	local pts = {}
	for j = 0, ny - 1 do
		for i = 0, nx - 1 do pts[#pts + 1] = { x = x0 + i * step, y = y0 + j * step } end
	end
	return { points = pts, grid = { x0 = x0, y0 = y0, x1 = x1, y1 = y1, step = step, nx = nx, ny = ny } }
end

-- a grid's points (row by row, y0 first) as text rows: "~" water, "." land, "?" not read. -> a list of strings
function M.waterRows(points, nx)
	local rows, row = {}, {}
	for _, p in ipairs(points) do
		row[#row + 1] = p.onWater == true and "~" or p.onWater == false and "." or "?"
		if #row == nx then rows[#rows + 1] = table.concat(row); row = {} end
	end
	if #row > 0 then rows[#rows + 1] = table.concat(row) end
	return M.array(rows)
end

---------------------------------------------------------------------------------------------------------------------
-- terrain: a rectangle's ground heights replaced (flat, or a uniform slope along x or y), the rest of the map as it
-- is. The engine's way is one command with a whole map (api.cmd.makeWorldReplaceTerrainCmd, as the map editor's
-- generate and import): the map is copied from the game (makeMapFromGame without towns: a map listing towns asserts
-- in terrain_util::ReplaceTerrain), the heights inside the rectangle changed in the copied table, and the whole
-- table assigned back (GameMap.heightmap hands out a copy on each read: an element written into it is lost).
-- The heightmap: (numTiles * 256 / step + 1) points per row, point (i, j) at index j * w + i + 1, i along x from the
-- map's min corner, heights in metres.

M.TERRAIN_MAX_SIDE = 1024 -- metres per side: at most 257 x 257 points of 4 m
M.TERRAIN_BLEND = 16 -- metres inside the rectangle's edge over which the new heights blend into the old (4 points)
M.TERRAIN_MAX_PCT = 100
-- the whole map's heightmap is copied into a Lua table: at most this many points (a small map, 32 x 32 tiles, has
-- 2049^2 = 4.2 M; a medium one 7.9 M), counted from the terrain's bounding box before anything is copied
M.TERRAIN_MAX_MAP_POINTS = 4500000
M.TERRAIN_STEP = 4 -- metres between heightmap points (GameMap.resolution.x in the base maps)
-- inside the engine's range (-100 .. 3176.75 m: offsetZ -100 plus 65535 steps of 0.05 m), as UTG keeps its heights
M.TERRAIN_HEIGHTS = { -99, 3170 }
-- what the guiUpdate script or the recipe needs for a replacement (looked at with type(), never called to look)
M.TERRAIN_NEEDS = { "api.engine.terrain.makeMapFromGame", "api.engine.terrain.getBoundingBox", "api.type.Map.new",
	"api.cmd.makeWorldReplaceTerrainCmd", "api.cmd.sendCommand", "api.res.getBaseConfig", "api.engine.util.getWorld" }
-- also reported by terrainApi: what the base map editor calls round it, and what later steps (towns) would need
M.TERRAIN_LOOKS = { "api.gui.map.setMapSeedText", "api.gui.map.reloadMaterialIndexManagerPipeline",
	"api.engine.mapgen.createTowns", "api.engine.mapgen.createIndustries", "api.cmd.makeTownCreateCmd",
	"api.gui.game.isMapEditor", "api.engine.terrain.getHeightAt",
	"api.type.Map.Town.new", "api.cmd.makeTownUpdateCargoNeedsCmd" } -- (the town command's: remote_town.lua)

-- "a.b.c" under the global table: the value there, nil where a step is missing; nothing called
local function valueAt(path, root)
	local v = root or _G
	for part in path:gmatch("[^%.]+") do
		if type(v) ~= "table" and type(v) ~= "userdata" then return nil end
		local ok, nv = pcall(function() return v[part] end)
		if not ok then return nil end
		v = nv
	end
	return v
end

-- "a.b.c": its type() ("nil" where a step is missing), nothing called
function M.typeAt(path, root)
	return type(valueAt(path, root))
end

-- can it be called: a function, or a table / userdata with a __call (the engine's api entries are such tables, so
-- type() says "table" for them). Looked at, never called. Without getmetatable, a table or userdata counts as callable.
function M.isCallable(v)
	local t = type(v)
	if t == "function" then return true end
	if t ~= "table" and t ~= "userdata" then return false end
	if type(getmetatable) ~= "function" then return true end
	local ok, mt = pcall(getmetatable, v)
	if not ok then return true end
	if type(mt) ~= "table" then return false end
	local okC, c = pcall(function() return mt.__call end)
	return okC and c ~= nil
end

-- { [path] = type } and { [path] = callable } for the needs and the looks; third value: the needs missing (a list,
-- empty when all are there). Missing means nil: the engine's api entries are callable tables whose metatable cannot
-- be read from outside (isCallable is false for them), so a callable check here would wrongly report them missing.
function M.terrainFunctions(root)
	local out, callable, missing = {}, {}, {}
	for _, list in ipairs({ M.TERRAIN_NEEDS, M.TERRAIN_LOOKS }) do
		for _, p in ipairs(list) do
			local v = valueAt(p, root)
			out[p], callable[p] = type(v), M.isCallable(v)
		end
	end
	for _, p in ipairs(M.TERRAIN_NEEDS) do
		if out[p] == "nil" then missing[#missing + 1] = p end
	end
	return out, callable, missing
end

M.TERRAIN_VIAS = { auto = true, update = true, gui = true }

-- args: rect = "x0,y0,x1,y1" (x0 < x1, y0 < y1, metres), and one of flat = z, slopeX = pct, slopeY = pct (with
-- base = the height at x0 / y0, the rectangle's west / south edge; pct > 0 rises toward x1 / y1); blend (metres,
-- default TERRAIN_BLEND, 0 = a sharp edge), dryRun, via (auto = gui, update, gui), inGame (outside the map editor:
-- only when asked for). -> the request, or nil and why
function M.terrainRequest(args)
	args = type(args) == "table" and args or {}
	if args.rect == nil then return nil, "give rect (x0,y0,x1,y1)" end
	local rc, err = M.numberList(args.rect, 4)
	if not rc then return nil, "rect: " .. err end
	if #rc ~= 4 then return nil, "rect needs x0,y0,x1,y1" end
	local L = M.BUILD_LIMITS.xy
	for i = 1, 4 do if math.abs(rc[i]) > L then return nil, "rect: x and y must be within " .. L end end
	local x0, y0, x1, y1 = rc[1], rc[2], rc[3], rc[4]
	if not (x1 > x0 and y1 > y0) then return nil, "rect: x0 < x1 and y0 < y1" end
	local S = M.TERRAIN_MAX_SIDE
	if x1 - x0 > S or y1 - y0 > S then
		return nil, string.format("rect: %g x %g m, at most %d m per side", x1 - x0, y1 - y0, S)
	end
	local given = {}
	for _, k in ipairs({ "flat", "slopeX", "slopeY" }) do if args[k] ~= nil then given[#given + 1] = k end end
	if #given ~= 1 then return nil, "give one of flat (a height), slopeX or slopeY (a percentage, with base)" end
	local r = { rect = { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }, mode = given[1], dryRun = args.dryRun == true }
	local v = tonumber(args[r.mode])
	if not finite(v) then return nil, r.mode .. " must be a finite number" end
	if r.mode == "flat" then
		if args.base ~= nil then return nil, "flat is the height itself: no base" end
		r.z = v
	else
		if math.abs(v) > M.TERRAIN_MAX_PCT then return nil, r.mode .. ": at most " .. M.TERRAIN_MAX_PCT .. " %" end
		local b = tonumber(args.base)
		if not finite(b) then return nil, "give base (the height at the rectangle's " .. (r.mode == "slopeX" and "x0" or "y0") .. " edge)" end
		r.pct, r.base = v, b
	end
	local blend = args.blend
	-- not given: TERRAIN_BLEND, or a quarter of the shorter side on a small rectangle
	if blend == nil then blend = math.min(M.TERRAIN_BLEND, math.min(x1 - x0, y1 - y0) / 4) end
	blend = tonumber(blend)
	if not finite(blend) or blend < 0 then return nil, "blend must be a number of metres >= 0" end
	if 2 * blend > math.min(x1 - x0, y1 - y0) then
		return nil, string.format("blend %g m is more than half the rectangle's shorter side", blend)
	end
	r.blend = blend
	local via = args.via == nil and "auto" or args.via
	if not M.TERRAIN_VIAS[via] then return nil, "via must be auto, update or gui" end
	r.via = via
	if args.inGame ~= nil and type(args.inGame) ~= "boolean" then return nil, "inGame must be true or false" end
	r.inGame = args.inGame == true
	local lo, hi = M.terrainRange(r)
	local H = M.TERRAIN_HEIGHTS
	if lo < H[1] or hi > H[2] then
		return nil, string.format("the heights asked for run %g .. %g m; the engine's range is kept to %g .. %g m",
			lo, hi, H[1], H[2])
	end
	return r
end

-- the height asked for at x, y (before the blend)
function M.terrainTarget(r, x, y)
	if r.mode == "flat" then return r.z end
	if r.mode == "slopeX" then return r.base + r.pct / 100 * (x - r.rect.x0) end
	return r.base + r.pct / 100 * (y - r.rect.y0)
end

-- the lowest and highest height asked for in the rectangle (a plane: at its corners)
function M.terrainRange(r)
	local c = r.rect
	local lo, hi = math.huge, -math.huge
	for _, p in ipairs({ { c.x0, c.y0 }, { c.x1, c.y0 }, { c.x0, c.y1 }, { c.x1, c.y1 } }) do
		local h = M.terrainTarget(r, p[1], p[2])
		if h < lo then lo = h end
		if h > hi then hi = h end
	end
	return lo, hi
end

-- how much of the new height a point takes: 0 on the rectangle's edge (so the edge stays as it is, and the land
-- outside meets it without a step), 1 from blend metres inside it on; a sharp edge (blend 0) is 1 everywhere
function M.terrainWeight(r, x, y)
	if r.blend <= 0 then return 1 end
	local c = r.rect
	local d = math.min(x - c.x0, c.x1 - x, y - c.y0, c.y1 - y)
	if d <= 0 then return 0 end
	return math.min(1, d / r.blend)
end

-- the map's grid: info = { minX, minY, maxX, maxY (the terrain's bounding box), step, w, h (points per row and
-- column) }. -> the grid points inside the rectangle { i0, i1, j0, j1, nx, ny, points, x0, y0, x1, y1 (the first
-- and last points' positions) }, or nil and why (the rectangle off the map, no point in it)
function M.terrainGrid(r, info)
	local c = r.rect
	local eps = 1e-6
	if c.x0 < info.minX - eps or c.y0 < info.minY - eps or c.x1 > info.maxX + eps or c.y1 > info.maxY + eps then
		return nil, string.format("rect is not inside the map (%g,%g .. %g,%g)", info.minX, info.minY, info.maxX, info.maxY)
	end
	local s = info.step
	local i0, i1 = math.ceil((c.x0 - info.minX) / s - eps), math.floor((c.x1 - info.minX) / s + eps)
	local j0, j1 = math.ceil((c.y0 - info.minY) / s - eps), math.floor((c.y1 - info.minY) / s + eps)
	i0, j0 = math.max(i0, 0), math.max(j0, 0)
	i1, j1 = math.min(i1, info.w - 1), math.min(j1, info.h - 1)
	if i1 < i0 or j1 < j0 then return nil, "no grid point of the map (every " .. s .. " m) lies in rect" end
	local nx, ny = i1 - i0 + 1, j1 - j0 + 1
	return { i0 = i0, i1 = i1, j0 = j0, j1 = j1, nx = nx, ny = ny, points = nx * ny, step = s,
		x0 = info.minX + i0 * s, y0 = info.minY + j0 * s, x1 = info.minX + i1 * s, y1 = info.minY + j1 * s }
end

-- the new heights written into heights (the copied table, in place) at the grid's points. -> { changed (points
-- that moved more than 1 mm), before = { min, max }, written = { min, max } }
function M.terrainFill(heights, grid, r, info)
	local s, w = info.step, info.w
	local changed = 0
	local bLo, bHi, wLo, wHi = math.huge, -math.huge, math.huge, -math.huge
	for j = grid.j0, grid.j1 do
		local y = info.minY + j * s
		local row = j * w + 1
		for i = grid.i0, grid.i1 do
			local x = info.minX + i * s
			local k = row + i
			local old = heights[k]
			local t = M.terrainWeight(r, x, y)
			local new = old + (M.terrainTarget(r, x, y) - old) * t
			heights[k] = new
			if math.abs(new - old) > 0.001 then changed = changed + 1 end
			if old < bLo then bLo = old end
			if old > bHi then bHi = old end
			if new < wLo then wLo = new end
			if new > wHi then wHi = new end
		end
	end
	return { changed = changed, before = { min = bLo, max = bHi }, written = { min = wLo, max = wHi } }
end

-- points to read back after the replacement (getHeightAt): the middle and the corners of the part that takes the
-- full new height (blend metres in from the edge), each on a grid point; expected = what the table holds there.
-- -> a list of { x, y, expected }
function M.terrainSamples(heights, grid, r, info)
	local s, c = info.step, r.rect
	local function snapI(x) return math.max(grid.i0, math.min(grid.i1, math.floor((x - info.minX) / s + 0.5))) end
	local function snapJ(y) return math.max(grid.j0, math.min(grid.j1, math.floor((y - info.minY) / s + 0.5))) end
	local b = r.blend
	local xs = { (c.x0 + c.x1) / 2, c.x0 + b, c.x1 - b, c.x0 + b, c.x1 - b }
	local ys = { (c.y0 + c.y1) / 2, c.y0 + b, c.y0 + b, c.y1 - b, c.y1 - b }
	local out, seen = {}, {}
	for n = 1, #xs do
		local i, j = snapI(xs[n]), snapJ(ys[n])
		local k = j * info.w + i + 1
		if not seen[k] then
			seen[k] = true
			out[#out + 1] = { x = info.minX + i * s, y = info.minY + j * s, expected = heights[k] }
		end
	end
	return out
end

-- the terrain requests the guiUpdate script hands the speed control (the gui way): { { id, kind = "probe" } } to look
-- at the functions there, or { { id, kind = "apply", args = <terrainRequest's args> } }; checked again here,
-- malformed ones left out
function M.terrainRequests(list)
	local out = {}
	if type(list) ~= "table" then return out end
	for _, r in ipairs(list) do
		local id = type(r) == "table" and tonumber(r.id)
		if id and r.kind == "probe" then
			out[#out + 1] = { id = id, kind = "probe" }
		elseif id and r.kind == "apply" and type(r.args) == "table" and M.terrainRequest(r.args) then
			out[#out + 1] = { id = id, kind = "apply", args = r.args }
		end
	end
	return out
end

-- the number of heightmap points of a map whose terrain's bounding box is box ({ min = { x, y }, max = { x, y } }).
-- -> n, or nil when the box cannot be read
function M.terrainMapPoints(box)
	local lo, hi = type(box) == "table" and box.min, type(box) == "table" and box.max
	local x0, y0 = tonumber(lo and lo.x), tonumber(lo and lo.y)
	local x1, y1 = tonumber(hi and hi.x), tonumber(hi and hi.y)
	if not (x0 and y0 and x1 and y1) or x1 < x0 or y1 < y0 then return nil end
	local s = M.TERRAIN_STEP
	return (math.floor((x1 - x0) / s + 0.5) + 1) * (math.floor((y1 - y0) / s + 0.5) + 1)
end

---------------------------------------------------------------------------------------------------------------------
-- town: one town put on the map, as the map editor's towns window and import do (map_editor.tl makeTowns):
-- api.engine.mapgen.createTowns(seed, { GameMap.Town }) makes the proposal (TownInfo: initialLandUseCapacities and
-- the streets' angle the engine picks for the place), api.cmd.makeTownCreateCmd(result.toAdd) builds it. The
-- town's first cargo needs are handed over twice: as GameMap.Town.landUse2CargoNeeds (category names per land
-- use, as the base import and Advanced Town Placement pass them) and, when the new town does not show them,
-- api.cmd.makeTownUpdateCargoNeedsCmd with cargo type ids per district (as Real World Map Importer does: a town
-- made by a script gets no first demand from the game, and without one it never asks for goods).

M.TOWN_SIZE = { 0.1, 2.5 } -- sizeFactors (each district): the import's default is 1; ATP uses 0.34 .. 2.3, RWMI 0.4 .. 2.2
M.TOWN_MAX_CAPACITY = 1000 -- the average initial capacity per district, when given (ATP: 220 * its size factor, up to ~500)
M.TOWN_NAME_MAX = 64
M.TOWN_MAX_NEEDS = 3 -- categories per land use
M.TOWN_LAND_USES = { "res", "com", "ind" } -- in the engine's district order (residential, commercial, industrial)
M.TOWN_LAND_USE_TYPE = { res = "RESIDENTIAL", com = "COMMERCIAL", ind = "INDUSTRIAL" }
-- what the work needs where it runs (nil is missing; see terrainFunctions on callable tables)
M.TOWN_NEEDS = { "api.engine.mapgen.createTowns", "api.type.Map.Town.new", "api.cmd.makeTownCreateCmd",
	"api.cmd.sendCommand", "api.type.Vec2f.new" }
-- also reported: the needs command, sent from the guiUpdate state after the town is made (without it the town may
-- have no first needs), and the map check
M.TOWN_LOOKS = { "api.cmd.makeTownUpdateCargoNeedsCmd", "api.engine.terrain.isValidCoordinate" }
M.TOWN_VIAS = M.TERRAIN_VIAS

-- the needs as given: nil = auto (the economy's lowest tier, one for the shops and one for the industry, as ATP),
-- false or "none" = none, a table { res = { "fish" }, com = ..., ind = ... } or a text "com:fish,ind:planks"
-- (land use : category, comma separated). -> "auto" | "none" | { res = {...}, com = {...}, ind = {...} }, or nil
-- and why
function M.townNeedsArg(v)
	if v == nil or v == "auto" then return "auto" end
	if v == false or v == "none" then return "none" end
	local out, n = { res = {}, com = {}, ind = {} }, 0
	local function add(lu, cat)
		lu = tostring(lu):lower()
		if out[lu] == nil then return "needs: the land use must be res, com or ind (not " .. lu .. ")" end
		if type(cat) ~= "string" or not cat:match("^[%w_]+$") then
			return "needs: a category is a name such as fish or planks (not " .. tostring(cat) .. ")"
		end
		for _, c in ipairs(out[lu]) do if c == cat then return nil end end
		if #out[lu] >= M.TOWN_MAX_NEEDS then return "needs: at most " .. M.TOWN_MAX_NEEDS .. " per land use" end
		table.insert(out[lu], cat)
		n = n + 1
	end
	if type(v) == "string" then
		for part in (v .. ","):gmatch("([^,]*),") do
			local lu, cat = part:match("^%s*(%a+)%s*:%s*([^%s]+)%s*$")
			if not lu then return nil, "needs: give land use:category, comma separated (com:fish,ind:planks)" end
			local err = add(lu, cat)
			if err then return nil, err end
		end
	elseif type(v) == "table" then
		for k, list in pairs(v) do
			if type(list) ~= "table" then return nil, "needs." .. tostring(k) .. ": a list of category names" end
			for _, cat in ipairs(list) do
				local err = add(k, cat)
				if err then return nil, err end
			end
		end
	else
		return nil, "needs: auto, none, a text com:fish,ind:planks or a table"
	end
	if n == 0 then return nil, "needs: none given (for none write none)" end
	return out
end

-- args: at = "x,y" or a list (metres), name, size (each district's size factor, default 1), capacity (the
-- average initial capacity per district; none: the engine's for the place), needs (townNeedsArg), dryRun, via (auto
-- = gui, update, gui), inGame (outside the map editor: only when asked for). -> the request, or nil and why
function M.townRequest(args)
	args = type(args) == "table" and args or {}
	if args.at == nil then return nil, "give at (x,y in metres)" end
	local p, err = M.numberList(args.at, 2)
	if not p then return nil, "at: " .. err end
	if #p ~= 2 or not finite(p[1]) or not finite(p[2]) then return nil, "at needs x,y (finite numbers)" end
	local L = M.BUILD_LIMITS.xy
	if math.abs(p[1]) > L or math.abs(p[2]) > L then return nil, "at: x and y must be within " .. L end
	local name = type(args.name) == "string" and args.name:match("^%s*(.-)%s*$") or ""
	if name == "" then return nil, "give name (the town's name)" end
	if #name > M.TOWN_NAME_MAX then return nil, "name: at most " .. M.TOWN_NAME_MAX .. " bytes" end
	local r = { at = { x = p[1], y = p[2] }, name = name, dryRun = args.dryRun == true }
	local size = args.size == nil and 1 or tonumber(args.size)
	if not finite(size) or size < M.TOWN_SIZE[1] or size > M.TOWN_SIZE[2] then
		return nil, string.format("size must be a number from %g to %g (the size factor; 1 as the base import)", M.TOWN_SIZE[1], M.TOWN_SIZE[2])
	end
	r.size = size
	if args.capacity ~= nil then
		local c = tonumber(args.capacity)
		if not finite(c) or c < 1 or c > M.TOWN_MAX_CAPACITY or c ~= math.floor(c) then
			return nil, "capacity must be a whole number from 1 to " .. M.TOWN_MAX_CAPACITY
		end
		r.capacity = c
	end
	local needs, nerr = M.townNeedsArg(args.needs)
	if not needs then return nil, nerr end
	r.needs = needs
	local via = args.via == nil and "auto" or args.via
	if not M.TOWN_VIAS[via] then return nil, "via must be auto, update or gui" end
	r.via = via
	if args.inGame ~= nil and type(args.inGame) ~= "boolean" then return nil, "inGame must be true or false" end
	r.inGame = args.inGame == true
	return r
end

-- the economy's cargo categories ({ [name] = { tier, landUses } }, landUses as LandUseType values or names) and the
-- cargo types ({ [id] = category }) -> the needs per land use: { res, com, ind = { names } } and the cargo type
-- ids per district { { res ids }, { com ids }, { ind ids } } (makeTownUpdateCargoNeedsCmd's form), or nil and why.
-- want: townNeedsArg's. landUseType: { RESIDENTIAL = 0, ... } (the engine's enum).
function M.townNeedsPlan(want, categories, cargoCategory, landUseType)
	local names = { res = {}, com = {}, ind = {} }
	local ids = { {}, {}, {} }
	if want == "none" then return names, ids end
	local idOf = {}
	for id, cat in pairs(cargoCategory or {}) do
		id = tonumber(id)
		if id and type(cat) == "string" and cat ~= "" and (idOf[cat] == nil or id < idOf[cat]) then idOf[cat] = id end
	end
	local luOf = {}
	for _, k in ipairs(M.TOWN_LAND_USES) do
		local v = landUseType and landUseType[M.TOWN_LAND_USE_TYPE[k]]
		if v ~= nil then luOf[tostring(v)] = k end
		luOf[M.TOWN_LAND_USE_TYPE[k]] = k
	end
	-- a category's land uses (as keys of names)
	local function usesOf(c)
		local out = {}
		for _, v in ipairs(type(c) == "table" and type(c.landUses) == "table" and c.landUses or {}) do
			local k = luOf[tostring(v)] or luOf[tostring(v):upper()]
			if k then out[k] = true end
		end
		return out
	end
	if want == "auto" then
		-- one for the shops and one for the industry, the first of the lowest tier by name (ATP picks one of each at
		-- random; here the same every time)
		local pools = { com = {}, ind = {} }
		for cat, c in pairs(categories or {}) do
			if type(c) == "table" and tonumber(c.tier) == 0 and idOf[cat] then
				for k in pairs(usesOf(c)) do if pools[k] then table.insert(pools[k], cat) end end
			end
		end
		for k, list in pairs(pools) do
			table.sort(list)
			if list[1] then names[k] = { list[1] } end
		end
	else
		for _, k in ipairs(M.TOWN_LAND_USES) do
			for _, cat in ipairs(want[k] or {}) do
				local c = categories and categories[cat]
				if c == nil then
					local known = {}
					for name in pairs(categories or {}) do known[#known + 1] = name end
					table.sort(known)
					return nil, string.format("needs: no cargo category %q in this game's economy (%s)", cat, table.concat(known, ", "))
				end
				if not idOf[cat] then return nil, string.format("needs: no cargo type of category %q", cat) end
				table.insert(names[k], cat)
			end
		end
	end
	for i, k in ipairs(M.TOWN_LAND_USES) do
		for _, cat in ipairs(names[k]) do table.insert(ids[i], idOf[cat]) end
	end
	return names, ids
end

-- a town's cargo needs as the TOWN component holds them (per district a list of { id, weight } pairs, or ids)
-- -> { { ids }, { ids }, { ids } }
function M.townNeedIds(cargoNeeds)
	local out = { {}, {}, {} }
	for k = 1, 3 do
		local list = M.at(cargoNeeds, k)
		local n = M.size(list) or 0
		for i = 1, n do
			local v = M.at(list, i)
			local id = tonumber(v) or tonumber(M.at(v, 1))
			if id then table.insert(out[k], id) end
		end
	end
	return out
end

-- the ids as whole numbers where the Lua has them (the GUI save data may hand them back as floats; the command takes
-- CargoTypeIds) -> { { ids }, { ids }, { ids } }
function M.townIntIds(ids)
	local out = {}
	for k = 1, 3 do
		out[k] = {}
		for _, id in ipairs((ids or {})[k] or {}) do
			out[k][#out[k] + 1] = math.tointeger and math.tointeger(id) or id
		end
	end
	return out
end

-- does have hold every id of want, per district
function M.townNeedsMet(have, want)
	for k = 1, 3 do
		local set = {}
		for _, id in ipairs((have or {})[k] or {}) do set[id] = true end
		for _, id in ipairs((want or {})[k] or {}) do if not set[id] then return false end end
	end
	return true
end

-- the engine's initial capacities scaled to an average of capacity per district, its districts' proportions kept
-- (as ATP rescales createTowns' proposal). -> the list, or nil when the engine's add up to nothing
function M.townScaledCapacities(caps, capacity)
	local total = 0
	for k = 1, 3 do total = total + (tonumber(caps[k]) or 0) end
	if total <= 0 then return nil end
	local avg = total / 3
	local out = {}
	for k = 1, 3 do out[k] = math.floor(capacity * (tonumber(caps[k]) or 0) / avg + 0.5) end
	return out
end

-- the town requests the guiUpdate script hands the speed control (the gui way): { { id, kind = "apply", args,
-- propose } }; checked again here, malformed ones left out
function M.townRequests(list)
	local out = {}
	if type(list) ~= "table" then return out end
	for _, r in ipairs(list) do
		local id = type(r) == "table" and tonumber(r.id)
		if id and r.kind == "apply" and type(r.args) == "table" and M.townRequest(r.args) then
			out[#out + 1] = { id = id, kind = "apply", args = r.args, propose = r.propose == true }
		end
	end
	return out
end

-- the official mods (Urban Games' vehicle packs on mod.io, ug_*): a map editor started by newgame --editor takes
-- these and the probe, not the running game's (a map keeps its mods)
M.OFFICIAL_PREFIX = "ug_"
function M.officialMods(installed)
	local out = {}
	for _, n in ipairs(installed or {}) do
		if type(n) == "string" and n:sub(1, #M.OFFICIAL_PREFIX) == M.OFFICIAL_PREFIX then out[#out + 1] = n end
	end
	table.sort(out)
	return out
end

-- the values a construction's own params start with, as the base's construction menu picks them
-- (construction.tl getParamDefaultValue: numbers[defaultIndex], or defaultIndex when there are no numbers).
-- descParams: the desc's params as plain tables { key, numbers, defaultIndex }.
function M.buildDefaults(descParams)
	local out = {}
	for _, p in ipairs(descParams or {}) do
		local key = type(p) == "table" and p.key
		if type(key) == "string" and key ~= "" then
			local di = tonumber(p.defaultIndex) or 0
			local numbers = type(p.numbers) == "table" and p.numbers or {}
			local v = tonumber(numbers[di])
			if v == nil then v = di end
			out[key] = v
		end
	end
	return out
end

-- the params sent: the defaults, then the request's own on top, the seed when the request has none
-- (constructions that use randomness ask for one: a mod's pier asserts it, nova auto_piers batch.lua), and the
-- probe's mark, which stays in the construction's params (a key its updateFn does not know: nova's piers carry one
-- of their own the same way, batch.lua nova_sert_vss_auto) and tells build remove, after a load, that the probe
-- built it
M.BUILD_MARK = "remote_probe_build"
function M.buildParams(defaults, given, seed)
	local out = {}
	for k, v in pairs(defaults or {}) do out[k] = v end
	for k, v in pairs(given or {}) do out[k] = v end
	if out.seed == nil then out.seed = seed end
	out[M.BUILD_MARK] = 1
	return out
end

-- the resName as given, and the spellings it may also go by: without the file's ".lua", and a base game name
-- with the "::/" the base's own names carry (street templates: "::/infrastructure/...")
function M.buildResCandidates(res)
	local out, seen = {}, {}
	local function add(s) if s and s ~= "" and not seen[s] then seen[s] = true; out[#out + 1] = s end end
	add(res)
	local bare = res:gsub("%.lua$", "")
	add(bare)
	if not bare:find("::", 1, true) then
		local rel = bare:gsub("^/+", "")
		add("::/" .. rel)
	end
	return out
end

-- May build remove take this construction away? Only what the probe built:
--   rec (what this load of the probe built under that id: { res, x, y }): the same file at the same place (an id
--   the engine gave again to something else after ours went, by hand or unseen, is not ours);
--   or, after a load, its name starts with BUILD_NAME_PREFIX and its params carry the probe's mark.
-- con: what the engine has under the id now: { fileName, x, y, name, marked }. -> true, or false and why
M.BUILD_SAME_PLACE_M = 1
function M.buildRemovable(rec, con)
	if type(con) ~= "table" or type(con.fileName) ~= "string" then return false, "no construction" end
	if type(rec) == "table" and rec.res == con.fileName and tonumber(con.x) and tonumber(con.y)
		and math.abs(con.x - rec.x) <= M.BUILD_SAME_PLACE_M and math.abs(con.y - rec.y) <= M.BUILD_SAME_PLACE_M then
		return true
	end
	if con.marked and type(con.name) == "string" and con.name:sub(1, #M.BUILD_NAME_PREFIX) == M.BUILD_NAME_PREFIX then
		return true
	end
	if type(rec) == "table" then
		return false, "not what the probe built under this id (another file or place now: the id may have been given again)"
	end
	return false, "not built by the probe (no " .. M.BUILD_NAME_PREFIX .. " name with the probe's mark in its params)"
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

-- a model argument that names a multiple unit (a .mu.lua file, as the store's "multiple unit" rows; .mu also, as
-- the game may name them without .lua): bought as the train it lists, not as one model
M.MU_SUFFIX = ".mu.lua"
function M.isMuName(q)
	if type(q) ~= "string" then return false end
	local l = q:lower()
	return (#l > #M.MU_SUFFIX and l:sub(-#M.MU_SUFFIX) == M.MU_SUFFIX) or (#l > 3 and l:sub(-3) == ".mu")
end

-- a multiple unit's name as compared: any case, the folder left out, and .mu.lua or .mu off the end
-- ("vehicle/train/shinkansen_0s/Shinkansen_0s.MU.lua" -> "shinkansen_0s")
function M.muKey(name)
	local n = tostring(name or ""):lower():gsub("\\", "/")
	n = n:match("([^/]*)$") or n
	n = n:gsub("%.mu%.lua$", ""):gsub("%.mu$", "")
	return n
end

-- the multiple units from api.res.multipleUnitRep.getAll() ({ [id] = name }, type.d.tl): { id, value (getAll's
-- value, when a name), getName (getName(id), when a name), name (getName's, else the value: the store goes by
-- getName, vehicle_store_window.tl), names (both, to match against) }, sorted by id. A unit with neither is left
-- out. Second result: why the walk stopped, when pairs could not go through (the list is then what came before).
-- 2026-11-23 in game a lookup by getName's name alone matched nothing: it is not known which form either has.
function M.muListFrom(all, getName)
	local list = {}
	if all == nil then return list end
	local ok, err = pcall(function()
		for id, v in pairs(all) do
			local value = type(v) == "string" and v ~= "" and v or nil
			local byName
			if getName then
				local okN, n = pcall(getName, id)
				if okN and type(n) == "string" and n ~= "" then byName = n end
			end
			local names = {}
			if byName then names[#names + 1] = byName end
			if value and value ~= byName then names[#names + 1] = value end
			if #names > 0 and tonumber(id) then
				list[#list + 1] = { id = tonumber(id), value = value, getName = byName, name = names[1], names = names }
			end
		end
	end)
	table.sort(list, function(x, y) return x.id < y.id end)
	if not ok then return list, string.format("the walk of getAll() stopped after %d: %s", #list, tostring(err)) end
	return list
end

-- list (muListFrom) against query: the whole name (any case), then the key (muKey: file name without .mu.lua /
-- .mu), then a unique part of the key. No hit: why, with what was there to match, so the next try can do better:
-- how many there are (and notes, e.g. that the visible list was empty), the names holding a piece of the query
-- (its parts between _ - . and spaces, 3 letters or more), and the first 5.
function M.matchMu(list, query, notes)
	if type(query) ~= "string" or query == "" then return nil, "give the multiple unit" end
	local q, k = query:lower(), M.muKey(query)
	local exact, key, partial = {}, {}, {}
	for _, m in ipairs(list or {}) do
		-- the best of its names counts (getName's and getAll's value may differ in form)
		local best = 0
		for _, name in ipairs(m.names or { m.name }) do
			local n = tostring(name):lower():gsub("\\", "/")
			local mk = M.muKey(name)
			if n == q then best = math.max(best, 3)
			elseif k ~= "" and mk == k then best = math.max(best, 2)
			elseif k ~= "" and mk:find(k, 1, true) then best = math.max(best, 1) end
		end
		if best == 3 then exact[#exact + 1] = m
		elseif best == 2 then key[#key + 1] = m
		elseif best == 1 then partial[#partial + 1] = m end
	end
	local hits = #exact > 0 and exact or (#key > 0 and key or partial)
	if #hits == 1 then return hits[1] end
	local function names(t, n)
		local out = {}
		for i = 1, math.min(#t, n) do out[#out + 1] = string.format("%s (%s)", tostring(t[i].name), tostring(t[i].id)) end
		return table.concat(out, ", ") .. (#t > n and ", ..." or "")
	end
	if #hits > 1 then
		table.sort(hits, function(a, b) return tostring(a.name) < tostring(b.name) end)
		return nil, string.format("%d multiple units match %q: %s", #hits, query, names(hits, 10))
	end
	list = list or {}
	local near, seen = {}, {}
	for piece in k:gmatch("[^_%-%.%s]+") do
		if #piece >= 3 then
			for _, m in ipairs(list) do
				for _, name in ipairs(m.names or { m.name }) do
					if not seen[m] and tostring(name):lower():find(piece, 1, true) then
						seen[m] = true
						near[#near + 1] = m
					end
				end
			end
		end
	end
	local msg = string.format("no multiple unit matches %q (%d multiple units listed%s)", query, #list,
		(notes and notes ~= "") and ("; " .. notes) or "")
	if #near > 0 then msg = msg .. "; names with a piece of it: " .. names(near, 10) end
	if #list > 0 then msg = msg .. "; the first ones: " .. names(list, 5) end
	return nil, msg
end

-- cmd: buy, duplicate, replace or sell. Returns { via, count, depot, line, vehicle, model, mu } (model: the query
-- as given, matched later against the model list, or the multiple unit list when mu is true) or nil and why.
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
		if M.isMuName(m) then
			-- only the store's way is built for a multiple unit: the cmd way sends purchaseTime 0 (wrong prices) and
			-- a train of parts by hand has never been sent through it
			if cmd == "replace" then return nil, "replace takes one model; a multiple unit (.mu.lua) can only be bought" end
			if out.via ~= "gui" then return nil, "a multiple unit (.mu.lua) is bought via gui only" end
			out.mu = true
		end
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
-- what: the kind of thing in the messages (default "vehicle model"; "multiple unit" for the .mu.lua list)
function M.matchModel(list, query, what)
	what = what or "vehicle model"
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
	if #hits == 0 then return nil, string.format("no %s matches %q", what, query) end
	table.sort(hits, function(a, b) return tostring(a.name) < tostring(b.name) end)
	local names = {}
	for i = 1, math.min(#hits, 10) do names[#names + 1] = string.format("%s (%s)", tostring(hits[i].name), tostring(hits[i].id)) end
	return nil, string.format("%d %ss match %q: %s%s", #hits, what == "vehicle model" and "model" or what, query, table.concat(names, ", "), #hits > 10 and ", ..." or "")
end

-- what the operation cost: positive = paid, negative = earned (a sale). nil when a balance is unknown (the
-- engine returns nil for infinite money).
function M.spent(before, after)
	if type(before) ~= "number" or type(after) ~= "number" then return nil end
	return before - after
end

---------------------------------------------------------------------------------------------------------------------
-- models and vehicles --state (read only): the numbers a vehicle rebalance is measured by (ships, 2026-11-21:
-- price and running costs as the store reads them, speed, capacity per cargo type, loadSpeed; and, of a running
-- vehicle, what the engine holds about its stop, so a poll every few seconds can time how long it stays in port)

M.MODELS_LIMIT = 200
M.MODELS_MAX = 1000 -- details per answer at most: each reads a model's metadata and walks its cargo sets
M.MAX_VEHICLE_ENTITIES = 50

-- args: grep (a part of the file name or the shown name, any case; digits also match the id), carrier (ROAD, RAIL,
-- TRAM, AIR, WATER; any case), limit. Returns them or nil and why.
function M.modelsArgs(args)
	args = type(args) == "table" and args or {}
	local out = { limit = M.MODELS_LIMIT }
	if args.grep ~= nil then
		if type(args.grep) == "number" then args.grep = string.format("%d", args.grep) end
		if type(args.grep) ~= "string" or args.grep == "" then return nil, "grep must be a part of the name" end
		out.grep = args.grep:lower()
	end
	if args.carrier ~= nil then
		if type(args.carrier) ~= "string" or args.carrier == "" then return nil, "carrier must be a name (ROAD, RAIL, TRAM, AIR, WATER)" end
		out.carrier = args.carrier:upper()
	end
	-- mu: the multiple units instead (true, or a part of the name to keep)
	if args.mu ~= nil and args.mu ~= false then
		if args.mu ~= true and (type(args.mu) ~= "string" or args.mu == "") then
			return nil, "mu must be true or a part of the name"
		end
		out.mu = args.mu
		if out.carrier then return nil, "carrier does not go with mu (multiple units are trains)" end
		if out.grep then return nil, "grep does not go with mu (give the filter as mu)" end
	end
	if args.limit ~= nil then
		local n = tonumber(args.limit)
		if n == nil or n ~= math.floor(n) or n < 1 or n > M.MODELS_MAX then
			return nil, "limit must be a whole number from 1 to " .. M.MODELS_MAX
		end
		out.limit = n
	end
	return out
end

-- the vehicles command: line and limit as before (a limit that is no number is the default, as it always was),
-- and the new ones: entities (only these vehicles; one that is gone is listed under missing, not an error, so a
-- poll can see a ship sold or replaced), state (what the engine holds about the vehicle's stop and its money),
-- since (a game time: the vehicle's balance from then, with state), atTerminal (with state: only the vehicles
-- whose state is AT_TERMINAL). With line and entities both, a vehicle of the company on another line is left out
-- (neither listed nor missing). Returns them or nil and why.
function M.vehicleListArgs(args)
	args = type(args) == "table" and args or {}
	local out = { limit = tonumber(args.limit) or 200 }
	if args.line ~= nil then
		out.line = tonumber(args.line)
		if out.line == nil then return nil, "line must be an entity id" end
	end
	if args.entities ~= nil then
		if type(args.entities) ~= "table" then return nil, "entities must be a list of entity ids" end
		local list, seen = {}, {}
		for _, e in ipairs(args.entities) do
			local n = entityArg(e)
			if n == nil then return nil, "entities must be a list of entity ids (whole numbers >= 0)" end
			if not seen[n] then seen[n] = true; list[#list + 1] = n end -- one answer per vehicle
		end
		if #list == 0 then return nil, "entities must name at least one vehicle" end
		if #list > M.MAX_VEHICLE_ENTITIES then return nil, "at most " .. M.MAX_VEHICLE_ENTITIES .. " entities at once" end
		out.entities = list
	end
	if args.state ~= nil and type(args.state) ~= "boolean" then return nil, "state must be true or false" end
	out.state = args.state == true
	if args.since ~= nil then
		local n = tonumber(args.since)
		if n == nil or n < 0 then return nil, "since must be a game time (a number >= 0)" end
		if not out.state then return nil, "since goes with state" end
		out.since = math.floor(n) -- calculateBalance takes an integer game time
	end
	if args.atTerminal ~= nil and type(args.atTerminal) ~= "boolean" then return nil, "atTerminal must be true or false" end
	if args.atTerminal == true then
		if not out.state then return nil, "atTerminal goes with state" end
		out.atTerminal = true
	end
	return out
end

-- the capacity per cargo type as the vehicle store adds it up (vehicle_store_util.tl getVehicleCargoCapacities):
-- in each compartment the largest capacity a load config gives each cargo type (a compartment carries one of its
-- configs at a time), summed over the compartments; the total is the sum of each compartment's largest.
-- compartments: { { { capacity = n, cargoTypes = { id, ... } }, ... }, ... }. Returns { [id] = n }, total.
function M.storeCapacities(compartments)
	local per, total = {}, 0
	for _, comp in ipairs(compartments or {}) do
		local max = {}
		for _, lc in ipairs(comp or {}) do
			local cap = tonumber(lc.capacity) or 0
			for _, id in ipairs(lc.cargoTypes or {}) do max[id] = math.max(max[id] or 0, cap) end
		end
		local biggest = 0
		for id, cap in pairs(max) do
			per[id] = (per[id] or 0) + cap
			biggest = math.max(biggest, cap)
		end
		total = total + biggest
	end
	return per, total
end

-- the cargo ids of a cargo name map ({ [id] = name }), in order. Engine vectors per cargo type are read by these
-- (vector[id + 1], as the base reads loadSpeedModifiers and config.capacities, cargo_util.tl), never walked: an
-- id the engine does not know is its assertion.
function M.cargoIds(names)
	local ids = {}
	for id in pairs(names or {}) do if type(id) == "number" then ids[#ids + 1] = id end end
	table.sort(ids)
	return ids
end

-- the name of an engine enum value: names is the list to try, enum the table of values (api.type.enum.X).
-- Unknown: the value as text, so a new value shows up instead of vanishing.
function M.enumName(enum, names, v)
	if v == nil then return nil end
	for _, n in ipairs(names) do
		local ok, x = pcall(function() return enum[n] end)
		if ok and x ~= nil and x == v then return n end
	end
	return tostring(v)
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

-- a whole number >= 0 (or digits): an index as the engine counts it (0-based), else nil
local function indexArg(v)
	if type(v) == "string" and v:match("^%s*%d+%s*$") then v = tonumber(v) end
	if type(v) ~= "number" or v ~= v or v < 0 or v ~= math.floor(v) or v > 1e6 then return nil end
	return v
end

-- the waiting modes of a stop (Line.Stop.loadMode), by the numbers the base's cargo filter window sets
-- (cargofilter_window.tl: initialSelected = loadMode + 1, setStopField("loadMode", index - 1)) in the order of the
-- LoadMode enum (engine.d.tl). LEGACY_UNLOAD_ONLY (3) is left out: the base window does not offer it, so what the
-- engine does with it on a new stop is unknown.
M.LOAD_MODES = { available = 0, any = 1, all = 2,
	load_if_available = 0, full_load_any = 1, full_load_all = 2 }
M.LOAD_MODE_NAMES = { [0] = "available", [1] = "any", [2] = "all" }

-- one load mode as given: a name above (any case) or 0..2. Returns the number, or nil and why.
local function loadModeArg(v, what)
	if type(v) == "number" and M.LOAD_MODE_NAMES[v] then return v end
	if type(v) == "string" then
		local n = M.LOAD_MODES[v:match("^%s*(.-)%s*$"):lower()]
		if n then return n end
		if v:match("^%s*%d+%s*$") and M.LOAD_MODE_NAMES[tonumber(v)] then return tonumber(v) end
	end
	return nil, what .. " must be available, any or all (or 0, 1, 2: LOAD_IF_AVAILABLE, FULL_LOAD_ANY, " ..
		"FULL_LOAD_ALL), got " .. (type(v) == "string" and string.format("%q", v) or "a " .. type(v))
end

-- one stop's forceUnload as given: true / false, 1 / 0 or "1" / "0" (the tool sends booleans). Returns the boolean,
-- or nil and why.
local function forceUnloadArg(v, i)
	if type(v) == "boolean" then return v end
	if v == 1 or v == "1" then return true end
	if v == 0 or v == "0" then return false end
	return nil, string.format("force unload %d must be 0 or 1 (true or false), got %s", i,
		type(v) == "string" and string.format("%q", v) or "a " .. type(v))
end

-- one stop's platform as given: { station, terminal } (0-based, as the lines command shows them), a terminal
-- number (station 0) or "station:terminal". Returns { station, terminal } or nil and why.
local function terminalArg(v, i)
	local st, te
	if type(v) == "table" then
		st, te = v.station == nil and 0 or indexArg(v.station), indexArg(v.terminal)
	elseif type(v) == "string" and v:find(":", 1, true) then
		local a, b = v:match("^%s*(%d+)%s*:%s*(%d+)%s*$")
		st, te = indexArg(a), indexArg(b)
	else
		st, te = 0, indexArg(v)
	end
	if st == nil or te == nil then
		return nil, string.format("terminal %d must be a terminal number or station:terminal (whole numbers >= 0, " ..
			"0-based as the lines and stations commands show them)", i)
	end
	return { station = st, terminal = te }
end

-- a list as Lua holds one: keys 1..n and nothing else
local function isList(t)
	if type(t) ~= "table" then return false end
	local n = #t
	for k in pairs(t) do
		if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then return false end
	end
	return true
end

-- args: action, via, line, stops (a list), name, cargo, sellVehicles, terminals (one per stop), loadModes (one per
-- stop, or one for every stop), forceUnload (one per stop: Line.Stop.stopConfig.forceUnload). Returns { action,
-- via, line, stops, name, cargo, sellVehicles, terminals, loadModes (a list) or loadModeAll (a number),
-- forceUnload (a list of booleans) } or nil and why. A line needs two stops: the base makes a one-stop
-- line only on the way to the second click, and nothing runs on it.
-- terminals go for every stop or for none: when one stop has no platform the base's autoAssignTerminals takes the
-- engine's assignment for every stop (allowing changes), so the platforms given to the others would not hold.
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
	if args.terminals ~= nil then
		if not isList(args.terminals) or #args.terminals == 0 then
			return nil, "terminals must be a list, one per stop"
		end
		if #args.terminals > M.MAX_LINE_STOPS then return nil, "more than " .. M.MAX_LINE_STOPS .. " terminals" end
		out.terminals = {}
		for i = 1, #args.terminals do
			local t, err = terminalArg(args.terminals[i], i)
			if not t then return nil, err end
			out.terminals[i] = t
		end
		if out.stops and #out.terminals ~= #out.stops then
			return nil, string.format("give a terminal for every stop (%d stops, %d terminals): when one stop has " ..
				"none, the base assigns every stop's platform anew (autoAssignTerminals), so some would not hold",
				#out.stops, #out.terminals)
		end
	end
	if args.loadModes ~= nil then
		if type(args.loadModes) == "table" then
			if not isList(args.loadModes) or #args.loadModes == 0 then
				return nil, "loadModes must be one mode, or a list with one per stop"
			end
			if #args.loadModes > M.MAX_LINE_STOPS then return nil, "more than " .. M.MAX_LINE_STOPS .. " load modes" end
			out.loadModes = {}
			for i = 1, #args.loadModes do
				local m, err = loadModeArg(args.loadModes[i], "load mode " .. i)
				if not m then return nil, err end
				out.loadModes[i] = m
			end
			if out.stops and #out.loadModes ~= #out.stops then
				return nil, string.format("give one load mode for every stop, or one for all (%d stops, %d load modes)",
					#out.stops, #out.loadModes)
			end
		else
			local m, err = loadModeArg(args.loadModes, "the load mode")
			if not m then return nil, err end
			out.loadModeAll = m
		end
	end
	if args.forceUnload ~= nil then
		-- one per stop and no "one for all": a count that does not match the line is refused, never spread
		if not isList(args.forceUnload) or #args.forceUnload == 0 then
			return nil, "forceUnload must be a list, one 0 or 1 per stop"
		end
		if #args.forceUnload > M.MAX_LINE_STOPS then return nil, "more than " .. M.MAX_LINE_STOPS .. " force unload values" end
		out.forceUnload = {}
		for i = 1, #args.forceUnload do
			local b, err = forceUnloadArg(args.forceUnload[i], i)
			if b == nil then return nil, err end
			out.forceUnload[i] = b
		end
		if out.stops and #out.forceUnload ~= #out.stops then
			return nil, string.format("give one force unload value for every stop (%d stops, %d values)",
				#out.stops, #out.forceUnload)
		end
	end
	local perStop = out.terminals or out.loadModes or out.loadModeAll or out.forceUnload
	if out.action == "create" then
		if out.line ~= nil then return nil, "create makes a new line: no line" end
		if not out.stops then return nil, "give the stops" end
	else
		if out.line == nil then return nil, "give the line (the lines command lists them)" end
		if out.action == "update" and not (out.stops or out.name or out.cargo or perStop) then
			return nil, "give stops, name, cargo, terminals, load modes or force unload to change"
		end
		if out.action == "delete" and (out.stops or out.name or out.cargo or perStop) then
			return nil, "delete takes no stops, name, cargo, terminals, load modes or force unload"
		end
	end
	return out
end

-- the line requests (gui way) the guiUpdate script hands the speed control: { { id, kind = "create" | "update",
-- line, name, cargo, stops = { { stationGroup } }, terminals = { { station, terminal } }, loadModes = { n },
-- forceUnload = { boolean }, carriers = { n } } }, plain values only; malformed ones are left out
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
			-- terminals and loadModes: one per stop, whole numbers; a request with a malformed one is left out
			-- whole (sent without them, the engine would pick the platforms the caller did not want)
			local terminals, loadModes, carriers
			if good and r.terminals ~= nil then
				terminals = {}
				if not isList(r.terminals) then good = false end
				for _, t in ipairs(good and r.terminals or {}) do
					local st, te = type(t) == "table" and indexArg(t.station), type(t) == "table" and indexArg(t.terminal)
					if st and te then terminals[#terminals + 1] = { station = st, terminal = te } else good = false end
				end
				if #terminals == 0 or (stops and #terminals ~= #stops) then good = false end
			end
			if good and r.loadModes ~= nil then
				loadModes = {}
				if not isList(r.loadModes) then good = false end
				for _, m in ipairs(good and r.loadModes or {}) do
					if M.LOAD_MODE_NAMES[m] then loadModes[#loadModes + 1] = m else good = false end
				end
				if #loadModes == 0 or (stops and #loadModes ~= #stops) then good = false end
			end
			local forceUnload
			if good and r.forceUnload ~= nil then
				forceUnload = {}
				if not isList(r.forceUnload) then good = false end
				for _, b in ipairs(good and r.forceUnload or {}) do
					if type(b) == "boolean" then forceUnload[#forceUnload + 1] = b else good = false end
				end
				if #forceUnload == 0 or (stops and #forceUnload ~= #stops) then good = false end
			end
			if good and r.carriers ~= nil then
				carriers = {}
				if not isList(r.carriers) then good = false end
				for _, c in ipairs(good and r.carriers or {}) do
					if indexArg(c) then carriers[#carriers + 1] = indexArg(c) else good = false end
				end
			end
			if good and (r.kind == "create" or tonumber(r.line)) then
				out[#out + 1] = { id = tonumber(r.id), kind = r.kind, line = tonumber(r.line), stops = stops,
					name = type(r.name) == "string" and r.name or nil, cargo = tonumber(r.cargo), terminals = terminals,
					loadModes = loadModes, forceUnload = forceUnload, carriers = carriers }
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
-- industryWorkers: who works at an industry (read only)

-- the base's game script that counts workers arriving by lines (industries/industry_workers.script.tl)
M.WORKERS_SCRIPT = "::/industries/industry_workers.gs"
-- the share of the capacity that must have arrived for the productivity boost (industry_productivity_util.tl)
M.WORKERS_BOOST_FRACTION = 0.5

-- args: entity (one industry) or nothing (all). Returns { entity } or nil and why.
function M.industryWorkersArgs(args)
	args = type(args) == "table" and args or {}
	if args.entity == nil then return {} end
	local e = tonumber(args.entity)
	if e == nil or e ~= math.floor(e) or e < 0 or e > M.MAX_ENTITY_ID then
		return nil, "entity must be an industry's id (the entities --kind industry command lists them)"
	end
	return { entity = e }
end

-- one industry's entry of the workers script's state, read as industry_productivity_util.getIndustryWorkersState
-- does: state_native:findPath({ "industriesState", entity }):asTable(). A plain table (state) is walked instead.
-- Returns the entry (a table), false when the state has none for it (nobody arrived yet: the base reads that as
-- no visitors), or nil and why.
function M.workersEntry(stateNative, plainState, entity)
	if stateNative ~= nil then
		local ok, v = pcall(function() return stateNative:findPath({ "industriesState", entity }) end)
		if not ok then return nil, "state_native:findPath failed: " .. tostring(v) end
		if v == nil then return false end
		local ok2, t = pcall(function() return v:asTable() end)
		if not ok2 or type(t) ~= "table" then return nil, "the industry's entry did not read as a table" end
		return t
	end
	if type(plainState) == "table" then
		local all = plainState.industriesState
		local t = type(all) == "table" and all[entity] or nil
		if t == nil then return false end
		if type(t) ~= "table" then return nil, "the industry's entry is no table" end
		return t
	end
	return nil, "the game script has no state"
end

-- from an entry: the number of last visitors and the newest arrival's game time (nil when none)
function M.visitorsOf(entry)
	if not entry then return 0, nil end
	local list = entry.lastVisitors
	local n, newest = M.size(list), nil
	for i = 1, n do
		local t = tonumber(M.field(M.at(list, i), "time"))
		if t and (newest == nil or t > newest) then newest = t end
	end
	return n, newest
end

-- a town's population from its { residential, commercial, industrial } capacities, as the town HUD shows it
-- (town_hud_react_util.tl: residential, or the larger of the others when it has none). idx: 1-based indices.
function M.townPopulation(caps, idx)
	if caps == nil then return nil end
	idx = idx or { residential = 1, commercial = 2, industrial = 3 }
	local r = tonumber(M.at(caps, idx.residential))
	if r == nil then return nil end
	if r <= 0 then
		r = math.max(tonumber(M.at(caps, idx.industrial)) or 0, tonumber(M.at(caps, idx.commercial)) or 0)
	end
	return r
end

-- the nearest of candidates { { id, name, position = { x, y } } } to pos, with its distance (m, rounded), or nil
function M.nearest(pos, candidates)
	if not pos then return nil end
	local best, bestD
	for _, c in ipairs(candidates or {}) do
		if c.position then
			local d = math.sqrt((c.position.x - pos.x) ^ 2 + (c.position.y - pos.y) ^ 2)
			if bestD == nil or d < bestD then best, bestD = c, d end
		end
	end
	if not best then return nil end
	return best, math.floor(bestD + 0.5)
end

---------------------------------------------------------------------------------------------------------------------
-- industryStocks: an industry's stocks, rules and its construction's params (read only), for checking what mods
-- that rebuild industries (Age of Mobility's upgrades) leave in them across loads and rebuilds

-- the params shown without --all-params: every key with this prefix (AoM's upgrades), and these
M.STOCKS_PARAM_PREFIX = "hummer_aom_upg_"
M.STOCKS_PARAM_KEYS = { "industrialCapacity", "upgrade", "year" }

-- args: entity (one industry), grep (a part of the name, any case), allParams (every param). Returns them or nil
-- and why.
function M.industryStocksArgs(args)
	args = type(args) == "table" and args or {}
	local out, err = M.industryWorkersArgs({ entity = args.entity })
	if not out then return nil, err end
	if args.grep ~= nil then
		if type(args.grep) ~= "string" or args.grep == "" then return nil, "grep must be a part of the name" end
		out.grep = args.grep:lower()
	end
	if args.allParams ~= nil and type(args.allParams) ~= "boolean" then return nil, "allParams must be true or false" end
	out.allParams = args.allParams == true
	return out
end

-- from a construction's params (a plain table): { prefixed = { key = value }, other = { key = value } }, values as
-- plain tables. A key that is there with "" keeps "": the JSON tells it apart from a key that is not there.
function M.pickParams(params, prefix, keys)
	local out = { prefixed = {}, other = {} }
	if type(params) ~= "table" then return out end
	prefix = prefix or M.STOCKS_PARAM_PREFIX
	for k, v in pairs(params) do
		if type(k) == "string" and k:sub(1, #prefix) == prefix then out.prefixed[k] = M.plain(v) end
	end
	for _, k in ipairs(keys or M.STOCKS_PARAM_KEYS) do
		if params[k] ~= nil then out.other[k] = M.plain(params[k]) end
	end
	return out
end

-- a stock list rule as plain data: input as one list per input set (amount per stock, 1-based like the stocks),
-- output as a list of { cargoType, amount } (a map keyed by cargo ids would read as a JSON list when they run 1..n)
function M.ruleOf(rule, cargoName)
	local r = { booster = M.field(rule, "booster"), boostFactor = tonumber(M.field(rule, "boostFactor")),
		capacity = tonumber(M.field(rule, "capacity")), consumptionFactor = tonumber(M.field(rule, "consumptionFactor")),
		priority = tonumber(M.field(rule, "priority")), slot = tonumber(M.field(rule, "slot")) }
	if type(r.booster) ~= "boolean" then r.booster = nil end
	r.input = {}
	for _, set in ipairs(M.toList(M.field(rule, "input"))) do
		local amounts = {}
		for _, n in ipairs(M.toList(set)) do amounts[#amounts + 1] = tonumber(n) or 0 end
		r.input[#r.input + 1] = M.array(amounts)
	end
	M.array(r.input)
	r.output = {}
	local outMap = M.field(rule, "output")
	pcall(function()
		for id, n in pairs(outMap) do
			r.output[#r.output + 1] = { cargoType = tonumber(id), amount = tonumber(n), cargo = cargoName and cargoName(tonumber(id)) or nil }
		end
	end)
	table.sort(r.output, function(a, b) return (a.cargoType or -1) < (b.cargoType or -1) end)
	M.array(r.output)
	return r
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

---------------------------------------------------------------------------------------------------------------------
-- persons (read only): the sim persons on a vehicle (or on a line), each with its happiness and, aboard, the
-- engine's expected arrival time, next to the game time; and the engine's passenger quality counts for the
-- vehicle, its line and the line's stops. Made to time when a passenger's happiness starts to fall (on boarding,
-- or once the expected arrival is past) by asking every few seconds.

M.PERSONS_LIMIT = 200
M.PERSONS_MAX = 2000 -- each person is four or five component reads: a ship's load at most, within one frame
-- the base's line between happy and unhappy (sim_person_eow.script.tl HappinessBar: below 0.5 is "Unhappy")
M.UNHAPPY_BELOW = 0.5
-- waiting this long at a terminal, the base person window shows a falling happiness (sim_person.tl: arrivalTime +
-- 1000 * 2 * 60)
M.TERMINAL_GRACE_MS = 2 * 60 * 1000

-- args: vehicle, line, town (its residents: the people whose home is one of its buildings) or destination (the
-- people with that entity as one of their destinations: home, shop or work), one of them: an entity id; limit
-- (persons listed, 1..PERSONS_MAX). Returns them or nil and why.
M.PERSONS_FROM = { vehicle = "the vehicles", line = "the lines", town = "entities --kind town",
	destination = "industry-workers, stations --catchment" }
function M.personsArgs(args)
	args = type(args) == "table" and args or {}
	local out = { limit = M.PERSONS_LIMIT }
	local given = {}
	for _, k in ipairs({ "vehicle", "line", "town", "destination" }) do
		if args[k] ~= nil then
			local n = tonumber(args[k])
			if n == nil or n ~= math.floor(n) or n < 0 or n > M.MAX_ENTITY_ID then
				return nil, k .. " must be an entity id (" .. M.PERSONS_FROM[k] .. " lists them)"
			end
			out[k] = n
			given[#given + 1] = k
		end
	end
	if #given > 1 then return nil, "give one of vehicle, line, town, destination, not both (" .. table.concat(given, " and ") .. ")" end
	if #given == 0 then return nil, "give the vehicle (or a line, a town, a destination): its entity id" end
	if args.limit ~= nil then
		local n = tonumber(args.limit)
		if n == nil or n ~= math.floor(n) or n < 1 or n > M.PERSONS_MAX then
			return nil, "limit must be a whole number from 1 to " .. M.PERSONS_MAX
		end
		out.limit = n
	end
	return out
end

-- an engine CargoQualityData (a userdata; api/engine/util.d.tl UtilCargo) as a plain table: total, bad (the
-- unhappy ones, for passengers), averageQuality (nil when the engine has none: nobody there), veryBad. nil in,
-- nil out; a field that does not read is left out.
function M.qualityOf(q)
	if q == nil then return nil end
	local out = { total = tonumber(M.field(q, "countTotal")), bad = tonumber(M.field(q, "countBad")),
		averageQuality = tonumber(M.field(q, "averageQuality")) }
	local vb = M.field(q, "isVeryBad")
	if type(vb) == "boolean" then out.veryBad = vb end
	if next(out) == nil then return nil end
	return out
end

-- over the listed persons { happiness, late, atTerminal = { late }, ... }: how many, how many below UNHAPPY_BELOW,
-- how many aboard past their expected arrival (late), how many waiting past TERMINAL_GRACE_MS (lateWaiting), and
-- the mean, lowest and highest happiness of those with one.
function M.personSummary(persons)
	local out = { count = 0, withHappiness = 0, unhappy = 0, late = 0, lateWaiting = 0 }
	local sum = 0
	for _, p in ipairs(persons or {}) do
		out.count = out.count + 1
		local h = tonumber(p.happiness)
		if h and h == h then
			out.withHappiness = out.withHappiness + 1
			sum = sum + h
			if h < M.UNHAPPY_BELOW then out.unhappy = out.unhappy + 1 end
			if out.minHappiness == nil or h < out.minHappiness then out.minHappiness = h end
			if out.maxHappiness == nil or h > out.maxHappiness then out.maxHappiness = h end
		end
		if p.late == true then out.late = out.late + 1 end
		if type(p.atTerminal) == "table" and p.atTerminal.late == true then out.lateWaiting = out.lateWaiting + 1 end
	end
	if out.withHappiness > 0 then out.meanHappiness = sum / out.withHappiness end
	out.reach = M.reachSummary(persons)
	return out
end

-- over persons { reachable = { walkDrive = { n... }, lines = { n... } } }: how many have the counts, and per place
-- of the engine's list (landUse2ReachableWalkDrive / Lines, {integer, integer} in the tealdef: which land use each
-- is, it does not say) how many reach at least one such destination; none: reaching nothing either way. nil when
-- no person has them.
function M.reachSummary(persons)
	local out = { persons = 0, walkDrive = {}, lines = {}, none = 0 }
	for _, p in ipairs(persons or {}) do
		local r = type(p.reachable) == "table" and p.reachable or nil
		if r then
			out.persons = out.persons + 1
			local any = false
			for _, k in ipairs({ "walkDrive", "lines" }) do
				for i, n in ipairs(type(r[k]) == "table" and r[k] or {}) do
					out[k][i] = out[k][i] or 0
					if tonumber(n) and n > 0 then out[k][i] = out[k][i] + 1; any = true end
				end
			end
			if not any then out.none = out.none + 1 end
		end
	end
	if out.persons == 0 then return nil end
	M.array(out.walkDrive); M.array(out.lines)
	return out
end

---------------------------------------------------------------------------------------------------------------------
-- modhub (remote_modhub.lua): the base's MOD hub > My Mods page, from the main menu. It reads the staging area,
-- re-validates one staging mod, as the page's Re-Validate button does, and uploads one new mod as its Upload
-- button does (modhubPublish). A new mod page, or a mod made public, is not undone from the game, so the upload is
-- held in narrow bounds: one folder named here, a first upload only (no update of a mod already on mod.io), the
-- visibility always given, one upload per launch; tools/tf3ctl.py adds its own checks and a mark on disk.

-- the staging folders validate takes: the author's mods already published from that staging area, and the one
-- prepared next. Validating reads the folder and makes the game ask mod.io for the mod's details; the list keeps
-- a typo, or a half-made folder of another project, from starting minutes of validation on the wrong mod.
-- status reads every staging mod.
M.MODHUB_VALIDATE_FOLDERS = {
	hummer_construction_altitude_tooltip_1 = true,
	hummer_cursor_altitude_tooltip_1 = true,
	hummer_industry_pollution_display_1 = true,
	hummer_force_unload_default_1 = true,
}
-- the staging folders publish takes: separate from validate's list, so a folder fit to validate is not fit to
-- upload by that alone. A folder is added only once a person decided it: the first to go up this way, then the
-- author's mods already on mod.io (their updates; each has _metadata/mod.io_fileid.txt, checked by tf3ctl.py).
M.MODHUB_PUBLISH_FOLDERS = {
	hummer_force_unload_default_1 = true,
	hummer_cursor_altitude_tooltip_1 = true,
	hummer_construction_altitude_tooltip_1 = true,
	hummer_industry_pollution_display_1 = true,
}
-- the folders already on mod.io, each held to its mod.io page: a first upload of one is refused, and an update only
-- goes to that id. Without this, a lost or remade _metadata/mod.io_fileid.txt would make such a folder look new to
-- both tf3ctl.py and the game, and a first upload would make a second page. The same table is in tf3ctl.py.
-- After a first upload, add the folder and its new id to both.
M.MODHUB_PUBLISHED_IDS = {
	hummer_force_unload_default_1 = "6543965",
	hummer_cursor_altitude_tooltip_1 = "6523060",
	hummer_construction_altitude_tooltip_1 = "6536988",
	hummer_industry_pollution_display_1 = "6536959",
}
M.MODHUB_PUBLISH_SEC = { default = 900, max = 3600 } -- s for the whole publish command (waits, validation, upload)
M.MODHUB_CHANGELOG_MAX = 5000 -- characters; mod.io takes far more, a longer one here is a mistake
M.MODHUB_STATUS_WAIT = { default = 30, max = 120 } -- s status waits for mod.io and the staging mods' sync
M.MODHUB_VALIDATE_SEC = { default = 300, max = 1800 } -- s a validation may take before it is aborted
M.MODHUB_MESSAGES = { default = 50, max = 500 } -- validator messages listed in an answer (all are counted)
M.MODHUB_STATES = { "Sync", "Ready", "Publishing", "HasResult" } -- Modhub.StagingModData.State
M.LOG_LEVELS = { "Critical", "Error", "Warning", "Message", "Verbose", "Raw" } -- LogLevel, both of the api's lists

-- the folder name in a staging mod's id. The game logs the id as "StagingArea,<folder>" (modHubId=... in
-- stdout.txt) and takes it so on its --validate command line; whether Modhub.ModId.value carries the prefix in
-- Lua is not known, so both forms are read.
function M.stagingFolder(value)
	if type(value) ~= "string" or value == "" then return nil end
	return value:match("^StagingArea,(.+)$") or value
end

-- a staging folder name as given: a plain folder name, not a path
function M.stagingFolderArg(v)
	if type(v) ~= "string" or v == "" then return nil, "give a staging folder name (modhub status lists them)" end
	if #v > 200 or v:find("[/\\,%c]") or v == "." or v == ".." then
		return nil, "a staging folder is a plain folder name: " .. v:sub(1, 200)
	end
	return v
end

local function secondsArg(v, lim, what, positive)
	if v == nil then return lim.default end
	local n = tonumber(v)
	if n == nil or n ~= n or n < 0 or n > lim.max or (positive and n == 0) then
		return nil, what .. " must be " .. (positive and "more than 0" or "0") .. " to " .. lim.max .. " seconds"
	end
	return n
end

-- args: folder (only that mod in the list), wait (s to wait for mod.io and the sync; 0: answer at once)
function M.modhubStatusArgs(args)
	args = type(args) == "table" and args or {}
	local out = {}
	if args.folder ~= nil then
		local f, err = M.stagingFolderArg(args.folder)
		if not f then return nil, err end
		out.folder = f
	end
	local w, err = secondsArg(args.wait, M.MODHUB_STATUS_WAIT, "wait")
	if not w then return nil, err end
	out.wait = w
	return out
end

-- args: folder (required, from MODHUB_VALIDATE_FOLDERS), timeout (s), messages (how many to list)
function M.modhubValidateArgs(args)
	args = type(args) == "table" and args or {}
	local f, err = M.stagingFolderArg(args.folder)
	if not f then return nil, err end
	if not M.MODHUB_VALIDATE_FOLDERS[f] then
		local names = {}
		for k in pairs(M.MODHUB_VALIDATE_FOLDERS) do names[#names + 1] = k end
		table.sort(names)
		return nil, "validate takes only these staging folders: " .. table.concat(names, ", ") .. " (not " .. f .. ")"
	end
	local t
	t, err = secondsArg(args.timeout, M.MODHUB_VALIDATE_SEC, "timeout", true)
	if not t then return nil, err end
	local n = M.MODHUB_MESSAGES.default
	if args.messages ~= nil then
		n = tonumber(args.messages)
		if n == nil or n ~= math.floor(n) or n < 0 or n > M.MODHUB_MESSAGES.max then
			return nil, "messages must be a whole number 0-" .. M.MODHUB_MESSAGES.max
		end
	end
	return { folder = f, timeout = t, messages = n }
end

-- args: folder (required, from MODHUB_PUBLISH_FOLDERS), public (true / false, required: no default visibility),
-- one of firstUpload = true (a new mod page) or update = true with modioId (the mod.io id tools/tf3ctl.py read from
-- the staging folder's _metadata/mod.io_fileid.txt: the update goes only to that page), changelog (text, required),
-- dryRun, timeout (s, the whole command), messages (validator messages listed), version ("X.Y.Z", optional) with
-- revision (mod.json's, which tools/tf3ctl.py reads: Lua has no io; required with version), updateMetadata
-- (true / false, an update only: false when not given; a first upload is always true). Both or neither of
-- firstUpload and update is refused: a new page and an update must never be taken for each other.
function M.modhubPublishArgs(args)
	args = type(args) == "table" and args or {}
	local f, err = M.stagingFolderArg(args.folder)
	if not f then return nil, err end
	if not M.MODHUB_PUBLISH_FOLDERS[f] then
		local names = {}
		for k in pairs(M.MODHUB_PUBLISH_FOLDERS) do names[#names + 1] = k end
		table.sort(names)
		return nil, "publish takes only these staging folders: " .. table.concat(names, ", ") .. " (not " .. f .. ")"
	end
	if args.firstUpload ~= nil and args.firstUpload ~= true then return nil, "firstUpload is true or not given" end
	if args.update ~= nil and args.update ~= true then return nil, "update is true or not given" end
	if args.firstUpload and args.update then
		return nil, "give firstUpload = true (a new mod) or update = true (a mod already on mod.io), not both"
	end
	if not args.firstUpload and not args.update then
		return nil, "give firstUpload = true (a new mod) or update = true with modioId (a mod already on mod.io)"
	end
	-- updateMetadata: whether the page's fields (modinfo.json's name, summary and description) go up again. A first
	-- upload always sends them (the page's box is disabled for a new mod); an update sends them only when asked:
	-- they replace what mod.io's page holds, and a description put there by other means is lost.
	if args.updateMetadata ~= nil and type(args.updateMetadata) ~= "boolean" then
		return nil, "updateMetadata is true or false"
	end
	if args.firstUpload and args.updateMetadata == false then
		return nil, "updateMetadata = false is only for an update: a first upload sends modinfo.json's name, summary "
			.. "and description (the page's box is disabled for a new mod)"
	end
	local modioId
	if args.update then
		modioId = args.modioId
		if type(modioId) ~= "string" or not modioId:find("^%d+$") or #modioId > 20 then
			return nil, "an update needs modioId, the mod.io id (digits) of _metadata/mod.io_fileid.txt"
		end
	elseif args.modioId ~= nil then
		return nil, "modioId is only for an update: a first upload has no mod.io id yet"
	end
	local pinned = M.MODHUB_PUBLISHED_IDS[f]
	if pinned and args.firstUpload then
		return nil, f .. " is on mod.io already (mod " .. pinned .. "): a first upload would make a second page"
	end
	if pinned and modioId ~= pinned then
		return nil, f .. " is mod.io mod " .. pinned .. ", not " .. tostring(modioId) .. ": not updated"
	end
	if type(args.public) ~= "boolean" then
		return nil, "give public = true or false: there is no default visibility"
	end
	if type(args.changelog) ~= "string" or not args.changelog:find("%S") then
		return nil, "give a changelog (text)"
	end
	if #args.changelog > M.MODHUB_CHANGELOG_MAX then
		return nil, "the changelog is longer than " .. M.MODHUB_CHANGELOG_MAX .. " characters"
	end
	if args.dryRun ~= nil and type(args.dryRun) ~= "boolean" then return nil, "dryRun is true or false" end
	local t
	t, err = secondsArg(args.timeout, M.MODHUB_PUBLISH_SEC, "timeout", true)
	if not t then return nil, err end
	local n = M.MODHUB_MESSAGES.default
	if args.messages ~= nil then
		n = tonumber(args.messages)
		if n == nil or n ~= math.floor(n) or n < 0 or n > M.MODHUB_MESSAGES.max then
			return nil, "messages must be a whole number 0-" .. M.MODHUB_MESSAGES.max
		end
	end
	local version
	if args.version ~= nil then
		version, err = M.modhubVersionArg(args.version, args.revision)
		if not version then return nil, err end
	elseif args.revision ~= nil then
		return nil, "revision is only given with version"
	end
	return { folder = f, public = args.public, firstUpload = args.firstUpload == true, update = args.update == true,
		updateMetadata = args.firstUpload == true or args.updateMetadata == true, modioId = modioId,
		changelog = args.changelog, dryRun = args.dryRun == true, timeout = t, messages = n,
		version = version, revision = version and args.revision or nil }
end

-- a version for PublishSettings.additionalMetadata: "X.Y.Z", whole numbers without leading zeros, Y and Z 0-99,
-- and the same number as mod.json's revision (X*10000 + Y*100 + Z, the rule of the author's mods): a version
-- that says one release and a revision that says another is refused. Whether mod.io's file version takes it is
-- not known (the game sent "1.0" there for force unload 1.0.3, 2026-11-22).
function M.modhubVersionArg(v, revision)
	if type(v) ~= "string" then return nil, "version is a string X.Y.Z" end
	local x, y, z = v:match("^(%d+)%.(%d+)%.(%d+)$")
	if not x or #v > 20 then return nil, "version is X.Y.Z (whole numbers only): " .. v:sub(1, 40) end
	for _, p in ipairs({ x, y, z }) do
		if #p > 1 and p:sub(1, 1) == "0" then return nil, "version has no leading zeros: " .. v end
	end
	x, y, z = tonumber(x), tonumber(y), tonumber(z)
	if y > 99 or z > 99 then return nil, "version's Y and Z are 0-99 (revision X*10000+Y*100+Z): " .. v end
	if type(revision) ~= "number" or revision ~= math.floor(revision) or revision < 1 then
		return nil, "version needs revision, mod.json's (a whole number of 1 or more)"
	end
	local want = x * 10000 + y * 100 + z
	if want ~= revision then
		return nil, string.format("version %s is revision %d, but mod.json's revision is %d (that is %d.%d.%d)", v,
			want, revision, math.floor(revision / 10000), math.floor(revision / 100) % 100, revision % 100)
	end
	return v
end

-- whether a finished validation lets the upload go without a person. The base's Upload button needs a result
-- without criticalPc (mod_manager_react_util.tl 1808-1809), and asks a person to "Proceed Anyway" when levelPc or
-- levelConsole is Error or Critical (1819-1820, validationLevelIsFailed 20-22): that question is not answered here,
-- so those are refused too. r: validationSummary's table (levels as names). Returns nil when it may go, else why.
function M.publishValidationBlock(r)
	if type(r) ~= "table" then return "no validation result" end
	if r.criticalPc ~= false then return r.criticalPc == true and "the validation has critical PC issues"
		or "the validation's criticalPc cannot be read" end
	if r.criticalConsole == true then return "the validation has critical console issues" end
	for _, k in ipairs({ "levelPc", "levelConsole" }) do
		local lv = r[k]
		if lv == "Error" or lv == "Critical" then
			return "the validation's " .. k .. " is " .. lv .. ": the base page would ask a person to proceed anyway"
		end
		if type(lv) ~= "string" then return "the validation's " .. k .. " cannot be read" end
	end
	return nil
end

-- what the base's My Mods page says of a finished validation (mod_manager_react_util.tl, "Validation: ..."), with
-- the counts it makes: every message counted by its level, PC and console alike (consoleOnly is counted on top).
-- r: { messages = { { level = <name>, file, message, context, consoleOnly } }, criticalPc, criticalConsole,
-- levelPc, levelConsole } with levels as names. limit: messages listed; all are counted.
function M.validationSummary(r, limit)
	if type(r) ~= "table" then return nil end
	limit = limit or M.MODHUB_MESSAGES.default
	local counts = { critical = 0, error = 0, warning = 0, other = 0, consoleOnly = 0 }
	local list = {}
	local msgs = type(r.messages) == "table" and r.messages or {}
	for i, m in ipairs(msgs) do
		local lv = type(m) == "table" and m.level or nil
		if lv == "Critical" then counts.critical = counts.critical + 1
		elseif lv == "Error" then counts.error = counts.error + 1
		elseif lv == "Warning" then counts.warning = counts.warning + 1
		else counts.other = counts.other + 1 end
		if type(m) == "table" and m.consoleOnly == true then counts.consoleOnly = counts.consoleOnly + 1 end
		if i <= limit then list[#list + 1] = m end
	end
	local text
	if counts.critical > 0 then text = "Validation: " .. counts.critical .. " Critical Issues"
	elseif counts.error > 0 and counts.warning > 0 then
		text = "Validation: " .. counts.error .. " Errors, " .. counts.warning .. " Warnings"
	elseif counts.error > 0 then text = "Validation: " .. counts.error .. " Errors"
	elseif counts.warning > 0 then text = "Validation: " .. counts.warning .. " Warnings"
	else text = "Validation: No Issues Found" end
	return { criticalPc = r.criticalPc, criticalConsole = r.criticalConsole, levelPc = r.levelPc,
		levelConsole = r.levelConsole, counts = counts, messageCount = #msgs, messages = M.array(list),
		truncated = #msgs > #list or nil, text = text }
end


---------------------------------------------------------------------------------------------------------------------
-- debug commands (remote_debug.lua does the game side): api.cmd.debug's stock amount and simulation steps, to cut
-- the waiting on maps made for tests (a harbour's stock filling up, a full load, a town growing). Test saves only.

M.DEBUG_FUNCTIONS = { stockSet = "api.cmd.debug.makeStockSetCargoAmountCmd",
	steps = "api.cmd.debug.makeGamePerformSimulationStepsCmd" }
M.STOCK_MAX_AMOUNT = 100000 -- a stock list's stock is also held to its capacity (the base debug panel's slider max)
M.STEPS_MAX = 10000
M.CARGO_NAME_MAX = 100

-- the debug function at path (DEBUG_FUNCTIONS) or nil. There or not goes by nil only: the engine's api entries are
-- callable tables whose metatable cannot be read (see terrainFunctions), so a callable check would miss them.
function M.debugFunction(path, root)
	return valueAt(path, root)
end

local function wholeNumber(v)
	local n = tonumber(v)
	if n == nil or n ~= n or n ~= math.floor(n) then return nil end
	return n
end

-- The stock lists under a construction, through its subconstructions as the base finds a warehouse's or an
-- industry's window from the construction (the base takes the first; the caller here refuses two or more)
-- (view_manager_util.tl: the WAREHOUSE / INDUSTRY component of one of con.subconstructions; the
-- stock list entity in its stockList, as cargo_util.getStockListEntityFromOwner). A warehouse (warehouse.script.lua)
-- has one subconstruction holding all its stocks: one mixed stock for the universal modules (their capacities
-- summed) and one stock for each specialized module. c: the CONSTRUCTION component; read(e, kind): that component
-- of e, or nil (only ids the engine has may reach getComponent: read checks). -> { { entity, kind, stockList } },
-- one per stock list (an owner listed twice, in subconstructions and industries, counts once).
M.STOCK_OWNER_KINDS = { "WAREHOUSE", "INDUSTRY", "TOWN_BUILDING" }
function M.stockOwnersOf(c, read)
	local out, seenEntity, seenList = {}, {}, {}
	if c == nil then return out end
	for _, list in ipairs({ "subconstructions", "industries", "townBuildings" }) do
		for _, v in ipairs(M.toList(M.field(c, list))) do
			v = tonumber(v)
			if v and v >= 0 and not seenEntity[v] then
				seenEntity[v] = true
				for _, kind in ipairs(M.STOCK_OWNER_KINDS) do
					local s = tonumber(M.field(read(v, kind), "stockList"))
					if s and s >= 0 then
						if not seenList[s] then
							seenList[s] = true
							out[#out + 1] = { entity = v, kind = kind, stockList = s }
						end
						break
					end
				end
			end
		end
	end
	return out
end

-- The warehouses whose WAREHOUSE component names construction e, for a construction whose subconstructions do
-- not list its warehouse (a game's warehouse 46841 of construction 46840 was not reached from 46840, 2026-11-23,
-- while entities --kind warehouse showed it so). ids: the entities with a WAREHOUSE component; read(v, kind) as for
-- stockOwnersOf. -> { { entity, kind = "WAREHOUSE", stockList } }, in the order of ids
function M.warehousesOf(e, ids, read)
	local out, seen = {}, {}
	for _, v in ipairs(M.toList(ids)) do
		v = tonumber(v)
		if v and v >= 0 and not seen[v] then
			seen[v] = true
			local w = read(v, "WAREHOUSE")
			local s = tonumber(M.field(w, "stockList"))
			if tonumber(M.field(w, "construction")) == e and s and s >= 0 then
				out[#out + 1] = { entity = v, kind = "WAREHOUSE", stockList = s }
			end
		end
	end
	return out
end

-- stockList: args entity (a stock list, an industry / town building / warehouse holding one, a construction with
-- one of those under it, or a vehicle)
function M.stockListArgs(args)
	args = type(args) == "table" and args or {}
	local e = wholeNumber(args.entity)
	if e == nil or e < 0 or e > M.MAX_ENTITY_ID then
		return nil, "give the entity: an industry's, station's or vehicle's id (industry-stocks, stations, vehicles)"
	end
	return { entity = e }
end

-- stockSet: entity (as stockList), stock (the stock's id, 0-based as the engine counts them; -1 = a vehicle's
-- load, which needs cargo), amount (0..STOCK_MAX_AMOUNT), cargo (a cargo type's resource name, e.g. COAL: optional
-- for a stock list's stock), dryRun. -> the request, or nil and why. Whether the stock is there and takes that
-- cargo and amount is checked in the game, against the stock list read there.
function M.stockSetRequest(args)
	args = type(args) == "table" and args or {}
	local r, err = M.stockListArgs(args)
	if not r then return nil, err end
	local stock = wholeNumber(args.stock)
	if stock == nil or stock < -1 or stock > 1000 then
		return nil, "stock must be a stock's id (0, 1, ... as stock list shows them; -1 for a vehicle's load)"
	end
	local amount = wholeNumber(args.amount)
	if amount == nil or amount < 0 or amount > M.STOCK_MAX_AMOUNT then
		return nil, "amount must be a whole number from 0 to " .. M.STOCK_MAX_AMOUNT
	end
	local cargo = args.cargo
	if cargo ~= nil then
		if type(cargo) ~= "string" or cargo == "" or #cargo > M.CARGO_NAME_MAX or cargo:find("[%c%s]") then
			return nil, "cargo must be a cargo type's name as stock list shows it (e.g. COAL)"
		end
	end
	if stock == -1 and cargo == nil then return nil, "stock -1 (a vehicle's load) needs cargo" end
	if args.dryRun ~= nil and type(args.dryRun) ~= "boolean" then return nil, "dryRun must be true or false" end
	r.stock, r.amount, r.cargo, r.dryRun = stock, amount, cargo, args.dryRun == true
	return r
end

-- steps: count (1..STEPS_MAX simulation steps), dryRun, allowRunning (send while the game is not paused)
function M.stepsRequest(args)
	args = type(args) == "table" and args or {}
	local n = wholeNumber(args.count)
	if n == nil or n < 1 or n > M.STEPS_MAX then
		return nil, "count must be a whole number from 1 to " .. M.STEPS_MAX
	end
	if args.dryRun ~= nil and type(args.dryRun) ~= "boolean" then return nil, "dryRun must be true or false" end
	if args.allowRunning ~= nil and type(args.allowRunning) ~= "boolean" then
		return nil, "allowRunning must be true or false"
	end
	return { count = n, dryRun = args.dryRun == true, allowRunning = args.allowRunning == true }
end

-- One step is 200 of game time (measured 2026-11-22, paused: steps 1 / 10 moved it 200 / 2000; 20 steps make a
-- day). The engine's callback comes before the steps have all run (steps 1000 answered at 100 of them; the rest
-- ran on at about 65 steps a second), so the answer waits for the steps' own marks.
M.STEP_GAME_TIME = 200
M.STEPS_WAIT_MIN_SEC = 30
M.STEPS_WAIT_SEC_PER_10000 = 200 -- 1000 steps took about 15 s on a small test save: 10000 at that pace, ~150 s

-- how long a steps command may take, from the send to the last step: at least STEPS_WAIT_MIN_SEC
function M.stepsWaitSec(count)
	return math.max(M.STEPS_WAIT_MIN_SEC, (tonumber(count) or 0) / 10000 * M.STEPS_WAIT_SEC_PER_10000)
end

-- whether steps sent at before (gameTime, updateCount) have all run by now: the update count up by count, or the
-- game time up by count steps. -> done, and which mark said so ("updateCount" / "gameTime"); nil when neither
-- can be read at both ends
function M.stepsDone(before, now, count)
	before, now = before or {}, now or {}
	local readable = false
	if before.updateCount and now.updateCount then
		readable = true
		if now.updateCount - before.updateCount >= count then return true, "updateCount" end
	end
	if before.gameTime and now.gameTime then
		readable = true
		if now.gameTime - before.gameTime >= count * M.STEP_GAME_TIME then return true, "gameTime" end
	end
	if not readable then return nil end
	return false
end


---------------------------------------------------------------------------------------------------------------------
-- town develop / town size (remote_town_grow.lua does the game side): buildings added at a point
-- (makeTownDevelopAtCmd) and a town's size factors set (makeTownUpdateSizeCmd), to give a test map's harbour or
-- station the houses and shops round it without running years of steps. Test saves only.

M.TOWN_GROW_FUNCTIONS = { develop = "api.cmd.makeTownDevelopAtCmd", size = "api.cmd.makeTownUpdateSizeCmd",
	vec2f = "api.type.Vec2f.new", send = "api.cmd.sendCommand" }
M.TOWN_DEVELOP_MAX = 200 -- commands in one town develop
M.TOWN_GROW_RADIUS = 250 -- default circle the buildings near the point are counted in (a harbour's catchment)
M.TOWN_GROW_RADIUS_MAX = 2000
-- a size factor's upper bound: the base's growth script raises the factors step by step from 1; a big jump with
-- updateAll would ask the engine for very many buildings at once
M.TOWN_GROW_SIZE_MAX = 5

local function flagArg(args, key)
	local v = args[key]
	if v ~= nil and type(v) ~= "boolean" then return nil, key .. " must be true or false" end
	return v == true
end

-- townDevelop: at ("x,y" or a list, metres), count (1..TOWN_DEVELOP_MAX, default 1), streets, upgrade (booleans,
-- default false), radius (m, for the counts near the point), dryRun. -> the request, or nil and why
function M.townDevelopRequest(args)
	args = type(args) == "table" and args or {}
	if args.at == nil then return nil, "give at (x,y in metres)" end
	local p, err = M.numberList(args.at, 2)
	if not p then return nil, "at: " .. err end
	if #p ~= 2 then return nil, "at needs x,y (finite numbers)" end
	local L = M.BUILD_LIMITS.xy
	if math.abs(p[1]) > L or math.abs(p[2]) > L then return nil, "at: x and y must be within " .. L end
	local n = args.count == nil and 1 or wholeNumber(args.count)
	if n == nil or n < 1 or n > M.TOWN_DEVELOP_MAX then
		return nil, "count must be a whole number from 1 to " .. M.TOWN_DEVELOP_MAX
	end
	local radius = args.radius == nil and M.TOWN_GROW_RADIUS or tonumber(args.radius)
	if not finite(radius) or radius <= 0 or radius > M.TOWN_GROW_RADIUS_MAX then
		return nil, "radius must be a number above 0 and at most " .. M.TOWN_GROW_RADIUS_MAX .. " (m)"
	end
	local r = { at = { x = p[1], y = p[2] }, count = n, radius = radius }
	for _, k in ipairs({ "streets", "upgrade", "dryRun" }) do
		local v, ferr = flagArg(args, k)
		if v == nil then return nil, ferr end
		r[k] = v
	end
	return r
end

-- townSize: entity (a town), factors ("r,c,i" or a list: residential, commercial, industrial, each
-- 0..TOWN_GROW_SIZE_MAX, as the town's sizeFactors), updateAll (boolean: all buildings to their target capacity),
-- dryRun. -> the request, or nil and why
function M.townSizeRequest(args)
	args = type(args) == "table" and args or {}
	local e = wholeNumber(args.entity)
	if e == nil or e < 0 or e > M.MAX_ENTITY_ID then return nil, "give the town's entity id (entities --kind town)" end
	if args.factors == nil then return nil, "give factors: residential,commercial,industrial (e.g. 1.5,1.2,1)" end
	local f, err = M.numberList(args.factors, 3)
	if not f then return nil, "factors: " .. err end
	if #f ~= 3 then return nil, "factors needs 3 numbers: residential,commercial,industrial" end
	for i = 1, 3 do
		if f[i] < 0 or f[i] > M.TOWN_GROW_SIZE_MAX then
			return nil, "factors: each from 0 to " .. M.TOWN_GROW_SIZE_MAX .. " (the town's sizeFactors; 1 as a new town)"
		end
	end
	local r = { entity = e, factors = f }
	for _, k in ipairs({ "updateAll", "dryRun" }) do
		local v, ferr = flagArg(args, k)
		if v == nil then return nil, ferr end
		r[k] = v
	end
	return r
end

-- town building counts: list of { town, kind ("residential" / "commercial" / "industrial" / nil), capacity, near
-- (true when within the circle) } -> { [town] = { buildings, residential, commercial, industrial, unknownKind,
-- capacity = {...}, near = { same, without capacity } } }, totals, nearTotals
local function emptyCount()
	return { buildings = 0, residential = 0, commercial = 0, industrial = 0, unknownKind = 0,
		capacity = { residential = 0, commercial = 0, industrial = 0 } }
end
local function addTo(c, b)
	c.buildings = c.buildings + 1
	if b.kind and c[b.kind] then
		c[b.kind] = c[b.kind] + 1
		c.capacity[b.kind] = c.capacity[b.kind] + (tonumber(b.capacity) or 0)
	else
		c.unknownKind = c.unknownKind + 1
	end
end
function M.townBuildingCounts(list)
	local towns, total, near = {}, emptyCount(), emptyCount()
	for _, b in ipairs(list or {}) do
		local t = b.town or -1
		towns[t] = towns[t] or emptyCount()
		addTo(towns[t], b)
		addTo(total, b)
		if b.near then addTo(near, b) end
	end
	return towns, total, near
end

-- the difference of two counts (after - before) in the plain kinds, nil when either is missing
function M.townCountDelta(before, after)
	if not before or not after then return nil end
	local d = {}
	for _, k in ipairs({ "buildings", "residential", "commercial", "industrial" }) do
		d[k] = (after[k] or 0) - (before[k] or 0)
	end
	return d
end

---------------------------------------------------------------------------------------------------------------------
-- parcels (read only, remote_parcels.lua): the town building parcels on each side of a road piece (edge)

M.PARCELS_RECT_MAX = 2000 -- m, a rect's longest side
M.PARCELS_MAX_EDGES = 400 -- edges answered for a rect; more are counted, not listed (truncated)
-- ParcelData's two lists: type.d.tl names them leftEntities and rightParcels (the engine's binding has two names of
-- 12 letters, as those are); the other spellings are read too, in case the documentation is off
M.PARCEL_LEFT_FIELDS = { "leftEntities", "leftParcels" }
M.PARCEL_RIGHT_FIELDS = { "rightParcels", "rightEntities" }

-- edge (one road piece's entity) or rect ("x0,y0,x1,y1" or a list, metres; either order), list (parcels one by one:
-- on for an edge, off for a rect unless asked). -> { edge, list } / { rect = { x0, y0, x1, y1 }, list }, or nil, why
function M.parcelsRequest(args)
	args = type(args) == "table" and args or {}
	if (args.edge == nil) == (args.rect == nil) then return nil, "give edge (a road piece's id) or rect (x0,y0,x1,y1)" end
	local list, lerr = flagArg(args, "list")
	if list == nil then return nil, lerr end
	if args.edge ~= nil then
		local e = wholeNumber(args.edge)
		if e == nil or e < 0 or e > M.MAX_ENTITY_ID then return nil, "edge must be a road piece's entity id (0 or more)" end
		return { edge = e, list = args.list == nil or list }
	end
	local r, err = M.numberList(args.rect, 4)
	if not r then return nil, "rect: " .. err end
	if #r ~= 4 then return nil, "rect needs x0,y0,x1,y1" end
	local L = M.BUILD_LIMITS.xy
	for i = 1, 4 do if math.abs(r[i]) > L then return nil, "rect: x and y must be within " .. L end end
	local x0, x1 = math.min(r[1], r[3]), math.max(r[1], r[3])
	local y0, y1 = math.min(r[2], r[4]), math.max(r[2], r[4])
	if x1 - x0 > M.PARCELS_RECT_MAX or y1 - y0 > M.PARCELS_RECT_MAX then
		return nil, "rect: at most " .. M.PARCELS_RECT_MAX .. " m a side"
	end
	return { rect = { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }, list = list }
end

-- whether point p ({ x, y }) is in the rect (edges included)
function M.inRect(p, r)
	return p ~= nil and p.x ~= nil and p.y ~= nil and p.x >= r.x0 and p.x <= r.x1 and p.y >= r.y0 and p.y <= r.y1
end

-- a ParcelData (a table or the engine's record) -> left ids, right ids (lists of numbers), the field names read.
-- The first spelling there wins for each side; nil data gives two empty lists.
function M.parcelSides(pd)
	local fields = {}
	local function side(names)
		for _, k in ipairs(names) do
			local v = pd ~= nil and M.field(pd, k) or nil
			if v ~= nil then
				fields[#fields + 1] = k
				local out = {}
				for _, x in ipairs(M.toList(v)) do
					local n = tonumber(x)
					if n then out[#out + 1] = n end
				end
				return out
			end
		end
		return {}
	end
	local left = side(M.PARCEL_LEFT_FIELDS)
	local right = side(M.PARCEL_RIGHT_FIELDS)
	return left, right, fields
end

-- a parcel's faces (Parcel.faces: each with points, Vec3f) -> { x, y, z (the mean of all points), area (m², the
-- faces' areas seen from above, summed: shoelace), faces, points }, or nil when no point reads
function M.faceSummary(faces)
	local sx, sy, sz, n, area, nf = 0, 0, 0, 0, 0, 0
	for _, f in ipairs(M.toList(faces)) do
		local pts = {}
		for _, p in ipairs(M.toList(M.field(f, "points"))) do
			local x, y, z = tonumber(M.field(p, "x")), tonumber(M.field(p, "y")), tonumber(M.field(p, "z"))
			if finite(x) and finite(y) then
				pts[#pts + 1] = { x, y }
				sx, sy, sz, n = sx + x, sy + y, sz + (finite(z) and z or 0), n + 1
			end
		end
		if #pts > 0 then nf = nf + 1 end
		local a = 0
		for i = 1, #pts do
			local p, q = pts[i], pts[i % #pts + 1]
			a = a + p[1] * q[2] - q[1] * p[2]
		end
		area = area + math.abs(a) / 2
	end
	if n == 0 then return nil end
	local function r2(v) return math.floor(v * 100 + 0.5) / 100 end
	return { x = r2(sx / n), y = r2(sy / n), z = r2(sz / n), area = r2(area), faces = nf, points = n }
end

---------------------------------------------------------------------------------------------------------------------
-- company / company init (remote_company.lua)

-- the world's population as the base's company_util.computeWorldPopulation counts it: the residential capacity
-- (the first of each town's person capacities) summed over the towns. nil when the map could not be read
function M.worldPopulation(capsMap)
	if capsMap == nil then return nil end
	local total = 0
	local ok = pcall(function()
		for _, caps in pairs(capsMap) do total = total + (tonumber(M.at(caps, 1)) or 0) end
	end)
	return ok and total or nil
end

-- what a company read says, in one line. Measured 2026-11-23 (e2e of 32bfbc7): a newgame game with generated towns
-- has its basePopulation (793) and a rank after 10 days without company init; one started with no towns
-- (--no-towns, or a flat base with towns placed later) has basePopulation 0, and company_growth then never makes
-- its state (its update returns while basePopulation <= 0), also after towns were placed
function M.companyDiagnosis(s)
	if s.mapEditor then return "the map editor: the base's company scripts do nothing here" end
	if s.mission then return "a mission: company progression is the mission's" end
	if not s.company.running then return "the base's company script is not running" end
	local world = tonumber(s.worldPopulation) or 0
	if not s.company.initialized then
		return "company.gs has no basePopulation: the game's start event (initNewGameFromMap) has not set it (not "
			.. "seen in a game yet). company init sends it"
	end
	if s.company.basePopulation == 0 then
		if world > 0 then
			return "basePopulation is 0 (the game started with no town population); the towns have " .. world
				.. " now. company_growth does nothing while it is 0 (no rank, no ticket price multiplier): company "
				.. "init sends the start event again, for a basePopulation from today's towns"
		end
		return "basePopulation is 0 and the towns have no population: company_growth does nothing (no rank), as in "
			.. "the base. Place towns, let them grow a little, then company init"
	end
	if not s.growth.initialized then
		return "basePopulation is set; company_growth has no companyState yet (it makes it in its update: run the "
			.. "game a few days and look again)"
	end
	return "the company scripts have their state, as after the base's new-game page"
end

-- whether company init sends the start event: { send, reason, noPopulation }. force always sends (refusals aside)
function M.companyInitDecision(s, force)
	local base, world = s.company.basePopulation, tonumber(s.worldPopulation) or 0
	if force then return { send = true, reason = "forced" } end
	if base == nil then return { send = true, reason = "company.gs has no basePopulation" } end
	if base == 0 and world > 0 then
		return { send = true, reason = "basePopulation is 0 and the towns have " .. world .. " now" }
	end
	if base == 0 then
		return { send = false, noPopulation = true, reason = "basePopulation is 0 and the towns have no population: "
			.. "the event would set it to 0 again. Place towns, then company init (force = true sends anyway)" }
	end
	return { send = false, reason = "company.gs has its basePopulation (" .. tostring(base) .. "): nothing to do "
		.. "(force = true sends anyway, which resets the company's progression)" }
end

-- whether a read after a send shows the event ran: basePopulation set anew (other than before); company.script's
-- companies emptied; company_growth's entry for the player gone, or made again lower (its update makes it again
-- at once from basePopulation: experience = the population, level 1). A forced send on a map whose population and
-- company did not change may show none of these. From nil the base's legacy update (company_legacy_util, version
-- below 2) also sets basePopulation without any event, so that case cannot tell them apart
function M.companyInitSeen(before, now)
	local b, n = before.company.basePopulation, now.company.basePopulation
	if n ~= nil and n ~= b then return true end
	if (before.company.companies or 0) > 0 and now.company.companies == 0 then return true end
	local bp, np = before.growth.player, now.growth.player
	if bp and not np then return true end
	if bp and np then
		for _, k in ipairs({ "level", "potentialLevel", "experience" }) do
			local x, y = tonumber(bp[k]), tonumber(np[k])
			if x and y and y < x then return true end
		end
	end
	return false
end

-- what the base's company button at the bottom left shows (game_bar.tl CompanyButton, read 2026-11-23): the rank
-- when company_growth's entry for the player has experience above 0, else the word "Achievements"
function M.companyRankButton(player)
	if type(player) == "table" and (tonumber(player.experience) or 0) > 0 then return "rank" end
	return "achievements"
end

-- why company init must not send (nil: it may)
function M.companyInitRefusal(s)
	if s.mapEditor then return "not in the map editor: the base's company scripts do nothing there" end
	if s.mission then return "not in a mission: its start event is the mission's own (initMission)" end
	if not s.company.running then return "the base's company script (" .. tostring(s.company.script) .. ") is not running" end
	return nil
end

---------------------------------------------------------------------------------------------------------------------
-- town connections / town connect (remote_town_connect.lua)

M.TOWN_CONNECT_MAX_TOWNS = 64
M.TOWN_CONNECT_MAX_PAIRS = 256

-- a list of entity ids: "1,2" or { 1, 2 }. -> list, or nil and why
local function entityIds(v, what, most)
	local parts = {}
	if type(v) == "string" then
		for part in (v .. ","):gmatch("([^,]*),") do parts[#parts + 1] = part end
	elseif type(v) == "number" then
		parts[1] = v
	elseif type(v) == "table" then
		for i = 1, #v do parts[i] = v[i] end
	else
		return nil, what .. ": give entity ids separated by commas"
	end
	if #parts == 0 then return nil, what .. ": empty" end
	if #parts > most then return nil, what .. ": at most " .. most end
	local out, seen = {}, {}
	for _, x in ipairs(parts) do
		local e = wholeNumber(x)
		if e == nil or e < 0 or e > M.MAX_ENTITY_ID then return nil, what .. ": not an entity id: " .. tostring(x) end
		if seen[e] then return nil, what .. ": " .. e .. " twice" end
		seen[e] = true
		out[#out + 1] = e
	end
	return out
end

-- "801:802,802:803" or { { 801, 802 }, ... } (town entity ids) -> list of { a, b }, or nil and why
local function townPairs(v)
	local list = {}
	if type(v) == "string" then
		for part in (v .. ","):gmatch("([^,]*),") do
			local a, b = part:match("^%s*([^:]+):([^:]+)%s*$")
			if not a then return nil, "pairs: write town:town, e.g. 801:802 (not " .. part .. ")" end
			list[#list + 1] = { a, b }
		end
	elseif type(v) == "table" then
		for i = 1, #v do
			if type(v[i]) ~= "table" then return nil, "pairs: each a pair { town, town }" end
			list[i] = { v[i][1], v[i][2] }
		end
	else
		return nil, "pairs: write town:town,town:town"
	end
	if #list == 0 then return nil, "pairs: empty" end
	if #list > M.TOWN_CONNECT_MAX_PAIRS then return nil, "pairs: at most " .. M.TOWN_CONNECT_MAX_PAIRS end
	local out = {}
	for _, p in ipairs(list) do
		local a, b = wholeNumber(p[1]), wholeNumber(p[2])
		if not (a and b and a >= 0 and b >= 0 and a <= M.MAX_ENTITY_ID and b <= M.MAX_ENTITY_ID) then
			return nil, "pairs: not town ids: " .. tostring(p[1]) .. ":" .. tostring(p[2])
		end
		if a == b then return nil, "pairs: a town with itself (" .. a .. ")" end
		out[#out + 1] = { a, b }
	end
	return out
end

-- townConnections: entity (one town, optional). -> the request, or nil and why
function M.townConnectionsRequest(args)
	args = type(args) == "table" and args or {}
	local r = {}
	if args.indexBase ~= nil then
		if args.indexBase ~= 0 and args.indexBase ~= 1 then return nil, "indexBase must be 0 or 1" end
		r.indexBase = args.indexBase
	end
	if args.entity == nil then return r end
	local e = wholeNumber(args.entity)
	if e == nil or e < 0 or e > M.MAX_ENTITY_ID then return nil, "entity: a town's id (entities --kind town)" end
	r.entity = e
	return r
end

-- townConnect: auto (makeTownAutoDetectConnectionsCmd: detect connections over the roads there are) or build
-- (makeTownConnectWithIndustriesCmd: streets between the towns of the connections, and to all industries, as the
-- map editor's Generate). entities (towns; nil: all), pairs (build: town:town to add), default (build: add the
-- engine's default connections, as the editor's Propose Default Connections), keep (build: keep the street
-- connections there are; default true, false removes them), indexBase (0 or 1: how the engine numbers the towns
-- in its connections, when the map does not tell), dryRun. -> the request, or nil and why
function M.townConnectRequest(args)
	args = type(args) == "table" and args or {}
	local r = {}
	for _, k in ipairs({ "auto", "build", "default", "dryRun" }) do
		local v, err = flagArg(args, k)
		if v == nil then return nil, err end
		r[k] = v
	end
	if r.auto == r.build then return nil, "give auto (detect the connections over the roads) or build (streets), one of them" end
	if args.keep ~= nil and type(args.keep) ~= "boolean" then return nil, "keep must be true or false" end
	r.keep = args.keep ~= false
	if args.entities ~= nil then
		local list, err = entityIds(args.entities, "entities", M.TOWN_CONNECT_MAX_TOWNS)
		if not list then return nil, err end
		r.entities = list
	end
	if args.pairs ~= nil then
		local list, err = townPairs(args.pairs)
		if not list then return nil, err end
		r.pairs = list
	end
	if args.indexBase ~= nil then
		if args.indexBase ~= 0 and args.indexBase ~= 1 then return nil, "indexBase must be 0 or 1" end
		r.indexBase = args.indexBase
	end
	if r.auto and (r.pairs or r.default or args.keep ~= nil) then
		return nil, "pairs, default and keep go with build (auto only detects, it builds nothing)"
	end
	return r
end

-- how the engine numbers towns in a map's townConnections: 0 when an index 0 is there, 1 when the index n (the
-- number of towns) is, else nil (not told by these lists)
function M.townIndexBase(lists, n)
	local zero, top = false, false
	for _, list in ipairs(lists) do
		for _, p in ipairs(list or {}) do
			for _, i in ipairs({ tonumber(M.at(p, 1)), tonumber(M.at(p, 2)) }) do
				if i == 0 then zero = true end
				if i == n then top = true end
			end
		end
	end
	if zero and not top then return 0 end
	if top and not zero then return 1 end
	return nil
end

-- index pairs -> { { from, to } } of town entities (towns: the map's list in its order, each { entity, name }).
-- base nil: pairs left unresolved. An index out of range is kept with its entity nil
function M.townPairsResolved(raw, towns, base)
	local out = {}
	for _, p in ipairs(raw or {}) do
		local a, b = tonumber(M.at(p, 1)), tonumber(M.at(p, 2))
		local row = { index = { a, b } }
		if base ~= nil and a and b then
			local ta, tb = towns[a + 1 - base], towns[b + 1 - base]
			row.from = ta and ta.entity or nil
			row.to = tb and tb.entity or nil
			row.fromName = ta and ta.name or nil
			row.toName = tb and tb.name or nil
		end
		out[#out + 1] = row
	end
	return out
end

-- what build sends: the towns (the chosen ones, in the map's order) and the connections as index pairs into that
-- list in the engine's numbering. mapTowns: { { entity, name } } in the map's order; existing / defaults: the map's
-- townConnections and the engine's default ones (index pairs); base: the engine's numbering (nil: not known).
-- -> { townEntities, connections, pairs (as entity pairs), dropped }, or nil and why
function M.townConnectPlan(r, mapTowns, existing, defaults, base)
	-- nothing chosen and nothing added: the map's towns and pairs as they are, as the editor's Generate sends them
	-- (no numbering needed then), when every town has its entity
	if not r.entities and not r.pairs and not r.default then
		local all, ents = true, {}
		for i, t in ipairs(mapTowns) do
			if t.entity == nil then all = false end
			ents[i] = t.entity
		end
		if all then
			local conns = {}
			for i, p in ipairs(existing or {}) do conns[i] = { tonumber(M.at(p, 1)), tonumber(M.at(p, 2)) } end
			return { townEntities = ents, connections = conns,
				pairs = M.townPairsResolved(existing, mapTowns, base), dropped = 0, asMap = true }
		end
	end
	local pos = {}
	for i, t in ipairs(mapTowns) do if t.entity ~= nil then pos[t.entity] = i end end
	local chosen = {}
	if r.entities then
		for _, e in ipairs(r.entities) do
			if not pos[e] then return nil, "entity " .. e .. " is no town of this map (town connections lists them)" end
			chosen[e] = true
		end
	else
		for _, t in ipairs(mapTowns) do if t.entity ~= nil then chosen[t.entity] = true end end
	end
	local list = {}
	for _, t in ipairs(mapTowns) do if t.entity ~= nil and chosen[t.entity] then list[#list + 1] = t.entity end end
	local newIndex = {}
	for i, e in ipairs(list) do newIndex[e] = i end
	local wanted, seen, dropped = {}, {}, 0
	local function add(a, b)
		if a == nil or b == nil or a == b then dropped = dropped + 1; return end
		if not (newIndex[a] and newIndex[b]) then dropped = dropped + 1; return end
		local k = math.min(a, b) .. ":" .. math.max(a, b)
		if seen[k] then return end
		seen[k] = true
		wanted[#wanted + 1] = { a, b }
	end
	local fromMap = {} -- (index pairs into mapTowns, all of it, towns without an entity too)
	for _, p in ipairs(existing or {}) do fromMap[#fromMap + 1] = p end
	if r.default then for _, p in ipairs(defaults or {}) do fromMap[#fromMap + 1] = p end end
	if #fromMap > 0 and base == nil then
		return nil, "how the engine numbers the towns in its connections is not known on this map (no index 0 or "
			.. #mapTowns .. " in them): give indexBase 0 or 1"
	end
	for _, row in ipairs(M.townPairsResolved(fromMap, mapTowns, base)) do add(row.from, row.to) end
	for _, p in ipairs(r.pairs or {}) do
		if not (pos[p[1]] and pos[p[2]]) then
			return nil, "pairs: " .. p[1] .. ":" .. p[2] .. " is not two towns of this map"
		end
		if not (newIndex[p[1]] and newIndex[p[2]]) then
			return nil, "pairs: " .. p[1] .. ":" .. p[2] .. " has a town that is not among entities"
		end
		add(p[1], p[2])
	end
	if #wanted > 0 and base == nil then
		return nil, "how the engine numbers the towns in its connections is not known on this map: give indexBase 0 or 1"
	end
	local conns = {}
	for i, p in ipairs(wanted) do conns[i] = { newIndex[p[1]] - 1 + base, newIndex[p[2]] - 1 + base } end
	return { townEntities = list, connections = conns, pairs = wanted, dropped = dropped }
end

---------------------------------------------------------------------------------------------------------------------
-- around (read only, remote_around.lua): what stands near a point, one entry per entity with its kind and box

M.AROUND_RADIUS = { default = 100, max = 2000 } -- m
M.AROUND_LIMIT = { default = 200, max = 2000 } -- entries listed (nearest first); more are counted, not listed
M.AROUND_SCAN_MAX = 10000 -- entities the octree gives that are looked at; more: truncated (dropped says how many)
-- the time the entities are looked at for, in one frame of the GUI: past it the rest is left (timeTruncated)
M.AROUND_TIME_MS = 2000
-- every kind an entry can have; the default leaves out nodes (each road end: the pieces are listed) and what moves
M.AROUND_KINDS = { "street", "track", "node", "town_building", "station", "depot", "industry", "construction",
	"field", "asset", "town", "model", "moving", "other", "map" }
-- map: an entity whose box spans AROUND_MAP_SIZE both ways (the terrain, the world or a grid over the map) never
-- stands in a build's way (a road depot's fit met entity 2, a box 14,336 m square, at every place, 2026-11-23):
-- off unless asked for
M.AROUND_DEFAULT_OFF = { node = true, moving = true, map = true }
M.AROUND_MAP_SIZE = 2000 -- m, both sides: more than any station or industry, less than the smallest map
-- a road or track piece is a line with a width: half of these, a guess (not read from the street type)
M.AROUND_HALF_WIDTH = { street = 6, track = 3 }

-- at ("x,y" or a list), radius, kinds (a list or "a,b"; "all": every kind), limit. -> the request, or nil and why
function M.aroundRequest(args)
	args = type(args) == "table" and args or {}
	if args.at == nil then return nil, "give at (x,y in metres)" end
	local p, err = M.numberList(args.at, 3)
	if not p then return nil, "at: " .. err end
	if #p < 2 then return nil, "at needs x,y (finite numbers)" end
	local L = M.BUILD_LIMITS.xy
	if math.abs(p[1]) > L or math.abs(p[2]) > L then return nil, "at: x and y must be within " .. L end
	local r = M.AROUND_RADIUS.default
	if args.radius ~= nil then
		r = tonumber(args.radius)
		if not finite(r) or r <= 0 or r > M.AROUND_RADIUS.max then
			return nil, string.format("radius must be more than 0 and at most %g m", M.AROUND_RADIUS.max)
		end
	end
	local limit = M.AROUND_LIMIT.default
	if args.limit ~= nil then
		limit = wholeNumber(args.limit)
		if limit == nil or limit < 1 or limit > M.AROUND_LIMIT.max then
			return nil, "limit must be a whole number 1-" .. M.AROUND_LIMIT.max
		end
	end
	local known, kinds = {}, {}
	for _, k in ipairs(M.AROUND_KINDS) do known[k] = true end
	if args.kinds == nil then
		for _, k in ipairs(M.AROUND_KINDS) do if not M.AROUND_DEFAULT_OFF[k] then kinds[k] = true end end
	else
		local list = args.kinds
		if type(list) == "string" then
			local t = {}
			for part in (list .. ","):gmatch("([^,]*),") do t[#t + 1] = part end
			list = t
		end
		if type(list) ~= "table" or #list == 0 then return nil, "kinds: give kind names separated by commas" end
		for _, k in ipairs(list) do
			k = type(k) == "string" and k:gsub("^%s+", ""):gsub("%s+$", "") or k
			if k == "all" then
				for _, a in ipairs(M.AROUND_KINDS) do kinds[a] = true end
			elseif known[k] then
				kinds[k] = true
			else
				return nil, "kinds: unknown kind " .. tostring(k) .. " (one of all, " .. table.concat(M.AROUND_KINDS, ", ") .. ")"
			end
		end
	end
	if args.lanes ~= nil and type(args.lanes) ~= "boolean" then return nil, "lanes must be true or false" end
	return { x = p[1], y = p[2], radius = r, limit = limit, kinds = kinds, lanes = args.lanes == true }
end

-- lanes (read only, remote_lanes.lua): edges ("a,b" or a list of road / track piece ids, 1-EDGE_LANES_MAX),
-- network (default true: the transport network's edges too) -> the request, or nil and why
M.EDGE_LANES_MAX = 20
function M.edgeLanesRequest(args)
	args = type(args) == "table" and args or {}
	local list = args.edges
	if type(list) == "number" then list = { list } end
	if type(list) == "string" then
		local t = {}
		for part in (list .. ","):gmatch("([^,]*),") do t[#t + 1] = part end
		list = t
	end
	if type(list) ~= "table" or #list == 0 then return nil, "edges: give piece ids separated by commas" end
	if #list > M.EDGE_LANES_MAX then return nil, "edges: at most " .. M.EDGE_LANES_MAX .. " pieces" end
	local out = {}
	for _, x in ipairs(list) do
		local n = tonumber(type(x) == "string" and x:gsub("^%s+", ""):gsub("%s+$", "") or x)
		if n == nil or n ~= math.floor(n) or n < 0 or n > 2 ^ 31 then
			return nil, "edges: " .. tostring(x) .. " is no entity id (a whole number, 0 or more)"
		end
		out[#out + 1] = n
	end
	if args.network ~= nil and type(args.network) ~= "boolean" then return nil, "network must be true or false" end
	return { edges = out, network = args.network ~= false }
end

-- a transf's turn about the vertical (radians) from its first column (m11, m12: cos, sin); nil when not readable
function M.transfAngle(m11, m12)
	if not (finite(m11) and finite(m12)) or (m11 == 0 and m12 == 0) then return nil end
	return math.atan2(m12, m11)
end

-- a point in a construction's own frame: place = { x, y, z, angle } -> { dx, dy, dz } (dx along its x axis)
function M.toLocal(place, x, y, z)
	local a = place.angle or 0
	local ox, oy = x - place.x, y - place.y
	local c, s = math.cos(a), math.sin(a)
	local function r3(v) return math.floor(v * 1000 + 0.5) / 1000 end
	return { dx = r3(c * ox + s * oy), dy = r3(-s * ox + c * oy),
		dz = (z and place.z) and r3(z - place.z) or nil }
end

-- the distance in the plane from (px, py) to a box { x0, y0, x1, y1 } (0 inside it)
function M.distToBox(px, py, b)
	local dx = math.max(b.x0 - px, 0, px - b.x1)
	local dy = math.max(b.y0 - py, 0, py - b.y1)
	return math.sqrt(dx * dx + dy * dy)
end

-- the distance in the plane from (px, py) to the segment a-b ({ x, y } each)
function M.distToSegment(px, py, a, b)
	local vx, vy = b.x - a.x, b.y - a.y
	local L2 = vx * vx + vy * vy
	local t = L2 > 0 and ((px - a.x) * vx + (py - a.y) * vy) / L2 or 0
	t = math.max(0, math.min(1, t))
	local qx, qy = a.x + t * vx, a.y + t * vy
	return math.sqrt((px - qx) ^ 2 + (py - qy) ^ 2)
end

-- a bounding volume's bbox (Box3 with min / max Vec3f, or the engine's userdata) -> { x0, y0, z0, x1, y1, z1 } or nil
function M.boxOf(bb)
	local lo, hi = bb and M.field(bb, "min"), bb and M.field(bb, "max")
	local x0, y0, z0 = tonumber(lo and M.field(lo, "x")), tonumber(lo and M.field(lo, "y")), tonumber(lo and M.field(lo, "z"))
	local x1, y1, z1 = tonumber(hi and M.field(hi, "x")), tonumber(hi and M.field(hi, "y")), tonumber(hi and M.field(hi, "z"))
	if not (finite(x0) and finite(y0) and finite(x1) and finite(y1)) then return nil end
	return { x0 = math.min(x0, x1), y0 = math.min(y0, y1), z0 = z0, x1 = math.max(x0, x1), y1 = math.max(y0, y1), z1 = z1 }
end

return M
