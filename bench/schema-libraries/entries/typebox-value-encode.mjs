import { Value } from "typebox/value";
import { FLAT_PROGRAM, flatToWire } from "../spec.mjs";
import { typeboxIssues } from "../adapters/_issues.mjs";

export const meta = { id: "typebox-value", version: "1.3.34", kind: "interpreted-validator", codegen: false, cspExpected: true, nativeMismatches: ["encode accepts present optional undefined"] };
export function run(value) {
  return Value.Check(FLAT_PROGRAM, value)
    ? { ok: true, value: JSON.stringify(flatToWire(value)) }
    : { ok: false, issues: typeboxIssues(Value.Errors(FLAT_PROGRAM, value)) };
}
