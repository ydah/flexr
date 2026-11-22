import { createRuntime } from './runtime.mjs';

export async function run({ state, base }) {
  try {
    const start = performance.now();
    const [response, data] = await Promise.all([fetch(`${base}ruby.wasm`), fetch(`${base}flexr.json`)]);
    if (!response.ok || !data.ok) throw new Error('The Ruby runtime could not be downloaded. Retry when the connection is available.');
    const binary = await response.arrayBuffer();
    const assets = await data.json();
    const runtime = await createRuntime(binary, assets);
    const downloadMs = performance.now() - start;
    for (const name of ['fetch', 'XMLHttpRequest', 'WebSocket', 'WebTransport', 'EventSource', 'Worker', 'importScripts']) {
      for (let target = globalThis; target; target = Object.getPrototypeOf(target)) {
        const property = Object.getOwnPropertyDescriptor(target, name);
        if (target === globalThis || property?.configurable) {
          Object.defineProperty(target, name, { value: undefined, configurable: false, writable: false });
        }
      }
    }
    const result = await runtime.run(state, (startupMs, flexrVersion) => postMessage({ phase: 'ready', startupMs, flexrVersion }));
    const payload = JSON.stringify({ ...result, wasm_bytes: binary.byteLength, download_ms: downloadMs });
    if (new TextEncoder().encode(payload).byteLength > 4_000_000) throw new Error('Output exceeds 4 MB. Reduce the input or number of states.');
    postMessage({ phase: 'result', result: JSON.parse(payload) });
  } catch (error) {
    postMessage({ phase: 'error', error: error instanceof Error ? error.message : String(error) });
  }
}

self.onmessage = ({ data }) => run(data);
