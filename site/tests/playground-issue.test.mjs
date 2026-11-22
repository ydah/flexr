import assert from 'node:assert/strict';
import { test } from 'node:test';
import { issueDraft } from '../src/playground/issue.mjs';

test('keeps the full local draft when the encoded URL is too long', () => {
  const source = 'é'.repeat(20_000);
  const { body, url, manualPaste } = issueDraft({
    source, input: '<!-- example -->', mode: 'generated', version: '2.0.0', diagnostics: 'FLEXR-E014',
  });
  assert.ok(body.includes(source));
  assert.ok(body.includes('    <!-- example -->'));
  assert.equal(manualPaste, true);
  assert.equal(url.searchParams.has('body'), false);
  assert.equal(url.pathname, '/ydah/flexr/issues/new');
});
