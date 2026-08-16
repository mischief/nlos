#!/usr/bin/env lua5.4
-- lib/bitchat/fragment.lua: a packet cut up, and put back together.
--
-- The layout is what the swift planner writes and the c implementation
-- reads: eight bytes of id, index and total big-endian, the original
-- type, then a slice of the whole encoded packet.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" ..
    scriptdir .. "/../lib/?/init.lua;" .. package.path

local fragment = require("bitchat.fragment")

local count, failed = 0, 0

local function ok(cond, name)
	count = count + 1
	if cond then
		io.write(("ok %d - %s\n"):format(count, name))
	else
		failed = failed + 1
		io.write(("not ok %d - %s\n"):format(count, name))
	end
	io.flush()
end

local ME, THEM = "SENDER01", "SENDER02"
local ID = "IDIDIDID"
local clock = 0

local function newasm()
	clock = 0
	return fragment.new({ now = function() return clock end })
end

-- ---- the layout ----

local frame = ("abcdefghij"):rep(30)		-- 300 bytes
local parts = fragment.split(frame, 0x02, 100, ID)

ok(#parts == 3, "three parts at a hundred bytes each")
ok(parts[1]:sub(1, 8) == ID, "the id comes first")

local index, total, ptype = string.unpack(">I2I2B", parts[2], 9)

ok(index == 1, "the index is where it sits, from zero")
ok(total == 3, "beside how many there are")
ok(ptype == 0x02, "and what the whole thing was")
ok(#parts[1] == fragment.HEADER + 100, "a part is the header and a slice")

-- ---- there and back ----

local A = newasm()

ok(A:feed(ME, parts[1]) == nil, "one part is not a packet")
ok(A:feed(ME, parts[2]) == nil, "nor two")

local got, kind = A:feed(ME, parts[3])

ok(got == frame, "the third puts it back exactly")
ok(kind == 0x02, "with the type it had")

-- a frame that divides evenly must not gain an empty part.
local even = ("x"):rep(200)
local ep = fragment.split(even, 0x01, 100, ID)

ok(#ep == 2, "an exact fit is not one part longer")

A = newasm()
A:feed(ME, ep[1])
ok(A:feed(ME, ep[2]) == even, "and comes back whole")

-- one part is still a set.
local small = fragment.split("hi", 0x01, 100, ID)

ok(#small == 1, "something small is one part")
ok(newasm():feed(ME, small[1]) == "hi", "which arrives on its own")

-- ---- what a mesh does to them ----

A = newasm()
A:feed(ME, parts[3])
A:feed(ME, parts[1])
ok(A:feed(ME, parts[2]) == frame, "parts arriving out of order")

A = newasm()
A:feed(ME, parts[1])
A:feed(ME, parts[1])
A:feed(ME, parts[2])
ok(A:feed(ME, parts[3]) == frame, "and a part arriving twice")

-- two peers sending sets that happen to share an id are two sets.
A = newasm()
local other = fragment.split(("z"):rep(300), 0x02, 100, ID)

A:feed(ME, parts[1])
A:feed(THEM, other[1])
A:feed(THEM, other[2])
ok(A:feed(THEM, other[3]) == ("z"):rep(300), "one sender completes")
A:feed(ME, parts[2])
ok(A:feed(ME, parts[3]) == frame, "and the other is undisturbed")

-- ---- what is refused ----

A = newasm()
ok(A:feed(ME, "short") == nil, "a runt fragment")
ok(A:feed(ME, ID .. string.pack(">I2I2B", 0, 0, 1)) == nil,
    "a set of no parts")
ok(A:feed(ME, ID .. string.pack(">I2I2B", 5, 3, 1)) == nil,
    "a part past the end of its set")
ok(fragment.split(("x"):rep(100000), 1, 64, ID) == nil,
    "more parts than a reader will hold")

-- ---- what is not kept ----

A = newasm()
A:feed(ME, parts[1])
clock = fragment.MAXAGE + 1
A:feed(ME, parts[2])		-- starts a new set, the old one aged out
ok(A:feed(ME, parts[3]) == nil,
    "a set nobody finished is dropped rather than kept")

-- a peer that starts sets and never finishes them cannot fill this.
A = newasm()
for i = 1, fragment.SLOTS + 3 do
	A:feed(ME, ("i%d"):format(i) .. "IDID" ..
	    string.pack(">I2I2B", 0, 3, 1) .. "x")
end

local n = 0

for _ in pairs(A.sets) do
	n = n + 1
end
ok(n <= fragment.SLOTS, "the half-built sets are bounded")

-- ---- a real packet, through the whole path ----
--
-- What is cut up is the encoded packet, so the signature travels with
-- it and the far side verifies what was signed rather than a copy.
local packet = require("bitchat.packet")

local long = ("the mesh relays what it cannot read. "):rep(8)
local orig = packet.encode({ type = packet.MESSAGE, ttl = 7,
    timestamp = 1234, sender = ME, payload = long,
    signature = ("s"):rep(64) })

ok(#orig > 182, "a message long enough to need cutting")

local A2 = newasm()
local pieces = fragment.split(orig, packet.MESSAGE, fragment.cut(182),
    "FRAGIDXX")
local rebuilt

for _, body in ipairs(pieces) do
	-- as it goes on the wire: a fragment packet carrying the piece.
	local wire = packet.encode({ type = packet.FRAGMENT, ttl = 7,
	    timestamp = 1234, sender = ME, payload = body })
	local f = packet.decode(wire)

	rebuilt = A2:feed(f.sender, f.payload) or rebuilt
end

ok(rebuilt == orig, "the packet comes back byte for byte")

local back = packet.decode(rebuilt)

ok(back.payload == long, "with its text")
ok(back.signature == ("s"):rep(64), "and its signature")
ok(back.timestamp == 1234, "and the time it was sent")

io.write("1.." .. count .. "\n")
os.exit(failed == 0 and 0 or 1)
