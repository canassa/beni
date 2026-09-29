// Hand-edited copies of the development build, to price a fix before it is
// built: each is out/beni-dev with named edits, registered as an extra
// subject in out/extra-subjects.json (never committed).
//
//   beni-eqmsg  the row as a compiler that inlined `== Just x` and did not
//               rebuild unchanged handler messages would emit it
//   beni-reuse  the keyed list keeping its key map across a render that
//               moves rows (assumes distinct keys: an experiment only)
//
//   node experiments.mjs    (after build.mjs)

import { cpSync, readFileSync, rmSync, writeFileSync } from "node:fs";

const base = new URL("./out/beni-dev/", import.meta.url);
const mk = (name, edits) => {
  const dir = new URL(`./out/${name}/`, import.meta.url);
  rmSync(dir, { recursive: true, force: true });
  cpSync(base, dir, { recursive: true });
  const f = new URL("Main.mjs", dir);
  let s = readFileSync(f, "utf8");
  for (const [a, b] of edits) {
    if (!s.includes(a)) throw new Error(`${name}: missing ${a}`);
    s = s.replace(a, () => b);
  }
  writeFileSync(f, s);
  return { name, kind: "beni", dir: name };
};
const eqEdit = [
  "Maybe$Maybe$$eq(Main$eq$prim, model$1.selected, { $: \"Just\", a: row$2.id }) ? \"danger\" : \"\"",
  "(model$1.selected.$ === \"Just\" && model$1.selected.a === row$2.id) ? \"danger\" : \"\"",
];
const msgEdits = [
  ["    const $t$66 = { $: \"Select\", a: item$62.id };\n", ""],
  ["    const $t$68 = { $: \"Remove\", a: item$62.id };\n", ""],
  ["    if ($t$66 !== i$61.a2) {\n      i$61.a2 = $t$66;\n      i$61.w4.$$click = $t$66;\n    }\n", ""],
  ["    if ($t$68 !== i$61.a4) {\n      i$61.a4 = $t$68;\n      i$61.w7.$$click = $t$68;\n    }\n", ""],
];
const rt = (name, edits) => {
  const f = new URL(`./out/${name}/_platform/_browser/runtime.foreign.mjs`, import.meta.url);
  let s = readFileSync(f, "utf8");
  for (const [a, b] of edits) {
    if (!s.includes(a)) throw new Error(`${name}: missing ${a}`);
    s = s.replace(a, () => b);
  }
  writeFileSync(f, s);
};
// Experiment only: the key map kept across a render that moves rows, one
// lookup per surviving row and a stamp instead of delete + get + set.
// Assumes the new keys are distinct (the benchmark's are).
const reuseEdits = [
  ["    let distinct = true;\n    const old = s.u ?? [];", `    if (s.d) {
      const stamp = ++stamps;
      const old = s.u;
      const byKey = s.x;
      const next = [];
      let moved = false;
      let position = 0;
      for (let at = items; at.$ === 1; at = at.b, position++) {
        const item = at.a;
        const key = keyOf === null ? item : keyOf(item);
        let i = byKey.get(key);
        if (i !== undefined) {
          if (!same || i.x !== item || (row.i && i.y !== position)) {
            const was = i.y;
            const n = patchRow(row, i, item, position, s.cx);
            if (n !== i) { old[was] = n; byKey.set(key, n); i = n; }
          }
          if (!moved && old[position] !== i) moved = true;
        } else {
          i = mountRow(row, item, position, s.cx);
          i.k = key;
          byKey.set(key, i);
          moved = true;
        }
        i.v = stamp;
        i.x = item;
        i.y = position;
        next.push(i);
      }
      if (next.length !== old.length) moved = true;
      for (const o of old) if (o.v !== stamp) byKey.delete(o.k);
      if (moved) {
        const parent = parentOf(s);
        if (old.length === 0) {
          const f = globalThis.document.createDocumentFragment();
          for (const i of next) put(f, i, null);
          parent.insertBefore(f, s.i !== null ? first(s.i) : s.m);
        } else if (next.length === 0 && parent.firstChild === first(old[0]) && parent.lastChild === last(old[old.length - 1])) parent.textContent = "";
        else reconcile(parent, old, next, last(old[old.length - 1]).nextSibling);
        if (parked !== null) parked = null;
      }
      s.u = next;
      fallback(s, items.$ !== 1, row.f);
      return;
    }
    let distinct = true;
    const old = s.u ?? [];`],
  ["const inPlace = (s, items, keyOf, row, same) => {", "let stamps = 0;\nconst inPlace = (s, items, keyOf, row, same) => {"],
];
const reuse = mk("beni-reuse", []);
rt("beni-reuse", reuseEdits);
const subjects = [mk("beni-eqmsg", [eqEdit, ...msgEdits]), reuse];
writeFileSync(new URL("./out/extra-subjects.json", import.meta.url), JSON.stringify(subjects));
console.log(subjects.map((s) => s.name).join(" "));
