import { type } from "arktype";
import { flatToWire } from "../spec.mjs";

export const meta = { id: "arktype", version: "2.2.3", kind: "compiled-validator", codegen: true, cspExpected: true };
const safeInt = type("number.integer").atLeast(-9007199254740991).atMost(9007199254740991);
const finite = type("number").narrow(Number.isFinite);
const validate = type({
  userId: safeInt, displayName: "string", email: "string", age: safeInt,
  active: "boolean", score: finite, role: "string", "nickname?": "string",
}).onDeepUndeclaredKey("reject");
export function run(value) {
  const result = validate(value);
  return result instanceof type.errors
    ? { ok: false, issues: [...result].map((error) => ({ path: Array.from(error.path), code: error.code })) }
    : { ok: true, value: JSON.stringify(flatToWire(value)) };
}
