# lua-os

Lua 5.4 running on bare UEFI x86_64: a cursed fusion of Lua, Mach, and
Plan 9. Most logic in Lua, small C glue. Isolated Lua states as
processes, capabilities for all IPC, 9P at every boundary facing the
outside world.

Built from scratch — no gnu-efi, no mingw, no EDK II, no glibc. Vanilla
Lua 5.4 as an unpatched submodule; everything else is ours.

It is a playground with discipline: toy scope, but real protocols, real
isolation, and tests. The point is to find out how much OS fits in Lua,
not to ship a product.

## Run it

```sh
meson setup build
meson compile -C build
ninja -C build qemu     # com1 = console on stdio, com2 = 9p on build/9p.sock
```

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

`scripts/boottest.sh` extracts the TAP and dumps the whole serial trace
as diagnostics on failure. `lib/tap.lua` is the guest-side producer.

## Reading further

- [AGENTS.md](AGENTS.md) — the rules a change has to pass, traps already
  walked, known debts, non-goals. Written for agents, useful to humans.
- [docs/uefi-notes.md](docs/uefi-notes.md) — boot path, toolchain facts
  that cost blood, firmware quirks, EFI event semantics.
- [docs/microvm-plan.md](docs/microvm-plan.md),
  [docs/namespace-design.md](docs/namespace-design.md) — parked designs;
  recorded arguments rather than commitments.
