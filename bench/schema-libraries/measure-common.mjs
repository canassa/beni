import { isDeepStrictEqual } from "node:util";

export const ROWS = [
  "json-floor",
  "handwritten",
  "ajv",
  "ajv-standalone",
  "typia",
  "typebox-value",
  "typebox-compiled",
  "arktype",
  "fast-json-stringify+handwritten-guard",
  "zod",
  "zod-jitless",
  "valibot",
  "effect",
];

export const DIRECTIONS = ["decode", "encode"];
export const MEASURED_PATHS = ["valid", "wrong_type", "missing_key", "unknown_key"];

export function adapterPath(root, id) {
  if (id === "handwritten") return new URL("./handwritten.mjs", root).href;
  return new URL(`./adapters/${id}.mjs`, root).href;
}

export function entryPath(root, id, direction) {
  return new URL(`./entries/${id}-${direction}.mjs`, root).href;
}

export function percentile(values, fraction) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const position = (sorted.length - 1) * fraction;
  const lower = Math.floor(position);
  const upper = Math.ceil(position);
  if (lower === upper) return sorted[lower];
  return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - lower);
}

export function stats(samples) {
  return {
    count: samples.length,
    median_ns_per_op: percentile(samples, 0.5),
    p10_ns_per_op: percentile(samples, 0.1),
    p90_ns_per_op: percentile(samples, 0.9),
    min_ns_per_op: samples.length === 0 ? null : Math.min(...samples),
    max_ns_per_op: samples.length === 0 ? null : Math.max(...samples),
  };
}

export function rotate(items, offset) {
  if (items.length === 0) return [];
  const n = ((offset % items.length) + items.length) % items.length;
  return items.slice(n).concat(items.slice(0, n));
}

export function cellKey({ row, workload, direction, path }) {
  return `${row}\u0000${workload}\u0000${direction}\u0000${path}`;
}

export function caseKey({ workload, direction, path }) {
  return `${workload}\u0000${direction}\u0000${path}`;
}

export function supported(meta, direction) {
  const directions = meta.supportedDirections ?? meta.directions ?? DIRECTIONS;
  return directions.includes(direction);
}

export function structuralSuccessEqual(direction, actual, expected) {
  if (direction === "encode" && typeof actual === "string" && typeof expected === "string") {
    try {
      return isDeepStrictEqual(JSON.parse(actual), JSON.parse(expected));
    } catch {
      return false;
    }
  }
  return isDeepStrictEqual(actual, expected);
}

export function issuePaths(result) {
  if (!result || result.ok !== false || !Array.isArray(result.issues)) return null;
  return result.issues.map((issue) => issue.path);
}

function consumeScalar(item) {
  if (item === null || item === undefined) return 1;
  if (typeof item === "boolean") return item ? 3 : 5;
  if (typeof item === "number") return Number.isFinite(item) ? (Math.trunc(item) | 0) : 7;
  if (typeof item === "string") return item.length + (item.length === 0 ? 0 : item.charCodeAt(0) + item.charCodeAt(item.length - 1));
  return 11;
}

function consumePayload(item) {
  if (typeof item === "string") return consumeScalar(item);
  if (Array.isArray(item)) return item.length;
  if (item && typeof item === "object") {
    const keys = Object.keys(item);
    if (keys.length === 0) return 0;
    return keys.length + keys[0].length + keys[keys.length - 1].length + consumeScalar(item[keys[0]]) + consumeScalar(item[keys[keys.length - 1]]);
  }
  return consumeScalar(item);
}

export function consume(value) {
  if (value && typeof value === "object" && typeof value.ok === "boolean") {
    if (value.ok) return 17 + consumePayload(value.value);
    const issues = Array.isArray(value.issues) ? value.issues : [];
    if (issues.length === 0) return 19;
    const first = issues[0];
    return 19 + issues.length + (Array.isArray(first?.path) ? first.path.length : 0) + consumeScalar(first?.code);
  }
  return consumePayload(value);
}

export function serializeError(error) {
  return {
    name: error?.name ?? "Error",
    message: String(error?.message ?? error),
    stack: typeof error?.stack === "string" ? error.stack : null,
  };
}
