import { cp, mkdir, readdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const site = fileURLToPath(new URL('..', import.meta.url));
const root = path.dirname(site);
const output = path.join(site, 'public/playground-runtime');
const files = {};
async function collect(directory) {
  for (const entry of await readdir(path.join(root, directory), { withFileTypes: true })) {
    const relative = path.posix.join(directory, entry.name);
    if (entry.isDirectory()) await collect(relative);
    else if (entry.name.endsWith('.rb')) files[`/app/${relative}`] = await readFile(path.join(root, relative), 'utf8');
  }
}
await collect('lib');
files['/app/playground.rb'] = await readFile(path.join(site, 'ruby/playground.rb'), 'utf8');
await mkdir(output, { recursive: true });
const payload = JSON.stringify({ files });
await writeFile(path.join(output, 'flexr.json'), payload);
const wasm = path.join(site, 'node_modules/@ruby/4.0-wasm-wasi/dist');
await cp(path.join(wasm, 'ruby+stdlib.wasm'), path.join(output, 'ruby.wasm'));
await cp(path.join(wasm, 'LICENSE'), path.join(output, 'LICENSE'));
await cp(path.join(wasm, 'NOTICE'), path.join(output, 'NOTICE'));
console.log(`Playground: packaged ${Object.keys(files).length} Ruby files (${Buffer.byteLength(payload)} bytes).`);
