import Ajv from "ajv";
import { makeCodec } from "../common.mjs";
import { schemaFor } from "../spec.mjs";
import { ajvIssues, selectedUnionErrors } from "./_issues.mjs";

export const meta = {
  id: "ajv",
  version: "8.20.0",
  kind: "compiled-validator",
  codegen: true,
  cspExpected: false,
  nativeMismatches: ["encode accepts a present optional nickname whose value is undefined"],
};

const ajv = new Ajv({
  allErrors: false,
  coerceTypes: false,
  strict: true,
  useDefaults: false,
});

export function create(workload, direction) {
  const compiled = ajv.compile(schemaFor(workload, direction));
  const validate = (value) => compiled(value)
    ? null
    : ajvIssues(workload === "union" ? selectedUnionErrors(compiled.errors, value) : compiled.errors);
  return makeCodec(workload, direction, validate);
}
