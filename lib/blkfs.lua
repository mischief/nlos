-- blkfs: a block device as a dev backend (see lib/dev.lua).
--
-- the tree is two files and nothing else:
--
--	/data	the whole device, as a seekable byte stream
--	/ctl	read-only text: capacity, sector size
--
-- /data being an ordinary file is the whole design. a filesystem laid
-- over these bytes is then a backend that opens /data through a
-- namespace and knows nothing about virtio, which means it can be
-- developed and tested against a plain file on a host and mounted here
-- unchanged. the alternative -- a filesystem talking to
-- los.platform.blk directly -- would tie it to this platform and to
-- this transport for no gain.
--
-- offsets and lengths here are BYTES, because that is what dev.read and
-- dev.write take and what every caller above already speaks. sectors
-- are this file's problem and appear in no interface it exposes; the
-- read-modify-write that hides them is below.
--
-- failures are raised, not returned (lib/dev.lua says why).

-- whichever raw device this proc holds. The kernel grants exactly one
-- -- PRIV_BLK brings los.platform.blk, PRIV_FLASH brings
-- los.platform.flash -- and they answer the same three calls, so this
-- file works either way and a client cannot tell from the outside which
-- it mounted. Asking for both and taking the one that answers is how a
-- proc discovers what its own capability was.
local blk = select(2, pcall(require, "los.platform.blk"))

if type(blk) ~= "table" then
	blk = require("los.platform.flash")
end

local buf = require("los.buf")
local dev = require("dev")

local M = {}

local err = dev.error

function M.new()
	local nsec, secsz = blk.capacity()

	if not nsec then
		err(dev.Eio)
	end

	local size = nsec * secsz

	-- the most sectors ONE DEVICE TRANSFER may carry, which is a fact
	-- about virtio_blk.c (VIRTIO_BLK_MAXIO) and about nothing else.
	--
	-- it is not a limit on what this backend answers. A read of any
	-- size is satisfied in full, splitting into as many transfers as it
	-- takes, because that is what the dev interface promises: short
	-- means end of file and nothing else, and a backend that returned
	-- short for its own convenience would truncate every large read
	-- that came through a mount (see dev.readloop).
	--
	-- the transport's own ceiling is a separate concern living in a
	-- separate place -- dev.IOUNIT, applied by lib/mnt.lua and
	-- lib/srv.lua. That split is the point: this file knows about
	-- sectors, that one knows about messages, and neither has to know
	-- the other's number.
	--
	-- A driver that disagrees says so: the esp32 flash partition
	-- moves 4KB sectors and takes eight, where virtio takes 32 of
	-- 512 bytes. Whichever it is, the number is the device's and not
	-- this file's.
	local MAXSEC = blk.maxsec or 32

	local B = {}

	local ctl = string.format("sectors %d\nsectorsize %d\nbytes %d\n",
		nsec, secsz, size)

	-- a handle is { name = }: "/" for the root, "data" or "ctl" for
	-- the two files. there is no per-handle state beyond that, so
	-- open() can hand back a fresh table and satisfy dev.lua's rule
	-- that an opened handle owns its own lifetime without owning
	-- anything.
	local function h_of(name)
		return { name = name, dir = (name == "/") }
	end

	local files = { data = true, ctl = true }

	function B.attach()
		return h_of("/")
	end

	function B.walk(h, name)
		if not h.dir then
			err(dev.Enotdir)
		end
		if name == "." then
			return h_of(h.name)
		end
		-- ".." at our root stays at our root: a mount is a boundary
		-- and a client must not climb out of it.
		if name == ".." then
			return h_of("/")
		end
		if not files[name] then
			err(dev.Enonexist)
		end
		return h_of(name)
	end

	local function sizeof(name)
		if name == "data" then
			return size
		elseif name == "ctl" then
			return #ctl
		end
		return 0
	end

	function B.stat(h)
		return {
			name = h.name,
			size = sizeof(h.name),
			dir = h.dir,
		}
	end

	function B.open(h, mode)
		if h.dir then
			if mode ~= "r" then
				err(dev.Eisdir)
			end
			return dev.closable(B, h_of("/"))
		end
		if h.name == "ctl" and mode ~= "r" then
			err(dev.Eperm)
		end
		return dev.closable(B, h_of(h.name))
	end

	-- nothing here can be made or removed: the tree is fixed and the
	-- device's size is the device's.
	function B.create(h, name, mode)
		if not h.dir then
			err(dev.Enotdir)
		end
		err(dev.Eperm)
	end

	function B.readdir(h)
		if not h.dir then
			err(dev.Enotdir)
		end
		return {
			{ name = "ctl", size = #ctl, dir = false },
			{ name = "data", size = size, dir = false },
		}
	end

	-- read [off, off+n) of the device.
	--
	-- the request is almost never sector aligned -- a caller reading a
	-- 512-byte structure at offset 3 is reading two sectors -- so the
	-- transfer is widened to the sectors that contain it and the
	-- surplus trimmed off the ends afterwards.
	local function readat(off, n)
		if off >= size then
			return ""		-- eof, which is the contract
		end
		if off + n > size then
			n = size - off
		end

		local first = off // secsz
		local last = (off + n - 1) // secsz
		local skip = off - first * secsz
		local nsec = last - first + 1

		-- one transfer: the driver's own buffer is the answer, and
		-- nothing is copied at all. A read of whole sectors comes
		-- back untouched, which is what a filesystem asks for.
		if nsec <= MAXSEC then
			local got = blk.read(first, nsec)

			if skip == 0 and #got == n then
				return got
			end
			return got:view(skip + 1, skip + n)
		end

		-- larger than one transfer: one buffer for the run, each
		-- transfer copied into it once. The device ceiling is
		-- invisible above this line.
		local whole = buf.new(nsec * secsz)
		local pos = 1
		local sec = first

		while sec <= last do
			local want = last - sec + 1

			if want > MAXSEC then
				want = MAXSEC
			end
			pos = pos + whole:copy(pos, blk.read(sec, want))
			sec = sec + want
		end

		return whole:view(skip + 1, skip + n)
	end

	function B.read(h, off, n)
		if h.dir then
			err(dev.Eisdir)
		end
		if off < 0 or n < 0 then
			err(dev.Ebadarg)
		end
		if h.name == "ctl" then
			return ctl:sub(off + 1, off + n)
		end
		return readat(off, n)
	end

	function B.write(h, off, data)
		if h.dir then
			err(dev.Eisdir)
		end
		if h.name ~= "data" then
			err(dev.Eperm)
		end
		if off < 0 then
			err(dev.Ebadarg)
		end

		local n = #data

		if n == 0 then
			return 0
		end
		-- short rather than wrapping or extending: a disk has a
		-- fixed size and the caller has to be told it hit the end.
		if off >= size then
			err(dev.Eio)
		end
		if off + n > size then
			n = size - off
			data = data:sub(1, n)
		end

		local first = off // secsz
		local last = (off + n - 1) // secsz
		local head = off - first * secsz
		local tail = (last + 1) * secsz - (off + n)

		-- read-modify-write, and only where it is actually needed:
		-- a write that starts mid-sector must preserve the bytes
		-- before it, and one that ends mid-sector the bytes after.
		-- a write covering whole sectors reads nothing.
		--
		-- One buffer for the whole run, with the caller's bytes
		-- copied into the middle of it. Growing a string at both
		-- ends instead copied everything again per end, which for a
		-- one-byte write at an offset was two copies of the run.
		if head > 0 or tail > 0 then
			local whole = buf.new((last - first + 1) * secsz)

			if head > 0 then
				whole:copy(1, blk.read(first, 1), 1, head)
			end
			whole:copy(head + 1, data)
			if tail > 0 then
				whole:copy(head + #data + 1,
				    blk.read(last, 1), secsz - tail + 1)
			end
			data = whole
		end

		local sec = first
		local pos = 1

		while sec <= last do
			local want = last - sec + 1

			if want > MAXSEC then
				want = MAXSEC
			end

			local nb = want * secsz

			-- a view where the run is a buffer, a slice where
			-- the caller handed whole sectors as a string
			blk.write(sec, buf.is(data) and
			    data:view(pos, pos + nb - 1) or
			    data:sub(pos, pos + nb - 1))
			pos = pos + nb
			sec = sec + want
		end

		-- the bytes the CALLER asked to write, not the sectors we
		-- touched to do it
		return n
	end

	function B.clunk(h)
	end

	return B
end

return M
