import { programParser } from "./_valibot-flat.mjs";
import { flatCodec } from "../flat-codec.mjs";
export const run = flatCodec(programParser(), "encode");
