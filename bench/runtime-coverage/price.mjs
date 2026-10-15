// Price a set of never-executed code: delete the never-executed bytes of
// the named units (owner module + beni name; `*` for every unit of the
// owner) from a bundle and recompress. Not a program; a price (research
// 102 §1's *alone*, on dead bytes only).
//
//   node bench/runtime-coverage/price.mjs <app-platform> <owner>:<name>[,<name>…] …
//
// e.g. `price.mjs Conduit-tea browser-tea/Tea:perform,starter browser/Cmd:map`

import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { br, apply } from "../output-size/lib.mjs";

const repo = resolve(import.meta.dirname, "../..");
const analysis = JSON.parse(readFileSync(join(repo, "zig-out/runtime-coverage/analysis.json"), "utf8"));

export function price(key, picks) {
  const a = analysis[key];
  const src = readFileSync(a.bundle, "utf8").replace(/\/\/# sourceMappingURL=.*\n?$/, "");
  const edits = [];
  const hit = [];
  for (const r of a.rows) {
    for (const [owner, names] of picks) {
      if (r.owner !== `platforms/${owner}` && r.owner !== owner) continue;
      if (!names.includes("*") && !names.includes(r.orig)) continue;
      for (const [s, e] of r.ranges) edits.push({ start: s, end: e, text: "" });
      hit.push(`${r.orig}:${r.dead}`);
    }
  }
  const total = br(src);
  return { total, saved: edits.length ? total - br(apply(src, edits)) : 0, raw: edits.reduce((n, e) => n + e.end - e.start, 0), hit };
}

if (import.meta.main) {
  const [key, ...specs] = process.argv.slice(2);
  const picks = specs.map((s) => {
    const [owner, names] = s.split(":");
    return [owner, names.split(",")];
  });
  console.log(price(key, picks));
}
