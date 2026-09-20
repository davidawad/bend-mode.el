# AGENTS.md — bend-mode.el

Standalone, publishable Emacs major mode for Bend 2
(https://github.com/bendlang/bend). Font-lock, indentation and Eglot wiring
live in `bend-mode.el`; the Flymake `--check-only` diagnostics backend is
the separate file `bend-mode-flymake.el` (`require` it separately) because
it is the piece most likely to need replacing outright once a real
compiler-backed Bend 2 LSP exists upstream.

## For agents

- Read `README.md` first; it is the complete feature and install reference.
- Tests: ERT in `test/bend-mode-test.el`. The Flymake tests exercise only
  the pure parsing functions (`bend-mode-flymake--parse` /
  `--block-message`) against canned output strings -- no `bend` process is
  spawned, so the whole suite runs offline with no toolchain installed. Run
  via `emacs -Q --batch -L . -l bend-mode.el -l bend-mode-flymake.el -l
  test/bend-mode-test.el -f ert-run-tests-batch-and-exit`.
- `checkdoc-file` and `batch-byte-compile` should both be silent on both
  source files before any change lands; check both after editing.
- The nested-block-comment behavior in `bend-mode-syntax-propertize` is a
  documented, deliberate approximation (simple toggle, not true nesting
  depth) -- read that function's own docstring in full before touching it;
  it also explains why `syntax-ppss` must never be called from inside a
  syntax-propertize function (a real footgun that hung this file's own
  test suite once during development).
- Zero references to the owner's dotfiles are allowed here -- the repo
  must remain publishable as-is. THIS repo is canonical; the owner's
  dotfiles Doom Emacs config imports it via load-path
  (`config/terminal/emacs/plugin-packs.el`'s `plugin-packs--require-external`)
  and carries no copy of the source. All changes land here.
- Authorized: david, swe.
