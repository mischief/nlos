#!/usr/bin/env lua5.4
-- screenshot-esp32.lua [PORT] [OUT.pbm] [--draw TEXT] [--rows N] --
-- read the panel back and write a netpbm.
--
--	meson devenv -C build lua5.4 tools/screenshot-esp32.lua \
--	    /dev/ttyACM0 /tmp/shot.pbm
--
-- The transfer, and why the panel cannot simply be read, are in
-- tools/hostpanel.lua. This is the command line over it; use
-- tools/poke-esp32.lua to touch or type as well as look.
--
-- The guest does the work, in task/shot.lua, so the size comes from the
-- panel rather than from here; adding a board does not touch this file.
--
-- --rows N captures the top N rows only: the image and the sender must
-- be resident at once, which a board with no PSRAM has no room for.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."

package.path = scriptdir .. "/?.lua;" .. scriptdir .. "/../lib/?.lua;" ..
    package.path

local hostpanel = require("hostpanel")

local port = arg[1] or "/dev/ttyACM0"
local out = arg[2] or "/tmp/shot.pbm"
local draw, rows

for i = 1, #arg do
	if arg[i] == "--draw" then
		draw = arg[i + 1] or "lua-os"
	elseif arg[i] == "--rows" then
		rows = tonumber(arg[i + 1])
	end
end

local ok, p = pcall(hostpanel.open, port)

if not ok then
	io.stderr:write(tostring(p) .. "\n")
	os.exit(1)
end

-- only --draw needs a prompt of its own. Panel:shot goes through dos
-- and takes the session there itself.
if draw then
	p:tolua()
	p:say([[FT=require("los.font") M=thread.rpc(fb,{op="mode"}).ok]])
	p:say([[thread.rpc(fb,{op="fill",r={x=0,y=0,w=M.w,h=M.h},color=0})]])
	p:say("P,PW,PH=FT.render(" .. string.format("%q", draw) ..
	    ",0xffffff,0)")
	p:say([[thread.rpc(fb,{op="load",r={x=6,y=10,w=PW,h=PH},data=P})]])
end

local st, err = p:shot(out, rows)

p:close()

if not st then
	io.stderr:write(tostring(err) .. "\n")
	os.exit(1)
end
print(("%s: %s %dx%d, %d bytes"):format(out, st.kind, st.w, st.h, st.bytes))
