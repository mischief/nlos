
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

