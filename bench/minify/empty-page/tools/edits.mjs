// The runtime source edits priced by tools/source-trials.mjs and used by
// steps.mjs. No imports: steps.mjs is loaded by measure.mjs.
export const one = (a, b) => (s) => { if (!s.includes(a)) throw new Error(`not found: ${a}`); return s.replace(a, () => b); };
export const re = (a, b) => (s) => { const t = s.replace(a, b); if (t === s) throw new Error(`no match: ${a}`); return t; };
export const seq = (...fs) => (s) => fs.reduce((x, f) => f(x), s);
// Only code lines, never comment lines.
export const code = (f) => (s) => s.split("\n").map((l) => (l.trim().startsWith("//") ? l : f(l))).join("\n");

export const SOURCE = {
  parent: ["`parent` locals (a host global, never renamed) named `into`", code((l) => l.replace(/(?<![.\w$])parent(?![\w$])/g, "into"))],
  cx: ["`cx` locals (a shorthand key, never renamed) named `context`", seq(
    code((l) => l.replace(/(?<![.\w$])cx(?![\w$:])/g, "context")),
    one("m: marker, context, i: null", "m: marker, cx: context, i: null"))],
  docLocal: ["`const document = globalThis.document` locals named `doc`", seq(
    one("const document = globalThis.document;\n      const t = document.createElement", "const doc = globalThis.document;\n      const t = doc.createElement"),
    one("const f = document.createDocumentFragment()", "const f = doc.createDocumentFragment()"),
    one("const document = globalThis.document;\n  for (const m of program) {\n    const root = m.n === null ? document.body : document.getElementById(m.n);", "const doc = globalThis.document;\n  for (const m of program) {\n    const root = m.n === null ? doc.body : doc.getElementById(m.n);"))],
  docBare: ["`document` read bare, no `globalThis.` and no local", seq(
    one("      const document = globalThis.document;\n", ""),
    one("  const document = globalThis.document;\n  for (const m of program)", "  for (const m of program)"),
    code((l) => l.replace(/globalThis\.document/g, "document")))],
  nullish: ["`x !== null ? x : y` → `x ?? y` in first, last, parentOf", seq(
    one("(i.s !== null ? i.s : head(i.q))", "(i.s ?? head(i.q))"),
    one("(i.e !== null ? i.e : tail(i.q))", "(i.e ?? tail(i.q))"),
    one("(s.p !== null ? s.p : s.m.parentNode)", "(s.p ?? s.m.parentNode)"))],
  uLength: ["`s.u !== null && s.u.length !== 0` → `s.u?.length` in head, tail", code((l) => l.replace("s.u !== null && s.u.length !== 0", "s.u?.length"))],
  constN: ["`patch`'s `const n` named `fresh`, so the kept units assign no `const` name", seq(one("  const n = unit(b, cx);\n  swap(i, n);\n  return n;", "  const fresh = unit(b, cx);\n  swap(i, fresh);\n  return fresh;"))],
  childPut: ["`childHtml` puts its first instance itself (`place`'s other arm is dead there)", one("  if (s.i === null) place(s, unit(b, s.cx));\n  else s.i = patch(s.i, b, s.cx);\n};\n\n// `(slot, block or null)`", "  if (s.i === null) {\n    const i = unit(b, s.cx);\n    put(parentOf(s), i, s.m);\n    s.i = i;\n  } else s.i = patch(s.i, b, s.cx);\n};\n\n// `(slot, block or null)`")],
  mountRender: ["`mount`'s first render is `render()`", one("  };\n  childHtml(s, program.view(model));\n};", "  };\n  render();\n};")],
  mountInRun: ["`mount`, called once, written in `run`'s loop", seq(
    one("    mount(m.h ? m.h(root, flush, (f) => (phase = f, scheduled)) : m.a, root);\n  }\n};", "    const program1 = m.h ? m.h(root, flush, (f) => (phase = f, scheduled)) : m.a;\n    const s = slot(root, null, null);\n    let model = program1.init;\n    let waiting = false;\n    const render = () => {\n      waiting = false;\n      childHtml(s, program1.view(model));\n    };\n    root.$$root = (msg) => {\n      if (!waiting) {\n        waiting = true;\n        queued.push(render);\n        if (!scheduled) {\n          scheduled = true;\n          queueMicrotask(() => {\n            if (scheduled) flush();\n          });\n        }\n      }\n      model = program1.update(msg, model);\n    };\n    childHtml(s, program1.view(model));\n  }\n};"),
    re(/\nconst mount = \(program, root\) => \{[\s\S]*?\n\};\n/, "\n"))],
  conciseEnds: ["`head` and `tail` written as one conditional expression each", seq(
    one("const head = (s) => {\n  if (s.u !== null && s.u.length !== 0) return first(s.u[0]);\n  return s.i !== null ? first(s.i) : s.m;\n};", "const head = (s) => (s.u !== null && s.u.length !== 0 ? first(s.u[0]) : s.i !== null ? first(s.i) : s.m);"),
    one("const tail = (s) => {\n  if (s.m !== null) return s.m;\n  if (s.u !== null && s.u.length !== 0) return last(s.u[s.u.length - 1]);\n  return last(s.i);\n};", "const tail = (s) => (s.m !== null ? s.m : s.u !== null && s.u.length !== 0 ? last(s.u[s.u.length - 1]) : last(s.i));"))],
  rootTruthy: ["`root.$$root !== undefined` → `root.$$root`", one("root.$$root !== undefined", "root.$$root")],
};
