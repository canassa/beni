#!/usr/bin/env node
// The mutation controls of the record demand (`docs/design/ownership-checker.md`
// §31.12): each mutation breaks the checker one way, and the record fixtures of
// `tests/corpus/ownership/` must catch it — at least one golden must fail.
//
//     zig build test-record-mutations
//
// Each mutation builds the compiler again (`-Downership-record-mutation=…`)
// and runs the `ownership/Record` fixtures. A mutation the fixtures do not
// catch fails the step. The fourth control of §31.12, a hoist published with
// the wrong placement is pinned by the published table.

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
}
if (missed) {
  console.error(`${missed} of ${mutations.length} record mutations went uncaught`);
  process.exit(1);
}
