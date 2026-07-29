#!/usr/bin/env python3
"""9p protocol test, host-driven: boots lua-os with the srv9p payload,
speaks real 9P2000 over the com2 unix socket, emits TAP."""

import os
import shutil
import socket
import struct
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
    print("# " + str(s), flush=True)


def s9(s):
    b = s.encode()
    return struct.pack("<H", len(b)) + b


class Client:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        self.sock.settimeout(20)
        self.buf = b""

    def readmsg(self):
        while True:
            if len(self.buf) >= 4:
                size = struct.unpack("<I", self.buf[:4])[0]
                if len(self.buf) >= size:
                    m, self.buf = self.buf[:size], self.buf[size:]
                    return m
            d = self.sock.recv(4096)
            if not d:
                raise EOFError
            self.buf += d

    def rpc(self, t, tag, body):
        msg = struct.pack("<IBH", 7 + len(body), t, tag) + body
        self.sock.sendall(msg)
        m = self.readmsg()
        typ, rtag = struct.unpack("<BH", m[4:7])
        if typ == 107:
            elen = struct.unpack("<H", m[7:9])[0]
            raise RuntimeError("Rerror: " + m[9:9 + elen].decode())
        if typ != t + 1 or rtag != tag:
            raise RuntimeError(f"bad reply type={typ} tag={rtag}")
        return m[7:]


def main():
    tmp = tempfile.mkdtemp()
    sock_path = os.path.join(tmp, "9p.sock")
    vars_path = os.path.join(tmp, "vars.fd")
    serial_log = os.path.join(tmp, "serial.log")
    shutil.copy(qemuarch.FW_VARS, vars_path)

    qemu = subprocess.Popen([
        *qemuarch.qemu(), *qemuarch.machine(),
        "-display", "none", "-net", "none", "-monitor", "none",
        "-no-reboot", "-snapshot",
        "-serial", f"file:{serial_log}",
        *qemuarch.wire(sock_path),
        "-fw_cfg", f"name=opt/org.luaos.test,file={payload}",
        "-drive", f"if=pflash,format=raw,readonly=on,file={qemuarch.FW_CODE}",
        "-drive", f"if=pflash,format=raw,file={vars_path}",
        *qemuarch.disk(img),
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    print("1..8", flush=True)
    try:
        # wait for the guest server to come up
        deadline = time.time() + 30
        c = None
        while time.time() < deadline:
            try:
                with open(serial_log, "rb") as f:
                    if b"9p test server ready" in f.read():
                        c = Client(sock_path)
                        break
            except (FileNotFoundError, ConnectionRefusedError):
                pass
            time.sleep(0.5)
        if not ok(c is not None, "guest 9p server came up"):
            raise SystemExit(1)

        # version
        r = c.rpc(100, 0xFFFF, struct.pack("<I", 8192) + s9("9P2000"))
        ms, vl = struct.unpack("<IH", r[:6])
        ok(r[6:6 + vl].decode() == "9P2000", "version negotiation")

        # attach
        r = c.rpc(104, 1, struct.pack("<II", 0, 0xFFFFFFFF) +
                  s9("host") + s9(""))
        ok(r[0] == 0x80, "attach returns directory qid")

        # walk + open + read README
        c.rpc(110, 2, struct.pack("<IIH", 0, 1, 1) + s9("README"))
        c.rpc(112, 3, struct.pack("<IB", 1, 0))
        r = c.rpc(116, 4, struct.pack("<IQI", 1, 0, 4096))
        n = struct.unpack("<I", r[:4])[0]
        ok(b"mounted over 9p" in r[4:4 + n], "read README content")
        c.rpc(120, 5, struct.pack("<I", 1))

        # list root
        c.rpc(110, 6, struct.pack("<IIH", 0, 2, 0))
        c.rpc(112, 7, struct.pack("<IB", 2, 0))
        r = c.rpc(116, 8, struct.pack("<IQI", 2, 0, 4096))
        n = struct.unpack("<I", r[:4])[0]
        data, names, off = r[4:4 + n], [], 0
        while off < len(data):
            sz = struct.unpack("<H", data[off:off + 2])[0]
            ent = data[off + 2:off + 2 + sz]
            nl = struct.unpack("<H", ent[39:41])[0]
            names.append(ent[41:41 + nl].decode())
            off += 2 + sz
        ok(sorted(names) == ["README", "echo", "proc", "ticks", "uname"],
           "root directory listing")

        # nested walk: proc/list
        c.rpc(110, 9, struct.pack("<IIH", 0, 3, 2) + s9("proc") + s9("list"))
        c.rpc(112, 10, struct.pack("<IB", 3, 0))
        r = c.rpc(116, 11, struct.pack("<IQI", 3, 0, 4096))
        n = struct.unpack("<I", r[:4])[0]
        # some fixed number of driver tasks (currently cons/wire/power)
        # are always alive before any init/payload, plus the payload
        # itself -- don't hardcode the count, just that it's sane.
        pids = r[4:4 + n].decode().strip().split()
        ok(len(pids) >= 1 and all(p.isdigit() for p in pids),
           "proc/list dynamic read")

        # walk to a nonexistent file errors
        try:
            c.rpc(110, 12, struct.pack("<IIH", 0, 4, 1) + s9("nope"))
            ok(False, "walk to missing file errors")
        except RuntimeError as e:
            ok("not found" in str(e), "walk to missing file errors")

        # write to the echo file (Twrite path)
        c.rpc(110, 13, struct.pack("<IIH", 0, 5, 1) + s9("echo"))
        c.rpc(112, 14, struct.pack("<IB", 5, 1))
        r = c.rpc(118, 15, struct.pack("<IQI", 5, 0, 5) + b"hello")
        ok(struct.unpack("<I", r[:4])[0] == 5, "write accepted")

    except Exception as e:  # noqa: BLE001 - report anything as TAP
        diag(f"exception: {e}")
        try:
            with open(serial_log, "rb") as f:
                for line in f.read().decode(errors="replace").splitlines():
                    diag(line)
        except OSError:
            pass
        print(f"not ok {count + 1} - unhandled exception", flush=True)
        failed_exit(qemu, tmp)
        return 1
    finally:
        qemu.kill()
        qemu.wait()
        shutil.rmtree(tmp, ignore_errors=True)

    return 1 if failed else 0


def failed_exit(qemu, tmp):
    qemu.kill()
    qemu.wait()
    shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
