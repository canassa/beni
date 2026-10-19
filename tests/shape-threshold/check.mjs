// `zig build test-shape-threshold` (`schema.md` §6, *How a program chooses between shapes and
// workers*): builds the dashboard-shaped programs of `gen.mjs` both ways, each seed, and fails
// when T = `SchemaValid.shape_threshold` has stopped being their crossover: workers must be
// smaller at T − 4 runs and shapes at T runs, for every seed. It prints every measurement, so
// a failure says how far the crossover moved. Not a gate: about 12 builds of up to 25 modules.
// node check.mjs <beni> <scratch>
import fs from "node:fs"; import path from "node:path"; import zlib from "node:zlib"; import { execFileSync } from "node:child_process"; import { project } from "./gen.mjs";
const [beni, scratch] = process.argv.slice(2).map((p) => path.resolve(p));
const src = fs.readFileSync(new URL("../../src/js/SchemaValid.zig", import.meta.url), "utf8");
const T = Number(/pub const shape_threshold = (\d+);/.exec(src)[1]);
const br = (b) => zlib.brotliCompressSync(b, { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11 } }).length;
function measure(n, seed) {
  const d = path.join(scratch, `n${n}s${seed}`); fs.rmSync(d, { recursive: true, force: true }); fs.mkdirSync(d, { recursive: true });
  const files = project(n, seed); for (const [f, t] of Object.entries(files)) fs.writeFileSync(path.join(d, f), t);
  const out = {};
  for (const mode of ["never", "always"]) {
    execFileSync(beni, ["build", "--platform=node", "--release", "--no-cache", "--jobs=1", `--schema-shapes=${mode}`, `--out=${mode}`, ...Object.keys(files)], { cwd: d, stdio: "pipe" });
    out[mode] = br(fs.readFileSync(path.join(d, mode, "_main.mjs")));
  }
  return { W: out.never, S: out.always };
}
let failed = false;
for (const [runs, want] of [[T - 4, "workers"], [T, "shapes"]]) for (const seed of [1, 2, 3]) {
  const { W, S } = measure(runs - 1, seed);
  const ok = want === "workers" ? W < S : S < W;
  failed ||= !ok;
  console.log(`${ok ? "ok  " : "FAIL"} ${runs} runs, seed ${seed}: workers ${W} B, shapes ${S} B, shapes − workers ${S - W} B; ${want} should be smaller`);
}
if (failed) { console.log(`T = ${T} is no longer the crossover of these programs: re-measure it (schema.md §6, *T is 25*).`); process.exit(1); }
