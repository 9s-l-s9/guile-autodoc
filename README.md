# guile-autodoc

A cross-linked API reference generator and static doc-site builder for
Guile Scheme projects, in the spirit of Zig's autodoc or rustdoc: docs
that go *to* code, not just *about* it. Every documented binding links to
its exact definition line in your repository's source view.

As far as we've found, Guile has nothing else like this today — the
ecosystem mostly leans on Texinfo manuals and docstrings read in a REPL.
This project came out of documenting [SchemeWM](https://github.com/9s-l-s9/scheme-wayland-wm),
a Wayland compositor with an embedded Guile policy layer, and was pulled
out because the problem (and the fix) isn't specific to that project.

## What it does

- **`(autodoc scan)`** reads a tree of `.scm` files with Guile's own
  reader (never `load`s or evaluates them — safe for code with real
  side effects at definition time, like a compositor). For every
  top-level `define`, `define*`, and `define-record-type` binding, it
  records the signature as written, the leading docstring if any, and
  the exact source file and line (`read-enable 'positions`, not a
  regex).

- **`(autodoc reference)`** cross-references that scan against a
  project's *live*, loaded modules (`module-map`, `resolve-interface`)
  to generate a Markdown API reference: one table per module, one row
  per actual export, with a `Source` column linking to
  `your-repo/blob/main/path/to/file.scm#L123`. Live reflection is the
  ground truth for what's actually exported (it can't lie about
  re-exports the way hand-maintained docs can drift); the scan fills in
  what reflection alone can't — `define*` keyword-argument names and
  source locations.

- **`(autodoc site)`** renders a directory of plain Markdown docs
  (including the generated reference) into a static site with
  [Haunt](https://dthompson.us/projects/haunt.html), working around two
  gaps that bite immediately: Haunt's own `flat-pages` builder crashes on
  any non-Markdown file sitting next to your docs, and its bundled
  `guile-commonmark` reader has no GFM pipe-table support. Internal
  `.md` cross-links are rewritten to `.html` automatically.

## Quick start

```scheme
;; doc/haunt.scm
(use-modules (autodoc site) (autodoc reference) (haunt site))

;; Write your generated reference into doc/generated/api.md however you
;; already run scripts (a `make docs` target, a shell script, whatever):
;;   (generate-api-reference #:modules '((my-project widgets)
;;                                       (my-project layout))
;;                           #:source-directory "src"
;;                           #:repo-blob-prefix
;;                           "https://github.com/you/my-project/blob/main/")

(site #:title "my-project"
      #:builders (list (docs-pages "." #:template default-template))
      #:build-directory "_site")
```

```sh
guix shell -m manifest.scm -- haunt build   # from doc/
```

See `tests/smoke-test.scm` for a runnable example that generates a
reference against an arbitrary project's already-loadable modules.

## Status

Early and extracted for reuse, not yet published to Guix proper. Install
by adding this checkout to `GUILE_LOAD_PATH`, or build it with
`guix build -f guix.scm`.

`(autodoc reference)`'s `extra-columns` keyword is the escape hatch for
anything project-specific this library has no opinion about — a demo/
example id, a stability tier, whatever your project tracks per binding
that a generic tool shouldn't guess at.

## License

GPL-3.0-or-later.
