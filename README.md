# lua-os

Lua 5.4 running on bare UEFI — x86_64, aarch64 or riscv64: a cursed
fusion of Lua, Mach, and Plan 9. Most logic in Lua, small C glue.
Isolated Lua states as processes, capabilities for all IPC, 9P at every
boundary facing the outside world.

Built from scratch — no gnu-efi, no mingw, no EDK II, no glibc. Vanilla
Lua 5.4 as an unpatched submodule; everything else is ours.

It is a playground with discipline: toy scope, but real protocols, real
isolation, and tests. The point is to find out how much OS fits in Lua,
not to ship a product.

## Run it

```sh
meson setup build
meson compile -C build
ninja -C build qemu     # console on stdio, 9p on build/9p.sock
```

That builds for the machine you are on. To build for another, hand
meson a cross file:

```sh
meson setup build-riscv64 --cross-file cross/riscv64.txt
meson test -C build-riscv64          # qemu-system-riscv64, under tcg
```

Either way you need that machine's UEFI firmware: OVMF on x86_64
(`/usr/share/edk2-ovmf`), AAVMF on aarch64 (`/usr/share/AAVMF`),
qemu's own `edk2-riscv-code.fd` on riscv64 (`/usr/share/qemu`), or
`OVMF_CODE`/`OVMF_VARS` in the environment to point elsewhere. Per-arch
qemu, firmware and devices live in `tools/arch.lua` and
`test/qemuarch.lua`, which meson tells which arch it built; nothing else
needs to know.

The 9p wire is a second serial port, which the machines reach very
differently: com2 at a fixed io port on a pc, a `-device pci-serial`
card on qemu's `virt` machines (whose one uart belongs to the firmware
console). The scripts above add whichever is needed.

The net tests are gated on `-Dfw_network`, which defaults off for
riscv64: the firmware qemu ships for it is built without edk2's
NetworkPkg. It does publish the virtio-net `SimpleNetworkProtocol`,
which is all our stack needs now that it drives the card directly, so
that default may be more conservative than it has to be — nobody has
tried it. Configure `-Dfw_network=enabled` to find out.

Talk 9P to it from the host, with plan9port:

```sh
9p -a 'unix!'$PWD'/build/9p.sock' ls /
9p -a 'unix!'$PWD'/build/9p.sock' read README
```

With a NIC, the same namespace is also served over TCP, and there is a
DNS resolver and an HTTP client at the repl:

```
> ps
> resolve("example.com")
> http.get(tcp, dnscap, "http://example.com/").status
```

`ninja -C build fetch-mcp` boots a standalone MCP server instead of the
repl, reachable on host tcp/8090.

On real hardware: `dd` `build/luaos.img` to a USB stick and UEFI-boot it.

## SSH into it

```sh
meson setup build
ninja -C build qemu          # boots it; this terminal is the serial console
```

and from another terminal:

```sh
ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    anyone@127.0.0.1
```

You land in the same `dos` shell the serial console gives, as an
unprivileged proc of your own holding exactly one right: the console you
are typing into. `exit` or ^D ends the session.

Three things about it that are prototype, not design:

- **The host key is generated per boot**, in memory, so every connection
  is to a host your client has never seen. Hence the two `-o` flags. A
  persistent key means either the ESP right (which the session
  deliberately does without) or a key baked into the image.
- **Any public key is accepted**, from any username. `authorized` in
  `svc/sshd.lua` is one line so that this is obvious.
- **You need an ed25519 key.** `ssh-ed25519` is the only host key and
  user key algorithm offered; there is no RSA anywhere.

The key exchange is `mlkem768x25519-sha256` -- post-quantum, so OpenSSH
10 does not warn about it. ML-KEM-768 encapsulation costs 14ms on this
machine, against 85ms for the X25519 half it is paired with, so the
quantum-resistant part is the cheap part. Authentication stays
`ssh-ed25519` deliberately: harvest-now-decrypt-later attacks
confidentiality, and a signature forged in 2040 verifies nothing today.
`curve25519-sha256` is still offered for clients that want it.

`etc/services.lua` is what starts it, and `args.trace = true` there logs
every packet's message number to the console -- which is on because this
is a branch for working on it.

The crypto is `lib/crypto` (Lua) and `src/crypto.c` (ChaCha20 and
Poly1305), the protocol is `lib/ssh`, and both came from
`~/code/lua/ssh`, where the RFC vectors run against them under busted.
Entropy is `EFI_RNG_PROTOCOL` via `los.platform.rng`; no RNG means no
sshd, rather than a weaker one.

## Test it

```sh
meson test -C build                     # full suite, parallel, TAP
meson test -C build boot-proc           # one test
meson test -C build --print-errorlogs
```

Three kinds of test, all real boots:

- **boot tests** (`test/boot/test_*.lua`) — injected via qemu fw_cfg as
  `opt/org.luaos.test`, replacing `/init.lua` as the boot payload. The
  guest emits TAP over com1 and powers itself off. `-snapshot` keeps the
  shared image read-only so they run in parallel.
- **net boot tests** — same, but `NET=1` gives the guest a real NIC on
  qemu's usermode network. Separate because DHCP costs boot seconds the
  other tests have no reason to pay.
- **host-driven tests** (`test/test_*.py`) — a real external client
  drives the guest: plan9port-compatible 9P over the com2 socket, and
  HTTP/JSON-RPC over a forwarded port. A guest cannot test its own TCP
  server, because qemu's usermode network does not hairpin.

`tools/boottest.lua` extracts the TAP and dumps the whole serial trace
as diagnostics on failure. `lib/tap.lua` is the guest-side producer.

Benchmarks are separate from tests and are not run by `meson test`:

```sh
ninja -C build benchmark            # or: meson test -C build --benchmark
```

They assert nothing beyond "it ran" — a throughput floor would be flaky
on a loaded host — so read the numbers from
`build/meson-logs/benchmarklog.txt`. Meson runs benchmarks serially,
which is what makes them comparable between runs.

## Where things live

Everything is .lua, so the directory is what says which kind it is:

```
lib/     required. returns a table. loading it does nothing else.
task/    a proc's main chunk: loaded by PATH, runs, never returns.
         drivers (spawned by src/kernel.c) and services (spawned from
         etc/services.lua) alike -- the difference between them is who
         starts them and what they are granted, and both of those are
         stated at the spawn site rather than in a directory name.
bin/     a program under the lib/prog.lua ABI, run by a shell.
tools/   host-side. builds and runs the image; never reaches the guest.
test/    boot/ is guest payloads; the rest are host-side drivers.
```

`lib/` is the half that can be checked, so test/boot/test_layout.lua
checks it: every module must require cleanly and yield a table. That
catches a library that grew a side effect and a task that drifted into
lib/, which is not hypothetical -- lib/idle.lua had been a proc all
along, and blocks forever the moment anything requires it.

## Reading further

- [AGENTS.md](AGENTS.md) — the rules a change has to pass, traps already
  walked, known debts, non-goals. Written for agents, useful to humans.
- [docs/uefi-notes.md](docs/uefi-notes.md) — boot path, toolchain facts
  that cost blood, firmware quirks, EFI event semantics.
- [docs/scheduling.md](docs/scheduling.md) — the two schedulers and how
  they meet: where a yield lands, where a preempted proc resumes, how a
  message reaches a parked thread.
- [docs/locking.md](docs/locking.md) — the ipc locks: what a narrow
  region may do, why nothing allocates Lua memory under one, and how a
  waker and its target divide the work between them.
- [docs/debugging.md](docs/debugging.md) — asking a proc what it is
  doing: stacks, the Broke state a faulted proc is held in, and the
  line-trace ring.
- [docs/namespace-design.md](docs/namespace-design.md) — a parked design;
  a recorded argument rather than a commitment.
