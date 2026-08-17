#!/usr/bin/env lua5.4
-- lib/zmodem.lua on the host: a sender and a receiver wired to each
-- other, with nothing between them that either can see.
--
-- The library is sans-io, so the line here is two string buffers and a
-- clock that is a number. That is what makes the interesting cases
-- reachable at all: a byte corrupted at a chosen offset, a peer that
-- stops answering, a cancel arriving mid-file. None of those can be
-- asked for from a real wire, and every one of them is a line here.
--
-- Two of our own machines agreeing proves consistency, not correctness
-- -- they share every misreading of Forsberg. What pins the encoding to
-- the spec instead is the check vectors below and the fact that the
-- frames are built from the constants in zmodem.h, byte for byte.
-- test/boot/test_zmodem.lua runs the same code over real ports.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/../lib/?.lua;" .. package.path

local zmodem = require("zmodem")

local count, failed = 0, 0

local function ok(cond, name)
	count = count + 1
	if cond then
		io.write(("ok %d - %s\n"):format(count, name))
	else
		failed = failed + 1
		io.write(("not ok %d - %s\n"):format(count, name))
	end
	return cond
end

local function diag(s)
	io.write("# " .. tostring(s) .. "\n")
end

io.write("1..23\n")

-- ---- deterministic filler ----
--
-- Every byte value appears, including the ones the escaper has to
-- rewrite (ZDLE, XON, XOFF and their high halves) and the ones a
-- careless decoder eats (0x7f, 0xff). A pure text payload would exercise
-- none of the escaping.
local function filler(n)
	local parts = {}
	local x = 0x12345

	for i = 1, (n + 4095) // 4096 do
		local b = {}

		for j = 1, 4096 do
			x = (x * 1103515245 + 12345) & 0x7fffffff
			b[j] = string.char((x >> 16) & 0xff)
		end
		parts[i] = table.concat(b)
	end
	return table.concat(parts):sub(1, n)
end

-- ---- the line ----
--
-- Both machines are stepped, their output handed to the other end, and
-- the clock only moves when neither has anything left to say -- which is
-- exactly the condition a real timeout describes. `mangle` sees every
-- byte going sender -> receiver.
local function pump(a, b, mangle)
	local now, steps = 0, 0

	while (a.state == "running" or b.state == "running") and
	    steps < 1000000 do
		steps = steps + 1

		a:run(now)

		local oa = a:pull()

		b:run(now)

		local ob = b:pull()

		if oa then
			b:feed(mangle and mangle(oa) or oa)
		end
		if ob then
			a:feed(ob)
		end
		if not oa and not ob then
			now = now + 1000
		end
	end
	return now, steps
end

-- ---- check vectors ----

ok(zmodem.crc16("123456789") == 0x31c3, "crc16 check vector")
ok(zmodem.crc32("123456789") == 0xcbf43926, "crc32 check vector")

-- ---- a transfer larger than any buffer involved ----

local SIZE = 512 * 1024
local data = filler(SIZE)

do
	local tx = zmodem.sender({ name = "big.bin", data = data })
	local rx = zmodem.receiver()

	pump(tx, rx)

	ok(tx.state == "done", "sender finished: " .. tostring(tx.err))
	if ok(rx.state == "done", "receiver finished: " .. tostring(rx.err)) then
		local f = rx.result[1]

		ok(f.name == "big.bin", "the name came across")
		ok(f.size == SIZE, "the size in ZFILE matched")
		ok(f.data == data, ("%d bytes arrived intact"):format(SIZE))
	else
		ok(false, "the name came across")
		ok(false, "the size in ZFILE matched")
		ok(false, "bytes arrived intact")
	end
end

-- ---- crc16 frames, which is a different subpacket tail width ----

do
	local small = data:sub(1, 40000)
	local tx = zmodem.sender({ name = "c16.bin", data = small },
	    { crc32 = false, blocksize = 1024 })
	local rx = zmodem.receiver({ crc32 = false })

	pump(tx, rx)
	ok(rx.state == "done" and rx.result[1].data == small,
	    "a crc16 transfer arrives intact too")
end

-- ---- several files in one session ----

do
	local files = {
		{ name = "one", data = "first" },
		{ name = "two", data = data:sub(1, 100000) },
		{ name = "three", data = "" },
	}
	local tx = zmodem.sender(files)
	local rx = zmodem.receiver()

	pump(tx, rx)

	local got = rx.result

	ok(rx.state == "done" and got and #got == 3 and
	    got[1].data == "first" and got[2].data == files[2].data and
	    got[3].data == "" and got[3].name == "three",
	    "three files in one session, including an empty one")
end

-- ---- a corrupted byte costs a frame, not the transfer ----
--
-- ZMODEM recovers by position: the receiver answers with the offset it
-- actually holds and the sender resumes the frame there. That path had
-- never run until this test broke a byte on purpose.
do
	local payload = data:sub(1, 200000)
	local tx = zmodem.sender({ name = "hurt.bin", data = payload },
	    { blocksize = 4096 })
	local rx = zmodem.receiver()
	local seen, hurt = 0, false

	local function mangle(s)
		seen = seen + #s
		if hurt or seen < 60000 then
			return s
		end
		hurt = true
		-- flip a bit well inside the buffer, where it lands in a
		-- data subpacket rather than in a header
		local i = #s // 2

		return s:sub(1, i - 1) ..
		    string.char(s:byte(i) ~ 0x01) .. s:sub(i + 1)
	end

	pump(tx, rx, mangle)

	ok(hurt, "the corruption was actually applied")
	if not ok(rx.state == "done" and rx.result[1].data == payload,
	    "a corrupted subpacket is recovered from") then
		diag("sender " .. tx.state .. " " .. tostring(tx.err))
		diag("receiver " .. rx.state .. " " .. tostring(rx.err))
	end
end

-- ---- a file that is never held whole at either end ----
--
-- The point of the reader/sink pair: a transfer larger than anything
-- the two ends are willing to keep. Nothing here concatenates the
-- payload, so the only thing that grows with the file is the offset.
do
	local BIG = 3 * 1024 * 1024

	local function gen(off, n)
		local b = {}

		for i = 1, n do
			b[i] = string.char(((off + i) * 37 + 11) & 0xff)
		end
		return table.concat(b)
	end

	-- every block is checked against what the reader would have
	-- produced at that offset, so the whole file is verified without
	-- either end ever holding more than one block of it.
	local got, bad = 0, nil
	local sink = function()
		return {
			write = function(off, s)
				if off ~= got then
					bad = bad or ("out of order at " .. off)
				elseif s ~= gen(off, #s) then
					bad = bad or ("wrong bytes at " .. off)
				end
				got = got + #s
			end,
		}
	end

	local tx = zmodem.sender({ name = "huge.bin", size = BIG, read = gen },
	    { blocksize = 8192 })
	local rx = zmodem.receiver({ sink = sink })

	pump(tx, rx)

	ok(tx.state == "done" and rx.state == "done",
	    ("%d bytes streamed with no buffer at either end"):format(BIG))
	ok(got == BIG, ("the sink saw every byte: %d"):format(got))
	if not ok(bad == nil, "and every block was the right bytes at the right offset") then
		diag(bad)
	end
end

-- ---- a cancel is obeyed ----

do
	local rx = zmodem.receiver({ timeout = 100, retries = 2 })

	rx:feed(zmodem.abort())
	rx:run(0)
	ok(rx.state == "error" and rx.err == "cancelled",
	    "eight CANs cancel a receiver")
end

-- ---- a peer that never answers gives up rather than hanging ----

do
	local tx = zmodem.sender({ name = "x", data = "y" },
	    { timeout = 1000, retries = 3 })
	local now = 0

	while tx.state == "running" and now < 600000 do
		tx:run(now)
		tx:pull()
		now = now + 1000
	end
	ok(tx.state == "error" and tx.err == "no receiver",
	    "a sender with no receiver stops trying")
end

-- ---- escaping is what the receiver asked for ----
--
-- Control characters are escaped until the peer's ZRINIT says whether
-- it needs that. A body of NULs is the case that shows it: every byte
-- doubles under ESCCTL and none of them has to.

local function wire(rxopts)
	local body = string.rep("\0", 8192)
	local tx = zmodem.sender({ name = "nul.bin", data = body })
	local rx = zmodem.receiver(rxopts)
	local sent = 0
	local now, steps = 0, 0

	while (tx.state == "running" or rx.state == "running") and
	    steps < 1000000 do
		steps = steps + 1
		tx:run(now)

		local oa = tx:pull()

		rx:run(now)

		local ob = rx:pull()

		if oa then
			sent = sent + #oa
			rx:feed(oa)
		end
		if ob then
			tx:feed(ob)
		end
		if not oa and not ob then
			now = now + 1000
		end
	end
	return sent, tx, rx, body
end

do
	local loud, txl, rxl, body = wire(nil)
	local quiet, txq, rxq = wire({ escctl = false })

	ok(txl.state == "done" and rxl.state == "done",
	    "a receiver asking for escctl gets its transfer")
	ok(txq.state == "done" and rxq.state == "done",
	    "and so does one that does not ask")
	ok(rxl.result[1].data == body and rxq.result[1].data == body,
	    "both deliver the same bytes")

	ok(txl.escall, "the sender escapes everything when asked")
	ok(not txq.escall, "and stops once the peer says it need not")
	ok(quiet < loud // 2 + 2048,
	    ("a body of nuls costs %d bytes rather than %d"):format(quiet,
	    loud))

	-- escctl = true is a caller overriding the peer, which a line that
	-- is known to eat control characters needs.
	local forced = zmodem.sender({ name = "x", data = "y" },
	    { escctl = true })

	forced.escall = false
	ok(forced.escforce, "a sender told to escape says so whatever the peer asks")
end

os.exit(failed > 0 and 1 or 0)
