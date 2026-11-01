#!/usr/bin/env node
// The holder cover oracle (`ownership-v2.md` §2.8 *As built*, *The join
// index*, #1510): generated probes over `incAll`, a writer that pushes into
// every list of a `Rose` tree, each checked by `beni dump --stage=ownership
// --ownership=v2` and then run by a small concrete interpreter twice:
//
// - every write copying (the reference);
// - every write into a list the call's argument held before the call done in
//   place when the call's verdict for that list's path (`#Rose.0`,
//   `#Rose.0[*]#Rose.0`, `#Rose.0[*]⟨Rose⟩#Rose.0`) is `accepted`, or always
//   with `--forced`. A list the call makes is written in place.
//
// A difference of the two results is an unsafe accept when the program is
// accepted (every verdict of the probe accepted). A refused program never
// builds, so its partial runs are counted apart. `--forced` must report
// unsafe runs: it is the oracle's own control.
//
// The probes: an `else if` chain of D arms, a list literal, nested
// positions, a `rest` view (`tailOf`) and a call's result (`mk`), with the
// shared literal `k` anywhere in them; the call alone, or with its argument,
// an alias of it or `k` read after it. No probe calls a generic function.
//
//     zig build test-blackbox-build -Dtest-filter=none   # zig-out/safe/bin/beni
//     node bench/ownership-cover-oracle.mjs [--beni=zig-out/safe/bin/beni]
//         [--work=zig-out/cover-oracle] [--count=600] [--seed=1510] [--forced]
//
// The dumps go to `<work>/dumps.txt`, `account` and `crossing` lines left
// out, for a byte comparison of two compilers. About 20 s for 600 probes.

import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const opt = Object.fromEntries(process.argv.slice(2).map((a) => { const [k, v] = a.replace(/^--/, "").split("="); return [k, v ?? true]; }));
const beni = resolve(repo, opt.beni ?? "zig-out/safe/bin/beni");
const work = resolve(repo, opt.work ?? "zig-out/cover-oracle");
const forced = !!opt.forced;
let seed = Number(opt.seed ?? 1510);
const count = Number(opt.count ?? 600);
const rand = () => { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; };
const pick = (xs) => xs[Math.floor(rand() * xs.length)];

// ---- the probe language: Rose expressions and list expressions ----------
// rose: {t:"rose", list} | {t:"mk", list} (a call: its result is a view)
// list: {t:"lit", items} | {t:"k"} | {t:"tail", list} (a `rest` view)
function genList(depth) {
  const r = rand();
  if (r < 0.08) return { t: "k" };
  if (r < 0.2 && depth > 0) return { t: "tail", list: { t: "lit", items: Array.from({ length: 1 + Math.floor(rand() * 3) }, () => genRose(depth - 1)) } };
  const n = depth <= 0 ? 0 : Math.floor(rand() * (depth > 1 ? 5 : 3));
  return { t: "lit", items: Array.from({ length: n }, () => genRose(depth - 1)) };
}
function genRose(depth) {
  return { t: rand() < 0.15 ? "mk" : "rose", list: genList(depth) };
}
const showList = (l) => l.t === "k" ? "k" : l.t === "tail" ? `(tailOf ${showList(l.list)})` : l.items.length === 0 ? "[]" : `[ ${l.items.map(showRose).join(", ")} ]`;
const showRose = (r) => `${r.t === "mk" ? "mk" : "Rose"} ${showList(r.list)}`;

// ---- the interpreter ------------------------------------------------------
let nextId = 0;
const arr = (items) => ({ id: nextId++, items });
const view = (base, off) => ({ id: nextId++, view: true, base, off });
const items = (a) => (a.view ? items(a.base).slice(a.off) : a.items);
function evalList(l, env) {
  if (l.t === "k") return env.k;
  if (l.t === "tail") { const b = evalList(l.list, env); return items(b).length === 0 ? arr([]) : view(b, 1); }
  return arr(l.items.map((r) => evalRose(r, env)));
}
const evalRose = (r, env) => ({ kids: evalList(r.list, env) });
function pushTo(a, x, st) {
  if (st.inPlace(a)) {
    let at = a;
    while (at.view) at = at.base;
    at.items.push(x);
    return a;
  }
  return arr([...items(a), x]);
}
function incAll(r, st) { return r.leaf ? r : { kids: incList(pushTo(r.kids, { leaf: true }, st), st) }; }
function incList(rs, st) {
  const xs = items(rs);
  if (xs.length === 0) return arr([]);
  return arr([incAll(xs[0], st), ...items(incList(view(rs, 1), st))]);
}
const size = (r) => (r.leaf ? 1 : 1 + sizeList(r.kids));
const sizeList = (l) => items(l).reduce((s, r) => s + size(r), 0);
const show = (r) => (r.leaf ? "L" : `R[${items(r.kids).map(show).join(",")}]`);

// Each list `v` holds before the call, by the path the call's verdicts name.
function classes(v) {
  const out = new Map();
  const add = (a, p) => { if (!out.has(a)) out.set(a, new Set()); out.get(a).add(p); };
  const walk = (r, depth) => {
    add(r.kids, depth === 1 ? "#Rose.0" : depth === 2 ? "#Rose.0[*]#Rose.0" : "#Rose.0[*]⟨Rose⟩#Rose.0");
    for (const s of items(r.kids)) if (!s.leaf) walk(s, depth + 1);
  };
  walk(v, 1);
  return out;
}

// ---- the probes -----------------------------------------------------------
const uses = ["( incAll v, 0 )", "( incAll v, size v )", "( incAll v, sizeList k )", "( incAll v, ignore v )", "( incAll v, size w )"];
function genProbe(i) {
  const shape = pick(["chain", "chain", "literal", "nested", "view"]);
  const use = rand() < 0.45 ? 0 : Math.floor(rand() * uses.length);
  let arms;
  if (shape === "chain") {
    const d = pick([1, 2, 3, 5, 8, 17, 24, 40]);
    arms = Array.from({ length: d + 1 }, () => genRose(1 + Math.floor(rand() * 3)));
  } else if (shape === "literal") {
    arms = [{ t: "rose", list: { t: "lit", items: Array.from({ length: 1 + Math.floor(rand() * 6) }, () => genRose(1 + Math.floor(rand() * 2))) } }];
  } else if (shape === "nested") {
    arms = [{ t: "rose", list: { t: "lit", items: [genRose(3), { t: "rose", list: { t: "lit", items: [genRose(2), genRose(2)] } }] } }];
  } else {
    arms = [{ t: "rose", list: { t: "tail", list: { t: "lit", items: Array.from({ length: 2 + Math.floor(rand() * 4) }, () => genRose(2)) } } }];
  }
  return { i, shape, use, arms };
}
function probeSource(p, line0) {
  const lines = [`pub p${p.i} : Int → Rose × Int`, `p${p.i} c =`, "    k = [ Rose [] ]", "    v ="];
  if (p.arms.length === 1) lines.push(`        ${showRose(p.arms[0])}`);
  else {
    p.arms.forEach((a, j) => {
      if (j === p.arms.length - 1) lines.push("        else");
      else lines.push(`        ${j === 0 ? "if" : "else if"} c == ${j + 1} then`);
      lines.push(`            ${showRose(a)}`);
    });
  }
  if (p.use === 4) lines.push("    w = v");
  p.callLine = line0 + lines.length + 1;
  lines.push(`    ${uses[p.use]}`);
  p.lines = [line0 + 1, line0 + lines.length];
  return lines.join("\n");
}
function runProbe(p, arm, verdicts) {
  const env = { k: arr([{ kids: arr([]) }]) };
  const v = evalRose(p.arms[arm], env);
  const w = v;
  const cls = verdicts ? classes(v) : null;
  const st = { inPlace: (a) => !verdicts ? false : !cls.has(a) || forced || [...cls.get(a)].every((path) => verdicts.get(path) === "accepted") };
  const out = incAll(v, st);
  const second = [0, size(v), sizeList(env.k), 0, size(w)][p.use];
  return `${show(out)} ${second}`;
}

const header = `type Rose
    = Rose (List Rose)
    | Leaf


incAll : Rose → Rose
incAll r =
    case r of
        Rose kids →
            Rose (incList (List.push kids Leaf))

        Leaf →
            Leaf


incList : List Rose → List Rose
incList rs =
    case rs of
        [ s, …rest ] →
            [ incAll s, …incList rest ]

        [] →
            []


size : Rose → Int
size r =
    case r of
        Rose kids →
            1 + sizeList kids

        Leaf →
            1


sizeList : List Rose → Int
sizeList rs =
    case rs of
        [ s, …rest ] →
            size s + sizeList rest

        [] →
            0


ignore : Rose → Int
ignore _ =
    0


tailOf : List Rose → List Rose
tailOf xs =
    case xs of
        [ _, …rest ] →
            rest

        [] →
            []


mk : List Rose → Rose
mk xs =
    Rose xs
`;

mkdirSync(work, { recursive: true });
const per = 20;
const tally = { probes: 0, accepted: 0, refused: 0, runs: 0, unsafe: 0, unsafeAccepted: 0, byShape: {}, lines: [] };
const dumps = [];
for (let m = 0; m * per < count; m++) {
  const probes = [];
  let src = header;
  for (let j = 0; j < per && m * per + j < count; j++) {
    const p = genProbe(m * per + j);
    src += "\n\n";
    const line0 = src.split("\n").length - 1;
    src += probeSource(p, line0) + "\n";
    probes.push(p);
  }
  const file = join(work, `M${m}`, "Main.beni");
  mkdirSync(join(work, `M${m}`), { recursive: true });
  writeFileSync(file, src);
  const r = spawnSync(beni, ["dump", "--stage=ownership", "--ownership=v2", file], { encoding: "utf8", maxBuffer: 1 << 28 });
  if (r.status !== 0) { console.error(`module ${m}: exit ${r.status}\n${r.stderr.slice(0, 2000)}`); process.exit(2); }
  dumps.push(r.stdout.split("\n").filter((l) => !/^\s*(account|crossing)\b/.test(l)).join("\n"));
  const verdictLines = r.stdout.split("\n").map((l) => l.match(/^\s+(\d+):(\d+) (.*?): (accepted|rejected|pending)\b/)).filter(Boolean);
  for (const p of probes) {
    tally.probes++;
    const mine = verdictLines.filter((x) => Number(x[1]) >= p.lines[0] && Number(x[1]) <= p.lines[1]);
    const verdicts = new Map();
    for (const x of mine) {
      const call = x[3].match(/^Main\.incAll v(.*)$/);
      if (call && Number(x[1]) === p.callLine) verdicts.set(call[1], x[4]);
    }
    const unchecked = new RegExp(`unchecked p${p.i}: `).test(r.stdout);
    const paths = ["#Rose.0", "#Rose.0[*]#Rose.0", "#Rose.0[*]⟨Rose⟩#Rose.0"];
    const refused = unchecked || mine.some((x) => x[4] !== "accepted") || !paths.every((q) => verdicts.has(q));
    if (unchecked) tally.unchecked = (tally.unchecked ?? 0) + 1;
    if (refused) tally.refused++;
    else tally.accepted++;
    const key = `${p.shape}/${uses[p.use]}`;
    const b = (tally.byShape[key] ??= { probes: 0, accepted: 0, runs: 0, unsafe: 0 });
    b.probes++;
    if (!refused) b.accepted++;
    for (let arm = 0; arm < p.arms.length; arm++) {
      tally.runs++;
      b.runs++;
      const copy = runProbe(p, arm, null);
      const inPlace = runProbe(p, arm, verdicts);
      if (copy !== inPlace) {
        tally.unsafe++;
        b.unsafe++;
        if (!refused) tally.unsafeAccepted++;
        if (tally.lines.length < 8) tally.lines.push(`p${p.i} arm ${arm + 1} ${refused ? "refused" : "ACCEPTED"} [${[...verdicts].map(([k, v]) => `${k}:${v}`).join(" ")}]: copy ${copy} / in place ${inPlace}`);
      }
    }
  }
}
writeFileSync(join(work, "dumps.txt"), dumps.join("\n=====\n"));
console.log(`${forced ? "FORCED " : ""}probes ${tally.probes} (accepted ${tally.accepted}, refused ${tally.refused}, of them unchecked ${tally.unchecked ?? 0}), runs ${tally.runs}, unsafe runs ${tally.unsafe}, unsafe in accepted programs ${tally.unsafeAccepted}`);
for (const [k, v] of Object.entries(tally.byShape).sort()) console.log(`  ${k.padEnd(36)} probes ${String(v.probes).padStart(4)} accepted ${String(v.accepted).padStart(4)} runs ${String(v.runs).padStart(5)} unsafe ${v.unsafe}`);
for (const l of tally.lines) console.log("  " + l);
