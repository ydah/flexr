import { mkdir, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { readStableFile, stableFiles, stableReleaseTag } from './stable-release.mjs';

const prefix = 'site/src/content/docs/';
const output = fileURLToPath(new URL('../src/content/docs/stable/', import.meta.url));
const files = stableFiles(prefix).filter(filename => filename.endsWith('.md'));
const slugs = new Set(files.map(filename => filename.slice(prefix.length, -3)));
if (!files.length) throw new Error(`No site documentation in ${stableReleaseTag}.`);

await rm(output, { recursive: true, force: true });
for (const filename of files) {
  const source = readStableFile(filename)
    .replace(/\/flexr\/([^\s)#?]+)/g, (url, target) =>
      slugs.has(target.replace(/\/$/, '')) ? `/flexr/stable/${target}` : url
    )
    .replace(/https:\/\/github\.com\/ydah\/flexr\/(blob|tree)\/main\//g,
      `https://github.com/ydah/flexr/$1/${stableReleaseTag}/`);
  const target = path.join(output, filename.slice(prefix.length));
  await mkdir(path.dirname(target), { recursive: true });
  await writeFile(target, source);
}
