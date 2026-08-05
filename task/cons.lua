-- cons: the console over the serial device -- the sole task anywhere with
-- los.platform.cons (raw console write), and it holds the raw keyboard
-- recv right directly (handle 1 in this proc's own table, granted by the
-- kernel at spawn -- not a los.sys-wide constant; no other proc needs to
-- know it).
--
-- the console logic -- the line editor, getch, the tty protocol -- is
-- lib/console.lua, which knows nothing of a wire. this file is only the
-- binding: the serial device is the byte sink, the raw keyboard is the
-- key source. a framebuffer console binds the same core to a glyph
-- renderer instead; both hand a program the identical tty capability.
--
-- claim_input is microvm-only: com1 is the keyboard and the 9p wire both,
-- and until someone chooses, the wire has the bytes. The boot payload
-- chooses by sending {op="claim_input"}, rather than the console claiming
-- unasked -- a machine whose serial line is carrying 9p wants that to keep
-- working. Absent on efi, where ConIn and com2 are different devices, so
-- the field is nil there and the core skips it.

local platform = require("los.platform.cons")

local RAWKBD = 1

require("console").new({
	write = platform.write,
	keyport = RAWKBD,
	claim_input = platform.claim_input,
}):run()
