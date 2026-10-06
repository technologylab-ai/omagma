import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const dist = path.join(path.dirname(fileURLToPath(import.meta.url)), 'dist');
const { base } = JSON.parse(await fs.readFile(path.join(dist, 'site-manifest.json'), 'utf8'));
const port = Number(process.env.PORT ?? 4173);
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.json': 'application/json', '.png': 'image/png', '.gif': 'image/gif', '.webp': 'image/webp', '.svg': 'image/svg+xml', '.xml': 'application/xml', '.txt': 'text/plain; charset=utf-8' };
const server = http.createServer(async (request, response) => {
  try {
    const url = new URL(request.url, `http://127.0.0.1:${port}`);
    if (url.pathname === '/' && base !== '/') {
      response.writeHead(302, { location: base });
      response.end();
      return;
    }
    if (!url.pathname.startsWith(base)) throw new Error('Outside site base');
    const relative = decodeURIComponent(url.pathname.slice(base.length));
    let filename = path.resolve(dist, relative);
    if (filename !== dist && !filename.startsWith(`${dist}/`)) throw new Error('Outside public output');
    if (url.pathname.endsWith('/')) filename = path.join(filename, 'index.html');
    const data = await fs.readFile(filename);
    response.writeHead(200, { 'content-type': types[path.extname(filename)] ?? 'application/octet-stream', 'cache-control': 'no-store' });
    response.end(data);
  } catch {
    response.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' });
    response.end('Page not found.');
  }
});
server.listen(port, '127.0.0.1', () => console.log(`Preview: http://127.0.0.1:${port}${base}`));
for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => server.close());
