// browsertest-wasm.js MODULE WORKER OUT.PNG [MS] [SCRIPT.json]
//
// the page, in node: it runs machine/wasm/worker.js in a real worker
// thread and does everything index.html does -- paint, input, sockets --
// so the browser's own structure is what is under test. The script is
// [{at: ms, click/key/type/wheel/px/shot}].

const fs = require('fs');
const path = require('path');
const zlib = require('zlib');
const { Worker } = require('worker_threads');

const WASM = path.resolve(process.argv[2]);
const WORKER = path.resolve(process.argv[3]);
const OUT = process.argv[4];
const MS = Number(process.argv[5] || 6000);
const SCRIPT = process.argv[6] || '';

const W = 1024, H = 768;

const RING = require(path.join(path.dirname(WORKER), 'ring.js'));

const shared = new SharedArrayBuffer((16 + 256) * 4);
const sab = new Int32Array(shared);
const screen = new SharedArrayBuffer(W * H * 4);
const pixels = new Uint8Array(screen);
const netring = new SharedArrayBuffer(2 * 1024 * 1024);
const net32 = new Int32Array(netring, 0, 2);
const net8 = new Uint8Array(netring);

const WAKE = 0, KHEAD = 1, KTAIL = 2;
const PTRX = 3, PTRY = 4, PTRB = 5, PTRMOVED = 6, PTRWHEEL = 7;
const DIRTY = 8;
const KEYS = 16, KEYRING = 256;

// the config volume, kept in a file so a second run finds what the
// first one wrote -- which is what the page's localStorage is for.
const CONFIG = process.env.CONFIG || '';
const config = new SharedArrayBuffer(512 * 1024);
const disk = new Uint8Array(config);

if (CONFIG && fs.existsSync(CONFIG))
	disk.set(fs.readFileSync(CONFIG).subarray(0, disk.length));

// the page's canvas: an ImageData filled from the shared screen.
const img = { data: new Uint8ClampedArray(W * H * 4) };
const canvas = new Uint8Array(W * H * 4);
let paints = 0;

function paint({ x, y, w, h }) {
	paints++;
	for (let row = y; row < y + h; row++) {
		const off = (row * W + x) * 4;

		img.data.set(pixels.subarray(off, off + w * 4), off);
		canvas.set(img.data.subarray(off, off + w * 4), off);
	}
}

function wake() {
	Atomics.notify(sab, WAKE);
}

// ---- the network, as index.html owns it ----

const socks = new Map();

function netput(kind, id, bytes) {
	RING.write(net32, net8, kind, id, bytes);
	wake();
}

function wscmd(c) {
	if (c.op === 'send') {
		const s = socks.get(c.id);

		if (s && s.readyState === 1)
			s.send(c.data);
		return;
	}
	if (c.op === 'close') {
		const s = socks.get(c.id);

		if (s) {
			socks.delete(c.id);
			try {
				s.close();
			} catch (e) { /* already gone */ }
		}
		return;
	}

	let s;

	console.log('-- ws open ' + c.url);
	try {
		s = new WebSocket(c.url);
	} catch (e) {
		netput(RING.STATE, c.id, Uint8Array.of(2));
		return;
	}
	socks.set(c.id, s);
	s.binaryType = 'arraybuffer';
	s.onopen = () => {
		console.log('-- ws open');
		netput(RING.STATE, c.id, Uint8Array.of(1));
	};
	s.onclose = () => netput(RING.STATE, c.id, Uint8Array.of(2));
	s.onerror = () => netput(RING.STATE, c.id, Uint8Array.of(2));
	s.onmessage = (e) => netput(RING.MESSAGE, c.id,
		typeof e.data === 'string' ? new TextEncoder().encode(e.data) :
			new Uint8Array(e.data));
}

// ---- input, as index.html sends it ----

const NAMED = {
	up: [27, 91, 65], down: [27, 91, 66],
	right: [27, 91, 67], left: [27, 91, 68],
};

function keypush(seq) {
	const head = Atomics.load(sab, KHEAD);
	let tail = Atomics.load(sab, KTAIL);

	for (const c of seq) {
		const next = (tail + 1) % KEYRING;

		if (next === head)
			return;
		Atomics.store(sab, KEYS + tail, c);
		tail = next;
	}
	Atomics.store(sab, KTAIL, tail);
	wake();
}

function ptrput(x, y, b) {
	Atomics.store(sab, PTRX, x);
	Atomics.store(sab, PTRY, y);
	Atomics.store(sab, PTRB, b);
	Atomics.store(sab, PTRMOVED, 1);
	wake();
}

function snap(file) {
	const raw = Buffer.alloc(H * (1 + W * 3));

	for (let y = 0, o = 0; y < H; y++) {
		raw[o++] = 0;
		for (let x = 0; x < W; x++) {
			const i = (y * W + x) * 4;

			raw[o++] = canvas[i];
			raw[o++] = canvas[i + 1];
			raw[o++] = canvas[i + 2];
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

	ihdr.writeUInt32BE(W, 0);
	ihdr.writeUInt32BE(H, 4);
	ihdr[8] = 8;
	ihdr[9] = 2;
	fs.writeFileSync(file, Buffer.concat([
		Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
		chunk('IHDR', ihdr),
		chunk('IDAT', zlib.deflateSync(raw)),
		chunk('IEND', Buffer.alloc(0)),
	]));
}

const script = SCRIPT && fs.existsSync(SCRIPT) ?
	JSON.parse(fs.readFileSync(SCRIPT, 'utf8')) : [];
let next = 0;

const worker = new Worker(path.join(__dirname, 'browsertest-worker.js'), {
	workerData: {
		shared, screen, netring, config,
		wasm: WASM, worker: WORKER,
		dir: path.dirname(WORKER),
		membytes: 96 * 1024 * 1024,
		w: W, h: H,
	},
});

worker.on('message', (m) => {
	if (m.paint)
		paint(m.paint);
	else if (m.ws)
		wscmd(m.ws);
	else if (m.log !== undefined)
		console.log(m.log);
	else if (m.error)
		console.log('worker error:', m.error);
});
worker.on('error', (e) => console.log('worker threw:', e));

const started = Date.now();

const timer = setInterval(() => {
	const elapsed = Date.now() - started;

	while (next < script.length && script[next].at <= elapsed) {
		const a = script[next++];

		if (a.type)
			keypush(Buffer.from(a.type, 'utf8'));
		if (a.key)
			keypush(NAMED[a.key]);
		if (a.move)
			ptrput(a.move[0], a.move[1], 0);
		if (a.click)
			ptrput(a.click[0], a.click[1], 1);
		if (a.release)
			ptrput(a.release[0], a.release[1], 0);
		if (a.wheel) {
			Atomics.add(sab, PTRWHEEL, a.wheel);
			wake();
		}
		if (a.shot)
			snap(a.shot);
		// one pixel of the canvas, named, so a caller can assert on
		// what is drawn rather than only on what was logged.
		if (a.px) {
			const i = (a.px[1] * W + a.px[0]) * 4;
			const hex = [canvas[i], canvas[i + 1], canvas[i + 2]]
				.map((v) => v.toString(16).padStart(2, '0'))
				.join('');

			console.log(`px ${a.say || a.px.join(',')} ${hex}`);
			continue;
		}
		if (a.say)
			console.log('--', a.say);
	}

	if (elapsed > MS) {
		clearInterval(timer);
		console.log(`paints: ${paints}`);
		console.log(`config writes: ${Atomics.load(sab, DIRTY)}`);
		snap(OUT);
		if (CONFIG)
			fs.writeFileSync(CONFIG, Buffer.from(disk));
		// the worker's console goes to ours through a pipe, and an
		// abrupt exit loses whatever is still in it -- which is the
		// whole boot log.
		worker.terminate().then(() => setTimeout(() => process.exit(0),
			200));
	}
}, 10);
