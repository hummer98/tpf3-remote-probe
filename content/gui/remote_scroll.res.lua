-- Wraps the base entity windows' scrolled content (exported entity_window_util.ContentWidgetScrollContainer) so
-- that tf3ctl scroll can move it to the top or the bottom without a click or a mouse wheel.
function data()
	return {
		type = "react-replacement-config",
		data = {
			filePath = "hummer_remote_probe::/gui/remote_scroll.script",
			doReplaceFn = "install",
			order = 500,
		},
	}
end
