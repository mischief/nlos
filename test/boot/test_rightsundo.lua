-- a message that cannot be received takes nothing with it.
--
-- deserialize mints rights into the receiver as it walks, so a message
-- that fails partway -- a full rights table, most easily -- has already
-- installed some. Those handle numbers were never pushed to Lua, so the
-- receiver cannot name them to sys.close and they are lost for the life
-- of the proc. The sender picks both the count and the timing, so it is
-- also how one client exhausts a server's rights table from outside:
-- MAXMSGRIGHTS is 32 and MAXRIGHTS 512, so a handful of refused
-- messages would do it.
--
-- The victim below cannot observe the leak directly -- there is no
-- handle to look at. What it can observe is whether the slots come
-- back: fill the table, free exactly two, refuse a message carrying
-- more than two rights, and then ask for two again.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(4)

local VICTIM = [[
local sys = require("los.sys")
local a = ...
local back = a.reply.__right

-- fill our own rights table. sendright on our own port is the cheapest
-- way to take a slot and needs nothing from outside.
local held = {}

while true do
	local ok, h = pcall(sys.sendright, sys.SELF)

	if not ok or not h then
		break
	end
	held[#held + 1] = h
end

-- free exactly two slots, so a message carrying more than two rights
-- must fail partway rather than before it starts
local freed = 2

for _ = 1, freed do
	sys.close(table.remove(held))
end

-- tell the parent we are ready, then take the message it sends
sys.send(back, { ready = true, held = #held })
sys.block(0)

local ok, err = pcall(sys.tryrecv, 0)

-- now the question: are the two slots still ours? if the refused
-- message kept what it minted, these fail.
local regained = 0

for _ = 1, freed do
	local got, h = pcall(sys.sendright, sys.SELF)

	if got and h then
		regained = regained + 1
	end
end

sys.send(back, { refused = not ok, err = tostring(err),
    regained = regained, want = freed })
]]

local back = sys.sendright(sys.SELF)
local vpid, vh = sys.spawn(VICTIM, { name = "victim",
    arg = { reply = { __right = back } } })

sys.close(back)

local m = thread.recv(sys.SELF)

tap.ok(m.ready == true, "the victim filled its rights table (" ..
    tostring(m.held) .. " held)")

-- four rights in one message, into two free slots
local payload = { a = { __right = vh }, b = { __right = vh },
    c = { __right = vh }, d = { __right = vh } }

tap.ok(sys.send(vh, payload), "a message carrying four rights was sent")

local r = thread.recv(sys.SELF)

tap.ok(r.refused == true, "the receive failed: " .. tostring(r.err))
tap.is(r.regained, r.want,
    "and gave back every right it had minted before failing")

sys.close(vh)
tap.done()
