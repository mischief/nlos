-- reboot: sync the volumes, then restart the machine.
--
--   > reboot          restart
--   > reboot -w       a warm reset, where the firmware distinguishes one
--   > reboot -p       power off instead
--
-- The repl has `halt()` as a bare word; a dos shell has no bare-word
-- globals, so the same authority needs a program in front of it. See
-- bin/ps.lua.
--
-- Unlike ps and stats this one holds a capability: the power task,
-- lent by the shell the same way the screen and the network are. A
-- shell that was given no power -- an ssh session, a browser session --
-- hands out none, and this program says so rather than failing oddly.
--
-- What the three modes mean is the platform's business. efi passes them
-- to ResetSystem; microvm and esp32 have one reset each and take any
-- mode as that, so `-p` there is a restart. Ask the platform, not this
-- program, which of them your machine can tell apart.

local prog = require("prog")
local ns = require("ns")

local function die(s)
	io.stderr:write("reboot: " .. s .. "\n")
	os.exit(1)
end

-- A fat volume's cache is write-back and a tick commits it every few
-- seconds, so a reset on its own throws away whatever was written in
-- between. Every mount that answers to a ctl file is told to sync;
-- one that has no such file is not a volume with anything to lose.
local function syncvolumes()
	local N = ns.current()
	local n = 0

	for _, m in ipairs((N and N.mounts) or {}) do
		local at = m.prefix or ""

		if at == "/" then
			at = ""
		end

		local path = at .. "/ctl"

		if N:stat(path) and pcall(N.writefile, N, path, "sync") then
			n = n + 1
		end
	end
	return n
end

local mode = "cold"

for _, a in ipairs(arg) do
	if a == "-w" then
		mode = "warm"
	elseif a == "-p" then
		mode = "shutdown"
	else
		die("usage: reboot [-w | -p]")
	end
end

local power = prog.power()

if not power then
	die("no power capability: this shell was not given one")
end

-- before anything is said about resetting: the sync is the part that
-- must happen, and a machine that cannot say so still commits.
local synced = syncvolumes()

io.write(("%s... (%d volume%s synced)\n"):format(
    mode == "shutdown" and "powering off" or "rebooting",
    synced, synced == 1 and "" or "s"))

-- the message and the reset go to one mailbox and are handled in the
-- order they are sent, so the stall lands first. It is what gives the
-- line above time to leave the uart: a machine that resets with output
-- still in flight prints nothing, and the reset then looks like a
-- crash. See src/platform/microvm/uart.c.
power.stall(100000)
power.reset(mode)

-- the reset is a send, so this returns. Nothing after it is reachable
-- on a machine that resets, and on one that does not, exiting is the
-- honest thing to do rather than hanging.
