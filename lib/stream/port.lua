-- port streams: a program's stdin or stdout over a port right.
--
-- Two read strategies behind one shape. A drained stream takes messages
-- off the queue and reads eof from the port's refcount; a pull stream
-- asks for each read and reads eof from a nil answer, which is what
-- lib/cons.lua and lib/wire.lua speak.

-- Writing is one operation either way: {op="write", data=}.

local sys = require("los.sys")

local M = {}

local Port = {}

Port.__index = Port

-- own says whether closing the stream closes the handle. A stream over
-- a right that arrived in a message owns its copy and must drop it: for
-- a pipe, the writer letting go is the reader's eof.
--
-- A launcher building a stream over a handle it keeps and shares passes
-- false, so a program calling close(1) cannot take the console with it.
local function new(h, own, mt)
	return setmetatable({ h = h, own = own ~= false }, mt)
end

function M.new(h, own)
	return new(h, own, Port)
end

-- A full port applies backpressure: park until the reader drains, then
-- retry. A write that discarded sys.send's false, "full" would report
-- bytes it never sent.
--
-- A dead port is not an error: the reader hung up, which is EPIPE. 0
-- written matches read()'s "" for eof.
function Port:write(data)
	local msg = { op = "write", data = data }

	while true do
		local ok, why = sys.send(self.h, msg)

		if ok then
			return #data
		end
		if why ~= "full" then
			return 0
		end
		require("los.thread").parksend(self.h)
	end
end

-- thread.await is exactly this: drain first, and only then treat empty
-- and nobody else holding the port as the end. port_unref wakes
-- receivers so the hangup gets re-tested after a writer exits.
function Port:read(_)
	local m, why = require("los.thread").await(self.h)

	-- eof is "" rather than nil because a stream's read answers a
	-- string, and it is read from why rather than from m being nil
	-- because a message with no data is not an ending.
	if why then
		return ""
	end
	return (m and m.data) or ""
end

function Port:close()
	if self.own then
		sys.close(self.h)
	end
end

-- The pull form, for where data arrives asynchronously from hardware:
-- there is nothing in the queue to drain, so the far end is asked.
local Pull = setmetatable({}, { __index = Port })

Pull.__index = Pull

function M.pull(h, own)
	return new(h, own, Pull)
end

function Pull:read(_)
	if not self.replyport then
		self.replyport = sys.newport("stream.reply")
		-- send only: {__right=} copies the recv flag, and the far
		-- end has no business receiving our own answers
		self.replyright = sys.sendright(self.replyport)
	end
	sys.send(self.h, { op = "read", reply = { __right = self.replyright } })

	local r = require("los.thread").recv(self.replyport)

	-- nil means the far end is done; "" is this ABI's eof, so a
	-- program's `while data ~= ""` loop ends rather than erroring
	return r or ""
end

function Pull:close()
	if self.replyport then
		sys.close(self.replyright)
		sys.close(self.replyport)
		self.replyport, self.replyright = nil, nil
	end
	Port.close(self)
end

return M
