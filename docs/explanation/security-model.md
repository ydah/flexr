# Security model

flexr is a code generator, not a sandbox. A specification is ordinary Ruby and
its actions can perform any operation available to the Ruby process. Generated
files retain those actions as Ruby code.

Static generation parses the specification and evaluates only a constrained set
of literal and constant forms. This reduces accidental build-time execution but
does not make the generated artifact safe to load if its source is untrusted.

`--eval` is an explicit execution boundary: it evaluates the full specification
to discover dynamic patterns. Use it only with trusted files and a trusted
environment. The same rule applies to generated output: review or sign the
artifact before loading it in a process with sensitive access.

The runtime's `max_token_size`, `max_lookahead_size`, `max_buffer_size`,
`max_state_stack`, and optional `max_steps` limits provide resource guards for
input processing. A `cancellation` callback can stop concurrent work
cooperatively. Limits are checked while scanning, before an oversized token's
action runs. They are operational controls, not a security sandbox and do not
protect against arbitrary Ruby actions.

Use `retain_input: false` for long-lived streaming lexers that do not need the
complete input after consumption. This makes the buffer a sliding window;
`input` and `binary_input` no longer contain discarded prefixes.
