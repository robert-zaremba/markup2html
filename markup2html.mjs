#!/usr/bin/env bun
// markup2html.mjs — render a Markdown (.md) or Org (.org) document to a
// standalone RFC-styled HTML page. CLI replacement for contrib/markup2html.sh;
// markup2html.el invokes the same script from Emacs.
//
// Usage:
//   markup2html.mjs [-o OUTPUT] [--css FILE] <input.md | input.org>
//   markup2html.mjs --html [--title TITLE] [--meta "KEY: VAL"]... [--h1]
//                [-o OUTPUT] [--css FILE] < body.html
//
// In file mode, Markdown bodies are rendered with the marked version
// vendored next to this script (marked.esm.js, pinned so output stays
// byte-stable) and Org bodies with batch Emacs. In --html mode the body
// is ready-made HTML read from stdin and only assembled into the page
// shell; markup2html.el pipes in-process Org exports this way. The base stylesheet (rfc-style.css) is
// inlined; github-markdown-css and the highlight.js theme layer on top
// via pinned CDN links. Pages with mermaid diagrams, code fences or
// sections load the corresponding client-side enhancers; everything else
// stays script-free.

import { parseArgs } from "node:util";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { marked } from "./marked.esm.js";

const VERSION = "1.0.0";
const here = dirname(fileURLToPath(import.meta.url));

const CDN_LINKS = `<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/github-markdown-css@5.9.0/github-markdown-light.min.css" integrity="sha384-3eJN7MnSPucsOdiaSfRFVznUcc1JUEkgzZT4He1EMOFayD+GagtU7AVsHkRyRuyd" crossorigin="anonymous">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@11.12.0/styles/github.min.css" integrity="sha384-eFTL69TLRZTkNfYZOLM+G04821K1qZao/4QLJbet1pP4tcF+fdXq/9CdqAbWRl/L" crossorigin="anonymous">
`;

const TOC_SCAFFOLD = `<nav id="toc" aria-label="Table of contents"><div class="toc-title">Contents</div><ul></ul></nav>
<button id="toc-toggle" type="button" aria-controls="toc" aria-expanded="true">✕</button>
`;

const MERMAID_JS = `<script type="module">
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
`;

const HLJS_JS = `<script src="https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@11.12.0/highlight.min.js" integrity="sha384-wjfDDhOPPdjtva8vWBhWeVprSpmxisEu5aYT3q1JyACqXpdKpo3PWZTMVq24MBix" crossorigin="anonymous"></script>
<script>
for (const code of document.querySelectorAll("pre > code[class*=language-]:not(.language-mermaid)")) {
	hljs.highlightElement(code);
}
</script>
`;

const TOC_JS = `<script>
(() => {
	const toc = document.getElementById("toc");
	if (!toc) return;
	const list = toc.querySelector("ul");
	const slugs = new Set();
	const slug = (t) => {
		let s = t.toLowerCase().trim().replace(/[^a-z0-9\\s-]/g, "").replace(/\\s+/g, "-");
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
`;

// Batch-export the org file (SRC env) to body-only HTML (OUT env).
// toc/section-numbers off: the page shell renders its own title and the
// TOC is built client-side.
const ORG_EXPORT_ELISP = `(progn
	(require 'org)
	(require 'ox-html)
	(setq create-lockfiles nil make-backup-files nil)
	(let ((buffer (find-file-noselect (getenv "SRC") t)))
		(with-current-buffer buffer
			(let ((output (org-export-as 'html nil nil t '(:with-toc nil :section-numbers nil))))
				(with-temp-file (getenv "OUT") (insert output))))
		(kill-buffer buffer)))`;

const usage = (out = console.error) =>
	out(`Usage: markup2html.mjs [-o OUTPUT] [--css FILE] <input.md | input.org>
       markup2html.mjs --html [--title TITLE] [--meta "KEY: VAL"]... [--h1]
                     [-o OUTPUT] [--css FILE] < body.html

Render a Markdown (.md) or Org (.org) document — or ready-made HTML from
stdin (--html) — to a standalone styled HTML page. Writes the page to
stdout; -o writes it to a file instead.

Options:
  -o, --output FILE   write to FILE instead of stdout
  --css FILE          stylesheet to inline instead of the packaged one
  --html              assemble the page shell around HTML from stdin
  --title TITLE       page title (--html mode)
  --meta "KEY: VAL"   meta table row, repeatable (--html mode)
  --h1                also render the title as a heading (--html mode)
  -h, --help          show this help
  -v, --version       show the version
`);

const escapeHtml = (s) =>
	s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

// "KEY: VAL" argument of --html mode (the first colon splits; leading
// spaces of the value are stripped). Values arrive final: FILETAGS come
// pre-transformed.
function parseMetaArg(arg) {
	const idx = arg.indexOf(":");
	if (idx <= 0) {
		console.error(`error: --meta expects "KEY: VAL", got: ${arg}`);
		process.exit(1);
	}
	return [arg.slice(0, idx), arg.slice(idx + 1).replace(/^ +/, "")];
}

// Optional YAML front matter: a leading --- block, stripped and returned as
// key/value rows (like GitHub). Lines without a colon are skipped; a single
// leading space is stripped from values.
function parseFrontMatter(lines) {
	if (lines[0] !== "---") return { rows: [], bodyLines: lines };
	const end = lines.findIndex((l, i) => i > 0 && /^---[ \t]*$/.test(l));
	if (end === -1) return { rows: [], bodyLines: lines };
	const rows = [];
	for (const line of lines.slice(1, end)) {
		const idx = line.indexOf(":");
		if (idx <= 0) continue;
		let val = line.slice(idx + 1);
		if (val.startsWith(" ")) val = val.slice(1);
		if (val.endsWith("\r")) val = val.slice(0, -1);
		rows.push([line.slice(0, idx), val]);
	}
	return { rows, bodyLines: lines.slice(end + 1) };
}

// Leading #+KEYWORD: header lines as meta rows (like md front matter).
// TITLE is skipped (it becomes the page title); FILETAGS renders as a
// comma-separated list.
function parseOrgKeywords(lines) {
	const rows = [];
	for (const line of lines) {
		if (line === "") break;
		const m = line.match(/^#\+([A-Za-z0-9_-]+):[ \t]*(.*)$/);
		if (!m) break;
		const [, key, raw] = m;
		if (key === "TITLE") continue;
		let val = raw;
		if (val === "") continue;
		if (key === "FILETAGS") val = val.replace(/^:/, "").replace(/:$/, "").replace(/:/g, ", ");
		rows.push([key, val]);
	}
	return rows;
}

function extractTitle(lines, ext, stem) {
	for (const line of lines) {
		if (ext === "md" && /^# /.test(line)) return line.replace(/^# */, "");
		if (ext === "org" && /^#\+TITLE:/.test(line)) return line.replace(/^#\+TITLE:\s*/, "");
	}
	return stem;
}

function renderMarkdownBody(text) {
	// Keep the body newline-terminated, like the `marked` CLI output.
	return marked.parse(text, { gfm: true }) + "\n";
}

function renderOrgBody(input) {
	const dir = mkdtempSync(join(tmpdir(), "markup2html-"));
	const bodyPath = join(dir, "body.html");
	const r = spawnSync("emacs", ["--batch", "-Q", "--eval", ORG_EXPORT_ELISP], {
		env: { ...process.env, SRC: resolve(input), OUT: bodyPath },
		encoding: "utf8",
	});
	if (r.error && r.error.code === "ENOENT") {
		console.error("error: emacs not found");
		process.exit(2);
	}
	if (r.status !== 0 || !existsSync(bodyPath)) {
		console.error(`error: emacs org export failed for ${input}`);
		if (r.stderr) console.error(r.stderr.trim());
		rmSync(dir, { recursive: true, force: true });
		process.exit(3);
	}
	const body = readFileSync(bodyPath, "utf8");
	rmSync(dir, { recursive: true, force: true });
	return body;
}

function metaTable(rows) {
	const cells = rows.map(
		([k, v]) => `<td><strong>${escapeHtml(k)}</strong></td>\n<td>${escapeHtml(v)}</td>`,
	);
	return `<table>\n<tbody><tr>\n${cells.join("\n</tr>\n<tr>\n")}\n</tr>\n</tbody></table>\n`;
}

function assemble({ title, rows, body, injectH1, css }) {
	const esc = escapeHtml(title);
	const hasMermaid = /language-mermaid|src-mermaid/.test(body);
	const hasToc = /<h[234]/.test(body);
	const hasCode = /<code class="language-/.test(body);
	let html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc}</title>
<style>
${css}</style>
${CDN_LINKS}</head>
`;
	html += hasToc ? '<body class="toc-open">\n' : "<body>\n";
	if (hasToc) html += TOC_SCAFFOLD;
	html += '<main class="rfc markdown-body">\n';
	if (rows.length) html += metaTable(rows);
	if (injectH1) html += `<h1>${esc}</h1>\n`;
	html += body;
	html += "</main>\n";
	if (hasMermaid) html += MERMAID_JS;
	if (hasCode) html += HLJS_JS;
	if (hasToc) html += TOC_JS;
	html += "</body>\n</html>\n";
	return html;
}

function main() {
	let values;
	let positionals;
	try {
		({ values, positionals } = parseArgs({
			allowPositionals: true,
			options: {
				output: { type: "string", short: "o" },
				css: { type: "string" },
				html: { type: "boolean" },
				title: { type: "string" },
				meta: { type: "string", multiple: true },
				h1: { type: "boolean" },
				help: { type: "boolean", short: "h" },
				version: { type: "boolean", short: "v" },
			},
		}));
	} catch (err) {
		console.error(`error: ${err.message}`);
		usage();
		process.exit(1);
	}
	if (values.help) {
		usage(console.log);
		return;
	}
	if (values.version) {
		console.log(`markup2html ${VERSION}`);
		return;
	}

	const cssPath = values.css ? resolve(values.css) : join(here, "rfc-style.css");
	const css = readFileSync(cssPath, "utf8");
	let output = values.output;

	let title;
	let rows;
	let body;
	let injectH1;
	if (values.html) {
		// Assembly-only mode: the body arrives as ready-made HTML on stdin
		// (markup2html.el pipes in-process Org exports here).
		if (positionals.length) {
			console.error("error: --html reads the body from stdin; no input file allowed");
			process.exit(1);
		}
		body = readFileSync(0, "utf8");
		rows = (values.meta ?? []).map(parseMetaArg);
		title = values.title ?? "";
		injectH1 = values.h1 === true;
	} else {
		if (values.meta || values.title || values.h1) {
			console.error("error: --title/--meta/--h1 require --html");
			process.exit(1);
		}
		const input = positionals[0];
		if (!input) {
			usage();
			process.exit(1);
		}
		if (!existsSync(input)) {
			console.error(`error: file not found: ${input}`);
			process.exit(1);
		}
		const ext = extname(input).slice(1);
		if (ext !== "md" && ext !== "org") {
			console.error(`error: unsupported extension .${ext}, expected .md or .org`);
			usage();
			process.exit(1);
		}

		const text = readFileSync(input, "utf8");
		const lines = text.split("\n");
		const stem = basename(input, extname(input));

		if (ext === "md") {
			const fm = parseFrontMatter(lines);
			rows = fm.rows;
			body = renderMarkdownBody(fm.bodyLines.join("\n"));
		} else {
			rows = parseOrgKeywords(lines);
			body = renderOrgBody(input);
		}
		title = extractTitle(lines, ext, stem);
		injectH1 = ext === "org";
	}

	const page = assemble({ title, rows, body, injectH1, css });
	if (output && output !== "-") {
		writeFileSync(output, page);
		console.log(`wrote ${output}`);
	} else {
		process.stdout.write(page);
	}
}

main();
