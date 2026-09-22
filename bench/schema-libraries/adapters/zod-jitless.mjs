import { parser } from "../builders/zod.mjs";
import { schemaFor } from "../spec.mjs";
import { makeParsedCodec } from "../common.mjs";
export const meta = { id: "zod-jitless", version: "4.6.5", codegen: false, cspExpected: true, kind: "interpreted control", config: "strictObject; exactOptional; safeParse(...,{jitless:true}); native issue paths; safe integers", caveat: "Per-parse jitless disables generated parser use, not the schema-construction eval capability probe" };
export const create = (workload, direction) => makeParsedCodec(workload, direction, parser(schemaFor(workload, direction), true));
