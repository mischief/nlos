-- fetch: an HTTP GET.
--
--   > fetch http://192.168.0.12/
--   > fetch -i https://example.com/      (with the status and headers)
--   > fetch -k https://self-signed/       (without checking the key)
--   > fetch http://192.168.0.12/big | p
--
-- The protocol is lib/http.lua, which owns no capability and rides
-- whichever the caller holds. This program holds the tcp task, lent by
-- the shell the same way the screen is -- so a shell that was given no
-- network hands out none, and fetch says so rather than failing oddly.
--
-- A name needs a resolver and there is none yet: nothing starts
-- task/dns.lua, so a dotted quad works and a hostname is refused with
-- the reason. lib/http.lua already takes nil for the resolver, since
-- resolving "1.2.3.4" would only fail.
--
-- The body goes to stdout and nothing else does, so `fetch ... | p` and
-- `fetch ... > file` behave. Diagnostics go to stderr.

local prog = require("prog")
local http = require("http")
local getopt = require("getopt")

local function die(s)
	io.stderr:write("fetch: " .. s .. "\n")
	os.exit(1)
end

local flags, optind = getopt.parse(arg, "ik")

if not flags or not arg[optind] then
	io.stderr:write("usage: fetch [-ik] url\n")
	os.exit(2)
end

local showhead, insecure = flags.i, flags.k
local url = arg[optind]

-- a bare host is a url with the scheme left off, which is what anyone
-- types first
if not url:match("^%a+://") then
	url = "http://" .. url
end

local net = prog.net()

if not net then
	die("no network capability: this shell was lent none")
end

-- https trusts on first use: no clock this machine believes and no root
-- store, so a validity window is not something it can check. Nothing
-- persists the key yet, so "first use" is every run and -k skips even
-- that.
local opts = {
	rand = prog.rand(),
	insecure = insecure,
	verify = not insecure and require("tlstcp").tofu(
	    url:match("^https://([^:/]+)") or "",
	    function(h, fp)
		io.stderr:write(("fetch: %s is %s\n"):format(h, fp))
	    end) or nil,
}
if url:match("^https://") and not opts.rand then
	die("no entropy: this shell was lent no seed, and tls needs one")
end

-- the body goes out as it arrives rather than being held whole: a
-- track is megabytes and this machine has no room to keep one. The
-- headers cannot be printed from in here, so they are printed after --
-- which is where they belong anyway, ahead of nothing.
if showhead then
	opts.onhead = function(status, headers)
		io.write(("HTTP %s\n"):format(tostring(status)))
		for k, v in pairs(headers or {}) do
			io.write(("%s: %s\n"):format(k, v))
		end
		io.write("\n")
	end
end

opts.sink = function(part)
	io.write(part)
	return true
end

local res, err = http.get(net, prog.dns(), url, opts)

if not res then
	die(tostring(err))
end

-- a request that reached the server and was refused by it is not this
-- program's failure, but it is not a success either: the status is the
-- answer, and a script wants to know without parsing the body.
if type(res.status) == "number" and res.status >= 400 then
	os.exit(1)
end
