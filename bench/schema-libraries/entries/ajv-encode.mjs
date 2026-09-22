import Ajv from "ajv";
import { FLAT_PROGRAM, flatToWire } from "../spec.mjs";
import { ajvIssues } from "../adapters/_issues.mjs";

export const meta = { id: "ajv", version: "8.20.0", kind: "compiled-validator", codegen: true, cspExpected: false, nativeMismatches: ["encode accepts present optional undefined"] };
const validate = new Ajv({ allErrors: false, coerceTypes: false, strict: true, useDefaults: false }).compile(FLAT_PROGRAM);
export function run(value) {
  return validate(value)
    ? { ok: true, value: JSON.stringify(flatToWire(value)) }
    : { ok: false, issues: ajvIssues(validate.errors) };
}
