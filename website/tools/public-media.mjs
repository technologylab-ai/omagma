#!/usr/bin/env node
// Built-in Node APIs only. See --help; all browser runs require HOST_TOKEN.
import assert from 'node:assert/strict';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { browser, delay, fileAsset, reservation, root } from './browser.mjs';

const { positionals, values: options } = parseArgs({ allowPositionals: true, options: {
  help: { type: 'boolean', short: 'h' }, template: { type: 'string' }, output: { type: 'string' },
  'out-dir': { type: 'string' }, dist: { type: 'string' }, overwrite: { type: 'boolean' },
} });
if (options.help) {
  console.log(`Usage:
  HOST_TOKEN=... node website/tools/public-media.mjs social [--template FILE] [--output PNG] [--overwrite]
  HOST_TOKEN=... node website/tools/public-media.mjs qa [--dist DIR] [--out-dir NEW_DIR]

social renders a self-contained HTML template at exactly 1200x630. {{base}}
becomes /omagma/; use {{base}}assets/omagma-calendar-week.png and
{{base}}assets/omagma-logo.png. Only those two public images are served.
Default template: website/templates/social.html
Default output: docs/images/omagma-social-calendar.png (existing files refused).

qa serves only the built site's explicit manifest and known runtime files.
It checks desktop 1440, tablet 768, mobile 390/320, guide navigation/search,
copy success/fallback with an isolated in-page clipboard, reduced motion,
the Gmail+Calendar headline/metadata and all four native screenshot references.
Screenshots and JSON go into a fresh private output directory.

Both modes verify their coordinator's live cooperative host reservation,
use a throwaway headless Chromium profile and deny external requests.
CHROMIUM may select the installed Chromium executable. No installation,
live accounts, GUI control, publication or reservation release is performed.`);
  process.exit(0);
}
const mode = positionals[0];
assert.equal(positionals.length, 1, 'Choose exactly one mode: social or qa (see --help)');
assert(['social', 'qa'].includes(mode), 'Unknown mode; use social or qa');
const captures = ['omagma-calendar-week.png', 'omagma-calendar-review.png', 'omagma-meeting-reminder.png', 'omagma-mail-invitation.png'];
const absolute = value => path.resolve(root, value);

async function writeNew(filename, data, overwrite = false) {
  await mkdir(path.dirname(filename), { recursive: true });
  await writeFile(filename, data, { flag: overwrite ? 'w' : 'wx', mode: 0o600 });
}
function cleanPng(data) {
  assert.equal(data.subarray(0, 8).toString('hex'), '89504e470d0a1a0a', 'Invalid PNG');
  const parts = [data.subarray(0, 8)];
  let offset = 8;
  while (offset + 12 <= data.length) {
    const length = data.readUInt32BE(offset), end = offset + length + 12;
    assert(end <= data.length, 'Truncated PNG chunk');
    if (!['tEXt', 'iTXt', 'zTXt', 'eXIf'].includes(data.toString('ascii', offset + 4, offset + 8))) parts.push(data.subarray(offset, end));
    offset = end;
  }
  assert.equal(offset, data.length, 'Unexpected PNG trailer');
  return Buffer.concat(parts);
}
const imageReport = `({title:document.title,width:innerWidth,scrollWidth:document.documentElement.scrollWidth,missingImages:[...document.images].filter(image=>!image.complete||!image.naturalWidth).map(image=>image.getAttribute('src')),headings:[...document.querySelectorAll('h1,h2')].map(node=>node.textContent.trim())})`;
async function waitFor(page, expression, label) {
  for (let attempt = 0; attempt < 60; attempt++) { if (await page.evaluate(expression)) return; await delay(50); }
  throw Error(label);
}
async function activate(page, selector) {
  assert(await page.evaluate(`(()=>{const node=document.querySelector(${JSON.stringify(selector)});if(!node)return false;node.scrollIntoView({block:'center'});node.focus();return document.activeElement===node;})()`), `Missing or unfocusable control: ${selector}`);
  await page.key('Enter');
}

async function social() {
  const template = absolute(options.template || 'website/templates/social.html');
  const output = absolute(options.output || 'docs/images/omagma-social-calendar.png');
  const source = await readFile(template, 'utf8');
  assert(!/\{\{(?!base\}\})/.test(source), 'Social template supports only the {{base}} placeholder');
  const assets = new Map([['/__social.html', { data: Buffer.from(source.replaceAll('{{base}}', '/omagma/')), type: 'text/html' }]]);
  for (const [name, file] of [['omagma-calendar-week.png', 'docs/images/omagma-calendar-week.png'], ['omagma-logo.png', 'assets/omagma-logo.png']]) assets.set(`/omagma/assets/${name}`, await fileAsset(absolute(file), root));
  const owned = await browser(assets);
  try {
    const page = await owned.page('/__social.html', { width: 1200, height: 630 });
    const report = await page.evaluate(imageReport);
    assert(report.scrollWidth <= 1200 && !report.missingImages.length, 'Social template overflows or has missing images');
    assert(await page.evaluate("document.documentElement.scrollHeight<=630&&[...document.images].some(image=>image.src.endsWith('/omagma-calendar-week.png'))"), 'Social template must fit 1200x630 and show the genuine Calendar capture');
    assert(await page.evaluate("[...document.querySelectorAll('h1,img,.platforms,.foot,figcaption')].every(node=>{const box=node.getBoundingClientRect();return box.left>=0&&box.top>=0&&box.right<=1200&&box.bottom<=630;})"), 'Social copy or imagery is clipped by the fixed canvas');
    assert(!owned.errors.length && owned.blocked.every(url => url === '/favicon.ico'), 'Social page has exceptions or unexpected resource requests');
    const png = cleanPng(await page.screenshot());
    assert(png.readUInt32BE(16) === 1200 && png.readUInt32BE(20) === 630, 'Unexpected social raster dimensions');
    await reservation();
    await writeNew(output, png, options.overwrite);
    console.log(`Rendered ${path.relative(root, output)}: 1200x630, genuine Calendar image, no external requests or PNG text metadata.`);
  } finally { await owned.close(); }
}

async function siteAssets(dist) {
  const manifest = JSON.parse(await readFile(path.join(dist, 'site-manifest.json'), 'utf8'));
  assert(/^\/(?:[a-zA-Z0-9_-]+\/)*$/.test(manifest.base), 'Invalid site base');
  assert(Array.isArray(manifest.pages) && Array.isArray(manifest.images), 'Missing site manifest lists');
  const assets = new Map();
  const files = new Set([...manifest.pages.map(route => `${route}index.html`), ...manifest.images, 'assets/site.css', 'assets/site.js', 'search.json']);
  for (const file of files) {
    assert(/^[a-zA-Z0-9/._-]+$/.test(file) && !file.split('/').includes('..'), 'Invalid manifest asset path');
    const entry = await fileAsset(path.join(dist, file), dist);
    assets.set(manifest.base + file, entry);
    if (file.endsWith('index.html')) assets.set(manifest.base + file.slice(0, -10), entry);
  }
  return { assets, base: manifest.base };
}

async function qa() {
  const dist = absolute(options.dist || 'website/dist');
  const out = absolute(options['out-dir'] || `.local-notes/site-qa-${new Date().toISOString().replace(/[:.]/g, '-')}`);
  const { assets, base } = await siteAssets(dist);
  await mkdir(out, { recursive: false, mode: 0o700 });
  const owned = await browser(assets);
  const report = { passed: false, viewports: [], controls: {}, clipboard: 'Isolated in-page clipboard; shared desktop clipboard untouched', externalRequestsBlocked: true };
  try {
    for (const [width, height] of [[1440, 1080], [768, 1024], [390, 844], [320, 740]]) {
      for (const [name, route] of [['home', ''], ['terminal', 'docs/terminal/'], ['calendar', 'docs/calendar-events/']]) {
        const page = await owned.page(base + route, { width, height });
        const snapshot = await page.evaluate(imageReport);
        assert(snapshot.scrollWidth <= width + 1, `${name}/${width} has horizontal page overflow`);
        assert(!snapshot.missingImages.length, `${name}/${width} has missing images: ${snapshot.missingImages.join(', ')}`);
        if (name === 'home') {
          const metadata = await page.evaluate(`({h1:document.querySelector('h1')?.textContent,title:document.title,description:document.querySelector('meta[name="description"]')?.content,ogDescription:document.querySelector('meta[property="og:description"]')?.content,images:[...document.images].map(image=>new URL(image.src).pathname.split('/').pop()),social:document.querySelector('meta[property="og:image"]')?.content})`);
          for (const key of ['h1', 'title', 'description', 'ogDescription']) assert(/gmail/i.test(metadata[key]) && /calendar/i.test(metadata[key]), `Homepage ${key} must explain Gmail and Calendar`);
          for (const capture of captures) assert(metadata.images.includes(capture), `Homepage missing native screenshot ${capture}`);
          assert(metadata.social?.endsWith('/assets/omagma-social-calendar.png'), 'Homepage must use the current Calendar social preview');
          snapshot.metadata = metadata;

        }
        if (name !== 'home' && width < 1280) assert(await page.evaluate("document.querySelector('.doc-toc')?.open===false"), 'Mobile/tablet guide ToC should begin collapsed');
        await writeNew(path.join(out, `${name}-${width}.png`), cleanPng(await page.screenshot()));
        if (name === 'home' && width < 500) {
            const selector = '.shot__body--week';
            assert(await page.evaluate(`(()=>{const node=document.querySelector(${JSON.stringify(selector)});return node?.scrollWidth>node.clientWidth+400;})()`), 'Mobile Week must stay large enough to explore horizontally');
            await page.evaluate(`document.querySelector(${JSON.stringify(selector)}).focus({preventScroll:true})`);
            await page.key('ArrowRight');
            await waitFor(page, `document.querySelector(${JSON.stringify(selector)}).scrollLeft>0`, 'Mobile Week cannot be scrolled with arrow keys');
            await page.evaluate(`document.querySelector(${JSON.stringify(selector)}).scrollLeft=0;document.activeElement.blur()`);
            report.controls.mobileWeekPan = true;
          }
        if (name === 'home' && width === 1440) {
          await writeNew(path.join(out, 'home-full.png'), cleanPng(await page.screenshot(true)));
          // Keep each product chapter readable for visual review rather than
          // relying on a very tall, automatically downscaled page screenshot.
          for (const id of ['week', 'new-meetings', 'reminders', 'invitations']) {
            const clip = await page.evaluate(`(()=>{const node=document.getElementById(${JSON.stringify(id)});if(!node)return null;const box=node.getBoundingClientRect();return{x:Math.floor(box.left+scrollX),y:Math.floor(box.top+scrollY),width:Math.ceil(box.width),height:Math.ceil(box.height),scale:1};})()`);
            assert(clip?.width > 0 && clip.height > 0, `Missing Calendar chapter ${id}`);
            const { data } = await page.call('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true, clip });
            await writeNew(path.join(out, `chapter-${id}.png`), cleanPng(Buffer.from(data, 'base64')));
          }
        }
        report.viewports.push({ page: name, ...snapshot });
        await page.close();
      }
    }
    const docs = await owned.page(base + 'docs/terminal/', { width: 390, height: 844 });
    await activate(docs, '[data-nav-toggle]');
    assert(await docs.evaluate("document.getElementById('docs-nav').classList.contains('is-open')&&document.querySelector('[data-nav-toggle]').getAttribute('aria-expanded')==='true'"), 'Guide menu did not open with keyboard activation');
    await docs.key('Escape');
    assert(await docs.evaluate("!document.getElementById('docs-nav').classList.contains('is-open')&&document.activeElement.matches('[data-nav-toggle]')"), 'Escape must close the guide menu and restore focus');
    await activate(docs, '[data-nav-toggle]');
    await docs.evaluate("document.getElementById('doc-search').focus()");
    await docs.call('Input.insertText', { text: 'calendar' });
    await waitFor(docs, "document.querySelectorAll('#search-results a').length>0", 'Guide search found no Calendar results');
    const matches = await docs.evaluate("[...document.querySelectorAll('#search-results a')].map(link=>({title:link.textContent,url:link.getAttribute('href')}))");
    assert(matches.some(link => /calendar/i.test(link.title)), 'Calendar guides missing from search results');
    await docs.key('ArrowDown');
    assert(await docs.evaluate("document.activeElement.matches('#search-results a')"), 'Search ArrowDown did not focus the first result');
    await docs.evaluate("document.getElementById('doc-search').focus()");
    await docs.key('Escape');
    assert(await docs.evaluate("document.getElementById('doc-search').value===''&&document.getElementById('search-results').hidden"), 'Search Escape did not clear its results');
    report.controls.navigation = { keyboardOpen: true, escapeClose: true, focusRestored: true };
    report.controls.search = { calendarMatches: matches, keyboardResultFocus: true, escapeClear: true };
    await docs.close();

    const prompt = await owned.page(base + 'docs/agent-setup/', { width: 390, height: 844 });
    const count = await prompt.evaluate("document.querySelectorAll('[data-copy-prompt]').length");
    assert.equal(count, 2, 'Expected the two agent setup prompts');
    await activate(prompt, '[data-copy-prompt]');
    await waitFor(prompt, "document.querySelector('[data-copy-prompt]').textContent==='Copied'", 'Prompt copy handler did not respond');
    assert(await prompt.evaluate("window.__qaCopied===document.getElementById(document.querySelector('[data-copy-prompt]').dataset.copy).textContent.trim()&&window.__qaCopied.startsWith('Read AGENTS.md')"), 'Copied prompt does not match its source');
    await prompt.evaluate('window.__qaClipboardReject=true');
    await activate(prompt, '[data-copy-prompt]');
    await waitFor(prompt, "document.querySelector('[data-copy-prompt]').textContent==='Select & copy'", 'Denied clipboard did not offer selection fallback');
    assert(await prompt.evaluate("getSelection().toString().trim()===document.getElementById(document.querySelector('[data-copy-prompt]').dataset.copy).textContent.trim()"), 'Clipboard fallback selected the wrong text');
    report.controls.copy = { prompts: count, exactContent: true, deniedFallback: true };
    await prompt.close();

    const motion = await owned.page(base, { width: 390, height: 844, reducedMotion: true });
    assert(await motion.evaluate("matchMedia('(prefers-reduced-motion: reduce)').matches"), 'Reduced-motion emulation unavailable');
    const controls = await motion.evaluate("document.querySelectorAll('[data-animation-toggle]').length");
    for (let index = 0; index < controls; index++) {
      const state = await motion.evaluate(`(()=>{const button=[...document.querySelectorAll('[data-animation-toggle]')][${index}];const image=button.closest('figure').querySelector('img');return{pressed:button.getAttribute('aria-pressed'),src:image.currentSrc||image.src};})()`);
      assert(state.pressed === 'false' && !state.src.endsWith('.gif'), 'Reduced motion must select a paused still');
      // Select by a temporary QA-only attribute; no source markup is changed.
      await motion.evaluate(`document.querySelectorAll('[data-animation-toggle]')[${index}].setAttribute('data-qa-motion','${index}')`);
      await activate(motion, `[data-qa-motion="${index}"]`);
      assert(await motion.evaluate(`document.querySelector('[data-qa-motion="${index}"]').getAttribute('aria-pressed')==='true'`), 'Explicit animation play failed');
      await activate(motion, `[data-qa-motion="${index}"]`);
      assert(await motion.evaluate(`document.querySelector('[data-qa-motion="${index}"]').getAttribute('aria-pressed')==='false'`), 'Explicit animation pause failed');
    }
    assert(await motion.evaluate("document.getAnimations().every(animation=>animation.playState!=='running'||animation.effect.getTiming().iterations!==Infinity)"), 'Infinite animation remains active under reduced motion');
    await writeNew(path.join(out, 'home-reduced-motion.png'), cleanPng(await motion.screenshot()));
    report.controls.reducedMotion = { active: true, controls, playPause: true };
    await motion.close();
    assert(!owned.errors.length, 'Browser page exceptions occurred');
    // A harmless browser favicon probe may be denied; other denied resources
    // mean the template requested something outside the publication manifest.
    assert(owned.blocked.every(url => url === '/favicon.ico'), `Unexpected resource requests: ${owned.blocked.join(', ')}`);
    await reservation();
    report.passed = true;
    console.log(`Browser QA PASS: ${report.viewports.length} composed views, navigation/search/copy/reduced motion. Evidence: ${path.relative(root, out)}`);
  } finally {
    report.errors = owned.errors; report.blockedRequests = owned.blocked; report.requests = owned.requests;
    await owned.close();
    await writeNew(path.join(out, 'report.json'), JSON.stringify(report, null, 2) + '\n');
  }
}

await reservation();
await (mode === 'social' ? social() : qa());
