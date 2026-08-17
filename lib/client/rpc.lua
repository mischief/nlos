-- client/rpc: the request half every capability wrapper shares.
--
-- thread.call is the transport and thread.replyport supplies the port,
-- so nothing is minted and nothing has to be closed. Only "full"
-- retries: "dead" and "hungup" are answers, not conditions to wait out.

local sys = require("los.sys")
local thread = require("los.thread")
local buf = require("los.buf")

local M = {}

-- one reply port PER CALL, not shared across the capability object.
-- a single shared port was the original design, but http.serve hands
-- the same tcp/dns capability object to multiple coroutines running
-- concurrently (accept loop + one per connection) -- with a shared
-- port, whichever coroutine calls thread.recv() first can steal
-- another coroutine's reply (eg an accept's boolean landing where a
-- recv's string was expected). fresh port per call avoids that
-- cross-delivery entirely; close it right after use so it doesn't
-- leak (same close-both-sides pattern net.lua's server side uses).
-- send, applying backpressure. sys.send reports a full queue
-- (false, "full") rather than raising, because the kernel refuses to
-- decide between a pipe writer that should wait and a server reply that
-- must not -- so deciding is the caller's job, and for a request whose
-- reply you are about to wait for, the answer is always "wait".
--
-- Ignoring that return silently DROPS the message. For a requester that
-- is worse than a lost write: the request is gone and the caller then
-- blocks forever on a reply that nothing will send.
--
-- sys.sendblock's size argument is what makes this park instead of
-- spin. Without it sendblock only asks "is the queue non-full", which
-- stays true while a large message is still refused by a queue holding
-- another one -- so it returns at once, the send fails again, and the
-- loop eats the whole slice. That measured as 33ms per band on the
-- framebuffer path.

-- how big a queue slot this message needs, for sendblock. The payload
-- length is the size that matters; the table around it is small, and
-- the estimate only has to avoid under-asking. Named rather than
-- inlined because requester needs the same number.
local function needof(m)
	local d = type(m) == "table" and m.data

	-- {__buf = b} is a payload too. The bytes are not in the message
	-- but are charged to the queue, so asking for room for the table
	-- alone asks for nothing and spins.
	if type(d) == "table" then
		d = d.__buf
	end

	-- a buffer needs the room its bytes need. #d works for either.
	if type(d) == "string" or buf.is(d) then
		return #d + 256
	end
	return 0
end

-- thread.parksend, not sys.sendblock: parking is legal only for the
-- coroutine the kernel resumed, and callers here are as often inside a
-- thread as not. parksend picks the right wait for either.
local function sendwait(handle, m)
	local need = needof(m)

	while true do
		local ok, why = sys.send(handle, m)

		if ok then
			return true
		end
		if why ~= "full" then
			return nil, why
		end
		thread.parksend(handle, need)
	end
end

M.sendwait = sendwait

-- the canonical request/reply, and the most-travelled one in the tree:
-- Every client under lib/client, and lib/draw.lua, comes through
-- here.
--
-- thread.call is the transport -- one kernel entry at the top level,
-- send plus the scheduler's own block inside a thread -- and
-- thread.replyport() supplies the port, so nothing is minted and
-- nothing has to be closed. That is the whole of what this used to get
-- wrong three times over in other files: a port or a right per request,
-- and a leak that surfaced somewhere else entirely.
--
-- ---- why the retry loop stays here ----
--
-- thread.call REPORTS a full queue rather than waiting it out, on
-- purpose: the kernel refuses to decide between a pipe writer that
-- should wait and a server reply that must not, and so does call. For a
-- request whose reply we are about to wait for, the answer is always
-- "wait" -- so the policy lives here, where that is known.
--
-- It could not move into thread.call anyway. What makes this park
-- instead of spin is the SIZE passed to sendblock, and the size lives
-- in m.data -- a convention of these messages, not a fact the scheduler
-- has any business knowing. Without it sendblock only asks "is the
-- queue non-full", which stays true while a large message is still
-- refused by a queue holding another one: 33ms per band, measured, on
-- the framebuffer path.
--
-- Only "full" retries. "dead" and "hungup" are answers, not conditions
-- to wait out.
-- `ms` bounds the wait for a reply, giving nil plus "timeout" where a
-- server dropped one. Not the default: an op on a slow volume takes as
-- long as it takes. Pass it where a hang is the worse outcome.
--
-- A late reply is drained first. Read as the answer to the next
-- request, it would leave every later op returning the one before it.
local function requester(target, ms)
	return function(extra)
		local reply, send = thread.replyport()

		-- tryrecv answers false on an empty queue, not nil: testing
		-- for nil here would never end.
		if ms then
			while sys.tryrecv(reply) do
			end
		end
		extra.reply = { __right = send }

		while true do
			local result, why

			if ms then
				local ok, serr = sendwait(target, extra)

				if not ok then
					return nil, serr
				end
				result, why = thread.recvtimeout(reply, ms)
				if result == nil and why == "timeout" then
					return nil, "timeout"
				end
				return result, why
			end

			result, why = thread.call(target, extra, reply)

			if why ~= "full" then
				-- includes the ordinary success case, where
				-- why is nil and result is the reply
				return result, why
			end
			-- parksend, for the reason sendwait above gives
			thread.parksend(target, needof(extra))
		end
	end
end

return { needof = needof, requester = requester, sendwait = sendwait }
