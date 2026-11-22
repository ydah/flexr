# ADR 0025: Keep whole-token acceleration opt-in

## Context

The compiler can derive a complete-token expression from a proven ASCII
DFA branch. Calling `StringScanner#skip` on that expression advances the
scanner by the same longest accepted prefix as DFA traversal.

The [2026-11-20 JSON benchmark](../perf-log.md#2026-11-20-whole-token-acceleration)
measured gains for explicit StringScanner mode on the interpreter and YJIT
after adding this optimization. On ZJIT the same comparison fell from 2.029
to 1.838 MB/s in runtime mode and from 0.875 to 0.791 MB/s in generated mode.
Those measurements describe the tested corpus and Ruby build.

## Decision

Build whole-token plans only for an explicit `accel :strscan` request. Use
the plans for proven branches on eligible frozen input and fall back to DFA
traversal otherwise. Preserve checks for streaming, resource limits, and
matching semantics. See the [backend explanation](../explanation/backends.md#acceleration-and-packing)
for the eligibility rules.

The default `accel :auto` continues to select region acceleration. Revisit
whole-token defaults when separate interpreter and JIT measurements justify
automatic selection. The DFA remains the matching contract described in
[ADR 0006](0006-accel-not-scanner.md).
