;;; markup2html.el --- Render Markdown and Org documents to RFC-styled HTML -*- lexical-binding: t; -*-

;; Author: Robert Zaremba
;; Version: 1.0.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: markdown, org, html, docs, export, preview

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Emacs front-end for the markup2html.mjs renderer shipped in this
;; package.  All conversion (marked for Markdown, in-process Org
;; export) and HTML assembly happen in the script; this module only
;; wires it into Emacs.  The same script is a standalone CLI that
;; replaces contrib/markup2html.sh:
;;
;;   bun markup2html.mjs [-o OUTPUT] [--css FILE] <input.md | input.org>
;;
;; Commands (work in `markdown-mode', `gfm-mode', `markdown-ts-mode'
;; and `org-mode' buffers alike):
;;
;;   `markup2html-export'              write <stem>.html next to the source
;;   `markup2html-export-and-preview'  export, then open in a browser
;;   `markup2html-preview-exported'    open the exported page in a browser
;;
;; markdown-mode integration: `markup2html-command' is a
;; `markdown-command'-compatible function, so the native preview and
;; export commands (C-c C-c p, e, v) render through markup2html too.
;; The region arguments are ignored: the renderer works on whole
;; files.
;;
;; Org integration: Org buffers are exported to body-only HTML
;; in-process and piped to the renderer's stdin (--html assembly
;; mode), so no batch-Emacs process is spawned and unsaved edits are
;; included.  The export dispatcher entry "C-c C-e R" runs the same
;; commands (r = write the file, o = write and open).
;;
;; The script runs on `markup2html-js-runtime' (bun by default; node
;; works too).  Markdown rendering uses the marked version vendored
;; next to the script; the stylesheet ships with the package.

;;; Code:

(require 'browse-url)
(require 'ox-html) ; registers the parent backend for the dispatcher entry

(defgroup markup2html nil
  "Render Markdown and Org documents to RFC-styled HTML via markup2html.mjs."
  :group 'text
  :prefix "markup2html-")

(defcustom markup2html-js-runtime 'bun
  "JavaScript runtime used to execute the markup2html.mjs renderer."
  :type '(choice (const :tag "Bun" bun)
          (const :tag "Node.js" node))
  :package-version '(markup2html . "1.0.0"))

(defconst markup2html--package-dir
  (file-name-directory
   (or (and load-file-name (expand-file-name load-file-name))
       (locate-library "markup2html")))
  "Directory containing this file.
markup2html.mjs, the vendored marked and the stylesheet live there.")

(defcustom markup2html-script
  (file-name-concat markup2html--package-dir "markup2html.mjs")
  "The markup2html.mjs renderer executed by the commands in this module."
  :type 'file
  :package-version '(markup2html . "1.0.0"))


;; Script invocation

(defun markup2html--exe ()
  "Path to the `markup2html-js-runtime' executable."
  (or (executable-find
       (pcase markup2html-js-runtime
         ((or `bun `node) (symbol-name markup2html-js-runtime))
         (_ (user-error "markup2html: unknown runtime: %s" markup2html-js-runtime))))
      (user-error "markup2html: %s runtime not found on PATH"
                  markup2html-js-runtime)))

(defun markup2html--run (args &optional stdin-string)
  "Run markup2html.mjs with ARGS.
Feed STDIN-STRING to the renderer's standard input when given.
Signal `user-error' with the renderer output on failure; return
non-nil on success."
  (let* ((log (generate-new-buffer " *markup2html-log*"))
         (status
          (if stdin-string
              (with-temp-buffer
                (insert stdin-string)
                (apply #'call-process-region (point-min) (point-max)
                       (markup2html--exe) nil (list log t) nil args))
            (apply #'call-process (markup2html--exe) nil (list log t) nil args))))
    (unwind-protect
        (let ((log-text (string-trim (with-current-buffer log (buffer-string)))))
          (if (zerop status)
              (progn (message "%s" (or log-text "done")) t)
            (user-error "markup2html: renderer failed (exit %s)%s"
                        status
                        (if (string-empty-p log-text) "" (format ": %s" log-text)))))
      (kill-buffer log))))


;; Org support: export the buffer to body-only HTML in-process and pipe
;; it to the script's --html assembly mode.

(defun markup2html--org-lines ()
  "Lines of the current (widened) buffer as a list of strings."
  (save-restriction
    (widen)
    (string-lines (buffer-string))))

(defun markup2html--org-meta-rows ()
  "Collect leading #+KEYWORD: lines as the page's meta table rows.
Stops at the first blank or non-keyword line.  TITLE is skipped
(it becomes the page title); empty values are skipped; FILETAGS
values are rendered as a comma-separated list."
  (let (rows)
    (catch 'done
      (dolist (line (markup2html--org-lines))
        (unless (string-match "\\`#\\+\\([A-Za-z0-9_-]+\\):[ \t]*" line)
          (throw 'done nil))
        (let ((key (match-string 1 line))
              (val (substring line (match-end 0))))
          (unless (or (string= key "TITLE") (string-empty-p val))
            (when (string= key "FILETAGS")
              (setq val (string-replace ":" ", " (string-trim val ":" ":"))))
            (push (cons key val) rows)))))
    (nreverse rows)))

(defun markup2html--org-title ()
  "Page title from the #+TITLE: line, or the visited file's stem."
  (if-let* ((line (seq-find (lambda (l) (string-prefix-p "#+TITLE:" l))
                            (markup2html--org-lines))))
      (string-trim (string-remove-prefix "#+TITLE:" line))
    (file-name-base (or (buffer-file-name) (buffer-name)))))

(defun markup2html--org-body-html ()
  "Export the current Org buffer to body-only HTML, in-process."
  (let ((org-html-htmlize-output-type 'css))
    (org-no-properties
     (org-export-as 'html nil nil t '(:with-toc nil :section-numbers nil)))))

(defun markup2html--export-org (output-file)
  "Export the current Org buffer to OUTPUT-FILE via the script's --html mode.
The Org body is exported in-process and piped to markup2html.mjs on
stdin, so no batch-Emacs process is spawned."
  (markup2html--run
   (append
    (list markup2html-script "--html" "--output" output-file
          "--h1" "--title" (markup2html--org-title))
    (mapcan (lambda (row)
              (list "--meta" (format "%s: %s" (car row) (cdr row))))
            (markup2html--org-meta-rows)))
   (markup2html--org-body-html))
  output-file)


;; Commands

;;;###autoload
(defun markup2html-export (&optional output-file)
  "Export the current document to a standalone RFC-styled HTML page.
Markdown buffers are rendered from the visited file; Org buffers are
exported in-process from the buffer (unsaved edits included).
Writes to OUTPUT-FILE or <stem>.html next to the visited file, like
the CLI.  Return the output file name."
  (interactive)
  (unless buffer-file-name
    (user-error "markup2html: buffer is not visiting a file"))
  (let ((output (or output-file
                    (concat (file-name-sans-extension buffer-file-name)
                            ".html"))))
    (if (derived-mode-p 'org-mode)
        (markup2html--export-org output)
      (markup2html--run (list markup2html-script buffer-file-name "--output" output)))
    output))

;;;###autoload
(defun markup2html-export-and-preview ()
  "Export the current document and open the result in a browser."
  (interactive)
  (browse-url-of-file (markup2html-export)))

;;;###autoload
(defun markup2html-preview-exported ()
  "Open the exported HTML page of the current document in a browser.
The page must already exist next to the source document (<stem>.html,
as written by `markup2html-export' or the CLI); signal `user-error'
when it is absent."
  (interactive)
  (unless buffer-file-name
    (user-error "markup2html: buffer is not visiting a file"))
  (let ((html (concat (file-name-sans-extension buffer-file-name) ".html")))
    (if (file-exists-p html)
        (browse-url-of-file html)
      (user-error "markup2html: no exported page found: %s (run markup2html-export)"
                  html))))

(defun markup2html-command (_beg _end output-buffer)
  "Render the visited file with markup2html.mjs into OUTPUT-BUFFER.
A `markdown-command'-compatible function: markdown-mode's native
preview and export commands (C-c C-c p, e, v) render through
markup2html.  The region arguments are ignored: the renderer works on
whole files.  The rendered page arrives on the renderer's stdout
(-o -) and nothing is written next to the source."
  (unless buffer-file-name
    (user-error "markup2html: buffer is not visiting a file"))
  (let* ((errf (make-temp-file "markup2html-err-" nil ".txt"))
         (status (call-process (markup2html--exe) nil (list output-buffer errf) nil
                               markup2html-script buffer-file-name "--output" "-")))
    (unless (zerop status)
      (let ((err (with-temp-buffer
                   (insert-file-contents errf)
                   (string-trim (buffer-string)))))
        (user-error "markup2html: renderer failed (exit %s)%s"
                    status
                    (if (string-empty-p err) "" (format ": %s" err)))))
    (delete-file errf))
  output-buffer)


;; Org export dispatcher entry (C-c C-e r). The backend only provides
;; the menu; the actions run the commands above and it never transcodes.

(defun markup2html--dispatch-export (&rest _)
  "Export dispatcher action: write the RFC HTML file."
  (markup2html-export))

(defun markup2html--dispatch-open (&rest _)
  "Export dispatcher action: write the RFC HTML file and open it."
  (markup2html-export-and-preview))

(org-export-define-derived-backend 'markup2html 'html
  :menu-entry
  '(?r "Export to RFC-styled HTML (markup2html)"
    ((?r "As HTML file" markup2html--dispatch-export)
     (?o "As HTML file and open" markup2html--dispatch-open))))

(provide 'markup2html)

;;; markup2html.el ends here
