# advice for agents working on lua-os

Read this before changing anything. It is advice and constraint, not
neutral documentation — its audience is whoever (or whatever) is about
to edit this repo next.

Lua 5.4 on bare UEFI, x86_64 and aarch64: Lua, Mach and Plan 9 fused. Isolated Lua
states as processes, Mach-style ports and rights for all IPC, 9P at
every boundary facing outward. A playground with discipline — toy
scope, real protocols, real isolation, real tests. The point is to find
out how much OS fits in Lua, not to ship a product.

## Do not use this repo as a scratchpad

The `.md` files here were once an AI memory substitute, and they rotted:
API lists that no longer matched `kapi[]`, "fixed handles 1/2/3" after
handles stopped being fixed, a test count off by six. Every rotted line
was prose restating code. The rationale, being rationale, survived fine.

So:

- **Running session state goes in the agent memory directory**, not
  here. What you tried, what is half-done, what to do next.
- **This file holds only what stays true**: rules, traps, non-goals.
- **Never restate code in prose.** Module lists, function inventories
  and handle tables belong in the source, which cannot go stale. Cite a
  file, do not summarize it.
- If you catch a claim in here contradicting the code, the code wins —
  fix this file in the same change.

## The hard rules

**C is mechanism, Lua is policy.** The C kernel provides exactly proc
lifecycle, ports/rights, the serializer, the scheduler loop, device
pumps, and the libc floor. Everything with an opinion — repl, line
editing, 9P, supervision, every network protocol above the raw EFI
primitives — is Lua on the ESP, editable with a text editor and a
reboot. A feature goes in Lua unless C can argue its way in. Adding
TCP, UDP, DNS, HTTP and JSON-RPC grew C by one file of raw primitives
and nothing else; keep it that way.

**Procs are isolated Lua states, and that is the whole process model.**
No shared heap between procs, ever. Communication is message copy or
right transfer, nothing else. Instruction budgets and memory caps make
a proc a real containment unit, Erlang-style: it can crash, leak or
spin without taking the machine. No native userspace — no ring 3, no
ELF loader, no syscall ABI, and the MMU stays optional. If that
changes, it is a different project.

**No ambient authority.** A proc touches exactly what its rights table
says: handle 0 (its own receive port) plus whatever was explicitly
granted. New authority arrives as `{__right=h}`, either inside a message
or in `sys.spawn`'s `arg`. Device access — keyboard, serial, network —
is a right like any other.

`arg` exists because a message is always too late for some things. It is
delivered before the child's chunk runs and arrives as the chunk's
`...`, so a proc can hold a capability on its first line — which is
where `require` happens, and therefore where a namespace has to already
be. That is what `fork` gives Plan 9 for free. The kernel does not
interpret it: it is the ordinary serializer, so rights travel exactly as
they do in a message, and what the value *means* is entirely Lua's.

**A server's fids are per client.** `srv`'s well-known port is
establishment only: it answers `session` and `readonly` and nothing else.
A session is a port of its own with its own fid table, which is what 9P
gets from one fid space per connection. It has to work this way because a
port carries no sender identity, so a shared fid table cannot tell whose
fid it is being handed and a client could name another's by guessing a
small integer. `mnt` opens a session on first use, not at mount time,
because `ns:mount` runs `dev.check` before any traffic. A mount releases
its session in `close`, which `ns:unmount` calls — hold it and the far
side never sees a hangup, so its serve thread outlives the client.

**Attenuate rather than check.** `sys.sendright(h)` derives a send-only
right; `dev.readonly(B)` derives a read-only backend; `srv`'s `readonly`
op combines them to serve one filesystem at two authority levels. Asking
for a weaker right needs no capability of its own because it cannot
escalate. So "may this client write the ESP" is answered by *which right
it holds*, with no permission bit and no per-call check — which is why
Unix users and mode bits are a non-goal here rather than a missing
feature.

Note `{__right=h}` **copies the recv flag**. Handing out a port you
created with `sys.newport()` therefore hands out the ability to *receive*
on it, and for a port several clients share that lets one take another's
requests. Use `sys.sendright` for anything you publish.

**Handle numbers are not an ABI.** Handle 0 is the only well-known
handle there can be, because it is how a proc receives at all. Every
other capability is granted at whatever slot the first-free allocator
picked and looked up *by name*: the boot payload reads `sys.granted()`,
everyone else learns handles from the `{__right=}` message that granted
them. Never hardcode a number.

**Test a capability by looking it up, never by trying to use it.**
`pcall`ing a send with a right attached is not a check, it is a
transfer — a "probe" that succeeds has permanently handed the
capability to whatever it was aimed at. Use `sys.granted().tcp ~= nil`.

**A privileged raw primitive must not be registered anywhere except the
task that owns it.** The distinction that matters: if authority is an
*argument* (`sys.send(h, msg)` does nothing without a valid `h`),
anyone may call it — the handle is what is checked. If authority *is*
the function (`console_write`, `ResetSystem`, raw TCP4), there is no
handle to check and calling it does the privileged thing. Gating such a
function behind a check is not enough — the check exists in every
proc's C surface, one bug away from everything. Instead its
`los.platform.*` module goes into `package.preload` for its one owning
task only. There is nothing to get wrong elsewhere because the
reference does not exist elsewhere. `sys.spawn` cannot mint a
privileged proc; only the kernel's boot sequence can.

One owner per *resource*, not per convenience. Power is separate from
cons and wire. TCP and UDP are separate tasks and soft-fail
independently.

**One resource still uses a weaker checked-right form.**
`sys.set_priority` is a plain C function present in every proc with no
`lua_State` to check against, so it tests whether `current_proc` holds a
right to a reserved port. **Know which form a new resource needs before
building it** — prefer removing the reference to checking inside it.

Disk access used to be the other one, gated inside `fopen`. It is not
any more: the ESP is a server task and ordinary procs have no file-
opening C function at all, so the *write* gate in `los.fs.open` now
only ever applies to the one proc that holds the disk right. Read is
still ungated there for the original reason — the threat model is buggy
Lua rather than hostile users, nothing on the ESP is confidential, and a
stray read cannot corrupt a future boot the way a runaway write can.

**9P is the boundary vocabulary.** Real 9P2000 wire format, not a
dialect, so stock clients mount with zero shim. The same namespace is
served over com2 and TCP with the server unchanged — transport is a
pair of read/write closures.

**The namespace is the boundary, not a preference.** Every proc except
proc 0 loses `io.open`, `io.lines`, `io.input`, `io.output`, `loadfile`
and `dofile` in `proc_new`, and `ns.setcurrent` replaces `require`. So a
proc reaches exactly what was mounted for
it — files *and* module code — and a proc given no namespace reaches
nothing. `lib/nsio.lua` puts `io.open` back over `chan`. This is removal,
not a check: the same rule as `los.platform.*`, and for the same reason.
Proc 0 keeps the raw entry points because it is where the ESP reaches and
where the root namespace is built; `PRIV_BOOT` marks it and nothing else.

The ESP itself is a server (`lib/espsrv.lua`, `PRIV_ESP`), so `los.fs` is
registered for exactly two procs and everyone else gets the disk as a
mount — `sys.granted().esp` *is* that mount. **`ns.setcurrent` replaces
`require` with a Lua implementation** rather than adding a
`package.searchers` entry, because a mounted lookup *blocks* and
`require` cannot be yielded through.

Be precise about why, because the sloppy version ("C functions can't
yield") is wrong and will mislead: C functions yield fine via
`lua_yieldk`, and `sys.block` does exactly that. What fails is yielding
past a C frame entered with `lua_call`/`lua_pcall`, which has no
continuation to resume into. `pcall` is safe — `lbaselib.c` uses
`lua_pcallk`, so `Chan:read`'s pcall was never the issue — and so is
`dofile`. But `loadlib.c` uses plain `lua_call` both to invoke a searcher
(:633) **and to run the loaded chunk** (:662). So neither a searcher nor
a module's own top-level body may block. Check for `lua_callk` before
putting anything blocking behind a stdlib hook.
**Output is a port too** (`lib/stdout.lua`). `print`/`io.write` send
`{op="write", data=}` to a port the proc was granted, so redirecting a
proc means handing it a different right. `proc.spawn` inherits the
parent's by default; `out = false` means nowhere. There is deliberately
no fallback to `console_write` — a fallback is indistinguishable from a
grant until you are debugging where output went. Kernel-spawned tasks and
`platform_abort` keep the raw C path by construction, because a driver
that cannot report its own failure is worse than an ambient write.

**`proc.spawn`'s bootstrap must `require` everything it needs BEFORE
`adopt()`.** Adopting routes `require` through the new namespace, and a
confined namespace need not contain `/lib` at all — so a module pulled in
afterwards is unfindable and the child dies before its first line. Same
trap as loading `nsio` before installing the searcher in
`ns.setcurrent`; it has now bitten twice.

**Stripping a stdlib field is not enough on its own.** `src/linit.c`
loads io/debug/table/math/utf8/coroutine lazily via a metatable on `_G`,
and `luaL_requiref` re-runs the opener whenever `package.loaded[name]` is
falsy. An unprivileged proc can clear both and be handed a fresh, whole
`io` — which read a real ESP file out of a proc whose namespace held one
in-memory tree. The lazy loader therefore re-strips
(`kernel_strip_io`). **Any future removal from a lazily-loaded library
must do the same**, and `test/boot/test_escape.lua` is where to prove it.

**Reading an unbound global raises.** The same `_G` metatable runs only
on a miss, so it is also the one place that knows a name was never bound
— and it errors rather than answering nil. `prit("x")` names `prit` at
the line that read it, instead of "attempt to call a nil value" a frame
later. Costs nothing on the hit path: a bound global never reaches a
metamethod. Assignment is *not* guarded — there is no `__newindex`, so
`x = 1` still binds — because read checking already catches the mistake
that matters (`total = total + 1` on an undeclared `total` reads first).
**To ask whether a name is present, use `rawget(_G, "name")`**, which
runs no metamethod and still answers nil; the absence checks in
`test_drivers.lua`, `test_nsio.lua` and `srvweb.lua` all do.

**Diagnostics are a different stream from output.** `print`/`io.write`
are a proc's output and stay verbatim — `seq 5` emits `1\n2\n…` and
nothing else. `lib/log.lua` is the machine's transcript: stamped, tagged,
`{op="log"}` to the same cons task. `kernel.c`'s `klog()` produces the
same `[%5llu.%03llu] ` prefix, so **two producers share one format** —
change one and change the other. The stamp is taken at *emit*, which is
load-bearing rather than decorative: the kernel writes the console
synchronously while Lua goes through a port, so display order and real
order differ and only the stamps recover it.

`uptime_ms()` is milliseconds since `calibrate_clock()`, and returns 0
before it runs. The TSC is 64-bit — ~195 years at 3GHz — so there is
nothing to guard against; the 4.7s wrap belongs to the 24-bit ACPI PM
timer, a different counter.

**A Chan carries its name.** `lib/chan.lua` is (backend, handle, Cname)
— Plan 9's Chan, spelled the same on purpose. The name is the *caller's*
cleaned path and never anything a backend reports, because a backend has
no idea what prefix it was mounted at. Read
`plan9front/sys/doc/lexnames.ms` before touching path resolution: `..` is
folded lexically in `ns.clean` before any backend sees it, which is
exactly Pike's definition, and we get it cheaply only because we
re-evaluate from the mount root each time. **The moment a retained Chan
becomes the origin of a relative path, `..` stops being free** and the
Cname is what disambiguates which mount you came through. Note
`ns.clean` deliberately does *not* implement `cleanname`'s rule 5 (leave
`..` at the head of a non-rooted path): it takes rooted paths only, and
every caller joins `cwd` first.

**Ports carry the dev interface, not 9P bytes.** These are three layers
and not a choice: a port is the transport, `lib/dev.lua` is the
interface, and 9P is the encoding *only where the port has to become
bytes* — off this machine. Between two procs the dev call travels as a
table (`lib/srv.lua`, `lib/mnt.lua`), because 9P's framing exists to
recover message boundaries from a byte stream and a port has not lost
them. The semantics still survive whole; what the port replaces is
tags with a reply right carried in each request, Tauth with holding the
right, and msize with the serializer's own limits. Measured:
byte-framing would add ~24% of a round trip and buy nothing, while the
per-request right costs under 5% and is cheaper than sending the same
shape as plain data.

The reply port belongs to the **calling thread**, not to the service
(`thread.replyport`). That is what makes tags unnecessary rather than
merely skipped: tags demultiplex several replies arriving on one
channel, and one port per caller leaves nothing to demultiplex. A
thread blocks for its answer, so one port covers every service it ever
uses. Measured against a lock held across each rpc: 1.6x at 2 threads,
2.2x at 4, 3.0x at 8. The budget is `MAXPORTS` = 128 system-wide, so
the cache is weak-keyed and finalized — a thread that exits returns its
port. **Do not invent a fourth
vocabulary** — a new service is a dev backend if its state is ambient
(procfs, espfs) and an `srv` proc otherwise.

**One vendored header, and the reasoning for it.**
`include/sys/queue.h` is OpenBSD's rev 1.47, verbatim but for three
lines: `<sys/_null.h>` becomes `<stddef.h>` (all `-nostdinc` allows) and
`QUEUE_MACRO_DEBUG` is on. It is macros — no runtime, no symbols, no
ABI — which is why it sits closer to a compiler builtin than to a
library, and hand-rolling four intrusive list types with correct removal
from several lists at once is more risk than a header everyone has read.
The system copy will not do: `-nostdinc` excludes it, glibc's is the old
BSD one missing `*_FOREACH_SAFE` and `_Q_INVALIDATE` — the two things
this is for — and depending on the host's copy means three toolchains
can disagree about the scheduler's data structures. **This is the
exception, argued; it is not licence to vendor the next thing.**

**No other third-party code.** Vanilla Lua 5.4 submodule, unpatched. Our own
freestanding libc, `-nostdinc`, only compiler-provided headers. Hand
PE header, self-relocation, plain binutils. Compiler builtins are
preferred over hand-rolled code; vendored libraries are not. This
extends to protocols — DNS, HTTP and JSON are hand-rolled in Lua for
the same reason 9P is.

**Arch code lives in `src/<arch>/`.** The kernel, libc and all Lua are
arch-blind. x86_64, aarch64 and riscv64 are ported; `meson.build` picks
the directory from `host_machine.cpu_family()`, which a `--cross-file
cross/<arch>.txt` sets. Meson then *tells* `tools/arch.lua` and
`test/qemuarch.lua` which arch it built, via `LUAOS_ARCH`. They must
never work it out from `uname` again: under a cross build the host arch
is the wrong answer, and riscv64 has only ever been cross-built.

This file used to predict that an aarch64 port would cost "one
directory plus the PE machine field". It cost that plus four things,
which is the honest list of what is genuinely per-arch and cannot be
quarantined:

- the **calling convention** (`EFIAPI` in `src/efi.h`) — ms_abi on
  x86_64, and the plain C convention on both aarch64 and riscv64, so
  their entry stubs have no register shuffle to do at all;
- the **`jmp_buf` size** (`include/setjmp.h`), which is just the
  callee-saved set;
- the **PE section table**: `src/pe.ld` splits at `__data_start` so the
  headers can declare RX text and NX data separately, which is what
  firmware with image protection enabled requires — it maps a writable
  section non-executable, and a section claiming both then cannot run.
  RiscVVirtQemu does apply it (watch `SetUefiImageMemoryAttributes` in
  its boot log); OVMF and AAVMF as shipped do not, so on those two it
  is hardening rather than a fix;
- whatever the machine uses for a second serial port (see below).

The riscv64 port cost none of that again, and the reason is worth
keeping: **the second and third ports are cheap only if you refuse to
copy.** aarch64's `uart.c` is pure `EFI_PCI_IO_PROTOCOL` and its
`fwcfg.c` differs from riscv64's by one address, so both moved to
`src/virt/` (the qemu virt machines, whichever cpu is under them) with
the address coming from `meson.build`. Its `math.c` was portable C
throughout and became `src/libc/softmath.c`. What is left in
`src/riscv64/` is only what is genuinely riscv: the header, the entry
stub, `rdtime`, `R_RISCV_RELATIVE`, the lp64d `jmp_buf`, and floor/
ceil/round — which the D extension, alone among our three, has no
instruction for.

**A builtin that lowers to a call is fine; a builtin that lowers to a
call *into libgcc* is not.** We link `-nostdlib` with no `-lgcc`, and
all three images have zero undefined symbols — check with `nm -u` if
you doubt it. `__builtin_floor` and `__builtin_fmod` become calls to
`floor()` and `fmod()` on riscv64, and that is harmless because those
are ours. `__builtin_bswap32` becomes a call to `__bswapsi2`, which is
nobody's but libgcc's, so `src/virt/fwcfg.c` swaps bytes by hand. The
test is *whose symbol it is*, not whether a call appears.

Everything else really did stay inside the directory.

**Only `los.efi` touches firmware.** `los.sys` and `los.thread` must
never grow an EFI dependency. This keeps the ExitBootServices door open
at constant cost.

## The reactor, and why busy-spinning is a bug

`kernel_run` is an event loop: gather what is ready, run it, and when
nothing is ready block in one "wait for the next thing" call rather
than polling hot. Two of these are nested — the outer C loop schedules
whole procs, the inner Lua one (`los.thread`) schedules coroutines
inside a proc. The nesting is load-bearing and the join is implicit: a
proc with every thread parked simply stops being READY, so the inner
reactor's exhaustion *is* the signal the outer one waits on. No handoff
protocol. That is why `thread.recv(h)` can look like a blocking call
with no kernel support for blocking calls, and why one proc can hold
many connections open without touching the TCP task's poll machinery.

The scheduled unit is a real stackful coroutine, not a callback — same
trick as libtask or goroutines, which is where `los.thread`'s shape
comes from.

**Request/reply goes through `thread.call(h, msg, replyh)`, not
`sys.call` directly.** `sys.call` fuses the send and the wait into one
kernel entry, but the wait it does marks the whole *proc* blocked and
takes it off the run queue — so a coroutine yielding out of one would
strand every sibling thread. The kernel refuses it outright
(`blocking_twice`) rather than letting that happen quietly, so a thread
that calls it gets an error, not a corrupted waiter list.
`thread.call` picks the fused entry only at the top level.

That costs a thread nothing, because its expensive half is already
fused: `thread.run` hands every parked port to `sys.altrecv`, which
blocks and takes a message in one entry on behalf of all of them at
once. What is left over is a plain send, which never blocks.

**Build an `alt` case table once, outside the loop.** `alt` neither
keeps nor mutates `cases`, so writing the literal at the call site —
`thread.alt({{port=a},{port=b}})` inside a `while true` — builds three
tables every trip for nothing. That measured as 34% of an `alt` that
finds a message already waiting, which is more than everything inside
`alt` costs put together. The exclusive device tasks sit in exactly this
loop for the life of the machine, so it is where an idle system spends
its time. When one case's port genuinely varies, keep the table and
assign the field; one store still beats three allocations.

**`thread.await(h)` is the receive half**, and the one blocking receive
that can report an ending: a *reply* port holds two rights while a
request is in flight, so a drop back to one with nothing queued means
the holder died without answering. `thread.recv` cannot say that about
an ordinary service port — a right that *can* send is indistinguishable
from one that will — which is why the two exist separately. `sys.call`
reports the same condition as `nil, "hungup"`. Without it a dead server
parks its clients forever, and since the ESP is a server proc, that is
every proc's filesystem.

**Corollary: anything that busy-spins instead of parking breaks both
levels at once.** `sys.yield()` keeps a proc READY, so the outer loop's
"is anything runnable" test is always yes and it never reaches its idle
sleep. Use `sys.timer(ms)` and the `thread.sleep`/`thread.recvtimeout`
sugar over it — never a `sys.ticks()` deadline loop. Booting with a NIC
once cost 5.2s of CPU per 15s purely because the DHCP retry spun;
parking on a timer took it to 1.6s.

## Time

`platform_ticks()`/`sys.ticks()` is the machine's free-running counter —
`rdtsc` on x86_64, `cntvct_el0` on aarch64, the `time` CSR via `rdtime`
on riscv64 — a tick count, not a duration, and not even the same order
of magnitude between them: a TSC runs at GHz, the arm virtual counter at
62.5MHz under qemu, and riscv's at 10MHz. Boot calibrates it against
`BS->Stall` and everything time-shaped is
denominated in milliseconds via `sys.uptime_ms()`. Do not reintroduce
cycle-denominated constants; the same number was a different duration on
every machine, and the comments describing them were wrong by 2-4x even
on the machine they were written on. The coarse counter is also why
`calibrate_reductions` treats "zero cycles per instruction" as a real
answer rather than an impossible one.

`sys.timer(ms)` returns a receive right to a port that gets one message
at the deadline. It is a port rather than a `sleep()` call so that
recv-with-timeout falls out of `alt` composition with no new API:

    thread.alt({ {port = reply}, {port = sys.timer(500)} })

Resolution is the scheduler tick, so a timer fires up to one tick late
and never early. `SetTimer` cannot beat ~10ms on this platform anyway
(measured — see `docs/uefi-notes.md`), and every deadline here is
hundreds of milliseconds, so no per-deadline EFI event is armed.

The timer table is a flat unsorted array scanned once per lap,
deliberately not a timing wheel: a wheel buys O(1) insert and earns that
at thousands of timers, and `MAXPROCS` is 32.

## Traps already walked — do not re-derive these

- **EFI events are completion tokens, not readiness**, and the signaled
  state is consumed by whoever observes it first. A notify function eats
  it; so does including the event in `kernel_run`'s wait array. Either
  way the poll that cares sees "not ready" for an operation that
  completed at the wire level. Completion events belong to exactly one
  poller and the scheduler is not it. Full account in
  `docs/uefi-notes.md`; `test/tcp4echo/` exists to answer this class of
  question from outside the kernel, which is the only place it can be
  answered.
- **A table carrying `__right` ships as the right and nothing else.**
  `serialize` sees the key and emits one `R` record, so every sibling
  field in that table is dropped in transit, silently and with no error.
  `{__right = h, pull = true}` was the documented shape of the program
  ABI's stdin for as long as `pull` never once arrived: `cat < file`
  handed the program a pull server and told it by omission to drain a
  pipe, so it called `tryrecv` on a send right. Flags go BESIDE the
  right (`stdinpull`), never inside it. Nothing caught this because no
  test read from a redirect; it surfaced only when a program first tried
  to read the console.
- **`sys.sendblock` must be told how big the message is**, or a large
  sender spins instead of parking. `port_push_owned` admits a message
  only if `qbytes + len <= MAXQUEUE`, so a message that is a large
  fraction of the queue can be refused while `qbytes < MAXQUEUE` is
  still true — the old size-blind `sendblock` then returned "there is
  room" at once, the send failed again, and the retry loop burned the
  whole slice. Measured as 33ms per 63KiB band, 146x, and it presented
  as "the framebuffer is slow". Small messages never trigger it, which
  is why nothing before pixels had met it.
- **A `sys.send` that returns `false, "full"` and is ignored silently
  drops the message.** The kernel reports rather than blocking on
  purpose (it cannot tell a pipe writer from a server reply), so
  applying backpressure is the caller's job. `lib/caps.lua`'s
  `requester()` does *not* do this — fine for the small messages every
  other user sends, fatal for pixels, and on the reply path it loses the
  request and then blocks forever on an answer that will never come.
- **Pixels do not fit in a message.** `sys.MAXMSG` is 64KiB, which is
  16384 BGRx pixels — a 128x128 tile — so "load the whole screen in one
  call" cannot exist, in either direction (a reply is a message too).
  `lib/caps.lua`'s `fb.load`/`fb.unload` split into bands of whole rows
  on that bound. Do not raise MAXMSG to dodge this: it is a global limit
  protecting every port, and the design that survives the copy is the
  one that only ever ships the rectangle that changed. The serializer
  bounds the whole message, not just the payload string, so a caller
  splitting to exactly MAXMSG still fails on the table around it.
- **Coalescing the wakeup ping is not enough** to stop it monopolising
  the scheduler — the task drains it the same lap it arrives, so the
  next lap pushes another. Pace it to the tick. Unpaced cost 9.8s CPU
  per 10s wall with everything parked; paced, 2.1s.
- **The com2 hang was never the scheduler.** It was firmware console
  contention; `uart_takeover()` fixes it.
- **`self_relocate` may not touch anything the GOT mediates**, because
  the GOT is what it exists to fix. `-fvisibility=hidden` governs
  definitions, not `extern` declarations, so on aarch64 gcc reached
  `__rela_start`/`__rela_end` through GOT slots holding link-time
  addresses: it then walked firmware memory as if it were a relocation
  table and wrote the results over its own GOT. The image ran far
  enough to fault later, in `console_write`, on an `ST` that was
  garbage — the symptom is nowhere near the cause. x86_64 never showed
  it because it addresses those symbols rip-relative. The declarations
  are now explicitly `visibility("hidden")`; anything new that runs
  before or inside relocation needs the same care.
- **A device the firmware enumerated is not a device the firmware
  turned on.** The aarch64 9p wire is a `pci-serial` card, and PCI
  enumeration placed its io bar but left decoding disabled, so every
  register read came back `0xff`. `PciIo->Attributes(Enable,
  ATTRIBUTE_IO)` cannot fix it there — ArmVirtQemu's root bridge does
  not advertise io in its supported mask — so `src/aarch64/uart.c`
  sets the command register itself. Note the second-order damage: a
  stuck-high `LSR` reads as "data ready" forever, so the serial pump
  manufactured endless bytes, no proc was ever idle, the kernel never
  reached its `WaitForEvent` sleep, and the *scheduler* and *timer*
  tests failed. Two apparently unrelated subsystems were reporting one
  dead io port.
- **The firmware having a NIC driver does not mean it has a network
  stack.** qemu's `edk2-riscv-code.fd` publishes the virtio-net
  `SimpleNetworkProtocol` — one handle, the card is right there — and
  nothing above it: no MNP, ARP, IP4, DHCP4, TCP4 or UDP4. When our net
  stack was a binding over `EFI_TCP4`/`EFI_UDP4` that made networking
  simply absent on that firmware, and every net test failed for a
  reason that was not in this tree. `-Dfw_network=` is the switch, and
  `test_efiprobe` is what told us. Probe the layer you need, not the
  device under it — and note that the layer we need has since moved
  down to SNP itself, so the riscv64 default is now untested rather
  than known.
- **Bundling unrelated resources into one privileged task** ("conio" =
  console-write plus reset/stall) is the same mistake it was fixing.
- **`Configure()` does not dial.** With `ActiveFlag=1` it only prepares
  an active connection; `Connect()` is the separate async step. This
  survived a long time because nothing called dial for real.
- **Reserving ungranted fixed handle numbers** to stop the allocator
  aliasing them is a guard against a problem fixed numbers created.
  Removing the numbers removed the problem.
- **A handoff hint on IPC bought nothing.** Marking a just-woken proc
  run-next (L4's direct process switch, weakened to a hint to avoid a
  nested `lua_resume` under the sender's live C frame) measured neutral
  at best and 14% slower with a bug in it. The reason is structural:
  `kernel_run` scans all `MAXPROCS` slots every lap, so every READY proc
  already gets a turn and "run next" can only reorder *within* a lap,
  never save one. Even a two-proc ping-pong arranged so replies travel
  backwards through slot order came out even, because with two procs one
  direction always runs forward.
  Handoff pays where dispatch is a priority queue and a woken thread
  waits behind others -- which is why L4 and seL4 have it and Plan 9,
  which enqueues on `ready()` and lets the waker keep running, does not.
  So it is only worth revisiting *after* a priority-queue scheduler
  exists, not before, and it should be measured with `bench_ipc` rather
  than reasoned about.
- **Do not universally preload a module to work around a capability
  gate.** That was done for `ninep` and dissolved once read stopped
  being gated.

## Testing

`meson test -C build`. See README.md for invocations. Three kinds, all
real boots: fw_cfg-injected boot payloads emitting TAP over com1; the
same with `NET=1` for a real NIC; and host-driven tests where an
external client drives the guest.

**A TCP server cannot test itself** — qemu's usermode network does not
hairpin, so a guest dialing its own address times out. Network servers
need a host-driven test.

**If a feature needs a harness change to be testable at all, the
harness change is part of the feature.** The whole net stack once
shipped untested because the harness ran `-net none` and the tasks were
never even spawned. That is the failure this rule exists to prevent and
it happened anyway.

Not everything is observable from inside a proc. Whether the kernel
reaches its idle sleep is not — there is no blocking sleep to measure
across, and any spin loop doing the measuring is what keeps the machine
busy. That one was verified from outside by qemu CPU time. Prefer an
honest external measurement over an assertion that cannot fail.

## Scheduling feedback

Every proc carries `cputime` (TSC cycles actually spent inside
`lua_resume`) and `cpu` — a decaying average of the fraction of wall time
it spent running, in per-mille. `sys.priority(pid)` returns weight, the
computed priority and cpu; `ps` shows all three.

Priority is Plan 9's `reprioritize`: inversely proportional to recent cpu
against an equal share, clamped to the proc's weight. So
`sys.set_priority` stays the static, capability-gated policy knob and the
kernel computes the dynamic part. A proc **under** its fair share clamps
to the top however hard it spins — differentiation only happens under
contention, and that is the formula working, not a missing case.

Dispatch is two phases per lap, and the split is the design:

- *phase one* takes the highest priority first, so an interactive proc
  answers before a hog gets another turn. It is bounded by how many were
  waiting when the lap started, so it cannot spin on procs it keeps
  waking.
- *phase two* drains whatever is left with no reference to priority,
  including anything woken during phase one.

Phase two is the starvation guarantee, and it is deliberately independent
of the priority function. Every runnable proc runs at least once and at
most once per lap, whatever `reprioritize` computes, so a policy that is
buggy, hostile or merely untuned costs latency and cannot wedge the
machine. **Never make the progress guarantee depend on the policy being
correct** — policy is the part we expect to get wrong.

"Already had its turn" is membership in a second set that the two phases
drain, swapped at the end of a lap, so nothing is sized against
`MAXPROCS` and nothing scans. Waiting is a list per port (`wait_add`,
`wake_receivers`), so delivering a message touches only the procs
actually blocked on that port. Both together took an empty cross-proc
round trip from 47k cycles to 26k, and `MAXPROCS` no longer affects it at
all — flat from 64 to 512, where each doubling used to cost about 4%.

Plan 9 cannot make this guarantee: `runproc()` takes the first proc off
the highest non-empty `runq` with no aging, so a high-`basepri` proc
starves a low one indefinitely, which `PriEdf > PriKproc > PriNormal`
makes deliberate.

Measured: the two phases cost about 1% of throughput and change no proc's
share. Priority orders; it does not ration. Share is still `weight`, via
the WRR loop in `run_proc`.

**Slices are wall-clock, not instruction counts.** The preempt hook fires
every `p->reductions` VM instructions but only *yields* once `QUANTUM_MS`
of real time has elapsed, so the instruction count is a **sampling rate**
and not a slice length. A proc can overshoot its quantum by at most one
period.

That is why `default_reductions` is **calibrated at boot** rather than
fixed: the right count depends entirely on how fast the machine executes
bytecode. Measured here at ~24-32 cycles per instruction, 25000 is 176us
and 100000 is 705us against a 2ms quantum — both fine. On a machine four
times slower, 100000 would be 2.8ms, longer than the quantum itself, and
time-slicing would quietly degrade back into instruction-slicing.
Calibration targets a fixed fraction of the quantum instead, so the
overshoot bound holds anywhere. `sys.stats().reductions` reports what it
picked.

It is approximate under frequency scaling, and that is fine. The TSC is
invariant by design — constant rate whatever the P-state — which is what
makes it a usable clock and also why it does not track how fast
instructions retire. The *quantum* check stays exact regardless (both
sides are TSC units); only the sampling granularity drifts, bounded by
one period. If it ever matters, the fix is self-correcting rather than
more calibration: the hook already knows elapsed time, so a proc that
consistently overshoots could have its own period lowered.

Note the direction of the trade, which is the opposite of what "add a
time bound" suggests: slices got **longer**, not shorter. A compute-bound
proc holds the CPU for 2ms instead of yielding every ~176us. That is +4%
throughput for up to 2ms of added latency, paid only when something is
genuinely compute-bound.

Nothing here fixes the real hole, and nothing can while we are inside
boot services: the hook cannot fire inside a single C call, so
`string.rep("x", 1e8)` holds the machine for as long as it takes. Plan
9's clock interrupt would preempt it.

**Instruction counting as a *scheduling metric* was tried and dropped —
do not re-derive it.**
The preempt hook fires every `lua_gethookcount()` instructions, so
counting fires is an exact reduction count in the BEAM sense, and it is
tempting because it is deterministic and machine-independent. It has a
floor that kills it: a proc yielding *before* it reaches its period
registers zero, which is most IPC-bound work including cons, wire and
tcp. Lua exposes no way to read the partial countdown — `L->hookcount` is
internal and `lua_gethookcount` returns the configured period — so exact
reductions would mean patching the VM, and vanilla Lua is a pillar.

The TSC has no floor, catches time spent in C as well as in the VM, is
cheap, and is what real schedulers use. It does attribute qemu and
firmware overhead to whoever happened to be running, which is a known and
accepted cost here.

## More than one cpu

Real on `-Dplatform=microvm`, and only there. `qemu -smp N` gives N
vcpus, procs run on all of them at once, and the parallelism is
measured from outside rather than asserted from within: four spinning
procs take 1.70s at `-smp 1`, 0.99s at 2 and 0.65s at 4 — 1.85x and
3.2x net of ~0.15s boot. Idle is still a real sleep, not a spin.

Every other platform is a uniprocessor and stays one. efi is where
firmware lives, and firmware under TPL is one big cooperative lock; on
aarch64 and riscv64 nothing has been written. `NCPU` is 8 on microvm
and 1 everywhere else, and at 1 `src/lock.h` compiles to compiler
barriers — which is what lets `kernel.c` stay one arch-blind file with
no `#ifdef` in it. The barrier is not nothing: it still stops the
compiler hoisting a load out of a critical section, which is a bug on
one cpu too.

**What is per cpu.** `struct cpu` (`src/cpu.h`) holds the currently
running proc, whether the cpu dispatches at all, and the counters. A cpu
finds its own through `cpu_self()`, which is `%gs` on microvm and "the
only one" on efi.

The run queues are not there. There is one pair for the machine under
one lock, so whichever cpu looks next takes the next runnable proc and
there is no placement to decide at spawn — the decision that cannot be
made well, since it is made before the proc has done anything. This is
plan 9's arrangement (`runq[Nrq]` in `port/proc.c` is global there too)
rather than the per-cpu queues and work stealing of OpenBSD's
`kern_sched.c`. The usual argument for per-cpu queues is keeping cpus
off one lock on the hottest path, and it is weak here: every send and
every wakeup already passes through the single IPC lock, held longer
than the scheduler lock ever is. The scheduler lock cannot become the
bottleneck without the IPC lock being one first. If it ever does, plan 9
has the next step as well — a lock per priority queue rather than one
over the set.

Both phases of the dispatch lap run over that one pair, so the progress
guarantee is machine-wide rather than per cpu. The lap ends when the
run set empties, and whichever cpu empties it swaps the sets: a cpu
cannot swap on its own schedule without handing the others procs that
already had a turn.

`p->home` records where a proc last ran. Nothing reads it to decide
anything; it is what the smp tests ask, and it is the field soft
affinity would use.

Measured on `test/boot/microvm_spin.lua`, four procs of pure
computation, wall clock with the 0.22s boot subtracted: 0.49s at
`-smp 1`, 0.25s at 2, 0.14s at 4. That is lua running in parallel, and
it says nothing about the kernel: the spinners share nothing.

`test/boot/microvm_pairs.lua` asks the other half. Four independent
pairs of procs pass a message back and forth over ports no other pair
touches — no shared server, no shared queue. 800000 round trips, wall
clock including boot: **1.00s at `-smp 1`, 1.01s at 2, 0.98s at 4,
1.53s at 8.** Flat to four cpus. Under one ipc lock the same run was
0.95 / 1.14 / 1.38 / 1.87 — more cpus made message passing slower.

`schedlock` is the ceiling now, and at `-smp 8` it is 89.1% contended.
That is the one global run queue, and it is the next piece of work.

**What is shared, and how.** The ipc layer has eight locks, hashed on
the port index; a caller that names one port takes one, and a caller
that can reach a port it cannot name takes all eight. An allocation
under one used to be able to reach another, through the collector
running a `__gc` handler that clunks a handle; the collector is stopped
now and runs only at two points that hold nothing, so it cannot.
`docs/locking.md` is the discipline in full — the wide/narrow split,
the wake protocol, the three assertion tiers, and where the collector
is allowed to run — and it is worth reading before touching
`kernel.c`'s ipc paths. The physical allocator has one lock; the malloc
counters are relaxed atomics. The lock order is in `src/lock.h`.

The `luaheap` arrangement follows `NCPU`, and neither setting takes a
lock — the only combination that would need one is shared-and-parallel,
which is the one never picked. At `NCPU > 1` each proc has its own,
because a shared heap would need a lock on every Lua allocation, the
most frequent thing here; a per-proc heap needs none, since a proc runs
on one cpu at a time. At `NCPU == 1` there is a single machine-wide
heap, because per-proc heaps cost real memory for nothing: measured on
efi with 26 procs, 50021 bytes mapped per proc against 40879, waste
30.3% against 14.7%, 232KB in total, with `lua_live` identical — the
whole difference is chunk tails. That is what makes it matter on esp32,
which is compile-time uniprocessor and where memory binds.

`NCPU` rather than `platform_ncpu()` on purpose: the running count is
not known when the first proc is made, because `smp_start_aps()` runs
after it deliberately.

**What stays on the boot cpu.** Device interrupts, by routing: the
ioapic sends everything to apic id 0 and MSI-X entries name the boot
cpu. So do the device pumps, `expire_timers`, and everything that
touches firmware. APs run the scheduler and nothing else.

Driver procs do not. Nothing pins them, and nothing can: there is one
run queue, so a driver runs wherever a cpu picks it up. Their
interrupts still land on the boot cpu, which makes running them there a
preference and not a requirement — the device-path invariants that were
once credited to pinning hold on any cpu.

**What is per driver rather than per cpu**, and the distinction has
bitten once: a virtio queue is safe with no lock because exactly one
proc owns the device — the platform modules are opened into that one
driver proc's `lua_State` — and a proc is one thread of control on one
cpu at a time. It is *not* safe because it is on the boot cpu; it
isn't. Granting one of those modules to a second proc would corrupt the
rings and nothing would report it.

Two invariants that reversed when procs began running on APs, both now
fixed, both worth knowing because the reasoning that broke is the kind
that looks safe:

- the uart rx ring was single-producer/single-consumer with both ends
  on the boot cpu. `run_proc` calls `uart_poll`, so it is filled from
  whichever cpu is running a proc, and `console_getchar` drains it from
  the cons proc wherever that is. `cli` excludes this cpu's handler and
  says nothing about the others; it now takes a lock as well.
- `srv.serve`'s "one worker" meant one loop, not one thread of control.
  `ops.session` spawns a second serve on the same backend, so a gefs
  server syncing on a tick had two coroutines inside an unlocked
  filesystem. That one is cooperative-only and needed no second cpu —
  see `lib/sync/lock.lua`'s header on invariants that span a park.

Tests run at `-smp 2` and `-smp 4` as `smp2-*` / `smp4-*` in
`meson.build`. `src/lock.h` is tested natively with `NCPU` forced past
1, because the target never has enough cpus to contend and the host
always does.

## Known debts — do not report these as discoveries

Structural, worth fixing:

- **TCP/UDP connections are integers, not rights.** Every other
  authority arrives as a right; a connection is a small integer in a
  table shared by all holders of the TCP capability, so any co-holder
  can name any connection. Currently safe only because co-holders are
  trusted, a proc holding TCP already has unrestricted network access,
  and connection ids are monotonic so a stale one fails cleanly. Still
  the one place the capability rule is not followed through. The fix is
  a port per connection, so holding it *is* the authorization. Urgent
  the moment TCP is granted to anything less trusted than the repl.
- **Resource ceilings are ad-hoc** — reductions per slice, memory per
  proc, message size, rights per proc, grants per proc, HTTP body size,
  scheduler weight. Each sensible alone, collectively unrelated. The
  grant table has one spare slot; two more boot capabilities truncate
  silently.
- **A proc's rights are split inline and overflow.** The first
  `NRIGHTS_INLINE` live in `struct kproc`, the rest in an array allocated
  only when a proc needs one, reached through `right_slot`. A driver task
  holds two rights and an ordinary proc one to three, while a shell
  running a pipeline reaches thirty, so the inline part covers the
  numerous case. `sys.stats().rightshigh` reports the high water if the
  split needs revisiting. `struct kproc` is 544 bytes.
- **The index tables are flat, so they are sized for the maximum.**
  Proc and port bodies are on the heap, so a machine running a dozen
  procs allocates a dozen; what scales with the limits is one pointer
  each. 1024 procs and 4096 ports is 40KB of `.bss`. Going much further
  wants a two-level table, which would add an indirection to every
  serialize. `MAXPORTS` cannot exceed 65536 — the serializer carries a
  port index in a 16-bit field and a static assert enforces it. Figures
  across the range are in `kernel.c` beside the defines.
- **A dead `srv` proc parks its clients forever.** `mnt`'s rpc has no
  deadline and nothing else wakes it. The fix is hangup detection on
  the reply port, not a timeout — a slow backend is not a broken one.
- **Pending-token scans are O(n) per tick.** The exclusive tasks walk
  every outstanding token on every wakeup because EFI never says which
  one completed. Fine at a handful of connections, a ceiling at fifty.
  Possibly forced by the platform — confirm before designing around it.

Bounded and understood: HTTP has no timeout on its reads, so a peer that
connects and never sends parks a coroutine forever — `thread.recvtimeout`
now exists to fix this and it simply hasn't been applied; no chunked transfer-encoding
either direction; the serializer refuses cycles and functions and
`time()` is rdtsc; strtod is exact for round decimals but not last-ulp
for arbitrary mantissas; the 9P server has no auth or
create/remove/wstat, one connection per server, 9P2000 only;
alt-send on unbuffered channels only pairs with an already-parked
receiver; `src/los.c` hosts `los.efi` and the filename lags the rename.

## Non-goals — do not helpfully add these

POSIX compatibility or any compatibility layer. Running existing native
binaries. Multi-user security (the threat model is buggy Lua, not
hostile users). Performance beyond "interactive and pleasant in qemu
and on a stick".

Third-party code in the tree. `include/sys/queue.h` is the one vendored
file and it is pure macros; a network stack is the usual way this rule
gets tested, and importing lwip for microvm is not on the table.

A window system inside the framebuffer. It is two layers on purpose and
the seam is plan 9's: `src/platform/efi/gop.c` plus `task/fb.lua` are
libmemdraw — a rectangle of pixels, and `load`/`unload`/`fill`/`scroll`
to move them — and anything that stacks, clips, routes input or knows
what a window is goes above, in another proc holding a right to that
one. That is what libmemlayer is, and it works precisely because the
layer under it never heard of a window. Do not teach `fb` about
z-order, focus or fonts; add a proc.

## Open questions — recorded arguments, not commitments

**Do we ever ExitBootServices?** Answered, and the answer was "neither
pill exclusively". `-Dplatform=microvm` builds for qemu's firmware-less
machine: PVH entry, our own paging, IDT, LAPIC and physical allocator,
virtio-mmio for 9p and rng. `-Dplatform=efi` is unchanged and remains
the default and the only one that runs on real hardware or on aarch64
and riscv64.

So the question is no longer whether to leave boot services but what
each platform is for. EFI keeps the firmware's allocator, console and
network stack, and pays for them in TPL-as-one-big-lock, no true
preemption and a vendor-quirk minefield — `docs/uefi-notes.md` is that
bill. microvm has interrupts, preemption and a boot measured in
milliseconds, and owes everything the firmware was providing: it has no
network stack at all, and its filesystem is a host directory over
virtio-9p rather than a disk.

Neither is a staging area for the other. The kernel proper stayed
firmware-blind throughout, which is what made a second platform ~2400
lines rather than a rewrite; keep it that way.

**Is the protocol stack infrastructure or a demo?** DNS, HTTP, JSON and
MCP are ~700 lines of application protocol that is not an operating
system. They are the payload that proved the net stack works end to
end, and an OS that is an LLM tool server is a good ending. But it is
the first code here that is not kernel, runtime or boundary protocol,
and the boundary vocabulary is supposed to be 9P. Either they are
permanent infrastructure and stay in `lib/` held to the testing rules,
or they are a demo and belong under `test/`. Unresolved — decide
deliberately rather than by accretion.

## Before proposing a change, ask

1. Could this C code have been Lua?
2. Does it add authority that does not arrive as a right?
3. Does it hardcode a handle number, or test for a capability by trying
   to use it rather than looking it up?
4. Does it register a privileged raw primitive anywhere except the one
   task that owns it?
5. Does it invent a protocol where 9P would do?
6. Does it add a dependency?
7. Does it leak arch or EFI knowledge past its quarantine?
8. Where is its TAP test — and if the harness cannot test it as it
   stands, is the harness change part of this change?
9. Does it add a new "wait for the next thing" primitive, or reuse the
   reactor-of-reactors shape?
10. Does it busy-spin where it should park?
