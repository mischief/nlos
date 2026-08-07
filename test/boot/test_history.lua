-- the line editor's history, and the arrow keys that reach it.
--
-- lib/console.lua is the editor for every terminal on the machine --
-- the serial line, the panel, an ssh session, a browser tab -- so this
-- drives the Console object directly against a backend that collects
-- what would have been written. What is under test is the returned
-- line and the bytes the editor emitted, both of which are exact.
--
-- Keys are pushed into the console's own input port rather than typed
-- at its keyboard: the pump that moves one to the other never returns,
-- and thread.run() only comes back when every thread is dead. The pump
-- forwards each byte unchanged (the interrupt character aside), so what
-- the editor sees is the same either way.
local sys = require("los.sys")
local thread = require("los.thread")
local console = require("console")
local tap = require("tap")

tap.plan(15)

local ESC = "\27"
local UP = ESC .. "[A"
local DOWN = ESC .. "[B"

-- a backend that remembers what was written. cols/rows are absent, as
-- on a serial line, which is what the size op answers nil for.
local function backend()
	local out = {}

	return {
		write = function(s)
			out[#out + 1] = s
		end,
		keyport = sys.newport(),
		drain = function()
			local s = table.concat(out)

			out = {}
			return s
		end,
	}
end

local io = backend()
local con = console.new(io)

tap.ok(con ~= nil, "a console over a collecting backend")

-- type a line and read it back. The keys are queued before the editor
-- runs, which makes the whole exchange deterministic: no timing decides
-- what the test sees, except the escape timeout that is its own case
-- below.
local function typeline(keys)
	local got

	for i = 1, #keys do
		sys.send(con.inq, keys:sub(i, i))
	end
	thread.spawn(function()
		got = con:readline("> ")
	end)
	thread.run()
	return got
end

-- ---- the plain path still works ----

tap.is(typeline("hello\n"), "hello", "a typed line comes back")
tap.is(typeline("ab\8c\n"), "ac", "backspace erases")
tap.is(typeline("junk\21kept\n"), "kept", "ctrl-u kills the line")

-- ---- what is remembered ----

tap.is(#con.history, 3, "each line was remembered once")
tap.is(typeline("\n"), "", "an empty line comes back empty")
tap.is(#con.history, 3, "and is not remembered")
typeline("kept\n")
tap.is(#con.history, 3, "nor is the line already on top")

-- ---- the arrows ----

io.drain()
tap.is(typeline(UP .. "\n"), "kept", "up recalls the last line")
tap.is(typeline(UP .. UP .. "\n"), "ac", "up twice walks back two")

-- the line you were typing is not lost by looking at an older one.
tap.is(typeline("live" .. UP .. DOWN .. "\n"), "live",
    "down comes back to the line being typed")

-- application cursor mode: the same key, a different sequence, and
-- which one arrives is the far end's business. "live" is on top by now,
-- having just been entered.
tap.is(typeline(ESC .. "OA" .. "\n"), "live",
    "ESC O A is the same up arrow")

-- ---- sequences the editor does not act on ----
--
-- Delete is ESC [ 3 ~, three bytes after the escape. An editor that
-- stops reading at the first byte it does not recognise leaves the rest
-- to be typed into the line, which is the bug this pins: before the
-- arrows were read at all, an up arrow inserted a literal "[A".
tap.is(typeline("x" .. ESC .. "[3~" .. "y\n"), "xy",
    "an ignored sequence is swallowed whole, not typed")

-- a bare Escape has no sequence behind it. The byte that follows is a
-- keystroke of its own and has to survive being looked at: the editor
-- read it to find out whether a sequence was starting, and an editor
-- that then drops it is an editor that eats input.
tap.is(typeline("a" .. ESC .. "b\n"), "ab",
    "Escape then a letter types the letter")

-- and the byte that follows can be the one that ends the line, which is
-- why the pushback goes back through the whole editor rather than being
-- typed where it was read.
tap.is(typeline("a" .. ESC .. "\n"), "a",
    "Escape then Enter still ends the line")

tap.done()
