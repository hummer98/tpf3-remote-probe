-- The scroll marker (remote_scroll.script.lua): a pixel high, so ensureVisible has something to bring into view
-- (an empty component of no size did not scroll its window, 2026-11-19 01:40 JST)
local ssu = require "::/gui/main/stylesheetutil.lua"

function data()
	local result = {}
	local a = ssu.makeAdder(result)
	a("Component!hummer-remote-scroll-marker", {
		minSize = { 1, 1 },
	})
	return result
end
