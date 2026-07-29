#!/usr/bin/env python3
"""http server test, host-driven: boots lua-os with a payload that
serves http on guest tcp/7777, forwards that to a host port, and
drives it with real HTTP/1.1 requests. emits TAP.

this is the only test that exercises the tcp path end to end --
listen, accept, recv, send, close -- against a client that isn't
itself. the guest cannot test this alone: qemu's usermode network
does not hairpin, so a guest dialing its own address just times out.
"""

import http.client
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qemuarch

img = sys.argv[1]
payload = sys.argv[2]

count = 0
failed = 0


def ok(cond, name):
    global count, failed
    count += 1
    if not cond:
        failed += 1
    print(("ok" if cond else "not ok") + f" {count} - {name}", flush=True)
    return cond


def diag(s):
    for line in str(s).splitlines():
        print("# " + line, flush=True)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def main():
    tmp = tempfile.mkdtemp()
    vars_path = os.path.join(tmp, "vars.fd")
    serial_log = os.path.join(tmp, "serial.log")
    shutil.copy(qemuarch.FW_VARS, vars_path)
    port = free_port()

    qemu = subprocess.Popen([
        *qemuarch.qemu(), *qemuarch.machine(),
        "-display", "none", "-monitor", "none",
        "-netdev", f"user,id=n0,hostfwd=tcp:127.0.0.1:{port}-:7777",
        "-device", "virtio-net-pci,netdev=n0",
        "-no-reboot", "-snapshot",
        "-serial", f"file:{serial_log}",
        *qemuarch.wire(),
        "-fw_cfg", f"name=opt/org.luaos.test,file={payload}",
        "-drive", f"if=pflash,format=raw,readonly=on,file={qemuarch.FW_CODE}",
        "-drive", f"if=pflash,format=raw,file={vars_path}",
        *qemuarch.disk(img),
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    print("1..5", flush=True)
    try:
        # the guest prints this once listen() finally succeeds, which
        # is only after dhcp has handed it a lease.
        deadline = time.time() + 60
        up = False
        while time.time() < deadline:
            try:
                with open(serial_log, "rb") as f:
                    if b"http test server ready" in f.read():
                        up = True
                        break
            except FileNotFoundError:
                pass
            if qemu.poll() is not None:
                break
            time.sleep(0.5)
        if not ok(up, "guest http server came up"):
            raise SystemExit(1)

        def get(path):
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
            c.request("GET", path)
            r = c.getresponse()
            body = r.read()
            c.close()
            return r, body

        r, body = get("/hello")
        ok(r.status == 200, f"GET /hello -> {r.status}")
        ok(body == b"you asked for /hello", f"echoed path: {body!r}")
        ok(r.getheader("Content-Length") == str(len(body)),
           "Content-Length matches body")

        # a handler that raises must become a 500, with the server
        # still alive for the next request afterwards.
        r, _ = get("/boom")
        boom_ok = r.status == 500
        r2, body2 = get("/after")
        ok(boom_ok and r2.status == 200 and body2 == b"you asked for /after",
           "handler error is a 500 and the server survives it")

    finally:
        qemu.kill()
        qemu.wait()
        try:
            with open(serial_log, "rb") as f:
                log = f.read().decode("utf-8", "replace")
            if failed:
                diag("guest serial log:")
                diag(log)
        except FileNotFoundError:
            pass
        shutil.rmtree(tmp, ignore_errors=True)

    sys.exit(1 if failed else 0)


main()
