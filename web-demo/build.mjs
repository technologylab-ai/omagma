import { build } from 'esbuild';
import { cp, mkdir, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const here = fileURLToPath(new URL('.', import.meta.url));
const args = process.argv.slice(2);
const options = new Map();
for (let index = 0; index < args.length; index += 2) {
  if (!['--wasm', '--out-dir'].includes(args[index]) || !args[index + 1] || options.has(args[index])) throw new Error('Usage: npm run build -- [--wasm /path/to/omagma.wasm] [--out-dir /path/to/site]');
  options.set(args[index], args[index + 1]);
}
const wasm = options.has('--wasm') ? resolve(process.cwd(), options.get('--wasm')) : resolve(here, 'omagma.wasm');
// Packaging only: the served application is a static page, JS, CSS and WASM.
const module = await WebAssembly.compile(await readFile(wasm));
for (const entry of WebAssembly.Module.imports(module)) if (entry.module !== 'env' || !['http_request', 'now_ms', 'drafts_store'].includes(entry.name) || entry.kind !== 'function') throw new Error('The browser module imports an unsupported host capability.');
const exports = new Set(WebAssembly.Module.exports(module).map(({ name }) => name));
for (const name of ['memory', 'init', 'resize', 'input_ptr', 'input_capacity', 'input', 'output_ptr', 'output_len', 'codepoint_width', 'policy_ptr', 'policy_len']) {
  if (!exports.has(name)) throw new Error(`Missing browser WASM export: ${name}`);
}
const out = options.has('--out-dir') ? resolve(process.cwd(), options.get('--out-dir')) : resolve(here, 'dist');
await mkdir(out, { recursive: true });
await build({
  absWorkingDir: here,
  entryPoints: ['app.mjs'],
  outfile: resolve(out, 'app.mjs'),
  bundle: true,
  minify: true,
  format: 'esm',
  target: ['es2022'],
  legalComments: 'external',
});
await Promise.all([
  cp(resolve(here, 'index.html'), resolve(out, 'index.html')),
  cp(resolve(here, 'style.css'), resolve(out, 'style.css')),
  cp(resolve(here, '../assets/omagma-logo.png'), resolve(out, 'omagma-logo.png')),
  cp(resolve(here, 'node_modules/@xterm/xterm/css/xterm.css'), resolve(out, 'xterm.css')),
  cp(resolve(here, 'node_modules/@xterm/xterm/LICENSE'), resolve(out, 'LICENSE-xterm.txt')),
  cp(resolve(here, 'node_modules/@xterm/addon-fit/LICENSE'), resolve(out, 'LICENSE-xterm-addon-fit.txt')),
  cp(wasm, resolve(out, 'omagma.wasm')),
]);
console.log(`Built static browser experiment: ${out}`);
