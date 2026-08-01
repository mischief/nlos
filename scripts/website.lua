#!/usr/bin/env lua5.4
-- website.lua IMG -- boots IMG NORMALLY, with the webterm service
-- enabled, and forwards host port WEB_PORT (default 8080) to it.
--
-- it used to inject test/boot/srvweb.lua as a fw_cfg payload, which
-- REPLACES init.lua -- so the payload had to bring the machine up
-- itself, and the DHCP client it forgot cost four seconds of every
-- boot. now init boots the machine and svc/webterm.lua is a service
-- on top of it. see lib/svc.lua.
--
-- the service is commented out in the image's /etc/services.lua,
-- because a machine that hands anonymous visitors a shell should be a
-- deliberate choice rather than a default. so this script injects a
-- services.lua that enables it -- which needs no change to the disk
-- image, and is exactly how you would enable it for real.
--
-- the guest console stays on stdio, so you can watch it while poking
-- at the page -- and unlike before, the repl is there too, so `ps`
-- shows you every visitor session.
--
-- ---- why this shells out to a generated sh script rather than doing
-- its own temp-file/cleanup bookkeeping ----
--
-- the two temp files (an injected services.lua, a private varstore
-- copy) MUST be removed even if the user Ctrl-Cs qemu -- both halves
-- are ephemeral so two of these can run at once (see below). that
-- needs a signal trap (EXIT HUP INT TERM), which stock Lua has no way
-- to install: os.execute never returns control to us if the signal
-- also reaches our own process (the common case, same foreground
-- process group). the shell already solves this correctly, so this
-- script's job is just building the right shell text and one
-- invocation -- the arch table and argument handling are still Lua's.

local scriptdir = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = scriptdir .. "/?.lua;" .. package.path
local arch = require("arch")
local q = arch.quote

local web_port = os.getenv("WEB_PORT") or "8080"
local img = arg[1]

local services_cfg = [[
return {
	-- port 80, not 7777: init's own 9p-over-tcp server already listens
	-- on 7777, and a second listener on one port is EFI_INVALID_PARAMETER.
	-- that conflict could not happen while this replaced init instead of
	-- running beside it.
	{ path = "/svc/webterm.lua", caps = { "tcp" },
	  args = { port = 80 } },
}
]]

print("web terminal will be at http://localhost:" .. web_port ..
    "/ once dhcp lands")

local sh = string.format([[
set -eu
svccfg=$(mktemp -t luaos-svc.XXXXXX)
cat > "$svccfg" <<'CFG'
%s
CFG
# EPHEMERAL, both halves, so two of these can run at once and neither
# touches the build tree.
#
# -snapshot sends disk writes to a temp file and opens the image
# read-only, which is what lets a second instance start at all: without
# it qemu takes a write lock and the second boot dies with `Failed to get
# "write" lock`. it also means a session cannot leave anything behind on
# the ESP, which for a payload that hands strangers a shell is the right
# default rather than a convenience.
#
# the varstore needs the same treatment for the same reason -- it is
# opened read-write -- so it goes to a private temp copy rather than a
# shared ./OVMF_VARS.fd in whatever directory you happened to run from.
vars=$(mktemp -t luaos-vars.XXXXXX)
trap 'rm -f "$vars" "$svccfg"' EXIT HUP INT TERM
cp %s "$vars"

# not exec: the trap has to survive to clean the varstore up
%s -nographic %s %s %s -snapshot \
	-netdev user,id=n0,hostfwd=tcp::%s-:80 \
	-device %s,netdev=n0 \
	-serial mon:stdio \
	%s \
	-fw_cfg name=opt/org.luaos.services,file="$svccfg" \
	-drive if=pflash,format=raw,readonly=on,file=%s \
	-drive if=pflash,format=raw,file="$vars" \
	-drive %s,file=%s
]], services_cfg, q(arch.FW_VARS), arch.QEMU, arch.MACHINE, arch.VIDEO,
    arch.RNG, web_port, arch.NIC, arch.wire_args("null"), q(arch.FW_CODE),
    arch.BLK, q(img))

os.exit(os.execute(sh) and 0 or 1)
