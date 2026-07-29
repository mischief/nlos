#!/usr/bin/env python3
"""web terminal test, host-driven: boots lua-os with a payload that
serves the browser shell on guest tcp/7777, forwards that to a host
port, and drives it as the page's javascript would. emits TAP.

what this actually covers is the whole capability chain -- http handler
-> session port -> spawned unprivileged dos proc -> its namespace ->
back out as text -- which no in-guest test can reach, since qemu's
usermode network does not hairpin.
"""

import http.client
import json
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

    print("1..22", flush=True)
    try:
        deadline = time.time() + 60
        up = False
        while time.time() < deadline:
            try:
                with open(serial_log, "rb") as f:
                    if b"web terminal ready" in f.read():
                        up = True
                        break
            except FileNotFoundError:
                pass
            if qemu.poll() is not None:
                break
            time.sleep(0.5)
        if not ok(up, "guest web terminal came up"):
            raise SystemExit(1)

        def req(method, path, body=None):
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
            c.request(method, path, body=body)
            r = c.getresponse()
            data = r.read()
            c.close()
            return r, data

        def post(path, body=None):
            r, data = req("POST", path, body)
            try:
                return r, json.loads(data)
            except ValueError:
                return r, {"_raw": data}

        r, page = req("GET", "/")
        ok(r.status == 200 and b"<pre id=\"scr\">" in page,
           f"GET / serves the page ({r.status}, {len(page)} bytes)")

        # a session is a real proc: the banner and the first prompt come
        # back with it, because the shell asks for a line before there
        # is anything to answer with.
        r, j = post("/session")
        if not ok(r.status == 200 and "id" in j,
                  f"POST /session creates one ({r.status})"):
            diag(j)
            raise SystemExit(1)
        sid = j["id"]
        ok(j.get("out", "").endswith("> "),
           f"banner arrives ending at a prompt: {j.get('out','')!r}")

        def line(text):
            r, j = post("/session/" + sid, text)
            return r, j.get("out", "")

        # a builtin: no proc spawned, pure launcher state.
        r, out = line("pwd")
        ok(r.status == 200 and out.startswith("/\n"),
           f"pwd -> {out!r}")

        # a real program: dos spawns it, prog.lua gives it the ABI, and
        # its stdout is the same session port the shell writes to.
        r, out = line("seq 1 5")
        ok("1\n2\n3\n4\n5\n" in out, f"seq 1 5 -> {out!r}")

        # the namespace: this content exists only as a lua table in the
        # server's payload, and reached the visitor as nsdesc.
        r, out = line("cat /notes/hello")
        ok("one lua table" in out, f"cat through the namespace -> {out!r}")

        r, out = line("ls /bin")
        ok("seq.lua" in out and "cat.lua" in out, f"ls /bin -> {out!r}")

        # discoverability: programs are files, so `ls /bin` always found
        # them -- but the builtins live in a lua table in the launcher
        # and had no listing anywhere, so `exit` could only be guessed.
        # help ENUMERATES both, so adding a builtin cannot leave it out.
        r, out = line("help")
        ok("exit" in out and "cd" in out and "seq" in out,
           f"help lists builtins and programs -> {out!r}")

        # and the moment a lost user actually needs it
        r, out = line("nosuchthing")
        ok("help" in out, f"an unknown command points at help -> {out!r}")

        # THE sandbox assertion. a visitor's program must not be able to
        # reach the disk behind its namespace. proc_new nils io.open /
        # loadfile / dofile for every proc but PRIV_BOOT, and prog.lua
        # adds back only io.write -- so this is checking the property
        # the whole public-shell idea rests on, in the one place a
        # visitor can actually run code.
        r, out = line("probe")
        ok("io.open=false" in out and "loadfile=false" in out
           and "dofile=false" in out,
           f"a visitor's program has no ambient file access -> {out!r}")

        # a session is ONE proc: programs run as coroutines beside the
        # shell (dos coro=true), so two runs report the same pid. under
        # the spawn path each would be a proc of its own and they would
        # differ. this is what takes MAXPROCS off the visitor ceiling.
        import re
        first = re.search(r"pid=(\d+)", out)
        r, out2 = line("probe")
        second = re.search(r"pid=(\d+)", out2)
        ok(first and second and first.group(1) == second.group(1),
           f"programs share the session's proc "
           f"({first and first.group(1)} == {second and second.group(1)})")

        # and a pipeline still works when both stages are coroutines in
        # that one proc, joined by a Channel rather than a port
        r, out = line("seq 3 | cat")
        ok("1\n2\n3\n" in out, f"seq 3 | cat as coroutines -> {out!r}")

        # writes land in the visitor's private copy of the tree
        r, out = line("seq 1 3 > /tmp/x")
        r, out = line("cat /tmp/x")
        ok("1\n2\n3\n" in out, f"write then read back -> {out!r}")

        # a nonexistent session must not be a 500 or a hang
        r, j = post("/session/nope-1")
        ok(r.status == 404, f"unknown session -> {r.status}")

        # `exit` ends the shell while the request handler is parked in
        # pump() on that session's port. the janitor hears the exit
        # notice and must NOT close the port underneath it: thread.run
        # passes every parked port to altblock in one call, so a right
        # vanishing there raises from the scheduler and kills the whole
        # server proc. this took the server down the first time it was
        # tried by hand.
        r, j = post("/session/" + sid, "exit")
        ok(r.status == 200 and j.get("ended") is True,
           f"exit reports the session ended ({r.status}, {j})")

        # the session is gone...
        r, j = post("/session/" + sid, "pwd")
        ok(r.status == 404, f"the ended session is really gone -> {r.status}")

        # ...and, the point of the test, the SERVER is still alive and
        # still able to hand out new ones.
        r, j = post("/session")
        alive = r.status == 200 and "id" in j
        if alive:
            r2, out2 = post("/session/" + j["id"], "pwd")
            alive = r2.status == 200 and out2.get("out", "").startswith("/\n")
        if not ok(alive,
                  "server survives a session exiting and serves a new one"):
            raise SystemExit(1)
        sid = j["id"]

        # pump's deadline. `drip` paces its output (see srvweb.lua): slow
        # enough never to fill MAXQUEUE, steady enough to keep the drain
        # loop fed indefinitely. the drain path used to consult the timer
        # case ONLY when the queue came up empty, so this request never
        # returned -- alt picks the first ready case in array order, so
        # no ordering of the cases could have fixed it either.
        t0 = time.time()
        r, j = post("/session/" + sid, "drip")
        elapsed = time.time() - t0
        ok(r.status == 200 and j.get("running") is True and elapsed < 20,
           f"paced output returns at the deadline "
           f"({elapsed:.1f}s, running={j.get('running')})")
        ok("drip 1\n" in j.get("out", ""),
           f"...with the output so far: {j.get('out','')[:40]!r}")

        # and the rest is still collectable: nothing was lost, the
        # program just outlived one request.
        r, j = post("/session/" + sid, "")
        ok(r.status == 200 and "drip" in j.get("out", ""),
           "a follow-up request collects more of the same program's output")

        # backpressure. a program writing flat out used to die at ~1600
        # line-writes with "port queue full" -- MAXQUEUE is 64KB of
        # SERIALIZED bytes, and {op="write", data="N\n"} costs ~40 of
        # them to carry ~5. now a full pipe parks the writer until the
        # reader drains, so this completes however long it takes.
        r, j = post("/session")
        bp = r.status == 200 and "id" in j
        if bp:
            bsid = j["id"]
            seen, guard = "", 0
            r, k = post("/session/" + bsid, "seq 1 20000")
            seen += k.get("out", "")
            # collect until the shell parks at a prompt again
            while k.get("running") and guard < 40:
                guard += 1
                r, k = post("/session/" + bsid, "")
                seen += k.get("out", "")
            bp = "port queue full" not in seen and "20000\n" in seen
        ok(bp, "a flat-out writer gets backpressure, not a full-queue error")

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
