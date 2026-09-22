import { parser } from "../builders/effect.mjs";
import { schemaFor } from "../spec.mjs";
import { makeParsedCodec } from "../common.mjs";
export const meta = { id: "effect", version: "4.0.0-rc.116", codegen: false, cspExpected: true, kind: "interpreted", config: "rc.116 SchemaParser.decodeUnknownResult; errors:first; onExcessProperty:error; optionalKey; isInt; isFinite; native SchemaIssue formatter path extraction", caveat: "Optional unstable SchemaCompiler adapters are not enabled or measured" };
export const create = (workload, direction) => makeParsedCodec(workload, direction, parser(schemaFor(workload, direction)));
