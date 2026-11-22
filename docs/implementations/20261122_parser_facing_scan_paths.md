# Scan paths for recognition and expected tokens

## Recognizer

The public contract is in [20261122_action_free_recognition.md / Decision](../adr/20261122_action_free_recognition.md#decision).

`Flexr::Recognizer` holds the compiled DFA, trailing context tables, fixed rule identities, and rank information.
Construction materializes lazy generated rows for Ractor sharing.
It can share the snapshot independently of the lexer class and its actions.
At match time, local cursor variables avoid allocating lexer state.

On 2026-11-22, a warmed Ruby 4.0.9 measurement recorded 100,000 allocations for 100,000 successful tuple calls.
The block form recorded zero allocations on ASCII, multibyte, and trailing-context matches in the same measurement.

At the same revision, the generator included native scanning helpers in `firstmatch` standalones only.
The ordinary DFA standalone recognizer fixture measured 90,990 bytes with the helpers separated and 102,424 bytes with the helpers included.

## Expected tokens

The eligibility policy is in [20261122_parser_token_expectations.md / Decision](../adr/20261122_parser_token_expectations.md#decision).

`Runtime#next_token` preserves the generated scan path for unrestricted calls.
Filtered scans use `Runtime::Interpreter`, which checks the eligible candidates at each DFA acceptance or native first match.
The same lexer's step and size limits apply to the filtered path.

A same-ABI generated lexer already embeds enough DFA data for the updated runtime to filter rules that use `emit:`.
Newly generated artifacts carry explicit rule-level `emits:` annotations as optional metadata.
A previously generated standalone lexer must be regenerated to embed the updated runtime.
