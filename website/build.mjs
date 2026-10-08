import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Marked, Renderer } from 'marked';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.dirname(here);
const dist = path.join(here, 'dist');
const github = 'https://github.com/technologylab-ai/omagma';
const packageDeclaration = await fs.readFile(path.join(repo, 'build.zig.zon'), 'utf8');
const packageVersion = packageDeclaration.match(/\.version\s*=\s*"(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)"/)?.[1];
if (!packageVersion) throw new Error('Missing package version in build.zig.zon');
const base = process.env.OMAGMA_SITE_BASE ?? '/omagma/';
if (!/^\/(?:[a-zA-Z0-9_-]+\/)*$/.test(base)) throw new Error('OMAGMA_SITE_BASE must be an absolute path ending in /');
const siteUrl = new URL(process.env.OMAGMA_SITE_URL ?? 'https://technologylab-ai.github.io/omagma/');
if (siteUrl.protocol !== 'https:' && siteUrl.protocol !== 'http:') throw new Error('OMAGMA_SITE_URL must be HTTP(S)');
if (!siteUrl.pathname.endsWith('/')) siteUrl.pathname += '/';
if (siteUrl.search || siteUrl.hash) throw new Error('OMAGMA_SITE_URL must be a public base URL without query or fragment');
const escape = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const text = html => html.replace(/<[^>]*>/g, '').replace(/&(?:amp|lt|gt|quot|#39);/g, x => ({ '&amp;': '&', '&lt;': '<', '&gt;': '>', '&quot;': '"', '&#39;': "'" }[x]));
const slug = value => text(value).toLowerCase().replace(/[^\p{L}\p{N}_ -]/gu, '').trim().replace(/ /g, '-');
// Explicit reviewed inputs: an untracked note or screenshot placed next to
// documentation must never silently become a deployment artifact.
const sourceFiles = [
  'README.md', 'AGENTS.md', 'EVIDENCE.md', 'LICENSES/README.md', 'skills/omagma-setup/SKILL.md',
  'docs/release-notes/0.2.5.md', 'docs/release-notes/0.2.6.md',
  'docs/ROADMAP.md',
  ...['AGENT-CLI', 'AGENT-SETUP', 'BACKGROUND-REFRESH', 'DEVELOPMENT', 'DISTRIBUTION', 'FEATURES', 'INSTALL', 'MACOS', 'MEMORY', 'PRIVACY', 'PROTOCOL', 'README', 'RELEASING', 'SETUP', 'TERMINAL-BACKGROUND', 'TERMINAL-IMPLEMENTATION', 'TERMINAL-PROVIDER-DESIGN', 'TERMINAL-UI-DESIGN', 'TERMINAL-VERIFICATION', 'TERMINAL', 'TRANSPORT', 'TUI-CACHE', 'UI', 'VERIFICATION', 'ZIG017-WIKI-FOLLOWUP'].map(name => `docs/${name}.md`),
  ...['terminal-0.2.0', 'terminal-0.2.1', 'terminal-0.2.2', 'terminal-0.2.3-mouse', 'terminal-0.2.3', 'terminal-0.2.4', 'terminal-0.2.5', 'terminal-0.2.6', 'zig-0.17.0'].map(name => `docs/evidence/${name}.md`),
];
sourceFiles.sort();
const routeFor = source => {
  if (source === 'README.md') return 'docs/project/';
  if (source === 'AGENTS.md') return 'docs/agents/';
  if (source === 'EVIDENCE.md') return 'docs/evidence/zig-016-baseline/';
  if (source === 'LICENSES/README.md') return 'docs/licenses/';
  if (source === 'skills/omagma-setup/SKILL.md') return 'docs/setup-skill/';
  if (source === 'docs/README.md') return 'docs/';
  return `${source.slice(0, -3).toLowerCase()}/`;
};
const routes = new Map(sourceFiles.map(source => [source, routeFor(source)]));
if (new Set(routes.values()).size !== routes.size) throw new Error('Duplicate documentation route');
const navGroups = [
  ['Get started', [['docs/README.md', 'Overview'], ['docs/FEATURES.md', 'Features'], ['docs/AGENT-SETUP.md', 'Agent-guided setup'], ['docs/INSTALL.md', 'Linux install'], ['docs/MACOS.md', 'Mac install'], ['docs/SETUP.md', 'Google & accounts']]],
  ['Use Omagma', [['docs/UI.md', 'Bar'], ['docs/TERMINAL.md', 'Terminal'], ['docs/AGENT-CLI.md', 'Agent CLI'], ['docs/TUI-CACHE.md', 'Mail cache'], ['docs/BACKGROUND-REFRESH.md', 'Bar refresh'], ['docs/TERMINAL-BACKGROUND.md', 'Background cache']]],
  ['About', [['docs/PRIVACY.md', 'Privacy'], ['docs/MEMORY.md', 'Memory'], ['docs/DISTRIBUTION.md', 'Distribution'], ['LICENSES/README.md', 'Licenses']]],
  ['Developers', [['docs/DEVELOPMENT.md', 'Development'], ['docs/ROADMAP.md', 'Next priorities'], ['docs/TRANSPORT.md', 'Transport'], ['docs/PROTOCOL.md', 'Bar protocol'], ['docs/TERMINAL-IMPLEMENTATION.md', 'Terminal architecture'], ['docs/TERMINAL-UI-DESIGN.md', 'Terminal UI'], ['docs/TERMINAL-PROVIDER-DESIGN.md', 'Provider design'], ['docs/VERIFICATION.md', 'Bar verification'], ['docs/TERMINAL-VERIFICATION.md', 'Terminal verification'], ['docs/RELEASING.md', 'Releases'], ['docs/ZIG017-WIKI-FOLLOWUP.md', 'Zig findings']]],
];
const nav = active => navGroups.map(([label, entries]) => `<section class="nav-group"><h2>${label}</h2><ul>${entries.map(([source, name]) => `<li><a href="${base}${routes.get(source)}"${source === active ? ' aria-current="page" class="active"' : ''}>${name}</a></li>`).join('')}</ul></section>`).join('');
const sectionFor = source => navGroups.find(([, entries]) => entries.some(([s]) => s === source))?.[0] ?? (source.includes('evidence') || source === 'EVIDENCE.md' ? 'Historical evidence' : 'Reference');
const publicImages = new Set(['assets/omagma-logo.png', 'docs/images/omagma.png', 'docs/images/omagma-social.png', 'docs/images/omagma-social-preview.png']);
for (const name of ['omagma-tui.png', 'omagma-tui-below.png', 'omagma-tui-arrivals.png', 'omagma-fetch.png', 'omagma-fetch.gif']) {
  const source = `docs/images/${name}`;
  try {
    if (!(await fs.lstat(path.join(repo, source))).isFile()) throw new Error(`Public image must be a regular file: ${source}`);
    publicImages.add(source);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
}
const imageRoutes = new Map([...publicImages].map(source => [source, `assets/${path.basename(source)}`]));
const resolveLink = (href, source, image = false) => {
  if (href.startsWith('#')) return href;
  if (/^https?:\/\//i.test(href)) {
    if (image) throw new Error(`Remote image is not allowed: ${source}`);
    return href;
  }
  if (/^mailto:/i.test(href) && !image) return href;
  if (/^[a-z][a-z0-9+.-]*:/i.test(href) || href.startsWith('//')) throw new Error(`Unsupported link protocol in ${source}`);
  const [target, fragment = ''] = href.split('#', 2);
  const canonical = path.posix.normalize(path.posix.join(path.posix.dirname(source), decodeURIComponent(target)));
  if (canonical.startsWith('../') || canonical.startsWith('/')) throw new Error(`Link leaves public repository: ${source}`);
  const suffix = fragment ? `#${fragment}` : '';
  if (routes.has(canonical)) return `${base}${routes.get(canonical)}${suffix}`;
  if (imageRoutes.has(canonical)) return `${base}${imageRoutes.get(canonical)}${suffix}`;
  if (image) throw new Error(`Image outside public allowlist: ${source}: ${canonical}`);
  return `${github}/${canonical === 'LICENSES' ? 'tree' : 'blob'}/main/${canonical}${suffix}`;
};
const docs = [];
for (const source of sourceFiles) {
  if (!(await fs.lstat(path.join(repo, source))).isFile()) throw new Error(`Public document must be a regular file: ${source}`);
  const markdown = await fs.readFile(path.join(repo, source), 'utf8');
  const headings = [];
  const counts = new Map();
  let codeNumber = 0;
  let promptNumber = 0;
  const defaults = new Renderer();
  const renderer = new Renderer();
  renderer.heading = function ({ tokens, depth }) {
    const body = this.parser.parseInline(tokens);
    const stem = slug(body);
    const count = counts.get(stem) ?? 0;
    counts.set(stem, count + 1);
    const id = `${stem}${count ? `-${count}` : ''}`;
    headings.push({ depth, id, title: text(body) });
    return `<h${depth} id="${escape(id)}">${body}<a class="heading-anchor" href="#${escape(id)}" aria-label="Link to ${escape(text(body))}">#</a></h${depth}>\n`;
  };
  renderer.link = function ({ href, title, tokens }) {
    const url = resolveLink(href, source);
    return `<a href="${escape(url)}"${title ? ` title="${escape(title)}"` : ''}>${this.parser.parseInline(tokens)}</a>`;
  };
  renderer.image = function ({ href, title, text: alt }) {
    return `<img src="${escape(resolveLink(href, source, true))}" alt="${escape(alt)}"${title ? ` title="${escape(title)}"` : ''} loading="lazy" decoding="async">`;
  };
  renderer.code = function ({ text: code, lang = '' }) {
    const language = /^[a-zA-Z0-9_-]+$/.test(lang.trim()) ? lang.trim() : '';
    const id = `code-${++codeNumber}`;
    return `<div class="code-block"><button class="copy-code" type="button" aria-label="Copy code" data-copy="${id}">Copy</button><pre><code id="${id}"${language ? ` class="language-${language}"` : ''}>${escape(code)}\n</code></pre></div>\n`;
  };
  renderer.table = function (token) {
    defaults.parser = this.parser;
    const table = defaults.table(token).replaceAll('<th ', '<th scope="col" ').replaceAll('<th>', '<th scope="col">');
    return `<div class="table-wrap" tabindex="0" role="region" aria-label="Scrollable table">${table}</div>\n`;
  };
  renderer.blockquote = function ({ tokens, text: quote }) {
    const body = this.parser.parse(tokens);
    if (source !== 'docs/AGENT-SETUP.md' || !quote.startsWith('Read AGENTS.md') || promptNumber >= 2) return `<blockquote>${body}</blockquote>\n`;
    const id = `agent-prompt-${++promptNumber}`;
    const label = promptNumber === 1 ? 'Copy read-only setup prompt' : 'Copy terminal setup prompt';
    return `<div class="copyable-prompt"><div class="prompt-controls"><button class="copy-code copy-prompt" type="button" data-copy="${id}" data-copy-prompt aria-label="${label}">Copy prompt</button></div><blockquote id="${id}">${body}</blockquote></div>\n`;
  };
  // Canonical Markdown is reviewed repository content; raw HTML is displayed
  // as text rather than gaining script, iframe or event-handler privileges.
  renderer.html = ({ text: html }) => escape(html);
  renderer.strong = function ({ tokens }) {
    const content = this.parser.parseInline(tokens);
    const label = text(content).toLowerCase();
    const css = /^source only:?$/.test(label) ? ' class="source-only"' : /^experimental:?$/.test(label) ? ' class="experimental"' : '';
    return `<strong${css}>${content}</strong>`;
  };
  const marked = new Marked({ renderer, gfm: true });
  const body = marked.parse(markdown.replace(/^---\n[\s\S]*?\n---\n/, ''));
  const title = headings.find(h => h.depth === 1)?.title ?? path.basename(source, '.md');
  const description = `Omagma documentation: ${title}.`;
  docs.push({ source, route: routes.get(source), title, description, headings, body });
}
const template = (content, values) => content.replace(/\{\{([a-z_]+)\}\}/g, (_, key) => {
  if (!(key in values)) throw new Error(`Unknown template slot ${key}`);
  return values[key];
});
const [landing, shell] = await Promise.all(['landing.html', 'docs.html'].map(name => fs.readFile(path.join(here, 'templates', name), 'utf8')));
await fs.rm(dist, { recursive: true, force: true });
await fs.mkdir(path.join(dist, 'assets'), { recursive: true });
await fs.writeFile(path.join(dist, '.nojekyll'), '');
for (const [source, target] of imageRoutes) {
  if (!(await fs.lstat(path.join(repo, source))).isFile()) throw new Error(`Public image must be a regular file: ${source}`);
  await fs.copyFile(path.join(repo, source), path.join(dist, target));
}
for (const name of ['site.css', 'site.js']) await fs.copyFile(path.join(here, name), path.join(dist, 'assets', name));
const common = { base, version: escape(packageVersion), section: 'Omagma', title: 'Omagma — mail without the weight', description: 'Separate Gmail accounts in the Linux Omarchy bar, experimental Linux/Mac terminal client and agent CLI.', body: '', sidebar: '', toc: '', source_url: `${github}/blob/main/README.md` };
const decorate = (html, route) => {
  const canonical = new URL(route, siteUrl).href;
  const social = new URL('assets/omagma-social-preview.png', siteUrl).href;
  return html.replace('</head>', `<link rel="canonical" href="${escape(canonical)}"><meta property="og:type" content="website"><meta property="og:url" content="${escape(canonical)}"><meta property="og:image" content="${escape(social)}"><meta name="theme-color" content="#14151c"></head>`);
};
await fs.writeFile(path.join(dist, 'index.html'), decorate(template(landing, common), ''));
for (const doc of docs) {
  const toc = `<ul>${doc.headings.filter(h => h.depth >= 2 && h.depth <= 3).map(h => `<li class="toc-depth-${h.depth}"><a href="#${escape(h.id)}">${escape(h.title)}</a></li>`).join('')}</ul>`;
  const directory = path.join(dist, doc.route);
  await fs.mkdir(directory, { recursive: true });
  const output = template(shell, { ...common, title: escape(doc.title), description: escape(doc.description), body: doc.body, sidebar: nav(doc.source), toc, source_url: `${github}/blob/main/${doc.source}`, section: sectionFor(doc.source) });
  await fs.writeFile(path.join(directory, 'index.html'), decorate(output, doc.route));
}
await fs.writeFile(path.join(dist, 'search.json'), JSON.stringify(docs.map(doc => ({ title: doc.title, url: `${base}${doc.route}`, section: sectionFor(doc.source), headings: doc.headings.filter(h => h.depth >= 2 && h.depth <= 3).map(h => ({ title: h.title, url: `${base}${doc.route}#${h.id}` })) }))));
await fs.writeFile(path.join(dist, 'site-manifest.json'), JSON.stringify({ base, pages: ['', ...docs.map(d => d.route)], images: [...imageRoutes.values()] }, null, 2));
await fs.writeFile(path.join(dist, 'sitemap.xml'), `<?xml version="1.0" encoding="UTF-8"?><urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">${['', ...docs.map(d => d.route)].map(route => `<url><loc>${escape(new URL(route, siteUrl).href)}</loc></url>`).join('')}</urlset>`);
await fs.writeFile(path.join(dist, 'robots.txt'), `User-agent: *\nAllow: /\nSitemap: ${new URL('sitemap.xml', siteUrl).href}\n`);
console.log(`Built landing + ${docs.length} canonical Markdown pages into website/dist (base ${base}).`);
