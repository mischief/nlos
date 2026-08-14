-- wifi: pick a network, and remember it.
--
--   > wifi                      ask, save, and join
--   > wifi labratory hunter2    save and join without asking
--   > wifi -s                   say what is saved
--   > wifi -l                   what is in range
--
-- Writes /config/wifi.lua, which init joins at startup, and
-- joins now through /net/wifi/ctl where the namespace has it. Without
-- that mount it still saves, and says so.
--
-- The passphrase is echoed as it is typed, and stored in the clear.
-- lib/console.lua's readline draws what it edits and has no way not to,
-- and there is no secure element here to store a key in -- it would
-- have to be readable by this machine to be usable, and the flash can
-- be read out over USB by whoever is holding the board.

-- Through the namespace rather than io.open: an unprivileged proc has
-- none (kernel_strip_io takes it), and the posix shim's open walks
-- before it opens, so it cannot make a file that is not there yet.
-- prog.ns() is the namespace this program was handed, and readfile and
-- writefile are what it already has.
local unistd = require("posix.unistd")
local prog = require("prog")

local N = assert(prog.ns(), "wifi: no namespace")

-- /config is the partition a reflash does not write, so a network saved
-- there survives one. A machine without that volume keeps its network
-- in /etc, and loses it the next time the filesystem is rebuilt.
local CONF = N:stat("/config") and "/config/wifi.lua" or "/etc/wifi.lua"

local function out(s)
	unistd.write(1, s)
end

local function die(s)
	unistd.write(2, "wifi: " .. s .. "\n")
	os.exit(1)
end

-- what is saved, or an empty table. A file that will not load is worth
-- saying so about rather than silently overwriting: it may be someone's
-- hand-written one with a typo in it.
local function saved()
	local src = N:readfile(CONF)

	if not src then
		return {}
	end

	local chunk, err = load(src, "=" .. CONF, "t", {})

	if not chunk then
		out("wifi: " .. CONF .. ": " .. tostring(err) .. "\n")
		return {}
	end

	local ok, conf = pcall(chunk)

	return (ok and type(conf) == "table") and conf or {}
end

-- One read is one line.
--
-- A console stream ignores the byte count and replies with the line its
-- own editor has just finished, newline already stripped -- see
-- lib/prog.lua's PortStream. So asking for a byte at a time does not
-- get a byte: it gets the whole line, which is then not a newline, and
-- the reader waits for a second line to end the first. Every prompt
-- needed Enter twice.
--
-- An empty answer and end of input are both "", and both mean "keep
-- what is there", which is what pressing Enter at a prompt should do.
local function readline()
	local l = unistd.read(0, 512)

	if l == nil or l == "" then
		return nil
	end
	return (l:gsub("[\r\n]+$", ""))
end

local function ask(prompt, default)
	if default and default ~= "" then
		out(("%s [%s]: "):format(prompt, default))
	else
		out(prompt .. ": ")
	end

	local l = readline()

	if l == nil or l == "" then
		return default
	end
	return l
end

-- the radio, where this namespace has it. WIFI is nil on a machine
-- whose interface has nothing to associate, and every use below is
-- guarded by that rather than by asking what platform this is.
local WIFI = N:stat("/net/wifi/ctl") and "/net/wifi" or nil

local function scanlines()
	local txt = N:readfile(WIFI .. "/scan")

	if not txt then
		return {}
	end

	local aps = {}

	for line in txt:gmatch("[^\n]+") do
		local rssi, auth, ssid = line:match("^(-?%d+) (%S+) (.*)$")

		if rssi and ssid ~= "" then
			aps[#aps + 1] = { rssi = tonumber(rssi),
			    open = auth == "open", ssid = ssid }
		end
	end
	return aps
end

local args = {}

for _, a in ipairs(arg) do
	if a == "-l" then
		if not WIFI then
			die("no radio on this machine")
		end
		out("scanning...\n")
		for _, ap in ipairs(scanlines()) do
			out(("%4d dBm  %-4s %s\n"):format(ap.rssi,
			    ap.open and "open" or "psk", ap.ssid))
		end
		os.exit(0)
	elseif a == "-s" then
		local c = saved()

		if c.ssid then
			out(("ssid %s\npsk %s\n"):format(c.ssid,
			    (c.psk and c.psk ~= "") and c.psk or "(open)"))
		else
			out("no network saved\n")
		end
		os.exit(0)
	else
		args[#args + 1] = a
	end
end

local have = saved()
local ssid = args[1] or ask("ssid", have.ssid)

if ssid == nil or ssid == "" then
	die("no ssid")
end

local psk = args[2] or ask("passphrase", have.psk)

-- %q rather than quotes of our own: a passphrase is exactly the kind of
-- string that has a quote or a backslash in it, and %q writes something
-- lua reads back as what went in.
local ok, err = N:writefile(CONF,
    ("-- written by wifi\nreturn {\n\tssid = %q,\n\tpsk = %q,\n}\n")
    :format(ssid, psk or ""))

if not ok then
	die(CONF .. ": " .. tostring(err))
end

out(("saved %s\n"):format(CONF))

if not WIFI then
	out(("joins %s at next boot\n"):format(ssid))
	os.exit(0)
end

-- one field a line: a passphrase is a sentence as often as it is a
-- word, and an ssid may hold a space too.
local wok, werr = N:writefile(WIFI .. "/ctl",
    "join\n" .. ssid .. "\n" .. ((psk and psk ~= "") and psk or ""))

if not wok then
	die("join: " .. tostring(werr))
end

-- association is asynchronous, so report what it settled on rather than
-- that the write succeeded -- a wrong passphrase fails here, not above.
out("joining " .. ssid .. "...\n")
for _ = 1, 20 do
	local st = N:readfile(WIFI .. "/status") or ""
	local state = st:match("state (%S+)")

	if state == "joined" then
		out("joined " .. ssid .. "\n")
		os.exit(0)
	elseif state == "failed" then
		out(("failed: reason %s\n"):format(st:match("reason (%S+)") or "?"))
		os.exit(1)
	end
	require("los.thread").sleep(250)
end
out("still joining; " .. WIFI .. "/status says how it ends\n")
