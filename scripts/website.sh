#!/bin/sh
# website.sh IMG -- boots IMG NORMALLY, with the webterm service enabled,
# and forwards host port WEB_PORT (default 8080) to it.
#
# it used to inject test/boot/srvweb.lua as a fw_cfg payload, which
# REPLACES init.lua -- so the payload had to bring the machine up itself,
# and the DHCP client it forgot cost four seconds of every boot. now init
# boots the machine and svc/webterm.lua is a service on top of it. see
# lib/svc.lua.
#
# the service is commented out in the image's /etc/services.lua, because a
# machine that hands anonymous visitors a shell should be a deliberate
# choice rather than a default. so this script injects a services.lua that
# enables it -- which needs no change to the disk image, and is exactly
# how you would enable it for real.
#
# the guest console stays on stdio, so you can watch it while poking at
# the page -- and unlike before, the repl is there too, so `ps` shows you
# every visitor session.
set -eu

WEB_PORT=${WEB_PORT:-8080}

img=$1
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$here/scripts/arch.sh"
# an overriding /etc/services.lua, injected rather than baked in
svccfg=$(mktemp -t luaos-svc.XXXXXX)
cat > "$svccfg" <<'CFG'
return {
	-- port 80, not 7777: init's own 9p-over-tcp server already listens
	-- on 7777, and a second listener on one port is EFI_INVALID_PARAMETER.
	-- that conflict could not happen while this replaced init instead of
	-- running beside it.
	{ path = "/svc/webterm.lua", caps = { "tcp" },
	  args = { port = 80 } },
}
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
cp "$FW_VARS" "$vars"

echo "web terminal will be at http://localhost:$WEB_PORT/ once dhcp lands"

# not exec: the trap has to survive to clean the varstore up
$QEMU -nographic $MACHINE $VIDEO -snapshot \
	-netdev user,id=n0,hostfwd=tcp::"$WEB_PORT"-:80 \
	-device $NIC,netdev=n0 \
	-serial mon:stdio \
	$(wire_args null) \
	-fw_cfg name=opt/org.luaos.services,file="$svccfg" \
	-drive if=pflash,format=raw,readonly=on,file="$FW_CODE" \
	-drive if=pflash,format=raw,file="$vars" \
	-drive $BLK,file="$img"
