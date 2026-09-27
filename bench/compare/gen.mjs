// Generates an N-copy project for one language from the ports in this
// directory. Each copy is the three programs (interpreter, red-black tree,
// data transformation) as three modules renamed App<k>Interp, App<k>Tree and
// App<k>Data; one Main imports every copy and concatenates their `run`
// results. Copies are separate modules, never pasted into one file.
//
//   node gen.mjs <lang> <N> <outdir>
//
// <lang> is beni, elm, gleam, roc or purescript.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const HERE = path.dirname(fileURLToPath(import.meta.url));
export const LANGS = ["beni", "elm", "gleam", "roc", "purescript"];
export const PROGRAMS = ["Interp", "Tree", "Data"];

// Where each port's three program files live, relative to HERE.
export function portFile(lang, program) {
  switch (lang) {
    case "beni":
      return path.join(HERE, "beni", `${program}.beni`);
    case "elm":
      return path.join(HERE, "elm", "src", `${program}.elm`);
    case "gleam":
      return path.join(HERE, "gleam", "src", `${program.toLowerCase()}.gleam`);
    case "roc":
      return path.join(HERE, "roc", `${program}.roc`);
    case "purescript":
      return path.join(HERE, "purescript", "src", `${program}.purs`);
  }
  throw new Error(`unknown language ${lang}`);
}

const copyName = (k, program) => `App${k}${program}`;
const gleamName = (k, program) => `app${k}_${program.toLowerCase()}`;

function write(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text);
}

function copies(n) {
  const out = [];
  for (let k = 1; k <= n; k++) for (const p of PROGRAMS) out.push([k, p]);
  return out;
}

export function generate(lang, n, outDir) {
  fs.rmSync(outDir, { recursive: true, force: true });
  fs.mkdirSync(outDir, { recursive: true });
  const source = Object.fromEntries(
    PROGRAMS.map((p) => [p, fs.readFileSync(portFile(lang, p), "utf8")]),
  );
  const all = copies(n);

  if (lang === "beni") {
    // The module name is the file's path; the source is unchanged.
    for (const [k, p] of all) write(path.join(outDir, `${copyName(k, p)}.beni`), source[p]);
    const imports = all.map(([k, p]) => `import ${copyName(k, p)}\n`).join("");
    const items = all.map(([k, p]) => `${copyName(k, p)}.run`).join("\n            , ");
    write(
      path.join(outDir, "Main.beni"),
      `${imports}import Node exposing (Program)\n\n\nmain : Program\nmain =\n    Node.printLines\n        (List.concat\n            [ ${items}\n            ]\n        )\n`,
    );
  } else if (lang === "elm") {
    fs.copyFileSync(path.join(HERE, "elm", "elm.json"), path.join(outDir, "elm.json"));
    for (const [k, p] of all) {
      const text = source[p].replace(
        new RegExp(`^module ${p} exposing`, "m"),
        `module ${copyName(k, p)} exposing`,
      );
      write(path.join(outDir, "src", `${copyName(k, p)}.elm`), text);
    }
    const imports = all.map(([k, p]) => `import ${copyName(k, p)}\n`).join("");
    const items = all.map(([k, p]) => `${copyName(k, p)}.run`).join("\n        , ");
    write(
      path.join(outDir, "src", "Main.elm"),
      `port module Main exposing (main)\n\n${imports}\n\nport output : String -> Cmd msg\n\n\nresults : List String\nresults =\n    List.concat\n        [ ${items}\n        ]\n\n\nmain : Program () () ()\nmain =\n    Platform.worker\n        { init = \\_ -> ( (), output (String.join "\\n" results) )\n        , update = \\_ _ -> ( (), Cmd.none )\n        , subscriptions = \\_ -> Sub.none\n        }\n`,
    );
  } else if (lang === "gleam") {
    const tmpl = path.join(HERE, "gleam");
    fs.copyFileSync(path.join(tmpl, "gleam.toml"), path.join(outDir, "gleam.toml"));
    fs.copyFileSync(path.join(tmpl, "manifest.toml"), path.join(outDir, "manifest.toml"));
    // Downloaded dependency sources, so no run touches the network.
    fs.cpSync(path.join(tmpl, "build", "packages"), path.join(outDir, "build", "packages"), {
      recursive: true,
    });
    for (const [k, p] of all) write(path.join(outDir, "src", `${gleamName(k, p)}.gleam`), source[p]);
    const imports = all.map(([k, p]) => `import ${gleamName(k, p)}\n`).join("");
    const items = all.map(([k, p]) => `${gleamName(k, p)}.run()`).join(",\n    ");
    write(
      path.join(outDir, "src", "compare.gleam"),
      `${imports}import gleam/io\nimport gleam/list\nimport gleam/string\n\npub fn main() -> Nil {\n  list.flatten([\n    ${items},\n  ])\n  |> string.join("\\n")\n  |> io.println\n}\n`,
    );
  } else if (lang === "roc") {
    // The module name is the file's name; the header is `module [run]`.
    for (const [k, p] of all) write(path.join(outDir, `${copyName(k, p)}.roc`), source[p]);
    const imports = all.map(([k, p]) => `import ${copyName(k, p)}\n`).join("");
    const items = all.map(([k, p]) => `${copyName(k, p)}.run`).join(",\n        ");
    write(
      path.join(outDir, "Main.roc"),
      `module [results]\n\n${imports}\nresults : List Str\nresults =\n    List.join(\n        [\n        ${items},\n        ],\n    )\n`,
    );
    write(
      path.join(outDir, "app.roc"),
      fs.readFileSync(path.join(HERE, "roc", "app.roc"), "utf8"),
    );
  } else if (lang === "purescript") {
    for (const [k, p] of all) {
      const text = source[p].replace(
        new RegExp(`^module ${p} \\(run\\) where`, "m"),
        `module ${copyName(k, p)} (run) where`,
      );
      write(path.join(outDir, "src", `${copyName(k, p)}.purs`), text);
    }
    const imports = all.map(([k, p]) => `import ${copyName(k, p)} as ${copyName(k, p)}\n`).join("");
    const items = all.map(([k, p]) => `${copyName(k, p)}.run`).join("\n      , ");
    write(
      path.join(outDir, "src", "Main.purs"),
      `module Main (main) where\n\nimport Prelude\n\nimport Data.Array as Array\nimport Data.Foldable (fold)\nimport Data.String (joinWith)\nimport Effect (Effect)\nimport Effect.Console (log)\n${imports}\nmain :: Effect Unit\nmain =\n  log\n    ( joinWith "\\n"\n        ( Array.fromFoldable\n            ( fold\n                [ ${items}\n                ]\n            )\n        )\n    )\n`,
    );
  } else {
    throw new Error(`unknown language ${lang}`);
  }
  return outDir;
}

// ---- size of one copy -------------------------------------------------------

const COMMENT = {
  beni: { line: "--" },
  elm: { line: "--", open: "{-", close: "-}" },
  gleam: { line: "//" },
  roc: { line: "#" },
  purescript: { line: "--", open: "{-", close: "-}" },
};

// Lexical tokens after dropping comments: a string or char literal, a word,
// a number, a run of operator characters, or one bracket/comma. The same
// rules for every language, so the counts are comparable if approximate.
export function measure(lang, text) {
  const c = COMMENT[lang];
  let code = "";
  let i = 0;
  while (i < text.length) {
    const ch = text[i];
    if (ch === '"') {
      let j = i + 1;
      while (j < text.length && text[j] !== '"') j += text[j] === "\\" ? 2 : 1;
      code += text.slice(i, j + 1);
      i = j + 1;
    } else if (ch === "'" && lang !== "gleam" && /^'(\\.|[^'\\])'/.test(text.slice(i, i + 4))) {
      const m = text.slice(i).match(/^'(\\.|[^'\\])'/);
      code += m[0];
      i += m[0].length;
    } else if (text.startsWith(c.line, i)) {
      while (i < text.length && text[i] !== "\n") i++;
    } else if (c.open && text.startsWith(c.open, i)) {
      const end = text.indexOf(c.close, i + 2);
      i = end < 0 ? text.length : end + 2;
    } else {
      code += ch;
      i++;
    }
  }
  const lines = code.split("\n").filter((l) => l.trim() !== "").length;
  const tokens = (
    code.match(
      /"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])'|[A-Za-z_][A-Za-z0-9_]*|\d[\d_]*|[!#$%&*+./<=>?@\\^|~:-]+|[()[\]{},]/g,
    ) || []
  ).length;
  return { lines, tokens };
}

export function copySize(lang) {
  let lines = 0;
  let tokens = 0;
  for (const p of PROGRAMS) {
    const m = measure(lang, fs.readFileSync(portFile(lang, p), "utf8"));
    lines += m.lines;
    tokens += m.tokens;
  }
  return { lines, tokens };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [lang, n, out] = process.argv.slice(2);
  if (!LANGS.includes(lang) || !(Number(n) >= 1) || !out) {
    console.error("usage: node gen.mjs <beni|elm|gleam|roc|purescript> <N> <outdir>");
    process.exit(2);
  }
  generate(lang, Number(n), path.resolve(out));
  console.log(path.resolve(out));
}
