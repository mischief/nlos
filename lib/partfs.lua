-- partfs: one partition of a block device, served as /data and /ctl.
--
-- It sits on another dev's /data -- blksrv's whole disk -- and presents a
-- [off, off+len) window of it as its own /data starting at zero. That is
-- the block-offset translation a filesystem above should not have to do:
-- task/gefssrv.lua mounts this exactly as it mounts the whole disk, and
-- the only difference it sees is fewer bytes, shifted. lib/blkfs.lua is
-- the same shape one layer down; this is thinner because the disk below
-- is already byte-addressable, so there are no sectors to widen to.
--
-- the tree is the two files blkfs serves, and for the same reasons:
--
--	/data	the partition, as a seekable byte stream
--	/ctl	read-only text: the window's length and its offset
--
-- failures are raised, not returned (src/dev.c says why).

local dev = require("dev")

local M = {}

local err = dev.error

-- parent: an open handle on the underlying /data (seek/read/write, as
-- ns:open hands back). off, len: the window in bytes.
function M.new(parent, off, len)
	local B = {}

	local ctl = string.format("bytes %d\noffset %d\n", len, off)

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
			return len
		elseif name == "ctl" then
			return #ctl
		end
		return 0
	end

	function B.stat(h)
		return { name = h.name, size = sizeof(h.name), dir = h.dir }
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

	function B.create(h)
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
			{ name = "data", size = len, dir = false },
		}
	end

	function B.read(h, o, n)
		if h.dir then
			err(dev.Eisdir)
		end
		if o < 0 or n < 0 then
			err(dev.Ebadarg)
		end
		if h.name == "ctl" then
			return ctl:sub(o + 1, o + n)
		end
		if o >= len then
			return ""		-- eof, the contract
		end
		if o + n > len then
			n = len - o
		end
		parent:seek("set", off + o)
		local s = parent:read(n) or ""
		if #s < n then
			s = s .. string.rep("\0", n - #s)
		end
		return s
	end

	function B.write(h, o, data)
		if h.dir then
			err(dev.Eisdir)
		end
		if h.name ~= "data" then
			err(dev.Eperm)
		end
		if o < 0 then
			err(dev.Ebadarg)
		end

		local n = #data

		if n == 0 then
			return 0
		end
		-- short rather than past the end: the partition has a fixed
		-- size, the same way the disk does in blkfs.
		if o >= len then
			err(dev.Eio)
		end
		if o + n > len then
			n = len - o
			data = data:sub(1, n)
		end
		parent:seek("set", off + o)
		parent:write(data)
		return n
	end

	function B.clunk(_)
	end

	return B
end

return M
