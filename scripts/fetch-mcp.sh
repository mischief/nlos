#!/bin/sh
# fetch-mcp.sh IMG -- boots IMG with test/boot/fetch_mcp.lua injected
# as the boot payload (replacing init.lua) via fw_cfg, same mechanism
# scripts/boottest.sh uses for tests. exposes its mcp server (a
# single "fetch" tool, see the payload itself) on host port MCP_PORT
# (default 8090), via qemu's usermode NAT hostfwd.
set -eu

MCP_PORT=${MCP_PORT:-8090}

img=$1
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$here/scripts/arch.sh"
payload="$here/test/boot/fetch_mcp.lua"

test -e OVMF_VARS.fd || cp "$FW_VARS" OVMF_VARS.fd

exec $QEMU -nographic $MACHINE $VIDEO \
	-netdev user,id=n0,hostfwd=tcp::"$MCP_PORT"-:8090 \
	-device $NIC,netdev=n0 \
	-serial mon:stdio \
	$(wire_args null) \
	-fw_cfg name=opt/org.luaos.test,file="$payload" \
	-drive if=pflash,format=raw,readonly=on,file="$FW_CODE" \
	-drive if=pflash,format=raw,file=OVMF_VARS.fd \
	-drive $BLK,file="$img"
