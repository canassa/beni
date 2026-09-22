import { Value } from "typebox/value";
import { Settings } from "typebox/system";
import { makeCodec } from "../common.mjs";
import { schemaFor } from "../spec.mjs";
import { selectedUnionErrors, typeboxIssues } from "./_issues.mjs";

export const meta = {
  id: "typebox-value",
  version: "1.3.34",
  kind: "interpreted-validator",
  codegen: false,
  cspExpected: true,
  nativeMismatches: ["encode accepts a present optional nickname whose value is undefined"],
};

// A four-way `oneOf` can exceed TypeBox's default diagnostic cap of eight
// before reaching the discriminant-selected branch. Preserve native details
// for path normalization by allowing every branch to report.
Settings.Set({ maxErrors: 64 });

export function create(workload, direction) {
  const schema = schemaFor(workload, direction);
  const validate = (value) => {
    if (Value.Check(schema, value)) return null;
    const errors = Value.Errors(schema, value);
    return typeboxIssues(workload === "union" ? selectedUnionErrors(errors, value) : errors);
  };
  return makeCodec(workload, direction, validate);
}
