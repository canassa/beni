#!/usr/bin/env node
// A generator of small list programs for the step 0 prototype (research
// report 111). Each program is one function of a few bindings over lists,
// pairs, records, lists of lists and a tree with a list at each node. A
// binding takes its operands from the bindings before it, most often the
// newest one and sometimes an older one, so many programs read a list after
// a write of it. The helpers write a parameter, answer a parameter two times,
// fold with a lambda that writes its accumulator, and hand a function on.
//
// `--family=higher` adds function values and cells to the same programs: a
// lambda that answers a list that it captured, a function in a local, a fold
// whose accumulator is a pair that the lambda swaps, a function that calls
// two functions, and a cell that keeps a list. The first full run of the
// sanitiser corpus found the prototype's faults in this family (report 111
// §4.2), and the first family has none of it. The default is `first`: a seed
// of it makes the program that it made before the second family was there.
//
// Each program is built and run as the oracle (a plain build: no list is
// edited in place), and then under each checker with `--ownership-everywhere
// --sanitize-lists`: each accepted write runs on a copy and poisons the list
// it wrote. For each checker a program is one of:
//
//   - `refused`: the checker refuses it (the build fails);
//   - `same`: the run prints what the oracle prints;
//   - `trap`: the run throws a stale read;
//   - `differs`: the run prints different text or ends differently.
//
// A `trap` or a `differs` is an accepted program that the copying program
// does not agree with: a hole of the checker (or of the sanitiser's harness).
//
//     TMPDIR=<a directory on disk> node bench/ownership-step0-generator.mjs [--beni=zig-out/bin/beni] [--count=500] [--seed=1] [--jobs=4] [--checkers=v1,v2,v3] [--family=first|higher] [--bias=0.85] [--keep=<dir>] [--print=<n>]

import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const args = Object.fromEntries(
  process.argv.slice(2).map((a) => {
    const [k, ...v] = a.replace(/^--/, "").split("=");
    return [k, v.length ? v.join("=") : true];
  }),
);
const beni = resolve(repo, args.beni ?? "zig-out/bin/beni");
const total = Number(args.count ?? 500);
const seed0 = Number(args.seed ?? 1);
const jobs = Number(args.jobs ?? 4);
const checkers = String(args.checkers ?? "v1,v2,v3").split(",");
// How often a binding takes the newest value of a type (a lower number makes more stale reads).
const bias = Number(args.bias ?? 0.85);
const higher = (args.family ?? "first") === "higher";
const scratch = mkdtempSync(join(tmpdir(), "beni-step0-gen-"));
process.on("exit", () => rmSync(scratch, { recursive: true, force: true }));
if (args.keep) mkdirSync(resolve(args.keep), { recursive: true });

function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const prelude = `import List
import Node exposing (Program)
${higher ? "import Ref exposing (Ref)\n" : ""}import String


type T
    = Leaf
    | Tip (List Int) T T


show : List Int → String
show l = "[" ++ String.join (List.map l String.fromInt) "," ++ "]"


showLL : List (List Int) → String
showLL ll = "{" ++ String.join (List.map ll show) "" ++ "}"


showT : T → String
showT t =
    case t of
        Leaf →
            "."

        Tip xs l r →
            "(" ++ show xs ++ showT l ++ showT r ++ ")"


ident : List Int → List Int
ident xs = xs


pushOne : List Int, Int → List Int
pushOne xs n = List.push xs n


dup : List Int → List Int × List Int
dup xs = ( xs, xs )


both : List Int, List Int → List Int
both a b = List.push a (List.length b)


pick : Bool, List Int, List Int → List Int
pick c a b = if c then a else b


wrap : List Int → List (List Int)
wrap xs = [ xs ]


grow : T, Int → T
grow t n =
    case t of
        Leaf →
            Leaf

        Tip xs l r →
            Tip (List.push xs n) l r


left : T → T
left t =
    case t of
        Leaf →
            Leaf

        Tip _ l _ →
            l


rootOf : T → List Int
rootOf t =
    case t of
        Leaf →
            []

        Tip xs _ _ →
            xs


fold : List Int, List Int → List Int
fold xs acc = List.foldl xs acc λit ac → List.push ac it


applyTo : List Int, (List Int → List Int) → List Int
applyTo xs f = f xs


twice : List Int, (List Int → List Int) → List Int
twice xs f = f (f xs)
`;

// The helpers of the second family. A program has only those that it names:
// each checker judges every declaration, and one that refuses a helper
// refuses the program.
const helpers = {
  swapFold: `swapFold : List Int, List Int → List Int × List Int
swapFold a b = List.foldl [ 1, 2, 3 ] ( a, b ) λit ac → ( ac.1, List.push ac.0 it )
`,
  callBoth: `callBoth : (List Int → List Int), (List Int → List Int), List Int → List Int × List Int
callBoth f g xs =
    a = f xs
    ( a, g a )
`,
  keepIn: `keepIn : Ref (List Int), List Int → List Int
keepIn c xs =
    Ref.set c xs
    xs
`,
};

function program(seed) {
  const r = rng(seed);
  const int = (n) => Math.floor(r() * n);
  const vars = { L: ["p", "q"], P: [], R: [], LL: [], T: [], F: [], C: [] };
  const lines = [];
  let n = 0;
  // An earlier binding of type `t`: most often the newest.
  const use = (t) => {
    const vs = vars[t];
    if (vs.length === 0) return null;
    return r() < bias ? vs[vs.length - 1] : vs[int(vs.length)];
  };
  const L = () => use("L");
  const lit = () => `[ ${int(9)}, n ]`;
  const lam = () => [`λl → List.push l ${int(9)}`, "ident", `λl → l`, `λl → pushOne l n`, `λl → List.set l 0 ${int(9)}`][int(5)];
  // A function in a local, or `ident`.
  const fn = () => use("F") ?? "ident";
  const makers = {
    F: () => [`λl → List.push l ${int(9)}`, `λl → ${L()}`, `λl → if List.length l > ${int(4)} then l else ${L()}`, `pushOne _ ${int(9)}`, `λl → pushOne l n`, `λl → l`][int(6)],
    C: () => `Ref.make ${L()}`,
    L: () => {
      if (higher && r() < 0.4) {
        const c = use("C");
        const f = use("F");
        switch (int(9)) {
          case 0: return `applyTo ${L()} ${fn()}`;
          case 1: return `twice ${L()} ${fn()}`;
          case 2: return f ? `${f} ${L()}` : `applyTo ${L()} (λl → ${L()})`;
          case 3: return c ? `Ref.get ${c}` : `twice ${L()} (λl → ${L()})`;
          case 4: return c ? `keepIn ${c} ${L()}` : `applyTo ${L()} (λl → if List.length l > ${int(4)} then l else ${L()})`;
          case 5: return `(swapFold ${L()} ${L()}).${int(2)}`;
          case 6: return `(callBoth ${fn()} ${fn()} ${L()}).${int(2)}`;
          case 7: return `List.foldl [ 1, 2 ] ${L()} λit ac → if it > 1 then ${fn()} ac else ac`;
          default: return `(List.foldl [ 1, 2 ] ( ${L()}, ${L()} ) λit ac → ( List.push ac.0 it, ${fn()} ac.1 )).${int(2)}`;
        }
      }
      const k = int(22);
      const p = use("P");
      const rec = use("R");
      const ll = use("LL");
      const t = use("T");
      switch (k) {
        case 0: return lit();
        case 1: return `List.push ${L()} ${int(9)}`;
        case 2: return `pushOne ${L()} n`;
        case 3: return `[ …${L()}, ${int(9)} ]`;
        case 4: return `${L()} ++ [ ${int(9)} ]`;
        case 5: return `${L()} ++ ${L()}`;
        case 6: return `List.set ${L()} 0 ${int(9)}`;
        case 7: return `ident ${L()}`;
        case 8: return `pick (n > ${int(4)}) ${L()} ${L()}`;
        case 9: return `both ${L()} ${L()}`;
        case 10: return `fold ${L()} ${L()}`;
        case 11: return `applyTo ${L()} (${lam()})`;
        case 12: return `twice ${L()} (${lam()})`;
        case 13: return `List.copy ${L()}`;
        case 14: return p ? `${p}.${int(2)}` : lit();
        case 15: return rec ? `${rec}.${["a", "b"][int(2)]}` : lit();
        case 16: return t ? `rootOf ${t}` : lit();
        case 17: return ll ? `List.foldl ${ll} ${L()} λel ac → ac ++ el` : lit();
        case 18: return `List.foldl ${L()} ${L()} λit ac → [ …ac, it ]`;
        case 19: return `[ ${int(9)}, …${L()} ]`;
        case 20: return `List.map ${L()} λit → it + ${int(3)}`;
        default: return `if n > ${int(4)} then List.push ${L()} ${int(9)} else ${L()}`;
      }
    },
    P: () => [`( ${L()}, ${L()} )`, `dup ${L()}`, `( List.push ${L()} ${int(9)}, ${L()} )`, `( ${L()}, List.push ${L()} ${int(9)} )`][int(4)],
    R: () => {
      const rec = use("R");
      const k = int(4);
      if (k === 0 || !rec) return `{ a = ${L()}, b = ${L()} }`;
      if (k === 1) return `{ ${rec} | a = ${L()} }`;
      if (k === 2) return `{ ${rec} | a = List.push ${rec}.a ${int(9)} }`;
      return `{ ${rec} | b = List.push ${rec}.a ${int(9)} }`;
    },
    LL: () => {
      const ll = use("LL");
      const k = int(6);
      if (k === 0 || !ll) return `[ ${L()}, ${L()} ]`;
      if (k === 1) return `wrap ${L()}`;
      if (k === 2) return `List.push ${ll} ${L()}`;
      if (k === 3) return `List.update ${ll} 0 λel → List.push el ${int(9)}`;
      if (k === 4) return `List.map ${ll} λel → List.push el ${int(9)}`;
      return `[ …${ll}, ${L()} ]`;
    },
    T: () => {
      const t = use("T");
      const k = int(5);
      if (k === 0 || !t) return `Tip ${L()} Leaf Leaf`;
      if (k === 1) return `Tip ${L()} ${t} ${use("T")}`;
      if (k === 2) return `grow ${t} ${int(9)}`;
      if (k === 3) return `left ${t}`;
      return `Tip (List.push (rootOf ${t}) ${int(9)}) (left ${t}) Leaf`;
    },
  };
  const count = 3 + int(5);
  const types = higher ? ["L", "L", "L", "L", "P", "R", "LL", "T", "F", "F", "C"] : ["L", "L", "L", "L", "P", "R", "LL", "T"];
  for (let i = 0; i < count; i += 1) {
    // A statement on a cell: a list goes into it, or a callback answers its new value.
    if (higher && vars.C.length !== 0 && r() < 0.2) {
      const c = use("C");
      lines.push(`    ${[`Ref.set ${c} ${L()}`, `Ref.update ${c} λold → ${L()}`, `Ref.update ${c} λold → List.push old ${int(9)}`][int(3)]}`);
      continue;
    }
    const t = types[int(types.length)];
    const name = `v${n++}`;
    lines.push(`    ${name} = ${makers[t]()}`);
    vars[t].push(name);
  }
  // What the function answers: a few of its bindings, as text.
  const shown = [];
  const shows = { L: (v) => `\${show ${v}}`, P: (v) => `\${show ${v}.0}\${show ${v}.1}`, R: (v) => `\${show ${v}.a}\${show ${v}.b}`, LL: (v) => `\${showLL ${v}}`, T: (v) => `\${showT ${v}}`, C: (v) => `\${show (Ref.get ${v})}` };
  const all = Object.entries(vars).flatMap(([t, vs]) => (t === "F" ? [] : vs.map((v) => [t, v])));
  const picks = 1 + int(3);
  for (let i = 0; i < picks; i += 1) {
    const [t, v] = r() < 0.6 ? all[all.length - 1 - int(Math.min(3, all.length))] : all[int(all.length)];
    shown.push(shows[t](v));
  }
  const mainCall = r() < 0.1 ? "    s = [ 4, 5 ]\n    Node.print (run 3 s s)" : "    Node.print (run 3 [ 4, 5 ] [ 6 ])";
  const body = lines.join("\n");
  const extra = Object.entries(helpers)
    .filter(([name]) => body.includes(`${name} `))
    .map(([, text]) => `\n\n${text}`)
    .join("");
  return `${prelude}${extra}

run : Int, List Int, List Int → String
run n p q =
${lines.join("\n")}
    "${shown.join(" ")}"


main : Program
main =
${mainCall}
`;
}

function run(cmd, argv, timeoutMs = 60000) {
  return new Promise((done) => {
    const child = spawn(cmd, argv, { cwd: repo });
    let out = "";
    let err = "";
    const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      done({ code, signal, out, err });
    });
  });
}

const flagsOf = { v1: ["--ownership-everywhere", "--sanitize-lists"], v2: ["--ownership=v2", "--ownership-everywhere", "--sanitize-lists"], v3: ["--ownership=v3", "--ownership-everywhere", "--sanitize-lists"] };

async function one(i) {
  const seed = seed0 + i;
  const text = program(seed);
  const dir = join(scratch, `g${i}`);
  mkdirSync(dir);
  const file = join(dir, "Main.beni");
  writeFileSync(file, text);
  if (args.keep) writeFileSync(join(resolve(args.keep), `gen-${seed}.beni`), text);
  const r = { seed };
  const plain = await run(beni, ["build", "--platform=node", `--out=${join(dir, "o")}`, file]);
  if (plain.code !== 0) return { ...r, invalid: plain.err.split("\n").slice(0, 4).join(" | ") };
  const oracle = await run("node", [join(dir, "o", "_main.mjs")]);
  for (const c of checkers) {
    const out = join(dir, c);
    const b = await run(beni, ["build", "--platform=node", ...flagsOf[c], `--out=${out}`, file]);
    if (b.signal !== null) {
      r[c] = { status: "crash", detail: String(b.signal) };
      continue;
    }
    if (b.code !== 0) {
      r[c] = { status: /is refused|ownership|list_|still used|may be shared|changed/i.test(b.err) ? "refused" : "crash", detail: b.err.split("\n")[0] };
      continue;
    }
    const got = await run("node", [join(out, "_main.mjs")]);
    if (/a stale read of a list/.test(got.err)) r[c] = { status: "trap", detail: (got.err.match(/beni: a stale read[^\n]*/) ?? [""])[0] };
    else if (got.out !== oracle.out || got.code !== oracle.code) r[c] = { status: "differs", detail: `${JSON.stringify(oracle.out)} -> ${JSON.stringify(got.out)}` };
    else r[c] = { status: "same" };
  }
  rmSync(dir, { recursive: true, force: true });
  return r;
}

if (args.print) {
  console.log(program(Number(args.print)));
  process.exit(0);
}

const results = new Array(total);
let next = 0;
async function worker() {
  while (next < total) {
    const i = next++;
    results[i] = await one(i);
    if (i % 10 === 0) process.stderr.write(`\r${i + 1}/${total} `);
  }
}
await Promise.all(Array.from({ length: jobs }, worker));
process.stderr.write("\n");

const valid = results.filter((r) => !r.invalid);
console.log(`beni: ${beni}`);
console.log(`programs: ${results.length} (seeds ${seed0} to ${seed0 + total - 1}); the oracle builds ${valid.length}\n`);
console.log("| checker | same | refused | trap | differs | crash |");
console.log("|---|---:|---:|---:|---:|---:|");
for (const c of checkers) {
  const n = (s) => valid.filter((r) => r[c]?.status === s).length;
  console.log(`| ${c} | ${n("same")} | ${n("refused")} | ${n("trap")} | ${n("differs")} | ${n("crash")} |`);
}
if (checkers.includes("v3")) {
  for (const o of checkers.filter((c) => c !== "v3")) {
    const lost = valid.filter((r) => r[o]?.status === "same" && r.v3?.status === "refused").length;
    const won = valid.filter((r) => r[o]?.status === "refused" && r.v3?.status === "same").length;
    console.log(`\n${o} accepts and v3 refuses: ${lost}; ${o} refuses and v3 accepts: ${won}`);
  }
}
const invalid = results.filter((r) => r.invalid);
if (invalid.length) console.log(`\nPrograms that the oracle does not build: ${invalid.length}; the first: seed ${invalid[0].seed}: ${invalid[0].invalid}`);
for (const c of checkers) {
  const bad = valid.filter((r) => ["trap", "differs", "crash"].includes(r[c]?.status));
  if (bad.length) console.log(`\n${c}: ${bad.length} traps, differences and crashes`);
  for (const r of bad.slice(0, 20)) console.log(`- ${c} seed ${r.seed}: ${r[c].status}: ${r[c].detail}`);
}
if (args.json) writeFileSync(resolve(args.json), JSON.stringify(results, null, 1));
