-- keygen: an ssh-ed25519 key of this machine's own.
--
--	keygen                    -> /config/id_ed25519 and .pub
--	keygen -f /sd/mykey       somewhere else
--	keygen -y -f FILE         print the public line of a key you have

-- /config by default because it is a flash partition of its own: a key
-- there survives reflashing the filesystem, which is where wifi's
-- credentials already live for the same reason.

local unistd = require("posix.unistd")
local prog = require("prog")
local keys = require("ssh.keys")
local ed25519 = require("crypto.ed25519")

local function die(s)
	unistd.write(2, "keygen: " .. s .. "\n")
	os.exit(1)
end

local path, pubonly = "/config/id_ed25519", false
local i = 1

while arg[i] and arg[i]:sub(1, 1) == "-" and #arg[i] > 1 do
	local o = arg[i]

	i = i + 1
	if o == "-f" then
		path = arg[i] or die("-f wants a path")
		i = i + 1
	elseif o == "-y" then
		pubonly = true
	else
		unistd.write(2, "usage: keygen [-y] [-f path] [comment]\n")
		os.exit(2)
	end
end

local comment = arg[i] or "lua-os"
local N = prog.ns() or die("no namespace")

local function slurp(p)
	return N:readfile(p)
end

-- writefile, not open: open finds a file, and this one is not there
-- yet. It creates, and falls back to a truncating open where it is.
local function spit(p, s)
	local ok, err = N:writefile(p, s)

	if not ok then
		die(p .. ": " .. tostring(err))
	end
end

if pubonly then
	local text = slurp(path) or die(path .. ": cannot read")
	local seed, pk = keys.parse_private(text)

	if not seed then
		die(path .. ": " .. tostring(pk))
	end
	io.write(keys.public_line(pk, comment))
	os.exit(0)
end

-- Refused rather than overwritten: a key file is the one thing here
-- whose loss cannot be undone by running the command again.
if slurp(path) then
	die(path .. " exists; move it first, or -f somewhere else")
end

local rand = prog.rand() or die("no entropy: this shell was given no seed")
local seed = rand(32)
local pk = ed25519.publickey(seed)

spit(path, keys.write_private(seed, pk, comment, rand))
spit(path .. ".pub", keys.public_line(pk, comment))

io.write(path .. "\n")
io.write(keys.fingerprint(keys.blob(pk)) .. "\n")
io.write(keys.public_line(pk, comment))
