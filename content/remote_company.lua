-- company / company init: the base's company progression (company level, perks, ticket price multiplier) and
-- the start event that sets it up.
--
-- How the base sets it up (game_mechanics/company, read 2026-11-23): on the engine event initNewGameFromMap (or
-- initMission) company.script stores the world's population as basePopulation, and company_growth.script makes
-- its companyState from it in its update, which returns while basePopulation <= 0. So a game that starts with no
-- town population keeps basePopulation 0: no rank (the company button shows "Achievements"), no perks, no ticket
-- price multiplier. company_growth errors at each ticket price when its companyState is nil (stdout 2026-11-22
-- 18:08Z, company_growth.script.tl(161) at each OnCalcTicketPrice, on a map started with no towns; that the empty
-- companyState the event sets is lost in such a game is a guess: growth.initialized stayed false, e2e 2026-11-23).
-- Measured 2026-11-23 (e2e of 32bfbc7): newgame (app.startGame) does get the start event: with generated towns
-- basePopulation 793 and the rank after 10 days with nothing sent; with --no-towns, or on a flat base with towns
-- placed later, basePopulation 0, and still 0 / no companyState after towns were placed and 20 days run.
--
-- company: read only, both scripts' states (GAME_SCRIPT .state, as company_util.externalGetCompaniesState reads
-- it) for the player's company, and the towns' population now.
-- company init: test saves only. Sends the start event again (makeScriptingSendEventCmd with src "", id "", name
-- initNewGameFromMap) when basePopulation is missing, or 0 while the towns have population now
-- (core.companyInitDecision); force always sends. Then waits until a read shows it ran (core.companyInitSeen).
-- The command's doc says the event is "broadcasted to all scripts"; scripts subscribe to event names
-- (GameScriptState.subscribeToEvent), and none of the base's subscribes to this one, so whether a sent copy
-- reaches them is not known before it is tried in a game: the answer says what the states show afterwards.
-- What the event does in the base: company.script resets its companies' state (permits used, prospections) and
-- takes the world population as basePopulation; company_growth.script empties its companyState (the company's
-- experience and level); towns.script sets each town's cached ratings to 1; subventions.script and
-- notifications.script start their states again, and company.script sets the game speed to 1
-- (makeGameSetSpeedCmd); the GUI's context_helper.script sets showWelcome. Other mods' scripts may listen to it.
-- A send that timed out is remembered: one queued while the game did not run the command would run later, and a
-- second send would then reset the progression again, so another send needs force.
local M = {}

M.COMPANY_SCRIPT = "::/game_mechanics/company/company.gs"
-- the base's own util asks for it without the slash (company_progression_util.tl); both are tried
M.GROWTH_SCRIPTS = { "::game_mechanics/company/company_progression.gs", "::/game_mechanics/company/company_progression.gs" }
M.EVENT = "initNewGameFromMap"
M.WAIT_SEC = 15

local NOTE = "test saves only: the base's initNewGameFromMap sent by hand also resets the towns' cached ratings, "
	.. "the subventions and the notifications, sets the game speed to 1 (company.script, as a base new game) and "
	.. "the welcome flag (context_helper); other mods' scripts may listen to it too"

-- ctx: core, answer(id, payload, tag), fail(id, msg), appTime(), try(fn), say(msg, level), mapEditor() -> boolean
function M.new(ctx)
	local core, answer, fail, appTime, try, say = ctx.core, ctx.answer, ctx.fail, ctx.appTime, ctx.try, ctx.say
	local job = nil
	local timedOut = nil -- the id of a send that timed out (its event may still run)

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
		local sp = try(function()
			return api.engine.getComponent(api.engine.util.getWorld(), api.type.ComponentType.GAME_SPEED) end)
		out.speedup = sp and tonumber(try(function() return sp.speedup end)) or nil
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
		local force = c.args.force == true
		local d = core.companyInitDecision(before, force)
		out.force = force or nil
		out.reason = d.reason
		if not d.send then
			out.sent = false
			out.alreadyInitialized = (before.company.basePopulation or 0) > 0 or nil
			out.noPopulation = d.noPopulation
			return answer(c.id, out)
		end
		if timedOut and not force then
			return fail(c.id, "the send of command " .. timedOut .. " timed out, and its event may still run (a "
				.. "command queued while the game did not run it): a second one would reset the progression again. "
				.. "Run the game a moment and look (company); force = true sends again")
		end
		if out.dryRun then
			out.sent, out.wouldSend = false, true
			return answer(c.id, out)
		end
		local okM, cmd = pcall(function() return api.cmd.makeScriptingSendEventCmd("", "", M.EVENT, {}) end)
		if not okM or cmd == nil then return fail(c.id, "making the command failed: " .. tostring(cmd)) end
		local j = { id = c.id, out = out, before = before, deadline = appTime() + M.WAIT_SEC, startedAt = appTime() }
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
		say("company init (command " .. c.id .. "): sent the base's " .. M.EVENT .. " (" .. d.reason .. ")", 1)
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
		-- what the event should have given: the towns' population as basePopulation
		local base, world = out.after.company.basePopulation, out.after.worldPopulation
		out.expectedBasePopulation = world
		out.basePopulationMatches = base ~= nil and world ~= nil and math.abs(base - world) <= math.max(1, world * 0.1)
		-- (right after the send both count the same town capacities, so this only shows the event took today's
		-- towns; the rank is what decides)
		out.check = "company_growth makes the company's level in its update from the next simulation steps on: run "
			.. "the game a few days (speed 4) and look with company: growth.initialized true, growth.player.level, "
			.. "rankButton rank. basePopulationMatches only says the event took today's towns; a small "
			.. "basePopulation (towns just placed) makes the ranks come sooner"
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
			if core.companyInitSeen(j.before, now) then
				timedOut = nil
				return finish(j, true)
			end
			if appTime() > j.deadline then
				timedOut = j.id
				finish(j, false, "sent, but after " .. M.WAIT_SEC .. " s company.gs's basePopulation is as before ("
					.. tostring(j.before.company.basePopulation) .. ") and company_growth's entry is unchanged: the "
					.. "event did not reach the scripts (a sent event may reach only those subscribed to its name), the "
					.. "game did not run the command (paused?), or (forced) the population had not changed")
			end
		end)
		if not ok then
			if job == j then job = nil end
			fail(j.id, err)
		end
	end

	function T.reset() job, timedOut = nil, nil end

	T.handlers = { company = T.show, companyInit = T.init }
	return T
end

return M
