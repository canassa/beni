import { measurementCases } from "../fixtures.mjs";
import { ROWS, adapterPath } from "../measure-common.mjs";
import { verifySources } from "../verify-sources.mjs";

const sourceVerification = await verifySources();
const input = (await measurementCases()).find((item) => item.workload === "flat" && item.direction === "encode" && item.path === "valid").input;
const observations = [];
for (const row of ROWS.filter((item) => item !== "json-floor")) {
  const adapter = await import(adapterPath(new URL("../", import.meta.url), row));
  const run = adapter.create("flat", "encode");
  for (const key of ["nickname", "unexpected", "__beni_schema_never__probe"]) {
    const actual = run({ ...input, [key]: undefined });
    observations.push({ row, key, value: "JavaScript undefined (not a JSON value)", expected: { ok: false, path: [key] }, actual });
  }
}
process.stdout.write(`${JSON.stringify({ node: process.version, source_verification: sourceVerification, observations }, null, 2)}\n`);
