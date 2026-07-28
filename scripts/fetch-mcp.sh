#!/bin/sh
# fetch-mcp.sh IMG -- boots IMG with test/boot/fetch_mcp.lua injected
# as the boot payload (replacing init.lua) via fw_cfg, same mechanism
# scripts/boottest.sh uses for tests. exposes its mcp server (a
# single "fetch" tool, see the payload itself) on host port MCP_PORT
# (default 8090), via qemu's usermode NAT hostfwd.
set -eu

OVMF_CODE=${OVMF_CODE:-/usr/share/edk2-ovmf/OVMF_CODE.fd}
OVMF_VARS=${OVMF_VARS:-/usr/share/edk2-ovmf/OVMF_VARS.fd}
MCP_PORT=${MCP_PORT:-8090}

img=$1
here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
payload="$here/test/boot/fetch_mcp.lua"

test -e OVMF_VARS.fd || cp "$OVMF_VARS" OVMF_VARS.fd

exec qemu-system-x86_64 -nographic -enable-kvm -cpu max \
	-netdev user,id=n0,hostfwd=tcp::"$MCP_PORT"-:8090 \
	-device virtio-net-pci,netdev=n0 \
	-serial mon:stdio \
	-serial null \
	-fw_cfg name=opt/org.luaos.test,file="$payload" \
	-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
	-drive if=pflash,format=raw,file=OVMF_VARS.fd \
	-drive format=raw,file="$img"
