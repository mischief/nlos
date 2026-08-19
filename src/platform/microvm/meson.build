# microvm: the sources this machine adds, its link, and the image built
# from it.

kernel_src += files(
  '../../../src/platform/microvm/console.c',
  '../../../src/platform/microvm/drivers.c',
  '../../../src/platform/microvm/fs.c',
  '../../../src/platform/microvm/main.c',
  '../../../src/platform/microvm/malloc.c',
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
     : meson.project_source_root() / boot_payload),
  # the machine picks its own list, installed under the one name the
  # payload reads -- the same arrangement the efi and esp32 builds use.
  '/etc/services.lua=' + meson.project_source_root() /
      'machine/microvm/services.lua']
# the same list twice over: the guest's name for a module is the
# path as written, and the input is that path against the root.
embed_inputs = []
foreach f : embed_files
  embed_args += '/' + f + '=' + meson.project_source_root() / f
  embed_inputs += files('../../../' + f)
endforeach
# the revision, beside the modules rather than among them: it is
# generated, so it is named by path and not through embed_files.
embed_args += '/VERSION.app=' + version_txt.full_path()
embedfs_src = custom_target('embedfs.c',
  output: 'embedfs.c',
  input: embed_inputs + files('../../../' + boot_payload),
  command: [lua_interp, files('../../../tools/gen_embedfs.lua'), '@OUTPUT@'] + embed_args,
  depends: version_txt,
)
kernel_src += embedfs_src

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
  link_depends: files('../../../src/platform/microvm/microvm.ld'),
  build_by_default: true,
)

# boots test/boot/microvm_hello.lua via fw_cfg, the only way to run
# code here (no filesystem yet) -- console on stdio, -no-reboot turns
# the deliberate triple-fault shutdown into a clean qemu exit.
run_target('qemu-microvm',
  command: [lua_interp, files('../../../tools/qemu-microvm.lua'), luaos_microvm_elf,
    files('../../../test/boot/microvm_hello.lua')],
)


# the microvm tests, which are the efi boot tests' counterpart: payload
# injected via fw_cfg, TAP on com1, guest ends itself. They register
# only for this platform because a build is configured for one or the
# other, so `meson test` runs whichever suite the build can actually
# produce a guest for.
#
# see the note on `boottest` above for why this is passed as a program
# rather than an argv list.
microvm_boottest = files('../../../tools/boottest-microvm.lua')

# every guest gets a virtio-rng. --9p additionally serves a seeded
# temporary directory over virtio-9p; only the mount test wants one,
# and it wants a private directory since it creates a file.
microvm_tests = [
  ['hello', []],
  ['rng', []],
  ['p9mount', ['--9p']],
  ['p9bench', ['--9p']],
  ['blk', ['--blk']],
  ['gefs', ['--gefscommit']],
  ['gefssrv', ['--gefscommit']],
  ['gefspar', ['--gefs']],
  ['gefsshutdown', ['--gefscommit']],
  ['gefsgpt', ['--gefsgpt']],
  ['gefspart', ['--gefsgpt']],
  ['fat', ['--fat']],
  ['eth', ['--net']],
  ['arp', ['--net']],
  ['ping', ['--net']],
  ['dhcp', ['--net']],
  ['netfiles', ['--net']],
  ['dns', ['--net']],
  ['iptask', ['--net']],
  ['udpq', ['--net']],
  ['loopback', ['--net']],
  ['udpbench', ['--net']],
  ['autoip', ['--net']],
  ['ipraw', ['--net']],
  ['tcp', ['--netecho']],
  ['tcpbench', ['--net']],
  ['idle', []],
  ['smp', ['--smp=2']],
  ['spin', []],
  ['pairs', []],
  ['claim', []],
  ['altpending', []],
  ['bigmsg', []],
  ['sample', []],
]

# The gefs entries build their disk image at test time, in the host's
# own lua, so the harness reaches lib/gefs and needs gefs.native. Named
# for every entry rather than only those: the cost is nothing for a test
# that does not load it, and a --gefs flag added to an entry later would
# otherwise fail as a missing lua module far from this list.
# payloads that reach the ip or tcp task, and so must run under a real
# init: those are services now. A raw-ethernet test is deliberately not
# here -- it wants the wire to itself, and the ip task would take frames
# from under it.
net_service_tests = ['dhcp', 'netfiles', 'dns', 'iptask', 'udpq',
  'loopback', 'udpbench', 'autoip', 'ipraw', 'tcp', 'tcpbench',
  'tcploop', 'fetch', 'httpd']

foreach t : microvm_tests
  tflags = t[1]
  if t[0] in net_service_tests
    tflags += ['--services']
  endif
  test('microvm-' + t[0], microvm_boottest,
    args: [luaos_microvm_elf, files('../../../test/boot/microvm_' + t[0] + '.lua')] +
      tflags,
    protocol: 'tap',
    timeout: 60,
    is_parallel: true,
    env: gefs_host_env,
    depends: gefs_host_deps,
  )
endforeach

# the same payloads on a machine with more than one cpu. This is where
# the scheduler, the ipc lock and the reschedule ipi are actually under
# contention rather than merely present: everything above runs them on
# one cpu, which exercises the ordering and none of the racing.
#
# Two shapes because they fail differently. Two cpus is the smallest
# machine where a wakeup can cross, and four is where a proc's home is
# usually not the sender's.
microvm_smp_tests = [
  ['hello', []],
  ['rng', []],
  ['idle', []],
  ['blk', ['--blk']],
  ['p9mount', ['--9p']],
  ['eth', ['--net']],
  ['tcp', ['--netecho']],
  ['gefssrv', ['--gefscommit']],
  ['gefspar', ['--gefs']],
  ['spin', []],
  ['pairs', []],
  ['claim', []],
  ['altpending', []],
  ['bigmsg', []],
  ['sample', []],
  ['spawnrace', []],
  ['dbg', []],
]

foreach n : ['2', '4']
  foreach t : microvm_smp_tests
    tflags = t[1]
    if t[0] in net_service_tests
      tflags += ['--services']
    endif
    test('smp' + n + '-' + t[0], microvm_boottest,
      args: [luaos_microvm_elf,
        files('../../../test/boot/microvm_' + t[0] + '.lua'),
        '--smp=' + n] + tflags,
      protocol: 'tap',
      timeout: 60,
      is_parallel: true,
      env: gefs_host_env,
      depends: gefs_host_deps,
    )
  endforeach
endforeach

foreach t : shared_tests
  tflags = t[1]
  if t[0] in net_service_tests
    tflags += ['--services']
  endif
  test('microvm-' + t[0], microvm_boottest,
    args: [luaos_microvm_elf, files('../../../test/boot/shared_' + t[0] + '.lua')] + tflags,
    protocol: 'tap',
    timeout: 60,
    is_parallel: true,
    env: gefs_host_env,
    depends: gefs_host_deps,
  )
endforeach

# the same guest on a q35, where the devices are virtio-pci behind PCIe
# root ports rather than virtio-mmio in a fixed window. That is the
# machine systemd-vmspawn builds and the shape real hardware has, and it
# exercises what mmio never touches: the bridge walk, memory BARs, and
# MSI-X (src/platform/microvm/pci.c, virtio_pci.c).
#
# One test per device class rather than the whole list. What differs
# between the transports is discovery and interrupt delivery, which any
# one test of a device establishes; everything above the ring is the
# same code either way and is already covered above.
microvm_pci_tests = [
  ['hello', []],
  ['rng', []],
  ['blk', ['--blk']],
  ['p9mount', ['--9p']],
  ['eth', ['--net']],
  ['ping', ['--net']],
  ['tcp', ['--netecho']],
]

# and the same devices on the root bus, where they are transitional:
# other PCI ids, other BARs, no bridge. rng is what systemd-vmspawn
# itself attaches that way, and blk is the one whose transitional id
# (0x1001) is furthest from the formula a reader would guess.
microvm_pci0_tests = [
  ['rng', []],
  ['blk', ['--blk']],
]

foreach t : microvm_pci0_tests
  test('pci0-' + t[0], microvm_boottest,
    args: [luaos_microvm_elf, files('../../../test/boot/microvm_' + t[0] + '.lua')] +
      t[1] + ['--pci0'],
    protocol: 'tap',
    timeout: 60,
    is_parallel: true,
    env: gefs_host_env,
    depends: gefs_host_deps,
  )
endforeach

foreach t : microvm_pci_tests
  tflags = t[1]
  if t[0] in net_service_tests
    tflags += ['--services']
  endif
  test('pci-' + t[0], microvm_boottest,
    args: [luaos_microvm_elf, files('../../../test/boot/microvm_' + t[0] + '.lua')] +
      tflags + ['--pci'],
    protocol: 'tap',
    timeout: 60,
    is_parallel: true,
    env: gefs_host_env,
    depends: gefs_host_deps,
  )
endforeach

# http over the lua tcp stack, host-driven for the reason its own header
# gives: a guest cannot reach its own listener (slirp does not hairpin),
# so hostfwd gives the host a door in and hostutil walks through it. This
# is the test listen and accept exist for -- the guest runs lib/http.lua
# and lib/caps.lua unmodified, and the client is a separate
# implementation on the host.
# bin/rz.lua and bin/sz.lua against real lrzsz, over a pty bridged to
# the guest console. The only zmodem test with the whole path in it:
# raw mode, the tty client's readraw, the program ABI, and the launcher
# starting rz because a sender asked for it by name.
if have_hostutil and sz_prog.found() and rz_prog.found() and \
    socat_prog.found()
  test('microvm-zmodem', lua_interp,
    args: [files('../../../tools/zmodemtest.lua'), luaos_microvm_elf],
    protocol: 'tap',
    timeout: 400,
    env: {'HOSTUTIL_SO': hostutil.full_path()},
    depends: hostutil,
  )
endif

if have_hostutil
  test('microvm-http', lua_interp,
    args: [files('../../../test/microvm_http.lua'), luaos_microvm_elf,
      files('../../../test/boot/microvm_httpd.lua')],
    protocol: 'tap',
    timeout: 60,
    env: {'HOSTUTIL_SO': hostutil.full_path()},
    depends: hostutil,
  )
endif

# bulk transfer, with the host as the server. No forwarding needed in
# this direction: qemu proxies a guest's connection to 10.0.2.2 onto the
# host's loopback, which is where test/hostserver.lua binds. Several
# megabytes each way is thousands of segments, a receive window that
# closes and reopens continuously, and a send buffer that fills -- none
# of which a five-byte echo reaches.
if have_hostutil
  test('microvm-bulk', lua_interp,
    args: [files('../../../test/microvm_bulk.lua'), luaos_microvm_elf,
      files('../../../test/boot/microvm_bulk.lua')],
    protocol: 'tap',
    timeout: 120,
    env: {'HOSTUTIL_SO': hostutil.full_path()},
    depends: hostutil,
  )
endif

# serial receive needs the port in BOTH directions, which the boottest
# harness cannot do -- it points the guest's serial at a file. This one
# drives a unix socket instead, so it is host-driven like the efi
# platform's 9p test and needs hostutil for the same reason.
# the no-fw_cfg path: nothing injected, so the guest runs the console
# repl embedded in its own image, and this types at it. Needs the port
# in both directions, so it is here with the other socket-driven test
# rather than in the boottest loop. Tested under qemu because that is
# where a test can run; it exists for vmd, which has no other way in.
if have_hostutil
  test('microvm-embedded-boot', lua_interp,
    args: [files('../../../test/microvm_repl.lua'), luaos_microvm_elf],
    protocol: 'tap',
    timeout: 120,
    env: {'HOSTUTIL_SO': hostutil.full_path()},
    depends: hostutil,
  )
endif

if have_hostutil
  test('microvm-serialrx', lua_interp,
    args: [files('../../../test/microvm_serial.lua'), luaos_microvm_elf,
      files('../../../test/boot/microvm_serialrx.lua')],
    protocol: 'tap',
    timeout: 120,
    env: {'HOSTUTIL_SO': hostutil.full_path()},
    depends: hostutil,
  )
endif

