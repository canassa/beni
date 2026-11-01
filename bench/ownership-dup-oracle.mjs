#!/usr/bin/env node
// The dup oracle (#1546): a writer `f : T → T` over `type T = N (List Int) T T
// | L` whose body puts one child `c` (at pattern depth 1, 2 or 3) beside a
// recursive call on it, as `N (List.push v 1) (f c) c` does, and drivers
// that call `f` on an argument holding one tree twice, `f (N [] t t)`, then
// maybe write into the result. Each program is checked by `beni dump
// --stage=ownership --ownership=v2` (f local, or imported from a module of
// its own) and then run by a small concrete interpreter twice:
//
// - every write copying (the reference);
// - every write in place where its verdict allows it: a push whose demand is
//   `accepted fresh`, or `accepted param` when the caller allowed that path
//   of the parameter; a call allows its callee the argument paths whose
//   demand is accepted (`param` ones when the caller itself allowed them). A
//   path with no demand line is written in place, so a write v2 missed
//   shows. A refused demand copies. `--forced` makes every write in place:
//   it must report unsafe runs, the oracle's own control.
//
// A driver is `accepted` when every demand of `f` and of it is accepted. A
// run whose `f` has a refused demand never builds; it is counted apart as
// `partial` (its refused sites copying), which is #1546's question.
//
//     node bench/ownership-dup-oracle.mjs [--beni=zig-out/safe/bin/beni]
//         [--work=zig-out/dup-oracle] [--forced]

import { spawnSync } from "node:child_process";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const opt = Object.fromEntries(process.argv.slice(2).map((a) => { const [k, v] = a.replace(/^--/, "").split("="); return [k, v ?? true]; }));
const beni = resolve(repo, opt.beni ?? "zig-out/safe/bin/beni");
const work = resolve(repo, opt.work ?? "zig-out/dup-oracle");
const forced = !!opt.forced;

// ---- expressions ----------------------------------------------------------
// {k:"var",n} {k:"N",a:[e,e,e]} {k:"L"} {k:"lit",items} {k:"push",e,x}
// {k:"call",fn,arg} {k:"tup",a} {k:"case",s,arms:[{p,b}]}
// patterns: {k:"var",n} {k:"_"} {k:"N",a} {k:"L"}
const V = (n) => ({ k: "var", n });
const N = (a, b, c) => ({ k: "N", a: [a, b, c] });
const L = { k: "L" };
const nil = { k: "lit", items: [] };
const push = (e, x) => ({ k: "push", e, x });
const call = (arg) => ({ k: "call", fn: "f", arg });
const cs = (s, arms) => ({ k: "case", s, arms });
const W = { k: "_" };

// Printing records each site's offset; `qual` is how the driver names `f`.
function printer(qual) {
  let out = "";
  const sites = [];
  const emit = (s) => { out += s; };
  const atom = (e) => e.k === "var" || e.k === "L" || e.k === "lit" || e.k === "tup";
  function ex(e, ind) {
    switch (e.k) {
      case "var": return emit(e.n);
      case "L": return emit("L");
      case "lit": return emit(e.items.length ? `[ ${e.items.join(", ")} ]` : "[]");
      case "N": emit("N"); for (const a of e.a) { emit(" "); sub(a, ind); } return;
      case "push": e.site = sites.push(out.length) - 1; emit("List.push "); sub(e.e, ind); emit(` ${e.x}`); return;
      case "call": e.site = sites.push(out.length) - 1; emit(`${qual} `); sub(e.arg, ind); return;
      case "tup": emit("( "); e.a.forEach((a, i) => { if (i) emit(", "); ex(a, ind); }); emit(" )"); return;
      case "case":
        emit("case "); ex(e.s, ind); emit(" of");
        for (const arm of e.arms) { emit(`\n${" ".repeat(ind + 4)}`); pat(arm.p.k === "N" ? topPat(arm.p) : arm.p); emit(" →\n" + " ".repeat(ind + 8)); ex(arm.b, ind + 8); emit("\n"); }
        return;
    }
  }
  function sub(e, ind) { if (atom(e)) ex(e, ind); else { emit("("); ex(e, ind); emit(")"); } }
  function pat(p) {
    if (p.k === "var") emit(p.n); else if (p.k === "_") emit("_"); else if (p.k === "L") emit("L");
    else { if (!p.top) emit("("); emit("N"); for (const a of p.a) { emit(" "); pat(a); } if (!p.top) emit(")"); }
  }
  return {
    fn(name, sig, param, body) { emit(`pub ${name} : ${sig}\n${name} ${param} =\n    `); ex(body, 4); emit("\n\n\n"); },
    text: () => out,
    pos(site) { const before = out.slice(0, sites[site]); const lines = before.split("\n"); return `${lines.length}:${[...lines.at(-1)].length + 1}`; },
  };
}
// A top-level pattern prints without its parentheses.
const topPat = (p) => ({ ...p, top: true });

// ---- the family -----------------------------------------------------------
// Depth d: the pattern reaching the child `c`, its parameter path, and the
// lists on the way (`v` at depth 1, `w` at 2, `u` at 3).
const depths = {
  1: { p: { k: "N", a: [V("v"), V("c"), V("r")] }, paths: { v: [0], c: [1], r: [2] } },
  2: { p: { k: "N", a: [V("v"), { k: "N", a: [V("w"), V("c"), W] }, V("r")] }, paths: { v: [0], w: [1, 0], c: [1, 1], r: [2] } },
  3: { p: { k: "N", a: [V("v"), { k: "N", a: [V("w"), { k: "N", a: [V("u"), V("c"), W] }, W] }, V("r")] }, paths: { v: [0], w: [1, 0], u: [1, 1, 0], c: [1, 1, 1], r: [2] } },
};
const c = V("c");
const bodies = {
  dup: (d) => N(push(V("v"), 1), call(c), c),
  dupSwap: (d) => N(push(V("v"), 1), c, call(c)),
  twice: (d) => N(push(V("v"), 1), call(c), call(c)),
  noOwn: (d) => N(V("v"), call(c), c),
  other: (d) => N(push(V("v"), 1), call(c), V("r")),
  alone: (d) => N(push(V("v"), 1), call(c), L),
  besideTwice: (d) => N(push(V("v"), 1), call(c), N(nil, c, c)),
  nested: (d) => N(push(V("v"), 1), N(nil, c, call(c)), c),
  deepList: (d) => N(V("v"), call(c), N(d >= 2 ? push(V(d === 3 ? "u" : "w"), 1) : push(V("v"), 2), c, L)),
};
const t = V("t");
const drivers = {
  plain: () => call(N(nil, t, t)),
  left: () => call(N(nil, t, L)),
  right: () => call(N(nil, L, t)),
  kept: () => ({ k: "tup", a: [call(N(nil, t, t)), t] }),
  first: () => cs(call(N(nil, t, t)), [{ p: { k: "N", a: [V("a"), W, W] }, b: push(V("a"), 9) }, { p: W, b: nil }]),
  second: () => cs(call(N(nil, t, t)), [{ p: { k: "N", a: [W, { k: "N", a: [V("b"), W, W] }, W] }, b: push(V("b"), 9) }, { p: W, b: nil }]),
  third: () => cs(call(N(nil, t, t)), [{ p: { k: "N", a: [W, W, { k: "N", a: [V("b"), W, W] }] }, b: push(V("b"), 9) }, { p: W, b: nil }]),
  secondZ: () => cs(call(N(nil, t, t)), [{ p: { k: "N", a: [W, { k: "N", a: [V("b"), W, W] }, V("z")] }, b: { k: "tup", a: [push(V("b"), 9), V("z")] } }, { p: W, b: { k: "tup", a: [nil, L] } }]),
  again: () => call(call(N(nil, t, t))),
  underCall: () => call(N({ k: "lit", items: [0] }, t, call(t))),
};
const driverSig = { kept: "T → T × T", first: "T → List Int", second: "T → List Int", third: "T → List Int", secondZ: "T → List Int × T" };

function program(bodyName, depth, imported) {
  const D = depths[depth];
  const fBody = cs(V("t"), [{ p: topPat(D.p), b: bodies[bodyName](depth) }, { p: W, b: L }]);
  const typeText = `${imported ? "pub " : ""}type T\n    = N (List Int) T T\n    | L\n\n\n`;
  // The type goes first; positions are counted on the final text.
  const fPrinter = printer("f");
  fPrinter.fn("f", "T → T", "t", fBody);
  const dPrinter = printer(imported ? "A.f" : "f");
  const ds = Object.entries(drivers).map(([name, mk]) => { const b = mk(); dPrinter.fn(name, driverSig[name] ?? "T → T", "t", b); return { name, b }; });
  const header = imported ? "import A exposing (T, N, L)\n\n\n" : "";
  const typeLines = typeText.split("\n").length - 1;
  const shift = (pos, by) => { const [l, col] = pos.split(":").map(Number); return `${l + by}:${col}`; };
  const fText = fPrinter.text();
  const fLines = fText.split("\n").length - 1;
  const fShift = typeLines;
  const dShift = imported ? header.split("\n").length - 1 : typeLines + fLines;
  return {
    fFun: { param: "t", body: fBody, paths: D.paths, pos: (s) => shift(fPrinter.pos(s), fShift), module: imported ? "A" : "Main" },
    drivers: ds.map(({ name, b }) => ({ name, body: b, pos: (s) => shift(dPrinter.pos(s), dShift), module: "Main" })),
    files: imported ? { "A.beni": typeText + fText, "Main.beni": header + dPrinter.text() } : { "Main.beni": typeText + fText + dPrinter.text() },
  };
}

// ---- verdicts ---------------------------------------------------------------
function verdicts(dump) {
  const by = new Map(); // "module pos" → [{path, ok, cause}]
  let mod = "";
  for (const line of dump.split("\n")) {
    const m = /^module (\S+)/.exec(line);
    if (m) { mod = m[1]; continue; }
    const d = /^  (\d+:\d+) (\S+) (.+?): (accepted|rejected|pending)\s*(\S*)/.exec(line);
    if (!d) continue;
    const subj = d[3];
    const i = subj.indexOf("#");
    const path = i < 0 ? "" : subj.slice(i);
    const key = `${mod} ${d[1]}`;
    if (!by.has(key)) by.set(key, []);
    by.get(key).push({ path, ok: d[4] === "accepted", cause: d[5].replace(/:$/, "") });
  }
  return by;
}
// A demand path `#N.1⟨T⟩#N.0` as a matcher of a concrete field path.
function matcher(path) {
  const re = path.replace(/#N\.(\d)/g, ",$1").replace(/⟨T⟩/g, "(?:,[12])*").replace(/\[\*\]/g, ",\\*");
  return new RegExp(`^${re}$`);
}
function lookup(lines, q) {
  if (!lines) return null;
  const s = q.map((x) => `,${x}`).join("");
  const exact = lines.find((l) => !l.path.includes("⟨") && matcher(l.path).test(s));
  return exact ?? lines.find((l) => matcher(l.path).test(s)) ?? null;
}

// ---- the interpreter -------------------------------------------------------
let nextId = 0;
const arr = (items) => ({ id: nextId++, items });
const show = (v) => v === undefined ? "?" : v.tag === "L" ? "L" : v.tag === "N" ? `N[${v.f[0].items.join(",")}](${show(v.f[1])})(${show(v.f[2])})` : v.tag === "tup" ? `(${v.a.map(show).join(", ")})` : v.items ? `[${v.items.join(",")}]` : "?";

function run(prog, driver, vmap, input, mode) {
  let steps = 0;
  const fn = prog.fFun;
  const verdictAt = (fun, site) => vmap.get(`${fun.module} ${fun.pos(site)}`);
  function evalE(e, env, ctx) {
    if (++steps > 100000) throw new Error("diverges");
    switch (e.k) {
      case "var": return env[e.n].val;
      case "L": return { tag: "L" };
      case "lit": return arr([...e.items]);
      case "N": return { tag: "N", f: e.a.map((a) => evalE(a, env, ctx)) };
      case "tup": return { tag: "tup", a: e.a.map((a) => evalE(a, env, ctx)) };
      case "push": {
        const a = evalE(e.e, env, ctx);
        let inPlace = mode === "forced";
        if (mode === "verdicts") {
          const v = lookup(verdictAt(ctx.fun, e.site), []);
          if (!v) inPlace = true;
          else if (v.ok) inPlace = v.cause === "param" && e.e.k === "var" && env[e.e.n].pp ? ctx.own(env[e.e.n].pp) : true;
        }
        if (inPlace) { a.items.push(e.x); return a; }
        return arr([...a.items, e.x]);
      }
      case "call": {
        const a = evalE(e.arg, env, ctx);
        const lines = verdictAt(ctx.fun, e.site);
        const own = (q) => {
          if (mode === "forced") return true;
          const v = lookup(lines, q);
          if (!v) return true;
          if (!v.ok) return false;
          return v.cause === "param" ? argOwn(e.arg, q, env, ctx) : true;
        };
        return apply(a, { fun: fn, own });
      }
      case "case": {
        const s = evalE(e.s, env, ctx);
        const sp = e.s.k === "var" ? env[e.s.n].pp : null;
        for (const arm of e.arms) {
          const b = {};
          if (match(arm.p, s, sp, b)) return evalE(arm.b, { ...env, ...b }, ctx);
        }
        throw new Error("no arm");
      }
    }
  }
  function argOwn(e, q, env, ctx) {
    if (e.k === "var") return env[e.n].pp ? ctx.own([...env[e.n].pp, ...q]) : true;
    if (e.k === "N") return q.length ? argOwn(e.a[q[0]], q.slice(1), env, ctx) : true;
    return true;
  }
  function match(p, v, pp, b) {
    if (p.k === "_") return true;
    if (p.k === "var") { b[p.n] = { val: v, pp }; return true; }
    if (p.k === "L") return v.tag === "L";
    if (v.tag !== "N") return false;
    return p.a.every((sp, i) => match(sp, v.f[i], pp ? [...pp, i] : null, b));
  }
  const apply = (arg, ctx) => evalE(fn.body, { [fn.param]: { val: arg, pp: [] } }, ctx);
  const dctx = { fun: driver, own: () => true };
  return show(evalE(driver.body, { t: { val: input(), pp: [] } }, dctx));
}

const inputs = [
  () => ({ tag: "L" }),
  () => ({ tag: "N", f: [arr([5]), { tag: "L" }, { tag: "L" }] }),
  () => ({ tag: "N", f: [arr([5]), { tag: "N", f: [arr([6]), { tag: "L" }, { tag: "L" }] }, { tag: "L" }] }),
];
const tree = (d, k) => d === 0 ? { tag: "L" } : { tag: "N", f: [arr([k]), tree(d - 1, k * 2), tree(d - 1, k * 2 + 1)] };
for (let d = 2; d <= 5; d++) inputs.push(() => tree(d, 1));

// ---- the sweep ---------------------------------------------------------------
const tally = { programs: 0, drivers: 0, accepted: 0, acceptedUnsafe: 0, partial: 0, partialUnsafe: 0, refused: 0, runs: 0, differ: 0, differAccepted: 0, differPartial: 0, differRefused: 0 };
const unsafe = [];
rmSync(work, { recursive: true, force: true });
for (const imported of [false, true]) for (const bodyName of Object.keys(bodies)) for (const depth of [1, 2, 3]) {
  const prog = program(bodyName, depth, imported);
  const dir = join(work, `${bodyName}-${depth}-${imported ? "imported" : "local"}`);
  mkdirSync(dir, { recursive: true });
  for (const [f, text] of Object.entries(prog.files)) writeFileSync(join(dir, f), text);
  const r = spawnSync(beni, ["dump", "--stage=ownership", "--ownership=v2", "--ownership-everywhere", dir], { encoding: "utf8" });
  if (r.status !== 0 && !r.stdout.includes("module")) { console.error(dir, r.stderr); process.exit(2); }
  writeFileSync(join(dir, "dump.txt"), r.stdout);
  const vmap = verdicts(r.stdout);
  // Every push site must have read a verdict line; a call with none writes nothing.
  const sitesOf = (fun) => { const s = []; const walk = (e) => { if (!e || typeof e !== "object") return; if (e.site !== undefined) s.push(e); for (const v of Object.values(e)) if (Array.isArray(v)) v.forEach(walk); else if (v && typeof v === "object") walk(v); }; walk(fun.body); return s; };
  const okAll = (fun) => sitesOf(fun).every((e) => { const ls = vmap.get(`${fun.module} ${fun.pos(e.site)}`); if (!ls) { if (e.k === "push") throw new Error(`${dir}: no verdict at ${fun.pos(e.site)}`); return true; } return ls.every((l) => l.ok); });
  const limited = (name) => r.stdout.includes(`unchecked ${name}:`);
  const fOk = okAll(prog.fFun) && !limited("f");
  tally.programs++;
  for (const drv of prog.drivers) {
    tally.drivers++;
    const dOk = okAll(drv) && !limited(drv.name);
    const kind = fOk && dOk ? "accepted" : dOk ? "partial" : "refused";
    tally[kind]++;
    let bad = false;
    for (const input of inputs) {
      tally.runs++;
      const ref = run(prog, drv, vmap, input, "copy");
      const got = run(prog, drv, vmap, input, forced ? "forced" : "verdicts");
      if (ref !== got) { tally.differ++; tally[`differ${kind[0].toUpperCase()}${kind.slice(1)}`]++; bad = true; if (unsafe.length < 6) unsafe.push(`${dir} ${drv.name} [${kind}]: copy ${ref} vs in place ${got}`); }
    }
    if (bad && kind === "accepted") tally.acceptedUnsafe++;
    if (bad && kind === "partial") tally.partialUnsafe++;
  }
}
console.log(JSON.stringify(tally));
for (const u of unsafe) console.log(u);
