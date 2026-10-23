;;; bend-ts-mode.el --- Tree-sitter major mode for Bend 2 -*- lexical-binding: t; -*-

;; Author: David Awad <angrybohr@protonmail.com>
;; Maintainer: David Awad <angrybohr@protonmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (bend-mode "0.1.0"))
;; Keywords: languages tree-sitter
;; URL: https://github.com/davidawad/bend-mode.el

;; This file is not part of GNU Emacs.

;; MIT License; see LICENSE in this package's directory for the full text.

;;; Commentary:

;; `bend-ts-mode' is the tree-sitter flavor of `bend-mode', built on
;; tree-sitter-bend2 (https://github.com/davidawad/tree-sitter-bend2).
;; It derives from `bend-mode', so it inherits that mode's keymap,
;; syntax table, comment settings, Eglot wiring (`bend2-fmt-lsp') and
;; Flymake backend (through `bend-mode-hook'), and replaces:
;;
;; - font-lock with `treesit-font-lock-settings' covering the same
;;   faces as the regex mode (plus parameters, operators and
;;   punctuation at the higher font-lock levels);
;; - indentation with `treesit-simple-indent-rules': block items
;;   (statements, `case' clauses, constructors, ...) indent one
;;   `bend-mode-indent-offset' under the line that opens their block,
;;   which also dedents correctly; a blank new line, a comment line,
;;   or code the parser could not make sense of falls back to the regex
;;   mode's rule (copy the previous code line, one level deeper after a
;;   trailing `:');
;; - Imenu (defs, types, laws) and defun navigation
;;   (`beginning-of-defun', `end-of-defun', `mark-defun').
;;
;; The grammar is pinned to `bend-ts-mode-grammar-revision' through
;; `treesit-language-source-alist'.  Install it with
;; \\[bend-ts-mode-install-grammar].  Until it is installed, opening a
;; `.bend' file falls back to the regex `bend-mode'
;; (`bend-ts-mode-maybe'); calling `bend-ts-mode' directly without the
;; grammar signals an error that names the installer.

;;; Code:

(require 'bend-mode)
(require 'treesit nil t)
(require 'rx)

(declare-function treesit-ready-p "treesit")
(declare-function treesit-node-type "treesit")
(declare-function treesit-node-text "treesit")
(declare-function treesit-node-child-by-field-name "treesit")
(declare-function treesit-parser-create "treesit")
(declare-function treesit-font-lock-rules "treesit")
(declare-function treesit-major-mode-setup "treesit")
(declare-function treesit-install-language-grammar "treesit")
(declare-function treesit-language-available-p "treesit")
(defvar treesit-language-source-alist)
(defvar treesit-load-name-override-list)
(defvar treesit-font-lock-settings)
(defvar treesit-font-lock-feature-list)
(defvar treesit-simple-indent-rules)
(defvar treesit-defun-type-regexp)
(defvar treesit-defun-name-function)
(defvar treesit-thing-settings)
(defvar treesit-simple-imenu-settings)

;;; Grammar

(defconst bend-ts-mode-grammar-url
  "https://github.com/davidawad/tree-sitter-bend2"
  "Git repository of the tree-sitter-bend2 grammar.")

(defconst bend-ts-mode-grammar-revision
  "8ad225d157f7409b59c995a11a86908123b9b20c"
  "Revision of tree-sitter-bend2 this mode's queries are written against.
This is the head of the grammar's main branch at the time of writing;
bump it together with the queries below.")

;; The grammar's language name is `bend2' (the C symbol is
;; `tree_sitter_bend2'), but Emacs-side the language is `bend', matching
;; the mode name.
(when (boundp 'treesit-language-source-alist)
  (unless (assq 'bend treesit-language-source-alist)
    (push `(bend ,bend-ts-mode-grammar-url ,bend-ts-mode-grammar-revision "src")
          treesit-language-source-alist)))

(when (boundp 'treesit-load-name-override-list)
  (unless (assq 'bend treesit-load-name-override-list)
    (push '(bend "libtree-sitter-bend" "tree_sitter_bend2")
          treesit-load-name-override-list)))

(defun bend-ts-mode-grammar-available-p ()
  "Return non-nil if Emacs can load the Bend tree-sitter grammar."
  (and (fboundp 'treesit-available-p)
       (treesit-available-p)
       (treesit-language-available-p 'bend)))

;;;###autoload
(defun bend-ts-mode-install-grammar ()
  "Download and build the Bend tree-sitter grammar.
Clones tree-sitter-bend2 at `bend-ts-mode-grammar-revision' and compiles
it with the system C compiler into the `tree-sitter' directory under
`user-emacs-directory'.  Needs git and a C compiler."
  (interactive)
  (unless (and (fboundp 'treesit-available-p) (treesit-available-p))
    (user-error "This Emacs was built without tree-sitter support"))
  (dolist (tool '("git"))
    (unless (executable-find tool)
      (user-error "Cannot install the Bend grammar: `%s' not found" tool)))
  (unless (or (executable-find "cc") (executable-find "gcc")
              (executable-find "clang"))
    (user-error "Cannot install the Bend grammar: no C compiler found"))
  (treesit-install-language-grammar 'bend))

;;; Font lock

(defconst bend-ts-mode--keywords
  '("def" "law" "type" "is" "match" "case" "do" "return" "for" "exs"
    "where" "import" "as")
  "Keyword tokens of tree-sitter-bend2; `@unsafe' is its own node.")

(defconst bend-ts-mode--operators
  '("=" "=>" "->" "<-" "+" "-" "*" "/" "%" "==" "!=" "<=" ">=" "<" ">"
    "&&" "||" "<>" "++" ".|." ".^." ".&." "<<" ">>" "<&>" "&" "|" "~"
    "!" "@")
  "Operator tokens of tree-sitter-bend2.")

(defvar bend-ts-mode--font-lock-settings
  (when (fboundp 'treesit-font-lock-rules)
    (treesit-font-lock-rules
     :language 'bend
     :feature 'comment
     '([(comment) (block_comment)] @font-lock-comment-face)

     :language 'bend
     :feature 'definition
     '((def_declaration name: (_) @font-lock-function-name-face)
       (law_declaration name: (_) @font-lock-function-name-face)
       (type_declaration name: (_) @font-lock-type-face))

     :language 'bend
     :feature 'keyword
     `([,@bend-ts-mode--keywords] @font-lock-keyword-face
       (unsafe_annotation) @font-lock-keyword-face)

     :language 'bend
     :feature 'string
     '([(string_literal) (char_literal)] @font-lock-string-face)

     :language 'bend
     :feature 'hole
     '((hole) @font-lock-warning-face)

     :language 'bend
     :feature 'type
     '(["Type" "Data" "Kind" "Quant"] @font-lock-type-face
       (constructor_definition name: (_) @font-lock-type-face)
       (constructor_expression name: (_) @font-lock-type-face)
       (constructor_pattern name: (_) @font-lock-type-face)
       ((identifier) @font-lock-type-face
        (:match "\\`[A-Z]" @font-lock-type-face)))

     :language 'bend
     :feature 'constant
     '([(nat_literal) (u32_literal) (float_literal) (quantity)]
       @font-lock-constant-face)

     :language 'bend
     :feature 'variable
     '((parameter name: (identifier) @font-lock-variable-name-face)
       (lambda_expression param: (identifier) @font-lock-variable-name-face))

     :language 'bend
     :feature 'operator
     `([,@bend-ts-mode--operators (reflexivity)] @font-lock-operator-face)

     :language 'bend
     :feature 'bracket
     '(["(" ")" "[" "]" "{" "}"] @font-lock-bracket-face)

     :language 'bend
     :feature 'delimiter
     '(["," ":" ";" "."] @font-lock-delimiter-face)))
  "Tree-sitter font-lock rules for `bend-ts-mode'.
Node names come from tree-sitter-bend2's queries/highlights.scm.  With
the default `treesit-font-lock-level' (3) the faces match the regex
`bend-mode'; level 4 adds parameters, operators and punctuation.")

(defconst bend-ts-mode--font-lock-feature-list
  '((comment definition)
    (keyword string hole)
    (type constant)
    (variable operator bracket delimiter))
  "Font-lock features of `bend-ts-mode', one list per level.")

;;; Indentation

(defconst bend-ts-mode--block-item-regexp
  (rx bos (or "statement" "case_clause" "constructor_definition"
              "foreign_import_statement" "for_clause" "exs_clause"
              "claim_statement" "bind_statement" "do_let_statement"
              "return_statement_line" "expression_statement_line")
      eos)
  "Node types that are items of an indented block.")

(defun bend-ts-mode--previous-code-bol (bol)
  "Return the indentation position of the code line before BOL."
  (save-excursion
    (goto-char bol)
    (bend-mode--previous-code-line)
    (back-to-indentation)
    (point)))

(defun bend-ts-mode--previous-code-anchor (_node _parent bol)
  "Anchor for the fallback rule: the previous code line, from BOL."
  (bend-ts-mode--previous-code-bol bol))

(defun bend-ts-mode--previous-code-offset (_node _parent bol)
  "Offset for the fallback rule: one level when the previous line opens a block.
BOL is the position of the first non-whitespace character on the line."
  (save-excursion
    (goto-char (bend-ts-mode--previous-code-bol bol))
    (end-of-line)
    (skip-chars-backward " \t")
    (if (eq (char-before) ?:) bend-mode-indent-offset 0)))

(defun bend-ts-mode--inside-token-p (_node parent _bol)
  "Non-nil if the line starts inside a multi-line comment, per PARENT."
  (member (treesit-node-type parent) '("block_comment")))

(defvar bend-ts-mode--indent-rules
  `((bend
     ;; Inside a block comment: leave the text alone.
     (bend-ts-mode--inside-token-p no-indent 0)
     ;; Blank line (nothing to look at yet): the regex mode's rule.
     (no-node bend-ts-mode--previous-code-anchor
              bend-ts-mode--previous-code-offset)
     ;; Top-level declarations.
     ((parent-is "source_file") column-0 0)
     ;; Block items sit one level under the line that opens the block.
     ((node-is ,bend-ts-mode--block-item-regexp)
      parent-bol bend-mode-indent-offset)
     ;; Comments, continuation lines and unparsed code.
     (catch-all bend-ts-mode--previous-code-anchor
                bend-ts-mode--previous-code-offset)))
  "Indentation rules of `bend-ts-mode' (see `treesit-simple-indent-rules').")

;;; Navigation and Imenu

(defconst bend-ts-mode--defun-regexp
  (rx bos (or "def_declaration" "law_declaration" "type_declaration") eos)
  "Node types `beginning-of-defun' and friends move between.")

(defun bend-ts-mode--defun-name (node)
  "Return the name of the declaration NODE, or nil."
  (when (string-match-p bend-ts-mode--defun-regexp (treesit-node-type node))
    (when-let ((name (treesit-node-child-by-field-name node "name")))
      (treesit-node-text name t))))

;;; Mode definition

;;;###autoload
(define-derived-mode bend-ts-mode bend-mode "Bend[ts]"
  "Tree-sitter major mode for editing Bend 2.
Derives from `bend-mode'; see the file commentary of bend-ts-mode.el.

\\{bend-ts-mode-map}"
  (unless (and (fboundp 'treesit-ready-p) (treesit-ready-p 'bend))
    (error "Bend tree-sitter grammar not available; run M-x bend-ts-mode-install-grammar"))
  (treesit-parser-create 'bend)
  (setq-local treesit-font-lock-settings bend-ts-mode--font-lock-settings)
  (setq-local treesit-font-lock-feature-list
              bend-ts-mode--font-lock-feature-list)
  (setq-local treesit-simple-indent-rules bend-ts-mode--indent-rules)
  (setq-local treesit-defun-type-regexp bend-ts-mode--defun-regexp)
  (setq-local treesit-defun-name-function #'bend-ts-mode--defun-name)
  (when (boundp 'treesit-thing-settings)
    (setq-local treesit-thing-settings
                `((bend (defun ,bend-ts-mode--defun-regexp)))))
  (setq-local treesit-simple-imenu-settings
              `(("Def" "\\`def_declaration\\'" nil bend-ts-mode--defun-name)
                ("Type" "\\`type_declaration\\'" nil bend-ts-mode--defun-name)
                ("Law" "\\`law_declaration\\'" nil bend-ts-mode--defun-name)))
  (treesit-major-mode-setup))

;;; Fallback to the regex mode

(defcustom bend-ts-mode-prefer-treesit t
  "Whether `.bend' files open in `bend-ts-mode' when its grammar is installed.
When nil, or when the grammar is missing, they open in the regex
`bend-mode'."
  :type 'boolean
  :group 'bend)

(defvar bend-ts-mode--fallback-noted nil
  "Non-nil once the missing-grammar fallback has been announced.")

;;;###autoload
(defun bend-ts-mode-maybe ()
  "Enable `bend-ts-mode' if its grammar is installed, else `bend-mode'."
  (interactive)
  (cond
   ((not bend-ts-mode-prefer-treesit) (bend-mode))
   ((bend-ts-mode-grammar-available-p) (bend-ts-mode))
   (t
    (unless bend-ts-mode--fallback-noted
      (setq bend-ts-mode--fallback-noted t)
      (message "Bend tree-sitter grammar not installed; using bend-mode (M-x bend-ts-mode-install-grammar)"))
    (bend-mode))))

;;;###autoload
(when (boundp 'major-mode-remap-alist)
  (add-to-list 'major-mode-remap-alist
               '(bend-mode . bend-ts-mode-maybe)))

;;; Eglot

(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               '((bend-ts-mode :language-id "bend") . bend-mode--eglot-contact)))

(provide 'bend-ts-mode)

;;; bend-ts-mode.el ends here
