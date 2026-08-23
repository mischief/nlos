-- web: a page fetched and turned into blocks a panel can draw.

-- The io half over lib/http.lua and lib/html.lua, the way gemini's
-- M.fetch is over its own. What it adds is the two bounds a page from
-- anywhere needs, and following a redirect, which lib/http.lua does
-- not do for itself.

-- lib/http.lua wants los.thread, which a host has none of. Required
-- where it is used, so the parsing and the bounds here are testable
-- off the machine.
local html = require("html")
local url = require("url")

local M = {}

-- The bytes are not held, so this is only the point at which a page
-- stops being one: a stream that never ends, or one nothing here could
-- read anyway. lib/html.lua's block count is the bound that decides
-- what a page actually costs.
M.MAXBYTES = 2 * 1024 * 1024

M.MAXREDIRECT = 5

local REDIRECT = { [301] = true, [302] = true, [303] = true,
    [307] = true, [308] = true }

-- A sink that keeps what arrives and stops at max. Refusing the body
-- is how a sink says stop, and lib/http.lua turns that into an error --
-- so a caller must ask s.cut before believing the failure.
function M.capsink(max)
	local s = { parts = {}, n = 0, cut = false }

	function s.sink(part)
		if s.cut then
			return false
		end
		if s.n + #part > max then
			s.parts[#s.parts + 1] = part:sub(1, max - s.n)
			s.n = max
			s.cut = true
			return false
		end
		s.n = s.n + #part
		s.parts[#s.parts + 1] = part
		return true
	end

	function s.take()
		local body = table.concat(s.parts)

		s.parts = {}
		return body
	end
	return s
end


-- One request, no redirects, and no page held: the body goes into a
-- parser as it arrives and what comes back is blocks. res.truncated
-- says a bound stopped it early.
function M.get(net, dns, page, opts)
	opts = opts or {}

	local status, headers
	local parser, cap, cut, stopped = nil, nil, nil, false
	local n = 0
	local maxbytes = opts.maxbytes or M.MAXBYTES
	local t = url.split(page)
	local verify = opts.verify

	-- https with no verifier of the caller's own: trust on first use,
	-- which without a store is every use. opts.onkey is told what was
	-- accepted, and opts.insecure skips even that.
	if t.scheme == "https" and not verify and not opts.insecure then
		local ok, tlstcp = pcall(require, "tlstcp")

		if not ok then
			return nil, "no tls on this machine"
		end
		verify = tlstcp.tofu((t.authority or ""):gsub(":%d+$", ""),
		    opts.onkey)
	end

	local res, err = require("http").get(net, dns, page, {
		rand = opts.rand,
		insecure = opts.insecure,
		verify = verify,
		-- the type arrives before the body does, which is what
		-- lets the bytes go straight where they belong
		onhead = function(st, h)
			local mime = M.mime(h)

			status, headers = st, h
			if REDIRECT[st] then
				return
			end
			if mime == "text/html"
			    or mime == "application/xhtml+xml" then
				parser = html.parser({
					base = page,
					nochrome = opts.nochrome,
					main = opts.main,
					maxtext = opts.maxtext,
					maxblocks = opts.maxblocks,
				})
			elseif mime:match("^text/") then
				cap = M.capsink(maxbytes)
			end
		end,
		sink = function(part)
			n = n + #part
			if n > maxbytes then
				cut = "bytes"
				return false
			end
			if parser then
				-- the parser stops for two reasons: it hit
				-- the bound, or it has the whole article and
				-- the rest of the page is not wanted
				if not parser:feed(part) then
					stopped = true
					cut = parser.info.truncated
					return false
				end
				return true
			end
			if cap then
				return cap.sink(part)
			end
			return true
		end,
	})

	if not res and not cut and not stopped then
		return nil, err
	end

	local blocks, info

	if parser then
		blocks, info = parser:eof()
	elseif cap then
		local d = require("doc")

		blocks, info = { d.run(d.block("pre"), cap.take()) }, {}
	end
	info = info or {}
	info.truncated = info.truncated or cut
	return {
		status = status or (res and res.status),
		headers = headers or (res and res.headers) or {},
		blocks = blocks,
		info = info,
		nbytes = n,
		truncated = info.truncated,
		url = page,
	}
end

-- and the same, following redirects. opts.onredirect(from, to, status).
function M.fetch(net, dns, page, opts)
	opts = opts or {}

	local max = opts.maxredirect or M.MAXREDIRECT
	local at = page

	for _ = 0, max do
		local res, err = M.get(net, dns, at, opts)

		if not res then
			return nil, err
		end
		if not REDIRECT[res.status] then
			return res
		end

		local to = res.headers.location

		if not to or to == "" then
			return nil, "redirect with no location"
		end
		to = url.resolve(at, to)
		if opts.onredirect then
			opts.onredirect(at, to, res.status)
		end
		at = to
	end
	return nil, "more than " .. max .. " redirects"
end

-- the type, without its parameters
function M.mime(headers)
	local ct = (headers or {})["content-type"] or "text/html"

	return (ct:match("^%s*([^;%s]*)") or ""):lower()
end


return M
