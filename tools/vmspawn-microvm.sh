#!/bin/sh
# vmspawn-microvm.sh [ELF] -- boot the microvm kernel under
# systemd-vmspawn.
#
# sh rather than lua for the same reason as vmd-microvm.sh: this is a
# host driver, not part of the build.
#
# vmspawn is qemu underneath, but it picks the machine: q35 with
# firmware, not the microvm type. That makes it a third loader for the
# same image -- SeaBIOS finds the PVH note and jumps to entry32, so no
# new entry point is needed -- and a q35 has both interrupt controllers
# where microvm has only the APIC (see src/platform/microvm/intr.c).
#
# Two arguments exist to get out of vmspawn's way:
#
# -i: with neither --image= nor --directory= vmspawn defaults the root
# to the current directory and shells out to virtiofsd, which we do not
# need and may not have. A throwaway raw file is the cheapest way to say
# "no root filesystem"; root=none stops it dissecting that file for a
# root partition.
#
# --console-transport=serial: the default console is virtio hvc0, and
# the guest speaks com1 only.
#
# vmspawn forwards the guest console only when its own stdout is a
# terminal. Piped or redirected, this script prints nothing at all.

set -e

elf=${1:-build-mvm/luaos-microvm.elf}

if [ ! -f "$elf" ]; then
	echo "$0: no kernel at $elf" >&2
	exit 1
fi

# vmspawn wants an absolute --linux=.
case $elf in
/*) ;;
*) elf=$PWD/$elf ;;
esac

disk=$(mktemp)
trap 'rm -f "$disk"' EXIT
truncate -s 16M "$disk"

exec systemd-vmspawn \
	--image="$disk" \
	--linux="$elf" \
	--firmware=none \
	--ram=256M \
	--console-transport=serial \
	root=none
