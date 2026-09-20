;;; bend-mode.el --- Major mode for Bend 2 -*- lexical-binding: t; -*-

;; Author: David Awad <angrybohr@protonmail.com>
;; Maintainer: David Awad <angrybohr@protonmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: languages
;; URL: https://github.com/davidawad/bend-mode.el

;; This file is not part of GNU Emacs.

;; MIT License; see LICENSE in this package's directory for the full text.

;;; Commentary:

;; A major mode for Bend 2 (https://github.com/bendlang/bend), a
;; dependently typed, affine, Python-shaped language whose compiler
;; targets native CPU, Metal/CUDA and JS.  Bend 2 is a fresh rewrite (the
;; whole editor ecosystem that existed for Bend 1 -- tree-sitter, VS
;; Code, Zed, Neovim, IntelliJ -- targets the old syntax and does not
;; apply) and, as of 2.0.22, ships only a Sublime Text grammar and a
;; formatting-only language server (`bend2-fmt-lsp', not yet on any
;; package registry -- build it from tools/bend-fmt-lsp in the bend
;; checkout).  This mode is believed to be the first Emacs support Bend
;; has had in either version.
;;
;; Provides:
;; - Syntax highlighting: comments (line `#...' and block `#{ ... #}',
;;   depth-aware for arbitrarily nested pairs -- see
;;   `bend-mode-syntax-propertize'), strings, char literals, keywords,
;;   the `def NAME'/`law NAME' binding,
;;   uppercase type/constructor names, numeric literals (`U32', `F32',
;;   `Nat' with its `n' suffix), quantity markers (`&0' `&1' `&2'), and
;;   `?hole'/`?TODO' goals.
;; - Indentation: a plain "copy the previous line, add one level after a
;;   trailing `:'" rule, matching Bend 2's Python-shaped off-side blocks.
;;   It does not attempt smart dedent (e.g. aligning a new `case' with
;;   its siblings) -- see bend-mode-flymake.el's file header and the
;;   README's Roadmap for what a v2 would add.
;; - Eglot: registers `bend2-fmt-lsp --stdio' for `bend-mode' so
;;   `M-x eglot' + `eglot-format-buffer' formats on demand once that
;;   server is on PATH (it exposes no diagnostics/completion/hover by
;;   design -- see its own README).
;;
;; Flymake diagnostics (parses `bend FILE --check-only' output) live in
;; the sibling file bend-mode-flymake.el -- `require' it separately.

;;; Code:

(require 'eglot nil t)

(defgroup bend nil
  "Major mode for the Bend 2 programming language."
  :group 'languages
  :prefix "bend-mode-")

(defcustom bend-mode-indent-offset 2
  "Number of columns to indent a block under a line ending in `:'.

Every example in Bend's own guide and grammar uses two spaces; there is
no reason to deviate absent a project convention."
  :type 'integer
  :safe #'integerp
  :group 'bend)

(defcustom bend-mode-command "bend"
  "Name or path of the `bend' executable, used by bend-mode-flymake.el.

Set to an absolute path if `~/.bend/bin' (bend's own installer's default
location) is not on the variable `exec-path'."
  :type 'string
  :group 'bend)

;;; Syntax table

(defvar bend-mode-syntax-table
  (let ((table (make-syntax-table)))
    ;; Single-line `# ...' comments: the common case, handled entirely
    ;; by the syntax table (no propertize needed).  The nested block
    ;; form `#{ ... #}' overrides these two chars via
    ;; `bend-mode-syntax-propertize' below -- text properties win over
    ;; the table, so both forms coexist.
    (modify-syntax-entry ?# "<" table)
    (modify-syntax-entry ?\n ">" table)
    ;; Strings and escapes.
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?\\ "\\" table)
    ;; Punctuation, not symbol constituents -- keeps `forward-word' and
    ;; font-lock word-boundary regexps from swallowing operators.
    (dolist (ch '(?+ ?- ?* ?/ ?% ?< ?> ?= ?& ?| ?! ?@ ?~))
      (modify-syntax-entry ch "." table))
    ;; `.' and `_' are legal inside an identifier (`U32.add', `foo_bar').
    (modify-syntax-entry ?_ "_" table)
    (modify-syntax-entry ?. "_" table)
    (modify-syntax-entry ?\{ "(}" table)
    (modify-syntax-entry ?\} "){" table)
    (modify-syntax-entry ?\[ "(]" table)
    (modify-syntax-entry ?\] ")[" table)
    (modify-syntax-entry ?\( "()" table)
    (modify-syntax-entry ?\) ")(" table)
    table)
  "Syntax table for `bend-mode'.")

(defun bend-mode-syntax-propertize (start end)
  "Syntax-propertize function for `bend-mode', covering START to END.

Marks the leading `#' of each `#{'/`#}' delimiter with Emacs's
generic-comment syntax class `!' (`(string-to-syntax \"!\")'), so
`#{ ... #}' delimits a block comment instead of `#' alone reading as
a line comment.  The `{'/`}' half of each delimiter is deliberately
left with its ordinary paren-matching class from
`bend-mode-syntax-table', since `{'/`}' are also real Bend syntax
outside a comment (`K{x, y}').

Bend 2 allows `#{ ... #}' to nest arbitrarily deep, so this is a
depth-aware scan, not a flat per-occurrence toggle: it finds each
outermost `#{' (one not already inside a pair currently being
tracked), then scans forward counting nested `#{'/`#}' occurrences
until the count returns to zero at that opener's true matching `#}'
-- or end of buffer, for an unterminated comment, which is handled by
simply not marking a closer rather than erroring (the buffer then
reads as one open comment through EOF).  Only the outermost opener's
`#' and its true matching closer's `#' are marked; every
`#{'/`#}' strictly between them is left with no `syntax-table'
property at all.  That is sufficient: once the outer pair correctly
toggles comment state, Emacs's own scanner treats everything between
the two marked characters as comment body, nested delimiters
included, with no further special-casing needed.  The scan then
resumes after the matched close, looking for the next outermost
`#{'.

START and END are intentionally unused: rather than reason through
syntax-propertize's incremental-region contract (a call for one
region may still need context from before it, or a match past it, to
classify correctly under arbitrary nesting), this rescans the whole
buffer from `point-min' on every call, clearing and reapplying every
`syntax-table' property this function owns first.  That trades a
little performance for straightforward correctness, an acceptable
tradeoff for the small files this mode targets.

Also deliberately does not special-case a `#{'/`#}' written inside a
string literal (`\"a #{ b\"): calling `syntax-ppss' from inside a
syntax-propertize function to ask about a position at or past START
recurses back into this very function (it re-runs syntax-propertize to
catch its cache up to point first) -- a documented footgun, not an
oversight; an earlier version of this function called `syntax-ppss'
for exactly this check and hung the ERT suite outright.  A comment
delimiter inside a real Bend string is rare enough that the tradeoff
is accepted."
  (ignore start end)
  (remove-text-properties (point-min) (point-max) '(syntax-table nil))
  (goto-char (point-min))
  (while (re-search-forward "#{" nil t)
    (let ((open-start (match-beginning 0))
          (depth 1)
          (close-start nil))
      (while (and (> depth 0) (re-search-forward "#{\\|#}" nil t))
        (if (string= (match-string 0) "#{")
            (setq depth (1+ depth))
          (setq depth (1- depth))
          (when (zerop depth)
            (setq close-start (match-beginning 0)))))
      (put-text-property open-start (1+ open-start)
                          'syntax-table (string-to-syntax "!"))
      (when close-start
        (put-text-property close-start (1+ close-start)
                            'syntax-table (string-to-syntax "!"))))))

;;; Font lock

(defconst bend-mode--keywords
  '("def" "law" "type" "is" "match" "case" "do" "return" "for" "exs"
    "where" "import" "as" "@unsafe")
  "Bend 2's reserved words.
From LANGUAGE-CORE's grammar summary and
bend2/docs/bend.sublime-syntax's `keyword.control.bend' scope.")

(defconst bend-mode--storage-types
  '("Type" "Data" "Kind" "Quant")
  "The kind-former keywords -- `storage.type.bend' in the shipped grammar.")

(defvar bend-mode-font-lock-keywords
  `(;; `def NAME' / `law NAME' -- the binding being introduced.
    (,(rx symbol-start (or "def" "law") (1+ space)
          (group (1+ (or word (syntax symbol)))))
     1 font-lock-function-name-face)
    ;; `type NAME' likewise, though the bare uppercase rule below would
    ;; also catch it -- kept explicit to match the shipped grammar 1:1.
    (,(rx symbol-start "type" (1+ space)
          (group (1+ (or word (syntax symbol)))))
     1 font-lock-type-face)
    (,(regexp-opt bend-mode--keywords 'symbols) . font-lock-keyword-face)
    (,(regexp-opt bend-mode--storage-types 'symbols) . font-lock-type-face)
    ;; `?goal' / `?TODO' -- an open hole, always worth flagging.  Must
    ;; come before the bare-uppercase rule below: `TODO' alone also
    ;; matches that rule, and font-lock's default (no OVERRIDE) keeps
    ;; whichever face a position got from the first matching rule in
    ;; this list, not the last.
    (,(rx "?" symbol-start (1+ (or word (syntax symbol))))
     . font-lock-warning-face)
    ;; A bare uppercase-leading identifier is a type or a constructor
    ;; name in every Bend program -- `Nat', `U32', `Cons', `Base.Some',
    ;; a user's own `type Job is ...' names, all share this shape.
    (,(rx symbol-start upper-case (0+ (or word (syntax symbol))))
     . font-lock-type-face)
    ;; Quantity markers `&0' `&1' `&2' and the `<&>' minimum operator's
    ;; operands read the same way as the Nat-literal rule below.
    (,(rx "&" (any "012") symbol-end) . font-lock-constant-face)
    ;; `3n' (Nat), `42' (U32), `1.5' (F32) -- deliberately excludes a
    ;; leading `-'/`+': LANGUAGE-CORE is explicit that a glued sign
    ;; heads a binder or literal, never reads as this token.
    (,(rx symbol-start (1+ digit) (opt "n") symbol-end)
     . font-lock-constant-face)
    (,(rx symbol-start (1+ digit) "." (1+ digit)
          (opt (any "eE") (opt (any "+-")) (1+ digit)) symbol-end)
     . font-lock-constant-face)
    ;; `'c'` / `'\n'` char literals -- the syntax table leaves `'' as
    ;; punctuation (a lone apostrophe is not reserved), so this is
    ;; fontified by pattern rather than by string syntax.
    (,(rx "'" (or (seq "\\" anychar) (not (any "'\\"))) "'")
     . font-lock-string-face))
  "Font-lock keyword table for `bend-mode'.")

;;; Indentation

(defun bend-mode--previous-code-line ()
  "Move point to the previous non-blank, non-comment-only line.
Return that line's indentation, or 0 at the buffer start."
  (forward-line -1)
  (while (and (not (bobp))
              (save-excursion
                (back-to-indentation)
                (or (eolp) (eq (char-after) ?#))))
    (forward-line -1))
  (if (bobp) 0 (current-indentation)))

(defun bend-mode-indent-line ()
  "Indent the current line for `bend-mode'.

Bend 2's blocks are Python-shaped off-side blocks: this copies the
previous code line's indentation, adding one `bend-mode-indent-offset'
level when that line's trailing (comment-stripped) text ends in `:'.
It never dedents automatically -- typing a `case' back out to align
with an earlier sibling, or closing a block, is a manual
`indent-line-to'/`<backtab>', the same tradeoff most first-cut
indentation-sensitive modes make.  See the README Roadmap."
  (interactive)
  (let ((indent
         (save-excursion
           (let ((prev-indent (bend-mode--previous-code-line)))
             (end-of-line)
             (if (save-excursion
                   (skip-chars-backward " \t")
                   (eq (char-before) ?:))
                 (+ prev-indent bend-mode-indent-offset)
               prev-indent))))
        (offset (- (current-column) (current-indentation))))
    (indent-line-to (max indent 0))
    (when (> offset 0) (forward-char offset))))

;;; Eglot

(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '(bend-mode . ("bend2-fmt-lsp" "--stdio"))))

;;; Mode definition

;;;###autoload
(define-derived-mode bend-mode prog-mode "Bend"
  "Major mode for editing Bend 2 (https://github.com/bendlang/bend)."
  :syntax-table bend-mode-syntax-table
  (setq-local font-lock-defaults '(bend-mode-font-lock-keywords))
  (setq-local syntax-propertize-function #'bend-mode-syntax-propertize)
  (setq-local comment-start "# ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "#+[ \t]*")
  (setq-local indent-line-function #'bend-mode-indent-line)
  (setq-local indent-tabs-mode nil))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.bend\\'" . bend-mode))

(provide 'bend-mode)

;;; bend-mode.el ends here
