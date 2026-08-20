//	node machine/wasm/serve.js [port] [module.wasm]
//
// The two headers are what SharedArrayBuffer needs: without them the
// page cannot allocate one, and without one the worker can neither
// sleep nor be typed at. Any server will do, given these headers.

const fs = require('fs');
const http = require('http');
const path = require('path');

const port = Number(process.argv[2] || 8000);
const module_path = process.argv[3] ||
	'build-wasm/src/platform/wasm/luaos.wasm';
const here = __dirname;

const TYPES = {
	'.html': 'text/html; charset=utf-8',
	'.js': 'text/javascript; charset=utf-8',
	'.wasm': 'application/wasm',
};

// the module is named as a file rather than copied next to the page, so
// a rebuild is live on reload.
function resolve(url) {
	const name = url === '/' ? '/index.html' : url.split('?')[0];

	if (name === '/luaos.wasm')
		return module_path;
	const file = path.join(here, path.normalize(name));

	return file.startsWith(here) ? file : null;
}

http.createServer((req, res) => {
	const file = resolve(req.url);

	let body;

	try {
		body = fs.readFileSync(file);
	} catch {
		res.writeHead(404, { 'content-type': 'text/plain' });
		res.end('not here\n');
		return;
	}
	res.writeHead(200, {
		'content-type': TYPES[path.extname(file)] ||
			'application/octet-stream',
		'cross-origin-opener-policy': 'same-origin',
		'cross-origin-embedder-policy': 'require-corp',
		'cache-control': 'no-store',
	});
	res.end(body);
}).listen(port, () => {
	console.log(`lua-os on http://localhost:${port}/`);
	console.log(`serving ${module_path}`);
});
