#!/usr/bin/env node
// Runtime of the emitted JavaScript — M5 of `plans/static-dispatch-spike.md`
// §7.
//
// Builds every program under `bench/runtime/<variant>/` with `beni build`,
// runs it under Node `--runs` times, and prints one JSON line per program:
//
//     {"program":"R1DictString","variant":"c0","runs":20,"ops":120000,
//      "floor_ms":36.1,"best_ms":329.8,"median_ms":334.9,
//      "ns_per_op":2447.5,"checksum":"60000 288894"}
//
// `--variant=c0|c1` picks the directory, so S6 can drop the dispatch
// rewrites in `bench/runtime/c1/` beside the `c0` originals under the same
// names and the two sets line up row for row.
//
// Each program carries its own op count in a `-- ops: <n>` header comment
// (the first such line in the file). `ns_per_op` is measured against
// `best_ms - floor_ms`: the timing is around the whole child process, so
// everything that is not the workload has to come out or the number is
// mostly Node.
//
// **The floor is a null beni PROGRAM, not an empty script.** An empty `.mjs`
// measures the interpreter starting and nothing else; what every program
// here actually pays before its first op is the interpreter start PLUS the
// ESM load of `out/main.mjs`, the platform runtime and the whole of `core/`,
// which is ~6 ms today and which C1 changes — `core/Dict` loses its
// comparator plumbing and gains derived functions. So the floor is
// `Node.done` compiled by the same binary in the same run, and a C1 floor is
// automatically a C1 floor.
//
// **It is re-measured interleaved with every program**, run for run, rather
// than once at the start (`bench/README.md:60-64`: an early draft of the M1d
// table read 784 ms where the real number was 51 ms because the machine
// drifted between blocks). Each iteration times the floor and then the
// program, so a machine that speeds up or slows down over the run moves both
// numbers together.
//
// Every program prints ONE checksum line. Each run's stdout is compared with
// the first run's, so a wrong answer is a failure and not a fast number.
//
// Output order is the sorted file name, always.

import { spawnSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { tmpdir } from "node:os";
import process from "node:process";

const usage = `usage: node bench/runtime.mjs [options]

  --beni=<path>       compiler to run (default ./zig-out/bin/beni)
  --dir=<path>        program root (default bench/runtime)
  --variant=c0|c1     subdirectory of --dir to measure (default c0)
  --runs=<n>          runs per program (default 20)
  --program=<name>    measure only this program (basename, repeatable)
  --cpu-prof          also write a V8 CPU profile for R4 and R6 (§7 M5)
  --prof-dir=<path>   where --cpu-prof writes (default bench-runtime-prof)
  --keep              leave the temporary build trees on disk
  --help              print this

Prints one JSON line per program, sorted by program name.`;

function parseArgs(argv) {
  const options = {
    beni: "./zig-out/bin/beni",
    dir: "bench/runtime",
    variant: "c0",
    runs: 20,
    programs: [],
    cpuProf: false,
    profDir: "bench-runtime-prof",
    keep: false,
  };
  for (const arg of argv) {
    const eq = arg.indexOf("=");
    const name = eq === -1 ? arg : arg.slice(0, eq);
    const value = eq === -1 ? null : arg.slice(eq + 1);
    switch (name) {
      case "--help":
      case "-h":
        console.log(usage);
        process.exit(0);
        break;
      case "--beni":
        options.beni = value;
        break;
      case "--dir":
        options.dir = value;
        break;
      case "--variant":
        if (value !== "c0" && value !== "c1") fail(`--variant must be c0 or c1, not ${value}`);
        options.variant = value;
        break;
      case "--runs":
        options.runs = Number(value);
        if (!Number.isInteger(options.runs) || options.runs < 1) fail(`--runs must be a positive integer`);
        break;
      case "--program":
        options.programs.push(value.replace(/\.beni$/, ""));
        break;
      case "--cpu-prof":
        options.cpuProf = true;
        break;
      case "--prof-dir":
        options.profDir = value;
        break;
      case "--keep":
        options.keep = true;
        break;
      default:
        fail(`unknown option ${name}\n\n${usage}`);
    }
  }
  return options;
}

function fail(message) {
  process.stderr.write(`bench/runtime.mjs: ${message}\n`);
  process.exit(2);
}

/// The op count a program declares, so `ns_per_op` means something. A
/// program without the header is a failure rather than a guess.
function opsOf(source, path) {
  const match = source.match(/^--\s*ops:\s*(\d+)\s*$/m);
  if (!match) fail(`${path} has no '-- ops: <n>' header line`);
  return Number(match[1]);
}

/// Best and median of a sorted-by-value copy. Median of an even count is the
/// lower of the two middles, so the number is always one that was measured.
function summary(samples) {
  const sorted = [...samples].sort((a, b) => a - b);
  return { best: sorted[0], median: sorted[(sorted.length - 1) >> 1] };
}

function timeOnce(nodeExe, script, cwd, extraArgs) {
  const started = process.hrtime.bigint();
  const run = spawnSync(nodeExe, [...extraArgs, script], { cwd, encoding: "utf8" });
  const elapsed = Number(process.hrtime.bigint() - started) / 1e6;
  return { ms: elapsed, run };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const root = resolve(options.dir, options.variant);
  let entries;
  try {
    entries = readdirSync(root);
  } catch {
    fail(`cannot read ${root}`);
  }
  const programs = entries
    .filter((name) => name.endsWith(".beni"))
    .map((name) => name.slice(0, -".beni".length))
    .filter((name) => options.programs.length === 0 || options.programs.includes(name))
    .sort();
  if (programs.length === 0) fail(`no programs under ${root}`);

  const beni = resolve(options.beni);
  const nodeExe = process.execPath;
  const work = mkdtempSync(join(tmpdir(), "beni-runtime-"));
  const profDir = resolve(options.profDir);

  // The floor: a beni program that does nothing, built by the same compiler
  // in the same run, so it carries this variant's core and platform.
  const floorDir = join(work, "__floor");
  mkdirSync(floorDir, { recursive: true });
  writeFileSync(join(floorDir, "Floor.beni"), "import Node exposing (Program)\n\n\nmain : Program\nmain =\n    Node.done\n");
  const floorBuilt = spawnSync(beni, ["build", "--platform=node", "--out=out", "Floor.beni"], {
    cwd: floorDir,
    encoding: "utf8",
  });
  if (floorBuilt.status !== 0 || (floorBuilt.stderr ?? "").length !== 0) {
    process.stderr.write(
      `bench/runtime.mjs: the floor program did not build\n${floorBuilt.stdout ?? ""}${floorBuilt.stderr ?? ""}\n`,
    );
    rmSync(work, { recursive: true, force: true });
    process.exit(1);
  }

  let failed = false;
  const lines = [];
  for (const program of programs) {
    const sourcePath = join(root, `${program}.beni`);
    const source = readFileSync(sourcePath, "utf8");
    const ops = opsOf(source, sourcePath);

    // Copied into a project of its own, exactly as `corpus_test.zig` does:
    // the module name comes from the path, so a program measured in place
    // would be `Bench.Runtime.C0.R1DictString`.
    const project = join(work, `${options.variant}-${program}`);
    mkdirSync(project, { recursive: true });
    const moduleName = `${basename(program)}.beni`;
    writeFileSync(join(project, moduleName), source);

    const built = spawnSync(beni, ["build", "--platform=node", "--out=out", moduleName], {
      cwd: project,
      encoding: "utf8",
    });
    if (built.status !== 0 || (built.stderr ?? "").length !== 0) {
      process.stderr.write(`bench/runtime.mjs: ${program} did not build\n${built.stdout ?? ""}${built.stderr ?? ""}\n`);
      failed = true;
      continue;
    }

    const samples = [];
    const floorSamples = [];
    let checksum = null;
    let broke = false;
    for (let i = 0; i < options.runs; i++) {
      // Interleaved: the floor immediately before the program it is
      // subtracted from, every run.
      const floorRun = timeOnce(nodeExe, "out/main.mjs", floorDir, []);
      if (floorRun.run.status !== 0) {
        process.stderr.write(`bench/runtime.mjs: the floor program exited ${floorRun.run.status}\n`);
        broke = true;
        break;
      }
      floorSamples.push(floorRun.ms);
      const { ms, run } = timeOnce(nodeExe, "out/main.mjs", project, []);
      if (run.status !== 0) {
        process.stderr.write(
          `bench/runtime.mjs: ${program} exited ${run.status}\n${run.stdout ?? ""}${run.stderr ?? ""}\n`,
        );
        broke = true;
        break;
      }
      const out = (run.stdout ?? "").trim();
      if (checksum === null) checksum = out;
      else if (out !== checksum) {
        process.stderr.write(`bench/runtime.mjs: ${program} run ${i} printed ${out}, run 0 printed ${checksum}\n`);
        broke = true;
        break;
      }
      samples.push(ms);
    }
    if (broke) {
      failed = true;
      continue;
    }

    // §7 M5 asks for a V8 profile on R4 and R6 — the two rows that ask
    // whether the engine inlines the call — and nothing else.
    let profile = null;
    if (options.cpuProf && /^R[46]/.test(program)) {
      mkdirSync(profDir, { recursive: true });
      const run = spawnSync(nodeExe, ["--cpu-prof", `--cpu-prof-dir=${profDir}`, "out/main.mjs"], {
        cwd: project,
        encoding: "utf8",
      });
      if (run.status !== 0) {
        process.stderr.write(`bench/runtime.mjs: ${program} --cpu-prof run exited ${run.status}\n`);
        failed = true;
      } else {
        profile = profDir;
      }
    }

    const { best, median } = summary(samples);
    const floor = summary(floorSamples).best;
    const best_ms = Number(best.toFixed(2));
    const floor_ms = Number(floor.toFixed(2));
    const line = {
      program,
      variant: options.variant,
      runs: samples.length,
      ops,
      floor_ms,
      best_ms,
      median_ms: Number(median.toFixed(2)),
      // From the ROUNDED pair, so the line is self-checking: a reader can
      // redo the division with the numbers printed beside it.
      ns_per_op: Number(((Math.max(best_ms - floor_ms, 0) * 1e6) / ops).toFixed(1)),
      checksum,
    };
    if (profile !== null) line.cpu_prof_dir = profile;
    lines.push(JSON.stringify(line));
  }

  process.stdout.write(lines.map((line) => `${line}\n`).join(""));
  if (!options.keep) rmSync(work, { recursive: true, force: true });
  else process.stderr.write(`bench/runtime.mjs: build trees left under ${work}\n`);
  process.exit(failed ? 1 : 0);
}

main();
