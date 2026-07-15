#!/bin/sh
# mkimage.sh OUTPUT LUAOS_EFI LUA_FILE...
# 48M gpt disk, one esp partition, fat via mtools (no root needed).
# lua files land at /<name> except lib/* which lands at /lib/<name>.
set -eu

SGDISK=${SGDISK:-/sbin/sgdisk}

out=$1
efi=$2
shift 2

rm -f "$out"
dd if=/dev/zero of="$out" bs=512 count=93750 2>/dev/null
"$SGDISK" -Z "$out" >/dev/null
"$SGDISK" -N 1 "$out" >/dev/null
"$SGDISK" -t 1:ef00 "$out" >/dev/null
"$SGDISK" -c 1:"EFI" "$out" >/dev/null
mformat -i "$out"@@1M -v EFI -F -h 32 -t 44 -n 64 -c 1
mmd -i "$out"@@1M efi efi/boot lib
mcopy -o -i "$out"@@1M "$efi" ::efi/boot/bootx64.efi

for f; do
	case "$f" in
	*/lib/*)
		mcopy -o -i "$out"@@1M "$f" ::lib/"$(basename "$f")"
		;;
	*)
		mcopy -o -i "$out"@@1M "$f" ::"$(basename "$f")"
		;;
	esac
done
