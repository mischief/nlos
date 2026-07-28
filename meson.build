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

# freestanding: our include/ plus only the compiler's own headers.
# machine flags: no red zone (efi), sse4.1 so floor/ceil are single
# instructions (qemu wants -cpu max), pic + hidden for the
# RELATIVE-relocs-only self-relocation scheme.
gccinc = run_command(cc.cmd_array() + ['-print-file-name=include'],
  check: true).stdout().strip()

freestanding_args = [
  '-ffreestanding',
  '-fpic',
  '-fvisibility=hidden',
  '-fno-stack-protector',
  '-fno-strict-aliasing',
  '-mno-red-zone',
  '-msse4.1',
  '-fshort-wchar',
  '-nostdinc',
  '-I' + gccinc,
  '-DLUA_PATH_DEFAULT="/?.lua;/lib/?.lua"',
  '-DLUA_CPATH_DEFAULT=""',
]

add_project_arguments(freestanding_args, language: 'c')

inc = include_directories('include', 'src', 'lua')

kernel_src = files(
  'src/dirs.c',
  'src/drivers.c',
  'src/console.c',
  'src/fs.c',
  'src/kernel.c',
  'src/linit.c',
  'src/los.c',
  'src/main.c',
  'src/malloc.c',
  'src/net.c',
)

libc_src = files(
  'src/libc/locale.c',
  'src/libc/math.c',
  'src/libc/stdio.c',
  'src/libc/stdlib.c',
  'src/libc/string.c',
  'src/libc/time.c',
  'src/libc/vsnprintf.c',
)

arch_src = files(
  'src/x86_64/fwcfg.c',
  'src/x86_64/header.S',
  'src/x86_64/machine.c',
  'src/x86_64/math.c',
  'src/x86_64/reloc.c',
  'src/x86_64/setjmp.S',
  'src/x86_64/uart.c',
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

pe_ld = meson.current_source_dir() / 'src/pe.ld'

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

# the elf intermediate: base 0, RELATIVE relocs only, self-relocated at
# entry. gcc drives ld; -nostdlib keeps crt/libc out.
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
  link_depends: files('src/pe.ld'),
)

# flat binary; the hand PE32+ header in src/x86_64/header.S makes this
# a valid uefi application.
luaos_efi = custom_target('luaos.efi',
  input: luaos_elf,
  output: 'luaos.efi',
  command: [objcopy, '-O', 'binary', '@INPUT@', '@OUTPUT@'],
  build_by_default: true,
)

lua_payload = files(
  'init.lua',
  'lib/caps.lua',
  'lib/cons.lua',
  'lib/dev.lua',
  'lib/dns.lua',
  'lib/espfs.lua',
  'lib/http.lua',
  'lib/idle.lua',
  'lib/json.lua',
  'lib/mcp.lua',
  'lib/ninep.lua',
  'lib/ns.lua',
  'lib/power.lua',
  'lib/ps.lua',
  'lib/tap.lua',
  'lib/tcp.lua',
  'lib/thread.lua',
  'lib/udp.lua',
  'lib/wire.lua',
)

# 48M gpt disk with one esp, assembled with sgdisk + mtools (no root)
luaos_img = custom_target('luaos.img',
  input: [luaos_efi] + lua_payload,
  output: 'luaos.img',
  command: [files('scripts/mkimage.sh'), '@OUTPUT@', '@INPUT@'],
  build_by_default: true,
)

# com1 = console (stdio), com2 = 9p wire on <builddir>/9p.sock
# mount from host: 9p -a 'unix!<builddir>/9p.sock' ls /
run_target('qemu',
  command: [files('scripts/qemu.sh'), luaos_img],
)

# boots test/boot/fetch_mcp.lua instead of init.lua (single-url mcp
# fetch server), mcp reachable on host tcp/8090
run_target('fetch-mcp',
  command: [files('scripts/fetch-mcp.sh'), luaos_img],
)

# ---- tests ----
# boot tests: the payload is injected via fw_cfg and replaces
# /init.lua; the guest emits TAP on com1 and powers off. the harness
# extracts the TAP for meson.

boottest = files('scripts/boottest.sh')

boot_tests = ['channel', 'proc', 'recovery', 'ipc', 'budget', 'memlimit',
              'drivers', 'sched', 'json', 'timer', 'readdir', 'magic', 'dev', 'ns']
foreach t : boot_tests
  test('boot-' + t, boottest,
    args: [luaos_img, files('test/boot/test_' + t + '.lua')],
    protocol: 'tap',
    timeout: 90,
    is_parallel: true,
  )
endforeach

# net boot tests: same harness, but NET=1 gives the guest a real NIC
# on qemu's usermode network. separated because dhcp costs real boot
# seconds that the tests above have no reason to pay.
foreach t : ['netboot', 'dns', 'efiprobe']
  test('boot-' + t, boottest,
    args: [luaos_img, files('test/boot/test_' + t + '.lua')],
    protocol: 'tap',
    timeout: 120,
    is_parallel: true,
    env: {'NET': '1'},
  )
endforeach

python = find_program('python3')

# host-driven http test: the guest serves on tcp/7777, forwarded to a
# host port, driven with real HTTP/1.1. the only end-to-end cover for
# tcp listen/accept/recv/send -- the guest can't test this itself,
# since qemu's usermode network doesn't hairpin.
test('http-server', python,
  args: [files('test/test_http.py'), luaos_img, files('test/boot/srvhttp.lua')],
  protocol: 'tap',
  timeout: 150,
)

# host-driven mcp test: real JSON-RPC 2.0 over HTTP POST against the
# guest. covers tcp + http + json + mcp composed together.
test('mcp-server', python,
  args: [files('test/test_mcp.py'), luaos_img, files('test/boot/srvmcp.lua')],
  protocol: 'tap',
  timeout: 150,
)

# ---- benchmarks ----
# not run by `meson test`; run with `meson test --benchmark` or
# `ninja benchmark`. meson runs benchmarks serially rather than in
# parallel, which is what makes the numbers worth reading.
benchmark('ipc', boottest,
  args: [luaos_img, files('test/bench_ipc.lua')],
  protocol: 'tap',
  timeout: 180,
  env: {'TIMEOUT': '150'},
)

# host-driven 9p protocol test: real 9P2000 over the com2 socket
test('9p-protocol', python,
  args: [files('test/test_9p.py'), luaos_img, files('test/boot/srv9p.lua')],
  protocol: 'tap',
  timeout: 90,
)
