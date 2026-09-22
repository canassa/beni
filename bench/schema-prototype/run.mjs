#!/usr/bin/env node

import { brotliCompressSync, constants } from "node:zlib";
import { spawn } from "node:child_process";
import {
  access,
  cp,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { measureBrowser } from "./browser.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, "../..");
const platform = join(here, "platform");
const sources = join(here, "src");
const cases = join(here, "cases");
const negatives = join(cases, "negative");
const expectedLabelsPath = join(cases, "expected-labels.json");
const benchmarkExpectedPath = join(cases, "benchmark-expected.json");
const chromePath = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const PROCESS_TIMEOUT_MS = 60000;
const MAX_OUTPUT = 64 * 1024 * 1024;

function parseArgs(argv) {
  const options = {
    beni: join(repo, "zig-out/bin/beni"),
    browser: true,
  };
  for (const argument of argv) {
    if (argument === "--no-browser") options.browser = false;
    else if (argument.startsWith("--beni=")) options.beni = resolve(argument.slice("--beni=".length));
    else throw new Error(`unknown argument ${argument}`);
  }
  return options;
}

function run(executable, args, cwd, timeoutMs = PROCESS_TIMEOUT_MS) {
  return new Promise((resolveRun, reject) => {
    const child = spawn(executable, args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
    const chunks = { stdout: [], stderr: [] };
    const sizes = { stdout: 0, stderr: 0 };
    let timedOut = false;
    const collect = (name, chunk) => {
      sizes[name] += chunk.length;
      if (sizes[name] > MAX_OUTPUT) {
        child.kill("SIGKILL");
        reject(new Error(`${executable} ${name} exceeded ${MAX_OUTPUT} bytes`));
      } else {
        chunks[name].push(chunk);
      }
    };
    child.stdout.on("data", (chunk) => collect("stdout", chunk));
    child.stderr.on("data", (chunk) => collect("stderr", chunk));
    child.once("error", reject);
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGKILL");
    }, timeoutMs);
    child.once("close", (code, signal) => {
      clearTimeout(timer);
      const stdout = Buffer.concat(chunks.stdout).toString("utf8");
      const stderr = Buffer.concat(chunks.stderr).toString("utf8");
      if (timedOut) reject(new Error(`${executable} timed out after ${timeoutMs} ms`));
      else resolveRun({ code, signal, stdout, stderr });
    });
  });
}

const same = (actual, expected, label) => {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) throw new Error(`${label}\nexpected ${e}\nactual   ${a}`);
};

async function files(root, suffix = undefined) {
  const found = [];
  async function walk(directory) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) await walk(path);
      else if (entry.isFile() && (!suffix || entry.name.endsWith(suffix))) found.push(path);
    }
  }
  await walk(root);
  return found.sort();
}

async function copyBeni(from, to, skipNegative = false) {
  for (const path of await files(from, ".beni")) {
    const rel = relative(from, path);
    if (skipNegative && (rel === "negative" || rel.startsWith(`negative/`))) continue;
    const target = join(to, rel);
    await mkdir(dirname(target), { recursive: true });
    await cp(path, target);
  }
}

async function outputMap(root) {
  const map = {};
  for (const path of await files(root)) map[relative(root, path)] = (await readFile(path)).toString("base64");
  return map;
}

async function size(root) {
  const paths = await files(root, ".mjs");
  const parts = [];
  let raw = 0;
  for (const path of paths) {
    const contents = await readFile(path);
    parts.push(contents, Buffer.from("\n"));
    raw += contents.length;
  }
  const bundle = Buffer.concat(parts);
  return {
    files: paths.length,
    raw_bytes: raw,
    brotli_bytes: brotliCompressSync(bundle, {
      params: { [constants.BROTLI_PARAM_QUALITY]: 11 },
    }).length,
  };
}

function assertProbe(result, expectedLabels, label) {
  const duplicates = expectedLabels.filter((item, index) => expectedLabels.indexOf(item) !== index);
  if (duplicates.length !== 0) throw new Error(`expected label list has duplicates: ${duplicates.join(", ")}`);
  const expected = {
    kind: "schema-prototype",
    passed: true,
    count: expectedLabels.length,
    results: expectedLabels.map((item) => ({ label: item, passed: true })),
    fatal: null,
  };
  same(result, expected, `${label} did not report the complete expected result`);
}

async function build(options, project, out, release, jobs) {
  const args = [
    "build",
    `--platform=${platform}`,
    `--out=${out}`,
    `--jobs=${jobs}`,
    ...(release ? ["--release"] : []),
    "source",
  ];
  const built = await run(options.beni, args, project);
  if (built.code !== 0) throw new Error(`build ${release ? "release" : "dev"} jobs=${jobs} failed\n${built.stderr}`);
  if (built.stderr !== "" || built.stdout !== "") {
    throw new Error(`successful build wrote output\nstdout: ${built.stdout}\nstderr: ${built.stderr}`);
  }
}

async function execute(out, project) {
  const executed = await run(process.execPath, [join(out, "_main.mjs")], project);
  if (executed.code !== 0 || executed.stderr !== "") {
    throw new Error(`emitted program failed (${executed.code})\n${executed.stderr}`);
  }
  const lines = executed.stdout.trimEnd().split("\n");
  if (lines.length !== 1) throw new Error(`emitted program must write exactly one JSON line: ${executed.stdout}`);
  return JSON.parse(lines[0]);
}

async function negativeChecks(options, root) {
  try {
    await access(negatives);
  } catch {
    return [];
  }
  const reports = [];
  for (const entry of (await readdir(negatives, { withFileTypes: true })).filter((item) => item.isDirectory()).sort((a, b) => a.name.localeCompare(b.name))) {
    const fixture = join(negatives, entry.name);
    const expectedPath = join(fixture, "expected.diag.json");
    const project = join(root, `negative-${entry.name}`);
    await mkdir(project, { recursive: true });
    await copyBeni(sources, project);
    await copyBeni(fixture, project);
    const result = await run(
      options.beni,
      ["build", `--platform=${platform}`, "--diagnostics=json", "--no-cache", "--out=out", "."],
      project,
    );
    if (result.code !== 1 || result.stdout !== "") {
      throw new Error(`negative ${entry.name} expected exit 1 and empty stdout, got ${result.code}\n${result.stdout}\n${result.stderr}`);
    }
    const actual = JSON.parse(result.stderr);
    const expected = JSON.parse(await readFile(expectedPath, "utf8"));
    same(actual, expected, `negative ${entry.name} diagnostic differs`);
    let emitted = [];
    try {
      emitted = await files(join(project, "out"));
    } catch {}
    if (emitted.length !== 0) throw new Error(`negative ${entry.name} wrote output files`);
    let cached = [];
    try {
      cached = await files(join(project, ".beni-cache"));
    } catch {}
    if (cached.length !== 0) throw new Error(`negative ${entry.name} wrote cache files`);
    reports.push({ name: entry.name, diagnostics: actual.length });
  }
  return reports;
}

async function main() {
  if (Number(process.versions.node.split(".")[0]) !== 24) {
    throw new Error(`schema prototype requires pinned Node 24; got ${process.version}. Run through nix develop.`);
  }
  const options = parseArgs(process.argv.slice(2));
  await access(options.beni);
  const expectedLabels = JSON.parse(await readFile(expectedLabelsPath, "utf8"));
  const benchmarkExpected = JSON.parse(await readFile(benchmarkExpectedPath, "utf8"));
  if (!Array.isArray(expectedLabels) || expectedLabels.some((label) => typeof label !== "string")) {
    throw new Error("cases/expected-labels.json must be an array of strings");
  }
  const root = await mkdtemp(join(tmpdir(), "beni-schema-prototype-"));
  try {
    const project = join(root, "project");
    const source = join(project, "source");
    await mkdir(source, { recursive: true });
    await copyBeni(sources, source);
    await copyBeni(cases, source, true);

    const variants = [];
    for (const release of [false, true]) {
      for (const jobs of [1, 8]) {
        const name = `${release ? "release" : "dev"}-jobs${jobs}`;
        const out = join(project, name);
        await build(options, project, out, release, jobs);
        const result = await execute(out, project);
        assertProbe(result, expectedLabels, name);
        variants.push({ name, release, jobs, out, result, size: await size(out) });
      }
    }
    same(await outputMap(variants[0].out), await outputMap(variants[1].out), "development output differs between jobs=1 and jobs=8");
    same(await outputMap(variants[2].out), await outputMap(variants[3].out), "release output differs between jobs=1 and jobs=8");
    for (const variant of variants.slice(1)) same(variant.result, variants[0].result, `${variant.name} result differs`);

    const negative = await negativeChecks(options, root);
    const browser = [];
    if (options.browser) {
      await access(chromePath);
      for (const variant of [variants[0], variants[2]]) {
        await writeFile(
          join(variant.out, "browser.html"),
          '<!doctype html><meta charset="utf-8"><script type="module">await import("./_main.mjs" + location.search)</script>',
        );
        browser.push({
          mode: variant.release ? "release" : "development",
          ...(await measureBrowser(variant.out, variant.result, { chromePath, benchmarkExpected })),
        });
      }
    }

    const report = {
      environment: {
        node: process.version,
        platform: process.platform,
        architecture: process.arch,
      },
      scenarios: {
        labels: expectedLabels,
        result: variants[0].result,
        variants: variants.map(({ name, size: measured }) => ({ name, ...measured })),
        negative,
      },
      measurement: {
        note: "Browser timings measure Benchmark.run's explicit mixed workload; they are not Effect parity or JSON parsing throughput. Separate per-schema-operation medians remain deferred.",
        browser,
      },
    };
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

await main();
