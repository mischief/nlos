#!/bin/sh
# lanfetch.sh [-r RANGE] [-s] ELF HOST PORT PATH -- fetch a file into a
# guest over the lua tcp stack, bridged onto a real network.
#
# Not part of the test suite and deliberately not wired into meson: it
# needs a route to a machine on somebody's LAN, and a test that depends
# on that is a test that fails for reasons having nothing to do with the
# code.
#
# It exists because every test in the suite moves a few kilobytes
# between two things on the same host, over a link with no loss and a
# round trip of microseconds. That exercises correctness and says
# nothing about whether the stack works. A real download off a real
# nginx crosses a real switch, closes and reopens the window thousands
# of times, and takes long enough for a retransmission to happen -- and
# with -s it says whether the bytes that arrived are the bytes that were
# sent.
#
# The bridge is qemu's own helper, which carries cap_net_admin as a file
# capability, so no tap needs making by hand and nothing here runs as
# root. /etc/qemu/bridge.conf has to allow the bridge -- $BRIDGE names
# which one, default bridge0.
#
#   -r RANGE  an HTTP byte range, eg 0-4194303 for the first 4MB. The
#             whole file otherwise.
#   -s        hash the body with sha256 as it arrives, and print it. The
#             point of this one: compare against sha256sum on the host
#             and the whole path is verified, not just its length.
#
# Environment: BRIDGE (bridge0), MEM (256), TIMEOUT (25).
#
#   tools/lanfetch.sh -s build/luaos-microvm.elf 192.168.0.10 80 /big.iso

set -e

range=
hash=no

while getopts r:s opt; do
	case $opt in
	r) range=$OPTARG ;;
	s) hash=yes ;;
	*) echo "usage: ${0##*/} [-r RANGE] [-s] ELF HOST PORT PATH" >&2
	   exit 2 ;;
	esac
done
shift $((OPTIND - 1))

[ $# -eq 4 ] || {
	echo "usage: ${0##*/} [-r RANGE] [-s] ELF HOST PORT PATH" >&2
	exit 2
}

elf=$1
host=$2
port=$3
path=$4
br=${BRIDGE:-bridge0}
mem=${MEM:-256}
# A bound, not the exit path: the payload powers the guest off when the
# fetch finishes, so a good run ends on its own. 232MB takes about ten
# seconds all in, a range fetch under two.
#
# Keep it tight anyway. It was 600 while the power-off was quietly
# broken, and a 300ms transfer then took ten minutes of wall clock to
# fail -- which I twice read as the download being slow rather than as
# the harness never exiting.
timeout=${TIMEOUT:-25}

dir=$(dirname "$0")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

# the payload carries its parameters, because fw_cfg injects one file
# and there is nowhere else to put them.
sed -e "s|@@HOST@@|$host|g" \
    -e "s|@@PORT@@|$port|g" \
    -e "s|@@PATH@@|$path|g" \
    -e "s|@@RANGE@@|$range|g" \
    -e "s|@@HASH@@|$hash|g" \
    "$dir/../test/boot/microvm_fetch.lua" > "$tmp/payload.lua"

# a locally administered unicast address: the second-least-significant
# bit of the first octet set, the lowest clear. On a real segment this
# has to be an address nothing else claims, and picking one out of the
# vendor space is how two guests end up fighting over a dhcp lease.
mac=52:54:00:$(od -An -N3 -tx1 /dev/urandom | tr ' ' ':' | sed 's/^://')

echo "# bridging to $br as $mac"
echo "# GET http://$host:$port$path ${range:+range $range}"

exec timeout "$timeout" qemu-system-x86_64 \
	-M microvm,pit=on,pic=off,rtc=off,ioapic2=off,acpi=on \
	-enable-kvm -cpu host -m "$mem" \
	-kernel "$elf" \
	-fw_cfg "name=opt/org.luaos.test,file=$tmp/payload.lua" \
	-device virtio-rng-device,bus=virtio-mmio-bus.1 \
	-netdev "bridge,id=n0,br=$br" \
	-device "virtio-net-device,netdev=n0,bus=virtio-mmio-bus.2,mac=$mac" \
	-nodefaults -no-user-config -no-reboot -display none \
	-serial file:/dev/stdout
