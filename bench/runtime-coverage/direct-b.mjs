// Research 103 §3.2: what browser-direct still ships of the framework, live
// and dead together — each app's browser-tea `Rt` units beyond the dozen
// primitives the direct TodoMVC page uses (its slots, `template`, `place`),
// and `Direct`'s run-time template protocol (`template*` and the helpers
// only it calls) — stubbed as research 102 stubs a group, alone.
//
//   node bench/runtime-coverage/direct-b.mjs

import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { br, apply } from "../output-size/lib.mjs";

const repo = resolve(import.meta.dirname, "../..");
const analysis = JSON.parse(readFileSync(join(repo, "zig-out/runtime-coverage/analysis.json"), "utf8"));
const stubs = JSON.parse(readFileSync(join(repo, "zig-out/runtime-coverage/stubs.json"), "utf8"));
const primitives = new Set(analysis["TodoMVC-direct"].rows.filter((r) => r.owner === "platforms/browser/Rt").map((r) => r.orig));
console.log(`Rt primitives the direct TodoMVC page keeps: ${[...primitives].join(" ")}`);
for (const app of ["Conduit", "TodoMVC", "Sternhalma", "BikeWars", "Table"]) {
  const key = `${app}-direct`;
  const a = analysis[key];
  const src = readFileSync(a.bundle, "utf8").replace(/\/\/# sourceMappingURL=.*\n?$/, "");
  const total = br(src);
  const rt = a.rows.filter((r) => r.owner === "platforms/browser/Rt" && !primitives.has(r.orig));
  const tp = a.rows.filter((r) => r.owner === "platforms/browser-direct/Direct" && /^template/.test(r.orig ?? ""));
  const alone = (rows) => (rows.length ? total - br(apply(src, rows.map((r) => stubs[key][r.js]))) : 0);
  console.log(`${key}: ${total} B; TEA Rt beyond the primitives ${rt.length} units ${rt.reduce((n, r) => n + r.raw, 0)} raw, alone ${alone(rt)}; Direct template protocol ${tp.length} units ${tp.reduce((n, r) => n + r.raw, 0)} raw, alone ${alone(tp)}; both ${alone([...rt, ...tp])}`);
}
