import { performance } from "node:perf_hooks";
import { pathToFileURL } from "node:url";
import { adapterPath, caseKey, consume, rotate, serializeError, stats, supported } from "./measure-common.mjs";

const config = JSON.parse(process.argv[2]);
const root = pathToFileURL(`${config.root}/`);
const { measurementCases } = await import(new URL("./fixtures.mjs", root));
const cases = await measurementCases();
const byKey = new Map(cases.map((item) => [caseKey(item), item]));
let sink = 0;

function batch(run, input, iterations) {
  const start = performance.now();
  for (let i = 0; i < iterations; i++) sink = (sink + consume(run(input))) | 0;
  return (performance.now() - start) * 1e6 / iterations;
}

function calibrate(run, input, targetNs, maxIterations) {
  let iterations = 1;
  const attempts = [];
  while (true) {
    const start = performance.now();
    for (let i = 0; i < iterations; i++) sink = (sink + consume(run(input))) | 0;
    const elapsedNs = (performance.now() - start) * 1e6;
    attempts.push({ iterations, elapsed_ns: elapsedNs });
    if (elapsedNs >= targetNs || iterations >= maxIterations) return { iterations, attempts };
    const scale = Math.max(2, Math.min(16, Math.ceil(targetNs / Math.max(1, elapsedNs))));
    iterations = Math.min(maxIterations, iterations * scale);
  }
}

function warm(run, input, iterations, options) {
  const rounds = [];
  let prior = null;
  let stable = 0;
  for (let round = 0; round < options.maxWarmupRounds; round++) {
    const samples = Array.from({ length: options.warmupSamplesPerRound }, () => batch(run, input, iterations));
    const summary = stats(samples);
    const change = prior === null ? null : Math.abs(summary.median_ns_per_op - prior) / Math.max(1, prior);
    rounds.push({ samples_ns_per_op: samples, median_ns_per_op: summary.median_ns_per_op, relative_change: change });
    stable = change !== null && change <= options.convergenceTolerance ? stable + 1 : 0;
    prior = summary.median_ns_per_op;
    if (stable >= options.convergenceWindows) return { converged: true, rounds };
  }
  return { converged: false, rounds };
}

const cells = [];
const rowOrder = rotate(config.rows, config.rotation);
for (const row of rowOrder) {
  let module;
  try {
    module = await import(adapterPath(root, row));
  } catch (error) {
    cells.push({ row, measurement_failed: true, reason: "adapter import failed", error: serializeError(error) });
    continue;
  }
  for (const testCase of cases) {
    if (!supported(module.meta, testCase.direction)) {
      cells.push({ row, workload: testCase.workload, direction: testCase.direction, path: testCase.path, unsupported: true, reason: "direction unsupported" });
      continue;
    }
    const canonical = byKey.get(caseKey(testCase));
    const input = row === "json-floor" ? canonical.jsonFloorInput : canonical.input;
    try {
      const run = module.create(testCase.workload, testCase.direction);
      if (typeof run !== "function") throw new Error("create did not return a run function");
      const calibration = calibrate(run, input, config.targetBatchNs, config.maxIterations);
      const warmup = warm(run, input, calibration.iterations, config);
      const samples = Array.from({ length: config.samples }, () => batch(run, input, calibration.iterations));
      cells.push({
        row,
        workload: testCase.workload,
        direction: testCase.direction,
        path: testCase.path,
        unsupported: false,
        iterations: calibration.iterations,
        calibration: calibration.attempts,
        warmup,
        samples_ns_per_op: samples,
        summary: stats(samples),
      });
    } catch (error) {
      cells.push({ row, workload: testCase.workload, direction: testCase.direction, path: testCase.path, measurement_failed: true, reason: "measurement setup failed", error: serializeError(error) });
    }
  }
}

process.stdout.write(JSON.stringify({ group: config.group, repetition: config.repetition, rotation: config.rotation, row_order: rowOrder, sink, cells }));
