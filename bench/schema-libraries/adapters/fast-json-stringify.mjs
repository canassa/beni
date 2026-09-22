import fastJson from "fast-json-stringify";
import { makeCodec } from "../common.mjs";
import { validateHandwritten } from "../handwritten.mjs";
import { schemaFor } from "../spec.mjs";

export const meta = {
  id: "fast-json-stringify+handwritten-guard",
  version: "7.0.1",
  kind: "serializer+handwritten-validator",
  codegen: true,
  cspExpected: false,
  supportedDirections: ["encode"],
  deviation: "fast-json-stringify does not provide strict validation or structured issues",
};

export function create(workload, direction) {
  if (direction !== "encode") {
    throw new Error("fast-json-stringify is encode-only");
  }
  const serialize = fastJson(schemaFor(workload, "decode"));
  const validate = (value) => validateHandwritten(workload, direction, value);
  return makeCodec(workload, direction, validate, serialize);
}
