// The differential oracle for the `dom` lowering (docs/design/backend.md
// §15.10): the template strings and walks dom-expressions' compiler emits
// for its own client fixtures, against the ones beni emits for the same
// markup written in beni.
//
//   node extract.mjs refresh <fixtures> <oracle>
//       Re-extract every `<oracle>/<fixture>/expected.txt` from
//       `<fixtures>/<fixture>/output.js` (dom-expressions'
//       `packages/babel-plugin-jsx/test/__dom_fixtures__`), and write
//       `<oracle>/extracted-from.txt`, the SHA-256 of each `output.js` read. Run by hand
//       when the pin of `references/dom-expressions` moves.
//   node extract.mjs stale <fixtures> <oracle>
//       Exit 1 naming each fixture whose `output.js` is no longer the one
//       `extracted-from.txt` records; exit 0 when they all are, or when `<fixtures>` is
//       absent (the submodule is not checked out).
//   node extract.mjs check <oracle>/<fixture> (<module.mjs> | -)
//       Compare beni's emitted module — none, for `-` — with
//       `expected.txt`. A difference
//       must be listed in `differences.txt` — `- <line>` for an entry
//       dom-expressions has and beni does not, `+ <line>` for one beni has
//       and dom-expressions does not, each followed by `  # <reason>` —
//       and every listed difference must still occur. Exit 1 with the
//       unlisted and the stale ones otherwise.
//
// An entry is one clone of a template: the template's flag and string, and
// the walk to each node the code uses — a path of `firstChild` and
// `nextSibling` steps from the clone. A walk variable used only as the base
// of another walk is not a use, so a compiler that declares a walk for
// every node (Babel's `detectExpressions`) and one that declares only what
// it needs agree. Entries are compared as a sorted list, one per line:
//
//   <flag> <JSON template> [<walk> …]
//
// Nothing here parses JavaScript: both compilers print these statements in
// one fixed shape each, which the patterns below read.

import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import process from "node:process";

const escapeRegExp = (s) => s.replace(/[$.*+?^()[\]{}|\\]/g, "\\$&");

// Occurrences of the identifier `name` in `code`.
const count = (code, name) => (code.match(new RegExp(`(?<![\\w$])${escapeRegExp(name)}(?![\\w$])`, "g")) ?? []).length;

// The entries of one module, given how its compiler spells a template, a
// clone and a walk.
function entries(code, templates, clonePattern, walkPattern) {
  const walks = new Map(); // name → { base, steps }
  for (const m of code.matchAll(walkPattern)) walks.set(m[1], { base: m[2], steps: m[3].slice(1).split(".") });
  const bases = new Map();
  for (const w of walks.values()) bases.set(w.base, (bases.get(w.base) ?? 0) + 1);
  const out = [];
  for (const m of code.matchAll(clonePattern)) {
    const clone = m[1];
    const t = templates.get(m[2]);
    if (t === undefined) continue;
    const paths = [];
    for (const [name, w] of walks) {
      // The walk's path from its clone, if it is one of this clone's.
      let steps = [...w.steps];
      let base = w.base;
      while (base !== clone && walks.has(base)) {
        steps = [...walks.get(base).steps, ...steps];
        base = walks.get(base).base;
      }
      if (base !== clone) continue;
      const uses = count(code, name) - 1 - (bases.get(name) ?? 0);
      if (uses > 0) paths.push(steps.join("."));
    }
    paths.sort();
    out.push(`${t.flag} ${JSON.stringify(t.html)}${paths.length ? ` ${paths.join(" ")}` : ""}`);
  }
  // A template cloned where no walk starts from it (`_tmpl$()` in an
  // expression) is an entry of its own.
  return out;
}

// A JavaScript template literal's text, as the string it evaluates to.
const unescapeTemplate = (s) =>
  s.replace(/\\(u\{[0-9a-fA-F]+\}|u[0-9a-fA-F]{4}|x[0-9a-fA-F]{2}|.)/gs, (_, e) => {
    if (e === "n") return "\n";
    if (e === "t") return "\t";
    if (e === "r") return "\r";
    if (e[0] === "u" || e[0] === "x") return String.fromCodePoint(parseInt(e.replace(/[ux{}]/g, ""), 16));
    return e;
  });

function solid(code) {
  const templates = new Map();
  for (const m of code.matchAll(/(_tmpl\$\d*) = \/\*#__PURE__\*\/ _\$template\(\s*`((?:[^`\\]|\\.)*)`(?:,\s*(\d+))?\s*\)/gs)) {
    templates.set(m[1], { html: unescapeTemplate(m[2]), flag: m[3] ?? "0" });
  }
  // A clone is `_el$N = _tmpl$M()`; a clone used in place is `_tmpl$M()`
  // with no variable, whose entry has no walks.
  const list = entries(code, templates, /(_el\$\d*) = (_tmpl\$\d*)\(\)/g, /(_el\$\d*) = (_el\$\d*)((?:\.(?:firstChild|nextSibling))+)(?=[,;\n])/g);
  for (const m of code.matchAll(/(?<!_el\$\d* = )(_tmpl\$\d*)\(\)/g)) {
    const t = templates.get(m[1]);
    if (t !== undefined) list.push(`${t.flag} ${JSON.stringify(t.html)}`);
  }
  return list.sort();
}

function beni(code) {
  const templates = new Map();
  // `template` is the markup runtime's export (`$markup$template`), or the
  // declaration of its runtime module that supplies it (`Rt$template`,
  // backend.md §15.1).
  for (const m of code.matchAll(/const ([\w$]+) = (?:\$markup|[A-Z]\w*)\$template\(("(?:[^"\\]|\\.)*"), (\d+)\);/g)) {
    templates.set(m[1], { html: JSON.parse(m[2]), flag: m[3] });
  }
  return entries(code, templates, /const (r\$\d+) = ([\w$]+)\(\);/g, /const (w\$\d+) = ([rw]\$\d+)((?:\.(?:firstChild|nextSibling))+);/g).sort();
}

const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

function readDifferences(file) {
  const listed = [];
  if (!existsSync(file)) return listed;
  readFileSync(file, "utf8")
    .split("\n")
    .forEach((raw, i) => {
      const line = raw.trimEnd();
      if (line === "" || line.startsWith("#")) return;
      const m = line.match(/^([-+]) (.*?)  # (.+)$/);
      if (!m) throw new Error(`${file}:${i + 1}: not \`- <entry>  # <reason>\` or \`+ <entry>  # <reason>\``);
      listed.push({ side: m[1], entry: m[2], line: i + 1 });
    });
  return listed;
}

// The multiset `a` minus `b`.
function minus(a, b) {
  const left = new Map();
  for (const x of b) left.set(x, (left.get(x) ?? 0) + 1);
  const out = [];
  for (const x of a) {
    const n = left.get(x) ?? 0;
    if (n > 0) left.set(x, n - 1);
    else out.push(x);
  }
  return out;
}

function check(dir, module) {
  const expected = readFileSync(join(dir, "expected.txt"), "utf8").split("\n").filter((l) => l !== "");
  // `-`: a fixture none of whose roots beni can write has no module.
  const actual = module === "-" ? [] : beni(readFileSync(module, "utf8"));
  const found = [
    ...minus(expected, actual).map((entry) => ({ side: "-", entry })),
    ...minus(actual, expected).map((entry) => ({ side: "+", entry })),
  ];
  const listed = readDifferences(join(dir, "differences.txt"));
  const key = (d) => `${d.side} ${d.entry}`;
  const unlisted = minus(found.map(key), listed.map(key));
  const stale = minus(listed.map(key), found.map(key));
  if (unlisted.length === 0 && stale.length === 0) return 0;
  const report = [];
  if (unlisted.length !== 0) report.push(`${dir}: differences not listed in differences.txt:`, ...unlisted.map((l) => `  ${l}`));
  if (stale.length !== 0) report.push(`${dir}: listed in differences.txt but no longer different:`, ...stale.map((l) => `  ${l}`));
  process.stderr.write(`${report.join("\n")}\n`);
  return 1;
}

const [mode, a, b] = process.argv.slice(2);
if (mode === "refresh") {
  const source = [];
  for (const fixture of readdirSync(b, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name).sort()) {
    const bytes = readFileSync(join(a, fixture, "output.js"));
    writeFileSync(join(b, fixture, "expected.txt"), `${solid(bytes.toString("utf8")).join("\n")}\n`);
    source.push(`${sha256(bytes)}  ${fixture}/output.js`);
  }
  writeFileSync(join(b, "extracted-from.txt"), `${source.join("\n")}\n`);
} else if (mode === "stale") {
  if (!existsSync(a)) process.exit(0);
  const moved = [];
  for (const line of readFileSync(join(b, "extracted-from.txt"), "utf8").split("\n")) {
    const m = line.match(/^([0-9a-f]{64})  (.+)$/);
    if (!m) continue;
    const file = join(a, m[2]);
    if (!existsSync(file) || sha256(readFileSync(file)) !== m[1]) moved.push(m[2]);
  }
  if (moved.length !== 0) {
    process.stderr.write(`the dom-expressions fixtures moved; re-extract with \`node tests/oracle/extract.mjs refresh …\`:\n${moved.map((f) => `  ${f}`).join("\n")}\n`);
    process.exit(1);
  }
} else if (mode === "check") {
  process.exit(check(a, b));
} else if (mode === "solid" || mode === "beni") {
  const lines = (mode === "solid" ? solid : beni)(readFileSync(a, "utf8"));
  process.stdout.write(`${lines.join("\n")}\n`);
} else {
  process.stderr.write("usage: node extract.mjs (refresh <fixtures> <oracle> | stale <fixtures> <oracle> | check <dir> <module.mjs> | solid <output.js> | beni <module.mjs>)\n");
  process.exit(2);
}
