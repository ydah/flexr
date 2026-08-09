# Performance

Measure before changing backends. `token_kind :yield` avoids the token array
when consuming through `each_token`; region extraction is available through
`Flexr::Automaton::Accel`.
