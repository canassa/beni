import { pathToFileURL } from "node:url";
import { adapterPath, serializeError, supported } from "./measure-common.mjs";

const config = JSON.parse(process.argv[2]);
const root = pathToFileURL(`${config.root}/`);
try {
  const [{ measurementCases, adversarialCases }, adapter] = await Promise.all([
    import(new URL("./fixtures.mjs", root)),
    import(adapterPath(root, config.row)),
  ]);
  let calls = 0;
  for (const testCase of [...await measurementCases(), ...await adversarialCases()]) {
    if (!supported(adapter.meta, testCase.direction)) continue;
    const run = adapter.create(testCase.workload, testCase.direction);
    if (typeof run !== "function") throw new Error("create did not return a run function");
    run(testCase.input);
    calls++;
  }
  process.stdout.write(JSON.stringify({ row: config.row, feasible: true, calls }));
} catch (error) {
  process.stdout.write(JSON.stringify({ row: config.row, feasible: false, error: serializeError(error) }));
}
