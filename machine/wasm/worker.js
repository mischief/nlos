// the browser embedder, in a worker: boot() never returns, so whichever
// thread calls it answers no events again.
//
// The screen is not painted here for the same reason. An OffscreenCanvas
// reaches the page only when the worker's task ends; these pixels go
// into a shared buffer, and the page puts them on the glass.

importScripts('ring.js');

// the input layout, in Int32 slots. Must match index.html.
const WAKE = 0;		// futex word: always 0, notified to wake us
const KHEAD = 1;	// key ring read index, ours
const KTAIL = 2;	// key ring write index, the page's
const PTRX = 3;
const PTRY = 4;
const PTRB = 5;
const PTRMOVED = 6;
const PTRWHEEL = 7;	// wheel clicks not yet reported; sign is direction
const DIRTY = 8;	// sector writes ever made; the page watches it
const KEYS = 16;
const KEYRING = 256;

const WHEELUP = 8, WHEELDOWN = 16;
const SECTOR = 512;

let sab = null;		// Int32Array over the input buffer
let rgba = null;	// Uint8Array over the shared screen, as the page reads it
let net32 = null;	// the socket ring's header
let net8 = null;	// and its bytes
let disk = null;	// the config volume, shared with the page
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

// one record per call. A wheel click is reported before any move, and
// exactly once: it is an event, where the buttons and the position are
// a state the reader may fall behind on without losing anything.
function ptr(xp, yp, bp) {
	const wheel = Atomics.load(sab, PTRWHEEL);
	let buttons;

	if (wheel !== 0) {
		Atomics.add(sab, PTRWHEEL, wheel > 0 ? -1 : 1);
		buttons = Atomics.load(sab, PTRB) |
			(wheel > 0 ? WHEELUP : WHEELDOWN);
	} else if (Atomics.exchange(sab, PTRMOVED, 0)) {
		buttons = Atomics.load(sab, PTRB);
	} else {
		return 0;
	}

	const out = new Int32Array(mem.buffer);

	out[xp >> 2] = Atomics.load(sab, PTRX);
	out[yp >> 2] = Atomics.load(sab, PTRY);
	out[bp >> 2] = buttons;
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

// the websockets, which are the whole of what a browser lends of the
// network. The page owns them, because a socket delivers through the
// event loop and this thread is inside boot() and never returns to one.
// Commands go out by postMessage, which a blocked worker may still
// send; what comes back arrives through the ring.
const socks = new Map();
let nextsock = 1;

function drain() {
	for (;;) {
		const rec = RING.read(net32, net8);

		if (!rec)
			return;
		const s = socks.get(rec.id);

		if (!s)
			continue;
		if (rec.kind === RING.STATE)
			s.state = rec.bytes[0];
		else
			s.q.push(rec.bytes);
	}
}

function wsopen(p, n) {
	const url = new TextDecoder().decode(new Uint8Array(mem.buffer, p, n));
	const id = nextsock++;

	socks.set(id, { q: [], state: 0 });
	postMessage({ ws: { op: 'open', id, url } });
	return id;
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
			now_unix: () => BigInt(Math.floor(Date.now() / 1000)),
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

			ws_open: wsopen,
			ws_state(id) {
				drain();
				const s = socks.get(id);

				return s ? s.state : 2;
			},
			ws_send(id, p, n) {
				const s = socks.get(id);

				if (!s || s.state !== 1)
					return 0;
				postMessage({ ws: { op: 'send', id,
					data: new TextDecoder().decode(
						new Uint8Array(mem.buffer,
							p, n)) } });
				return 1;
			},
			// -1 nothing waiting, -2 gone. A message longer than
			// the guest's buffer is dropped rather than torn:
			// half an event is not an event.
			ws_recv(id, p, max) {
				drain();
				const s = socks.get(id);

				if (!s)
					return -2;
				if (!s.q.length)
					return s.state === 2 ? -2 : -1;
				const bytes = s.q.shift();

				if (bytes.length > max)
					return -1;
				new Uint8Array(mem.buffer, p, max).set(bytes);
				return bytes.length;
			},
			ws_close(id) {
				if (socks.delete(id))
					postMessage({ ws: { op: 'close', id } });
			},

			// the config volume. Shared memory, so a sector is a
			// copy and never a round trip: the page keeps it
			// somewhere a reload will find it, and only has to be
			// told that it changed.
			blk_size: () => (disk ? disk.length / SECTOR : 0),
			blk_read(lba, p, nsec) {
				if (!disk || (lba + nsec) * SECTOR > disk.length)
					return -1;
				new Uint8Array(mem.buffer, p, nsec * SECTOR)
					.set(disk.subarray(lba * SECTOR,
						(lba + nsec) * SECTOR));
				return 0;
			},
			blk_write(lba, p, nsec) {
				if (!disk || (lba + nsec) * SECTOR > disk.length)
					return -1;
				disk.set(new Uint8Array(mem.buffer, p,
					nsec * SECTOR), lba * SECTOR);
				Atomics.add(sab, DIRTY, 1);
				return 0;
			},
		},
	};
}

onmessage = async (e) => {
	const { shared, screen, netring, config, url, membytes, w, h } = e.data;

	try {
		sab = new Int32Array(shared);
		if (screen)
			rgba = new Uint8Array(screen);
		if (netring) {
			net32 = new Int32Array(netring, 0, 2);
			net8 = new Uint8Array(netring);
		}
		if (config)
			disk = new Uint8Array(config);

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
