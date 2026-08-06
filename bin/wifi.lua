-- wifi: remember a network to join.
--
--   > wifi                      ask, and save
--   > wifi labratory hunter2    save without asking
--   > wifi -s                   say what is saved
--
-- Writes /etc/wifi.lua, which boot/esp32.lua reads and joins at startup.
-- It does not join now: joining needs los.platform.wifi, which lives in
-- task/eth.lua and is granted to nothing else, and a program run from a
-- shell holds no right to that task. Reaching it would mean either
-- lending every program the whole nic or serving a control file from a
-- proc that exists to answer one write a month. Until a port can be
-- activated on demand, this saves and says so.
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
local CONF = "/etc/wifi.lua"

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

-- one line from the terminal, a byte at a time: the console hands over
-- what has been typed, and a read of 256 would wait for 256 bytes or a
-- close, neither of which anyone types.
local function readline()
	local acc = {}

	while true do
		local c = unistd.read(0, 1)

		if c == nil or c == "" then
			return #acc > 0 and table.concat(acc) or nil
		end
		if c == "\n" or c == "\r" then
			return table.concat(acc)
		end
		acc[#acc + 1] = c
	end
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

local args = {}

for _, a in ipairs(arg) do
	if a == "-s" then
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

out(("saved %s\njoins %s at next boot\n"):format(CONF, ssid))
