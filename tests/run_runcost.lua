-- running-costs, running-costs --set-* and finance (content/remote_runcost.lua, content/remote_gs.script.lua), over
-- tests/fake_game.lua's installRunningCosts. Run from tests/run.lua, which hands in its helpers.
return function(h)
	local test, eq, truthy, fake, core = h.test, h.eq, h.truthy, h.fake, h.core
	local send, frames, final, FIRST = h.send, h.frames, h.final, h.FIRST

	local function fleetOf(model)
		return { vehicles = { { part = { modelId = model, reversed = false, compartment2loadConfig = {} }, purchaseTime = 5,
			maintenanceState = 1, autoLoadConfig = {} } }, vehicleGroups = { 1 }, muFileNames = {}, line = -1, depot = -1 }
	end
	-- a game with two buses of model 101 and a truck; gameScript on unless off
	local function game(spec, opts)
		opts = opts or {}
		opts.fleet = opts.fleet or { [601] = fleetOf(101), [602] = fleetOf(101), [603] = fleetOf(103) }
		if not opts.gameScriptOff then opts.modParams = { hummer_remote_probe = { gameScript = 2 } } end
		local g = h.vehicleGame(opts)
		fake.installRunningCosts(g, spec)
		return g
	end
	local function run(g, id, cmd, argsLua, n)
		send(g, id, cmd, argsLua)
		frames(g, n or FIRST + 20)
		return final(g, id)
	end
	local DOUBLE = '{ model = "bus_1900", ops = { { field = "runningCosts", scale = 2 } }, _testSave = "probe-runcost" }'

	test("core.runningCostOps / runningCostsArgs: fields, set or scale, limits, the test save's name", function()
		local ops = core.runningCostOps({ { field = "runningCosts", set = 100 }, { field = "maintenanceScale", scale = 2 } })
		eq(#ops, 2); eq(ops[1].group, "maintenance"); eq(ops[1].set, 100); eq(ops[2].scale, 2)
		truthy(select(2, core.runningCostOps({ { field = "price", set = 1 } })):find("must be one of"))
		truthy(select(2, core.runningCostOps({ { field = "runningCosts", set = 1, scale = 2 } })):find("one of them"))
		truthy(select(2, core.runningCostOps({ { field = "runningCosts" } })):find("one of them"))
		truthy(select(2, core.runningCostOps({ { field = "runningCosts", set = -1 } })):find("from 0"))
		truthy(select(2, core.runningCostOps({ { field = "runningCosts", set = 0 / 0 } })):find("from 0"))
		truthy(select(2, core.runningCostOps({ { field = "runningCosts", scale = 0 } })):find("above 0"))
		truthy(select(2, core.runningCostOps({ { field = "runningCosts", scale = 101 } })):find("at most"))
		truthy(select(2, core.runningCostOps({ { field = "runningCosts", set = 1 }, { field = "runningCosts", set = 2 } })):find("twice"))
		truthy(select(2, core.runningCostOps({})):find("at least one"))
		truthy(select(2, core.runningCostOps(nil)):find("list"))
		-- read
		local r = core.runningCostsArgs({ model = 101 })
		eq(r.model, "101"); eq(r.limit, core.RUNCOST_VEHICLES); eq(r.ops, nil)
		truthy(select(2, core.runningCostsArgs({})):find("give model"))
		truthy(select(2, core.runningCostsArgs({ model = "" })):find("give model"))
		truthy(select(2, core.runningCostsArgs({ model = "x", ops = {} })):find("only reads"))
		truthy(select(2, core.runningCostsArgs({ model = "x", limit = 51 })):find("limit"))
		-- write: a test save's name first
		local okOps = { { field = "runningCosts", scale = 2 } }
		local w = core.runningCostsArgs({ model = "bus", ops = okOps, _testSave = "probe-x" }, true)
		eq(w.where, "script"); eq(w.testSave, "probe-x"); eq(#w.ops, 1)
		eq(core.runningCostsArgs({ model = "bus", ops = okOps, _testSave = "3-probe", where = "gui" }, true).where, "gui")
		for _, save in ipairs({ "aom-eu-1900", "12-probe", "", false }) do
			local _, e = core.runningCostsArgs({ model = "bus", ops = okOps, _testSave = save }, true)
			truthy(e and e:find("test saves only"), tostring(save))
		end
		truthy(select(2, core.runningCostsArgs({ model = "bus", ops = okOps }, true)):find("test saves only"))
		truthy(select(2, core.runningCostsArgs({ model = "bus", ops = okOps, _testSave = "probe-x", where = "both" }, true)):find("script or gui"))
	end)

	test("core.runningCostTargets / readRunningCostFields / writeRunningCosts / requestChecked", function()
		local before = { maintenance = { runningCosts = 500, maintenanceScale = 1 } }
		local t = core.runningCostTargets(before, core.runningCostOps({ { field = "runningCosts", scale = 2 },
			{ field = "maintenanceScale", set = 3 } }))
		eq(t[1].from, 500); eq(t[1].to, 1000); eq(t[2].from, 1); eq(t[2].to, 3)
		truthy(select(2, core.runningCostTargets({ maintenance = { runningCosts = -1 } },
			core.runningCostOps({ { field = "runningCosts", scale = 2 } }))):find("set it"))
		truthy(select(2, core.runningCostTargets({ maintenance = {} },
			core.runningCostOps({ { field = "runningCosts", scale = 2 } }))):find("cannot be scaled"))
		eq(core.runningCostTargets({ maintenance = {} }, core.runningCostOps({ { field = "runningCosts", set = 7 } }))[1].to, 7)
		-- a model held in place, one that raises, one handed out as a copy
		local held = { metadata = { cost = { price = 10, priceScale = 1 }, maintenance = { runningCosts = 5, runningCostScale = 1 } } }
		local rep = { get = function(id) if id == 1 then return held end error("no model " .. id) end }
		local f = core.readRunningCostFields(rep, 1)
		eq(f.cost.price, 10); eq(f.maintenance.runningCosts, 5); eq(f.maintenance.lifespan, nil)
		truthy(select(2, core.readRunningCostFields(rep, 2)):find("no model 2"))
		local w = core.writeRunningCosts(rep, 1, { { field = "runningCosts", group = "maintenance", from = 5, to = 10 } })
		eq(w[1].ok, true); eq(w[1].stuck, true); eq(w[1].readBack, 10); eq(held.metadata.maintenance.runningCosts, 10)
		local copies = { get = function() return { metadata = { maintenance = { runningCosts = 5 } } } end }
		w = core.writeRunningCosts(copies, 1, { { field = "runningCosts", group = "maintenance", from = 5, to = 10 } })
		eq(w[1].ok, true); eq(w[1].stuck, false); eq(w[1].readBack, 5)
		-- the game script's check of a request
		local r = core.runningCostRequestChecked(core.runningCostRequest(9, 101,
			{ ops = core.runningCostOps({ { field = "runningCosts", scale = 2 } }), testSave = "probe-x" }))
		eq(r.req, 9); eq(r.model, 101); eq(r.ops[1].scale, 2)
		truthy(select(2, core.runningCostRequestChecked({ req = 1, model = 101, ops = { { field = "runningCosts", set = 1 } },
			testSave = "aom-eu-1900" })):find("test saves only"))
		truthy(select(2, core.runningCostRequestChecked({ req = 1, model = 101, ops = {}, testSave = "probe-x" })):find("at least one"))
		truthy(select(2, core.runningCostRequestChecked({ model = 101 })):find("numbers"))
		eq(core.closeTo(1000.00001, 1000), true); eq(core.closeTo(1001, 1000), false); eq(core.closeTo(nil, 1), false)
	end)

	test("running-costs (read): every field, the model's vehicles with their running cost, nothing written or sent", function()
		local g = game({ maintenance = { [101] = { runningCosts = 4000, runningCostScale = 1.5 } } })
		local a = run(g, 2601, "runningCosts", '{ model = "bus_1900" }')
		truthy(a.ok, a.error)
		eq(a.model.id, 101); eq(a.model.fileName, "vehicle/bus/bus_1900.mdl"); eq(a.view, "gui")
		eq(a.fields.cost.price, 30000); eq(a.fields.cost.priceScale, 1)
		eq(a.fields.maintenance.runningCosts, 4000); eq(a.fields.maintenance.runningCostScale, 1.5)
		eq(a.fields.maintenance.maintenanceScale, 1); eq(a.fields.maintenance.lifespan, 20)
		eq(a.fields.maintenance.topSpeedMaintenanceFactorPenaltyPerLevel, 0.1)
		eq(a.vehicleCount, 2); eq(#a.vehicles, 2); eq(a.vehicles[1].entity, 601); eq(a.vehicles[1].runningCostPerYear, 6000)
		eq(a.gameScript, true)
		eq(table.concat(a.writable, ","), "maintenance.maintenanceScale,maintenance.runningCostScale,maintenance.runningCosts")
		eq(g.runcostEvents, nil, "no script event for a read")
		eq((g.gsValue or {}).runningCosts, nil, "the game script's state untouched (but status's luaLoad, from its update)")
		eq(g.runningCostMeta(101).runningCosts, 4000)
		-- by id, and a limit of the vehicles listed
		local b = run(g, 2602, "runningCosts", "{ model = 101, limit = 1 }", 20)
		truthy(b.ok, b.error); eq(#b.vehicles, 1); eq(b.vehicleCount, 2)
		-- not a vehicle model, or more than one match
		local c = run(g, 2603, "runningCosts", '{ model = "bus_house" }', 20)
		eq(c.ok, false); truthy(c.error:find("no vehicle model"), c.error)
		local d = run(g, 2604, "runningCosts", '{ model = "bus" }', 20)
		eq(d.ok, false); truthy(d.error:find("2 models match"), d.error)
		-- read-only goes without the setting, and lastAction stays unset (no game-changing command)
		local off = game({}, { gameScriptOff = true })
		local e = run(off, 2605, "runningCosts", '{ model = "truck" }')
		truthy(e.ok, e.error); eq(e.gameScript, false); eq(e.vehicleCount, 1)
	end)

	test("running-costs --scale-running (script): the game script writes; both views, before and after, and the vehicles", function()
		local g = game({ maintenance = { [101] = { runningCosts = 4000 } } })
		frames(g, 5)
		truthy(g.gsSubs[core.RUNCOST_EVENT_WRITE] and g.gsSubs[core.RUNCOST_EVENT_READ], "subscribed with gameScript on")
		local a = run(g, 2611, "runningCostsSet", DOUBLE)
		truthy(a.ok, a.error)
		eq(a.where, "script"); eq(a.wroteIn, "game script"); eq(a.testSave, "probe-runcost"); eq(a.model.id, 101)
		eq(a.before.gui.maintenance.runningCosts, 4000); eq(a.before.script.maintenance.runningCosts, 4000)
		eq(#a.writes, 1); eq(a.writes[1].field, "runningCosts"); eq(a.writes[1].from, 4000); eq(a.writes[1].to, 8000)
		eq(a.writes[1].ok, true); eq(a.writes[1].stuck, true); eq(a.writes[1].readBack, 8000)
		eq(a.after.script.maintenance.runningCosts, 8000); eq(a.after.gui.maintenance.runningCosts, 8000, "the GUI sees it")
		eq(a.vehiclesBefore[1].runningCostPerYear, 4000); eq(a.vehiclesAfter[1].runningCostPerYear, 8000)
		eq(#g.gsDelivered, 1); eq(g.gsDelivered[1].name, core.RUNCOST_EVENT_WRITE)
		eq(g.gsDelivered[1].param.testSave, "probe-runcost")
		eq(g.gsValue.runningCosts.req, 2611)
		eq(g.runningCostMeta(101).runningCosts, 8000)
		eq(g.runningCostMeta(103).runningCosts, 20000 / 6, "another model untouched")
		-- set and a second field in one go
		local b = run(g, 2612, "runningCostsSet", '{ model = 101, ops = { { field = "runningCosts", set = 1000 }, '
			.. '{ field = "maintenanceScale", scale = 3 } }, _testSave = "probe-runcost" }', 30)
		truthy(b.ok, b.error)
		eq(b.writes[1].to, 1000); eq(b.writes[2].field, "maintenanceScale"); eq(b.writes[2].to, 3)
		eq(b.after.gui.maintenance.maintenanceScale, 3)
	end)

	test("running-costs --set-*: refused without a test save's name, the setting off, a busy job; the engine's error word for word", function()
		local g = game({})
		frames(g, 5)
		for i, save in ipairs({ "aom-eu-1900", "", "12-probe" }) do
			local a = run(g, 2620 + i, "runningCostsSet", '{ model = 101, ops = { { field = "runningCosts", scale = 2 } }, '
				.. '_testSave = "' .. save .. '" }', i == 1 and FIRST + 20 or 20)
			eq(a.ok, false); truthy(a.error:find("test saves only"), a.error)
		end
		local nosave = run(g, 2624, "runningCostsSet", '{ model = 101, ops = { { field = "runningCosts", scale = 2 } } }', 20)
		eq(nosave.ok, false); truthy(nosave.error:find("test saves only"))
		eq(g.runcostEvents, nil, "nothing sent"); eq(g.runningCostMeta(101).runningCosts, 5000)
		-- script-event cannot send the probe's own event (it has no test-save check), even with a test save's name
		local se = run(g, 2625, "scriptEvent", '{ id = "hummer_remote_probe.runningCosts", name = "' .. core.RUNCOST_EVENT_WRITE
			.. '", param = { req = 1, model = 101, ops = { { field = "runningCosts", set = 1 } }, testSave = "probe-x" } }', 20)
		eq(se.ok, false); truthy(se.error:find("probe's own"), se.error)
		eq(g.runcostEvents, nil); eq(g.runningCostMeta(101).runningCosts, 5000)
		-- an event that reaches the game script anyway with a person's save's name: refused, no state written
		g.gsState:set({ keep = 1 })
		g.gs.handleEvent(nil, g.gsState, "", core.RUNCOST_EVENT_ID, core.RUNCOST_EVENT_WRITE,
			{ req = 1, model = 101, ops = { { field = "runningCosts", set = 1 } }, testSave = "aom-eu-1900" })
		eq(g.runningCostMeta(101).runningCosts, 5000); eq(g.gsValue.keep, 1); eq(g.gsValue.runningCosts, nil)
		-- the setting off: where script refused, nothing subscribed, the state untouched (a person's save keeps none)
		local off = game({}, { gameScriptOff = true })
		frames(off, 200)
		eq(next(off.gsSubs), nil, "no subscription with gameScript off"); eq(off.gsValue, nil)
		local o = run(off, 2626, "runningCostsSet", DOUBLE)
		eq(o.ok, false); truthy(o.error:find("gameScript=2"), o.error); eq(off.runcostEvents, nil)
		-- the engine says no: its words come back, and ok is false
		local ro = game({ readOnly = "script" })
		local r = run(ro, 2627, "runningCostsSet", DOUBLE)
		eq(r.ok, false); eq(r.writes[1].ok, false)
		eq(r.writes[1].error, "cannot write to read only member 'runningCosts'")
		truthy(r.error:find("not every field"), r.error)
		eq(ro.runningCostMeta(101).runningCosts, 5000)
		-- a copy handed out: no error, but it did not stick
		local cp = game({ copies = true })
		local c = run(cp, 2628, "runningCostsSet", DOUBLE)
		eq(c.ok, false); eq(c.writes[1].ok, true); eq(c.writes[1].stuck, false)
		-- no answer from the game script: an error after the wait, the job freed
		local nd = game({ noDelivery = true })
		local n = run(nd, 2629, "runningCostsSet", DOUBLE, FIRST + 30 * (core.RUNCOST_WAIT_SEC + 2))
		eq(n.ok, false); truthy(n.error:find("no answer from the game script"), n.error)
		-- the job is freed: the next write is taken (and waits); one more while it waits is refused as busy
		local n2 = run(nd, 2630, "runningCostsSet", DOUBLE, 20)
		eq(n2, nil, "taken and waiting: no answer yet")
		local busy = run(nd, 2632, "runningCostsSet", DOUBLE, 20)
		eq(busy.ok, false); truthy(busy.error:find("still waiting"), busy.error)
	end)

	test("game script: other events, the setting off, a request twice, an engine error; no new globals", function()
		local g = game({})
		frames(g, 5)
		local gs, st = g.gs, g.gsState
		local req = { req = 77, model = 101, ops = { { field = "runningCosts", scale = 2 } }, testSave = "probe-x" }
		-- events of other ids or names: nothing read, no state
		gs.handleEvent(nil, st, "", "", "initNewGame", {})
		gs.handleEvent(nil, st, "", "VehicleModifier", core.RUNCOST_EVENT_WRITE, req)
		gs.handleEvent(nil, st, "", core.RUNCOST_EVENT_ID, "other", req)
		eq((g.gsValue or {}).runningCosts, nil); eq(g.runningCostMeta(101).runningCosts, 5000)
		-- once applied, the same req again is dropped (a write is never applied twice)
		gs.handleEvent(nil, st, "", core.RUNCOST_EVENT_ID, core.RUNCOST_EVENT_WRITE, req)
		eq(g.runningCostMeta(101).runningCosts, 10000)
		gs.handleEvent(nil, st, "", core.RUNCOST_EVENT_ID, core.RUNCOST_EVENT_WRITE, req)
		eq(g.runningCostMeta(101).runningCosts, 10000, "not 4x")
		-- subscribing again at each read of the setting (no hasEventSubscriptions guard), without saying it again
		g.gsSubs = { other = true }
		gs._resetForTests()
		frames(g, 2)
		truthy(g.gsSubs[core.RUNCOST_EVENT_WRITE], "subscribed although another name was in")
		-- the setting off in a game that is subscribed: a write event does nothing
		local off = game({}, { gameScriptOff = true })
		off.gs.handleEvent(nil, off.gsState, "", core.RUNCOST_EVENT_ID, core.RUNCOST_EVENT_WRITE, req)
		eq(off.gsValue, nil); eq(off.runningCostMeta(101).runningCosts, 5000)
		-- the engine raising inside: logged, not raised
		local rep = api.res.modelRep
		api.res.modelRep = nil
		local ok = pcall(gs.handleEvent, nil, st, "", core.RUNCOST_EVENT_ID, core.RUNCOST_EVENT_WRITE,
			{ req = 78, model = 101, ops = { { field = "runningCosts", set = 1 } }, testSave = "probe-x" })
		api.res.modelRep = rep
		eq(ok, true)
		-- loading the file makes no global but data (TF3's init.lua refuses new globals)
		local before = {}
		for k in pairs(_G) do before[k] = true end
		_G.data = nil
		dofile(h.root .. "/content/remote_gs.script.lua")
		local new = {}
		for k in pairs(_G) do if not before[k] and k ~= "data" then new[#new + 1] = tostring(k) end end
		eq(table.concat(new, ","), "")
		_G.data = nil
	end)

	test("running-costs --where gui: written in the GUI's state, read back by the game script", function()
		local g = game({})
		frames(g, 5)
		local a = run(g, 2641, "runningCostsSet", '{ model = 101, where = "gui", ops = { { field = "runningCostScale", '
			.. 'set = 2 } }, _testSave = "probe-x" }')
		truthy(a.ok, a.error)
		eq(a.wroteIn, "gui"); eq(a.writes[1].field, "runningCostScale"); eq(a.writes[1].stuck, true)
		eq(a.after.gui.maintenance.runningCostScale, 2); eq(a.after.script.maintenance.runningCostScale, 2)
		eq(g.gsDelivered[1].name, core.RUNCOST_EVENT_READ)
		eq(a.vehiclesAfter[1].runningCostPerYear, 10000)
		-- without the game script: the GUI's view only, and a note
		local off = game({}, { gameScriptOff = true })
		local b = run(off, 2642, "runningCostsSet", '{ model = 101, where = "gui", ops = { { field = "runningCosts", '
			.. 'scale = 2 } }, _testSave = "probe-x" }')
		truthy(b.ok, b.error); eq(b.after.script, nil); truthy(b.after.scriptNote:find("gameScript"))
		eq(off.runcostEvents, nil); eq(off.runningCostMeta(101).runningCosts, 10000)
		-- read only in the GUI: the engine's words
		local ro = game({ readOnly = "gui" })
		local c = run(ro, 2643, "runningCostsSet", '{ model = 101, where = "gui", ops = { { field = "runningCosts", '
			.. 'scale = 2 } }, _testSave = "probe-x" }')
		eq(c.ok, false); eq(c.writes[1].error, "cannot write to read only member 'runningCosts'")
		eq(c.after.script.maintenance.runningCosts, 5000)
	end)

	test("finance: the table's rows per carrier, the vehicle rows summed, the fleet's and a vehicle's running costs", function()
		local J = fake.JOURNAL
		local spec = { finance = { header = { "1899", "1900" }, total = { -10, -20 }, balance = { 100, 80 }, rows = {
			ROAD = { { type = "INCOME", values = { 500, 900 } },
				{ type = "MAINTENANCE", maintenance = "VEHICLE", values = { -100, -150 } },
				{ type = "MAINTENANCE", maintenance = "VEHICLE", values = { -1, -2 } },
				{ type = "MAINTENANCE", maintenance = "VEHICLE_MAINTENANCE", values = { -30, -40 } },
				{ type = "MAINTENANCE", maintenance = "INFRASTRUCTURE", construction = "STREET", values = { -5, -6 } } },
			RAIL = { { type = "MAINTENANCE", maintenance = "VEHICLE", values = { -7, -8 } } } } } }
		local balances = { [601] = { { 100, -40, J.Maintenance.VEHICLE }, { 200, -9, J.Maintenance.VEHICLE_MAINTENANCE },
			{ 300, 70 } }, [603] = { { 150, -11, J.Maintenance.VEHICLE } } }
		local g = game(spec, { vehicleBalances = balances })
		g.gameTime = 1000
		local a = run(g, 2651, "finance", "{ vehicles = { 601, 999 }, since = 50 }")
		truthy(a.ok, a.error)
		eq(a.columns, 4); eq(g.financeAsked.count, 4)
		eq(table.concat(a.table.header, ","), "1899,1900")
		local road = a.table.carriers.ROAD
		eq(#road.rows, 5); eq(road.rows[1].type, "INCOME"); eq(road.rows[2].maintenance, "VEHICLE")
		eq(road.rows[5].construction, "STREET"); eq(road.rows[2].construction, nil)
		eq(road.vehicleRunning[1], -101); eq(road.vehicleRunning[2], -152)
		eq(road.vehicleMaintenance[2], -40)
		eq(a.table.carriers.TRAM.sameAs, "ROAD", "TRAM's rows are ROAD's")
		eq(a.table.carriers.RAIL.vehicleRunning[1], -7); eq(a.table.carriers.RAIL.sameAs, nil)
		eq(a.table.total[2], -20); eq(a.table.balance[1], 100)
		local now = a.gameTime
		truthy(now >= 1000)
		eq(a.since, 50)
		-- the fleet: every own vehicle; running = Maintenance.VEHICLE only
		eq(a.fleet.vehicles, 3); eq(a.fleet.running, -51); eq(a.fleet.maintenance, -9); eq(a.fleet.all, 10)
		eq(#a.vehicles, 1); eq(a.vehicles[1].entity, 601); eq(a.vehicles[1].running, -40); eq(a.vehicles[1].maintenance, -9)
		eq(a.vehicles[1].runningCostPerYear, 5000)
		eq(a.missing[1], 999)
		-- since left out: a twelfth of a year back; a window that leaves an entry out
		local b = run(g, 2652, "finance", "{ since = 160 }", 20)
		truthy(b.ok, b.error); eq(b.fleet.running, 0); eq(b.fleet.maintenance, -9)
		local c = run(g, 2653, "finance", "{ columns = 2 }", 20)
		truthy(c.ok, c.error); truthy(c.sinceNote:find("twelfth")); eq(g.financeAsked.count, 2)
		local bad = run(g, 2654, "finance", "{ columns = 9 }", 20)
		eq(bad.ok, false); truthy(bad.error:find("columns"))
		-- the engine raising: the error in the answer, the rest still read
		local r = game({ financeRaises = true }, { balanceRaises = true })
		local d = run(r, 2655, "finance", "{}")
		truthy(d.ok, d.error); truthy(d.tableError:find("computeFinanceTable"), d.tableError)
		truthy(d.fleet.runningError:find("std::exception")); eq(d.fleet.running, nil)
		eq(#r.commands, 0, "finance sends nothing")
	end)

	test("status luaLoad: the GUI's and the game script's load / loadstring / setfenv; unread when off or no script", function()
		-- core: each name's type, "unread" when reading raised, all "unread" without a reader; gs values as strings only
		local k = core.luaLoadKinds(function(n) if n == "load" then return print elseif n == "setfenv" then error("strict") end end)
		eq(k.load, "function"); eq(k.loadstring, "nil"); eq(k.setfenv, "raised", "raised apart from not read")
		for _, bad in ipairs({ nil, {}, "load" }) do
			local u = core.luaLoadKinds(bad)
			eq(u.load, "unread"); eq(u.loadstring, "unread"); eq(u.setfenv, "unread")
		end
		for _, v in ipairs({ nil, {}, "x", { load = 5, loadstring = true } }) do
			local u = core.luaLoadGs(v)
			eq(u.load, "unread"); eq(u.loadstring, "unread"); eq(u.setfenv, "unread")
		end
		eq(core.luaLoadGs({ load = "function", setfenv = "nil" }).loadstring, "unread")
		eq(core.luaLoadGs({ load = "raised" }).load, "raised", "the script's raised kept")
		-- gameScript on: the script writes its own into the state once, beside what was there; status reads both
		local g = game({})
		g.gsValue = { runningCosts = { req = 5 } }
		local sets, set = 0, g.gsState.set
		g.gsState.set = function(self, v) sets = sets + 1; return set(self, v) end
		local was = _G.loadstring
		_G.loadstring = nil -- this run's Lua has all three: one taken away, for the script and the GUI alike
		local okRun, s = pcall(run, g, 9301, "status", "{}")
		_G.loadstring = was
		truthy(okRun, s)
		truthy(s.ok, s.error)
		eq(s.luaLoad.gui.load, "function"); eq(s.luaLoad.gui.loadstring, "nil"); eq(s.luaLoad.gui.setfenv, "function")
		eq(s.luaLoad.gs.load, "function"); eq(s.luaLoad.gs.loadstring, "nil"); eq(s.luaLoad.gs.setfenv, "function")
		eq(g.gsValue.runningCosts.req, 5, "the state's other keys kept")
		eq(sets, 1, "written once, not at each read of the setting")
		g.gs._resetForTests() -- (the setting is read again after 5 s of wall clock: as a new worker instead)
		frames(g, 2)
		eq(sets, 2, "written again when a value changed (loadstring back)")
		eq(g.gsValue.luaLoad.loadstring, "function")
		g.gs._resetForTests()
		frames(g, 2)
		eq(sets, 2, "and not again")
		-- the setting turned off after an on-run: the value left in the state is stale, not shown
		g.modParams = { hummer_remote_probe = { gameScript = 0 } }
		truthy(g.gsValue.luaLoad, "the old value still in the state")
		local s4 = run(g, 9304, "status", "{}")
		eq(s4.luaLoad.gs.load, "unread"); eq(s4.luaLoad.gs.loadstring, "unread"); eq(s4.luaLoad.gui.load, "function")
		-- the script's own values, apart from the GUI's (each state has its own globals)
		-- (the wall clock held still, so the script does not read the setting again and write its real values over these)
		g.modParams = { hummer_remote_probe = { gameScript = 2 } }
		local clock = os.time
		os.time = function() return 1800000000 end
		g.gs._resetForTests()
		frames(g, 2)
		g.gsValue.luaLoad = { load = "nil", loadstring = "raised", setfenv = "function" }
		local okS5, s5 = pcall(run, g, 9305, "status", "{}")
		os.time = clock
		truthy(okS5, s5)
		eq(s5.luaLoad.gs.load, "nil"); eq(s5.luaLoad.gs.loadstring, "raised"); eq(s5.luaLoad.gui.load, "function")
		-- gameScript off: nothing written; the GUI's still read
		local off = game({}, { gameScriptOff = true })
		local s2 = run(off, 9302, "status", "{}")
		eq(off.gsValue, nil, "off: no state written")
		eq(s2.luaLoad.gui.load, "function"); eq(s2.luaLoad.gs.load, "unread"); eq(s2.luaLoad.gs.setfenv, "unread")
		-- no game script at all (the state never handed over): unread
		local bare = h.vehicleGame({})
		local s3 = run(bare, 9303, "status", "{}")
		eq(s3.luaLoad.gs.loadstring, "unread"); eq(s3.luaLoad.gui.loadstring, "function")
	end)
end
