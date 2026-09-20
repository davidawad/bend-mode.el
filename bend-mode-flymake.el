;;; bend-mode-flymake.el --- Flymake backend for bend-mode -*- lexical-binding: t; -*-

;; Author: David Awad <angrybohr@protonmail.com>
;; Maintainer: David Awad <angrybohr@protonmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (bend-mode "0.1.0"))
;; Keywords: languages
;; URL: https://github.com/davidawad/bend-mode.el

;; This file is not part of GNU Emacs.

;; MIT License; see LICENSE in this package's directory for the full text.

;;; Commentary:

;; A Flymake backend that shells out to `bend FILE --check-only' and
;; parses its checker-error format into diagnostics.  `bend2-fmt-lsp'
;; (see bend-mode.el's Eglot wiring) is formatting-only by design and
;; exposes no diagnostics; a compiler-backed Bend 2 LSP was proposed
;; upstream (bendlang/bend#865) and its author was asked to publish it
;; as its own project rather than merge it into the compiler repo, so
;; as of this writing nothing else fills that gap for any editor.  This
;; is the "cheap approximation" that PR's own author described: bend
;; stops at its first error, so at most one diagnostic surfaces per
;; check; it reads the file from disk, so an unsaved buffer is checked
;; via a same-directory temp copy (relative `import ./x.bend' needs the
;; real directory); no hover, no completion -- replace this file
;; outright the day a real Bend 2 LSP reports diagnostics itself.
;;
;; Enable per-buffer:
;;
;;   (add-hook 'bend-mode-hook #'flymake-mode)
;;
;; `bend-mode' itself registers this backend buffer-locally; turning on
;; `flymake-mode' (directly, or Doom's default `+checkers' setup) is
;; the only wiring left to the user.

;;; Code:

(require 'flymake)
(require 'bend-mode)

(defvar-local bend-mode-flymake--proc nil
  "The live `bend --check-only' process for the current buffer, if any.
A new call to `bend-mode-flymake' kills whatever this points to before
starting its own process, and the sentinel below compares itself
against this variable to discard a stale result if a newer check
already superseded it -- the standard Flymake backend idiom.")

(defun bend-mode-flymake--block-message (block)
  "Render checker-error BLOCK into one Flymake message string.
Joins its `- expected/- observed' or `- message' lines, or, lacking
those, falls back to the block's own first line, for shapes like
\"Error: N TODOs found.\"."
  (let ((detail-lines
         (seq-filter (lambda (l) (string-prefix-p "- " l))
                      (split-string block "\n"))))
    (if detail-lines
        (mapconcat (lambda (l) (string-trim (substring l 2))) detail-lines "; ")
      (string-trim (car (split-string block "\n"))))))

(defun bend-mode-flymake--parse (output)
  "Parse bend's OUTPUT into a list of (LINE . MESSAGE) conses.

Bend stops at its first error (TOOLING-CLI.md, \"Check and run\"), so
this looks only at the first `Error:' block: it may carry an optional
`Location:' source excerpt whose offending line is marked
\"N>|\" (ERROR-TAXONOMY.md); when that marker is present its N is used,
else the diagnostic is attached to line 1 -- covers the location-less
shapes (`N TODOs found.', `PROOF.bend must import ./LAWS.bend', a bare
parser `expected : ...')."
  (let ((start (string-match "^Error:" output)))
    (when start
      (let* ((next (string-match "^Error:" output (1+ start)))
             (block (substring output start next))
             (line
              (if (string-match (rx line-start (group (1+ digit)) ">" "|") block)
                  (string-to-number (match-string 1 block))
                1)))
        (list (cons line (bend-mode-flymake--block-message block)))))))

(defun bend-mode-flymake--report (report-fn proc source-buffer)
  "Report PROC's diagnostics to REPORT-FN if SOURCE-BUFFER is still live.
Shared body for `bend-mode-flymake--sentinel'."
  (unless (buffer-live-p source-buffer)
    (kill-buffer (process-buffer proc)))
  (when (buffer-live-p source-buffer)
    (with-current-buffer source-buffer
      (if (not (eq proc bend-mode-flymake--proc))
          ;; A newer check superseded this one; drop the result.
          (kill-buffer (process-buffer proc))
        (let ((output (with-current-buffer (process-buffer proc)
                         (buffer-string))))
          (kill-buffer (process-buffer proc))
          (funcall
           report-fn
           (mapcar
            (lambda (hit)
              (let* ((line (car hit))
                     (beg (save-excursion
                            (goto-char (point-min))
                            (forward-line (1- line))
                            (line-beginning-position)))
                     (end (save-excursion (goto-char beg) (line-end-position))))
                (flymake-make-diagnostic source-buffer beg end :error (cdr hit))))
            (bend-mode-flymake--parse output))))))))

(defun bend-mode-flymake--sentinel (report-fn proc _event)
  "Dispatch PROC's diagnostics to REPORT-FN once PROC has exited.
Flymake process sentinel; forwards to `bend-mode-flymake--report'."
  (when (memq (process-status proc) '(exit signal))
    (bend-mode-flymake--report report-fn proc (process-get proc 'bend-mode-flymake-buffer))))

(defun bend-mode-flymake (report-fn &rest _args)
  "Flymake backend function for `bend-mode', reporting to REPORT-FN.
Registered buffer-locally by `bend-mode' itself; call `flymake-mode'
to actually turn checking on."
  (if (not (executable-find bend-mode-command))
      (funcall report-fn :panic :explanation
               (format "%s not found on PATH" bend-mode-command))
    (when (process-live-p bend-mode-flymake--proc)
      (delete-process bend-mode-flymake--proc))
    (let* ((source-buffer (current-buffer))
           (tempfile
            (unless (and buffer-file-name (not (buffer-modified-p)))
              ;; bend reads a real file and resolves `import ./x.bend'
              ;; relative to its directory, so an unsaved buffer is
              ;; checked via a same-directory sibling, never a
              ;; system-temp copy.
              (let ((dir (if buffer-file-name
                             (file-name-directory buffer-file-name)
                           default-directory)))
                (concat (make-temp-name
                         (expand-file-name ".bend-mode-flymake-" dir))
                        ".bend"))))
           (target (or tempfile buffer-file-name)))
      (if (not target)
          (funcall report-fn :panic :explanation "buffer has no file to check")
        (when tempfile
          (write-region (point-min) (point-max) tempfile nil 'silent))
        (setq bend-mode-flymake--proc
              (make-process
               :name "bend-mode-flymake" :noquery t :connection-type 'pipe
               :buffer (generate-new-buffer " *bend-mode-flymake*")
               :command (list bend-mode-command target "--check-only")
               :sentinel
               (lambda (proc event)
                 (unwind-protect
                     (bend-mode-flymake--sentinel report-fn proc event)
                   (when (and tempfile
                              (memq (process-status proc) '(exit signal)))
                     (ignore-errors (delete-file tempfile)))))))
        (process-put bend-mode-flymake--proc 'bend-mode-flymake-buffer source-buffer)))))

;;;###autoload
(defun bend-mode-flymake-setup ()
  "Register the backend for the current buffer, buffer-locally.
Called automatically by `bend-mode'; harmless to call again."
  (add-hook 'flymake-diagnostic-functions #'bend-mode-flymake nil t))

(add-hook 'bend-mode-hook #'bend-mode-flymake-setup)

(provide 'bend-mode-flymake)

;;; bend-mode-flymake.el ends here
