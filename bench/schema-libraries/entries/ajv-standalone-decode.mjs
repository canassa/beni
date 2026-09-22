import validate from "../generated/ajv-standalone/flat-decode.mjs";
import { FLAT_WIRE, flatToProgram } from "../spec.mjs";
import { ajvIssues } from "../adapters/_issues.mjs";

export const meta = { id: "ajv-standalone", version: "8.20.0", kind: "generated-validator", codegen: "build-time", cspExpected: true, nativeMismatches: ["encode accepts present optional undefined"] };
export function run(text) {
  let value;
  try { value = JSON.parse(text); }
  catch { return { ok: false, issues: [{ path: [], code: "invalid_json" }] }; }
  return validate(value)
    ? { ok: true, value: flatToProgram(value) }
    : { ok: false, issues: ajvIssues(validate.errors) };
}
