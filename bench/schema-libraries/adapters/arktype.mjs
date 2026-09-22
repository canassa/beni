import { type } from "arktype";
import { makeCodec } from "../common.mjs";

export const meta = {
  id: "arktype",
  version: "2.2.3",
  kind: "compiled-validator",
  codegen: true,
  cspExpected: true,
  cspBehavior: "ArkType automatically selects its jitless evaluator under CSP",
};

const MIN_SAFE = -9007199254740991;
const MAX_SAFE = 9007199254740991;

function flatSchema(direction) {
  const safeInt = type("number.integer").atLeast(MIN_SAFE).atMost(MAX_SAFE);
  const finite = type("number").narrow(Number.isFinite);
  return type(direction === "decode" ? {
    "user-id": safeInt,
    "display-name": "string",
    email: "string",
    age: safeInt,
    active: "boolean",
    score: finite,
    role: "string",
    "nickname?": "string",
  } : {
    userId: safeInt,
    displayName: "string",
    email: "string",
    age: safeInt,
    active: "boolean",
    score: finite,
    role: "string",
    "nickname?": "string",
  });
}

function buildSchema(workload, direction) {
  const safeInt = type("number.integer").atLeast(MIN_SAFE).atMost(MAX_SAFE);
  const finite = type("number").narrow(Number.isFinite);
  if (workload === "flat") return flatSchema(direction).onDeepUndeclaredKey("reject");
  if (workload === "list") return flatSchema(direction).array().onDeepUndeclaredKey("reject");
  if (workload === "union") {
    const item = type({ kind: "'user'", user: flatSchema(direction) })
      .or({ kind: "'count'", count: safeInt })
      .or({ kind: "'text'", text: "string" })
      .or({ kind: "'point'", x: finite, y: finite });
    return item.array().onDeepUndeclaredKey("reject");
  }
  if (workload === "tree") {
    return type.module({
      Tree: { id: safeInt, label: "string", children: "Tree[]" },
    }).Tree.onDeepUndeclaredKey("reject");
  }
  if (workload === "typeahead") {
    const hit = type(direction === "decode"
      ? { hit_id: "string", title: "string" }
      : { id: "string", title: "string" });
    return type({
      hits: hit.array(),
      total: safeInt,
    }).onDeepUndeclaredKey("reject");
  }
  throw new Error(`unsupported ArkType workload: ${workload}`);
}

export function create(workload, direction) {
  const schema = buildSchema(workload, direction);
  const validate = (value) => {
    const result = schema(value);
    return result instanceof type.errors
      ? [...result].map((error) => ({ path: Array.from(error.path), code: error.code }))
      : null;
  };
  return makeCodec(workload, direction, validate);
}
