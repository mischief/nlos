#!/usr/bin/env lua5.4
-- fetch-mcp.lua IMG -- boots IMG with test/boot/fetch_mcp.lua injected
-- as the boot payload (replacing init.lua) via fw_cfg, same mechanism
-- tools/boottest.lua uses for tests. exposes its mcp server (a
-- single "fetch" tool, see the payload itself) on host port MCP_PORT
-- (default 8090), via qemu's usermode NAT hostfwd.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."
local here = scriptdir .. "/.."
package.path = scriptdir .. "/?.lua;" .. package.path
local arch = require("arch")
local q = arch.quote

local mcp_port = os.getenv("MCP_PORT") or "8090"
local img = arg[1]
local payload = here .. "/test/boot/fetch_mcp.lua"

if not io.open("OVMF_VARS.fd", "rb") then
	arch.copyvars("OVMF_VARS.fd")
end

local cmd = table.concat({
	arch.QEMU, "-nographic", arch.MACHINE, arch.VIDEO, arch.RNG,
	"-netdev user,id=n0,hostfwd=tcp::" .. mcp_port .. "-:8090",
	"-device " .. arch.NIC .. ",netdev=n0",
	"-serial mon:stdio",
	arch.wire_args("null"),
	"-fw_cfg name=opt/org.luaos.test,file=" .. q(payload),
	"-drive if=pflash,format=raw,readonly=on,file=" .. q(arch.FW_CODE),
	"-drive if=pflash,format=raw,file=OVMF_VARS.fd",
	"-drive " .. arch.BLK .. ",file=" .. q(img),
}, " ")

os.exit(os.execute(cmd) and 0 or 1)
