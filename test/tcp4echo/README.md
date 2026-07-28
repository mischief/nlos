# tcp4echo

A standalone UEFI application that accepts one TCP connection on port
7777 and echoes back whatever it receives. It shares nothing with the
lua-os kernel: no scheduler, no lua, no malloc, no libc — just
`src/efi.h`, `BS`/`ST`, and a busy `CheckEvent` poll with `Stall()`
between checks.

## Why it exists

It was written to answer one question during the net work: when
`Accept()` never completed even though the connection had genuinely
finished at the wire level (confirmed by packet capture), was that a
bug in how we drive EFI TCP4, or something about how `kernel_run`
drives EFI events?

Being an ordinary EFI application with no kernel underneath it, it
isolates the two. It worked, which is what established that a plainly
`CheckEvent`-polled event behaves correctly and that the problem lay in
`kernel_run`'s event handling — specifically that both a notify
function and inclusion in `WaitForEvent`'s array consume the signaled
state before the owning poll can observe it. See the comment on
`kernel_new_net_event()` in `src/kernel.c`.

It is kept because that question tends to recur, and re-deriving the
answer from inside the kernel is exactly what doesn't work.

## Building

Not wired into the meson build — it is a debugging tool, not part of
the system, and it deliberately doesn't share the build graph. Compile
it the same way `luaos.efi` is produced (freestanding, `-fpic`,
`ms_abi`, flat binary via `objcopy -O binary`), against `src/` for
`efi.h` plus `src/x86_64/header.S` and `reloc.c` for the PE header and
self-relocation. The resulting `.efi` is gitignored.
