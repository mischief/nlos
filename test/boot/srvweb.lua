-- web terminal payload for test/test_web.py: serve the browser shell on
-- tcp/7777 and announce readiness on com1 once dhcp has landed, same
-- handshake as srvhttp.lua.
--
-- this doubles as the reference deployment. what a visitor gets is
-- decided entirely here, in the namespace handed to lib/webterm.lua --
-- the module itself has no policy about content.

local sys = require("los.sys")
local caps = require("caps")
local dev = require("dev")
local ns = require("ns")
local webterm = require("webterm")
local caps_of = sys.granted()

local tcp = caps.tcp(caps_of.tcp)

-- the programs, read off the ESP here (this proc has the disk) and
-- carried into each visitor's namespace as plain data. a visitor never
-- touches the real /bin.
--
-- the cost is a copy per session, which is why this is the stage-1
-- shape rather than the final one: /bin wants to be one srv.lua proc
-- that every session mounts with a "mnt" right, shared and read-only,
-- for the price of a proc. see lib/srv.lua.
local function slurp(path)
	local f = io.open(path, "r")

	if not f then
		return "-- missing: " .. path .. "\n"
	end
	local src = f:read("a")

	f:close()
	return src
end

-- this payload REPLACES init.lua, so it does not inherit init's dhcp
-- client either -- and without one, the listen below waits for the
-- firmware's, which sits on an offer it already holds for four seconds
-- (the whole argument is in lib/dhcp.lua). that was the entire gap
-- between "web terminal ready t=5294ms" and t~1200ms.
--
-- a PROC rather than a one-shot acquire, because this one is meant to
-- stay up and a lease has to be renewed. no ns= is passed: dhcpd is a
-- child of proc 0 and resolves its own requires through the ambient
-- searcher, same as everything else this payload spawns.
local dhcpd = nil

if caps_of.udp then
	local _, h = require("proc").spawn(slurp("/lib/dhcpd.lua"), {
		name = "dhcp",
		arg = {
			tcp = { __right = caps_of.tcp },
			udp = { __right = caps_of.udp },
		},
	})

	dhcpd = h
end

local site = {
	["README"] = [[
lua-os -- lua 5.4 on bare uefi, and you are inside it.

this shell is a proc of your own. it holds exactly one right: the
console you are typing into. no network, no disk, no other procs.
everything under / is a private copy -- write to it freely, it dies
when you disconnect.

try:  help        ls /bin        seq 1 10        cat notes/hello
]],
	["notes"] = {
		["hello"] = "the whole filesystem you are looking at is one " ..
		    "lua table.\nsee lib/dev.lua's dev.mem.\n",
	},
	["bin"] = {
		["ls.lua"] = slurp("/bin/ls.lua"),
		["cat.lua"] = slurp("/bin/cat.lua"),
		["seq.lua"] = slurp("/bin/seq.lua"),

		-- for test_web.py, and it exists because `seq` cannot test
		-- this: a program writing flat out dies on MAXQUEUE (64KB of
		-- SERIALIZED messages, so ~1600 line-sized writes) long
		-- before webterm's pump deadline is reached. what reaches
		-- the deadline is a producer PACED slow enough never to fill
		-- the queue and steady enough to keep the drain loop fed --
		-- which is this. not shipped to visitors; test/boot only.
		-- for test_web.py: reports what ambient authority a visitor's
		-- program actually holds. this is the sandbox assertion, and
		-- it is a PROGRAM because there is no other way to run code
		-- as a visitor -- the shell has no eval.
		["probe.lua"] = [==[
			local unistd = require("posix.unistd")
			local sys = require("los.sys")
			local out = {}

			-- run twice, this is the same pid iff programs are
			-- coroutines in the shell's proc rather than procs
			out[#out + 1] = "pid=" .. tostring(sys.self())
			out[#out + 1] = "io.open=" .. tostring(io.open ~= nil)
			out[#out + 1] = "loadfile=" ..
			    tostring(loadfile ~= nil)
			out[#out + 1] = "dofile=" .. tostring(dofile ~= nil)
			unistd.write(1, table.concat(out, " ") .. "\n")
		]==],

		["drip.lua"] = [==[
			local thread = require("los.thread")
			local unistd = require("posix.unistd")

			for i = 1, 200 do
				unistd.write(1, "drip " .. i .. "\n")
				thread.sleep(50)
			end
		]==],
	},
	["tmp"] = {},
}

-- built through ns rather than as a literal so mount() validates the
-- backend, then described: the description is what actually travels,
-- and for the "mem" kind it is the tree itself.
local N = ns.new()

assert(N:mount("/", dev.mem(site), "mem", { tree = site }))

webterm.serve(tcp, 7777, N:describe(), {
	-- a visitor arrives with no context at all -- no man pages, no
	-- prior session, and nothing on the page to read. the banner is
	-- the only place to say what to type first, so it names the two
	-- commands that lead everywhere else rather than just greeting.
	banner = "lua-os " .. sys.stats().arch ..
	    " -- an experimental os, and this is a shell inside it.\n" ..
	    "type 'help' for commands, 'cat README' for what this is.\n\n",
	onready = function()
		print("web terminal ready t=" .. sys.uptime_ms() .. "ms")
	end,
})
