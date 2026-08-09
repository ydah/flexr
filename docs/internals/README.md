# Internals

Both runtime and generated modes construct the same `IR::Spec`. The compiler
parses each supported regexp into an AST, expands Unicode code points to UTF-8
byte ranges, builds a Thompson NFA, determinizes it by byte class, and applies
deterministic minimization. The interpreter then records the last accepting
position to preserve leftmost-longest matching.

Generated files retain ordinary Ruby surrounding the DSL calls and embed the
compiled machines. The runtime source and the generated source intentionally
remain separate execution paths; `rake modes:equivalence` checks their token
streams against one another.

The packed table format stores row defaults plus displaced exceptions. The
direct backend uses an uncompressed row lookup, while `firstmatch` is retained
only for explicit compatibility use and requires `option :experimental`.
