# ADR 0017: Static generation by default

The generator resolves only deterministic expressions. Dynamic construction is
reported as `FLEXR-E017`; `--eval` is explicit because it executes user code
and can make output depend on the build environment.
