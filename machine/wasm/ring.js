// a one-way byte ring in shared memory: the page writes, the worker
// reads. It exists because the worker sits inside boot() and never
// returns to its event loop, so nothing reaches it by message and
// Atomics.wait runs no callbacks. One writer, one reader, no lock; a
// record is kind, id, length, payload, and one that does not fit is
// dropped whole rather than torn.

// eslint-disable-next-line no-unused-vars
const RING = {
	WPOS: 0,
	RPOS: 1,
	HDR: 8,		// bytes of Int32 header before the data area

	// kinds
	STATE: 1,
	MESSAGE: 2,

	write(i32, u8, kind, id, bytes) {
		const cap = u8.length - this.HDR;
		const w = Atomics.load(i32, this.WPOS);
		const r = Atomics.load(i32, this.RPOS);
		const need = 12 + bytes.length;

		if (need > cap - (w - r))
			return false;

		const put = (v) => {
			u8[this.HDR + (pos++ % cap)] = v & 0xff;
			u8[this.HDR + (pos++ % cap)] = (v >> 8) & 0xff;
			u8[this.HDR + (pos++ % cap)] = (v >> 16) & 0xff;
			u8[this.HDR + (pos++ % cap)] = (v >> 24) & 0xff;
		};
		let pos = w;

		put(kind);
		put(id);
		put(bytes.length);
		for (let i = 0; i < bytes.length; i++)
			u8[this.HDR + (pos++ % cap)] = bytes[i];

		// last, and atomic: the payload must be in memory before the
		// reader is told the record is there.
		Atomics.store(i32, this.WPOS, w + need);
		return true;
	},

	read(i32, u8) {
		const cap = u8.length - this.HDR;
		const w = Atomics.load(i32, this.WPOS);
		let r = Atomics.load(i32, this.RPOS);

		if (w - r < 12)
			return null;

		const get = () => {
			const v = u8[this.HDR + (r % cap)] |
				(u8[this.HDR + ((r + 1) % cap)] << 8) |
				(u8[this.HDR + ((r + 2) % cap)] << 16) |
				(u8[this.HDR + ((r + 3) % cap)] << 24);

			r += 4;
			return v;
		};
		const kind = get();
		const id = get();
		const len = get();
		const bytes = new Uint8Array(len);

		for (let i = 0; i < len; i++)
			bytes[i] = u8[this.HDR + ((r + i) % cap)];
		r += len;
		Atomics.store(i32, this.RPOS, r);
		return { kind, id, bytes };
	},
};

if (typeof module !== 'undefined')
	module.exports = RING;
