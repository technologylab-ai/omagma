// Rasterize the genuine meeting reminder states; retain all approved footage.
import {readFileSync, writeFileSync, mkdirSync, existsSync} from 'node:fs';
import {join} from 'node:path';
import {createHash} from 'node:crypto';
import {parseArgs} from 'node:util';
import {browser, reservation, root} from './cdp.mjs';

const {values: options} = parseArgs({options: {
  take: {type: 'string', default: 'revision-07/notifications'},
}});
if (!/^revision-\d{2}\/notifications$/.test(options.take)) throw Error('Use a named capture revision');
await reservation();
const cache = join(root, 'video/cache/short029');
const take = options.take;
const receipt = JSON.parse(readFileSync(join(cache, take, 'capture-manifest.json')));
if (!receipt.passed || !receipt.syntheticOnly || receipt.liveProviderWrites !== 0 ||
    !receipt.automaticArrivalInMail || !receipt.minuteTransitionVerified || !receipt.nativeJoinProof) {
  throw Error('Notification workflow evidence is incomplete');
}
const out = join(cache, take, 'assets');
if (existsSync(out)) throw Error('Preserve existing notification images');
mkdirSync(out);
const manifestPath = join(cache, 'assets-manifest.json');
const manifest = JSON.parse(readFileSync(manifestPath));
const b = await browser();
try {
  const p = await b.page('video/short029/capture-images.html', {scale: 2});
  for (const [key, asset] of Object.entries(receipt.assets)) {
    const tape = take + '/' + asset.tape;
    const rect = await p.evaluate(`window.capture(${JSON.stringify(tape)},${JSON.stringify(asset.mark)})`);
    await p.evaluate('new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))');
    const clip = {x: rect.left, y: rect.top, width: rect.columns * rect.cellW,
      height: rect.rows * rect.cellH, scale: 1};
    const data = Buffer.from((await p.call('Page.captureScreenshot', {format: 'png', clip})).data, 'base64');
    const filename = key.replaceAll('.', '-') + '.png';
    writeFileSync(join(out, filename), data);
    manifest.assets[key] = {
      file: take + '/assets/' + filename, width: clip.width * 2, height: clip.height * 2,
      sha256: createHash('sha256').update(data).digest('hex'),
      rois: {full: [0, 0, 1, 1], ...asset.rois}, tape, mark: asset.mark, panes: rect.panes,
      provenance: 'Actual native TUI cells; fictional Calendar and mail; fixture clock advanced explicitly for before/during states',
    };
  }
  await p.close();
} finally {
  await b.close();
}
manifest.notificationReceipt = take + '/capture-manifest.json';
writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
console.log('Rasterized native meeting reminders; all earlier assets preserved');
