#!/bin/sh
# website.sh IMG -- boots IMG with test/boot/srvweb.lua injected as the
# boot payload (replacing init.lua) via fw_cfg, same mechanism
# scripts/boottest.sh uses for tests. serves the browser shell on host
# port WEB_PORT (default 8080), via qemu's usermode NAT hostfwd.
#
# the guest console stays on stdio, so you can watch it while poking at
# the page: every visitor session is a real proc, and `ps` from the
# repl would show them -- except this payload runs the web server
# instead of a repl, so the interesting view is the serial log.
set -eu

WEB_PORT=${WEB_PORT:-8080}

img=$1
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$here/scripts/arch.sh"
payload="$here/test/boot/srvweb.lua"

test -e OVMF_VARS.fd || cp "$FW_VARS" OVMF_VARS.fd

echo "web terminal will be at http://localhost:$WEB_PORT/ once dhcp lands"

exec $QEMU -nographic $MACHINE $VIDEO \
	-netdev user,id=n0,hostfwd=tcp::"$WEB_PORT"-:7777 \
	-device $NIC,netdev=n0 \
	-serial mon:stdio \
	$(wire_args null) \
	-fw_cfg name=opt/org.luaos.test,file="$payload" \
	-drive if=pflash,format=raw,readonly=on,file="$FW_CODE" \
	-drive if=pflash,format=raw,file=OVMF_VARS.fd \
	-drive $BLK,file="$img"
