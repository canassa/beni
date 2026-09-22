import { Value } from "typebox/value";
import { FLAT_WIRE, flatToProgram } from "../spec.mjs";
import { typeboxIssues } from "../adapters/_issues.mjs";

export const meta = { id: "typebox-value", version: "1.3.34", kind: "interpreted-validator", codegen: false, cspExpected: true, nativeMismatches: ["encode accepts present optional undefined"] };
export function run(text) {
  let value;
  try { value = JSON.parse(text); }
  catch { return { ok: false, issues: [{ path: [], code: "invalid_json" }] }; }
  return Value.Check(FLAT_WIRE, value)
    ? { ok: true, value: flatToProgram(value) }
    : { ok: false, issues: typeboxIssues(Value.Errors(FLAT_WIRE, value)) };
}
