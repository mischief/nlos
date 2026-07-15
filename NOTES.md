# lua-os

lua 5.4 running on bare UEFI, evolving into a cursed fusion of lua,
mach, and plan 9: most logic in lua, small c glue, isolated lua states
as processes, ports/capabilities for ipc, 9p to the outside world.

built from scratch: no gnu-efi, no mingw, no edk2, no glibc.

## how to run

```
make qemu          # com1 = console on stdio, com2 = 9p on ./9p.sock
```

talk 9p to it from the host (plan9port):

```
9p -a 'unix!'$PWD'/9p.sock' ls /
9p -a 'unix!'$PWD'/9p.sock' read README
9p -a 'unix!'$PWD'/9p.sock' read proc/list
```

on real hardware: `dd` luaos.img to a usb stick and uefi-boot it.

## architecture

```
init.lua                  lua: repl + spawns the 9p server (proc 0)
lib/thread.lua            lua: los.thread — sched, Channel, alt, recv
lib/ninep.lua             lua: 9P2000 codec + synthetic-tree server
--------------------------------------------------------------------
src/kernel.c              procs (isolated lua_States), ports, rights,
                          serializer, scheduler, kbd/serial pumps,
                          the los.sys module opener
src/los.c                 the los.efi module (firmware bindings)
src/{main,console,fs,malloc,linit}.c       efi platform glue
src/libc/ + include/      freestanding libc, zero glibc
src/x86_64/               ALL machine code: PE header, self-reloc,
                          setjmp, x87 math, uart, rdtsc/hlt
lua/                      vanilla lua 5.4 submodule, unpatched
```

### boot path

hand-written PE32+ header (`src/x86_64/header.S`) → firmware loads at
any address → `_start` applies R_X86_64_RELATIVE self-relocations →
`efi_main` → kernel spawns `/init.lua` from the esp.

toolchain notes that cost blood:
- `ld -shared -Bsymbolic` + `-fvisibility=hidden` → only RELATIVE
  relocs, which the self-relocator handles
- PE header fields use `sym - dos_header` label differences (pc-rel,
  legal in a shared link); a hand `.reloc` section keeps firmware happy
- `.reloc` raw size must not point past EOF (pad the page) or the
  loader says Unsupported
- `-nostdinc` + own `include/`; only compiler-provided headers allowed
- c99 `inline` in headers + `extern inline` in one .c for math builtins
- `-msse4.1` so floor/ceil are single instructions (qemu needs -cpu max)

### kernel model (mach-lite)

- **proc** = isolated `lua_State` + one lua thread. no shared heap,
  ever. count-hook preemption (200k instructions) so busy loops can't
  starve the machine.
- **port** = kernel fifo of serialized messages. **right** = per-proc
  small-int handle onto a port; handle 0 is the proc's own receive
  port (task-self). lua never sees pointers.
- messages: nil/bool/int/double/string/table (deep copy), plus right
  transfer via `{__right=h}` markers. functions and cycles refused.
  64k cap.
- `los.altblock({h...})` = mach port-set blocking, backs alt.
- keyboard and com2-serial are pumped into ports by the kernel; the
  line editor is lua (los.thread), the 9p wire is a port like any other.

### serial takeover (firmware owns com2)

the 9p wire is raw-polled com2 (0x2f8). but OVMF binds a terminal to
com2 and puts it in ConIn, so the firmware drains our bytes and leaks
the 9p handshake to the repl (the mystery "stray keystrokes" — that was
a Tversion frame's `9P2000` showing up at the prompt). fix: at boot,
walk every SerialIo handle, read the ACPI PNP0501 `_UID` from its
device path (the Uart() messaging node carries no base address, so
`_UID` is the only discriminator), and `DisconnectController` the com2
one (`_UID 1`). com1 (`_UID 0`, the console) is left alone. this is a
boot-services-era crutch; it's `serial_takeover()` in src/main.c and
needs `DisconnectController`/`LocateHandleBuffer` + device-path structs
in efi.h.

### plan9 layer

- lib/thread.lua (the `los.thread` module): `thread.spawn/run`
  cooperative threads inside a state (libthread shape: procs share
  nothing, threads share the state's heap), `Channel` buffered or
  rendezvous (cap 0), `alt` over channel recv/send + port recv,
  `QLock`. also the blocking sugar `recv`/`readline`. layered on
  `los.sys`.
- lib/ninep.lua: exact 9P2000 wire codec + synthetic-tree server
  (version/attach/walk/open/read/write/clunk/stat, dir reads as packed
  stats). verified against plan9port `9p` and a python client. the
  framer resyncs byte-wise on a bad header instead of dropping the
  buffer.
- init.lua spawns the 9p server proc (it receives the serial right in
  its first message — capability style) and runs the repl.

### module layering

nothing is a global anymore; everything is an explicit `require`, most
of it via `package.preload` (no disk search). `los` itself is a bare
namespace — there is no monolithic `los` table.

- **los.efi** (C, src/los.c) — firmware/boot-services bindings only:
  `reset`, `stall`, `firmware`, `firmware_revision`. the transitional
  layer; this is what gets swapped/deleted if we ever ExitBootServices.
- **los.sys** (C, src/kernel.c) — the microkernel abi: `send`,
  `tryrecv`, `block`, `altblock`, `newport`, `spawn`, `self`, `procs`,
  `yield`, plus kernel-owned primitives that outlive efi (`ticks` =
  rdtsc, `serwrite` = com2), plus the `SELF`/`KBD`/`SERIAL` handles.
- **los.thread** (lua, lib/thread.lua) — the cooperative runtime,
  built on `los.sys`.

mechanics: the proc pointer lives in the lua_State's extra space
(`lua_getextraspace`), so the kapi needs no upvalues and the whole
thing registers as a plain preload opener. proc_new registers
`los.sys`/`los.efi` (C openers) and `los.thread` (loadfile'd once) in
`package.preload`; the coroutine inherits the extra space from the main
state at `lua_newthread`. no more auto-run prelude.

## milestones (git log tells the story)

1. hello world efi, hand PE header, OVMF boots it
2. lua 5.4 freestanding: own libc, %g printf, malloc on AllocatePool
3. esp filesystem + io library + repl on the esp (edit lua, reboot)
4. package library, require from /lib
5. mach-lite kernel: procs, ports, rights, spawn, echo service
6. plan9 furniture: threads/Channel/alt/QLock, com2 uart, 9P2000
   server an external client can mount
7. hardening + refactor pass: review fixes across kernel/libc/ninep;
   root-caused the com2 hang (firmware console contention) and added
   serial_takeover; made los a real preload module then split it into
   los.efi / los.sys / los.thread; killed all globals.

## fixed in the hardening pass

- **com2 hang root-caused**: was firmware console contention, not the
  scheduler. serial_takeover detaches firmware from com2. serial 9p is
  reliable now (15/15 reads clean, interleaved ops fine).
- **true hlt idle**: with the takeover in place, the periodic 1ms timer
  event + WaitForEvent idle works (the old hang was the same com2
  contention). idle cpu is now 0%, and the tick bounds serial rx
  latency at ~1ms. event-driven io (efi tcp) is unblocked.
- uart rx now buffered in a software ring drained from the tx spin +
  after each proc resume, so a big reply can't overflow the 16-byte fifo.
- 9p framer resyncs on desync instead of dropping the whole buffer.
- deserializer got a depth guard + count bound; serialize rejects a
  non-integer `__right`.
- altblock ceiling raised to MAXRIGHTS + dedup (no more proc death when
  parking on >8 ports); proc_new frees its port on the error paths.
- libc: calloc overflow guard, strtod underflow errno; malloc magic now
  actually checked (double-free/corruption panics).
- dropped the dead `los.readline`/console_readline path.

## known debts (still open)

- **dead procs still leak their ports/rights** (no refcount, no port
  death notification). proc_new's error paths are fixed, but a proc
  that runs and dies still leaks. needs refcount + death notify.
- serializer: no cycles, no functions; strtod ~1ulp; pow(neg, int)
  basic; time() is rdtsc
- 9p server: no auth, no create/remove/wstat, single connection,
  9P2000 only (no .u/.L dialects — linux v9fs prefers those)
- alt-send on unbuffered channels only pairs with already-parked
  receivers
- kbd/serial rights are positional handles (1, 2) in proc 0
- ninep is still a disk `require` via LUA_PATH (could be preloaded like
  los.thread); src/los.c hosts the los.efi module (filename lags)

## open question: bluepilled vs redpilled (UNDECIDED)

do we ever ExitBootServices, or live in efi land forever? not deciding
yet, just recording the discussion.

- **stay bluepilled (efi as a HAL):** efi hands us a working allocator
  and *device drivers* (NIC via TCP4/SNP, BlockIo, GOP, USB) for free —
  the soul-crushing part. the interesting layer (procs/ports/caps/9p,
  los.sys/los.thread) is firmware-agnostic and doesn't care. and
  `los.efi` is already the isolation seam, so this costs nothing we
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
- **leaning:** treat phase-2 as "someday if we hit a wall," keep
  `los.efi` clean as the seam, don't treat the exit as an obligation.
  but not locked in.

## near-term order (proposed, not committed)

1. **procfs introspection over 9p** — lowest risk, gives host-side eyes
   on the scheduler/procs we're about to churn. needs (a) ninep dynamic
   directories (synth is static today) and (b) read-only introspection
   in los.sys (proc status, blocked-on, right count, port queue depth).
   also makes the dead-proc leak *visible*.
2. **scheduler/timers** — timer wheel (`sleep(ms)`, timeouts on
   recv/alt) + port-death notifications → supervision. crack the
   WaitForEvent/idle hang here; it unblocks hlt idle *and* efi tcp.
3. **9p over efi tcp** — the payoff transport; permanent infra if we
   stay bluepilled. event-driven, so it wants step 2 first.
4. **(maybe) redpill** — see above; demoted to optional.

## future directions

- **namespace**: per-proc mount table; `io.open` walks it; services
  mounted at paths (espfs, consfs, procfs as lua procs speaking
  9p-shaped messages over ports). plan9's per-process namespace is
  the sandboxing story.
- **9p client** in lua: mount the HOST from the vm; serial today,
  network later. also 9P2000.u/.L for linux v9fs mounts.
- **port death notifications** → erlang-style supervision, nameserver
  proc, `los.spawn` with linked lifetime
- **timer wheel**: sleep(ms) for threads, timeouts on recv/alt
- **MP**: EFI_MP_SERVICES prototype — pin a lua_State per AP with a
  private allocator pool; APs never call firmware; ports become
  shared-memory rings (atomics); BSP stays the io engine pumping
  async DiskIo2/BlockIo2. same code survives ExitBootServices later.
- **phase 2, own the machine** (see the bluepilled/redpilled question
  above — this is now "someday, if we hit a wall", not a plan):
  ExitBootServices, page allocator from the memory map, lapic timer,
  own keyboard/ahci/virtio drivers as lua procs, INIT-SIPI instead of
  mp services. the mach-lua-plan9 shape is designed to survive this
  transition unchanged.
- **dreams**: string.dump migration of procs between machines over
  9p; a lua debugger served as a filesystem; mount /dev/draw someday
  🗿
