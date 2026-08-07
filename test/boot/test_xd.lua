-- xd, on bytes whose dump is known exactly.
--
-- Driven through the shell rather than by requiring anything: xd reads
-- a pipe, a redirect and a file, and which one it got is the part worth
-- covering. The console is a passive drain -- xd asks a terminal for
-- nothing.
local sys = require("los.sys")
local dos = require("dos")
local ns = require("ns")
local tap = require("tap")

local caps_of = sys.granted()

tap.plan(9)

local N = ns.new()

N:mount("/", require("mnt").new(caps_of.esp), "mnt",
    { port = { __right = caps_of.esp } })

local function collector()
	local port = sys.newport()
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
local sh = dos.new({ ns = N, cons = cons })

-- ---- a pipeline ----
--
-- seq 3 is "1\n2\n3\n": six bytes, one short line, and every byte both
-- printable and not (the digits and the newlines), which is what the
-- text column has to get right.
tap.is(dos.once(sh, "seq 3 | xd"), 0, "seq 3 | xd ran")

local out = drain()

tap.ok(out:find("31 0a 32 0a 33 0a", 1, true), "the bytes are the digits")
tap.ok(out:find("|1.2.3.|", 1, true),
    "and the text column shows the unprintable ones as dots")
tap.ok(out:find("^00000000  "), "the line is numbered from zero")
tap.ok(out:find("00000006\n$"), "and the length is the last word")

-- ---- a file, and -n ----

dos.once(sh, "xd -n 16 /bin/xd.lua")
out = drain()

local lines = 0

for _ in out:gmatch("[^\n]+") do
	lines = lines + 1
end
tap.is(lines, 2, "-n 16 is one line of sixteen, plus the length")
tap.ok(out:find("00000010\n$"), "which ends at sixteen")

-- ---- a run of one byte folds ----
--
-- 48 zero bytes is three identical lines. od prints a star for the
-- middle of a run and so does this: the fact is that the block is
-- empty, not that it is empty three times.
--
-- The file goes on the ESP, which the harness boots under -snapshot --
-- so the write never reaches the image other tests are sharing.
assert(N:writefile("/zeros.bin", string.rep("\0", 48)))

dos.once(sh, "xd /zeros.bin")
out = drain()

tap.ok(out:find("\n*\n", 1, true), "a repeated line folds to a star")
tap.ok(out:find("00000030\n$"),
    "and the folded bytes are still counted")

tap.done()
