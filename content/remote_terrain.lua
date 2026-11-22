-- terrain: a rectangle's ground made flat at a height, or a uniform slope along x or y, the rest of the map as it
-- is (core.terrainRequest has the arguments, terrain_work.lua the engine's part). For maps made for tests and
-- shots, in a test save or in the map editor (newgame --editor); whether the replacement works outside the
-- editor is not known (every use seen is in the editor).
--
-- Before anything is read or sent, what stands in the rectangle (and PAD_M round it) is looked for: a road or
-- track piece, a node, a construction, a town building or an industry, and a town whose box comes within
-- TOWN_MARGIN_M. Any of them and nothing is sent: the heights under them would change and what the engine does with
-- that is not known (the editor removes towns and industries before it replaces the terrain).
--
-- Only in the map editor (api.gui.game.isMapEditor()), unless inGame is given (a new test game): whether the
-- replacement works in a game, and what it does there, is not known. A dry run sends nothing and needs neither.
--
-- Two ways (via): "gui" (and auto, the default) hands the request to the speed control's recipe (its join, on the
-- main thread, where the base editor and the terrain mods call the same functions: they call them from react
-- only) through the GUI save data and reads its report back; "update" runs terrain_work in this guiUpdate state,
-- only when asked for. The answer says which way went, and which functions each state had.
--
-- Not checked in a game yet (written 2026-11-22): the answer says so.
local M = {}

local RESULT_SEC = 120 -- for the replacement's callback (a large map is a large table)
local PICKUP_SEC = 20 -- for the recipe to report on a gui request (it reads every 0.5 s while a game is on screen)
local PROBE_SEC = 10 -- terrainApi's wait for the recipe
local SETTLE_FRAMES = 3 -- before the heights are read back
local READ_TOLERANCE = 0.1 -- metres: the heightmap keeps 0.05 m steps
local PAD_M = 8 -- two grid points round the rectangle: what stands there sits on the triangles that change
local TOWN_MARGIN_M = 200
local MAX_LISTED = 10

local NOTE = "not checked in a game yet: read the heights back (water --grid) and look at it (frame) before trusting it"

-- ctx: core, work (terrain_work.lua), answer(id, payload, tag), fail(id, msg), appTime(), try(fn), say(msg, level),
-- publishUi(fields), towns() -> { { id, name } }, mod
function M.new(ctx)
	local core, work, answer, fail, appTime, try, say = ctx.core, ctx.work, ctx.answer, ctx.fail, ctx.appTime, ctx.try, ctx.say
	local publishUi = ctx.publishUi or function() end
	local REPORT_KEY = (ctx.mod or core.MOD_ID) .. ".terrain"
	local jobs = {}
	local requests = {} -- [id] = the gui request

	local function CT() return api.type.ComponentType end
	local function exists(e) return type(e) == "number" and try(function() return api.engine.entityExists(e) end) == true end
	local function comp(e, kind)
		local t = CT()[kind]
		if t == nil or not exists(e) then return nil end
		return try(function() return api.engine.getComponent(e, t) end)
	end
	local function mapEditor()
		local v = try(function() return api.gui.game.isMapEditor() end)
		if v == true or v == false then return v end
		return nil
	end

	-- what stands in the rectangle: { roads = { ids }, nodes, constructions, buildings, industries, towns }, the
	-- number found, and warnings (towns whose place could not be read)
	local BLOCKING = { { "BASE_EDGE", "roads" }, { "BASE_NODE", "nodes" }, { "CONSTRUCTION", "constructions" },
		{ "TOWN_BUILDING", "buildings" }, { "INDUSTRY", "industries" }, { "SUBCONSTRUCTION", "constructions" } }
	local function blockersIn(rc)
		local found, n, seen = {}, 0, {}
		local hits = {}
		local ok, err = pcall(function()
			local box = api.type.Box3.new(api.type.Vec3f.new(rc.x0 - PAD_M, rc.y0 - PAD_M, -1000),
				api.type.Vec3f.new(rc.x1 + PAD_M, rc.y1 + PAD_M, 5000))
			api.engine.system.octreeSystem.findIntersectingEntities(box, function(e)
				e = tonumber(e)
				if e and not seen[e] then seen[e] = true; hits[#hits + 1] = e end
			end)
		end)
		if not ok then return nil, "the octree could not be read: " .. tostring(err) end
		-- (components looked up after the octree walk, as remote_connect does)
		table.sort(hits)
		for _, e in ipairs(hits) do
			for _, b in ipairs(BLOCKING) do
				if comp(e, b[1]) ~= nil then
					found[b[2]] = found[b[2]] or {}
					table.insert(found[b[2]], e)
					n = n + 1
					break
				end
			end
		end
		local warnings = {}
		for _, t in ipairs(ctx.towns and ctx.towns() or {}) do
			local bv = comp(t.id, "BOUNDING_VOLUME")
			local bb = bv and core.field(bv, "bbox")
			local lo, hi = bb and core.field(bb, "min"), bb and core.field(bb, "max")
			local x0, y0 = tonumber(lo and core.field(lo, "x")), tonumber(lo and core.field(lo, "y"))
			local x1, y1 = tonumber(hi and core.field(hi, "x")), tonumber(hi and core.field(hi, "y"))
			if x0 and y0 and x1 and y1 then
				local m = TOWN_MARGIN_M
				if x1 + m >= rc.x0 and x0 - m <= rc.x1 and y1 + m >= rc.y0 and y0 - m <= rc.y1 then
					found.towns = found.towns or {}
					table.insert(found.towns, { id = t.id, name = t.name })
					n = n + 1
				end
			else
				warnings[#warnings + 1] = string.format("town %s (%s): its place could not be read; its buildings and streets were looked for",
					tostring(t.name), tostring(t.id))
			end
		end
		return found, n, warnings
	end

	local function blockedText(found)
		local parts = {}
		for _, k in ipairs({ "towns", "roads", "nodes", "constructions", "buildings", "industries" }) do
			local list = found[k]
			if list then
				local shown = {}
				for i = 1, math.min(#list, MAX_LISTED) do
					local v = list[i]
					shown[i] = type(v) == "table" and string.format("%s (%s)", tostring(v.name), tostring(v.id)) or tostring(v)
				end
				parts[#parts + 1] = string.format("%d %s (%s%s)", #list, k, table.concat(shown, ", "), #list > MAX_LISTED and ", ..." or "")
			end
		end
		return table.concat(parts, "; ")
	end

	local function arrays(found)
		local out = {}
		for k, v in pairs(found) do out[k] = core.array(v) end
		return out
	end

	-- the gui requests, as the line commands' (remote_lines.lua)
	local function publishRequests()
		local list = {}
		for _, r in pairs(requests) do list[#list + 1] = r end
		table.sort(list, function(a, b) return a.id < b.id end)
		publishUi({ terrain = list })
	end
	local function reportOf(id)
		local d = try(function() return api.gui.game.getGuiSaveData(REPORT_KEY) end)
		if type(d) ~= "table" or type(d.reports) ~= "table" then return nil end
		for _, r in ipairs(d.reports) do
			if type(r) == "table" and tonumber(r.id) == id then return core.plain(r) end
		end
		return nil
	end
	local function retire(job)
		if requests[job.id] then
			requests[job.id] = nil
			publishRequests()
		end
	end

	-- the answer from the request and the work's report
	local function payload(job)
		local r, rep = job.r, job.report or {}
		local out = { ok = true, cmd = "terrain", via = job.via, dryRun = r.dryRun or nil, inGame = r.inGame or nil,
			mapPoints = rep.mapPoints, rect = r.rect, mode = r.mode,
			z = r.z, pct = r.pct, base = r.base, blend = r.blend, keepAssets = true, note = NOTE,
			functionsUpdate = job.here, functionsGui = job.via == "gui" and rep.functions or nil,
			callableUpdate = job.hereCallable, callableGui = job.via == "gui" and rep.callable or nil,
			map = rep.map, grid = rep.grid, target = rep.target, before = rep.before, written = rep.written,
			changed = rep.changed, waterLevel = rep.waterLevel, seedText = rep.seedText,
			reloadMaterials = rep.reloadMaterials, sent = rep.sent, success = rep.success,
			samples = rep.samples and core.array(rep.samples) or nil, mapEditor = mapEditor(),
			warnings = job.warnings and #job.warnings > 0 and core.array(job.warnings) or nil }
		return out
	end

	local function readBack(out)
		local all = true
		for _, s in ipairs(out.samples or {}) do
			s.read = tonumber(try(function() return api.engine.terrain.getHeightAt(api.type.Vec2f.new(s.x, s.y)) end))
			s.diff = s.read and s.expected and s.read - s.expected or nil
			if not (s.diff and math.abs(s.diff) <= READ_TOLERANCE) then all = false end
		end
		out.readBackOk = all
		if not all then out.warning = "the heights read back differ from those sent (samples)" end
	end

	local function finish(job)
		retire(job)
		local out = payload(job)
		if out.sent and out.success ~= true then
			out.ok = false
			out.error = "the engine refused the replacement (its callback said no success)"
			say("terrain (command " .. job.id .. "): refused", 1)
			return answer(job.id, out, "error")
		end
		if out.sent then readBack(out) end
		answer(job.id, out)
	end

	local function failJob(job, msg)
		retire(job)
		local out = payload(job)
		out.ok, out.error = false, msg
		answer(job.id, out, "error")
	end

	local T = {}

	function T.handle(c)
		local r, err = core.terrainRequest(c.args)
		if not r then return fail(c.id, err) end
		local found, n, warnings = blockersIn(r.rect)
		if not found then return fail(c.id, n) end
		local here, hereCallable, missing = core.terrainFunctions()
		local job = { id = c.id, r = r, here = here, hereCallable = hereCallable, warnings = warnings, started = appTime() }
		if n > 0 then
			job.via = "none"
			local out = payload(job)
			out.ok, out.blockers = false, arrays(found)
			out.error = "nothing sent: in rect (and " .. PAD_M .. " m round it) stand " .. blockedText(found)
				.. ". Clear them first, or pick another place"
			return answer(c.id, out, "error")
		end
		if not r.dryRun and not r.inGame and mapEditor() ~= true then
			job.via = "none"
			return failJob(job, "not the map editor (api.gui.game.isMapEditor() is " .. tostring(mapEditor())
				.. "): whether a replacement works in a game is not known. In a new test game give inGame (--in-game)")
		end
		local via = r.via
		if via == "auto" then via = "gui" end
		job.via = via
		if via == "update" then
			if #missing > 0 then return failJob(job, "via update: missing in the guiUpdate state: " .. table.concat(missing, ", ")) end
			job.report = {}
			local ok, werr = pcall(work.work, r, job.report)
			if not ok then return failJob(job, "via update: " .. tostring(werr)) end
			if r.dryRun then return finish(job) end
			jobs[#jobs + 1] = job
			return
		end
		requests[c.id] = { id = c.id, kind = "apply", args = core.plain(c.args) }
		publishRequests()
		jobs[#jobs + 1] = job
	end

	-- terrainApi (read only): which functions each state has, looked at with type()
	function T.api(c)
		local here, hereCallable = core.terrainFunctions()
		requests[c.id] = { id = c.id, kind = "probe" }
		publishRequests()
		jobs[#jobs + 1] = { id = c.id, probe = true, here = here, hereCallable = hereCallable, started = appTime() }
	end

	local function stepJob(job)
		if job.probe then
			local rep = reportOf(job.id)
			if rep and rep.done then
				retire(job)
				answer(job.id, { ok = true, cmd = "terrainApi", update = job.here, gui = rep.functions,
					callable = { update = job.hereCallable, gui = rep.callable },
					needs = core.array(core.TERRAIN_NEEDS), mapEditor = mapEditor() })
				return true
			end
			if appTime() - job.started > PROBE_SEC then
				retire(job)
				answer(job.id, { ok = true, cmd = "terrainApi", update = job.here, gui = nil,
					callable = { update = job.hereCallable, gui = nil },
					needs = core.array(core.TERRAIN_NEEDS), mapEditor = mapEditor(),
					guiNote = string.format("the speed control's recipe did not answer in %d s (is a game on screen?)", PROBE_SEC) })
				return true
			end
			return false
		end
		if job.via == "gui" then
			local rep = reportOf(job.id)
			if rep then
				job.report, job.picked = rep, true
				if rep.error ~= nil then failJob(job, "via gui: " .. tostring(rep.error)); return true end
			end
			if not job.picked and appTime() - job.started > PICKUP_SEC then
				failJob(job, string.format("via gui: the speed control's recipe did not take it up in %d s (is a game on screen?)", PICKUP_SEC))
				return true
			end
			if job.picked and job.r.dryRun and job.report.done then finish(job); return true end
		end
		local rep = job.report
		if rep and rep.success ~= nil then
			job.settle = (job.settle or 0) + 1
			if job.settle > SETTLE_FRAMES then finish(job); return true end
			return false
		end
		if appTime() - job.started > RESULT_SEC then
			failJob(job, string.format("no answer from the engine in %d s (look at the map: water --grid)", RESULT_SEC))
			return true
		end
		return false
	end

	function T.step()
		if #jobs == 0 then return end
		local keep = {}
		for _, job in ipairs(jobs) do
			local ok, done = pcall(stepJob, job)
			if not ok then
				retire(job)
				fail(job.id, done)
			elseif not done then
				keep[#keep + 1] = job
			end
		end
		jobs = keep
	end

	-- a new game: no job of the old one answers into it; the recipe's old reports are cleared
	function T.reset()
		jobs, requests = {}, {}
		pcall(function() api.gui.game.setGuiSaveData(REPORT_KEY, { reports = {} }) end)
	end

	return T
end

return M
