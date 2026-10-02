// The fiber runtime benchmark under Node: `node node.mjs <beni build dir>
// [<budget>=<beni build dir> …]`, where each build is `beni build --library
// --platform=node` of Bench.beni and the extra ones have their runtime's
// budget patched (budgets.mjs). Prints the tables as JSON.
// `node node.mjs --group=coordination <beni build dir>` runs only the
// coordination workloads (`Deferred`, `Ref`, detached fibers) instead, and
// `--group=time` the time workloads (`Task.sleep`, `Clock`, `retry`), and
// `--group=combinators` the structured combinators (`forEach`, `par`, …).

import { pathToFileURL } from "node:url";
import { resolve } from "node:path";
import * as effect from "./effect.mjs";
import { all, combinators, coordination, sweep, time } from "./workloads.mjs";

const load = (dir) => import(pathToFileURL(`${resolve(dir)}/Bench.mjs`).href);
const args = process.argv.slice(2);
const group = args.find((a) => a.startsWith("--group="))?.slice("--group=".length);
const [main, ...rest] = args.filter((a) => !a.startsWith("--group="));
const beni = await load(main ?? "out");
const groups = { combinators, coordination, time };
if (group in groups) {
  const run = groups[group];
  console.log(JSON.stringify({ host: `node ${process.version}`, result: await run(beni, effect) }, null, 1));
  process.exit(0);
}
const result = await all(beni, effect);
const budgets = [];
for (const arg of rest) {
  const [label, dir] = arg.split("=");
  budgets.push([label, await load(dir)]);
}
const latency = budgets.length === 0 ? [] : await sweep(budgets, effect);
console.log(JSON.stringify({ host: `node ${process.version}`, result, latency }, null, 1));
