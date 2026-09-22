import { toProgram, toWire } from "./spec.mjs";

export function makeCodec(workload, direction, validate, serialize = JSON.stringify) {
  if (direction === "decode") return (text) => {
    let value;
    try { value = JSON.parse(text); }
    catch { return { ok: false, issues: [{ path: [], code: "invalid_json" }] }; }
    const issues = validate(value);
    return issues === null ? { ok: true, value: toProgram(workload, value) } : { ok: false, issues };
  };
  return (value) => {
    const issues = validate(value);
    return issues === null ? { ok: true, value: serialize(toWire(workload, value)) } : { ok: false, issues };
  };
}

// Parsing libraries may clone on validation; use their returned value rather
// than discarding it. This intrinsic cloning cost remains part of their row.
export function makeParsedCodec(workload, direction, parse, serialize = JSON.stringify) {
  return (input) => {
    let value = input;
    if (direction === "decode") {
      try { value = JSON.parse(input); }
      catch { return { ok: false, issues: [{ path: [], code: "invalid_json" }] }; }
    }
    const parsed = parse(value);
    if (!parsed.ok) return parsed;
    return { ok: true, value: direction === "decode"
      ? toProgram(workload, parsed.value) : serialize(toWire(workload, parsed.value)) };
  };
}

// Exact JSON-pointer segments; numeric array indexes are made numeric only by
// inspecting the corresponding input container (object key "0" remains text).
export function pointerPath(pointer, input) {
  if (!pointer) return [];
  const path = [];
  let at = input;
  for (const raw of pointer.slice(1).split("/")) {
    const key = raw.replaceAll("~1", "/").replaceAll("~0", "~");
    const segment = Array.isArray(at) ? Number(key) : key;
    path.push(segment);
    at = at?.[segment];
  }
  return path;
}
