-- sys.atexit: handlers run when a proc's main chunk returns.
--
-- Written because the feature had no test and a merge changed its
-- internals. run_atexit runs on p->L after p->co has finished, which is
-- a state the rest of the kernel never resumes, so the questions worth
-- asking are whether a handler runs at all, whether the kernel api
-- still resolves inside one, and whether the order is the documented
-- LIFO.
--
-- The api question is the one with teeth: self() reads the handler
-- state's extraspace, and the plain-C paths that have no lua_State to
-- consult read cpu_self()->current instead. run_atexit is called from
-- inside run_proc, where dispatch_lap has already published that for
-- the whole resume -- so a handler calling into the kernel must work
-- without run_atexit setting anything itself.

local sys = require("los.sys")
local tap = require("tap")

tap.plan(4)

local me = sys.sendright(0)

-- three handlers, registered in order, each reporting when it runs. A
-- proc whose main chunk simply returns; nothing calls exit.
local pid = sys.spawn([[
	local sys = require("los.sys")
	local a = ...
	local to = a.reply.__right

	for i = 1, 3 do
		sys.atexit(function()
			-- sys.self() inside a handler is the api question:
			-- it resolves through the handler state, not p->co
			sys.send(to, { i = i, self = sys.self() })
		end)
	end
]], { name = "exiter", arg = { reply = { __right = me } } })

tap.ok(pid ~= nil, "the proc spawned")

local got = {}

while #got < 3 do
	local ok, m = sys.tryrecv(0)

	if ok then
		got[#got + 1] = m
	else
		sys.yield()
	end
end

tap.ok(#got == 3, "every registered handler ran")

-- LIFO, which is what the documentation and every other atexit says
tap.ok(got[1].i == 3 and got[2].i == 2 and got[3].i == 1,
    "handlers ran last registered first")

local samepid = true

for _, m in ipairs(got) do
	if m.self ~= pid then
		samepid = false
	end
end
tap.ok(samepid, "sys.self() inside a handler is the proc that is exiting")

tap.done()
