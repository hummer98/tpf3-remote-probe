-- company / company init: the base's company progression (company level, perks, ticket price multiplier) and
-- the event a new game gets from the base's new-game page.
--
-- Why (stdout 2026-11-22 18:02Z, a game newgame started): "companiesState is not initialized, returning 0 for
-- basePopulation!" once, and from the first passenger on "company_growth.script.tl(161): attempt to index field
-- 'companyState' (a nil value)" at each OnCalcTicketPrice. The base sets that state only on the engine event
-- initNewGameFromMap (or initMission): company.script stores the world's population as basePopulation then, and
-- company_growth.script makes its companyState from it (its update gives up while basePopulation is 0). The base's
-- new-game page starts a game with app.startGame2 and a map its preview widget generated; the probe's newgame uses
-- app.startGame ("a new test game", app.d.tl), which sends no initNewGameFromMap: no company level, no perks, no
-- ticket price multiplier, and towns.script, subventions.script and notifications.script miss their start too.
-- startGame2 is not open to the probe: the map it takes is made by the menu's MapPreviewComp widget (a builtin
-- the GUI mounts; no Lua call runs a terrain generator into a GameMap), and the menu probe has no GUI tree.
--
-- company: read only, both scripts' states (GAME_SCRIPT .state, as company_util.externalGetCompaniesState reads
-- it) for the player's company.
-- company init: test saves only. Sends the base's event itself, as the engine would (makeScriptingSendEventCmd
-- with src "", id "", name initNewGameFromMap), when company.gs has no basePopulation, then waits until it has one.
-- The command's doc says the event is "broadcasted to all scripts"; scripts subscribe to event names
-- (GameScriptState.subscribeToEvent), and none of the base's subscribes to this one, so whether a sent copy
-- reaches them is not known before it is tried in a game: the answer says what the states show afterwards.
-- What the event does in the base (game_mechanics, read 2026-11-23): company.script resets its companies' state
-- (permits used, prospections) and takes the world population as basePopulation; company_growth.script empties
-- its companyState; towns.script sets each town's cached ratings to 1; subventions.script and notifications.script
-- start their states again. Other mods' scripts may listen to it too.
local M = {}

M.COMPANY_SCRIPT = "::/game_mechanics/company/company.gs"
-- the base's own util asks for it without the slash (company_progression_util.tl); both are tried
M.GROWTH_SCRIPTS = { "::game_mechanics/company/company_progression.gs", "::/game_mechanics/company/company_progression.gs" }
M.EVENT = "initNewGameFromMap"
M.WAIT_SEC = 15

local NOTE = "test saves only: the base's initNewGameFromMap sent by hand also resets the towns' cached ratings, "
	.. "the subventions and the notifications (other mods' scripts may listen to it too)"

-- ctx: core, answer(id, payload, tag), fail(id, msg), appTime(), try(fn), say(msg, level), mapEditor() -> boolean
function M.new(ctx)
	local core, answer, fail, appTime, try, say = ctx.core, ctx.answer, ctx.fail, ctx.appTime, ctx.try, ctx.say
	local job = nil

	local function scriptState(names)
		if type(names) == "string" then names = { names } end
		for _, name in ipairs(names) do
			local e = tonumber(try(function() return api.engine.system.gameScriptSystem.getEntityForGameScript(name) end))
			if e ~= nil and e >= 0 then
				local gs = try(function() return api.engine.getComponent(e, api.type.ComponentType.GAME_SCRIPT) end)
				if gs == nil then return { script = name, running = true, error = "no GAME_SCRIPT component" } end
				local st = try(function() return gs.state end)
				if type(st) ~= "table" then
					local n = try(function() return gs.state_native end)
					st = n ~= nil and try(function() return n:asTable() end) or nil
				end
				return { script = name, running = true, state = type(st) == "table" and st or nil }
			end
		end
		return { script = names[1], running = false }
	end

	-- the player's company, both scripts, and what is missing
	local function read()
		local player = tonumber(try(function() return api.engine.util.getPlayer() end))
		local c = scriptState(M.COMPANY_SCRIPT)
		local gr = scriptState(M.GROWTH_SCRIPTS)
		local out = { player = player, mapEditor = ctx.mapEditor() == true,
			mission = try(function() return api.engine.util.hasStartedAsMission() end) == true }
		local cs = c.state
		out.company = { script = c.script, running = c.running, error = c.error,
			basePopulation = cs and tonumber(cs.basePopulation) or nil, version = cs and cs.version or nil }
		local n = 0
		if cs and type(cs.companyStates) == "table" then for _ in pairs(cs.companyStates) do n = n + 1 end end
		out.company.companies = cs and n or nil
		out.company.initialized = out.company.basePopulation ~= nil
		local gs = gr.state
		local mine = gs and type(gs.companyState) == "table" and player and gs.companyState[player] or nil
		out.growth = { script = gr.script, running = gr.running, error = gr.error,
			initialized = gs ~= nil and type(gs.companyState) == "table" }
		if type(mine) == "table" then
			out.growth.player = { level = tonumber(mine.level), potentialLevel = tonumber(mine.potentialLevel),
				experience = tonumber(mine.experience), ticketPriceMultiplier = tonumber(mine.ticketPriceMultiplier) }
		end
		-- the bottom-left company button (game_bar.tl CompanyButton) shows the rank only for an entry with
		-- experience > 0, else the text "Achievements"
		out.rankButton = core.companyRankButton(out.growth.player)
		out.worldPopulation = core.worldPopulation(try(function()
			return api.engine.system.townBuildingSystem.getTown2personCapacitiesMap() end))
		out.diagnosis = core.companyDiagnosis(out)
		return out
	end

	local T = {}

	function T.show(c)
		local out = read()
		out.ok = true
		answer(c.id, out)
	end

	function T.init(c)
		local before = read()
		local out = { ok = true, cmd = "companyInit", dryRun = c.args.dryRun == true or nil, event = M.EVENT,
			before = before, note = NOTE }
		if job then
			out.ok, out.sent = false, false
			out.error = "company init (command " .. job.id .. ") is still waiting: send again once it has answered"
			return answer(c.id, out, "error")
		end
		local why = core.companyInitRefusal(before)
		if why then return fail(c.id, why) end
		if before.company.initialized then
			out.sent = false
			out.alreadyInitialized = true
			out.note = "company.gs has its basePopulation (" .. tostring(before.company.basePopulation)
				.. "): the game had its start event, nothing sent"
			return answer(c.id, out)
		end
		if out.dryRun then
			out.sent = false
			return answer(c.id, out)
		end
		local okM, cmd = pcall(function() return api.cmd.makeScriptingSendEventCmd("", "", M.EVENT, {}) end)
		if not okM or cmd == nil then return fail(c.id, "making the command failed: " .. tostring(cmd)) end
		local j = { id = c.id, out = out, deadline = appTime() + M.WAIT_SEC, startedAt = appTime() }
		job = j
		local okS, err = pcall(function()
			api.cmd.sendCommand(cmd, function(_, success)
				if job == j then j.called, j.success = true, success end
			end)
		end)
		if not okS then
			job = nil
			return fail(c.id, "sendCommand raised: " .. tostring(err))
		end
		out.sent = true
		say("company init (command " .. c.id .. "): sent the base's " .. M.EVENT .. " (company.gs had no basePopulation)", 1)
	end

	local function finish(j, ok, err)
		job = nil
		local out = j.out
		out.after = read()
		out.waitedSec = appTime() - j.startedAt
		out.engineSuccess = j.success
		if not ok then
			out.ok, out.error = false, err
			say("company init (command " .. j.id .. "): " .. err, 1)
			return answer(j.id, out, "error")
		end
		if not out.after.growth.player then
			out.growthNote = "company_growth makes the company's level in its update from the next simulation step "
				.. "on: run the game a moment and look again (company)"
		end
		answer(j.id, out)
	end

	function T.step()
		local j = job
		if j == nil then return end
		local ok, err = pcall(function()
			if j.called and j.success == false then
				return finish(j, false, "the engine refused the script event (its callback said no success)")
			end
			local now = read()
			if now.company.initialized then return finish(j, true) end
			if appTime() > j.deadline then
				finish(j, false, "sent, but company.gs still has no basePopulation after " .. M.WAIT_SEC .. " s: "
					.. "the event did not reach it (a sent event may reach only the scripts subscribed to its name), "
					.. "or the game did not run the command (paused?)")
			end
		end)
		if not ok then
			if job == j then job = nil end
			fail(j.id, err)
		end
	end

	function T.reset() job = nil end

	T.handlers = { company = T.show, companyInit = T.init }
	return T
end

return M
