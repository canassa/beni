import { Compile } from "typebox/compile";
import { FLAT_PROGRAM, flatToWire } from "../spec.mjs";
import { typeboxIssues } from "../adapters/_issues.mjs";

export const meta = { id: "typebox-compiled", version: "1.3.34", kind: "compiled-validator-with-interpreter-fallback", codegen: true, cspExpected: true, nativeMismatches: ["encode accepts present optional undefined"] };
const validate = Compile(FLAT_PROGRAM);
export function run(value) {
  return validate.Check(value)
    ? { ok: true, value: JSON.stringify(flatToWire(value)) }
    : { ok: false, issues: typeboxIssues(validate.Errors(value)) };
}
