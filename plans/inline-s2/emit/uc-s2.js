// The unique-components scenario as tea-inline, a prototype strategy (see
// frameworks/tea-inline/README.md).
//
// The emitter plays the compiler of a TEA app, as in shared-components, but here there are no
// kinds to share: every widget is its own component (src/widgets/<id>.js), written out from
// its description as that widget's own code.
// - A widget's DOM is built once from one static HTML string (conditional sections included,
//   swapped out by `when` while hidden); its code refers to the elements by their place in
//   document order (`E[n]`); keyed list rows are built with `el(...)` by a row builder written
//   for that list.
// - Every dynamic expression (a text, a disabled state, a condition, a validation rule) is
//   compiled to JavaScript and becomes a binding. The emitter works out at compile time which
//   fields each binding reads, and groups the bindings per field: the widget's binding table
//   `G` holds one group per field (`G[0]`, `G[1]`, …), then each binding reading several
//   fields or other widgets, added at mount to the group of every field it reads (a reader of
//   another widget adds itself to that widget's group, `R[3][1]`). A list is the first binding
//   of its field's group (`G[1][0]`).
// - Every message (a `case` arm of the widget's `update`) is inlined into the action its
//   control calls: it writes the fields its ops change, in place, and schedules the groups of
//   exactly those fields, which hold the bindings of other widgets that read them. No `Msg`
//   object, no switch, no op table.
// - External events stay messages: `receive(msg)` routes serverSet/snapshot to a widget's
//   `load`, `tick` to the widgets that have a time-driven field and `notify` to the feed.
//
// Style choices (also in `style` below): one module per widget, static markup parsed once,
// in-place model edits, per-field binding groups, one microtask flush, keyed list rows edited
// in place by the action that knows which row it touched (other list edits replace the array
// and reconcile by id), and the runtime of tea-inline. The only generic code is the runtime and
// small helpers in widgets/widget.js (section, loader, items, nextId); no widget behaviour is
// kept as data.

const { templateFiles } = await import(process.env.RR + "/frameworks/tea-inline/framework.js");
const { literal, tplText } = await import(process.env.RR + "/frameworks/shared/jsx.js");

export const framework = "tea-inline";

const F = new Set((process.env.S2 || "").split("")); const D = F.has("d"), T = F.has("t"), P = F.has("p");
export const params = {};

// A widget's number: widget `wN` is number N, its position in page order counted from 1 (the
// emitter checks the ids).
const pos = (id) => Number(id.slice(1));
const str = JSON.stringify;
// HTML escaping for the static markup: text, and attribute values (unquoted when safe).
const escText = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;");
const attrValue = (v) => (/^[\w.:-]+$/.test(v) ? v : `"${v.replace(/&/g, "&amp;").replace(/"/g, "&quot;")}"`);

const WIDGET_FILE = () => `import { schedule${D && LISTNAMES.length ? ", fromList" : ""} } from "../runtime.js";
${D && LISTNAMES.length ? "export const LISTS = new Set(" + JSON.stringify(LISTNAMES) + ");" : ""}

// A widget's DOM: its section, keyed by its id (widget number i is wi), with the markup inside
// (its heading and everything it shows), appended to \`parent\`, and returned as its elements in
// document order.
export function section(parent, i, html) {
  parent.insertAdjacentHTML("beforeend", \`<section data-key=w\${i} data-role=widget>\${html}\`);
  return parent.lastChild.querySelectorAll(":not(h2,label,option)");
}

// Schedule every binding of a widget for its first render, and return its handle: its load for
// serverSet and snapshot (replace the widget's state, a copy since the message is not ours to
// edit, and run every binding it has again, and those of the widgets reading it), carrying its
// external arms.
export const loader = (s, all, arms) => (
  schedule(all),
  Object.assign((next) => {
    Object.assign(s, structuredClone(next));
${D && LISTNAMES.length ? "    for (const k in s) if (Array.isArray(s[k]) && s[k][0]?.id !== undefined || Array.isArray(s[k]) && !s[k].length && LISTS.has(k)) s[k] = fromList(s[k].map((x) => [x.id, x]));\n" : ""}    schedule(all);
  }, arms)
);

// A list's initial items, numbered from 1: their texts, or [text, done] pairs for a checkable list.
${D ? "export const items = (...xs) => fromList(xs.map((x, i) => [i + 1, x.map ? { id: i + 1, text: x[0], done: x[1] } : { id: i + 1, text: x }]));" : "export const items = (...xs) => xs.map((x, i) => (x.map ? { id: i + 1, text: x[0], done: x[1] } : { id: i + 1, text: x }));"}

// A new list item's id: one more than the largest.
${D ? "export const nextId = (d) => d.entries.reduce((max, e) => Math.max(max, e[0]), 0) + 1;" : "export const nextId = (items) => items.reduce((max, item) => Math.max(max, item.id), 0) + 1;"}

// The widgets by number, from 1: each widget's module adds its markup and its function when the
// app imports it, in page order.
export const W = [,];

`;

// ---------------------------------------------------------------------------------------------
// Expressions: compiled to JavaScript over the widget's state \`s\` and the slices of the
// widgets it reads. \`deps\` records the fields an expression reads.

// Drop the parentheses around a whole expression.
function bare(code) {
  if (code[0] !== "(" || code.at(-1) !== ")") return code;
  let depth = 0;
  for (let i = 0; i < code.length - 1; i++) {
    if (code[i] === '"') i = code.indexOf('"', i + 1);
    else if (code[i] === "(") depth++;
    else if (code[i] === ")" && --depth === 0) return code;
  }
  return code.slice(1, -1);
}

const exprCode = (e, deps) => bare(inner(e, deps));

function inner(e, deps) {
  const go = (x) => inner(x, deps);
  switch (e[0]) {
    case "f": deps.own.add(e[1]); return `s.${e[1]}`;
    case "w": deps.cross.add(`${e[1]}.${e[2]}`); return `model[${pos(e[1])}].${e[2]}`;
    case "k": return str(e[1]);
    case "+": case "-": return `(${go(e[1])} ${e[0]} ${go(e[2])})`;
    case "count": return D ? `size(${go(e[1])})` : `${go(e[1])}.length`; case "len": return `${go(e[1])}.length`;
    case "done": return D ? `count(${go(e[1])}, (item) => item.done)` : `${go(e[1])}.filter((item) => item.done).length`;
    case "left": return D ? `count(${go(e[1])}, (item) => !item.done)` : `${go(e[1])}.filter((item) => !item.done).length`;
    case "has": return `${go(e[1])}.includes(${str(e[2])})`;
    case "==": return `(${go(e[1])} == ${go(e[2])})`;
    case "!=": return `(${go(e[1])} != ${go(e[2])})`;
    case "<": case "<=": case ">": case ">=": return `(${go(e[1])} ${e[0]} ${go(e[2])})`;
    case "and": return `(${go(e[1])} && ${go(e[2])})`;
    case "or": return `(${go(e[1])} || ${go(e[2])})`;
    case "not": return `!${go(e[1])}`;
    case "if": return `(${go(e[1])} ? ${go(e[2])} : ${go(e[3])})`;
  }
  throw new Error(`unknown expression ${JSON.stringify(e)}`);
}

// The text parts as an expression: a template literal, or a plain string when static.
function partsCode(parts, deps) {
  if (parts.every((p) => typeof p === "string")) return { static: parts.join("") };
  if (parts.length === 1) return { code: exprCode(parts[0], deps) };
  return { code: "`" + parts.map((p) => (typeof p === "string" ? tplText(p) : `\${${exprCode(p, deps)}}`)).join("") + "`" };
}

// Every cross-widget read of a view, to know which fields other widgets read.
function crossReads(nodes, out) {
  const expr = (e) => {
    if (!Array.isArray(e)) return;
    if (e[0] === "w") out.push([e[1], e[2]]);
    else e.slice(1).forEach(expr);
  };
  for (const n of nodes) {
    for (const p of n.parts || []) expr(p);
    for (const p of n.text || []) expr(p);
    if (n.disabled) expr(n.disabled);
    if (n.cond) expr(n.cond);
    if (n.invalid) expr(n.invalid.when);
    crossReads(n.children || [], out);
  }
}

// ---------------------------------------------------------------------------------------------
// One widget: its module.

function widgetFile(w, reads, groupIndex) {
  const field = (name) => w.fields.find((f) => f.name === name);
  const message = (name) => w.messages.find((m) => m.name === name);
  const ids = {};
  const id = (p) => p + (ids[p] = (ids[p] || 0) + 1);
  // An element the code refers to: a placeholder, written at the end as the element's place in
  // the markup (`E[n]`).
  const ref = (p) => `\0${id(p)}\0`;

  const bindings = []; // { code, own, cross, name }
  const actions = []; // thunks writing the handlers, once the binding groups are known
  const lists = {}; // list field -> a placeholder for its place in G

  const bind = (mk, name) => {
    const deps = { own: new Set(), cross: new Set() };
    const code = mk(deps);
    bindings.push({ code, own: [...deps.own], cross: [...deps.cross], name });
  };

  const attrs = (o) => `{ ${Object.entries(o).map(([k, v]) => `${/^\w+$/.test(k) ? k : str(k)}: ${v}`).join(", ")} }`;

  // The scheduling call of an action writing \`fields\`.
  const sched = (fields, args = []) => {
    for (const f of new Set(fields)) {
      if (groupFields.has(f)) args.push(`G[${groupFields.get(f)}]`);
    }
    return args.length ? [`schedule(${args.join(", ")});`] : [];
  };
  let groupFields = new Map();

  // The code of a click message: its ops, inlined.
  function opLines(m) {
    const lines = [];
    for (const op of m.ops) {
      const [kind, name] = op;
      const f = field(name);
      const v = `s.${name}`;
      switch (kind) {
        case "add":
          lines.push(op[2] > 0 ? `${v} = Math.min(${f.max}, ${v} + ${op[2]});` : `${v} = Math.max(${f.min}, ${v} - ${-op[2]});`);
          break;
        case "set": lines.push(`${v} = ${str(op[2])};`); break;
        case "toggle": lines.push(`${v} = !${v};`); break;
        case "reset": lines.push(`${v} = ${literal(f.initial)};`); break;
        case "cycle": {
          // The option after the current one, wrapping around: the compiler knows the options.
          const o = f.options;
          lines.push(`${v} = ${o.map((x, i) => `${v} == ${str(o.at(i - 1))} ? ${str(x)} : `).slice(0, -1).join("")}${str(o.at(-1))};`);
          break;
        }
        case "push": case "pushText": {
          if (m.ops.length !== 1) throw new Error("push inside a combined message");
          const item = (text) => `{ id: nextId(${v}), text: ${text}${f.checkable ? ", done: false" : ""} }`;
          if (kind === "push") {
            lines.push(`const title = s.${op[2]}.trim();`, "if (!title) return;", `const item = ${item("title")};`);
          } else lines.push(`const item = ${item(str(op[2]))};`);
          lines.push(D ? `insert(${v}, item.id, item);` : `${v}.push(item);`);
          if (kind === "push") lines.push(`s.${op[2]} = "";`);
          if (lists[name]) lines.push(D ? `${lists[name]}.at(item.id);` : `${lists[name]}.add(item);`);
          break;
        }
        case "pop": lines.push(D ? `{ const k = keyAt(${v}, size(${v}) - 1); k.$ || (remove(${v}, k.a)${lists[name] ? `, ${lists[name]}.at(k.a)` : ""}); }` : `${v} = ${v}.slice(0, -1);`); break;
        case "shift": lines.push(D ? `{ const k = keyAt(${v}, 0); k.$ || (remove(${v}, k.a)${lists[name] ? `, ${lists[name]}.at(k.a)` : ""}); }` : `${v} = ${v}.slice(1);`); break;
        case "clear": lines.push(D ? `${v} = empty();` : `${v} = [];`); break;
        case "clearDone": lines.push(D ? `${v} = filter(${v}, (k, item) => !item.done);` : `${v} = ${v}.filter((item) => !item.done);`); break;
        default: throw new Error(`unknown op ${kind}`);
      }
    }
    return lines;
  }

  const writesOf = (m) => {
    if (m.kind !== "click") return [m.field];
    return m.ops.flatMap((op) => (op[0] === "push" ? [op[1], op[2]] : [op[1]]));
  };

  // The handler of a message on the element \`node\`.
  function handler(node, m) {
    actions.push(() => {
      const f = m.field && field(m.field);
      const done = sched(writesOf(m));
      const wrap = (event, body) => [`on(${node}, ${event === "click" ? "()" : "(e)"} => {`, ...body.map((l) => "  " + l), event === "click" ? "});" : `}, "${event}");`];
      switch (m.kind) {
        case "click": return wrap("click", [...opLines(m), ...done]);
        case "check": return wrap("click", [`s.${f.name} = !s.${f.name};`, ...done]);
        case "select": return wrap("input", [`s.${f.name} = e.target.value;`, ...done]);
        case "input":
          if (f.type === "int") {
            return wrap("input", [`const value = e.target.valueAsNumber;`,
              `if (!Number.isInteger(value) || value < ${f.min} || value > ${f.max}) return;`,
              `s.${f.name} = value;`, ...done]);
          }
          return wrap("input", [`s.${f.name} = e.target.value;`, ...done]);
      }
      throw new Error(`unknown message kind ${m.kind}`);
    });
  }

  // The action of an item control (toggle or remove), inlined into the row's handler, which
  // knows its item; written once the binding groups are known (see `itemBodies`). A toggle
  // writes its item's `done`, so it schedules the row's own binding (`set`) with the field's
  // group.
  const itemBodies = {};
  function itemAction(name) {
    const m = message(name);
    itemBodies[name] = () => {
      const v = `s.${m.field}`;
      // By id: an earlier event in the same task (a second click, a server push) may have
      // removed or replaced the item, and an action on a gone item does nothing.
      if (m.op === "toggle") return D ? [`update(${v}, k, (m) => (m.$ === 0 && (m.a.done = !m.a.done), m));`, `${lists[m.field]}.at(k);`, ...sched([m.field])] : [`const it = ${v}.find((x) => x.id === item.id);`, "if (!it) return;", "it.done = !it.done;", ...sched([m.field], ["set"])];
      return D ? [`remove(${v}, k);`, `${lists[m.field]}.at(k);`, ...sched([m.field])] : [`const at = ${v}.findIndex((x) => x.id === item.id);`, "if (at < 0) return;", `${v}.splice(at, 1);`, `${lists[m.field]}.drop(item.id);`, ...sched([m.field])];
    };
    return `@@${name}@@`;
  }

  // The widget's static markup, as one HTML string, and the elements the code refers to: the
  // n-th element of the markup (in document order) is \`refs[n]\`.
  let html = "";
  let count = 0;
  const refs = [];
  const open = (tag, a = {}, name) => {
    if (name) refs[count] = name;
    if (!["h2", "label", "option"].includes(tag)) count++;
    html += `<${tag}${Object.entries(a).map(([k, v]) => ` ${k}=${attrValue(String(v))}`).join("")}>`;
  };
  const close = (tag) => (html += `</${tag}>`);
  const element = (tag, a, content, name) => {
    open(tag, a, name);
    if (tag !== "input") html += escText(content ?? "") + `</${tag}>`;
  };

  function node(n) {
    switch (n.el) {
      case "text": {
        const p = partsCode(n.parts, { own: new Set(), cross: new Set() });
        if (p.static !== undefined) element(n.tag, {}, p.static);
        else {
          const t = ref("t");
          element(n.tag, {}, "", t);
          bind((deps) => `() => text(${t}, ${partsCode(n.parts, deps).code})`);
        }
        return;
      }
      case "button": {
        const b = ref("b");
        const p = partsCode(n.text, { own: new Set(), cross: new Set() });
        element("button", { "data-role": n.msg }, p.static ?? "", b);
        if (p.static === undefined) bind((deps) => `() => text(${b}, ${partsCode(n.text, deps).code})`);
        if (n.disabled) bind((deps) => `() => prop(${b}, ${exprCode(n.disabled, deps)}, "disabled")`);
        handler(b, message(n.msg));
        return;
      }
      case "input": {
        const m = message(n.msg);
        const f = field(m.field);
        const num = f.type === "int";
        if (n.label) {
          open("label");
          html += escText(n.label);
        }
        const i = ref("i");
        const o = { type: num ? "number" : "text", "data-role": n.msg };
        if (n.placeholder) o.placeholder = n.placeholder;
        element("input", o, null, i);
        if (n.label) close("label");
        bind((deps) => `() => prop(${i}, ${num ? `String(${exprCode(["f", f.name], deps)})` : exprCode(["f", f.name], deps)})`);
        handler(i, m);
        if (n.invalid) {
          const e = ref("e");
          element("p", { "data-role": n.msg + "Error" }, n.invalid.message, e);
          bind((deps) => `() => when(${e}, ${exprCode(n.invalid.when, deps)})`);
        }
        return;
      }
      case "check": {
        const m = message(n.msg);
        const c = ref("c");
        open("label");
        element("input", { type: "checkbox", "data-role": n.msg }, null, c);
        html += escText(n.label);
        close("label");
        bind((deps) => `() => prop(${c}, ${exprCode(["f", m.field], deps)}, "checked")`);
        handler(c, m);
        return;
      }
      case "select": {
        const m = message(n.msg);
        const f = field(m.field);
        if (n.label) {
          open("label");
          html += escText(n.label);
        }
        const o = ref("o");
        open("select", { "data-role": n.msg }, o);
        for (const value of f.options) element("option", { value }, value);
        close("select");
        if (n.label) close("label");
        bind((deps) => `() => prop(${o}, ${exprCode(["f", f.name], deps)})`);
        handler(o, m);
        return;
      }
      case "list": {
        const f = field(n.field);
        const l = id("ls");
        const u = ref("n");
        lists[n.field] = `\u0001${l}\u0001`;
        element(n.tag, {}, "", u);
        if (T) {
          const esc = (x) => String(x).replace(/&/g, "&amp;").replace(/</g, "&lt;");
          const h = `<li data-role=${n.field}Item>${n.check ? `<input type=checkbox data-role=${n.check}>` : ""}<span></span>${n.remove ? `<button data-role=${n.remove}>${esc(n.removeText)}` : ""}`;
          TPLS.push(`const T${l} = tpl(${str(h)});`);
          const row = [`const node = T${l}.cloneNode(true), c = node.children;`, 'node.dataset.key = k;'];
          const set = [];
          if (n.check) set.push('prop(c[0], item.done, "checked");');
          set.push(`text(c[${n.check ? 1 : 0}], item.text);`);
          row.push(`const set = (next) => { item = next; ${set.join(" ")} };`);
          if (n.check) row.push("on(c[0], () => {", itemAction(n.check), "});");
          if (n.remove) row.push(`on(c[${n.check ? 2 : 1}], () => {`, itemAction(n.remove), "});");
          row.push("return [node, set];");
          const code = [`list(${u}, () => s.${f.name}, (k, item) => {`, ...row.map((r) => "  " + r), "})"].join("\n");
          bindings.push({ code, own: [f.name], cross: [], list: l });
          return;
        }
        const row = [`const node = el("li", null, ${attrs({ "data-key": "item.id", "data-role": str(n.field + "Item") })});`];
        const set = [];
        if (n.check) {
          row.push(`const box = el("input", node, ${attrs({ type: str("checkbox"), "data-role": str(n.check) })});`);
          set.push('prop(box, item.done, "checked");');
        }
        row.push('const label = el("span", node);');
        set.push("text(label, item.text);");
        // The row's binding: the list hands it the item of its id, so the row keeps its item
        // current for its controls' arms; a toggle schedules it as is.
        row.push(`const set = (${n.check ? "next = item" : "next"}) => { item = next; ${set.join(" ")} };`);
        if (n.check) row.push("on(box, () => {", itemAction(n.check), "});");
        if (n.remove) {
          row.push(`on(el("button", node, ${attrs({ "data-role": str(n.remove) })}, ${str(n.removeText)}), () => {`, itemAction(n.remove), "});");
        }
        row.push("return [node, set];");
        // The list is its field's first binding, and is referred to as such (G[i][0]).
        const code = [`list(${u}, () => s.${f.name}, (${D ? "k, " : ""}item) => {`, ...row.map((r) => "  " + r), "})"].join("\n");
        bindings.push({ code, own: [f.name], cross: [], list: l });
        return;
      }
      case "when": {
        const g = ref("g");
        open(n.tag, {}, g);
        for (const c of n.children) node(c);
        close(n.tag);
        bind((deps) => `() => when(${g}, ${exprCode(n.cond, deps)})`);
        return;
      }
      case "group": {
        open(n.tag);
        for (const c of n.children) node(c);
        close(n.tag);
        return;
      }
    }
    throw new Error(`unknown view node ${n.el}`);
  }

  // The section itself is written by `section`: the markup is what goes inside, from element 0.
  element("h2", {}, w.label);
  for (const n of w.view) node(n);
  // Leave out the end tags HTML makes optional: `</option>` before an option or the select's
  // end, `</p>` before a block element or its parent's end (none of the parents here is one
  // that keeps it, like `<a>`); the parsed DOM is the same.
  html = html.replace(/<\/option>(?=<option|<\/select>)/g, "")
    .replace(/<\/p>(?=<(?:aside|div|fieldset|footer|header|ol|p|section|ul)[\s>]|<\/|$)/g, "")
    .replace(/(<\/\w+>)+$/, "");

  // The bindings: those reading one field of this widget and nothing else are written inline in
  // that field's group (G[i] for the i-th field); each other binding (reading several fields, or
  // other widgets) is an entry of G of its own, after the groups, and added at mount to the group
  // of each field of this widget it reads.
  const groups = new Map();
  for (const b of bindings) for (const f of b.own) groups.set(f, groups.get(f) || []);
  const extra = bindings.filter((b) => !(b.own.length === 1 && b.cross.length === 0));
  const listRefs = {};
  for (const b of bindings) {
    if (extra.includes(b)) continue;
    const g = groups.get(b.own[0]);
    if (b.list) {
      listRefs[b.list] = [b.own[0], g.filter((x) => x.list).length];
      g.splice(listRefs[b.list][1], 0, b);
    } else g.push(b);
  }
  // A field other widgets read: its group also holds their bindings, registered at mount.
  for (const f of w.fields) if (reads[w.id]?.has(f.name)) groups.set(f.name, groups.get(f.name) || []);
  groupFields = new Map([...groups.keys()].map((f, i) => [f, i]));
  extra.forEach((b, i) => (b.name = `G[${groups.size + i}]`));
  const groupItems = [...[...groups.values()].map((items) => `[${items.map((b) => b.name || b.code).join(", ")}]`), ...extra.map((b) => b.code)];
  const groupLines = groupItems.length ? ["G.push(", ...groupItems.flatMap((g) => `  ${g},`.split("\n").map((l, i) => (i ? "  " + l : l))), ");"] : [];
  groupLines.push(...extra.flatMap((b) => b.own.map((f) => `G[${groupFields.get(f)}].push(${b.name});`)));
  groupIndex[w.id] = groupFields;
  const crossPushes = bindings.flatMap((b) => b.cross.map((c) => {
    const [src, f] = c.split(".");
    if (!groupIndex[src]) throw new Error(`${w.id} reads ${src}, which is not above it`);
    return `R[${pos(src)}][${groupIndex[src].get(f)}].push(${b.name});`;
  }));

  // External arms.
  const arms = [];
  const tickFields = w.fields.filter((f) => f.tick);
  if (tickFields.length) {
    // `min(max, value + tick)` changes the value unless it is already the maximum.
    const body = tickFields.flatMap((f) => [
      `if (s.${f.tickWhen} && s.${f.name} != ${f.max}) {`,
      `  s.${f.name} = Math.min(${f.max}, s.${f.name} + ${f.tick});`,
      ...sched([f.name]).map((l) => "  " + l),
      "}",
    ]);
    arms.push(["// The external arm: tick.", "tick() {", ...body.map((l) => "  " + l), "},"]);
  }
  const feed = w.fields.find((f) => f.feed);
  if (feed) {
    arms.push(["// The external arm: notify(item).", "notify(item) {", D ? `  insert(s.${feed.name}, item.id, item);` : `  s.${feed.name}.push(item);`, D ? `  ${lists[feed.name]}.at(item.id);` : `  ${lists[feed.name]}.add(item);`,
      ...sched([feed.name]).map((l) => "  " + l), "},"]);
  }

  const handlerLines = actions.map((a) => a());
  const expand = (lines) => lines.flatMap((l) => {
    const m = /^(\s*)@@(\w+)@@$/.exec(l);
    return m ? itemBodies[m[2]]().map((b) => m[1] + "  " + b) : [l];
  });

  const body = [
    "// The bindings, grouped by the field they read.",
    ...expand(groupLines),
    ...(crossPushes.length ? ["", "// Register with the widgets this one reads.", ...crossPushes] : []),
    ...(handlerLines.length ? ["", "// The arms of update, as actions."] : []),
    ...handlerLines.flat(),
    ...(arms.length ? ["", "return {", ...arms.flat().map((l) => "  " + l), "};"] : []),
  ];
  const at = new Map(Object.entries(refs).map(([n, r]) => [r, n]));
  const text = body.map((l) => (l ? "  " + l : l)).join("\n").replace(/\0\w+\0/g, (r) => `E[${at.get(r)}]`)
    .replace(/\u0001(\w+)\u0001/g, (_, l) => `G[${groupFields.get(listRefs[l][0])}][${listRefs[l][1]}]`);

  const rt = ["el", "text", "prop", "on", "when", "list", "schedule", ...(D ? ["size", "count", "insert", "remove", "keyAt", "empty", "filter", "update"] : [])].filter((n) => new RegExp(`\\b${n}\\(`).test(text)).concat(TPLS.length ? ["tpl"] : []);
  const wi = ["nextId"].filter((n) => new RegExp(`\\b${n}\\(`).test(text));
  // The widget's markup, and its function: given the markup's elements (in document order, those
  // the code refers to are E[n]), its state slice and its (empty) binding table G, and when it
  // reads other widgets their binding tables R and the model.
  return `import { ${rt.join(", ")} } from "../runtime.js";
import { ${["W", ...wi].join(", ")} } from "./widget.js";

${TPLS.splice(0).join("\n")}
// Widget ${w.id}: its markup, and its code over the markup's elements.
W.push([${str(html)}, (E, s, G${text.includes("model[") || text.includes("R[") ? ", R, model" : ""}) => {
${text}
}]);
`;
}

// ---------------------------------------------------------------------------------------------
// The app: init, the widgets in page order, and the external arms of update.

// The initial model as a literal, with every list of items numbered 1, 2, … in order written as
// `items(...)`: the items' texts, or [text, done] pairs for a checkable list.
function initLiteral(model) {
  const calls = [];
  const numbered = (v) => Array.isArray(v) && v.length > 0 && v.every((x, i) => x && x.id === i + 1 && typeof x.text === "string"
    && Object.keys(x).length === ("done" in x ? 3 : 2) && v.every((y) => "done" in y === "done" in x));
  const walk = (v) => {
    if (numbered(v)) {
      calls.push(`items(${v.map((x) => literal("done" in x ? [x.text, x.done] : x.text)).join(", ")})`);
      return `\0${calls.length - 1}\0`;
    }
    if (Array.isArray(v)) return v.map(walk);
    if (v && typeof v === "object") return Object.fromEntries(Object.entries(v).map(([k, x]) => [k, D && LISTNAMES.includes(k) && Array.isArray(x) && !x.length ? (calls.push("empty()"), `\0${calls.length - 1}\0`) : walk(x)]));
    return v;
  };
  return literal(walk(model), "  ").replace(/"\\u0000(\d+)\\u0000"/g, (_, i) => calls[i]);
}

function appFile(spec, reads) {
  const ticking = spec.widgets.filter((w) => w.fields.some((f) => f.tick));
  const cases = [`      case "serverSet":
        views[msg.widget.slice(1)](msg.state);
        break;`];
  if (ticking.length) {
    cases.push(`      case "tick":
${ticking.map((w) => `        views[${pos(w.id)}].tick();`).join("\n")}
        break;`);
  }
  if (spec.widgets.some((w) => w.fields.some((f) => f.feed))) {
    cases.push(`      case "notify":
        views[msg.widget.slice(1)].notify(msg.item);
        break;`);
  }
  cases.push(`      case "snapshot":
        for (const id in msg.state.widgets) views[id.slice(1)](msg.state.widgets[id]);
        break;`);

  const init = initLiteral(spec.widgets.map((w) => spec.initialState.widgets[w.id]));
  const imports = [`import { flush, cancel${init.includes("empty()") ? ", empty" : ""} } from "./runtime.js";`,
    `import { W, section, loader${init.includes("items(") ? ", items" : ""} } from "./widgets/widget.js";`,
    ...spec.widgets.map((w) => `import "./widgets/${w.id}.js";`)];

  return `${imports.join("\n")}

export function start(root) {
  // The initial model (TEA's \`init\`: its widgets by number, from 1), fresh for every mount.
  const model = [, ${init.slice(1)};
  // The dashboard, from its markup like every widget.
  root.insertAdjacentHTML("beforeend", "<div data-role=dashboard>");
  const board = root.lastChild;
  // Every widget's binding table, by number: a widget reading another adds its bindings to the
  // groups of the fields it reads, which come above it.
  const R = [];
  // Every widget in page order, given its markup's elements and its number (widget \`wN\` is number N,
  // its position from 1: its slice of the model is \`model[N]\`, its handle \`views[N]\`; \`map\` skips
  // the hole at 0). The widget fills its binding table; its handle is its load for serverSet and
  // snapshot (which runs the whole table), carrying the external arms the widget returns.
  const views = W.map(([html, widget], i) => loader(model[i], (R[i] = []), widget(section(board, i, html), model[i], R[i], R, model)));
  flush();

  // The arms of update still reached by a message: external events.
  function receive(msg) {
    switch (msg.type) {
${cases.join("\n")}
    }
  }

  function stop() {
    cancel();
    board.remove();
  }

  return { receive, stop };
}
`;
}

const DICT_LIST_P = `
export const tpl = (html) => { const t = document.createElement("template"); t.innerHTML = html; return t.content.firstChild; };
export const just = (a) => ({ $: 0, a });
export const nothing = { $: 1, a: null };
export const empty = () => ({ entries: [], index: new Map() });
export const size = (d) => d.entries.length;
export const keyAt = (d, i) => (i >= 0 && i < d.entries.length ? just(d.entries[i][0]) : nothing);
export const count = (d, f) => { let n = 0; for (const e of d.entries) if (f(e[1])) n++; return n; };
export function insert(d, k, v) { const e = d.index.get(k); if (e) e[1] = v; else { const n = [k, v]; d.entries.push(n); d.index.set(k, n); } return d; }
export function remove(d, k) { const e = d.index.get(k); if (e) { d.entries.splice(d.entries.indexOf(e), 1); d.index.delete(k); } return d; }
export function update(d, k, f) { const e = d.index.get(k), r = f(e ? just(e[1]) : nothing); return r.$ === 0 ? insert(d, k, r.a) : remove(d, k); }
export function filter(d, f) { const r = empty(); for (const [k, v] of d.entries) if (f(k, v)) insert(r, k, v); return r; }
export function fromList(l) { const d = empty(); for (const [k, v] of l) insert(d, k, v); return d; }
export function list(parent, get, build) {
  let R = [], M = new Map(), last;
  const make = (k, v) => { const r = build(k, v); r.k = k; r.v = v; r[1](v); M.set(k, r); return r; };
  const L = () => {
    const d = get();
    if (d === last) return;
    last = d;
    const old = M, N = [];
    let kept = 0;
    M = new Map();
    R.forEach((r, i) => { r.p = i; });
    for (const [k, v] of d.entries) {
      let r = old.get(k);
      if (r) { kept++; old.delete(k); M.set(k, r); if (r.v !== v) { r.v = v; r[1](v); } } else r = make(k, v);
      N.push(r);
    }
    R = N;
    if (!kept) { const f = new DocumentFragment(); for (const r of N) f.append(r[0]); parent.replaceChildren(f); return; }
    for (const r of old.values()) r[0].remove();
    const P = N.map((r) => r.p ?? -1), t = [], prev = [], stay = [];
    P.forEach((x, i) => {
      if (x < 0) return;
      let lo = 0, hi = t.length;
      while (lo < hi) { const m = (lo + hi) >> 1; P[t[m]] < x ? (lo = m + 1) : (hi = m); }
      prev[i] = lo ? t[lo - 1] : -1;
      t[lo] = i;
    });
    for (let i = t[t.length - 1]; i >= 0; i = prev[i]) stay[i] = 1;
    let next = null;
    for (let i = N.length; i--; ) { const n = N[i][0]; if (!stay[i]) parent.insertBefore(n, next); next = n; }
  };
  L.at = (k) => {
    const e = get().index.get(k), r = M.get(k);
    if (!e) { if (r) { R.splice(R.indexOf(r), 1); M.delete(k); r[0].remove(); } }
    else if (r) { r.v = e[1]; r[1](r.v); }
    else { const n = make(k, e[1]); R.push(n); parent.append(n[0]); }
  };
  return L;
}
`;
let LISTNAMES = []; const TPLS = [];
const DICT_LIST = `
// ---- core/Dict (the subset the widgets reach) and the keyed rows of a Dict (S2 target).
export const tpl = (html) => { const t = document.createElement("template"); t.innerHTML = html; return t.content.firstChild; };
export const just = (a) => ({ $: 0, a });
export const nothing = { $: 1, a: null };
export const empty = () => ({ entries: [], index: new Map() });
export const size = (d) => d.entries.length;
export const keyAt = (d, i) => (i >= 0 && i < d.entries.length ? just(d.entries[i][0]) : nothing);
export const count = (d, f) => { let n = 0; for (const e of d.entries) if (f(e[1])) n++; return n; };
export function insert(d, k, v) {
  const p = d.index.get(k);
  if (p === undefined) { d.index.set(k, d.entries.length); d.entries.push([k, v]); } else d.entries[p][1] = v;
  return d;
}
export function remove(d, k) {
  let p = d.index.get(k);
  if (p !== undefined) { const e = d.entries; e.splice(p, 1); d.index.delete(k); for (; p < e.length; p++) d.index.set(e[p][0], p); }
  return d;
}
export function update(d, k, f) {
  const p = d.index.get(k), r = f(p === undefined ? nothing : just(d.entries[p][1]));
  return r.$ === 0 ? insert(d, k, r.a) : remove(d, k);
}
export function filter(d, f) { const r = empty(); for (const [k, v] of d.entries) if (f(k, v)) insert(r, k, v); return r; }
export function fromList(l) { const d = empty(); for (const [k, v] of l) insert(d, k, v); return d; }
export function list(parent, get, build) {
  let R = [], last;
  const make = (k, v) => { const r = build(k, v); r.k = k; r.v = v; r[1](v); return r; };
  const L = () => {
    const d = get();
    if (d === last) return;
    last = d;
    const old = new Map(), N = [];
    let kept = 0;
    R.forEach((r, i) => { r.p = i; old.set(r.k, r); });
    for (const [k, v] of d.entries) {
      let r = old.get(k);
      if (r) { kept++; old.delete(k); if (r.v !== v) { r.v = v; r[1](v); } } else r = make(k, v);
      N.push(r);
    }
    R = N;
    if (!kept) { const f = new DocumentFragment(); for (const r of N) f.append(r[0]); parent.replaceChildren(f); return; }
    for (const r of old.values()) r[0].remove();
    const P = N.map((r) => r.p ?? -1), t = [], prev = [], stay = [];
    P.forEach((x, i) => {
      if (x < 0) return;
      let lo = 0, hi = t.length;
      while (lo < hi) { const m = (lo + hi) >> 1; P[t[m]] < x ? (lo = m + 1) : (hi = m); }
      prev[i] = lo ? t[lo - 1] : -1;
      t[lo] = i;
    });
    for (let i = t[t.length - 1]; i >= 0; i = prev[i]) stay[i] = 1;
    let next = null;
    for (let i = N.length; i--; ) { const n = N[i][0]; if (!stay[i]) parent.insertBefore(n, next); next = n; }
  };
  L.at = (k) => {
    const d = get(), j = d.index.get(k);
    if (j === undefined) { const i = R.findIndex((r) => r.k === k); if (i >= 0) R.splice(i, 1)[0][0].remove(); }
    else if (R[j]?.k === k) { const r = R[j]; r.v = d.entries[j][1]; r[1](r.v); }
    else {
      const i = R.findIndex((r) => r.k === k), v = d.entries[j][1];
      let r;
      if (i < 0) r = make(k, v); else { r = R.splice(i, 1)[0]; r.v = v; r[1](v); }
      parent.insertBefore(r[0], R[j]?.[0] ?? null);
      R.splice(j, 0, r);
    }
  };
  return L;
}
`;

export function emit(spec) {
  LISTNAMES = spec.widgets.flatMap((w) => w.fields.filter((f) => f.type === "list").map((f) => f.name));
  // Widgets are numbered in page order (their ids are w1, w2, …): the model is an array by number.
  if (spec.widgets.some((w, i) => w.id !== `w${i + 1}`)) throw new Error("widget ids are not w1, w2, … in order");
  // The fields other widgets read.
  const reads = {};
  for (const w of spec.widgets) {
    const out = [];
    crossReads(w.view, out);
    for (const [wid, f] of out) (reads[wid] ||= new Set()).add(f);
  }
  const files = {
    ...templateFiles({ name: "unique-components", title: "Unique components" }),
    "src/app.js": appFile(spec, reads),
    "src/widgets/widget.js": (LISTNAMES = spec.widgets.flatMap((w) => w.fields.filter((f) => f.type === "list").map((f) => f.name)), WIDGET_FILE()),
  };
  if (D) files["src/runtime.js"] = files["src/runtime.js"].replace(/\/\/ -{20,}\n\/\/ Keyed lists[\s\S]*$/, "") + (P ? DICT_LIST_P : DICT_LIST);
  const groupIndex = {};
  for (const w of spec.widgets) files[`src/widgets/${w.id}.js`] = widgetFile(w, reads, groupIndex);
  return {
    files,
    style: {
      track: "prototype: no framework implements this strategy",
      components: "one module per widget, each written out from its own description; DOM built once from one static HTML string, elements referred to by their place in document order (E[n]); conditional sections swapped out by when while hidden; list rows built with createElement",
      messages: "erased for DOM events: each update arm is inlined into the action its control calls, which writes the widget's fields in place",
      updates: "each action schedules the per-field binding groups of the fields it writes (known at compile time), held by place in the widget's binding table G; one microtask flush",
      derived: "a binding reading another widget adds itself at mount to the group of the field it reads in that widget's binding table (R[widget][group]); the writing action schedules the group",
      lists: "keyed: add and remove schedule their row's edit, toggle its row's binding; other edits replace the array and reconcile by id in one forward pass",
      externalEvents: "receive(msg): serverSet and snapshot replace a widget's state (a copy) and run all its bindings and its readers; tick and notify call the widgets' external arms",
      build: "Vite with no framework plugin, production defaults, hidden source maps",
    },
  };
}
