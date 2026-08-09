# States

Use `state :name do ... end`, then `push`, `pop`, or `begin_state` in an action.
State blocks are exclusive by default; `inclusive: true` also keeps initial
rules active.
