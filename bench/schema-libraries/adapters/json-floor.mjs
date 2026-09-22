export const meta = {
  id: "json-floor",
  version: process.versions.v8,
  kind: "unvalidated-json-floor",
  codegen: false,
  cspExpected: true,
  deviation: "Intentionally performs no schema validation or program/wire mapping and is excluded from correctness checks.",
};

export function create(_workload, direction) {
  if (direction === "decode") return (text) => {
    try {
      return { ok: true, value: JSON.parse(text) };
    } catch {
      return { ok: false, issues: [{ path: [], code: "invalid_json" }] };
    }
  };
  if (direction === "encode") return (value) => {
    try {
      return { ok: true, value: JSON.stringify(value) };
    } catch {
      return { ok: false, issues: [{ path: [], code: "json_stringify" }] };
    }
  };
  throw new Error(`unknown direction ${direction}`);
}
