;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;
;;; Static source scanner: reads a tree of Guile source files with its own
;;; `read` (never `load`s or evaluates them), so it works for code that
;;; can't safely be instantiated outside its real runtime -- a compositor,
;;; a driver, anything with side effects at definition time. What Guile's
;;; runtime reflection *can* tell you (via `procedure-source`,
;;; `procedure-documentation`) is patchy across compiled vs. interpreted
;;; code and loses `define*` keyword-argument names; reading the source
;;; text directly is the same trick scripts/generate-api-reference.scm in
;;; SchemeWM used before this module existed, generalized so any project
;;; can reuse it instead of re-deriving it.
;;;
;;; Records, for each top-level `define`/`define*`/`define-record-type`
;;; binding found: its signature as written, its leading docstring (if
;;; any), and its exact file and line -- via `(read-enable 'positions)`,
;;; which makes Guile's reader attach real source locations to every form,
;;; not just the ones the evaluator later happens to remember.

(define-module (autodoc scan)
  #:use-module (ice-9 ftw)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-9)
  #:export (scan-tree
            scan-source-files
            source-info?
            source-info-signature
            source-info-documentation
            source-info-file
            source-info-line
            lookup-source-info
            register-documentation!))

(read-enable 'positions)

(define-record-type <source-info>
  (make-source-info signature documentation file line)
  source-info?
  (signature source-info-signature)
  (documentation source-info-documentation)
  (file source-info-file)
  (line source-info-line))

;; A <scan> bundles three hash tables keyed both by bare NAME (first
;; definition of that name anywhere in the tree wins, so unqualified
;; lookups are still useful) and by "MODULE/NAME" (exact, for resolving
;; re-exports to their real definition site). Kept as an opaque triple
;; rather of a record so lookup-source-info can stay a one-liner.
(define-record-type <scan>
  (make-scan signatures documentation locations)
  scan?
  (signatures scan-signatures)
  (documentation scan-documentation)
  (locations scan-locations))

(define (scan-key module-name name)
  (format #f "~s/~a" module-name name))

(define (table-set! table module-name name value)
  (when (symbol? name)
    (unless (hash-ref table name)
      (hash-set! table name value))
    (when module-name
      (hash-set! table (scan-key module-name name) value))))

(define (table-ref table module-name name)
  (or (and module-name (hash-ref table (scan-key module-name name)))
      (hash-ref table name)))

(define (scan-tree directory)
  "Every \".scm\" file under DIRECTORY, sorted, depth-first."
  (append-map
   (lambda (entry)
     (if (member entry '("." ".."))
         '()
         (let ((path (string-append directory "/" entry)))
           (cond
            ((file-is-directory? path) (scan-tree path))
            ((string-suffix? ".scm" path) (list path))
            (else '())))))
   (sort (or (scandir directory) '()) string<?)))

(define (record-signature! signatures module-name name arguments)
  (table-set! signatures module-name name (cons name arguments)))

(define (record-documentation! documentation module-name name body)
  (when (and (pair? body) (string? (car body)))
    (table-set! documentation module-name name (car body))))

(define (record-location! locations module-name name path line)
  (when line
    ;; +1: `read-enable 'positions' reports 0-indexed lines; editors, GitHub
    ;; blob URLs (#L123), and everyone reading a stack trace count from 1.
    (table-set! locations module-name name (cons path (+ line 1)))))

(define (record-definition! scan module-name form path line)
  (when (pair? form)
    (let ((signatures (scan-signatures scan))
          (documentation (scan-documentation scan))
          (locations (scan-locations scan)))
      (define (record! name arguments body)
        (record-signature! signatures module-name name arguments)
        (record-documentation! documentation module-name name body)
        (record-location! locations module-name name path line))
      (cond
       ((and (memq (car form) '(define define*))
             (> (length form) 2))
        (let ((target (cadr form)))
          (cond
           ((and (pair? target) (symbol? (car target)))
            (record! (car target) (cdr target) (cddr form)))
           ((and (symbol? target)
                 (pair? (caddr form))
                 (eq? (caaddr form) 'lambda))
            (record! target (cadr (caddr form)) (cddr (caddr form)))))))
       ((and (eq? (car form) 'define-record-type)
             (> (length form) 3))
        (let ((constructor (list-ref form 2))
              (predicate (list-ref form 3))
              (fields (drop form 4)))
          (when (pair? constructor)
            (record! (car constructor) (cdr constructor) '()))
          (record! predicate '(RECORD) '())
          (for-each
           (lambda (field)
             (when (and (list? field) (> (length field) 1))
               (record! (list-ref field 1) '(RECORD) '())
               (when (> (length field) 2)
                 (record! (list-ref field 2) '(RECORD VALUE) '()))))
           fields)))))))

(define* (scan-source-files files #:key on-form)
  "Read every path in FILES with Guile's own reader (no evaluation) and
return a <scan> of every top-level define/define*/define-record-type
binding's signature, leading docstring, and source file/line.

ON-FORM, if given, is called as (ON-FORM SCAN MODULE-NAME FORM PATH LINE)
for every top-level form read, before the built-in recognizers run -- for
project-specific conventions the scanner has no opinion about, such as an
adjacent metadata alist next to bindings that can't carry a docstring
themselves (macros, SRFI-9 accessors, exported constants). Use
`register-documentation!' on the given SCAN to feed findings back in."
  (let ((scan (make-scan (make-hash-table) (make-hash-table) (make-hash-table))))
    (for-each
     (lambda (path)
       (call-with-input-file path
         (lambda (port)
           (let loop ((module-name #f))
             (let ((form (read port)))
               (unless (eof-object? form)
                 (let ((next-module
                        (if (and (pair? form) (eq? (car form) 'define-module))
                            (cadr form)
                            module-name))
                       (line (assq-ref (source-properties form) 'line)))
                   (when on-form (on-form scan next-module form path line))
                   (record-definition! scan next-module form path line)
                   (loop next-module))))))))
     files)
    scan))

(define (register-documentation! scan module-name name text)
  "Manually record documentation TEXT for NAME (optionally scoped to
MODULE-NAME), for a source convention this scanner has no built-in opinion
about -- e.g. an adjacent metadata alist next to bindings that can't carry
a real docstring (macros, SRFI-9 accessors, exported constants). Call this
from the ON-FORM callback given to `scan-source-files', which runs before
this scanner's own recognizers for the same form; like the rest of this
module's tables, first-recorded wins, so this only fills a gap left by a
definition this scanner has no built-in way to read a docstring from -- it
will not override one for a name this scanner also recognizes."
  (table-set! (scan-documentation scan) module-name name text))

(define (lookup-source-info scan module-name name)
  "The <source-info> SCAN recorded for NAME in MODULE-NAME, falling back to
any module's definition of that bare name if MODULE-NAME has none (the
case when a binding is re-exported from elsewhere). All three fields are
independently optional -- e.g. a docstring-free define with no accompanying
metadata still yields a usable file/line with #f signature/documentation."
  (make-source-info
   (table-ref (scan-signatures scan) module-name name)
   (table-ref (scan-documentation scan) module-name name)
   (let ((location (table-ref (scan-locations scan) module-name name)))
     (and location (car location)))
   (let ((location (table-ref (scan-locations scan) module-name name)))
     (and location (cdr location)))))
