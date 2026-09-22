import { validateWire } from "../typia/generated/flat.js";
import { flatToProgram } from "../spec.mjs";
import { typiaIssues } from "../adapters/_issues.mjs";

export const meta = { id: "typia", version: "15.0.0", kind: "transformed-validator+serializer", codegen: "build-time", cspExpected: true };
export function run(text) {
  let value;
  try { value = JSON.parse(text); }
  catch { return { ok: false, issues: [{ path: [], code: "invalid_json" }] }; }
  const result = validateWire(value);
  return result.success
    ? { ok: true, value: flatToProgram(value) }
    : { ok: false, issues: typiaIssues(result.errors) };
}
