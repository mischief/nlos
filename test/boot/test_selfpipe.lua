-- a pipe whose two ends are threads of one proc.
--
-- sys.hungup answers "nobody outside this proc holds a right", so a
-- reader whose writer is a thread beside it is told the pipe is
-- finished before anything is written. That is what stops a shell
-- running inside a program from piping to it -- io.popen's shape.

local sys = require("los.sys")
local thread = require("los.thread")
local prog = require("prog")
local tap = require("tap")

tap.plan(6)

-- ---- the property, at the syscall ----

local port = sys.newport("selfpipe")

tap.ok(sys.hungup(port), "a port only this proc holds reads as hung up")

local wr = sys.sendright(port)

tap.ok(sys.hungup(port),
    "and still does when this proc makes itself a send right")

-- a message really is queued: the hangup is about holders, not content
sys.send(wr, { op = "write", data = "hello" })

local got, m = sys.tryrecv(port)

tap.ok(got and m and m.data == "hello",
    "yet a message sent to it arrives: " .. tostring(m and m.data))

-- ---- what that does to a stream ----
--
-- await drains before it decides, so bytes already queued come out.
-- What cannot happen is WAITING: a reader that arrives first is told
-- the pipe is finished instead of parking until its neighbour writes.
local wrote = false

thread.spawn(function()
	local w = prog.pipestream(wr, false)

	w:write("from a thread")
	wrote = true
end)

-- read before the writer has run: this is popen's order.
local early = prog.pipestream(port, false):read(64)

tap.is(early, "", "a reader that arrives first is told eof, not parked")
tap.is(wrote, false, "so it never yielded, and the writer had not run")

-- let it run, and read again: the bytes were always deliverable.
thread.run()

local late = prog.pipestream(port, false):read(64)

tap.is(late, "from a thread",
    "bytes already queued do come out: " .. tostring(late))

sys.close(wr)
sys.close(port)
tap.done()
