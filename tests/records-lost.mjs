#!/usr/bin/env node
// No list verdict reads a record condition (`docs/design/ownership-checker.md`
// §31.4 item 6): every program of the corpus is checked twice, once as is
// and once with every record condition failing (`--ownership-records-lost`,
// hidden and test-only), and the lines a list's demand prints must be the
// same, byte for byte. A record line (`update …`) may move; nothing else may.
//
//     zig build test-records-lost       (checker v1)
//     zig build test-records-lost-v2    (checker v2, `ownership-v2.md` §7, point 8)
//
// Not a gate: it runs the ownership checker twice over two thousand programs.
// A program that the compiler refuses in both runs has no line to compare,
// so it is an error here, and not a program with no difference.

import { spawn } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";

const beni = resolve(process.argv[2]);
// The checker's own flags, for both runs: `--ownership=v2` compares checker v2 (`ownership-v2.md` §7, point 8).
const checker = process.argv.slice(3);
const repo = process.cwd();
const corpus = join(repo, "tests/corpus");
const isDir = (p) => statSync(p).isDirectory();
// One `dump` reads one directory. A project whose modules are in several (an
// `_expected.sources` of several lines, a manifest with `"paths"`) is
// `several`: where the compiler refuses it, it is named and not compared.
function program(path, fallback) {
  if (!isDir(path)) return { name: relative(repo, path), platform: fallback, paths: [path], root: [], several: false };
  const own = existsSync(join(path, "platform")) ? join(path, "platform") : null;
  const named = join(path, "_expected.sources");
  const listed = existsSync(named) ? readFileSync(named, "utf8").split("\n").map((l) => l.trim()).filter(Boolean) : [];
  const dir = listed.length ? join(repo, listed[0]) : path;
  const manifest = join(path, "beni.json");
  const several = listed.length > 1 || (existsSync(manifest) && "paths" in (JSON.parse(readFileSync(manifest, "utf8")).build ?? {}));
  return { name: relative(repo, path), platform: own ?? fallback, paths: [dir], root: [`--root=${dir}`], several };
}
function programs(dir, platform, skip = []) {
  return readdirSync(dir)
    .filter((n) => !skip.includes(n) && (n.endsWith(".beni") || isDir(join(dir, n))))
    .sort()
    .map((n) => program(join(dir, n), platform));
}
// An ownership fixture names its platforms beside it (`X.platform`): tokens
// `<platform>` or `<platform>+everywhere` (`corpus_test.zig`,
// `ownershipReport`). Each run here has `--ownership-everywhere`, so a
// fixture is one program for each platform that it names.
function ownership() {
  const dir = join(corpus, "ownership");
  return readdirSync(dir)
    .filter((n) => n.endsWith(".beni") || (isDir(join(dir, n)) && n !== "core"))
    .sort()
    .flatMap((n) => {
      const base = join(dir, n.replace(/\.beni$/, ""));
      const file = [`${base}.platform`, join(base, "_expected.platform")].find((f) => existsSync(f));
      const tokens = file ? readFileSync(file, "utf8").split(/\s+/).filter(Boolean) : ["node"];
      const platforms = [...new Set(tokens.map((t) => t.replace(/\+everywhere$/, "")))];
      return platforms.map((p) => ({ ...program(join(dir, n), p), name: `${relative(repo, join(dir, n))} [${p}]` }));
    });
}
const browser = join(corpus, "browser");
const all = [
  ...programs(join(corpus, "run"), "node"),
  ...ownership(),
  // The sub-corpora, each with the platform that `corpus_test.zig` builds it for (`collectFixtures`).
  ...programs(browser, join(repo, "tests/platforms/page"), ["dom", "tea", "inline", "dedicated", "gpu", "managed", "prerender"]),
  ...programs(join(browser, "dedicated"), join(repo, "tests/platforms/worker")),
  ...programs(join(browser, "gpu"), join(repo, "tests/platforms/gpu")),
  ...programs(join(browser, "managed"), "browser"),
  ...programs(join(browser, "prerender"), "browser-inline"),
  ...programs(join(browser, "dom"), "browser"),
  ...programs(join(browser, "tea"), "browser-tea"),
  ...programs(join(browser, "inline"), "browser-inline"),
  ...["bike-wars", "conduit", "sternhalma"].map((n) => program(join(repo, "examples", n, "src"), "browser-tea")),
  { name: "core", platform: null, paths: ["core"], root: [] },
  ...["node", "html", "browser", "browser-tea", "browser-inline"].map((p) => ({ name: `platforms/${p}`, platform: p, paths: [`platforms/${p}`], root: [] })),
];
const run = (argv) =>
  new Promise((done) => {
    // Only the report is read. A pipe for the diagnostics that nobody reads
    // stops the compiler when it is full (#2472).
    const c = spawn(beni, argv, { cwd: repo, stdio: ["ignore", "pipe", "ignore"] });
    c.stdout.setEncoding("utf8");
    let out = "";
    c.stdout.on("data", (d) => (out += d));
    c.on("close", (code, signal) => done({ code, signal, out }));
  });
// A list's demand line: a demand line that is not a record's.
const lines = (out) => out.split("\n").filter((l) => /^  \d+:\d+ /.test(l) && !/^  \d+:\d+ update /.test(l));
let next = 0;
let differ = 0;
let crashed = 0;
let refused = 0;
const several = [];
async function worker() {
  while (next < all.length) {
    const p = all[next++];
    const argv = ["dump", "--stage=ownership", ...checker, "--ownership-everywhere", ...(p.platform ? [`--platform=${p.platform}`] : []), ...p.root, ...p.paths];
    const [a, b] = await Promise.all([run(argv), run([...argv, "--ownership-records-lost"])]);
    if (a.code !== b.code || a.signal || b.signal) {
      crashed++;
      console.log(`DIFFERENT EXIT ${p.name}: ${a.signal ?? a.code} / ${b.signal ?? b.code}`);
      continue;
    }
    if (a.code !== 0) {
      if (p.several) several.push(p.name);
      else {
        refused++;
        console.log(`NO REPORT ${p.name}: the compiler refuses the program in both runs (exit ${a.code})`);
      }
      continue;
    }
    const la = lines(a.out).join("\n");
    const lb = lines(b.out).join("\n");
    if (la !== lb) {
      differ++;
      console.log(`## ${p.name}`);
      const sa = new Set(lines(a.out));
      const sb = new Set(lines(b.out));
      for (const x of sa) if (!sb.has(x)) console.log(`  - ${x}`);
      for (const x of sb) if (!sa.has(x)) console.log(`  + ${x}`);
    }
  }
}
await Promise.all(Array.from({ length: 12 }, worker));
for (const n of several.sort()) console.log(`not compared (its modules are in several directories): ${n}`);
console.log(`${all.length} programs: ${differ} with list lines that read a record condition, ${crashed} with a different exit, ${refused} with no report, ${several.length} not compared`);
if (differ || crashed || refused) process.exit(1);
