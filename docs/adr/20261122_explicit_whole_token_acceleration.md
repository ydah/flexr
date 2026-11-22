# ADR: Require explicit opt-in for whole-token acceleration

- Status: Accepted
- Decision date: 2026-11-22
- Related: [#65](https://github.com/ydah/flexr/pull/65), [#39](https://github.com/ydah/flexr/pull/39), [#77](https://github.com/ydah/flexr/pull/77), [20260809_accel_not_scanner.md / Decision](20260809_accel_not_scanner.md#decision)

## Context

`Flexr::Automaton::Accel.whole_token_plans` derives expressions from proven
ASCII DFA branches. `StringScanner#skip` can then advance by the same
longest accepted prefix as DFA traversal. In the
[2026-11-20 JSON benchmark](../perf-log.md#2026-11-20-whole-token-acceleration)
on Ruby 4.0.9, adding whole-token scans to explicit StringScanner mode
improved throughput on the interpreter and YJIT, while ZJIT runtime
throughput fell from 2.029 to 1.838 MB/s and generated throughput fell from
0.875 to 0.791 MB/s.

## Decision

Build whole-token plans only for explicit `accel :strscan`. Use the plans
where they preserve DFA matching and resource limits on eligible frozen
input. Fall back to DFA traversal elsewhere. Keep the default `accel :auto`
on DFA-based scanning with region acceleration available when appropriate.

## Alternatives considered

Enabling whole-token scans by default would give eligible applications a
speedup without a configuration change. The JSON result on ZJIT and the
[2026-11-22 cross-workload comparison](../perf-log.md#2026-11-22-whole-token-selection-by-engine-and-workload)
show that the same policy can slow supported workloads. Engine selection
alone would still group workloads where the attempts have different costs.

## Consequences

Applications can enable the optimization and measure their own lexer and
inputs. Equivalent matching remains a requirement, as established by the
decision in [20260809_accel_not_scanner.md / Decision](20260809_accel_not_scanner.md#decision).
The [backend explanation](../explanation/backends.md#acceleration-and-packing)
lists the eligibility rules.
