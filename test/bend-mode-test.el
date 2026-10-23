;;; bend-mode-test.el --- Tests for bend-mode.el -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; ERT tests for bend-mode.el and bend-mode-flymake.el.  The flymake
;; tests exercise only the pure parsing functions
;; (`bend-mode-flymake--parse' / `--block-message') against canned
;; `bend --check-only' output strings taken from
;; bend2-mega-skill's TOOLING-CLI.md/ERROR-TAXONOMY.md -- no `bend'
;; process is spawned, so these run offline and need no toolchain
;; installed.
;;
;; Standalone: from this directory,
;;   emacs -Q --batch -L ../src -l ../src/bend-mode.el \
;;     -l ../src/bend-mode-flymake.el -l bend-mode-test.el \
;;     -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(add-to-list 'load-path
             (expand-file-name
              "src"
              (file-name-directory
               (directory-file-name
                (file-name-directory (or load-file-name buffer-file-name))))))
(require 'bend-mode)
(require 'bend-mode-flymake)
(require 'cl-lib)

(defmacro bend-mode-test--with-buffer (content &rest body)
  "Run BODY in a temp `bend-mode' buffer containing CONTENT."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,content)
     (bend-mode)
     (font-lock-ensure)
     (goto-char (point-min))
     ,@body))

(defun bend-mode-test--face-at (string)
  "Return the face at the first match of STRING in the current buffer."
  (goto-char (point-min))
  (search-forward string)
  (get-text-property (- (point) 1) 'face))

;;; auto-mode-alist

(ert-deftest bend-mode-test-auto-mode-alist ()
  (should (eq (assoc-default "foo.bend" auto-mode-alist #'string-match)
              'bend-mode)))

;;; Font lock

(ert-deftest bend-mode-test-keyword-face ()
  (bend-mode-test--with-buffer "def pow2(+d: Nat) -> U32:\n  1\n"
    (should (eq (bend-mode-test--face-at "def") 'font-lock-keyword-face))))

(ert-deftest bend-mode-test-def-name-face ()
  (bend-mode-test--with-buffer "def pow2(+d: Nat) -> U32:\n  1\n"
    (should (eq (bend-mode-test--face-at "pow2") 'font-lock-function-name-face))))

(ert-deftest bend-mode-test-type-face ()
  (bend-mode-test--with-buffer "def f(x: U32) -> Nat:\n  1n\n"
    (should (eq (bend-mode-test--face-at "U32") 'font-lock-type-face))
    (should (eq (bend-mode-test--face-at "Nat") 'font-lock-type-face))))

(ert-deftest bend-mode-test-line-comment-face ()
  (bend-mode-test--with-buffer "# a comment\ndef f() -> U32:\n  1\n"
    (should (eq (bend-mode-test--face-at "a comment") 'font-lock-comment-face))))

(ert-deftest bend-mode-test-string-face ()
  (bend-mode-test--with-buffer "def f() -> String:\n  \"hi\"\n"
    (should (eq (bend-mode-test--face-at "hi") 'font-lock-string-face))))

(ert-deftest bend-mode-test-hole-face ()
  (bend-mode-test--with-buffer "def f() -> U32:\n  ?TODO\n"
    (should (eq (bend-mode-test--face-at "?TODO") 'font-lock-warning-face))))

(ert-deftest bend-mode-test-nat-literal-face ()
  (bend-mode-test--with-buffer "def f() -> Nat:\n  3n\n"
    (should (eq (bend-mode-test--face-at "3n") 'font-lock-constant-face))))

;;; Nested block comments

(ert-deftest bend-mode-test-nested-block-comment ()
  ;; The inner `#}' must not close the outer comment early: position
  ;; right after "live" (inside the still-open outer comment) must
  ;; read as inside-a-comment via `syntax-ppss'.
  (bend-mode-test--with-buffer "#{ outer #{ inner #} still live #}\ndef f() -> U32:\n  1\n"
    (goto-char (point-min))
    (search-forward "still live")
    (should (nth 4 (syntax-ppss (point))))
    (should (eq (bend-mode-test--face-at "def") 'font-lock-keyword-face))))

(ert-deftest bend-mode-test-block-comment-does-not-eat-following-code ()
  (bend-mode-test--with-buffer "#{ a block comment #}\ndef f() -> U32:\n  1\n"
    (should (eq (bend-mode-test--face-at "def") 'font-lock-keyword-face))))

(ert-deftest bend-mode-test-deeply-nested-block-comment-depth-aware ()
  ;; A discriminating regression test for the depth-aware rewrite: one
  ;; outer comment containing two SEPARATE nested pairs, with plain
  ;; text "c" in between them at depth 1.  Under the old
  ;; toggle-per-occurrence implementation, "b" and "d" (both inside a
  ;; nested pair) were wrongly classified as NOT in a comment -- see
  ;; `bend-mode-syntax-propertize's docstring for why.  Every position
  ;; below must actually be inside the comment via a real depth count,
  ;; not by parity coincidence.
  (bend-mode-test--with-buffer
      "#{ a #{ b #} c #{ d #} e #}\ndef f() -> U32:\n  1\n"
    (goto-char (point-min))
    (search-forward "b")
    (should (nth 4 (syntax-ppss (point))))
    (goto-char (point-min))
    (search-forward "c")
    (should (nth 4 (syntax-ppss (point))))
    (goto-char (point-min))
    (search-forward "d")
    (should (nth 4 (syntax-ppss (point))))
    (goto-char (point-min))
    (search-forward "e")
    (should (nth 4 (syntax-ppss (point))))
    (should (eq (bend-mode-test--face-at "def") 'font-lock-keyword-face))))

(ert-deftest bend-mode-test-unterminated-block-comment-does-not-hang ()
  ;; An unterminated `#{' (no matching `#}' before EOF) must be handled
  ;; gracefully -- treated as open-to-EOF -- rather than hanging or
  ;; erroring.  This is a smoke test only; success is simply that
  ;; `font-lock-ensure' returns.
  (bend-mode-test--with-buffer "#{ never closed\ndef f() -> U32:\n  1\n"
    (should t)))

;;; Indentation

(ert-deftest bend-mode-test-indent-after-colon ()
  (bend-mode-test--with-buffer "def f() -> U32:\n1\n"
    (goto-char (point-min))
    (forward-line 1)
    (bend-mode-indent-line)
    (should (= (current-indentation) bend-mode-indent-offset))))

(ert-deftest bend-mode-test-indent-matches-previous-when-no-colon ()
  (bend-mode-test--with-buffer "def f() -> U32:\n  1\n  2\n"
    (goto-char (point-min))
    (forward-line 2)
    (bend-mode-indent-line)
    (should (= (current-indentation) bend-mode-indent-offset))))

;;; Flymake parsing (pure functions, no process)

(ert-deftest bend-mode-test-flymake-parse-structured-error ()
  (let* ((output "Error:
- expected : U32
- observed : Bool
Context:
- p : Nat
Location: pow2
11 |     case 1n+p:
12>|       ?goal
")
         (hits (bend-mode-flymake--parse output)))
    (should (= (length hits) 1))
    (should (= (caar hits) 12))
    (should (string-match-p "expected : U32" (cdar hits)))
    (should (string-match-p "observed : Bool" (cdar hits)))))

(ert-deftest bend-mode-test-flymake-parse-todos-no-location ()
  (let* ((output "Error: N TODOs found.
The code is incomplete, and not a valid proof yet.
")
         (hits (bend-mode-flymake--parse output)))
    (should (= (length hits) 1))
    (should (= (caar hits) 1))
    (should (string-match-p "TODOs found" (cdar hits)))))

(ert-deftest bend-mode-test-flymake-parse-clean-output ()
  (should (null (bend-mode-flymake--parse "All terms check.\n"))))

(ert-deftest bend-mode-test-flymake-parse-message-form ()
  (let* ((output "Error:
- message : a parameter or field scrutinee (a match cannot scrutinize a computed value: give it its own def)
")
         (hits (bend-mode-flymake--parse output)))
    (should (= (length hits) 1))
    (should (= (caar hits) 1))
    (should (string-match-p "a match cannot scrutinize" (cdar hits)))))

(ert-deftest bend-mode-test-fmt-lsp-install-command ()
  (let* ((bend-mode-fmt-lsp-prefix "/opt/bend prefix")
         (bend-mode-fmt-lsp-ref "v2.0.26")
         (cmd (bend-mode-fmt-lsp--install-command)))
    (should (string-match-p "--branch v2\\.0\\.26 " cmd))
    (should (string-match-p "sparse-checkout set tools/bend-fmt-lsp" cmd))
    (should (string-match-p (regexp-quote (shell-quote-argument "/opt/bend prefix")) cmd))
    (should (string-match-p "trap 'rm -rf" cmd))))

(ert-deftest bend-mode-test-eglot-contact-falls-back-to-prefix ()
  (let ((bend-mode-fmt-lsp-prefix "/opt/bendprefix"))
    (cl-letf (((symbol-function 'executable-find) (lambda (_) nil)))
      (should (equal (bend-mode--eglot-contact)
                     '("/opt/bendprefix/bin/bend2-fmt-lsp" "--stdio"))))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_) "/usr/bin/bend2-fmt-lsp")))
      (should (equal (car (bend-mode--eglot-contact))
                     "/usr/bin/bend2-fmt-lsp")))))

(ert-deftest bend-mode-test-tab-width-matches-indent-offset ()
  ;; Eglot's formatting request uses `tab-width' as tabSize.
  (let ((bend-mode-indent-offset 3))
    (with-temp-buffer
      (bend-mode)
      (should (= tab-width 3)))))

;;; Tree-sitter mode (bend-ts-mode)

(require 'bend-ts-mode)

(defvar bend-mode-test--grammar-dir
  (expand-file-name "bend-ts-mode-test-grammar" temporary-file-directory)
  "Where the test setup builds the Bend grammar when it is not installed.")

(defun bend-mode-test--ensure-grammar ()
  "Return non-nil if the Bend grammar is loadable, installing it if feasible.
Tries Emacs's own grammar path first, then a cached build under
`bend-mode-test--grammar-dir', then builds one there (needs network,
git and a C compiler)."
  (and (fboundp 'treesit-available-p)
       (treesit-available-p)
       (or (bend-ts-mode-grammar-available-p)
           (progn
             (add-to-list 'treesit-extra-load-path bend-mode-test--grammar-dir)
             (bend-ts-mode-grammar-available-p))
           (condition-case nil
               (progn
                 (make-directory bend-mode-test--grammar-dir t)
                 (let ((inhibit-message t))
                   (treesit-install-language-grammar
                    'bend bend-mode-test--grammar-dir))
                 (bend-ts-mode-grammar-available-p))
             (error nil)))))

(defvar bend-mode-test--ts-available 'unknown)

(defun bend-mode-test--ts-p ()
  "Non-nil when the grammar is available (computed once)."
  (when (eq bend-mode-test--ts-available 'unknown)
    (setq bend-mode-test--ts-available
          (and (bend-mode-test--ensure-grammar) t)))
  bend-mode-test--ts-available)

(defmacro bend-mode-test--with-ts-buffer (content &rest body)
  "Run BODY in a temp `bend-ts-mode' buffer containing CONTENT."
  (declare (indent 1))
  `(progn
     (skip-unless (bend-mode-test--ts-p))
     (with-temp-buffer
       (insert ,content)
       (bend-ts-mode)
       (font-lock-ensure)
       (goto-char (point-min))
       ,@body)))

(ert-deftest bend-ts-mode-test-grammar-registered ()
  (let ((entry (assq 'bend treesit-language-source-alist)))
    (should entry)
    (should (equal (nth 2 entry) bend-ts-mode-grammar-revision))
    (should (string-match-p "tree-sitter-bend2" (nth 1 entry)))))

(ert-deftest bend-ts-mode-test-falls-back-without-grammar ()
  (let ((bend-ts-mode--fallback-noted t))
    (cl-letf (((symbol-function 'bend-ts-mode-grammar-available-p)
               (lambda () nil)))
      (with-temp-buffer
        (bend-ts-mode-maybe)
        (should (eq major-mode 'bend-mode))))))

(ert-deftest bend-ts-mode-test-remap-registered ()
  (should (eq (alist-get 'bend-mode major-mode-remap-alist)
              'bend-ts-mode-maybe)))

(ert-deftest bend-ts-mode-test-derives-from-bend-mode ()
  (should (provided-mode-derived-p 'bend-ts-mode 'bend-mode))
  (should (eq (keymap-parent bend-ts-mode-map) bend-mode-map))
  (should (eq (char-table-parent bend-ts-mode-syntax-table)
              bend-mode-syntax-table)))

(ert-deftest bend-ts-mode-test-maybe-uses-ts ()
  (skip-unless (bend-mode-test--ts-p))
  (with-temp-buffer
    (bend-ts-mode-maybe)
    (should (eq major-mode 'bend-ts-mode))))

(ert-deftest bend-ts-mode-test-faces ()
  (bend-mode-test--with-ts-buffer
      "# note\ndef pow2(+d: Nat) -> U32:\n  ?TODO\n  3n\n  \"hi\"\n"
    (should (eq (bend-mode-test--face-at "note") 'font-lock-comment-face))
    (should (eq (bend-mode-test--face-at "def") 'font-lock-keyword-face))
    (should (eq (bend-mode-test--face-at "pow2") 'font-lock-function-name-face))
    (should (eq (bend-mode-test--face-at "Nat") 'font-lock-type-face))
    (should (eq (bend-mode-test--face-at "U32") 'font-lock-type-face))
    (should (eq (bend-mode-test--face-at "?TODO") 'font-lock-warning-face))
    (should (eq (bend-mode-test--face-at "3n") 'font-lock-constant-face))
    (should (eq (bend-mode-test--face-at "hi") 'font-lock-string-face))))

(ert-deftest bend-ts-mode-test-type-and-law-names ()
  (bend-mode-test--with-ts-buffer
      "type Shape is\n  Circle(r: U32)\n\nlaw foo:\n  for x: Nat\n  {x == x : Nat}\n"
    (should (eq (bend-mode-test--face-at "Shape") 'font-lock-type-face))
    (should (eq (bend-mode-test--face-at "Circle") 'font-lock-type-face))
    (should (eq (bend-mode-test--face-at "foo") 'font-lock-function-name-face))))

(ert-deftest bend-ts-mode-test-indent-dedents-case ()
  ;; The regex mode never dedents; the tree rules do.
  (bend-mode-test--with-ts-buffer
      "def f(x):\n  match x:\n    case 0n:\n      1n\n    case 1n+p:\n      2n\n"
    (let ((expected (buffer-string)))
      (goto-char (point-min))
      (while (not (eobp))
        (delete-horizontal-space)
        (forward-line 1))
      (indent-region (point-min) (point-max))
      (should (equal (buffer-string) expected)))))

(ert-deftest bend-ts-mode-test-indent-blank-line-after-colon ()
  (bend-mode-test--with-ts-buffer "def f() -> U32:\n\n"
    (forward-line 1)
    (indent-according-to-mode)
    (should (= (current-indentation) bend-mode-indent-offset))))

(ert-deftest bend-ts-mode-test-imenu ()
  (bend-mode-test--with-ts-buffer
      "type T is\n  A\n\nlaw l:\n  for x: Nat\n  {x == x : Nat}\n\ndef l(x):\n  x\n"
    (let ((index (treesit-simple-imenu)))
      (should (assoc "Def" index))
      (should (assoc "Type" index))
      (should (assoc "Law" index))
      (should (assoc "l" (cdr (assoc "Law" index)))))))

(ert-deftest bend-ts-mode-test-defun-navigation ()
  (bend-mode-test--with-ts-buffer
      "def a() -> U32:\n  1\n\ndef b() -> U32:\n  2\n"
    (goto-char (point-max))
    (beginning-of-defun)
    (should (looking-at "def b"))
    (beginning-of-defun)
    (should (looking-at "def a"))))

(ert-deftest bend-ts-mode-test-flymake-and-eglot-wiring ()
  (bend-mode-test--with-ts-buffer "def f() -> U32:\n  1\n"
    (should (memq #'bend-mode-flymake flymake-diagnostic-functions))
    (should (= tab-width bend-mode-indent-offset)))
  (when (boundp 'eglot-server-programs)
    (should (cl-find-if
             (lambda (e)
               (let ((k (car e)))
                 (or (eq k 'bend-ts-mode)
                     (and (consp k) (eq (car k) 'bend-ts-mode)))))
             eglot-server-programs))))

(ert-deftest bend-ts-mode-test-examples-parse-and-fontify ()
  (skip-unless (bend-mode-test--ts-p))
  (let ((dir (expand-file-name
              "examples"
              (file-name-directory
               (directory-file-name
                (file-name-directory
                 (or load-file-name buffer-file-name)))))))
    (dolist (f (directory-files dir t "\\.bend\\'"))
      (with-temp-buffer
        (insert-file-contents f)
        (bend-ts-mode)
        (setq-local treesit-font-lock-level 4)
        (treesit-font-lock-recompute-features)
        (font-lock-ensure)
        (should-not (treesit-search-subtree
                     (treesit-buffer-root-node) "ERROR" nil t))))))

(provide 'bend-mode-test)

;;; bend-mode-test.el ends here
