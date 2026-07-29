# sourced, not run: everything that boots the image needs the same
# per-arch qemu, firmware and device set, and there are three callers.
# test/qemuarch.py is the same table for the host-driven tests.
#
# sets QEMU, MACHINE, FW_CODE, FW_VARS, NIC, BLK and defines
# wire_args(), which is how the 9p wire gets attached.

# meson sets LUAOS_ARCH from the arch it built for, which is the only
# correct answer under a cross build. uname is the fallback for running
# these scripts by hand against a native build.
ARCH=${LUAOS_ARCH:-$(uname -m)}

# first readable path wins, so one table serves distros that spell the
# firmware differently. falls back to naming the first candidate when
# none exist, so the error says something real rather than "".
pick() {
	for p in "$@"; do
		if [ -r "$p" ]; then
			echo "$p"
			return
		fi
	done
	echo "$1"
}

case $ARCH in
x86_64)
	QEMU=qemu-system-x86_64
	MACHINE="-cpu max"
	FW_CODE=${OVMF_CODE:-/usr/share/edk2-ovmf/OVMF_CODE.fd}
	FW_VARS=${OVMF_VARS:-/usr/share/edk2-ovmf/OVMF_VARS.fd}
	NIC=virtio-net-pci
	BLK="format=raw"
	VIDEO=""		# qemu adds a vga to a pc by default
	;;
aarch64)
	QEMU=qemu-system-aarch64
	# virt has no legacy anything: the disk has to be virtio, and
	# the wire has to be a pci card because the one pl011 on the
	# machine is already the firmware console.
	MACHINE="-machine virt -cpu max"
	# AAVMF is debian and ubuntu's name for it. gentoo and arch ship
	# qemu's own blobs instead, where the aarch64 varstore is spelled
	# edk2-arm-vars.fd -- arm and aarch64 differ in the code image, not
	# in a blank 64MiB varstore.
	FW_CODE=${OVMF_CODE:-$(pick /usr/share/AAVMF/AAVMF_CODE.fd \
	    /usr/share/qemu/edk2-aarch64-code.fd)}
	FW_VARS=${OVMF_VARS:-$(pick /usr/share/AAVMF/AAVMF_VARS.fd \
	    /usr/share/qemu/edk2-arm-vars.fd)}
	NIC=virtio-net-pci
	BLK="if=virtio,format=raw"
	# virt has no display at all unless one is asked for, and with
	# none the firmware publishes no GraphicsOutput -- which
	# test_efiprobe checks for. ramfb is the cheapest thing that
	# makes the guest see what a pc sees by default.
	VIDEO="-device ramfb"
	;;
riscv64)
	QEMU=qemu-system-riscv64
	# same shape as arm virt -- virtio disk, pci-serial wire -- and
	# for the same reason: the machine's one ns16550a is already the
	# firmware console. -cpu rv64 is rv64gc, which is what we build.
	MACHINE="-machine virt -cpu rv64"
	# from qemu's own firmware blobs (edk2's OvmfPkg/RiscVVirt).
	# there is no separate distro package the way OVMF and AAVMF
	# each have one.
	FW_CODE=${OVMF_CODE:-/usr/share/qemu/edk2-riscv-code.fd}
	FW_VARS=${OVMF_VARS:-/usr/share/qemu/edk2-riscv-vars.fd}
	NIC=virtio-net-pci
	BLK="if=virtio,format=raw"
	VIDEO="-device ramfb"
	;;
*)
	echo "unsupported arch $ARCH" >&2
	exit 1
	;;
esac

# kvm only ever applies when the guest arch is the host arch, which
# under a cross build it is not.
if [ "$ARCH" = "$(uname -m)" ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
	case $ARCH in
	x86_64)  MACHINE="-enable-kvm -cpu max" ;;
	aarch64) MACHINE="-machine virt,gic-version=max,accel=kvm -cpu host" ;;
	esac
fi

# wire_args null | wire_args socket PATH
# the second serial port, which carries 9p. on x86_64 the machine
# already has com2 and it is simply the second -serial; on the virt
# machines there is no second uart, so it is a pci-serial with a named
# chardev.
wire_args() {
	if [ "$1" = null ]; then
		if [ "$ARCH" = x86_64 ]; then
			echo "-serial null"
		else
			echo "-chardev null,id=wire -device pci-serial,chardev=wire"
		fi
	else
		if [ "$ARCH" = x86_64 ]; then
			echo "-serial unix:$2,server,nowait"
		else
			echo "-chardev socket,id=wire,path=$2,server=on,wait=off -device pci-serial,chardev=wire"
		fi
	fi
}
