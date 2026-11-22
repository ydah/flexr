# Contextual lexer runtime implementation

These notes record how the Flexr 2.2 runtime supports included sources, dynamic
delimiters, indentation, and embedded lexers.

## Input stack

`Flexr::Runtime#push_input` validates a new buffer before adding it to the
pending inputs. Runtime and generated actions use the same transition at the
next token boundary. `activate_pending_inputs` records the checkpoint fields
along with the active buffer, filename, and input-specific scanner flags.
`resume_suspended_input` restores those fields, then clears scanner caches
so acceleration uses the restored bytes.

Standalone generation embeds the helper for visible calls to `push_input` or
for `option :input_stack`. See [20261122_input_stack.md / Decision](../adr/20261122_input_stack.md#%E6%B1%BA%E5%AE%9A).

## Dynamic delimiters

`Flexr::Runtime#scan_delimiter` carries the length of the matched delimiter
prefix through each buffer read. A prefix fallback table lets it handle
overlapping occurrences without restarting the search. It checks the token
extent and charges guarded work before changing the cursor. On success the
normal match finalization updates coordinates and retains the `less` and
`more` semantics.

Standalone generation embeds the helper for visible delimiter calls or for
`option :dynamic_delimiters`. See [20261122_runtime_delimiters.md / Decision](../adr/20261122_runtime_delimiters.md#%E6%B1%BA%E5%AE%9A).

## Indentation

`Flexr::Runtime::Indentation` records leading spaces and tabs before the
buffer can discard them. Its token reader consumes the same visible stream
as the parser and keeps a scanned content token behind any layout tokens it
triggers. The input frame hooks save the layout queue, levels, and open
brackets with the suspended source.

Standalone generation includes the processor when the source declares
`indentation`. See [20261122_post_lexical_indentation.md / Decision](../adr/20261122_post_lexical_indentation.md#%E6%B1%BA%E5%AE%9A).

## Capture delegation

`Flexr::Runtime#delegate` reads the group's byte offsets from named capture
data. It scans a frozen slice with a child instance, rebases structured
locations and errors, and stages the result for the host rule.
`finish_delegation` transfers staged tokens to the host's output and lets
the layout processor treat the delegating rule as one content match.

Standalone generation embeds the helper for visible calls to `delegate` or
for `option :delegation`. A separately generated child loads against the
host's embedded runtime. See [20261122_capture_delegation.md / Decision](../adr/20261122_capture_delegation.md#%E6%B1%BA%E5%AE%9A).
