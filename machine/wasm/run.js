// the embedder, in node: six functions and a call to boot().
//
//	node machine/wasm/run.js [module.wasm] [membytes]
//
// boot() never returns, so the event loop never runs again: everything
// below is synchronous, input included.

const fs = require('fs');

const path = process.argv[2] || 'build-wasm/src/platform/wasm/luaos.wasm';
const membytes = BigInt(process.argv[3] || 64 * 1024 * 1024);

let mem = null;

const bytes = (p, n) => new Uint8Array(mem.buffer, p, n);

// stdin again, opened non-blocking so a read with nothing waiting
// answers EAGAIN instead of stopping the machine.
const stdin = fs.openSync('/dev/stdin', fs.constants.O_RDONLY |
	fs.constants.O_NONBLOCK);
const inbuf = Buffer.alloc(256);
let inpos = 0, inlen = 0;

if (process.stdin.isTTY)
	process.stdin.setRawMode(true);

function readbyte() {
	if (inpos < inlen)
		return inbuf[inpos++];
	try {
		inlen = fs.readSync(stdin, inbuf, 0, inbuf.length, null);
	} catch (e) {
		if (e.code === 'EAGAIN')
			return -1;
		if (e.code === 'EOF')
			return -1;
		throw e;
	}
	inpos = 0;
	return inlen > 0 ? inbuf[inpos++] : -1;
}

const sleeper = new Int32Array(new SharedArrayBuffer(4));

const imports = {
	luaos: {
		write(p, n) {
			fs.writeSync(1, Buffer.from(bytes(p, n)));
		},
		read: readbyte,
		now_ns() {
			return process.hrtime.bigint();
		},
		// a key typed during the sleep is seen when it ends, so the
		// tick length is also the worst-case echo delay.
		wait(ms) {
			Atomics.wait(sleeper, 0, 0, ms);
		},
		random(p, n) {
			require('crypto').randomFillSync(bytes(p, n));
			return 1;
		},
		exit(code) {
			if (process.stdin.isTTY)
				process.stdin.setRawMode(false);
			process.exit(code);
		},
	},
};

const mod = new WebAssembly.Module(fs.readFileSync(path));
const inst = new WebAssembly.Instance(mod, imports);

mem = inst.exports.memory;
inst.exports.boot(membytes);
