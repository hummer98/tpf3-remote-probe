-- Replaces the speed buttons' recipe (exported game_bar_widgets.GameSpeedControl) with the same buttons plus a
-- label for speeds the buttons cannot show (anything but 0/1/2/4) and for a remote run in progress.
function data()
	return {
		type = "react-replacement-config",
		data = {
			filePath = "hummer_remote_probe::/gui/remote_speed.script",
			doReplaceFn = "install",
			order = 500,
		},
	}
end
