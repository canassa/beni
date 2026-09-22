import { makeCodec } from "./common.mjs";

const issue = (key, code) => [{ path: key === undefined ? [] : [key], code }];
const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const prefix = (errors, key) => { if (errors) for (const error of errors) error.path.unshift(key); return errors; };

// Straight-line per-shape checks, no schema interpreter or runtime generator.
// Paths are allocated only on failure, never for successful tree/list traversal.
export function validateFlat(v, direction = "decode") {
  if (!isObject(v)) return issue(undefined, "object");
  if (direction === "decode") {
    if (!Number.isSafeInteger(v["user-id"])) return issue("user-id", "safe_integer");
    if (typeof v["display-name"] !== "string") return issue("display-name", "string");
  } else {
    if (!Number.isSafeInteger(v.userId)) return issue("userId", "safe_integer");
    if (typeof v.displayName !== "string") return issue("displayName", "string");
  }
  if (typeof v.email !== "string") return issue("email", "string");
  if (!Number.isSafeInteger(v.age)) return issue("age", "safe_integer");
  if (typeof v.active !== "boolean") return issue("active", "boolean");
  if (typeof v.score !== "number" || !Number.isFinite(v.score)) return issue("score", "finite");
  if (typeof v.role !== "string") return issue("role", "string");
  if (Object.hasOwn(v, "nickname") && typeof v.nickname !== "string") return issue("nickname", "string");
  const id = direction === "decode" ? "user-id" : "userId";
  const name = direction === "decode" ? "display-name" : "displayName";
  for (const key in v) if (key !== id && key !== name && key !== "email" && key !== "age" && key !== "active" && key !== "score" && key !== "role" && key !== "nickname") return issue(key, "unknown_key");
  return null;
}
function validateUnion(v, direction) {
  if (!Array.isArray(v)) return issue(undefined, "array");
  for (let i = 0; i < v.length; i++) {
    const item = v[i];
    if (!isObject(item)) return prefix(issue(undefined, "object"), i);
    let error;
    switch (item.kind) {
      case "user":
        error = validateFlat(item.user, direction);
        if (error) return prefix(prefix(error, "user"), i);
        for (const key in item) if (key !== "kind" && key !== "user") return prefix(issue(key, "unknown_key"), i);
        break;
      case "count":
        if (!Number.isSafeInteger(item.count)) return prefix(issue("count", "safe_integer"), i);
        for (const key in item) if (key !== "kind" && key !== "count") return prefix(issue(key, "unknown_key"), i);
        break;
      case "text":
        if (typeof item.text !== "string") return prefix(issue("text", "string"), i);
        for (const key in item) if (key !== "kind" && key !== "text") return prefix(issue(key, "unknown_key"), i);
        break;
      case "point":
        if (typeof item.x !== "number" || !Number.isFinite(item.x)) return prefix(issue("x", "finite"), i);
        if (typeof item.y !== "number" || !Number.isFinite(item.y)) return prefix(issue("y", "finite"), i);
        for (const key in item) if (key !== "kind" && key !== "x" && key !== "y") return prefix(issue(key, "unknown_key"), i);
        break;
      default: return prefix(issue("kind", "discriminator"), i);
    }
  }
  return null;
}
function validateTree(v) {
  if (!isObject(v)) return issue(undefined, "object");
  if (!Number.isSafeInteger(v.id)) return issue("id", "safe_integer");
  if (typeof v.label !== "string") return issue("label", "string");
  if (!Array.isArray(v.children)) return issue("children", "array");
  for (const key in v) if (key !== "id" && key !== "label" && key !== "children") return issue(key, "unknown_key");
  for (let i = 0; i < v.children.length; i++) {
    const error = validateTree(v.children[i]);
    if (error) return prefix(prefix(error, i), "children");
  }
  return null;
}
function validatePage(v, direction) {
  if (!isObject(v)) return issue(undefined, "object");
  if (!Array.isArray(v.hits)) return issue("hits", "array");
  if (!Number.isSafeInteger(v.total)) return issue("total", "safe_integer");
  for (const key in v) if (key !== "hits" && key !== "total") return issue(key, "unknown_key");
  const id = direction === "decode" ? "hit_id" : "id";
  for (let i = 0; i < v.hits.length; i++) {
    const item = v.hits[i];
    if (!isObject(item)) return prefix(prefix(issue(undefined, "object"), i), "hits");
    if (typeof item[id] !== "string") return prefix(prefix(issue(id, "string"), i), "hits");
    if (typeof item.title !== "string") return prefix(prefix(issue("title", "string"), i), "hits");
    for (const key in item) if (key !== id && key !== "title") return prefix(prefix(issue(key, "unknown_key"), i), "hits");
  }
  return null;
}
export function validateHandwritten(workload, direction, value) {
  switch (workload) {
    case "flat": return validateFlat(value, direction);
    case "list":
      if (!Array.isArray(value)) return issue(undefined, "array");
      for (let i = 0; i < value.length; i++) {
        const error = validateFlat(value[i], direction);
        if (error) return prefix(error, i);
      }
      return null;
    case "union": return validateUnion(value, direction);
    case "tree": return validateTree(value);
    case "typeahead": return validatePage(value, direction);
    default: throw new Error(`unknown workload ${workload}`);
  }
}

const quote = JSON.stringify;
export function serializeFlat(v) {
  return `{"user-id":${v["user-id"]},"display-name":${quote(v["display-name"])},"email":${quote(v.email)},"age":${v.age},"active":${v.active},"score":${v.score},"role":${quote(v.role)}${Object.hasOwn(v,"nickname") ? `,"nickname":${quote(v.nickname)}` : ""}}`;
}
function serializeTree(v) {
  let text = `{"id":${v.id},"label":${quote(v.label)},"children":[`;
  for (let i = 0; i < v.children.length; i++) text += (i ? "," : "") + serializeTree(v.children[i]);
  return text + "]}";
}
export function serializeHandwritten(workload, value) {
  if (workload === "flat") return serializeFlat(value);
  if (workload === "tree") return serializeTree(value);
  if (workload === "typeahead") {
    let text = '{"hits":[';
    for (let i = 0; i < value.hits.length; i++) {
      const hit = value.hits[i];
      text += (i ? "," : "") + `{"hit_id":${quote(hit.hit_id)},"title":${quote(hit.title)}}`;
    }
    return text + `],"total":${value.total}}`;
  }
  let text = "[";
  for (let i = 0; i < value.length; i++) {
    const item = value[i];
    if (i) text += ",";
    if (workload === "list") text += serializeFlat(item);
    else switch (item.kind) {
      case "user": text += `{"kind":"user","user":${serializeFlat(item.user)}}`; break;
      case "count": text += `{"kind":"count","count":${item.count}}`; break;
      case "text": text += `{"kind":"text","text":${quote(item.text)}}`; break;
      case "point": text += `{"kind":"point","x":${item.x},"y":${item.y}}`; break;
    }
  }
  return text + "]";
}
export const meta = { id: "handwritten", version: "local", codegen: false, cspExpected: true, kind: "straight-line per-shape reference", contract: "strict path-reporting; no runtime codegen" };
export function create(workload, direction) {
  return makeCodec(workload, direction, (value) => validateHandwritten(workload, direction, value), (value) => serializeHandwritten(workload, value));
}
