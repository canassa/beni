import { wireParser } from "./_effect-flat.mjs";
import { flatCodec } from "../flat-codec.mjs";
export const run = flatCodec(wireParser(), "decode");
