-- netfs: this machine's network configuration, as files -- the same
-- /net task/dhcpd.lua serves where there is a lease to serve. The set
-- is addr, prefix, addr6, dns and domain.

-- There is no lease here: the host owns the address and lends its
-- sockets, so every value is read when the file is read. A laptop that
-- roams changes the answer and a boot snapshot would go quietly stale.

-- No gw, no mask, no lease time. Nothing here reaches a frame, so a
-- gateway is not something a proc could route through, and a file
-- saying otherwise is a promise this machine cannot keep. An absent
-- file reads as "this machine does not know", which is what
-- lib/resolv.lua and bin/settings.lua already expect.

local tcpc = require("client.tcp")
local dev = require("dev")

-- at file scope: `...` is the chunk's, and a task that waits until it is
-- inside thread.spawn has already lost it.
local init, cfg = require("svcarg")(...)
local tcp = tcpc.new(init.tcp.__right)

-- what the machine was told at boot, where it was told anything. The
-- resolver is the host's own; a machine started with -n was told a
-- different one and this is where that lands.
local resolver = cfg.resolver
local domain = cfg.domain

-- a well-known address in each family, used only to ask the host which
-- of its own addresses it would use to get there. Nothing is sent.
local V4PROBE = "192.0.2.1"		-- TEST-NET-1
local V6PROBE = "2001:db8::1"		-- the documentation prefix

local function localaddr(probe)
	local r = tcp.localaddr(probe)

	return r and r.addr, r and r.prefix
end

-- one value per file, computed on read. An empty string is a file that
-- exists and has nothing to say; nil is a file that is not there.
local files = {}

files.addr = function()
	return localaddr(V4PROBE)
end

files.prefix = function()
	local _, p = localaddr(V4PROBE)

	return p and tostring(p)
end

files.addr6 = function()
	return localaddr(V6PROBE)
end

files.dns = function()
	return resolver and (resolver .. "\n")
end

files.domain = function()
	return domain
end

-- which files exist right now: a machine with no ipv6 route has no
-- addr6, and saying so by absence is what lets a reader tell "none"
-- from "unknown".
local function present()
	local out = {}

	for name, get in pairs(files) do
		local ok, v = pcall(get)

		if ok and v then
			out[name] = tostring(v)
		end
	end
	return out
end

local function backend()
	local B = {}

	local function h_of(name)
		return { name = name }
	end

	function B.attach()
		return h_of(nil)
	end

	function B.walk(h, name)
		if h.name then
			dev.error(dev.Enotdir)
		end
		if name == ".." or name == "." then
			return h_of(nil)
		end
		if not present()[name] then
			dev.error(dev.Enonexist)
		end
		return h_of(name)
	end

	function B.stat(h)
		if not h.name then
			return { name = "/", dir = true, size = 0 }
		end
		-- the current length, which for a value read on demand is a
		-- hint rather than a promise; readers loop until "".
		return { name = h.name, dir = false,
		    size = #(present()[h.name] or "") }
	end

	function B.open(h, mode)
		if mode and mode ~= "r" then
			dev.error(dev.Eperm)
		end
		return dev.closable(B, h_of(h.name))
	end

	function B.clunk(_)
	end

	function B.read(h, off, n)
		if not h.name then
			dev.error(dev.Eisdir)
		end

		local v = present()[h.name] or ""

		if off >= #v then
			return ""
		end
		return v:sub(off + 1, off + n)
	end

	function B.write()
		-- the host's configuration is the host's. A machine that
		-- wants a different resolver is started with -n.
		dev.error(dev.Eperm)
	end

	function B.readdir(h)
		if h.name then
			dev.error(dev.Enotdir)
		end

		local out = {}

		for name, v in pairs(present()) do
			out[#out + 1] = { name = name, dir = false, size = #v }
		end
		table.sort(out, function(x, y) return x.name < y.name end)
		return out
	end

	function B.create()
		dev.error(dev.Eperm)
	end

	function B.remove()
		dev.error(dev.Eperm)
	end

	return B
end

require("srv").main(backend)
