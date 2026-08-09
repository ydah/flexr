# ADR 0018: Prism is generator-only

Prism reads source during AOT generation. Runtime mode receives real Ruby
Regexp and Proc objects, so it remains dependency-free.
