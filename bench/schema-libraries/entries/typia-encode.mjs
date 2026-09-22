import { stringifyWire, validateProgram } from "../typia/generated/flat.js";
import { flatToWire } from "../spec.mjs";
import { typiaIssues } from "../adapters/_issues.mjs";

export const meta = { id: "typia", version: "15.0.0", kind: "transformed-validator+serializer", codegen: "build-time", cspExpected: true };
export function run(value) {
  const result = validateProgram(value);
  return result.success
    ? { ok: true, value: stringifyWire(flatToWire(value)) }
    : { ok: false, issues: typiaIssues(result.errors) };
}
