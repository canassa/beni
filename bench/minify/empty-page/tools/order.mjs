// A hill-climb over the order of the runtime's top-level statements in the
// shipped file (skill §3 item 5; research 40 §4.3's method). Legal because
// every runtime statement's initialiser is inert (an arrow, a literal): none
// reads another binding at load, so any order evaluates the same. The emitted
// half — which calls `l(...)` and `b(...)` at load — stays where it is, after.
//   node tools/order.mjs FILE [ITERATIONS] [SEED]
// Prints the best brotli size found and the order, as unit indices.
import fs from "node:fs";
import { sizes, units } from "../measure.mjs";

const file = process.argv[2];
const iterations = Number(process.argv[3] ?? 3000);
let seed = Number(process.argv[4] ?? 1);
const rand = () => ((seed = (seed * 1103515245 + 12345) >>> 0) / 2 ** 32);

const text = fs.readFileSync(file, "utf8");
const us = units(text);
// The runtime half ends where the emitted half begins: the Browser sibling's
// `let b=` or the first statement that calls at load. Found by the marker the
// caller passes in, default the first unit that starts with `let b=c=>[`.
const marker = process.env.ORDER_SPLIT ?? "let b=c=>[";
const split = us.findIndex((u) => u.startsWith(marker));
if (split < 0) throw new Error(`no unit starts with ${marker}`);
const head = us.slice(0, split);
const tail = us.slice(split).join("");
const price = (order) => sizes(Buffer.from(order.map((k) => head[k]).join("") + tail)).br;

let best = head.map((_, k) => k);
let bestBr = price(best);
const start = bestBr;
for (let it = 0; it < iterations; it++) {
  const cand = [...best];
  const a = Math.floor(rand() * cand.length);
  const b = Math.floor(rand() * cand.length);
  if (rand() < 0.5) [cand[a], cand[b]] = [cand[b], cand[a]];
  else cand.splice(b, 0, ...cand.splice(a, 1));
  const br = price(cand);
  if (br <= bestBr) { best = cand; bestBr = br; }
}
console.log(`units ${head.length}; brotli ${start} -> ${bestBr} (${bestBr - start}) after ${iterations} iterations, seed ${process.argv[4] ?? 1}`);
console.log(JSON.stringify(best));
if (process.env.ORDER_OUT) fs.writeFileSync(process.env.ORDER_OUT, best.map((k) => head[k]).join("") + tail);
