import { validateFlat, serializeFlat } from "../handwritten.mjs";
import { flatToProgram, flatToWire } from "../spec.mjs";
export const run = (text) => {
  let value;
  try { value = JSON.parse(text); } catch { return {ok:false,issues:[{path:[],code:"invalid_json"}]}; }
  const issues = validateFlat(value, "decode");
  return issues ? {ok:false,issues} : {ok:true,value:flatToProgram(value)};
};
