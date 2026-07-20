#!/bin/sh
exec guile --no-auto-compile -L . -L "${1:?usage: smoke-test.scm PROJECT-LOAD-PATH PROJECT-SOURCE-DIR MODULE...}" -s "$0" "$@"
!#
;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;
;;; Sanity check against a real project: generate a reference for MODULEs
;;; found under PROJECT-SOURCE-DIR (with PROJECT-LOAD-PATH added so they're
;;; loadable) and assert the output looks like a plausible API reference,
;;; not that it byte-matches anything -- this is a smoke test, not a golden
;;; file, since the whole point is that it works against projects
;;; guile-autodoc has never seen.
;;;
;;; Usage: tests/smoke-test.scm PROJECT-LOAD-PATH PROJECT-SOURCE-DIR MODULE...
;;;   e.g. tests/smoke-test.scm ~/Projects/scheme-wayland-wm/scheme \
;;;          ~/Projects/scheme-wayland-wm/scheme "(schemewm windows)"

(use-modules (autodoc reference)
             (ice-9 match))

(define args (cdr (program-arguments)))
(match args
  ((load-path source-dir modules-strings ...)
   (let ((modules (map (lambda (s) (with-input-from-string s read)) modules-strings)))
     (define markdown
       (generate-api-reference #:modules modules
                               #:source-directory source-dir
                               #:repo-blob-prefix "https://example.com/blob/main/"
                               #:title "Smoke-test reference"))
     (unless (string-contains markdown "# Smoke-test reference")
       (error "missing title"))
     (unless (string-contains markdown "| Binding | Kind | Signature | Description | Source |")
       (error "missing table header"))
     (unless (string-contains markdown "#L")
       (error "no binding got a source-line link"))
     (format #t "smoke test ok: ~a bytes of markdown for ~a module(s)~%"
             (string-length markdown) (length modules))))
  (_
   (format (current-error-port)
           "usage: smoke-test.scm PROJECT-LOAD-PATH PROJECT-SOURCE-DIR MODULE...~%")
   (exit 1)))
