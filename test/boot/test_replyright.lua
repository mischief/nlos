-- a reply right is send-only.
--
-- {__right=} copies the recv flag, so a port published as created hands
-- the far end the ability to RECEIVE on it. For a reply port that is
-- the whole request/reply protocol turned inside out: a server can take
-- the answer meant for its client, or take its own request's reply slot
-- and never answer. thread.replyport() therefore hands out two handles,
-- the port to wait on and a send right to publish.
--
-- The kernel has no "may not receive" error to assert on -- api_send
-- ignores the flag and recv is refused by right_get's caller -- so the
-- test is behavioural: a server that tries to receive on the right it
-- was given must not get the client's reply.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(6)

-- ---- 1. what replyport hands out ----

local rp, sr = thread.replyport()

tap.ok(rp ~= nil and sr ~= nil, "replyport returns a port and a right")
tap.ok(rp ~= sr, "which are different handles")

-- the receive handle works as one; the send right does not. tryrecv is
-- the check: it raises on a right that cannot receive, and answers
-- (empty) on one that can.
tap.ok(not pcall(sys.tryrecv, sr), "the published right cannot receive")
tap.ok(pcall(sys.tryrecv, rp), "the retained handle can")

-- ---- 2. a greedy server cannot take its client's reply ----
--
-- GREEDY answers, then tries to receive on the same right. If that
-- right could receive, it would take the reply back off the port before
-- the client ever woke, and the recv below would hang.

local GREEDY = [[
local sys = require("los.sys")
local thread = require("los.thread")
local m = thread.recv(sys.SELF)
local r = m.reply.__right

sys.send(r, "answer")
-- try to take it back. must fail: this is a send right.
local ok = pcall(sys.tryrecv, r)

sys.send(r, { stole = ok })
]]

local _, gh = sys.spawn(GREEDY, { name = "greedy" })

sys.send(gh, { reply = { __right = sr } })

local first = thread.recv(rp)
local second = thread.recv(rp)

tap.is(first, "answer", "the client got its reply")
tap.is(second.stole, false, "and the server could not take it back")

sys.close(gh)
tap.done()
