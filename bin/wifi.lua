-- wifi: pick a network, and remember it.
--   > wifi -j                   ask for a network, then join it
--   > wifi -j labratory hunter2 join that one
--   > wifi -s                   the networks saved, best first
--   > wifi -l                   what is in range
--   > wifi -f labratory         forget one

-- Everything goes through /net/wifi/ctl: task/wifisrv.lua holds the
-- list and writes it, a join is saved before the radio is told, and it
-- goes to the front. A second writer here would reduce a list of
-- networks to whichever of the two wrote last.

-- The passphrase is echoed as it is typed and stored in the clear.
-- lib/console.lua's readline draws what it edits, and the flash can be
-- read out over USB by whoever is holding the board.

-- Through the namespace rather than io.open: an unprivileged proc has
-- none, and this has to make a file that is not there yet.
local prog = require("prog")

local N = assert(prog.ns(), "wifi: no namespace")

local function out(s)
	io.write(s)
end

local function die(s)
	io.stderr:write("wifi: " .. s .. "\n")
	os.exit(1)
end

-- the radio, where this namespace has it. A session that should not
-- retune it is given a namespace without this mount, so its absence is
-- an answer and not a fault.
local W = require("wifi").new(N)

local function ctl(...)
	local wok, werr = W:ctl(...)

	if not wok then
		die(tostring(werr))
	end
end

-- "l", not a byte count: io.read(n) fills to n bytes before it answers,
-- so a prompt would look hung. The console puts the newline back on an
-- ABI read, so a line terminates here. "" is an empty line; only nil is
-- end of input.
local function readline()
	local l = io.read("l")

	if l == nil then
		return nil
	end
	return (l:gsub("\r+$", ""))
end

local function prompt(what, default)
	if default and default ~= "" then
		out(("%s [%s]: "):format(what, default))
	else
		out(what .. ": ")
	end

	local l = readline()

	if l == nil or l == "" then
		return default
	end
	return l
end

local USAGE = table.concat({
	"usage: wifi -j [ssid [passphrase]]   ask for a network, or join one",
	"       wifi -s                       the networks saved, best first",
	"       wifi -l                       what is in range",
	"       wifi -f ssid                  forget one",
}, "\n") .. "\n"

-- no arguments is a question, not an instruction: joining a network is
-- the one thing here that changes what the machine does, so it is asked
-- for by name rather than being what happens by default.
if not arg[1] then
	out(USAGE)
	os.exit(0)
end

local args = {}
local joining = false
local i = 1

while arg[i] do
	local a = arg[i]

	if a == "-h" then
		out(USAGE)
		os.exit(0)
	end

	if a == "-l" or a == "-s" or a == "-f" or a == "-j" then
		if not W then
			die("no radio in this namespace")
		end
	end

	if a == "-l" then
		out("scanning...\n")

		local aps, why = W:scan()

		if not aps then
			die(why)
		end
		if #aps == 0 then
			out("nothing in range\n")
		end
		for _, ap in ipairs(aps) do
			out(("%4d dBm  %-4s %s\n"):format(ap.rssi,
			    ap.open and "open" or "psk", ap.ssid))
		end
		os.exit(0)
	elseif a == "-s" then
		local nets = W:known()

		if #nets == 0 then
			out("no networks saved\n")
		end
		for n, net in ipairs(nets) do
			out(("%d. %-4s %s\n"):format(n,
			    net.open and "open" or "psk", net.ssid))
		end
		os.exit(0)
	elseif a == "-f" then
		i = i + 1
		if not arg[i] then
			die("-f wants an ssid")
		end
		ctl("forget", arg[i])
		out(("forgot %s\n"):format(arg[i]))
		os.exit(0)
	elseif a == "-j" then
		joining = true
	elseif a:match("^%-") then
		out(USAGE)
		die("no such option: " .. a)
	else
		args[#args + 1] = a
	end
	i = i + 1
end

if not joining then
	out(USAGE)
	die("nothing to do; -j joins")
end

-- the one it is on, or the one it prefers: both are better guesses at
-- what somebody retyping this means than nothing at all.
local function suggest()
	local ssid = W:status().ssid

	if ssid ~= "" then
		return ssid
	end

	local nets = W:known()

	return nets[1] and nets[1].ssid
end

local ssid = args[1] or prompt("ssid", suggest())

if ssid == nil or ssid == "" then
	die("no ssid")
end

local psk = args[2] or prompt("passphrase")

-- one field a line: a passphrase is a sentence as often as it is a
-- word, and an ssid may hold a space too.
ctl("join", ssid, psk or "")

out("joining " .. ssid .. "...\n")

local thread = require("los.thread")

for _ = 1, 30 do
	if W:status().state == "joined" then
		out(("joined %s, and saved\n"):format(ssid))
		os.exit(0)
	end
	thread.sleep(500)
end

out("still joining; /net/wifi/status says how it ends\n")
