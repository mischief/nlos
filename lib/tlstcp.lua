-- tlstcp: a tcp capability, with TLS over it. Answers dial, send, recv
-- and close, which is all lib/http asks of a transport, so http.get
-- takes one where it took the plain capability.

-- lib/tls/conn.lua is sans-io: it turns bytes into bytes and never
-- touches a socket. This is the half that does, and it is the only
-- place the two meet.

local tlsconn = require("tls.conn")

local M = {}

-- Trust on first use: the key is remembered per host and a change is
-- refused, which is what a machine with no clock it believes and no
-- root store can honestly do. The store lives as long as the caller,
-- so first use is every run. onnew is told what was accepted.
function M.tofu(host, onnew)
	local seen = {}

	return require("tls.tofu").new({
		host = host,
		known = function(h)
			return seen[h]
		end,
		learn = function(h, fp)
			seen[h] = fp
		end,
		ask = function(h, fp)
			if onnew then
				onnew(h, fp)
			end
			return true
		end,
	})
end

-- Records arrive whole or in pieces, and neither is visible from here:
-- a handshake step is "read some bytes, feed them in, send what comes
-- back" until the state says established.
local CHUNK = 4096

-- A handshake that will not finish must end. TLS 1.3 needs one round
-- trip and two with a HelloRetryRequest, so ten catches a peer that
-- answers without progressing and limits nothing real.
local MAXFLIGHT = 10

-- opts.rand is where the bytes come from, and there is no default:
-- entropy is data here, handed down from the boot proc, and a
-- library that invented its own would be inventing a weak one.
function M.new(tcp, opts)
	opts = opts or {}

	local rand = assert(opts.rand, "tls: needs rand")

	local t = {}

	-- host is the name for SNI and for whatever `verify` pins on. An
	-- ip address is not a name, so it travels as nil.
	function t.dial(a, b, c, d, port, host)
		local sock = tcp.dial(a, b, c, d, port)

		if not sock then
			return nil, "connect failed"
		end

		local self = {
			sock = sock,
			tls = tlsconn.new {
				rand = rand,
				server_name = host,
				verify = opts.verify,
				insecure = opts.insecure,
			},
			-- plaintext the record layer handed back before the
			-- caller asked for it. A record carries as much as it
			-- carries; a reader asks for what it wants.
			pending = "",
		}

		-- Driven on the state, not on what comes back: a flight
		-- split across segments leaves nothing to send yet, which
		-- means read more rather than finished.
		local out = self.tls:start()
		local n = 0

		while true do
			if out and #out > 0 then
				if not tcp.send(sock, out) then
					tcp.close(sock)
					return nil, "tls: send failed"
				end
			end
			if self.tls.state == "established" then
				break
			end

			n = n + 1
			if n > MAXFLIGHT then
				tcp.close(sock)
				return nil, "tls: handshake did not settle"
			end

			local inb = tcp.recv(sock, CHUNK)

			if not inb then
				tcp.close(sock)
				return nil, "tls: the peer closed during the "
				    .. "handshake"
			end

			local reply, err = self.tls:recv(inb)

			if not reply then
				tcp.close(sock)
				return nil, "tls: " .. tostring(err)
			end
			out = reply
			-- what came back may be plaintext rather than a
			-- flight: an established peer can speak first.
			self.pending = self.pending .. self.tls:read()
		end
		return self
	end

	function t.send(self, data)
		local recs, err = self.tls:write(data)

		if not recs then
			return nil, err
		end
		return tcp.send(self.sock, recs)
	end

	-- Answers plaintext, or nil where the plain capability would: at
	-- the end of the stream. A record that yields nothing yet is not
	-- the end, so this reads again rather than reporting one.
	function t.recv(self, want)
		while self.pending == "" do
			local inb = tcp.recv(self.sock, want or CHUNK)

			if not inb then
				return nil
			end

			local out, err = self.tls:recv(inb)

			if not out then
				return nil, err
			end
			if #out > 0 and not tcp.send(self.sock, out) then
				return nil, "tls: send failed"
			end
			self.pending = self.pending .. self.tls:read()
			if self.tls.closed and self.pending == "" then
				return nil
			end
		end

		local s = self.pending

		self.pending = ""
		return s
	end

	-- close_notify first, so the peer can tell the end of the stream
	-- from a connection that was cut. Best effort: a socket already
	-- gone is the case this is for.
	function t.close(self)
		local bye = self.tls:close()

		if bye and #bye > 0 then
			tcp.send(self.sock, bye)
		end
		return tcp.close(self.sock)
	end
	return t
end

return M
