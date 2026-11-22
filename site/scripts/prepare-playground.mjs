import { cp, mkdir, readdir, readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { readStableFile, stableFiles } from './stable-release.mjs';

const site = fileURLToPath(new URL('..', import.meta.url));
const root = path.dirname(site);
const output = path.join(site, 'public/playground-runtime');
const useStable = process.env.FLEXR_PLAYGROUND_STABLE === '1';
const files = {};
async function collect(directory) {
  for (const entry of await readdir(path.join(root, directory), { withFileTypes: true })) {
    const relative = path.posix.join(directory, entry.name);
    if (entry.isDirectory()) await collect(relative);
    else if (entry.name.endsWith('.rb')) files[`/app/${relative}`] = await readFile(path.join(root, relative), 'utf8');
  }
}
if (useStable) {
  for (const filename of stableFiles('lib').filter(filename => filename.endsWith('.rb'))) {
    files[`/app/${filename}`] = readStableFile(filename);
  }
} else {
  await collect('lib');
}
files['/app/playground.rb'] = await readFile(path.join(site, 'ruby/playground.rb'), 'utf8');
await mkdir(output, { recursive: true });
const payload = JSON.stringify({ files });
await writeFile(path.join(output, 'flexr.json'), payload);
const inputs = {
  toml: 'title = "flexr"',
  graphql: 'query { user(id: 12) { name } }',
  sql: 'select name from users where id >= 12;',
};
const presets = {};
for (const [name, input] of Object.entries(inputs)) {
  const filename = `examples/${name}/lexer.flexr.rb`;
  const source = useStable ? readStableFile(filename) : await readFile(path.join(root, filename), 'utf8');
  presets[name] = { source, input };
}
const absenceFilename = 'site/ruby/presets/absence.flexr.rb';
if (!useStable || stableFiles(absenceFilename).includes(absenceFilename)) {
  const source = useStable ? readStableFile(absenceFilename) : await readFile(path.join(root, absenceFilename), 'utf8');
  presets.absence = { source, input: '/* 前 */first /* another comment */second' };
}
await writeFile(path.join(output, 'presets.json'), JSON.stringify(presets));
const wasm = path.join(site, 'node_modules/@ruby/4.0-wasm-wasi/dist');
await cp(path.join(wasm, 'ruby+stdlib.wasm'), path.join(output, 'ruby.wasm'));
await cp(path.join(wasm, 'LICENSE'), path.join(output, 'LICENSE'));
await cp(path.join(wasm, 'NOTICE'), path.join(output, 'NOTICE'));
console.log(`Playground: packaged ${Object.keys(files).length} Ruby files (${Buffer.byteLength(payload)} bytes).`);
