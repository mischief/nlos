#!/bin/sh
# boottest.sh IMG TEST.lua -- boot the image with the test payload
# injected via fw_cfg, wait for the guest to power off, and emit the
# TAP the guest printed on com1. everything else on the serial line is
# passed through as TAP diagnostics on failure.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$here/arch.sh"

TIMEOUT=${TIMEOUT:-60}

img=$1
payload=$2

# NET=1 gives the guest a real NIC on qemu's usermode (slirp) network:
# gateway 10.0.2.2, dns 10.0.2.3, guest 10.0.2.15 via slirp's built-in
# dhcp. without it the guest sees no tcp4/udp4 service binding at all
# and the net tasks are never spawned -- which is the right default
# for tests that don't care, since dhcp costs real boot seconds.
if [ "${NET:-0}" = "1" ]; then
	netargs="-netdev user,id=n0 -device $NIC,netdev=n0"
else
	netargs="-net none"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cp "$FW_VARS" "$tmp/vars.fd"

# -snapshot: the (possibly shared, parallel) image is never written.
# the guest powers off via ResetSystem(shutdown) when the test is done;
# -no-reboot turns any triple-fault into an exit instead of a hang.
rc=0
timeout "$TIMEOUT" $QEMU \
	$MACHINE -display none $netargs $VIDEO -monitor none \
	-no-reboot -snapshot \
	-serial file:"$tmp/serial.log" \
	$(wire_args null) \
	-fw_cfg name=opt/org.luaos.test,file="$payload" \
	-drive if=pflash,format=raw,readonly=on,file="$FW_CODE" \
	-drive if=pflash,format=raw,file="$tmp/vars.fd" \
	-drive $BLK,file="$img" \
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
