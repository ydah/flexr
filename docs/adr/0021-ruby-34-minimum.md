# ADR 0021: Require Ruby 3.4 for v2

## Context

The v1 runtime supported Ruby 3.1 and the generator had a separate Ruby 3.3
minimum. Version 2 changes the runtime contracts for structured tokens and
generated artifacts. That major release gives us one upgrade point for Ruby
and artifact compatibility.

## Decision

Require Ruby 3.4 or newer for the runtime, generator, and standalone output.
Set the gem's Ruby requirement and the CI minimum to the same version. Run a
generated-only check at that minimum so the deployment path is tested
independently of the generator.

Prism remains a build-time dependency for the generator, as described in
[ADR 0018](0018-prism-for-generator-only.md). Alternate Ruby implementations
must meet the same language requirement. Support is tracked in the
[compatibility reference](../reference/compatibility.md).

Upgrade Ruby before installing flexr 2 and regenerate existing lexers as
described in the [migration guide](../migration-v2.md).
