// Hand-edited copies of a build, to price a change before it is built:
// each is an output directory with named edits, registered as an extra
// subject in out/extra-subjects.json (never committed).
//
//   beni-list   the development build with `core/List`'s `filter` and
//               `indexedMap` as a `List` could have them without an array
//               type: `filter` asks `isGood` once per element, in order,
//               and shares the tail after the last element it drops;
//               `indexedMap` is one pass and one reverse-free build
//
// (Research 39's `beni-eqmsg` and `beni-reuse` were built into the compiler
// and the runtime on 2026-09-29; their edits no longer apply.)
//
//   node experiments.mjs    (after build.mjs)

import { cpSync, existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";

const mk = (name, from, file, edits) => {
  const dir = new URL(`./out/${name}/`, import.meta.url);
  rmSync(dir, { recursive: true, force: true });
  cpSync(new URL(`./out/${from}/`, import.meta.url), dir, { recursive: true });
  const f = new URL(file, dir);
  let s = readFileSync(f, "utf8");
  for (const [a, b] of edits) {
    if (!s.includes(a)) throw new Error(`${name}: missing ${a}`);
    s = s.replace(a, () => b);
  }
  writeFileSync(f, s);
  return { name, kind: "beni", dir: name };
};

const listEdits = [
  [
    "const List$indexedMap = (xs$1, func$2) => List$map2(List$range(0, Basics$sub(List$length(xs$1), 1)), xs$1, func$2);",
    `const List$indexedMap = (xs, func) => {
  const top = { $: 1, a: null, b: null };
  let t = top;
  let i = 0;
  for (let at = xs; at.$ === 1; at = at.b) {
    const c = { $: 1, a: func(i++, at.a), b: null };
    t.b = c;
    t = c;
  }
  t.b = { $: 0, a: null, b: null };
  return top.b;
};`,
  ],
  [
    "const List$filter = (list$1, isGood$2) => List$reverse(List$foldl(list$1, { $: 0, a: null, b: null }, (x$3, xs$4) => isGood$2(x$3) ? List$cons(x$3, xs$4) : xs$4));",
    `const List$filter = (list, isGood) => {
  const keep = [];
  let cut = -1;
  let k = 0;
  for (let at = list; at.$ === 1; at = at.b, k++) {
    const good = isGood(at.a);
    keep.push(good);
    if (!good) cut = k;
  }
  if (cut === -1) return list;
  const top = { $: 1, a: null, b: null };
  let t = top;
  let at = list;
  for (let j = 0; j < cut; j++, at = at.b) {
    if (keep[j]) {
      const c = { $: 1, a: at.a, b: null };
      t.b = c;
      t = c;
    }
  }
  t.b = at.b;
  return top.b;
};`,
  ],
];

const subjects = [mk("beni-list", "beni-dev", "_core/List.mjs", listEdits)];
const extra = new URL("./out/extra-subjects.json", import.meta.url);
const kept = existsSync(extra) ? JSON.parse(readFileSync(extra, "utf8")).filter((x) => !subjects.some((s) => s.name === x.name)) : [];
writeFileSync(extra, JSON.stringify([...kept, ...subjects]));
console.log(subjects.map((s) => s.name).join(" "));
