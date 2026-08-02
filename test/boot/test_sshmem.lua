-- What the ssh stack costs a proc, module by module.
--
-- sshd is the heaviest proc on the machine and the obvious suspicion is
-- "all the code it loads". Obvious suspicions about memory are wrong
-- often enough to be worth measuring, so this measures: load each module
-- in order, collect, and report the delta.
--
-- Counted with sys.meminfo, which is the kernel's own per-proc
-- accounting from kalloc rather than collectgarbage("count"), so it sees
-- everything the proc is charged for and not just what Lua's heap knows
-- about.

local tap = require("tap")
local sys = require("los.sys")

local mods = {
	"crypto.util", "crypto.hashstate", "crypto.sha256", "crypto.sha512",
	"crypto.chacha20", "crypto.poly1305", "crypto.drbg",
	"crypto.field25519", "crypto.x25519", "crypto.ed25519",
	"crypto.keccak", "crypto.mlkem768",
	"ssh.wire", "ssh.msg", "ssh.base64", "ssh.keys",
	"ssh.packet", "ssh.kex", "ssh.server",
}

tap.plan(2)

local function settled()
	collectgarbage("collect")
	collectgarbage("collect")
	return (sys.meminfo())
end

local base = settled()
local prev = base
local rows = {}

for _, m in ipairs(mods) do
	local ok, err = pcall(require, m)

	if not ok then
		rows[#rows + 1] = string.format("%-20s FAILED %s", m,
		    tostring(err))
	else
		local now = settled()

		rows[#rows + 1] = string.format("%-20s %7d", m, now - prev)
		prev = now
	end
end

for _, r in ipairs(rows) do tap.diag(r) end

local total = prev - base

tap.diag(string.format("%-20s %7d  (%.0f%% of a %d-byte proc)",
    "TOTAL", total, 100 * total / prev, prev))

tap.ok(total > 0, "the ssh stack costs something measurable")
tap.ok(prev > total, "and is not the whole of the proc")

tap.done()
