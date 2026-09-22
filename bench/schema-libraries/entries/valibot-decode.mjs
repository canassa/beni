import { wireParser } from "./_valibot-flat.mjs";
import { flatCodec } from "../flat-codec.mjs";
export const run = flatCodec(wireParser(), "decode");
