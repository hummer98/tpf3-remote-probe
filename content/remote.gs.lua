-- GUI side only: app.* (userdata files, loadGame, saveGame) and api.gui.* exist only in the GUI thread.
-- Never rename or move this file: its resource name identifies the script in saves.
function data()
	return {
		guiUpdateScript = { fileName = "remote.script@guiUpdate" },
	}
end
