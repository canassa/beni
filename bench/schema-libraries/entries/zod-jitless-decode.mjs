import { wireParser } from "./_zod-flat.mjs";
import { flatCodec } from "../flat-codec.mjs";
export const run = flatCodec(wireParser(true), "decode");
