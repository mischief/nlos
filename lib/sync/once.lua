-- sync.once: work that several threads ask for and one thread does.
--
-- ---- the failure this exists to prevent ----
--
-- A mount opens its session on first use, and opening one is a round
-- trip to the server, so it PARKS. Every thread that arrived while the
-- first was waiting therefore also found no session and opened one of
-- its own. Each session has a fid space of its own -- that is what
-- they are for -- so the last assignment won and every fid the others
-- had minted named nothing.
--
-- It did not heal, either: the namespace caches the root handle it
-- walked from, so a mount touched concurrently the first time stayed
-- broken afterwards for readers that were perfectly serial. Six
-- threads on a cold mount opened six sessions, and every read from
-- then on answered nil.
--
-- Nothing about that needs preemption. The window is a whole round
-- trip rather than two instructions, so it is not a race you can lose
-- by being unlucky -- it is one you lose by being concurrent at all.
-- Anything shaped like
--
--	if not cached then
--		cached = something_that_parks()
--	end
--
-- has it, and a lazily opened connection, a filled cache entry and a
-- handshake are all shaped like that.
--
-- ---- what it does ----
--
--	local once = require("sync.once")
--	local session = once.new()
--
--	local function get()
--		return session:get(function()
--			return establish({ op = "session" })
--		end)
--	end
--
-- The first caller runs fn. Callers arriving while it runs wait, and
-- every one of them gets that same value. Later callers get it without
-- waiting.
--
-- AN ERROR IS NOT REMEMBERED. If fn raises, the error goes to the
-- caller that ran it, and the callers that were waiting try again
-- themselves rather than inheriting it. That is the difference from
-- go's sync.Once, which marks itself done whatever happened, and it is
-- deliberate: a server being unreachable for one caller's round trip
-- is not a verdict on the mount. It does mean a server that is down
-- costs one attempt per waiting caller.
--
-- fn may park -- that is the whole point -- and may be called again
-- after a failure, so it must be safe to run twice.
--
-- IN-PROCESS ONLY. Channels live in one lua_State, so this coordinates
-- the threads of one proc and nothing else. Two procs agreeing on who
-- does a piece of work is a different problem with a different answer:
-- send a message and let one of them own the thing.

local thread = require("los.thread")

local Once = {}

Once.__index = Once

local function new()
	return setmetatable({
		-- the value, once there is one. `done` is separate because
		-- nil is a legal result.
		v = nil,
		done = false,
		-- non-nil while somebody is running fn: the channel every
		-- other caller waits on. Closing it wakes them all at once,
		-- which is what a broadcast is here.
		running = nil,
	}, Once)
end

function Once:get(fn)
	while true do
		if self.done then
			return self.v
		end

		local ch, mine

		-- Finding `running` unset and setting it need nothing
		-- between them: a thread is not switched away from except
		-- where it parks, and neither the test nor chancreate does.
		-- The waiting happens afterwards, on the channel, which is
		-- where a thread may park -- and it is the park inside fn
		-- that made any of this necessary.
		if self.running then
			ch = self.running
		else
			ch = thread.chancreate(0)
			self.running, mine = ch, true
		end

		if not mine then
			-- until whoever claimed it is finished. Then round
			-- again rather than assuming it succeeded: it may
			-- have raised, in which case this thread claims the
			-- attempt itself.
			ch:recv()
		else
			local ok, res = pcall(fn)

			-- written out rather than `ok and res or nil`,
			-- which turns a legitimate false result into nil.
			if ok then
				self.v, self.done = res, true
			end
			self.running = nil
			ch:close()	-- wake every waiter
			if not ok then
				error(res, 0)
			end
			return self.v
		end
	end
end

-- the value if there already is one, without running fn or waiting for
-- anyone who is. Returns the value and whether there was one, since
-- nil is a legal value.
--
-- For the cleanup shape: a finalizer that should release the thing if
-- it was ever made, and do nothing at all if it was not. Asking with
-- get() there would establish a session in order to tear it down.
function Once:peek()
	return self.v, self.done
end

-- forget the value, so the next get() runs fn again. For a cached
-- thing that has gone stale -- a session whose server died, say.
function Once:reset()
	self.v, self.done = nil, false
end

return { new = new, Once = Once }
