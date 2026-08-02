#!/bin/sh
# vmd-tcp.sh [ELF [FILE]] -- drive test/boot/vmd_tcp.lua under OpenBSD
# vmd, both directions, and check what arrived by hash.
#
# Runs on the OpenBSD host, not in the build -- like vmd-reachable.sh,
# and for the same reason: it is the machine on the other end of the
# connection as well as the one running the vm.
#
# The image has to be built with the payload embedded:
#
#   meson setup build-vmd -Dplatform=microvm \
#       -Dboot_payload=test/boot/vmd_tcp.lua
#
# because vmd's fw_cfg cannot be handed a file, so the embedded fallback
# is the only program that can ever run there.
#
# What this is for, given the qemu suite already covers the protocol:
# the peer here is OpenBSD's own TCP, not slirp's reimplementation, on
# the machine that also leased us our address and answers our ARP. Two
# implementations agreeing is worth more than one agreeing with itself.
#
# -L gives the guest a local interface with vmd's dhcp behind it: the
# host takes 100.64.N.2 and the guest 100.64.N.3, so the guest's
# gateway is this machine, which is where nc is listening.

set -e

elf=${1:-/tmp/luaos-tcp.elf}
file=${2:-/tmp/tcptest.bin}
name=${VMNAME:-luaostcp}
dialport=7001
listenport=7777
log=/tmp/vmd-tcp-console.log

[ -f "$elf" ] || { echo "$0: no kernel at $elf" >&2; exit 1; }
[ -f "$file" ] || { echo "$0: no test file at $file" >&2; exit 1; }

# vmd will not start a vm for an unprivileged user unless vm.conf says
# so, and the guest here is created on the command line rather than
# declared -- so this needs doas, exactly as `vmctl start` by hand does.
if [ "$(id -u)" = 0 ]; then
	VMCTL=vmctl
	DOAS=
else
	VMCTL="doas vmctl"
	DOAS=doas
fi

want=$(sha256 -q "$file")
size=$(wc -c < "$file" | tr -d ' ')

echo "# test file: $size bytes, sha256 $want"

cleanup() {
	$VMCTL stop -f -w "$name" >/dev/null 2>&1 || true
	kill $ncpid $conpid 2>/dev/null || true
}
trap cleanup EXIT INT TERM

$VMCTL stop -f -w "$name" >/dev/null 2>&1 || true
rm -f "$log"

# The listener has to be up before the guest boots: it dials as soon as
# dhcp answers, and a refused connection is indistinguishable from a
# broken one at that point.
#
# -N so nc half-closes when the file runs out. Without it the guest
# reads the whole file and then waits forever for a FIN that nobody is
# going to send, which looks exactly like a stack that cannot see one.
nc -N -l "$dialport" < "$file" &
ncpid=$!

# Start detached, then read the guest's tty directly.
#
# Two things here cost a run each. vmctl's -c wants a terminal:
# backgrounded with its output redirected it prints "Connected to
# /dev/ttyp3" and immediately "[EOT]", which reads exactly like a guest
# that died on boot. It is not -- it is vmctl hanging up because nothing
# is attached. And script(1) does not rescue it either, since backgrounded
# under ssh it has no stdin of its own.
#
# So the tty vmd allocated is read straight off, which needs no terminal
# on this side at all. The cost is the first tenth of a second of boot
# log, printed before this cat starts; everything the test says comes
# seconds later.
$VMCTL start -L -b "$elf" -m 256M "$name" > /tmp/vmd-tcp-start.log 2>&1
tty=$(sed -n 's/.*tty \(\/dev\/[a-z0-9]*\).*/\1/p' /tmp/vmd-tcp-start.log)

if [ -z "$tty" ]; then
	echo "# could not start the vm:"
	cat /tmp/vmd-tcp-start.log
	exit 1
fi

echo "# console on $tty"

# doas, because vmd owns the tty as root -- and the error is NOT thrown
# away, because the first version of this sent it to /dev/null and the
# result was an empty log that looked like a silent guest rather than a
# permission denied.
$DOAS cat "$tty" > "$log" &
conpid=$!

# the tap for this vm, and from it the guest's address. vmd numbers the
# pair itself, so this is read back rather than assumed.
sleep 3
iface=$(ifconfig | grep -B4 "description: vm.*-$name" | grep -o '^tap[0-9]*' | head -1)
[ -n "$iface" ] || iface=$(ifconfig tap | grep -o '^tap[0-9]*' | tail -1)
hostaddr=$(ifconfig "$iface" | awk '/inet /{print $2}')
guest=$(echo "$hostaddr" | awk -F. '{print $1"."$2"."$3"."$4+1}')

echo "# host $hostaddr on $iface, guest $guest"

# wait for the guest to say it is listening, then connect. Gating on the
# banner rather than sleeping: how long dhcp and a 4MB download take is
# not something to guess at.
i=0
while [ $i -lt 120 ]; do
	if grep -q "listening on $listenport" "$log" 2>/dev/null; then
		break
	fi
	sleep 1
	i=$((i + 1))
done

if grep -q "listening on $listenport" "$log" 2>/dev/null; then
	echo "# guest is listening; connecting"
	nc -N "$guest" "$listenport" < "$file" || true
else
	echo "# guest never announced a listener"
fi

# and wait for it to finish talking.
i=0
while [ $i -lt 120 ]; do
	if grep -q "vmdtcp: done" "$log" 2>/dev/null; then
		break
	fi
	sleep 1
	i=$((i + 1))
done

echo
sed -n 's/^.*vmdtcp: /vmdtcp: /p' "$log" | tr -d '\r'
echo

fail=0
got=$(sed -n 's/.*received sha256 \([0-9a-f]*\).*/\1/p' "$log" | tr -d '\r' | tail -1)
acc=$(sed -n 's/.*accepted sha256 \([0-9a-f]*\).*/\1/p' "$log" | tr -d '\r' | tail -1)

if [ "$got" = "$want" ]; then
	echo "ok - the guest received $size bytes from OpenBSD, hash matches"
else
	echo "not ok - outbound: got '$got' want '$want'"
	fail=1
fi

if [ "$acc" = "$want" ]; then
	echo "ok - the guest accepted $size bytes from OpenBSD, hash matches"
else
	echo "not ok - inbound: got '$acc' want '$want'"
	fail=1
fi

exit $fail
