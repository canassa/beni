// The playground page's own modules, under Node (docs/design/playground.md
// §4.2, §4.5, §6). `tests/blackbox/playground_page_test.zig` runs each mode
// and reads the exit code; a failure prints what differed.
//
//   node tests/wasm/page_test.mjs positions <source> <diagnostics.json> <text>…
//       each diagnostic's range in <source> holds the <text> of its place
//   node tests/wasm/page_test.mjs share
//       the shareable link gives back every source it was made from
//   node tests/wasm/page_test.mjs syntax
//       the grammar names the tokens of each line as the test says
//   node tests/wasm/page_test.mjs vendor
//       every vendored editor module is the bytes `SHA256SUMS` names, and
//       `index.html`'s import map names each module and nothing else
import { createHash } from "node:crypto";
import { readFileSync, readdirSync } from "node:fs";
import { rangeOf } from "../../playground/positions.js";
import { decode, encode, maxSource } from "../../playground/share.js";
import { copyState, startState, token } from "../../playground/syntax.js";

/// The tokens of `lines`, as `[text, name]`, with the state carried from
/// line to line as CodeMirror's `StreamLanguage` carries it.
function tokenize(lines) {
  let state = startState();
  const out = [];
  for (const line of lines) {
    const stream = new Stream(line);
    while (!stream.eol()) {
      stream.start = stream.pos;
      const name = token(stream, state);
      if (stream.pos === stream.start) throw new Error(`no progress at ${stream.pos} of ${JSON.stringify(line)}`);
      if (name !== null) out.push([stream.current(), name]);
    }
    state = copyState(state);
  }
  return out;
}

/// The part of CodeMirror's `StringStream` the grammar and the Elm mode it
/// extends use, over one line, as `@codemirror/language` defines them.
class Stream {
  constructor(string) {
    this.string = string;
    this.pos = 0;
    this.start = 0;
  }
  eol() {
    return this.pos >= this.string.length;
  }
  peek() {
    return this.string.charAt(this.pos) || undefined;
  }
  next() {
    return this.pos < this.string.length ? this.string.charAt(this.pos++) : undefined;
  }
  eat(match) {
    const ch = this.string.charAt(this.pos);
    const ok = typeof match === "string" ? ch === match : ch !== "" && (match instanceof RegExp ? match.test(ch) : match(ch));
    if (!ok) return undefined;
    this.pos += 1;
    return ch;
  }
  eatWhile(match) {
    const start = this.pos;
    while (this.eat(match) !== undefined);
    return this.pos > start;
  }
  skipTo(ch) {
    const found = this.string.indexOf(ch, this.pos);
    if (found === -1) return undefined;
    this.pos = found;
    return true;
  }
  eatSpace() {
    const start = this.pos;
    while (/[\s ]/.test(this.string.charAt(this.pos))) this.pos += 1;
    return this.pos > start;
  }
  skipToEnd() {
    this.pos = this.string.length;
  }
  match(pattern, consume = true) {
    if (typeof pattern === "string") {
      if (!this.string.startsWith(pattern, this.pos)) return null;
      if (consume) this.pos += pattern.length;
      return true;
    }
    const m = this.string.slice(this.pos).match(pattern);
    if (m === null || m.index > 0) return null;
    if (consume) this.pos += m[0].length;
    return m;
  }
  column() {
    return this.start;
  }
  indentation() {
    return this.string.search(/\S|$/);
  }
  current() {
    return this.string.slice(this.start, this.pos);
  }
}

const [mode, ...args] = process.argv.slice(2);
let failures = 0;
const check = (ok, what) => {
  if (!ok) {
    failures += 1;
    process.stderr.write(`FAIL ${what}\n`);
  }
};

if (mode === "positions") {
  const [sourcePath, diagnosticsPath, ...expected] = args;
  const text = readFileSync(sourcePath, "utf8");
  const diagnostics = JSON.parse(readFileSync(diagnosticsPath, "utf8"));
  check(diagnostics.length === expected.length, `${diagnostics.length} diagnostics, expected ${expected.length}`);
  diagnostics.forEach((d, i) => {
    const { from, to } = rangeOf(text, d.span);
    const got = text.slice(from, to);
    check(got === expected[i], `${d.code} at ${JSON.stringify(d.span)} marks ${JSON.stringify(got)}, expected ${JSON.stringify(expected[i])}`);
  });
} else if (mode === "share") {
  const sources = ["", "main = 1\n", "-- → ⊤ ≠ ▷ … 😀\nx = \"😀\"\n", "x".repeat(100_000), Array.from({ length: 2_000 }, (_, i) => `v${i} = ${i}`).join("\n")];
  for (const platform of ["browser-direct", "node"]) {
    for (const source of sources) {
      const back = await decode(`#${await encode(platform, source)}`);
      check(back !== null && back.platform === platform && back.source === source, `${platform} ${JSON.stringify(source.slice(0, 40))} round trip`);
    }
  }
  check((await decode("#platform=node&code=@@@@")) === null, "a code that is not base64url is no program");
  const huge = await encode("node", "x".repeat(maxSource + 1));
  check(huge.length < 10_000, `a long source compresses to a short link (${huge.length} bytes)`);
  check((await decode(huge)) === null, "a link that inflates past maxSource is no program");
  const largest = "y".repeat(maxSource);
  check((await decode(await encode("node", largest)))?.source === largest, "a link of exactly maxSource opens");
  check((await decode("#platform=node")) === null, "a fragment with no code is no program");
  check((await decode("")) === null, "no fragment is no program");
} else if (mode === "syntax") {
  // Lines, and the name the grammar gives each piece of them (null for
  // none), in order; a piece not listed is not checked.
  const cases = [
    [["-- a comment"], [["-- a comment", "lineComment"]]],
    [["--| a doc comment"], [["--| a doc comment", "docComment"]]],
    [["case kind of"], [["case", "keyword"], ["kind", "variable"], ["of", "keyword"]]],
    [["type alias Model ="], [["type", "keyword"], ["alias", "keyword"], ["Model", "type"], ["=", "operator"]]],
    [['"a${b}c"'], [['"', "string"], ["a", "string"], ["${", "meta"], ["b", "variable"], ["}", "meta"], ['c"', "string"]]],
    [['"tab\\tend"'], [['"', "string"], ["tab", "string"], ["\\t", "escape"], ['end"', "string"]]],
    [["x = 'a'"], [["'a'", "string"]]],
    [["n = 0x1F + 2.5e3"], [["0x1F", "number"], ["+", "operator"], ["2.5e3", "number"]]],
    [["f : Int, Int → Int"], [["→", "operator"]]],
    [["λx → x ▷ g"], [["λ", "operator"], ["▷", "operator"]]],
    [["b = True ≠ False"], [["True", "bool"], ["≠", "operator"], ["False", "bool"]]],
    [["u = ⊤"], [["⊤", "atom"]]],
    [["v = model.todos"], [["model", "variable"], [".todos", "propertyName"]]],
    [["    \\\\raw ${x} text"], [["\\\\raw ${x} text", "string"]]],
    // A comparison after an operand, markup where an operand may start.
    [["less = a <b"], [["a", "variable"], ["<", "operator"], ["b", "variable"]]],
    [
      ['    <button onClick={Increment}>-</button>'],
      [["<button", "tagName"], ["onClick", "attributeName"], ["=", "operator"], ["{", "brace"], ["Increment", "type"], ["}", "brace"], [">", "tagName"], ["-", "content"], ["</button", "tagName"], [">", "tagName"]],
    ],
    [['    <span>{count}</span>'], [["<span", "tagName"], [">", "tagName"], ["{", "brace"], ["count", "variable"], ["}", "brace"], ["</span", "tagName"]]],
    // Children are text: an inline element after text is a tag, and an
    // apostrophe or a `--` in text is text (frontend.md §9.3).
    [["<p>Hello <b>world</b> -- don't</p>"], [["Hello ", "content"], ["<b", "tagName"], ["world", "content"], ["</b", "tagName"], [" -- don't", "content"], ["</p", "tagName"]]],
    [["<>", "    <li>one</li>", "</>"], [["<", "tagName"], [">", "tagName"], ["<li", "tagName"], ["one", "content"], ["</li", "tagName"], ["</", "tagName"]]],
    [["<hr /> < limit"], [["<hr", "tagName"], ["/>", "tagName"], ["<", "operator"], ["limit", "variable"]]],
    [["<input -- a comment", "    value={v} />"], [["<input", "tagName"], ["-- a comment", "lineComment"], ["value", "attributeName"], ["v", "variable"], ["/>", "tagName"]]],
    [["let x = 1 in <div />"], [["in", "keyword"], ["<div", "tagName"]]],
    [["ok = f x? <y"], [["?", "operator"], ["<", "operator"], ["y", "variable"]]],
    // §2.5: no underscores; `schema` and `where` are keywords only where
    // they start their forms.
    [["n = 1_000"], [["1", "number"], ["_", "keyword"]]],
    [["schema Person ="], [["schema", "keyword"], ["Person", "type"]]],
    [["where = 1"], [["where", "def"]]],
    [["sort : List a → List a where a.compare : a, a → Order"], [["where", "keyword"], ["a", "variable"], [".compare", "propertyName"]]],
    // A string does not go on to the next line, and an interpolation's
    // state does.
    [['s = "open', "next = 1"], [['"', "string"], ["open", "string"], ["next", "def"], ["1", "number"]]],
      // The Elm mode's own names: a name at the start of a line is a
    // definition, and Elm's `module` and `port` are names in beni.
    [["update : Msg, Model → Model"], [["update", "def"], [":", "operator"], ["Msg", "type"], [",", "punctuation"], ["Model", "type"], ["→", "operator"]]],
    [["x = module port"], [["module", "variable"], ["port", "variable"]]],
    // beni's keywords that Elm lacks, and the rest of the notation.
    [["pub foreign opaque"], [["pub", "keyword"], ["foreign", "keyword"], ["opaque", "keyword"]]],
    [["t = a ≠ b ≤ c ≥ d ◁ e ← f … g × h ⊥"], [["≠", "operator"], ["≤", "operator"], ["≥", "operator"], ["◁", "operator"], ["←", "operator"], ["…", "operator"], ["×", "operator"], ["⊥", "atom"]]],
    [["r = { x = 1 }"], [["{", "brace"], ["x", "variable"], ["}", "brace"]]],
  ];
  for (const [lines, expected] of cases) {
    const got = tokenize(lines);
    let at = 0;
    for (const [piece, name] of expected) {
      while (at < got.length && got[at][0] !== piece) at += 1;
      check(at < got.length && got[at][1] === name, `${JSON.stringify(lines)}: ${JSON.stringify(piece)} is ${JSON.stringify(at < got.length ? got[at][1] : "missing")}, expected ${JSON.stringify(name)}; tokens ${JSON.stringify(got)}`);
      at += 1;
    }
  }
} else if (mode === "vendor") {
  // Paths are the repository's: `tests/blackbox/playground_page_test.zig`
  // runs this from the repository root.
  const vendor = "playground/vendor";
  const sums = new Map(
    readFileSync(`${vendor}/SHA256SUMS`, "utf8")
      .trim()
      .split("\n")
      .map((line) => line.split(/\s+/))
      .map(([sum, file]) => [file, sum]),
  );
  const modules = readdirSync(vendor).filter((f) => f.endsWith(".js")).sort();
  check(modules.length > 0 && sums.size === modules.length, `a sum for each module (${modules.length} modules, ${sums.size} sums)`);
  for (const file of modules) {
    const sum = createHash("sha256").update(readFileSync(`${vendor}/${file}`)).digest("hex");
    check(sums.get(file) === sum, `${file} is the bytes SHA256SUMS names`);
  }
  const html = readFileSync("playground/index.html", "utf8");
  const map = JSON.parse(/<script type="importmap">([\s\S]*?)<\/script>/.exec(html)[1]).imports;
  const targets = Object.values(map).map((url) => url.replace(/^\.\/vendor\//, "")).sort();
  check(JSON.stringify(targets) === JSON.stringify(modules), `the import map names each vendored module once: ${JSON.stringify(targets)}`);
  // Every bare import inside a vendored module is a name the map resolves:
  // a new pin that adds a dependency fails here, not in a browser.
  for (const file of modules) {
    const text = readFileSync(`${vendor}/${file}`, "utf8");
    for (const [, spec] of text.matchAll(/^(?:import|export)\b[^;]*?\bfrom\s*['"]([^'"]+)['"]/gm)) {
      if (spec.startsWith(".")) continue;
      check(Object.hasOwn(map, spec), `${file} imports ${spec}, which the import map resolves`);
    }
  }
  for (const [name, url] of Object.entries(map)) {
    check(url.startsWith("./vendor/"), `${name} loads from the site (${url})`);
    // By file: a subpath such as `@codemirror/legacy-modes/mode/elm` is one
    // file of its package.
    const file = url.slice("./vendor/".length);
    check(readFileSync("playground/vendor/LICENSES.txt", "utf8").includes(`== ${file}: ${name.split("/").slice(0, name.startsWith("@") ? 2 : 1).join("/")} `), `LICENSES.txt holds ${name}'s licence`);
  }
} else {
  process.stderr.write("usage: node tests/wasm/page_test.mjs (positions <source> <diagnostics.json> <text>… | share | syntax | vendor)\n");
  process.exit(2);
}
process.exitCode = failures === 0 ? 0 : 1;
