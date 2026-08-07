-- host, over qemu's usermode network.
--
-- slirp answers dns at 10.0.2.3, so the resolution here is real: a
-- query goes out and an answer comes back. What it resolves is
-- localhost, whose answer is a constant everywhere -- a test that
-- asserted example.com's address would fail the day that address
-- changed, and would be measuring the internet rather than this
-- program.
--
-- The rest is the parts that need no server at all: a dotted quad, a
-- name with nobody to ask, and a shell that was lent no udp.
local sys = require("los.sys")
local dos = require("dos")
local ns = require("ns")
local tap = require("tap")

local caps_of = sys.granted()

tap.plan(8)

tap.ok(caps_of.ip ~= nil, "the boot payload holds the ip task")

local N = ns.new()

N:mount("/", require("mnt").new(caps_of.esp), "mnt",
    { port = { __right = caps_of.esp } })

local function collector()
	local port = sys.newport("test_host")
	local out = {}

	return sys.sendright(port), function()
		while true do
			local ok, m = sys.tryrecv(port)

			if not ok then
				local s = table.concat(out)

				for i = #out, 1, -1 do
					out[i] = nil
				end
				return s
			end
			if m and m.op == "write" then
				out[#out + 1] = m.data
			end
		end
	end
end

local cons, drain = collector()
local sh = dos.new({ ns = N, cons = cons, udp = caps_of.ip })

-- ---- a name, asked of a named server ----
--
-- The server is given rather than read from /net/dns: this shell's
-- namespace is one built here, and the lease filesystem belongs to the
-- one init built. Naming it is also the argument-handling path.
tap.is(dos.once(sh, "host localhost 10.0.2.3"), 0, "host ran")
tap.is(drain(), "127.0.0.1\n", "and resolved localhost")

-- ---- an address is not a question ----

tap.is(dos.once(sh, "host 1.2.3.4"), 0, "a dotted quad is accepted")
tap.is(drain(), "1.2.3.4\n", "and answered with itself, asking nobody")

-- ---- no resolver named, and none to find ----
--
-- /net is not in this namespace, so there is nothing to read and
-- nothing to guess. Saying so beats a query to an address made up here.
tap.is(dos.once(sh, "host example.com"), 1, "with no resolver, host fails")
tap.ok(drain():find("no resolver"), "and says that is what was missing")

-- ---- no capability ----

local cons2, drain2 = collector()
local blind = dos.new({ ns = N, cons = cons2 })

dos.once(blind, "host localhost 10.0.2.3")
tap.ok(drain2():find("no udp capability"),
    "a shell lent no udp hands out none")

tap.done()
