# Runtime versus generated

Both modes begin with the same DSL concepts and compile to the same IR-shaped
rule and state model, but they serve different operational needs.

| Concern | Runtime | Generated |
|---|---|---|
| Specification | Evaluated by Ruby | Read statically with Prism by default |
| DFA construction | First class use | Build time |
| Dynamic pattern methods | Available | Requires trusted `--eval` |
| Startup cost | Includes compilation | Loads compiled payload |
| Action code | Ruby block | Ruby source preserved in artifact |
| Prism at runtime | Not needed | Not needed after generation |

Keeping actions as Ruby is deliberate: semantic work belongs in the user's
action, while flexr owns rule selection and token boundaries. It also means
that generated files are executable code and must be treated as trusted build
artifacts.

The generated header and payload digest make artifact provenance visible. The
repository's mode-equivalence checks execute each example in both modes and
compare token streams.
