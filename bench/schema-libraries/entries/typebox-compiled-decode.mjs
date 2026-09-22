import { Compile } from "typebox/compile";
import { FLAT_WIRE, flatToProgram } from "../spec.mjs";
import { typeboxIssues } from "../adapters/_issues.mjs";

export const meta = { id: "typebox-compiled", version: "1.3.34", kind: "compiled-validator-with-interpreter-fallback", codegen: true, cspExpected: true, nativeMismatches: ["encode accepts present optional undefined"] };
const validate = Compile(FLAT_WIRE);
export function run(text) {
  let value;
  try { value = JSON.parse(text); }
  catch { return { ok: false, issues: [{ path: [], code: "invalid_json" }] }; }
  return validate.Check(value)
    ? { ok: true, value: flatToProgram(value) }
    : { ok: false, issues: typeboxIssues(validate.Errors(value)) };
}
