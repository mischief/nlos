-- Gemini (gemini://, port 1965): the client half, and gemtext.
--
-- Sans-io: nothing here dials, reads or knows what a socket is. A
-- caller sends what M.request builds and feeds the reply to M.response.
-- The protocol carries no length, so the peer's close IS the
-- terminator: a truncated page reads as a whole one at this layer.

local M = {}

M.PORT = 1965
-- the request line, CRLF included, and the meta string on its own
M.MAXURL = 1024
M.MAXMETA = 1024

-- the status classes, which are the whole of the reply's meaning. Only
-- SUCCESS carries a body; for the rest the meta says what to do -- a
-- prompt, a URL to go to, or why not.
M.INPUT, M.SUCCESS, M.REDIRECT = 1, 2, 3
M.TEMPFAIL, M.PERMFAIL, M.CERTREQ = 4, 5, 6

function M.class(status)
	return status // 10
end

-- ---- percent encoding ----

function M.escape(s)
	return (s:gsub("[^%w%-%._~]", function(c)
		return string.format("%%%02X", c:byte())
	end))
end

function M.unescape(s)
	return (s:gsub("%%(%x%x)", function(h)
		return string.char(tonumber(h, 16))
	end))
end

-- ---- URLs ----

-- RFC 3986's five parts, each absent rather than empty when it is not
-- there: an authority of "" and no authority at all resolve
-- differently, and a query of "" is a search that found nothing.
local function split(s)
	local t = {}
	local rest = s
	local i = rest:find("#", 1, true)

	if i then
		t.fragment = rest:sub(i + 1)
		rest = rest:sub(1, i - 1)
	end
	i = rest:find("?", 1, true)
	if i then
		t.query = rest:sub(i + 1)
		rest = rest:sub(1, i - 1)
	end

	local scheme, afterscheme = rest:match("^(%a[%w+.%-]*):(.*)$")

	if scheme then
		t.scheme = scheme:lower()
		rest = afterscheme
	end

	local auth, afterauth = rest:match("^//([^/?#]*)(.*)$")

	if auth then
		t.authority = auth
		rest = afterauth
	end
	t.path = rest
	return t
end

local function recompose(t)
	local s = t.scheme and (t.scheme .. ":") or ""

	if t.authority then
		s = s .. "//" .. t.authority
	end
	s = s .. (t.path or "")
	if t.query then
		s = s .. "?" .. t.query
	end
	if t.fragment then
		s = s .. "#" .. t.fragment
	end
	return s
end

-- RFC 3986 5.2.4. A trailing slash survives a "." or ".." that ends the
-- path, because "/a/.." names the directory and not the file beside it.
local function dotseg(p)
	local out = {}
	local abs = p:sub(1, 1) == "/"
	local trail = p:sub(-1) == "/" or p:match("/%.%.?$") ~= nil
	    or p == "." or p == ".."

	for seg in p:gmatch("[^/]+") do
		if seg == ".." then
			if #out > 0 then
				table.remove(out)
			end
		elseif seg ~= "." then
			out[#out + 1] = seg
		end
	end

	local s = table.concat(out, "/")

	if abs then
		s = "/" .. s
	end
	if trail and #out > 0 then
		s = s .. "/"
	end
	return s
end

local function merge(base, p)
	if base.authority and base.path == "" then
		return "/" .. p
	end
	return (base.path:gsub("[^/]*$", "")) .. p
end

-- RFC 3986 5.2.2: what a link on a page means, given the page it is
-- on. Every gemtext link is relative until proven otherwise, so this
-- is on the path of every click.
function M.resolve(base, ref)
	local B, R = split(base), split(ref)
	local T = {}

	if R.scheme then
		T.scheme, T.authority = R.scheme, R.authority
		T.path, T.query = dotseg(R.path), R.query
	else
		T.scheme = B.scheme
		if R.authority then
			T.authority = R.authority
			T.path, T.query = dotseg(R.path), R.query
		else
			T.authority = B.authority
			if R.path == "" then
				T.path = B.path
				T.query = R.query or B.query
			else
				if R.path:sub(1, 1) == "/" then
					T.path = dotseg(R.path)
				else
					T.path = dotseg(merge(B, R.path))
				end
				T.query = R.query
			end
		end
	end
	T.fragment = R.fragment
	return recompose(T)
end

-- a gemini URL, in the pieces a dial needs. base makes it the answer
-- to "what does this link point at", which is the same parse.
function M.url(s, base)
	if type(s) ~= "string" then
		return nil, "url is not a string"
	end
	if base then
		s = M.resolve(base, s)
	end

	local t = split(s)

	if not t.scheme then
		return nil, "no scheme"
	end
	if t.scheme ~= "gemini" then
		return nil, "not a gemini url: " .. t.scheme
	end
	if not t.authority or t.authority == "" then
		return nil, "no host"
	end
	-- gemini has no userinfo. A URL carrying one is either a mistake
	-- or an attempt to make the host read as something it is not.
	if t.authority:find("@", 1, true) then
		return nil, "userinfo is not allowed"
	end

	local host, port = t.authority:match("^%[(.-)%]:?(%d*)$")

	if not host then
		host, port = t.authority:match("^([^:]*):?(%d*)$")
	end
	if not host or host == "" then
		return nil, "no host"
	end

	local u = {
		scheme = "gemini",
		host = host:lower(),
		port = tonumber(port) or M.PORT,
		path = t.path ~= "" and t.path or "/",
		query = t.query,
	}

	u.url = M.formaturl(u)
	return u
end

-- what goes on the wire: no fragment, and the default port left off,
-- so two spellings of one page are one string.
function M.formaturl(u)
	local host = u.host:find(":", 1, true) and ("[" .. u.host .. "]")
	    or u.host
	local s = "gemini://" .. host

	if u.port and u.port ~= M.PORT then
		s = s .. ":" .. u.port
	end
	s = s .. (u.path ~= "" and u.path or "/")
	if u.query then
		s = s .. "?" .. u.query
	end
	return s
end

-- the whole of what a client sends. u is a URL string or a parsed one.
function M.request(u)
	local s

	if type(u) == "table" then
		s = M.formaturl(u)
	else
		local parsed, err = M.url(u)

		if not parsed then
			return nil, err
		end
		s = parsed.url
	end
	if #s + 2 > M.MAXURL then
		return nil, "url too long"
	end
	return s .. "\r\n"
end

-- the answer to a 1x prompt, as the URL that carries it: the reply to
-- a question is a fresh request for the same page with a query on it.
function M.answer(u, text)
	local parsed = type(u) == "table" and u or M.url(u)

	if not parsed then
		return nil, "bad url"
	end
	return M.request({ host = parsed.host, port = parsed.port,
	    path = parsed.path, query = M.escape(text) })
end

-- ---- the reply ----

local Resp = {}

Resp.__index = Resp

-- opts.sink(chunk) takes the body as it arrives; without one the body
-- is held and Resp:take() hands it over.
function M.response(opts)
	opts = opts or {}
	return setmetatable({
		buf = "",
		body = {},
		sink = opts.sink,
		nbody = 0,
	}, Resp)
end

local function fail(r, err)
	r.err = err
	return nil, err
end

local function header(r)
	local i = r.buf:find("\r\n", 1, true)

	if not i then
		-- a header that never ends is a peer talking to the wrong
		-- protocol, and the bound is what stops it filling memory
		if #r.buf > M.MAXMETA + 16 then
			return fail(r, "no header in the first "
			    .. #r.buf .. " bytes")
		end
		return true
	end

	local head = r.buf:sub(1, i - 1)
	local rest = r.buf:sub(i + 2)
	local st, meta = head:match("^(%d%d)%s?(.*)$")

	if not st then
		return fail(r, "malformed header")
	end
	if #meta > M.MAXMETA then
		return fail(r, "meta too long")
	end
	r.status = tonumber(st)
	r.meta = meta
	r.header = head
	r.buf = ""
	return rest
end

function Resp:feed(data)
	if self.err then
		return nil, self.err
	end
	if not self.status then
		self.buf = self.buf .. data

		local rest, err = header(self)

		if not rest then
			return nil, err
		end
		if rest == true then
			return true
		end
		data = rest
	end
	if data ~= "" then
		self.nbody = self.nbody + #data
		if self.sink then
			self.sink(data)
		else
			self.body[#self.body + 1] = data
		end
	end
	return true
end

-- the peer closed. Whether that is the end of the page or the middle
-- of it is not answerable here, so it is only ever the end of what
-- arrived.
function Resp:eof()
	if self.err then
		return nil, self.err
	end
	if not self.status then
		return fail(self, "closed before a header")
	end
	self.done = true
	return true
end

function Resp:take()
	local s = table.concat(self.body)

	self.body = {}
	return s
end

-- the meta of a 2x reply is a MIME type. An empty one is gemtext,
-- which is what the spec says a server may leave unsaid.
function M.mime(meta)
	local t = (meta or ""):match("^%s*([^;%s]*)")
	local params = {}

	if t == "" then
		t = "text/gemini"
	end
	for k, v in (meta or ""):gmatch(";%s*([%w%-]+)%s*=%s*([^;%s]+)") do
		params[k:lower()] = v:gsub('^"(.*)"$', "%1")
	end
	return t:lower(), params
end

function M.isgemtext(meta)
	return M.mime(meta) == "text/gemini"
end

-- ---- gemtext ----

-- Line-oriented and nothing else: there is no inline markup, so a line
-- is one node and no line changes what another means. The exception is
-- the ``` toggle, which is why this is a machine and not a match.
local Gem = {}

Gem.__index = Gem

function M.gemtext()
	return setmetatable({ buf = "", pre = false, out = {}, head = 1 },
	    Gem)
end

local function line2node(line, pre)
	if pre then
		return { kind = "pre", text = line }
	end

	local hashes, htext = line:match("^(#+)%s*(.*)$")

	if hashes then
		local level = #hashes

		return { kind = "head", level = level > 3 and 3 or level,
		    text = htext }
	end

	local rest = line:match("^=>%s*(.*)$")

	if rest then
		local url = rest:match("^(%S+)")

		if not url then
			return { kind = "text", text = "" }
		end
		return { kind = "link", url = url,
		    label = rest:sub(#url + 1):match("^%s*(.-)%s*$") }
	end

	local item = line:match("^%*%s(.*)$")

	if item then
		return { kind = "item", text = item }
	end

	local quote = line:match("^>%s*(.*)$")

	if quote then
		return { kind = "quote", text = quote }
	end
	return { kind = "text", text = line }
end

local function push(g, line)
	line = line:gsub("\r$", "")

	local alt = line:match("^```(.*)$")

	if alt then
		g.pre = not g.pre
		g.out[#g.out + 1] = g.pre
		    and { kind = "prebegin", alt = alt }
		    or { kind = "preend" }
		return
	end
	g.out[#g.out + 1] = line2node(line, g.pre)
end

function Gem:feed(s)
	self.buf = self.buf .. s

	local from = 1

	while true do
		local i = self.buf:find("\n", from, true)

		if not i then
			break
		end
		push(self, self.buf:sub(from, i - 1))
		from = i + 1
	end
	self.buf = self.buf:sub(from)
end

-- a page whose last line has no newline still has that line
function Gem:eof()
	if self.buf ~= "" then
		push(self, self.buf)
		self.buf = ""
	end
	self.done = true
end

function Gem:next()
	local n = self.out[self.head]

	if n == nil then
		return nil
	end
	self.out[self.head] = nil
	self.head = self.head + 1
	return n
end

-- the whole document at once, for a caller that already holds it all
function M.parse(text)
	local g = M.gemtext()
	local nodes = {}

	g:feed(text)
	g:eof()
	for n in function() return g:next() end do
		nodes[#nodes + 1] = n
	end
	return nodes
end

-- ---- laying it out ----

local PREFIX = {
	head = { [1] = "", [2] = "  ", [3] = "    " },
	item = "* ",
	quote = "> ",
}

-- a column is a codepoint, not a byte: gemini is utf-8 and a page of
-- it wraps by what a reader sees. Text that is not valid utf-8 falls
-- back to bytes rather than refusing to lay out.
local function wlen(s)
	return utf8.len(s) or #s
end

local function wsub(s, i, j)
	local a = utf8.offset(s, i)
	local b = j and utf8.offset(s, j + 1)

	if not a then
		return s:sub(i, j)
	end
	return s:sub(a, b and b - 1 or nil)
end

local function fold(text, width, first, cont, emit)
	if width < 4 then
		width = 4
	end
	if text == "" then
		emit(first, true)
		return
	end

	local pre, room = first, width - wlen(first)
	local out = ""

	for word in text:gmatch("%S+") do
		if out == "" then
			out = word
		elseif wlen(out) + 1 + wlen(word) <= room then
			out = out .. " " .. word
		else
			emit(pre .. out, false)
			pre, room, out = cont, width - wlen(cont), word
		end
		-- a word longer than the line is broken rather than left
		-- to run off the edge, since nothing below can wrap it
		while wlen(out) > room do
			emit(pre .. wsub(out, 1, room), false)
			out = wsub(out, room + 1)
			pre, room = cont, width - wlen(cont)
		end
	end
	if out ~= "" then
		emit(pre .. out, false)
	end
end

-- nodes to display lines, each carrying what it came from: a line of a
-- link knows the link, which is what makes a click or a typed number
-- mean something. Preformatted lines are handed over as they are --
-- wrapping them would be wrapping the picture they draw.
--
-- opts.number puts [n] on a link, counting from 1 across the page.
function M.wrap(nodes, cols, opts)
	opts = opts or {}

	local lines = {}
	local nlink = 0

	for i = 1, #nodes do
		local n = nodes[i]
		local function emit(text, blank)
			lines[#lines + 1] = { text = text, kind = n.kind,
			    node = i, url = n.url, link = n.linkno,
			    level = n.level, blank = blank or nil }
		end

		if n.kind == "pre" then
			emit(n.text)
		elseif n.kind == "prebegin" or n.kind == "preend" then
			if opts.showalt and n.alt and n.alt ~= "" then
				emit(n.alt)
			end
		elseif n.kind == "link" then
			nlink = nlink + 1
			n.linkno = nlink

			local label = n.label ~= "" and n.label or n.url
			local mark = opts.number
			    and string.format("[%d] ", nlink) or "=> "

			fold(label, cols, mark, string.rep(" ", #mark), emit)
		elseif n.kind == "head" then
			fold(n.text, cols, PREFIX.head[n.level],
			    PREFIX.head[n.level], emit)
		elseif n.kind == "item" then
			fold(n.text, cols, PREFIX.item, "  ", emit)
		elseif n.kind == "quote" then
			fold(n.text, cols, PREFIX.quote, PREFIX.quote, emit)
		else
			fold(n.text, cols, "", "", emit)
		end
	end
	return lines
end

-- ---- sugar for a caller that does have a connection ----
--
-- Not part of the machine above, the way zmodem's drive() is not: this
-- is the loop a caller holding a dial/send/recv/close writes anyway.

-- what a client follows before it decides the server is going in
-- circles. The spec's own number.
M.MAXREDIRECT = 5

local function parseip(s)
	local a, b, c, d = s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")

	if not a then
		return nil
	end
	return tonumber(a), tonumber(b), tonumber(c), tonumber(d)
end

local function dial(tcp, dns, u, opts)
	local ok, tlstcp = pcall(require, "tlstcp")

	if not ok then
		return nil, "no tls on this machine: " .. tostring(tlstcp)
	end
	if not opts.rand then
		return nil, "tls needs entropy, and this caller was lent none"
	end

	-- gemini is TLS always, and trust is the caller's to decide: pass
	-- a verify, or take first-use, which without a store is every use.
	local t = tlstcp.new(tcp, {
		rand = opts.rand,
		insecure = opts.insecure,
		verify = opts.verify or (not opts.insecure and
		    tlstcp.tofu(u.host, opts.onkey) or nil),
	})
	local a, b, c, d = parseip(u.host)
	local named = a == nil

	if not a then
		if not dns then
			return nil, "no resolver, and host is not an ip: "
			    .. u.host
		end

		local ip = dns.resolve(u.host)

		if not ip then
			return nil, "cannot resolve " .. u.host
		end
		a, b, c, d = parseip(ip)
		if not a then
			return nil, "resolver returned junk: " .. tostring(ip)
		end
	end

	local sock, err = t.dial(a, b, c, d, u.port, named and u.host or nil)

	if not sock then
		return nil, err or "connect failed"
	end
	return t, sock
end

-- one request, no redirects. The reply is a table: status, meta, url,
-- and the body unless opts.sink took it.
function M.request_once(tcp, dns, url, opts)
	opts = opts or {}

	local u, uerr = M.url(url)

	if not u then
		return nil, uerr
	end

	local line, lerr = M.request(u)

	if not line then
		return nil, lerr
	end

	local t, sock = dial(tcp, dns, u, opts)

	if not t then
		return nil, sock
	end

	-- a sink is for the page, not for the one-line body a failure or a
	-- redirect may still carry, so the status decides where bytes go.
	-- Declared before it is built: the closure names it.
	local r

	r = M.response({ sink = opts.sink and function(part)
		if M.class(r.status) == M.SUCCESS then
			opts.sink(part)
		else
			r.body[#r.body + 1] = part
		end
	end or nil })

	if not t.send(sock, line) then
		t.close(sock)
		return nil, "send failed"
	end

	while true do
		local part, rerr = t.recv(sock)

		if not part then
			if rerr then
				t.close(sock)
				return nil, rerr
			end
			break
		end

		local fed, ferr = r:feed(part)

		if not fed then
			t.close(sock)
			return nil, ferr
		end
	end
	t.close(sock)

	local done, derr = r:eof()

	if not done then
		return nil, derr
	end
	r.url = u.url
	return r
end

-- and the same, following redirects the way every client does. Each
-- hop is resolved against the one before it, so a server may move a
-- page with a relative meta. opts.onredirect(from, to, status) is told.
function M.fetch(tcp, dns, url, opts)
	opts = opts or {}

	local max = opts.maxredirect or M.MAXREDIRECT
	local at = url

	for _ = 0, max do
		local r, err = M.request_once(tcp, dns, at, opts)

		if not r then
			return nil, err
		end
		if M.class(r.status) ~= M.REDIRECT then
			return r
		end
		if r.meta == "" then
			return nil, "redirect to nowhere"
		end

		local to = M.resolve(r.url, r.meta)

		if opts.onredirect then
			opts.onredirect(r.url, to, r.status)
		end
		at = to
	end
	return nil, "more than " .. max .. " redirects"
end

return M
