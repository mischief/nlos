#!/usr/bin/env lua5.4
-- screenshot-esp32.lua [PORT] [OUT.pbm] [--draw TEXT] -- read the panel
-- back over ZMODEM and write a PBM.
--
-- The panel itself cannot be read. Neither board routes the display's
-- SDO anywhere -- verified from the schematics, not assumed -- so there
-- is no path back from the glass. What this reads is the copy
-- CONFIG_LUAOS_FB_SHADOW keeps, which is one bit per pixel: a
-- screenshot shows shape, not colour. Hence PBM, which is exactly that.
--
-- The guest does the work, in task/shot.lua; this only asks and
-- receives. So the size comes from the panel rather than from here --
-- 240x135 on a Cardputer, 320x240 on a T-Deck -- and adding a board
-- does not touch this file.
--
-- ZMODEM rather than printing the pixels. The console is the only line
-- out, and a guest that free-runs a dump into it blocks forever once
-- the USB-Serial-JTAG buffer fills with nobody draining: a host that
-- times out mid-dump leaves the guest stuck in print() until a power
-- cycle, measured the hard way. ZMODEM is paced by the receiver, and
-- moves a 320x240 screen in about a second where a character per pixel
-- took the better part of a minute.
--
--	HOSTUTIL_SO=build/hostutil.so \
--	    lua5.4 tools/screenshot-esp32.lua /dev/ttyACM0 /tmp/shot.pbm

local HOSTUTIL = os.getenv("HOSTUTIL_SO")

if not HOSTUTIL then
	io.stderr:write("HOSTUTIL_SO is not set " ..
	    "(build it: ninja -C build hostutil.so)\n")
	os.exit(1)
end

local hu = assert(package.loadlib(HOSTUTIL, "luaopen_hostutil"))()
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

-- One connection for the whole session, commands and transfer alike.
--
-- Not tidiness. socat asserts DTR/RTS when it attaches, and on a native
-- USB-Serial-JTAG those are the reset strap -- measured as rst:0x15
-- (USB_UART_CHIP_RESET) mid-session, which reboots the board, wipes the
-- shadow and loses whatever was typed before it. A second opener is a
-- second chance to reset, so lrz is handed this very descriptor rather
-- than opening the port for itself.
local f = assert(hu.serial(port, 115200))
local fd = hu.fileno(f)

local function say(line, settle)
	f:write(line, "\r\n")

	-- before reading anything back. The stream is read/write, and C
	-- wants the direction change separated by a flush whatever the
	-- buffering; skip it and a later read blocks forever on a line
	-- that is working perfectly.
	f:flush()
	os.execute("sleep " .. (settle or "0.4"))
end

say("")

if draw then
	say("FT=require(\"los.font\") M=thread.rpc(fb,{op=\"mode\"}).ok")
	say("thread.rpc(fb,{op=\"fill\",r={x=0,y=0,w=M.w,h=M.h},color=0})")
	say("P,PW,PH=FT.render(" .. string.format("%q", draw) ..
	    ",0xffffff,0)")
	say("thread.rpc(fb,{op=\"load\",r={x=6,y=10,w=PW,h=PH},data=P})")
end

-- lrz writes to the current directory under the name the sender gave
-- and cannot be told otherwise, so ask for a name of our choosing and
-- move it afterwards.
local tmp = ".shot-esp32.pbm"

os.remove(tmp)

-- --rows N captures the top N rows only.
--
-- For the board that cannot manage a whole screen: the image and the
-- sender have to be resident at once, and on a Cardputer (no PSRAM,
-- ~107KB free) a full 240x135 does not fit -- it takes the console proc
-- down with it, which costs the only line out. Sixteen rows transfer
-- there without trouble. Not a workaround to keep: see the memory
-- notes on task/shot.lua.
say(("shot(%q%s)"):format(tmp, rows and (", " .. rows) or ""), "0.5")

local pid = hu.spawn({ "lrz", "-y" },
    { stdin = fd, stdout = fd, stderr = 2 })

if not pid then
	io.stderr:write("cannot run lrz (install lrzsz)\n")
	os.exit(1)
end

-- A screen is about 10KB and moves at ~114KB/s, so this is slack for a
-- guest that is busy rather than for a transfer that is slow. If it
-- expires the transfer has failed and waiting longer will not mend it.
local deadline = os.time() + 20
local rc

while os.time() < deadline do
	rc = hu.poll(pid)
	if rc then
		break
	end
	os.execute("sleep 0.2")
end

local timedout = not rc

if timedout then
	hu.kill(pid)
	io.stderr:write("lrz did not finish within 20s\n")
end

-- the guest reports its own result and says why when it failed, which
-- is worth surfacing: "no receiver" and "not enough memory" are
-- different problems and both look like an empty file from out here.
-- Read it on the timeout path too -- that is the case where the reason
-- is least obvious and most wanted.
for _ = 1, 3 do
	if not hu.readable(fd, 1.0) then
		break
	end

	local l = f:read("l")

	if not l then
		break
	end
	l = l:gsub("%c", "")
	if l:match("shot:") then
		io.stderr:write(l, "\n")
	end
end

local fh = io.open(tmp, "rb")

if timedout or not fh then
	if fh then
		fh:close()
	end
	os.remove(tmp)
	io.stderr:write("no file received\n")
	os.exit(1)
end

local data = fh:read("a")

fh:close()
os.remove(tmp)

local w, h = data:match("^P4\n(%d+) (%d+)\n")

if not w then
	io.stderr:write("not a PBM: " ..
	    string.format("%q", data:sub(1, 16)) .. "\n")
	os.exit(1)
end

local o = assert(io.open(out, "wb"))

o:write(data)
o:close()
print(("%s: %sx%s, %d bytes"):format(out, w, h, #data))
