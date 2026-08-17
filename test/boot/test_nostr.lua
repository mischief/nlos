-- NIP-01 events, against one taken off the network.
--
-- The id is a hash of exact bytes, so this is really a test of the
-- serialization: any disagreement about escaping, key order or how a
-- number is rendered shows up as an id that does not match.

local nostr = require("nostr")
local sha1 = require("crypto.sha1")
local base64 = require("ssh.base64")
local tap = require("tap")

tap.plan(15)

local EV = {
	id = "4376c65d2f232afbe9b882a35baa4f6fe8667c4e684749af565f981833ed6a65",
	pubkey = "6e468422dfb74a5738702a8823b9b28168abab8655faacb6853cd0ee15deee93",
	created_at = 1673347337,
	kind = 1,
	tags = {
		{ "e",
		  "3da979448d9ba263864c4d6f14984c423a3838364ec255f03c7904b1ae77f206" },
		{ "p",
		  "bf2376e17ba4ec269d10fcc996a4746b451152be9031fa48e74553dde5526bce" },
	},
	content = "Walled gardens became prisons, and nostr is the first " ..
	    "step towards tearing down the prison walls.",
	sig = "908a15e46fb4d8675bab026fc230a0e3542bfade63da02d542fb78b2a8513" ..
	    "fcd0092619a2c8c1221e581946e0191f2af505dfdf8657a414dbca329186f009262",
}

tap.is(nostr.hex(nostr.id(EV)), EV.id, "the id of a published event recomputes")
tap.ok(nostr.verify(EV) == true, "and its signature verifies")

-- the half that matters: a verifier that accepts everything passes
-- every case above.
local tampered = {}

for k, v in pairs(EV) do
	tampered[k] = v
end
tampered.content = EV.content .. "!"
tap.ok(nostr.verify(tampered) ~= true, "an altered event is refused")

tampered.content = EV.content
tampered.sig = EV.sig:sub(1, 126) .. "00"
tap.ok(nostr.verify(tampered) ~= true, "an altered signature is refused")
tap.ok(nostr.verify({}) ~= true, "a table that is not an event is refused")

-- ---- our own ----
local sec = ("\43"):rep(32)
local mine = nostr.sign(sec, 1, "hello from lua-os", {}, 1755300000)

tap.ok(mine ~= nil and #mine.id == 64, "signs an event")
tap.ok(nostr.verify(mine) == true, "and verifies what it signed")
tap.ok(nostr.serialize(mine):find("[]", 1, true) ~= nil,
    "empty tags serialize as an array, not an object")

-- content that has to be escaped exactly, or the id moves
local tricky = nostr.sign(sec, 1, "a\"b\\c\nd\te\1f", {}, 1755300000)

tap.ok(nostr.verify(tricky) == true, "control characters survive the id")
tap.ok(nostr.serialize(tricky):find("\\u0001", 1, true) ~= nil,
    "and an unnamed control is \\u00xx")

-- ---- keys ----
tap.is(nostr.seckey(nostr.nsec(sec)), sec, "an nsec round trips")

-- genkey, against entropy this test chooses, so what it does with a bad
-- draw is checked rather than left to luck.
local draws = {}
local function feed(...)
	draws = { ... }
	local at = 0

	return function(n)
		at = at + 1
		return draws[at] or ("\1"):rep(n)
	end
end

local made = nostr.genkey(feed())

tap.ok(made ~= nil and #made == 32 and nostr.pubkey(made) ~= nil,
    "genkey makes a key the curve accepts")

-- zero and the order itself are the two scalars that are not keys, and
-- a generator that returned either would make an identity that cannot sign
local order = nostr.unhex(
    "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141")

tap.is(nostr.genkey(feed(("\0"):rep(32), order, ("\7"):rep(32))),
    ("\7"):rep(32), "and redraws past zero and past the order")

tap.ok(nostr.genkey(nil) == nil, "with no entropy it makes nothing")

-- ---- sha1, which the websocket handshake needs ----
tap.is(base64.encode(sha1.hash("dGhlIHNhbXBsZSBub25jZQ==" ..
    "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"), true),
    "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "rfc 6455's own accept key")

tap.done()
