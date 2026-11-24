-- What the mod does with tf3ctl's configuration (tools/tf3ctl.py config_values): the test saves' rules and the
-- modhub lists come with each command (_testSaveRules, _modhub). Without them, the mod's own defaults: probe- names
-- only, no modhub folder. These tests take a fresh copy of remote_core.lua (freshCore): run.lua sets the copy the
-- other tests use to a configured machine's values.
return function(t)
	local test, eq, truthy, freshCore = t.test, t.eq, t.truthy, t.freshCore

	test("config: test saves without rules are probe- names only; the rules tf3ctl sends decide otherwise", function()
		local c = freshCore()
		eq(#c.TEST_SAVE_DEFAULT.prefixes, 1); eq(c.TEST_SAVE_DEFAULT.prefixes[1], "probe-")
		eq(c.TEST_SAVE_DEFAULT.digitFirst, false)
		for _, yes in ipairs({ "probe-a", " probe-a ", "/s/probe-a.sav" }) do truthy(c.isTestSaveName(yes), yes) end
		for _, no in ipairs({ "3-probe", "7", "shot-1", "probe", "", "My Railway" }) do
			eq(c.isTestSaveName(no), false, no)
		end
		local rules = { prefixes = { "shot-", "tmp-" }, digitFirst = true }
		for _, yes in ipairs({ "shot-1", "tmp-x.sav", "3-probe", "7" }) do truthy(c.isTestSaveName(yes, rules), yes) end
		for _, no in ipairs({ "probe-a", "12-a", "x" }) do eq(c.isTestSaveName(no, rules), false, no) end
		eq(c.isTestSaveName("3-probe", { prefixes = { "probe-" }, digitFirst = false }), false, "digit rule off")
		eq(c.isTestSaveName("probe-a", { prefixes = {}, digitFirst = false }), false, "no prefix at all")
		-- rules of another form: the default, never a wider rule
		for _, bad in ipairs({ "x", { prefixes = "probe-" }, { prefixes = { "" } }, { prefixes = { 5 } },
			{ digitFirst = true } }) do
			eq(c.isTestSaveName("3-probe", bad), false, "malformed rules: no digit rule")
			eq(c.isTestSaveName("probe-a", bad), true, "malformed rules: the default prefix")
		end
	end)

	test("config: road --ignore-errors, lights --off and running-costs writes check the name by the rules sent", function()
		local c = freshCore()
		local road = { from = "0,0", to = "30,0", ignoreErrors = true, _testSave = "3-probe" }
		local ok, err = c.roadRequest(road)
		eq(ok, nil); truthy(err:find("test saves only"), err)
		road._testSaveRules = { prefixes = { "probe-" }, digitFirst = true }
		ok, err = c.roadRequest(road)
		truthy(ok and ok.ignoreErrors, tostring(err))
		ok, err = c.lightsOffRequest({ node = 5, _testSave = "shot-1" })
		eq(ok, nil); truthy(err:find("test saves only"), err)
		truthy(c.lightsOffRequest({ node = 5, _testSave = "shot-1", _testSaveRules = { prefixes = { "shot-" } } }))
		local ops = { { field = "runningCosts", scale = 2 } }
		eq(c.runningCostsArgs({ model = "bus", ops = ops, _testSave = "shot-1" }, true), nil)
		local w = c.runningCostsArgs({ model = "bus", ops = ops, _testSave = "shot-1",
			_testSaveRules = { prefixes = { "shot-" } } }, true)
		truthy(w, "taken with the rules")
		-- the game script's second check gets the same rules in the request
		local req = c.runningCostRequest(7, 101, w)
		eq(req.testSaveRules.prefixes[1], "shot-"); eq(req.testSaveRules.digitFirst, false)
		truthy(c.runningCostRequestChecked(req), "the game script takes it")
		req.testSaveRules = nil
		local no, why = c.runningCostRequestChecked(req)
		eq(no, nil); truthy(why:find("test saves only"), why)
		-- a request made without rules (an older GUI copy) carries the default's
		local plain = c.runningCostRequest(8, 101, { ops = ops, testSave = "probe-x" })
		eq(plain.testSaveRules.prefixes[1], "probe-")
		truthy(c.runningCostRequestChecked(plain))
	end)

	test("config: modhub validate and publish take no folder without the lists tf3ctl sends", function()
		local c = freshCore()
		local _, err = c.modhubValidateArgs({ folder = "my_mod_1" })
		truthy(err and err:find("validate takes no staging folder"), err)
		_, err = c.modhubPublishArgs({ folder = "my_mod_1", public = true, firstUpload = true, changelog = "x" })
		truthy(err and err:find("publish takes no staging folder"), err)
		local lists = { validateFolders = { "my_mod_1" }, publishFolders = { "my_mod_1", "old_mod_1" },
			publishedIds = { old_mod_1 = "123" } }
		truthy(c.modhubValidateArgs({ folder = "my_mod_1", _modhub = lists }))
		_, err = c.modhubValidateArgs({ folder = "old_mod_1", _modhub = lists })
		truthy(err and err:find("only these staging folders: my_mod_1 %(not old_mod_1%)"), err)
		truthy(c.modhubPublishArgs({ folder = "my_mod_1", public = true, firstUpload = true, changelog = "x",
			_modhub = lists }))
		-- a folder on mod.io: held to its id by the list sent
		_, err = c.modhubPublishArgs({ folder = "old_mod_1", public = true, firstUpload = true, changelog = "x",
			_modhub = lists })
		truthy(err and err:find("on mod.io already %(mod 123%)"), err)
		_, err = c.modhubPublishArgs({ folder = "old_mod_1", public = true, update = true, modioId = "999",
			changelog = "x", _modhub = lists })
		truthy(err and err:find("is mod.io mod 123, not 999"), err)
		truthy(c.modhubPublishArgs({ folder = "old_mod_1", public = true, update = true, modioId = "123",
			changelog = "x", _modhub = lists }))
		-- lists of another form: nothing taken (not the module's own tables)
		c.MODHUB_VALIDATE_FOLDERS.my_mod_1 = true
		for _, bad in ipairs({ "x", { validateFolders = "my_mod_1" }, { validateFolders = { 5 } } }) do
			_, err = c.modhubValidateArgs({ folder = "my_mod_1", _modhub = bad })
			truthy(err and err:find("validate takes no staging folder"), tostring(err))
		end
		truthy(c.modhubValidateArgs({ folder = "my_mod_1" }), "without _modhub: the module's table")
		-- status: each staging mod's validateAllowed by the lists sent
		local s = c.modhubStatusArgs({ _modhub = lists })
		eq(s.lists.validate.my_mod_1, true); eq(s.lists.validate.old_mod_1, nil)
	end)

	test("config: screenshot is no command any more; newgame from inside a save takes no unsafe", function()
		local c = freshCore()
		eq(c.COMMANDS.screenshot, nil)
		local r = c.readCommand({ id = 3, cmd = "screenshot", args = {} }, 0)
		truthy(r.error and r.error:find("unknown command: screenshot"), r.error)
		local g = t.newGame({ saves = t.SAVES })
		t.frames(g, 2)
		t.send(g, 901, "newgame", '{ size = "tiny", unsafe = true }')
		t.frames(g, t.FIRST)
		local a = t.final(g, 901)
		eq(a.ok, false); truthy(a.error:find("cannot start from inside a save"), a.error)
		eq(#g.started, 0, "nothing started")
		t.send(g, 902, "screenshot", "{ scale = 1 }")
		t.frames(g, 20)
		a = t.final(g, 902)
		truthy(a.error and a.error:find("unknown command"), a.error)
	end)
end
