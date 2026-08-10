import { existsSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const root = resolve(new URL('..', import.meta.url).pathname);
const required = [
  'astro.config.mjs',
  'src/pages/index.astro',
  'src/pages/playground.astro',
  'src/content/docs/learn/getting-started.md',
  'src/content/docs/learn/generation.md',
  'src/content/docs/reference/dsl.md',
  'src/content/docs/reference/diagnostics.md',
  'public/playground.js'
];

const missing = required.filter((file) => !existsSync(resolve(root, file)));
if (missing.length) {
  console.error(`Missing site files: ${missing.join(', ')}`);
  process.exit(1);
}

const sourceFiles = required.map((file) => readFileSync(resolve(root, file), 'utf8'));
const source = sourceFiles.join('\n');
if (/[\u3040-\u30ff\u3400-\u9fff]/u.test(source)) {
  console.error('Site content must remain English-only.');
  process.exit(1);
}

const requiredPhrases = [
  'longest match',
  'Runtime mode',
  'Generated mode',
  'fixture-backed',
  'does not execute arbitrary Ruby'
];
const missingPhrases = requiredPhrases.filter((phrase) => !source.toLowerCase().includes(phrase.toLowerCase()));
if (missingPhrases.length) {
  console.error(`Missing product-site contract language: ${missingPhrases.join(', ')}`);
  process.exit(1);
}

console.log(`Site verification passed (${required.length} required files, English-only copy, product boundary checks).`);
