-- webterm: the browser shell, as a service.
--
-- compare test/boot/srvweb.lua, which does the same job as a fw_cfg
-- payload: ~130 lines, of which about 100 were bringing the machine up
-- because replacing init.lua meant nobody else would. no DHCP client
-- here, no hand-built namespace, no io.open, no sys.granted() -- init
-- did all of that, and this is handed exactly what it declared in
-- /etc/services.lua.
--
-- the ARG is the whole interface (see lib/svc.lua):
--	a.tcp        the right this service named in its caps list
--	a.args       whatever the config passed it

local sys = require("los.sys")
local tcpc = require("client.tcp")
local dev = require("dev")
local ns = require("ns")
local webterm = require("webterm")

local a = ...

if not (type(a) == "table" and a.tcp) then
	print("webterm: no tcp capability, not serving")
	return
end

local args = a.args or {}
local port = args.port or 80
local tcp = tcpc.new(a.tcp.__right)

-- the published namespace. plain data, so it travels in nsdesc and each
-- visitor gets a private copy whose writes die with the session.
--
-- programs come from the namespace this service was given -- which is
-- init's, so /bin is the real one -- and are copied in as data. still a
-- copy per session; the fix remains a read-only ESP server that every
-- session mounts instead, which is also what would let a visitor adopt a
-- namespace properly. see lib/webterm.lua's header.
local N = ns.current()

local function slurp(path)
	local src = N and N:readfile(path)

	return src or ("-- missing: " .. path .. "\n")
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
	},
	["tmp"] = {},
}

local V = ns.new()

assert(V:mount("/", dev.mem(site), "mem", { tree = site }))

webterm.serve(tcp, port, V:describe(), {
	banner = "lua-os " .. sys.stats().arch ..
	    " -- an experimental os, and this is a shell inside it.\n" ..
	    "type 'help' for commands, 'cat README' for what this is.\n\n",
	onready = function(p)
		print("webterm: serving on tcp/" .. p ..
		    " t=" .. sys.uptime_ms() .. "ms")
	end,
})
