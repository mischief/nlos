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

# -Db_sanitize=address, which two things elsewhere have to know about:
# the tsan lock test cannot be built beside it, and the hosted binary
# links the runtime statically. A host with an LD_PRELOAD of its own
# loads it before libasan and asan refuses to start, which a static
# runtime cannot run into.
asan_build = get_option('b_sanitize').contains('address')
tsan_build = get_option('b_sanitize').contains('thread')

objcopy = find_program('objcopy')

# every tools/*.lua and test/*.lua tool is run through this rather
# than relying on a shebang + preserved execute bit.
lua_interp = find_program('lua5.4', 'lua')

# the per-arch table, and the only place any of it is written down.
# it decides which sources build, what the esp must call the loader for
# the firmware to find it (the UEFI spec's removable-media path), and
# what machine-specific flags the compiler needs. everything downstream
# -- tools/arch.lua, test/qemuarch.lua -- is told the answer rather
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

if platform == 'wasm' and arch != 'wasm32'
  error('the wasm platform needs --cross-file cross/wasm32.txt')
endif

# every port needs the platform layer (src/<arch>/machine.c, setjmp.S)
# plus a way to reach fw_cfg, a second serial port, and the libm floor.
# efi also needs header.S (the hand PE32+ header/entry) and reloc.c
# (self-relocation to wherever firmware loaded it) -- microvm links at
# a fixed physical address instead (see src/platform/microvm/boot.S),
# so it needs neither.
#
# hosted needs none of it: there is no boot stub to write, and the
# clock, setjmp and libm all come from the host's own libc.
if platform == 'hosted'
  plat_src = []
elif platform == 'wasm'
  # no setjmp.S: wasm has no stack to save, so the compiler lowers
  # setjmp itself and calls what src/wasm32/sjlj.c defines.
  plat_src = files(
    'src' / arch / 'machine.c',
    'src' / arch / 'sjlj.c',
    'src' / arch / 'longjmp.S',
  )
else
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
endif

# the architecture: its flags and the sources only it has. A process
# takes the host toolchain's defaults and has no boot stub at all, so
# it is the one machine that descends nowhere.
if platform == 'hosted'
  arch_args = []
  arch_src = []
  boot_efi = ''
elif arch == 'x86_64' or arch == 'aarch64' or arch == 'riscv64' or arch == 'wasm32'
  subdir('src' / arch)
else
  error('no src/' + arch + ': x86_64, aarch64, riscv64 and wasm32 are ported')
endif

# hosted compiles against the host's libc, so include/ stays OFF the
# path: our stdio.h and string.h would shadow glibc's and the structs
# would not match. src/platform/hosted/sys/queue.h is the one exception
# and names the project copy by path.
#
# LUA_USE_LINUX is deliberately not defined. It would give lua popen and
# dlopen, which every other platform lacks, so the guest would have
# authority here that it has nowhere else.
if platform == 'hosted'
  # the window, if this host has SDL. Optional and auto: a host without
  # it builds a machine with no screen, which is what --headless asks
  # for anyway, and the fb tests then skip rather than fail.
  sdl_dep = dependency('sdl2', required: get_option('sdl'))
  hosted_args = [
    '-D_GNU_SOURCE',
    '-DNCPU=8',
    '-fno-strict-aliasing',
    '-DLUA_USER_H="coreg.h"',
    '-DLUA_PATH_DEFAULT="/?.lua;/lib/?.lua"',
    '-DLUA_CPATH_DEFAULT=""',
  ]
  if sdl_dep.found()
    hosted_args += '-DHAVE_SDL'
  endif
  # named by the targets that want them rather than added to the
  # project: a machine's flags belong to that machine's targets.
  plat_args = hosted_args
  inc = include_directories('src', 'lua', 'src/platform/hosted')
endif

# freestanding: our include/ plus only the compiler's own headers.
# pic + hidden is for the RELATIVE-relocs-only self-relocation scheme.
gccinc = run_command(cc.cmd_array() + ['-print-file-name=include'],
  check: true).stdout().strip()

# wasm relocates nothing: a module is loaded at offset zero of its own
# linear memory, so the pic half below describes a scheme it has no use
# for. What it needs instead is the exception handling the compiler
# lowers setjmp onto; see src/wasm32/sjlj.c.
if platform == 'wasm'
  codegen_args = [
    '-mexception-handling',
    '-mbulk-memory',
    '-mllvm', '-wasm-enable-sjlj',
    '-mllvm', '-wasm-use-legacy-eh=false',
  ]
else
  codegen_args = ['-fpic', '-fvisibility=hidden']
endif

freestanding_args = [
  '-ffreestanding',
  '-fno-stack-protector',
  '-fno-strict-aliasing',
  '-fshort-wchar',
  '-nostdinc',
  '-I' + gccinc,
] + [
  # src/coreg.h, through the hook lua provides for exactly this: it
  # redefines LUA_EXTRASPACE and the luai_userstate* macros so the
  # kernel can keep every lua_State of a proc on a list. lua/ is a
  # submodule of upstream and stays untouched.
  '-DLUA_USER_H="coreg.h"',
  '-DLUA_PATH_DEFAULT="/?.lua;/lib/?.lua"',
  '-DLUA_CPATH_DEFAULT=""',
] + codegen_args + arch_args

message('lua-os host system: ' + host_machine.system())

openbsd_freestanding_args = []
if host_machine.system() == 'openbsd'
  openbsd_freestanding_args = ['-idirafter/usr/include/.']
endif

if platform != 'hosted'
  plat_args = freestanding_args
  inc = include_directories('include', 'src', 'lua', 'src' / arch,
    'src/platform' / platform)
endif

# dirs.c/kernel.c/linit.c are firmware-blind (the platform seam is
# platform.h + fs.h/efi.h, all resolved from the per-platform
# include dir above); everything else is the platform's own.
# The shared source lists live in tools/sources.lua, which ESP-IDF's
# cmake reads too: two build systems is the honest answer for esp32,
# and one list is what stops them drifting apart unnoticed.
sources_lua = files('tools/sources.lua')

# the revision, generated once and consumed three ways: revision.h for
# the C symbol, /VERSION.app in the embedded tree, and /VERSION.fs on
# every filesystem image. One producer is what makes comparing them
# mean something -- three generators could each be right and disagree.
#
# Always stale, because the answer depends on the tree rather than on
# any file a build system could watch. version.lua rewrites it only
# when it changed, so this does not relink the kernel every build.
version_txt = custom_target('version.txt',
  output: 'version.txt',
  command: [lua_interp, files('tools/version.lua'), '@OUTPUT@'],
  build_always_stale: true,
)

version_h = custom_target('revision.h',
  input: version_txt,
  output: 'revision.h',
  command: [lua_interp, files('tools/version_h.lua'), '@INPUT@', '@OUTPUT@'],
)

kernel_src = files(run_command(lua_interp, sources_lua, 'kernel', check: true)
  .stdout().strip().split('\n'))
kernel_src += version_h

libc_src = files(run_command(lua_interp, sources_lua, 'libc', check: true)
  .stdout().strip().split('\n'))

lua_src = files(run_command(lua_interp, sources_lua, 'lua', check: true)
  .stdout().strip().split('\n'))

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
  # trap rather than call a runtime, which is what makes a sanitizer
  # usable here at all: there is no libc to link one from. On its own
  # this flag does nothing -- it says how to report, not what to check
  # -- so it sat here inert until -Dubsan turned a checker on.
  '-fsanitize-trap=all',
]
  if cc.has_argument(a)
    hardening_args += a
  endif
endforeach

if host_machine.system() == 'openbsd' and cc.has_argument('-Wno-error=attributes')
  hardening_args += '-Wno-error=attributes'
endif

# see meson.options: off by default because it costs up to 1.9x on the
# serializer, so a build measuring anything wants it off.
if get_option('ubsan')
  if cc.has_argument('-fsanitize=undefined')
    hardening_args += '-fsanitize=undefined'
  else
    error('-Dubsan=true but the compiler has no -fsanitize=undefined')
  endif
endif

# vanilla lua, warnings left to upstream
lua_lib = static_library('lua54', lua_src,
  include_directories: inc,
  c_args: plat_args + openbsd_freestanding_args,
)


# hostutil: the one C module backing the host-driven test clients
# (test/test_9p.lua etc) -- sockets and argv-array process spawning,
# neither of which stock Lua has. built native regardless of
# -Dplatform/cross-file, since this runs on the machine driving the
# tests, never the guest. optional like fw_network below: a host
# without lua5.4's headers just doesn't run these four tests, rather
# than failing the whole configure.
lua54_dep = dependency('lua5.4', native: true, required: false)
have_hostutil = lua54_dep.found()

# lrzsz and socat, for the zmodem tests on both platforms. Optional on
# purpose: nothing in the guest depends on either, and socat is here
# only because lrzsz wants its stdio on a pipe pair while hostutil hands
# out sockets.
sz_prog = find_program('sz', 'lsz', required: false)
rz_prog = find_program('rz', 'lrz', required: false)
socat_prog = find_program('socat', required: false)
# BlueZ's virtual controller, for the HCI tests. Rarely on PATH: it is
# a noinst program, built only with ./configure --enable-testing, so
# -Dbtvirt=/path/to/emulator/btvirt is the usual way to name it. Absent,
# the codec still runs and only the exchanges with a controller are lost.
btvirt_prog = find_program(get_option('btvirt'), 'btvirt', required: false)
btmon_prog = find_program('btmon', required: false)
sshd_prog = find_program('sshd', required: false,
  dirs: ['/usr/sbin', '/usr/bin', '/sbin'])
sshkeygen_prog = find_program('ssh-keygen', required: false)
ssh_prog = find_program('ssh', required: false)
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

# src/buf.c is los.buf, which lib/ files use for anything with bytes in
# it. The host tests run those files under the host's own lua5.4, so it
# has to exist there too: the same source, built against test/hostbuf.c
# for the two things it wants from the kernel. One implementation, and
# test/boot/test_buf.lua covers it on the other side.
#
# Named los.so for the same reason gefs.so is: the C-path searcher takes
# a.b to a.so and calls luaopen_a_b, so require("los.buf") finds
# luaopen_los_buf with no build subdirectory to arrange.
#
# host_deps must be passed as `depends:` by every test using it. `meson
# test` builds only what the selected tests declare, not `all`, so
# build_by_default is no help when a test names a subset: the module is
# simply absent and the test fails as a missing lua module. It looked
# like it worked because the default LUA_CPATH ends in ./?.so and the
# test's cwd is the build directory, so a stale copy from an earlier
# full build was found by accident.
host_deps = []
if lua54_dep.found()
  buf_native_host = shared_module('los',
    ['src/buf.c', 'test/hostbuf.c'],
    name_prefix: '',
    include_directories: include_directories('src'),
    dependencies: lua54_dep,
    native: true,
    build_by_default: true,
  )
  host_deps += buf_native_host

  # dev, which every filesystem lib requires. The guest preloads it; on
  # the host it has to be a module the loader can find, or lib/fat and
  # lib/gefs cannot be tested here at all.
  dev_native_host = shared_module('dev',
    ['src/dev.c', 'src/buf.c', 'test/hostbuf.c'],
    name_prefix: '',
    include_directories: include_directories('src'),
    dependencies: lua54_dep,
    native: true,
    build_by_default: true,
  )
  host_deps += dev_native_host

  # chan, which ns and nsfs build over dev.
  chan_native_host = shared_module('chan',
    ['src/chan.c', 'src/dev.c', 'src/buf.c', 'test/hostbuf.c'],
    name_prefix: '',
    include_directories: include_directories('src'),
    dependencies: lua54_dep,
    native: true,
    build_by_default: true,
  )
  host_deps += chan_native_host

  # the same primitives the guest preloads, so lib/crypto and what sits
  # on it can be tested here rather than only on a board.
  crypto_native_host = shared_module('crypto',
    ['src/native_glue.c', 'test/hostcrypto.c', 'src/buf.c',
     'test/hostbuf.c'],
    name_prefix: '',
    include_directories: include_directories('src'),
    dependencies: lua54_dep,
    native: true,
    build_by_default: true,
  )
  host_deps += crypto_native_host
endif

# src/gefs_native.c built for the host, so the host test exercises the
# same hash the guest does rather than a second implementation that
# merely agrees with it. lib/gefs/hash.lua has no fallback.
#
# Named `gefs` rather than `gefs/native` because lua's last searcher
# takes a.b to a.so and calls luaopen_a_b -- so gefs.so answers
# require("gefs.native") through luaopen_gefs_native, with no build
# subdirectory to arrange. require("gefs") itself still finds
# lib/gefs/init.lua, because the lua-path searcher runs before this one.
#
# Up here, above every platform's own section: the gefs-host test runs
# on all of them, and the efi image's gefs.img is built by running lua
# against this module.
#
# gefs_host_deps carries both modules, since anything reaching lib/gefs
# also reaches los.buf. See the note at host_deps for why `depends:` is
# required rather than merely tidy.
gefs_host_deps = []
if lua54_dep.found()
  gefs_native_host = shared_module('gefs',
    ['src/gefs_native.c'],
    name_prefix: '',
    dependencies: lua54_dep,
    native: true,
    build_by_default: true,
  )
  gefs_host_deps += [gefs_native_host, buf_native_host]

  # the decoder's hot loop, so the host test runs the C the guest runs
  # rather than a lookalike. require("adpcm.native") reaches it through
  # luaopen_adpcm_native in adpcm.so.
  adpcm_native_host = shared_module('adpcm',
    ['src/adpcm_native.c'],
    name_prefix: '',
    dependencies: lua54_dep,
    native: true,
    build_by_default: true,
  )
endif

# Every native host module is declared above, so all of them land in the
# build root and one LUA_CPATH entry reaches the lot. Prepended, so the
# build tree wins: a module installed under one of our names -- dev, los
# and chan are ordinary words -- must not answer instead of ours.
#
# The same block goes to the tests and to `meson devenv`, which is what
# lets a script say require("hostutil") whether meson runs it or a
# person does:
#
#	meson devenv -C build lua5.4 tools/poke-esp32.lua push bin/x.lua
#	eval "$(meson devenv -C build --dump)"
#
# .lua modules are not here on purpose. Each script prepends its own
# directory to package.path from arg[0], which works from any build dir
# and does not let tools/gefs.lua shadow lib/gefs.lua.
#
# The ";;" goes last, where lua expands it to the compiled-in default.
# Behind the caller's own entries rather than ahead of them, so a module
# we do not have resolves the way it would outside a build.
lua_host_env = environment()
lua_host_env.prepend('LUA_CPATH', meson.project_build_root() + '/?.so',
  separator: ';')
lua_host_env.append('LUA_CPATH', ';', separator: ';')
meson.add_devenv(lua_host_env)
add_test_setup('default', is_default: true, env: lua_host_env)

# the esp32 boards: run targets that drive ESP-IDF, since that build
# cannot be replaced by this one. The IDF project itself stays at
# esp32/, which is a meson project of its own and cannot be a subdir.
# one branch, and the machine describes itself: its sources, its
# compile and link, the image built from it and the targets that run
# it all live beside the C they belong to.
# tests that ask nothing of either platform's hardware, so the same file
# runs on both and is named without a platform prefix. Keeping one copy
# is the point: close() truncating everything past the send window lived
# in the shared stack, shipped on main, and was caught by one test on one
# platform -- a second copy of that test would have been a second thing
# to forget to update.
#
# [name, microvm boot flags, needs a nic]. "needs a nic" is not about the
# wire -- tcploop never reaches it -- but about the tcp task existing at
# all, since kernel.c only spawns ip and tcp4 when a card is present.
shared_tests = [
  ['tcploop', ['--net'], true],
  ['checksum', [], false],
]



# the tests that need neither platform: lua on the host, and the C that
# has no kernel in it. They register for every -Dplatform, because
# nothing about them is one.
subdir('src/platform' / platform)

subdir('src/platform/esp32')


subdir('test')
