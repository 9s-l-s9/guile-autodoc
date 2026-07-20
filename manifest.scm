;; Development environment.
;; Usage: guix shell -m manifest.scm
(specifications->manifest
 '("guile"
   "haunt"            ; propagates guile-commonmark
   "guile-commonmark"))
