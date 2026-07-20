;;; guix.scm -- build guile-autodoc as a Guix package.
;;;
;;;     guix build -f guix.scm
;;;     guix shell -Df guix.scm -- guile -c '(use-modules (autodoc scan))'

(use-modules (guix packages)
             (guix gexp)
             (guix build-system guile)
             ((guix licenses) #:prefix license:)
             (gnu packages guile)
             (gnu packages guile-xyz))

(define %source-dir (dirname (current-filename)))

(package
  (name "guile-autodoc")
  (version "0.1.0")
  (source (local-file %source-dir "guile-autodoc-source"
                      #:recursive? #t
                      #:select? (lambda (file stat)
                                  (not (string-contains file "/.git")))))
  (build-system guile-build-system)
  (native-inputs (list guile-3.0))
  (propagated-inputs (list haunt guile-commonmark))
  (synopsis "Generate cross-linked API docs and a doc site for Guile projects")
  (description
   "guile-autodoc scans a tree of Guile source files and a project's live,
loaded modules to generate a Markdown API reference -- one table per
module, one row per exported binding, each linked to its exact definition
line in your repository's source view (GitHub, GitLab, ...), the way
Zig's autodoc or rustdoc work for their ecosystems.  A companion Haunt
site-builder module renders a directory of Markdown docs, including that
generated reference, into a static HTML site, working around two gaps in
Haunt/guile-commonmark that a docs site runs into immediately: no GFM
pipe-table support, and a directory-scanning builder that crashes on any
non-Markdown file placed alongside your docs.")
  (home-page "https://github.com/9s-l-s9/guile-autodoc")
  (license license:gpl3+))
