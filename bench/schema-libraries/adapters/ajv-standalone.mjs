import { makeCodec } from "../common.mjs";
import * as generated from "../generated/ajv-standalone.mjs";
import { ajvIssues, selectedUnionErrors } from "./_issues.mjs";

export const meta = {
  id: "ajv-standalone",
  version: "8.20.0",
  kind: "generated-validator",
  codegen: "build-time",
  cspExpected: true,
  nativeMismatches: ["encode accepts a present optional nickname whose value is undefined"],
};

export function create(workload, direction) {
  const compiled = generated[`${workload}_${direction}`];
  if (!compiled) throw new Error(`unsupported Ajv standalone workload: ${workload}`);
  const validate = (value) => compiled(value)
    ? null
    : ajvIssues(workload === "union" ? selectedUnionErrors(compiled.errors, value) : compiled.errors);
  return makeCodec(workload, direction, validate);
}
