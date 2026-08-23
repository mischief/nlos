# ---- the boot tests ----
#
# One payload per name under test/boot, run by whichever harness the
# platform has: a firmware boot for efi, a process for hosted. The two
# lists sit together so a name in one and not the other is visible --
# hosted has no firmware, no NIC and no framebuffer, and says so by
# leaving those out rather than by failing them.

if platform == 'hosted'
# ---- tests ----
# the payload runs as proc 0 of a process, so these cost milliseconds
# rather than a boot. Tests naming hardware this machine has not got
# are absent rather than failing: no NIC, no framebuffer, no firmware.
hosted_boottest = files('../tools/boottest-hosted.lua')
hosted_env = {
  'MESON_SOURCE_ROOT': meson.project_source_root(),
  'LUA_CPATH': meson.project_build_root() / '?.so;;',
}

hosted_tests = ['spawnarg', 'nsio', 'escape', 'stdout', 'channel', 'proc',
  'recovery', 'ipc', 'budget', 'memlimit', 'math', 'srv', 'mountcmd',
  'sendwait', 'sched', 'json', 'timer', 'pingpong', 'readdir', 'magic',
  'ns', 'hangup', 'procfs', 'buf', 'mnt', 'readonly', 'session', 'runq',
  'ninep_selfmount', 'p9stream', 'p9flush', 'chanstress', 'torture',
  'generator', 'sync', 'readline', 'mntconc', 'ports', 'pcm', 'font', 'nohook',
  'preempt', 'stack', 'broke', 'kill', 'exit', 'sshkbd', 'replyright',
  'rightsundo', 'procpriv', 'portlimit', 'trace', 'wakeup', 'nesting',
  'rng', 'sshcrypto', 'mlkem', 'sshmem', 'tls', 'layout', 'strictglobals',
  'bufout', 'bufmove', 'serialize', 'mntshare', 'althup', 'ninepc',
  'selfpipe', 'reboot', 'nsfs', 'zmodem', 'atexit', 'history',
  'top', 'portq', 'intr', 'intrsh', 'intrread', 'sibwake', 'reclaim',
  'lazy', 'strseed', 'clock', 'log', 'dbg', 'dbgstop', 'dbgbreak',
  'dbgstep', 'dbgread', 'dbgcap', 'dbglib', 'dbghole', 'secp256k1',
  'nostr']

foreach t : hosted_tests
  test('hosted-' + t, lua_interp,
    args: [hosted_boottest, luaos_hosted,
      files('boot/test_' + t + '.lua')],
    protocol: 'tap', timeout: 60, env: hosted_env,
  )
endforeach

# a small machine, because the point is to reach the ceiling: filling
# the default 512M with lua objects takes far longer than the test is
# worth, and what it proves does not depend on the figure.
test('hosted-oom', lua_interp,
  args: [hosted_boottest, luaos_hosted, files('boot/test_oom.lua'),
    '--mem=64'],
  protocol: 'tap', timeout: 60, env: hosted_env,
)

# what needs to write into the root: the harness copies the tree for
# these rather than letting a test edit the working copy.
foreach t : ['dev', 'prog', 'vi', 'xd']
  test('hosted-' + t, lua_interp,
    args: [hosted_boottest, luaos_hosted,
      files('boot/test_' + t + '.lua'), '--writable'],
    protocol: 'tap', timeout: 60, env: hosted_env,
  )
endforeach

# the screen, where this host has SDL to put one on. The window is
# SDL's dummy driver: the payloads read pixels back rather than look at
# them, so a test needs a framebuffer and not a display.
if sdl_dep.found()
  foreach t : ['fb', 'fbcons', 'fbprog', 'fbproxy', 'fbwin', 'dio']
    test('hosted-' + t, lua_interp,
      args: [hosted_boottest, luaos_hosted,
        files('boot/test_' + t + '.lua'), '--gui'],
      protocol: 'tap', timeout: 60, env: hosted_env,
    )
  endforeach
endif

# the park and wake path under many threads: p9bench's concurrent
# phase with no transport under it. Here because this is the platform a
# profiler can see into.
test('hosted-altbench', lua_interp,
  args: [hosted_boottest, luaos_hosted, files('boot/hosted_altbench.lua')],
  protocol: 'tap', timeout: 60, env: hosted_env,
)

# this machine's own, because no other takes tcp and udp from the
# platform rather than building them on frames.
foreach t : ['tcp', 'udp']
  test('hosted-' + t, lua_interp,
    args: [hosted_boottest, luaos_hosted,
      files('boot/hosted_' + t + '.lua')],
    protocol: 'tap', timeout: 60, env: hosted_env,
  )
endforeach

# the gnss stack, off a recording. The replay driver stands in for a
# receiver, so this runs wherever the tests do rather than only where a
# board is plugged in; LUAOS_GPS is the file it reads, and without one
# the machine simply has no receiver. Slower than its neighbours by
# design: the recording plays at the rate it was taken.
test('hosted-gps', lua_interp,
  args: [hosted_boottest, luaos_hosted, files('boot/hosted_gps.lua')],
  protocol: 'tap', timeout: 120,
  env: hosted_env + {
    'LUAOS_GPS': meson.project_source_root() / 'test/fixtures/gps-cold.nmea',
  },
)

# the disk, seeded by the harness. The payloads are the microvm ones:
# what they exercise is blk and the filesystems over it, which this
# machine has for the same reason that one does.
foreach t : [['blk', '--blk'], ['gefs', '--gefs'], ['gefssrv', '--gefs'],
  ['gefspar', '--gefs'], ['gefsshutdown', '--gefs']]
  test('hosted-' + t[0], lua_interp,
    args: [hosted_boottest, luaos_hosted,
      files('boot/microvm_' + t[0] + '.lua'), t[1]],
    protocol: 'tap', timeout: 120, env: hosted_env,
  )
endforeach

foreach t : shared_tests
  if not t[2]
    test('hosted-' + t[0], lua_interp,
      args: [hosted_boottest, luaos_hosted,
        files('boot/shared_' + t[0] + '.lua')],
      protocol: 'tap', timeout: 60, env: hosted_env,
    )
  endif
endforeach
endif # platform == 'hosted'

if platform == 'wasm'
# one test, and it is a smoke test: the module's proc 0 is always
# /init.lua, so there is no payload to inject and nothing here can emit
# TAP from inside the guest. The harness reads the console instead.
#
# Skipped where there is no engine to run it, which is the same trade
# the sdl and lrzsz tests make.
node_prog = find_program('node', 'nodejs', required: false)
if node_prog.found()
  test('wasm-boot', lua_interp,
    args: [files('../tools/boottest-wasm.lua'),
      files('../machine/wasm/run.js'), luaos_wasm,
      files('../tools/browsertest-wasm.js'),
      files('../machine/wasm/worker.js'),
      files('wasm/panel.json')],
    protocol: 'tap', timeout: 180,
    env: { 'NODE': node_prog.full_path() },
    depends: luaos_wasm,
  )
endif
endif # platform == 'wasm'

if platform == 'efi'
# ---- tests ----
# boot tests: the payload is injected via fw_cfg and replaces
# /init.lua; the guest emits TAP on com1 and powers off. the harness
# extracts the TAP for meson.

# test()'s program argument must be a single executable (not an argv
# list the way run_target/custom_target's command: can be), so this
# one relies on the shebang line + the execute bit, unlike every other
# tools/*.lua invocation in this file.
boottest = files('../tools/boottest.lua')

boot_tests = ['spawnarg', 'nsio', 'escape', 'stdout', 'channel', 'proc', 'recovery', 'ipc', 'budget', 'memlimit',
              'math',
              'srv', 'mountcmd', 'sendwait', 'drivers', 'sched', 'json', 'timer', 'pingpong', 'readdir', 'magic', 'dev', 'ns', 'prog', 'hangup',
              'procfs', 'buf', 'mnt', 'readonly', 'session', 'runq', 'ninep_selfmount', 'p9stream', 'p9flush', 'chanstress', 'torture', 'generator', 'sync', 'readline', 'mntconc',
              'ports', 'pcm',
              'font', 'fb', 'fbproxy', 'fbwin', 'fbprog', 'fbcons',
              'nohook', 'preempt', 'idle', 'stack', 'broke', 'kill', 'exit', 'sshkbd',
              'replyright', 'rightsundo', 'procpriv', 'portlimit', 'trace',
              'wakeup', 'nesting', 'rng', 'sshcrypto', 'mlkem', 'sshmem', 'tls',
              'layout', 'strictglobals', 'bufout', 'bufmove', 'serialize', 'mntshare', 'althup', 'dio', 'ninepc',
              'efigefs', 'version', 'oom', 'selfpipe', 'reboot', 'nsfs', 'vi', 'zmodem', 'atexit',
              'history', 'top', 'xd', 'portq', 'intr', 'intrsh', 'intrread', 'sibwake', 'reclaim', 'lazy', 'strseed',
              'clock', 'log', 'dbg', 'dbgstop', 'dbgbreak', 'dbgstep',
              'dbgread', 'dbgcap', 'dbglib', 'dbghole', 'secp256k1', 'nostr']
foreach t : boot_tests
  test('boot-' + t, boottest,
    args: [luaos_img, files('boot/test_' + t + '.lua')],
    protocol: 'tap',
    timeout: 60,
    is_parallel: true,
    env: archenv,
  )
endforeach

foreach t : shared_tests
  if not t[2]
    test('boot-' + t[0], boottest,
      args: [luaos_img, files('boot/shared_' + t[0] + '.lua')],
      protocol: 'tap',
      timeout: 60,
      is_parallel: true,
      env: archenv,
    )
  endif
endforeach

hostenv = archenv
if have_hostutil
  hostenv = archenv + {'HOSTUTIL_SO': hostutil.full_path()}
endif

# does the firmware ship a network stack? this gates the net tests, and
# it dates from when ours was a binding over the firmware's own
# EFI_TCP4/EFI_UDP4. We drive the card through SNP now, which the stock
# riscv64 blob does publish, so the per-arch default below may be more
# conservative than it needs to be -- untested. see meson.options.
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
  foreach t : ['netboot', 'dns', 'dhcp', 'efiprobe', 'host', 'date', 'irc']
    test('boot-' + t, boottest,
      args: [luaos_img, files('boot/test_' + t + '.lua')] + ['--services'],
      protocol: 'tap',
      timeout: 120,
      is_parallel: true,
      env: archenv + {'NET': '1'},
    )
  endforeach

  # our ssh client against a real OpenSSH server, which the harness runs
  # on a port of its own. The second implementation is the point: our
  # two halves agreeing with each other proves neither.
  #
  # It is also what covers a full-size frame arriving from outside. A
  # KEXINIT is over one segment, and a receive buffer a frame too small
  # drops exactly that and nothing smaller -- so every other test here
  # passed while ssh took two minutes.
  if sshd_prog.found() and sshkeygen_prog.found()
    test('net-sshclient', lua_interp,
      args: [files('../tools/sshclienttest.lua'), luaos_img,
        files('boot/net_sshclient.lua')],
      protocol: 'tap',
      timeout: 120,
      env: archenv + {'NET': '1'},
    )
  endif

  foreach t : shared_tests
    if t[2]
      test('boot-' + t[0], boottest,
        args: [luaos_img, files('boot/shared_' + t[0] + '.lua')] + ['--services'],
        protocol: 'tap',
        timeout: 120,
        is_parallel: true,
        env: archenv + {'NET': '1'},
      )
    endif
  endforeach

  if have_hostutil
    # host-driven http test: the guest serves on tcp/7777, forwarded to
    # a host port, driven with real HTTP/1.1. the only end-to-end cover
    # for tcp listen/accept/recv/send -- the guest can't test this
    # itself, since qemu's usermode network doesn't hairpin.
    test('http-server', lua_interp,
      args: [files('test_http.lua'), luaos_img, files('boot/srvhttp.lua')],
      protocol: 'tap',
      timeout: 150,
      env: hostenv,
    )

    # task/sshd.lua, driven by a real ssh client: the session ends when
    # the shell does, and a command reports the status it exited on.
    # Nothing else covers the server half at all.
    if ssh_prog.found() and sshkeygen_prog.found()
      test('sshd-server', lua_interp,
        args: [files('test_sshd.lua'), luaos_img,
          files('boot/srvsshd.lua')],
        protocol: 'tap',
        timeout: 15,
        env: hostenv,
      )
    endif

    # host-driven web terminal test: drives the browser shell as its
    # own javascript would. the only cover for the full chain -- http
    # -> session port -> a spawned unprivileged dos proc -> its
    # namespace.
    test('web-terminal', lua_interp,
      args: [files('test_web.lua'), luaos_img, files('boot/srvweb.lua')],
      protocol: 'tap',
      timeout: 180,
      env: hostenv,
    )

    # host-driven mcp test: real JSON-RPC 2.0 over HTTP POST against
    # the guest. covers tcp + http + json + mcp composed together.
    test('mcp-server', lua_interp,
      args: [files('test_mcp.lua'), luaos_img, files('boot/srvmcp.lua')],
      protocol: 'tap',
      timeout: 150,
      env: hostenv,
    )
  endif
else
  warning('firmware is built without NetworkPkg: skipping the net tests. ' +
          '-Dfw_network=enabled to try them anyway.')
endif

# ---- benchmarks ----
# not run by `meson test`; run with `meson test --benchmark` or
# `ninja benchmark`. meson runs benchmarks serially rather than in
# parallel, which is what makes the numbers worth reading.
benchmark('fb', boottest,
  args: [luaos_img, files('bench_fb.lua')],
  protocol: 'tap',
  timeout: 120,
  env: archenv,
)

benchmark('ipc', boottest,
  args: [luaos_img, files('bench_ipc.lua')],
  protocol: 'tap',
  timeout: 180,
  env: archenv + {'TIMEOUT': '150'},
)

benchmark('9p', boottest,
  args: [luaos_img, files('bench_9p.lua')],
  protocol: 'tap',
  timeout: 180,
  env: archenv + {'TIMEOUT': '150'},
)

# host-driven 9p protocol test: real 9P2000 over the com2 socket
if have_hostutil
  test('9p-protocol', lua_interp,
    args: [files('test_9p.lua'), luaos_img, files('boot/srv9p.lua')],
    protocol: 'tap',
    timeout: 60,
    env: hostenv,
    depends: hostutil,
  )
endif

endif # platform == 'efi'

# ---- host-native tests ----
# src/luaheap.c is the per-lua_State allocator. It has no firmware and
# no kernel in it -- the chunk source is a pair of function pointers --
# so it is built and tested natively, on whichever host is driving the
# build, regardless of -Dplatform or any cross file. These register for
# both platforms because neither one is involved.

luaheap_test = executable('luaheap_test',
  ['luaheap_test.c', '../src/luaheap.c'],
  include_directories: include_directories('../src'),
  native: true,
)
test('luaheap', luaheap_test, protocol: 'tap', timeout: 120)

# Whether two lua_States can share one immutable object without the
# collector touching it. Native for the same reason luaheap_test is:
# the question is about lua's collector and nothing else, so no kernel
# and no firmware are involved. It reaches lua's internal headers
# (lstate.h, lgc.h) because building an arena object by hand is exactly
# what a relocator would do, and there is no public API for it.
#
# luai_makeseed is pinned the way src/coreg.h would pin it: lstate.c
# guards it with #if !defined, so every state hashes a string to the
# same bucket and one state's intern table can be spliced with another's
# strings. In the kernel this becomes one seed per boot rather than a
# constant, so hash flooding stays as hard as lua intends.
arena_test = executable('arena_test',
  ['arena_test.c'] + lua_src,
  c_args: ['-Dluai_makeseed(L)=0x9e3779b9u'],
  include_directories: include_directories('../lua'),
  dependencies: meson.get_compiler('c', native: true).find_library('m',
    required: false),
  native: true,
)
test('arena', arena_test, protocol: 'tap', timeout: 120)

# src/lock.h is the other file that can only be tested where there is
# more than one cpu, which the target never has enough of and the host
# always does. Built native, with NCPU forced past 1 so the real ticket
# lock compiles rather than the uniprocessor barrier, and against the
# host's own src/<arch>/machine.h for machine_relax.
host_arch = build_machine.cpu_family()
if host_arch in ['x86_64', 'aarch64', 'riscv64']
  thread_dep = dependency('threads', native: true)

  # NCPU only has to exceed 1 to select the ticket lock; the thread count
  # is separate, and belongs to the host rather than to that constant.
  # Bounded at both ends. Below two there is nothing to exclude. Above
  # eight buys no more interleaving and costs a great deal: the work is
  # NTHREAD x NITER, and the threads spin, so a 32-way host quadruples
  # the test and saturates every core -- which times out the qemu tests
  # meson is running beside it, not just this one.
  nproc = run_command('nproc', check: false)
  if nproc.returncode() != 0
    nproc = run_command('sysctl', '-n', 'hw.ncpu', check: false)
  endif
  ncpu = nproc.returncode() == 0 ? nproc.stdout().strip().to_int() : 4
  nthread = ncpu
  if nthread < 2
    nthread = 2
  elif nthread > 8
    nthread = 8
  endif

  lock_test = executable('lock_test',
    ['lock_test.c'],
    include_directories: include_directories('../src', '../src' / host_arch),
    c_args: ['-DNCPU=8', '-DNTHREAD=@0@'.format(nthread)],
    dependencies: thread_dep,
    native: true,
  )
  test('lock', lock_test, protocol: 'tap', timeout: 120)

  # the same test under thread sanitizer, which sees the half the test
  # above cannot.
  #
  # lock_test proves that increments are not lost. It cannot prove the
  # memory order. A ticket lock with its acquire and release downgraded
  # to relaxed still passes a counting test on x86, because the
  # hardware orders stores anyway. The same lock loses updates on
  # aarch64, where it does not. The publication case has the same blind
  # spot for the same reason.
  #
  # tsan models C11 atomics. It derives happens-before from the lock's
  # own acquire and release, stays quiet when they are correct, and
  # reports the unprotected counter when they are not. That makes it a
  # test of the ordering and not of this host.
  #
  # tsan is slow, so the iteration count and the thread count are both
  # fixed low here. A race it finds is a property of the code, not of
  # how long the test runs or how many threads it runs on: it derives
  # happens-before rather than witnessing an interleaving, and reports
  # a relaxed ticket lock at two threads as readily as at eight. The
  # threads matter to the clock instead -- each turn of a spin loop is
  # an instrumented acquire, so cost per increment grows about a
  # hundredfold from four threads to eight.
  #
  # The test is skipped, not failed, where libtsan is absent. It is a
  # toolchain component, not a source dependency.
  tsan_args = ['-DNCPU=8', '-DNTHREAD=4', '-DNITER=2000',
    '-fsanitize=thread', '-g']
  # not in an address-sanitized build: the two instrumentations are
  # mutually exclusive, and this target asks for one of them by hand.
  if cc.has_link_argument('-fsanitize=thread') and not asan_build
    lock_test_tsan = executable('lock_test_tsan',
      ['lock_test.c'],
      include_directories: include_directories('../src', '../src' / host_arch),
      c_args: tsan_args,
      link_args: ['-fsanitize=thread'],
      dependencies: thread_dep,
      native: true,
    )
    # halt_on_error so a race is a failed test rather than a warning
    # scrolling past a run that still reports ok.
    test('lock-tsan', lock_test_tsan, protocol: 'tap', timeout: 300,
      env: {'TSAN_OPTIONS': 'halt_on_error=1:exitcode=1'})
  endif
endif

# the bench needs a real lua to allocate through, which is the host's
# rather than the freestanding one this build produces.
luaheap_lua_dep = dependency('lua5.4', native: true, required: false)
if luaheap_lua_dep.found()
  luaheap_bench = executable('luaheap_bench',
    ['luaheap_bench.c', '../src/luaheap.c'],
    include_directories: include_directories('../src'),
    dependencies: luaheap_lua_dep,
    native: true,
  )
  test('luaheap-bench', luaheap_bench, protocol: 'tap', timeout: 120)
endif

# lib/tcp4.lua is the TCP codec -- sequence arithmetic, the header and
# its options -- with no state and no I/O in it, so like luaheap it can
# be tested by the host's own lua without booting anything. That is new
# for a lua module here, and it earns its place on TCP specifically: the
# cases most likely to be wrong are the ones no real peer will produce
# on request, such as a sequence number that laps the space or an option
# whose length cannot advance the parser.
#
# It does not stand in for a boot test. It says the codec is right; only
# test/boot can say anything is wired to anything.
test('tcp4-codec', lua_interp,
  args: [files('host_tcp4.lua')],
  protocol: 'tap',
  timeout: 20,
  env: host_env,
  depends: host_deps,
)

# lib/mouse.lua's record codec, and one client's queue driven against a
# port that refuses. "the reader stopped reading" is a function that
# returns false here, and a machine under load anywhere else.
# what a service list means, with proc.spawn replaced by a function that
# records what it was handed. An entry naming a capability the task never
# reads is the failure this catches, and it went unseen on a real machine
# because the service started and only then hung.
test('svc-start', lua_interp,
  args: [files('host_svc.lua')],
  protocol: 'tap',
  timeout: 20,
  env: host_env,
  depends: host_deps,
)

# lib/frame.lua's geometry, selection and utf8 offsets. The panel it is
# for runs on a board and nothing under meson can draw, but where a
# point lands and which bytes an edit moves are arithmetic -- and that
# is where an off-by-one hides.
test('frame-text', lua_interp,
  args: [files('host_frame.lua')],
  protocol: 'tap',
  timeout: 20,
)

test('mouse-queue', lua_interp,
  args: [files('host_mouse.lua')],
  protocol: 'tap',
  timeout: 20,
  env: host_env,
  depends: host_deps,
)

# the 2048 board. No screen and no clock in it, and the rand is given,
# so a whole game is played with the luck chosen.
test('slide-board', lua_interp,
  args: [files('host_slide.lua')],
  protocol: 'tap',
  timeout: 20,
)

# NMEA 0183. Sans-io like the zmodem codec, so the whole parser runs
# here and a board adds only the uart it arrives on.
test('nmea-parser', lua_interp,
  args: [files('host_nmea.lua')],
  protocol: 'tap',
  timeout: 20,
)

# lib/geometry.lua: the identities are the test. A rotation keeps a
# length, a frame round-trips, and a satellite placed from a bearing is
# seen again at that bearing -- which is what a sky plot rests on.
test('geometry', lua_interp,
  args: [files('host_geometry.lua')],
  protocol: 'tap',
  timeout: 20,
)

# lua's io read formats, ours against the host's own io. The reference
# is what lua answers, not a table of expectations written here.
test('io-formats', lua_interp,
  args: [files('host_nsio.lua')],
  protocol: 'tap',
  timeout: 20,
)

# the battery curve: the kernel reports millivolts, and everything that
# turns those into a number a person reads is lib/ps.lua.
test('battery', lua_interp,
  args: [files('host_battery.lua')],
  protocol: 'tap',
  timeout: 20,
)

# rename over all three backends that have one, plus two mounts, because
# the refusal to rename across them is the rule no filesystem can show.
test('ns-rename', lua_interp,
  args: [files('host_rename.lua')],
  protocol: 'tap',
  timeout: 60,
  env: host_env,
  depends: host_deps,
)

# the known networks. What a scan saw is a table, so choosing one is
# tested without a radio.
test('wifi-config', lua_interp,
  args: [files('host_wificfg.lua')],
  protocol: 'tap',
  timeout: 20,
)

# A USB configuration descriptor, and the audio class over it. The
# fixture is a real adapter's, read off the board.
test('usb', lua_interp,
  args: [files('host_usb.lua')],
  protocol: 'tap',
  timeout: 20,
)

# Which device the samples go to, and that listing them starts nothing.
test('audio', lua_interp,
  args: [files('host_audio.lua')],
  protocol: 'tap',
  timeout: 20,
)

# /net/wifi, parsed once for both faces of the app.
test('wifi', lua_interp,
  args: [files('host_wifi.lua')],
  protocol: 'tap',
  timeout: 20,
)

# lib/dhcp.lua's options, built by hand. A server offers what it is
# configured to offer, so the ones this machine's server does not send
# are reachable here and nowhere else.
test('dhcp-codec', lua_interp,
  args: [files('host_dhcp.lua')],
  protocol: 'tap',
  timeout: 20,
  env: host_env,
  depends: host_deps,
)

# lib/tcb.lua is one connection's state machine, and sans-io for the
# same reason: it takes segments as tables and hands them back, so two
# of them can be wired to each other here and driven through a handshake
# with no network involved. Two agreeing with each other proves only
# that they are consistent -- they share every misreading of the RFC --
# which is what the boot tests against a real peer are for. What this
# reaches instead is everything a real peer will not do on request: a
# simultaneous open, a reset acknowledging nothing, an acknowledgment of
# a segment never sent, a SYN arriving inside an open connection.
# lib/zmodem.lua is sans-io in the same way tcb.lua is: the line is a
# pair of buffers, so a sender and a receiver can be wired to each other
# here with no port, no wire and no clock. What that buys is the cases a
# real link will not perform on request -- a byte corrupted at a chosen
# offset, a peer that stops answering, a cancel -- plus the crc check
# vectors, which is what pins the framing to zmodem.h rather than to our
# own agreement with ourselves. test/boot/test_zmodem.lua runs the same
# code between two procs over real ports.
# lib/irc.lua is sans-io for the same reason as the two above: a
# protocol whose awkward cases -- an empty trailing parameter, a tag
# holding its own separator, a user typing a newline into a message --
# are all lines of data rather than connections to arrange.
test('irc-protocol', lua_interp,
  args: [files('host_irc.lua')],
  protocol: 'tap',
  timeout: 20,
)

test('bitchat-packet', lua_interp,
  args: [files('host_bitchat.lua')],
  protocol: 'tap',
  timeout: 30,
  env: host_env,
  depends: host_deps,
)

# deflate and inflate, against what gzip wrote rather than against
# themselves. Shared with the ssh tree, where it is kept.
test('zlib', lua_interp,
  args: [files('host_zlib.lua')],
  protocol: 'tap',
  timeout: 60,
)

# a packet too big for a link, split and put back together.
test('bitchat-fragment', lua_interp,
  args: [files('host_fragment.lua')],
  protocol: 'tap',
  timeout: 30,
  env: host_env,
  depends: host_deps,
)

# what a mesh passes on, and what stops at it.
test('bitchat-relay', lua_interp,
  args: [files('host_relay.lua')],
  protocol: 'tap',
  timeout: 30,
  env: host_env,
  depends: host_deps,
)

# the XX handshake both ends of a private message need.
test('noise', lua_interp,
  args: [files('host_noise.lua')],
  protocol: 'tap',
  timeout: 60,
  env: host_env,
  depends: host_deps,
)

test('zmodem-protocol', lua_interp,
  args: [files('host_zmodem.lua')],
  protocol: 'tap',
  timeout: 60,
)
# the audio decoder, both halves against each other. adpcm.so is on
# LUA_CPATH so require("adpcm.native") reaches the same C the guest
# runs rather than a lookalike.
if lua54_dep.found()
  adpcm_env = environment()
  adpcm_env.set('LUA_CPATH',
    meson.project_build_root() / '?.so', separator: ';')
  test('adpcm-decode', lua_interp,
    args: [files('host_adpcm.lua')],
    protocol: 'tap',
    timeout: 60,
    env: adpcm_env,
    depends: [adpcm_native_host],
  )

  # the mesh protocol, against the constants their firmware defines.
  # crypto.so for the same reason adpcm.so is here: the cipher under
  # test should be the one the board runs.
  test('meshtastic', lua_interp,
    args: [files('host_meshtastic.lua')],
    protocol: 'tap',
    timeout: 60,
    env: adpcm_env,
    depends: [crypto_native_host],
  )

  # the radio's registers, against a wire that only records. A modem
  # parameter that disagrees with everyone else's reads as a quiet
  # antenna, so the bytes are pinned rather than the behaviour.
  test('sx1262', lua_interp,
    args: [files('host_sx1262.lua')],
    protocol: 'tap',
    timeout: 60,
  )

  # the node table, which exists to have a ceiling: a mesh larger than
  # the table must not be able to grow it.
  test('nodedb', lua_interp,
    args: [files('host_nodedb.lua')],
    protocol: 'tap',
    timeout: 60,
  )
endif

# lib/ble/hci.lua, sans-io like zmodem above it. The codec half needs
# nothing; the rest spawns btvirt on a port of its own and exchanges
# real packets with it, which is what checks our encoding against
# somebody else's reading of the specification.
if have_hostutil
  ble_env = {'HOSTUTIL_SO': hostutil.full_path()}
  if btvirt_prog.found()
    ble_env += {'BTVIRT': btvirt_prog.full_path()}
  endif
  # btmon is the reader the trace format exists for, so where there is
  # one it is what says whether we wrote the format or merely something
  # that looks like it.
  if btmon_prog.found()
    ble_env += {'BTMON': btmon_prog.full_path()}
  endif
  test('ble-hci', lua_interp,
    args: [files('host_ble.lua')],
    protocol: 'tap',
    timeout: 60,
    env: ble_env,
    depends: hostutil,
  )
endif

# a lazy require raises at first use, so a name that cannot resolve
# waits in whatever branch first touches it. This fails the build here
# instead.
test('lazy-names', lua_interp,
  args: [files('../tools/checklazy.lua'), meson.project_source_root()],
  timeout: 30,
)

# and against lrzsz, where there is one on the host. This is the only
# test with a peer that has never seen our code -- everything else wires
# our sender to our receiver, which proves the two agree and not that
# either is right. It earned its place immediately: ESCCTL turned out to
# be a promise about what you send rather than a preference about what
# you accept, and a peer in that mode silently discards the control
# characters you leave raw.
if have_hostutil and sz_prog.found() and rz_prog.found() and socat_prog.found()
  test('zmodem-lrzsz', lua_interp,
    args: [files('host_lrzsz.lua')],
    protocol: 'tap',
    timeout: 120,
    # the peers by the path meson found, not by a name the test repeats:
    # the guard above takes either spelling, so a test naming one of them
    # itself runs on a host where that half is missing.
    env: {'HOSTUTIL_SO': hostutil.full_path(),
          'LRZSZ_SZ': sz_prog.full_path(),
          'LRZSZ_RZ': rz_prog.full_path()},
    depends: hostutil,
  )
endif

test('tcb-statemachine', lua_interp,
  args: [files('host_tcb.lua')],
  protocol: 'tap',
  timeout: 20,
  env: host_env,
  depends: host_deps,
)

# the same state machine over a link that loses, reorders, duplicates
# and delays. Every network this has ever been run against is perfect --
# slirp, the LAN across 167,000 segments, and vmd all dropped nothing --
# so its loss recovery had never once executed in a test. Congestion
# control makes that worse rather than better, being entirely loss
# recovery: slow start and fast retransmit are dead code on a perfect
# link.
#
# Deterministic, because "drop the third data segment" is debuggable
# where "5% loss" fails once a fortnight. And free: because the TCBs take
# time as an argument, two minutes of simulated network costs five
# milliseconds of wall clock.
test('tcb-lossy', lua_interp,
  args: [files('host_tcbloss.lua')],
  protocol: 'tap',
  timeout: 20,
  env: host_env,
  depends: host_deps,
)

# lib/gefs is a port of 9front's Bε-tree filesystem, and it is sans-io in
# the same way tcb.lua is: a volume is opened on a device -- any table
# answering read/write/size -- so gefs.ram drives it in memory and
# gefs.io over a real file, with no kernel underneath. That is the whole
# of it that can be tested here, and it is most of it: that the port
# loads and runs, that lib/gefs/io.lua is a working device, and that a
# commit cut anywhere leaves the disk whole -- proven both at block
# granularity and mid-block through a coroutine that yields inside a
# write and is abandoned. What this cannot say is that a served volume is
# wired to the block driver, which is test/boot/microvm_gefs.lua's job.

test('gefs-host', lua_interp,
  args: [files('host_gefs.lua')],
  protocol: 'tap',
  timeout: 120,
  env: gefs_host_env,
  depends: gefs_host_deps,
)

# lib/fat is the filesystem the esp32 flash partition and the microSD
# card both carry, and lib/fatfs.lua is what puts it behind a mount. The
# format itself has its own suite upstream; this covers the part that
# only exists here -- that the port loads under our loader, and that the
# dev backend over it reads, writes and lists what it should. What this
# cannot say is that a served volume is wired to the flash driver, which
# is the boot test's job.
# the fat WRITE path, which is where task #47 lives: a volume built the
# way the board's is, written to a little, and then read back in full --
# plus the same with the cache thrown away, which is what a reset in the
# middle of a write leaves behind. What this cannot cover is the flash
# driver under the filesystem, where an erase that completes and a
# program that does not is a sector of 0xff.
test('fat-write', lua_interp,
  args: [files('host_fatwrite.lua')],
  protocol: 'tap',
  timeout: 120,
  env: host_env,
  depends: host_deps,
)

test('fat-host', lua_interp,
  args: [files('host_fat.lua')],
  protocol: 'tap',
  timeout: 60,
  env: host_env,
  depends: host_deps,
)

# lib/p9serve.lua is the 9P server over a dev backend -- the bridge
# task/9pexport.lua serves gefs (and any other backend) to a real 9p
# client with. Pure Lua over lib/ninep's codec, so the host drives it
# with crafted 9P messages against a gefs volume; the live wire is a boot
# test's concern, this pins the message mapping.
test('p9serve-host', lua_interp,
  args: [files('host_p9serve.lua')],
  protocol: 'tap',
  timeout: 30,
  env: gefs_host_env,
  depends: gefs_host_deps,
)
