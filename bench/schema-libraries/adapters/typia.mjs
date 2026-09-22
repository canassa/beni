import { makeCodec } from "../common.mjs";
import * as generated from "../typia/generated/input.js";
import { typiaIssues } from "./_issues.mjs";

export const meta = {
  id: "typia",
  version: "15.0.0",
  kind: "transformed-validator+serializer",
  codegen: "build-time",
  cspExpected: true,
  transformer: "ttsc 0.28.1 (Typia 15's supported native transformer)",
  config: "validateEquals; finite:true; undefined:false; exactOptionalPropertyTypes:true; never template index preserves exact surplus-key paths",
};

const validators = {
  flat: [generated.validateFlatWire, generated.validateFlatProgram],
  list: [generated.validateListWire, generated.validateListProgram],
  union: [generated.validateUnionWire, generated.validateUnionProgram],
  tree: [generated.validateTreeWire, generated.validateTreeProgram],
  typeahead: [generated.validateTypeaheadWire, generated.validateTypeaheadProgram],
};
const serializers = {
  flat: generated.stringifyFlatWire,
  list: generated.stringifyListWire,
  union: generated.stringifyUnionWire,
  tree: generated.stringifyTreeWire,
  typeahead: generated.stringifyTypeaheadWire,
};

export function create(workload, direction) {
  const nativeValidate = validators[workload]?.[direction === "decode" ? 0 : 1];
  if (!nativeValidate) throw new Error(`unsupported typia workload: ${workload}`);
  const validate = (value) => {
    const result = nativeValidate(value);
    return result.success ? null : typiaIssues(result.errors);
  };
  return makeCodec(
    workload,
    direction,
    validate,
    direction === "encode" ? serializers[workload] : JSON.stringify,
  );
}
