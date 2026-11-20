import { instance } from '@viz-js/viz';

self.onmessage = async ({ data }) => {
  try {
    if (typeof data !== 'string' || data.length > 500_000) throw new Error('DFA is too large to draw. Inspect its DOT output instead.');
    const viz = await instance();
    self.postMessage({ svg: viz.renderString(data, { format: 'svg', engine: 'dot' }) });
  } catch (error) {
    self.postMessage({ error: error instanceof Error ? error.message : String(error) });
  }
};
