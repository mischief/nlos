
lua_payload = files(
  '../../../init.lua',
  # services, at /task/<name> -- started by init rather than by
  # replacing it. same directory as the driver tasks because the only
  # difference is who spawns them and what they are granted, and both
  # of those are said elsewhere: kernel.c for the drivers,
  # etc/services.lua for the rest.
  '../../../task/webterm.lua',
  '../../../task/sshd.lua',
  # programs, at /bin/<name> -- see lib/prog.lua for the ABI they run under
  '../../../bin/cat.lua',
  '../../../bin/ps.lua',
  # the other two repl words, and the pager. Nothing here is esp32's:
  # a shell over ssh or a browser reaches /bin rather than the repl's
  # _ENV, so these are wanted wherever a shell is. bin/wifi.lua is not
  # here, being about a radio these machines do not have.
  '../../../bin/ports.lua',
  '../../../bin/stats.lua',
  '../../../bin/p.lua',
  '../../../bin/rm.lua',
  '../../../bin/mv.lua',
  '../../../bin/rev.lua',
  '../../../bin/fetch.lua',
  '../../../bin/reboot.lua',
  '../../../bin/top.lua',
  '../../../bin/xd.lua',
  # the two halves of a ZMODEM transfer over the console. Named rz and
  # sz because those are the words each end types at the other before
  # its first header, so a launcher with them in /bin completes a
  # transfer the user only started at their terminal.
  '../../../bin/rz.lua',
  '../../../bin/sz.lua',
  # a lua prompt as a program: the boot console is one, and a dos, ssh
  # or panel shell had no way to reach one.
  '../../../bin/lua.lua',
  '../../../bin/host.lua',
  '../../../bin/date.lua',
  '../../../bin/batcast.lua',
  '../../../lib/ntp.lua',
  '../../../lib/time.lua',
  # the irc protocol. On the image ahead of any client for it, so a
  # session can drive it from the repl -- which is how the client is
  # debugged before there is a client.
  '../../../lib/irc.lua',
  '../../../lib/resolv.lua',
  '../../../bin/irc.lua',
  '../../../bin/stack.lua',
  '../../../bin/trace.lua',
  # the debugger. lib/ only here and not in embed_files: nothing before
  # a mount needs it, and the microvm gets /bin off the 9p mount.
  '../../../lib/dbg.lua',
  '../../../bin/dbg.lua',
  '../../../bin/ls.lua',
  '../../../bin/seq.lua',
  '../../../bin/smiley.lua',
  '../../../bin/clock.lua',
  # the window system. Not started here -- platform_have_ptr is 0 on
  # efi, so no machine boots into it -- but present so a test can hand
  # dio ports of its own and drive the tray under qemu. Injecting a
  # touch needs nothing special: the pointer is a port, and a synthetic
  # record is an ordinary send to it.
  '../../../task/dio.lua',
  '../../../etc/dio.lua',
  '../../../lib/mouse.lua',
  '../../../bin/term.lua',
  '../../../lib/fbsh.lua',
  '../../../bin/scribble.lua',
  # vi, and its ed/ engine and terminal (lib/ed/*). a full-screen program
  # over the tty capability -- see lib/prog.lua and lib/caps.lua.
  '../../../bin/vi.lua',
  '../../../lib/ed/buffer.lua',
  '../../../lib/ed/terminfo.lua',
  '../../../lib/client/rpc.lua',
  '../../../lib/client/tcp.lua',
  '../../../lib/client/udp.lua',
  '../../../lib/draw.lua',
  '../../../lib/client/dns.lua',
  '../../../lib/client/tty.lua',
  '../../../lib/client/power.lua',
  '../../../lib/client/wire.lua',
  '../../../lib/client/rpc.lua',
  '../../../task/cons.lua',
  '../../../lib/console.lua',
  '../../../lib/fbcons.lua',
  '../../../lib/lazy.lua',
  '../../../lib/devtree.lua',
  # the block device and the gefs filesystem over it. blksrv is spawned
  # by the kernel when platform_have_blk() finds a disk (now true on efi
  # too, via src/platform/efi/blk.c); the rest is the same stack microvm
  # carries. salvage stays out -- a host recovery tool, off the boot path.
  '../../../lib/blkfs.lua',
  '../../../task/blksrv.lua',
  '../../../lib/gpt.lua',
  '../../../lib/gefs.lua',
  '../../../lib/gefs/dat.lua',
  '../../../lib/gefs/hash.lua',
  '../../../lib/gefs/pack.lua',
  '../../../lib/gefs/obj.lua',
  '../../../lib/gefs/blk.lua',
  '../../../lib/gefs/store.lua',
  '../../../lib/gefs/tree.lua',
  '../../../lib/gefs/snap.lua',
  '../../../lib/gefs/fsops.lua',
  '../../../lib/gefs/check.lua',
  '../../../lib/gefs/vol.lua',
  '../../../lib/gefs/ram.lua',
  '../../../lib/gefs/io.lua',
  '../../../lib/gefs/slice.lua',
  '../../../lib/gefsfs.lua',
  '../../../lib/partfs.lua',
  '../../../task/partsrv.lua',
  '../../../task/gefssrv.lua',
  '../../../lib/p9serve.lua',
  '../../../lib/nsfs.lua',
  '../../../task/9pexport.lua',
  '../../../lib/memdraw.lua',
  '../../../lib/sync/once.lua',
  '../../../lib/sync/sema.lua',
  '../../../lib/sync/lock.lua',
  '../../../lib/crypto/util.lua',
  '../../../lib/crypto/chacha20.lua',
  '../../../lib/crypto/poly1305.lua',
  '../../../lib/crypto/hashstate.lua',
  '../../../lib/crypto/sha256.lua',
  '../../../lib/crypto/sha512.lua',
  '../../../lib/crypto/field25519.lua',
  '../../../lib/crypto/x25519.lua',
  '../../../lib/crypto/ed25519.lua',
  '../../../lib/crypto/drbg.lua',
  '../../../lib/crypto/keccak.lua',
  '../../../lib/crypto/mlkem768.lua',
  '../../../lib/crypto/sha384.lua',
  '../../../lib/crypto/hmac.lua',
  '../../../lib/crypto/hkdf.lua',
  '../../../lib/crypto/aead.lua',
  '../../../lib/crypto/bignum.lua',
  '../../../lib/crypto/p256.lua',
  '../../../lib/crypto/secp256k1.lua',
  '../../../lib/crypto/rsa.lua',
  '../../../lib/ssh/wire.lua',
  '../../../lib/ssh/msg.lua',
  '../../../lib/ssh/base64.lua',
  '../../../lib/ssh/keys.lua',
  '../../../lib/ssh/packet.lua',
  '../../../lib/ssh/kex.lua',
  '../../../lib/ssh/server.lua',
  '../../../lib/ssh/client.lua',
  # the client half as a program. Named ssh because that is what it is,
  # and it reaches a machine from a shell here rather than the reverse.
  '../../../bin/ssh.lua',
  '../../../bin/keygen.lua',
  # tls 1.3 over the stack below, and the certificate parsing that says
  # who the peer is. Sans-io, like lib/ssh: the caller owns the socket.
  '../../../lib/tls/wire.lua',
  '../../../lib/tls/hello.lua',
  '../../../lib/tls/keys.lua',
  '../../../lib/tls/record.lua',
  '../../../lib/tls/server.lua',
  '../../../lib/tls/client.lua',
  '../../../lib/tls/conn.lua',
  '../../../lib/tls/tofu.lua',
  '../../../lib/x509/der.lua',
  '../../../lib/x509/cert.lua',
  '../../../lib/dhcp.lua',
  '../../../task/dhcpd.lua',
  # the ipv4 stack. On the efi image because that platform now drives
  # the nic directly through EFI_SIMPLE_NETWORK_PROTOCOL (src/platform/
  # efi/snp.c) instead of the firmware's EFI_TCP4/EFI_UDP4 -- so these
  # are the stack on both platforms rather than microvm's alone, and
  # this list mirrors the microvm embed_files above.
  '../../../lib/ether.lua',
  '../../../lib/ethwire.lua',
  '../../../lib/ip4.lua',
  '../../../lib/arp.lua',
  '../../../lib/icmp.lua',
  '../../../lib/udp4.lua',
  '../../../lib/inet.lua',
  '../../../lib/tcp4.lua',
  '../../../lib/tcb.lua',
  '../../../task/ip.lua',
  '../../../task/tcp4.lua',
  '../../../lib/dns.lua',
  '../../../task/dns.lua',
  '../../../task/timed.lua',
  '../../../lib/espfs.lua',
  '../../../task/espsrv.lua',
  '../../../task/fb.lua',
  '../../../lib/http.lua',
  '../../../lib/tlstcp.lua',
  '../../../lib/tls/client.lua',
  '../../../lib/tls/conn.lua',
  '../../../lib/tls/hello.lua',
  '../../../lib/tls/keys.lua',
  '../../../lib/tls/record.lua',
  '../../../lib/tls/server.lua',
  '../../../lib/tls/tofu.lua',
  '../../../lib/tls/wire.lua',
  '../../../lib/x509/cert.lua',
  '../../../lib/x509/der.lua',
  '../../../lib/llm.lua',
  '../../../lib/agent.lua',
  '../../../task/idle.lua',
  '../../../lib/bech32.lua',
  '../../../lib/nostr.lua',
  '../../../lib/nostrrelay.lua',
  '../../../lib/websocket.lua',
  '../../../lib/crypto/sha1.lua',
  '../../../lib/json.lua',
  '../../../lib/mcp.lua',
  '../../../lib/mnt.lua',
  '../../../lib/ninep.lua',
  '../../../lib/ns.lua',
  '../../../lib/nsio.lua',
  '../../../lib/srv.lua',
  '../../../lib/stdout.lua',
  '../../../lib/svc.lua',
  '../../../lib/svcarg.lua',
  '../../../lib/dos.lua',
  '../../../task/power.lua',
  '../../../lib/p9fs.lua',
  '../../../lib/p9tcp.lua',
  '../../../task/p9srv.lua',
  '../../../lib/proc.lua',
  '../../../lib/procfs.lua',
  '../../../lib/prog.lua',
  '../../../lib/stream/port.lua',
  '../../../lib/stream/pipe.lua',
  '../../../lib/stream/chan.lua',
  '../../../lib/ps.lua',
  '../../../lib/battery.lua',
  '../../../task/eth.lua',
  '../../../lib/srvc.lua',
  '../../../task/srvd.lua',
  '../../../lib/srvfs.lua',
  '../../../bin/dmesg.lua',
  '../../../lib/tap.lua',
  '../../../lib/webterm.lua',
  '../../../task/wire.lua',
  '../../../lib/zmodem.lua',
)

# a prebuilt gefs volume with one file, for the disk's second partition.
# Its size is the partition's size (mkimage reads it), so it is picked
# here rather than fixed in two places.
#
# tools/mkgefs.lua reaches gefs.so through require("gefs.native"), which
# resolves against the build directory it runs in -- a runtime
# dependency ninja cannot see in the command line, so it is declared.
# Without it the two targets are unordered and the build fails whenever
# ninja reaches this one first.
gefs_img_deps = []
if lua54_dep.found()
  gefs_img_deps += gefs_native_host
endif

gefs_img = custom_target('gefs.img',
  output: 'gefs.img',
  command: [lua_interp, files('../../../tools/mkgefs.lua'), '@OUTPUT@',
            '--version', version_txt.full_path()],
  depends: gefs_img_deps + [version_txt],
)

# gpt disk: an esp, and a gefs partition after it holding gefs_img.
# Assembled with sfdisk + mtools + dd, no root. $GEFS_IMG is what makes
# mkimage add the second partition.
# which services list this machine gets. The path on the image is
# /etc/services.lua wherever it boots, so what a machine runs is a
# build decision rather than something the boot payload knows the name
# of -- see machine/ for the lists themselves.
machine_services = files('../../../machine/efi/services.lua')

luaos_img = custom_target('luaos.img',
  input: [luaos_efi] + lua_payload,
  output: 'luaos.img',
  command: [lua_interp, files('../../../tools/mkimage.lua'), '@OUTPUT@', '@INPUT@',
            '--install', machine_services, '/etc/services.lua',
            '--install', version_txt.full_path(), '/VERSION.fs'],
  depend_files: machine_services,
  env: {'BOOT_EFI': boot_efi, 'GEFS_IMG': gefs_img.full_path()},
  depends: [gefs_img, version_txt],
  build_by_default: true,
)

# every script that boots the image needs to know which machine it is
# booting, and must not guess: with a cross build the host arch is the
# wrong answer. tools/arch.lua and test/qemuarch.lua both fall back
# to uname when this is unset, which is what a bare `qemu.lua img` gets.
archenv = {
  'LUAOS_ARCH': arch,
  # where tools/gefs.lua finds gefs.so; see its note. Without it the
  # tools only work from inside a build directory.
  'LUAOS_BUILD': meson.current_build_dir(),
}

# console on stdio, 9p wire on <builddir>/9p.sock
# mount from host: 9p -a 'unix!<builddir>/9p.sock' ls /
run_target('qemu',
  command: [lua_interp, files('../../../tools/qemu.lua'), luaos_img],
  env: archenv,
)

# the same interactive run, plus a window to see the framebuffer in.
# the console stays on stdio, so you type at the dos prompt in this
# terminal and watch the screen next to it -- which is what running a
# graphical program from the shell needs. LUAOS_DISPLAY picks a backend
# if the default (gtk, then sdl) is not what you want.
run_target('qemu-gtk',
  command: [lua_interp, files('../../../tools/qemu.lua'), luaos_img, 'gtk'],
  env: archenv,
)

# the same, named for what it is now: a window plus a tablet, which is
# an absolute pointer, which is what makes the machine start dio -- so
# this is the tray and the apps, driven with a real mouse. The lua repl
# stays on stdio in this terminal.
run_target('qemu-gui',
  command: [lua_interp, files('../../../tools/qemu.lua'), luaos_img, 'gtk'],
  env: archenv,
)

# boots test/boot/fetch_mcp.lua instead of init.lua (single-url mcp
# fetch server), mcp reachable on host tcp/8090
run_target('fetch-mcp',
  command: [lua_interp, files('../../../tools/fetch-mcp.lua'), luaos_img],
  env: archenv,
)

# boots test/boot/fbdraw.lua, waits for it to say it has finished
# drawing, and captures the screen to <builddir>/screenshot.png. the
# framebuffer is the one output here no serial line can carry, so this
# is how you look at it -- test/boot/test_fb.lua proves the pixels are
# what we asked for, which is a different claim from what a person
# sitting in front of the machine would see.
run_target('screenshot',
  command: [lua_interp, files('../../../tools/screenshot.lua'), luaos_img,
    files('../../../test/boot/fbdraw.lua'), 'screenshot.ppm'],
  env: archenv,
)

# the same framebuffer, in a window on your desktop instead of a png:
# boots test/boot/fbsmiley.lua and leaves qemu up to look at. needs a
# DISPLAY or WAYLAND_DISPLAY; on a headless box use screenshot above.
run_target('smiley',
  command: [lua_interp, files('../../../tools/smiley.lua'), luaos_img,
    files('../../../test/boot/fbsmiley.lua')],
  env: archenv,
)

# boots test/boot/srvweb.lua instead of init.lua: the browser shell,
# reachable at http://localhost:8080/ (WEB_PORT to change it)
run_target('website',
  command: [lua_interp, files('../../../tools/website.lua'), luaos_img],
  env: archenv,
)

