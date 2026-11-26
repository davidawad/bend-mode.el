;;; render.el --- fontify a .bend file with bend-mode and emit HTML  -*- lexical-binding: t; -*-
;; Usage: emacs -Q --batch -L src -l docs/showcase/render.el --eval '(bend-showcase-render "in.bend" "out.html" "title")'
;; Real font-lock does the fontification; batch Emacs has no color
;; support, so each face is mapped to a color here.

;;; Code:

(require 'bend-mode)

(defconst bend-showcase-palette
  '((font-lock-comment-face . "color:#6b7280;font-style:italic")
    (font-lock-comment-delimiter-face . "color:#6b7280;font-style:italic")
    (font-lock-string-face . "color:#16803c")
    (font-lock-keyword-face . "color:#7c3aed;font-weight:bold")
    (font-lock-function-name-face . "color:#1d4ed8;font-weight:bold")
    (font-lock-type-face . "color:#b45309")
    (font-lock-constant-face . "color:#be185d")
    (font-lock-builtin-face . "color:#0e7490")
    (font-lock-variable-name-face . "color:#0f766e")
    (font-lock-warning-face . "color:#dc2626;font-weight:bold")
    (font-lock-preprocessor-face . "color:#0e7490")
    (font-lock-number-face . "color:#be185d"))
  "Face to inline CSS.")

(defun bend-showcase--css (face)
  "CSS for FACE (a symbol or list), or nil."
  (cl-some (lambda (f) (alist-get f bend-showcase-palette))
           (if (listp face) face (list face))))

(defun bend-showcase-render (in out title)
  "Fontify IN with `bend-mode' and write a styled HTML page to OUT, titled TITLE."
  (with-temp-buffer
    (insert-file-contents in)
    (bend-mode)
    (font-lock-ensure)
    (let ((pos (point-min)) spans)
      (while (< pos (point-max))
        (let* ((next (or (next-single-property-change pos 'face nil (point-max))
                         (point-max)))
               (css (bend-showcase--css (get-text-property pos 'face)))
               (txt (xml-escape-string (buffer-substring-no-properties pos next))))
          (push (if css (format "<span style=\"%s\">%s</span>" css txt) txt) spans)
          (setq pos next)))
      (let ((body (apply #'concat (nreverse spans))))
        (with-temp-file out
          (insert (format "<!doctype html><meta charset=utf-8><style>
body{margin:0;background:#e5e7eb;padding:28px;display:inline-block}
.win{background:#fafafa;border-radius:10px;box-shadow:0 6px 24px #0004;overflow:hidden;font-family:Menlo,'DejaVu Sans Mono',monospace}
.bar{background:#d1d5db;color:#374151;font-size:13px;padding:7px 14px}
.mode{background:#374151;color:#e5e7eb;font-size:13px;padding:4px 14px}
pre{margin:0;padding:14px 18px;font-size:15px;line-height:1.45;color:#111827}
</style><div class=win><div class=bar>%s</div><pre>%s</pre><div class=mode>-:--- %s  (Bend)</div></div>"
                          title body title)))))))
;;; render.el ends here
