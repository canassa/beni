import { parser } from "../builders/zod.mjs";
import { schemaFor } from "../spec.mjs";
import { makeParsedCodec } from "../common.mjs";
export const meta = { id: "zod", version: "4.6.5", codegen: true, cspExpected: true, kind: "default v4 object JIT", config: "strictObject; exactOptional; safeParse; native issue paths; safe integers; defaults/coercion absent", caveat: "Zod v4 default is not wholly interpreted; see zod-jitless control; CSP falls back" };
export const create = (workload, direction) => makeParsedCodec(workload, direction, parser(schemaFor(workload, direction)));
