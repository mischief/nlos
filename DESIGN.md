# lua-os design

constraints and goals. NOTES.md tracks day-to-day status and debts;
this file records what the project *is*, so decisions don't drift with
whoever edited last. things marked DECIDED are load-bearing; things
marked OPEN are recorded arguments, not commitments.

## what this is

a lua operating system for x86_64 UEFI: a cursed fusion of lua, mach,
and plan 9. most logic in lua, small c glue. isolated lua states as
processes, capabilities for all ipc, 9p at every boundary that faces
the outside world.

it is a playground with discipline: toy scope, but real protocols,
real isolation, and tests. the point is to find out how much os fits
in lua, not to ship a product.

## the pillars (DECIDED)

### 1. c is mechanism, lua is policy

the c kernel provides exactly: proc lifecycle, ports/rights, the
serializer, the scheduler loop, device pumps, and the libc floor lua
stands on. everything with an opinion — repl, line editing, 9p, file
service, supervision trees, namespaces — is lua on the esp, editable
with a text editor and a reboot. when in doubt, the feature goes in
lua; c has to argue its way in.

### 2. procs are isolated lua states. this IS the process model.

no shared heap between procs, ever. communication is message copy or
right transfer, nothing else. limits (instruction budgets, memory
caps) make a proc a real containment unit, erlang-style: it can crash,
leak, or spin without taking the machine.

corollary (LEANING, see open questions): no native userspace. we do
not plan to run untrusted machine code, so no ring 3, no elf loader,
no syscall abi, and the mmu stays optional forever. "spawning a
process" means spawning a lua state. if this ever changes it is a
different project.

### 3. capabilities everywhere, no ambient authority

a proc can touch exactly what its rights table says: handle 0 (its own
receive port) plus whatever rights it was explicitly sent. port names
are per-proc handles; lua never sees kernel pointers. new authority
arrives only inside a message ({__right=h}), mach-style. device access
(keyboard, serial) is a right like any other, handed out at boot or
passed along — not a global anyone can open.

known violations get tracked as debt, not shrugged at (today:
sys.serwrite is ambient; the kbd/serial handles are positional).

### 4. everything is a port; 9p is the boundary protocol

inside the machine, services are procs behind ports. at the edge —
and eventually between procs too — the vocabulary is 9p: real
9P2000 wire format, not a dialect, so stock clients (plan9port 9p,
v9fs someday) mount us with zero shim. drivers converge on the plan9
Dev shape: a tree you walk/open/read/write, served by a proc.

### 5. no third-party code, no glibc, no toolchain magic

vanilla lua 5.4 submodule, unpatched. our own freestanding libc
(-nostdinc; only compiler-provided headers allowed). hand-written PE
header, self-relocation, plain binutils. compiler builtins/intrinsics
are preferred over hand-rolled code (sse sqrt/floor, __atomic_*), but
no vendored libraries. if we can't write it, we probably don't
understand it well enough to boot on it.

### 6. machine-dependent code lives in src/<arch>/ only

everything that knows about x86 — PE header, setjmp, x87 math, uart,
rdtsc, hlt, port io — is quarantined in src/x86_64/. the kernel, libc,
and all lua are arch-blind. an aarch64 port should touch one
directory (plus the PE machine field).

### 7. only los.efi touches firmware

boot/runtime services are reached through the los.efi module and the
platform glue behind it, nowhere else. los.sys (kernel abi) and
los.thread (runtime) must never grow an efi dependency. this keeps
the ExitBootServices door open at constant cost, whether or not we
ever walk through it.

### 8. tested like we mean it

every kernel feature lands with a boot test (TAP over serial, driven
by qemu); protocol code gets exercised against real external clients
(plan9port 9p, python). host-testable pieces (libc string/float code,
the serializer, ninep.lua) get host tests. no green, no merge.

### 9. the kernel is a reactor of reactors

`kernel_run` is an event loop in the same family as ~/code/c/clm and
~/code/c/mbt: gather what's ready, run it, and when nothing is ready,
block in a single "wait for the next thing" call instead of polling
hot. the ready-set comes from device pumps (`pump_keyboard`,
`pump_serial`, eventually tcp4 completion tokens) that translate
platform readiness into port pushes; the blocking call is
`BS->WaitForEvent` over an array of EFI Events (`ConIn.WaitForKey`,
the periodic tick, eventually per-io completion tokens) — playing
exactly the role `poll()`/`epoll_wait()`/`kevent()` play in mbt's
`ev_poll.c`/`ev_sd.c` backends.

one precise difference: EFI Events are completion-token based, not
readiness based. `poll()` says "this fd is readable now, go read
whatever's there"; an EFI network Receive() issues the read up front
and signals its own Event only when *that specific op* finishes —
closer to IOCP/io_uring than POSIX poll. same shape, different flavor;
matters for how the tcp4 work gets structured, not for the overall
architecture.

there are two of these reactors, nested, at different granularities:

- **outer (C, kernel_run)**: schedules whole procs (isolated
  lua_States) at proc granularity. blocks in `WaitForEvent`.
- **inner (lua, los.thread)**: schedules coroutines within one proc,
  sharing that proc's heap. blocks by returning control to the outer
  loop — a proc with every thread parked simply stops being READY, so
  the inner reactor's exhaustion becomes the signal the outer one
  waits on. no explicit handoff protocol needed; it falls out of
  "yield when nothing is runnable" at both levels.

the real divergence from clm/mbt: their task unit is a callback closure
(state threaded explicitly, no first-class continuation). ours is a
real stackful coroutine — `thread.recv(h)` returns a value and the
caller's code below it just continues, because `lua_yield`/
`lua_resume` capture and restore the whole call stack. same trick as
libtask (Russ Cox's C fiber scheduler, itself descended from Plan 9's
libthread — where los.thread's shape came from) or Go's goroutines
over its netpoller. so: reactor core like clm/mbt, but the scheduled
unit is a fiber, not a callback.

clm/mbt are pluggable by design (`ev_poll`/`ev_libevent`/`ev_sd`, same
app logic, swappable backend) because they target multiple host OSes.
we have exactly one backend today — EFI Events — because pillar 7
already quarantines firmware access to a single seam rather than
abstracting it. that stops being a single-backend given the moment
docs/microvm-plan.md lands: no EFI there, so kernel_run's "wait for
the next thing" primitive becomes real interrupts + our own IDT +
lapic timer. at that point kernel_run needs exactly the backend seam
clm/mbt already have, just not framed that way until now.

## open questions (OPEN)

### bluepilled vs redpilled: do we ever ExitBootServices?

not deciding yet. the recorded argument:

- **stay bluepilled (efi as a HAL):** efi hands us a working allocator
  and *device drivers* (NIC via TCP4/SNP, BlockIo, GOP, USB) for free —
  the soul-crushing part. the interesting layer (procs/ports/caps/9p,
  los.sys/los.thread) is firmware-agnostic and doesn't care. and
  los.efi is already the isolation seam, so this costs nothing we
  can't reverse. consequence: 9p-over-efi-tcp becomes *permanent*
  infra, not throwaway scaffolding.
- **cost of bluepilled:** boot services isn't a runtime — we live inside
  the firmware TPL (one big cooperative lock), must keep the watchdog
  disabled, no true preemption/interrupts (we poll), and vendor
  firmware is a quirk minefield (we already ate com2-console contention
  + the WaitForEvent hang). rich protocols (tcp4, mp_services) aren't
  guaranteed on minimal/real hardware.
- **redpill (own the machine)** only buys interrupt-driven io,
  preemption, MP, power. for a 9p-serving lua playground we may never
  hit that wall. and it's expensive: lose AllocatePool, ConOut, Stall,
  and — the killer — SimpleFileSystem (our edit-lua-and-reboot loop).
- **leaning:** treat the exit as "someday, if we hit a wall." pillar 7
  keeps the door open; nothing else should care.

### native userspace (LEANING NO, recorded above)

pillar 2's corollary is a leaning, not yet doctrine: the counterpoint
would be wanting to run existing native software someday, which would
mean mmu, ring 3, an abi, and a loader. current position: that is a
different project; lua states + budgets are our processes. revisit
only with a concrete use case in hand.

### multiprocessing

if/when: one lua state pinned per AP (efi mp_services first, INIT-SIPI
after any redpill), private allocator pools, ports become shared-memory
rings, APs never call firmware, BSP stays the io engine. nothing in the
current design blocks this; nothing in it requires it. cooperative
single-core with budgets is the plan of record.

## explicit non-goals

- posix compatibility, or any compatibility layer
- running existing native binaries
- multi-user security; the threat model is buggy lua, not hostile users
- performance beyond "interactive and pleasant in qemu and on a stick"
- supporting non-uefi boot (bios, coreboot linuxboot, etc)

## litmus tests

when a change is proposed, ask:

1. could this c code have been lua? (pillar 1)
2. does it add authority that doesn't arrive as a right? (pillar 3)
3. does it invent a protocol where 9p would do? (pillar 4)
4. does it add a dependency? (pillar 5)
5. does it leak arch or efi knowledge past its quarantine? (6, 7)
6. where is its TAP test? (pillar 8)
7. does it add a new "wait for the next thing" primitive, or reuse
   the existing reactor-of-reactors shape? (pillar 9)
