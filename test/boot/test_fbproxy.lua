-- the framebuffer reached through a proxy, as every app reaches it: dio
-- sits between an app and fb and rebuilds each message. test_fb talks
-- to fb directly and so cannot see a middle hop drop a field or lose a
-- message. This stands a small dio between.

local sys = require("los.sys")
local thread = require("los.thread")
local draw = require("draw")
local memdraw = require("memdraw")
local rpc = require("client.rpc")
local tap = require("tap")

local caps_of = sys.granted()

tap.plan(9)

tap.ok(caps_of.fb ~= nil, "boot payload was granted fb")
if not caps_of.fb then
	tap.done()
	return
end

local fb = draw.new(caps_of.fb)

-- ---- the proxy ----
--
-- an image space of its own, held on the client's behalf, and every op
-- rebuilt rather than forwarded whole: a dropped field is the failure
-- this exists to catch.

local up = fb.session()

tap.ok(up ~= nil, "the proxy took an image space of its own")

local front = sys.newport("proxy")
local frontsend = sys.sendright(front)

thread.spawn(function()
	while true do
		local m = thread.recv(front)

		if type(m) ~= "table" then
			break
		end

		local reply = m.reply and m.reply.__right
		local out = {}

		for k, v in pairs(m) do
			if k ~= "reply" then
				out[k] = v
			end
		end

		if reply then
			local rp = sys.newport("proxy.reply")

			out.reply = { __right = sys.sendright(rp) }
			rpc.sendwait(up.handle, out)

			local r = thread.recv(rp)

			sys.close(out.reply.__right)
			sys.close(rp)
			sys.send(reply, r)
			sys.close(reply)
		else
			rpc.sendwait(up.handle, out)
		end
	end
end)

local via = draw.new(frontsend)

-- the client is a thread of its own, since the proxy is one: a main
-- chunk blocked on a reply never lets the proxy run to answer it.
thread.spawn(function()

-- ---- an image the proxy never touches the pixels of ----

local id = via.alloc(32, 32, nil, memdraw.blue)

tap.ok(id ~= nil, "alloc through the proxy answers an id: " .. tostring(id))

-- an id dropped in the middle sends this fill to the screen instead,
-- at a rectangle that means nothing, and the image stays blue.
via.fill(memdraw.rect(0, 0, 16, 16), memdraw.green, true, id)

local corner = memdraw.rect(200, 40, 32, 32)

fb.fill(corner, memdraw.red, true)
via.draw(nil, id, memdraw.rect(0, 0, 32, 32),
    memdraw.pt(corner.x, corner.y), true)

local back = memdraw.fromBytes(32, 32, fb.unload(corner))

tap.is(memdraw.at(back, 0, 0), memdraw.green,
    "a fill carrying an id reached the image, not the glass")
tap.is(memdraw.at(back, 31, 31), memdraw.blue,
    "and the rest of the image is what alloc coloured it")

-- ---- a payload larger than a message ----
--
-- only the last band waits, so every band before it crosses the proxy
-- with no reply owed and no return value to report its loss.

local wide = memdraw.image(160, 80, memdraw.red)

wide:fill(memdraw.rect(0, 79, 160, 1), memdraw.green)

local wr = memdraw.rect(0, 120, 160, 80)

via.load(wr, memdraw.bytes(wide), true)

local got = memdraw.fromBytes(160, 80, fb.unload(wr))

tap.is(memdraw.at(got, 0, 0), memdraw.red, "a banded load crossed the proxy")
tap.is(memdraw.at(got, 159, 79), memdraw.green,
    "and the last band arrived as well as the first")

-- ---- and the images go when the proxy drops the space ----
--
-- dio closes an app's session when that app's serve loop ends. Nothing
-- else can: fb cannot tell one sender from another.

local big = fb.session()
local function fbused()
	for _, pid in ipairs(sys.procs()) do
		local st = sys.pidstat(pid)

		if st.name == "fb" then
			return st.used
		end
	end
end

big.alloc(256, 256, nil, memdraw.red)

local held = fbused()

sys.close(big.handle)
fb.mode()			-- a message, so the loop notices the hangup
fb.mode()

local after = fbused()

tap.ok(held == nil or after < held - 200000,
    "a space dropped by the proxy takes its images (" .. tostring(held) ..
    " -> " .. tostring(after) .. ")")

-- the proxy's own space is untouched by that, so its image still draws
fb.fill(corner, memdraw.red, true)
via.draw(nil, id, memdraw.rect(0, 0, 32, 32),
    memdraw.pt(corner.x, corner.y), true)

local still = memdraw.fromBytes(32, 32, fb.unload(corner))

tap.is(memdraw.at(still, 0, 0), memdraw.green,
    "and leaves another client's space alone")

tap.done()
end)

thread.run()
