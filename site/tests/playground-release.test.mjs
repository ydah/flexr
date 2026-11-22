import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { devNull, tmpdir } from 'node:os';
import path from 'node:path';
import { stableReleaseTag as stableTag } from '../scripts/stable-release.mjs';

test('packages the released lexer and presets when building the public Playground', async () => {
  const repo = await mkdtemp(path.join(tmpdir(), 'flexr-playground-release-'));
  const site = path.join(repo, 'site');
  const git = (...args) => execFileSync('git', args, {
    cwd: repo,
    env: { ...process.env, GIT_CONFIG_GLOBAL: devNull, GIT_CONFIG_NOSYSTEM: '1' }
  });
  const write = async (name, contents) => {
    const filename = path.join(repo, name);
    await mkdir(path.dirname(filename), { recursive: true });
    await writeFile(filename, contents);
  };
  const readAsset = async name => JSON.parse(await readFile(path.join(site, 'public/playground-runtime', name), 'utf8'));
  const prepare = stable => execFileSync(process.execPath, ['scripts/prepare-playground.mjs'], {
    cwd: site,
    env: { ...process.env, FLEXR_PLAYGROUND_STABLE: stable ? '1' : '' }
  });

  try {
    git('init', '-q');
    await write('lib/flexr/version.rb', `Flexr::VERSION = "${stableTag.slice(1)}"\n`);
    await write('lib/flexr.rb', '# Released lexer\n');
    for (const name of ['toml', 'graphql', 'sql']) {
      await write(`examples/${name}/lexer.flexr.rb`, `# Released ${name}\n`);
    }
    git('add', 'lib', 'examples');
    git('-c', 'user.name=flexr test', '-c', 'user.email=flexr@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Release');
    git('tag', stableTag);
    await write('lib/flexr.rb', '# Main lexer\n');
    await write('lib/main-only.rb', '# Next release\n');
    await write('examples/toml/lexer.flexr.rb', '# Main TOML\n');
    await write('site/ruby/playground.rb', '# Playground bridge\n');
    await write('site/ruby/presets/absence.flexr.rb', '# Main absence preset\n');
    await write('site/ruby/presets/pattern.flexr.rb', '# Main pattern preset\n');
    await write('site/ruby/presets/keywords.flexr.rb', '# Main keyword preset\n');
    await write('site/ruby/presets/trivia.flexr.rb', '# Main trivia preset\n');
    await cp(new URL('../scripts/', import.meta.url), path.join(site, 'scripts'), { recursive: true });
    for (const asset of ['ruby+stdlib.wasm', 'LICENSE', 'NOTICE']) {
      await write(`site/node_modules/@ruby/4.0-wasm-wasi/dist/${asset}`, '');
    }

    prepare(false);
    assert.equal((await readAsset('flexr.json')).files['/app/lib/flexr.rb'], '# Main lexer\n');
    assert.equal((await readAsset('presets.json')).toml.source, '# Main TOML\n');
    assert.equal((await readAsset('presets.json')).absence.source, '# Main absence preset\n');
    assert.equal((await readAsset('presets.json')).keywords.source, '# Main keyword preset\n');
    assert.equal((await readAsset('presets.json')).trivia.source, '# Main trivia preset\n');
    prepare(true);
    const { files } = await readAsset('flexr.json');
    assert.equal(files['/app/lib/flexr.rb'], '# Released lexer\n');
    assert.equal(files['/app/lib/main-only.rb'], undefined);
    assert.equal((await readAsset('presets.json')).toml.source, '# Released toml\n');
    assert.equal((await readAsset('presets.json')).absence, undefined);
    assert.equal((await readAsset('presets.json')).pattern, undefined);
    assert.equal((await readAsset('presets.json')).keywords, undefined);
    assert.equal((await readAsset('presets.json')).trivia, undefined);
  } finally {
    await rm(repo, { recursive: true, force: true });
  }
});
