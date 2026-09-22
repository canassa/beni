import { validateFlat, serializeFlat } from "../handwritten.mjs";
import { flatToProgram, flatToWire } from "../spec.mjs";
export const run = (value) => {
  const issues = validateFlat(value, "encode");
  return issues ? {ok:false,issues} : {ok:true,value:serializeFlat(flatToWire(value))};
};
