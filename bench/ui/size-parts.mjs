// Research 59 Q4: where a beni `--release` bundle's bytes go. The bundle is
// one scope-hoisted file whose top-level bindings are the runtime's, core's
// and the program's functions under short names; a map below names each
// binding's part. Measured as sizes.mjs measures (terser `--compress
// --mangle --module`, then brotli 11), three ways, because brotli is not
// additive:
//
//   alone   the part's declarations by themselves (exported, so terser
//           keeps them), minified, brotli 11.
//   loo     leave one out: the whole bundle with the part's declarations
//           stubbed (below), minified again, against the whole.
//   peel    the parts stubbed one after another in the map's order, each
//           charged what its removal saved at that point; these sum to the
//           whole, with the stubs' own bytes left in "what is left".
//
//   node size-parts.mjs [--file=out/beni-rel/_main.mjs] [--map=table|table-for|table-coarse]
//
// A removed binding becomes a stub naming the bindings it used, so no other
// part's code becomes dead and is dropped with it.

import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";
import { brotliCompressSync, constants } from "node:zlib";
import { root } from "./lib/serve.mjs";

const require = createRequire(join(root, "apps/solid2/package.json"));
const { minify } = require("terser");
const acorn = require("../solid1/node_modules/acorn");

const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
const file = join(root, arg("file", "out/beni-rel/_main.mjs"));

// The table app (apps/beni/Main.beni) as `beni build --release` writes it
// at this commit; the names are read off the bundle by hand.
const maps = {
  table: [
    ["core List: the trie, views and `[ x, …xs ]`", "R S T U V W X Y Z $ _ aa ba ca da ea fa ga ha ia ja"],
    ["core List.append", "ka la ma na oa pa"],
    ["core List.get", "qa ra"],
    ["core List.indexedMap", "sa ta ua va"],
    ["core List.filter", "wa xa ya za"],
    ["core Basics.modBy, Maybe.Nothing", "P Q"],
    ["Rt keyed For: reconcile, fast path, row mount and patch", "A B C D E F G H I J K"],
    ["Rt delegation: listener, walk, fire", "L M N O"],
    ["Rt scheduler: queue, turn, flush, defect guards, mount, run", "o p q r s t u v y"],
    ["Rt slots: slot, unit, patch, child, refresh", "h i j k l m n z"],
    ["Rt template", "g"],
    ["Rt DOM ranges: first, last, put, drop", "a b c d e f"],
    ["program: message constructors", "Aa Ba Ca Da Ea Fa Ga"],
    ["program: data (word lists, buildData)", "Pa Qa Ra Sa Ta Ua Va"],
    ["program: update (and swap)", "Wa Xa x"],
    ["program: view (templates, kinds, patches)", "Ha Ia Ja Ka La Ma Na Oa w"],
    ["program: init and start", "Ya"],
  ],
};

// The same, with keyed `For` cut into its four pieces.
maps["table-for"] = maps.table.flatMap((p) =>
  p[1] === "A B C D E F G H I J K"
    ? [
        ["Rt For: the general keyed walk (forKeyed)", "K A"],
        ["Rt For: the move reconciler (moves, removes, inserts)", "H G"],
        ["Rt For: the in-place fast path", "J I"],
        ["Rt For: row mount, row patch, selection, deps", "B C D E F"],
      ]
    : [p],
);

// Three parts: core, the platform runtime, the program.
const coarse = (prefix) => maps.table.filter(([l]) => l.startsWith(prefix)).map(([, n]) => n).join(" ");
maps["table-coarse"] = [
  ["core (List, Basics, Maybe)", coarse("core")],
  ["platform runtime (Rt)", coarse("Rt")],
  ["program", coarse("program")],
];

const map = maps[arg("map", "table")];
const src = readFileSync(file, "utf8");
const ast = acorn.parse(src, { ecmaVersion: "latest", sourceType: "module" });

// Every top-level declarator, by name; the other statements as they are.
const partOf = new Map();
for (const [label, names] of map) for (const n of names.split(" ")) partOf.set(n, label);
const decls = [];
for (const st of ast.body) {
  if (st.type === "VariableDeclaration") for (const d of st.declarations) decls.push({ name: d.id.name, kind: st.kind, text: src.slice(d.start, d.end) });
}
const unassigned = decls.filter((d) => !partOf.has(d.name)).map((d) => d.name);
if (unassigned.length > 0) throw new Error(`no part for ${unassigned.join(" ")}`);

// A removed binding becomes a stub that still names every top-level
// binding its code named (`d=[a,b,c]`), so removing it never makes another
// part's code dead; the stubs' few bytes stay in "what is left". Local
// names that shadow a top-level one are counted too, which only keeps more
// alive.
const topNames = new Set(decls.map((d) => d.name));
const refs = (node, into) => {
  if (node === null || typeof node !== "object") return into;
  if (Array.isArray(node)) {
    for (const x of node) refs(x, into);
    return into;
  }
  if (node.type === "Identifier" && topNames.has(node.name)) into.add(node.name);
  for (const k of Object.keys(node)) if (k !== "start" && k !== "end" && k !== "loc") refs(node[k], into);
  return into;
};
const stub = (d) => `${d.id.name}=[${[...refs(d.init, new Set())].filter((n) => n !== d.id.name).join(",")}]`;

// The program with the bindings in `gone` stubbed, in its original order.
const without = (gone) => {
  const out = [];
  for (const st of ast.body) {
    if (st.type === "VariableDeclaration") {
      const kept = st.declarations.map((d) => (gone.has(d.id.name) ? stub(d) : src.slice(d.start, d.end)));
      if (kept.length > 0) out.push(`${st.kind} ${kept.join(",")};`);
    } else out.push(src.slice(st.start, st.end));
  }
  return out.join("");
};

const br = (s) => brotliCompressSync(Buffer.from(s), { params: { [constants.BROTLI_PARAM_QUALITY]: 11, [constants.BROTLI_PARAM_SIZE_HINT]: s.length } }).length;
const size = async (text) => {
  const code = (await minify(text, { compress: true, mangle: true, module: true })).code ?? "";
  return { raw: code.length, br: code.length === 0 ? 0 : br(code) };
};

const whole = await size(src);
console.log(`${file.slice(root.length)}: minified ${whole.raw} B, brotli 11 ${whole.br} B\n`);
console.log("| part | alone raw | alone br | leave-one-out br | peel br |");
console.log("|---|--:|--:|--:|--:|");
const gone = new Set();
let before = whole.br;
let sumLoo = 0;
let sumAlone = 0;
for (const [label, names] of map) {
  const set = new Set(names.split(" "));
  const own = decls.filter((d) => set.has(d.name));
  const alone = await size(`${own.map((d) => `${d.kind} ${d.text};`).join("")}export{${own.map((d) => d.name).join(",")}};`);
  const loo = whole.br - (await size(without(set))).br;
  for (const n of set) gone.add(n);
  const after = (await size(without(gone))).br;
  console.log(`| ${label} | ${alone.raw} | ${alone.br} | ${loo} | ${before - after} |`);
  sumLoo += loo;
  sumAlone += alone.br;
  before = after;
}
console.log(`| what is left (start-up statements) | | | | ${before} |`);
console.log(`| **sum** | | ${sumAlone} | ${sumLoo} | ${whole.br} |`);
