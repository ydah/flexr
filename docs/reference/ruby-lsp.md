# Ruby LSP integration

flexr includes an optional add-on for [Ruby LSP](https://shopify.github.io/ruby-lsp/add-ons.html).
It supports Ruby LSP `~> 0.26.11`; incompatible server versions skip activation.
The lexer runtime does not depend on Ruby LSP.

Keep flexr in the project's bundle and enable its linter in the editor's Ruby
LSP configuration. For VS Code, add `flexr` to the existing list:

```json
{
  "rubyLsp.linters": ["flexr"]
}
```

Keep any other linters you use in that array. Ruby LSP discovers the add-on
automatically. It displays flexr diagnostics for `.flexr.rb` files using the
current editor contents, including unsaved edits. Rule hovers show compiler
warnings, counterexamples, and overlap information. Diagnostics and hovers
use the static reader: they do not evaluate specifications or run actions.
Syntax errors are reported by Ruby LSP's Prism integration.

The add-on uses the same static specification subset as `flexr check`, so
dynamic Ruby DSL construction must be checked separately. Compilation is
cached for the most recent document contents. Timing-dependent `FLEXR-W016`
is omitted; other diagnostics include their help and notes. The add-on honors
the server's negotiated UTF-8, UTF-16, or UTF-32 position encoding.

To run the integration tests against the real Ruby LSP server:

```sh
BUNDLE_GEMFILE=gemfiles/ruby_lsp.gemfile bundle install
BUNDLE_GEMFILE=gemfiles/ruby_lsp.gemfile bundle exec rspec -Ilib -Ispec test/ruby_lsp_addon_spec.rb
```
