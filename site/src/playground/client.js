import workerUrl from './worker.mjs?worker&url';
import graphWorkerUrl from './graph-worker.mjs?worker&url';
import { PRESETS } from './presets.mjs';
import { decodeState, encodeState, validateState } from './share.mjs';

const source = document.querySelector('#spec');
const input = document.querySelector('#input');
const mode = document.querySelector('#mode');
const status = document.querySelector('#status');
const runButton = document.querySelector('[data-action="run"]');
const stopButton = document.querySelector('[data-action="stop"]');
const steps = document.querySelector('#step');
let worker;
let timer;
let graphWorker;
let graphTimer;
let trace = [];
let dot = '';

function show(id, text) { document.querySelector(`#${id}`).textContent = text; }

function stop(message = 'Stopped. Edit the source or input, then run again.') {
  worker?.terminate();
  worker = undefined;
  clearTimeout(timer);
  runButton.disabled = false;
  stopButton.disabled = true;
  status.textContent = message;
}

function selectStep(index) {
  steps.value = String(Math.max(0, Math.min(index, trace.length - 1)));
  const selected = trace[Number(steps.value)];
  show('step-position', selected ? `Step ${Number(steps.value) + 1} of ${trace.length}` : 'No scan steps.');
  show('decisions', selected ? JSON.stringify(selected, null, 2) : 'Run a specification to inspect its decisions.');
}

function display(result) {
  if (!result || typeof result !== 'object') throw new Error('The worker returned an invalid result.');
  if (typeof result.error === 'string') {
    show('diagnostics', result.error);
    show('tokens', 'Execution failed.');
    show('generated', 'Generation did not finish.');
    show('console', 'No console output.');
    show('graph', 'No automaton is available.');
    show('dot', '');
    stop('The specification or input failed. Read the diagnostic below.');
    return;
  }
  if (!Array.isArray(result.tokens) || !Array.isArray(result.steps) || typeof result.generated !== 'string' || typeof result.dot !== 'string') {
    throw new Error('The worker returned an invalid result.');
  }
  show('tokens', JSON.stringify(result.tokens, null, 2));
  show('diagnostics', result.diagnostics || 'No diagnostics.');
  show('generated', result.generated);
  show('console', result.console || 'No console output.');
  dot = result.dot;
  show('dot', dot);
  show('graph', 'Select Draw DFA to load Graphviz and render this automaton.');
  trace = result.steps;
  steps.max = String(Math.max(0, trace.length - 1));
  steps.disabled = trace.length === 0;
  selectStep(0);
  stop(`${result.tokens.length} token${result.tokens.length === 1 ? '' : 's'}, ${trace.length} step${trace.length === 1 ? '' : 's'}. Ruby ${result.ruby_version}, Prism ${result.prism_version}.`);
  show('metrics', `${(Number(result.wasm_bytes) / 1_048_576).toFixed(2)} MiB Ruby download; download/compile ${Math.round(Number(result.download_ms))} ms; VM and flexr startup ${Math.round(Number(result.startup_ms))} ms. Cached downloads may be faster.`);
}

function run() {
  stop();
  try {
    const state = validateState({ source: source.value, input: input.value, mode: mode.value });
    show('tokens', 'Running…');
    show('diagnostics', 'Compiling…');
    show('generated', 'Generating…');
    show('graph', 'Compiling…');
    show('dot', 'Compiling…');
    show('console', 'Running…');
    graphWorker?.terminate();
    clearTimeout(graphTimer);
    trace = [];
    dot = '';
    selectStep(0);
    const url = new URL(workerUrl, location.href).href;
    const bootstrap = `let queued; self.onmessage=e=>{queued=e.data}; import(${JSON.stringify(url)}).then(()=>{if(queued)self.dispatchEvent(new MessageEvent('message',{data:queued}))});`;
    const blob = URL.createObjectURL(new Blob([bootstrap], { type: 'text/javascript' }));
    worker = new Worker(blob, { type: 'module' });
    URL.revokeObjectURL(blob);
    runButton.disabled = true;
    stopButton.disabled = false;
    status.textContent = 'Loading Ruby locally. The runtime is about 31 MiB before compression.';
    timer = setTimeout(() => stop('Runtime loading exceeded 30 seconds. Check the connection and retry.'), 30_000);
    worker.onerror = () => stop('The worker failed. Retry, or reduce the specification.');
    let started = false;
    const currentWorker = worker;
    worker.onmessage = ({ data }) => {
      if (currentWorker !== worker) return;
      if (data?.phase === 'ready' && !started) {
        started = true;
        clearTimeout(timer);
        status.textContent = 'Running the specification in a worker…';
        timer = setTimeout(() => stop('Execution exceeded 5 seconds and was stopped. Reduce the specification or input.'), 5_000);
      } else if (data?.phase === 'error') {
        stop(String(data.error));
      } else if (data?.phase === 'result') {
        try { display(data.result); } catch (error) { stop(error.message); }
      }
    };
    const base = new URL(`${import.meta.env.BASE_URL}/playground-runtime/`.replaceAll('//', '/'), location.origin).href;
    worker.postMessage({ state, base });
  } catch (error) { stop(error.message); }
}

function safeSvg(text) {
  const parsed = new DOMParser().parseFromString(text, 'image/svg+xml');
  const allowed = new Set(['svg', 'g', 'title', 'polygon', 'path', 'ellipse', 'text', 'polyline', 'rect', 'line', 'circle']);
  const attributes = new Set(['viewBox', 'width', 'height', 'fill', 'stroke', 'transform', 'points', 'd', 'rx', 'ry', 'cx', 'cy', 'x', 'y', 'font-family', 'font-size', 'text-anchor', 'stroke-width']);
  function copy(node) {
    if (node.nodeType === Node.TEXT_NODE) return document.createTextNode(node.textContent);
    if (node.nodeType !== Node.ELEMENT_NODE || !allowed.has(node.localName)) return document.createTextNode('');
    const clean = document.createElementNS('http://www.w3.org/2000/svg', node.localName);
    for (const attribute of node.attributes) {
      if (attributes.has(attribute.name) && !/url\s*\(/i.test(attribute.value)) clean.setAttribute(attribute.name, attribute.value);
    }
    for (const child of node.childNodes) clean.append(copy(child));
    return clean;
  }
  if (parsed.documentElement.localName !== 'svg') throw new Error('Graphviz returned invalid SVG.');
  return copy(parsed.documentElement);
}

function drawGraph() {
  if (!dot) { show('graph', 'Run a specification first.'); return; }
  graphWorker?.terminate();
  clearTimeout(graphTimer);
  show('graph', 'Drawing DFA…');
  graphWorker = new Worker(graphWorkerUrl, { type: 'module' });
  graphTimer = setTimeout(() => {
    graphWorker.terminate();
    show('graph', 'Drawing exceeded 5 seconds. Inspect the DOT output instead.');
  }, 5000);
  graphWorker.onmessage = ({ data }) => {
    clearTimeout(graphTimer);
    graphWorker.terminate();
    try {
      if (typeof data?.svg !== 'string' || data.svg.length > 2_000_000) throw new Error(data?.error || 'The diagram is too large. Inspect the DOT output.');
      document.querySelector('#graph').replaceChildren(safeSvg(data.svg));
    } catch (error) { show('graph', error.message); }
  };
  graphWorker.onerror = () => {
    clearTimeout(graphTimer);
    graphWorker.terminate();
    show('graph', 'Graphviz could not draw this DFA. Inspect the DOT output instead.');
  };
  graphWorker.postMessage(dot);
}

let languagePresets;
document.querySelector('#preset').addEventListener('change', async event => {
  stop();
  const name = event.target.value;
  try {
    let preset = PRESETS[name];
    if (!preset) {
      status.textContent = 'Loading the repository example…';
      languagePresets ||= fetch(`${import.meta.env.BASE_URL}/playground-runtime/presets.json`.replaceAll('//', '/'))
        .then(response => {
          if (!response.ok) throw new Error('The example presets could not be downloaded.');
          return response.json();
        });
      preset = (await languagePresets)[name];
    }
    const state = validateState({ ...preset, mode: mode.value });
    if (event.target.value !== name) return;
    source.value = state.source;
    input.value = state.input;
    status.textContent = 'Preset loaded. Edit it or run it as written.';
  } catch (error) { status.textContent = error.message; }
});
document.querySelector('[data-action="run"]').addEventListener('click', run);
document.querySelector('[data-action="stop"]').addEventListener('click', () => stop());
document.querySelector('[data-action="draw"]').addEventListener('click', drawGraph);
document.querySelector('[data-action="previous"]').addEventListener('click', () => selectStep(Number(steps.value) - 1));
document.querySelector('[data-action="next"]').addEventListener('click', () => selectStep(Number(steps.value) + 1));
steps.addEventListener('input', () => selectStep(Number(steps.value)));
document.querySelector('[data-action="share"]').addEventListener('click', async () => {
  try {
    const hash = encodeState({ source: source.value, input: input.value, mode: mode.value });
    history.replaceState(null, '', `#${hash}`);
    const link = document.querySelector('#share-link');
    link.value = location.href;
    link.hidden = false;
    link.select();
    await navigator.clipboard?.writeText(location.href);
    status.textContent = 'Share link ready below. Opening it loads the text without running it.';
  } catch (error) { status.textContent = error.message; }
});

source.value = PRESETS.longest.source;
input.value = PRESETS.longest.input;
function restoreShare() {
  if (location.hash.length <= 1) return;
  try {
    const state = decodeState(location.hash.slice(1));
    source.value = state.source;
    input.value = state.input;
    mode.value = state.mode;
    status.textContent = 'Shared source loaded. Review it before selecting Run.';
  } catch (error) { status.textContent = error.message; }
}
restoreShare();
window.addEventListener('hashchange', restoreShare);
