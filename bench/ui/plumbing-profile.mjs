// A plumbing.mjs profile, grouped (research 59): self time per message,
// summed over every function whose name and file match a group's pattern,
// so that 128 per-level functions (`Main$p…`, `Main$view…`) count as one row.
// `(program)` (the browser's own work, idle between clicks included) and the
// harness's two bracket listeners are listed apart.
//
//   node plumbing-profile.mjs results/<file>.json

import { readFileSync } from "node:fs";

const r = JSON.parse(readFileSync(process.argv[2], "utf8"));
const groups = [
  ["(program)", /^\(program\)/],
  ["(garbage collector)", /^\(garbage collector\)/],
  ["harness bracket listeners", /^\(anonymous\) :[45]$|^now :0$/],
  ["beni: per-level patch functions", /^Main\$p\d+ /],
  ["beni: per-level view helpers (`{t, v:[n]}`)", /^Main\$view\d* /],
  ["beni: per-level update helpers", /^Main\$(bump\d+|update) /],
  ["beni: kinds' mount", /^m /],
  ["Rt: patch, childHtml, held, restate", /^Rt\$(patch|childHtml|held|restate|unit) /],
  ["Rt: delegation (delegated, its closure, bubble, fire, mountAbove, through)", /^Rt\$(delegated|bubble|fire|mountAbove|through) |^\(anonymous\) .*Rt\.mjs:3[4-6]\d$/],
  ["Rt: $$root, turn, flush, render", /^(Rt\$mount\.root\$2\.\$\$root|Rt\$turn|Rt\$flush|render\$6|Rt\$microtask) /],
];
for (const [subject, p] of Object.entries(r.profiles)) {
  const rows = new Map(groups.map(([g]) => [g, 0]));
  let other = 0;
  const others = [];
  for (const [key, e] of Object.entries(p.fns)) {
    const g = groups.find(([, re]) => re.test(key));
    if (g) rows.set(g[0], rows.get(g[0]) + e.self);
    else {
      other += e.self;
      others.push([key, e.self]);
    }
  }
  const per = (us) => ((us * 1000) / p.messages / 1000).toFixed(2);
  console.log(`\n${subject}: ${p.messages} messages, µs of self time per message`);
  for (const [g, us] of rows) if (us > 0) console.log(`  ${per(us).padStart(8)}  ${g}`);
  console.log(`  ${per(other).padStart(8)}  everything else, of which:`);
  for (const [k, us] of others.sort((a, b) => b[1] - a[1]).slice(0, 12)) console.log(`  ${per(us).padStart(12)}  ${k}`);
}
