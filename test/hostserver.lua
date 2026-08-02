-- a tiny discard/chargen/echo server for the host side of a guest test.
--
-- The guest needs something to dial. Everything else in test/ has the
-- host as the client and the guest as the server, which hostfwd
-- arranges; this is the other direction, and qemu's user networking
-- already provides it -- a guest connecting to 10.0.2.2 is proxied onto
-- the host's loopback, which is exactly where listen_tcp binds.
--
-- Written here rather than borrowed, because the alternative was
-- depending on inetd having chargen enabled, or on a machine on
-- somebody's LAN. A bulk transfer test that fails when a router is
-- rebooted is not testing this code.
--
-- Single-threaded on purpose. The guest is the client and makes one
-- connection at a time, so a select loop would be machinery in service
-- of nothing.

local M = {}

-- The pattern the guest checks against. Deliberately not a constant
-- byte: a stack that duplicated or dropped a whole segment would still
-- produce the right length and the right hash out of "xxxx...", and the
-- point of hashing is to catch exactly that. Period 251, a prime, so it
-- lines up with no segment or buffer size in use anywhere.
--
-- BLOCK is a whole number of periods, which is what lets chargen repeat
-- it instead of generating the stream. Repeating a block whose length
-- is not a multiple of 251 is a different sequence from continuing the
-- pattern, and the two agree for exactly the first block -- so the
-- first version of this passed its length check and failed its hash.
M.PERIOD = 251
M.BLOCKLEN = 251 * 261		-- 65511, just under 64KB

function M.pattern(n, off)
	local out = {}

	off = off or 0
	for i = 0, n - 1 do
		out[#out + 1] = string.char((i + off) % 251)
	end
	return table.concat(out)
end

-- chargen: write `total` bytes of the pattern and close. The close is
-- the signal the guest reads for -- there is no length header, so a
-- guest that mishandles a FIN hangs here rather than quietly passing.
function M.chargen(hostutil, fd, total, chunk)
	chunk = chunk or M.BLOCKLEN

	local sent = 0
	local block = M.pattern(chunk)

	while sent < total do
		local n = math.min(chunk, total - sent)
		local piece = n == chunk and block or block:sub(1, n)

		-- hostutil.send writes the whole string or fails: it loops
		-- over the short writes itself, and answers true rather than
		-- a count. So there is no partial case to carry here, and a
		-- false means the guest went away mid-transfer.
		if not hostutil.send(fd, piece) then
			return sent
		end
		sent = sent + n
	end
	return sent
end

-- discard: read until the peer closes, counting. What the guest is
-- being timed on is its send path.
function M.discard(hostutil, fd, timeout)
	local total = 0

	while true do
		local chunk, err = hostutil.recv(fd, 65536, timeout or 10)

		if not chunk or #chunk == 0 then
			return total, err
		end
		total = total + #chunk
	end
end

-- echo: read and write back until the peer closes.
function M.echo(hostutil, fd, timeout)
	local total = 0

	while true do
		local chunk = hostutil.recv(fd, 65536, timeout or 10)

		if not chunk or #chunk == 0 then
			return total
		end
		hostutil.send(fd, chunk)
		total = total + #chunk
	end
end

return M
