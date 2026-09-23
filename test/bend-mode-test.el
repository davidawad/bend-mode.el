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

(provide 'bend-mode-test)

;;; bend-mode-test.el ends here
