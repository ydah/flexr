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

The runtime's `max_token_size` and `max_state_stack` limits provide resource
guards for input processing. They are operational controls, not a security
sandbox and do not protect against arbitrary Ruby actions.
