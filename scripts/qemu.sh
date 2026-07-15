#!/bin/sh
# qemu.sh IMG -- interactive run.
# com1 = console on stdio, com2 = 9p wire on ./9p.sock (in cwd, which
# for `ninja qemu` is the build directory).
set -eu

OVMF_CODE=${OVMF_CODE:-/usr/share/edk2-ovmf/OVMF_CODE.fd}
OVMF_VARS=${OVMF_VARS:-/usr/share/edk2-ovmf/OVMF_VARS.fd}

img=$1

test -e OVMF_VARS.fd || cp "$OVMF_VARS" OVMF_VARS.fd

exec qemu-system-x86_64 -nographic -enable-kvm -cpu max -net none \
	-serial mon:stdio \
	-serial unix:9p.sock,server,nowait \
	-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
	-drive if=pflash,format=raw,file=OVMF_VARS.fd \
	-drive format=raw,file="$img"
