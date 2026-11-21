-- The remote probe in the main menu, so a tool can load a save or start a new game with nobody at the keyboard.
-- The game runs this when launched as
--   steam -applaunch 3493540 --script hummer_remote_probe::/startup.lua      (tools/tf3ctl.py launch / restart)
-- Found 2026-11-16 in the game binary: "--script <path>" loads a resource path ("<mod>::/<file>"; a disk path or
-- a file missing from the base's _content.json is "not cached" and the game exits), calls its data() and reads
-- handleEvent and update from the result; update then runs every frame, in the main menu too, with app and api.
-- A missing data(), or a nil handleEvent / update, is a Lua error (the first one ends the game).
--
-- This is the same command loop as in a save (remote.script.lua), in its menu mode: only status, saves, info,
-- load, newgame, poll, quit and the My Mods commands modhubStatus / modhubValidate (core.MENU_COMMANDS). Once it
-- has called loadGame or startGame it stops, and the new game's own copy of the probe answers from then on.
local MOD = "hummer_remote_probe"
local req = ug_require or require

-- A failure here must not end the game (an error in data(), handleEvent or update does): it is logged and the
-- game runs on without the probe in the menu.
-- No new globals: the base's init.lua puts a __newindex on _G, and a new global from a mod's file is logged as
-- "ERROR Global variable in mod" and sent as a crash report (every launch, 2026-11-20 to 21). So:
-- - the probe is kept in remote_core.lua's module table, not in a global. A module that returns a value stays in
--   package.loaded (init.lua's require), so if the game runs this file again in the same Lua state the probe is
--   found there and not made twice; remote.script.lua returns nothing, so the base would run it again. (Read in
--   init.lua; that the game ever runs this file twice in one state is not seen in game.)
-- - data is cleared to false, not nil: init.lua declares it (data = false), and nil would drop the key, so the
--   "function data()" in remote.script.lua would make a new global.
local remote
local ok, err = pcall(function()
	local core = req(MOD .. "::/remote_core.lua")
	remote = core.menuProbe
	if remote then return end
	data = false
	req(MOD .. "::/remote.script.lua") -- defines data(), which hands out the script
	if type(data) ~= "function" then error("remote.script.lua did not define data()") end
	remote = data()
	remote.setMenu()
	core.menuProbe = remote
end)
if not ok then
	remote = nil
	print("[remote_probe] startup.lua could not start the probe in the main menu: " .. tostring(err))
end

local startup = {}

function startup.handleEvent() end

function startup.update()
	if not remote then return end
	local ok, err = pcall(remote.guiUpdate)
	if not ok and not startup.warned then
		startup.warned = true
		print("[remote_probe] the menu probe failed: " .. tostring(err))
	end
end

function data()
	return startup
end
