-- The remote probe in the main menu, so a tool can load a save or start a new game with nobody at the keyboard.
-- The game runs this when launched as
--   steam -applaunch 3493540 --script hummer_remote_probe::/startup.lua      (tools/tf3ctl.py launch / restart)
-- Found 2026-11-16 in the game binary: "--script <path>" loads a resource path ("<mod>::/<file>"; a disk path or
-- a file missing from the base's _content.json is "not cached" and the game exits), calls its data() and reads
-- handleEvent and update from the result; update then runs every frame, in the main menu too, with app and api.
-- A missing data(), or a nil handleEvent / update, is a Lua error (the first one ends the game).
--
-- This is the same command loop as in a save (remote.script.lua), in its menu mode: only status, saves, info,
-- load, newgame, poll and quit (core.MENU_COMMANDS). Once it has called loadGame or startGame it stops, and the
-- new game's own copy of the probe answers from then on.
local MOD = "hummer_remote_probe"
local req = ug_require or require

-- A failure here must not end the game (an error in data(), handleEvent or update does): it is logged and the
-- game runs on without the probe in the menu. The script is kept in a global, since require caches
-- remote.script.lua: if the game runs this file again in the same Lua state, that file does not run again.
-- (a plain global, not rawget(_G, ...): _G is not a plain table in the game's GUI Lua, 2026-11-15)
local remote = __hummer_remote_probe_menu
if not remote then
	local ok, err = pcall(function()
		data = nil
		req(MOD .. "::/remote.script.lua") -- defines data(), which hands out the script
		if type(data) ~= "function" then error("remote.script.lua did not define data()") end
		remote = data()
		remote.setMenu()
	end)
	if ok then
		__hummer_remote_probe_menu = remote
	else
		remote = nil
		print("[remote_probe] startup.lua could not start the probe in the main menu: " .. tostring(err))
	end
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
