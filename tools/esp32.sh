#!/bin/sh
# esp32.sh IDF BOARD ACTION... -- run idf.py for one board.
#
# The toolchain, the python environment and IDF_PATH come from IDF's
# own export.sh, which a build system cannot inherit: hence a shell
# between meson and idf.py rather than a direct call.
#
# The board decides the build directory and which sdkconfig layers over
# sdkconfig.defaults, so a caller names a board and nothing else.

set -e

idf=$1
board=$2

if [ -z "$idf" ] || [ -z "$board" ]; then
	echo "usage: esp32.sh IDF BOARD ACTION..." >&2
	exit 2
fi
shift 2

if [ ! -f "$idf/export.sh" ]; then
	echo "esp32.sh: no export.sh under $idf -- is that an esp-idf?" >&2
	exit 1
fi

# Which board to flash is a per-invocation choice, not a build-time
# one: two of the same kind are often plugged in at once. ESPPORT is
# IDF's own variable, so this only supplies the configured default
# when the caller named nothing.
if [ -z "$ESPPORT" ] && [ -n "$LUAOS_ESPPORT" ]; then
	ESPPORT=$LUAOS_ESPPORT
	export ESPPORT
fi

case $board in
tdeck)
	set -- -B build-tdeck "$@"
	;;
c5)
	set -- -B build-c5 -DSDKCONFIG=build-c5.sdkconfig \
	    -DIDF_TARGET=esp32c5 \
	    -DSDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.c5" "$@"
	;;
qemu)
	set -- -B build-qemu \
	    -DSDKCONFIG_DEFAULTS="sdkconfig.defaults;sdkconfig.qemu" "$@"
	;;
*)
	echo "esp32.sh: no such board: $board" >&2
	exit 2
	;;
esac

# Refused rather than guessed. esptool would pick one of two identical
# boards on its own, and flashing the wrong one is quiet: it succeeds.
case " $* " in
*" flash "*)
	if [ -z "$ESPPORT" ]; then
		echo "esp32.sh: no port. ESPPORT=/dev/ttyACM0 ninja ..." >&2
		echo "  or configure a default with -Desp32_port=" >&2
		exit 2
	fi
	echo "esp32.sh: flashing $board on $ESPPORT" >&2
	;;
esac

cd "$(dirname "$0")/../esp32"

# export.sh is chatty and says nothing a build wants; its failures are
# not quiet, so the status is what this reads.
. "$idf/export.sh" >/dev/null

exec idf.py "$@"
