#!/usr/bin/env bun
// Slims the vendored marked.esm.js: removes machinery markup2html never uses
// (Marked.use/extensions, walkTokens, async parsing, hooks, the extra API
// surface, pedantic/breaks rule tables). Run after re-vendoring upstream;
// every cut asserts its markers exist exactly once, so upstream drift fails
// loudly instead of silently corrupting the file.
//
// Usage: bun slim-marked.mjs <path/to/marked.esm.js>   (rewrites in place)
import { readFileSync, writeFileSync } from "node:fs";

const target = process.argv[2];
if (!target) {
	console.error("Usage: bun slim-marked.mjs <marked.esm.js>");
	process.exit(1);
}
let src = readFileSync(target, "utf8");
const before = src.length;

function cutOnce(startMarker, endMarker, replacement) {
	const start = src.indexOf(startMarker);
	if (start === -1) throw new Error(`marker not found: ${startMarker.slice(0, 40)}`);
	const end = src.indexOf(endMarker, start);
	if (end === -1) throw new Error(`end marker not found: ${endMarker.slice(0, 40)}`);
	src = src.slice(0, start) + replacement + src.slice(end);
}

function replaceOnce(from, to) {
	const first = src.indexOf(from);
	if (first === -1 || src.indexOf(from, first + 1) !== -1) {
		throw new Error(`marker not unique: ${from.slice(0, 40)}`);
	}
	src = src.slice(0, first) + to + src.slice(first + from.length);
}

function replaceAll(from, to) {
	const parts = src.split(from);
	if (parts.length < 2) throw new Error(`marker not found: ${from.slice(0, 40)}`);
	src = parts.join(to);
}

// Drop the Hooks class (options.hooks stays null forever).
cutOnce("var P=class{", "var D=class{", "");
replaceAll("Hooks=P;", "");

// Drop Marked.walkTokens and Marked.use; the constructor no longer calls use.
// markup2html only calls marked.parse(text, {gfm:true}).
cutOnce("constructor(...e){this.use(...e)}walkTokens(e,t){", "setOptions(e){", "constructor(){}");

// Lean parseMarkdown: sync-only, no hooks/async/walkTokens dispatch.
cutOnce(
	"parseMarkdown(e){return(n,r)=>{",
	"onError(e,t){",
	'parseMarkdown(e){return(n,r)=>{let s={...this.defaults,...r},a=this.onError(!!s.silent);' +
		'if(typeof n>"u"||n===null)return a(new Error("marked(): input parameter is undefined or null"));' +
		'if(typeof n!="string")return a(new Error("marked(): input parameter is of type "+Object.prototype.toString.call(n)+", string expected"));' +
		"try{let l=(e?x.lex:x.lexInline)(n,s),c=(e?b.parse:b.parseInline)(l,s);return c}catch(o){return a(o)}}}",
);

// Trim the API surface to what markup2html imports: the `marked` function.
cutOnce(
	"var L=new D;",
	"//# sourceMappingURL=",
	'var L=new D;function g(u,e){return L.parse(u,e)}g.parse=g;export{g as marked};\n',
);

// Drop the pedantic and breaks rule tables; gfm/non-gfm remain selectable.
// The table objects reference named regex-table variables; unreferenced
// ones become dead and are cut with a balanced-brace scan (regex literals
// in the tables keep their braces balanced).
function cutBalanced(anchor) {
	const first = src.indexOf(anchor);
	if (first === -1 || src.indexOf(anchor, first + 1) !== -1) {
		throw new Error(`anchor not unique: ${anchor}`);
	}
	let depth = 0;
	let i = src.indexOf("{", first);
	for (let j = i; j < src.length; j++) {
		if (src[j] === "{") depth++;
		else if (src[j] === "}") {
			depth--;
			if (depth === 0) {
				src = src.slice(0, first) + src.slice(j + 1);
				return;
			}
		}
	}
	throw new Error(`unbalanced braces at: ${anchor}`);
}
replaceAll("B={normal:K,gfm:Me,pedantic:ze}", "B={normal:K,gfm:Me}");
replaceAll("E={normal:X,gfm:N,breaks:et,pedantic:Ye}", "E={normal:X,gfm:N}");
cutBalanced(",ze={");
cutBalanced(",Ye={");
cutBalanced(",et={");

// Rule selection: gfm toggles the gfm tables; no pedantic/breaks variants.
replaceOnce(
	"this.options.pedantic?(t.block=B.pedantic,t.inline=E.pedantic):this.options.gfm&&(t.block=B.gfm,this.options.breaks?t.inline=E.breaks:t.inline=E.gfm)",
	"this.options.gfm&&(t.block=B.gfm,t.inline=E.gfm)",
);

// Provenance note under the upstream header comment.
const note =
	"/* Slimmed for markup2html (see slim-marked.mjs): removed Marked.use/extensions,\n" +
	"   walkTokens, async parsing, hooks and the pedantic/breaks rule tables —\n" +
	"   markup2html only calls marked.parse(text, {gfm: true}). */\n";
const headerEnd = src.indexOf("*/", src.indexOf("*/") + 1); // after the DO NOT EDIT block
if (headerEnd === -1) throw new Error("header comments not found");
const insertAt = headerEnd + 3;
if (!src.startsWith("/* Slimmed for markup2html", insertAt)) {
	src = src.slice(0, insertAt) + "\n" + note + src.slice(insertAt);
}

writeFileSync(target, src);
console.log(`marked.esm.js: ${before} -> ${src.length} bytes (-${before - src.length})`);
