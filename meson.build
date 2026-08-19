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

if platform == 'hosted'
  arch_args = []
  arch_src = []
  boot_efi = ''
elif arch == 'x86_64'
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
  if platform == 'microvm'
    # the only configuration with more than one cpu; everything else
    # takes lock.h's uniprocessor path.
    arch_args += '-DNCPU=8'
  endif
  if platform == 'efi'
    arch_src += files('src/x86_64/uart.c')
  else
    arch_src += files(
      'src/platform/microvm/boot.S',
      'src/platform/microvm/idt_stubs.S',
      'src/platform/microvm/idt.c',
      'src/platform/microvm/lapic.c',
      'src/platform/microvm/ioapic.c',
      'src/platform/microvm/i8259.c',
      'src/platform/microvm/i8253.c',
      'src/platform/microvm/intr.c',
      'src/platform/microvm/pci.c',
      'src/platform/microvm/tsc.c',
      'src/platform/microvm/pmm.c',
      'src/platform/microvm/smp.c',
      'src/platform/microvm/smp_trampoline.S',
      'src/platform/microvm/uart.c',
      'src/platform/microvm/reset.c',
      'src/platform/microvm/efi_shim.c',
      'src/platform/microvm/virtio.c',
      'src/platform/microvm/virtio_mmio.c',
      'src/platform/microvm/virtio_pci.c',
      'src/platform/microvm/virtio_rng.c',
      'src/platform/microvm/virtio_9p.c',
      'src/platform/microvm/virtio_net.c',
      'src/platform/microvm/virtio_blk.c',
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
  sdl_dep = dependency('sdl3', required: get_option('sdl'))
  hosted_args = [
    '-D_GNU_SOURCE',
    '-fno-strict-aliasing',
    '-DLUA_USER_H="coreg.h"',
    '-DLUA_PATH_DEFAULT="/?.lua;/lib/?.lua"',
    '-DLUA_CPATH_DEFAULT=""',
  ]
  if sdl_dep.found()
    hosted_args += '-DHAVE_SDL'
  endif
  add_project_arguments(hosted_args, language: 'c')
  inc = include_directories('src', 'lua', 'src/platform/hosted')
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
  # src/coreg.h, through the hook lua provides for exactly this: it
  # redefines LUA_EXTRASPACE and the luai_userstate* macros so the
  # kernel can keep every lua_State of a proc on a list. lua/ is a
  # submodule of upstream and stays untouched.
  '-DLUA_USER_H="coreg.h"',
  '-DLUA_PATH_DEFAULT="/?.lua;/lib/?.lua"',
  '-DLUA_CPATH_DEFAULT=""',
] + arch_args

if platform != 'hosted'
  add_project_arguments(freestanding_args, language: 'c')
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
if platform == 'hosted'
  kernel_src += files(
    'src/platform/hosted/blk.c',
    'src/platform/hosted/clock.c',
    'src/platform/hosted/fb.c',
    'src/platform/hosted/console.c',
    'src/platform/hosted/drivers.c',
    'src/platform/hosted/fs.c',
    'src/platform/hosted/machine.c',
    'src/platform/hosted/main.c',
    'src/platform/hosted/net.c',
  )

  # the tree, carried in the binary, so --no-host-fs has a root. The
  # list is tools/embedtree.lua's rather than a literal here because it
  # is every lua file under lib, bin and task: a curated list would be a
  # second place to forget a new module.
  hosted_embed = run_command(lua_interp, files('tools/embedtree.lua'),
    check: true).stdout().strip().split('\n')

  embed_args = ['/etc/services.lua=' + meson.current_source_dir() /
      'machine/hosted/services.lua']
  foreach f : hosted_embed
    embed_args += '/' + f + '=' + meson.current_source_dir() / f
  endforeach
  embed_args += '/VERSION.app=' + version_txt.full_path()

  kernel_src += custom_target('embedfs.c',
    output: 'embedfs.c',
    input: files(hosted_embed) +
      files('machine/hosted/services.lua'),
    command: [lua_interp, files('tools/gen_embedfs.lua'), '@OUTPUT@'] + embed_args,
    depends: version_txt,
  )
elif platform == 'efi'
  kernel_src += files(
    'src/platform/efi/blk.c',
    'src/platform/efi/console.c',
    'src/platform/efi/drivers.c',
    'src/platform/efi/fs.c',
    'src/platform/efi/gop.c',
    'src/platform/efi/los.c',
    'src/platform/efi/main.c',
    'src/platform/efi/malloc.c',
    'src/platform/efi/rng.c',
    'src/platform/efi/snp.c',
  )
else
  kernel_src += files(
    'src/platform/microvm/console.c',
    'src/platform/microvm/drivers.c',
    'src/platform/microvm/efi_shim.c',
    'src/platform/microvm/fs.c',
    'src/platform/microvm/main.c',
    'src/platform/microvm/malloc.c',
  )

  # what the microvm C loader can open before any namespace exists (see
  # src/platform/microvm/fs.c). Deliberately only the libs needed to
  # reach the point of mounting something: the driver tasks' own
  # lib/*.lua, los.thread, and the 9p client that turns virtio-9p into a
  # mount. Anything you want to edit without rebuilding belongs on that
  # mount, not in this list -- every entry here is frozen at build time.
  #
  # boot/microvm.lua is the exception in kind: not a lib but the payload
  # main.c falls back to when no fw_cfg one was injected, which is the
  # only way this image boots on a loader whose fw_cfg cannot serve
  # arbitrary files (OpenBSD vmd).
  # -Dboot_payload names what gets embedded AS /boot/microvm.lua, so
  # main.c's BOOT_PAYLOAD path stays fixed and only the contents change.
  # See meson.options for why this is worth an option: on vmd it is the
  # only program that can ever run.
  boot_payload = get_option('boot_payload')

  embed_files = [
    # tls, and the closure it pulls in. This machine has no disk, so a
    # guest that is to reach an https server has to carry the whole
    # stack in the image -- and being able to is what makes microvm the
    # quick way to work on anything that talks to the network.
    'lib/tlstcp.lua',
    'lib/tls/client.lua',
    'lib/tls/conn.lua',
    'lib/tls/hello.lua',
    'lib/tls/keys.lua',
    'lib/tls/record.lua',
    'lib/tls/server.lua',
    'lib/tls/tofu.lua',
    'lib/tls/wire.lua',
    'lib/x509/cert.lua',
    'lib/x509/der.lua',
    # named only through a table in tls/tofu.lua, so a dependency
    # scan does not see them: the signature algorithm picks one.
    'lib/crypto/sha384.lua',
    'lib/crypto/aead.lua',
    'lib/crypto/bignum.lua',
    'lib/crypto/ed25519.lua',
    'lib/crypto/field25519.lua',
    'lib/crypto/hkdf.lua',
    'lib/crypto/hmac.lua',
    'lib/crypto/p256.lua',
    'lib/crypto/secp256k1.lua',
    'lib/crypto/rsa.lua',
    'lib/crypto/sha512.lua',
    'lib/crypto/util.lua',
    'lib/crypto/x25519.lua',
    'lib/bech32.lua',
    'lib/nostr.lua',
    'lib/nostrrelay.lua',
    'lib/websocket.lua',
    'lib/crypto/sha1.lua',
    'lib/json.lua',
    'lib/llm.lua',
    'lib/agent.lua',
    # a couple of programs, so the spawn path has something to run:
    # this machine has no disk, so /bin exists only if the image says.
    'lib/prog.lua',
    'lib/stream/port.lua',
    'lib/stream/pipe.lua',
    'lib/stream/chan.lua',
    'lib/client/tty.lua',
    'lib/client/power.lua',
    'lib/client/udp.lua',
    'lib/draw.lua',
    'lib/mouse.lua',
    'lib/time.lua',
    'bin/ls.lua',
    'bin/cat.lua',
    'lib/console.lua',
    'lib/fbcons.lua',
    'task/cons.lua',
    'task/wire.lua',
    'task/power.lua',
    'lib/stdout.lua',
    'lib/ninep.lua',
    'lib/srv.lua',
    'lib/mnt.lua',
    'lib/ns.lua',
    # ns:adopt reaches nsio, and lib/proc.lua's bootstrap is what calls
    # adopt. Without both, no proc on this platform can take a namespace
    # it was handed -- which is how every service task gets one.
    'lib/nsio.lua',
    'lib/proc.lua',
    'lib/lazy.lua',
    'lib/devtree.lua',
    'lib/p9fs.lua',
    'lib/p9tcp.lua',
    'task/p9srv.lua',
    'lib/blkfs.lua',
    'task/blksrv.lua',
    # gefs: a filesystem to mount over the block device above. Frozen in
    # rather than served over a mount because the direction is to boot
    # from it, which makes it a bootstrap dependency the way blkfs is.
    # salvage.lua is left out: it is a host recovery tool, not on any
    # path the guest takes.
    'lib/gefs.lua',
    'lib/gefs/dat.lua',
    'lib/gefs/hash.lua',
    'lib/gefs/pack.lua',
    'lib/gefs/obj.lua',
    'lib/gefs/blk.lua',
    'lib/gefs/store.lua',
    'lib/gefs/tree.lua',
    'lib/gefs/snap.lua',
    'lib/gefs/fsops.lua',
    'lib/gefs/check.lua',
    'lib/gefs/vol.lua',
    'lib/gefs/ram.lua',
    'lib/gefs/io.lua',
    'lib/gefs/slice.lua',
    'lib/gefsfs.lua',
    # lib/fat: the flash filesystem, frozen in so a boot test can mount
    # a FAT volume over the block device.
    'lib/fat.lua',
    'lib/fat/obj.lua',
    'lib/fat/dat.lua',
    'lib/fat/pack.lua',
    'lib/fat/vol.lua',
    'lib/fat/blk.lua',
    'lib/fat/fat.lua',
    'lib/fat/dir.lua',
    'lib/fat/fsops.lua',
    'lib/fat/check.lua',
    'lib/fatfs.lua',
    'lib/gpt.lua',
    'lib/partfs.lua',
    'task/partsrv.lua',
    'task/gefssrv.lua',
    'task/eth.lua',
    'lib/ether.lua',
    'lib/ip4.lua',
    'lib/arp.lua',
    'lib/ethwire.lua',
    'lib/icmp.lua',
    'lib/udp4.lua',
    'lib/tcp4.lua',
    'lib/inet.lua',
    'lib/dhcp.lua',
    'lib/dhcpc.lua',
    'lib/ntp.lua',
    'lib/time.lua',
    'lib/dns.lua',
    'lib/dnsc.lua',
    'lib/client/rpc.lua',
    'lib/client/tcp.lua',
    'lib/client/udp.lua',
    'lib/draw.lua',
    'lib/client/dns.lua',
    'lib/client/tty.lua',
    'lib/client/power.lua',
    'lib/client/wire.lua',
    'lib/client/rpc.lua',
    'lib/http.lua',
    'lib/crypto/chacha20.lua',
    'lib/crypto/poly1305.lua',
    'lib/crypto/hashstate.lua',
    'lib/crypto/sha256.lua',
    # what task/tcp4.lua draws an initial sequence number from when it
    # is started as a service: a service holds no raw rng, so lib/svc.lua
    # hands it a seed and it expands that here.
    'lib/crypto/drbg.lua',
    'lib/tcb.lua',
    'task/ip.lua',
    'task/tcp4.lua',
    'task/dhcpd.lua',
    'lib/srv.lua',
    'lib/sync/once.lua',
    'lib/sync/sema.lua',
    'lib/sync/lock.lua',
    'lib/tap.lua',
    'lib/ps.lua',
    'lib/battery.lua',
    'lib/zmodem.lua',
    # what init.lua needs before it has mounted anything. romfs is the
    # root on a machine with no disk, and is what makes the embedded
    # files above reachable by path rather than by require alone.
    'lib/romfs.lua',
    'lib/procfs.lua',
    'lib/svc.lua',
    'lib/svcarg.lua',
    'lib/dnsc.lua',
    'task/dns.lua',
  ]
  embed_args = ['/boot/microvm.lua=' +
      (boot_payload.startswith('/') ? boot_payload
       : meson.current_source_dir() / boot_payload),
    # the machine picks its own list, installed under the one name the
    # payload reads -- the same arrangement the efi and esp32 builds use.
    '/etc/services.lua=' + meson.current_source_dir() /
        'machine/microvm/services.lua']
  foreach f : embed_files
    embed_args += '/' + f + '=' + meson.current_source_dir() / f
  endforeach
  # the revision, beside the modules rather than among them: it is
  # generated, so it is named by path and not through embed_files.
  embed_args += '/VERSION.app=' + version_txt.full_path()
  embedfs_src = custom_target('embedfs.c',
    output: 'embedfs.c',
    input: files(embed_files) + files(boot_payload),
    command: [lua_interp, files('tools/gen_embedfs.lua'), '@OUTPUT@'] + embed_args,
    depends: version_txt,
  )
  kernel_src += embedfs_src
endif

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
)

if platform == 'hosted'
  # an ordinary program. --wrap=fopen is what keeps luaL_loadfile and
  # io.open inside the served root and behind the disk capability; see
  # src/platform/hosted/fs.c.
  luaos_hosted = executable('luaos-hosted',
    kernel_src,
    include_directories: inc,
    c_args: hardening_args,
    link_with: lua_lib,
    dependencies: [cc.find_library('m', required: false), sdl_dep],
    link_args: ['-Wl,--wrap=fopen', '-Wl,--wrap=fopen64'],
    build_by_default: true,
  )

  # the tree as it stands, served as /. Nothing is built into an image,
  # so an edit under lib/ is live on the next run.
  run_target('hosted',
    command: [luaos_hosted, '-r', meson.current_source_dir()],
  )

  # the same binary with no directory behind it, which is what ships.
  run_target('hosted-selfcontained',
    command: [luaos_hosted, '--no-host-fs'],
  )

elif platform == 'efi'
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
      # do not emit a build-id: pe.ld discards .note.* (a flat binary has
      # nowhere to keep it), and generating one only to drop it warns.
      '-Wl,--build-id=none',
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
    command: [lua_interp, files('tools/qemu-microvm.lua'), luaos_microvm_elf,
      files('test/boot/microvm_hello.lua')],
  )
endif

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
# host_deps travels with host_env and must be passed as `depends:` by
# every test using it. `meson test` builds only what the selected tests
# declare, not `all`, so build_by_default is no help when a test names a
# subset: the module is simply absent and the test fails as a missing
# lua module. It looked like it worked because the default LUA_CPATH
# ends in ./?.so and the test's cwd is the build directory, so a stale
# copy from an earlier full build was found by accident.
host_env = environment()
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
  host_env.append('LUA_CPATH',
    meson.current_build_dir() / '?.so', separator: ';')
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
# LUA_CPATH is appended rather than set, so a caller's own is kept, and
# unconditionally as well as inside the branch: the gefs host test also
# loads los.buf, which is built beside this and by the same test for
# lua5.4's headers.
#
# gefs_host_deps carries both modules, since anything reaching lib/gefs
# also reaches los.buf. See the note at host_deps for why `depends:` is
# required rather than merely tidy.
gefs_host_env = environment()
gefs_host_deps = []
gefs_host_env.append('LUA_CPATH',
  meson.current_build_dir() / '?.so', separator: ';')
if lua54_dep.found()
  gefs_native_host = shared_module('gefs',
    ['src/gefs_native.c'],
    name_prefix: '',
    dependencies: lua54_dep,
    native: true,
    build_by_default: true,
  )
  gefs_host_env.append('LUA_CPATH',
    meson.current_build_dir() / '?.so', separator: ';')
  gefs_host_deps += [gefs_native_host, buf_native_host]
endif

# the esp32 boards: run targets that drive ESP-IDF, since that build
# cannot be replaced by this one. The IDF project itself stays at
# esp32/, which is a meson project of its own and cannot be a subdir.
subdir('src/platform/esp32')


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


if platform == 'efi'
subdir('src/platform/efi')
endif # platform == 'efi'

if platform == 'microvm'
subdir('src/platform/microvm')
endif # platform == 'microvm'

# the tests that need neither platform: lua on the host, and the C that
# has no kernel in it. They register for every -Dplatform, because
# nothing about them is one.
subdir('test')
