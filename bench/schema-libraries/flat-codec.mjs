import { flatToProgram, flatToWire } from "./spec.mjs";
export function flatCodec(parse, direction) {
  return (input) => {
    let value = input;
    if (direction === "decode") {
      try { value = JSON.parse(input); }
      catch { return { ok: false, issues: [{ path: [], code: "invalid_json" }] }; }
    }
    const parsed = parse(value);
    if (!parsed.ok) return parsed;
    return { ok: true, value: direction === "decode" ? flatToProgram(parsed.value) : JSON.stringify(flatToWire(parsed.value)) };
  };
}
