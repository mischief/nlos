# sending files over the console

`bin/sz.lua` and `bin/rz.lua` move files over whatever terminal the
shell is on, so a board with nothing but a serial line still has a way
in. `lib/zmodem.lua` is the protocol, sans-io, and both use it.

	sz -b file                  from a desktop, over the port
	picocom --send-cmd "sz -b"

No flags beyond `-b`, and none on this side: `rz` starts itself, since
a sender writes "rz\r" before its first header.

`rz` advertises a receive window and clears CANOVIO, both truthfully: a
write parks the proc, and nothing reads the line while it is parked.
Our own `sz` honours them and waits. lrzsz ignores both and streams, so
what has to hold is the path underneath -- the console queues rather
than drops, and it hands a reader as much as it asked for.

## reproducing a failure without a board

The hosted machine's console is stdin and stdout, so a real `sz` talks
to a real `rz` with no hardware:

	socat EXEC:"sz -b FILE" \
	    EXEC:"build-hosted/src/platform/hosted/luaos-hosted -r DIR -w"

The machine exits when `sz` does, so whatever `rz` would report at the
end goes with it.

Do not measure this over socat on a board: socat resets the chip when
it opens the port, so the transfer is talking to a machine that is
still booting. `tools/poke-esp32.lua`'s serial does not.

## what the receiver reports

`rz` counts what it asked for twice. "crc" is bytes that arrived wrong,
which on a line means bytes lost; "timeout" is bytes that did not
arrive. They call for opposite fixes.
