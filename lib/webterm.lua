-- webterm: a shell in a browser. drawterm's shape, minus the graphics.
--
-- a visitor gets an unprivileged dos(1) proc of their own and the
-- browser is its console. the reason this module is small is that
-- lib/dos.lua does not know what its console IS -- it writes
-- {op="write", data=} and asks {op="readline", reply=} against a port
-- right, which is precisely what lib/cons.lua answers. so a session
-- here is another console implementation, not a terminal emulator, and
-- the shell needs no changes at all to be served over http.
--
-- ---- why the output is text and not a canvas ----
--
-- the browser does its own line editing, so this never needs cons raw
-- mode (which docs/shell-namespace-draft.md lists as the prerequisite
-- for vi.lua). it also means the page is a <pre> full of real text
-- nodes: selection, copy and find are the browser's, working the way
-- they work everywhere else. a VT emulator on a canvas would have to
-- reimplement all three, worse, to gain escape sequences nothing here
-- emits.
--
-- ---- the settle point ----
--
-- http is request/response and a shell is not, so something has to
-- decide when a command's output is complete. it is not a timeout:
-- dos's repl is readline -> run -> print -> readline, so the shell
-- ASKING FOR THE NEXT LINE is the exact moment there is nothing more
-- to come. pump() collects writes until a readline is parked, and that
-- is the whole synchronisation story. the deadline exists only for a
-- program that never returns.
--
-- ---- what a visitor holds ----
--
-- one right: the send end of its console port. no tcp, no disk, no
-- cons, no procfs unless it was mounted. its namespace arrives as
-- nsdesc -- plain data for a "mem" tree, so each visitor gets a
-- private copy and writes are scratch that die with the session.
--
-- deliberately NOT handed to a public session: the `esp` right. it is
-- a mount to lib/espsrv.lua, and that task holds diskport -- so a
-- client holding the right can CREATE AND WRITE on the real ESP, not
-- merely read it. giving a visitor the namespace proc 0 runs with would
-- let them rewrite /lib/dos.lua. what a public session gets is `mem`
-- (plain data, a private copy per visitor) and, if it ever needs the
-- disk, a right to a server that serves a READ-ONLY view -- which does
-- not exist yet, see below.
--
-- ---- what confines a visitor, and what does not ----
--
-- file access is confined: proc_new nils io.open/lines/input/output/
-- popen/tmpfile plus loadfile/dofile for every proc except PRIV_BOOT
-- (src/kernel.c), and lib/nsio.lua puts io.open back only over an
-- adopted namespace. so a visitor's shell and its programs reach
-- exactly what their namespace holds. test_web.py asserts this through
-- /bin/probe rather than trusting it.
--
-- MODULE lookup is not confined, and that is a deliberate compromise
-- rather than an oversight. this module spawns the visitor with a bare
-- sys.spawn and does NOT use lib/proc.lua's spawn(src, {ns=}), so the
-- visitor never adopts and its require() falls back to the ambient
-- LUA_PATH searcher -- exactly what proc.lua's header warns against.
--
-- the reason: adopting routes require() through the namespace, and a
-- visitor's namespace is a mem tree with no /lib in it, so adopting
-- would leave require("dos") with nowhere to look. the honest fix is a
-- read-only ESP server proc -- srv.main over a backend that delegates
-- reads and raises Eperm on create/write -- mounted at /lib and /bin,
-- shared by every session instead of copied into each. that is one
-- small file and it closes this and the /bin copy in the same move.
--
-- what the compromise actually costs is narrow: require() names
-- modules, it does not read arbitrary files, and a visitor has no eval
-- to call it with anyway. programs are still loaded from the namespace
-- by prog.lua, not by the searcher.

local sys = require("los.sys")
local thread = require("los.thread")
local json = require("json")

local M = {}

-- MAXPROCS is 32 (src/kernel.c). a session used to cost one proc for the
-- shell plus one more per program it was running, which put the real
-- ceiling far below this number -- a visitor typing a three-stage
-- pipeline cost four procs on their own.
--
-- with coro=true (see the VISITOR chunk) a session is exactly ONE proc
-- whatever it runs, because programs are coroutines beside the shell.
-- so the arithmetic is now the honest one: this many, plus proc 0, cons,
-- tcp and the rest of the boot tasks. still short of 32 on purpose --
-- the failure mode of being generous is that the machine runs out of
-- procs and the SERVER cannot spawn a session either.
M.MAXSESSIONS = 16

-- how long a command may run before its output is returned unfinished.
-- the next request picks up whatever else arrived in the meantime, so
-- this truncates a response, never a program.
M.SETTLE_MS = 3000

-- a session nobody has typed at for this long is reaped.
M.IDLE_MS = 5 * 60 * 1000

-- how often the janitor wakes when no proc has exited.
M.TICK_MS = 15000

M.MAXLINE = 1024

-- output held for a session between requests. a runaway program would
-- otherwise grow this without bound inside the SERVER proc -- the one
-- proc here that must not hit its memory cap.
--
-- the ceiling is not taste, it is MAXMSG. a response body reaches the
-- network as ONE message to the tcp task (lib/caps.lua's requester),
-- and the serializer refuses anything over 64KB -- so an oversized
-- body does not truncate, it raises "unserializable message", drops
-- the connection and hands the client nothing. append() trims at twice
-- this, and json escaping inflates what is left, so 8KB keeps the
-- worst case comfortably clear of the limit.
--
-- (that ceiling is lib/http.lua's, not this module's: ANY handler
-- returning a ~64KB body hits it. worth fixing there by chunking the
-- write, at which point this can go back up.)
M.SCROLLBACK = 8 * 1024

-- the visitor proc: restore the namespace it was handed, then hand the
-- console right to the launcher and never return. a plain string
-- because rights arrive at handle numbers it cannot know until the
-- message lands, and because lua_dump carries no upvalue values into
-- another state.
local VISITOR = [[
	local sys = require("los.sys")
	local thread = require("los.thread")
	local ns = require("ns")
	local dos = require("dos")

	local m = thread.recv(sys.SELF)
	local cons = m.cons.__right
	local N, err = ns.restore(m.nsdesc)

	if not N then
		sys.send(cons, { op = "write",
		    data = "namespace: " .. tostring(err) .. "\n" })
		return
	end
	-- coro: a session is ONE proc. programs run as coroutines beside
	-- the shell rather than as procs of their own, so MAXPROCS stops
	-- bounding how many visitors there can be -- see Sh:pipecoro. the
	-- isolation given up is between a visitor and their own programs,
	-- which is not a boundary anyone here needs; the boundary that
	-- matters, between one visitor and another, is still a proc.
	dos.start({ ns = N, cons = cons, coro = true }, m.banner)
]]

-- ---- sessions ----

local function append(s, data)
	if type(data) ~= "string" then
		return
	end
	s.out[#s.out + 1] = data
	s.outlen = s.outlen + #data
	-- trim only once we are WELL past the cap, never at exactly it.
	-- trimming at the cap meant concatenating and re-slicing the whole
	-- buffer on every message once full -- O(n^2) over a chatty
	-- program, and `seq 1 20000` spent longer in this function than
	-- the guest spent producing it. discarding half at a time makes it
	-- amortised O(1) per byte, for twice the peak buffer.
	if s.outlen > M.SCROLLBACK * 2 then
		local all = table.concat(s.out):sub(-M.SCROLLBACK)

		s.out, s.outlen = { all }, #all
	end
end

local function flush(s)
	local data = table.concat(s.out)

	s.out, s.outlen = {}, 0
	return data
end

local function absorb(s, m)
	if type(m) ~= "table" then
		return
	end
	if m.op == "write" then
		append(s, m.data)
	elseif m.op == "readline" and type(m.reply) == "table" then
		s.waiting = m.reply.__right
	end
end

-- collect console traffic until the shell parks a readline, which is
-- the settle point described at the top.
--
--	"settled"  a readline is parked; the output is complete
--	"gone"     the shell exited (exit, ^d, a crash)
--	"timeout"  neither happened in time; output so far stays buffered
--
-- the loop is srv.lua's and prog.lua's idiom rather than a bare alt:
-- DRAIN with tryrecv, then test hangup on an empty queue, then park.
-- the order is what makes `exit` return the shell's last words instead
-- of eating them -- hangup goes true the moment the shell's right is
-- dropped, while its final writes are still sitting in the queue.
--
-- ONE timer for the whole pump rather than thread.recvtimeout per
-- message: a chatty program would otherwise take a timer slot per line
-- of output, and the timer table is finite.
local function pump(s, ms)
	if s.waiting then
		return "settled"
	end
	local t = sys.timer(ms)

	if not t then
		return "timeout"
	end

	-- the timer case is only ever CONSULTED when the queue comes up
	-- empty, so a program producing output faster than this loop
	-- drains it would keep the tryrecv branch fed and never reach the
	-- deadline at all -- unbounded output meaning an unbounded pump,
	-- with SCROLLBACK bounding the memory and nothing bounding the
	-- time. reordering the alt cases cannot fix it (this alt returns
	-- the first ready case in array order, with no randomisation,
	-- unlike libthread's and go's), so the deadline is checked in the
	-- drain path itself. one clock read per message is the price.
	local deadline = sys.uptime_ms() + ms

	local function done(how)
		sys.close(t)
		return how
	end

	while not s.waiting do
		local ok, m = sys.tryrecv(s.port)

		if ok then
			absorb(s, m)
			-- a readline that landed on this very message wins
			-- over the deadline: the output really is complete.
			if not s.waiting and sys.uptime_ms() >= deadline then
				return done("timeout")
			end
		elseif sys.hungup(s.port) then
			-- nothing queued and nobody else holds the port: the
			-- shell is gone and no readline is ever coming.
			return done("gone")
		else
			-- park until a message arrives, a right is dropped
			-- (port_unref wakes receivers precisely so the hangup
			-- test above re-runs), or the deadline passes.
			local which, am =
			    thread.alt({ { port = s.port }, { port = t } })

			if which == 2 then
				return done("timeout")
			end
			absorb(s, am)
		end
	end
	return done("settled")
end

-- hand the parked readline its line. the right is CLOSED afterwards:
-- rights are copied on transfer, so every readline delivers another
-- one of ours to the same per-proc reply port, and keeping them would
-- leak a right per line typed.
local function deliver(s, line)
	local r = s.waiting

	s.waiting = nil
	if not r then
		return false
	end
	-- as in lib/mnt.lua: the pcall catches a bad right, `sent` catches
	-- a dead or full port, which sys.send reports rather than raises.
	local ok, sent = pcall(sys.send, r, line)

	pcall(sys.close, r)
	return ok and sent
end

-- NEVER close a port some coroutine may be parked on.
--
-- thread.run hands every parked port to sys.altblock in ONE call, so a
-- right that went away underneath it raises "bad receive right" from
-- the scheduler itself -- which kills this entire proc, every other
-- session with it, rather than the one session being torn down. that
-- is what typing `exit` did: the shell exited, the janitor heard the
-- notice and closed the port while the request handler was still
-- parked on it in pump().
--
-- so a busy session -- one whose handler is inside pump() right now --
-- is only MARKED here. the handler tears it down when it returns,
-- which it will, because pump() now notices the hangup itself.
local function destroy(S, id)
	local s = S.sessions[id]

	if not s then
		return
	end
	if s.busy then
		s.dead = true
		return
	end
	-- there is no sys.kill. dropping our right to the console port is
	-- what ends a shell that is still running: the port goes dead,
	-- thread.readline's request can no longer be delivered, and it
	-- returns nil -- which dos's repl already treats as end of
	-- session. that is srv.lua's lifetime rule (the last right going
	-- away is what shuts a thing down) rather than a shutdown message,
	-- which any one holder could otherwise fire at everyone else.
	--
	-- this only works because readline REPORTS the dead port. a dead
	-- port drops silently rather than raising, so before that check
	-- existed the shell parked in readline forever and reaping an idle
	-- session leaked its proc -- invisibly, since the session slot was
	-- freed either way.
	if s.waiting then
		pcall(sys.close, s.waiting)
	end
	pcall(sys.close, s.port)
	S.sessions[id] = nil
	S.count = S.count - 1
end

-- ids are a counter mixed with the clock. NOT unguessable, and that is
-- a deliberate limit rather than an oversight: a guessed id lets you
-- type into a stranger's shell, which is rude, but grants no authority
-- -- the shell it reaches is one anybody can create for themselves by
-- asking. anything that made a session worth stealing (a private
-- mount, a login) would need real session secrets first.
local function newid(S)
	S.n = S.n + 1
	return string.format("%d-%x", S.n, sys.uptime_ms() % 0x1000000)
end

local function create(S)
	if S.count >= M.MAXSESSIONS then
		return nil, "too many sessions"
	end
	local port = sys.newport()

	if not port then
		return nil, "out of ports"
	end
	local pid, h = sys.spawn(VISITOR, { name = "visitor" })

	if not pid then
		sys.close(port)
		return nil, "out of procs"
	end
	sys.send(h, {
		cons = { __right = port },
		nsdesc = S.nsdesc,
		banner = S.banner,
	})
	-- nothing further is ever said to the visitor: its console is the
	-- port, and this right only existed to deliver that one message.
	sys.close(h)
	sys.monitor(pid)

	-- busy from birth: the caller pumps for the banner before it
	-- replies, and the janitor must not close the port under that pump
	-- any more than under a later one. the caller clears it.
	local s = {
		id = newid(S), port = port, pid = pid,
		out = {}, outlen = 0, waiting = nil, busy = true,
		touched = sys.uptime_ms(),
	}

	S.sessions[s.id] = s
	S.count = S.count + 1
	return s
end

-- the janitor: reaps idle sessions, and hears the exit notices that
-- sys.monitor delivers to this proc's own port. a shell can end on its
-- own -- exit, ^d, a crash -- and with MAXSESSIONS this small, leaking
-- the slot until the idle timeout would be felt.
local function janitor(S)
	while true do
		local m = thread.recvtimeout(sys.SELF, M.TICK_MS)
		local now = sys.uptime_ms()

		if type(m) == "table" and m.exit then
			for id, s in pairs(S.sessions) do
				if s.pid == m.exit then
					destroy(S, id)
				end
			end
		end
		for id, s in pairs(S.sessions) do
			if now - s.touched > M.IDLE_MS then
				destroy(S, id)
			end
		end
	end
end

-- ---- http ----

local JSON = { ["Content-Type"] = "application/json" }
local HTML = { ["Content-Type"] = "text/html; charset=utf-8" }

local function jsonresp(status, tbl)
	return { status = status, headers = JSON, body = json.encode(tbl) }
end

local function handler(S)
	return function(req)
		if req.method == "GET" and
		    (req.path == "/" or req.path == "/index.html") then
			return { headers = HTML, body = M.PAGE }
		end

		if req.method == "POST" and req.path == "/session" then
			local s, err = create(S)

			if not s then
				return jsonresp(503, { error = err })
			end
			local how = pump(s, M.SETTLE_MS)

			s.busy = false
			s.touched = sys.uptime_ms()

			-- a shell that died before its first prompt means the
			-- namespace failed to restore, and the visitor chunk
			-- writes the reason before returning.
			if how == "gone" or s.dead then
				local out = flush(s)

				destroy(S, s.id)
				return jsonresp(500,
				    { error = "shell exited at startup",
				      out = out })
			end
			return jsonresp(200, { id = s.id, out = flush(s) })
		end

		local id = req.method == "POST" and
		    req.path:match("^/session/([%w%-]+)$")
		local s = id and S.sessions[id]

		if id and not s then
			-- reaped, or never existed. the page starts over.
			return jsonresp(404, { error = "no such session" })
		end
		if s then
			-- two requests pumping one port would each eat the
			-- other's messages. the page serialises its own
			-- requests, so this only fires on a doubled tab or a
			-- deliberate poke.
			if s.busy then
				return jsonresp(409, { error = "session busy" })
			end
			local line = (req.body or ""):sub(1, M.MAXLINE)
				:gsub("[\r\n].*$", "")

			s.busy = true
			s.touched = sys.uptime_ms()

			-- pump before delivering as well as after: if the last
			-- request timed out, the readline it was waiting for
			-- may have landed since, and the line has nowhere to go
			-- until it is parked.
			local how = pump(s, M.SETTLE_MS)

			if how == "settled" and deliver(s, line) then
				how = pump(s, M.SETTLE_MS)
			elseif how == "settled" then
				how = "gone"	-- the readline reply bounced
			end
			s.busy = false
			s.touched = sys.uptime_ms()

			-- `exit`, ^d and a crash all land here, which is the
			-- normal way a session ends rather than an error: the
			-- shell's last words are already buffered, so they go
			-- back with the notice.
			if how == "gone" or s.dead then
				local out = flush(s)

				destroy(S, s.id)
				return jsonresp(200,
				    { out = out, ended = true })
			end
			if how == "timeout" then
				return jsonresp(200,
				    { out = flush(s), running = true })
			end
			return jsonresp(200, { out = flush(s) })
		end

		return { status = 404, body = "not found\n" }
	end
end

-- ---- the page ----
--
-- one file, no external anything: the machine serving it has no CDN to
-- reach and a page that needed one would be blank. output is appended
-- as TEXT NODES, never innerHTML -- a shell prints whatever a visitor
-- asks it to print, so treating that as markup would be an xss hole
-- with extra steps.

M.PAGE = [==[
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>lua-os</title>
<style>
:root { color-scheme: dark; }
body {
	margin: 0; padding: 1.5rem;
	background: #14161a; color: #d6dae0;
	font: 14px/1.45 ui-monospace, "SF Mono", Menlo, Consolas, monospace;
}
main { max-width: 90ch; margin: 0 auto; }
#scr { white-space: pre-wrap; word-break: break-word; margin: 0; }
form { display: flex; gap: .5ch; margin: 0; }
#ps { color: #7f8794; }
#inp {
	flex: 1; background: none; border: 0; padding: 0;
	color: #e8ecf1; font: inherit; outline: none;
}
#inp:disabled { opacity: .4; }
.err { color: #e0787a; }
</style>
<main>
<pre id="scr"></pre>
<form id="f"><span id="ps">&gt;&nbsp;</span><input id="inp" autofocus
	autocomplete="off" autocapitalize="off" spellcheck="false"
	disabled></form>
</main>
<script>
const scr = document.getElementById('scr');
const inp = document.getElementById('inp');
const f = document.getElementById('f');
let id = null;

function write(t, cls) {
	if (!t) return;
	const n = document.createTextNode(t);
	if (cls) {
		const s = document.createElement('span');
		s.className = cls;
		s.appendChild(n);
		scr.appendChild(s);
	} else {
		scr.appendChild(n);
	}
	window.scrollTo(0, document.body.scrollHeight);
}

async function post(path, body) {
	let r;
	try {
		r = await fetch(path, { method: 'POST', body: body || '' });
	} catch (e) {
		write('\n[unreachable: ' + e.message + ']\n', 'err');
		return null;
	}
	let j = null;
	try { j = await r.json(); } catch (e) {}
	if (!r.ok) {
		write('\n[' + r.status + ': ' +
		    ((j && j.error) || 'error') + ']\n', 'err');
		if (j && j.out) write(j.out);
		if (r.status === 404) id = null;
		return null;
	}
	return j;
}

async function start(clear) {
	const j = await post('/session');
	if (!j) return;
	id = j.id;
	if (clear) scr.textContent = '';
	write(j.out);
	inp.disabled = false;
	inp.focus();
}

f.addEventListener('submit', async (e) => {
	e.preventDefault();
	if (!id || inp.disabled) return;
	const line = inp.value;
	inp.value = '';
	inp.disabled = true;
	// nothing on the far end echoes: cons.lua's line editor is what
	// normally does it, and this session is not cons.
	write(line + '\n');
	const j = await post('/session/' + id, line);
	if (j) {
		write(j.out);
		if (j.running) {
			// no readline was parked, so the line was not
			// delivered -- press enter again to collect more.
			write('[still running]\n', 'err');
		}
		if (j.ended) {
			id = null;
			write('\n[session ended]\n\n', 'err');
			await start(false);
			return;
		}
	}
	inp.disabled = false;
	inp.focus();
});

write('connecting...\n');
start(true);
</script>
]==]

-- ---- entry point ----
--
-- blocks forever, like http.serve. nsdesc is what ns:describe()
-- returns -- see the warning above about which kinds are safe to hand
-- a stranger.
function M.serve(tcp, port, nsdesc, opts)
	opts = opts or {}

	local S = {
		sessions = {}, count = 0, n = 0,
		nsdesc = nsdesc,
		banner = opts.banner,
	}

	thread.spawn(function() janitor(S) end)
	return require("http").serve(tcp, port, handler(S), opts.onready)
end

return M
