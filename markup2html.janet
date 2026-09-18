#!/usr/bin/env janet
# markup2html.janet — render a Markdown (.md) or Org (.org) document, or
# ready-made HTML read from stdin, to a standalone RFC-styled HTML page.
#
# Usage:
#   markup2html.janet [-o OUTPUT] [--css FILE] <input.md | input.org>
#   markup2html.janet --html [--title TITLE] [--meta "KEY: VAL"]... [--h1]
#                  [-o OUTPUT] [--css FILE] < body.html
#
# Markdown bodies are rendered with the `marked` CLI and Org bodies with
# batch Emacs; --html mode only assembles the page shell around the HTML
# body from stdin. The base stylesheet (rfc-style.css) is inlined;
# github-markdown-css and the highlight.js theme layer on top via pinned
# CDN links. Pages with mermaid diagrams, code fences or sections load the
# corresponding client-side enhancers; everything else stays script-free.
#
# Janet's process API has no PATH lookup, stdout piping or reliable env
# overrides, so child processes run through /bin/sh -c with shell
# redirections and SRC/OUT assignments.

(def VERSION "0.3.0")

(defn find-last [pat s]
  (let [xs (string/find-all pat s)]
    (unless (empty? xs) (last xs))))

(def script-dir
  (if-let [i (find-last "/" (or (dyn :current-file) ""))]
    (string/slice (dyn :current-file) 0 i)
    "."))

# Longstrings are raw and drop the final newline; each constant appends
# its trailing "\n" explicitly.
(def CDN-LINKS (string `<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/github-markdown-css@5.9.0/github-markdown-light.min.css" integrity="sha384-3eJN7MnSPucsOdiaSfRFVznUcc1JUEkgzZT4He1EMOFayD+GagtU7AVsHkRyRuyd" crossorigin="anonymous">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@11.12.0/styles/github.min.css" integrity="sha384-eFTL69TLRZTkNfYZOLM+G04821K1qZao/4QLJbet1pP4tcF+fdXq/9CdqAbWRl/L" crossorigin="anonymous">
` "\n"))

(def TOC-SCAFFOLD (string `<nav id="toc" aria-label="Table of contents"><div class="toc-title">Contents</div><ul></ul></nav>
<button id="toc-toggle" type="button" aria-controls="toc" aria-expanded="true">✕</button>
` "\n"))

(def MERMAID-JS (string `<script type="module">
import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@12/dist/mermaid.esm.min.mjs";

// Normalize to the <pre class="mermaid"> shape from the docs' recommended setup:
// md fences produce <pre><code class="language-mermaid">, org src blocks <pre class="src src-mermaid">.
const normalize = (pre) => {
	pre.classList.add("mermaid");
	for (const code of pre.querySelectorAll("code")) code.replaceWith(...code.childNodes);
};
for (const code of document.querySelectorAll("pre > code.language-mermaid")) normalize(code.parentElement);
for (const pre of document.querySelectorAll("pre.src-mermaid")) normalize(pre);

mermaid.initialize({
	startOnLoad: false,
	securityLevel: "loose",
});
await mermaid.run({ querySelector: "pre.mermaid" });
</script>
` "\n"))

(def HLJS-JS (string `<script src="https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@11.12.0/highlight.min.js" integrity="sha384-wjfDDhOPPdjtva8vWBhWeVprSpmxisEu5aYT3q1JyACqXpdKpo3PWZTMVq24MBix" crossorigin="anonymous"></script>
<script>
for (const code of document.querySelectorAll("pre > code[class*=language-]:not(.language-mermaid)")) {
	hljs.highlightElement(code);
}
</script>
` "\n"))

(def TOC-JS (string `<script>
(() => {
	const toc = document.getElementById("toc");
	if (!toc) return;
	const list = toc.querySelector("ul");
	const slugs = new Set();
	const slug = (t) => {
		let s = t.toLowerCase().trim().replace(/[^a-z0-9\s-]/g, "").replace(/\s+/g, "-");
		if (s === "") s = "section";
		let u = s;
		let n = 1;
		while (slugs.has(u)) u = s + "-" + n++;
		slugs.add(u);
		return u;
	};
	for (const h of document.querySelectorAll("main.rfc h2, main.rfc h3, main.rfc h4")) {
		if (!h.id) h.id = slug(h.textContent);
		const a = document.createElement("a");
		a.href = "#" + h.id;
		a.textContent = h.textContent;
		const li = document.createElement("li");
		li.className = "toc-h" + h.tagName[1];
		li.appendChild(a);
		list.appendChild(li);
	}
	const btn = document.getElementById("toc-toggle");
	const sync = () => {
		const open = document.body.classList.contains("toc-open");
		btn.textContent = open ? "✕" : "☰";
		btn.setAttribute("aria-expanded", open ? "true" : "false");
	};
	btn.addEventListener("click", () => {
		document.body.classList.toggle("toc-open");
		sync();
	});
	sync();
})();
</script>
` "\n"))

# Batch-export the org file (SRC env) to body-only HTML (OUT env).
# toc/section-numbers off: the page shell renders its own title and the
# TOC is built client-side. (quote ...) is spelled out because the
# snippet is passed through a single-quoted shell argument.
(def ORG-EXPORT-ELISP `(progn
	(require (quote org))
	(require (quote ox-html))
	(setq create-lockfiles nil make-backup-files nil)
	(let ((buffer (find-file-noselect (getenv "SRC") t)))
		(with-current-buffer buffer
			(let ((output (org-export-as (quote html) nil nil t (quote (:with-toc nil :section-numbers nil)))))
				(with-temp-file (getenv "OUT") (insert output))))
		(kill-buffer buffer)))`)

(def org-key-peg
  ~(* "#" "+" (capture (some (+ :w "-"))) ":" (any (+ " " "\t")) (capture (any 1))))
(def meta-arg-peg
  ~(* (capture (some (if-not ":" 1))) ":" (any " ") (capture (any 1))))
(def toc-rx ~(* "<h" (set "234")))

(defn usage [&opt out]
  (default out stderr)
  (file/write out `Usage: markup2html.janet [-o OUTPUT] [--css FILE] <input.md | input.org>
       markup2html.janet --html [--title TITLE] [--meta "KEY: VAL"]... [--h1]
                      [-o OUTPUT] [--css FILE] < body.html

Render a Markdown (.md) or Org (.org) document — or ready-made HTML from
stdin (--html) — to a standalone styled HTML page. Writes <stem>.html
next to the input unless -o is given.

Options:
  -o, --output FILE   output path (required with --html)
  --css FILE          stylesheet to inline instead of the packaged one
  --html              assemble the page shell around HTML from stdin
  --title TITLE       page title (--html mode)
  --meta "KEY: VAL"   meta table row, repeatable (--html mode)
  --h1                also render the title as a heading (--html mode)
  -h, --help          show this help
  -v, --version       show the version
`))

(defn die [msg &opt code]
  (file/write stderr msg "\n")
  (os/exit (or code 1)))

(defn esc [s]
  (reduce (fn [s [from to]] (string/replace-all from to s)) s
          [["&" "&amp;"] ["<" "&lt;"] [">" "&gt;"]]))

# POSIX single-quote: ' -> '\''
(defn shq [s]
  (string "'" (string/replace-all "'" "'\\''" s) "'"))

(defn sh! [cmd]
  (os/proc-wait (os/spawn ["/bin/sh" "-c" cmd])))

(defn tmpname [suffix]
  (string (or (os/getenv "TMPDIR") "/tmp") "/markup2html-"
          (os/time) "-" (os/clock) suffix))

(defn rmf [path]
  (try (os/rm path) ([_] nil)))

(defn slurp-or [path default]
  (if (truthy? (os/stat path)) (slurp path) default))

(defn fm-close? [line]
  (and (string/has-prefix? "---" line)
       (all (fn [b] (or (= b 32) (= b 9))) (string/slice line 3))))

(defn fm-row [line]
  (when-let [idx (string/find ":" line)]
    (when (> idx 0)
      (let [raw (string/slice line (inc idx))
            val (if (string/has-prefix? " " raw) (string/slice raw 1) raw)
            val (if (string/has-suffix? "\r" val) (string/slice val 0 -2) val)]
        [(string/slice line 0 idx) val]))))

# Optional YAML front matter: a leading --- block, stripped and returned as
# key/value rows (like GitHub). Lines without a colon are skipped.
(defn parse-front-matter [lines]
  (def end (if (= (first lines) "---")
              (find-index fm-close? (slice lines 1))))
  (if end
    [(keep fm-row (slice lines 1 (+ end 1))) (slice lines (+ end 2))]
    [@[] lines]))

(defn org-keyword-row [line]
  (when-let [[key val] (peg/match org-key-peg line)]
    (unless (or (= key "TITLE") (empty? val))
      [key (if (= key "FILETAGS")
           (let [v (if (string/has-prefix? ":" val) (string/slice val 1) val)
                 v (if (string/has-suffix? ":" v) (string/slice v 0 -2) v)]
             (string/replace-all ":" ", " v))
           val)])))

# Leading #+KEYWORD: header lines as meta rows (like md front matter).
# TITLE is skipped (it becomes the page title); FILETAGS renders as a
# comma-separated list.
(defn parse-org-keywords [lines]
  (keep org-keyword-row
        (take-while (fn [l] (and (not (empty? l)) (peg/match org-key-peg l)))
                    lines)))

(defn extract-title [lines ext stem]
  (def prefix (if (= ext "md") "# " "#+TITLE:"))
  (or (when-let [line (find |(string/has-prefix? prefix $) lines)]
        (if (= ext "md")
          (string/triml (string/slice line 1) " ")
          (string/triml (string/slice line (length prefix)))))
      stem))

# "KEY: VAL" argument of --html mode. Values arrive final: FILETAGS come
# pre-transformed.
(defn parse-meta-arg [s]
  (or (peg/match meta-arg-peg s)
      (die (string/format "error: --meta expects \"KEY: VAL\", got: %s" s))))

# sh exits 127 when a command is not on PATH.
(defn render-markdown-body [text]
  (let [tmp (tmpname ".md")
        outf (tmpname ".html")
        errf (tmpname ".err")
        code (do (spit tmp text)
                 (sh! (string/format "marked --gfm %s > %s 2> %s"
                                     (shq tmp) (shq outf) (shq errf))))]
    (rmf tmp)
    (cond
      (= code 127) (die "marked not found, install it: bun install -g marked" 2)
      (not= code 0) (let [err (slurp-or errf "")]
                      (rmf errf)
                      (die (string "markup2html: marked failed: " err)))
      (do (rmf errf) (slurp outf)))))

(defn render-org-body [input]
  (let [bodyf (tmpname ".html")
        errf (tmpname ".err")
        code (sh! (string/format "SRC=%s OUT=%s emacs --batch -Q --eval %s 2> %s"
                                 (shq input) (shq bodyf)
                                 (shq ORG-EXPORT-ELISP) (shq errf)))]
    (cond
      (= code 127) (die "error: emacs not found" 2)
      (or (not= code 0) (nil? (slurp-or bodyf nil)))
      (do (file/write stderr "error: emacs org export failed for " input "\n")
          (let [err (slurp-or errf "")]
            (unless (empty? err) (file/write stderr err "\n")))
          (os/exit 3))
      (let [body (slurp bodyf)]
        (rmf bodyf)
        (rmf errf)
        body))))

(defn meta-table [rows]
  (string "<table>\n<tbody><tr>\n"
          (string/join (map (fn [[k v]]
                              (string "<td><strong>" (esc k)
                                      "</strong></td>\n<td>" (esc v) "</td>"))
                            rows)
                       "\n</tr>\n<tr>\n")
          "\n</tr>\n</tbody></table>\n"))

(defn assemble [title rows body inject-h1 css]
  # Appends go through a buffer: growing an immutable string per push
  # would copy the whole page each time.
  (let [t (esc title)
        has-mermaid (truthy? (or (string/find "language-mermaid" body)
                                 (string/find "src-mermaid" body)))
        has-toc (truthy? (peg/find toc-rx body))
        has-code (truthy? (string/find "<code class=\"language-" body))
        buf @""]
  (buffer/push buf
               "<!DOCTYPE html>\n"
               "<html lang=\"en\">\n"
               "<head>\n"
               "<meta charset=\"utf-8\">\n"
               "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
               "<title>" t "</title>\n"
               "<style>\n" css "</style>\n"
               CDN-LINKS "</head>\n")
  (if has-toc
    (buffer/push buf "<body class=\"toc-open\">\n" TOC-SCAFFOLD)
    (buffer/push buf "<body>\n"))
  (buffer/push buf "<main class=\"rfc markdown-body\">\n")
  (when (next rows) (buffer/push buf (meta-table rows)))
  (when inject-h1 (buffer/push buf "<h1>" t "</h1>\n"))
  (buffer/push buf body "</main>\n")
  (when has-mermaid (buffer/push buf MERMAID-JS))
  (when has-code (buffer/push buf HLJS-JS))
  (when has-toc (buffer/push buf TOC-JS))
  (buffer/push buf "</body>\n</html>\n")
  (string buf)))

(defn parse-opts [argv]
  (def value-opts {"-o" :output "--output" :output
                   "--css" :css "--title" :title "--meta" :meta})
  (def flag-opts {"--html" :html "--h1" :h1
                  "-h" :help "--help" :help "-v" :version "--version" :version})
  (def opts @{:meta @[]})
  (var i 0)
  (while (< i (length argv))
    (def a (argv i))
    (def vopt (in value-opts a))
    (def fopt (in flag-opts a))
    (cond
      vopt (do
            (++ i)
            (unless (< i (length argv)) (die (string "error: missing value for " a)))
            (if (= vopt :meta)
              (array/push (opts :meta) (argv i))
              (put opts vopt (argv i))))

      fopt (put opts fopt true)

      (and (> (length a) 1) (string/has-prefix? "-" a))
      (die (string "error: unknown option: " a))

      (opts :input)
      (die (string "error: unexpected argument: " a))

      (put opts :input a))
    (++ i))
  opts)

# File mode: returns [rows body title inject-h1 stem].
(defn parse-input [input]
  (unless (truthy? (os/stat input))
    (die (string "error: file not found: " input)))
  (let [base (if-let [i (find-last "/" input)] (string/slice input (inc i)) input)
        dot (find-last "." base)
        ext (if dot (string/slice base (inc dot)))
        stem (if dot (string/slice base 0 dot) base)]
    (unless (or (= ext "md") (= ext "org"))
      (file/write stderr (string/format "error: unsupported extension .%s, expected .md or .org\n"
                                        (or ext "")))
      (usage)
      (os/exit 1))
    (let [lines (string/split "\n" (slurp input))]
      (if (= ext "md")
        (let [[fm-rows body-lines] (parse-front-matter lines)]
          [fm-rows
           (render-markdown-body (string/join body-lines "\n"))
           (extract-title lines ext stem)
           false
           stem])
        [(parse-org-keywords lines)
         (render-org-body input)
         (extract-title lines ext stem)
         true
         stem]))))

# The runtime calls a script-defined `main` after loading; args are read
# from (dyn :args).
(defn main [& _]
  (def opts (parse-opts (slice (dyn :args) 1)))
  (when (opts :help) (usage stdout) (os/exit 0))
  (when (opts :version) (print "markup2html " VERSION) (os/exit 0))

  (def html-mode (truthy? (opts :html)))
  (when html-mode
    (when (opts :input)
      (die "error: --html reads the body from stdin; no input file allowed"))
    (unless (opts :output) (die "error: --html requires -o OUTPUT")))
  (unless html-mode
    (when (or (opts :title) (opts :h1) (not (empty? (opts :meta))))
      (die "error: --title/--meta/--h1 require --html"))
    (unless (opts :input) (usage) (os/exit 1)))

  (def [rows body title inject-h1 stem]
    (if html-mode
      [(map parse-meta-arg (opts :meta))
       (file/read stdin :all)
       (or (opts :title) "")
       (truthy? (opts :h1))
       nil]
      (parse-input (opts :input))))

  (let [css (slurp (or (opts :css) (string script-dir "/rfc-style.css")))
        output (or (opts :output)
                   (let [dir (if-let [i (find-last "/" (opts :input))]
                               (string/slice (opts :input) 0 i)
                               ".")]
                     (string (if (= dir ".") stem (string dir "/" stem)) ".html")))]
    (spit output (assemble title rows body inject-h1 css))
    (print "wrote " output)))
