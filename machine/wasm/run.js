// the embedder, in node. Flags after the module: -m BYTES, --fb WxH to
// open a screen (which starts the panel), --shot FILE MS to write that
// screen as a png and halt.
//
// boot() never returns, so the event loop never runs again: everything
// below is synchronous, input included.

const fs = require('fs');
const zlib = require('zlib');

let path = 'build-wasm/src/platform/wasm/luaos.wasm';
let membytes = 64 * 1024 * 1024;
let fbw = 0, fbh = 0;
let shotfile = null, shotms = 0;

for (let i = 2; i < process.argv.length; i++) {
	const a = process.argv[i];

	if (a === '-m')
		membytes = Number(process.argv[++i]);
	else if (a === '--fb')
		[fbw, fbh] = process.argv[++i].split('x').map(Number);
	else if (a === '--shot') {
		shotfile = process.argv[++i];
		shotms = Number(process.argv[++i]);
	} else
		path = a;
}

let mem = null;
let fbptr = 0;

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
		if (e.code === 'EAGAIN' || e.code === 'EOF')
			return -1;
		throw e;
	}
	inpos = 0;
	return inlen > 0 ? inbuf[inpos++] : -1;
}

// a png of the screen, so a machine with no window can still be looked
// at. Filter 0 per row, one deflate over the lot -- this is a debugging
// aid, not an encoder.
function png(file) {
	const src = new Uint32Array(mem.buffer, fbptr, fbw * fbh);
	const raw = Buffer.alloc(fbh * (1 + fbw * 3));

	for (let y = 0, o = 0; y < fbh; y++) {
		raw[o++] = 0;
		for (let x = 0; x < fbw; x++) {
			const s = src[y * fbw + x];

			raw[o++] = (s >> 16) & 0xff;	/* red */
			raw[o++] = (s >> 8) & 0xff;	/* green */
			raw[o++] = s & 0xff;		/* blue */
		}
	}

	const chunk = (type, data) => {
		const b = Buffer.alloc(8 + data.length + 4);

		b.writeUInt32BE(data.length, 0);
		b.write(type, 4, 'latin1');
		data.copy(b, 8);
		b.writeUInt32BE(zlib.crc32(Buffer.concat(
			[Buffer.from(type, 'latin1'), data])), 8 + data.length);
		return b;
	};
	const ihdr = Buffer.alloc(13);

	ihdr.writeUInt32BE(fbw, 0);
	ihdr.writeUInt32BE(fbh, 4);
	ihdr[8] = 8;		/* bits per channel */
	ihdr[9] = 2;		/* truecolour */

	fs.writeFileSync(file, Buffer.concat([
		Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
		chunk('IHDR', ihdr),
		chunk('IDAT', zlib.deflateSync(raw)),
		chunk('IEND', Buffer.alloc(0)),
	]));
}

const sleeper = new Int32Array(new SharedArrayBuffer(4));
const started = Date.now();

const imports = {
	luaos: {
		write(p, n) {
			fs.writeSync(1, Buffer.from(bytes(p, n)));
		},
		// with a screen, the keyboard has the input: a panel and a
		// console fighting over one terminal would split every line.
		read: () => (fbw ? -1 : readbyte()),
		now_ns() {
			return process.hrtime.bigint();
		},
		now_unix: () => BigInt(Math.floor(Date.now() / 1000)),
		// a key typed during the sleep is seen when it ends, so the
		// tick length is also the worst-case echo delay.
		wait(ms) {
			if (shotfile && Date.now() - started >= shotms) {
				png(shotfile);
				process.exit(0);
			}
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
		fb_open(w, h, pixels) {
			fbptr = pixels;
			return 1;
		},
		// nothing to present to: the pixels are read where they lie,
		// by png() above.
		fb_flush: () => {},
		kbd: () => (fbw ? readbyte() : -1),
		ptr: () => 0,
		// no websockets in a terminal: node has them, but boot()
		// never yields to the event loop that would deliver one.
		// The browser embedder owns its sockets on the page for
		// exactly that reason.
		ws_open: () => -1,
		ws_state: () => 2,
		ws_send: () => 0,
		ws_recv: () => -2,
		ws_close: () => {},
		// no config volume either: nothing here outlives the run.
		blk_size: () => 0,
		blk_read: () => -1,
		blk_write: () => -1,
	},
};

const mod = new WebAssembly.Module(fs.readFileSync(path));
const inst = new WebAssembly.Instance(mod, imports);

mem = inst.exports.memory;
inst.exports.boot(BigInt(membytes), fbw, fbh);
