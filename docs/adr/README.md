# Architecture decision records

Write an ADR when all three conditions hold.

- Reversing the decision would be costly. Public interfaces, file formats, and compatibility requirements usually have callers that must migrate.
- The reason would be surprising to a reader who only saw the code.
- The project chose between real alternatives with different trade-offs.

Record reversible implementation choices in the pull request or in [Implementation records](../implementations/README.md). Keep the decisions that callers rely on in the [public reference](../reference/README.md) as well.

## Naming and format

Use `YYYYMMDD_english_snake_case.md`, with the date the record was opened. For the older records in this index, the first recorded Git date supplies the filename and decision date when the original record has no separate date.

Use English prose with the fixed template labels below. Omit either optional section when it has no content.

```markdown
# ADR: <State the decision in one sentence>

- ステータス: 提案
- 決定日: YYYY-MM-DD
- 関連: <Issues, pull requests, tickets, or ADR filenames>

## コンテキスト

<The specific problem in this repository and the constraints that affect the choice>

## 決定

<What the project chose, in active voice>

## 決定しないこと

<Optional. What is out of scope, with the record or ticket that owns it, or say the owner is undecided>

## 検討した代替案

<Optional. The alternatives considered and why the project declined them>

## 影響

<Benefits, costs, and remaining consequences>
```

Use a proposed status during review, accepted after agreement, rejected for a declined proposal, and replaced when a later ADR changes an accepted decision. A status describes agreement on the decision. Use these forms in that order.

```markdown
- ステータス: 提案
- ステータス: 採用
- ステータス: 却下
- ステータス: 置換 → `YYYYMMDD_replacing_decision.md`
```

## Review checklist

MUST rules are required. For a SHOULD rule, explain any exception in the pull request.

| Rule | Level | Requirement |
| --- | --- | --- |
| A-1 | MUST | Put issue, pull request, and ticket numbers in the related field. State the facts someone needs in the body. |
| A-2 | MUST | Refer to code by its class, method, or constant. Line numbers drift. |
| A-3 | SHOULD | Refer to another ADR by filename and link to the relevant section. |
| B-1 | MUST | Check facts against the repository or a primary source. Include the gem version and the class or method when describing gem behavior. |
| B-2 | MUST | Give enough evidence and reasoning for a reader to understand the decision from the ADR itself. Record facts that a third party can verify. |
| B-3 | SHOULD | Describe the concrete problem that occurred in this repository and the constraints on solving it. |
| C-1 | MUST | Keep implementation plans, progress, task lists, and commit lists in the pull request or implementation record. |
| C-2 | SHOULD | Describe public contracts and persistent formats at the level someone must preserve when replacing the implementation. |
| C-3 | SHOULD | State scope and indicate the issue or ADR that owns an excluded decision. Say the owner is undecided when there is no known record. |
| C-4 | SHOULD | Explain the alternatives that were considered and why they were declined. |
| D-1 | MUST | Add a new ADR to change an accepted decision. Mark the old status as replaced and point to the new filename. Correct spelling and factual errors in place. |
| D-2 | SHOULD | Use the same terms as the existing ADRs, code, and user interfaces. |
| E-1 | SHOULD | Record dates and versions for time-sensitive facts. Leave update dates, assignees, and relative dates in planning records. |
| F-1 | MUST | Resolve open points or move them to the out-of-scope section before accepting the ADR. |

## Index

The previous filenames are listed here for readers following historical references. The [v2.2.0 ADR directory](https://github.com/ydah/flexr/tree/v2.2.0/docs/adr) contains the original records.

| Previous file | Record |
| --- | --- |
| `0001-byte-level-dfa.md` | [Compile lexer transitions over bytes](20260809_byte_level_dfa.md) |
| `0003-leftmost-longest.md` | [Select the longest match at each input position by default](20260809_leftmost_longest.md) |
| `0006-accel-not-scanner.md` | [Keep DFA rule selection authoritative during acceleration](20260809_accel_not_scanner.md) |
| `0008-what-pure-ruby-means.md` | [Run lexers with Ruby and its standard library](20260809_what_pure_ruby_means.md) |
| `0016-spec-is-plain-ruby.md` | [Use an internal Ruby DSL for lexer specifications](20260809_spec_is_plain_ruby.md) |
| `0017-static-analysis-by-default.md` | [Generate from static source unless the caller requests evaluation](20260809_static_analysis_by_default.md) |
| `0018-prism-for-generator-only.md` | [Run lexers with Ruby and its standard library](20260809_what_pure_ruby_means.md) |
| `0019-measured-performance-floor.md` | [Measured performance floor for the pure-Ruby backend](../implementations/20260810_measured_performance_floor.md) |
| `0020-vendored-unicode-contract.md` | [Use vendored Unicode data as the compatibility contract](20260810_vendored_unicode_contract.md) |
| `0021-ruby-34-minimum.md` | [Require Ruby 3.4 or later for flexr 2](20261122_ruby_34_minimum.md) |
| `0022-immutable-tokens-and-locations.md` | [Make structured tokens and locations immutable Ruby Data records](20261122_immutable_tokens_and_locations.md) |
| `0023-stable-explicit-firstmatch.md` | [Support first-match selection as a stable explicit backend](20261122_stable_explicit_firstmatch.md) |
| `0024-opt-in-ractor-sharing.md` | [Prepare generated lexers for Ractor sharing on request](20261122_opt_in_ractor_sharing.md) |
| `0025-explicit-whole-token-acceleration.md` | [Require explicit opt-in for whole-token acceleration](20261122_explicit_whole_token_acceleration.md) |
| `0026-retain-direct-dispatch.md` | [Retain direct dispatch after the state cases experiment](../implementations/20261122_retain_direct_dispatch.md) |
| `0027-per-engine-performance-targets.md` | [Set performance targets per Ruby engine](../implementations/20261122_per_engine_performance_targets.md) |
| `0028-dfa-absence-groups.md` | [Define absence groups to match text with no forbidden substring](20261122_dfa_absence_groups.md) |
| `0029-pattern-algebra.md` | [Expose composable regular languages as immutable pattern values](20261122_pattern_algebra.md) |
| `0030-classify-keywords-after-matching.md` | [Classify keywords after the base rule wins](20261122_classify_keywords_after_matching.md) |
| `0031-trivia-channels.md` | [Preserve trivia without changing the default token stream](20261122_trivia_channels.md) |
| `0032-explicit-rule-priority.md` | [Apply explicit rule priority only to equal-length matches](20261122_explicit_rule_priority.md) |
| `0033-action-free-recognition.md` | [Recognize rules at a byte offset without running actions](20261122_action_free_recognition.md) |
| `0034-lexer-checkpoints.md` | [Restore a lexer with an opaque bookmark and seek by byte offset](20261122_lexer_checkpoints.md) |
| `0035-parser-token-expectations.md` | [Apply parser token expectations before selecting a rule](20261122_parser_token_expectations.md) |
| `0038-replay-named-regexp-captures.md` | [Expose named captures from the selected rule body](20261122_named_captures_of_selected_rule.md) |
| `0039-input-stack.md` | [Suspend the parent input while a lexer scans an included source](20261122_input_stack.md) |
| `0040-runtime-delimiters.md` | [Let a rule action consume a delimiter chosen from the input](20261122_runtime_delimiters.md) |
| `0041-post-lexical-indentation.md` | [Emit indentation tokens from the parser-visible stream](20261122_post_lexical_indentation.md) |
| `0042-capture-delegation.md` | [Delegate the exact captured source range to a child lexer](20261122_capture_delegation.md) |
| `0043-expand-reusable-rules-explicitly.md` | [Insert reusable rules at each explicit use site](20261122_expand_reusable_rules_explicitly.md) |
| `0044-import-oedipus-firstmatch.md` | [Preserve first-match order when importing oedipus_lex](20261122_import_oedipus_firstmatch.md) |
