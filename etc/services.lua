-- what this machine runs, and what each of those may touch.
--
-- read by lib/svc.lua from init.lua once the machine is up. `caps` names
-- are looked up in sys.granted(), and the rights found there are ALL the
-- authority a service gets -- it has no path to anything it did not name.
-- so this file is the machine's capability grant table, which is the job
-- unix would want users and mode bits for.
--
-- a service naming a capability this machine does not have (tcp with no
-- NIC) is skipped rather than started to fail.
--
-- it is a lua chunk rather than a data format so a machine can decide
-- what to run from what it can see, without this growing a syntax.

return {
	-- the browser shell. off by default: it hands anonymous visitors a
	-- shell, which is a decision to make deliberately rather than
	-- inherit from a default config.
	-- note port 80 rather than 7777: init's 9p-over-tcp server holds
	-- 7777, and two listeners on one port is EFI_INVALID_PARAMETER.
	-- { path = "/svc/webterm.lua", caps = { "tcp" },
	--   args = { port = 80 } },
}
