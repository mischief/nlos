# sending files over the console

`bin/sz.lua` and `bin/rz.lua` move files over whatever terminal the
shell is on, so a board with nothing but a serial line still has a way
in. `lib/zmodem.lua` is the protocol, sans-io, and is what both use.

## from a desktop to a board

	sz -w 4096 -b file          from a shell, over the port
	picocom --send-cmd "sz -w 4096 -b"

`-w` is not optional on anything slower than a pipe, and this is the
one thing worth knowing here.

## why -w is not optional

A ZMODEM receiver advertises what it can do in ZRINIT: a receive buffer
size, and a CANOVIO bit meaning "I can take bytes while I write to
disk". `rz` sets the buffer to 8KB and clears CANOVIO, both truthfully:
a write parks the proc, and while it is parked nothing reads the line.

lrzsz's `sz` reads both and acts on neither. Its own transmit window is
a separate variable, zero unless `-w` says otherwise, and at zero it
streams every block back to back. Measured against `sz -vvv`: it prints
`Rxbuflen=8192` and `Txwindow = 0` in the same breath, and every frame
after that ends `ZCRCG`, which is "more follows, do not answer".

The console is USB, so the nominal 115200 is fiction: lrzsz measured
210KB/s into a T-Deck. An unpaced sender at that rate sends far more
than the receiver takes in, and what it overruns is the console buffer.

## measuring this on a board

Not with socat. It resets the board when it opens the port -- uptime
reads 193365ms before an attach and 17270ms after -- so a transfer
started that way is talking to a machine that is still booting, and
every number out of it describes the boot rather than the transfer.
tools/poke-esp32.lua's serial does not reset, and is what to drive.

## between two lua-os machines

`bin/sz.lua` honours the window and needs no flag: it stops after the
advertised buffer and waits for the ack. The pair is what
`test/boot/test_zmodem.lua` exercises over real ports.

## what the receiver reports

`rz` counts what it rejected, by reason. "crc" means bytes arrived
wrong, which on a serial line means bytes were lost and the line is
outrunning the receiver. "timeout" means nothing arrived at all, which
is a sender that stopped. They call for opposite fixes, which is why
they are counted apart.

## reproducing it without a board

The hosted machine's console is stdin and stdout, so a real `sz` talks
to a real `rz` with no hardware in the way. `sz` writes "rz\r" before
its first header, so nothing has to be typed:

	socat EXEC:"sz -b FILE" \
	    EXEC:"build-hosted/src/platform/hosted/luaos-hosted -r DIR -w"

A 64KB file arrives byte-identical. A 3.8MB one rewinds every 62KB and
does not finish, which is the failure from a board reproduced where
perf and gdb can see it. Note that the machine exits when `sz` does, so
anything `rz` reports at the end is lost with it.
