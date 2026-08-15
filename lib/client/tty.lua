-- client/tty: the terminal, as a client

local sys = require("los.sys")
local thread = require("los.thread")

-- the console as an interactive terminal, for a full-screen program
-- (bin/vi.lua). the handle is the same console mailbox every proc writes
-- to; a tty adds the raw side of it: rawon/rawoff to leave and re-enter
-- line-edited cooked mode, and getch for one un-echoed keystroke. cons,
-- the ssh session and (later) webterm each answer these, so a program
-- runs over any of them the way posix vi runs over a serial line, a pty
-- or an xterm -- one contract, several terminals.
--
-- getch is a plain request/reply, deliberately: the console owns the
-- timeout (it replies "" when `timeout` ms pass with no key), so this
-- side just blocks on the answer. that is what lets the same call work
-- whether the program is a proc of its own or a coroutine in a shell --
-- thread.recv adapts to either, where a client-side timer would need the
-- scheduler and would race the console over who consumed the byte.
local M = {}

function M.new(handle)
	local t = { handle = handle }	-- for re-granting: {__right = t.handle}
	-- the port to wait on, and the send right to publish. minted
	-- together on first use: {__right=} copies the recv flag, so the
	-- port as created would hand the console the ability to receive
	-- our answers.
	local replyport, replyright

	local function reply()
		if not replyport then
			replyport = sys.newport("client.replyport")
			replyright = sys.sendright(replyport)
		end
		return replyright
	end

	function t.write(s)
		sys.send(handle, { op = "write", data = s })
	end
	-- fire and forget: messages to one port keep their order, so a rawon
	-- followed by a getch is seen in that order without a round trip.
	function t.rawon()
		sys.send(handle, { op = "rawon" })
	end
	function t.rawoff()
		sys.send(handle, { op = "rawoff" })
	end
	-- one keystroke, or "" once `timeout` ms pass with none. one reusable
	-- reply port: a full-screen editor reads one key at a time, never
	-- concurrently, so there is nothing to cross-deliver.
	function t.getch(timeout)
		sys.send(handle, { op = "getch", timeout = timeout,
		    reply = { __right = reply() } })
		return thread.recv(replyport)
	end
	-- one edited line, with the terminal's own history and cursor
	-- keys, or nil at end of input. A program that prompts wants this
	-- rather than stdin: fd 0 reads the same lines underneath, but the
	-- prompt belongs to the editor, so recalling a line through stdin
	-- redraws over a prompt the console does not know is there.
	function t.readline(prompt)
		return thread.readline(handle, prompt)
	end
	-- bulk sibling of getch, for a program moving bytes rather than
	-- keystrokes: whatever is queued after the first byte, in one
	-- reply. "" on a timeout. The console caps `n` at its own bound,
	-- so a large ask is not a large answer.
	function t.readraw(n, timeout)
		sys.send(handle, { op = "readraw", n = n,
		    timeout = timeout, reply = { __right = reply() } })

		local d = thread.recv(replyport)

		return type(d) == "string" and d or ""
	end
	-- how wide and how tall, or nil when the far end does not know.
	-- A program that lays out columns asks once and falls back to its
	-- own default; nil means a serial line, not an error.
	function t.size()
		sys.send(handle, { op = "size",
		    reply = { __right = reply() } })

		-- Bounded, because "the far end does not know" and "the far
		-- end does not answer" are the same thing to a caller and
		-- only one of them is survivable by waiting. A console that
		-- has never heard of this op drops the message, and an
		-- unbounded recv here parks the program on a port nothing
		-- will ever write -- no cpu, no wakeup, nothing in ps but a
		-- pid sitting on a port. Half a second is far longer than a
		-- console on the same machine needs.
		local m = thread.recvtimeout(replyport, 500)

		return m and m.cols, m and m.rows
	end
	function t.close()
		if replyport then
			sys.close(replyport)
			replyport = nil
		end
	end
	return t
end

return M
