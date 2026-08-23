-- url: RFC 3986's five parts, and what a relative reference means
-- against the page it was found on.

-- Every hypertext protocol needs this and none of them differ in it,
-- so it is here rather than inside whichever one asked first. Nothing
-- about a scheme is known: gemini's own rules are lib/gemini.lua's.

local M = {}

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

-- absent rather than empty when a part is not there: an authority of
-- "" and no authority at all resolve differently, and a query of ""
-- is a search that found nothing.
function M.split(s)
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

function M.recompose(t)
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

-- RFC 3986 5.2.4. A trailing slash survives a "." or ".." that ends
-- the path, because "/a/.." names the directory and not the file
-- beside it.
function M.dotseg(p)
	local out = {}
	local abs = p:sub(1, 1) == "/"
	local trail = p:sub(-1) == "/" or p:match("/%.%.?$") ~= nil
	    or p == "." or p == ".."

	-- find rather than gmatch: this runs once for every link on a
	-- page, and a gmatch state is 608 bytes to walk a path with
	local i, n = 1, #p

	while i <= n do
		local sl = p:find("/", i, true)
		local seg = p:sub(i, (sl or n + 1) - 1)

		if seg == ".." then
			if #out > 0 then
				table.remove(out)
			end
		elseif seg ~= "." and seg ~= "" then
			out[#out + 1] = seg
		end
		i = (sl or n) + 1
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
-- on. On the path of every click, in every protocol here.
function M.resolve(base, ref)
	local B, R = M.split(base), M.split(ref)
	local T = {}

	if R.scheme then
		T.scheme, T.authority = R.scheme, R.authority
		T.path, T.query = M.dotseg(R.path), R.query
	else
		T.scheme = B.scheme
		if R.authority then
			T.authority = R.authority
			T.path, T.query = M.dotseg(R.path), R.query
		else
			T.authority = B.authority
			if R.path == "" then
				T.path = B.path
				T.query = R.query or B.query
			else
				if R.path:sub(1, 1) == "/" then
					T.path = M.dotseg(R.path)
				else
					T.path = M.dotseg(merge(B, R.path))
				end
				T.query = R.query
			end
		end
	end
	T.fragment = R.fragment
	return M.recompose(T)
end

return M
