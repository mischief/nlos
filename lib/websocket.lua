-- websocket: RFC 6455, the client half.
--
--	local ws = websocket.connect(net, dns, "wss://relay.example",
--	    { rand = prog.rand() })
--	ws:send('["REQ","sub",{"kinds":[1],"limit":20}]')
--	print(ws:recv())

-- The upgrade is written here rather than through http.Conn: a 101
-- carries no body, and the framing below owns the socket afterwards.

-- A client masks every frame it sends and a server masks none. The mask
-- is four bytes of the caller's entropy rather than a counter, because
-- RFC 6455 wants a value the peer cannot predict.

local http = require("http")
local sha1 = require("crypto.sha1")
local base64 = require("ssh.base64")

local M = {}

local Ws = {}

Ws.__index = Ws

local GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

M.CONT, M.TEXT, M.BINARY = 0x0, 0x1, 0x2
M.CLOSE, M.PING, M.PONG = 0x8, 0x9, 0xa

-- how much of one message is kept. A relay may send a very long event,
-- and a machine this size would rather drop it than run out of memory.
M.MAXMSG = 128 * 1024

-- ---- the socket underneath ----

function Ws:fill(want)
	while not want(self.buf) do
		if self.dead then
			return nil, "connection closed"
		end

		local data = self.tcp.recv(self.conn, 4096)

		if not data or data == "" then
			self.dead = true
			return nil, "connection closed"
		end
		self.buf = self.buf .. data
	end
	return true
end

local function need(n)
	return function(buf) return #buf >= n end
end

function Ws:take(n)
	local ok, err = self:fill(need(n))

	if not ok then
		return nil, err
	end

	local out = self.buf:sub(1, n)

	self.buf = self.buf:sub(n + 1)
	return out
end

-- ---- frames ----

-- The length is 7 bits, or 16, or 64, whichever is the shortest that
-- fits. A server that reads a longer form than needed is entitled to
-- close the connection, so this picks the same way every peer does.
local function header(op, len, mask)
	local b1 = 0x80 | op
	local out

	if len < 126 then
		out = string.char(b1, 0x80 | len)
	elseif len < 65536 then
		out = string.char(b1, 0x80 | 126) .. string.pack(">I2", len)
	else
		out = string.char(b1, 0x80 | 127) .. string.pack(">I8", len)
	end
	return out .. mask
end

local function xormask(data, mask)
	local out = {}

	for i = 1, #data do
		out[i] = string.char(data:byte(i) ~
		    mask:byte((i - 1) % 4 + 1))
	end
	return table.concat(out)
end

function Ws:frame(op, data)
	if self.dead then
		return nil, "connection closed"
	end

	data = data or ""

	local mask = self.rand and self.rand(4) or "\0\0\0\0"
	local wire = header(op, #data, mask) .. xormask(data, mask)
	local n, err = self.tcp.send(self.conn, wire)

	if not n then
		self.dead = true
		return nil, err or "send failed"
	end
	return true
end

function Ws:send(text)
	return self:frame(M.TEXT, text)
end

-- one frame off the wire, as (op, payload). A server never masks, but
-- one that does is unmasked here rather than refused: the bit says so.
function Ws:readframe()
	local h, err = self:take(2)

	if not h then
		return nil, err
	end

	local b1, b2 = h:byte(1), h:byte(2)
	local fin = (b1 & 0x80) ~= 0
	local op = b1 & 0x0f
	local masked = (b2 & 0x80) ~= 0
	local len = b2 & 0x7f

	if len == 126 then
		local e = self:take(2)

		if not e then
			return nil, "short length"
		end
		len = string.unpack(">I2", e)
	elseif len == 127 then
		local e = self:take(8)

		if not e then
			return nil, "short length"
		end
		len = string.unpack(">I8", e)
	end

	if len > M.MAXMSG then
		self:close(1009, "message too big")
		return nil, ("frame of %d bytes is over the limit"):format(len)
	end

	local mask

	if masked then
		mask = self:take(4)
		if not mask then
			return nil, "short mask"
		end
	end

	local data = ""

	if len > 0 then
		data, err = self:take(len)
		if not data then
			return nil, err
		end
		if mask then
			data = xormask(data, mask)
		end
	end
	return op, data, fin
end

-- one whole message, answering pings on the way. Continuation frames
-- are joined, which is why this is not readframe: a relay is free to
-- split an event across as many as it likes.
function Ws:recv()
	local parts, first = {}, nil

	while true do
		local op, data, fin = self:readframe()

		if not op then
			return nil, data
		end

		if op == M.PING then
			self:frame(M.PONG, data)
		elseif op == M.PONG then
			-- nothing to do: we sent the ping
		elseif op == M.CLOSE then
			self.dead = true
			return nil, "closed by peer"
		else
			if op ~= M.CONT then
				first = op
			end
			parts[#parts + 1] = data
			if fin then
				return table.concat(parts), first
			end
		end
	end
end

function Ws:ping(data)
	return self:frame(M.PING, data or "")
end

function Ws:alive()
	return not self.dead
end

function Ws:close(code, why)
	if not self.dead then
		self:frame(M.CLOSE,
		    string.pack(">I2", code or 1000) .. (why or ""))
		self.dead = true
	end
	if self.conn then
		self.tcp.close(self.conn)
		self.conn = nil
	end
end

-- ---- the upgrade ----

local function accept_for(key)
	return base64.encode(sha1.hash(key .. GUID), true)
end

-- connect(tcp, dns, url, opts) -> ws, or nil and why.
--
-- opts.rand is required for wss and for masking, and there is no
-- default: entropy is handed down here, and a library that invented its
-- own would be inventing a weak one.
function M.connect(tcp, dns, url, opts)
	opts = opts or {}

	local scheme, rest = url:match("^(wss?)://(.*)$")

	if not scheme then
		return nil, "not a ws:// or wss:// url"
	end

	local host = rest:match("^([^/]+)")
	local path = rest:match("^[^/]+(/.*)$") or "/"
	local as_http = (scheme == "wss" and "https://" or "http://") .. rest

	-- trust on first use, as the http client does: a machine with no
	-- clock it believes and no root store can say the key did not
	-- change, and cannot say more than that.
	if scheme == "wss" and not opts.verify and not opts.insecure then
		local ok, tlstcp = pcall(require, "tlstcp")

		if not ok then
			return nil, "no tls on this machine: " ..
			    tostring(tlstcp)
		end
		local with = {}

		for k, v in pairs(opts) do
			with[k] = v
		end
		with.verify = tlstcp.tofu(host:match("^[^:]+"))
		opts = with
	end

	local c, err = http.connect(tcp, dns, as_http, opts)

	if not c then
		return nil, err
	end
	local key = base64.encode(opts.rand and opts.rand(16) or
	    ("lua-os websocket"), true)
	local req = table.concat({
		("GET %s HTTP/1.1"):format(path),
		("Host: %s"):format(host),
		"Upgrade: websocket",
		"Connection: Upgrade",
		("Sec-WebSocket-Key: %s"):format(key),
		"Sec-WebSocket-Version: 13",
		"", "",
	}, "\r\n")

	local ws = setmetatable({
		tcp = c.tcp, conn = c.conn, host = host,
		buf = "", dead = false, rand = opts.rand,
	}, Ws)

	local n, serr = ws.tcp.send(ws.conn, req)

	if not n then
		ws:close()
		return nil, serr or "send failed"
	end

	local ok, ferr = ws:fill(function(buf)
		return buf:find("\r\n\r\n", 1, true) ~= nil
	end)

	if not ok then
		ws:close()
		return nil, "no upgrade response: " .. tostring(ferr)
	end

	local at = ws.buf:find("\r\n\r\n", 1, true)
	local head = ws.buf:sub(1, at - 1)

	-- what is left is the first frame, and it stays in the buffer
	ws.buf = ws.buf:sub(at + 4)

	local status = tonumber(head:match("^HTTP/1%.[01] (%d%d%d)"))

	if status ~= 101 then
		ws:close()
		return nil, ("upgrade refused: status %s"):format(
		    tostring(status))
	end

	local got = head:match("[Ss]ec%-[Ww]eb[Ss]ocket%-[Aa]ccept:%s*([^\r\n]+)")

	if got ~= accept_for(key) then
		ws:close()
		return nil, "the peer's accept key does not match"
	end
	return ws
end

return M
