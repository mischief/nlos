# sending files over the console

`bin/sz.lua` and `bin/rz.lua` move files over whatever terminal the
shell is on, so a board with nothing but a serial line still has a way
in. `lib/zmodem.lua` is the protocol, sans-io, and both use it.

Between two lua-os machines this works as it stands: `rz` advertises a
receive window and clears CANOVIO, because a write parks the proc and
nothing reads the line while it is parked, and `sz` honours both.

lrzsz's `sz` reads those and streams anyway; its transmit window is a
separate thing, set only by `-w`. Until the receiver takes bytes as
fast as a sender offers them, a large transfer from lrzsz needs
`-w 4096` or it retries its way to a halt. That is a gap to close, not
a setting to keep.

## reproducing it without a board

The hosted machine's console is stdin and stdout, so a real `sz` talks
to a real `rz` with no hardware. `sz` writes "rz\r" before its first
header, so nothing has to be typed:

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
