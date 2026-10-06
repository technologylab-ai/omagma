import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const here = path.dirname(fileURLToPath(import.meta.url));
const dist = path.join(here, 'dist');
const manifest = JSON.parse(await fs.readFile(path.join(dist, 'site-manifest.json'), 'utf8'));
const files = [];
async function walk(directory) {
  for (const item of await fs.readdir(directory, { withFileTypes: true })) {
    const filename = path.join(directory, item.name);
    assert(!item.isSymbolicLink(), `Unexpected symlink in output: ${filename}`);
    if (item.isDirectory()) await walk(filename);
    else files.push(filename);
  }
}
await walk(dist);
const htmlFiles = files.filter(file => file.endsWith('.html'));
const html = new Map(await Promise.all(htmlFiles.map(async file => [file, await fs.readFile(file, 'utf8')])));
const ids = new Map();
for (const [file, content] of html) {
  const found = [...content.matchAll(/\bid="([^"]+)"/g)].map(match => match[1]);
  assert.equal(new Set(found).size, found.length, `Duplicate HTML ID in ${file}`);
  ids.set(file, new Set(found));
  assert(content.includes('lang="en"'), `Missing document language: ${file}`);
  assert(content.includes('name="viewport"'), `Missing responsive viewport: ${file}`);
  assert(content.includes('skip-link'), `Missing skip link: ${file}`);
  assert(!/\{\{[a-z_]+\}\}/.test(content), `Unfilled template in ${file}`);
  assert(!/<(?:script|img|iframe|source|video)\b[^>]*(?:src|srcset|poster)="https?:\/\//i.test(content), `Remote runtime asset in ${file}`);
  assert(!/<link\b(?=[^>]*rel="stylesheet")(?=[^>]*href="https?:\/\/)/i.test(content), `Remote stylesheet in ${file}`);
}
let references = 0;
for (const [file, content] of html) {
  for (const match of content.matchAll(/\b(?:href|src)="([^"]+)"/g)) {
    const reference = match[1].replaceAll('&amp;', '&');
    if (/^(?:https?:|mailto:)/i.test(reference)) continue;
    assert(!/^(?:javascript:|data:|file:|\/\/)/i.test(reference), `Unsafe link in ${file}`);
    const [pathname, fragment = ''] = reference.split('#', 2);
    let target;
    if (!pathname) target = file;
    else {
      assert(pathname.startsWith(manifest.base), `Link ignores deployment base: ${reference}`);
      const relative = decodeURIComponent(pathname.slice(manifest.base.length));
      target = path.resolve(dist, relative);
      assert(target.startsWith(`${dist}/`) || target === dist, `Link escapes output: ${reference}`);
      if (pathname.endsWith('/')) target = path.join(target, 'index.html');
    }
    assert(files.includes(target), `Missing local resource ${reference} in ${path.relative(dist, file)}`);
    if (fragment && target.endsWith('.html')) assert(ids.get(target)?.has(decodeURIComponent(fragment)), `Missing anchor ${reference} in ${path.relative(dist, file)}`);
    references += 1;
  }
}
const topLevel = new Set(['index.html', '404.html', '.nojekyll', 'search.json', 'site-manifest.json', 'sitemap.xml', 'robots.txt']);
for (const file of files) {
  const relative = path.relative(dist, file).replaceAll(path.sep, '/');
  const allowed = topLevel.has(relative) || /^docs\/[a-z0-9/._-]*index\.html$/.test(relative) || /^assets\/[a-z0-9._-]+\.(?:css|js|png|gif|webp|svg)$/.test(relative);
  assert(allowed, `Unexpected published file: ${relative}`);
  if (/\.(?:html|js|css|json|xml|txt)$/.test(relative)) {
    const content = await fs.readFile(file, 'utf8');
    for (const pattern of [/(?:ya29\.[a-zA-Z0-9._-]{16,}|1\/\/[a-zA-Z0-9_-]{20,})/, /\d{8,}-[a-zA-Z0-9_-]+\.apps\.googleusercontent\.com/, /\/home\/[a-zA-Z][^\s<"']*\/(?:\.config|code|Work)\//, /codex-clipboard-[a-zA-Z0-9]+/]) {
      assert(!pattern.test(content), `Possible credential/private artifact in ${relative}`);
    }
    if (relative.endsWith('.css')) assert(!/(?:@import\s|url\(["']?https?:)/i.test(content), `Remote CSS resource in ${relative}`);
  }
}
assert.equal(htmlFiles.length, manifest.pages.length, 'Unexpected documentation page count');
console.log(`Checked ${htmlFiles.length} pages, ${references} local links/anchors and ${files.length} allowlisted public files.`);
