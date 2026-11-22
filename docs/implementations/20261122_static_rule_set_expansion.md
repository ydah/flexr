# Static rule-set expansion

`Flexr::Rules` records reusable declarations, and `use` adds them with new
indexes in the consumer's active states. `Flexr::Source::PrismReader` resolves
a named rule-set constant from a single module declaration that precedes
the use site and expands the rules declared directly in that module. The generated binding retains the original Ruby
action blocks and checks the rule-set declaration count at load time.

A rule-set constant selected dynamically or loaded from another file works
at runtime. The static reader reports unsupported forms at the argument or
declaration. Standalone generation includes rule-set support when the source
declares such a module. See [20261122_expand_reusable_rules_explicitly.md / Decision](../adr/20261122_expand_reusable_rules_explicitly.md#decision).
