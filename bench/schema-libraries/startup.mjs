import { stats, supported } from "./measure-common.mjs";
import { spawnJson } from "./process-tools.mjs";

export async function measureStartup({ rootPath, rows, adapters, cases, repetitions = 3, progress = () => {} }) {
  const valid = cases.filter((item) => item.path === "valid");
  const reports = [];
  for (const row of rows) {
    const adapter = adapters.find((item) => item.meta.id === row);
    if (!adapter) continue;
    for (const testCase of valid) {
      if (!supported(adapter.meta, testCase.direction)) continue;
      for (let repetition = 0; repetition < repetitions; repetition++) {
        progress(`startup ${row} ${testCase.workload}/${testCase.direction} ${repetition + 1}/${repetitions}`);
        reports.push(await spawnJson(process.execPath, [
          new URL("./startup-worker.mjs", import.meta.url).pathname,
          JSON.stringify({ root: rootPath, row, workload: testCase.workload, direction: testCase.direction, repetition }),
        ], { cwd: rootPath }));
      }
    }
  }
  for (const row of rows) {
    const adapter = adapters.find((item) => item.meta.id === row);
    if (!adapter) continue;
    for (const testCase of valid.filter((item) => item.workload === "flat")) {
      if (!supported(adapter.meta, testCase.direction)) continue;
      for (let repetition = 0; repetition < repetitions; repetition++) {
        progress(`startup flat-entry ${row} ${testCase.direction} ${repetition + 1}/${repetitions}`);
        reports.push(await spawnJson(process.execPath, [
          new URL("./startup-worker.mjs", import.meta.url).pathname,
          JSON.stringify({ root: rootPath, row, workload: testCase.workload, direction: testCase.direction, repetition, entry: true }),
        ], { cwd: rootPath }));
      }
    }
  }
  const keys = [...new Set(reports.filter((item) => !item.error).map((item) => `${item.surface}\u0000${item.row}\u0000${item.workload}\u0000${item.direction}`))];
  const eventStats = (values) => {
    const result = stats(values);
    return { count: result.count, median_ns: result.median_ns_per_op, p10_ns: result.p10_ns_per_op, p90_ns: result.p90_ns_per_op, min_ns: result.min_ns_per_op, max_ns: result.max_ns_per_op };
  };
  const summary = keys.map((key) => {
    const [surface, row, workload, direction] = key.split("\u0000");
    const cells = reports.filter((item) => !item.error && item.surface === surface && item.row === row && item.workload === workload && item.direction === direction);
    return {
      surface,
      row,
      workload,
      direction,
      import: eventStats(cells.map((item) => item.import_ns)),
      construction_compile: surface === "flat-only-entry" ? null : eventStats(cells.map((item) => item.construct_ns)),
      first_call: eventStats(cells.map((item) => item.first_call_ns)),
    };
  });
  return { repetitions, raw: reports, summary };
}

export async function measureCsp({ rootPath, rows, adapters, progress = () => {} }) {
  const reports = [];
  for (const row of rows) {
    progress(`csp ${row}`);
    const report = await spawnJson(process.execPath, [
      "--disallow-code-generation-from-strings",
      new URL("./csp-worker.mjs", import.meta.url).pathname,
      JSON.stringify({ root: rootPath, row }),
    ], { cwd: rootPath });
    const expected = adapters.find((item) => item.meta.id === row)?.meta.cspExpected;
    reports.push({ ...report, expected: expected ?? null, matches_expectation: expected === undefined ? null : report.feasible === expected });
  }
  return reports;
}
