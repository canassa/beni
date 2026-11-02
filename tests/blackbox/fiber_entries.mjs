import assert from "node:assert/strict";
import * as beni from "./Bench.mjs";
import { all } from "./workloads.mjs";

// The shared workload runner must forward parked results, too. Comparison
// functions only supply expected answers; npm dependencies are not in gates.
const comparison = { loopFlatMap: n => n, loopGen: n => n, loopYielding: async n => n, fanOut: async n => n * (n + 1) / 2 };
await all(beni, comparison, { calls: 8, sequenced: 2, yields: 3, fibers: 3, effectCalls: 1, effectYields: 1 });

const entries = [
  ["runLoopYielding", [3, 7], 10],
  ["runFanOut", [3], 6],
  ["runSleepZero", [2, 5], 7],
  ["runTenHours", [], 4],
  ["runForEachSixteen", [3], 6],
  ["runParFast", [2, 3], 5],
  ["runRaceParked", [2, 4], 6],
  ["runTimeoutFast", [2, 5], 7],
  ["runDeferredHandoff", [2, 4], 6],
  ["runDeferredReady", [2, 6], 8],
  ["runRefUpdates", [3], 3],
  ["runDetachJoin", [2, 9], 11],
  ["runLogBelow", [2, 6], 8],
  ["runLogWritten", [3], 3],
  ["runLogInContext", [3], 3],
  ["runPermitUncontended", [3], 3],
  ["runPermitContended", [3, 2], 6],
  ["runCancelledWaits", [3], null],
];
const exported = Object.keys(beni).filter(name => name.startsWith("Bench$run") && !name.endsWith("$s")).sort();
assert.deepEqual(exported, entries.map(([name]) => "Bench$" + name).sort());
for (const [name, args, expected] of entries) {
  const exit = await new Promise(resolve => beni["Bench$" + name](...args, resolve));
  if (name === "runCancelledWaits") {
    assert.deepEqual(exit, { $: "Done", a: exit.a });
    assert.equal(beni.Bench$availablePermits(exit.a), 0, name);
  } else {
    assert.deepEqual(exit, { $: "Done", a: expected }, name);
  }
}
console.log("all 18 benchmark entries checked");
