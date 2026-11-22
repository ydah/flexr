# Try the Playground demos

Each link loads a lexer specification and its input. Select **Run** to inspect
the tokens, diagnostics, and match decisions.

- [Stop at the first closing comment delimiter](https://ydah.github.io/flexr/playground/#eyJzb3VyY2UiOiJjbGFzcyBMZXhlciA8IEZsZXhyOjpMZXhlclxuICBydWxlKCVyey9cXCooP35cXCovKVxcKi99LCBlbWl0OiA6Q09NTUVOVClcbiAgcnVsZSgvICsvLCBza2lwOiB0cnVlKVxuZW5kIiwiaW5wdXQiOiIvKiBmaXJzdCAqLyAvKiBzZWNvbmQgKi8iLCJtb2RlIjoiZ2VuZXJhdGVkIn0).
  The absence group stops each comment at its own closing delimiter.
- [Reproduce the shadowed `if` rule](https://ydah.github.io/flexr/playground/#eyJzb3VyY2UiOiJjbGFzcyBMZXhlciA8IEZsZXhyOjpMZXhlclxuICBydWxlKC9bYS16XSsvLCBlbWl0OiA6SURFTlQpXG4gIHJ1bGUoXCJpZlwiLCBlbWl0OiA6SUYpXG5lbmQiLCJpbnB1dCI6ImlmIiwibW9kZSI6ImdlbmVyYXRlZCJ9).
  The diagnostic gives `if` as an example because the earlier identifier rule wins a tie.
- [Subtract the keyword from the identifier pattern](https://ydah.github.io/flexr/playground/#eyJzb3VyY2UiOiJjbGFzcyBMZXhlciA8IEZsZXhyOjpMZXhlclxuICBJREVOVCA9IHBhdHRlcm4oL1thLXpdKy8pXG4gIEtFWVdPUkQgPSBwYXR0ZXJuKFwiaWZcIilcbiAgcnVsZShJREVOVCAtIEtFWVdPUkQsIGVtaXQ6IDpJREVOVClcbiAgcnVsZShLRVlXT1JELCBlbWl0OiA6SUYpXG4gIHJ1bGUoLyArLywgc2tpcDogdHJ1ZSlcbmVuZCIsImlucHV0IjoiaWYgaWZmeSIsIm1vZGUiOiJnZW5lcmF0ZWQifQ).
  The same input rule can still recognize longer identifiers such as `iffy`.

The absence and subtraction demos require flexr 2.1 or later.
