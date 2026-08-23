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

-- What a page may cost, in the two units that matter: bytes bound the
-- read, and lib/html.lua's block count bounds what those bytes expand
-- into. A page over this is read up to here and marked short, which is
-- truthful where a refusal would be unhelpful.
-- Measured: blocks and lines together come to about three times the
-- bytes they were made from, and the page is still held while they are
-- built. So this ceiling costs about four times itself at the peak.
M.MAXBYTES = 64 * 1024

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

-- one request, no redirects. res.truncated says a bound cut it.
function M.get(net, dns, page, opts)
	opts = opts or {}

	local cap = M.capsink(opts.maxbytes or M.MAXBYTES)
	local status, headers

	local res, err = require("http").get(net, dns, page, {
		rand = opts.rand,
		insecure = opts.insecure,
		verify = opts.verify,
		onhead = function(st, h)
			status, headers = st, h
		end,
		sink = cap.sink,
	})

	if not res and not cap.cut then
		return nil, err
	end
	return {
		status = status or (res and res.status),
		headers = headers or (res and res.headers) or {},
		body = cap.take(),
		nbody = cap.n,
		truncated = cap.cut and "bytes" or nil,
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

-- a fetched page as blocks. Text that is not html is its own
-- preformatted block, which is what makes a .txt readable in the same
-- viewer without a second path through it.
function M.blocks(res, opts)
	opts = opts or {}

	local mime = M.mime(res.headers)

	if mime == "text/html" or mime == "application/xhtml+xml" then
		local blocks, info = html.parse(res.body,
		    { base = res.url, maxblocks = opts.maxblocks })

		info.truncated = info.truncated or res.truncated
		return blocks, info
	end
	if mime:match("^text/") then
		local doc = require("doc")

		return { doc.run(doc.block("pre"), res.body) },
		    { truncated = res.truncated }
	end
	return nil, "not text: " .. mime
end

return M
