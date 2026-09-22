import { isDeepStrictEqual } from "node:util";
import { issuePaths, serializeError, structuralSuccessEqual, supported } from "./measure-common.mjs";

export function checkResult(testCase, result) {
  const expected = testCase.expected;
  if (!result || typeof result.ok !== "boolean") return "result is not an {ok,...} object";
  if (expected.ok) {
    if (!result.ok) return "successful case was rejected";
    if (!structuralSuccessEqual(testCase.direction, result.value, expected.value)) return "successful value differs";
    return null;
  }
  if (result.ok) return "invalid case was accepted";
  if (!Array.isArray(result.issues) || result.issues.length === 0) return "failure has no issues";
  if (result.issues.some((issue) => typeof issue.code !== "string" || issue.code.length === 0)) return "failure issue has an empty code";
  const actualPaths = issuePaths(result);
  const expectedPaths = expected.issues.map((issue) => issue.path);
  const unique = (paths) => [...new Set(paths.map((path) => JSON.stringify(path)))].sort();
  if (!isDeepStrictEqual(unique(actualPaths), unique(expectedPaths))) return `fault paths differ: ${JSON.stringify(actualPaths)} != ${JSON.stringify(expectedPaths)}`;
  return null;
}

function caseReference(testCase) {
  return { workload: testCase.workload, direction: testCase.direction, path: testCase.path, measured: testCase.measure !== false };
}

function resultReference(result) {
  if (!result || typeof result !== "object") return result;
  if (result.ok === false) return { ok: false, issues: result.issues };
  return {
    ok: result.ok,
    value_type: Array.isArray(result.value) ? "array" : typeof result.value,
    value_length: typeof result.value === "string" || Array.isArray(result.value) ? result.value.length : null,
  };
}

export async function auditAdapter({ adapter, cases, adversarial, jsonFloor = false }) {
  const failures = [];
  const checks = [];
  for (const testCase of [...cases, ...adversarial]) {
    if (!supported(adapter.meta, testCase.direction)) continue;
    const input = jsonFloor && testCase.jsonFloorInput !== undefined ? testCase.jsonFloorInput : testCase.input;
    const before = structuredClone(input);
    let run;
    let result;
    try {
      run = adapter.create(testCase.workload, testCase.direction);
      if (typeof run !== "function") throw new Error("create did not return a run function");
      result = run(input);
    } catch (error) {
      failures.push({ case: caseReference(testCase), reason: "threw", error: serializeError(error) });
      continue;
    }
    if (!isDeepStrictEqual(input, before)) failures.push({ case: caseReference(testCase), reason: "mutated input" });
    if (!jsonFloor) {
      const reason = checkResult(testCase, result);
      if (reason) failures.push({ case: caseReference(testCase), reason, actual: resultReference(result) });
    }
    checks.push({ workload: testCase.workload, direction: testCase.direction, path: testCase.path, measured: testCase.measure !== false });
  }
  return { row: adapter.meta.id, meta: adapter.meta, passed: failures.length === 0, checks, failures };
}

export async function auditAll({ adapters, cases, adversarial }) {
  const reports = [];
  for (const adapter of adapters) reports.push(await auditAdapter({ adapter, cases, adversarial, jsonFloor: adapter.meta.id === "json-floor" }));
  return reports;
}

// These JS-only boundaries are deliberately not part of the comparable JSON
// matrix. Preserve each native outcome as capability evidence instead of
// repairing it or turning it into a timing qualification.
export async function auditContractProbes({ adapters, probes }) {
  const reports = [];
  for (const adapter of adapters) {
    if (adapter.meta.id === "json-floor") {
      reports.push({ row: adapter.meta.id, excluded: true, reason: "JSON floor does not validate" });
      continue;
    }
    const outcomes = [];
    for (const probe of probes) {
      if (!supported(adapter.meta, probe.direction)) continue;
      const before = structuredClone(probe.input);
      try {
        const run = adapter.create(probe.workload, probe.direction);
        if (typeof run !== "function") throw new Error("create did not return a run function");
        const actual = run(probe.input);
        const mutated = !isDeepStrictEqual(probe.input, before);
        outcomes.push({
          probe: caseReference(probe),
          conforms: !mutated && checkResult(probe, actual) === null,
          mutation: mutated,
          deviation: mutated ? "mutated input" : checkResult(probe, actual),
          actual,
        });
      } catch (error) {
        outcomes.push({ probe: caseReference(probe), conforms: false, mutation: false, deviation: "threw", error: serializeError(error) });
      }
    }
    reports.push({ row: adapter.meta.id, outcomes, conforms: outcomes.every((item) => item.conforms) });
  }
  return reports;
}
