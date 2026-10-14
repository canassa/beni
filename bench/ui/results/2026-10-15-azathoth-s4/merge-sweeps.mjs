// Preserve the completed prefix and the availability-fix continuation.
import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
const dir = fileURLToPath(new URL("./", import.meta.url));
const prefix = JSON.parse(readFileSync(dir + "sweeps-prefix.json"));
const rest = JSON.parse(readFileSync(dir + "sweeps-rest.json"));
for (const key of ["chrome", "node", "beni", "commit", "cpu", "taskset", "throttle", "settings", "untraced"]) assert.deepEqual(prefix[key], rest[key], key);
assert.ok(rest.finished, "continuation must complete");
const kept = new Set(["holes", "rows"]);
const result = {
  ...prefix,
  sweeps: [...prefix.sweeps.filter((s) => kept.has(s.id)), ...rest.sweeps],
  samples: [...prefix.samples.filter((s) => kept.has(s.sweep)), ...rest.samples],
  batches: [...prefix.batches.filter((s) => kept.has(s.sweep)), ...rest.batches],
  failures: [...prefix.failures, ...rest.failures],
  skipped: [...prefix.skipped.filter((s) => kept.has(s.sweep)), ...rest.skipped],
  finished: rest.finished,
  seconds: (Date.parse(rest.finished) - Date.parse(prefix.started)) / 1000,
  epochs: [
    { file: "sweeps-prefix.json", started: prefix.started, finished: prefix.finished ?? null, kept: [...kept] },
    { file: "sweeps-rest.json", started: rest.started, finished: rest.finished },
  ],
  interruption: {
    condition: "filtered/toggle/100",
    reason: "The original harness attempted a P3 subject without a generator, then timed out. The incomplete point was stopped; static availability was fixed and all remaining conditions resumed jointly.",
    log: "sweeps-prefix.log",
  },
};
const cells = new Map();
for (const s of result.samples) {
  const key = [s.sweep, s.op, s.param, s.subject].join("/");
  cells.set(key, (cells.get(key) ?? 0) + 1);
}
for (const [key, count] of cells) assert.equal(count, key.startsWith("stream/") ? 2 : 24, key);
for (const sweep of result.sweeps) for (const op of sweep.ops) for (const p of sweep.params) {
  for (const subject of ["vanillajs", "solid1", "solid2", "beni-release", "beni-direct-release"]) assert.ok(cells.has([sweep.id, op, p, subject].join("/")), `missing ${sweep.id}/${op}/${p}/${subject}`);
}
writeFileSync(dir + "sweeps.json", JSON.stringify(result, null, 1) + "\n");
console.log(`${result.samples.length} observations, ${cells.size} complete cells`);
