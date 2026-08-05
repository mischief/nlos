#!/usr/bin/env lua5.4
-- screenshot-esp32.lua [PORT] [OUT.pbm] -- read the panel back over the
-- serial repl and write a PBM.
--
-- The panel itself cannot be read. The Cardputer's LCD connector is
-- eight pins (RST, RS, MOSI, SCK, CS, BL, 3V3, GND) and the ST7789's
-- SDO is routed nowhere, so there is no path back from the glass --
-- verified from the M5StampS3 schematic, not assumed. What this reads
-- is the copy CONFIG_LUAOS_FB_SHADOW keeps, which is one bit per pixel:
-- a screenshot shows shape, not colour.
--
-- PBM because that is exactly what the data is. A PPM would triple the
-- file to carry two colours.
--
-- One character per pixel on the wire, not hex. unload speaks BGRx
-- because that is the shared fb protocol, so a row is 960 bytes -- as
-- hex that is 1920 characters per row and 259200 for a screen, which at
-- 115200 baud is half a minute of serial and a great deal of per-byte
-- lua. Sampling one channel and sending '#' or '.' is 240 per row, and
-- it survives the USB-Serial-JTAG console's LF translation the same way
-- hex would.
--
-- Sent as several short lines on purpose: the console's readline
-- truncates a long one, and a truncated program fails as a syntax error
-- inside the guest where you cannot see it. Keep each under ~180
-- characters.
--
--	lua5.4 tools/screenshot-esp32.lua /dev/ttyACM1 /tmp/shot.pbm

local port = arg[1] or "/dev/ttyACM1"
local out = arg[2] or "/tmp/shot.pbm"

-- --draw "TEXT" clears the screen and writes TEXT before capturing, in
-- the SAME serial session. Two sessions is one open too many: see the
-- DTR/RTS note below.
local draw = nil

for i = 3, #arg do
	if arg[i] == "--draw" then
		draw = arg[i + 1] or "lua-os"
	end
end

local W, H = 240, 135

local py = os.getenv("IDF_PYTHON") or
    (os.getenv("HOME") .. "/.espressif/python_env/idf6.0_py3.13_env/bin/python")

local prog = {
	"G=sys.granted() F=G.fb R=thread.rpc",
	"function ROW(y) local d=R(F,{op=\"unload\",r={x=0,y=y,w=" .. W ..
	    ",h=1}}).ok local t={} for i=1," .. (W * 4) ..
	    ",4 do t[#t+1]=d:byte(i)>0 and \"#\" or \".\" end return table.concat(t) end",
	"function SHOT() print(\"SHOT-BEGIN\") for y=0," .. (H - 1) ..
	    " do print(ROW(y)) end print(\"SHOT-END\") end",
	"SHOT()",
}

if draw then
	table.insert(prog, 2, "FT=require(\"los.font\")")
	table.insert(prog, 3, "R(F,{op=\"fill\",r={x=0,y=0,w=" .. W ..
	    ",h=" .. H .. "},color=0})")
	table.insert(prog, 4, "P,PW,PH=FT.render(" ..
	    string.format("%q", draw) .. ",0xffffff,0)")
	table.insert(prog, 5,
	    "R(F,{op=\"load\",r={x=6,y=10,w=PW,h=PH},data=P})")
end

local lines = {}

for _, l in ipairs(prog) do
	lines[#lines + 1] = string.format("%q", l .. "\n")
end

-- Opening the port must not assert DTR/RTS. On USB-Serial-JTAG those
-- are the reset and boot lines, and pyserial raises them on open by
-- default -- which resets the board, wipes the shadow and unbinds the
-- functions this just defined. That is why a capture in its own
-- connection came back empty while the same thing inline worked.
local script = ([[
import serial, sys, time
s = serial.Serial()
s.port = %q
s.baudrate = 115200
s.timeout = 2
s.dtr = False
s.rts = False
s.open()
time.sleep(0.5); s.reset_input_buffer()
for line in [%s]:
    s.write(line.encode())
    time.sleep(0.4)
    s.read(s.in_waiting or 0)
buf = b""
deadline = time.time() + 90
while time.time() < deadline:
    buf += s.read(4096)
    if b"SHOT-END" in buf:
        break
sys.stdout.write(buf.decode("utf-8", "replace"))
]]):format(port, table.concat(lines, ", "))

local f = assert(io.open("/tmp/.shot-drive.py", "w"))

f:write(script)
f:close()

local p = assert(io.popen(py .. " /tmp/.shot-drive.py 2>&1"))
local text = p:read("a"):gsub("\r", "")

p:close()

local body = text:match("SHOT%-BEGIN\n(.-)SHOT%-END")

if not body then
	io.stderr:write("no complete capture. tail of what came back:\n" ..
	    text:sub(-500) .. "\n")
	os.exit(1)
end

-- Only full-width rows count. A short line is the console having
-- wrapped or the guest having raised, and taking it would skew every
-- row after it -- so it is dropped loudly rather than quietly.
local rows = {}

for line in body:gmatch("[^\n]+") do
	line = line:gsub("%s", "")
	if #line == W and line:match("^[#.]+$") then
		rows[#rows + 1] = line
	elseif #line > 0 and line ~= ">" then
		io.stderr:write("skipped: " .. line:sub(1, 70) .. "\n")
	end
end

if #rows == 0 then
	io.stderr:write("no usable scanlines\n")
	os.exit(1)
end
if #rows ~= H then
	io.stderr:write(("warning: %d scanlines, want %d\n"):format(#rows, H))
end

local o = assert(io.open(out, "wb"))

-- P1: ink is 1, which PBM renders black -- so glyphs come out dark on
-- white, the readable way round rather than the screen's way round.
o:write(("P1\n%d %d\n"):format(W, #rows))
for _, row in ipairs(rows) do
	o:write((row:gsub("#", "1 "):gsub("%.", "0 ")), "\n")
end
o:close()

print(("wrote %s (%dx%d)"):format(out, W, #rows))
