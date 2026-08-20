// the browser embedder, in a worker: boot() never returns, so whichever
// thread calls it answers no events again.
//
// The screen is not painted here for the same reason. An OffscreenCanvas
// reaches the page only when the worker's task ends; these pixels go
// into a shared buffer, and the page puts them on the glass.

// the input layout, in Int32 slots. Must match index.html.
const WAKE = 0;		// futex word: always 0, notified to wake us
const KHEAD = 1;	// key ring read index, ours
const KTAIL = 2;	// key ring write index, the page's
const PTRX = 3;
const PTRY = 4;
const PTRB = 5;
const PTRMOVED = 6;
const KEYS = 8;
const KEYRING = 256;

let sab = null;		// Int32Array over the input buffer
let rgba = null;	// Uint8Array over the shared screen, as the page reads it
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

// BGRx in our memory, RGBA in the shared screen: the two differ by
// swapping red and blue and by an alpha the guest does not carry.
function flush(x, y, w, h) {
	if (!rgba || w <= 0 || h <= 0)
		return;
	const src = new Uint32Array(mem.buffer, fbptr, fbw * fbh);
	const dst = new Uint32Array(rgba.buffer);

	for (let row = y; row < y + h; row++) {
		let i = row * fbw + x;

		for (let col = 0; col < w; col++, i++) {
			const s = src[i];

			dst[i] = 0xff000000 | ((s & 0xff) << 16) |
				(s & 0xff00) | ((s >> 16) & 0xff);
		}
	}
	postMessage({ paint: { x, y, w, h } });
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
				return rgba ? 1 : 0;
			},
			fb_flush: flush,
			kbd,
			ptr,
		},
	};
}

onmessage = async (e) => {
	const { shared, screen, url, membytes, w, h } = e.data;

	try {
		sab = new Int32Array(shared);
		if (screen)
			rgba = new Uint8Array(screen);

		const src = await WebAssembly.instantiateStreaming(
			fetch(url), imports());

		mem = src.instance.exports.memory;
		postMessage({ ready: true });
		src.instance.exports.boot(BigInt(membytes), w, h);
	} catch (err) {
		// boot() never returns, so anything caught here happened
		// before the machine started -- and nothing else would ever
		// say so.
		postMessage({ error: String(err && err.stack || err) });
	}
};
