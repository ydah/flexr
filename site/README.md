# flexr product site

This directory contains the Astro/Starlight product site for flexr. It is a static GitHub Pages site with a custom landing page, documentation routes, and a fixture-backed playground preview.

## Local development

```sh
cd site
pnpm install
pnpm dev
```

Run the same checks used by the Pages workflow:

```sh
pnpm verify
pnpm build
```

The current playground does not execute arbitrary Ruby. It demonstrates the matching decision model from fixed fixtures and keeps `--eval` out of the browser. A future Ruby WASM worker must preserve that security boundary and add runtime/generated equivalence tests before the UI claims full execution.

The repository examples, CLI definitions, and Ruby implementation remain the behavioral source of truth. Site copy links to those artifacts where a summary would otherwise drift.
