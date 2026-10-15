// Research 103 §3: every never-executed piece of shipped platform runtime,
// classified by why it ships, and priced.
//
//   node bench/runtime-coverage/classify.mjs
//
// Categories (the brief's):
//   a  reachable only through a value the compiler could know statically
//      (a command kind or policy never built, a control kind never
//      rendered, an event option never asked for, a template shape never
//      made) — can be specialised away;
//   b  generic runtime that browser-direct's compile-time analysis should
//      have replaced (the framework not yet compiled away);
//   c  needed, but not reached by the scripts (error paths, defect
//      teardown, list edits the scripts do not make, a subscription that
//      leaves) — real guarantees, kept;
//   d  can never run (an assertion of the compiler's own invariant, a
//      statement that does nothing).
//
// A rule names a unit (`owner:name`, the beni declaration), optionally the
// platform build (`tea`/`direct`) and a pattern a never-executed range must
// contain; the first matching rule wins. Every never-executed range of a
// platform unit must match one: an unclassified one fails the run.
// Prices: each category's never-executed bytes deleted from the bundle and
// recompressed (price.mjs's method), and per module the brotli *alone* of
// what ships, of what never ran, and of what is removable (a + b + d).

import { readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { br, apply } from "../output-size/lib.mjs";

const repo = resolve(import.meta.dirname, "../..");
const analysis = JSON.parse(readFileSync(join(repo, "zig-out/runtime-coverage/analysis.json"), "utf8"));

// [owner (under platforms/), names ('*' any), category, label, {platform, has}]
const R = (owner, names, cat, label, opt = {}) => ({ owner, names: names === "*" ? null : names.split(" "), cat, label, ...opt });
const rules = [
  // ---- Commands and subscriptions (Tea, Cmd, Hosted) --------------------
  R("browser-tea/Tea browser-direct/Tea", "perform", "a", "command kinds and policies the program never builds"),
  R("browser-tea/Tea browser-direct/Tea", "starter stopped waitFor", "a", "command kinds and policies the program never builds"),
  R("browser-tea/Tea browser-direct/Tea", "queue close stop", "a", "command kinds and policies the program never builds"),
  R("browser-tea/Tea browser-direct/Tea", "begin", "a", "subscription kinds the program never makes"),
  R("browser/Cmd", "map", "a", "command kinds and policies the program never builds"),
  R("browser/Hosted", "eq mapLater run", "a", "command kinds and policies the program never builds"),
  R("browser/Hosted", "afterRender", "a", "command kinds and policies the program never builds", { app: "Conduit" }),
  R("browser/Hosted", "afterRender emit", "a", "send callbacks no job of the program calls"),
  R("browser-tea/Tea browser-direct/Tea", "running settle diff hear lives", "c", "subscriptions and runs the scripts do not change"),
  R("browser-tea/Tea browser-direct/Tea", "address", "c", "error: an application opened from a file"),
  R("browser/Hosted", "hear unhear", "c", "subscriptions and runs the scripts do not change"),
  R("browser/Sub", "both", "c", "subscriptions and runs the scripts do not change"),
  R("browser/Listen browser/Browser/Events", "*", "c", "subscriptions and runs the scripts do not change"),
  R("browser/Browser", "afterRender hosted", "c", "after-render work and re-entrant sends the scripts do not make"),
  // ---- Storage, navigation: precise error wrapping (rule 9) -------------
  R("browser/Storage", "*", "c", "rule 9: each host failure wrapped and typed"),
  R("browser/Browser/Navigation", "*", "c", "rule 9: each host failure wrapped and typed; external links"),
  // ---- Http (not edited here: other slices own it) ----------------------
  R("browser/Http", "size utf8 tracked$s chunks$s orEmpty failed", "a", "Http: request options never used (tracked body, body sizes)"),
  R("browser/Http", "answer$s", "a", "Http: request options never used (tracked body, body sizes)"),
  R("browser/Http", "payload", "a", "Http: request options never used (form bodies)"),
  R("browser/Http", "exchange$s", "a", "Http: request options never used (timeouts)", { has: "TimeoutError" }),
  R("browser/Http", "settled timerOf readingOf", "a", "Http: request options never used (timeouts)"),
  R("browser/Http", "*", "c", "rule 9: each host failure wrapped and typed"),
  // ---- browser-direct ---------------------------------------------------
  R("browser-direct/Direct", "templateWanted templateFallbackEntered", "d", "assertions of the compiler's own tables", { has: "invariant" }),
  R("browser-direct/Direct", "templateWanted templateFallbackEntered templateMapMount templateMapPatch templateRow templatePlace templateSelect templateSelectNew templateCapture templatePatch restateValue childList", "b", "direct: template selection run at run time"),
  R("browser/Rt", "forKeyed trimmed reconcile forPosition patchRow sameInputs elements restateRows again restate passed endPass childList childMaybe patch held", "b", "direct: TEA's patch and row runtime shipped on direct", { platform: "direct", app: "Conduit Sternhalma BikeWars" }),
  R("browser-direct/Direct browser/Rt", "affected edits markAndHold holdEdit", "a", "controlled-input kinds the program never renders", { has: "options elements getElementsByName localName" }),
  R("browser-direct/Direct browser/Rt", "markAndHold holdEdit edits", "a", "controlled-input kinds the program never renders", { app: "Conduit" }),
  R("browser-direct/Direct browser/Rt", "listen listenRow delegate fire", "a", "event options the program never asks for", { has: "stopPropagation preventDefault" }),
  R("browser-direct/Direct browser/Rt", "listen fire", "a", "Html.map wrappers the program never makes", { has: ".up" }),
  R("browser-direct/Direct", "flush", "c", "the release file's `flush` export (Browser.flush, the driver)"),
  R("browser-direct/Direct", "*", "c", "defects, mount errors, list edits and branches the scripts do not make"),
  // ---- browser Rt -------------------------------------------------------
  R("browser/Rt", "template gather", "a", "template shapes no site of the program makes"),
  R("browser/Rt", "*", "c", "defects, mount errors, list edits and live rows the scripts do not reach"),
  // ---- html vocabulary --------------------------------------------------
  R("html/Html", "*", "c", "defects, mount errors, list edits and live rows the scripts do not reach"),
];

function classify(row, app, platform, text) {
  const owner = row.owner.replace(/^platforms\//, "");
  for (const r of rules) {
    if (!r.owner.split(" ").includes(owner)) continue;
    if (r.names && !r.names.includes(row.orig)) continue;
    if (r.platform && r.platform !== platform) continue;
    if (r.app && !r.app.split(" ").includes(app)) continue;
    if (r.has && !r.has.split(" ").some((h) => text.includes(h))) continue;
    return r;
  }
  throw new Error(`unclassified: ${app}-${platform} ${owner}:${row.orig}: ${text.slice(0, 120)}`);
}

const out = {};
for (const [key, a] of Object.entries(analysis)) {
  const [app, platform] = key.split("-");
  const src = readFileSync(a.bundle, "utf8").replace(/\/\/# sourceMappingURL=.*\n?$/, "");
  const total = br(src);
  const byCat = {}, byLabel = {}, byModule = {};
  const cut = (ranges) => (ranges.length ? total - br(apply(src, ranges.map(([s, e]) => ({ start: s, end: e, text: "" })))) : 0);
  const plat = a.rows.filter((r) => r.owner.startsWith("platforms/"));
  for (const r of plat) {
    const mod = r.owner.replace(/^platforms\//, "");
    const m = (byModule[mod] ??= { raw: 0, dead: 0, removableRaw: 0, units: [], deadRanges: [], removable: [] });
    m.raw += r.raw;
    m.dead += r.dead;
    m.units.push(r);
    for (const [s, e] of r.ranges) {
      const rule = classify(r, app, platform, src.slice(s, e));
      (byCat[rule.cat] ??= []).push([s, e]);
      const l = (byLabel[`${rule.cat}: ${rule.label}`] ??= { ranges: [], raw: 0 });
      l.ranges.push([s, e]);
      l.raw += e - s;
      m.deadRanges.push([s, e]);
      if (rule.cat !== "c") {
        m.removable.push([s, e]);
        m.removableRaw += e - s;
      }
    }
  }
  // The module's units stubbed as research 102 stubs them, from analyse's rows.
  const stubs = JSON.parse(readFileSync(join(repo, "zig-out/runtime-coverage/stubs.json"), "utf8"))[key];
  const result = { total, categories: {}, labels: {}, modules: {} };
  for (const [c, ranges] of Object.entries(byCat)) result.categories[c] = { raw: ranges.reduce((n, [s, e]) => n + e - s, 0), alone: cut(ranges) };
  for (const [l, v] of Object.entries(byLabel)) result.labels[l] = { raw: v.raw, alone: cut(v.ranges) };
  const allRemovable = Object.values(byModule).flatMap((m) => m.removable);
  result.removable = { raw: allRemovable.reduce((n, [s, e]) => n + e - s, 0), alone: cut(allRemovable) };
  result.dead = { raw: Object.values(byModule).reduce((n, m) => n + m.dead, 0), alone: cut(Object.values(byModule).flatMap((m) => m.deadRanges)) };
  result.shipped = { raw: Object.values(byModule).reduce((n, m) => n + m.raw, 0), alone: total - br(apply(src, plat.map((r) => stubs[r.js]))) };
  for (const [mod, m] of Object.entries(byModule))
    result.modules[mod] = { raw: m.raw, deadRaw: m.dead, removableRaw: m.removableRaw, shipped: total - br(apply(src, m.units.map((r) => stubs[r.js]))), dead: cut(m.deadRanges), removable: cut(m.removable) };
  out[key] = result;
  console.log(`\n== ${key}: ${total} B; platform runtime ${result.shipped.alone} alone, never ran ${result.dead.alone}, removable ${result.removable.alone}`);
  for (const [c, v] of Object.entries(result.categories).sort()) console.log(`  ${c}: raw ${v.raw}, alone ${v.alone}`);
  for (const [l, v] of Object.entries(result.labels).sort()) console.log(`    ${l}: raw ${v.raw}, alone ${v.alone}`);
  for (const [mod, v] of Object.entries(result.modules).sort((x, y) => y[1].shipped - x[1].shipped)) console.log(`  ${mod.padEnd(28)} shipped ${String(v.shipped).padStart(5)}  never-ran ${String(v.dead).padStart(5)}  removable ${String(v.removable).padStart(5)}`);
}
writeFileSync(join(import.meta.dirname, "results/classified.json"), JSON.stringify(out, null, 1) + "\n");
