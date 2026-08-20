// browsertest-wasm.js MODULE WORKER OUT.PNG [MS] [SCRIPT.json]
//
// runs machine/wasm/worker.js under node with the browser bits shimmed
// and paints its messages as index.html does, so the page can be driven
// without a browser. The script is [{at: ms, click/key/type/wheel/shot}].
const fs = require('fs');
const zlib = require('zlib');

const WASM = process.argv[2];
const WORKER = process.argv[3];
const OUT = process.argv[4];
const MS = Number(process.argv[5] || 6000);
const TYPE = process.argv[6] || '';

const W = 1024, H = 768;

const shared = new SharedArrayBuffer((8 + 256) * 4);
const sab = new Int32Array(shared);
const screen = new SharedArrayBuffer(W * H * 4);
const pixels = new Uint8Array(screen);

// the page's half, verbatim in shape: an ImageData filled from the
// shared screen, and a canvas put to.
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

globalThis.postMessage = (m) => {
	if (m.paint)
		paint(m.paint);
	else
		console.log('post:', JSON.stringify(m));
};
globalThis.close = () => { finish(); process.exit(0); };
globalThis.crypto = require('crypto').webcrypto;
globalThis.performance = require('perf_hooks').performance;
globalThis.fetch = () => Promise.resolve(null);

const realInstantiate = WebAssembly.instantiate.bind(WebAssembly);

WebAssembly.instantiateStreaming = (_, imp) =>
	realInstantiate(fs.readFileSync(WASM), imp);

// the page's own event handlers, driven from a script rather than from
// a person. The worker is blocked in Atomics.wait, so they run from
// inside the patched wait below.
const KTAIL = 2, KHEAD = 1, KEYS = 8, KEYRING = 256;
const PTRX = 3, PTRY = 4, PTRB = 5, PTRMOVED = 6, PTRWHEEL = 7;

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
}

function ptrput(x, y, b) {
	Atomics.store(sab, PTRX, x);
	Atomics.store(sab, PTRY, y);
	Atomics.store(sab, PTRB, b);
	Atomics.store(sab, PTRMOVED, 1);
}

// [{at: ms, ...}] where ... is one of type/key/click/wheel/shot.
const script = TYPE && fs.existsSync(TYPE) ?
	JSON.parse(fs.readFileSync(TYPE, 'utf8')) : [];
let next = 0;

function step(elapsed) {
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
		if (a.wheel)
			Atomics.add(sab, PTRWHEEL, a.wheel);
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
}

const started = Date.now();
const realWait = Atomics.wait.bind(Atomics);

Atomics.wait = (arr, i, v, ms) => {
	const elapsed = Date.now() - started;

	if (elapsed > MS) {
		finish();
		process.exit(0);
	}
	step(elapsed);
	return realWait(arr, i, v, Math.min(ms, 20));
};

function finish() {
	console.log(`paints: ${paints}`);
	snap(OUT);
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

eval(fs.readFileSync(WORKER, 'utf8'));

globalThis.onmessage({
	data: { shared, screen, url: 'luaos.wasm',
		membytes: 96 * 1024 * 1024, w: W, h: H },
});
