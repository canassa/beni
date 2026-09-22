import fastJson from "fast-json-stringify";
import { validateFlat } from "../handwritten.mjs";
import { FLAT_WIRE, flatToWire } from "../spec.mjs";

export const meta = {
  id: "fast-json-stringify+handwritten-guard",
  version: "7.0.1",
  kind: "serializer+handwritten-validator",
  codegen: true,
  cspExpected: false,
  supportedDirections: ["encode"],
  deviation: "fast-json-stringify does not provide strict validation or structured issues",
};
const serialize = fastJson(FLAT_WIRE);
export function run(value) {
  const issues = validateFlat(value, "encode");
  return issues === null
    ? { ok: true, value: serialize(flatToWire(value)) }
    : { ok: false, issues };
}
