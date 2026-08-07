-- sys.spawn's `arg`: one value delivered BEFORE the child's chunk runs.
--
-- the thing a message cannot do. a child's first line is typically
-- require(...), which happens before any recv, so anything the child
-- needs in order to load code at all has to be there already. that is
-- what fork hands plan 9 for free and what spawn could not express.
--
-- it is the ordinary serializer, so rights travel exactly as they do in
-- a message -- which is the whole point, since a namespace containing a
-- mount IS a right.

local sys = require("los.sys")
local thread = require("los.thread")
local tap = require("tap")

tap.plan(12)

-- ---- it arrives as the chunk's `...`, at the very first line ----

local rp = sys.newport("test_spawnarg.r")

sys.spawn([[
	-- line one. no recv has happened and none can have.
	local a = ...
	local sys = require("los.sys")

	sys.send(a.reply.__right, {
		got = a.greeting,
		n = a.number,
		nested = a.deep and a.deep.inner,
		kind = type(a),
	})
]], {
	name = "argchild",
	arg = {
		greeting = "hello from the parent",
		number = 42,
		deep = { inner = "nested value" },
		reply = { __right = rp },
	},
})

local m = thread.recvtimeout(rp, 5000)

tap.ok(m ~= nil, "the child answered using only its spawn arg")
tap.is(m and m.kind, "table", "arg arrived as a table")
tap.is(m and m.got, "hello from the parent", "strings survive")
tap.is(m and m.n, 42, "numbers survive")
tap.is(m and m.nested, "nested value", "nested tables survive")

-- ---- a right inside the arg is a working capability ----
--
-- the child never received a message before using it, so the right came
-- in through spawn itself.

local back = sys.newport("test_spawnarg.b")
local pid2, h2 = sys.spawn([[
	local a = ...
	local sys = require("los.sys")
	local thread = require("los.thread")

	-- prove the granted right works by using it, then wait so the
	-- parent can check we are still alive
	sys.send(a.out.__right, { note = "sent through a spawn-granted right" })
	thread.recv(sys.SELF)
]], { name = "rightchild", arg = { out = { __right = back } } })

local m2 = thread.recvtimeout(back, 5000)

tap.ok(m2 ~= nil and m2.note == "sent through a spawn-granted right",
    "a right delivered by spawn is usable: " .. tostring(m2 and m2.note))

-- the parent's own right is untouched: rights are copied, not moved
tap.ok(sys.send(back, { note = "still ours" }),
    "the parent still holds its own right")
tap.ok(thread.recvtimeout(back, 1000) ~= nil, "and it still works")

sys.monitor(pid2)
sys.send(h2, { done = true })
sys.close(h2)

-- wait for it to actually be gone before the accounting block samples a
-- baseline. a proc dying in the background frees its self port whenever
-- it gets around to it, and the first version of that block read its
-- baseline mid-death and saw the count go DOWN by one.
local d2 = sys.uptime_ms() + 3000

while sys.uptime_ms() < d2 do
	local rok, rm = sys.tryrecv(sys.SELF)

	if rok and rm and rm.exit == pid2 then
		break
	end
	sys.yield()
end

-- ---- no arg is still legal, and the chunk sees no varargs ----
--
-- every existing proc in the tree is spawned this way, so this is the
-- compatibility case: the extra resume argument must be absent, not nil
-- padding.

local n2 = sys.newport("test_spawnarg.n")
local _, nh = sys.spawn([[
	local a = ...
	local sys = require("los.sys")
	local thread = require("los.thread")
	local m = thread.recv(sys.SELF)

	sys.send(m.reply.__right, { none = (a == nil) })
]], { name = "noarg2" })

sys.send(nh, { reply = { __right = n2 } })

local m3 = thread.recvtimeout(n2, 5000)

tap.ok(m3 ~= nil and m3.none == true,
    "a spawn without arg gives the chunk no varargs")

-- ---- the reference accounting balances ----
--
-- serialize takes an in-flight ref, right_new takes the child's, and the
-- in-flight one has to be released -- exactly as a delivered message
-- releases its refs once received. get that wrong in either direction
-- and it is a silent leak or a premature free, so count ports across
-- enough rounds to show drift.

-- measured across TWO equal batches rather than against a baseline
-- taken once. a one-off settling -- a cancelled timer slot reaped
-- lazily, a proc finishing its death -- moves an absolute baseline by a
-- port or two and says nothing about whether each round leaks. two
-- batches cancel that: a per-round leak shows up as a difference
-- between them, and anything one-time lands entirely in the first.

local function batch(n, tag)
	for i = 1, n do
		local p = sys.newport("test_spawnarg")
		local pid, ch = sys.spawn([[
			local a = ...
			require("los.sys").send(a.out.__right, { i = a.i })
		]], { name = tag .. i,
		    arg = { out = { __right = p }, i = i } })

		sys.monitor(pid)
		sys.close(ch)

		local got = thread.recvtimeout(p, 5000)
		local deadline = sys.uptime_ms() + 3000

		while got and sys.uptime_ms() < deadline do
			local rok, rm = sys.tryrecv(sys.SELF)

			if rok and rm and rm.exit == pid then
				break
			end
			sys.yield()
		end
		sys.close(p)
	end
	for _ = 1, 5 do
		sys.yield()
	end
	return sys.stats().ports
end

local first = batch(15, "acctA")
local second = batch(15, "acctB")

tap.is(second, first,
    "15 more spawn-with-right rounds cost no further ports (" .. first ..
    " -> " .. second .. ")")

-- ---- an unserializable arg fails the spawn loudly ----

local ok, err = pcall(sys.spawn, "return", { arg = { f = print } })

tap.ok(not ok, "a function in the arg is refused")
tap.ok(tostring(err):find("unserializable") ~= nil,
    "and says so: " .. tostring(err))

tap.done()
