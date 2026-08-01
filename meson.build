project('lua-os', 'c',
  version: '0.1',
  license: 'MIT',
  meson_version: '>=1.1',
  default_options: [
    'c_std=gnu11',
    'warning_level=1',
    'optimization=2',
  ])

cc = meson.get_compiler('c')
objcopy = find_program('objcopy')

# every scripts/*.lua and test/*.lua tool is run through this rather
# than relying on a shebang + preserved execute bit.
lua_interp = find_program('lua5.4', 'lua')

# the per-arch table, and the only place any of it is written down.
# it decides which sources build, what the esp must call the loader for
# the firmware to find it (the UEFI spec's removable-media path), and
# what machine-specific flags the compiler needs. everything downstream
# -- scripts/arch.lua, test/qemuarch.lua -- is told the answer rather
# than working it out again; see the LUAOS_ARCH env below.
#
# a native build gets this from the host; a cross build gets it from
# --cross-file cross/<arch>.txt, which is the only way to build riscv64
# unless you have riscv64 hardware to build on.
arch = host_machine.cpu_family()
platform = get_option('platform')

if platform == 'microvm' and arch != 'x86_64'
  error('microvm platform is x86_64-only')
endif

# every port needs the platform layer (src/<arch>/machine.c, setjmp.S)
# plus a way to reach fw_cfg, a second serial port, and the libm floor.
# efi also needs header.S (the hand PE32+ header/entry) and reloc.c
# (self-relocation to wherever firmware loaded it) -- microvm links at
# a fixed physical address instead (see src/platform/microvm/boot.S),
# so it needs neither.
plat_src = files(
  'src' / arch / 'machine.c',
  'src' / arch / 'setjmp.S',
)
if platform == 'efi'
  plat_src += files(
    'src' / arch / 'header.S',
    'src' / arch / 'reloc.c',
  )
endif

if arch == 'x86_64'
  # no red zone (efi), sse4.1 so floor/ceil are single instructions
  # (qemu wants -cpu max)
  arch_args = ['-mno-red-zone', '-msse4.1']
  boot_efi = 'bootx64.efi'
  # a pc: fw_cfg and com2 are both at fixed io ports, and x87 has the
  # transcendentals in hardware. microvm supplies its own uart.c (com1,
  # not com2 -- no firmware console to share the machine with) but
  # reuses fwcfg.c/math.c unchanged, since both are already plain PIO/
  # x87 with no EFI dependency.
  arch_src = plat_src + files(
    'src/x86_64/fwcfg.c',
    'src/x86_64/math.c',
  )
  if platform == 'efi'
    arch_src += files('src/x86_64/uart.c')
  else
    arch_src += files(
      'src/platform/microvm/boot.S',
      'src/platform/microvm/idt_stubs.S',
      'src/platform/microvm/idt.c',
      'src/platform/microvm/lapic.c',
      'src/platform/microvm/tsc.c',
      'src/platform/microvm/pmm.c',
      'src/platform/microvm/uart.c',
      'src/platform/microvm/reset.c',
      'src/platform/microvm/efi_shim.c',
      'src/platform/microvm/virtio.c',
      'src/platform/microvm/virtio_rng.c',
      'src/platform/microvm/virtio_9p.c',
    )
  endif
elif arch == 'aarch64'
  # fp/simd is baseline on aarch64 and edk2 enables it before running
  # an application, so floor/ceil/sqrt are single instructions with no
  # flag. outline atomics are the one thing that would pull libgcc in.
  arch_args = ['-mno-outline-atomics']
  boot_efi = 'bootaa64.efi'
  # qemu's virt machine: fw_cfg is mmio, the wire is a pci card, and
  # there is no instruction above fsqrt.
  arch_src = plat_src + files(
    'src/libc/softmath.c',
    'src/virt/fwcfg.c',
    'src/virt/uart.c',
  )
  arch_args += '-DFWCFG_BASE=0x09020000UL'
elif arch == 'riscv64'
  # rv64gc with the hard-float abi, since lua is doubles all the way
  # down. medany because we are position-independent and relocate
  # ourselves to wherever the firmware put us, which medlow's
  # "everything within 2GiB of zero" cannot describe. -fno-math-errno
  # so __builtin_sqrt stays a bare fsqrt.d instead of keeping a call to
  # sqrt() on the negative-argument path.
  arch_args = [
    '-march=rv64imafdc',
    '-mabi=lp64d',
    '-mcmodel=medany',
    '-fno-math-errno',
  ]
  boot_efi = 'bootriscv64.efi'
  # same virt machine as aarch64, at a different fw_cfg address; plus
  # the rounding floor D has no instruction for.
  arch_src = plat_src + files(
    'src/libc/softmath.c',
    'src/riscv64/math.c',
    'src/virt/fwcfg.c',
    'src/virt/uart.c',
  )
  arch_args += '-DFWCFG_BASE=0x10100000UL'
else
  error('no src/' + arch + ': x86_64, aarch64 and riscv64 are ported')
endif

# freestanding: our include/ plus only the compiler's own headers.
# pic + hidden is for the RELATIVE-relocs-only self-relocation scheme.
gccinc = run_command(cc.cmd_array() + ['-print-file-name=include'],
  check: true).stdout().strip()

freestanding_args = [
  '-ffreestanding',
  '-fpic',
  '-fvisibility=hidden',
  '-fno-stack-protector',
  '-fno-strict-aliasing',
  '-fshort-wchar',
  '-nostdinc',
  '-I' + gccinc,
  '-DLUA_PATH_DEFAULT="/?.lua;/lib/?.lua"',
  '-DLUA_CPATH_DEFAULT=""',
] + arch_args

add_project_arguments(freestanding_args, language: 'c')

inc = include_directories('include', 'src', 'lua', 'src/platform' / platform)

# dirs.c/kernel.c/linit.c are firmware-blind (the platform seam is
# platform.h + fs.h/net.h/efi.h, all resolved from the per-platform
# include dir above); everything else is the platform's own.
kernel_src = files(
  'src/dirs.c',
  'src/kernel.c',
  'src/linit.c',
)
if platform == 'efi'
  kernel_src += files(
    'src/platform/efi/console.c',
    'src/platform/efi/drivers.c',
    'src/platform/efi/fs.c',
    'src/platform/efi/los.c',
    'src/platform/efi/main.c',
    'src/platform/efi/malloc.c',
    'src/platform/efi/net.c',
  )
else
  kernel_src += files(
    'src/platform/microvm/console.c',
    'src/platform/microvm/drivers.c',
    'src/platform/microvm/efi_shim.c',
    'src/platform/microvm/fs.c',
    'src/platform/microvm/main.c',
    'src/platform/microvm/malloc.c',
    'src/platform/microvm/net.c',
  )

  # what the microvm C loader can open before any namespace exists (see
  # src/platform/microvm/fs.c). Deliberately only the libs needed to
  # reach the point of mounting something: the driver tasks' own
  # lib/*.lua, los.thread, and the 9p client that turns virtio-9p into a
  # mount. Anything you want to edit without rebuilding belongs on that
  # mount, not in this list -- every entry here is frozen at build time.
  embed_files = [
    'lib/thread.lua',
    'lib/cons.lua',
    'lib/wire.lua',
    'lib/power.lua',
    'lib/stdout.lua',
    'lib/ninep.lua',
    'lib/dev.lua',
    'lib/srv.lua',
    'lib/mnt.lua',
    'lib/ns.lua',
    'lib/chan.lua',
    'lib/p9fs.lua',
    'lib/p9srv.lua',
    'lib/tap.lua',
  ]
  embed_args = []
  foreach f : embed_files
    embed_args += '/' + f + '=' + meson.current_source_dir() / f
  endforeach
  embedfs_src = custom_target('embedfs.c',
    output: 'embedfs.c',
    input: files(embed_files),
    command: [lua_interp, files('scripts/gen_embedfs.lua'), '@OUTPUT@'] + embed_args,
  )
  kernel_src += embedfs_src
endif

libc_src = files(
  'src/libc/locale.c',
  'src/libc/math.c',
  'src/libc/stdio.c',
  'src/libc/stdlib.c',
  'src/libc/string.c',
  'src/libc/time.c',
  'src/libc/vsnprintf.c',
)

lua_src = files(
  'lua/lapi.c',
  'lua/lauxlib.c',
  'lua/lbaselib.c',
  'lua/lcode.c',
  'lua/lcorolib.c',
  'lua/lctype.c',
  'lua/ldblib.c',
  'lua/ldebug.c',
  'lua/ldo.c',
  'lua/ldump.c',
  'lua/lfunc.c',
  'lua/lgc.c',
  'lua/liolib.c',
  'lua/llex.c',
  'lua/lmathlib.c',
  'lua/lmem.c',
  'lua/loadlib.c',
  'lua/lobject.c',
  'lua/lopcodes.c',
  'lua/lparser.c',
  'lua/lstate.c',
  'lua/lstring.c',
  'lua/lstrlib.c',
  'lua/ltable.c',
  'lua/ltablib.c',
  'lua/ltm.c',
  'lua/lundump.c',
  'lua/lutf8lib.c',
  'lua/lvm.c',
  'lua/lzio.c',
)

pe_ld = meson.current_source_dir() / 'src/platform/efi/pe.ld'
microvm_ld = meson.current_source_dir() / 'src/platform/microvm/microvm.ld'

# hardening warnings for OUR code only (the lua submodule stays
# vanilla and compiles with plain -Wall). adapted from c-template;
# checked per-flag so compiler upgrades don't break the build.
hardening_args = ['-Wextra', '-Werror']
foreach a : [
  '-Wnull-dereference',
  '-Warray-bounds',
  '-Wformat=2',
  '-Wformat-security',
  '-Wuninitialized',
  '-Wshadow',
  '-Wimplicit-fallthrough',
  '-Wswitch',
  '-Wstrict-prototypes',
  '-Wmissing-prototypes',
  '-Wmissing-declarations',
  '-Wvla',
  '-Walloca',
  '-Wshift-overflow',
  '-Wframe-larger-than=4096',
  '-Wno-unused-parameter',
  '-fsanitize-trap=all',
]
  if cc.has_argument(a)
    hardening_args += a
  endif
endforeach

# vanilla lua, warnings left to upstream
lua_lib = static_library('lua54', lua_src,
  include_directories: inc,
)

if platform == 'efi'
  # the elf intermediate: base 0, RELATIVE relocs only, self-relocated
  # at entry. gcc drives ld; -nostdlib keeps crt/libc out.
  luaos_elf = shared_library('luaos',
    kernel_src + libc_src + arch_src,
    name_prefix: '',
    include_directories: inc,
    c_args: hardening_args,
    link_with: lua_lib,
    link_args: [
      '-nostdlib',
      '-Wl,-Bsymbolic',
      '-Wl,-znocombreloc',
      '-Wl,-T,' + pe_ld,
    ],
    link_depends: files('src/platform/efi/pe.ld'),
  )

  # flat binary; the hand PE32+ header in src/<arch>/header.S makes this
  # a valid uefi application.
  luaos_efi = custom_target('luaos.efi',
    input: luaos_elf,
    output: 'luaos.efi',
    command: [objcopy, '-O', 'binary', '@INPUT@', '@OUTPUT@'],
    build_by_default: true,
  )
else
  # plain ELF at a fixed physical address (src/platform/microvm/boot.S,
  # microvm.ld) -- qemu's -kernel loader wants this directly, no
  # objcopy step and no self-relocation.
  luaos_microvm_elf = executable('luaos-microvm.elf',
    kernel_src + libc_src + arch_src,
    include_directories: inc,
    c_args: hardening_args,
    link_with: lua_lib,
    link_args: [
      '-nostdlib',
      '-static',
      '-Wl,--build-id=none',
      '-Wl,-T,' + microvm_ld,
    ],
    link_depends: files('src/platform/microvm/microvm.ld'),
    build_by_default: true,
  )

  # boots test/boot/microvm_hello.lua via fw_cfg, the only way to run
  # code here (no filesystem yet) -- console on stdio, -no-reboot turns
  # the deliberate triple-fault shutdown into a clean qemu exit.
  run_target('qemu-microvm',
    command: [lua_interp, files('scripts/qemu-microvm.lua'), luaos_microvm_elf,
      files('test/boot/microvm_hello.lua')],
  )
endif

if platform == 'efi'

lua_payload = files(
  'init.lua',
  # what the machine runs, and what each may touch -- see lib/svc.lua
  'etc/services.lua',
  # services, at /svc/<name> -- started by init, not by replacing it
  'svc/webterm.lua',
  # programs, at /bin/<name> -- see lib/prog.lua for the ABI they run under
  'bin/cat.lua',
  'bin/ls.lua',
  'bin/seq.lua',
  'lib/caps.lua',
  'lib/cons.lua',
  'lib/chan.lua',
  'lib/dev.lua',
  'lib/dhcp.lua',
  'lib/dhcpd.lua',
  'lib/dns.lua',
  'lib/espfs.lua',
  'lib/espsrv.lua',
  'lib/http.lua',
  'lib/idle.lua',
  'lib/json.lua',
  'lib/log.lua',
  'lib/mcp.lua',
  'lib/mnt.lua',
  'lib/ninep.lua',
  'lib/ns.lua',
  'lib/nsio.lua',
  'lib/srv.lua',
  'lib/stdout.lua',
  'lib/svc.lua',
  'lib/dos.lua',
  'lib/power.lua',
  'lib/p9fs.lua',
  'lib/p9srv.lua',
  'lib/proc.lua',
  'lib/procfs.lua',
  'lib/prog.lua',
  'lib/ps.lua',
  'lib/tap.lua',
  'lib/tcp.lua',
  'lib/thread.lua',
  'lib/udp.lua',
  'lib/webterm.lua',
  'lib/wire.lua',
)

# 48M gpt disk with one esp, assembled with sgdisk + mtools (no root)
luaos_img = custom_target('luaos.img',
  input: [luaos_efi] + lua_payload,
  output: 'luaos.img',
  command: [lua_interp, files('scripts/mkimage.lua'), '@OUTPUT@', '@INPUT@'],
  env: {'BOOT_EFI': boot_efi},
  build_by_default: true,
)

# every script that boots the image needs to know which machine it is
# booting, and must not guess: with a cross build the host arch is the
# wrong answer. scripts/arch.lua and test/qemuarch.lua both fall back
# to uname when this is unset, which is what a bare `qemu.lua img` gets.
archenv = {'LUAOS_ARCH': arch}

# console on stdio, 9p wire on <builddir>/9p.sock
# mount from host: 9p -a 'unix!<builddir>/9p.sock' ls /
run_target('qemu',
  command: [lua_interp, files('scripts/qemu.lua'), luaos_img],
  env: archenv,
)

# boots test/boot/fetch_mcp.lua instead of init.lua (single-url mcp
# fetch server), mcp reachable on host tcp/8090
run_target('fetch-mcp',
  command: [lua_interp, files('scripts/fetch-mcp.lua'), luaos_img],
  env: archenv,
)

# boots test/boot/srvweb.lua instead of init.lua: the browser shell,
# reachable at http://localhost:8080/ (WEB_PORT to change it)
run_target('website',
  command: [lua_interp, files('scripts/website.lua'), luaos_img],
  env: archenv,
)

# ---- tests ----
# boot tests: the payload is injected via fw_cfg and replaces
# /init.lua; the guest emits TAP on com1 and powers off. the harness
# extracts the TAP for meson.

# test()'s program argument must be a single executable (not an argv
# list the way run_target/custom_target's command: can be), so this
# one relies on the shebang line + the execute bit, unlike every other
# scripts/*.lua invocation in this file.
boottest = files('scripts/boottest.lua')

boot_tests = ['spawnarg', 'nsio', 'escape', 'stdout', 'channel', 'proc', 'recovery', 'ipc', 'budget', 'memlimit',
              'math',
              'drivers', 'sched', 'json', 'timer', 'readdir', 'magic', 'dev', 'ns', 'prog', 'hangup',
              'procfs', 'mnt', 'readonly', 'session', 'runq', 'ninep_selfmount']
foreach t : boot_tests
  test('boot-' + t, boottest,
    args: [luaos_img, files('test/boot/test_' + t + '.lua')],
    protocol: 'tap',
    timeout: 90,
    is_parallel: true,
    env: archenv,
  )
endforeach

# hostutil: the one C module backing the host-driven test clients
# (test/test_9p.lua etc) -- sockets and argv-array process spawning,
# neither of which stock Lua has. built native regardless of
# -Dplatform/cross-file, since this runs on the machine driving the
# tests, never the guest. optional like fw_network below: a host
# without lua5.4's headers just doesn't run these four tests, rather
# than failing the whole configure.
lua54_dep = dependency('lua5.4', native: true, required: false)
have_hostutil = lua54_dep.found()
if have_hostutil
  hostutil = shared_module('hostutil', 'test/hostutil.c',
    dependencies: lua54_dep,
    native: true,
    name_prefix: '',
  )
else
  warning('lua5.4 dev headers not found: skipping the host-driven ' +
          '9p/http/mcp/web-terminal tests (need liblua5.4-dev or ' +
          'equivalent for test/hostutil.c).')
endif

hostenv = archenv
if have_hostutil
  hostenv = archenv + {'HOSTUTIL_SO': hostutil.full_path()}
endif

# does the firmware have a tcp/ip stack? our net stack is a thin
# binding over the firmware's own EFI_TCP4/EFI_UDP4, so without one
# there is nothing under us to drive and every net test fails for a
# reason that has nothing to do with this code. see meson.options; the
# per-arch default below is what the stock blobs actually ship.
fw_network = get_option('fw_network')
if fw_network.auto()
  fw_network = arch != 'riscv64'
else
  fw_network = fw_network.enabled()
endif

if fw_network
  # net boot tests: same harness, but NET=1 gives the guest a real NIC
  # on qemu's usermode network. separated because dhcp costs real boot
  # seconds that the tests above have no reason to pay.
  foreach t : ['netboot', 'dns', 'dhcp', 'efiprobe']
    test('boot-' + t, boottest,
      args: [luaos_img, files('test/boot/test_' + t + '.lua')],
      protocol: 'tap',
      timeout: 120,
      is_parallel: true,
      env: archenv + {'NET': '1'},
    )
  endforeach

  if have_hostutil
    # host-driven http test: the guest serves on tcp/7777, forwarded to
    # a host port, driven with real HTTP/1.1. the only end-to-end cover
    # for tcp listen/accept/recv/send -- the guest can't test this
    # itself, since qemu's usermode network doesn't hairpin.
    test('http-server', lua_interp,
      args: [files('test/test_http.lua'), luaos_img, files('test/boot/srvhttp.lua')],
      protocol: 'tap',
      timeout: 150,
      env: hostenv,
    )

    # host-driven web terminal test: drives the browser shell as its
    # own javascript would. the only cover for the full chain -- http
    # -> session port -> a spawned unprivileged dos proc -> its
    # namespace.
    test('web-terminal', lua_interp,
      args: [files('test/test_web.lua'), luaos_img, files('test/boot/srvweb.lua')],
      protocol: 'tap',
      timeout: 180,
      env: hostenv,
    )

    # host-driven mcp test: real JSON-RPC 2.0 over HTTP POST against
    # the guest. covers tcp + http + json + mcp composed together.
    test('mcp-server', lua_interp,
      args: [files('test/test_mcp.lua'), luaos_img, files('test/boot/srvmcp.lua')],
      protocol: 'tap',
      timeout: 150,
      env: hostenv,
    )
  endif
else
  warning('firmware has no EFI_TCP4/EFI_UDP4: skipping the net tests. ' +
          '-Dfw_network=enabled if yours does.')
endif

# ---- benchmarks ----
# not run by `meson test`; run with `meson test --benchmark` or
# `ninja benchmark`. meson runs benchmarks serially rather than in
# parallel, which is what makes the numbers worth reading.
benchmark('ipc', boottest,
  args: [luaos_img, files('test/bench_ipc.lua')],
  protocol: 'tap',
  timeout: 180,
  env: archenv + {'TIMEOUT': '150'},
)

# host-driven 9p protocol test: real 9P2000 over the com2 socket
if have_hostutil
  test('9p-protocol', lua_interp,
    args: [files('test/test_9p.lua'), luaos_img, files('test/boot/srv9p.lua')],
    protocol: 'tap',
    timeout: 90,
    env: hostenv,
  )
endif

endif # platform == 'efi'

if platform == 'microvm'

# the microvm tests, which are the efi boot tests' counterpart: payload
# injected via fw_cfg, TAP on com1, guest ends itself. They register
# only for this platform because a build is configured for one or the
# other, so `meson test` runs whichever suite the build can actually
# produce a guest for.
#
# see the note on `boottest` above for why this is passed as a program
# rather than an argv list.
microvm_boottest = files('scripts/boottest-microvm.lua')

# every guest gets a virtio-rng. --9p additionally serves a seeded
# temporary directory over virtio-9p; only the mount test wants one,
# and it wants a private directory since it creates a file.
microvm_tests = [
  ['hello', []],
  ['rng', []],
  ['p9mount', ['--9p']],
]

foreach t : microvm_tests
  test('microvm-' + t[0], microvm_boottest,
    args: [luaos_microvm_elf, files('test/boot/microvm_' + t[0] + '.lua')] + t[1],
    protocol: 'tap',
    timeout: 90,
    is_parallel: true,
  )
endforeach

endif # platform == 'microvm'

# ---- host-native tests ----
# src/luaheap.c is the per-lua_State allocator. It has no firmware and
# no kernel in it -- the chunk source is a pair of function pointers --
# so it is built and tested natively, on whichever host is driving the
# build, regardless of -Dplatform or any cross file. These register for
# both platforms because neither one is involved.

luaheap_test = executable('luaheap_test',
  ['test/luaheap_test.c', 'src/luaheap.c'],
  include_directories: include_directories('src'),
  native: true,
)
test('luaheap', luaheap_test, protocol: 'tap', timeout: 120)

# the bench needs a real lua to allocate through, which is the host's
# rather than the freestanding one this build produces.
luaheap_lua_dep = dependency('lua5.4', native: true, required: false)
if luaheap_lua_dep.found()
  luaheap_bench = executable('luaheap_bench',
    ['test/luaheap_bench.c', 'src/luaheap.c'],
    include_directories: include_directories('src'),
    dependencies: luaheap_lua_dep,
    native: true,
  )
  test('luaheap-bench', luaheap_bench, protocol: 'tap', timeout: 120)
endif
