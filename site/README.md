# flexr product site

This directory contains the Astro/Starlight product site for flexr. The Playground
runs real Ruby and flexr locally through a pinned ruby.wasm runtime.

## Documentation versions

The existing documentation URLs describe `main`. The version links on each
page switch to the same topic under `/flexr/stable/` when that topic exists in
the release. If a topic is available in only one version, the link opens
Getting started in the other version.

`pnpm dev` and `pnpm build` copy the pinned release's Markdown from Git into
the ignored `src/content/docs/stable/` directory. Fetch the release tag with
`git fetch --tags` if it is missing from your clone. GitHub Pages also uses
that tag's Ruby library and example presets for the public Playground.

After a new stable gem is public on RubyGems and its Git tag is available,
update `stableReleaseTag` in `scripts/stable-release.mjs`. Run
`FLEXR_PLAYGROUND_STABLE=1 pnpm build` to reproduce the deployment build.

## Local development

```sh
cd site
pnpm install
pnpm dev
```

Run the same checks used by the Pages workflow:

```sh
pnpm verify
pnpm test
pnpm build
pnpm exec playwright install chromium
pnpm test:browser
```

`pnpm dev`, `pnpm build`, and `pnpm test` package the current repository's Ruby
files and copy the pinned runtime into ignored `public/playground-runtime` assets.
The WASM binary and source bundle are not checked into Git. The deployment build
produces them, including the Ruby distribution's license and notice.

The first Run lazily creates a worker and downloads the runtime. Every run starts
a new Ruby VM, loads the specification, compiles with flexr, executes its actions,
and returns tokens, real diagnostics, DOT, trace steps, and generated Ruby.
When the worker loads flexr, the version label shows the value that the gemspec
uses for the bundled source.
Prism 1.7.0 is available in the pinned Ruby 4.0.0 WASM build, so both runtime and
generated execution are tested. The static DSL restrictions of `flexr check` and
the generator apply. Specifications must be self-contained or use the bundled
Ruby libraries; additional gems and local companion files are unavailable.
The [ruby.wasm WASI limitations](https://ruby.github.io/ruby.wasm/README_md.html),
including unsupported thread creation, also apply.
The original three presets remain editable starting points. TOML, GraphQL, and
SQL subset presets load the actual repository example sources, packaged at build
time, so their lexer rules are maintained in one place.

The main page stops execution after five seconds; runtime download/startup has a
30-second limit. Source and input are limited to 20,000 characters each, DFA
construction to 1024 states, and output to 4 MB. Graphviz loads in a separate
worker only when Draw DFA is selected and has its own five-second limit.

Source/input are not uploaded by the application. Share links store them in the
URL fragment, and opening a link never executes it. Review shared Ruby before
running it. Workers isolate the UI and have a virtual filesystem; they are not a
complete hostile-code or memory sandbox. The page applies a CSP, disables common
network APIs in the Ruby worker after loading assets, and sanitizes rendered SVG.
Ruby actions can still modify their VM and interact with worker JavaScript.

## Size and startup measurements

Measured on 2026-11-21, macOS arm64, Headless Chrome 157, using the local static
preview server without network throttling:

| Asset | Uncompressed bytes | gzip bytes |
|---|---:|---:|
| Ruby 4.0.0 and standard library | 32,555,374 | 10,114,484 |
| flexr Ruby files and bridge | 533,463 | 119,954 |
| TOML, GraphQL, and SQL presets | 2,750 | 838 |

One browser run measured 43 ms for downloading/compiling the runtime and 203 ms
for starting the VM and loading flexr. These local numbers do not predict a
remote cold download. The UI reports measured sizes and timings on every run.
Initial page loading fetches neither Ruby WASM nor Graphviz; the browser test
checks that no WASM request occurs before Run or when opening a share link.

For local Chrome instead of a Playwright download, set
`PLAYWRIGHT_CHROMIUM_EXECUTABLE` to its executable path. Screenshots from the
browser tests are written to ignored `test-results/` directories.
