# Architecture decision records

Write an ADR when all three conditions hold.

- Reversing the decision would be costly. Public interfaces, file formats, and compatibility requirements usually have callers that must migrate.
- The reason would be surprising to a reader who only saw the code.
- The project chose between real alternatives with different trade-offs.

Record reversible implementation choices in the pull request or in [Implementation records](../implementations/README.md). Keep the decisions that callers rely on in the [public reference](../reference/README.md) as well.

## Naming and format

Use `YYYYMMDD_english_snake_case.md`, with the date the record was opened. For the older records in this index, the first recorded Git date supplies the filename and decision date when the original record has no separate date.

Write ADRs in English using this template. Omit either optional section when it has no content.

```markdown
# ADR: <State the decision in one sentence>

- Status: Proposed
- Decision date: YYYY-MM-DD
- Related: <Issues, pull requests, tickets, or ADR filenames>

## Context

<The specific problem in this repository and the constraints that affect the choice>

## Decision

<What the project chose, in active voice>

## Out of scope

<Optional. What is out of scope, with the record or ticket that owns it, or say the owner is undecided>

## Alternatives considered

<Optional. The alternatives considered and why the project declined them>

## Consequences

<Benefits, costs, and remaining consequences>
```

Use `Proposed` during review, `Accepted` after agreement, and `Rejected` for a declined proposal. Use `Superseded by` when a later ADR changes an accepted decision. Status records agreement on the decision.

```markdown
- Status: Proposed
- Status: Accepted
- Status: Rejected
- Status: Superseded by `YYYYMMDD_replacing_decision.md`
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
| D-1 | MUST | Add a new ADR to change an accepted decision. Set the old status to `Superseded by` followed by the new filename. Correct spelling and factual errors in place. |
| D-2 | SHOULD | Use the same terms as the existing ADRs, code, and user interfaces. |
| E-1 | SHOULD | Record dates and versions for time-sensitive facts. Leave update dates, assignees, and relative dates in planning records. |
| F-1 | MUST | Resolve open points or move them to the out-of-scope section before accepting the ADR. |

## Index

- [Compile lexer transitions over bytes](20260809_byte_level_dfa.md)
- [Select the longest match at each input position by default](20260809_leftmost_longest.md)
- [Keep DFA rule selection authoritative during acceleration](20260809_accel_not_scanner.md)
- [Run lexers with Ruby and its standard library](20260809_what_pure_ruby_means.md)
- [Use an internal Ruby DSL for lexer specifications](20260809_spec_is_plain_ruby.md)
- [Generate from static source unless the caller requests evaluation](20260809_static_analysis_by_default.md)
- [Use vendored Unicode data as the compatibility contract](20260810_vendored_unicode_contract.md)
- [Require Ruby 3.4 or later for flexr 2](20261122_ruby_34_minimum.md)
- [Make structured tokens and locations immutable Ruby Data records](20261122_immutable_tokens_and_locations.md)
- [Support first-match selection as a stable explicit backend](20261122_stable_explicit_firstmatch.md)
- [Prepare generated lexers for Ractor sharing on request](20261122_opt_in_ractor_sharing.md)
- [Require explicit opt-in for whole-token acceleration](20261122_explicit_whole_token_acceleration.md)
- [Define absence groups to match text with no forbidden substring](20261122_dfa_absence_groups.md)
- [Expose composable regular languages as immutable pattern values](20261122_pattern_algebra.md)
- [Classify keywords after the base rule wins](20261122_classify_keywords_after_matching.md)
- [Preserve trivia without changing the default token stream](20261122_trivia_channels.md)
- [Apply explicit rule priority only to equal-length matches](20261122_explicit_rule_priority.md)
- [Recognize rules at a byte offset without running actions](20261122_action_free_recognition.md)
- [Restore a lexer with an opaque bookmark and seek by byte offset](20261122_lexer_checkpoints.md)
- [Apply parser token expectations before selecting a rule](20261122_parser_token_expectations.md)
- [Expose named captures from the selected rule body](20261122_named_captures_of_selected_rule.md)
- [Suspend the parent input while a lexer scans an included source](20261122_input_stack.md)
- [Let a rule action consume a delimiter chosen from the input](20261122_runtime_delimiters.md)
- [Emit indentation tokens from the parser-visible stream](20261122_post_lexical_indentation.md)
- [Delegate the exact captured source range to a child lexer](20261122_capture_delegation.md)
- [Insert reusable rules at each explicit use site](20261122_expand_reusable_rules_explicitly.md)
- [Preserve first-match order when importing oedipus_lex](20261122_import_oedipus_firstmatch.md)
