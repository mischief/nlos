// the worker half of browsertest-wasm.js: a node worker thread wearing
// enough of a browser for machine/wasm/worker.js to run unchanged.
const fs = require('fs');
const path = require('path');
const { parentPort, workerData } = require('worker_threads');

const RING = require(path.join(workerData.dir, 'ring.js'));

// a worker's stdout is a stream pumped by its event loop, and this one
// is stopped inside boot() -- so everything the guest says would be
// lost. postMessage is the one thing a blocked worker can still do.
// A browser's console has no such problem.
console.log = (...a) => parentPort.postMessage({ log: a.join(' ') });

globalThis.RING = RING;
globalThis.importScripts = () => {};	// ring.js is required above
globalThis.postMessage = (m) => parentPort.postMessage(m);
globalThis.close = () => process.exit(0);
globalThis.performance = require('perf_hooks').performance;

const realInstantiate = WebAssembly.instantiate.bind(WebAssembly);

WebAssembly.instantiateStreaming = (_, imp) =>
	realInstantiate(fs.readFileSync(workerData.wasm), imp);
globalThis.fetch = () => Promise.resolve(null);

eval(fs.readFileSync(workerData.worker, 'utf8'));

globalThis.onmessage({ data: {
	shared: workerData.shared,
	screen: workerData.screen,
	netring: workerData.netring,
	url: 'luaos.wasm',
	membytes: workerData.membytes,
	w: workerData.w,
	h: workerData.h,
} });
