// the browser embedder, which must run in a worker: boot() never
// returns, so whichever thread calls it stops answering events forever.
//
// Input therefore cannot arrive as a DOM event here. The page writes it
// into a SharedArrayBuffer and this reads that buffer synchronously;
// the same buffer is what the idle sleep waits on.

// the shared layout, in Int32 slots. Must match index.html.
const WAKE = 0;		// futex word: always 0, notified to wake us
const KHEAD = 1;	// key ring read index, ours
const KTAIL = 2;	// key ring write index, the page's
const PTRX = 3;
const PTRY = 4;
const PTRB = 5;
const PTRMOVED = 6;
const KEYS = 8;
const KEYRING = 256;

let sab = null;		// Int32Array over the shared buffer
let ctx = null;		// the OffscreenCanvas context
let img = null;		// one full-screen ImageData, reused
let mem = null;		// the module's linear memory
let fbptr = 0, fbw = 0, fbh = 0;

let line = '';

function say(s) {
	line += s;
	let i;

	while ((i = line.indexOf('\n')) >= 0) {
		console.log(line.slice(0, i).replace(/\r$/, ''));
		line = line.slice(i + 1);
	}
}

function kbd() {
	const head = Atomics.load(sab, KHEAD);

	if (head === Atomics.load(sab, KTAIL))
		return -1;
	const c = Atomics.load(sab, KEYS + head);

	Atomics.store(sab, KHEAD, (head + 1) % KEYRING);
	return c;
}

function ptr(xp, yp, bp) {
	if (!Atomics.exchange(sab, PTRMOVED, 0))
		return 0;
	const out = new Int32Array(mem.buffer);

	out[xp >> 2] = Atomics.load(sab, PTRX);
	out[yp >> 2] = Atomics.load(sab, PTRY);
	out[bp >> 2] = Atomics.load(sab, PTRB);
	return 1;
}

// BGRx in our memory, RGBA in an ImageData: the two differ by swapping
// red and blue and by an alpha the screen does not carry.
function flush(x, y, w, h) {
	if (!ctx || w <= 0 || h <= 0)
		return;
	const src = new Uint32Array(mem.buffer, fbptr, fbw * fbh);
	const dst = new Uint32Array(img.data.buffer);

	for (let row = y; row < y + h; row++) {
		let i = row * fbw + x;

		for (let col = 0; col < w; col++, i++) {
			const s = src[i];

			dst[i] = 0xff000000 | ((s & 0xff) << 16) |
				(s & 0xff00) | ((s >> 16) & 0xff);
		}
	}
	ctx.putImageData(img, 0, 0, x, y, w, h);
}

function imports() {
	return {
		luaos: {
			write(p, n) {
				say(new TextDecoder().decode(
					new Uint8Array(mem.buffer, p, n)));
			},
			// the browser console is write-only; everything typed
			// goes to the panel's keyboard instead.
			read: () => -1,
			now_ns: () => BigInt(Math.round(performance.now() * 1e6)),
			wait(ms) {
				Atomics.wait(sab, WAKE, 0, ms);
			},
			random(p, n) {
				crypto.getRandomValues(
					new Uint8Array(mem.buffer, p, n));
				return 1;
			},
			exit(code) {
				say(`\nmachine halted (${code})\n`);
				postMessage({ halted: code });
				close();
			},
			fb_open(w, h, pixels) {
				fbw = w;
				fbh = h;
				fbptr = pixels;
				img = new ImageData(w, h);
				return ctx ? 1 : 0;
			},
			fb_flush: flush,
			kbd,
			ptr,
		},
	};
}

onmessage = async (e) => {
	const { canvas, shared, url, membytes } = e.data;

	sab = new Int32Array(shared);
	if (canvas)
		ctx = canvas.getContext('2d', { alpha: false });

	const src = await WebAssembly.instantiateStreaming(fetch(url), imports());

	mem = src.instance.exports.memory;
	postMessage({ ready: true });
	src.instance.exports.boot(BigInt(membytes),
		canvas ? canvas.width : 0, canvas ? canvas.height : 0);
};
