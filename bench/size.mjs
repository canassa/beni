#!/usr/bin/env node
// Output size — M4 of `plans/static-dispatch-spike.md` §7, against
// `backend.md` §13 ("sizes are tracked after compression: brotli primary,
// gzip secondary, raw as a diagnostic only").
//
// Builds every program of every corpus root with `beni build` and prints a
// `{"floor":…}` line, one JSON line per program, and a `{"total":…}` line:
//
//     {"floor":true,"entry":"Empty","files":5,"raw_bytes":2147, …}
//     {"program":"tests/corpus/run/Adt.beni","entry":"Adt","roots":"main",
//      "files":6,"raw_bytes":3520,"gzip_bytes":1584,"brotli_bytes":1318,
//      "net_raw_bytes":1373,"net_gzip_bytes":294,"net_brotli_bytes":213,
//      "derived_bytes":0,"derived_functions":0}
//     {"total":true,"programs":35,"gross_raw_bytes":…,"release_gross_raw_bytes":…,
//      "floor_once_raw_bytes":…, …}
//
// **The floor, and what it means now that §9 exists.** It is still an EMPTY
// program — a `main` that is `Node.done` — built in the same run and
// reported as the `floor` line, with every program's bytes given NET of it.
// What it MEASURES changed with reachability elimination (`backend.md` §9):
// it used to be the shared tree every program drags in whole, ~65 kB of the
// ~66 kB each one emitted, and it is now **the minimum a program can ship**,
// ~2 kB. So `net_*` is a subtraction against a minimum rather than against
// common code, and **`gross_*` is the number that matters**, because after
// elimination no two programs ship the same tree and the "shared tree
// counted once" arithmetic no longer describes anything.
//
// **Every figure on the total line says which arithmetic it is, because for
// one milestone three of them did not and the line read as if `--release`
// made programs bigger.** The total used to carry `raw_bytes`, `gzip_bytes`
// and `brotli_bytes` — the floor counted ONCE plus each program's net — next
// to `release_raw_bytes`, `release_gzip_bytes` and `release_brotli_bytes`,
// which were plain gross sums with the floor in them 35 times over. The two
// are not comparable, and the obvious comparison of the two is backwards;
// `plans/state-of-the-compiler.md` §4 had to warn its reader off it in
// prose. So the netted trio is now `floor_once_*` and the release column is
// `release_gross_*`, and the pair to divide is `gross_*` against
// `release_gross_*` — the same arithmetic on both sides, which is the only
// thing a ratio may be taken of. Program lines are unchanged: there
// `raw_bytes` and `release_raw_bytes` are both one whole tree already.
//
// Net compressed bytes are a subtraction, not a separate compression, so
// that the totals add up; a program's own bytes compress against the
// floor's dictionary, which is exactly how they would ship.
//
// **`roots` on every program line says which §9 root rule built it** —
// `"main"` for a program, `"library"` for a corpus root that declares none
// and is built behind a synthesised entry with `--library`. The rule is not
// a detail: under `main`-only roots `bench/corpus` keeps 1 declaration of
// 336 and the line stops meaning anything.
//
// Compressed size is measured over the CONCATENATION of the emitted files in
// sorted path order, not over the sum of per-file compressions, because what
// a page downloads is one bundle and per-file gzip counts every repeated
// identifier once per file. Node 24 has `zlib.brotliCompressSync` built in,
// so nothing new is pinned (§2, "Harness").
//
// `derived_bytes` is the part of the output attributable to DERIVED `eq` and
// `compare` functions, which is the "grows per type x method" row of report
// 18 §1.5, and §9's acceptance number: **0 on the floor and on any program
// that uses no `==` and no `compare`**. The names it looks for are exactly
// the ones §8.5 prints — see `derivedKind` below, which matches them by
// spelling and no longer needs a list of hand-written exceptions.
//
// The same walk also reports the SPLIT — `eq_functions`/`eq_bytes`,
// `compare_functions`/`compare_bytes`, `order_tables`/`order_bytes` — on the
// floor line, on every program line and on the total. §11 and A.38 require
// the per-method cost as separate numbers and never as a sum: a derived
// `compare` is lexicographic with an early return where a derived `eq` is a
// chain of `&&` (§9), and an `$order` table is a constructor-index table with
// no `eq` counterpart at all. The three counts add to `derived_functions` and
// the three byte figures add to `derived_bytes` by construction, which is what
// the `build_test` scenario asserts.
//
// A corpus root whose modules declare no `main : Program` (bench/corpus is
// one) cannot be built on its own, so the script synthesises a `BenchMain`
// that imports every module of the root the compiler can take and builds
// THAT; the modules it had to drop are listed on the line. Today that is
// `JsonCodecs` and `NotesApp`, which import a `Json.Decode` and an `Html`
// that do not exist. `Data/Parser` and `ExprParser` were on that list until
// `?` was emitted (`backend.md` §4) and are measured now.
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
  --dev-only          skip the --release column (halves the run)
  --keep              leave the temporary build trees on disk
  --help              print this

Prints one JSON line per program and one {"total":…} line, in sorted order.

Every tree is built TWICE by default, once as a development build and once
with \`--release\`, and both are measured in the same run — \`backend.md\` §9's
acceptance asks for that, so that a size claim is never a comparison against a
remembered number from a different binary. The release figures ride on the
same line under \`release_raw_bytes\`, \`release_gzip_bytes\` and
\`release_brotli_bytes\`; the derived-code split is a dev-only figure, because
it reads declarations by NAME and §9 item 2 has taken the names away.

On the {"total":…} line the release column is summed GROSS and named
\`release_gross_*\`, beside the dev \`gross_*\` it may be divided by. The
floor-counted-once arithmetic is there too, named \`floor_once_*\` so that it
cannot be mistaken for a gross sum.`;

function fail(message) {
  process.stderr.write(`bench/size.mjs: ${message}\n`);
  process.exit(2);
}

function parseArgs(argv) {
  const options = { beni: "./zig-out/bin/beni", corpora: [], keep: false, release: true };
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
      case "--dev-only":
        options.release = false;
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

const declared = /^(?:export\s+)?(?:const|let|var|function\*?)\s+([A-Za-z_$][\w$]*)/;

/// §8.5's names, matched EXACTLY rather than by family resemblance. A
/// printed name is `<module path with `.` as `$`>$<base>`, and a derived
/// declaration's base is one of:
///
///   - `<Type>$$eq` / `<Type>$$compare` for a nominal type, and
///     `<Type>$$order` for its §9.4 tag table. The separator is DOUBLE, and
///     that is the whole of why the name cannot collide (A.61): a beni
///     identifier holds no `$` and a module path has no empty segment, so
///     the empty segment between the two `$` is unspellable by a user.
///   - `eq$r$<f1>$<f2>…` / `compare$r$…` for a record shape, `eq$t<n>` /
///     `compare$t<n>` for a tuple, `eq$unit` / `compare$unit` for `()`.
///   - `eq$prim`, `compare$prim`, `compare$char` — §9.1's comparators.
///
/// **The old matcher was `\$(eq|compare|order)(\$|$)` and it was wrong in
/// both directions.** It charged a user's own `pub eq` to derivation —
/// `tests/corpus/run/UserEquality.beni` declares one, and it prints as
/// `UserEquality$eq`, exactly that shape — and it needed an explicit list of
/// nine hand-written core values (`Basics$compare`, `String$compare`,
/// `List$eq`, …) to stop claiming those as well. The double separator and
/// the enumerated structural suffixes tell the two apart by SPELLING, so
/// the list goes with the guesswork: nothing core writes by hand matches,
/// and nothing a user can spell matches either.
const nominal_derived = /\$\$(eq|compare|order)$/;
const structural_derived = /\$(eq|compare)\$(?:r(?:\$[A-Za-z_]\w*)*|t\d+|unit|prim)$/;
const char_comparator = /\$compare\$char$/;
/// `backend.md` §4, *Derived comparisons do not grow the native stack*: a
/// derived function that passes a depth has a `function* <base>$$steps` twin,
/// charged to its own function's kind, and its module one `derived$deep`
/// engine, charged to `engine` — a fourth kind, so the split stays a
/// partition of `derived_bytes`.
const steps_twin = /\$\$steps$/;
const deep_engine = /\$derived\$deep$/;

/// `null` if the name is not a derived one; otherwise which of the four
/// spellings it is — `eq`, `compare`, `order` or `engine`.
function derivedKind(name) {
  if (deep_engine.test(name)) return "engine";
  if (steps_twin.test(name)) return derivedKind(name.replace(steps_twin, ""));
  const nominal = name.match(nominal_derived);
  if (nominal !== null) return nominal[1];
  if (char_comparator.test(name)) return "compare";
  const structural = name.match(structural_derived);
  return structural === null ? null : structural[1];
}

function measureTree(outDir) {
  const files = filesUnder(outDir, ".mjs");
  let raw = 0;
  let derivedBytes = 0;
  let derivedFunctions = 0;
  // §11 and A.38 require the per-method split to be reported as separate
  // numbers and never as a sum: a derived `compare` is a different shape of
  // code from a derived `eq` (§9, lexicographic with early return against a
  // chain of `&&`), and an `$order` table has no `eq` counterpart at all.
  const split = { eq: { n: 0, bytes: 0 }, compare: { n: 0, bytes: 0 }, order: { n: 0, bytes: 0 }, engine: { n: 0, bytes: 0 } };
  const chunks = [];
  for (const rel of files) {
    const bytes = readFileSync(join(outDir, rel));
    raw += bytes.length;
    chunks.push(bytes);
    const text = bytes.toString("utf8");
    for (const statement of topLevelStatements(text)) {
      const match = statement.match(declared);
      if (match === null) continue;
      const kind = derivedKind(match[1]);
      if (kind === null) continue;
      const size = Buffer.byteLength(statement, "utf8");
      derivedFunctions += 1;
      derivedBytes += size;
      split[kind].n += 1;
      split[kind].bytes += size;
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
    eq_functions: split.eq.n,
    eq_bytes: split.eq.bytes,
    compare_functions: split.compare.n,
    compare_bytes: split.compare.bytes,
    order_tables: split.order.n,
    order_bytes: split.order.bytes,
    engines: split.engine.n,
    engine_bytes: split.engine.bytes,
  };
}

/// Build one project. Each program gets a project of its own, because two of
/// them in one tree would each pull the other's modules into `out/`.
///
/// `library` passes `--library`, which makes every exported name of the
/// root package a reachability root instead of `main` (`backend.md` §2,
/// §9). A corpus root that declares no `main` IS a library, and under
/// `main`-only roots elimination would keep 1 declaration of 336 and the
/// line would stop measuring anything.
/// `release` passes `--release` and writes to `out-release/`, so the two
/// builds of one project cannot read each other's output.
///
/// It also passes `--allow-debug`, the hidden test-only flag: since
/// 2026-09-19 a `--release` build that reaches `Debug` is refused
/// (`backend.md` §9's *`Debug` is refused, not pinned*), and 24 of the 121
/// programs under the default corpus `tests/corpus/run` use `Debug.log` as
/// their instrument for evaluation order. Without the flag the release
/// column would simply stop existing for a fifth of the table, which is a
/// worse answer than measuring the bytes those programs actually emit.
function buildProject(beni, work, projectDir, sources, library = false, release = false) {
  const projectRel = relative(work, projectDir).split(sep).join("/");
  const out = release ? "out-release" : "out";
  rmSync(join(projectDir, out), { recursive: true, force: true });
  return runBeni(
    beni,
    [
      "build",
      "--platform=node",
      "--diagnostics=json",
      `--out=${projectRel}/${out}`,
      `--root=${projectRel}`,
      ...(library ? ["--library"] : []),
      ...(release ? ["--release", "--allow-debug"] : []),
      ...sources.map((s) => `${projectRel}/${s}`),
    ],
    work,
  );
}

/// The release half of one already-built project: the same sources with
/// `--release`, or null when the column is off. A failure here is loud — a
/// tree that builds in dev and not in release is the finding, not a hole in
/// the table.
function measureRelease(options, beni, work, projectDir, sources, library) {
  if (!options.release) return null;
  const run = buildProject(beni, work, projectDir, sources, library, true);
  if (run.status !== 0) {
    process.stderr.write(
      `bench/size.mjs: --release build of ${projectDir} failed\n${run.stdout ?? ""}${run.stderr ?? ""}\n`,
    );
    return null;
  }
  const measured = measureTree(join(projectDir, "out-release"));
  return {
    release_files: measured.files,
    release_raw_bytes: measured.raw_bytes,
    release_gzip_bytes: measured.gzip_bytes,
    release_brotli_bytes: measured.brotli_bytes,
  };
}

/// The shared tree every program carries: core and the platform, reached by a
/// `main` that does nothing. Built by the same compiler, in the same run, so
/// the subtraction is against this binary's core and not a remembered number.
function measureFloor(options, beni, work) {
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
  return {
    ...measureTree(join(projectDir, "out")),
    ...(measureRelease(options, beni, work, projectDir, ["Empty.beni"], false) ?? {}),
  };
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  const beni = resolve(options.beni);
  const work = mkdtempSync(join(tmpdir(), "beni-size-"));
  const lines = [];
  let failed = false;

  const floor = measureFloor(options, beni, work);
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
      ...(floor.release_raw_bytes === undefined ? {} : {
        release_files: floor.release_files,
        release_raw_bytes: floor.release_raw_bytes,
        release_gzip_bytes: floor.release_gzip_bytes,
        release_brotli_bytes: floor.release_brotli_bytes,
      }),
      derived_bytes: floor.derived_bytes,
      derived_functions: floor.derived_functions,
      eq_functions: floor.eq_functions,
      eq_bytes: floor.eq_bytes,
      compare_functions: floor.compare_functions,
      compare_bytes: floor.compare_bytes,
      order_tables: floor.order_tables,
      order_bytes: floor.order_bytes,
      engines: floor.engines,
      engine_bytes: floor.engine_bytes,
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
    release_gross_raw_bytes: 0,
    release_gross_gzip_bytes: 0,
    release_gross_brotli_bytes: 0,
    derived_bytes: 0,
    derived_functions: 0,
    eq_functions: 0,
    eq_bytes: 0,
    compare_functions: 0,
    compare_bytes: 0,
    order_tables: 0,
    order_bytes: 0,
    engines: 0,
    engine_bytes: 0,
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
    total.release_gross_raw_bytes += measured.release_raw_bytes ?? 0;
    total.release_gross_gzip_bytes += measured.release_gzip_bytes ?? 0;
    total.release_gross_brotli_bytes += measured.release_brotli_bytes ?? 0;
    total.gross_raw_bytes += measured.raw_bytes;
    total.gross_gzip_bytes += measured.gzip_bytes;
    total.gross_brotli_bytes += measured.brotli_bytes;
    total.net_raw_bytes += net.net_raw_bytes;
    total.net_gzip_bytes += net.net_gzip_bytes;
    total.net_brotli_bytes += net.net_brotli_bytes;
    total.derived_bytes += measured.derived_bytes;
    total.derived_functions += measured.derived_functions;
    total.eq_functions += measured.eq_functions;
    total.eq_bytes += measured.eq_bytes;
    total.compare_functions += measured.compare_functions;
    total.compare_bytes += measured.compare_bytes;
    total.order_tables += measured.order_tables;
    total.order_bytes += measured.order_bytes;
    total.engines += measured.engines;
    total.engine_bytes += measured.engine_bytes;
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
    // A root whose modules declare `main` is measured as the PROGRAMS it
    // holds, rooted at `main`; a root that declares none is a library and
    // is measured as one. `library` says which, and it is recorded on the
    // line, because after §9 the rule is the difference between measuring a
    // library and measuring one declaration.
    const build = (projectDir, sources, library) => buildProject(beni, work, projectDir, sources, library);

    if (programs.length !== 0) {
      for (const program of programs) {
        const projectDir = join(work, `${corpus.replace(/[^\w]/g, "_")}__${program.replace(/[^\w]/g, "_")}`);
        mkdirSync(join(projectDir, dirname(program) === "." ? "" : dirname(program)), { recursive: true });
        cpSync(join(root, program), join(projectDir, program));
        const run = build(projectDir, [program], false);
        if (run.status !== 0) {
          process.stderr.write(
            `bench/size.mjs: ${corpus}/${program} did not build\n${run.stdout ?? ""}${run.stderr ?? ""}\n`,
          );
          failed = true;
          continue;
        }
        record(
          { program: `${corpus}/${program}`, entry: moduleNameOf(program), roots: "main" },
          {
            ...measureTree(join(projectDir, "out")),
            ...(measureRelease(options, beni, work, projectDir, [program], false) ?? {}),
          },
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
    // because dropping one can break its dependents. `?` was the common
    // cause until M3b emitted it; what is left is a module naming a package
    // that does not exist, and that is a fact about this milestone that
    // belongs on the line rather than in a crash.
    let kept = [...modules];
    let ok = false;
    for (let round = 0; round <= modules.length && kept.length !== 0; round++) {
      writeEntry(kept);
      const run = build(projectDir, [entry, ...kept], true);
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
        roots: "library",
        modules_measured: kept.length,
        modules_excluded: dropped,
      },
      {
        ...measureTree(join(projectDir, "out")),
        ...(measureRelease(options, beni, work, projectDir, [entry, ...kept], true) ?? {}),
      },
    );
  }

  lines.push(
    JSON.stringify({
      total: true,
      programs: total.programs,
      files: total.files,
      // The shared tree counted ONCE, plus what each program adds to it.
      // Named for the arithmetic and not `raw_bytes`, because a bare
      // `raw_bytes` here reads as the sum of the program lines' and is not.
      floor_once_raw_bytes: floor.raw_bytes + total.net_raw_bytes,
      floor_once_gzip_bytes: floor.gzip_bytes + total.net_gzip_bytes,
      floor_once_brotli_bytes: floor.brotli_bytes + total.net_brotli_bytes,
      floor_raw_bytes: floor.raw_bytes,
      floor_gzip_bytes: floor.gzip_bytes,
      floor_brotli_bytes: floor.brotli_bytes,
      net_raw_bytes: total.net_raw_bytes,
      net_gzip_bytes: total.net_gzip_bytes,
      net_brotli_bytes: total.net_brotli_bytes,
      // Every program's whole tree added up: the floor N times over, which
      // is the only sum a release sum may be divided by.
      gross_raw_bytes: total.gross_raw_bytes,
      gross_gzip_bytes: total.gross_gzip_bytes,
      gross_brotli_bytes: total.gross_brotli_bytes,
      // The release column, summed exactly the way `gross_*` is and named
      // so: every program's whole tree, so the pair is like for like.
      ...(options.release ? {
        release_gross_raw_bytes: total.release_gross_raw_bytes,
        release_gross_gzip_bytes: total.release_gross_gzip_bytes,
        release_gross_brotli_bytes: total.release_gross_brotli_bytes,
      } : {}),
      derived_bytes: total.derived_bytes,
      derived_functions: total.derived_functions,
      eq_functions: total.eq_functions,
      eq_bytes: total.eq_bytes,
      compare_functions: total.compare_functions,
      compare_bytes: total.compare_bytes,
      order_tables: total.order_tables,
      order_bytes: total.order_bytes,
      engines: total.engines,
      engine_bytes: total.engine_bytes,
    }),
  );
  process.stdout.write(lines.map((line) => `${line}\n`).join(""));
  if (!options.keep) rmSync(work, { recursive: true, force: true });
  else process.stderr.write(`bench/size.mjs: build trees left under ${work}\n`);
  process.exit(failed ? 1 : 0);
}

main();
