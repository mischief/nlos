# sourced, not run: everything that boots the image needs the same
# per-arch qemu, firmware and device set, and there are three callers.
# test/qemuarch.py is the same table for the host-driven tests.
#
# sets QEMU, MACHINE, FW_CODE, FW_VARS, NIC, BLK and defines
# wire_args(), which is how the 9p wire gets attached.

ARCH=$(uname -m)

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
	FW_CODE=${OVMF_CODE:-/usr/share/AAVMF/AAVMF_CODE.fd}
	FW_VARS=${OVMF_VARS:-/usr/share/AAVMF/AAVMF_VARS.fd}
	NIC=virtio-net-pci
	BLK="if=virtio,format=raw"
	# virt has no display at all unless one is asked for, and with
	# none the firmware publishes no GraphicsOutput -- which
	# test_efiprobe checks for. ramfb is the cheapest thing that
	# makes the guest see what a pc sees by default.
	VIDEO="-device ramfb"
	;;
*)
	echo "unsupported host arch $ARCH" >&2
	exit 1
	;;
esac

# kvm only ever applies here because guest arch == host arch: the
# build detects the host too, so there is nothing else to run.
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
	case $ARCH in
	x86_64)  MACHINE="-enable-kvm -cpu max" ;;
	aarch64) MACHINE="-machine virt,gic-version=max,accel=kvm -cpu host" ;;
	esac
fi

# wire_args null | wire_args socket PATH
# the second serial port, which carries 9p. on x86_64 the machine
# already has com2 and it is simply the second -serial; on aarch64
# there is no second uart, so it is a pci-serial with a named chardev.
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
