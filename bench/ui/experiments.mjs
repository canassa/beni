// Hand-edited copies of a build, to price a change before it is built:
// each is an output directory with named edits, registered as an extra
// subject in out/extra-subjects.json (never committed).
//
//   beni-list   the development build with `core/List`'s `filter` and
//               `indexedMap` as a `List` could have them without an array
//               type: `filter` asks `isGood` once per element, in order,
//               and shares the tail after the last element it drops;
//               `indexedMap` is one pass and one reverse-free build
//   beni-cons   the same two written in beni as cons steps, in the loop
//               the compiler emits for them (backend.md §8, tail calls
//               modulo cons): one pass each, no tail shared
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

// `beni-cons`: the two as beni source writes them as cons steps —
// `[ x, ...filter rest isGood ]`, `[ func i x, ...indexedMapFrom rest (i + 1) func ]`
// — in exactly the loop the compiler emits for that source since tail
// calls modulo cons (backend.md §8), copied from a build of it. No tail is
// shared: one pass, n cells, no `reverse`.
const consEdits = [
  [
    "const List$indexedMap = (xs$1, func$2) => List$map2(List$range(0, Basics$sub(List$length(xs$1), 1)), xs$1, func$2);",
    `const List$indexedMapFrom = ($in$0, $in$1, func$3) => {
  const $root = { $: 1, a: null, b: null };
  let $last = $root;
  List$indexedMapFrom: while (true) {
    const xs$1 = $in$0;
    const i$2 = $in$1;
    if (xs$1.$ === 0) {
      $last.b = { $: 0, a: null, b: null };
      return $root.b;
    } else {
      const x$4 = xs$1.a;
      const rest$5 = xs$1.b;
      $last.b = { $: 1, a: func$3(i$2, x$4), b: null };
      $last = $last.b;
      $in$0 = rest$5;
      $in$1 = Basics$add(i$2, 1);
      continue List$indexedMapFrom;
    }
  }
};
const List$indexedMap = (xs$1, func$2) => List$indexedMapFrom(xs$1, 0, func$2);`,
  ],
  [
    "const List$filter = (list$1, isGood$2) => List$reverse(List$foldl(list$1, { $: 0, a: null, b: null }, (x$3, xs$4) => isGood$2(x$3) ? List$cons(x$3, xs$4) : xs$4));",
    `const List$filter = ($in$0, isGood$2) => {
  const $root = { $: 1, a: null, b: null };
  let $last = $root;
  List$filter: while (true) {
    const list$1 = $in$0;
    if (list$1.$ === 0) {
      $last.b = { $: 0, a: null, b: null };
      return $root.b;
    } else {
      const x$3 = list$1.a;
      const rest$4 = list$1.b;
      if (isGood$2(x$3)) {
        $last.b = { $: 1, a: x$3, b: null };
        $last = $last.b;
        $in$0 = rest$4;
        continue List$filter;
      } else {
        $in$0 = rest$4;
        continue List$filter;
      }
    }
  }
};`,
  ],
];

const subjects = [mk("beni-list", "beni-dev", "_core/List.mjs", listEdits), mk("beni-cons", "beni-dev", "_core/List.mjs", consEdits)];
const extra = new URL("./out/extra-subjects.json", import.meta.url);
const kept = existsSync(extra) ? JSON.parse(readFileSync(extra, "utf8")).filter((x) => !subjects.some((s) => s.name === x.name)) : [];
writeFileSync(extra, JSON.stringify([...kept, ...subjects]));
console.log(subjects.map((s) => s.name).join(" "));
