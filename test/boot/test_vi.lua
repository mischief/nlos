-- vi (bin/vi.lua) driven end to end through the program ABI, with a
-- scripted terminal standing in for a person at a console.
--
-- the claim: vi opens a file over the namespace, takes keystrokes over the
-- tty capability (lib/caps.lua, lib/prog.lua), and writes the file back --
-- the same path a serial console or an ssh session drives, minus the
-- human. the fake terminal answers the raw tty protocol cons and sshd
-- answer: rawon/rawoff, getch, and write.
--
-- keystrokes are modelled as BURSTS, because that is what the Escape
-- timeout hinges on. within a burst getch-with-a-timeout returns the next
-- byte; at a burst boundary it returns "" (a timeout), which is how vi
-- tells a lone Escape from the first byte of an arrow sequence. so a burst
-- of just "\27" is an Escape keypress, exactly as on a real terminal.
local sys = require("los.sys")
local thread = require("los.thread")
local ns = require("ns")
local tap = require("tap")

tap.plan(11)

local N = ns.new()
local espcaps = sys.granted()

N:mount("/", require("mnt").new(espcaps.esp), "mnt",
    { port = { __right = espcaps.esp } })

-- a scripted terminal over a port. bursts is a list of byte strings; the
-- first is the cursor-position report vi's detect_size asks for, so it
-- does not eat the script.
local function terminal(bursts)
	local port = sys.newport()
	local bi, ci = 1, 1
	local writes = {}

	-- next byte across burst boundaries (a blocking getch, no timeout)
	local function nextbyte()
		while bi <= #bursts and ci > #bursts[bi] do
			bi = bi + 1
			ci = 1
		end
		if bi > #bursts then
			return nil
		end
		local b = bursts[bi]:sub(ci, ci)

		ci = ci + 1
		return b
	end

	-- next byte only within the current burst; a boundary is a timeout
	local function nextbyte_timed()
		if bi <= #bursts and ci <= #bursts[bi] then
			local b = bursts[bi]:sub(ci, ci)

			ci = ci + 1
			return b
		end
		return nil
	end

	-- serve until `done()` says vi has exited. returns everything vi drew.
	local function serve(done)
		local deadline = sys.uptime_ms() + 8000

		while not done() and sys.uptime_ms() < deadline do
			local ok, m = sys.tryrecv(port)

			if ok and type(m) == "table" then
				if m.op == "getch" then
					-- not `a and b() or c()`: nextbyte_timed()
					-- returning nil (a burst boundary -- a
					-- timeout) must stay nil, or the Escape that
					-- hinges on it reads the next key instead.
					local b

					if m.timeout then
						b = nextbyte_timed()
					else
						b = nextbyte()
					end
					sys.send(m.reply.__right, b or "")
				elseif m.op == "write" then
					writes[#writes + 1] = m.data
				end
				-- rawon/rawoff need no answer
			else
				sys.yield()
			end
		end
		return table.concat(writes)
	end

	return port, serve
end

-- run vi over a scripted terminal against file `path`, from `cwd`,
-- returning true once it exits. the report burst answers detect_size; the
-- rest is the script.
local function run_vi(path, script, cwd)
	local report = "\27[24;80R"
	local port, serve = terminal({ report, table.unpack(script) })
	local errport = sys.newport()
	local pid, h = sys.spawn('require("prog").main()', { name = "vi" })

	sys.monitor(pid)
	sys.send(h, {
		path = "/bin/vi.lua",
		name = "vi",
		args = { "vi", path },
		env = { PATH = "/bin" },
		cwd = cwd or "/",
		nsdesc = N:describe(),
		stderr = { __right = errport },
		tty = { __right = port },
	})
	sys.close(h)

	local exited = false
	local reason

	local screen = serve(function()
		if exited then
			return true
		end
		local ok, m = sys.tryrecv(sys.SELF)

		if ok and m and m.exit == pid then
			exited = true
			if not m.normal then
				reason = m.reason or m.exitmsg
			end
		end
		return exited
	end)

	-- surface anything vi wrote to stderr or a crash reason, so a failed
	-- write shows why rather than just a missing file.
	local errs = {}

	while true do
		local ok, m = sys.tryrecv(errport)

		if not ok then
			break
		end
		if m and m.data then
			errs[#errs + 1] = m.data
		end
	end
	sys.close(errport)
	if reason then
		print("# vi crashed: " .. tostring(reason))
	end
	if #errs > 0 then
		print("# vi stderr: " .. table.concat(errs):gsub("\n", " "))
	end
	return exited, screen
end

-- ---- a new file: insert text and save ----
-- "ihello, vi\27:wq\r" -- i to insert, the text, Escape (its own burst,
-- so it resolves), then :wq.
local ok1 = run_vi("/vitest1.txt", { "ihello, vi", "\27", ":wq\r" })

tap.ok(ok1, "vi exited after :wq")
tap.is(N:readfile("/vitest1.txt"), "hello, vi\n",
    "i inserted text and :wq wrote it through the namespace")

-- ---- an existing file: delete a line and save ----
N:writefile("/vitest2.txt", "line one\nline two\nline three\n")

-- "jdd:wq\r" -- down to line 2, dd deletes it (two keys, one burst is
-- fine: getch with no timeout crosses within a burst), then :wq.
local ok2 = run_vi("/vitest2.txt", { "jdd", ":wq\r" })

tap.ok(ok2, "vi exited after editing an existing file")
tap.is(N:readfile("/vitest2.txt"), "line one\nline three\n",
    "j moved down and dd deleted the second line")

-- ---- an ex command through the buffer engine: :s substitution ----
N:writefile("/vitest3.txt", "the quick brown fox\n")

-- ":s/quick/slow/\r:wq\r" -- substitute on the current line, then save.
local ok3 = run_vi("/vitest3.txt", { ":s/quick/slow/\r", ":wq\r" })

tap.ok(ok3, "vi exited after an ex substitution")
tap.is(N:readfile("/vitest3.txt"), "the slow brown fox\n",
    ":s/quick/slow/ ran through the ex engine and wrote the result")

-- ---- Ctrl-C leaves insert mode, like Escape ----
-- "ihi\3:wq\r" -- insert "hi", Ctrl-C (\3) instead of Escape to return to
-- normal mode, then :wq. The efi serial console defers a bare Esc, so this
-- is the instant path a person actually uses there.
local ok4 = run_vi("/vitest4.txt", { "ihi", "\3", ":wq\r" })

tap.ok(ok4, "vi exited after using Ctrl-C to leave insert mode")
tap.is(N:readfile("/vitest4.txt"), "hi\n",
    "Ctrl-C left insert mode so :wq wrote the inserted text")

-- ---- a relative filename resolves against the cwd, not / ----
-- `vi rel.txt` from /bin writes /bin/rel.txt: the namespace has no cwd, so
-- buffer must apply the one the launcher passed. This is the bug where an
-- edit in /n/gefs landed in /. /bin is an existing directory (the ESP has
-- no runtime mkdir), which is all this needs.
local ok5 = run_vi("virel.txt", { "ifrom cwd", "\3", ":wq\r" }, "/bin")

tap.ok(ok5, "vi exited after editing a relative path from a cwd")
tap.is(N:readfile("/bin/virel.txt"), "from cwd\n",
    "a bare filename resolved against the cwd, not the root")
tap.is(N:readfile("/virel.txt"), nil,
    "and did not land in / as it did before")

tap.done()
