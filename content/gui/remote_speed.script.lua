-- The speed buttons with a label to their right: "×16 実測×3.2 →2045-07-03" (room: remote_speed.css.lua).
-- The base buttons are 0/1/2/4 only (game_bar_widgets.tl) and select none for other speeds, so a speed set by the
-- remote probe was invisible in game. The base recipe (or another mod's replacement of it) is drawn unchanged;
-- the label is added beside it, not into it, so other mods' buttons (and base updates) still apply.
-- The recipe's meta (id "menu.dateSpeedControl", disableFocusableRecursive) is taken off its params by react and
-- applied to this wrapper, which holds the base buttons.
--
-- NO GAME API IN THE RECIPE BODY OR ITS STEPS. React runs recipes and their step functions on Main Pool worker
-- threads too, and api.util.getApplicationTime dereferences a main-thread-only pointer there: TF3 crashed with
-- SIGSEGV right after every load (5 times, 2026-11-15 21:39-21:53 JST), uncatchable by pcall. The only
-- game calls are inside react.enqueueJoin, which the base runs on the main thread after the parallel phase.
--
-- What to show and do comes from the guiUpdate script (remote.script.lua, publishUi) through the GUI save data
-- (api.gui.game.getGuiSaveData), which the game keeps per mod in C++: this recipe runs in a Lua state of its own,
-- so a shared Lua table never reached it (no label in game, 2026-11-15 22:49 JST).
local req = ug_require or require
local react = req "::/gui/main/react.lua"
local builtin = req "::/gui/main/builtin.lua"
local game_bar_widgets = req "::/gui/game_bar/game_bar_widgets.tl"
local MOD = (getOwningModId and getOwningModId()) or "hummer_remote_probe"
local core = req(MOD .. "::/remote_core.lua")
local vc = req(MOD .. "::/vehicle_configs.lua")
local lc = req(MOD .. "::/line_configs.lua")

local READ_SEC = 0.5
-- where the vehicle reports go: a key of their own, so this recipe never writes over what the guiUpdate script
-- publishes under MOD (each side writes one key, reads the other)
local REPORT_KEY = MOD .. ".vehicles"
local LINE_REPORT_KEY = MOD .. ".lines"
local REPORTS_KEPT = 10

-- a replacement another mod installed before this one (e.g. Time Warp's 8x/16x buttons, order 10): drawn
-- instead of the base buttons, so the label adds to it rather than undoing it. Replacement configs run in
-- ascending order (bootstrap_game.tl), and ours is 500.
local previous

-- our own speed controls, from this load or an earlier copy of this script: never "previous", or the label
-- would draw itself inside itself on every render (install run twice) or twice (script loaded again)
core.shared.ownSpeedControls = core.shared.ownSpeedControls or setmetatable({}, { __mode = "k" })

local function findPrevious()
	local ok, prev = pcall(function()
		return _react.recipeReplace[react.GetRecipeId(game_bar_widgets.GameSpeedControl)]
	end)
	if not ok or type(prev) ~= "function" or core.shared.ownSpeedControls[prev] then return nil end
	return prev
end

-- once per distinct failure: a request that fails every time must not flood the log
local function warnOnce(warnedRef, key, msg)
	local w = warnedRef:get() or {}
	if w[key] then return end
	w[key] = true
	warnedRef:set(w)
	print("[remote_probe] " .. msg) -- main thread (join): plain print
end

-- the window, event or tool of one request (main thread, in the join). gameCtx: the base passes it in the speed
-- control's params; its tool stack is what the base's own buttons push their tools onto.
local function perform(open, gameCtx, warnedRef)
	if open.entity then
		-- as the base statistics and line windows open an entity's window
		local ok, err = pcall(react.fireEvent, nil, "selectEntity", { entity = open.entity, stack = false })
		if not ok then warnOnce(warnedRef, "selectEntity " .. tostring(err), "selectEntity failed: " .. tostring(err)) end
	end
	if open.event then
		local ok, err = pcall(react.fireEvent, nil, open.event.name, open.event.param)
		local msg = "event " .. open.event.name .. " failed: " .. tostring(err)
		if not ok then warnOnce(warnedRef, msg, msg) end
	end
	if open.tool then
		local t = open.tool
		local ok, err = pcall(function()
			local m = req(t.module)
			local def = t.field and m[t.field] or m
			if type(def) ~= "table" then error(t.module .. (t.field and ("." .. t.field) or "") .. " is not a tool") end
			if not gameCtx or not gameCtx.toolStack then error("no gameCtx.toolStack in the speed control's params") end
			local stack = gameCtx.toolStack:get():getApi()
			if t.close then stack.pop(def, nil) else stack.push(def, nil, { gameCtx = gameCtx }) end
		end)
		local msg = "tool " .. t.module .. " failed: " .. tostring(err)
		if not ok then warnOnce(warnedRef, msg, msg) end
	end
end

-- the requests of the guiUpdate script that run here (gui way): vehicles (vehicle_configs.performGui) and lines
-- (line_configs.performGui), each run once. One channel each: its own list in the GUI save data and its own
-- report key. Kept for the life of this Lua state, not in the recipe's refs: a speed control mounted again (its
-- refs new) would take the waiting requests for old ones and never run them, and lose the reports.
-- handled: request id -> true, nil until the first read. What that read finds is taken as old: the guiUpdate
-- script empties the lists when a game loads (init), but nothing orders that before this recipe's first join, so
-- a request left in the loaded save could still be there.
-- reports: newest last; written whenever one changes (the base's callbacks fill them in later).
local function newChannel(key, run, what)
	return { key = key, perform = run, what = what, handled = nil, reports = { list = {} } }
end
local channels = {
	vehicles = newChannel(REPORT_KEY, vc.performGui, "vehicle"),
	lines = newChannel(LINE_REPORT_KEY, lc.performGui, "line"),
}

-- main thread (join)
local function performChannel(ch, list, warnedRef)
	if ch.handled == nil then
		ch.handled = {}
		for _, r in ipairs(list) do ch.handled[r.id] = true end
		return
	end
	local handled, reports = ch.handled, ch.reports
	for _, r in ipairs(list) do
		if not handled[r.id] then
			handled[r.id] = true
			local report = { id = r.id, kind = r.kind }
			reports.list[#reports.list + 1] = report
			while #reports.list > REPORTS_KEPT do table.remove(reports.list, 1) end
			local ok, err = pcall(ch.perform, req, r, report)
			if not ok then report.error = tostring(err) end
		end
	end
	if #reports.list == 0 then return end
	local text = core.json(reports.list)
	if text == reports.sent then return end
	local ok, err = pcall(function() api.gui.game.setGuiSaveData(ch.key, { reports = core.plain(reports.list) }) end)
	if ok then
		reports.sent = text
	else
		warnOnce(warnedRef, ch.what .. " report " .. tostring(err), ch.what .. " report not written: " .. tostring(err))
	end
end

local SpeedControl = react.RegisterRecipe("HummerRemoteSpeedControl", function(params)
	local state = react.useState({ label = "", tip = "" })
	-- nil until the first read: a request already in the save data when the game loads is old, not opened
	local seenSeq = react.useRef(nil)
	local warnedRef = react.useRef(nil)
	-- the newest params, for the join (a timer registered on an earlier render would see old ones)
	local paramsRef = react.useRef(nil)
	paramsRef:set(params)
	react.onStepTimer(function()
		react.enqueueJoin(function()
			local ok, d = pcall(function() return api.gui.game.getGuiSaveData(MOD) end)
			if not ok then return end
			local r = core.uiRequest(d)
			local old = state:old() or {}
			if r.label ~= old.label or r.tip ~= old.tip then state:set({ label = r.label, tip = r.tip }) end
			for name, ch in pairs(channels) do
				local okV, errV = pcall(performChannel, ch, r[name] or {}, warnedRef)
				if not okV then warnOnce(warnedRef, name .. " " .. tostring(errV), ch.what .. " requests failed: " .. tostring(errV)) end
			end
			local seq = r.open and r.open.seq or false
			if seenSeq:get() == nil then
				seenSeq:set(seq)
			elseif seq and seq ~= seenSeq:get() then
				seenSeq:set(seq)
				local p = paramsRef:get()
				perform(r.open, type(p) == "table" and p.gameCtx or nil, warnedRef)
			end
		end, "HummerRemoteSpeedControl:read")
	end, READ_SEC)
	local v = state:old() or {}
	local buttons
	if previous then
		buttons = previous(params)
	else
		buttons = react.CallOriginalRecipe(game_bar_widgets.GameSpeedControl, params)
	end
	local children = { buttons }
	if v.label ~= nil and v.label ~= "" then
		children[#children + 1] = builtin.TextView{
			-- the speed row sits in a mouseTransparent component; the label takes the mouse for its tooltip
			meta = { class = "font-scale-body, hummer-remote-speed", tooltip = v.tip, mouseTransparent = false },
			text = v.label,
		}
	end
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Horizontal,
		children = children,
	}
end)

core.shared.ownSpeedControls[SpeedControl] = true

local exports = {}

function exports.install(replacementApi)
	previous = findPrevious()
	replacementApi.ReplaceRecipe(game_bar_widgets.GameSpeedControl, SpeedControl)
end

exports.SpeedControl = SpeedControl

function data()
	return exports
end
