#!/bin/sh
# boottest.sh IMG TEST.lua -- boot the image with the test payload
# injected via fw_cfg, wait for the guest to power off, and emit the
# TAP the guest printed on com1. everything else on the serial line is
# passed through as TAP diagnostics on failure.
set -eu

OVMF_CODE=${OVMF_CODE:-/usr/share/edk2-ovmf/OVMF_CODE.fd}
OVMF_VARS=${OVMF_VARS:-/usr/share/edk2-ovmf/OVMF_VARS.fd}
TIMEOUT=${TIMEOUT:-60}

img=$1
payload=$2

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cp "$OVMF_VARS" "$tmp/vars.fd"

# -snapshot: the (possibly shared, parallel) image is never written.
# the guest powers off via ResetSystem(shutdown) when the test is done;
# -no-reboot turns any triple-fault into an exit instead of a hang.
rc=0
timeout "$TIMEOUT" qemu-system-x86_64 \
	-enable-kvm -cpu max -display none -net none -monitor none \
	-no-reboot -snapshot \
	-serial file:"$tmp/serial.log" \
	-serial null \
	-fw_cfg name=opt/org.luaos.test,file="$payload" \
	-drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
	-drive if=pflash,format=raw,file="$tmp/vars.fd" \
	-drive format=raw,file="$img" \
	>/dev/null 2>&1 || rc=$?

# strip cr + ansi, keep TAP lines
sed -e 's/\r//g' -e 's/\x1b\[[0-9;=]*[a-zA-Z]//g' "$tmp/serial.log" \
	> "$tmp/clean.log" || true

grep -E '^(1\.\.|ok |not ok |# )' "$tmp/clean.log" || true

if [ "$rc" -ne 0 ]; then
	echo "# qemu exited with $rc (124 = timeout); full serial trace:"
	sed 's/^/# /' "$tmp/clean.log"
	echo "not ok - boottest harness (qemu rc=$rc)"
	exit 1
fi

if ! grep -qE '^1\.\.' "$tmp/clean.log"; then
	echo "# no TAP plan seen; full serial trace:"
	sed 's/^/# /' "$tmp/clean.log"
	echo "not ok - boottest harness (no TAP output)"
	exit 1
fi
