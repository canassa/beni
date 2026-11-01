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
// Each program's `t` is one of two families. Flat: lists of numbers and
// lists of lists bound in a row from its parameter, literals, a generic
// `wrap` of a number or a list and `idl` (#1516's shape), an element handed
// out, writers, spreads and `++`, of which it returns some read whole, by
// length or by a pattern's shape alone (#1530's). Trees: a deep list a
// holder keeps, a tree rebuilt over it, a recursive writer of every level
// or of the top, then a recursive or pattern-only reader of the holder
// (#1523's). `main` prints the numbers.
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

// The flat family: lists of numbers (`A`) and lists of lists (`B`), each
// binding over the earlier ones. `wrap` takes a list as well as a number
// (#1516), `first`/`idl` alias, `headOf` hands out an element.
function flatExpr(A, B, k) {
  const a = pick(A);
  const forms = [
    () => ["A", `[ ${k} ]`],
    () => ["A", "[]"],
    () => ["A", `idl ${a}`],
    () => ["A", `List.push ${a} ${k}`],
    () => ["A", `${a}.push ${k}`],
    () => ["A", `List.set ${a} 0 ${k}`],
    () => ["A", `List.pop ${a}`],
    () => ["A", `[ …${a}, ${k} ]`],
    () => ["A", `[ ${k}, …${a} ]`],
    () => ["A", `${a} ++ [ ${k} ]`],
    () => ["A", `List.append ${a} ${pick(A)}`],
    () => ["A", `rest ${a} ${k}`],
    () => ["A", `first ( ${a}, ${pick(A)} )`],
    () => ["B", `wrap ${a}`],
    () => ["B", `[ ${a}, ${pick(A)} ]`],
  ];
  if (B.length) {
    const bb = pick(B);
    forms.push(
      () => ["A", `headOf ${bb}`],
      () => ["B", `idl ${bb}`],
      () => ["B", `List.push ${bb} ${a}`],
      () => ["B", `[ …${bb}, ${a} ]`],
      () => ["B", `List.set ${bb} 0 ${a}`],
    );
  }
  return pick(forms)();
}

// What `t` returns of a list: a whole read, or its length or shape alone.
const readA = (a) => pick([`List.length ${a}`, `total ${a}`, `isEmpty ${a}`]);
const readB = (bb) => pick([`List.length ${bb}`, `nested ${bb}`, `deep ${bb}`]);

function flat() {
  const n = 2 + Math.floor(rand() * 6);
  const A = ["b"];
  const B = [];
  const lines = [];
  const kinds = { b: "A" };
  for (let i = 0; i < n; i++) {
    const [kind, e] = flatExpr(A, B, i + 2);
    const name = `${kind === "A" ? "l" : "m"}${i}`;
    lines.push(`    ${name} = ${e}`);
    (kind === "A" ? A : B).push(name);
    kinds[name] = kind;
  }
  // Some of the lists, the last always: the others are dead after their use.
  const all = Object.keys(kinds);
  const out = all.filter((x, i) => i === all.length - 1 || rand() < 0.3).map((x) => (kinds[x] === "A" ? readA(x) : readB(x)));
  return `${lines.join("\n")}\n    [ ${out.join(", ")} ]`;
}

// The tree family (#1523, #1530): a deep list `k` that `w` still holds, a
// tree `u` built over it, a write of every list of `u`, then a reader of
// `w`, recursive and through patterns.
function rose() {
  const k = pick(["[ Rose [] ]", "[ Leaf ]", "[ Rose [], Leaf ]", "[]"]);
  const depth = 1 + Math.floor(rand() * 3);
  let v = "Rose k";
  for (let i = 0; i < depth; i++) v = `Rose [ ${v} ]`;
  const u = pick([
    "v",
    "case v of\n            Rose [ Rose [ d, …_ ], …_ ] →\n                Rose [ Rose [ d ] ]\n\n            _ →\n                Leaf",
    "case v of\n            Rose [ d, …_ ] →\n                Rose [ d ]\n\n            _ →\n                Leaf",
    "Rose [ v ]",
  ]);
  const reader = pick(["size", "sz", "skip2c", "deepLen"]);
  const write = pick(["incAll", "pushTop"]);
  const before = rand() < 0.2;
  const pair = before ? `[ ${reader} w, size (${write} u) ]` : `[ size (${write} u), ${reader} w ]`;
  return `    k = ${k}\n    v = ${v}\n    w = v\n    u =\n        ${u}\n    ${pair}`;
}

function program() {
  const body = rand() < 0.6 ? flat() : rose();
  return `import List
import Node exposing (Program)
import String


type Rose
    = Rose (List Rose)
    | Leaf


wrap : a → List a
wrap x = [ x ]


idl : a → a
idl x = x


first : a × b → a
first ( x, _ ) = x


headOf : List (List Int) → List Int
headOf xss =
    case xss of
        [ x, …_ ] →
            x

        [] →
            []


rest : List Int, Int → List Int
rest xs k =
    case xs of
        [ _, …tail ] →
            List.push tail k

        [] →
            [ k ]


total : List Int → Int
total xs =
    case xs of
        [ x, …r ] →
            x + total r

        [] →
            0


isEmpty : List Int → Int
isEmpty xs =
    case xs of
        [] →
            1

        _ →
            0


nested : List (List Int) → Int
nested xss =
    case xss of
        [ [ _, …_ ], …_ ] →
            7

        _ →
            0


deep : List (List Int) → Int
deep xss =
    case xss of
        [ x, …r ] →
            List.length x + deep r

        [] →
            0


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
        [ s, …more ] →
            [ incAll s, …incList more ]

        [] →
            []


pushTop : Rose → Rose
pushTop r =
    case r of
        Rose kids →
            Rose (List.push kids Leaf)

        Leaf →
            Leaf


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
        [ s, …more ] →
            size s + sizeList more

        [] →
            0


sz : Rose → Int
sz r =
    case r of
        Rose [ s, …more ] →
            sz s + sz (Rose more)

        _ →
            1


skip2c : Rose → Int
skip2c r =
    case r of
        Rose [ Rose [ _, …_ ], …_ ] →
            7

        _ →
            0


deepLen : Rose → Int
deepLen r =
    case r of
        Rose [ s, …_ ] →
            deepLen s

        Rose [] →
            100

        Leaf →
            0


t : List Int → List Int
t b =
${body}


main : Program
main = Node.printLines (List.map (t [ 1, 2 ]) λx → String.fromInt x)
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
  const why = got.stderr.match(/Error: beni: (a stale read of a list[^\n]*)/)?.[1] ?? `output ${JSON.stringify(got.stdout)} vs ${JSON.stringify(want.stdout)}`;
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
