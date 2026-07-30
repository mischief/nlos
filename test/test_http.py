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

    print("1..13", flush=True)
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

        # a body over MAXMSG (64KB) cannot go out as one message to the
        # tcp task -- the serializer refuses it, which killed the
        # connection and returned NOTHING rather than truncating.
        r, body = get("/big")
        ok(r.status == 200 and len(body) == 200000,
           f"a 200KB body survives the 64KB message ceiling ({len(body)} B)")

        def post(path, body, headers=None):
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
            c.request("POST", path, body=body, headers=headers or {})
            r = c.getresponse()
            data = r.read()
            c.close()
            return r, data

        # a body the server WILL accept, to prove the cap is a ceiling
        # and not a blanket refusal
        r, data = post("/echolen", b"z" * 1000)
        ok(r.status == 200 and data == b"1000", f"a normal POST body -> {data!r}")

        # ...and the attack: an enormous declared length must be refused
        # on the Content-Length alone, without reading it. this loop runs
        # in the server proc, and a boot payload has no mem_limit, so an
        # unbounded read here exhausts the kernel heap for EVERY session
        # rather than just the rude one.
        r, _ = post("/echolen", b"z" * 100,
                    {"Content-Length": str(1024 * 1024 * 1024)})
        ok(r.status == 413, f"a 1GB Content-Length is refused unread -> {r.status}")

        # and the server is still alive afterwards, which is the point
        r, body = get("/alive")
        ok(r.status == 200 and body == b"you asked for /alive",
           "server survives the oversized request")

        r, body = get("/files/hello.txt")
        ok(r.status == 200 and body == b"static file contents\n",
           f"static GET /files/hello.txt -> {r.status} {body!r}")
        ok(r.getheader("Content-Type") == "text/plain",
           "static Content-Type guessed from extension")

        r, body = get("/files/big.bin")
        ok(r.status == 200 and body == b"x" * 200000,
           "static streaming body crosses more than one chunk intact")

        r, body = get("/files/../secret")
        ok(r.status == 404,
           f"static traversal contained, not leaked -> {r.status} {body!r}")

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
