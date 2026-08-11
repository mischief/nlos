-- draw: the screen, as a client of task/fb.lua.
--
-- Plan 9's split, under plan 9's names: lib/memdraw.lua is the pixel
-- arithmetic with no device behind it, and this is the half that
-- reaches one. A caller draws into memdraw Images and hands them here.

local sys = require("los.sys")
local thread = require("los.thread")
local buf = require("los.buf")
local rpc = require("client.rpc")

local requester = rpc.requester
local sendwait = rpc.sendwait

local M = {}

function M.new(handle, chunk)
	local f = { handle = handle }	-- for re-granting to a spawned child: {__right = f.handle}

	-- pixels are where a dropped message bites first: MAXQUEUE is
	-- 64KiB, the same as MAXMSG, so at most one band of a banded load
	-- is ever in flight. A 320x320 smiley went out as seven bands, six
	-- of which vanished, and what came back was a tidy yellow arc -- a
	-- picture wrong in a way no readback assertion catches, since every
	-- pixel that did arrive was correct. sendwait above is why that
	-- cannot happen here or in requester(); see its comment.
	local function put(m)
		return sendwait(handle, m)
	end

	-- one reply port per call, for the reason requester() gives above.
	local function ask(m)
		local replyport = sys.newport("client.replyport")
		-- send only: {__right=} copies the recv flag, so publishing
		-- the port as created would let the server receive on it
		local sr = sys.sendright(replyport)

		m.reply = { __right = sr }

		local ok, why = put(m)

		if not ok then
			sys.close(sr)
			sys.close(replyport)
			return nil, why
		end

		local r = thread.recv(replyport)

		sys.close(sr)
		sys.close(replyport)
		if r.err then
			return nil, r.err
		end
		return r.ok
	end

	-- no reply port, so we do not pay a round trip per rectangle -- but
	-- still put(), so a full queue waits rather than losing the
	-- message. errors are deferred, not lost: the next call that does
	-- wait reports its own failure, and sync() exists to ask on
	-- purpose.
	local function tell(m, wait)
		if wait then
			return ask(m)
		end
		return put(m)
	end

	function f.mode()
		return ask({ op = "mode" })
	end
	function f.modes()
		return ask({ op = "modes" })
	end
	function f.setmode(n)
		return ask({ op = "setmode", n = n })
	end
	function f.fill(r, color, wait, id)
		return tell({ op = "fill", r = r, color = color, id = id },
		    wait)
	end

	-- ---- images the server keeps ----

	-- the same screen, with an image space nobody else can name: ids
	-- are small integers, so without this a client reaches another's
	-- image by guessing one. The images go when this client's right
	-- is dropped, so a program that dies stops costing the server.
	-- win, an id of ours, makes the new session a window on that image:
	-- its client draws into it and cannot name the glass. Sending the
	-- right is the whole grant, and dropping ours revokes it.
	function f.session(win)
		local r, err = ask({ op = "session", win = win })

		if not r then
			return nil, err
		end
		return M.new(r.port.__right, chunk)
	end

	-- where a window image sits on the glass, and whether it is on it.
	function f.place(id, at, on, wait)
		return tell({ op = "place", id = id, at = at, on = on }, wait)
	end

	-- alloc answers an id. The pixels never leave the server, so a
	-- picture built from parts crosses this port once and a frame
	-- made of it costs a message rather than its own size.
	function f.alloc(w, h, fmt, color)
		return ask({ op = "alloc", w = w, h = h, fmt = fmt,
		    color = color })
	end
	function f.free(id, wait)
		return tell({ op = "free", id = id }, wait)
	end
	-- src into dst at p; dst nil is the screen. r is the part of src
	-- to take, and defaults to all of it.
	function f.draw(dst, src, r, p, wait)
		return tell({ op = "draw", dst = dst, src = src, r = r,
		    p = p }, wait)
	end
	function f.line(id, p0, p1, thick, color, wait)
		return tell({ op = "line", id = id, p0 = p0, p1 = p1,
		    thick = thick, color = color }, wait)
	end
	-- pixels are the one thing here big enough to hit the serializer's
	-- ceiling: sys.MAXMSG is 64KiB, which is 16384 pixels, which is a
	-- 128x128 tile. a screen is two orders of magnitude past that, so
	-- "load the whole screen in one call" is not a thing that can
	-- exist, and pretending otherwise just moves the failure to
	-- whichever caller first draws something large.
	--
	-- so split, here, once, into bands of whole rows -- and split a row
	-- horizontally if even one will not fit.
	--
	-- this is plan 9's answer to the same problem, arrived at the same
	-- way. libdraw's loadimage takes `chunk = display->bufsize - 64`,
	-- sends `dy = chunk/bpl` whole rows at a time, and when dy comes
	-- out zero splits the row and recurses on the remainder;
	-- unloadimage is the mirror of it. their bufsize is `iounit(datafd)`
	-- -- asked for, not assumed, which is why sys.MAXMSG is reported to
	-- lua rather than being a constant every caller copies. the 64 (our
	-- 512) is room for the header the payload travels inside; splitting
	-- to exactly the limit fails on the message around the pixels.
	--
	-- this is also the honest argument for keeping pixels behind a port
	-- rather than reaching for shared memory: the copy is real, and the
	-- design that survives it is the one that only ever ships the
	-- rectangle that changed. plan 9 pays it too, down a 9P pipe.
	local CHUNK = chunk or (sys.MAXMSG - 512)

	-- one band of a payload, as bytes this can give away. Copied out
	-- once and handed over, rather than copied into the message and
	-- out of it again as a string.
	local function piece(data, from, to)
		local b = buf.new(to - from + 1)

		b:copy(1, data, from, to)
		return b
	end

	-- what a band travels as. Anything piece() made is ours alone, so
	-- this hands it over; a caller's own bytes passed straight through
	-- are not ours to give, and travel as bytes.
	local function given(b)
		if buf.is(b) and b:movable() then
			return { __buf = b }
		end
		return b
	end

	-- from the name, not from how many bytes arrived: a short buffer
	-- is what the server must catch, and dividing to find the pixel
	-- width would make it a format of zero bytes instead. memdraw
	-- defines these names; the map is here so draw need not require it.
	local BPP = { bgrx = 4, ["r5g6b5"] = 2 }

	local function pixwidth(fmt)
		return BPP[fmt or "bgrx"]
	end

	-- fmt still travels: two bytes could be more than one format, and
	-- the server cannot tell by looking.
	local function loadband(r, data, wait, fmt, bpp, id)
		local stride = r.w * bpp
		local perband = stride > 0 and (CHUNK // stride) or 0

		-- the whole payload in one message. What the caller handed
		-- us is the caller's, so it travels as bytes rather than
		-- being taken away.
		if perband >= r.h then
			return tell({ op = "load", r = r, data = data,
			    fmt = fmt, id = id }, wait)
		end

		-- not even one row fits, so split the ROW and recurse on what
		-- is left of it -- plan 9's loadimage does exactly this, and
		-- it is the case a first draft gets wrong by returning an
		-- error and telling the caller to draw narrower. a screen
		-- wider than a message is not the caller's mistake.
		--
		-- their `& ~7` on the split point is pixel alignment for
		-- sub-byte depths; every pixel here is four whole bytes, so
		-- there is nothing to align.
		if perband < 1 then
			local half = CHUNK // bpp

			if half < 1 then
				return nil, "message limit below one pixel"
			end
			for y = 0, r.h - 1 do
				local row = piece(data, y * stride + 1,
				    (y + 1) * stride)
				local x = 0

				while x < r.w do
					local n = r.w - x

					if n > half then
						n = half
					end
					local last = wait and
					    y == r.h - 1 and x + n >= r.w
					local ok, err = tell({ op = "load",
					    r = { x = r.x + x, y = r.y + y,
					        w = n, h = 1 },
					    fmt = fmt, id = id,
					    data = given(piece(row, x * bpp + 1,
					        (x + n) * bpp)) }, last)

					if not ok then
						return nil, err
					end
					x = x + n
				end
			end
			return true
		end

		local y = 0

		while y < r.h do
			local n = r.h - y

			if n > perband then
				n = perband
			end
			local band = { x = r.x, y = r.y + y, w = r.w, h = n }
			local from = y * stride + 1
			local slice = piece(data, from, from + n * stride - 1)
			-- only the LAST band waits: the task handles messages
			-- in order, so its reply reports the whole sequence.
			local last = y + n >= r.h
			local ok, err = tell({ op = "load", r = band,
			    fmt = fmt, id = id,
			    data = given(slice) }, wait and last)

			if not ok then
				return nil, err
			end
			y = y + n
		end
		return true
	end

	-- give: the bytes are the caller's to lose, so a load that fits one
	-- message hands them over instead of copying them in. A banded load
	-- copies either way, since a band is part of the payload.
	-- fmt names what the bytes are. Absent means bgrx, so a caller
	-- written before there was a choice keeps working.
	function f.load(r, data, wait, give, fmt, id)
		local bpp = pixwidth(fmt)

		if not bpp then
			return nil, "no such format: " .. tostring(fmt)
		end
		return loadband(r, give and given(data) or data, wait, fmt,
		    bpp, id)
	end
	-- the reply is a message too, so readback needs the same banding as
	-- load above -- the limit is on messages, not on direction. plan 9
	-- splits unloadimage identically, for identically this reason.
	function f.unload(r)
		local stride = r.w * 4
		local perband = stride > 0 and (CHUNK // stride) or 0

		if perband >= r.h then
			return ask({ op = "unload", r = r })
		end

		local out = {}

		-- a row wider than a message: read it in pieces and rejoin.
		-- the pieces have to be concatenated PER ROW, since the
		-- result is one contiguous run of rows.
		if perband < 1 then
			local half = CHUNK // 4

			if half < 1 then
				return nil, "message limit below one pixel"
			end
			for y = 0, r.h - 1 do
				local x = 0

				while x < r.w do
					local n = r.w - x

					if n > half then
						n = half
					end
					local piece, err = ask({ op = "unload",
					    r = { x = r.x + x, y = r.y + y,
					        w = n, h = 1 } })

					if not piece then
						return nil, err
					end
					out[#out + 1] = piece
					x = x + n
				end
			end
			return table.concat(out)
		end

		local y = 0

		while y < r.h do
			local n = r.h - y

			if n > perband then
				n = perband
			end
			local piece, err = ask({ op = "unload",
			    r = { x = r.x, y = r.y + y, w = r.w, h = n } })

			if not piece then
				return nil, err
			end
			out[#out + 1] = piece
			y = y + n
		end
		return table.concat(out)
	end
	function f.scroll(r, to, wait)
		return tell({ op = "scroll", r = r, to = to }, wait)
	end

	-- round-trip the cheapest op there is. one task handles its
	-- messages in order, so a reply to this one means every load sent
	-- before it has already reached the screen.
	function f.sync()
		return ask({ op = "mode" }) ~= nil
	end
	return f
end

return M
