import validate from "../generated/ajv-standalone/flat-encode.mjs";
import { FLAT_PROGRAM, flatToWire } from "../spec.mjs";
import { ajvIssues } from "../adapters/_issues.mjs";

export const meta = { id: "ajv-standalone", version: "8.20.0", kind: "generated-validator", codegen: "build-time", cspExpected: true, nativeMismatches: ["encode accepts present optional undefined"] };
export function run(value) {
  return validate(value)
    ? { ok: true, value: JSON.stringify(flatToWire(value)) }
    : { ok: false, issues: ajvIssues(validate.errors) };
}
