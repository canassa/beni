// One contract for every adapter. This is benchmark data, not Beni production API.
export const WORKLOADS = ["flat", "list", "union", "tree", "typeahead"];
export const MAX_SAFE = 9007199254740991;
const string = { type: "string" };
const integer = { type: "integer", minimum: -MAX_SAFE, maximum: MAX_SAFE };
const number = { type: "number" };
const object = (properties, optional = []) => ({
  type: "object", properties,
  required: Object.keys(properties).filter((key) => !optional.includes(key)),
  additionalProperties: false,
});
const array = (items) => ({ type: "array", items });
export const FLAT_WIRE = object({
  "user-id": integer, "display-name": string, email: string, age: integer,
  active: { type: "boolean" }, score: number, role: string, nickname: string,
}, ["nickname"]);
export const FLAT_PROGRAM = object({
  userId: integer, displayName: string, email: string, age: integer,
  active: { type: "boolean" }, score: number, role: string, nickname: string,
}, ["nickname"]);

export function schemaFor(workload, direction) {
  const flat = direction === "decode" ? FLAT_WIRE : FLAT_PROGRAM;
  switch (workload) {
    case "flat": return flat;
    case "list": return array(flat);
    case "union": return array({ oneOf: [
      object({ kind: { const: "user", type: "string" }, user: flat }),
      object({ kind: { const: "count", type: "string" }, count: integer }),
      object({ kind: { const: "text", type: "string" }, text: string }),
      object({ kind: { const: "point", type: "string" }, x: number, y: number }),
    ] });
    case "tree": return { $ref: "#/$defs/Tree", $defs: {
      Tree: object({ id: integer, label: string, children: array({ $ref: "#/$defs/Tree" }) }),
    } };
    case "typeahead": return object({
      hits: array(object(direction === "decode" ? { hit_id: string, title: string } : { id: string, title: string })),
      total: integer,
    });
    default: throw new Error(`unknown workload ${workload}`);
  }
}

export function flatToProgram(value) {
  const out = { userId: value["user-id"], displayName: value["display-name"],
    email: value.email, age: value.age, active: value.active, score: value.score, role: value.role };
  if (Object.hasOwn(value, "nickname")) out.nickname = value.nickname;
  return out;
}
export function flatToWire(value) {
  const out = { "user-id": value.userId, "display-name": value.displayName,
    email: value.email, age: value.age, active: value.active, score: value.score, role: value.role };
  if (Object.hasOwn(value, "nickname")) out.nickname = value.nickname;
  return out;
}
export function toProgram(workload, value) {
  switch (workload) {
    case "flat": return flatToProgram(value);
    case "list": return value.map(flatToProgram);
    case "union": return value.map((item) => item.kind === "user" ? { kind: "user", user: flatToProgram(item.user) } : item);
    case "tree": return value;
    case "typeahead": return { hits: value.hits.map((hit) => ({ id: hit.hit_id, title: hit.title })), total: value.total };
    default: throw new Error(`unknown workload ${workload}`);
  }
}
export function toWire(workload, value) {
  switch (workload) {
    case "flat": return flatToWire(value);
    case "list": return value.map(flatToWire);
    case "union": return value.map((item) => item.kind === "user" ? { kind: "user", user: flatToWire(item.user) } : item);
    case "tree": return value;
    case "typeahead": return { hits: value.hits.map((hit) => ({ hit_id: hit.id, title: hit.title })), total: value.total };
    default: throw new Error(`unknown workload ${workload}`);
  }
}
