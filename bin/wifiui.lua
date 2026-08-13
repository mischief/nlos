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
local sys = require("los.sys")
local thread = require("los.thread")
local mouse = require("mouse")
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
-- what fits across, in glyphs. The window is what dio left of the
-- screen, not the screen, so this is not a constant.
local COLS = W // FW

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
	-- clipped to what is left of the window from x. los.font renders
	-- whatever it is given and fb.load puts it where it is told, so a
	-- long line runs off the edge rather than stopping at it.
	local room = (W - x) // FW

	if room < 1 then
		return
	end
	if #s > room then
		s = s:sub(1, room)
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

-- ---- the keyboard ----
--
-- Whichever of the two this was started under: a tty from a shell, and
-- under dio the event port the front app is lent, which carries keys
-- as bare strings. Same characters either way.
local ctx = prog.ctx
local tty = prog.tty()
local ev = prog.events()
local kbd = prog.haskeys() and ev or nil

if not tty and not kbd then
	io.stderr:write("wifiui: no keyboard on this machine\n")
	os.exit(1)
end

-- ---- the pointer ----
--
-- records arrive on the event port, so keys, the window and the pointer
-- all come to one place and there is nothing to alt over.

-- filled in below, and named here because key() reaches it: the
-- passphrase screen waits for a keystroke and the window may change
-- underneath it.
local onwin

-- the next keystroke, whatever else arrives first. The window and the
-- pointer share this port, so a reader after a key has to take them off
-- it rather than mistake one for input.
local function key()
	if tty then
		return tty.getch()
	end
	while true do
		local m, why = thread.await(ev)

		if why then
			return nil
		end
		if type(m) == "string" and not mouse.parse(m) then
			return m
		end
		if type(m) == "table" and m.t == "win" then
			onwin(m.state)
		end
	end
end

-- ---- the screen ----

local aps, sel, top = {}, 1, 1
local msg = "scanning..."
-- dio keeps no pixels for an app that is not in front, so what is drawn
-- behind another one is thrown away. Skipping it is not an optimisation
-- here: a scan repaints while the terminal is on the glass.
local visible = true

-- what the radio last said. Held rather than asked for per paint: the
-- answer is a read through the mount, so putting it in the draw path
-- costs a round trip to another proc for every keystroke.
local st = { state = "unknown", ssid = "", reason = "0" }

-- one row, which is all a selection move changes. Every draw here is a
-- message, so a moved selection redraws two rows rather than the list.
local function paintrow(k)
	local i = k - top

	if not visible or i < 0 or i >= rows then
		return
	end

	local ap = aps[k]
	local y = TOP + i * ROWH
	local bg = (k == sel) and SEL or BG

	fb.fill({ x = 0, y = y - 2, w = W, h = ROWH }, bg, true)
	if not ap then
		return
	end
	text(8, y, ap.ssid, FG, bg)
	text(W - 8 - 9 * FW, y, bars(ap.rssi), FG, bg)
	text(W - 8 - 4 * FW, y, ap.open and "open" or " psk",
	    ap.open and DIM or FG, bg)
end

-- keep sel on screen, and say whether that scrolled: a scroll is the
-- one case where every row changed.
local function follow()
	local was = top

	if sel < top then
		top = sel
	elseif sel >= top + rows then
		top = sel - rows + 1
	end
	return top ~= was
end

local function paintheader()
	local right = st.state == "joined" and ("on " .. st.ssid) or st.state

	fb.fill({ x = 0, y = 0, w = W, h = TOP - 2 }, BG, true)
	text(8, 4, "wifi", FG)
	text(W - 8 - #right * FW, 4, right,
	    st.state == "joined" and OK or DIM)
end

local function paintmsg()
	fb.fill({ x = 0, y = H - ROWH - 4, w = W, h = ROWH + 4 }, BG, true)
	text(8, H - ROWH - 2, msg, DIM)
end

local function paint()
	if not visible then
		return
	end
	follow()
	paintheader()
	for i = 0, rows - 1 do
		paintrow(top + i)
	end
	paintmsg()
	fb.sync()
end

-- the selection moved. Two rows, unless that scrolled the list.
local function repoint(was)
	if not visible then
		return
	end
	if follow() then
		paint()
		return
	end
	paintrow(was)
	paintrow(sel)
	fb.sync()
end

-- ---- the passphrase ----
--
-- Typed here rather than through readline, which draws into a console
-- this program has taken the screen from. Echoed as dots: someone is
-- holding the board, and a shoulder is the threat a panel actually has.
local function askpsk(ssid)
	local pw = ""

	-- the fixed part once. Only the dots change as it is typed, and
	-- redrawing the screen for each of them is what flickers.
	clear()
	text(8, 4, "join " .. ssid, FG)
	text(8, TOP, "passphrase:", DIM)
	text(8, H - ROWH - 2, "enter to join, esc to go back", DIM)
	fb.sync()

	while true do
		fb.fill({ x = 0, y = TOP + ROWH - 2, w = W, h = ROWH }, BG,
		    true)
		text(8, TOP + ROWH, string.rep("*", #pw), FG)
		fb.sync()

		local k = key()

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

if tty then
	tty.rawon()
end

-- brought back to the front with a cleared rectangle: dio saves no
-- pixels, so an app that does not repaint here comes back empty. No
-- thread for it -- the loop below is on that port already, and a run
-- started from a shell has no window to hear about.
function onwin(state)
	if state == "redraw" or state == "visible" then
		visible = true
		paint()
	elseif state == "hidden" then
		visible = false
	end
end

local function bye()
	if tty then tty.rawoff() end
	clear(0)
	fb.sync()
end

local function refresh()
	st = status()
end

-- the one the selection is on, joined
local function activate()
	local ap = aps[sel]

	if not ap then
		return
	end

	local psk = nil

	if not ap.open then
		psk = askpsk(ap.ssid)
		if psk == nil then
			return
		end
	end
	msg = "joining " .. ap.ssid
	paint()

	local ok, err = join(ap.ssid, psk)

	if not ok then
		msg = "join: " .. tostring(err)
		paint()
		return
	end
	for _ = 1, 20 do
		refresh()
		if st.state == "joined" then
			msg = "joined " .. st.ssid
			paint()
			return
		elseif st.state == "failed" then
			msg = "failed (reason " .. st.reason .. ")"
			paint()
			return
		end
		thread.sleep(250)
	end
	msg = "still joining"
	paint()
end

local function rescan()
	msg = "scanning..."
	paintmsg()
	fb.sync()
	aps, sel, top = scan(), 1, 1
	msg = #aps .. " networks  enter join  r scan  q quit"
	refresh()
	paint()
end

-- a key, wherever it came from. true to carry on.
local function onkey(k)
	local was = sel

	if k == nil or k == "q" or k == "\3" then
		return false
	elseif k == "r" then
		rescan()
	elseif k == "k" or k == "\27[A" then
		sel = math.max(1, sel - 1)
		repoint(was)
	elseif k == "j" or k == "\27[B" then
		sel = math.min(math.max(#aps, 1), sel + 1)
		repoint(was)
	elseif k == "\r" or k == "\n" then
		activate()
	end
	return true
end

-- a touch or the ball. A tap picks the row under the finger; a tap on
-- the row already picked joins it, which is the two-step every touch
-- list wants -- the first tells you what you are about to do.
local down = false

local function onpoint(x, y, b)
	local was = sel

	if (b & mouse.WHEELUP) ~= 0 then
		sel = math.max(1, sel - 1)
		repoint(was)
		return
	end
	if (b & mouse.WHEELDOWN) ~= 0 then
		sel = math.min(math.max(#aps, 1), sel + 1)
		repoint(was)
		return
	end

	local pressed = (b & 1) ~= 0

	if pressed == down then
		return		-- a drag, or the same state reported again
	end
	down = pressed
	if not pressed then
		return		-- act on the press, not the release
	end

	local row = (y - TOP + 2) // ROWH

	if row < 0 or row >= rows then
		return
	end

	local hit = top + row

	if not aps[hit] then
		return
	end
	if hit == sel then
		activate()
	else
		sel = hit
		repoint(was)
	end
end

refresh()
paint()
rescan()

while true do
	if ev then
		-- one port and no threads: keys, the window and the
		-- pointer all arrive here. await rather than recv, or a
		-- dio that went away parks this forever.
		local m, why = thread.await(ev)

		if why then
			break
		end

		local px, py, pb = mouse.parse(m)

		if px then
			onpoint(px, py, pb)
		elseif type(m) == "string" then
			if not onkey(m) then
				break
			end
		elseif type(m) ~= "table" then
			-- nothing else speaks on this port
		elseif m.t == "win" then
			onwin(m.state)
		end
	elseif not onkey(key()) then
		break
	end
	-- no repaint here: what changed is what draws. A full one per
	-- event is what made a roll flicker, since every rectangle is a
	-- message and the whole window went out for a moved highlight.
end

bye()
