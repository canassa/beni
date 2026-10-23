#!/usr/bin/env node
// The mutation controls of the record demand (`docs/design/ownership-checker.md`
// §31.12): each mutation breaks the checker one way, and the record fixtures of
// `tests/corpus/ownership/` must catch it — at least one golden must fail.
//
//     zig build test-record-mutations
//
// Each mutation builds the compiler again (`-Downership-record-mutation=…`)
// and runs the `ownership/Record` fixtures. A mutation the fixtures do not
// catch fails the step. The fifth, a hoist published with the wrong placement,
// is pinned by the published table, and the sanitiser traps the program it
// lowers (`run/RecordHoistValues`, built in place).

import { spawnSync } from "node:child_process";

const zig = process.argv[2] ?? "zig";
const mutations = ["hoist-whole", "no-held-operand", "no-disjoint", "call-as-hoist", "wrong-placement"];
let missed = 0;
for (const m of mutations) {
  const r = spawnSync(zig, ["build", "test-blackbox", "-Dcorpus=ownership/Record", `-Downership-record-mutation=${m}`], {
    encoding: "utf8",
    maxBuffer: 1 << 28,
  });
  const out = `${r.stdout}${r.stderr}`;
  const caught = r.status !== 0 && /GoldenMismatch/.test(out);
  const failed = [...new Set(out.match(/FAIL tests\/corpus\/ownership\/[^:\s]+/g) ?? [])];
  console.log(`${m}: ${caught ? "caught by " + failed.join(", ") : "NOT CAUGHT"}`);
  if (!caught) missed++;
  // A hoist published at the wrong place is a lowering that reads a written
  // field after the store: the records' differential corpus, run in place
  // under the stale-read sanitiser (§31.12 slice 3), must trap on it too.
  if (m === "wrong-placement") {
    const d = spawnSync(zig, ["build", "test-blackbox", "-Dcorpus=run/RecordHoistValues", `-Downership-record-mutation=${m}`], { encoding: "utf8", maxBuffer: 1 << 28 });
    const trapped = d.status !== 0 && /a stale read of the record field/.test(`${d.stdout}${d.stderr}`);
    console.log(`${m} in place: ${trapped ? "trapped by the sanitiser in run/RecordHoistValues" : "NOT TRAPPED"}`);
    if (!trapped) missed++;
  }
}
if (missed) {
  console.error(`${missed} of ${mutations.length} record mutations went uncaught`);
  process.exit(1);
}
