;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;
;;; Renders a Markdown API reference table for a list of live, resolved
;;; Guile modules, one row per exported binding: name, kind, signature,
;;; docstring, and -- via (autodoc scan) -- a link to its exact definition
;;; line in your repository's GitHub/GitLab/etc. source view. This is the
;;; "docs that go to code" piece: every binding is one click from its real
;;; implementation, the way Zig's autodoc or rustdoc work, which nothing in
;;; the Guile ecosystem currently offers.
;;;
;;; Live module reflection (module-map, procedure?, procedure-documentation)
;;; gives you the actual exported surface -- it can't lie about what a
;;; module re-exports vs. defines, the way hand-maintained docs can drift.
;;; (autodoc scan) fills the gaps live reflection can't: `define*` keyword
;;; argument names, and source locations.

(define-module (autodoc reference)
  #:use-module (autodoc scan)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (generate-api-reference))

(define (one-line text)
  (string-join (string-tokenize text) " "))

(define (markdown-cell text)
  "Collapse TEXT to one line and escape the \"|\" characters that would
otherwise break out of a Markdown table cell."
  (string-join (string-split (one-line text) #\|) "\\|"))

(define (binding-kind value)
  (cond
   ((procedure? value) "procedure")
   ((string-contains (format #f "~s" value) "syntax-transformer") "syntax")
   (else "value")))

(define (positional-arguments count label)
  (map (lambda (index) (format #f "~a-~a" label (+ index 1)))
       (iota count)))

(define (inferred-signature name value)
  "Best-effort signature from live procedure arity when (autodoc scan)
found no source-level define for NAME (e.g. a binding produced by a macro
at load time rather than a literal top-level define)."
  (let* ((arity (procedure-minimum-arity value))
         (required (list-ref arity 0))
         (optional (list-ref arity 1))
         (rest? (list-ref arity 2))
         (parts (append
                 (positional-arguments required "arg")
                 (map (lambda (argument) (format #f "[~a]" argument))
                      (positional-arguments optional "optional"))
                 (if rest? '(". rest") '()))))
    (format #f "(~a~a)" name
            (if (null? parts) "" (string-append " " (string-join parts " "))))))

(define (binding-signature name value info)
  (cond
   ((source-info-signature info) (format #f "~s" (source-info-signature info)))
   ((procedure? value) (inferred-signature name value))
   (else (symbol->string name))))

(define (binding-documentation value info)
  (cond
   ((source-info-documentation info) (source-info-documentation info))
   ((and (procedure? value) (procedure-documentation value))
    => (lambda (doc) (if (string-null? doc) #f doc)))
   (else #f)))

(define (binding-source-link info repo-blob-prefix)
  (if (and repo-blob-prefix (source-info-file info) (source-info-line info))
      (format #f "[`~a:~a`](~a~a#L~a)"
              (source-info-file info) (source-info-line info)
              repo-blob-prefix (source-info-file info) (source-info-line info))
      "—"))

(define (module-bindings module-name)
  (sort
   (module-map (lambda (name variable) (cons name (variable-ref variable)))
               (resolve-interface module-name))
   (lambda (left right) (string<? (symbol->string (car left)) (symbol->string (car right))))))

(define* (generate-api-reference #:key
                                 modules
                                 source-directory
                                 repo-blob-prefix
                                 (title "API reference")
                                 (extra-columns '())
                                 (missing-docstring-text "No docstring is attached.")
                                 (on-form #f))
  "Return a Markdown string documenting every export of MODULES (a list of
module-name lists, e.g. '((my-project widgets))), one table per module.

SOURCE-DIRECTORY is scanned with (autodoc scan) for real signatures,
docstrings, and source locations; MODULES themselves must already be
loadable (e.g. via GUILE_LOAD_PATH), since their live bindings are what
determines which names actually get documented.

TITLE, if given, is emitted as a leading \"# TITLE\" line; pass #f to omit
it (e.g. when the caller writes its own document header around this).

REPO-BLOB-PREFIX, if given, is prepended to each binding's file path to
form its \"Source\" column link (e.g.
\"https://github.com/org/repo/blob/main/\"); omit it to leave that column
out entirely.

EXTRA-COLUMNS is a list of (header . proc) pairs appended after the
built-in ones; each PROC is called as (proc module-name name value info)
-- INFO an <source-info> from (autodoc scan), possibly all-#f fields -- and
must return the cell's Markdown-safe text. Use it for anything project
specific autodoc has no opinion about: a demo/example-script id, a
stability tier, a changelog version, an owning team."
  (define scan (scan-source-files (scan-tree source-directory) #:on-form on-form))
  (define (row module-name name value)
    (let ((info (lookup-source-info scan module-name name)))
      (string-append
       "| `" (symbol->string name) "` "
       "| " (binding-kind value) " "
       "| `" (binding-signature name value info) "` "
       "| " (markdown-cell (or (binding-documentation value info) missing-docstring-text)) " "
       (apply string-append
        (map (lambda (column)
               (string-append "| " (markdown-cell ((cdr column) module-name name value info)) " "))
             extra-columns))
       "| " (binding-source-link info repo-blob-prefix) " |\n")))
  (define header-cells
    (append '("Binding" "Kind" "Signature" "Description")
            (map car extra-columns)
            '("Source")))
  (define (table-header)
    (string-append
     "| " (string-join header-cells " | ") " |\n"
     "|" (string-join (map (lambda (_) "---") header-cells) "|") "|\n"))
  (string-append
   (if title (string-append "# " title "\n\n") "")
   (apply string-append
    (map (lambda (module-name)
           (string-append
            "## `" (format #f "~s" module-name) "`\n\n"
            (table-header)
            (apply string-append
             (map (lambda (binding) (row module-name (car binding) (cdr binding)))
                  (module-bindings module-name)))
            "\n"))
         modules))))
