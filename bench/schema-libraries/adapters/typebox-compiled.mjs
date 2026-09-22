import { Compile } from "typebox/compile";
import { Settings } from "typebox/system";
import { makeCodec } from "../common.mjs";
import { schemaFor } from "../spec.mjs";
import { selectedUnionErrors, typeboxIssues } from "./_issues.mjs";

export const meta = {
  id: "typebox-compiled",
  version: "1.3.34",
  kind: "compiled-validator-with-interpreter-fallback",
  codegen: true,
  cspExpected: true,
  cspBehavior: "uses TypeBox's interpreted fallback when dynamic evaluation is unavailable",
  nativeMismatches: ["encode accepts a present optional nickname whose value is undefined"],
};

Settings.Set({ maxErrors: 64 });

export function create(workload, direction) {
  const compiled = Compile(schemaFor(workload, direction));
  const validate = (value) => {
    if (compiled.Check(value)) return null;
    const errors = compiled.Errors(value);
    return typeboxIssues(workload === "union" ? selectedUnionErrors(errors, value) : errors);
  };
  return makeCodec(workload, direction, validate);
}
