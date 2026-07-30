#!/bin/sh
# mkimage.sh OUTPUT LUAOS_EFI LUA_FILE...
# 48M gpt disk, one esp partition, fat via mtools (no root needed).
# lua files land at /<name>; lib/*, bin/*, svc/* and etc/* land under the
# same name, so a file's path in the namespace matches its path here.
set -eu

SGDISK=${SGDISK:-/sbin/sgdisk}

# the removable-media path the firmware looks for, per arch (set by
# meson, which knows what it just built).
BOOT_EFI=${BOOT_EFI:-bootx64.efi}

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
mmd -i "$out"@@1M efi efi/boot lib bin svc etc
mcopy -o -i "$out"@@1M "$efi" ::efi/boot/"$BOOT_EFI"

for f; do
	case "$f" in
	*/lib/*)
		mcopy -o -i "$out"@@1M "$f" ::lib/"$(basename "$f")"
		;;
	*/bin/*)
		mcopy -o -i "$out"@@1M "$f" ::bin/"$(basename "$f")"
		;;
	*/svc/*)
		mcopy -o -i "$out"@@1M "$f" ::svc/"$(basename "$f")"
		;;
	*/etc/*)
		mcopy -o -i "$out"@@1M "$f" ::etc/"$(basename "$f")"
		;;
	*)
		mcopy -o -i "$out"@@1M "$f" ::"$(basename "$f")"
		;;
	esac
done
