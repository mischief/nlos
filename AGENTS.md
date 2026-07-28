# advice for agents working on lua-os

Read this before changing anything. It is advice and constraint, not
neutral documentation — its audience is whoever (or whatever) is about
to edit this repo next.

Lua 5.4 on bare UEFI x86_64: Lua, Mach and Plan 9 fused. Isolated Lua
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
says: handle 0 (its own receive port) plus whatever was explicitly sent
to it. New authority arrives only inside a message, as `{__right=h}`.
Device access — keyboard, serial, network — is a right like any other.

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

**Two resources use a weaker checked-right form, on purpose.** `fopen`
(via vanilla liolib.c) and `sys.set_priority` are plain C functions
present in every proc with no `lua_State` to check against, so they
test whether `current_proc` holds a right to a reserved port. Doing it
properly would mean replacing liolib's file machinery with yieldable
continuation-based C functions — possible in Lua 5.4, out of scope
here. Disk *write/append* is gated; disk *read* is deliberately not,
because the threat model is buggy Lua rather than hostile users,
nothing on the ESP is confidential, and a stray read cannot corrupt a
future boot the way a runaway write can. **Know which form a new
resource needs before building it.**

**9P is the boundary vocabulary.** Real 9P2000 wire format, not a
dialect, so stock clients mount with zero shim. The same namespace is
served over com2 and TCP with the server unchanged — transport is a
pair of read/write closures.

**No third-party code.** Vanilla Lua 5.4 submodule, unpatched. Our own
freestanding libc, `-nostdinc`, only compiler-provided headers. Hand
PE header, self-relocation, plain binutils. Compiler builtins are
preferred over hand-rolled code; vendored libraries are not. This
extends to protocols — DNS, HTTP and JSON are hand-rolled in Lua for
the same reason 9P is.

**Arch code lives in `src/x86_64/` only.** The kernel, libc and all Lua
are arch-blind. An aarch64 port should touch one directory plus the PE
machine field.

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

**Corollary: anything that busy-spins instead of parking breaks both
levels at once.** `sys.yield()` keeps a proc READY, so the outer loop's
"is anything runnable" test is always yes and it never reaches its idle
sleep. Use `sys.timer(ms)` and the `thread.sleep`/`thread.recvtimeout`
sugar over it — never a `sys.ticks()` deadline loop. Booting with a NIC
once cost 5.2s of CPU per 15s purely because the DHCP retry spun;
parking on a timer took it to 1.6s.

## Time

`platform_ticks()`/`sys.ticks()` is a raw `rdtsc` — a cycle count, not a
duration. Boot calibrates it against `BS->Stall` and everything
time-shaped is denominated in milliseconds via `sys.uptime_ms()`. Do not
reintroduce cycle-denominated constants; the same number was a different
duration on every machine, and the comments describing them were wrong
by 2-4x even on the machine they were written on.

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
- **Coalescing the wakeup ping is not enough** to stop it monopolising
  the scheduler — the task drains it the same lap it arrives, so the
  next lap pushes another. Pace it to the tick. Unpaced cost 9.8s CPU
  per 10s wall with everything parked; paced, 2.1s.
- **The com2 hang was never the scheduler.** It was firmware console
  contention; `serial_takeover()` fixes it.
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

**Nothing dispatches on this yet.** `kernel_run` still scans every slot.
Measure first, then change the loop; see the handoff trap above for what
happens when you skip that order.

**Instruction counting was tried and dropped — do not re-derive it.**
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
and on a stick". Non-UEFI boot.

## Open questions — recorded arguments, not commitments

**Do we ever ExitBootServices?** Staying bluepilled gets a working
allocator and real device drivers for free, and the interesting layer
is firmware-agnostic anyway. The cost is that boot services is not a
runtime: firmware TPL as one big cooperative lock, watchdog disabled,
no true preemption, and a vendor-quirk minefield — `docs/uefi-notes.md`
is the bill so far. Redpilling buys interrupt-driven IO, preemption, MP
and power, and costs AllocatePool, ConOut, Stall and (the killer)
SimpleFileSystem, which is the edit-Lua-and-reboot loop. Leaning:
someday, if we hit a wall.

The cheap move that makes that answer genuinely reversible rather than
rhetorically reversible is a backend seam in `kernel_run` — one "wait
for the next thing" abstraction, introduced while EFI is still the only
implementation and the seam is three lines. `docs/microvm-plan.md`
sketches microvm as a second platform with EFI retained.

**Is the protocol stack infrastructure or a demo?** DNS, HTTP, JSON and
MCP are ~700 lines of application protocol that is not an operating
system. They are the payload that proved the net stack works end to
end, and an OS that is an LLM tool server is a good ending. But it is
the first code here that is not kernel, runtime or boundary protocol,
and the boundary vocabulary is supposed to be 9P. Either they are
permanent infrastructure and stay in `lib/` held to the testing rules,
or they are a demo and belong under `test/`. Unresolved — decide
deliberately rather than by accretion.

**Multiprocessing**, if ever: one Lua state pinned per AP, private
allocator pools, ports become shared-memory rings, APs never call
firmware, BSP stays the IO engine. Nothing blocks it; nothing requires
it. Cooperative single-core with budgets is the plan of record.

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
