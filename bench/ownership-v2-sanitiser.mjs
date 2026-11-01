#!/usr/bin/env node
// The v2 sanitiser sweep (#1547): random straight-line list programs, each
// built twice — as shipped, and under `--ownership=v2 --ownership-everywhere
// --sanitize-lists`, where every list write v2 accepts runs on a copy and
// poisons the list it wrote (`ownership-v2.md` §7.3, v2's lowering channel in
// `src/own2/Hoists.zig`). A program v2 refuses is counted and skipped. One it
// accepts must print what the plain build prints: a trap ("a stale read of a
// list") or another output is a write v2 accepted unsoundly, and its
// directory is kept. The sanitiser is the oracle, so no interpreter is
// written here; it sees the writes v2 accepted in declarations v2 built.
//
// Each program's `t` binds lists in a row from its parameter, literals, a
// generic `wrap` and `idl` (#1516's shape), writers, spreads, `++` and a
// pattern's rest (#1530's), and returns some of them; `main` prints them.
//
//     node bench/ownership-v2-sanitiser.mjs [--beni=zig-out/safe/bin/beni]
//         [--work=zig-out/v2-sanitiser] [--programs=200] [--seed=1]
//         [--jobs=<cpus>] [--keep-vacuous]
//
// It prints one JSON line of counts (`wrapped` is the sanitised sites over
// all accepted programs, so a vacuous sweep shows as 0), then each unsafe
// program. Exit 1 when any is unsafe.

import { spawn } from "node:child_process";
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { availableParallelism } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const opt = Object.fromEntries(process.argv.slice(2).map((a) => { const [k, v] = a.replace(/^--/, "").split("="); return [k, v ?? true]; }));
const beni = resolve(repo, opt.beni ?? "zig-out/safe/bin/beni");
const work = resolve(repo, opt.work ?? "zig-out/v2-sanitiser");
const programs = Number(opt.programs ?? 200);
const jobs = Number(opt.jobs ?? availableParallelism());
let seed = Number(opt.seed ?? 1) >>> 0;

// mulberry32: the same programs for the same seed on every machine.
function rand() {
  seed = (seed + 0x6d2b79f5) >>> 0;
  let t = seed;
  t = Math.imul(t ^ (t >>> 15), t | 1);
  t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}
const pick = (xs) => xs[Math.floor(rand() * xs.length)];

// One binding's right-hand side over the earlier lists `ls`.
function expr(ls, k) {
  const l = pick(ls);
  return pick([
    () => `[ ${k} ]`,
    () => `wrap ${k}`,
    () => `idl ${l}`,
    () => `List.push ${l} ${k}`,
    () => `${l}.push ${k}`,
    () => `List.set ${l} 0 ${k}`,
    () => `List.pop ${l}`,
    () => `[ …${l}, ${k} ]`,
    () => `[ ${k}, …${l} ]`,
    () => `${l} ++ [ ${k} ]`,
    () => `List.append ${l} ${pick(ls)}`,
    () => `rest ${l} ${k}`,
    () => `first ( ${l}, ${pick(ls)} )`,
  ])();
}

function program() {
  const n = 2 + Math.floor(rand() * 5);
  const ls = ["b"];
  const lines = [];
  for (let i = 0; i < n; i++) {
    const name = `l${i}`;
    lines.push(`    ${name} = ${expr(ls, i + 2)}`);
    ls.push(name);
  }
  // Some of the lists, the last always: the others are dead after their use.
  const out = ls.filter((x, i) => i === ls.length - 1 || rand() < 0.25);
  return `import List
import Node exposing (Program)
import String


wrap : a → List a
wrap x = [ x ]


idl : a → a
idl x = x


first : a × b → a
first ( x, _ ) = x


rest : List Int, Int → List Int
rest xs k =
    case xs of
        [ _, …tail ] →
            List.push tail k

        [] →
            [ k ]


t : List Int → List (List Int)
t b =
${lines.join("\n")}
    [ ${out.join(", ")} ]


show : List Int → String
show xs = String.join (List.map xs λx → String.fromInt x) ","


main : Program
main = Node.printLines (List.map (t [ 1, 2 ]) λxs → show xs)
`;
}

function run(cmd, args, cwd) {
  return new Promise((done) => {
    const p = spawn(cmd, args, { cwd });
    let stdout = "";
    let stderr = "";
    p.stdout.on("data", (d) => { stdout += d; });
    p.stderr.on("data", (d) => { stderr += d; });
    p.on("close", (status) => done({ status, stdout, stderr }));
  });
}

// A refusal is these codes alone; any other error is a generator defect.
const ownershipCodes = ["list_still_used", "top_level_list_changed", "view_changes_model", "list_may_be_shared", "ownership_limit", "comparison_changes_value"];

const tally = { programs: 0, plainFailed: 0, refused: 0, accepted: 0, vacuous: 0, wrapped: 0, unsafe: 0 };
const unsafe = [];

async function one(i, text) {
  const dir = join(work, `p${i}`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "Main.beni"), text);
  tally.programs++;
  const plain = await run(beni, ["build", "--platform=node", "--out=plain", "Main.beni"], dir);
  if (plain.status !== 0) {
    tally.plainFailed++;
    unsafe.push(`${dir}: the plain build failed (a generator defect): ${plain.stderr.split("\n")[0]}`);
    return;
  }
  const san = await run(beni, ["build", "--platform=node", "--ownership=v2", "--ownership-everywhere", "--sanitize-lists", "--diagnostics=json", "--out=san", "Main.beni"], dir);
  const codes = [...san.stderr.matchAll(/"code":"([a-z_]+)"/g)].map((m) => m[1]);
  if (san.status === 1 && codes.length !== 0 && codes.every((c) => ownershipCodes.includes(c))) {
    tally.refused++;
    rmSync(dir, { recursive: true, force: true });
    return;
  }
  if (san.status !== 0) {
    unsafe.push(`${dir}: the sanitised build exited ${san.status}: ${san.stderr.split("\n")[0]}`);
    return;
  }
  tally.accepted++;
  const wrapped = (readFileSync(join(dir, "san", "Main.mjs"), "utf8").match(/_sanitize\$list\(/g) ?? []).length;
  tally.wrapped += wrapped;
  // An accepted program with no write wrapped checks nothing.
  if (wrapped === 0) tally.vacuous++;
  const want = await run("node", ["plain/_main.mjs"], dir);
  const got = await run("node", ["san/_main.mjs"], dir);
  if (got.status === want.status && got.stdout === want.stdout) {
    if (!opt["keep-vacuous"] || wrapped !== 0) rmSync(dir, { recursive: true, force: true });
    return;
  }
  tally.unsafe++;
  const why = got.stderr.match(/a stale read of a list[^\n]*/)?.[0] ?? `output ${JSON.stringify(got.stdout)} vs ${JSON.stringify(want.stdout)}`;
  unsafe.push(`${dir}: ${why}`);
}

rmSync(work, { recursive: true, force: true });
const texts = Array.from({ length: programs }, () => program());
let next = 0;
await Promise.all(Array.from({ length: Math.max(1, jobs) }, async () => {
  while (next < texts.length) {
    const i = next++;
    await one(i, texts[i]);
  }
}));
console.log(JSON.stringify(tally));
for (const u of unsafe.sort()) console.log(u);
process.exit(unsafe.length === 0 ? 0 : 1);
