# Use states

States model lexical contexts such as strings, comments, or interpolation.
The initial state is inclusive; a named state is exclusive by default.

```ruby
class Lexer < Flexr::Lexer
  emits :TEXT, :STRING

  rule(/[^"<]+/) { emit :TEXT }
  rule(/"/) { push :string; more; skip }

  state :string do
    rule(/[^"\\]+/) { more; skip }
    rule(/"/) { pop; emit :STRING }
  end
end
```

`push(name)` saves the current state, `pop` restores it, and `begin_state(name)`
switches without changing the stack. `push_state`, `pop_state`, and `state=`
are aliases. An undefined state raises `FLEXR-E003`; exceeding
`max_state_stack` raises `StateStackOverflowError`.

Use `inclusive: true` when a state should also use rules declared for the
initial state:

```ruby
state :interpolation, inclusive: true do
  rule(/\}/) { pop; skip }
end
```

`all_states` applies a rule block to every state known at that point. Keep
state transitions in actions so the rule set remains easy to inspect with
`flexr explain`.
