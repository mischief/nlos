-- shot: send the screen to the host over ZMODEM.
--
--	> shot panel.pbm [rows]
--
-- Receive it with `lrz -y`; tools/screenshot-esp32.lua drives both
-- halves. The sender is a proc of its own, and waiting for it is what
-- keeps a second reader off the console.

local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")
local proc = require("proc")

local args = prog.ctx and prog.ctx.args or {}
local name = args[2]

if not name then
	io.stderr:write("usage: shot NAME.pbm [rows]\n")
	os.exit(2)
end

local ctx = prog.ctx
local fb = ctx and ctx.fb
local cons = ctx and ctx.stdout and ctx.stdout.h

if not fb then
	io.stderr:write("shot: no screen on this machine\n")
	os.exit(1)
end
if not cons then
	io.stderr:write("shot: no console to send over\n")
	os.exit(1)
end

local N = prog.ns()
local src = N and N:readfile("/task/shot.lua")

if not src then
	io.stderr:write("shot: /task/shot.lua is not here\n")
	os.exit(1)
end

-- proc.spawn rather than sys.spawn: the sender requires lib/zmodem.lua,
-- and a raw spawn gives the child no namespace to find it in.
local pid, right = proc.spawn(src,
    { name = "shot", ns = N:describe() })

if not pid then
	io.stderr:write("shot: cannot start the sender\n")
	os.exit(1)
end

sys.send(right, {
	cons = { __right = cons },
	fb = { __right = fb },
	name = name,
	rows = tonumber(args[3]),
	done = { __right = sys.SELF },
})
sys.close(right)

-- the death as well as the answer: a sender that raises never sends
-- one, and without this the wait below never ends.
sys.monitor(pid)

while true do
	local m = thread.recv(sys.SELF)

	if type(m) == "table" and m.exit == pid then
		-- a corpse keeps its heap so it can be read; nothing else
		-- would free it, and a few failed shots would add up.
		pcall(sys.reap, pid)
		io.stderr:write("shot: sender died: " ..
		    tostring(m.reason or m.exitmsg) .. "\n")
		os.exit(1)
	elseif type(m) == "table" and m.ok ~= nil then
		if not m.ok then
			io.stderr:write("shot: " .. tostring(m.err) .. "\n")
			os.exit(1)
		end
		break
	end
end
