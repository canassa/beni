// The fiber runtime benchmark under Node: `node node.mjs <beni build dir>
// [<budget>=<beni build dir> …]`, where each build is `beni build --library
// --platform=node` of Bench.beni and the extra ones have their runtime's
// budget patched (budgets.mjs). Prints the tables as JSON.

import { pathToFileURL } from "node:url";
import { resolve } from "node:path";
import * as effect from "./effect.mjs";
import { all, sweep } from "./workloads.mjs";

const load = (dir) => import(pathToFileURL(`${resolve(dir)}/Bench.mjs`).href);
const [main, ...rest] = process.argv.slice(2);
const beni = await load(main ?? "out");
const result = await all(beni, effect);
const budgets = [];
for (const arg of rest) {
  const [label, dir] = arg.split("=");
  budgets.push([label, await load(dir)]);
}
const latency = budgets.length === 0 ? [] : await sweep(budgets, effect);
console.log(JSON.stringify({ host: `node ${process.version}`, result, latency }, null, 1));
