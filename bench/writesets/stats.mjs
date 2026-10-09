// The S0 stats gate of the direct platform (docs/design/browser-direct.md
// §11, §13 kill criterion 1, §14 S0; the format is the §16 amendment of
// 2026-10-09), reported in docs/design/research/64-direct-platform-stats-gate.md.
//
// It reads `beni dump --stage=writes` over every program the criterion names
// — research 61's TEA corpus (classify.mjs's list), the table app, TodoMVC,
// Conduit's Main and its eight pages as programs of their own (research 62's
// Pages.beni) — and evaluates every sub-criterion of kill criterion 1:
//
//   bounded   Conduit's leaf keys bounded, against two thirds
//   static    the share of message constructors under a `*` key, against 5 %,
//             on Conduit and on every corpus app
//   dynamic   the share of the dispatches of Conduit's three corpus scripts
//             (tests/corpus/browser/tea/Conduit{Reader,Editor,Tour}) whose key
//             is `*`, against 10 %
//   roots     value roots per program, against 3 and 5 % of its sites
//   pairs     (key, group) pairs ÷ bounded keys on the program with the most
//             keys, against 2× the median program's
//   trie      whether the trie's write half ships where §13 assumed it does not
//
// The dynamic count is the harness's own: the script builds Conduit for
// `browser-tea` in development, adds ONE statement to its copy of the emitted
// `Main.mjs` — at the head of `Main$update`, logging the message's constructor
// tags into the driver's transcript — and runs tests/browser/driver.mjs on each
// script. Nothing of the compiler, the platform or the fixtures changes.
//
//   BENI=zig-out/bin/beni node bench/writesets/stats.mjs [--json]
//
// About a minute: two dozen dumps, one Conduit build and three page runs, and
// eight small builds for the trie.

import { execFileSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { brotliCompressSync, constants } from "node:zlib";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const beni = path.resolve(repo, process.env.BENI ?? "zig-out/bin/beni");
const work = path.join(repo, "zig-out/writesets-stats");
const asJson = process.argv.includes("--json");
const rel = (p) => path.relative(repo, p);

rmSync(work, { recursive: true, force: true });
mkdirSync(work, { recursive: true });

// ---- The dump, parsed --------------------------------------------------------

function dump(target, platform = "browser-tea") {
  return execFileSync(beni, ["dump", "--stage=writes", `--platform=${platform}`, target], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], maxBuffer: 1 << 28 });
}

function parse(text, source) {
  const progs = [];
  let cur = null;
  let pendingKey = null;
  const classRe = /^\s+(\*|exact|indexed|structural)( \(cap [^)]*\))*\s+/;
  for (const line of text.split("\n")) {
    if (line.startsWith("program ")) {
      const m = line.match(/^program (?:<unrecognised> \((\S+)\)|(\S+) : (\S+))/);
      cur = { source, name: m[1] ?? m[2], kind: m[3] ?? "unrecognised", keys: [], lists: [] };
      progs.push(cur);
      continue;
    }
    if (!cur) continue;
    let m;
    if (pendingKey !== null && (m = line.match(classRe))) {
      cur.keys.push({ name: pendingKey, cls: m[1] });
      pendingKey = null;
      continue;
    }
    if ((m = line.match(/^  key (.*?)\s{2,}(\*|exact|indexed|structural)( \(cap [^)]*\))*\s/))) cur.keys.push({ name: m[1].trim(), cls: m[2] });
    else if ((m = line.match(/^  key (.*)$/))) pendingKey = m[1].trim();
    else if ((m = line.match(/^  keys (\d+): bounded (\d+)/))) Object.assign(cur, { n: +m[1], bounded: +m[2] });
    else if ((m = line.match(/^  sites (\d+): unique (\d+), shared (\d+), instanced (\d+), value (\d+)/))) Object.assign(cur, { sites: +m[1], unique: +m[2], shared: +m[3], instanced: +m[4], value: +m[5] });
    else if ((m = line.match(/^  carriers (.*)$/))) cur.carriers = m[1];
    else if ((m = line.match(/^  constructors (\d+): under \* (\d+)/))) Object.assign(cur, { ctors: +m[1], ctorsStar: +m[2] });
    else if ((m = line.match(/^  pairs (\d+) over (\d+) keys and (\d+) groups.*every key calls (\d+)/))) Object.assign(cur, { pairs: +m[1], pairKeys: +m[2], groups: +m[3], every: +m[4] });
    else if ((m = line.match(/^  list (\S+)\s+(reconciler|positional|scripts)(.*)$/))) cur.lists.push({ at: m[1], verdict: m[2], keys: m[3].trim() });
    else if ((m = line.match(/^  reconciler (\d+) of (\d+) lists/))) Object.assign(cur, { reconciled: +m[1], keyedLists: +m[2] });
    else if ((m = line.match(/^  patchAll (.*)$/))) cur.patchAll = m[1];
    else if (line === "  view (cap W)") cur.viewCapped = true;
  }
  // An unrecognised program prints one `*` key and no `keys` line.
  for (const p of progs) if (p.n === undefined) Object.assign(p, { n: 1, bounded: 0, keys: [{ name: "*", cls: "*" }] });
  return progs;
}

// ---- The programs ------------------------------------------------------------

const tea = path.join(repo, "tests/corpus/browser/tea");
const corpus = [];
for (const f of readdirSync(tea).sort()) {
  const p = path.join(tea, f);
  if (f.endsWith(".beni")) corpus.push({ target: p, platform: "browser-tea" });
  else if (statSync(p).isDirectory()) {
    if (existsSync(path.join(p, "_expected.sources"))) continue; // Conduit's scripts: Conduit is below
    const plat = path.join(p, "platform");
    corpus.push({ target: p, platform: existsSync(plat) ? plat : "browser-tea" });
  }
}
const table = { target: path.join(repo, "bench/ui/apps/beni"), platform: "browser-tea" };
const todomvc = { target: path.join(repo, "bench/todomvc/apps/beni"), platform: "browser-tea" };
// Conduit and its pages in one directory: `dump` takes one path.
const conduitDir = path.join(work, "conduit-src");
cpSync(path.join(repo, "examples/conduit/src"), conduitDir, { recursive: true });
cpSync(path.join(repo, "bench/writesets/conduit/Pages.beni"), path.join(conduitDir, "Pages.beni"));

const programs = [];
for (const c of corpus) for (const p of parse(dump(c.target, c.platform), rel(c.target))) programs.push({ ...p, set: "corpus" });
for (const p of parse(dump(table.target), rel(table.target))) programs.push({ ...p, set: "table" });
for (const p of parse(dump(todomvc.target), rel(todomvc.target))) programs.push({ ...p, set: "todomvc" });
for (const p of parse(dump(conduitDir), "examples/conduit/src")) programs.push({ ...p, set: p.name.startsWith("Main.") ? "conduit" : "page" });
const conduit = programs.find((p) => p.set === "conduit");
const label = (p) => `${p.source.replace(/^tests\/corpus\/browser\/tea\//, "")} ${p.name}`;
const pct = (a, b) => (b === 0 ? 0 : (100 * a) / b);

// ---- bounded -----------------------------------------------------------------

const bounded = { n: conduit.n, bounded: conduit.bounded, share: pct(conduit.bounded, conduit.n), fires: 3 * conduit.bounded < 2 * conduit.n };

// ---- static ------------------------------------------------------------------

const staticRows = programs
  .filter((p) => p.set !== "page")
  .map((p) => ({ program: label(p), set: p.set, ctors: p.ctors, star: p.ctorsStar, share: pct(p.ctorsStar, p.ctors), starKeys: p.keys.filter((k) => k.cls === "*").map((k) => k.name) }));
const staticOver = staticRows.filter((r) => r.share > 5);

// ---- roots -------------------------------------------------------------------

const rootRows = programs.map((p) => ({ program: label(p), set: p.set, sites: p.sites, value: p.value, share: pct(p.value, p.sites) }));
const rootOver = rootRows.filter((r) => r.value > 3 || r.share > 5);

// ---- pairs -------------------------------------------------------------------

// The series: every program with a bounded key, ordered by key count.
const series = programs
  .filter((p) => p.pairKeys > 0)
  .map((p) => ({ program: label(p), set: p.set, keys: p.pairKeys, pairs: p.pairs, groups: p.groups, ratio: p.pairs / p.pairKeys }))
  .sort((a, b) => a.keys - b.keys || a.program.localeCompare(b.program));
const largest = series[series.length - 1];
const lowerMedian = series[Math.floor((series.length - 1) / 2)];
const upperMedian = series[Math.floor(series.length / 2)];
// Least squares on log pairs against log keys: the growth exponent.
const pts = series.filter((s) => s.pairs > 0).map((s) => [Math.log(s.keys), Math.log(s.pairs)]);
const mx = pts.reduce((s, [x]) => s + x, 0) / pts.length;
const my = pts.reduce((s, [, y]) => s + y, 0) / pts.length;
const slope = pts.reduce((s, [x, y]) => s + (x - mx) * (y - my), 0) / pts.reduce((s, [x]) => s + (x - mx) ** 2, 0);
const pairs = {
  programs: series.length,
  excluded: programs.filter((p) => !(p.pairKeys > 0)).map(label),
  largest,
  lowerMedian,
  upperMedian,
  limitLower: 2 * lowerMedian.ratio,
  limitUpper: 2 * upperMedian.ratio,
  fires: largest.ratio > 2 * lowerMedian.ratio || largest.ratio > 2 * upperMedian.ratio,
  slope,
};

// ---- dynamic -----------------------------------------------------------------

function dynamicShare() {
  const out = path.join(work, "conduit-dev");
  execFileSync(beni, ["build", "--platform=browser-tea", "--no-cache", `--out=${out}`, path.join(repo, "examples/conduit/src")], { stdio: ["ignore", "pipe", "pipe"] });
  const mainFile = path.join(out, "Main.mjs");
  const src = readFileSync(mainFile, "utf8");
  const head = /^const Main\$update = \((\w+\$\d+), \w+\$\d+\) => \{$/m;
  const m = src.match(head);
  if (m === null) throw new Error("stats: Main$update's head is not where the harness looks for it");
  // The message's constructor tags, nested through its arguments.
  const log = `globalThis.__beniHarness?.log.push("(dispatch " + JSON.stringify((function k(v, d) { return d > 8 || v === null || typeof v !== "object" || typeof v.$ !== "string" ? 0 : [v.$, k(v.a, d + 1), k(v.b, d + 1), k(v.c, d + 1), k(v.d, d + 1)]; })(${m[1]}, 0)) + ")");`;
  writeFileSync(mainFile, src.replace(head, (h) => `${h}\n  ${log}`));
  // A key name as steps: `GotProfileMsg · CompletedFeedLoad#1 · Ok`.
  const keys = conduit.keys.map((k) => ({
    name: k.name,
    star: k.cls === "*",
    steps: k.name.split(" · ").map((s) => {
      const mm = s.match(/^(.*?)(?:#(\d+))?$/);
      return { ctor: mm[1], arg: mm[2] === undefined ? 0 : +mm[2] };
    }),
  }));
  // The most specific key a message matches: named steps first, `_` last.
  const match = (tags) => {
    let best = null;
    let bestScore = -1;
    for (const k of keys) {
      let node = tags;
      let score = 0;
      let ok = true;
      for (const s of k.steps) {
        if (!Array.isArray(node)) { ok = false; break; }
        if (s.ctor !== "_") {
          if (node[0] !== s.ctor) { ok = false; break; }
          score++;
        }
        node = node[1 + s.arg];
      }
      if (ok && score > bestScore) { best = k; bestScore = score; }
    }
    return best;
  };
  const scripts = ["ConduitReader", "ConduitEditor", "ConduitTour"];
  const rows = [];
  for (const s of scripts) {
    let text;
    try {
      text = execFileSync("node", [path.join(repo, "tests/browser/driver.mjs"), `--dom=${path.join(repo, "tests/browser/happy-dom.mjs")}`, path.join(out, "_main.mjs"), path.join(tea, s, "_expected.steps")], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], maxBuffer: 1 << 28 });
    } catch (e) {
      text = e.stdout; // the transcript so far; a driver failure is reported below
      rows.push({ script: s, error: String(e.stderr).split("\n")[0] });
    }
    const counts = new Map();
    let total = 0;
    let star = 0;
    let unmatched = 0;
    for (const line of text.split("\n")) {
      const mm = line.match(/^\(dispatch (.*)\)$/);
      if (!mm) continue;
      total++;
      const k = match(JSON.parse(mm[1]));
      if (k === null) { unmatched++; continue; }
      if (k.star) star++;
      counts.set(k.name, (counts.get(k.name) ?? 0) + 1);
    }
    rows.push({ script: s, dispatches: total, star, unmatched, share: pct(star, total), keys: Object.fromEntries([...counts].sort((a, b) => b[1] - a[1])) });
  }
  const runs = rows.filter((r) => r.dispatches !== undefined);
  const total = runs.reduce((s, r) => s + r.dispatches, 0);
  const star = runs.reduce((s, r) => s + r.star, 0);
  return { scripts: rows, dispatches: total, star, share: pct(star, total), fires: pct(star, total) > 10 };
}

// ---- trie --------------------------------------------------------------------

// The trie's write half: what only `List`'s writers name (backend.md §4,
// *the read/write split*).
const writeHalf = ["fromPlain", "triePrepend", "triePushed", "triePush", "trieSet", "triePop"];

function bundleBytes(dir) {
  const walk = (d) => readdirSync(d).sort().flatMap((f) => {
    const p = path.join(d, f);
    return statSync(p).isDirectory() ? walk(p) : /\.m?js$/.test(f) ? [readFileSync(p, "utf8")] : [];
  });
  const all = Buffer.from(walk(dir).join("\n"));
  return brotliCompressSync(all, { params: { [constants.BROTLI_PARAM_QUALITY]: 11, [constants.BROTLI_PARAM_SIZE_HINT]: all.length } }).length;
}

function trieOf(name, source) {
  const dir = path.join(work, "trie", name);
  mkdirSync(dir, { recursive: true });
  const file = path.join(dir, "Main.beni");
  writeFileSync(file, source);
  const dev = path.join(dir, "dev");
  const relOut = path.join(dir, "release");
  execFileSync(beni, ["build", "--platform=browser-tea", "--no-cache", `--out=${dev}`, file], { stdio: ["ignore", "pipe", "pipe"] });
  execFileSync(beni, ["build", "--platform=browser-tea", "--no-cache", "--release", `--out=${relOut}`, file], { stdio: ["ignore", "pipe", "pipe"] });
  const list = path.join(dev, "_core/List.mjs");
  const text = existsSync(list) ? readFileSync(list, "utf8") : "";
  return { program: name, ships: writeHalf.filter((f) => text.includes(`List$${f} = `)), bytes: bundleBytes(relOut) };
}

function trie() {
  const tableSrc = readFileSync(path.join(repo, "bench/ui/apps/beni/Main.beni"), "utf8");
  // The table app with its building loop's prepend taken out, as S3's
  // building-loop rule (§7.2) would leave it: the rows built by a reader
  // (`indexedMap` over `repeat`), so the one writer left is `Add`'s `++`.
  const build = /^build : Int, Int, Int → List Row × Int\n[\s\S]*?\n\n\nreplace :/m;
  if (!build.test(tableSrc)) throw new Error("stats: the table app's `build` is not where the harness looks for it");
  const noPrepend = tableSrc.replace(
    build,
    `build : Int, Int, Int → List Row × Int
build count id seed =
    ( List.indexedMap (List.repeat 0 count) λi _ → rowAt (id + i) (after seed (3 * i)), after seed (3 * count) )


after : Int, Int → Int
after seed n =
    if n ≤ 0 then
        seed
    else
        after (next seed) (n - 1)


rowAt : Int, Int → Row
rowAt id seed =
    a = next seed

    c = next a

    n = next c
    { id = id, label = "\${pick adjectives 25 a} \${pick colours 11 c} \${pick nouns 13 n}" }


replace :`,
  );
  // And without `Add`'s `++` too: the floor the two are measured against.
  const noWriter = noPrepend.replace("rows = model.rows ++ rows,", "rows = rows,");
  if (noWriter === noPrepend) throw new Error("stats: the table app's `Add` is not where the harness looks for it");
  // A program whose one list write is `List.set` on a list long enough to
  // birth a trie, and its twin that writes the element by `indexedMap`.
  const setOnly = (write) => `import Browser
import Html exposing (Html)
import Tea


type alias Model =
    rows : List Int


type Msg
    = Bump Int


update : Msg, Model → Model
update msg model =
    case msg of
        Bump i →
            { model | rows = ${write} }


view : Model → Html Msg
view model =
    <ul><For each={model.rows} keyed={False}>{λn → <li onClick={Bump n}>{n}</li>}</For></ul>


main : Browser.Program
main =
    Tea.sandbox { init = { rows = List.range 0 999 }, update = update, view = view }
`;
  return [
    trieOf("table", tableSrc),
    trieOf("table-no-prepend", noPrepend),
    trieOf("table-no-writer", noWriter),
    trieOf("set-only", setOnly("List.set model.rows i (i + 1)")),
    trieOf("set-by-indexedMap", setOnly("List.indexedMap model.rows λj n → if j == i then i + 1 else n")),
  ];
}

// ---- Report ------------------------------------------------------------------

const dynamic = dynamicShare();
const tries = trie();
const tableTrie = tries.find((t) => t.program === "table-no-prepend");
const result = {
  programs: programs.length,
  bounded,
  static: { rows: staticRows, over: staticOver, fires: staticOver.length > 0, conduit: staticRows.find((r) => r.set === "conduit") },
  dynamic,
  roots: { rows: rootRows, over: rootOver, fires: rootOver.length > 0 },
  pairs: { ...pairs, series },
  trie: { rows: tries, fires: tableTrie.ships.length > 0 },
  carriers: programs.map((p) => ({ program: label(p), carriers: p.carriers })),
  lists: programs.map((p) => ({ program: label(p), reconciled: p.reconciled, keyed: p.keyedLists, patchAll: p.patchAll })),
};

if (asJson) {
  process.stdout.write(JSON.stringify(result, null, 2) + "\n");
} else {
  const f1 = (x) => x.toFixed(1);
  const f2 = (x) => x.toFixed(2);
  const verdict = (b) => (b ? "FIRES" : "holds");
  console.log(`programs: ${programs.length}\n`);
  console.log(`bounded   ${verdict(bounded.fires)}: Conduit ${bounded.bounded} of ${bounded.n} leaf keys bounded (${f1(bounded.share)}%; bar 66.7%)`);
  console.log(`static    ${verdict(result.static.fires)}: Conduit ${result.static.conduit.star} of ${result.static.conduit.ctors} constructors under * (${f1(result.static.conduit.share)}%); ${staticOver.length} of ${staticRows.length} corpus programs above 5%`);
  for (const r of staticOver) console.log(`            ${r.program}: ${r.star}/${r.ctors} (${f1(r.share)}%) — * keys: ${r.starKeys.join(", ")}`);
  console.log(`dynamic   ${verdict(dynamic.fires)}: ${dynamic.star} of ${dynamic.dispatches} dispatches reach patchAll (${f1(dynamic.share)}%; bar 10%)`);
  for (const r of dynamic.scripts) console.log(`            ${r.script}: ${r.error ?? `${r.star}/${r.dispatches} (${f1(r.share)}%), unmatched ${r.unmatched}; ${JSON.stringify(r.keys)}`}`);
  console.log(`roots     ${verdict(result.roots.fires)}: ${rootOver.length} programs over 3 value roots or 5% of sites; max ${Math.max(...rootRows.map((r) => r.value))}`);
  for (const r of rootOver) console.log(`            ${r.program}: ${r.value} of ${r.sites} sites (${f1(r.share)}%)`);
  console.log(`pairs     ${verdict(pairs.fires)}: largest ${largest.program} ${largest.pairs}/${largest.keys} = ${f2(largest.ratio)} per key; median of ${series.length} (${lowerMedian.program} ${f2(lowerMedian.ratio)}, ${upperMedian.program} ${f2(upperMedian.ratio)}) → bar ${f2(pairs.limitLower)} / ${f2(pairs.limitUpper)}; log-log slope ${f2(slope)}`);
  for (const s of series) console.log(`            ${String(s.keys).padStart(3)} keys ${String(s.pairs).padStart(4)} pairs ${f2(s.ratio).padStart(6)}  ${s.program}`);
  console.log(`trie      ${verdict(result.trie.fires)}: write half under the table app without its prepend: ${tableTrie.ships.join(", ") || "none"}`);
  for (const t of tries) console.log(`            ${t.program.padEnd(18)} ${String(t.bytes).padStart(6)} B brotli; write half: ${t.ships.join(", ") || "none"}`);
}
