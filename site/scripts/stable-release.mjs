import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const stableReleaseTag = process.env.FLEXR_STABLE_RELEASE_TAG ?? 'v2.0.0';
if (!/^v[0-9]+\.[0-9]+\.[0-9]+$/.test(stableReleaseTag)) {
  throw new Error('FLEXR_STABLE_RELEASE_TAG must be a vX.Y.Z release tag.');
}

const root = fileURLToPath(new URL('../../', import.meta.url));
const ref = `refs/tags/${stableReleaseTag}`;

export function stableFiles(prefix) {
  return execFileSync('git', ['ls-tree', '-r', '--name-only', '-z', ref, '--', prefix], { cwd: root, encoding: 'utf8' })
    .split('\0').filter(Boolean);
}

export function readStableFile(filename) {
  return execFileSync('git', ['show', `${ref}:${filename}`], { cwd: root, encoding: 'utf8' });
}
