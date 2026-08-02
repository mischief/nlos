-- srvd: names for rights.
--
-- This is Plan 9's /srv, and it exists for the reason Plan 9's does: to
-- mount something you have to be able to name it, and in a capability
-- system there is nothing to name it with. A right is not a string. So
-- `mount 9p /n/9p` at a prompt is impossible until some rendezvous
-- exists where a server can leave a right and a client can pick one up.
--
-- Why a port service rather than a dev backend, when /proc and /net are
-- both backends: a capability cannot travel through the dev interface.
-- read() returns a string. A right moves only inside a message, as
-- {__right = h}, so acquiring one has to be a message and cannot be a
-- read. lib/srvfs.lua mounts the listing at /srv so `ls /srv` works,
-- but the right itself comes from here.
--
-- Plan 9 makes the same split and hides it: its /srv is devsrv.c, whose
-- open() hands back a dup of a stored Chan rather than any bytes on the
-- file. The file is the name; the kernel moves the capability.
--
--   {op="post",   name=, port={__right=h}}  -> {ok=true}
--   {op="open",   name=}                    -> {port={__right=h}}
--   {op="remove", name=}                    -> {ok=true}
--   {op="list"}                             -> {names={...}}
--
-- Holding a right to srvd is itself authority: it is permission to
-- publish under a name others will trust, and to pick up anything
-- published. There is no per-name access control, exactly as Plan 9 has
-- none beyond the file permissions -- what protects a service is that
-- nothing hands you srvd unless it means to.

local sys = require("los.sys")
local thread = require("los.thread")

local names = {}	-- name -> right this proc holds

-- a right arrives wrapped, exactly as it was sent: {__right = h}, not a
-- bare handle. lib/srv.lua unwraps the same way.
--
-- The right is closed after answering. Each request carries its own --
-- srvc uses thread.replyport() -- so holding it would leak a handle per
-- call, and the caller cannot be answered twice.
local function reply(m, msg)
	local h = type(m.reply) == "table" and m.reply.__right or nil

	if h then
		sys.send(h, msg)
		sys.close(h)
	end
end

-- a name is a single path element: it is going to be walked as one in
-- /srv, and a name with a slash in it would be a directory that does
-- not exist.
local function badname(n)
	return type(n) ~= "string" or n == "" or #n > 64 or
	    n:find("[/%z]") ~= nil or n == "." or n == ".."
end

while true do
	local m = thread.recv(sys.SELF)

	if m.op == "post" then
		if badname(m.name) then
			reply(m, { ok = false, err = "bad name" })
		elseif not (m.port and m.port.__right) then
			reply(m, { ok = false, err = "no right supplied" })
		elseif names[m.name] then
			reply(m, { ok = false, err = "already posted" })
		else
			-- the right arrived in the message and is ours now;
			-- it stays held until removed, which is what keeps
			-- the served port alive after its poster exits.
			names[m.name] = m.port.__right
			reply(m, { ok = true })
		end
	elseif m.op == "open" then
		local h = names[m.name]

		if not h then
			reply(m, { ok = false, err = "no such service" })
		else
			-- sendright, never the held right itself: handing
			-- over a receive right would let a client take the
			-- server's own requests. The registry keeps its copy,
			-- so many clients can open one name.
			--
			-- thread.giveright rather than a bare sendright,
			-- because sending copies and this server never exits:
			-- one right per lookup, never closed, is a registry
			-- that stops answering after MAXRIGHTS opens.
			reply(m, { ok = true, port = thread.giveright(h) })
		end
	elseif m.op == "remove" then
		local h = names[m.name]

		if not h then
			reply(m, { ok = false, err = "no such service" })
		else
			names[m.name] = nil
			sys.close(h)
			reply(m, { ok = true })
		end
	elseif m.op == "list" then
		local out = {}

		for n in pairs(names) do
			out[#out + 1] = n
		end
		table.sort(out)
		reply(m, { ok = true, names = out })
	else
		reply(m, { ok = false, err = "unknown op" })
	end
end
