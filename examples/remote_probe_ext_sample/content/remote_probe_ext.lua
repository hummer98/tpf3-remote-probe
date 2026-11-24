-- Commands of this mod for the remote probe (hummer_remote_probe): tf3ctl mod --list shows them, and
--   tf3ctl mod hummer_remote_probe_ext_sample hello '{"who": "me"}'
--   tf3ctl mod hummer_remote_probe_ext_sample speed '{"speed": 0}'
-- run them. The probe requires this file in the game's GUI Lua state and calls run(args, ctx); run returns the
-- answer (a table or a value that JSON can hold), or nil and a message for an error.
-- No new globals here: the game logs one made by a mod's file as an error.
return {
	api = 1,
	commands = {
		hello = {
			tag = "reads", -- only reads the game: sent like status
			description = "the game's date and speed, and the arguments back",
			run = function(args, ctx)
				local s = ctx.now()
				return { greeting = "hello" .. (type(args.who) == "string" and (", " .. args.who) or ""),
					date = s.date, speedup = s.speedup, args = args, from = ctx.owner }
			end,
		},
		speed = {
			tag = "changes", -- changes the game: the tool's owner check applies, as for tf3ctl speed
			description = "set the game speed to 0-4 (default 0, a pause); answers once the game took it",
			run = function(args, ctx)
				local n = args.speed == nil and 0 or tonumber(args.speed)
				if n == nil or n % 1 ~= 0 or n < 0 or n > 4 then return nil, "speed must be a whole number from 0 to 4" end
				-- the answer comes from the command's callback, on a later frame
				local finish = ctx.defer()
				local sent, err = ctx.sendCommand(api.cmd.makeGameSetSpeedCmd(n), function(_, success)
					finish({ speed = n, success = success == true, speedup = ctx.now().speedup })
				end)
				if not sent then finish(nil, "could not send the speed command: " .. tostring(err)) end
			end,
		},
	},
}
