-- The torture harness: random operations against a model of what the
-- answer should be. Driven by test/host_gefs.lua, and portable back to
-- the standalone gefs tree's busted suite it came from.
--
-- Everything else in this suite tests a thing somebody thought of. This
-- tests the things nobody thought of: it picks operations at random,
-- keeps a plain Lua table saying what the filesystem ought to contain,
-- and after every step checks that it does. Between steps it runs the
-- consistency checker, which asserts the invariants the tree's own
-- algorithms assume and never verify -- ordering, balance, the fill
-- numbers in pivot pointers, and that nothing reachable is also free.
--
-- The seeds are fixed so a failure reproduces. The mix is deliberately
-- unkind: writes that straddle blocks, truncations to unaligned
-- lengths, files that are mostly hole, renames into the middle of a
-- directory, and snapshots taken and dropped while all of that is going
-- on.

local h = require("gefs_helper")
local dat = h.dat

--------------------------------------------------------------------------
-- the model
--
-- A path maps to either a directory or a string. Holes are real zeroes
-- in the model, which is what makes a sparse write and a dense one
-- indistinguishable from outside -- as they should be.

local Model = {}
Model.__index = Model

local function model()
	return setmetatable({ files = {}, dirs = { ["/"] = true } }, Model)
end

function Model:parentof(path)
	local d = path:match("^(.*)/[^/]+$")
	if d == nil or d == "" then
		return "/"
	end
	return d
end

function Model:paths()
	local out = {}
	for p in pairs(self.files) do
		out[#out + 1] = p
	end
	table.sort(out)
	return out
end

function Model:dirpaths()
	local out = {}
	for p in pairs(self.dirs) do
		out[#out + 1] = p
	end
	table.sort(out)
	return out
end

function Model:write(path, off, s)
	local was = self.files[path] or ""
	if #was < off then
		was = was .. ("\0"):rep(off - #was)
	end
	self.files[path] = was:sub(1, off) .. s .. was:sub(off + #s + 1)
end

function Model:truncate(path, len)
	local was = self.files[path] or ""
	if #was > len then
		self.files[path] = was:sub(1, len)
	else
		self.files[path] = was .. ("\0"):rep(len - #was)
	end
end

function Model:children(dir)
	local out = {}
	local pfx = dir == "/" and "/" or (dir .. "/")
	for p in pairs(self.files) do
		if p:sub(1, #pfx) == pfx and not p:sub(#pfx + 1):find("/") then
			out[#out + 1] = p
		end
	end
	for p in pairs(self.dirs) do
		if p ~= "/" and p:sub(1, #pfx) == pfx and not p:sub(#pfx + 1):find("/") then
			out[#out + 1] = p
		end
	end
	return out
end

--------------------------------------------------------------------------
-- comparing the two

local function verify(m, mod, where)
	for _, p in ipairs(mod:paths()) do
		local d = m:walk(p)
		assert(d ~= nil, ("%s: %s is missing"):format(where, p))
		local want = mod.files[p]
		assert(d.length == #want, ("%s: %s is %d bytes, wanted %d"):format(where, p, d.length, #want))
		local got = m:read(d, 0, #want)
		if got ~= want then
			-- report where rather than dumping two long strings
			local at = 1
			while at <= #want and got:sub(at, at) == want:sub(at, at) do
				at = at + 1
			end
			error(("%s: %s differs at byte %d of %d"):format(where, p, at, #want), 2)
		end
	end
	for _, p in ipairs(mod:dirpaths()) do
		local d = m:walk(p)
		assert(d ~= nil, ("%s: directory %s is missing"):format(where, p))
		assert(d.mode & dat.DMDIR ~= 0, ("%s: %s is not a directory"):format(where, p))
	end
end

local function verifydirs(m, mod, where)
	for _, dir in ipairs(mod:dirpaths()) do
		local want = {}
		for _, p in ipairs(mod:children(dir)) do
			want[p:match("[^/]+$")] = true
		end
		local got = {}
		for _, e in ipairs(assert(m:ls(dir))) do
			got[e.name] = true
		end
		for n in pairs(want) do
			assert(got[n], ("%s: %s/%s missing from the listing"):format(where, dir, n))
		end
		for n in pairs(got) do
			assert(want[n], ("%s: %s/%s is in the listing and should not be"):format(where, dir, n))
		end
	end
end

--------------------------------------------------------------------------
-- the run

local function run(opts)
	local rand = h.rng(opts.seed)
	local m, fs, dev = h.mounted({
		blksz = opts.blksz,
		size = opts.size or 256 * 1024 * 1024,
	})
	local mod = model()
	local nfile = 0
	local ndir = 0
	local counts = {}

	local function note(op)
		counts[op] = (counts[op] or 0) + 1
	end

	local function anyfile()
		local ps = mod:paths()
		if #ps == 0 then
			return nil
		end
		return ps[rand(#ps)]
	end

	local function anydir()
		local ps = mod:dirpaths()
		return ps[rand(#ps)]
	end

	local ops = {}

	ops.create = function()
		local dir = anydir()
		nfile = nfile + 1
		local path = (dir == "/" and "/" or dir .. "/") .. ("f%04d"):format(nfile)
		if mod.files[path] or mod.dirs[path] then
			return
		end
		m:createfile(path)
		mod.files[path] = ""
		note("create")
	end

	ops.mkdir = function()
		local dir = anydir()
		if #dir:gsub("[^/]", "") > 5 then
			return
		end
		ndir = ndir + 1
		local path = (dir == "/" and "/" or dir .. "/") .. ("d%03d"):format(ndir)
		if mod.files[path] or mod.dirs[path] then
			return
		end
		m:mkdir(path)
		mod.dirs[path] = true
		note("mkdir")
	end

	ops.write = function()
		local path = anyfile()
		if path == nil then
			return
		end
		local blksz = fs.geom.blksz
		-- a mix of sizes and offsets, chosen to straddle block boundaries
		-- as often as not
		local off, n
		local kind = rand(4)
		if kind == 1 then
			off, n = rand(64) - 1, rand(64)
		elseif kind == 2 then
			off, n = blksz - rand(8), blksz + rand(64)
		elseif kind == 3 then
			off, n = rand(4) * blksz, rand(3) * blksz
		else
			off, n = rand(200000), rand(3000)
		end
		local s = h.randstr(rand, n)
		local d = assert(m:walk(path))
		m:write(d, off, s)
		mod:write(path, off, s)
		note("write")
	end

	ops.truncate = function()
		local path = anyfile()
		if path == nil then
			return
		end
		local was = #mod.files[path]
		if was == 0 then
			return
		end
		local len = rand(was) - 1
		m:truncate(assert(m:walk(path)), len)
		mod:truncate(path, len)
		note("truncate")
	end

	ops.remove = function()
		local path = anyfile()
		if path == nil then
			return
		end
		m:removepath(path)
		mod.files[path] = nil
		note("remove")
	end

	ops.rmdir = function()
		local ps = mod:dirpaths()
		for i = #ps, 1, -1 do
			local p = ps[i]
			if p ~= "/" and #mod:children(p) == 0 then
				m:removepath(p)
				mod.dirs[p] = nil
				note("rmdir")
				return
			end
		end
	end

	ops.rename = function()
		local path = anyfile()
		if path == nil then
			return
		end
		nfile = nfile + 1
		local dir = mod:parentof(path)
		local newname = ("r%04d"):format(nfile)
		local newpath = (dir == "/" and "/" or dir .. "/") .. newname
		if mod.files[newpath] or mod.dirs[newpath] then
			return
		end
		m:wstat(assert(m:walk(path)), { name = newname })
		mod.files[newpath] = mod.files[path]
		mod.files[path] = nil
		note("rename")
	end

	ops.sync = function()
		fs:sync()
		note("sync")
	end

	local snaps = {}
	local nsnap = 0

	ops.snap = function()
		if #snaps >= 4 then
			return
		end
		fs:sync()
		nsnap = nsnap + 1
		local name = ("t%03d"):format(nsnap)
		fs:snapshot("main", name, 0)
		fs:sync()
		-- remember what the snapshot should hold, so it can be checked later
		local held = {}
		for k, v in pairs(mod.files) do
			held[k] = v
		end
		local dirs = {}
		for k in pairs(mod.dirs) do
			dirs[k] = true
		end
		snaps[#snaps + 1] = { name = name, files = held, dirs = dirs }
		note("snap")
	end

	ops.dropsnap = function()
		if #snaps == 0 then
			return
		end
		local i = rand(#snaps)
		local s = table.remove(snaps, i)
		fs:delsnapshot(s.name)
		fs:sync()
		note("dropsnap")
	end

	ops.reopen = function()
		fs:sync()
		fs = h.gefs.open(dev)
		m = fs:mount("main")
		note("reopen")
	end

	-- weights: the operations that stress the tree run far more often
	-- than the ones that stress the commit
	local wheel = {}
	local function weigh(name, n)
		for _ = 1, n do
			wheel[#wheel + 1] = ops[name]
		end
	end
	weigh("create", 14)
	weigh("mkdir", 4)
	weigh("write", 34)
	weigh("truncate", 8)
	weigh("remove", 8)
	weigh("rmdir", 2)
	weigh("rename", 5)
	weigh("sync", 4)
	weigh("snap", opts.snapshots and 2 or 0)
	weigh("dropsnap", opts.snapshots and 2 or 0)
	weigh("reopen", opts.reopen and 1 or 0)

	-- opts.fsck runs the deep pass instead of the tree checks: reachability
	-- and the namespace, which cost a sweep of every arena. Leaked space
	-- is allowed, because reopening right after a commit loses that
	-- commit's reclamation by design -- but only if fix gets all of it
	-- back and the volume is sound afterwards.
	local function check(where)
		h.sound(fs, where)
		if not opts.fsck then
			return
		end
		local fail, report = fs:fsck({ maxleaks = 4 })
		local shown = math.min(#report.leaked, 4)
		if #report.leaked > 4 then
			shown = shown + 1
		end
		if #fail - shown > 0 then
			error(
				("%s: fsck found %d beyond the leaks\n  %s"):format(where, #fail - shown, table.concat(fail, "\n  ")),
				2
			)
		end
		if #report.leaked > 0 then
			local f2, r2 = fs:fsck({ fix = true })
			if r2.reclaimed ~= #report.leaked then
				error(
					("%s: %d leaked, %d reclaimable\n  %s"):format(
						where,
						#report.leaked,
						r2.reclaimed,
						table.concat(f2, "\n  ")
					),
					2
				)
			end
			local f3 = fs:fsck()
			if #f3 > 0 then
				error(("%s: %d problems after reclaiming\n  %s"):format(where, #f3, table.concat(f3, "\n  ")), 2)
			end
		end
	end

	for step = 1, opts.steps do
		wheel[rand(#wheel)]()

		if step % (opts.verify or 25) == 0 then
			verify(m, mod, ("seed %d step %d"):format(opts.seed, step))
		end
		if step % (opts.check or 50) == 0 then
			check(("seed %d step %d"):format(opts.seed, step))
		end
	end

	verify(m, mod, "final")
	verifydirs(m, mod, "final")
	check("final")

	-- and it all has to survive the round trip through the disk
	fs:sync()
	local fs2 = h.gefs.open(dev)
	local m2 = fs2:mount("main")
	verify(m2, mod, "reopened")
	verifydirs(m2, mod, "reopened")
	h.sound(fs2, "reopened")

	for _, s in ipairs(snaps) do
		local sm = fs2:mount(s.name)
		local held = setmetatable({ files = s.files, dirs = s.dirs }, Model)
		verify(sm, held, "snapshot " .. s.name)
	end

	return counts
end

return { run = run, model = model, verify = verify, verifydirs = verifydirs }
