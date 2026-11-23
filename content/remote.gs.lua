-- GUI side: app.* (userdata files, loadGame, saveGame) and api.gui.* exist only in the GUI thread.
-- Never rename or move this file: its resource name identifies the script in saves.
-- update / handleEvent (remote_gs.script.lua): the game script's one job, runningCostsSet; it does nothing unless the
-- mod setting gameScript is on.
function data()
	return {
		updateScript = { fileName = "remote_gs.script@update" },
		handleEventScript = { fileName = "remote_gs.script@handleEvent" },
		guiUpdateScript = { fileName = "remote.script@guiUpdate" },
	}
end
