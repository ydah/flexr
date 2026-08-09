# ADR 0008: Meaning of Pure Ruby

Generated lexers and runtime mode use Ruby and its standard library only.
Prism is a generator-side dependency and is never needed to run generated
output.
