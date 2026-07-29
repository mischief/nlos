#!/usr/bin/env python3
"""mcp server test, host-driven: boots lua-os with an mcp payload on
guest tcp/7777, forwards it to a host port, and speaks real JSON-RPC
2.0 over HTTP POST. emits TAP.

covers the whole stack at once -- tcp, http, json, mcp -- which is
the point: each layer is tested on its own elsewhere, this checks
they compose.
"""

import http.client
import json as jsonlib
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

    print("1..8", flush=True)
    try:
        # the guest prints this once listen() finally succeeds, which
        # is only after dhcp has handed it a lease.
        deadline = time.time() + 60
        up = False
        while time.time() < deadline:
            try:
                with open(serial_log, "rb") as f:
                    if b"mcp test server ready" in f.read():
                        up = True
                        break
            except FileNotFoundError:
                pass
            if qemu.poll() is not None:
                break
            time.sleep(0.5)
        if not ok(up, "guest mcp server came up"):
            raise SystemExit(1)

        def rpc(method, params=None, rid=1):
            body = {"jsonrpc": "2.0", "id": rid, "method": method}
            if params is not None:
                body["params"] = params
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=20)
            c.request("POST", "/", jsonlib.dumps(body),
                      {"Content-Type": "application/json"})
            r = c.getresponse()
            raw = r.read()
            c.close()
            return r.status, (jsonlib.loads(raw) if raw else None)

        st, r = rpc("initialize")
        ok(st == 200 and r["result"]["protocolVersion"],
           f"initialize -> {r and r.get('result', {}).get('protocolVersion')}")
        ok(r["result"]["serverInfo"]["name"] == "lua-os",
           "serverInfo identifies the server")

        st, r = rpc("tools/list")
        names = sorted(t["name"] for t in r["result"]["tools"])
        ok(names == ["boom", "echo"], f"tools/list -> {names}")

        st, r = rpc("tools/call",
                    {"name": "echo", "arguments": {"text": "hi"}})
        ok(r["result"]["content"][0]["text"] == "echo: hi",
           "tools/call returns the tool result")

        # a raising tool is an MCP-level isError result, not a dead
        # connection and not a transport error.
        st, r = rpc("tools/call", {"name": "boom", "arguments": {}})
        ok(st == 200 and r["result"]["isError"] is True,
           "a raising tool becomes isError, not a crash")

        st, r = rpc("tools/call", {"name": "nope", "arguments": {}})
        ok(r.get("error", {}).get("code") == -32602,
           "unknown tool is a json-rpc error")

        st, r = rpc("no/such/method")
        ok(r.get("error", {}).get("code") == -32601,
           "unknown method is a json-rpc error, server still alive")

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
