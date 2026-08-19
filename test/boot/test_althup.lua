-- sys.alt(set, sends, wanthup): a wait that reports a hangup itself.
--
-- Asked as a second syscall, "is there a message" and "is anyone left"
-- have a gap between them, and a server can answer and close in it --
-- the caller then reports a hangup with the reply sitting in the port.
-- Answered inside the take, there is no gap to lose it in.

local sys = require("los.sys")
local tap = require("tap")

tap.plan(9)

-- ---- what it does with a message ----

local p = sys.newport("althup.p")
local s = sys.sendright(p)

sys.send(p, "first")

local i, m = sys.alt({ p }, nil, true)

tap.is(i, 1, "a message still comes back as index and value")
tap.is(m, "first", "with the message")

-- ---- a message that is nil ----
--
-- why the reason is what a caller tests rather than the message: nil is
-- a value a sender may send, so it cannot mean "nothing".

sys.send(p, nil)

local i2, m2, why2 = sys.alt({ p }, nil, true)

tap.is(i2, 1, "a nil message is a message")
tap.is(m2, nil, "and arrives as nil")
tap.is(why2, nil, "with no reason, which is how it differs from a hangup")

-- ---- the hangup ----

sys.close(s)

local i3, m3, why3 = sys.alt({ p }, nil, true)

tap.is(i3, 1, "the index names the port that ended")
tap.is(m3, nil, "with no message")
tap.is(why3, "hungup", "and the reason says so")

-- ---- a queued message outranks it ----
--
-- The port is hung up from here on, and this asks for the case the
-- reordering exists for: something arrived before the sender left, so
-- it is delivered rather than reported as an end.

local q = sys.newport("althup.q")
local qs = sys.sendright(q)

sys.send(q, "last words")
sys.close(qs)

local i4, m4 = sys.alt({ q }, nil, true)

tap.is(m4, "last words",
    "a message queued before the hangup is delivered first")
