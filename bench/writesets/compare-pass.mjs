// Compare the write-set pass's classes with research 61's classifier, per
// constructor, over the classifier's own corpus. Usage:
//   BENI=zig-out/bin/beni node bench/writesets/compare-pass.mjs r61.json [--dom]
// where r61.json is `node bench/writesets/classify.mjs --json`'s output
// (research 63 §3).
import { execFileSync } from "node:child_process";
import { readFileSync, statSync } from "node:fs";

const beni = process.env.BENI ?? "zig-out/bin/beni";
const data = JSON.parse(readFileSync(process.argv[2], "utf8"));
const platform = process.argv.includes("--dom") ? "browser" : "browser-tea";
const rank = { exact: 0, indexed: 1, structural: 2, "*": 3 };
const names = ["exact", "indexed", "structural", "*"];

function dump(path) {
  try {
    let plat = platform;
    try { if (statSync(path + "/platform").isDirectory()) plat = path + "/platform"; } catch {}
    return execFileSync(beni, ["dump", "--stage=writes", `--platform=${plat}`, path], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  } catch (e) {
    return null;
  }
}

function parsePrograms(text) {
  const progs = [];
  let cur = null;
  let pending = null;
  for (const line of text.split("\n")) {
    if (line.startsWith("program ")) {
      cur = { head: line, keys: [], holes: {} };
      progs.push(cur);
      continue;
    }
    if (!cur) continue;
    let m = line.match(/^  key (.*?)\s{2,}(\*|exact|indexed|structural)( \(cap [^)]*\))*\s+(.*)$/);
    if (m) { cur.keys.push({ name: m[1].trim(), cls: m[2], set: m[4] }); continue; }
    m = line.match(/^  key (.*)$/);
    if (m && !line.match(/\s{2,}(\*|exact|indexed|structural)/)) { pending = m[1].trim(); continue; }
    m = line.match(/^\s{40,}(\*|exact|indexed|structural)( \(cap [^)]*\))*\s+(.*)$/);
    if (m && pending) { cur.keys.push({ name: pending, cls: m[1], set: m[3] }); pending = null; continue; }
    m = line.match(/^  holes \d+: static (\d+), literal (\d+), static-key (\d+), dynamic (\d+)/);
    if (m) cur.holes = { static: +m[1], literal: +m[2], key: +m[3], dynamic: +m[4] };
  }
  return progs;
}

function classOf(prog, ctor) {
  let best = -1;
  const named = new Set(prog.keys.map((k) => k.name.split(" · ")[0].replace(/#\d+$/, "")));
  for (const k of prog.keys) {
    const first = k.name.split(" · ")[0].replace(/#\d+$/, "");
    if (first === ctor || first === "(any)" || first === "*" || (first === "_" && !named.has(ctor))) best = Math.max(best, rank[k.cls]);
  }
  return best < 0 ? null : names[best];
}

let total = 0, agree = 0;
const diffs = [];
const tally = { mine: [0, 0, 0, 0], theirs: [0, 0, 0, 0] };
const holes = { static: 0, literal: 0, key: 0, dynamic: 0 };
for (const entry of data) {
  const path = entry.program;
  const text = dump(path);
  if (text === null) { diffs.push(`${path}: the pass could not run`); continue; }
  const mine = parsePrograms(text);
  for (const h of mine) for (const k of Object.keys(holes)) holes[k] += h.holes[k] ?? 0;
  const progs = entry.programs.filter((p) => !p.excluded);
  progs.forEach((p, i) => {
    const m = mine[entry.programs.indexOf(p)] ?? mine[i];
    for (const c of p.ctors) {
      total++;
      const theirs = c.cls === "*" ? "*" : c.cls;
      const ours = m ? classOf(m, c.ctor) : null;
      tally.theirs[rank[theirs]]++;
      if (ours !== null) tally.mine[rank[ours]]++;
      if (ours === theirs) agree++;
      else diffs.push(`${path.replace(/^.*?(tests|bench)\//, "$1/")} ${p.where} ${c.ctor}: research ${theirs}${c.flags?.length ? " [" + c.flags.join(",") + "]" : ""}, pass ${ours} — ${m ? m.keys.filter((k) => k.name.split(" · ")[0] === c.ctor || k.name === "(any)" || k.name.startsWith("_")).map((k) => k.name + " " + k.set).join(" | ") : "no program"}`);
    }
  });
}
console.log(`constructors ${total}, same class ${agree}`);
console.log(`research: exact ${tally.theirs[0]}, indexed ${tally.theirs[1]}, structural ${tally.theirs[2]}, * ${tally.theirs[3]}`);
console.log(`pass:     exact ${tally.mine[0]}, indexed ${tally.mine[1]}, structural ${tally.mine[2]}, * ${tally.mine[3]}`);
console.log(`pass holes: ${JSON.stringify(holes)}`);
for (const d of diffs) console.log(d);
