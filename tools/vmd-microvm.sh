#!/bin/sh
# vmd-microvm.sh [ELF] -- boot the microvm kernel under OpenBSD vmd.
#
# sh, not lua, unlike every other script here: this one runs on the
# OpenBSD host rather than in the build, and that host has no lua5.4
# unless someone installed one.
#
# vmctl -b takes a kernel and loads it with usr.sbin/vmd/loadfile_elf.c,
# which reads e_entry rather than the PVH note qemu's microvm uses --
# see src/platform/microvm/boot.S's entry_elf for the other half. No
# disk and no network here: this is the console-only milestone, so the
# guest runs the embedded /boot/microvm.lua (vmd's fw_cfg cannot be
# handed a payload) and triple-faults itself when done.
#
# -c attaches to the console immediately, which matters because the
# whole run is over in well under a second and detaching would miss it.

set -e

elf=${1:-build-mvm/luaos-microvm.elf}
name=${VMNAME:-luaos}

if [ ! -f "$elf" ]; then
	echo "$0: no kernel at $elf" >&2
	exit 1
fi

# a stale vm of the same name would make start fail with EEXIST; the
# guest resets rather than exits cleanly, so one is plausible.
vmctl stop -f -w "$name" 2>/dev/null || true

exec vmctl start -b "$elf" -m 256M -c "$name"
