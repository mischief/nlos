-- p9tcp: a 9P transport over a tcp connection, for lib/p9fs.lua.
--
-- The stream shape p9fs.new documents: send(bytes), recv() -> one whole
-- frame or nil. Everything above it -- tags, the mux that routes
-- replies back to their callers, fids -- is p9fs's, and nothing here
-- reads a byte of a message beyond its length prefix.
--
-- De-framing is here rather than in p9fs because this is where the
-- partial reads are. A tcp recv returns whatever happened to have
-- arrived: half a message, three messages, or a message split across
-- two arrivals. p9fs asks for one reply at a time and should not have
-- to know that the wire has no message boundaries -- 9P's size[4] is
-- there precisely to put them back, and putting them back is the job of
-- whoever holds the socket.
--
-- Note the contrast with the routed transport (los.platform.p9). There
-- the device answers into the slot the request went out in, so nothing
-- has to match replies to requests and the tag is only an assertion.
-- Here there is one channel carrying every reply in whatever order the
-- server chose, which is exactly why p9fs keeps a tag mux at all.

local M = {}

-- net is lib/caps.lua's tcp client (caps.tcp(handle)): dial, send, recv,
-- close, by message to the one task holding the tcp capability.
--
-- Returns a transport, or nil plus a message. The caller owns closing
-- it; dropping it leaks the connection until the tcp task's own
-- lifetime ends it.
function M.dial(net, a, b, c, d, port)
	local connid = net.dial(a, b, c, d, port or 564)

	if not connid then
		return nil, "p9tcp: dial failed"
	end

	local buf = ""
	local eof = false
	local T = {}

	function T.send(bytes)
		if not net.send(connid, bytes) then
			error("p9tcp: send failed", 0)
		end
	end

	-- one complete frame, or nil once the connection cannot produce
	-- one. size[4] counts ITSELF (see lib/ninep.lua's frame()), so the
	-- prefix is the whole length and not a body length.
	function T.recv()
		while true do
			if #buf >= 4 then
				local size = string.unpack("<I4", buf)

				-- a size that cannot be a 9P message means the
				-- stream is out of step, and every later frame
				-- would be garbage read from the middle of
				-- this one. Better to end the connection than
				-- to hand p9fs bytes that will decode into
				-- something plausible.
				if size < 7 then
					return nil
				end
				if #buf >= size then
					local frame = buf:sub(1, size)

					buf = buf:sub(size + 1)
					return frame
				end
			end
			if eof then
				return nil	-- a partial frame at the end
			end

			local got = net.recv(connid, 65536)

			if not got or got == "" then
				eof = true
			else
				buf = buf .. got
			end
		end
	end

	function T.close()
		net.close(connid)
		eof = true
	end

	return T
end

return M
