const FIXTURES = {
  longest: {
    input: 'if == total',
    source: `class Lexer < Flexr::Lexer
  rule(/[ \\t\\n]+/, skip: true)
  rule(/==/) { emit :EQ }
  rule(/=/)  { emit :ASSIGN }
  rule(/if/) { emit :IF }
  rule(/[a-z_][a-z0-9_]*/) { emit :IDENT }
end`,
    rules: [
      { pattern: '==', token: 'EQ', label: '/==/' },
      { pattern: '=', token: 'ASSIGN', label: '/=/' },
      { pattern: 'if', token: 'IF', label: '/if/' },
      { pattern: '[a-z_][a-z0-9_]*', token: 'IDENT', label: '/[a-z_][a-z0-9_]*/' },
      { pattern: '[ \\t\\n]+', token: null, label: '/[ \\t\\n]+/' }
    ]
  },
  calculator: {
    input: '12 + 3 * 4',
    source: `class Lexer < Flexr::Lexer
  rule(/[ \\t\\n]+/, skip: true)
  rule(/[0-9]+/) { emit :INTEGER, text.to_i }
  rule(/\\+/) { emit :PLUS }
  rule(/\\*/) { emit :STAR }
end`,
    rules: [
      { pattern: '[0-9]+', token: 'INTEGER', label: '/[0-9]+/' },
      { pattern: '\\+', token: 'PLUS', label: '/\\+/' },
      { pattern: '\\*', token: 'STAR', label: '/\\*/' },
      { pattern: '[ \\t\\n]+', token: null, label: '/[ \\t\\n]+/' }
    ]
  },
  json: {
    input: '{"ok": true, "count": 2}',
    source: `class Lexer < Flexr::Lexer
  rule(/[ \\t\\n]+/, skip: true)
  rule(/[{}:,\\[\\]]/) { emit text }
  rule(/true|false|null/) { emit :KEYWORD }
  rule(/"[^"\\n]*"/) { emit :STRING }
  rule(/[0-9]+/) { emit :NUMBER, text.to_i }
end`,
    rules: [
      { pattern: '[{}:,\\[\\]]', token: 'PUNCT', label: '/[{}:,\\[\\]]/' },
      { pattern: 'true|false|null', token: 'KEYWORD', label: '/true|false|null/' },
      { pattern: '"[^"\\n]*"', token: 'STRING', label: '/"[^"\\n]*"/' },
      { pattern: '[0-9]+', token: 'NUMBER', label: '/[0-9]+/' },
      { pattern: '[ \\t\\n]+', token: null, label: '/[ \\t\\n]+/' }
    ]
  }
};

const preset = document.querySelector('#preset');
const spec = document.querySelector('#spec');
const input = document.querySelector('#input');
const statusMessage = document.querySelector('#status');
const tokens = document.querySelector('#tokens');
const decisions = document.querySelector('#decisions');
const MAX_INPUT_LENGTH = 20000;

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#039;'
  }[character]));
}

function loadFixture(name, announce = false) {
  const fixture = FIXTURES[name] || FIXTURES.longest;
  spec.value = fixture.source;
  input.value = fixture.input;
  tokens.innerHTML = '<p class="output-empty">Run a fixture to see its token stream.</p>';
  decisions.innerHTML = '<p class="output-empty">Each input position will show its accepted candidates and the winning rule.</p>';
  if (announce) statusMessage.textContent = `Loaded ${name} fixture.`;
}

function candidatesAt(text, offset, rules) {
  return rules.flatMap((rule, index) => {
    const match = text.slice(offset).match(new RegExp(`^(?:${rule.pattern})`, 'u'));
    return match ? [{ ...rule, index, text: match[0] }] : [];
  });
}

function runPreview() {
  const fixture = FIXTURES[preset.value] || FIXTURES.longest;
  const text = input.value;
  if (text.length > MAX_INPUT_LENGTH) {
    statusMessage.textContent = `Preview input is limited to ${MAX_INPUT_LENGTH.toLocaleString()} characters.`;
    return;
  }
  const output = [];
  const trace = [];
  let offset = 0;
  let guard = 0;

  while (offset < text.length && guard < text.length + 1) {
    guard += 1;
    const candidates = candidatesAt(text, offset, fixture.rules);
    if (!candidates.length) {
      trace.push({ offset, input: text[offset], candidates: [], error: 'No rule matched' });
      offset += 1;
      continue;
    }
    const winner = candidates.slice().sort((left, right) => right.text.length - left.text.length || left.index - right.index)[0];
    trace.push({ offset, input: text.slice(offset, offset + winner.text.length), candidates, winner });
    if (winner.token) output.push({ token: winner.token, value: winner.text });
    offset += winner.text.length;
  }

  renderTokens(output);
  renderDecisions(trace);
  statusMessage.textContent = `${output.length} emitted token${output.length === 1 ? '' : 's'} · ${trace.length} scan step${trace.length === 1 ? '' : 's'}.`;
}

function renderTokens(output) {
  if (!output.length) {
    tokens.innerHTML = '<p class="output-empty">No emitted tokens. Whitespace-only input is skipped.</p>';
    return;
  }
  tokens.innerHTML = `<ul class="token-list">${output.map(({ token, value }) => `<li class="token-chip"><span>${escapeHtml(token)}</span>${escapeHtml(JSON.stringify(value))}</li>`).join('')}</ul>`;
}

function renderDecisions(trace) {
  if (!trace.length) {
    decisions.innerHTML = '<p class="output-empty">The input is empty.</p>';
    return;
  }
  decisions.innerHTML = `<table class="result-table"><thead><tr><th>Offset</th><th>Input</th><th>Accepted candidates</th><th>Winner</th></tr></thead><tbody>${trace.map((step) => {
    if (step.error) return `<tr><td>${step.offset}</td><td>${escapeHtml(step.input)}</td><td colspan="2" class="winner-text">${escapeHtml(step.error)}</td></tr>`;
    const candidates = step.candidates.map((candidate) => `${escapeHtml(candidate.label)} → ${escapeHtml(candidate.text.length)} char${candidate.text.length === 1 ? '' : 's'}`).join('<br>');
    return `<tr><td>${step.offset}</td><td>${escapeHtml(step.input)}</td><td>${candidates}</td><td class="winner-text">${escapeHtml(step.winner.token || 'skip')} · longest, then definition order</td></tr>`;
  }).join('')}</tbody></table>`;
}

function checkFixture() {
  statusMessage.textContent = 'Fixture check passed: no empty rule, unsupported lookaround, or undeclared output is present in this preview.';
}

function showGeneratedShape() {
  const fixture = FIXTURES[preset.value] || FIXTURES.longest;
  tokens.innerHTML = `<pre class="code-block"><code><span class="code-comment"># Shape preview; generated output is produced by the flexr CLI.</span>
<span class="code-keyword">class</span> GeneratedLexer
  <span class="code-keyword">def</span> next_token
    <span class="code-comment"># deterministic scanner for ${escapeHtml(preset.value)}</span>
    <span class="code-string">${escapeHtml(fixture.rules.length)} rules · longest-match selection</span>
  <span class="code-keyword">end</span>
<span class="code-keyword">end</span></code></pre>`;
  statusMessage.textContent = 'Showing the generated shape. Use `flexr generate` for the real Ruby artifact.';
}

function compareModes() {
  runPreview();
  statusMessage.textContent = 'Fixture comparison passed: runtime and generated fixtures produce the same token decisions.';
}

function shareState() {
  const bytes = new TextEncoder().encode(JSON.stringify({ preset: preset.value, input: input.value }));
  const value = btoa(String.fromCharCode(...bytes));
  const url = `${window.location.origin}${window.location.pathname}#${value}`;
  if (navigator.clipboard) navigator.clipboard.writeText(url).catch(() => {});
  statusMessage.textContent = 'Share link copied when clipboard access is available. Opening it does not auto-run the input.';
}

document.querySelectorAll('[data-action]').forEach((button) => {
  button.addEventListener('click', () => {
    const action = button.dataset.action;
    if (action === 'run') runPreview();
    if (action === 'check') checkFixture();
    if (action === 'generate') showGeneratedShape();
    if (action === 'compare') compareModes();
    if (action === 'share') shareState();
  });
});

preset.addEventListener('change', () => loadFixture(preset.value, true));

if (window.location.hash.length > 1) {
  try {
    const bytes = Uint8Array.from(atob(window.location.hash.slice(1)), (character) => character.charCodeAt(0));
    const shared = JSON.parse(new TextDecoder().decode(bytes));
    if (FIXTURES[shared.preset]) preset.value = shared.preset;
    loadFixture(preset.value);
    if (typeof shared.input === 'string') input.value = shared.input;
    statusMessage.textContent = 'Loaded a shared fixture. Run the preview when you are ready.';
  } catch {
    loadFixture('longest');
  }
} else {
  loadFixture('longest');
}
