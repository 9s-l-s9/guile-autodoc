;;; SPDX-License-Identifier: GPL-3.0-or-later
;;;
;;; Renders an interactive, three-pane API browser: navigation (left),
;;; documentation -- kind, signature, description (middle), and a sticky
;;; source panel (right) that fills in with the binding's real source text
;;; on click. One self-contained HTML file, vanilla JS, no build step and
;;; no server: every binding's source text is scanned and embedded at
;;; generation time (via (autodoc scan)'s exact start/end line tracking),
;;; so viewing it is a DOM swap, not a fetch.
;;;
;;; Shares its notion of a binding's kind/signature/description/source-link
;;; with (autodoc reference) (the flat Markdown-table view of the same
;;; data) via that module's exports, so the two views can never disagree
;;; about what a given binding's kind or signature actually is.
;;;
;;; Deliberately hand-built HTML strings rather than routed through (haunt
;;; html)'s sxml->html: that serializer HTML-escapes every text node
;;; unconditionally, which is correct for prose but would mangle this
;;; page's own <script> (e.g. any "<" or "&&" in the JS) if the script body
;;; were an SXML string child. Instead, the static CSS/JS below (author-
;;; controlled, no interpolated data) is emitted verbatim, and every piece
;;; of dynamic content (names, docstrings, source text, file paths) is
;;; individually run through `html-escape'.

(define-module (autodoc browser)
  #:use-module (autodoc reference)
  #:use-module (autodoc scan)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-11)
  #:use-module (srfi srfi-13)
  #:export (generate-api-browser))

(define (html-escape s)
  (apply string-append
   (map (lambda (c)
          (case c
            ((#\&) "&amp;")
            ((#\<) "&lt;")
            ((#\>) "&gt;")
            ((#\") "&quot;")
            (else (string c))))
        (string->list s))))

(define %style "
:root{--bg:#fff;--ink:#0a0a0a;--muted:#565656;--soft:#d4d4d4;--accent:#0a0a0a;--code-bg:#f4f4f4}
@media(prefers-color-scheme:dark){:root{--bg:#0a0a0a;--ink:#ededed;--muted:#a0a0a0;--soft:#333;--accent:#ededed;--code-bg:#161616}}
*{box-sizing:border-box}
html,body{margin:0;height:100%}
body{background:var(--bg);color:var(--ink);font:14px/1.5 ui-monospace,'IBM Plex Mono',monospace}
.abr{display:grid;grid-template-columns:240px 1fr 420px;height:100vh}
.abr-nav,.abr-source{overflow-y:auto;padding:14px}
.abr-docs{overflow-y:auto;padding:14px 24px}
.abr-nav{border-right:1px solid var(--soft)}
.abr-source{border-left:1px solid var(--soft);position:sticky;top:0}
.abr-title{font-size:13px;text-transform:uppercase;letter-spacing:.06em;margin:0 0 10px}
#abr-filter{width:100%;padding:6px 8px;margin-bottom:10px;background:var(--bg);color:var(--ink);
            border:1px solid var(--soft);font:inherit}
.abr-nav h2{font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);
            margin:14px 0 4px;border-bottom:1px solid var(--soft);padding-bottom:3px}
.abr-nav ul{list-style:none;margin:0;padding:0}
.abr-jump{display:block;width:100%;text-align:left;background:none;border:0;color:inherit;
          font:inherit;padding:2px 0;cursor:pointer;border-radius:2px}
.abr-jump:hover{text-decoration:underline}
.abr-binding{scroll-margin-top:10px;border-top:1px solid var(--soft);padding:12px 0}
.abr-binding.active{background:color-mix(in srgb,var(--accent) 6%,transparent)}
.abr-binding h3{margin:0 0 4px;font-size:14px}
.abr-binding .kind{color:var(--muted);font-size:11px;text-transform:uppercase;margin-left:8px}
.abr-binding .sig,.abr-binding .desc{margin:4px 0}
.abr-binding .sig code{background:var(--code-bg);padding:1px 5px}
.abr-binding .extra{color:var(--muted);font-size:12px;margin:2px 0}
.abr-binding .extra b{color:inherit;font-weight:600}
.abr-show-source{font:inherit;font-size:11px;text-transform:uppercase;letter-spacing:.04em;
                  background:none;border:1px solid var(--soft);color:inherit;padding:3px 8px;
                  cursor:pointer;margin-top:4px}
.abr-show-source:hover{border-color:var(--accent)}
.abr-source-head{font-size:12px;color:var(--muted);margin-bottom:8px;word-break:break-all}
.abr-source-empty{color:var(--muted)}
.abr-source pre{background:var(--code-bg);padding:10px 12px;overflow-x:auto;margin:0;
                 white-space:pre;font-size:12.5px;line-height:1.5}
@media(max-width:900px){
  .abr{display:block;height:auto}
  .abr-nav,.abr-source{position:static;max-height:40vh}
  .abr-source{border-left:0;border-top:2px solid var(--soft)}
}
")

(define %script "
document.addEventListener('click', function (event) {
  var trigger = event.target.closest('[data-id]');
  if (!trigger) return;
  var article = document.getElementById(trigger.getAttribute('data-id'));
  if (!article) return;
  var panel = document.getElementById('abr-source');
  panel.innerHTML = '';
  var head = document.createElement('div');
  head.className = 'abr-source-head';
  head.textContent = article.getAttribute('data-label') || '';
  panel.appendChild(head);
  var template = article.querySelector('template');
  if (template) {
    panel.appendChild(template.content.cloneNode(true));
  } else {
    var empty = document.createElement('div');
    empty.className = 'abr-source-empty';
    empty.textContent = 'No source location available.';
    panel.appendChild(empty);
  }
  document.querySelectorAll('.abr-binding.active').forEach(function (node) {
    node.classList.remove('active');
  });
  article.classList.add('active');
  if (trigger.classList.contains('abr-jump')) {
    article.scrollIntoView({block: 'center', behavior: 'smooth'});
  }
});
document.getElementById('abr-filter').addEventListener('input', function (event) {
  var needle = event.target.value.toLowerCase();
  document.querySelectorAll('.abr-nav li').forEach(function (item) {
    item.style.display = item.textContent.toLowerCase().includes(needle) ? '' : 'none';
  });
});
")

(define* (generate-api-browser #:key
                               modules
                               source-directory
                               repo-blob-prefix
                               (title "API browser")
                               (extra-columns '())
                               (missing-docstring-text "No docstring is attached.")
                               (documentation-fallback #f)
                               (on-form #f))
  "Return a complete, self-contained HTML document: a three-pane API
browser (navigation, documentation, source) for every export of MODULES.
Keyword arguments match `generate-api-reference' exactly (both read the
same scan); see its docstring for their meaning. REPO-BLOB-PREFIX, if
given, is also used for a plain-text fallback source link shown when a
binding has no scanned source range."
  (define scan (scan-source-files (scan-tree source-directory) #:on-form on-form))
  (define next-id! (let ((n 0)) (lambda () (set! n (+ n 1)) (format #f "b~a" n))))

  ;; A plain link alongside the "View source" button/panel -- useful when JS
  ;; is off, and gives the source panel's embedded text a canonical
  ;; permalink back to the real repository.
  (define (source-fallback-link info)
    (if (and repo-blob-prefix (source-info-file info) (source-info-line info))
        (format #f "<p class=\"extra\"><a href=\"~a~a#L~a\">View on GitHub: ~a:~a</a></p>"
                (html-escape repo-blob-prefix) (html-escape (source-info-file info))
                (source-info-line info)
                (html-escape (source-info-file info)) (source-info-line info))
        ""))

  (define (source-template info)
    (let ((text (source-text info)))
      (if text
          (format #f "<template><pre><code>~a</code></pre></template>" (html-escape text))
          "")))

  (define (source-label module-name name info)
    (html-escape
     (if (and (source-info-file info) (source-info-line info) (source-info-end-line info))
         (format #f "~a  ·  ~a lines ~a-~a" (format #f "~s ~a" module-name name)
                 (source-info-file info) (source-info-line info) (source-info-end-line info))
         (format #f "~s ~a" module-name name))))

  (define (binding-article module-name name value)
    (let* ((info (lookup-source-info scan module-name name))
           (id (next-id!))
           (description (or (binding-documentation module-name name value info documentation-fallback)
                            missing-docstring-text)))
      (values
       id
       (string-append
        "<article id=\"" id "\" class=\"abr-binding\" data-label=\""
        (source-label module-name name info) "\">"
        "<h3><code>" (html-escape (symbol->string name)) "</code>"
        "<span class=\"kind\">" (html-escape (binding-kind value)) "</span></h3>"
        "<p class=\"sig\"><code>" (html-escape (binding-signature name value info)) "</code></p>"
        "<p class=\"desc\">" (html-escape description) "</p>"
        (apply string-append
         (map (lambda (column)
                (string-append
                 "<p class=\"extra\"><b>" (html-escape (car column)) ":</b> "
                 (html-escape ((cdr column) module-name name value info)) "</p>"))
              extra-columns))
        (source-fallback-link info)
        "<button class=\"abr-show-source\" data-id=\"" id "\">View source</button>"
        (source-template info)
        "</article>"))))

  (define (module-section module-name)
    (let ((bindings (module-bindings module-name)))
      (let loop ((bindings bindings) (nav-items '()) (articles '()))
        (if (null? bindings)
            (values (reverse nav-items) (reverse articles))
            (let-values (((id article) (binding-article module-name (caar bindings) (cdar bindings))))
              (loop (cdr bindings)
                    (cons (string-append
                           "<li><button class=\"abr-jump\" data-id=\"" id "\">"
                           (html-escape (symbol->string (caar bindings))) "</button></li>")
                          nav-items)
                    (cons article articles)))))))

  (let loop ((modules modules) (nav-sections '()) (doc-sections '()))
    (if (null? modules)
        (string-append
         "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
         "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
         "<title>" (html-escape title) "</title><style>" %style "</style></head>"
         "<body><div class=\"abr\">"
         "<nav class=\"abr-nav\"><p class=\"abr-title\">" (html-escape title) "</p>"
         "<input id=\"abr-filter\" type=\"search\" placeholder=\"Filter bindings…\">"
         (apply string-append (reverse nav-sections))
         "</nav>"
         "<main class=\"abr-docs\">" (apply string-append (reverse doc-sections)) "</main>"
         "<aside class=\"abr-source\" id=\"abr-source\">"
         "<div class=\"abr-source-empty\">Select a binding to view its source.</div>"
         "</aside>"
         "</div><script>" %script "</script></body></html>\n")
        (let-values (((nav-items articles) (module-section (car modules))))
          (loop (cdr modules)
                (cons (string-append
                       "<h2>" (html-escape (format #f "~s" (car modules))) "</h2><ul>"
                       (apply string-append nav-items) "</ul>")
                      nav-sections)
                (cons (string-append
                       "<section><h2>" (html-escape (format #f "~s" (car modules))) "</h2>"
                       (apply string-append articles) "</section>")
                      doc-sections))))))
