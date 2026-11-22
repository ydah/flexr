import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { devNull, tmpdir } from 'node:os';
import path from 'node:path';

test('packages docs, lexer and presets from the selected release', async () => {
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
  const prepare = (script, env = {}) => {
    const cleanEnv = { ...process.env };
    delete cleanEnv.FLEXR_STABLE_RELEASE_TAG;
    delete cleanEnv.FLEXR_PLAYGROUND_STABLE;
    execFileSync(process.execPath, [`scripts/prepare-${script}.mjs`], {
      cwd: site, env: { ...cleanEnv, ...env }, stdio: 'pipe'
    });
  };
  const docs = 'site/src/content/docs/getting-started.md';
  const stableDocs = 'site/src/content/docs/stable/getting-started.md';
  const fixedDocLink = 'https://github.com/ydah/flexr/blob/main/lib/flexr.rb';

  try {
    git('init', '-q');
    await write('lib/flexr/version.rb', 'Flexr::VERSION = "2.0.0"\n');
    await write('lib/flexr.rb', '# Released lexer\n');
    for (const name of ['toml', 'graphql', 'sql']) {
      await write(`examples/${name}/lexer.flexr.rb`, `# Released ${name}\n`);
    }
    await write('site/ruby/presets/heredoc.flexr.rb', '# Released heredoc preset\n');
    await write('site/ruby/presets/html_js.flexr.rb', '# Released HTML and JS preset\n');
    await write(docs, `Default release docs. [Lexer](${fixedDocLink})\n`);
    git('add', 'lib', 'examples', 'site/ruby/presets', docs);
    git('-c', 'user.name=flexr test', '-c', 'user.email=flexr@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Release');
    git('tag', 'v2.0.0');
    await write('lib/flexr.rb', '# Main lexer\n');
    await write('lib/main-only.rb', '# Next release\n');
    await write('examples/toml/lexer.flexr.rb', '# Main TOML\n');
    await write('site/ruby/playground.rb', '# Playground bridge\n');
    await write('site/ruby/presets/absence.flexr.rb', '# Main absence preset\n');
    await write('site/ruby/presets/pattern.flexr.rb', '# Main pattern preset\n');
    await write('site/ruby/presets/keywords.flexr.rb', '# Main keyword preset\n');
    await write('site/ruby/presets/trivia.flexr.rb', '# Main trivia preset\n');
    await write('site/ruby/presets/priority.flexr.rb', '# Main priority preset\n');
    await write('site/ruby/presets/indentation.flexr.rb', '# Main indentation preset\n');
    await write('site/ruby/presets/heredoc.flexr.rb', '# Main heredoc preset\n');
    await write('site/ruby/presets/html_js.flexr.rb', '# Main HTML and JS preset\n');
    await write('site/ruby/presets/html_javascript.rb', '# Main JavaScript lexer\n');
    await cp(new URL('../scripts/', import.meta.url), path.join(site, 'scripts'), { recursive: true });
    for (const asset of ['ruby+stdlib.wasm', 'LICENSE', 'NOTICE']) {
      await write(`site/node_modules/@ruby/4.0-wasm-wasi/dist/${asset}`, '');
    }

    prepare('playground');
    assert.equal((await readAsset('flexr.json')).files['/app/lib/flexr.rb'], '# Main lexer\n');
    assert.equal((await readAsset('presets.json')).toml.source, '# Main TOML\n');
    assert.equal((await readAsset('presets.json')).absence.source, '# Main absence preset\n');
    assert.equal((await readAsset('presets.json')).keywords.source, '# Main keyword preset\n');
    assert.equal((await readAsset('presets.json')).trivia.source, '# Main trivia preset\n');
    assert.equal((await readAsset('presets.json')).priority.source, '# Main priority preset\n');
    assert.equal((await readAsset('presets.json')).indentation.source, '# Main indentation preset\n');
    assert.equal((await readAsset('presets.json')).heredoc.source, '# Main heredoc preset\n');
    assert.equal((await readAsset('presets.json'))['html-js'].source, '# Main HTML and JS preset\n');
    const helper = '/app/lib/playground/html_javascript.rb';
    assert.equal((await readAsset('flexr.json')).files[helper], '# Main JavaScript lexer\n');
    prepare('docs');
    assert.equal(await readFile(path.join(repo, stableDocs), 'utf8'),
      'Default release docs. [Lexer](https://github.com/ydah/flexr/blob/v2.0.0/lib/flexr.rb)\n');
    prepare('playground', { FLEXR_PLAYGROUND_STABLE: '1' });
    const { files } = await readAsset('flexr.json');
    assert.equal(files['/app/lib/flexr.rb'], '# Released lexer\n');
    assert.equal(files['/app/lib/main-only.rb'], undefined);
    assert.equal((await readAsset('presets.json')).toml.source, '# Released toml\n');
    assert.equal((await readAsset('presets.json')).absence, undefined);
    assert.equal((await readAsset('presets.json')).pattern, undefined);
    assert.equal((await readAsset('presets.json')).keywords, undefined);
    assert.equal((await readAsset('presets.json')).trivia, undefined);
    assert.equal((await readAsset('presets.json')).priority, undefined);
    assert.equal((await readAsset('presets.json')).indentation, undefined);
    assert.equal((await readAsset('presets.json')).heredoc.source, '# Released heredoc preset\n');
    assert.equal((await readAsset('presets.json'))['html-js'], undefined);
    assert.equal(files[helper], undefined);

    await write(docs, `Selected release docs. [Lexer](${fixedDocLink})\n`);
    await write('lib/flexr.rb', '# Selected release lexer\n');
    await write('lib/flexr/version.rb', 'Flexr::VERSION = "2.99.0"\n');
    await write('site/ruby/presets/html_javascript.rb', '# Released JavaScript lexer\n');
    git('add', docs, 'lib/flexr.rb', 'lib/flexr/version.rb', 'site/ruby/presets/html_javascript.rb');
    git('-c', 'user.name=flexr test', '-c', 'user.email=flexr@example.invalid', '-c', 'commit.gpgsign=false', 'commit', '-qm', 'Ship the JavaScript helper');
    git('tag', 'v2.99.0');
    await write(docs, 'Development docs.\n');
    await write('site/ruby/presets/html_javascript.rb', '# Main JavaScript lexer\n');

    const selected = { FLEXR_STABLE_RELEASE_TAG: 'v2.99.0' };
    prepare('docs', selected);
    assert.equal(await readFile(path.join(repo, stableDocs), 'utf8'),
      'Selected release docs. [Lexer](https://github.com/ydah/flexr/blob/v2.99.0/lib/flexr.rb)\n');
    prepare('playground', { ...selected, FLEXR_PLAYGROUND_STABLE: '1' });
    const selectedFiles = (await readAsset('flexr.json')).files;
    assert.equal(selectedFiles['/app/lib/flexr.rb'], '# Selected release lexer\n');
    assert.equal(selectedFiles['/app/lib/flexr/version.rb'], 'Flexr::VERSION = "2.99.0"\n');
    assert.equal(selectedFiles['/app/lib/main-only.rb'], undefined);
    assert.equal((await readAsset('presets.json')).toml.source, '# Released toml\n');
    assert.equal((await readAsset('presets.json'))['html-js'].source, '# Released HTML and JS preset\n');
    assert.equal(selectedFiles[helper], '# Released JavaScript lexer\n');

    assert.throws(() => prepare('docs', { FLEXR_STABLE_RELEASE_TAG: 'v2.98.0' }), /refs\/tags\/v2\.98\.0/);
    assert.throws(() => prepare('docs', { FLEXR_STABLE_RELEASE_TAG: 'v2.99.0-rc.1' }), /FLEXR_STABLE_RELEASE_TAG/);
  } finally {
    await rm(repo, { recursive: true, force: true });
  }
});
