-- hosthttp.lua: a minimal HTTP/1.1 client for the host-driven tests,
-- built on hostutil's raw connect_tcp/send/recv.
--
-- deliberately NOT lib/http.lua reused from the guest side: that
-- module is tied to the guest's coroutine-yielding tcp capability
-- object, and reusing the same client code the guest uses to test the
-- guest would quietly weaken the property these tests exist for
-- (test_web.lua's own docstring: "the only cover for the full chain,"
-- independent of guest-side code). this is a second, smaller,
-- independent implementation instead -- Connection: close only, no
-- chunked transfer-encoding, no keep-alive, matching what
-- lib/http.lua's server side actually sends.

local M = {}

local function readline(hostutil, fd, timeout, buf)
	while true do
		local nl = buf.data:find("\n", 1, true)
		if nl then
			local line = buf.data:sub(1, nl - 1):gsub("\r$", "")
			buf.data = buf.data:sub(nl + 1)
			return line
		end
		local chunk, err = hostutil.recv(fd, 65536, timeout)
		if not chunk then
			return nil, err
		end
		if chunk == "" then
			return nil, "eof"
		end
		buf.data = buf.data .. chunk
	end
end

-- request(hostutil, host, port, method, path, body, headers, timeout)
-- -> {status, headers, body} or nil, err
function M.request(hostutil, host, port, method, path, body, headers, timeout)
	timeout = timeout or 20

	local fd, cerr = hostutil.connect_tcp(host, port)
	if not fd then
		return nil, cerr
	end

	local hlines = { "Host: " .. host, "Connection: close" }
	local has_cl = false

	for k, v in pairs(headers or {}) do
		hlines[#hlines + 1] = k .. ": " .. v
		if k:lower() == "content-length" then
			has_cl = true
		end
	end
	-- callers may deliberately pass a fake Content-Length to test a
	-- server's handling of one (test_http.lua's oversized-body case);
	-- never silently overwrite it with the real length.
	if body and not has_cl then
		hlines[#hlines + 1] = "Content-Length: " .. #body
	end

	local req = method .. " " .. path .. " HTTP/1.1\r\n" ..
	    table.concat(hlines, "\r\n") .. "\r\n\r\n" .. (body or "")

	local ok, serr = hostutil.send(fd, req)
	if not ok then
		hostutil.close(fd)
		return nil, serr
	end

	local buf = { data = "" }
	local statusline, serr2 = readline(hostutil, fd, timeout, buf)
	if not statusline then
		hostutil.close(fd)
		return nil, serr2
	end
	local status = tonumber(statusline:match(" (%d%d%d) ")) or
	    tonumber(statusline:match(" (%d%d%d)$"))

	local resphdrs = {}
	while true do
		local line, herr = readline(hostutil, fd, timeout, buf)
		if not line then
			hostutil.close(fd)
			return nil, herr
		end
		if line == "" then
			break
		end
		local k, v = line:match("^([^:]+):%s*(.*)$")
		if k then
			resphdrs[k:lower()] = v
		end
	end

	local respbody
	local cl = tonumber(resphdrs["content-length"])

	if cl then
		respbody = buf.data
		while #respbody < cl do
			local chunk, rerr = hostutil.recv(fd, cl - #respbody, timeout)
			if not chunk then
				hostutil.close(fd)
				return nil, rerr
			end
			if chunk == "" then
				break
			end
			respbody = respbody .. chunk
		end
		respbody = respbody:sub(1, cl)
	else
		respbody = buf.data
		while true do
			local chunk = hostutil.recv(fd, 65536, timeout)
			if not chunk or chunk == "" then
				break
			end
			respbody = respbody .. chunk
		end
	end

	hostutil.close(fd)
	return { status = status, headers = resphdrs, body = respbody }
end

function M.get(hostutil, host, port, path, timeout)
	return M.request(hostutil, host, port, "GET", path, nil, nil, timeout)
end

function M.post(hostutil, host, port, path, body, headers, timeout)
	return M.request(hostutil, host, port, "POST", path, body or "", headers, timeout)
end

return M
