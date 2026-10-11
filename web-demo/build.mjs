import { build } from 'esbuild';
import { cp, mkdir, readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const here = fileURLToPath(new URL('.', import.meta.url));
const args = process.argv.slice(2);
if (args.length !== 0 && (args.length !== 2 || args[0] !== '--wasm')) {
  throw new Error('Usage: npm run build -- [--wasm /path/to/omagma.wasm]');
}
const wasm = args.length ? resolve(process.cwd(), args[1]) : resolve(here, 'omagma.wasm');
// Packaging only: the served application is a static page, JS, CSS and WASM.
const module = await WebAssembly.compile(await readFile(wasm));
if (WebAssembly.Module.imports(module).length !== 0) {
  throw new Error('The browser experiment requires an import-free WASM module.');
}
const exports = new Set(WebAssembly.Module.exports(module).map(({ name }) => name));
for (const name of ['memory', 'init', 'resize', 'input_ptr', 'input_capacity', 'input', 'output_ptr', 'output_len']) {
  if (!exports.has(name)) throw new Error(`Missing browser WASM export: ${name}`);
}
const out = resolve(here, 'dist');
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
  cp(resolve(here, 'node_modules/@xterm/xterm/css/xterm.css'), resolve(out, 'xterm.css')),
  cp(resolve(here, 'node_modules/@xterm/xterm/LICENSE'), resolve(out, 'LICENSE-xterm.txt')),
  cp(resolve(here, 'node_modules/@xterm/addon-fit/LICENSE'), resolve(out, 'LICENSE-xterm-addon-fit.txt')),
  cp(resolve(here, 'node_modules/@xterm/addon-unicode11/LICENSE'), resolve(out, 'LICENSE-xterm-addon-unicode11.txt')),
  cp(wasm, resolve(out, 'omagma.wasm')),
]);
console.log(`Built static browser experiment: ${out}`);
