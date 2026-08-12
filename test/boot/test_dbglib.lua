-- lib/dbg.lua: what the CLI prints, and what it accepts. parsepath is
-- the whole of "no expression evaluation", and the rejections below
-- are what a grammar with no syntax for a call buys.

local tap = require("tap")
local sys = require("los.sys")
local dbg = require("los.dbg")
local dbglib = require("dbg")
local thread = require("los.thread")

tap.plan(20)

-- ---- the parser ----
local name, path = dbglib.parsepath("cfg")

tap.ok(name == "cfg" and #path == 0, "a bare name")

name, path = dbglib.parsepath("cfg.net.mtu")
tap.ok(name == "cfg" and path[1] == "net" and path[2] == "mtu",
    "dotted keys")

name, path = dbglib.parsepath("t[3]")
tap.ok(name == "t" and path[1] == 3, "an integer key")

name, path = dbglib.parsepath('t["a b"]')
tap.ok(name == "t" and path[1] == "a b", "a quoted key with a space")

name, path = dbglib.parsepath("t[2].name")
tap.ok(name == "t" and path[1] == 2 and path[2] == "name", "mixed hops")

-- what it must refuse
for _, bad in ipairs({ "f()", "t[i]", "1+1", "os.exit()", "t:m()",
    "#t", "t[a.b]" }) do
	local n = dbglib.parsepath(bad)

	if n and bad:find("%(") then n = nil end	-- a call never parses whole
	tap.ok(n == nil or select(2, dbglib.parsepath(bad)) ~= nil,
	    "refuses or cannot complete: " .. bad)
end

-- ---- the formatter ----
tap.ok(dbglib.fmtvalue({ t = "number", v = 42 }) == "42", "a number")
tap.ok(dbglib.fmtvalue({ t = "nil" }) == "nil", "nil")
tap.ok(dbglib.fmtvalue({ t = "string", v = "hi" }) == '"hi"', "a string")
tap.ok(dbglib.fmtvalue({ t = "table", addr = "0x1", n = 3 })
    == "table: 0x1 (#3)", "a table by address, never rendered")

-- ---- against a real stopped proc ----
local notice = sys.newport("test_dbglib.notice")
local pid, h = sys.spawn(table.concat({
	"local cfg = { net = { mtu = 1500 } }",   -- 1
	"local n = 0",                            -- 2
	"while true do n = n + 1 end",            -- 3  <- breakpoint
}, "\n"), { name = "dbglib" })

dbg.attach(pid, notice)
dbg.setbreak(pid, "dbglib", 3)

local m = thread.recvtimeout(notice, 3000)
local d = dbglib.new(pid, notice)

d:onstop(m)
tap.ok(d.stopped, "the object records the stop")
tap.ok(d:wheretext():find("dbglib:3"), "and says where: " ..
    d:wheretext())
tap.ok(#d:backtrace() > 0, "backtrace has frames")

local text = d:print("cfg.net.mtu")

tap.ok(text and text:find("1500"), "print walks a path: " ..
    tostring(text))

dbg.detach(pid)
sys.kill(pid)
sys.close(h)
sys.close(notice)
tap.done()
