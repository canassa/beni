#!/usr/bin/env node
// No list verdict reads a record condition (`docs/design/ownership-checker.md`
// §31.4 item 6): every program of the corpus is checked twice, once as is
// and once with every record condition failing (`--ownership-records-lost`,
// hidden and test-only), and the lines a list's demand prints must be the
// same, byte for byte. A record line (`update …`) may move; nothing else may.
//
//     zig build test-records-lost
//
// Not a gate: it runs the ownership checker twice over a thousand programs.

import { spawn } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative, resolve } from "node:path";

const beni = resolve(process.argv[2]);
const repo = process.cwd();
const corpus = join(repo, "tests/corpus");
const isDir = (p) => statSync(p).isDirectory();
function program(path, fallback) {
  if (!isDir(path)) return { name: relative(repo, path), platform: fallback, paths: [path], root: [] };
  const own = existsSync(join(path, "platform")) ? join(path, "platform") : null;
  const named = join(path, "_expected.sources");
  const dir = existsSync(named) ? join(repo, readFileSync(named, "utf8").trim()) : path;
  return { name: relative(repo, path), platform: own ?? fallback, paths: [dir], root: [`--root=${dir}`] };
}
function programs(dir, platform, skip = []) {
  return readdirSync(dir)
    .filter((n) => !skip.includes(n) && (n.endsWith(".beni") || isDir(join(dir, n))))
    .sort()
    .map((n) => program(join(dir, n), platform));
}
// An ownership fixture names its platform beside it (`X.platform`).
function ownership() {
  const dir = join(corpus, "ownership");
  return readdirSync(dir)
    .filter((n) => n.endsWith(".beni") || (isDir(join(dir, n)) && n !== "core"))
    .sort()
    .map((n) => {
      const base = join(dir, n.replace(/\.beni$/, ""));
      const named = existsSync(`${base}.platform`) ? readFileSync(`${base}.platform`, "utf8").trim() : existsSync(join(base, "_expected.platform")) ? readFileSync(join(base, "_expected.platform"), "utf8").trim() : "node";
      return program(join(dir, n), named);
    });
}
const browser = join(corpus, "browser");
const all = [
  ...programs(join(corpus, "run"), "node"),
  ...ownership(),
  ...programs(browser, join(repo, "tests/platforms/page"), ["dom", "tea", "inline"]),
  ...programs(join(browser, "dom"), "browser"),
  ...programs(join(browser, "tea"), "browser-tea"),
  ...programs(join(browser, "inline"), "browser-inline"),
  ...["bike-wars", "conduit", "sternhalma"].map((n) => program(join(repo, "examples", n, "src"), "browser-tea")),
  { name: "core", platform: null, paths: ["core"], root: [] },
  ...["node", "html", "browser", "browser-tea", "browser-inline"].map((p) => ({ name: `platforms/${p}`, platform: p, paths: [`platforms/${p}`], root: [] })),
];
const run = (argv) =>
  new Promise((done) => {
    const c = spawn(beni, argv, { cwd: repo });
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
async function worker() {
  while (next < all.length) {
    const p = all[next++];
    const argv = ["dump", "--stage=ownership", "--ownership-everywhere", ...(p.platform ? [`--platform=${p.platform}`] : []), ...p.root, ...p.paths];
    const [a, b] = await Promise.all([run(argv), run([...argv, "--ownership-records-lost"])]);
    if (a.code !== b.code || a.signal || b.signal) {
      crashed++;
      console.log(`DIFFERENT EXIT ${p.name}: ${a.signal ?? a.code} / ${b.signal ?? b.code}`);
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
console.log(`${all.length} programs: ${differ} with list lines that read a record condition, ${crashed} with a different exit`);
if (differ || crashed) process.exit(1);
