import Ajv from "ajv";
import { FLAT_WIRE, flatToProgram } from "../spec.mjs";
import { ajvIssues } from "../adapters/_issues.mjs";

export const meta = { id: "ajv", version: "8.20.0", kind: "compiled-validator", codegen: true, cspExpected: false, nativeMismatches: ["encode accepts present optional undefined"] };
const validate = new Ajv({ allErrors: false, coerceTypes: false, strict: true, useDefaults: false }).compile(FLAT_WIRE);
export function run(text) {
  let value;
  try { value = JSON.parse(text); }
  catch { return { ok: false, issues: [{ path: [], code: "invalid_json" }] }; }
  return validate(value)
    ? { ok: true, value: flatToProgram(value) }
    : { ok: false, issues: ajvIssues(validate.errors) };
}
