export const MAX_TEXT = 20_000;
const MAX_HASH = 220_000;

export function validateState(value) {
  if (!value || typeof value !== 'object' || typeof value.source !== 'string' || typeof value.input !== 'string' ||
      !['runtime', 'generated'].includes(value.mode) || value.source.length > MAX_TEXT || value.input.length > MAX_TEXT) {
    throw new Error(`Invalid playground state. Source and input are limited to ${MAX_TEXT} characters each.`);
  }
  return { source: value.source, input: value.input, mode: value.mode };
}

export function encodeState(value) {
  const bytes = new TextEncoder().encode(JSON.stringify(validateState(value)));
  let binary = '';
  for (let index = 0; index < bytes.length; index += 4096) binary += String.fromCharCode(...bytes.subarray(index, index + 4096));
  const encoded = btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
  if (encoded.length > MAX_HASH) throw new Error('Share link is too large. Reduce the source or input.');
  return encoded;
}

export function decodeState(hash) {
  if (hash.length > MAX_HASH) throw new Error('Share link is too large.');
  try {
    const binary = atob(hash.replaceAll('-', '+').replaceAll('_', '/'));
    const bytes = Uint8Array.from(binary, character => character.charCodeAt(0));
    return validateState(JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes)));
  } catch {
    throw new Error('Invalid playground share link.');
  }
}
