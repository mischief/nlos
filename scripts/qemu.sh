#!/bin/sh
# qemu.sh IMG -- interactive run.
# com1 = console on stdio, the 9p wire on ./9p.sock (in cwd, which for
# `ninja qemu` is the build directory). virtio-net-pci + user-mode
# networking gives the net task a NIC; guest gets a DHCP lease and can
# be reached via qemu's usermode NAT (hostfwd if you need inbound).
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$here/arch.sh"

img=$1

test -e OVMF_VARS.fd || cp "$FW_VARS" OVMF_VARS.fd

exec $QEMU -nographic $MACHINE $VIDEO \
	-netdev user,id=n0,hostfwd=tcp::7777-:7777 \
	-device $NIC,netdev=n0 \
	-serial mon:stdio \
	$(wire_args socket 9p.sock) \
	-drive if=pflash,format=raw,readonly=on,file="$FW_CODE" \
	-drive if=pflash,format=raw,file=OVMF_VARS.fd \
	-drive $BLK,file="$img"
