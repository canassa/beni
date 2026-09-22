import { readFile } from "node:fs/promises";
import { WORKLOADS, toProgram, toWire } from "./spec.mjs";

export async function measurementCases() {
  const cases = [];
  for (const workload of WORKLOADS) {
    const data = JSON.parse(await readFile(new URL(`./payloads/${workload}.json`, import.meta.url), "utf8"));
    for (const entry of data) for (const direction of ["decode", "encode"]) {
      const input = direction === "decode" ? JSON.stringify(entry.wire) : entry.program;
      const expected = entry.path === "valid"
        ? { ok: true, value: direction === "decode" ? entry.program : JSON.stringify(entry.wire) }
        : { ok: false, issues: [{ path: direction === "decode" ? entry.wireFaultPath : entry.programFaultPath }] };
      cases.push({ workload, direction, path: entry.path, input, expected,
        jsonFloorInput: direction === "encode" ? entry.wire : input });
    }
  }
  return cases;
}

export async function adversarialCases() {
  const data = JSON.parse(await readFile(new URL("./payloads/flat.json", import.meta.url), "utf8"))[0];
  const result = [];
  for (const direction of ["decode", "encode"]) {
    for (const [name, key, bad] of [["unsafe_integer", "age", 9007199254740992], ["fractional_integer", "age", 1.5], ["nullable_optional", "nickname", null]]) {
      const value = structuredClone(direction === "decode" ? data.wire : data.program);
      value[key] = bad;
      result.push({ workload: "flat", direction, path: name, measure: false,
        input: direction === "decode" ? JSON.stringify(value) : value,
        expected: { ok: false, issues: [{ path: [key] }] } });
    }
    const value = Object.fromEntries(Object.entries(direction === "decode" ? data.wire : data.program).reverse());
    delete value.nickname;
    result.push({ workload: "flat", direction, path: "reordered_optional_absent", measure: false,
      input: direction === "decode" ? JSON.stringify(value) : value,
      expected: { ok: true, value: direction === "decode" ? toProgram("flat", value) : JSON.stringify(toWire("flat", value)) } });
    if (direction === "encode") {
      const value = { ...data.program, score: Infinity };
      result.push({ workload: "flat", direction, path: "nonfinite", measure: false, input: value,
        expected: { ok: false, issues: [{ path: ["score"] }] } });
    }
  }
  return result;
}

// JS-only encode boundaries cannot be committed as JSON payloads. These are
// reported separately from the common JSON-shaped timing matrix; an observed
// mismatch is a stated capability deviation, never silently repaired.
export async function contractProbes() {
  const data = JSON.parse(await readFile(new URL("./payloads/flat.json", import.meta.url), "utf8"))[0];
  return ["nickname", "unexpected"].map((key) => ({
    workload: "flat", direction: "encode", path: `present_undefined_${key}`,
    measure: false, input: { ...data.program, [key]: undefined },
    expected: { ok: false, issues: [{ path: [key] }] },
  }));
}
