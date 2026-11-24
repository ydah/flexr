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

| ADR | Summary |
| --- | --- |
| [Compile lexer transitions over bytes](20260809_byte_level_dfa.md) | One transition model handles UTF-8 and binary input and allows deterministic recovery from malformed UTF-8. |
| [Select the longest match at each input position by default](20260809_leftmost_longest.md) | Ranking includes trailing context in the match length, and the scanner consumes only the winning rule body. |
| [Keep DFA rule selection authoritative during acceleration](20260809_accel_not_scanner.md) | Fast paths may skip transitions when they preserve the DFA's selected rule, byte span, and scanning limits. |
| [Run lexers with Ruby and its standard library](20260809_what_pure_ruby_means.md) | Prism reads specifications at build time, and standalone output embeds the runtime for deployment. |
| [Use an internal Ruby DSL for lexer specifications](20260809_spec_is_plain_ruby.md) | Ordinary Ruby class bodies let specifications use constants, helper methods, and existing Ruby tooling. |
| [Generate from static source unless the caller requests evaluation](20260809_static_analysis_by_default.md) | Generation avoids executing source by default and offers `--eval` for trusted specifications with dynamic declarations. |
| [Use vendored Unicode data as the compatibility contract](20260810_vendored_unicode_contract.md) | A shared snapshot keeps Unicode properties and case folding consistent across host Ruby versions. |
| [Require Ruby 3.4 or later for flexr 2](20261122_ruby_34_minimum.md) | Runtime, generation, and standalone output share one Ruby minimum at the v2 upgrade boundary. |
| [Make structured tokens and locations immutable Ruby Data records](20261122_immutable_tokens_and_locations.md) | `Data` keeps emitted fields stable, and consumers use `with` to construct a record with changed fields. |
| [Support first-match selection as a stable explicit backend](20261122_stable_explicit_firstmatch.md) | An opt-in backend preserves source rule order and Ruby regexp alternative order for migrated lexers. |
| [Prepare generated lexers for Ractor sharing on request](20261122_opt_in_ractor_sharing.md) | `shareable!` lets applications choose when to incur the memory cost of preparing compiled data for multiple Ractors. |
| [Require explicit opt-in for whole-token acceleration](20261122_explicit_whole_token_acceleration.md) | `accel :strscan` is explicit because native scans can improve one workload and slow another. |
| [Define absence groups to match text with no forbidden substring](20261122_dfa_absence_groups.md) | `(?~X)` uses DFA semantics and accepts no input when `X` can match the empty string. |
| [Expose composable regular languages as immutable pattern values](20261122_pattern_algebra.md) | Pattern operators compose regular languages, and `upto` stops at the first completed terminator. |
| [Classify keywords after the base rule wins](20261122_classify_keywords_after_matching.md) | A keyword table remaps the winning identifier's token type while keeping its text and location. |
| [Preserve trivia without changing the default token stream](20261122_trivia_channels.md) | Named channels let formatters retain whitespace and comments while parsers consume the default channel. |
| [Apply explicit rule priority only to equal-length matches](20261122_explicit_rule_priority.md) | Compare length first, then declared priority and source order, so longer tokens still win. |
| [Recognize rules at a byte offset without running actions](20261122_action_free_recognition.md) | A parser can reuse the compiled DFA while retaining ownership of its input cursor. |
| [Restore a lexer with an opaque bookmark and seek by byte offset](20261122_lexer_checkpoints.md) | A bookmark saves scanner state, and restoration depends on the lexer still retaining the needed input bytes. |
| [Apply parser token expectations before selecting a rule](20261122_parser_token_expectations.md) | `expect:` limits eligible rules so a parser can distinguish division from a regexp literal at the same input position. |
| [Expose named captures from the selected rule body](20261122_named_captures_of_selected_rule.md) | Longest match chooses the rule body, then Ruby resolves ambiguous groups within that boundary. |
| [Suspend the parent input while a lexer scans an included source](20261122_input_stack.md) | Each included source keeps its own coordinates and EOF handling before the lexer resumes its parent. |
| [Let a rule action consume a delimiter chosen from the input](20261122_runtime_delimiters.md) | `scan_until` and `scan_until_line` can find heredoc-style terminators across streamed chunks. |
| [Emit indentation tokens from the parser-visible stream](20261122_post_lexical_indentation.md) | Visible newlines and bracket nesting determine layout tokens, with layout state saved in checkpoints. |
| [Delegate the exact captured source range to a child lexer](20261122_capture_delegation.md) | Child tokens retain host source coordinates and enter the host stream after the child scan succeeds. |
| [Insert reusable rules at each explicit use site](20261122_expand_reusable_rules_explicitly.md) | `use` fixes the expansion position so reusable declarations participate in the same tie-breaking rules as local ones. |
| [Preserve first-match order when importing oedipus_lex](20261122_import_oedipus_firstmatch.md) | The explicit import mode reports unsupported constructs before writing a specification. |
| [Build lexer DFAs from regular-expression derivatives](20261123_derivative_dfa_construction.md) | A derivative state records each rule's remaining byte language and preserves the lexer's token selection contract. |
| [Treat CRLF as one atomic match for the line-break escape](20261123_atomic_crlf_for_linebreak_escape.md) | A CR can match on its own only when its next byte is absent or differs from LF. |
| [Construct uncached runtime DFA transitions as input reaches them](20261123_on_demand_runtime_dfa.md) | Uncached table and direct scanners reuse transitions discovered during scanning. Inspection and caching use complete tables. |
| [Take a frozen snapshot of each mutable String input by default](20261123_snapshot_string_inputs.md) | A stable input lets scanners reuse work by byte position. Callers can opt out when they need live edits. |
| [Run ordinary longest-match scanning in linear time](20261123_linear_longest_match.md) | Cache failed DFA continuations at byte offsets so later tokens avoid rescanning the same suffix. |
