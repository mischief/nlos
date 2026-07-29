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

# pin the guest to ONE host cpu.
#
# an unpinned vcpu thread that migrates between host cores can wedge OVMF
# in boot device selection -- spinning at ~100% until the timeout, with
# the serial log stopping right before "BdsDxe: loading Boot0002", so
# before our binary is ever loaded. it looks exactly like a guest hang
# and is not one.
#
# measured: 32 guests unpinned lose 12, 64 guests unpinned lose 19, and
# 64 guests PINNED TWO TO A CORE lose none. so the trigger is migration,
# not contention -- oversubscribing a pinned core is fine.
#
# it is also specific to the KVM path: 96 unpinned TCG boots stalled
# none, against 10 of 96 under kvm, which matches the arm and risc-v
# suites never seeing this in ~150 unpinned cross-tcg boots. that is
# consistent with host tsc skew across cores, since kvm passes the host
# tsc through with a per-vcpu offset while tcg synthesises a clock that
# cannot skew -- but the loop inside OVMF has not been identified, so
# this is a correlation and not a diagnosis. note -invtsc and
# -tsc-deadline change nothing, which is NOT evidence against the tsc
# story: those are guest-visible cpuid bits and do not affect whether
# the host tsc is passed through at all.
#
# pinning by pid spreads parallel invocations with no coordination, and
# collisions are harmless per the above. it is applied only when arch.sh
# actually selected kvm -- which it does only for a native guest -- since
# under tcg there is nothing to fix.
pin=""
case $MACHINE in
*kvm*)
	if command -v taskset >/dev/null 2>&1 &&
	   command -v nproc >/dev/null 2>&1; then
		pin="taskset -c $(($$ % $(nproc)))"
	fi
	;;
esac

# -snapshot: the (possibly shared, parallel) image is never written.
# the guest powers off via ResetSystem(shutdown) when the test is done;
# -no-reboot turns any triple-fault into an exit instead of a hang.
rc=0
timeout "$TIMEOUT" $pin $QEMU \
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
