-- Room for the ×8 / ×16 buttons and the label beside the speed buttons. The right-hand bars of the game bar are
-- stacked in a floating layout with fixed widths (base game_bar.css.lua, build 40444: 508 / 380 / 330), so every
-- layer behind the speed row grows by the same amount. Another mod that sets these widths too would not add up
-- with this one (the stylesheet loaded last wins); Time Warp, which did, is incompatible (mod.json).
local ssu = require "::/gui/main/stylesheetutil.lua"

function data()
	local result = {}
	local a = ssu.makeAdder(result)

	-- "×16 実測×3.2 →2045-07-03" at body size (170) plus the two buttons (2 x (28 + 4 border) + 4 gap = 68), always:
	-- no game API is called here, since it is not known on which thread a stylesheet is built (a GUI call from a
	-- worker thread crashed the game, 2026-11-15)
	local buttonWidth = 28
	local buttonsGap = 4
	local extraWidth = 170 + 2 * (buttonWidth + 4) + buttonsGap
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

	-- the ×8 / ×16 group, by its class (as the base's construction.css.lua matches ToggleButtonGroup!ui-type-0). Its
	-- buttons take the base look from game_bar.css.lua's ToggleButtonGroup!horizontal rules.
	a("R::GameBarMenuRight ToggleButtonGroup!hummer-remote-speed-buttons", {
		gravity = { 0.0, 0.5 },
		margin = { 0, 0, 0, buttonsGap },
	})
	-- "×16" fits in 28 px; the base icons are 24 px high, so the row keeps its height
	a("R::GameBarMenuRight TextView!hummer-remote-speed-button", {
		size = { buttonWidth, 24 },
		textAlignment = { 0.5, 0.5 },
	})

	a("R::GameBarMenuRight TextView!hummer-remote-speed", {
		gravity = { 0.0, 0.5 },
		margin = { 0, 0, 0, 10 },
	})

	return result
end
