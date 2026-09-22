import { performance } from "node:perf_hooks";
import { readFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";
import { adapterPath, consume, entryPath, serializeError } from "./measure-common.mjs";

const config = JSON.parse(process.argv[2]);
const root = pathToFileURL(`${config.root}/`);
// Load the input without fixtures.mjs: fixtures imports spec.mjs, which is a
// dependency of some subjects and would otherwise be warm in the module cache
// before the import clock starts.
const payload = JSON.parse(await readFile(new URL(`./payloads/${config.workload}.json`, root), "utf8"));
const valid = payload.find((item) => item.path === "valid");
if (!valid) throw new Error(`no valid startup payload for ${config.workload}`);
const input = config.direction === "decode" ? JSON.stringify(valid.wire) : config.row === "json-floor" ? valid.wire : valid.program;
const importStart = performance.now();
try {
  const adapter = await import(config.entry ? entryPath(root, config.row, config.direction) : adapterPath(root, config.row));
  const imported = performance.now();
  const run = config.entry ? (adapter.run ?? adapter.default) : adapter.create(config.workload, config.direction);
  if (typeof run !== "function") throw new Error("subject did not provide a run function");
  const constructed = performance.now();
  const result = run(input);
  const called = performance.now();
  process.stdout.write(JSON.stringify({
    row: config.row,
    workload: config.workload,
    direction: config.direction,
    repetition: config.repetition,
    surface: config.entry ? "flat-only-entry" : "all-workload-adapter",
    import_ns: (imported - importStart) * 1e6,
    construct_ns: config.entry ? null : (constructed - imported) * 1e6,
    first_call_ns: (called - constructed) * 1e6,
    consumed: consume(result),
  }));
} catch (error) {
  process.stdout.write(JSON.stringify({ row: config.row, workload: config.workload, direction: config.direction, repetition: config.repetition, surface: config.entry ? "flat-only-entry" : "all-workload-adapter", error: serializeError(error) }));
}
