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
trap 'rm -f "$vars"' EXIT HUP INT TERM
cp "$FW_VARS" "$vars"

echo "web terminal will be at http://localhost:$WEB_PORT/ once dhcp lands"

# not exec: the trap has to survive to clean the varstore up
$QEMU -nographic $MACHINE $VIDEO -snapshot \
	-netdev user,id=n0,hostfwd=tcp::"$WEB_PORT"-:7777 \
	-device $NIC,netdev=n0 \
	-serial mon:stdio \
	$(wire_args null) \
	-fw_cfg name=opt/org.luaos.test,file="$payload" \
	-drive if=pflash,format=raw,readonly=on,file="$FW_CODE" \
	-drive if=pflash,format=raw,file="$vars" \
	-drive $BLK,file="$img"
