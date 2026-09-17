#!/usr/bin/env node
// Output size — M4 of `plans/static-dispatch-spike.md` §7, against
// `backend.md` §13 ("sizes are tracked after compression: brotli primary,
// gzip secondary, raw as a diagnostic only").
//
// Builds every program of every corpus root with `beni build` and prints a
// `{"floor":…}` line, one JSON line per program, and a `{"total":…}` line:
//
//     {"floor":true,"entry":"Empty","files":20,"raw_bytes":65111, …}
//     {"program":"tests/corpus/run/Adt.beni","files":21,"raw_bytes":66350,
//      "gzip_bytes":15694,"brotli_bytes":13196,
//      "net_raw_bytes":1239,"net_gzip_bytes":294,"net_brotli_bytes":213,
//      "derived_bytes":0,"derived_functions":0}
//     {"total":true,"programs":35,"raw_bytes":…,"gross_raw_bytes":…, …}
//
// **The floor.** Every program drags in the whole of `core/` and the
// platform, because there is no dead-code elimination yet (§11, "No DCE").
// On the `run/` corpus that shared tree is ~65 kB of the ~66 kB each program
// emits, so a gross total over 34 programs is 34 copies of one number and
// says nothing about any of them. The script therefore builds an EMPTY
// program — a `main` that is `Node.done` — in the same run, reports it as
// the `floor` line, and gives every program its bytes NET of that floor.
// The total counts the shared tree ONCE plus the net of each program, and
// keeps the gross sums beside it as `gross_*`. Net compressed bytes are a
// subtraction, not a separate compression, so that the totals add up; a
// program's own bytes compress against the floor's dictionary, which is
// exactly how they would ship.
//
// Compressed size is measured over the CONCATENATION of the emitted files in
// sorted path order, not over the sum of per-file compressions, because what
// a page downloads is one bundle and per-file gzip counts every repeated
// identifier once per file. Node 24 has `zlib.brotliCompressSync` built in,
// so nothing new is pinned (§2, "Harness").
//
// `derived_bytes` is the part of the output attributable to DERIVED `eq` and
// `compare` functions, which is the "grows per type x method" row of report
// 18 §1.5. It is **0 today** — nothing derives anything yet — and the names
// it looks for are the ones the spec prints (§8.5): a derived function is an
// ordinary module-level `const` spelled `Module$base`, with `base` one of
// `<T>$eq`, `<T>$compare`, `<T>$order`, `eq$r$<fields>`, `eq$t<n>`,
// `eq$unit`, `eq$prim`, `compare$prim`, `compare$char`. Hand-written core
// values that happen to share the shape (`Basics$compare`, `String$compare`,
// `List$eq`, …) are excluded by an explicit list, never by name shape, which
// is what makes the number 0 on `master` rather than a handful.
//
// A corpus root whose modules declare no `main : Program` (bench/corpus is
// one) cannot be built on its own, so the script synthesises a `BenchMain`
// that imports every module of the root the compiler can take and builds
// THAT; the modules it had to drop are listed on the line. Today that is
// `Data/Parser` and `ExprParser`, which use `?` (the back end grows it in
// M3b, `backend.md` §1), and `JsonCodecs` and `NotesApp`, which import a
// `Json.Decode` and an `Html` that do not exist.
//
// Output order: corpus roots sorted, then programs sorted within each root.

import { spawnSync } from "node:child_process";
import {
  cpSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, relative, resolve, sep } from "node:path";
import { tmpdir } from "node:os";
import { brotliCompressSync, constants, gzipSync } from "node:zlib";
import process from "node:process";

const usage = `usage: node bench/size.mjs [options]

  --beni=<path>       compiler to run (default ./zig-out/bin/beni)
  --corpus=<path>     a corpus root; repeatable
                      (default: tests/corpus/run and bench/corpus)
  --keep              leave the temporary build trees on disk
  --help              print this

Prints one JSON line per program and one {"total":…} line, in sorted order.`;

function fail(message) {
  process.stderr.write(`bench/size.mjs: ${message}\n`);
  process.exit(2);
}

function parseArgs(argv) {
  const options = { beni: "./zig-out/bin/beni", corpora: [], keep: false };
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
      case "--corpus":
        options.corpora.push(value);
        break;
      case "--keep":
        options.keep = true;
        break;
      default:
        fail(`unknown option ${name}\n\n${usage}`);
    }
  }
  if (options.corpora.length === 0) options.corpora = ["tests/corpus/run", "bench/corpus"];
  return options;
}

/// Every file under `root` matching `ext`, as `/`-separated paths relative to
/// it, sorted. Sorted because the whole script's output order rests on it.
function filesUnder(root, ext) {
  const out = [];
  const walk = (dir) => {
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.isFile() && entry.name.endsWith(ext)) out.push(relative(root, full).split(sep).join("/"));
    }
  };
  walk(root);
  return out.sort();
}

/// A module that declares `main : …` at column 0 is a program of its own.
function declaresMain(source) {
  return /^main\s*:/m.test(source);
}

/// The module name a path maps to (`language.md` §1): `Data/Parser.beni` is
/// `Data.Parser`.
function moduleNameOf(relPath) {
  return relPath.replace(/\.beni$/, "").split("/").join(".");
}

function runBeni(beni, args, cwd) {
  return spawnSync(beni, args, { cwd, encoding: "utf8" });
}

/// The files a JSON diagnostics stream blames, as paths relative to the
/// project.
function blamedFiles(stderr, projectRel) {
  let diagnostics;
  try {
    diagnostics = JSON.parse((stderr ?? "").trim() || "[]");
  } catch {
    return null;
  }
  const broken = new Set();
  for (const d of diagnostics) {
    if (d.severity !== "error") continue;
    const file = d.span?.file ?? "";
    broken.add(file.startsWith(`${projectRel}/`) ? file.slice(projectRel.length + 1) : file);
  }
  return broken;
}

/// Split one emitted `.mjs` file into top-level statements, so a derived
/// function can be charged the bytes of its whole declaration. The emitter
/// writes every top-level declaration starting at column 0 and indents
/// everything inside it, so "a line that starts with a non-space" is exactly
/// the statement boundary (`backend.md` §4; `src/js/Print.zig`).
function topLevelStatements(text) {
  const lines = text.split("\n");
  const statements = [];
  let start = 0;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (i !== 0 && line.length !== 0 && !/^\s/.test(line)) {
      statements.push(lines.slice(start, i).join("\n"));
      start = i;
    }
  }
  statements.push(lines.slice(start).join("\n"));
  return statements;
}

const declared = /^(?:export\s+)?(?:const|let|var|function)\s+([A-Za-z_$][\w$]*)/;

/// §8.5 prints every derived function as `Module$base`, where `base` is one
/// of `<T>$eq`, `<T>$compare`, `<T>$order`, `eq$r$<f1>$<f2>$…`, `eq$t<n>`,
/// `eq$unit`, `eq$prim`, `compare$prim`, `compare$char` — so the printed
/// names are `Shapes$Shape$eq`, `Shapes$Colour$order`, `Main$eq$r$x$y`,
/// `Main$compare$t2`, `Main$eq$unit`, `Main$compare$prim`. What they have in
/// common is a `$eq`, `$compare` or `$order` segment that is followed by `$`
/// or by the end of the name.
const derived_shape = /^[A-Za-z_$][\w$]*\$(eq|compare|order)(\$|$)/;

/// Values core writes BY HAND that the shape above would otherwise claim.
/// An explicit list, because there is no spelling that separates
/// `Basics$compare` (a real beni function) or `String$compare` (a real
/// foreign) from a derived one — §9.1 even routes `String`'s `compare` to
/// the hand-written core function on purpose.
const hand_written = new Set([
  "Basics$eq",
  "Basics$neq",
  "Basics$compare",
  "String$eq",
  "String$compare",
  "Char$eq",
  "Char$compare",
  "List$eq",
  "List$compare",
]);

function isDerivedName(name) {
  if (hand_written.has(name)) return false;
  return derived_shape.test(name);
}

function measureTree(outDir) {
  const files = filesUnder(outDir, ".mjs");
  let raw = 0;
  let derivedBytes = 0;
  let derivedFunctions = 0;
  const chunks = [];
  for (const rel of files) {
    const bytes = readFileSync(join(outDir, rel));
    raw += bytes.length;
    chunks.push(bytes);
    const text = bytes.toString("utf8");
    for (const statement of topLevelStatements(text)) {
      const match = statement.match(declared);
      if (match === null) continue;
      if (!isDerivedName(match[1])) continue;
      derivedFunctions += 1;
      derivedBytes += Buffer.byteLength(statement, "utf8");
    }
  }
  const bundle = Buffer.concat(chunks);
  return {
    files: files.length,
    raw_bytes: raw,
    gzip_bytes: gzipSync(bundle, { level: 9 }).length,
    brotli_bytes: brotliCompressSync(bundle, {
      params: { [constants.BROTLI_PARAM_QUALITY]: 11, [constants.BROTLI_PARAM_SIZE_HINT]: bundle.length },
    }).length,
    derived_bytes: derivedBytes,
    derived_functions: derivedFunctions,
  };
}

/// Build one project. Each program gets a project of its own, because two of
/// them in one tree would each pull the other's modules into `out/`.
function buildProject(beni, work, projectDir, sources) {
  const projectRel = relative(work, projectDir).split(sep).join("/");
  rmSync(join(projectDir, "out"), { recursive: true, force: true });
  return runBeni(
    beni,
    [
      "build",
      "--platform=node",
      "--diagnostics=json",
      `--out=${projectRel}/out`,
      `--root=${projectRel}`,
      ...sources.map((s) => `${projectRel}/${s}`),
    ],
    work,
  );
}

/// The shared tree every program carries: core and the platform, reached by a
/// `main` that does nothing. Built by the same compiler, in the same run, so
/// the subtraction is against this binary's core and not a remembered number.
function measureFloor(beni, work) {
  const projectDir = join(work, "__floor");
  mkdirSync(projectDir, { recursive: true });
  writeFileSync(
    join(projectDir, "Empty.beni"),
    "import Node exposing (Program)\n\n\nmain : Program\nmain =\n    Node.done\n",
  );
  const run = buildProject(beni, work, projectDir, ["Empty.beni"]);
  if (run.status !== 0) {
    process.stderr.write(`bench/size.mjs: the empty program did not build\n${run.stdout ?? ""}${run.stderr ?? ""}\n`);
    return null;
  }
  return measureTree(join(projectDir, "out"));
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const beni = resolve(options.beni);
  const work = mkdtempSync(join(tmpdir(), "beni-size-"));
  const lines = [];
  let failed = false;

  const floor = measureFloor(beni, work);
  if (floor === null) {
    rmSync(work, { recursive: true, force: true });
    process.exit(1);
  }
  lines.push(
    JSON.stringify({
      floor: true,
      entry: "Empty",
      files: floor.files,
      raw_bytes: floor.raw_bytes,
      gzip_bytes: floor.gzip_bytes,
      brotli_bytes: floor.brotli_bytes,
      derived_bytes: floor.derived_bytes,
      derived_functions: floor.derived_functions,
    }),
  );

  const total = {
    programs: 0,
    files: 0,
    net_raw_bytes: 0,
    net_gzip_bytes: 0,
    net_brotli_bytes: 0,
    gross_raw_bytes: 0,
    gross_gzip_bytes: 0,
    gross_brotli_bytes: 0,
    derived_bytes: 0,
    derived_functions: 0,
  };

  /// One program's line, and its contribution to the totals.
  const record = (fields, measured) => {
    const net = {
      net_raw_bytes: measured.raw_bytes - floor.raw_bytes,
      net_gzip_bytes: measured.gzip_bytes - floor.gzip_bytes,
      net_brotli_bytes: measured.brotli_bytes - floor.brotli_bytes,
    };
    lines.push(JSON.stringify({ ...fields, ...measured, ...net }));
    total.programs += 1;
    total.files += measured.files;
    total.gross_raw_bytes += measured.raw_bytes;
    total.gross_gzip_bytes += measured.gzip_bytes;
    total.gross_brotli_bytes += measured.brotli_bytes;
    total.net_raw_bytes += net.net_raw_bytes;
    total.net_gzip_bytes += net.net_gzip_bytes;
    total.net_brotli_bytes += net.net_brotli_bytes;
    total.derived_bytes += measured.derived_bytes;
    total.derived_functions += measured.derived_functions;
  };

  for (const corpus of [...options.corpora].sort()) {
    const root = resolve(corpus);
    try {
      if (!statSync(root).isDirectory()) fail(`${corpus} is not a directory`);
    } catch {
      fail(`cannot read ${corpus}`);
    }
    const modules = filesUnder(root, ".beni");
    if (modules.length === 0) {
      lines.push(JSON.stringify({ program: corpus, status: "skipped", reason: "no .beni files" }));
      continue;
    }

    const programs = modules.filter((m) => declaresMain(readFileSync(join(root, m), "utf8")));
    const build = (projectDir, sources) => buildProject(beni, work, projectDir, sources);

    if (programs.length !== 0) {
      for (const program of programs) {
        const projectDir = join(work, `${corpus.replace(/[^\w]/g, "_")}__${program.replace(/[^\w]/g, "_")}`);
        mkdirSync(join(projectDir, dirname(program) === "." ? "" : dirname(program)), { recursive: true });
        cpSync(join(root, program), join(projectDir, program));
        const run = build(projectDir, [program]);
        if (run.status !== 0) {
          process.stderr.write(
            `bench/size.mjs: ${corpus}/${program} did not build\n${run.stdout ?? ""}${run.stderr ?? ""}\n`,
          );
          failed = true;
          continue;
        }
        record(
          { program: `${corpus}/${program}`, entry: moduleNameOf(program) },
          measureTree(join(projectDir, "out")),
        );
      }
      continue;
    }

    // No `main` anywhere: the whole root is one program behind a synthesised
    // entry point.
    const projectDir = join(work, `${corpus.replace(/[^\w]/g, "_")}__all`);
    for (const module of modules) {
      const target = join(projectDir, module);
      mkdirSync(dirname(target), { recursive: true });
      cpSync(join(root, module), target);
    }
    const projectRel = relative(work, projectDir).split(sep).join("/");
    const entry = "BenchMain.beni";
    const writeEntry = (kept) => {
      const imports = kept.map((m) => `import ${moduleNameOf(m)}`).join("\n");
      writeFileSync(
        join(projectDir, entry),
        `import Node exposing (Program)\n${imports}\n\n\nmain : Program\nmain =\n    Node.print "size"\n`,
      );
    };

    // A module the BACK END cannot compile is dropped and the rest rebuilt,
    // because dropping one can break its dependents. Today `?` is the common
    // cause (`backend.md` §1, M3b), and that is a fact about this milestone
    // that belongs on the line rather than in a crash.
    let kept = [...modules];
    let ok = false;
    for (let round = 0; round <= modules.length && kept.length !== 0; round++) {
      writeEntry(kept);
      const run = build(projectDir, [entry, ...kept]);
      if (run.status === 0) {
        ok = true;
        break;
      }
      const broken = blamedFiles(run.stderr, projectRel);
      if (broken === null) {
        process.stderr.write(`bench/size.mjs: ${corpus} build stderr is not JSON\n${run.stderr ?? ""}\n`);
        failed = true;
        break;
      }
      broken.delete(entry);
      if (broken.size === 0) break;
      kept = kept.filter((m) => !broken.has(m));
    }
    const dropped = modules.filter((m) => !kept.includes(m));
    if (!ok) {
      lines.push(
        JSON.stringify({
          program: corpus,
          status: "skipped",
          reason: "no module of this root builds, and none declares `main : Program`",
          modules_excluded: modules,
        }),
      );
      continue;
    }
    record(
      {
        program: corpus,
        entry: "BenchMain (synthesised)",
        modules_measured: kept.length,
        modules_excluded: dropped,
      },
      measureTree(join(projectDir, "out")),
    );
  }

  lines.push(
    JSON.stringify({
      total: true,
      programs: total.programs,
      files: total.files,
      // The shared tree counted once, plus what each program adds to it.
      raw_bytes: floor.raw_bytes + total.net_raw_bytes,
      gzip_bytes: floor.gzip_bytes + total.net_gzip_bytes,
      brotli_bytes: floor.brotli_bytes + total.net_brotli_bytes,
      floor_raw_bytes: floor.raw_bytes,
      floor_gzip_bytes: floor.gzip_bytes,
      floor_brotli_bytes: floor.brotli_bytes,
      net_raw_bytes: total.net_raw_bytes,
      net_gzip_bytes: total.net_gzip_bytes,
      net_brotli_bytes: total.net_brotli_bytes,
      // Every program's whole tree added up: the shared bytes N times over,
      // which is what a per-program sum means when there is no DCE.
      gross_raw_bytes: total.gross_raw_bytes,
      gross_gzip_bytes: total.gross_gzip_bytes,
      gross_brotli_bytes: total.gross_brotli_bytes,
      derived_bytes: total.derived_bytes,
      derived_functions: total.derived_functions,
    }),
  );
  process.stdout.write(lines.map((line) => `${line}\n`).join(""));
  if (!options.keep) rmSync(work, { recursive: true, force: true });
  else process.stderr.write(`bench/size.mjs: build trees left under ${work}\n`);
  process.exit(failed ? 1 : 0);
}

main();
