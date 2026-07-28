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
-- v1 scope: HTTP/1.1, Connection: close (no keep-alive), no chunked
-- transfer-encoding (M.get reads until the peer closes, same as
-- curl -0 would; the server side reads exactly Content-Length bytes
-- of request body -- see read_request). no https. M.get itself only
-- ever issues GET, but M.serve's request parsing is method-agnostic
-- (POST bodies work, for lib/mcp.lua's JSON-RPC traffic).

local thread = require("los.thread")

local M = {}

local function parse_url(url)
	local host, port, path =
	    url:match("^https?://([^:/]+):?(%d*)(/?.*)$")
	if not host then
		return nil, "bad url"
	end
	port = tonumber(port) or 80
	if path == "" then
		path = "/"
	end
	return host, port, path
end

local function parse_ip(ip)
	local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then
		return nil
	end
	return tonumber(a), tonumber(b), tonumber(c), tonumber(d)
end

-- responses are read until the peer closes, so without a ceiling a
-- large (or endless) response just grows until the proc hits its
-- mem_limit and dies. callers who genuinely want more can raise it.
M.MAXBODY = 1024 * 1024

-- returns {status=, headers=, body=} or nil, "reason"
function M.get(tcp, dns, url)
	local host, port, path = parse_url(url)
	if not host then
		return nil, "bad url"
	end

	-- a dotted quad needs no resolver, and asking one to resolve
	-- "1.2.3.4" just fails.
	local a, b, c, d = parse_ip(host)

	if not a then
		if not dns then
			return nil, "no resolver, and host is not an ip: " .. host
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

	local conn = tcp.dial(a, b, c, d, port)
	if not conn then
		return nil, "connect failed"
	end

	local req = table.concat({
		"GET " .. path .. " HTTP/1.1",
		"Host: " .. host,
		"User-Agent: lua-os",
		"Connection: close",
		"", "",
	}, "\r\n")
	if not tcp.send(conn, req) then
		tcp.close(conn)
		return nil, "send failed"
	end

	local chunks = {}
	local total = 0
	local truncated = false

	while true do
		local data = tcp.recv(conn, 4096)
		if not data then
			break
		end
		chunks[#chunks + 1] = data
		total = total + #data
		if total > M.MAXBODY then
			truncated = true
			break
		end
	end
	tcp.close(conn)
	if truncated then
		return nil, "response exceeds MAXBODY (" .. M.MAXBODY .. ")"
	end

	local raw = table.concat(chunks)
	local statusline, headerblock, body =
	    raw:match("^(.-)\r\n(.-)\r\n\r\n(.*)$")
	if not statusline then
		return nil, "malformed response"
	end
	local status = tonumber(statusline:match(" (%d%d%d) "))
	local headers = {}
	for k, v in headerblock:gmatch("([^:\r\n]+):[ \t]*([^\r\n]*)") do
		headers[k:lower()] = v
	end

	return { status = status, headers = headers, body = body }
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

-- Configure() self-triggers dhcp but doesn't block for it, so a
-- listen right after boot fails with EFI_NO_MAPPING until a lease
-- lands. cycle counts, not seconds -- sys.ticks() is a raw TSC read.
local LISTEN_ATTEMPTS = 60
local LISTEN_RETRY_CYCLES = 1000000000

local STATUS_TEXT = {
	[200] = "OK", [201] = "Created", [204] = "No Content",
	[301] = "Moved Permanently", [302] = "Found",
	[400] = "Bad Request", [403] = "Forbidden", [404] = "Not Found",
	[405] = "Method Not Allowed", [500] = "Internal Server Error",
}

-- parses the request line + headers, then reads exactly
-- Content-Length bytes of body if present (0 otherwise -- fine for
-- GET, needed for POST). no chunked transfer-encoding on requests,
-- matching the same limitation M.get accepts on responses.
local function read_request(tcp, conn)
	local buf = ""

	while true do
		local headerend = buf:find("\r\n\r\n", 1, true)
		if headerend then
			local requestline, headerblock =
			    buf:match("^(.-)\r\n(.-)\r\n\r\n")
			local method, path, version =
			    requestline:match("^(%u+) (%S+) (HTTP/%d%.%d)$")
			if not method then
				return nil
			end
			local headers = {}
			for k, v in
			    headerblock:gmatch("([^:\r\n]+):[ \t]*([^\r\n]*)") do
				headers[k:lower()] = v
			end
			local body = buf:sub(headerend + 4)
			local clen = tonumber(headers["content-length"]) or 0

			while #body < clen do
				local data = tcp.recv(conn, 4096)
				if not data then
					break
				end
				body = body .. data
			end
			return { method = method, path = path,
			    version = version, headers = headers,
			    body = body:sub(1, clen) }
		end
		local data = tcp.recv(conn, 4096)
		if not data then
			return nil
		end
		buf = buf .. data
	end
end

local function write_response(tcp, conn, resp)
	local status = resp.status or 200
	local body = resp.body or ""
	local lines = {
		"HTTP/1.1 " .. status .. " " ..
		    (STATUS_TEXT[status] or "OK"),
		"Content-Length: " .. #body,
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
	tcp.send(conn, table.concat(lines, "\r\n") .. body)
end

-- the whole body runs under pcall, not just the handler: an error in
-- read_request or write_response would otherwise kill this coroutine
-- with the connection still open, leaking both a connid in the tcp
-- task's table and the efi child behind it, once per bad connection.
-- the close has to happen on every path out.
local function serve_conn(tcp, conn, handler)
	local req = read_request(tcp, conn)
	local resp

	if not req then
		resp = { status = 400, body = "bad request" }
	else
		local ok, r = pcall(handler, req)

		if ok then
			resp = r or { status = 404, body = "not found" }
		else
			resp = { status = 500,
			    body = "internal error: " .. tostring(r) }
		end
	end
	write_response(tcp, conn, resp)
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
	local function spin(cycles)
		local sys = require("los.sys")
		local t0 = sys.ticks()
		while sys.ticks() - t0 < cycles do
			sys.yield()
		end
	end

	local listener
	for _ = 1, LISTEN_ATTEMPTS do
		listener = tcp.listen(port)
		if listener then
			break
		end
		spin(LISTEN_RETRY_CYCLES)
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

return M
