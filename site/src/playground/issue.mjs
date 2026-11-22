function section(title, text) {
  const code = text.split('\n').map(line => `    ${line}`).join('\n');
  return `### ${title}\n\n${code}`;
}

export function issueDraft({ source, input, mode, version, diagnostics }) {
  const body = [
    section('Version and mode', `flexr ${version}\n${mode}`),
    section('Lexer specification', source),
    section('Input', input),
    section('Diagnostics', diagnostics),
  ].join('\n\n');
  const url = new URL('https://github.com/ydah/flexr/issues/new');
  url.searchParams.set('title', 'Playground reproduction');
  url.searchParams.set('body', body);
  const manualPaste = url.href.length > 7500;
  if (manualPaste) url.searchParams.delete('body');
  return { body, url, manualPaste };
}
