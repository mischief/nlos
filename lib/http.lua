-- http: a minimal HTTP/1.1 client, plain library (not a task) --
-- unlike tcp/udp/dns, it owns no capability of its own, just protocol
-- logic riding on whatever tcp/dns capability instances the calling
-- proc already holds (caps.tcp()/caps.dns() results, passed in).
--
-- "async" here means: this is ordinary-looking synchronous code, but
-- every tcp/dns call it makes goes through caps.lua's requester(),
-- which is thread.recv() underneath -- when called from inside a
-- thread.spawn()'d coroutine (thread.run() driving it), that recv
-- yields back to the scheduler instead of blocking the whole proc.
-- run several M.get() calls as separate coroutines to fetch
-- concurrently; run one directly (not inthread()) and it just
-- blocks the proc, same as dns.resolve() does today.
--
-- Scope: HTTP/1.1 with keep-alive and chunked responses. A response in
-- any other transfer-encoding is refused rather than guessed at, since
-- a body of unknown length cannot be told from the next response on a
-- connection that stays open. https is lib/tlstcp,
-- wrapped in where the scheme says so. M.serve's request parsing is
-- method-agnostic (POST bodies work, for lib/mcp.lua's JSON-RPC).

local thread = require("los.thread")
local ns = require("ns")

local M = {}

local function parse_url(url)
	local scheme, host, port, path =
	    url:match("^(https?)://([^:/]+):?(%d*)(/?.*)$")
	if not host then
		return nil, "bad url"
	end
	port = tonumber(port) or (scheme == "https" and 443 or 80)
	if path == "" then
		path = "/"
	end
	return host, port, path, scheme
end

local function parse_ip(ip)
	local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then
		return nil
	end
	return tonumber(a), tonumber(b), tonumber(c), tonumber(d)
end

-- a ceiling on one response, since without it a large (or endless) one
-- grows until the proc hits its mem_limit and dies. Callers who
-- genuinely want more can raise it.
M.MAXBODY = 1024 * 1024


-- ---- a connection, reused ----
-- A handshake costs seconds on a board where the network costs
-- milliseconds, so a second request's cost is nearly all avoidable.
-- This reads exactly Content-Length and keeps the socket; the one-shot
-- below reads to EOF and must close. A read can return the head of the
-- next response with the tail of this one, so the rest is kept.
local Conn = {}

Conn.__index = Conn

-- bytes from the socket until `want(buf)` returns something
function Conn:fill(want)
	while true do
		local at = want(self.buf)

		if at then
			return at
		end
		if self.dead then
			return want(self.buf, true), "connection closed"
		end

		local data = self.tcp.recv(self.conn, 4096)

		if not data or data == "" then
			-- one more look: a body ended by the close is
			-- complete, and `want` is what knows that.
			self.dead = true
			return want(self.buf, true), "closed early"
		end
		self.buf = self.buf .. data
		if #self.buf > M.MAXBODY then
			return nil, "response exceeds MAXBODY"
		end
	end
end

-- deliver `len` bytes to `sink`, a piece at a time. Nothing larger
-- than one socket read is ever held, so a body may be any size: the
-- ceiling stops being memory and starts being the far end's patience.
function Conn:drain(len, sink)
	local left = len

	while left > 0 do
		if #self.buf == 0 then
			local got = self:fill(function(buf, eof)
				if #buf > 0 then
					return #buf
				end
				return eof and 0 or nil
			end)

			if not got or got == 0 then
				return nil, "body ended early"
			end
		end

		local take = #self.buf < left and #self.buf or left
		local piece = self.buf:sub(1, take)

		self.buf = self.buf:sub(take + 1)
		left = left - take
		if not sink(piece) then
			return nil, "sink refused the body"
		end
	end
	return true
end

-- a chunked body, reassembled. Each chunk is a hex length, the bytes,
-- and a CRLF; a zero length ends it, and whatever trailers follow run
-- to a blank line. Reading them is what keeps the connection usable:
-- the alternative is not knowing where the next response starts.
function Conn:chunked(sink)
	local parts, total = {}, 0

	local function line()
		local at = self:fill(function(buf)
			return buf:find("\r\n", 1, true)
		end)

		if not at then
			return nil
		end

		local s = self.buf:sub(1, at - 1)

		self.buf = self.buf:sub(at + 2)
		return s
	end

	while true do
		local head = line()

		if not head then
			return nil, "chunk header truncated"
		end

		-- the length, up to any ";ext" the sender added
		local n = tonumber(head:match("^%x+") or "", 16)

		if not n then
			return nil, "bad chunk length: " ..
			    string.format("%q", head:sub(1, 16))
		end
		if n == 0 then
			-- trailers, then the blank line that ends them
			repeat
				local t = line()

				if not t then
					return nil, "trailer truncated"
				end
			until t == ""
			break
		end

		total = total + n
		-- a sink is the caller taking the bytes away, so the
		-- ceiling that protects memory does not apply
		if not sink and total > M.MAXBODY then
			return nil, "response exceeds MAXBODY"
		end

		-- the bytes plus the CRLF that follows them
		local got = self:fill(function(buf)
			return #buf >= n + 2 and n or nil
		end)

		if not got then
			return nil, "chunk body truncated"
		end
		if sink then
			if not sink(self.buf:sub(1, n)) then
				return nil, "sink refused the body"
			end
		else
			parts[#parts + 1] = self.buf:sub(1, n)
		end
		self.buf = self.buf:sub(n + 3)
	end
	if sink then
		return true
	end
	return table.concat(parts)
end

function Conn:request(req)
	if self.dead then
		return nil, "connection closed"
	end

	local body = req and req.body
	local lines = {
		((req and req.method) or "GET") .. " " ..
		    ((req and req.path) or "/") .. " HTTP/1.1",
		"Host: " .. self.host,
		"User-Agent: lua-os",
		-- said rather than assumed: 1.1 keeps a connection open
		-- without being told, but a 1.0 hop in the middle does not.
		"Connection: keep-alive",
	}

	for k, v in pairs((req and req.headers) or {}) do
		lines[#lines + 1] = k .. ": " .. v
	end
	if body then
		lines[#lines + 1] = "Content-Length: " .. #body
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = ""

	if not self.tcp.send(self.conn,
	    table.concat(lines, "\r\n") .. (body or "")) then
		self.dead = true
		return nil, "send failed"
	end

	local at, ferr = self:fill(function(buf)
		return buf:find("\r\n\r\n", 1, true)
	end)

	if not at then
		return nil, ferr or "no response"
	end

	local head = self.buf:sub(1, at - 1)

	self.buf = self.buf:sub(at + 4)

	local statusline, headerblock = head:match("^(.-)\r\n(.*)$")

	if not statusline then
		statusline, headerblock = head, ""
	end

	local status = tonumber(statusline:match(" (%d%d%d)"))
	local headers = {}

	for k, v in headerblock:gmatch("([^:\r\n]+):[ \t]*([^\r\n]*)") do
		headers[k:lower()] = v
	end
	if not status then
		self.dead = true
		return nil, "malformed response"
	end

	local len = tonumber(headers["content-length"] or "")
	local rbody

	local te = (headers["transfer-encoding"] or ""):lower()

	local sink = req and req.sink

	-- the status and headers, before a streamed body reaches the
	-- sink: a caller printing both cannot wait for a return that
	-- comes after the bytes it has to print first.
	if req and req.onhead then
		req.onhead(status, headers)
	end

	if te:find("chunked", 1, true) then
		local body, cerr = self:chunked(sink)

		if not body then
			self.dead = true
			return nil, cerr
		end
		rbody = sink and nil or body
	elseif te ~= "" then
		-- another coding leaves the body's end unknown, and a body
		-- whose end is unknown cannot be told from the next
		-- response on a socket that stays open.
		self.dead = true
		return nil, "transfer-encoding is not supported: " .. te
	elseif len then
		if sink then
			local okd, derr = self:drain(len, sink)

			if not okd then
				self.dead = true
				return nil, derr
			end
		else
			local got = self:fill(function(buf, eof)
				if #buf >= len then
					return len
				end
				return eof and #buf or nil
			end)

			if not got or got < len then
				self.dead = true
				return nil, "body ended early"
			end
			rbody = self.buf:sub(1, len)
			self.buf = self.buf:sub(len + 1)
		end
	else
		-- no length and no encoding: the close is the terminator,
		-- so this is the last response on this connection.
		if sink then
			while true do
				if #self.buf > 0 then
					if not sink(self.buf) then
						self.dead = true
						return nil, "sink refused the body"
					end
					self.buf = ""
				end
				if self.dead then
					break
				end
				self:fill(function(buf, eof)
					if #buf > 0 then
						return #buf
					end
					return eof and 0 or nil
				end)
			end
		else
			self:fill(function(_, eof) return eof and 0 or nil end)
			rbody, self.buf = self.buf, ""
		end
		self.dead = true
	end

	-- the far end's word wins: reusing a socket it has closed is a
	-- request sent into nothing.
	if (headers["connection"] or ""):lower():find("close", 1, true) then
		self.dead = true
	end

	-- a streamed body has already gone to the sink, so `length` is
	-- what a caller checks instead of #body
	return { status = status, headers = headers, body = rbody,
	    length = len }
end

function Conn:alive()
	return not self.dead
end

function Conn:close()
	if self.conn then
		self.tcp.close(self.conn)
		self.conn = nil
	end
	self.dead = true
end

-- connect(tcp, dns, url, opts) -> conn -- one handshake, many requests.
-- The url's path is ignored: each request names its own.
function M.connect(tcp, dns, url, opts)
	local host, port, _, scheme = parse_url(url)

	opts = opts or {}
	if not host then
		return nil, "bad url"
	end
	if scheme == "https" then
		local ok, tlstcp = pcall(require, "tlstcp")

		if not ok then
			return nil, "no tls on this machine: " ..
			    tostring(tlstcp)
		end
		-- entropy is data, handed down from the boot proc, and a
		-- caller lent none cannot open a tls connection. Answered
		-- rather than raised: tlstcp.new asserts, and an assert
		-- through here is a crash where every other failure in this
		-- function is a returned error.
		if not opts.rand then
			return nil, "tls: needs entropy, and this caller " ..
			    "was lent no seed"
		end
		tcp = tlstcp.new(tcp, opts)
	end

	local a, b, c, d = parse_ip(host)
	local named = a == nil

	if not a then
		if not dns then
			return nil, "no resolver, and host is not an ip: " ..
			    host
		end

		local ip = dns.resolve(host)

		if not ip then
			return nil, "dns resolve failed for " .. host
		end
		a, b, c, d = parse_ip(ip)
		if not a then
			return nil, "resolver returned junk: " .. tostring(ip)
		end
	end

	local conn, derr = tcp.dial(a, b, c, d, port, named and host or nil)

	if not conn then
		return nil, derr or "connect failed"
	end
	return setmetatable({ tcp = tcp, conn = conn, host = host,
	    buf = "", dead = false }, Conn)
end

-- one request over a connection of its own, which is what a caller
-- after a single page wants. Several of them go through M.connect,
-- and pay for the handshake once.
function M.get(tcp, dns, url, opts)
	local _, _, path = parse_url(url)
	local conn, cerr = M.connect(tcp, dns, url, opts)

	if not conn then
		return nil, cerr
	end

	-- opts.sink takes the body a piece at a time and res.body is then
	-- nil: what does not fit in memory can still be written to a file.
	local res, rerr = conn:request({ method = "GET", path = path,
	    sink = opts and opts.sink, onhead = opts and opts.onhead })

	conn:close()
	return res, rerr
end

-- ---- server ----
--
-- M.serve(tcp, port, handler) blocks forever, serving. it's built
-- entirely out of thread.spawn coroutines -- an "accept loop"
-- coroutine plus one more per live connection -- with thread.run()
-- as the actual event loop, so this task can hold many connections
-- open concurrently without ever touching tcp.lua's own poll
-- machinery directly (same reasoning as M.get: tcp.accept/recv/send
-- already yield correctly under thread.run() via caps.lua).
--
-- handler(req) -> {status=, headers=, body=} (status/headers/body
-- all optional; defaults are 200/{}/""). a handler error becomes a
-- real 500 instead of taking the connection (or the whole server)
-- down with it.

-- a listen before an address exists fails with EFI_NO_MAPPING, so this
-- retries. what it is waiting for changed, and so did the budget.
--
-- it used to be waiting out the FIRMWARE's dhcp, which takes about four
-- seconds whatever anyone does (see net_listen and lib/dhcp.lua) -- hence
-- 60 attempts at 250ms, fifteen seconds of headroom for a four second
-- wait nobody could shorten.
--
-- now every payload runs lib/dhcp.lua itself and has an address in
-- ~15ms, so all that is left to cover is the few milliseconds while a
-- dhcpd spawned moments ago finishes its four-way. a second of headroom
-- is generous for that, and failing in one second beats failing in
-- fifteen when the real problem is that nobody configured the network.
local LISTEN_ATTEMPTS = 20
local LISTEN_RETRY_MS = 50

local STATUS_TEXT = {
	[200] = "OK", [201] = "Created", [204] = "No Content",
	[301] = "Moved Permanently", [302] = "Found",
	[400] = "Bad Request", [403] = "Forbidden", [404] = "Not Found",
	[405] = "Method Not Allowed",
	[413] = "Content Too Large", [431] = "Request Header Fields Too Large",
	[500] = "Internal Server Error", [503] = "Service Unavailable",
}

-- ---- inbound limits ----
--
-- both of these are the difference between one rude client and a dead
-- machine. this loop runs in the SERVER proc, so anything it
-- accumulates is charged to the server -- and a boot payload has
-- mem_limit 0 (unlimited), which means an unbounded read here does not
-- kill the offending session, it exhausts the kernel heap for
-- everything.
--
-- there was no ceiling on either. `Content-Length: 1073741824` made
-- this read until the machine died, and headers with no blank line ever
-- did the same a chunk at a time. the body cap is enforced on the
-- DECLARED length, before a single byte is read, because reading a
-- gigabyte to discover it was a gigabyte concedes the attack.
M.MAXHEADERS = 16 * 1024
M.MAXBODYIN = 256 * 1024

-- outbound write size. well under MAXMSG (64KB), which is the hard
-- ceiling on a single message to the tcp task -- see write_response.
M.WRITECHUNK = 16 * 1024

local MIME_TYPES = {
	html = "text/html", htm = "text/html", css = "text/css",
	js = "text/javascript", json = "application/json",
	txt = "text/plain", md = "text/plain",
	png = "image/png", jpg = "image/jpeg", jpeg = "image/jpeg",
	gif = "image/gif", svg = "image/svg+xml", ico = "image/x-icon",
	wasm = "application/wasm", xml = "application/xml",
	pdf = "application/pdf",
}
local DEFAULT_MIME = "application/octet-stream"

-- parses the request line + headers, then reads exactly
-- Content-Length bytes of body if present (0 otherwise -- fine for
-- GET, needed for POST). no chunked transfer-encoding on requests,
-- matching the same limitation M.get accepts on responses.
--
-- returns the request, or nil plus the status to answer with.
local function read_request(tcp, conn)
	local parts, buflen, buf = {}, 0, ""

	while true do
		local headerend = buf:find("\r\n\r\n", 1, true)
		if headerend then
			local requestline, headerblock =
			    buf:match("^(.-)\r\n(.-)\r\n\r\n")
			local method, path, version =
			    requestline:match("^(%u+) (%S+) (HTTP/%d%.%d)$")
			if not method then
				return nil, 400
			end
			local headers = {}
			for k, v in
			    headerblock:gmatch("([^:\r\n]+):[ \t]*([^\r\n]*)") do
				headers[k:lower()] = v
			end
			local clen = tonumber(headers["content-length"]) or 0

			if clen < 0 or clen > M.MAXBODYIN then
				return nil, 413
			end
			-- accumulate in a table rather than by concatenation:
			-- `body = body .. data` is a fresh copy of everything
			-- per 4KB chunk, so a large body cost quadratic time
			-- and garbage on top of the memory it was already
			-- costing.
			local body = buf:sub(headerend + 4)
			local bparts, blen = { body }, #body

			while blen < clen do
				local data = tcp.recv(conn, 4096)
				if not data then
					break
				end
				bparts[#bparts + 1] = data
				blen = blen + #data
			end
			return { method = method, path = path,
			    version = version, headers = headers,
			    body = table.concat(bparts):sub(1, clen) }
		end
		if buflen > M.MAXHEADERS then
			-- headers that never end. 431 is the honest code and
			-- the connection is closed either way.
			return nil, 431
		end
		local data = tcp.recv(conn, 4096)
		if not data then
			return nil, 400
		end
		parts[#parts + 1] = data
		buflen = buflen + #data
		buf = table.concat(parts)
	end
end

-- resp.body is a string, OR a table with :read(n) matching ns.lua's
-- Chan -- "" at eof, nil on error -- so an ns:open() result is a body
-- with no adapter. a streaming body must carry resp.length, because
-- there is no #body once the whole thing is never in memory at once;
-- ns:stat(path).size is the usual source.
local function write_response(tcp, conn, resp)
	local status = resp.status or 200
	local body = resp.body or ""
	local streaming = type(body) == "table"
	local length = resp.length

	if not length then
		if streaming then
			error("http: streaming body requires resp.length")
		end
		length = #body
	end

	local lines = {
		"HTTP/1.1 " .. status .. " " ..
		    (STATUS_TEXT[status] or "OK"),
		"Content-Length: " .. length,
		"Connection: close",
	}
	-- Content-Length and Connection are ours to set: this server
	-- always closes and always knows the exact body length, and
	-- emitting a second copy of either is how response-smuggling
	-- ambiguity gets introduced.
	for k, v in pairs(resp.headers or {}) do
		local lk = k:lower()

		if lk ~= "content-length" and lk ~= "connection" then
			lines[#lines + 1] = k .. ": " .. v
		end
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = ""

	-- the body goes out in pieces because a tcp.send is ONE message to
	-- the tcp task, and the serializer refuses anything over MAXMSG
	-- (64KB). sending a larger body whole did not truncate it -- it
	-- raised "unserializable message", killed the connection
	-- coroutine, and handed the client nothing at all, which is a
	-- baffling way for a big page to fail.
	--
	-- this is NOT chunked transfer-encoding: Content-Length is still
	-- exact and the framing is unchanged. only the number of writes
	-- differs, which is invisible to the client.
	local head = table.concat(lines, "\r\n")

	if not tcp.send(conn, head) then
		return
	end

	if not streaming then
		local off = 1

		while off <= #body do
			local part = body:sub(off, off + M.WRITECHUNK - 1)

			if not tcp.send(conn, part) then
				return
			end
			off = off + #part
		end
		return
	end

	-- a short read or a read error leaves the promised Content-Length
	-- longer than what went out, which the peer cannot recover from --
	-- so raise rather than truncate silently. a failed SEND is
	-- different: the peer went away, which is not our error, so it
	-- returns quietly like the string path above.
	local sent = 0

	while sent < length do
		local chunk, rerr =
		    body:read(math.min(M.WRITECHUNK, length - sent))

		if not chunk then
			error("http: streaming body read failed: " ..
			    tostring(rerr))
		end
		if chunk == "" then
			error(string.format(
			    "http: streaming body ended early (%d/%d)",
			    sent, length))
		end
		if not tcp.send(conn, chunk) then
			return
		end
		sent = sent + #chunk
	end
end

-- the whole body runs under pcall, not just the handler: an error in
-- read_request or write_response would otherwise kill this coroutine
-- with the connection still open, leaking both a connid in the tcp
-- task's table and the efi child behind it, once per bad connection.
-- the close has to happen on every path out.
local function serve_conn(tcp, conn, handler)
	local req, status = read_request(tcp, conn)
	local resp

	if not req then
		resp = { status = status or 400,
		    body = (STATUS_TEXT[status] or "bad request") .. "\n" }
	else
		local ok, r = pcall(handler, req)

		if ok then
			resp = r or { status = 404, body = "not found" }
		else
			resp = { status = 500,
			    body = "internal error: " .. tostring(r) }
		end
	end
	-- a streaming body holds a Chan, and behind it an EFI file handle.
	-- write_response has no idea that is what it is holding, so this is
	-- the one place that both knows the contract and runs on every exit
	-- path, error or not.
	local wok, werr = pcall(write_response, tcp, conn, resp)

	if type(resp.body) == "table" and resp.body.close then
		pcall(resp.body.close, resp.body)
	end
	if not wok then
		error(werr)
	end
end

local function handle_conn(tcp, conn, handler)
	local ok, err = pcall(serve_conn, tcp, conn, handler)

	tcp.close(conn)
	if not ok then
		print("http: connection dropped: " .. tostring(err))
	end
end

-- blocks forever. returns nil, "reason" only if it can't even start
-- listening (e.g. DHCP never completed).
--
-- onready, if given, is called once the listener is actually up --
-- which is the only moment anything outside can know dhcp finished
-- and the port is accepting. there's no return value to check for
-- that otherwise, since this never returns on success.
function M.serve(tcp, port, handler, onready)
	local listener
	for _ = 1, LISTEN_ATTEMPTS do
		listener = tcp.listen(port)
		if listener then
			break
		end
		thread.sleep(LISTEN_RETRY_MS)	-- park, don't spin
	end
	if not listener then
		return nil, "listen failed"
	end
	if onready then
		onready(port)
	end

	thread.spawn(function()
		while true do
			local conn = tcp.accept(listener)
			if conn then
				thread.spawn(function()
					handle_conn(tcp, conn, handler)
				end)
			end
		end
	end)
	thread.run()
end

-- ---- static files ----
--
-- static(pns, root) -> a handler for M.serve, mapping req.path onto
-- files under `root` in the namespace `pns`. bodies STREAM: the response
-- body is the open Chan itself, closed by serve_conn once sent, so
-- serving a file never holds it in memory.
--
-- traversal safety: req.path is cleaned ALONE, as its own rooted path,
-- before it is joined to `root`. cleaning the two already joined is the
-- classic bug -- "/root/../.." cleans to "/" and escapes -- because
-- clean() only refuses to climb past the first slash it sees. cleaned in
-- isolation, the leading "/" it starts from is root's, so ".." can never
-- climb above root itself.
function M.static(pns, root)
	root = root or "/"
	if root ~= "/" then
		root = root:gsub("/+$", "")
	end

	return function(req)
		if req.method ~= "GET" and req.method ~= "HEAD" then
			return { status = 405, body = "method not allowed" }
		end

		local reqpath = req.path:match("^[^?]*")
		local cleaned = ns.clean(reqpath)
		local path = root == "/" and cleaned or (root .. cleaned)
		local st = pns:stat(path)

		if not st or st.dir then
			return { status = 404, body = "not found" }
		end

		local headers = {
			["Content-Type"] = MIME_TYPES[path:match("%.([%w]+)$")]
			    or DEFAULT_MIME,
		}

		if req.method == "HEAD" then
			return { status = 200, length = st.size,
			    headers = headers }
		end

		local f, ferr = pns:open(path, "r")

		if not f then
			return { status = 404,
			    body = "not found: " .. tostring(ferr) }
		end
		return { status = 200, body = f, length = st.size,
		    headers = headers }
	end
end

return M
