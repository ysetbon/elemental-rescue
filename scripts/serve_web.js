// Tiny static server that adds the cross-origin-isolation headers the
// multi-threaded Godot web export needs. For LOCAL testing only.
//   node scripts/serve_web.js [port]
const http = require('http');
const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..', 'web');
const port = Number(process.argv[2]) || 8765;

const types = {
  '.html': 'text/html', '.js': 'text/javascript', '.wasm': 'application/wasm',
  '.pck': 'application/octet-stream', '.png': 'image/png', '.svg': 'image/svg+xml',
  '.json': 'application/json', '.ico': 'image/x-icon', '.audio': 'application/octet-stream',
};

http.createServer((req, res) => {
  let urlPath = decodeURIComponent(req.url.split('?')[0]);
  if (urlPath === '/') urlPath = '/index.html';
  const filePath = path.join(root, urlPath);
  // COOP/COEP make the page cross-origin isolated (SharedArrayBuffer).
  res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
  res.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
  fs.readFile(filePath, (err, data) => {
    if (err) { res.statusCode = 404; res.end('Not found: ' + urlPath); return; }
    const ext = path.extname(filePath).toLowerCase();
    res.setHeader('Content-Type', types[ext] || 'application/octet-stream');
    res.end(data);
  });
}).listen(port, '127.0.0.1', () => {
  console.log(`Serving ./web at http://127.0.0.1:${port}/  (cross-origin isolated)`);
});
