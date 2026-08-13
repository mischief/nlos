-- wifiui: pick a network, on the panel.
--
--	> wifiui
--
--	up/down or the trackball   choose
--	enter                      join, asking for a passphrase if it wants one
--	r                          scan again
--	q                          leave
--
-- It holds no capability for the radio: what it reads and writes is
-- /net/wifi, which task/wifisrv.lua serves. A session whose namespace
-- lacks that mount cannot run it.

local prog = require("prog")
local font = require("los.font")

local N = prog.ns()
local fb = prog.screen()

if not fb then
	io.stderr:write("wifiui: no framebuffer on this machine\n")
	os.exit(1)
end
if not N or not N:stat("/net/wifi/ctl") then
	io.stderr:write("wifiui: no /net/wifi in this namespace\n")
	os.exit(1)
end

local mode = fb.mode()
local W, H = mode.w, mode.h
local FMT = mode.format == "r5g6b5" and "r5g6b5" or "bgrx"

-- the panel's own colors, dark: this runs on a handheld, often at night
local BG, FG, DIM = 0x101014, 0xd0d0d8, 0x707078
local SEL, OK, BAD = 0x2a4a80, 0x60c060, 0xc06060

local FW, FH = 6, 12		-- los.font's cell
local ROWH = FH + 4
local TOP = ROWH * 2
local rows = math.floor((H - TOP - ROWH * 2) / ROWH)

-- ---- drawing ----

local function clear(color)
	fb.fill({ x = 0, y = 0, w = W, h = H }, color or BG, true)
end

-- one line of text at a pixel position. los.font renders a whole string
-- with one foreground and background, which is all this needs: every
-- line here is one color.
local function text(x, y, s, fg, bg)
	s = tostring(s or "")
	if s == "" then
		return
	end
	if #s > 256 then
		s = s:sub(1, 256)
	end

	local px, w, h = font.render(s, fg or FG, bg or BG, true, FMT)

	if not px then
		return
	end
	fb.load({ x = x, y = y, w = w, h = h }, px, true, true, FMT)
end

-- signal as four blocks, which reads at arm's length where a number
-- does not. The thresholds are the usual ones for 2.4GHz.
local function bars(rssi)
	local n = 0

	if rssi >= -55 then n = 4
	elseif rssi >= -66 then n = 3
	elseif rssi >= -77 then n = 2
	elseif rssi >= -88 then n = 1
	end
	return string.rep("|", n) .. string.rep(".", 4 - n)
end

-- ---- the radio, as files ----

local function status()
	local txt = N:readfile("/net/wifi/status") or ""

	return {
		state = txt:match("state (%S+)") or "unknown",
		ssid = txt:match("ssid ([^\n]*)") or "",
		reason = txt:match("reason (%S+)") or "0",
	}
end

local function scan()
	local txt = N:readfile("/net/wifi/scan") or ""
	local aps = {}

	for line in txt:gmatch("[^\n]+") do
		local rssi, auth, ssid = line:match("^(-?%d+) (%S+) (.*)$")

		if rssi and ssid ~= "" then
			aps[#aps + 1] = { rssi = tonumber(rssi),
			    open = auth == "open", ssid = ssid }
		end
	end
	return aps
end

-- one field a line: both an ssid and a passphrase hold spaces in
-- practice, and neither holds a newline.
local function join(ssid, psk)
	return N:writefile("/net/wifi/ctl",
	    "join\n" .. ssid .. "\n" .. ((psk and psk ~= "") and psk or ""))
end

-- ---- the screen ----

local aps, sel, top = {}, 1, 1
local msg = "scanning..."

local function paint()
	clear()
	text(8, 4, "wifi", FG)

	local st = status()
	local right = st.state == "joined" and ("on " .. st.ssid) or st.state

	text(W - 8 - #right * FW, 4, right,
	    st.state == "joined" and OK or DIM)

	if sel < top then
		top = sel
	elseif sel >= top + rows then
		top = sel - rows + 1
	end

	for i = 0, rows - 1 do
		local ap = aps[top + i]

		if not ap then
			break
		end

		local y = TOP + i * ROWH
		local on = (top + i) == sel
		local bg = on and SEL or BG

		fb.fill({ x = 0, y = y - 2, w = W, h = ROWH }, bg, true)
		text(8, y, ap.ssid:sub(1, 24), FG, bg)
		text(W - 8 - 9 * FW, y, bars(ap.rssi), FG, bg)
		text(W - 8 - 4 * FW, y, ap.open and "open" or " psk",
		    ap.open and DIM or FG, bg)
	end
	text(8, H - ROWH - 2, msg, DIM)
	fb.sync()
end

-- ---- the passphrase ----
--
-- Typed here rather than through readline, which draws into a console
-- this program has taken the screen from. Echoed as dots: someone is
-- holding the board, and a shoulder is the threat a panel actually has.
local function askpsk(tty, ssid)
	local pw = ""

	while true do
		clear()
		text(8, 4, "join " .. ssid:sub(1, 20), FG)
		text(8, TOP, "passphrase:", DIM)
		text(8, TOP + ROWH, string.rep("*", #pw), FG)
		text(8, H - ROWH - 2, "enter to join, esc to go back", DIM)
		fb.sync()

		local k = tty.getch()

		if k == nil or k == "\27" then
			return nil
		elseif k == "\r" or k == "\n" then
			return pw
		elseif k == "\8" or k == "\127" then
			pw = pw:sub(1, -2)
		elseif #k == 1 and k >= " " then
			pw = pw .. k
		end
	end
end

-- ---- main ----

local tty = prog.tty()

if not tty then
	io.stderr:write("wifiui: no keyboard on this machine\n")
	os.exit(1)
end

tty.rawon()

local function bye()
	tty.rawoff()
	clear(0)
	fb.sync()
end

paint()
aps = scan()
msg = #aps .. " networks -- enter to join, r to rescan, q to quit"
paint()

while true do
	local k = tty.getch()

	if k == nil or k == "q" or k == "\3" then
		break
	elseif k == "r" then
		msg = "scanning..."
		paint()
		aps, sel, top = scan(), 1, 1
		msg = #aps .. " networks"
	elseif k == "k" or k == "\27[A" then
		sel = math.max(1, sel - 1)
	elseif k == "j" or k == "\27[B" then
		sel = math.min(#aps, sel + 1)
	elseif k == "\r" or k == "\n" then
		local ap = aps[sel]

		if ap then
			local psk = nil

			if not ap.open then
				psk = askpsk(tty, ap.ssid)
			end
			if psk ~= nil or ap.open then
				msg = "joining " .. ap.ssid .. "..."
				paint()

				local ok, err = join(ap.ssid, psk)

				if not ok then
					msg = "join: " .. tostring(err)
				else
					msg = "joining..."
					for _ = 1, 20 do
						local st = status()

						if st.state == "joined" then
							msg = "joined " .. st.ssid
							break
						elseif st.state == "failed" then
							msg = "failed (reason " ..
							    st.reason .. ")"
							break
						end
						require("los.thread").sleep(250)
					end
				end
			end
		end
	end
	paint()
end

bye()
