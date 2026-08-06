-- gefs served to several PROCS at once, each with several threads.
--
-- test/boot/microvm_gefssrv.lua is the same server hit by coroutines
-- inside ONE proc, which share one mnt: one session, one fid space, and
-- a reply port per thread. That is a different question from this one,
-- and the gap between them is why a silent write loss survived for
-- months -- nothing here had ever put two independent senders on one
-- server port.
--
-- So: six procs, six threads each, four files apiece. Separate sessions
-- and separate fid spaces across the procs, a shared session within
-- each, and under -smp the procs are genuinely parallel rather than
-- interleaved.
--
-- Thirty-six writers and not sixteen, because sixteen never fill the
-- server's port queue. Filling it is what this test is for: a refused
-- send is backpressure that lib/mnt waits out and repeats, and below
-- that width nothing exercises the waiting. Not larger still, because
-- eight threads x eight files exceeds what this machine finishes inside
-- the harness timeout, and a bigger number would only measure qemu.
--
-- ---- what the sizes are for ----
--
-- The failure this guards against was a function of payload size
-- against two bounds -- the port queue, and the backend's block -- so
-- the sizes are chosen against dev.IOUNIT rather than being round:
-- comfortably under it, one byte under, exactly it, and one byte over.
-- The last is the interesting one: it is the smallest write that spans
-- two requests.
--
-- One file per proc is then rewritten at an unaligned offset, because a
-- write that does not cover a whole block makes gefs read the old block
-- before writing it (fsops.lua), and nothing else here produces one --
-- writefile always starts at zero, so its chunks are aligned by
-- construction.

local sys = require("los.sys")
local thread = require("los.thread")
local ns = require("ns")
local mnt = require("mnt")
local dev = require("dev")
local tap = require("tap")

tap.plan(6)

local NPROC, NTHREAD, NFILE = 6, 6, 4

-- distinct per (proc, thread, file) and cheap to regenerate for the
-- comparison, so nothing has to be kept around to check against
local function content(p, t, f)
	local sizes = { 1000, dev.IOUNIT - 1, dev.IOUNIT, dev.IOUNIT + 1 }
	local tag = ("p%dt%df%d."):format(p, t, f)
	local n = sizes[f]

	return tag:rep(n // #tag + 1):sub(1, n)
end

local function path(p, t, f)
	return ("/g/p%d_t%d_f%d"):format(p, t, f)
end

local function main()
	local caps = sys.granted()

	if not tap.ok(caps.blk ~= nil, "a blk capability was granted") then
		tap.diag("no virtio-blk device; the rest cannot run")
		tap.done()
		return
	end

	local code = io.open("/task/gefssrv.lua"):read("a")
	local _, g = sys.spawn(code, { name = "gefssrv" })

	sys.send(g, { blk = { __right = caps.blk }, label = "main",
	    syncms = 500 })

	-- the parent mounts too, to seed nothing and check everything at
	-- the end through a session of its own
	local N = ns.new()

	if not tap.ok(N:mount("/g", mnt.new(g), "mnt",
	    { port = { __right = g } }), "mounted the gefs server") then
		tap.done()
		return
	end

	-- ---- the clients ----
	--
	-- each is a whole proc with its own namespace, so it establishes
	-- its own session and gets its own fid space. The right travels in
	-- the spawn argument, which is what makes a mount a capability.
	local client = [==[
		local sys = require("los.sys")
		local thread = require("los.thread")
		local ns = require("ns")
		local mnt = require("mnt")
		local dev = require("dev")
		local a = ...

		local function content(p, t, f)
			local sizes = { 1000, dev.IOUNIT - 1, dev.IOUNIT,
			    dev.IOUNIT + 1 }
			local tag = ("p%dt%df%d."):format(p, t, f)
			local n = sizes[f]

			return tag:rep(n // #tag + 1):sub(1, n)
		end
		local function path(p, t, f)
			return ("/g/p%d_t%d_f%d"):format(p, t, f)
		end

		local me, nthread, nfile = a.me, a.nthread, a.nfile

		-- under thread.run(), like the parent: a spawned coroutine
		-- is driven by the scheduler and by nothing else, so a bare
		-- recv in a main body waits forever on threads that never
		-- get to start.
		thread.spawn(function()

		local N = ns.new()

		assert(N:mount("/g", mnt.new(a.srv.__right), "mnt",
		    { port = { __right = a.srv.__right } }))

		local bad = {}
		local done = thread.chancreate(nthread)

		for t = 1, nthread do
			thread.spawn(function()
				for f = 1, nfile do
					local want = content(me, t, f)
					local p = path(me, t, f)
					-- assert inside the pcall: writefile
					-- REPORTS a failed write instead of
					-- raising, so a bare pcall around it
					-- succeeds for a write that never
					-- happened.
					local ok, err = pcall(function()
						return assert(N:writefile(p, want))
					end)

					if not ok then
						bad[#bad + 1] = p .. " write: " ..
						    tostring(err)
					elseif N:readfile(p) ~= want then
						bad[#bad + 1] = p .. " readback"
					end
				end
				done:send(true)
			end)
		end
		for _ = 1, nthread do done:recv() end

		-- and one unaligned rewrite, which is the only thing here
		-- that makes gefs read a block before writing it
		local p = path(me, 1, 3)
		local want = content(me, 1, 3)
		local at = 100
		local patch = ("X"):rep(5000)
		local fh = N:open(p, "rw")

		if fh then
			fh:seek("set", at)
			fh:write(patch)
			fh:close()
			want = want:sub(1, at) .. patch ..
			    want:sub(at + #patch + 1)
			if N:readfile(p) ~= want then
				bad[#bad + 1] = p .. " unaligned rewrite"
			end
		else
			bad[#bad + 1] = p .. " open rw"
		end

		sys.send(a.reply.__right, { me = me, bad = bad })
		end)
		thread.run()
	]==]

	local me = sys.sendright(0)

	for p = 1, NPROC do
		sys.spawn(client, {
			name = "gclient" .. p,
			arg = {
				me = p, nthread = NTHREAD, nfile = NFILE,
				srv = { __right = g },
				reply = { __right = me },
			},
		})
	end

	local heard, failures = 0, {}

	-- thread.recv, not sys.tryrecv: this runs under thread.run(), which
	-- holds the proc's ports in its own altblock. A bare receive in the
	-- main body races the scheduler for them.
	while heard < NPROC do
		local m = thread.recv(sys.SELF)

		heard = heard + 1
		for _, b in ipairs(m.bad or {}) do
			failures[#failures + 1] =
			    ("proc %d: %s"):format(m.me, b)
		end
	end

	for _, f in ipairs(failures) do
		tap.diag(f)
	end
	tap.ok(#failures == 0,
	    ("%d procs x %d threads x %d files, each verified by its writer")
	    :format(NPROC, NTHREAD, NFILE))

	-- ---- and again from a proc that wrote none of it ----
	--
	-- a client checking its own writes cannot tell a write that landed
	-- from one that was only remembered; this session never saw them.
	local reread = {}

	for p = 1, NPROC do
		for t = 1, NTHREAD do
			for f = 1, NFILE do
				-- every proc rewrites its own (1,3) at an
				-- unaligned offset; its writer already
				-- checked the patched content
				if t == 1 and f == 3 then
					goto continue
				end
				if N:readfile(path(p, t, f)) ~= content(p, t, f) then
					reread[#reread + 1] = path(p, t, f)
				end
				::continue::
			end
		end
	end
	for _, r in ipairs(reread) do
		tap.diag("stale or wrong on re-read: " .. r)
	end
	tap.ok(#reread == 0, "every file re-reads correctly from another proc")

	-- ---- the bound that started all this ----
	--
	-- The queue does fill at this width, and a refused send is where
	-- the write used to be lost: it reached the client as dev.Eio, and
	-- NS:writefile handed that back rather than raising, so the loss
	-- was invisible to a caller that had wrapped the write in pcall.
	--
	-- lib/mnt now waits for room and sends again, so a refusal costs
	-- nothing and the count below is a diagnostic rather than a fault.
	-- What proves the waiting works is the two checks above: every file
	-- has its full contents. Before the retry existed they failed here
	-- with seven files short.
	local drop, qpeak = 0, 0

	for _, pt in ipairs(sys.ports()) do
		drop = drop + (pt.dropfull or 0)
		if (pt.qpeak or 0) > qpeak then
			qpeak = pt.qpeak
		end
	end
	tap.diag(("iounit=%d, deepest port queue %d bytes, %d sends refused"):
	    format(dev.IOUNIT, qpeak, drop))
	tap.ok(drop > 0, "the server's queue filled, so backpressure ran")

	local st = sys.stats()
	local elsewhere = 0

	for i, c in ipairs(st.cpu or {}) do
		if i > 1 and (c.dispatched or 0) > 0 then
			elsewhere = elsewhere + 1
		end
	end
	if st.cpus > 1 then
		tap.ok(elsewhere > 0, "the clients ran on more than one cpu")
	else
		tap.ok(elsewhere == 0, "one cpu, so everything shared it")
	end

	tap.done()
end

thread.spawn(main)
thread.run()
