// A deterministic mutation fuzzer for the front end. NOT part of any gate —
// a useful campaign takes minutes, and `zig build test-blackbox` must stay
// fast. Run it by hand when the lexer, parser, layout or formatter changes.
//
//   node tests/fuzz.mjs ./zig-out/bin/beni <scratch-dir> check 110
//   node tests/fuzz.mjs ./zig-out/bin/beni <scratch-dir> fmt   44
//   node tests/fuzz.mjs ./zig-out/bin/beni ./zig-out/bin/beni  dump  33
//
// Arguments: the binary, a scratch directory it may delete, the mode, the
// number of mutants per seed (default 11), then the paths to take seeds
// from (default `tests/corpus`). Seeds are the `.beni` files under those
// paths that check CLEAN, found by running `check` on each; the ones that
// need `--platform=node` are discovered rather than listed.
//
// Every mutant is a pure function of (seed path, mutant index), so a finding
// replays exactly. Eleven operators are applied round-robin by index, so
// every seed gets every kind: delete / duplicate / swap / insert a token,
// truncate, flip a byte, re-indent a line by ±1..8, delete or duplicate a
// line, delete or insert a byte span (which can land mid-UTF-8, mid-string
// or mid-comment).
//
// A mutant is FINE when the binary exits 0, or exits 1 with at least one
// well-formed diagnostic whose span lies inside the file. Everything else is
// printed as one JSON line on stdout: a signal, the timeout, the memory cap,
// an exit code outside {0,1}, a diagnostic whose code is `internal`, an
// empty diagnostic list on exit 1, unparsable JSON under
// `--diagnostics=json`, a span outside the file or with end before start.
// `check` mode additionally requires the two parsers to AGREE: a mutant
// `check` accepts, `fmt` must format. `fmt` mode additionally requires that
// a REFUSED in-place format leaves the input byte-identical.
//
// Environment: FUZZ_JOBS (default 28), FUZZ_STACK (mutations per mutant,
// default 1 — raise it to walk further off the valid manifold), FUZZ_VCAP
// (`ulimit -v`, default 12000000 KB; a deep `--stage=ast` dump alone peaks
// near 2.1 GB of virtual address space, so a smaller cap reports the cap
// rather than the compiler), FUZZ_TIMEOUT (seconds, default 20).
import { execFile } from "node:child_process";
import { mkdirSync, writeFileSync, readFileSync, readdirSync, rmSync, statSync } from "node:fs";
import { basename, join } from "node:path";

const [, , BENI, WORK, MODE, N, ...ROOTS] = process.argv;
const perSeed = Number(N ?? 11);
const roots = ROOTS.length ? ROOTS : ["tests/corpus"];

// --- deterministic PRNG -----------------------------------------------------
function hash(s) { let h = 2166136261 >>> 0; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619) >>> 0; } return h; }
function rng(seed) { let a = seed >>> 0; return () => { a = (a + 0x6d2b79f5) >>> 0; let t = a; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; }; }
const pick = (r, xs) => xs[Math.floor(r() * xs.length)];
const int = (r, lo, hi) => lo + Math.floor(r() * (hi - lo)); // [lo, hi)

const VOCAB = ["(", ")", "[", "]", "{", "}", ",", ".", ":", "=", "->", "|", "\\", "_", "?", "<-", "|>", "<|", "==", "+", "-", "*", "/", "^", "::", "\"", "'", "${", "--", "--|", "--!", "if", "then", "else", "case", "of", "let", "in", "type", "alias", "pub", "opaque", "import", "as", "exposing", "foreign", "where", "x", "Foo", "0", "1e9", "0xFF"];
const TOKEN = /[A-Za-z_][A-Za-z0-9_]*|[0-9][0-9a-zA-Z._]*|"(?:\\.|[^"\\])*"?|'(?:\\.|[^'\\])*'?|--[^\n]*|\s+|[^\sA-Za-z0-9_]/g;

function mutate(src, r, op) {
  const toks = src.match(TOKEN) ?? [src];
  const lines = src.split("\n");
  const b = Buffer.from(src, "binary");
  switch (op) {
    case 0: { const i = int(r, 0, toks.length), n = int(r, 1, 6); return toks.slice(0, i).concat(toks.slice(i + n)).join(""); }
    case 1: { const i = int(r, 0, toks.length); return toks.slice(0, i).concat([toks[i], toks[i]], toks.slice(i + 1)).join(""); }
    case 2: { const i = int(r, 0, Math.max(1, toks.length - 1)); const c = toks.slice(); [c[i], c[i + 1]] = [c[i + 1], c[i]]; return c.join(""); }
    case 3: { const i = int(r, 0, toks.length); return toks.slice(0, i).concat([pick(r, VOCAB)], toks.slice(i)).join(""); }
    case 4: return src.slice(0, int(r, 0, src.length + 1));
    case 5: { const i = int(r, 0, Math.max(1, b.length)); const c = Buffer.from(b); c[i] = int(r, 0, 256); return c.toString("binary"); }
    case 6: { const i = int(r, 0, lines.length); const d = int(r, 1, 9), sign = r() < 0.5 ? -1 : 1; const c = lines.slice();
      c[i] = sign > 0 ? " ".repeat(d) + c[i] : c[i].replace(new RegExp(`^ {0,${d}}`), ""); return c.join("\n"); }
    case 7: { const i = int(r, 0, lines.length); return lines.slice(0, i).concat(lines.slice(i + 1)).join("\n"); }
    case 8: { const i = int(r, 0, lines.length); return lines.slice(0, i).concat([lines[i], lines[i]], lines.slice(i + 1)).join("\n"); }
    case 9: { const i = int(r, 0, Math.max(1, b.length)), n = int(r, 1, 9); return Buffer.concat([b.subarray(0, i), b.subarray(i + n)]).toString("binary"); }
    default: { const i = int(r, 0, Math.max(1, b.length)); return Buffer.concat([b.subarray(0, i), Buffer.from([int(r, 0, 256)]), b.subarray(i)]).toString("binary"); }
  }
}

// --- running ----------------------------------------------------------------
const SH = `ulimit -v ${process.env.FUZZ_VCAP ?? 12000000}; exec timeout -s KILL ${process.env.FUZZ_TIMEOUT ?? 20} "$0" "$@"`;
const run = (args, cwd) => new Promise((res) =>
  execFile("/bin/sh", ["-c", SH, BENI, ...args], { cwd, maxBuffer: 1 << 26, encoding: "buffer", timeout: 120000 },
    (e, o, s) => res({ code: e ? (e.code ?? 1) : 0, signal: e?.signal ?? null, stdout: o, stderr: s.toString("binary") })));

function spansOk(text, diags) {
  const lens = text.split("\n").map((l) => Buffer.byteLength(l, "binary"));
  for (const d of diags) {
    const s = d.span?.start, e = d.span?.end;
    if (!s || !e) return `span missing on ${d.code}`;
    for (const [w, p] of [["start", s], ["end", e]]) {
      if (p.line < 1 || p.line > lens.length) return `${d.code}: ${w}.line ${p.line} outside 1..${lens.length}`;
      if (p.col < 1 || p.col > lens[p.line - 1] + 1) return `${d.code}: ${w} ${p.line}:${p.col} past the line's ${lens[p.line - 1]} bytes`;
    }
    if (e.line < s.line || (e.line === s.line && e.col < s.col)) return `${d.code}: end ${e.line}:${e.col} before start ${s.line}:${s.col}`;
  }
  return null;
}

function classify(r, text) {
  if (r.signal || typeof r.code === "string") return `signal:${r.signal ?? r.code}`;
  if (r.code === 137 || r.code === 124) return "timeout-or-memory-cap";
  if (/panic|Unable to dump stack trace|SIGSEGV|reached unreachable/i.test(r.stderr)) return "panic";
  if (r.code !== 0 && r.code !== 1) return `exit:${r.code}`;
  if (r.code === 0) return null;
  let diags;
  try { diags = JSON.parse(Buffer.from(r.stderr, "binary").toString("utf8")); } catch { return "malformed-json"; }
  if (!Array.isArray(diags) || diags.length === 0) return "empty-diagnostics-on-exit-1";
  if (diags.some((d) => d.code === "internal")) return "internal-diagnostic";
  return spansOk(text, diags);
}

// --- seeds ------------------------------------------------------------------
function beniFiles(dir, out = []) {
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) beniFiles(p, out);
    else if (e.name.endsWith(".beni")) out.push(p);
  }
  return out;
}

const pool = Number(process.env.FUZZ_JOBS ?? 28);
async function pooled(items, body) {
  let i = 0;
  await Promise.all([...Array(pool).keys()].map(async (id) => { for (;;) { const k = i++; if (k >= items.length) return; await body(items[k], id); } }));
}

const candidates = roots.flatMap((r) => (statSync(r).isDirectory() ? beniFiles(r) : [r])).sort();
const seeds = [];
await pooled(candidates, async (f, id) => {
  const dir = join(WORK, `s${id}`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, basename(f)), readFileSync(f));
  const plain = await run(["check", "--jobs=1", basename(f)], dir);
  if (plain.code === 0 && !plain.stderr.length) return void seeds.push({ file: f, platform: false });
  const plat = await run(["check", "--jobs=1", "--platform=node", basename(f)], dir);
  if (plat.code === 0 && !plat.stderr.length) seeds.push({ file: f, platform: true });
});
seeds.sort((a, b) => (a.file < b.file ? -1 : 1));
process.stderr.write(`${seeds.length} clean seeds of ${candidates.length} files; ${seeds.length * perSeed} mutants\n`);

// --- the campaign -----------------------------------------------------------
const jobs = seeds.flatMap((s) => [...Array(perSeed).keys()].map((k) => ({ ...s, k })));
const findings = [];
let done = 0;
await pooled(jobs, async (j, id) => {
  const dir = join(WORK, `m${id}`);
  mkdirSync(dir, { recursive: true });
  const name = basename(j.file);
  const src = readFileSync(j.file, "binary");
  const r = rng(hash(j.file) ^ Math.imul(j.k + 1, 0x9e3779b1));
  let text = mutate(src, r, j.k % 11);
  for (let s = 1; s < Number(process.env.FUZZ_STACK ?? 1); s++) text = mutate(text, r, int(r, 0, 11));
  const path = join(dir, name);
  writeFileSync(path, Buffer.from(text, "binary"));
  const plat = j.platform ? ["--platform=node"] : [];
  const record = (what, extra) => findings.push({ file: j.file, k: j.k, op: j.k % 11, mode: MODE, what, ...extra });

  if (MODE === "check") {
    const c = await run(["check", "--jobs=1", "--diagnostics=json", ...plat, name], dir);
    const bad = classify(c, text);
    if (bad) record(bad, { stderr: c.stderr.slice(0, 300) });
    else if (c.code === 0) {
      const f = await run(["fmt", "--stdout", name], dir);
      if (f.code !== 0) record("check-accepts-fmt-refuses", { fmtCode: f.code, stderr: f.stderr.slice(0, 300) });
    }
  } else if (MODE === "fmt") {
    const before = readFileSync(path);
    const f = await run(["fmt", "--diagnostics=json", name], dir); // in place
    const bad = classify(f, text);
    if (bad) record(bad, { stderr: f.stderr.slice(0, 300) });
    if (f.code !== 0 && Buffer.compare(before, readFileSync(path)) !== 0) record("refused-fmt-rewrote-the-file", { code: f.code });
  } else {
    // `--platform` is REFUSED on the stages that resolve nothing (`beni help`).
    for (const stage of ["tokens", "ast", "bir"]) {
      const d = await run(["dump", `--stage=${stage}`, "--diagnostics=json", name], dir);
      if (d.signal || typeof d.code === "string") record(`signal:${d.signal ?? d.code}`, { stage });
      else if (d.code === 137 || d.code === 124) record("timeout-or-memory-cap", { stage });
      else if (/panic|Unable to dump stack trace|reached unreachable/i.test(d.stderr)) record("panic", { stage, stderr: d.stderr.slice(0, 300) });
      else if (![0, 1, 2].includes(d.code)) record(`exit:${d.code}`, { stage });
    }
  }
  if (++done % 2000 === 0) process.stderr.write(`${done}/${jobs.length}\n`);
});

for (const f of findings) console.log(JSON.stringify(f));
process.stderr.write(`ran ${done} mutants, ${findings.length} findings\n`);
process.exitCode = findings.length ? 1 : 0;
