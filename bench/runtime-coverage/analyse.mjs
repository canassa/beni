// Research 103's tables: which shipped platform-runtime code ran.
//
//   node bench/runtime-coverage/analyse.mjs
//
// Reads run.mjs's builds and coverage. An app is one bundle: Conduit's three
// scripts run the same `_main.mjs` (checked byte for byte), and a byte is
// live when any of them ran it. Each bundle is cut into research 102's
// top-level units (bench/output-size/units.mjs), each owned by the source
// holding most of its mapped bytes. A byte is executed when the innermost
// V8 block range containing it has a non-zero count (V8 nests ranges; the
// smallest wins). Per unit: `called` (its function body ran, or it is not
// a function) and its never-executed bytes. Per source group: units, raw
// shipped, raw never executed, units never called, and brotli *alone*
// (research 102 §1: the group's units stubbed and the bundle recompressed)
// for the whole group and for its never-called units only.
//
// Writes zig-out/runtime-coverage/analysis.json (every unit, with each
// never-executed range's text) and bench/runtime-coverage/results/
// summary.json (the group tables), and prints the tables.

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { units } from "../output-size/units.mjs";
import { br, apply, hash } from "../output-size/lib.mjs";

const repo = resolve(import.meta.dirname, "../..");
const work = resolve(repo, process.env.WORK ?? "zig-out/runtime-coverage");
const appRuns = {
  Conduit: ["ConduitEditor", "ConduitReader", "ConduitTour"],
  TodoMVC: ["TodoMVC"],
  Sternhalma: ["Sternhalma"],
  BikeWars: ["BikeWars"],
  Table: ["Table"],
};

const group = (owner) => (owner.startsWith("platforms/") ? owner.slice("platforms/".length) : owner.startsWith("core/") || owner === "unmapped" ? owner : "app");

// 0 outside every function, 1 never executed, 2 executed.
function mask(len, script) {
  const all = [];
  for (const fn of script.functions) for (const r of fn.ranges) all.push(r);
  all.sort((a, b) => b.endOffset - b.startOffset - (a.endOffset - a.startOffset));
  const m = new Uint8Array(len);
  for (const r of all) m.fill(r.count > 0 ? 2 : 1, r.startOffset, Math.min(r.endOffset, len));
  return m;
}

const result = {};
const stubs = {};
const summary = {};
for (const [app, runs] of Object.entries(appRuns)) {
  for (const p of ["tea", "direct"]) {
    let src = null, map = null, live = null;
    for (const run of runs) {
      const dir = join(work, `${run}-${p}`);
      const s = readFileSync(join(dir, "_main.mjs"), "utf8").replace(/\/\/# sourceMappingURL=.*\n?$/, "");
      if (src !== null && hash(s) !== hash(src)) throw new Error(`${run}-${p}: a different bundle from ${runs[0]}`);
      src = s;
      map ??= JSON.parse(readFileSync(join(dir, "_main.mjs.map"), "utf8"));
      const script = JSON.parse(readFileSync(join(dir, "coverage.json"), "utf8")).result.find((x) => x.url.endsWith("/_main.mjs"));
      const m = mask(src.length, script);
      if (live === null) live = m;
      else for (let i = 0; i < m.length; i++) if (m[i] === 2) live[i] = 2;
    }
    const { units: us } = units(src, map);
    const total = br(src);
    const rows = us.map((u) => {
      let dead = 0;
      const ranges = [];
      for (let i = u.start; i < u.end; i++) {
        if (live[i] !== 1) continue;
        dead++;
        if (ranges.length && ranges.at(-1)[1] === i) ranges.at(-1)[1] = i + 1;
        else ranges.push([i, i + 1]);
      }
      let called = true;
      if (u.stub.node) {
        called = false;
        for (let i = u.stub.start; i < u.stub.end; i++) if (live[i] !== 1) { called = true; break; }
      }
      return { js: u.js, orig: u.orig, owner: u.owner, group: group(u.owner), raw: u.end - u.start, dead, called, ranges, stub: { start: u.stub.start, end: u.stub.end, text: u.stub.text }, deadText: called ? ranges.map(([a, b]) => src.slice(a, b)) : [], text: called ? undefined : src.slice(u.start, u.end) };
    });
    const groups = {};
    for (const r of rows) (groups[r.group] ??= []).push(r);
    // Every never-executed byte of these rows deleted, and the bundle
    // recompressed: what the group's dead code costs, branches included.
    // Not a program (a deleted branch leaves broken syntax); a price only.
    const deadAlone = (rs) => {
      const edits = [];
      for (const r of rs) for (const [a, b] of r.ranges) edits.push({ start: a, end: b, text: "" });
      return edits.length ? total - br(apply(src, edits)) : 0;
    };
    const g = {};
    for (const [name, rs] of Object.entries(groups)) {
      const uncalled = rs.filter((r) => !r.called);
      g[name] = {
        deadAlone: deadAlone(rs),
        units: rs.length,
        raw: rs.reduce((a, r) => a + r.raw, 0),
        deadRaw: rs.reduce((a, r) => a + r.dead, 0),
        uncalled: uncalled.length,
        uncalledRaw: uncalled.reduce((a, r) => a + r.raw, 0),
        alone: total - br(apply(src, rs.map((r) => r.stub))),
        aloneUncalled: uncalled.length ? total - br(apply(src, uncalled.map((r) => r.stub))) : 0,
      };
    }
    // The whole platform runtime (platforms/*), and its never-called units, alone.
    const plat = rows.filter((r) => r.owner.startsWith("platforms/"));
    const platDead = plat.filter((r) => !r.called);
    g["(platform runtime)"] = {
      deadAlone: deadAlone(plat),
      units: plat.length,
      raw: plat.reduce((a, r) => a + r.raw, 0),
      deadRaw: plat.reduce((a, r) => a + r.dead, 0),
      uncalled: platDead.length,
      uncalledRaw: platDead.reduce((a, r) => a + r.raw, 0),
      alone: total - br(apply(src, plat.map((r) => r.stub))),
      aloneUncalled: platDead.length ? total - br(apply(src, platDead.map((r) => r.stub))) : 0,
    };
    stubs[`${app}-${p}`] = Object.fromEntries(rows.map((r) => [r.js, r.stub]));
    result[`${app}-${p}`] = { total, bundle: join(work, `${runs[0]}-${p}`, "_main.mjs"), rows: rows.map(({ stub, ...r }) => r) };
    summary[`${app}-${p}`] = { total, groups: g };
    console.log(`\n== ${app} ${p}: ${total} B brotli`);
    console.log("group".padEnd(30), "units", "raw".padStart(7), "neverRan".padStart(8), "uncalled".padStart(10), "alone".padStart(6), "uncalledAlone".padStart(13), "deadAlone".padStart(9));
    for (const [name, v] of Object.entries(g).filter(([n]) => n.includes("/") || n.startsWith("(")).sort((a, b) => b[1].alone - a[1].alone))
      console.log(name.padEnd(30), String(v.units).padStart(5), String(v.raw).padStart(7), String(v.deadRaw).padStart(8), `${v.uncalled}/${v.uncalledRaw}`.padStart(10), String(v.alone).padStart(6), String(v.aloneUncalled).padStart(13), String(v.deadAlone).padStart(9));
  }
}
writeFileSync(join(work, "analysis.json"), JSON.stringify(result, null, 1));
writeFileSync(join(work, "stubs.json"), JSON.stringify(stubs));
mkdirSync(join(import.meta.dirname, "results"), { recursive: true });
writeFileSync(join(import.meta.dirname, "results/summary.json"), JSON.stringify(summary, null, 1) + "\n");
