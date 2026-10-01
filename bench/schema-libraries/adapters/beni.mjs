import { codec, load } from "../beni/codec.mjs";

export const meta = {
  id: "beni",
  version: "S4",
  codegen: "build-time",
  cspExpected: true,
  kind: "specialised parse/print of `schema` declarations",
  config: "parseWith/printWith; FirstError; Reject unknown keys; safe Int; Float rejects NaN/Infinity when printed; optional key",
  caveat: "tree is a recursive record, which a v1 declaration cannot write; encode faults are ill-typed program values the type checker rejects",
  staticEncodeFaults: true,
  workloads: ["flat", "list", "union", "typeahead"],
};

const runners = await load("compiled");
export const create = (workload, direction) => codec(runners, workload, direction);
