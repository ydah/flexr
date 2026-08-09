# Static evaluation

Literals, arrays, constants, `.freeze`, and `Regexp.union` are static. Dynamic
method calls receive `FLEXR-E017`; runtime mode still supports them.
