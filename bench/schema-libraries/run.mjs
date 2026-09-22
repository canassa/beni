#!/usr/bin/env node

import { dirname } from "node:path";
import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { promisify } from "node:util";
import { fileURLToPath, pathToFileURL } from "node:url";
import { analyze } from "./analysis.mjs";
import { measureBundles } from "./bundle.mjs";
import { auditAll, auditContractProbes } from "./correctness.mjs";
import { adapterPath, ROWS, serializeError } from "./measure-common.mjs";
import { spawnJson } from "./process-tools.mjs";
import { performanceTables, bundleTable, startupTable } from "./report.mjs";
import { assertNoCompetingBuilds } from "./quiet.mjs";
import { measureCsp, measureStartup } from "./startup.mjs";
import { verifySources } from "./verify-sources.mjs";

const rootPath = dirname(fileURLToPath(import.meta.url));
const rootUrl = pathToFileURL(`${rootPath}/`);
const args = new Set(process.argv.slice(2));
const allowed = new Set(["--preflight"]);
for (const arg of args) if (!allowed.has(arg)) throw new Error(`unknown argument ${arg}`);
const preflightOnly = args.has("--preflight");
const progress = (message) => process.stderr.write(`${message}\n`);
const execFileAsync = promisify(execFile);
// A subject must not corrupt the one-document stdout protocol with import logs.
console.log = (...values) => console.error(...values);

async function environmentSnapshot() {
  if (process.platform !== "darwin") return { capture: "unsupported on this platform" };
  try {
    const [{ stdout: sysctl }, { stdout: battery }, { stdout: custom }] = await Promise.all([
      execFileAsync("sysctl", ["-n", "machdep.cpu.brand_string", "hw.physicalcpu", "hw.logicalcpu", "hw.memsize"]),
      execFileAsync("pmset", ["-g", "batt"]),
      execFileAsync("pmset", ["-g", "custom"]),
    ]);
    const [cpuBrand, physicalCores, logicalCores, memoryBytes] = sysctl.trim().split("\n");
    const lowPower = (section) => Number(new RegExp(`${section}:\\s*[\\s\\S]*?lowpowermode\\s+(\\d+)`).exec(custom)?.[1]);
    return {
      hardware: { cpu_brand: cpuBrand, physical_cores: Number(physicalCores), logical_cores: Number(logicalCores), memory_bytes: Number(memoryBytes) },
      power: {
        source: /Now drawing from '([^']+)'/.exec(battery)?.[1] ?? null,
        battery_percent: Number(/\s(\d+)%;/.exec(battery)?.[1]),
        low_power_mode: { ac: lowPower("AC Power"), battery: lowPower("Battery Power") },
        pmset_battery_raw: battery.trim(),
        pmset_custom_raw: custom.trim(),
      },
      controls: { frequency_control: "not available", process_affinity: "not available", final_run_idle_guard: "run externally under caffeinate -i; no persistent power-setting changes" },
    };
  } catch (error) {
    return { capture_error: serializeError(error) };
  }
}

async function loadAdapters() {
  const adapters = [];
  const failures = [];
  for (const row of ROWS) {
    try {
      const adapter = await import(adapterPath(rootUrl, row));
      if (!adapter.meta || typeof adapter.create !== "function") throw new Error("adapter must export meta and create");
      if (adapter.meta.id !== row) throw new Error(`adapter meta.id ${adapter.meta.id} does not match row ${row}`);
      adapters.push(adapter);
    } catch (error) {
      failures.push({ row, error: serializeError(error) });
    }
  }
  return { adapters, failures };
}

async function main() {
  if (Number(process.versions.node.split(".")[0]) !== 24) throw new Error(`requires pinned Node 24, got ${process.version}`);
  const sourceVerification = await verifySources();
  const { measurementCases, adversarialCases, contractProbes } = await import("./fixtures.mjs");
  const packageManifest = JSON.parse(await readFile(new URL("./package.json", import.meta.url), "utf8"));
  const provenance = JSON.parse(await readFile(new URL("./provenance.json", import.meta.url), "utf8"));
  const machine = await environmentSnapshot();
  const cases = await measurementCases();
  const adversarial = await adversarialCases();
  const probes = await contractProbes();
  const loaded = await loadAdapters();
  progress(`correctness: ${loaded.adapters.length}/${ROWS.length} adapters loaded`);
  const correctness = await auditAll({ adapters: loaded.adapters, cases, adversarial });
  const contract_probes = await auditContractProbes({ adapters: loaded.adapters, probes });
  const correctnessPassed = loaded.failures.length === 0 && correctness.every((item) => item.passed);
  const base = {
    protocol: 1,
    source_verification: sourceVerification,
    environment: { node: process.version, v8: process.versions.v8, platform: process.platform, architecture: process.arch, machine },
    pinned_packages: { ...packageManifest.dependencies, ...packageManifest.devDependencies },
    subject_provenance: provenance,
    setup_command: "nix develop -c sh -c 'cd bench/schema-libraries && npm run setup'",
    configuration: {
      groups: 3,
      repetitions_per_group: 3,
      samples_per_cell: 35,
      target_batch_ns: 2_000_000,
      warmup_samples_per_round: 4,
      max_warmup_rounds: 20,
      convergence_tolerance: 0.03,
      convergence_windows: 2,
      max_iterations: 1_048_576,
      serial: true,
    },
    adapter_import_failures: loaded.failures,
    correctness,
    contract_probes,
  };
  if (preflightOnly || !correctnessPassed) return { ...base, ok: correctnessPassed, complete: false, stopped_after: "correctness", reason: correctnessPassed ? "preflight requested" : "correctness failed" };

  const quiet_system = await assertNoCompetingBuilds();
  const processes = [];
  let processIndex = 0;
  for (let group = 0; group < 3; group++) {
    for (let repetition = 0; repetition < 3; repetition++) {
      processIndex++;
      progress(`timing process ${processIndex}/9 (group ${group}, repetition ${repetition})`);
      processes.push(await spawnJson(process.execPath, [
        new URL("./worker.mjs", import.meta.url).pathname,
        JSON.stringify({
          root: rootPath,
          rows: ROWS,
          group,
          repetition,
          rotation: processIndex - 1,
          samples: base.configuration.samples_per_cell,
          targetBatchNs: base.configuration.target_batch_ns,
          warmupSamplesPerRound: base.configuration.warmup_samples_per_round,
          maxWarmupRounds: base.configuration.max_warmup_rounds,
          convergenceTolerance: base.configuration.convergence_tolerance,
          convergenceWindows: base.configuration.convergence_windows,
          maxIterations: base.configuration.max_iterations,
        }),
      ], { cwd: rootPath, timeoutMs: 60 * 60 * 1000 }));
    }
  }
  const analysis = analyze(processes);
  const startup = await measureStartup({ rootPath, rows: ROWS, adapters: loaded.adapters, cases, progress });
  const csp = await measureCsp({ rootPath, rows: ROWS, adapters: loaded.adapters, progress });
  const bundles = await measureBundles({ rootUrl, rows: ROWS, adapters: loaded.adapters, cases, progress });
  const unexpectedUnsupported = analysis.unsupported.filter((item) => !(item.row === "fast-json-stringify+handwritten-guard" && item.direction === "decode"));
  const requiredTimingKeys = loaded.adapters.flatMap((adapter) => cases.filter((item) => (adapter.meta.supportedDirections ?? adapter.meta.directions ?? ["decode", "encode"]).includes(item.direction)).map((item) => `${adapter.meta.id}\u0000${item.workload}\u0000${item.direction}\u0000${item.path}`));
  const coverageFailures = processes.flatMap((process) => {
    const found = new Set(process.cells.filter((cell) => !cell.unsupported).map((cell) => `${cell.row}\u0000${cell.workload}\u0000${cell.direction}\u0000${cell.path}`));
    const missing = requiredTimingKeys.filter((key) => !found.has(key));
    return missing.length === 0 ? [] : [{ group: process.group, repetition: process.repetition, missing }];
  });
  const startupFailures = startup.raw.filter((item) => item.error);
  const bundleFailures = bundles.filter((item) => item.error || item.flat_only_audit?.passed !== true || item.execution?.passed !== true);
  const hardFailures = [
    ...analysis.measurement_failures.map((item) => ({ phase: "timing", detail: item })),
    ...coverageFailures.map((item) => ({ phase: "timing-coverage", detail: item })),
    ...unexpectedUnsupported.map((item) => ({ phase: "timing-unsupported", detail: item })),
    ...startupFailures.map((item) => ({ phase: "startup", detail: item })),
    ...bundleFailures.map((item) => ({ phase: "bundle", detail: item })),
  ];
  const qualifications = [];
  if (analysis.warmup_nonconvergence.length > 0) qualifications.push({ kind: "warmup_nonconvergence", cells: analysis.warmup_nonconvergence, effect: "Cells are retained in raw evidence but excluded from stable rankings and flip conclusions." });
  const cspMismatches = csp.filter((item) => item.matches_expectation === false);
  if (cspMismatches.length > 0) qualifications.push({ kind: "csp_expectation_mismatch", rows: cspMismatches });
  const complete = hardFailures.length === 0;
  return {
    ...base,
    ok: complete,
    complete,
    hard_failures: hardFailures,
    qualified: qualifications.length > 0,
    qualifications,
    quiet_system,
    timing: { processes, analysis },
    startup,
    csp,
    bundles,
    generated_tables: { performance: performanceTables(analysis), startup: startupTable(startup), bundles: bundleTable(bundles) },
  };
}

let result;
try {
  result = await main();
} catch (error) {
  result = { ok: false, complete: false, fatal: serializeError(error) };
  process.exitCode = 1;
}
if (result.ok === false) process.exitCode = 1;
process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
