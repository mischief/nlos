// browsertest-wasm.js MODULE WORKER OUT.PNG [MS] [TYPE]
//
// runs machine/wasm/worker.js under node with the browser bits shimmed
// and paints its messages the way index.html does, so the page's whole
// path can be checked without a browser. The png is what a browser
// would be showing.
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

// what the page's keydown does, on a timer: the worker is blocked in
// Atomics.wait, so this runs from inside the patched wait below.
let typed = 0;

function typeit() {
	if (typed >= TYPE.length)
		return;
	const tail = Atomics.load(sab, 2);

	Atomics.store(sab, 8 + tail, TYPE.charCodeAt(typed++));
	Atomics.store(sab, 2, (tail + 1) % 256);
}

const started = Date.now();
const realWait = Atomics.wait.bind(Atomics);

Atomics.wait = (arr, i, v, ms) => {
	if (Date.now() - started > MS) {
		finish();
		process.exit(0);
	}
	if (Date.now() - started > MS / 2)
		typeit();
	return realWait(arr, i, v, Math.min(ms, 20));
};

function finish() {
	console.log(`paints: ${paints}`);
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
	fs.writeFileSync(OUT, Buffer.concat([
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
