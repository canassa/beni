import { programParser } from "./_effect-flat.mjs";
import { flatCodec } from "../flat-codec.mjs";
export const run = flatCodec(programParser(), "encode");
