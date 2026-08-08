-- TLS 1.3 on real hardware, with timings.
--
-- The protocol's own suite lives in the host-side ssh tree and runs
-- under busted. This asks what a boot can answer instead: does a
-- handshake complete here, does the C arithmetic the certificate path
-- needs agree with the Lua it replaces, and what does either cost on
-- this machine.
--
-- The peer is tls/server.lua wrapped in the record layer, so both ends
-- share a key schedule. That makes this a liveness check, not a
-- conformance one; interoperation is the host tree's business.

local tap = require("tap")
local sys = require("los.sys")

tap.plan(13)

local ok_rng, rng = pcall(require, "los.platform.rng")
tap.ok(ok_rng, "los.platform.rng present")
if not ok_rng then tap.done() return end

local conn = require("tls.conn")
local record = require("tls.record")
local tlsserver = require("tls.server")
local sha256 = require("crypto.sha256")
local p256 = require("crypto.p256")

local function ms(f)
	local t0 = sys.uptime_ms()
	local r = f()
	return sys.uptime_ms() - t0, r
end

local function unhex(s)
	return (s:gsub("%x%x", function(c) return string.char(tonumber(c, 16)) end))
end

local function rand(n)
	return rng.bytes(n)
end

-- The server half: one flight, then application data.
local function peer(cert)
	local s = tlsserver.new { seed = rand(32), cert = cert, rand = rand,
	    alpn = "sample" }
	local p = { tls = s, inbuf = "", inbox = {} }

	function p:reply(bytes)
		self.inbuf = self.inbuf .. bytes
		local out = {}

		while #self.inbuf >= record.HEADER_LEN do
			local ctype, len = record.parse_header(self.inbuf)
			if #self.inbuf < record.HEADER_LEN + len then break end
			local head = self.inbuf:sub(1, record.HEADER_LEN)
			local body = self.inbuf:sub(record.HEADER_LEN + 1,
			    record.HEADER_LEN + len)
			self.inbuf = self.inbuf:sub(record.HEADER_LEN + len + 1)

			if ctype == record.CHANGE_CIPHER_SPEC then     -- ignored
			elseif ctype == record.HANDSHAKE then
				local flights, _, err = self.tls:accept(body)
				assert(flights, err)
				self.rx = record.new(self.tls.c_hs)
				out[#out + 1] = record.plain(record.HANDSHAKE,
				    flights.initial)
				out[#out + 1] = record.plain(record.CHANGE_CIPHER_SPEC, "\1")
				out[#out + 1] = record.new(self.tls.s_hs)
				    :seal(record.HANDSHAKE, flights.handshake)
			else
				local plain, inner = self.rx:open(head, body)
				assert(plain, "server could not open a record")
				if inner == record.HANDSHAKE then
					local ok, _, err = self.tls:client_finished(plain)
					assert(ok, err)
					self.rx = record.new(self.tls.c_ap)
					self.tx = record.new(self.tls.s_ap)
				else
					self.inbox[#self.inbox + 1] = plain
				end
			end
		end

		return table.concat(out)
	end

	function p:write(data)
		return self.tx:seal(record.APPLICATION_DATA, data)
	end

	return p
end

local c = conn.new { rand = rand, server_name = "example.com",
    alpn = "sample", insecure = true }
local s = peer(("c"):rep(300))          -- opaque to both ends here

local t_hs = ms(function()
	local from_client = c:start()
	while #from_client > 0 do
		local to_client = s:reply(from_client)
		from_client = assert(c:recv(to_client))
	end
end)

tap.diag(string.format("handshake: %d ms", t_hs))
tap.ok(c.state == "established", "the handshake completes")
tap.ok(c.tls.c_ap == s.tls.c_ap and c.tls.s_ap == s.tls.s_ap,
    "both ends agree on the traffic secrets")
tap.ok(c.alpn == "sample", "alpn is negotiated")

-- Application data, each way.
local request = "GET / HTTP/1.0\r\n\r\n"
s:reply(c:write(request))
tap.ok(s.inbox[1] == request, "the server reads what the client wrote")

assert(c:recv(s:write("hello")))
tap.ok(c:read() == "hello", "the client reads what the server wrote")

-- 64KB through the record layer, which is where the AEAD cost shows. A
-- record holds at most 16KB of plaintext, so this arrives as several of
-- them and the peer's inbox has one entry each.
local body = ("x"):rep(65536)
local t_bulk = ms(function() return s:reply(c:write(body)) end)
tap.diag(string.format("64KB sealed and opened: %d ms (%.1f KB/s)", t_bulk,
    t_bulk > 0 and 65536 / t_bulk or 0))
tap.ok(table.concat(s.inbox, "", 2) == body, "64KB survives the record layer")

-- The certificate path's arithmetic. RFC 6979 A.2.5, SHA-256, "sample".
local key = "\4" .. unhex("60FED4BA255A9D31C961EB74C6356D68C049B8923B61FA6CE669622E60F29FB6")
    .. unhex("7903FE1008B8BC99A41AE9E95628BC64F2F1B20C2D7E9F5177A3C294D4462299")
local hash = sha256.hash("sample")
local r = unhex("EFD48B2AACB6A8FD1140DD9CD45E81D69D2C877B56AAF991C34D0EA84EAF3716")
local sg = unhex("F7CB1C942D657C41D436C7A1B6E29F65F3E900DBB9AFF4064DC4AB2F843ACDA8")

local t_p256, good = ms(function() return p256.verify(key, hash, r, sg) end)
tap.diag(string.format("p256 verify: %d ms", t_p256))
tap.ok(good, "p256 verifies its published vector")

-- The C verifier against the Lua one it displaces, over a good
-- signature and a bad one. Absent the C module the two are the same
-- table and this says nothing, which is why it reports which it ran.
if p256.native then
	local pure = p256.pure
	local bad = sg:sub(1, 31) .. string.char(sg:byte(32) ~ 1)
	local t_pure = ms(function() return pure.verify(key, hash, r, sg) end)
	tap.diag(string.format("p256 verify in lua: %d ms", t_pure))
	tap.ok(pure.verify(key, hash, r, sg) == true and
	    pure.verify(key, hash, r, bad) == p256.verify(key, hash, r, bad),
	    "the lua and c verifiers agree")
else
	tap.ok(false, "the native crypto module is missing")
end

-- ---- tofu: the signature check, and the algorithms it loads ----
--
-- tls/tofu.lua requires an implementation when a handshake names it,
-- rather than all of them at load. So the dispatch is what decides
-- whether a signature is checked at all, and a branch that loaded the
-- wrong module would refuse a good signature or, worse, take the
-- absence of a checker for a pass.
local tofu = require("tls.tofu")
local ed25519 = require("crypto.ed25519")

local seed = string.rep("\7", 32)
local pk = ed25519.publickey(seed)
local th = string.rep("\3", 32)
local CONTEXT = string.rep("\32", 64) ..
    "TLS 1.3, server CertificateVerify\0"
local leaf = { key = { algorithm = { name = "Ed25519" }, bits = pk } }

tap.ok(tofu.check_signature(leaf, {
	algorithm = tofu.ED25519,
	transcript_hash = th,
	signature = ed25519.sign(seed, CONTEXT .. th),
}) == true, "tofu checks an Ed25519 CertificateVerify")

-- the same signature over a different transcript is the attack this
-- exists to refuse, so a false pass shows up here.
tap.ok(tofu.check_signature(leaf, {
	algorithm = tofu.ED25519,
	transcript_hash = th,
	signature = ed25519.sign(seed, CONTEXT .. string.rep("\4", 32)),
}) == nil, "and refuses one made over another transcript")

tap.ok(tofu.check_signature(leaf, {
	algorithm = 0xfefe, transcript_hash = th, signature = "",
}) == nil, "an algorithm it cannot check is refused, not pinned")

-- every RSA-PSS code names a hash module that exists: the table holds
-- names now, and a typo would only show up on a handshake with a
-- server using that one.
local allhash = true

for _, name in pairs(tofu.RSA_PSS) do
	local ok, mod = pcall(require, name)

	if not ok or type(mod.hash) ~= "function" then
		allhash = false
	end
end
tap.ok(allhash, "every RSA-PSS code names a loadable hash")

tap.done()
