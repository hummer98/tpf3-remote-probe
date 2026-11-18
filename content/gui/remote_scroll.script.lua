-- tf3ctl scroll: the base entity windows' scrolled content (industry, town, warehouse, construction windows) to
-- its top or bottom. The base ScrollArea takes no scroll position from outside (builtin.d.tl ScrollAreaParam has
-- only onScroll), but a node's ref can ensureVisible() itself, and the scroll area then scrolls to it. So, once a
-- request comes, an empty marker is put at that end of the content and made visible. Until then the base recipe
-- is drawn unchanged (no marker): a player's windows look as without this mod. Once there, the marker stays for
-- the window's life (taking it out again would move the content back by the layout's spacing).
--
-- A request already in the save data when a container first reads it is old (left from an earlier game or window),
-- unless it is a few seconds old at most (core.scrollFresh): a window opened just before tf3ctl scroll still
-- scrolls. "top" puts the marker before the first child, so the base's children move one place on: a window's
-- own state may be made again then (not seen in game yet); "bottom" only adds after them.
--
-- The request comes through the GUI save data (remote.script.lua publishUi, key "scroll"), read by each open
-- container in a join, as the speed control reads its requests: this recipe may live in a Lua state of its own.
-- NO GAME API IN THE RECIPE BODY OR ITS STEPS (remote_speed.script.lua says why): the reads and ensureVisible are
-- in react.enqueueJoin, on the main thread.
local req = ug_require or require
local react = req "::/gui/main/react.lua"
local builtin = req "::/gui/main/builtin.lua"
local entity_window_util = req "::/gui/entity_window/entity_window_util.tl"
local MOD = (getOwningModId and getOwningModId()) or "hummer_remote_probe"
local core = req(MOD .. "::/remote_core.lua")

local READ_SEC = 0.5

-- another mod's replacement installed before this one, drawn in place of the base recipe (as the speed control)
local previous
core.shared.ownScrollContainers = core.shared.ownScrollContainers or setmetatable({}, { __mode = "k" })

local function findPrevious()
	local ok, prev = pcall(function()
		return _react.recipeReplace[react.GetRecipeId(entity_window_util.ContentWidgetScrollContainer)]
	end)
	if not ok or type(prev) ~= "function" or core.shared.ownScrollContainers[prev] then return nil end
	return prev
end

-- A plain function, not a registered recipe: it runs as the base recipe's body (its hooks are that recipe's),
-- as Auto Assign Terminals replaces the same recipe. A registered recipe in its place made a node of its own from
-- (children, first), and the first industry window opened made React's step fail and the UI reload
-- (2026-11-19 01:21 JST). Another mod that replaces this recipe after us and calls the original by the recipe it
-- kept (AAT does) draws the base content without our marker: scroll then does nothing in its windows.
local function ScrollContainer(children, first)
	-- want: the newest request this container took ({ seq, to }), nil before one; seen: the newest seq read, nil
	-- until the first read (a request already in the save data when the window opens is old); done: the seq the
	-- marker was made visible for
	-- drawn: the seq whose marker the last render put in (so a marker still at the other end is never the one
	-- made visible)
	local want = react.useState(nil)
	local seen = react.useRef(nil)
	local done = react.useRef(nil)
	local drawn = react.useRef(nil)
	local marker = react.useNodeRef()
	react.onStepTimer(function()
		react.enqueueJoin(function()
			local ok, d = pcall(function() return api.gui.game.getGuiSaveData(MOD) end)
			local r = ok and core.uiScroll(d) or nil
			local seq = r and r.seq or false
			local first = seen:get() == nil
			if seq and seq ~= seen:get() and (not first or core.scrollFresh(r, os.time and os.time() or nil)) then
				seen:set(seq)
				want:set(r) -- drawn with the marker from the next render
				return
			end
			if first then seen:set(seq) end
			-- a render later: the marker is laid out at the asked end, so making it visible scrolls to it
			local w = want:old()
			if w and done:get() ~= w.seq and drawn:get() == w.seq then
				local okM, node = pcall(function() return marker:get() end)
				if okM and node then
					local okV, err = pcall(function() node:ensureVisible() end)
					if not okV then print("[remote_probe] scroll " .. w.to .. " failed: " .. tostring(err)) end
					done:set(w.seq)
				end
			end
		end, "HummerRemoteScrollContainer:read")
	end, READ_SEC)
	local w = want:old()
	local kids = children
	if w and type(children) == "table" then
		drawn:set(w.seq)
		local m = builtin.Component(react.ref(marker), { meta = { class = "hummer-remote-scroll-marker" } })
		kids = {}
		if w.to == "top" then kids[1] = m end
		for _, c in ipairs(children) do kids[#kids + 1] = c end
		if w.to ~= "top" then kids[#kids + 1] = m end
	end
	if previous then return previous(kids, first) end
	return react.CallOriginalRecipe(entity_window_util.ContentWidgetScrollContainer, kids, first)
end

core.shared.ownScrollContainers[ScrollContainer] = true

local exports = {}

function exports.install(replacementApi)
	previous = findPrevious()
	replacementApi.ReplaceRecipe(entity_window_util.ContentWidgetScrollContainer, ScrollContainer)
end

exports.ScrollContainer = ScrollContainer

function data()
	return exports
end
