import { parser } from "../builders/valibot.mjs";
import { schemaFor } from "../spec.mjs";
import { makeParsedCodec } from "../common.mjs";
export const meta = { id: "valibot", version: "1.5.0", codegen: false, cspExpected: true, kind: "interpreted", config: "strictObject; exactOptional; safeParse abortEarly and abortPipeEarly; integer+min/max; finite numbers" };
export const create = (workload, direction) => makeParsedCodec(workload, direction, parser(schemaFor(workload, direction)));
