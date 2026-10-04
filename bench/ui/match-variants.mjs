// Research 56's prototypes: hand edits of beni's development build, each a
// named variant match.mjs measures beside the build it was made from.
// PROTOTYPES of what the compiler and runtime could emit; none is built.
//
// A variant is `{ name, from, sweeps, edits(c) }`: `from` names a subject
// of the case (match.mjs's `baseSubjects`), `edits` returns
// `[file, find, replace]` triples applied in order to the copy.

const RT = "_platform/_browser/Rt.mjs";
const all = ["holes", "rows", "width", "depth", "derived", "static"];

// Ablations: what each piece of the per-message path costs, measured by
// taking it out. Not proposals by themselves.
const ablations = [
  // Render in the send, after `update`, not in a microtask.
  {
    name: "abl-sync",
    from: "beni",
    sweeps: all,
    edits: () => [[RT, "model$4 = program$1.update(msg$7, model$4);\n      return null;", "model$4 = program$1.update(msg$7, model$4);\n      Rt$flush();\n      return null;"]],
  },
  // Render in the send and queue no microtask at all.
  {
    name: "abl-nomicro",
    from: "beni",
    sweeps: all,
    edits: () => [
      [RT, "globalThis.queueMicrotask(() => Rt$microtask());", "0;"],
      [RT, "model$4 = program$1.update(msg$7, model$4);\n      return null;", "model$4 = program$1.update(msg$7, model$4);\n      Rt$flush();\n      return null;"],
    ],
  },
  // Vanilla JavaScript writing its one node in an empty microtask's place:
  // what one more top-level callback costs the harness by itself.
  {
    name: "vanilla-microtask",
    from: "vanillajs",
    sweeps: ["holes"],
    edits: () => [["main.js", "  tickText.data = tick;\n});", "  tickText.data = tick;\n  queueMicrotask(() => {});\n});"]],
  },
  {
    name: "vanilla-in-microtask",
    from: "vanillajs",
    sweeps: ["holes"],
    edits: () => [["main.js", "  tickText.data = tick;\n});", "  queueMicrotask(() => { tickText.data = tick; });\n});"]],
  },
  // No `try … finally` around a handler and a flush.
  {
    name: "abl-nofinally",
    from: "beni",
    sweeps: all,
    edits: () => [
      [RT, /let ok\$1 = false;\n    try \{([\s\S]*?)\n    \} finally \{\n      if \(!ok\$1\) \{\n        Rt\$stop\(\);\n      \}\n    \}/, (m, body) => "let ok$1 = false;" + body],
      [RT, /let ok\$5 = false;\n    try \{([\s\S]*?)\n    \} finally \{\n      if \(!ok\$5\) \{\n        Rt\$stop\(\);\n      \}\n    \}/, (m, body) => "let ok$5 = false;" + body],
    ],
  },
];

// ---- Proposal A: render at the end of the browser's dispatch -------------
//
// A message sent by a handler of an event the browser dispatched (trusted,
// with no beni code beneath it on the stack) is rendered when the delegated
// listener returns, instead of in a microtask. The microtask would run at
// that very point — a microtask checkpoint follows every listener callback
// whose stack empties — so what a program can observe is unchanged; what
// goes is one top-level callback per message. Every other send (a synthetic
// `el.click()`, a fiber, a timer, an event dispatched inside a render)
// keeps the microtask, so a burst still renders once.
const evflush = [
  [RT, "let Rt$dead = false;", "let Rt$dead = false;\nlet Rt$sync = false;\nlet Rt$inFlush = false;"],
  [RT, "      Rt$scheduled = false;\n      const renders$2 = Rt$queued;", "      Rt$scheduled = false;\n      Rt$inFlush = true;\n      const renders$2 = Rt$queued;"],
  [RT, "      ok$1 = true;\n      return null;\n    } finally {", "      ok$1 = true;\n      Rt$inFlush = false;\n      return null;\n    } finally {"],
  [RT, "globalThis.queueMicrotask(() => Rt$microtask());", "if (!Rt$sync) globalThis.queueMicrotask(() => Rt$microtask());"],
  [
    RT,
    "const Rt$delegated = (event$1) => {\n  const type_$2 = event$1.type;\n  return Rt$bubble(event$1, `$$${type_$2}`, event$1.target);\n};",
    `const Rt$delegated = (event$1) => {
  const type_$2 = event$1.type;
  const outer = event$1.isTrusted && !Rt$sync && !Rt$inFlush;
  if (outer) Rt$sync = true;
  Rt$bubble(event$1, \`$$\${type_$2}\`, event$1.target);
  if (outer) {
    Rt$sync = false;
    if (Rt$scheduled) Rt$flush();
  }
  return null;
};`,
  ],
];

const proposalA = [
  { name: "A-evflush", from: "beni", sweeps: all, edits: () => evflush },
  { name: "A-evflush-helper", from: "beni-helper", sweeps: ["derived"], edits: () => evflush },
];

// ---- Proposal B: the template computes its own values, by what they read -
//
// What `dom` would emit if a root's block carried the root's INPUTS — the
// locals its values read, `[model]` — instead of its values, and the kind
// computed each value itself, grouped by the field paths it reads (the
// analysis `For` rows already make, language.md §11.9): a group runs only
// when one of its paths is not `===` the one it last saw, and the root
// mounts through its patch (backend.md §15.5's `w`), so each value's code
// is written once. `lazyFlat` rewrites a development build whose one root
// holds only holes of the form `model.f` and constants — the `holes`,
// `width` and static pages — into that shape.
const lazyFlat = (src) => {
  const view = /const Main\$view = \(model\$1\) => \{\n([\s\S]*?)  return \{ t: (Main\$k\d+), v: \[([^\]]*)\] \};\n\};/.exec(src);
  if (view === null) throw new Error("lazyFlat: no view of the expected shape");
  const [whole, body, kind, list] = view;
  const field = new Map([...body.matchAll(/const (\$t\$\d+) = model\$1\.(\w+);/g)].map((m) => [m[1], m[2]]));
  const values = list.split(", ").map((e) => (field.has(e) ? { field: field.get(e) } : { constant: e }));
  const kindRe = new RegExp(`const ${kind.replace("$", "\\$")} = \\{ m: \\((v\\$\\d+), (cx\\$\\d+)\\) => \\{\\n([\\s\\S]*?)\\n  return \\{[^\\n]*\\};\\n\\}, p: [\\s\\S]*?\\n\\} \\};`);
  const k = kindRe.exec(src);
  if (k === null) throw new Error("lazyFlat: no kind of the expected shape");
  const [kindWhole, vName, cxName, mBody] = k;
  const lines = mBody.split("\n");
  const keep = [];
  const writes = values.map(() => []);
  const vRe = new RegExp(`${vName.replace("$", "\\$")}\\[(\\d+)\\]`);
  for (let j = 0; j < lines.length; j++) {
    const line = lines[j];
    const m = vRe.exec(line);
    if (m === null) {
      keep.push(line);
      continue;
    }
    const at = Number(m[1]);
    const v = values[at];
    if (v.constant !== undefined) keep.push(line.replace(vRe, v.constant));
    else writes[at].push(line.trim());
  }
  const root = /const (r\$\d+) = /.exec(mBody)[1];
  const nodes = new Set();
  const groups = new Map();
  values.forEach((v, at) => {
    if (v.field === undefined) return;
    if (!groups.has(v.field)) groups.set(v.field, []);
    for (const w of writes[at]) {
      for (const n of w.matchAll(/w\$(\d+)/g)) nodes.add(n[1]);
      groups.get(v.field).push(w);
    }
  });
  const fields = [...groups.keys()];
  const inst = [`s: ${root}`, "q: null", `e: ${root}`, ...[...nodes].map((n) => `n${n}: w$${n}`), ...fields.map((_, g) => `g${g}: undefined`)];
  const p = fields
    .map((f, g) => {
      const ws = groups.get(f).map((w) => `      ${w.replace(vRe, "x").replace(/w\$(\d+)/g, "i.n$1")}`);
      return `  {\n    const x = model.${f};\n    if (x !== i.g${g}) {\n      i.g${g} = x;\n${ws.join("\n")}\n    }\n  }`;
    })
    .join("\n");
  const newKind = `const ${kind} = { m: (${vName}, ${cxName}) => {
${keep.join("\n")}
  const i = { ${inst.join(", ")} };
  ${kind}.p(i, ${vName});
  return i;
}, p: (i, v) => {
  const model = v[0];
${p}
} };`;
  return src.replace(kindWhole, () => newKind).replace(whole, () => `const Main$view = (model$1) => ({ t: ${kind}, v: [model$1] });`);
};

// The derived page in the same shape: `shown = top model.items`, a `let`
// of `view` read only by the root, moves into the kind as a value of its
// own, computed when `model.items` is not the list it was last computed
// from — Solid's `createMemo`, derived from the reads instead of written.
// The row and the key function, which capture nothing, are hoisted.
const lazyDerived = (src) => {
  const kind = /const (Main\$k\d+) = \{ m: \((v\$\d+), (cx\$\d+)\) => \{\n([\s\S]*?)\n  w\$(\d+)\.\$\$click = v\$\d+\[0\];\n  if \(cx\$\d+ !== null\) \{\n    w\$\d+\.\$\$cx = cx\$\d+;\n  \}\n  w\$(\d+)\.data = v\$\d+\[1\];\n  Rt\$forKeyed\((c\$\d+), [\s\S]*?\n\} \};/.exec(src);
  if (kind === null) throw new Error("lazyDerived: no kind of the expected shape");
  const [kindWhole, k, vName, cxName, walks, button, tickNode, slot] = kind;
  const root = /const (r\$\d+) = /.exec(walks)[1];
  const view = /const Main\$view = \(model\$1\) => \{\n[\s\S]*?const (\$t\$\d+) = (\(\$p\$\d+\) => \$p\$\d+\.id);\n  return \{ t: Main\$k\d+, v: \["Go", \$t\$\d+, shown\$\d+, \$t\$\d+, (\{ m: [\s\S]*?f: null \})\] \};\n\};/.exec(src);
  if (view === null) throw new Error("lazyDerived: no view of the expected shape");
  const [viewWhole, , keyFn, rowObj] = view;
  const newKind = `const Main$key = ${keyFn};
const Main$row = ${rowObj};
const ${k} = { m: (${vName}, ${cxName}) => {
${walks}
  w$${button}.$$click = "Go";
  if (${cxName} !== null) {
    w$${button}.$$cx = ${cxName};
  }
  const i = { s: ${root}, q: null, e: ${root}, n${tickNode}: w$${tickNode}, c2: ${slot}, g0: undefined, g1: undefined, d0: undefined };
  ${k}.p(i, ${vName});
  return i;
}, p: (i, v) => {
  const model = v[0];
  {
    const x = model.tick;
    if (x !== i.g0) {
      i.g0 = x;
      i.n${tickNode}.data = x;
    }
  }
  {
    const x = model.items;
    if (x !== i.g1) {
      i.g1 = x;
      i.d0 = Main$top(x);
      Rt$forKeyed(i.c2, i.d0, Main$key, Main$row, null);
    }
  }
} };`;
  // The kind is declared before `Main$top`; it is only called after.
  return src.replace(kindWhole, () => newKind).replace(viewWhole, () => `const Main$view = (model$1) => ({ t: ${k}, v: [model$1] });`);
};

// The rows page in B's shape: the list hole guarded by `model.rows`, the
// two handlers constants, the row and its key function hoisted.
const lazyRows = (src) => {
  const kind = /const (Main\$k\d+) = \{ m: \((v\$\d+), (cx\$\d+)\) => \{\n([\s\S]*?)\n  w\$(\d+)\.\$\$click = v\$\d+\[0\];\n[\s\S]*?\n  w\$(\d+)\.\$\$click = v\$\d+\[1\];\n[\s\S]*?Rt\$forKeyed\((c\$\d+), [\s\S]*?\n\} \};/.exec(src);
  if (kind === null) throw new Error("lazyRows: no kind of the expected shape");
  const [kindWhole, k, vName, cxName, walks, go, swap, slot] = kind;
  const root = /const (r\$\d+) = /.exec(walks)[1];
  const view = /const Main\$view = \(model\$1\) => \{\n  const \$t\$1 = model\$1\.rows;\n  const (\$t\$\d+) = (\(\$p\$\d+\) => \$p\$\d+\.id);\n  return \{ t: Main\$k\d+, v: \["Go", "Swap", \$t\$1, \$t\$\d+, (\{ m: [\s\S]*?f: null \})\] \};\n\};/.exec(src);
  if (view === null) throw new Error("lazyRows: no view of the expected shape");
  const [viewWhole, , keyFn, rowObj] = view;
  const newKind = `const Main$key = ${keyFn};
const Main$row = ${rowObj};
const ${k} = { m: (${vName}, ${cxName}) => {
${walks}
  w$${go}.$$click = "Go";
  if (${cxName} !== null) {
    w$${go}.$$cx = ${cxName};
  }
  w$${swap}.$$click = "Swap";
  if (${cxName} !== null) {
    w$${swap}.$$cx = ${cxName};
  }
  const i = { s: ${root}, q: null, e: ${root}, c2: ${slot}, g0: undefined };
  ${k}.p(i, ${vName});
  return i;
}, p: (i, v) => {
  const x = v[0].rows;
  if (x !== i.g0) {
    i.g0 = x;
    Rt$forKeyed(i.c2, x, Main$key, Main$row, null);
  }
} };`;
  return src.replace(kindWhole, () => newKind).replace(viewWhole, () => `const Main$view = (model$1) => ({ t: ${k}, v: [model$1] });`);
};

// ---- Proposal C: a list says what changed since an older version ---------
//
// `core/List` gains a fourth protocol point, `xs.$diff(old)` (backend.md §4,
// *Lists are arrays*): for two tries of one length and shape, the elements
// at which they differ, found by walking only the nodes the two do not
// share — O(changes × log n), since a trie set copies the path to one leaf
// and shares the rest; `null` when the two are not comparable. `forKeyed`
// asks it first when its inputs are as last time and its selector did not
// move: if every changed item keeps its row's key, it patches those rows
// and visits no other. Anything else takes today's path.
const LIST = "_core/List.mjs";
const listDiff = [
  [
    LIST,
    "const List$header = (n$1, h$2, hc$3, tr$4, t$5) => ({ length: n$1, h: h$2, hc: hc$3, T: tr$4, t: t$5, p: null, $plain: List$triePlain });",
    `const List$diffLeaf = (x, y, at, from, to, out) => {
  for (let j = 0; j < 32; j++) {
    const r = at + j;
    if (r >= from && r < to && x[j] !== y[j]) out.push(r, x[j]);
  }
};
const List$diffNode = (x, y, s, at, from, to, out) => {
  if (x === y || at >= to || at + (32 << s) <= from) return;
  if (s === 0) return List$diffLeaf(x, y, at, from, to, out);
  for (let c = 0; c < 32; c++) List$diffNode(x[c], y[c], s - 5, at + (c << s), from, to, out);
};
const List$trieDiff = function(old) {
  const a = this;
  if (old === a) return [];
  if (old === null || old.T === undefined || old.length !== a.length || old.hc !== a.hc) return null;
  const tr = a.T;
  const to = old.T;
  if (tr !== to && (tr.s !== to.s || tr.off !== to.off || tr.tc !== to.tc)) return null;
  const hc = a.hc;
  const out = [];
  if (a.h !== old.h) for (let j = 0; j < hc; j++) if (a.h[j] !== old.h[j]) out.push(hc - 1 - j, a.h[j]);
  if (tr !== to && tr.r !== to.r) {
    const raw = [];
    List$diffNode(tr.r, to.r, tr.s, 0, tr.off, tr.off + tr.tc, raw);
    for (let k = 0; k < raw.length; k += 2) out.push(hc + raw[k] - tr.off, raw[k + 1]);
  }
  if (a.t !== old.t) {
    const base = hc + tr.tc;
    for (let j = 0; j < a.length - base; j++) if (a.t[j] !== old.t[j]) out.push(base + j, a.t[j]);
  }
  return out;
};
const List$header = (n$1, h$2, hc$3, tr$4, t$5) => ({ length: n$1, h: h$2, hc: hc$3, T: tr$4, t: t$5, p: null, $plain: List$triePlain, $diff: List$trieDiff });`,
  ],
  [
    RT,
    "  } else {\n    s$1.b = items$2;\n    s$1.y = inputs$5;\n    if (!(s$1.d && Rt$trimmed(",
    "  } else if (same$8 && was$10 === now$11 && s$1.d && Rt$edited(s$1, items$2, keyOf$3, row$4)) {\n    s$1.b = items$2;\n  } else {\n    s$1.b = items$2;\n    s$1.y = inputs$5;\n    if (!(s$1.d && Rt$trimmed(",
  ],
  [
    RT,
    "const Rt$forKeyed = ",
    `const Rt$edited = (s, items, keyOf, row) => {
  if (items.$diff === undefined || s.b === null || row.b !== undefined) return false;
  const d = items.$diff(s.b);
  if (d === null) return false;
  const rows = s.u;
  for (let k = 0; k < d.length; k += 2) if ((keyOf === null ? d[k + 1] : keyOf(d[k + 1])) !== rows[d[k]].k) return false;
  for (let k = 0; k < d.length; k += 2) {
    const i = rows[d[k]];
    row.p(i, d[k + 1], d[k]);
    i.x = d[k + 1];
  }
  return true;
};
const Rt$forKeyed = `,
  ],
];

const proposalC = [
  { name: "C-diff", from: "beni", sweeps: ["rows"], edits: () => listDiff },
  { name: "AC", from: "beni", sweeps: ["rows"], edits: () => [...evflush, ...listDiff] },
  { name: "AB", from: "beni", sweeps: ["rows"], edits: () => [...evflush, ["Main.mjs", /^[\s\S]*$/, (s) => lazyRows(s)]] },
];

const proposalB = [
  { name: "B-lazy", from: "beni", sweeps: ["derived"], edits: () => [["Main.mjs", /^[\s\S]*$/, (s) => lazyDerived(s)]] },
  { name: "AB", from: "beni", sweeps: ["derived"], edits: () => [...evflush, ["Main.mjs", /^[\s\S]*$/, (s) => lazyDerived(s)]] },
  { name: "B-lazy", from: "beni", sweeps: ["holes", "width", "static"], edits: () => [["Main.mjs", /^[\s\S]*$/, (s) => lazyFlat(s)]] },
  { name: "AB", from: "beni", sweeps: ["holes", "width", "static"], edits: () => [...evflush, ["Main.mjs", /^[\s\S]*$/, (s) => lazyFlat(s)]] },
];

// ---- The recommended path, whole: A everywhere, B where a page's roots read
// fields, C where a keyed list changes in place. One subject per sweep.
const next = [
  { name: "next", from: "beni", sweeps: ["holes", "width", "static"], edits: () => [...evflush, ["Main.mjs", /^[\s\S]*$/, (s) => lazyFlat(s)]] },
  { name: "next", from: "beni", sweeps: ["derived"], edits: () => [...evflush, ["Main.mjs", /^[\s\S]*$/, (s) => lazyDerived(s)]] },
  { name: "next", from: "beni", sweeps: ["rows"], edits: () => [...evflush, ...listDiff, ["Main.mjs", /^[\s\S]*$/, (s) => lazyRows(s)]] },
  { name: "next", from: "beni", sweeps: ["depth", "table"], edits: () => evflush },
];

export const variants = [...ablations, ...proposalA, ...proposalB, ...proposalC, ...next];
