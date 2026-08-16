-- keyboard-interactive, against a scripted server.
--
-- The exchange is what a password login is: the server asks, the client
-- answers, and it may take more than one round. A real server needs PAM
-- to offer it at all, so the peer here is a transcript rather than
-- sshd, and what is under test is the client's half of the messages.
local tap = require("tap")
local client = require("ssh.client")
local wire = require("ssh.wire")
local msg = require("ssh.msg")

tap.plan(7)

-- A conn whose packet layer is not encrypted: the client writes whole
-- packets through sendpkt, so the fake sits under that and speaks the
-- same framing an unencrypted transport does.
local function transport(script)
	local outq, inq = {}, {}
	local step = 0

	return {
		rand = function(n) return ("\7"):rep(n) end,
		write = function(s)
			outq[#outq + 1] = s
			return true
		end,
		read = function(n)
			while #(inq[1] or "") < n do
				step = step + 1
				if not script[step] then
					return nil, "script ran out"
				end
				inq[1] = (inq[1] or "") .. script[step]
			end

			local s = inq[1]:sub(1, n)

			inq[1] = inq[1]:sub(n + 1)
			return s
		end,
		sent = outq,
	}
end

-- one unencrypted packet, as ssh.packet frames it: length, padding
-- length, payload, padding.
local function packet(payload)
	local pad = 8 - ((#payload + 5) % 8)

	if pad < 4 then
		pad = pad + 8
	end
	return string.pack(">I4", #payload + pad + 1) ..
	    string.char(pad) .. payload .. ("\0"):rep(pad)
end

local function inforeq(name, instruction, prompts)
	local w = wire.writer()
		:byte(msg.USERAUTH_INFO_REQUEST)
		:string(name):string(instruction):string("")
		:uint32(#prompts)

	for _, p in ipairs(prompts) do
		w:string(p.text):boolean(p.echo)
	end
	return packet(w:tostring())
end

-- ---- one round, one prompt, then success ----

local conn = transport({
	inforeq("", "", { { text = "Password: ", echo = false } }),
	packet(string.char(msg.USERAUTH_SUCCESS)),
})
local C = client.new(conn)
local seen = nil

local ok, err = C:auth_keyboard("someone", function(name, instr, prompts)
	seen = prompts
	return { "hunter2" }
end)

tap.ok(ok, "the exchange succeeded" .. (ok and "" or ": " .. tostring(err)))
tap.is(seen and #seen, 1, "one prompt was handed over")
tap.is(seen and seen[1].text, "Password: ", "with its text")
tap.is(seen and seen[1].echo, false, "and echo off, so it is a password")

-- the answer went out as an INFO_RESPONSE carrying exactly one string
local last = conn.sent[#conn.sent]

tap.is(last:byte(6), msg.USERAUTH_INFO_RESPONSE,
    "the reply is an info response")
tap.ok(last:find("hunter2", 1, true) ~= nil, "and carries the answer")

-- ---- a refusal names what is left ----

local conn2 = transport({
	packet(wire.writer():byte(msg.USERAUTH_FAILURE)
	    :namelist({ "publickey" }):boolean(false):tostring()),
})
local ok2, err2 = client.new(conn2):auth_keyboard("someone", function()
	return {}
end)

tap.ok(not ok2 and tostring(err2):find("publickey"),
    "a refusal says what the server will accept: " .. tostring(err2))

tap.done()
