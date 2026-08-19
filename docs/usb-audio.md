# the usb port as a host, and audio out of it

The ESP32-S3 has an OTG controller. In host mode it enumerates whatever
is plugged into the chip's own USB port, which for a headphone adapter
means a USB audio class device: a stereo output stream, a microphone,
and a couple of volume keys.

## what a board decides

Two board facts gate this, and neither is software.

**The port must source 5V.** A bus-powered adapter draws its power from
VBUS. A board that only charges through that port cannot supply it, and
nothing enumerates. The T-Deck is one of those: VBUS goes through a
charger and a step-down converter into the 3.3V rail, and there is no
boost from the battery. A powered hub or a Y-cable that injects 5V works,
and charges the deck while it does.

**The port must be free.** On the S3 the USB-Serial-JTAG peripheral and
the OTG controller share the same two pins. Host mode takes them, so on a
board whose console is the chip's USB the console goes away, and does not
come back until the next boot. It also means `esptool` can no longer
reset the board over USB: a reflash needs the boot button.

The Freenove carrier answers both the easy way. Its console is a separate
serial bridge, so the chip's own port is free, and it is the board to
bring anything here up on.

## running it

`CONFIG_LUAOS_USB_HOST` compiles the controller in. Nothing starts it: a
program does, so an ordinary boot keeps its console.

	usb                  start the host and report what enumerates
	play /sd/song.wav    a wav file, out of the adapter

Where the console is about to disappear, start `logcast` first and watch
from another machine:

	logcast 192.168.0.12
	socat -u UDP-RECV:9998 -

## the split

The C layer owns the millisecond and nothing else. Isochronous transfers
go out whether or not anybody has audio ready, so it keeps a ring, fills
short packets with silence and counts how often it had to.

Everything above that is Lua. `lib/usb.lua` parses a configuration
descriptor into interfaces, alternate settings and endpoints.
`lib/uac.lua` reads the audio class over that and answers which setting
to play through, at what rate, in packets of what size. `sys.usbplay`
carries out that answer and does not second-guess it.

This is why a rate the device did not list is refused rather than played:
the device would accept the samples and play them at its own rate, which
sounds like the wrong speed rather than like an error.

## what is tested, and what is not

`test/host_usb.lua` runs the parsers against the descriptors a real
adapter reported, copied out of the kernel log. That covers the reading:
which interface, which endpoint, which rates, and the packet arithmetic.

The transfers themselves are not tested by anything. There is no
emulator for this, so the first proof that the audio path works is a
board with an adapter on it.
