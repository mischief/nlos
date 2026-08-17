-- agentui: a model on the panel, with the machine as its tools.
--
--	enter             send what is typed
--	esc               leave
--	touch the name    pick a model, which starts a new conversation
--	touch the bar     show what the tools did, and hide it again
--	trackball         scroll the transcript

-- The shape is bin/bitchatui.lua's, and for the same reasons: one
-- frame holds the transcript, a line at the bottom holds what is being
-- typed, and only the rows whose text changed are repainted, because a
-- row costs real time on this panel.

-- The turn runs in a thread of its own so the loop keeps taking keys
-- while the model is thinking -- a turn is seconds, and a panel that
-- ignored the keyboard for that long would feel broken.

-- No prompting before a tool runs. This machine is one person's, the
-- tools reach no further than the app was granted, and a question per
-- call on a screen this size is most of the screen.

local prog = require("prog")
local sys = require("los.sys")
local thread = require("los.thread")
local mouse = require("mouse")
local font = require("los.font")
local frame = require("frame")
local llm = require("llm")
local agent = require("agent")

local N = prog.ns()
local fb = prog.screen()

local function die(s)
	io.stderr:write("agentui: " .. s .. "\n")
	os.exit(1)
end

if not fb then
	die("no framebuffer")
end
if not N then
	die("no namespace")
end

local net = prog.net() or die("no network: /etc/dio.lua must say net = true")

-- the pointer is its own handle, not events on the port: what arrives
-- on the port is keys and window state.
local ptr = prog.mouse()

-- what to show before the server has been asked. The picker replaces
-- this with the endpoint's own list when it is first opened.
--
-- The first is the default, and it is capable rather than cheap:
-- reading a tree and reporting on it is what this is for, and a small
-- model answers that thinly.
local MODELS = {
	"gpt-5.6-luna",
	"gpt-5.5",
	"gpt-5.4",
	"gpt-5.4-mini",
	"gpt-5.4-nano",
}
local MODEL = MODELS[1]

-- only the ones worth talking to: the list carries embeddings, audio
-- and image models that this app cannot use.
local function chatty(id)
	return id:find("^gpt%-") ~= nil and
	    not id:find("audio") and not id:find("realtime") and
	    not id:find("image") and not id:find("search") and
	    not id:find("transcribe") and not id:find("tts") and
	    not id:find("%-%d%d%d%d%-%d%d%-%d%d$")
end
local KEYFILE = "/config/openai/key"

-- what to say on top of lib/agent.lua's description of the machine.
-- Short answers, because the screen is 53 columns and a paragraph is
-- the whole of it.
local BRIEF = [[

You are answering on a handheld with a 53-column screen. Keep answers
to a sentence or two unless more is asked for. Run a tool rather than
guessing, and say what you found rather than what you would do.
]]

local mode = fb.mode()
local W, H = mode.w, mode.h
local FMT = mode.format == "r5g6b5" and "r5g6b5" or "bgrx"

local BG, FG, DIM = 0x101014, 0xd0d0d8, 0x707078
local MINE, TOOL, WARN = 0x60a0e0, 0x80c080, 0xc06060

local FW, FH = 6, 12
local ROWH = FH + 2
local TOP = ROWH			-- the bar
local INPUT = H - ROWH			-- the line being typed
local rows = math.floor((INPUT - TOP) / ROWH)
local COLS = W // FW

-- ---- drawing ----

local function fill(x, y, w, h, color)
	fb.fill({ x = x, y = y, w = w, h = h }, color, true)
end

local function text(x, y, s, fg, bg)
	s = tostring(s or "")
	if s == "" then
		return
	end

	local px, w, h = font.render(s, fg or FG, bg or BG, true, FMT)

	if px then
		fb.load({ x = x, y = y, w = w, h = h }, px, true, true, FMT)
	end
end

-- ---- what is on the screen ----

local F = frame.new(COLS, rows)
local lines = {}		-- {text, color}, oldest first
local shownrow = {}
local typed = ""
local visible = true
local busy = false
local status = "ready"
local showtools = false
local toolog = {}
local picking = false		-- the model list is up
local picktop = 1		-- first model row shown
local gotmodels = false		-- the server's list has been asked for
local down = false		-- the pointer, so a press acts once
local BUT1 = 1			-- a click, from the panel or the ball

-- rows per scroll step. One row at a time reads as slow, because what
-- a step costs is the repaint rather than the step.
local SCROLL = 4

-- what a model writes and this font does not have. Spleen is 548
-- glyphs and none of them is a curly quote, so a box is what the panel
-- would otherwise draw for ordinary prose.
local FOLD = {
	["\u{2018}"] = "'", ["\u{2019}"] = "'",
	["\u{201c}"] = '"', ["\u{201d}"] = '"',
	["\u{2013}"] = "-", ["\u{2014}"] = "--",
	["\u{2026}"] = "...", ["\u{00a0}"] = " ",
	["\u{2022}"] = "*", ["\u{2192}"] = "->",
	["\u{00d7}"] = "x", ["\u{2212}"] = "-",
	["\u{2032}"] = "'", ["\u{2033}"] = '"',
}

-- a whole sequence at a time: a lua pattern counts bytes, so a range
-- written in codepoints would match none of these. What is not in the
-- table is left alone, since the font may well have it.
local function plain(s)
	return (tostring(s):gsub("[\194-\244][\128-\191]*", FOLD))
end

-- s as rows of at most cols, breaking hard at the margin and at a
-- newline. Codepoints, not bytes: cutting mid-sequence draws a box for
-- the character it halved. Text that is not utf8 falls back to bytes,
-- because a tool may return anything.
local function wrapped(s, cols)
	local out = {}

	for line in (tostring(s) .. "\n"):gmatch("([^\n]*)\n") do
		local n = utf8.len(line)

		if n == nil then
			for i = 1, #line, cols do
				out[#out + 1] = line:sub(i, i + cols - 1)
			end
		elseif n == 0 then
			out[#out + 1] = ""
		else
			local i = 1

			while i <= n do
				local j = math.min(i + cols - 1, n)
				local a = utf8.offset(line, i)
				local b = j < n and utf8.offset(line, j + 1) - 1
				    or #line

				out[#out + 1] = line:sub(a, b)
				i = j + 1
			end
		end
	end
	return out
end

-- how far along the bar the model name reaches, so the pointer knows
-- which half of the bar was touched.
local namew = 0

local function paintbar()
	if not visible then
		return
	end

	local name = "[" .. MODEL .. "]"

	namew = #name * FW
	fill(0, 0, W, ROWH, 0x202028)
	text(0, 0, name, FG, 0x202028)
	text(namew + FW, 0, status, DIM, 0x202028)
end

local function paintinput()
	if not visible then
		return
	end
	fill(0, INPUT, W, ROWH, 0x181820)

	local s = "> " .. typed
	local n = utf8.len(s)

	-- the tail, in codepoints: cutting bytes would split a sequence
	-- and draw a box for the character it halved.
	if n and n > COLS then
		s = s:sub(utf8.offset(s, n - COLS + 1))
	end
	text(0, INPUT, s, busy and DIM or FG, 0x181820)
end

local function paintbody(all)
	if not visible then
		return
	end
	if all or showtools or picking then
		fill(0, TOP, W, INPUT - TOP, BG)
		shownrow = {}
	end

	if picking then
		local y = TOP

		text(0, y, "pick a model", DIM)
		y = y + ROWH
		for i = picktop, #MODELS do
			if y + ROWH > INPUT then
				break
			end
			text(0, y, (MODELS[i] == MODEL and "* " or "  ") ..
			    MODELS[i], MODELS[i] == MODEL and MINE or FG)
			y = y + ROWH
		end
		return
	end

	if showtools then
		local y = TOP

		text(0, y, "what the tools did", DIM)
		y = y + ROWH
		for i = math.max(1, #toolog - rows + 2), #toolog do
			if y + ROWH > INPUT then
				break
			end
			text(0, y, toolog[i], TOOL)
			y = y + ROWH
		end
		return
	end

	local seen = {}

	for i = 1, rows do
		local s, l = F:line(i)
		local y = TOP + (i - 1) * ROWH

		s = s or ""
		seen[i] = s
		if shownrow[i] ~= s then
			fill(0, y, W, ROWH, BG)
			text(0, y, s,
			    l and lines[l.line] and lines[l.line][2] or FG)
		end
	end
	shownrow = seen
end

local function retext()
	local parts = {}

	for i, l in ipairs(lines) do
		parts[i] = l[1]
	end
	F:settext(table.concat(parts, "\n"))
end

local function atbottom()
	return F.top >= F:nlines() - F.rows
end

local function say(s, color)
	local stick = atbottom()

	for one in plain(s):gmatch("[^\n]*") do
		lines[#lines + 1] = { one, color or FG }
	end
	while #lines > 200 do
		table.remove(lines, 1)
	end
	retext()
	if stick then
		F:scroll(F:nlines())
	end
	paintbody()
end

-- whatever is in front: the model list when it is up, the transcript
-- otherwise.
local function scroll(by)
	if picking then
		picktop = math.max(1, math.min(#MODELS, picktop + by))
	else
		F:scroll(by)
	end
	paintbody(picking)
end

-- ---- the model ----

local key = N:readfile(KEYFILE)

if key then
	key = key:gsub("%s+$", ""):gsub("^%s+", "")
end

local client = llm.new({
	net = net,
	dns = prog.dns(),
	key = key,
	model = MODEL,
	rand = prog.rand(),
	stateful = true,
	tools = agent.TOOLS,
	instructions = agent.INSTRUCTIONS .. BRIEF,
})

local A = agent.new({
	client = client,
	caps = {},
	ns = N,
	-- the call on its own rows and the result on its own, wrapped
	-- rather than cut: a call and its result on one 53-column row
	-- leaves nothing of the result.
	trace = function(call, out)
		local function add(s)
			for _, l in ipairs(wrapped(plain(s), COLS)) do
				toolog[#toolog + 1] = l
			end
		end

		add(("%s %s"):format(call.name, call.raw or ""))
		add(out)
		while #toolog > 200 do
			table.remove(toolog, 1)
		end
		status = call.name
		paintbar()
		if showtools then
			paintbody(true)
		end
	end,
})

-- the picker, and what choosing does: a fresh conversation, because the
-- thread so far is a response id the server holds against the model
-- that made it.
local function choose(i)
	local m = MODELS[i]

	picking = false
	if m and m ~= MODEL then
		MODEL = m
		client.model = MODEL
		client:reset()
		say("model is " .. MODEL .. ", and this is a new conversation",
		    DIM)
	end
	paintbar()
	paintbody(true)
end

-- the endpoint's own list, fetched once and in a thread of its own: it
-- is a request, and the loop must keep taking keys through it.
local function askmodels()
	if gotmodels then
		return
	end
	gotmodels = true
	thread.spawn(function()
		local got, err = client:models()

		if not got then
			say("models: " .. tostring(err), WARN)
			return
		end

		local keep = {}

		for _, id in ipairs(got) do
			if chatty(id) then
				keep[#keep + 1] = id
			end
		end
		-- descending, which for these names is newest first: the
		-- top of the list is where the useful ones belong, and
		-- gpt-3.5 is a scroll away rather than in the way.
		table.sort(keep, function(a, b) return a > b end)
		if #keep > 0 then
			MODELS = keep
		end
		if picking then
			paintbody(true)
		end
	end)
end

local function openpicker()
	if busy then
		return
	end
	picking = not picking
	picktop = 1
	if picking then
		askmodels()
	end
	paintbody(true)
end

local function submit()
	local what = typed

	typed = ""
	paintinput()
	if what == "" or busy then
		return
	end
	if not key then
		say("no key: put one in " .. KEYFILE, WARN)
		return
	end

	say("> " .. what, MINE)
	busy = true
	status = "thinking"
	paintbar()

	thread.spawn(function()
		local t0 = sys.uptime_ms()
		-- xpcall, because a thread that dies takes its reason with
		-- it: the screen would keep saying "thinking" and nothing
		-- would ever say why.
		local ok, answer, err = xpcall(A.run, function(e)
			return tostring(e) .. "\n" .. debug.traceback("", 2)
		end, A, what)
		local ms = sys.uptime_ms() - t0

		if not ok then
			say("! " .. tostring(answer), WARN)
		elseif answer then
			say(answer)
		else
			say("! " .. tostring(err), WARN)
		end
		busy = false
		status = ("ready  %.1fs"):format(ms / 1000)
		paintbar()
		paintinput()
	end)
end

-- ---- the loop ----

local ev = prog.events()

if not ev then
	die("not running under the panel")
end

fill(0, 0, W, H, BG)
paintbar()
paintbody(true)
paintinput()

if key then
	say("ask it something. touch the name to pick a", DIM)
	say("model, or the bar for what the tools did.", DIM)
else
	say("no key found in " .. KEYFILE, WARN)
	say("write one there and start this again.", DIM)
end

-- the loop is a thread like the turn is, and thread.run below is what
-- gives either of them the cpu: a loop in the main chunk parks the whole
-- proc, and a turn spawned from it would never be resumed.
local function ui()

	while true do
		local m, why = thread.await(ev)

		if why or sys.hungup(ev) then
			break
		end

		if type(m) == "table" and m.t == "win" then
			visible = m.state ~= "hidden"
			if visible then
				fill(0, 0, W, H, BG)
				paintbar()
				paintbody(true)
				paintinput()
			end
		elseif type(m) == "string" then
			if m == "\r" or m == "\n" then
				submit()
			elseif m == "\27" then
				-- the list first, the app only when
				-- nothing is over it
				if picking or showtools then
					picking = false
					showtools = false
					paintbody(true)
				else
					break
				end
			elseif m == "\8" or m == "\127" then
				-- a codepoint, not a byte: backspacing one byte of a
				-- multibyte character leaves half of it behind.
				local n = utf8.len(typed)

				if n and n > 0 then
					typed = typed:sub(1, utf8.offset(typed, n) - 1)
				end
				paintinput()
			elseif m == "\t" then
				showtools = not showtools
				paintbody(true)
			elseif m == "\27[A" then
				scroll(-SCROLL)
			elseif m == "\27[B" then
				scroll(SCROLL)
			elseif m:byte(1) >= 0x20 and m:byte(1) ~= 0x7f then
				typed = typed .. m
				paintinput()
			end
	end
end

end

-- the pointer, read where it comes from. The bar is the one control the
-- T-Deck's keyboard cannot reach: it has no tab key.
local function pointer()
	if not ptr then
		return
	end
	while true do
		local x, y, b = ptr.read()

		if not x then
			return
		end
		if b and (b & BUT1) ~= 0 and not down then
			if y < ROWH then
				-- the name is one button and the rest of
				-- the bar is another
				if x < namew then
					openpicker()
				else
					picking = false
					showtools = not showtools
					paintbody(true)
					paintbar()
				end
			elseif picking and y < INPUT then
				-- the header takes the first row
				choose(picktop +
				    (y - TOP) // ROWH - 1)
			end
		end
		if b then
			down = (b & BUT1) ~= 0
		end
		-- the trackball, which is the wheel here. It moves whatever
		-- is in front: the list when the list is up.
		if b and (b & mouse.WHEELUP) ~= 0 then
			scroll(-SCROLL)
		elseif b and (b & mouse.WHEELDOWN) ~= 0 then
			scroll(SCROLL)
		end
	end
end

thread.spawn(pointer)
thread.spawn(ui)
thread.run()
