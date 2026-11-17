-- Room for the label beside the speed buttons. The right-hand bars of the game bar are stacked in a floating
-- layout with fixed widths (base game_bar.css.lua, build 40444: 508 / 380 / 330), so every layer behind the
-- speed row grows by the same amount, as Time Warp (mod.io 6453396) does for its two extra buttons. A mod that
-- sets these widths too (Time Warp) and this one do not add up: the stylesheet loaded last wins.
local ssu = require "::/gui/main/stylesheetutil.lua"

function data()
	local result = {}
	local a = ssu.makeAdder(result)

	-- "×16 実測×3.2 →2045-07-03" at body size (170) plus Time Warp's two buttons (56), always: no game API is
	-- called here, since it is not known on which thread a stylesheet is built (a GUI call from a worker thread
	-- crashed the game, 2026-11-15)
	local extraWidth = 170 + 56
	local bottomBarHeight = 28
	local middleBarHeight = 1
	local rightTopButtonHeight = 80 - bottomBarHeight - middleBarHeight
	local rightSensoryButtonWidth = 508 + extraWidth
	local rightHelpButtonWidth = 380 + extraWidth
	local rightSpeedButtonWidth = 330 + extraWidth

	a("R::GameBarMenuRight !button-rack !middle-space", { size = { rightSensoryButtonWidth, middleBarHeight } })
	a("R::GameBarMenuRight !statistics", { size = { rightSensoryButtonWidth, rightTopButtonHeight } })
	a("R::GameBarMenuRight !cameras", { size = { rightSensoryButtonWidth, bottomBarHeight } })
	a("R::GameBarMenuRight !music-player", { size = { rightHelpButtonWidth, bottomBarHeight } })
	a("R::GameBarMenuRight !game-speed", { size = { rightSpeedButtonWidth, bottomBarHeight } })

	a("R::GameBarMenuRight TextView!hummer-remote-speed", {
		gravity = { 0.0, 0.5 },
		margin = { 0, 0, 0, 10 },
	})

	return result
end
