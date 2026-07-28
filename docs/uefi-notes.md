# UEFI and toolchain notes

Facts about the firmware and the build that cost real debugging time.
Inclusion rule: things the code cannot tell you, and that you would
otherwise rediscover the hard way. Not a description of our own
architecture — that is AGENTS.md, and for module structure the code
itself is authoritative.

## Boot path

Hand-written PE32+ header (`src/x86_64/header.S`) → firmware loads the
image at any address → `_start` applies `R_X86_64_RELATIVE`
self-relocations (`src/x86_64/reloc.c`) → `efi_main` (`src/main.c`) →
the kernel spawns `/init.lua` from the ESP, or an fw_cfg-injected test
payload in its place.

## Toolchain facts that cost blood

- `ld -shared -Bsymbolic` plus `-fvisibility=hidden` is what keeps the
  relocation set to RELATIVE only, which is all the self-relocator
  handles.
- PE header fields use `sym - dos_header` label differences. Those are
  PC-relative and therefore legal in a shared link; absolute addresses
  are not. A hand-written `.reloc` section keeps the firmware loader
  happy.
- `.reloc` raw size must not point past end of file — pad the page, or
  the loader rejects the image as Unsupported.
- `-nostdinc` with our own `include/`. Only compiler-provided headers
  are allowed. See AGENTS.md, "no third-party code".
- C99 `inline` in headers plus `extern inline` in exactly one `.c` for
  the math builtins.
- `-msse4.1` so `floor`/`ceil` are single instructions. qemu therefore
  needs `-cpu max`.
- Hardening (`-Wextra -Werror`, `-fsanitize-trap=all`) applies to our
  code only; the Lua submodule compiles vanilla with plain `-Wall`.

## SetTimer has a hard floor at the timer-interrupt period

`SetTimer`'s `TriggerTime` is in 100ns units, which invites asking for
sub-millisecond periods. You will not get them: resolution is bounded by
the platform's timer interrupt, and the spec guidance is to use `Stall()`
for anything under 10ms.

Measured under OVMF/qemu, TSC calibrated against `BS->Stall(100000)`
(4,500,190 cycles/ms on this box, stable to ~4 ppm across boots):

| requested | actual |
|---|---|
| 0.5 ms | 9.505 ms |
| 1 ms | 9.982 ms |
| 5 ms | 9.974 ms |
| 10 ms | 9.975 ms |
| 15 ms | 14.975 ms |
| 20 ms | 19.975 ms |
| 50 ms | 49.971 ms |

So there is a hard **~10ms floor** — OVMF's timer interrupt is 100Hz —
but above it `SetTimer` is accurate to under 30µs. It is not quantised to
multiples of the floor, which is better than the spec guidance implies:
a 15ms request really does fire at 15ms, not at 20.

Two consequences we had wrong for a long time:

- `kernel_run`'s tick asked for 1ms and its comments claimed a "~1ms
  serial rx latency bound". It was getting 9.98ms. The constants now ask
  for 10ms and say so.
- Because the wakeup ping for network completions is paced to that tick,
  completion latency is ~10ms, not ~1ms. Fine for our workloads, but it
  is the real number.

The floor is also why the timer implementation does not bother arming a
per-deadline relative event: resolution is 10ms regardless, and every
deadline in this system is hundreds of milliseconds. Riding the existing
tick costs nothing in accuracy we could have used. Arming a one-shot
`TimerRelative` to the nearest deadline would buy sub-millisecond
precision above the floor, and is a small change if a use case ever
appears — but note `SetTimer` keeps a single armed state per event, so
re-arming means cancelling first.

## Calibrating the TSC

`platform_ticks()` is a raw `rdtsc` — a cycle count, not a time. Boot
calibrates it once against `BS->Stall(100000)` and keeps cycles-per-
millisecond, which is what `sys.uptime_ms()` and the timer deadlines are
denominated in. Stability across boots is ~4 ppm, so one 100ms
calibration is plenty; there is no need to re-calibrate or average.

This assumes an invariant TSC (constant rate regardless of P-state;
CPUID leaf 0x80000007, EDX bit 8), which holds on anything this project
targets. Before calibration existed, every timeout in the tree was
denominated in raw cycles, which meant the same constant was a different
duration on every machine — and the comments describing those constants
were wrong by 2-4x even on the machine they were written on.

## Firmware owns com2 (serial takeover)

The 9P wire is raw-polled com2 (0x2f8). But OVMF binds a terminal to
com2 and puts it in ConIn, so the firmware drains our bytes and leaks
the 9P handshake into the repl. The long-standing mystery "stray
keystrokes" at the prompt were a Tversion frame's `9P2000` string.

Fix, in `serial_takeover()` (`src/main.c`): at boot, walk every SerialIo
handle, read the ACPI PNP0501 `_UID` from its device path, and
`DisconnectController` the com2 one (`_UID 1`). com1 (`_UID 0`, the
console) is left alone. The Uart() messaging node carries no base
address, so `_UID` is the only discriminator available.

This also root-caused a second bug blamed on the scheduler for a long
time: the "timer hangs the serial path" hang was the same contention.
With the takeover in place, the periodic timer plus `WaitForEvent` idle
works, and idle CPU drops to approximately zero.

## EFI events are completion tokens, not readiness

`poll()` says "this fd is readable now, go read whatever is there". An
EFI `Receive()` issues the read up front and signals its own Event only
when *that specific operation* finishes. This is closer to IOCP or
io_uring than to POSIX poll, and it dictates the two-phase
`start`/`poll` shape of every long-running operation in `src/net.c`.

### The signal is consumed by whoever observes it first

This one cost the most. A TCP4 completion Event must be a **plain**
event: no notify function, and not included in `kernel_run`'s
`WaitForEvent` array. Either of those consumes the signaled state before
the owning `CheckEvent` poll can see it, so an operation that genuinely
completed at the wire level — confirmed by packet capture — looks
forever pending to the code waiting on it.

Both mistakes were made and both produced the same symptom. See the
comment on `kernel_new_net_event()` in `src/kernel.c`.

`test/tcp4echo/` exists to answer exactly this class of question: a bare
EFI application with no kernel, scheduler, Lua, malloc or libc under it,
which isolates "is this our TCP4 usage or our event loop?". It
established that a plainly `CheckEvent`-polled event behaves correctly,
which is what the current design rests on. Re-deriving that from inside
the kernel is precisely what does not work.

### Consequences for the wakeup path

Because nothing but `src/net.c` may touch those events, the only wakeup
signal is `pump_net`'s ping on a kernel-owned port, and that ping is
paced to the periodic tick. Pinging every scheduler lap instead keeps
the owning task permanently READY, which means `kernel_run`'s idle path
never executes at all and the machine spins at full tilt with a NIC
present. Measured with every proc parked over a 10 second window:
9.8s CPU unpaced versus 2.1s paced.

Coalescing the ping is *not* sufficient on its own — the task drains it
on the same lap it arrives, so the next lap simply pushes another.

## Other firmware behaviour worth knowing

- **`EFI_NO_MAPPING` is normal, not an error.** `Configure()`
  self-triggers DHCP but does not block for it, so a `listen` or `dial`
  immediately after boot fails with this status until a lease lands.
  Callers retry; logging it every attempt is just boot noise.
- **`CreateChild` requires `*ChildHandle == NULL` on input.** A non-NULL
  value means "add to this existing handle" rather than "create a new
  one". `malloc` does not zero, so this must be explicit — it worked by
  luck of memory contents for a long time.
- **UDP4's `TimeToLive` is taken literally.** Left at 0, outgoing
  datagrams die at the first hop with an ICMP time-exceeded from qemu's
  own gateway. TCP4 does not behave this way. Set it to 64.
- **UDP4's `Receive()` has the driver allocate `RxData`** and overwrite
  `Token->Packet.RxData` with its own pointer, unlike TCP4 where the
  caller supplies the buffer. It is returned via `RecycleSignal`, not
  `free()`; freeing it corrupts our heap. The extra `TimeStamp` and
  `RecycleSignal` fields that UDP4's receive data has and TCP4's does not
  are the tell.
- **OVMF reports the physical Backspace key as `ScanCode = 8` with
  `UnicodeChar = 0`**, not as `CHAR_BACKSPACE`. Without explicit
  handling it is dropped along with every other non-Unicode key.
- **Boot services is not a runtime.** We live inside the firmware TPL
  (one big cooperative lock), the watchdog must stay disabled, and there
  is no true preemption or interrupt delivery — we poll. Rich protocols
  (TCP4, MP_SERVICES) are not guaranteed to exist on minimal or real
  hardware. See AGENTS.md's bluepilled/redpilled question.
