// Write sets and hole constancy over TEA programs — the read-only feasibility
// prototype of research 58 §9 (iii), reported in
// docs/design/research/61-how-often-writes-are-known.md.
//
// It is NOT part of the compiler. It reads `beni dump --stage=ast` and runs a
// small abstract interpreter over each program's `update` (once per `Msg`
// constructor) and `view`. Its rules are written out in research 61 §2; the
// short names here (O, F, Rec, …) are the abstract values described there.
//
//   BENI=<beni> node bench/writesets/classify.mjs [--table|--list|--json] [--set=dom] [<program>…]
//
// A <program> is a .beni file or a directory of them (one program), or several
// of either joined with `+` (research 62 reads Conduit's pages with
// `examples/conduit/src+bench/writesets/conduit/Pages.beni`). With no
// program it runs research 61's TEA corpus, or with --set=dom its renderer
// corpus. --table prints research 61 §4's table, --list its Appendix A, and
// no flag every constructor's writes and every hole's read set.
//
// --root (research 62) reports, per mounted program, the constructors that
// write the model's ROOT: a write at path `(model)` that is not `*`. The
// rules call it exact when the model is not a record (§2.2's `*` row needs a
// record), but it conflicts with every read, so a handler would mark every
// group. With --table it prints one row per mounted program and the bounded
// and exact+indexed shares with root writes counted as unbounded; without, it
// marks them `(root)` in the listing. --skip=<where>,… leaves those mounted
// programs out (`--skip=main` for Conduit's pages alone). Neither flag
// changes any output without it.

import { execFileSync } from "node:child_process";
import { statSync, readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
let beni = process.env.BENI ?? path.join(repo, "zig-out/fast/bin/beni");
let asJson = false;
let asTable = false;
let asList = false;
let asRoot = false;
const skip = new Set();
let set = "tea";
const programArgs = [];
for (const a of process.argv.slice(2)) {
  if (a.startsWith("--beni=")) beni = a.slice(7);
  else if (a === "--json") asJson = true;
  else if (a === "--table") asTable = true;
  else if (a === "--list") asList = true;
  else if (a === "--root") asRoot = true;
  else if (a.startsWith("--skip=")) for (const w of a.slice(7).split(",")) skip.add(w);
  else if (a.startsWith("--set=")) set = a.slice(6);
  else programArgs.push(a.split("+").map((p) => path.resolve(p)).join("+"));
}

// ---- S-expression reader over the AST dump --------------------------------

function parseSexpr(text) {
  let i = 0;
  const n = text.length;
  function skip() {
    while (i < n && /\s/.test(text[i])) i++;
  }
  function atom() {
    if (text[i] === '"') {
      let j = i + 1;
      while (j < n && text[j] !== '"') j += text[j] === "\\" ? 2 : 1;
      const s = text.slice(i, j + 1);
      i = j + 1;
      return s;
    }
    let j = i;
    while (j < n && !/[\s()]/.test(text[j])) j++;
    const s = text.slice(i, j);
    i = j;
    return s;
  }
  function node() {
    i++; // (
    skip();
    const k = atom();
    const xs = [];
    for (;;) {
      skip();
      if (text[i] === ")") {
        i++;
        break;
      }
      if (text[i] === "(") xs.push(node());
      else xs.push(atom());
    }
    return { k, xs };
  }
  skip();
  return node();
}
const kids = (nd) => nd.xs.filter((x) => typeof x === "object");
const atoms = (nd) => nd.xs.filter((x) => typeof x === "string");

// ---- Programs -------------------------------------------------------------

// A program is a .beni file, a directory of them, or several of either joined
// with `+` (an application's directory and a measuring module beside it).
function loadModules(target) {
  const files = target.split("+").flatMap((t) =>
    statSync(t).isDirectory() ? readdirSync(t).filter((f) => f.endsWith(".beni")).map((f) => path.join(t, f)) : [t],
  );
  const mods = new Map();
  // A declaration's name, past its `pub` and `opaque` (`(type_decl pub Msg …)`).
  const declName = (d) => atoms(d).find((x) => x !== "pub" && x !== "opaque");
  for (const f of files) {
    const text = execFileSync(beni, ["dump", "--stage=ast", f], { encoding: "utf8" });
    const ast = parseSexpr(text);
    const name = path.basename(f, ".beni");
    const m = { name, file: f, defs: new Map(), annots: new Map(), types: new Map(), aliases: new Map(), imports: new Map() };
    for (const d of kids(ast)) {
      if (d.k === "definition") {
        const ks = kids(d);
        m.defs.set(d.xs[0], { name: d.xs[0], params: ks.slice(0, -1), body: ks[ks.length - 1], mod: m });
      } else if (d.k === "foreign_value") {
        m.defs.set(d.xs[0], { name: d.xs[0], foreign: true, mod: m });
      } else if (d.k === "annotation") m.annots.set(declName(d), kids(d)[0]);
      else if (d.k === "type_decl") m.types.set(declName(d), kids(d).filter((c) => c.k === "constructor").map((c) => c.xs[0]));
      else if (d.k === "type_alias") m.aliases.set(declName(d), kids(d)[0]);
      else if (d.k === "import") {
        const at = atoms(d);
        const asIx = at.indexOf("as");
        m.imports.set(asIx >= 0 ? at[asIx + 1] : at[0], at[0]);
        for (const e of kids(d)) for (const x of kids(e)) if (x.k === "exposed") m.imports.set("=" + x.xs[0], at[0]);
      }
    }
    mods.set(name, m);
  }
  return mods;
}

// ---- Abstract values ------------------------------------------------------
// O(path)         the old model's value at `path`, untouched
// F(reads, why)   a value the analysis cannot relate to the old model;
//                 `why` set when it came out of a call it did not summarise
// Rec(base, fs)   record update of `base`;  RecLit(fs) a record literal
// Tup(items)      tuple;  Join(alts) one of several (case/if)
// Lst(base, op)   a recognised list edit of `base`
// Fn(...)         closure;  Bot  never returns (Debug.todo);  Msg(C)  the message
// Empty           `[]`;  Thunk  a let not yet evaluated

const Bot = { t: "bot" };
const Empty = { t: "empty" };
const O = (p) => ({ t: "o", p });
const F = (reads, why = null) => ({ t: "f", reads, why });
const Rec = (base, fs) => ({ t: "rec", base, fs });
const RecLit = (fs) => ({ t: "reclit", fs });
const Tup = (items) => ({ t: "tup", items });
const Lst = (base, op, extra = {}) => ({ t: "lst", base, op, ...extra });
const Join = (alts) => {
  const a = alts.filter((v) => v.t !== "bot");
  if (a.length === 0) return Bot;
  if (a.length === 1) return a[0];
  return { t: "join", alts: a };
};

function readsOf(v, acc = new Set(), seen = new Set()) {
  if (!v || seen.has(v)) return acc;
  seen.add(v);
  if (v.cond) for (const r of v.cond) acc.add(r);
  switch (v.t) {
    case "ctorval": for (const r of v.reads) acc.add(r); break;
    case "listlit": for (const r of v.reads) acc.add(r); break;
    case "o": acc.add(v.p.join(".")); break;
    case "f": for (const r of v.reads) acc.add(r); break;
    case "rec": readsOf(v.base, acc, seen); for (const x of v.fs.values()) readsOf(x, acc, seen); break;
    case "reclit": for (const x of v.fs.values()) readsOf(x, acc, seen); break;
    case "tup": for (const x of v.items) readsOf(x, acc, seen); break;
    case "join": for (const x of v.alts) readsOf(x, acc, seen); break;
    case "lst": readsOf(v.base, acc, seen); if (v.arg) readsOf(v.arg, acc, seen); if (v.elem) readsOf(v.elem, acc, seen); break;
    case "fn": if (v.captured) for (const r of v.captured) acc.add(r); break;
    case "thunk": readsOf(force(v), acc, seen); break;
  }
  return acc;
}
const derived = (v) => readsOf(v).size > 0 || v.t === "fn" || v.t === "msg";
const force = (v) => {
  if (v && v.t === "thunk") {
    if (!v.val) {
      v.val = Bot; // a self-referencing let: never reached in these programs
      v.val = v.ev.eval(v.e, v.env);
    }
    return v.val;
  }
  return v;
};

// ---- The evaluator ----------------------------------------------------------

const LIST_INDEXED = new Set(["set", "push", "pop", "insertAt", "removeAt", "swap", "cons", "take", "drop", "slice"]);
const LIST_REORDER = new Set(["sort", "sortBy", "sortWith", "reverse"]);

class Ev {
  constructor(mods, main) {
    this.mods = mods;
    this.main = main;
    this.stack = [];
    this.notes = new Set(); // unsummarised calls met
  }
  resolve(name, mod) {
    if (mod.defs.has(name)) return mod.defs.get(name);
    const ix = name.lastIndexOf(".");
    if (ix > 0) {
      const q = name.slice(0, ix), base = name.slice(ix + 1);
      const target = this.mods.get(mod.imports.get(q) ?? q);
      if (target && target !== mod && target.defs.has(base)) return target.defs.get(base);
    } else {
      const im = mod.imports.get("=" + name);
      const target = im && this.mods.get(im);
      if (target && target.defs.has(name)) return target.defs.get(name);
    }
    return null;
  }
  // Bind a pattern to a value; `ctorOk` is false when a Msg pattern rejects.
  bind(pat, v, env) {
    v = force(v);
    switch (pat.k) {
      case "pat_var": env.set(pat.xs[0], v); return true;
      case "pat_paren": return this.bind(kids(pat)[0], v, env);
      case "pat_wild": case "pat_unit": case "pat_string": case "pat_int": return true;
      case "pat_tuple": {
        const ps = kids(pat);
        let ok = true;
        ps.forEach((p, i) => {
          const item = v.t === "tup" ? v.items[i] : v.t === "o" ? O([...v.p, String(i)]) : F(readsOf(v), v.why);
          ok = this.bind(p, item, env) && ok;
        });
        return ok;
      }
      case "pat_ctor": {
        const c = pat.xs[0];
        if (v.t === "msg") {
          const base = c.slice(c.lastIndexOf(".") + 1);
          if (base !== v.c) return false;
          for (const p of kids(pat)) this.bind(p, F(new Set()), env);
          return true;
        }
        kids(pat).forEach((p, i) => this.bind(p, v.t === "o" ? O([...v.p, `${c}#${i}`]) : F(readsOf(v), v.why), env));
        return true;
      }
      default:
        for (const p of kids(pat)) this.bind(p, F(readsOf(v), v.why), env);
        return true;
    }
  }
  apply(fv, args, mod) {
    fv = force(fv);
    if (fv.t === "fn") {
      if (fv.partial) {
        const full = [];
        let k = 0;
        for (const a of fv.partial) full.push(a === null ? args[k++] : a);
        while (k < args.length) full.push(args[k++]);
        return this.call(fv.callee, full, fv.mod, fv.calleeNode);
      }
      const env = new Map(fv.env);
      for (let i = 0; i < fv.params.length; i++) if (!this.bind(fv.params[i], args[i] ?? F(new Set()), env)) return Bot;
      return this.eval(fv.body, env, fv.mod);
    }
    if (fv.t === "accessor") {
      return this.field(args[0], fv.f);
    }
    return F(new Set([...readsOf(fv), ...args.flatMap((a) => [...readsOf(a)])]), "call of a value");
  }
  field(v, f) {
    v = force(v);
    switch (v.t) {
      case "o": return O([...v.p, f]);
      case "rec": return v.fs.has(f) ? v.fs.get(f) : this.field(v.base, f);
      case "reclit": return v.fs.get(f) ?? F(new Set());
      case "join": return Join(v.alts.map((a) => this.field(a, f)));
      case "bot": return Bot;
      default: return F(readsOf(v), v.why);
    }
  }
  elementOf(v) {
    v = force(v);
    if (v.t === "o") return O([...v.p, "[*]"]);
    if (v.t === "lst") return v.op === "map" || v.op === "indexedMap" ? (v.elem ?? F(readsOf(v))) : this.elementOf(v.base);
    if (v.t === "join") return Join(v.alts.map((a) => this.elementOf(a)));
    return F(readsOf(v), v.why);
  }
  // A call: user function inlined, recognised core function modelled, else opaque.
  call(calleeName, args, mod, node) {
    const def = this.resolve(calleeName, mod);
    if (def) {
      if (def.foreign) { this.notes.add("foreign " + calleeName); return F(new Set(args.flatMap((a) => [...readsOf(a)])), "foreign " + calleeName); }
      if (this.stack.includes(def) || this.stack.length > 40) {
        this.notes.add("recursion " + calleeName);
        return F(new Set(args.flatMap((a) => [...readsOf(a)])), "recursion " + def.name);
      }
      if (def.params.length === 0) {
        this.stack.push(def);
        const fv = this.eval(def.body, new Map(), def.mod);
        this.stack.pop();
        return args.length ? this.apply(fv, args, def.mod) : fv;
      }
      const env = new Map();
      for (let i = 0; i < def.params.length; i++) if (!this.bind(def.params[i], args[i] ?? F(new Set()), env)) return Bot;
      this.stack.push(def);
      let r = this.eval(def.body, env, def.mod);
      this.stack.pop();
      if (args.length > def.params.length) r = this.apply(r, args.slice(def.params.length), def.mod);
      return r;
    }
    const base = calleeName.slice(calleeName.lastIndexOf(".") + 1);
    const q = calleeName.slice(0, Math.max(0, calleeName.lastIndexOf(".")));
    const allReads = () => new Set(args.flatMap((a) => [...readsOf(a)]));
    if (calleeName === "Debug.todo") return Bot;
    if (calleeName === "Debug.log") return args[1];
    if (calleeName === "Tuple.first" && force(args[0]).t === "tup") return force(args[0]).items[0];
    if (calleeName === "Tuple.second" && force(args[0]).t === "tup") return force(args[0]).items[1];
    if (q === "List") {
      const l = args[0];
      if (base === "map" || base === "indexedMap") {
        const fn = args[1];
        const elemIn = this.elementOf(l);
        const elem = base === "map" ? this.apply(fn, [elemIn], mod) : this.apply(fn, [F(new Set()), elemIn], mod);
        return Lst(l, base, { elem });
      }
      if (base === "filter") {
        const pv = this.apply(args[1], [this.elementOf(l)], mod);
        return Lst(l, "filter", { arg: F(readsOf(pv)) });
      }
      if (base === "update") {
        const elem = this.apply(args[2], [this.elementOf(l)], mod);
        return Lst(l, "update", { elem, arg: args[1] });
      }
      if (base === "append") return this.append(args[0], args[1]);
      if (LIST_INDEXED.has(base)) return Lst(l, base, { arg: F(new Set(args.slice(1).flatMap((a) => [...readsOf(a)]))) });
      if (LIST_REORDER.has(base)) return Lst(l, base, { arg: F(new Set(args.slice(1).flatMap((a) => [...readsOf(a)]))) });
      if (base === "initialize") return Lst(F(new Set()), "initialize", { arg: F(allReads()) });
    }
    if (calleeName === "Html.map") return args[0];
    // Opaque: for each closure argument, apply it to elements of the first
    // list-ish argument so that what it reads is counted.
    const reads = allReads();
    for (const a of args) {
      const fa = force(a);
      if (fa.t === "fn") {
        const probe = [this.elementOf(args[0]), F(new Set()), F(new Set())];
        for (const r of readsOf(this.apply(fa, probe, mod))) reads.add(r);
      }
    }
    return F(reads, calleeName);
  }
  append(a, b) {
    const fa = force(a), fb = force(b);
    if (fb.t === "listlit" || fb.t === "empty") return Lst(a, "push", { arg: fb });
    if (fa.t === "listlit" || fa.t === "empty") return Lst(b, "cons", { arg: fa });
    if (fa.t === "spreadlit") return F(new Set([...readsOf(a), ...readsOf(b)]));
    // Two lists of the model, or a string append.
    if (fa.t === "o" || fa.t === "lst") return Lst(a, "concat", { arg: b });
    return F(new Set([...readsOf(a), ...readsOf(b)]), (fa.why || fb.why) ?? null);
  }
  eval(e, env, mod) {
    const ev = (x, en = env) => this.eval(x, en, mod);
    const ks = kids(e);
    switch (e.k) {
      case "paren": return ev(ks[0]);
      case "int": case "float": case "string": case "unit":
        if (e.k === "string") return F(new Set(ks.filter((c) => c.k === "interp").flatMap((c) => [...readsOf(ev(kids(c)[0]))])));
        return F(new Set());
      case "ident": {
        const nm = e.xs[0];
        if (env.has(nm)) return force(env.get(nm));
        const def = this.resolve(nm, mod);
        if (def) {
          if (def.foreign) return F(new Set(), "foreign " + nm);
          if (def.params.length === 0) return this.call(nm, [], mod, e);
          return { t: "fn", partial: [], callee: nm, mod, params: def.params };
        }
        // An external function used as a value (List.map xs String.fromInt).
        return { t: "fn", partial: [], callee: nm, mod, ext: true };
      }
      case "ctor": return { t: "ctorval", c: e.xs[0], reads: new Set() };
      case "accessor": return { t: "accessor", f: e.xs[0].replace(/^\./, "") };
      case "placeholder": return { t: "ph" };
      case "field_access": return this.field(ev(ks[0]), e.xs[0].replace(/^\./, ""));
      case "tuple_index": {
        const v = force(ev(ks[0]));
        const i = +e.xs[0].replace(/^\./, "");
        if (v.t === "tup") return v.items[i];
        if (v.t === "o") return O([...v.p, String(i)]);
        return F(readsOf(v), v.why);
      }
      case "record_update": {
        const base = env.has(e.xs[0]) ? force(env.get(e.xs[0])) : ev({ k: "ident", xs: [e.xs[0]] });
        const fs = new Map();
        for (const f of ks) fs.set(f.xs[0], ev(kids(f)[0]));
        return Rec(base, fs);
      }
      case "record": {
        const fs = new Map();
        for (const f of ks) fs.set(f.xs[0], ev(kids(f)[0]));
        return RecLit(fs);
      }
      case "tuple": return Tup(ks.map((k) => ev(k)));
      case "list": {
        if (ks.length === 0) return Empty;
        const spreads = ks.map((k) => k.k === "spread");
        const items = ks.map((k) => (k.k === "spread" ? ev(kids(k)[0]) : ev(k)));
        if (!spreads.some(Boolean)) return { t: "listlit", reads: new Set(items.flatMap((x) => [...readsOf(x)])), items };
        // [ …xs, x ]  push;  [ x, …xs ]  cons;  anything else rebuilt
        if (spreads.filter(Boolean).length === 1 && spreads[0]) return Lst(items[0], "push", { arg: F(new Set(items.slice(1).flatMap((x) => [...readsOf(x)]))) });
        if (spreads.filter(Boolean).length === 1 && spreads[spreads.length - 1]) return Lst(items[items.length - 1], "cons", { arg: F(new Set(items.slice(0, -1).flatMap((x) => [...readsOf(x)]))) });
        return F(new Set(items.flatMap((x) => [...readsOf(x)])), "list rebuilt from spreads");
      }
      case "append": return this.append(ev(ks[0]), ev(ks[1]));
      case "lambda": {
        const params = ks.slice(0, -1);
        return { t: "fn", params, body: ks[ks.length - 1], env: new Map(env), mod };
      }
      case "pipe_right": {
        const [lhs, rhs] = ks;
        if (rhs.k === "apply") {
          const rk = kids(rhs);
          const hasPh = rk.slice(1).some((x) => x.k === "placeholder");
          const newArgs = hasPh ? rk.slice(1).map((x) => (x.k === "placeholder" ? lhs : x)) : [lhs, ...rk.slice(1)];
          return ev({ k: "apply", xs: [rk[0], ...newArgs] });
        }
        return ev({ k: "apply", xs: [rhs, lhs] });
      }
      case "apply": {
        const [f, ...argNodes] = ks;
        const args = argNodes.map((a) => (a.k === "placeholder" ? null : ev(a)));
        if (f.k === "ctor") {
          return { t: "ctorval", c: f.xs[0], reads: new Set(args.filter(Boolean).flatMap((a) => [...readsOf(a)])) };
        }
        if (args.includes(null)) {
          // Partial application: a closure over the given arguments.
          if (f.k === "ident" && !env.has(f.xs[0])) return { t: "fn", partial: args, callee: f.xs[0], mod, captured: new Set(args.filter(Boolean).flatMap((a) => [...readsOf(a)])) };
          return { t: "fn", partial: args, callee: null, fval: ev(f), mod, captured: new Set() };
        }
        if (f.k === "ident" && !env.has(f.xs[0])) return this.call(f.xs[0], args, mod, e);
        return this.apply(ev(f), args, mod);
      }
      case "case": {
        const s = ev(ks[0]);
        const alts = [];
        const condReads = readsOf(s);
        for (const br of ks.slice(1)) {
          const bk = kids(br);
          const en = new Map(env);
          if (!this.bind(bk[0], s, en)) continue;
          alts.push(ev(bk[1], en));
        }
        const j = Join(alts);
        return withCond(j, condReads);
      }
      case "if": {
        const c = readsOf(ev(ks[0]));
        return withCond(Join([ev(ks[1]), ev(ks[2])]), c);
      }
      case "if_then": ev(ks[1]); return F(new Set());
      case "block": {
        const en = new Map(env);
        let last = F(new Set());
        for (const s of ks) {
          if (s.k === "let_def") {
            const sk = kids(s);
            if (sk.length > 1) en.set(s.xs[0], { t: "fn", params: sk.slice(0, -1), body: sk[sk.length - 1], env: en, mod });
            else en.set(s.xs[0], { t: "thunk", e: sk[0], env: en, ev: { eval: (x, en2) => this.eval(x, en2, mod) } });
          } else if (s.k === "let_pattern") {
            const sk = kids(s);
            this.bind(sk[0], ev(sk[1], en), en);
          } else if (s.k === "stmt") {
            ev(kids(s)[0], en);
          } else last = ev(s, en);
        }
        return last;
      }
      default: {
        // Operators: add, eq, neq, bool_and, interp, …: a scalar built from operands.
        return F(new Set(ks.flatMap((k) => [...readsOf(ev(k))])));
      }
    }
  }
}
// A case's scrutinee is read by the value it selects (for holes); writes ignore it.
function withCond(v, reads) {
  if (reads.size === 0) return v;
  return { ...(v.t === "join" ? v : { t: "join", alts: [v] }), cond: reads };
}

// ---- Types: what lives at a model path ------------------------------------

function typeAt(mods, mod, ty, p) {
  // Returns "list" | "record" | "scalar" | "other" for the type at path p.
  let t = ty;
  // An alias is looked up where the type naming it was written (`mod`, then
  // the module an alias came from), then in any module, as before.
  let cur = mod;
  const resolveAlias = (t) => {
    for (let n = 0; n < 10 && t && t.k === "type_con"; n++) {
      const nm = t.xs[0];
      const dot = nm.lastIndexOf(".");
      const base = nm.slice(dot + 1);
      let al = null;
      const home = cur && (dot < 0 ? cur : mods.get(cur.imports.get(nm.slice(0, dot)) ?? nm.slice(0, dot)));
      if (home && home.aliases.has(base)) { al = home.aliases.get(base); cur = home; }
      else if (home && home.types.has(base)) break; // a custom type of its own, not an alias
      else for (const m of mods.values()) if (m.aliases.has(base)) { al = m.aliases.get(base); if (cur) cur = m; }
      if (!al) break;
      t = al;
    }
    while (t && t.k === "type_paren") t = kids(t)[0];
    return t;
  };
  for (const seg of p) {
    t = resolveAlias(t);
    if (!t) return "other";
    if (seg === "[*]") t = t.k === "type_con" && t.xs[0] === "List" ? kids(t)[0] : null;
    else if (t.k === "type_record") t = kids(t).find((f) => f.xs[0] === seg)?.xs.find((x) => typeof x === "object");
    else return "other";
  }
  t = resolveAlias(t);
  if (!t) return "other";
  if (t.k === "type_record") return "record";
  if (t.k === "type_con" && t.xs[0] === "List") return "list";
  return "scalar";
}

// ---- Writes ----------------------------------------------------------------
// An entry: { path, cls: exact|indexed|structural|star, why, flag? }.
const RANK = { none: 0, exact: 1, indexed: 2, structural: 3, star: 4 };

function writes(v, P, ctx, out) {
  v = force(v);
  const ps = P.join(".") || "(model)";
  const ty = () => {
    const t = typeAt(ctx.mods, ctx.modelMod, ctx.modelType, P);
    return t === "other" && P.length === 0 && ctx.initKind ? ctx.initKind : t;
  };
  switch (v.t) {
    case "bot": return;
    case "o":
      if (v.p.join(".") === P.join(".")) return;
      // A whole record model replaced by a value kept elsewhere in it (an undo snapshot).
      if (P.length === 0 && ty() === "record") { out.push({ path: ps, cls: "star", why: `whole model replaced by the value at ${v.p.join(".")}` }); return; }
      out.push({ path: ps, cls: "exact", why: `copied from ${v.p.join(".") || "(model)"}` });
      return;
    case "rec":
      writes(v.base, P, ctx, out);
      for (const [f, x] of v.fs) writes(x, [...P, f], ctx, out);
      return;
    case "reclit":
      for (const [f, x] of v.fs) writes(x, [...P, f], ctx, out);
      return;
    case "tup":
      v.items.forEach((x, i) => writes(x, [...P, String(i)], ctx, out));
      return;
    case "join":
      for (const a of v.alts) writes(a, P, ctx, out);
      return;
    case "lst": {
      // `++` on a String reaches here as a "concat"/"push"; the path's type says which.
      if ((v.op === "concat" || v.op === "push" || v.op === "cons") && ty() !== "list") {
        out.push({ path: ps, cls: "exact", why: "computed value" });
        return;
      }
      // An edit script only describes a change of THIS path's old list: an edit
      // of a list from anywhere else (List.range, another field) is a replacement.
      const rootOf = (x) => {
        x = force(x);
        if (x.t === "lst") return rootOf(x.base);
        if (x.t === "o") return x.p.join(".");
        if (x.t === "join") { const rs = new Set(x.alts.map(rootOf)); return rs.size === 1 ? [...rs][0] : null; }
        return null;
      };
      if (rootOf(v) !== P.join(".")) {
        out.push({ path: ps, cls: "exact", why: `list rebuilt (List.${v.op} of a list that is not this path's)`, flag: "list-replaced" });
        return;
      }
      writes(v.base, P, ctx, out);
      const spine = ps + "{spine}";
      if (v.op === "map" || v.op === "indexedMap") {
        const inner = [];
        writes(v.elem, [...P, "[*]"], ctx, inner);
        if (inner.length === 0) return;
        const star = inner.some((w) => w.cls === "star");
        out.push({ path: inner.map((w) => w.path).join(", "), cls: star ? "star" : "structural", why: `List.${v.op}: elements rewritten, order and length kept`, elems: inner });
        return;
      }
      if (v.op === "filter") { out.push({ path: spine, op: "filter", cls: "structural", why: "List.filter: removals, order kept" }); return; }
      if (LIST_REORDER.has(v.op)) { out.push({ path: spine, op: v.op, cls: "structural", why: `List.${v.op}: a permutation` }); return; }
      if (v.op === "update") {
        const inner = [];
        writes(v.elem, [...P, "[*]"], ctx, inner);
        out.push({ path: spine.replace("{spine}", "[k]") + (inner.length ? " (" + inner.map((w) => w.path).join(", ") + ")" : ""), cls: inner.some((w) => w.cls === "star") ? "star" : "indexed", why: "List.update k", elems: inner });
        return;
      }
      if (v.op === "concat") { out.push({ path: spine, op: "concat", cls: "indexed", why: "append of a model list (positions from a length)" }); return; }
      out.push({ path: spine, op: v.op, cls: "indexed", why: `List.${v.op}` });
      return;
    }
    case "empty":
      out.push({ path: ty() === "list" ? ps + "{spine}" : ps, op: "clear", cls: ty() === "list" ? "indexed" : "exact", why: ty() === "list" ? "[] (clear)" : "literal" });
      return;
    case "listlit":
      out.push({ path: ps, cls: "exact", why: "list literal", flag: "list-replaced" });
      return;
    default: {
      // F, ctorval, fn: a new value at P.
      const opaque = v.why;
      const t = ty();
      if (P.length === 0 && t === "record") {
        out.push({ path: ps, cls: "star", why: opaque ? `whole model from ${opaque}` : "whole model rebuilt opaquely" });
        return;
      }
      const flag = t === "list" ? "list-replaced" : t === "record" && opaque ? "subtree" : undefined;
      out.push({ path: ps, cls: "exact", why: opaque ? `value from ${opaque}` : "computed value", flag });
    }
  }
}

// ---- Views: holes ----------------------------------------------------------

function isMarkupy(ev, e, env, mod, depth = 0) {
  if (depth > 20 || !e) return false;
  const ks = kids(e);
  switch (e.k) {
    case "markup_element": case "markup_fragment": case "markup_for": return true;
    case "paren": return isMarkupy(ev, ks[0], env, mod, depth + 1);
    case "block": return isMarkupy(ev, ks[ks.length - 1], env, mod, depth + 1);
    case "case": return ks.slice(1).some((b) => isMarkupy(ev, kids(b)[1], env, mod, depth + 1));
    case "if": return isMarkupy(ev, ks[1], env, mod, depth + 1) || isMarkupy(ev, ks[2], env, mod, depth + 1);
    case "apply": {
      const f = ks[0];
      if (f.k === "ident" && f.xs[0] === "Html.map") return true;
      if (f.k === "ident" && !env.has(f.xs[0])) {
        const d = ev.resolve(f.xs[0], mod);
        return !!(d && !d.foreign && isMarkupy(ev, d.body, new Map(), d.mod, depth + 1));
      }
      return false;
    }
    case "ident": {
      const v = env.get(e.xs[0]);
      if (v && v.t === "thunk") return isMarkupy(ev, v.e, v.env, v.mod ?? mod, depth + 1);
      if (!env.has(e.xs[0])) {
        const d = ev.resolve(e.xs[0], mod);
        return !!(d && !d.foreign && d.params.length === 0 && isMarkupy(ev, d.body, new Map(), d.mod, depth + 1));
      }
      return false;
    }
    // A record holding markup: a Tea.Document, or a page's { title, content }.
    case "record": return ks.some((f) => isMarkupy(ev, kids(f)[0], env, mod, depth + 1));
    case "field_access": return fieldsOf(ev, ks[0], fieldName(e), env, mod, depth + 1).some((x) => isMarkupy(ev, x.e, x.env, x.mod, depth + 1));
    default: return false;
  }
}

const fieldName = (e) => e.xs[0].replace(/^\./, "");

// The expressions a field of a record-valued expression can be, through
// parentheses, lets, branches, helpers and thunks; [] when unknown.
function fieldsOf(ev, e, name, env, mod, depth = 0) {
  if (depth > 20 || !e) return [];
  const ks = kids(e);
  switch (e.k) {
    case "paren": return fieldsOf(ev, ks[0], name, env, mod, depth + 1);
    case "block": return fieldsOf(ev, ks[ks.length - 1], name, env, mod, depth + 1);
    case "record": {
      const f = ks.find((x) => x.xs[0] === name);
      return f ? [{ e: kids(f)[0], env, mod }] : [];
    }
    case "case": return ks.slice(1).flatMap((b) => fieldsOf(ev, kids(b)[1], name, env, mod, depth + 1));
    case "if": return [...fieldsOf(ev, ks[1], name, env, mod, depth + 1), ...fieldsOf(ev, ks[2], name, env, mod, depth + 1)];
    case "apply": {
      const f = ks[0];
      if (f.k !== "ident" || env.has(f.xs[0])) return [];
      const d = ev.resolve(f.xs[0], mod);
      return d && !d.foreign ? fieldsOf(ev, d.body, name, new Map(), d.mod, depth + 1) : [];
    }
    case "ident": {
      const v = env.get(e.xs[0]);
      if (v && v.t === "thunk") return fieldsOf(ev, v.e, name, v.env, v.mod ?? mod, depth + 1);
      if (env.has(e.xs[0])) return [];
      const d = ev.resolve(e.xs[0], mod);
      return d && !d.foreign && d.params.length === 0 ? fieldsOf(ev, d.body, name, new Map(), d.mod, depth + 1) : [];
    }
    default: return [];
  }
}

// A helper's parameters, bound where it is called: a plain name as a thunk of
// its argument (so markup or a record passed in is walked where it is placed),
// any other pattern to the argument's value.
function bindArgs(ev, d, an, env, mod) {
  const en = new Map();
  d.params.forEach((p, i) => {
    if (p.k === "pat_var") en.set(p.xs[0], { t: "thunk", e: an[i], env, mod, ev: { eval: (x, en2) => ev.eval(x, en2, mod) } });
    else ev.bind(p, ev.eval(an[i], env, mod), en);
  });
  return en;
}

// Walk the field `name` of a record-valued expression, as walkChild walks markup.
function walkField(ev, e, name, env, mod, ctx, row, depth, whole) {
  const ks = kids(e);
  const fallback = () => ctx.holes.push({ kind: "child", reads: [...readsOf(ev.eval(whole.e, whole.env, whole.mod))], row });
  if (depth > 30) return;
  switch (e.k) {
    case "paren": return walkField(ev, ks[0], name, env, mod, ctx, row, depth + 1, whole);
    case "record": {
      const f = ks.find((x) => x.xs[0] === name);
      return f ? walkChild(ev, kids(f)[0], env, mod, ctx, row, depth + 1) : fallback();
    }
    case "block": {
      const en = letEnv(ev, ks, env, mod);
      return walkField(ev, ks[ks.length - 1], name, en, mod, ctx, row, depth + 1, whole);
    }
    case "case": {
      const sc = ev.eval(ks[0], env, mod);
      ctx.holes.push({ kind: "switch", reads: [...readsOf(sc)], row });
      for (const br of ks.slice(1)) {
        const bk = kids(br);
        const en = new Map(env);
        ev.bind(bk[0], sc, en);
        walkField(ev, bk[1], name, en, mod, ctx, row, depth + 1, whole);
      }
      return;
    }
    case "if":
      ctx.holes.push({ kind: "switch", reads: [...readsOf(ev.eval(ks[0], env, mod))], row });
      walkField(ev, ks[1], name, env, mod, ctx, row, depth + 1, whole);
      return walkField(ev, ks[2], name, env, mod, ctx, row, depth + 1, whole);
    case "apply": {
      const f = ks[0];
      const d = f.k === "ident" && !env.has(f.xs[0]) ? ev.resolve(f.xs[0], mod) : null;
      if (!d || d.foreign) return fallback();
      return walkField(ev, d.body, name, bindArgs(ev, d, ks.slice(1), env, mod), d.mod, ctx, row, depth + 1, whole);
    }
    case "ident": {
      const v = env.get(e.xs[0]);
      if (v && v.t === "thunk") return walkField(ev, v.e, name, v.env, v.mod ?? mod, ctx, row, depth + 1, whole);
      const d = env.has(e.xs[0]) ? null : ev.resolve(e.xs[0], mod);
      if (!d || d.foreign || d.params.length) return fallback();
      return walkField(ev, d.body, name, new Map(), d.mod, ctx, row, depth + 1, whole);
    }
    default: return fallback();
  }
}

// The lets of a block, bound as walkChild binds them.
function letEnv(ev, ks, env, mod) {
  const en = new Map(env);
  for (const s of ks.slice(0, -1)) {
    if (s.k === "let_def") {
      const sk = kids(s);
      if (sk.length > 1) en.set(s.xs[0], { t: "fn", params: sk.slice(0, -1), body: sk[sk.length - 1], env: en, mod });
      else en.set(s.xs[0], { t: "thunk", e: sk[0], env: en, mod, ev: { eval: (x, en2) => ev.eval(x, en2, mod) } });
    } else if (s.k === "let_pattern") { const sk = kids(s); ev.bind(sk[0], ev.eval(sk[1], en, mod), en); }
  }
  return en;
}

function walkView(ev, e, env, mod, ctx, row) {
  const ks = kids(e);
  const hole = (kind, expr, en = env) => {
    const v = ev.eval(expr, en, mod);
    ctx.holes.push({ kind, reads: [...readsOf(v)], row, src: kind });
  };
  switch (e.k) {
    case "markup_element": case "markup_fragment":
      for (const c of ks) {
        if (c.k === "markup_attr") {
          if (!c.xs.includes("braced")) continue;
          const name = c.xs[0];
          if (/^on[A-Z]/.test(name)) { ctx.events++; continue; }
          hole(`attr ${name}`, kids(c)[0]);
        } else if (c.k === "markup_hole") walkChild(ev, kids(c)[0], env, mod, ctx, row);
        else if (c.k !== "markup_text") walkView(ev, c, env, mod, ctx, row);
      }
      return;
    case "markup_for": {
      let eachV = null, key = null, body = null;
      for (const c of ks) {
        if (c.k === "markup_attr" && c.xs[0] === "each") eachV = kids(c)[0];
        else if (c.k === "markup_attr" && c.xs[0] === "keyed") { const k = kids(c)[0]; key = k.k === "accessor" ? k.xs[0].replace(/^\./, "") : null; }
        else if (c.k === "markup_hole") body = kids(c)[0];
      }
      const listV = ev.eval(eachV, env, mod);
      ctx.holes.push({ kind: "For each", reads: [...readsOf(listV)], row });
      const elem = ev.elementOf(listV);
      const fnV = ev.eval(body, env, mod);
      const elemPath = elem.t === "o" ? elem.p.join(".") : null;
      // `derived`: the rows are a filter, sort or map of the list, so positions are not the list's.
      const newRow = { key, elemPath, derived: force(listV).t !== "o" };
      if (fnV.t === "fn" && fnV.body) {
        const en = new Map(fnV.env);
        ev.bind(fnV.params[0], elem, en);
        walkChild(ev, fnV.body, en, fnV.mod, ctx, newRow);
      } else if (fnV.t === "fn" && fnV.callee) {
        const d = ev.resolve(fnV.callee, fnV.mod);
        if (d && !d.foreign) {
          const en = new Map();
          // `{row model _}`: the row is the placeholder's argument, the
          // others the ones written; a bare `{row}` takes it first.
          const partial = fnV.partial && fnV.partial.length ? fnV.partial : [null];
          let k = 0;
          d.params.forEach((p, i) => {
            const a = i < partial.length ? partial[i] : null;
            if (a === null && k++ === 0) ev.bind(p, elem, en);
            else if (a !== null) ev.bind(p, a, en);
          });
          walkChild(ev, d.body, en, d.mod, ctx, newRow);
        }
      }
      return;
    }
    default:
      walkChild(ev, e, env, mod, ctx, row);
  }
}

function walkChild(ev, e, env, mod, ctx, row, depth = 0) {
  const ks = kids(e);
  if (depth > 30) return;
  if (e.k === "record" && (depth === 0 || isMarkupy(ev, e, env, mod))) {
    // Tea.Document: { title, body }: the title is one hole, the body markup;
    // the same for such a record a helper makes.
    for (const f of ks) walkChild(ev, kids(f)[0], env, mod, ctx, row, depth + 1);
    return;
  }
  if (!isMarkupy(ev, e, env, mod)) {
    const v = ev.eval(e, env, mod);
    ctx.holes.push({ kind: "child", reads: [...readsOf(v)], row });
    return;
  }
  switch (e.k) {
    case "markup_element": case "markup_fragment": case "markup_for": return walkView(ev, e, env, mod, ctx, row);
    case "field_access": return walkField(ev, ks[0], fieldName(e), env, mod, ctx, row, depth + 1, { e, env, mod });
    case "paren": return walkChild(ev, ks[0], env, mod, ctx, row, depth + 1);
    case "block": {
      const en = new Map(env);
      for (const s of ks.slice(0, -1)) {
        if (s.k === "let_def") {
          const sk = kids(s);
          if (sk.length > 1) en.set(s.xs[0], { t: "fn", params: sk.slice(0, -1), body: sk[sk.length - 1], env: en, mod });
          else en.set(s.xs[0], { t: "thunk", e: sk[0], env: en, ev: { eval: (x, en2) => ev.eval(x, en2, mod) } });
        } else if (s.k === "let_pattern") { const sk = kids(s); ev.bind(sk[0], ev.eval(sk[1], en, mod), en); }
      }
      return walkChild(ev, ks[ks.length - 1], en, mod, ctx, row, depth + 1);
    }
    case "case": {
      const s = ev.eval(ks[0], env, mod);
      ctx.holes.push({ kind: "switch", reads: [...readsOf(s)], row });
      for (const br of ks.slice(1)) {
        const bk = kids(br);
        const en = new Map(env);
        ev.bind(bk[0], s, en);
        walkChild(ev, bk[1], en, mod, ctx, row, depth + 1);
      }
      return;
    }
    case "if": {
      ctx.holes.push({ kind: "switch", reads: [...readsOf(ev.eval(ks[0], env, mod))], row });
      walkChild(ev, ks[1], env, mod, ctx, row, depth + 1);
      walkChild(ev, ks[2], env, mod, ctx, row, depth + 1);
      return;
    }
    case "apply": {
      const [f, ...an] = ks;
      if (f.xs[0] === "Html.map") return walkChild(ev, an[0], env, mod, ctx, row, depth + 1);
      const d = ev.resolve(f.xs[0], mod);
      return walkChild(ev, d.body, bindArgs(ev, d, an, env, mod), d.mod, ctx, row, depth + 1);
    }
    case "ident": {
      const v = env.get(e.xs[0]);
      if (v && v.t === "thunk") return walkChild(ev, v.e, v.env, v.mod ?? mod, ctx, row, depth + 1);
      const d = ev.resolve(e.xs[0], mod);
      return walkChild(ev, d.body, new Map(), d.mod, ctx, row, depth + 1);
    }
  }
}

// ---- Conflicts between a read and a write ------------------------------------

const segs = (s) => (s === "(model)" ? [] : s.replace(/\[k\]/g, ".[*]").split(".").filter(Boolean));
function conflicts(read, w, row = null) {
  if (w.cls === "star") return true;
  const paths = w.elems ? w.elems.map((x) => x.path) : w.path.split(", ").map((x) => x.replace(/ \(.*$/, ""));
  const r = read === "" ? [] : read.split(".");
  // Pattern-bound segments (`editing.Just#0`) live under their parent path.
  for (const p of paths) {
    const spine = p.endsWith("{spine}");
    const wp = segs(p.replace("{spine}", ""));
    if (spine) {
      // A spine edit changes the list and its ancestors, not an existing element's fields.
      if (r.length <= wp.length && wp.slice(0, r.length).every((x, i) => x === r[i])) return true;
      // A positional (unkeyed) For: an edit that shifts positions changes what an existing row shows.
      const shifts = (row && row.derived) || !["push", "pop", "clear", "concat", "take"].includes(w.op);
      if (shifts && row && !row.key && wp.length + 1 <= r.length && wp.every((x, i) => x === r[i]) && r[wp.length] === "[*]") return true;
      continue;
    }
    const n = Math.min(r.length, wp.length);
    if (r.slice(0, n).every((x, i) => x === wp[i])) return true;
  }
  return false;
}

// ---- Init literals ----------------------------------------------------------

function isLiteral(e) {
  if (!e) return false;
  const ks = kids(e);
  switch (e.k) {
    case "int": case "float": case "unit": return true;
    case "string": return ks.every((c) => c.k === "chunk");
    case "ctor": return true;
    case "paren": return isLiteral(ks[0]);
    case "apply": return ks[0].k === "ctor" && ks.slice(1).every(isLiteral);
    case "list": return ks.every(isLiteral);
    case "record": return ks.every((f) => isLiteral(kids(f)[0]));
    case "tuple": return ks.every(isLiteral);
    default: return false;
  }
}
function initAt(ev, e, mod, p) {
  // Follow the init expression's AST to path p; null when it is not a literal shape.
  for (let n = 0; n < 10 && e; n++) {
    if (e.k === "paren") e = kids(e)[0];
    else if (e.k === "block") e = kids(e)[kids(e).length - 1];
    else if (e.k === "tuple") e = kids(e)[0];
    else if (e.k === "lambda") e = kids(e)[kids(e).length - 1];
    else if (e.k === "ident") { const d = ev.resolve(e.xs[0], mod); if (!d || d.foreign || d.params.length) return null; e = d.body; mod = d.mod; }
    else break;
  }
  if (p.length === 0) return e;
  const [s, ...rest] = p;
  if (e.k === "record") {
    const f = kids(e).find((x) => x.xs[0] === s);
    return f ? initAt(ev, kids(f)[0], mod, rest) : null;
  }
  if (s === "[*]" && e.k === "list") {
    const items = kids(e);
    if (items.length === 0) return null;
    const subs = items.map((it) => initAt(ev, it, mod, rest));
    return subs.every((x) => x && isLiteral(x)) ? subs[0] : null;
  }
  return null;
}

// ---- Driver -------------------------------------------------------------------

function findPrograms(mods) {
  const out = [];
  const visit = (e, mod, where, callee = null) => {
    if (!e || typeof e !== "object") return;
    if (e.k === "record") {
      const fs = new Map(kids(e).map((f) => [f.xs[0], kids(f)[0]]));
      if (fs.has("update") && fs.has("view")) out.push({ fs, mod, where, callee });
    }
    const ks = kids(e);
    const c0 = e.k === "apply" && ks[0].k === "ident" ? ks[0].xs[0] : null;
    for (const c of ks) visit(c, mod, where, c0);
  };
  for (const m of mods.values()) for (const d of m.defs.values()) if (d.body) visit(d.body, m, d.name);
  return out;
}

function msgCtors(ev, prog, updV, mods) {
  // The annotation's first parameter, else the type declaring the first constructor pattern met.
  const mod = prog.mod;
  let tname = null;
  let annMod = mod;
  const uf = prog.fs.get("update");
  if (uf.k === "ident") {
    const d = ev.resolve(uf.xs[0], mod);
    const an = d && d.mod.annots.get(d.name);
    if (an && an.k === "type_fn") { tname = kids(an)[0].xs[0]; annMod = d.mod; }
  }
  // The type as the annotation's module names it: its own, an imported
  // module's (`Home.Msg`), else any module's of that name.
  const findType = (n) => {
    const dot = n.lastIndexOf(".");
    const base = n.slice(dot + 1);
    const home = dot < 0 ? annMod : mods.get(annMod.imports.get(n.slice(0, dot)) ?? n.slice(0, dot));
    if (home && home.types.has(base)) return home.types.get(base);
    for (const m of mods.values()) if (m.types.has(base)) return m.types.get(base);
    return null;
  };
  if (tname && findType(tname)) return findType(tname);
  let first = null;
  const scan = (e) => {
    if (first || !e || typeof e !== "object") return;
    if (e.k === "pat_ctor") { first = e.xs[0]; return; }
    for (const c of kids(e)) scan(c);
  };
  const body = updV.body ?? ev.resolve(updV.callee, updV.mod)?.body;
  const params = updV.params ?? [];
  for (const p of params) scan(p);
  if (!first) scan(body);
  if (first) for (const m of mods.values()) for (const cs of m.types.values()) if (cs.includes(first.slice(first.lastIndexOf(".") + 1))) return cs;
  // `update = λmsg model → update deps msg model`: the module's own `Msg`.
  if (prog.mod.types.has("Msg")) return prog.mod.types.get("Msg");
  return [];
}

function ctorOrigins(mods, prog, ctors) {
  // Where each constructor is built: in view-reachable code (an event) or elsewhere (a command, a subscription).
  const reach = (roots) => {
    const seen = new Set();
    const nodes = [];
    const go = (e, mod) => {
      if (!e || typeof e !== "object") return;
      nodes.push(e);
      if (e.k === "ident") {
        const nm = e.xs[0];
        let d = mod.defs.get(nm);
        if (!d && nm.includes(".")) { const q = nm.slice(0, nm.lastIndexOf(".")); const t = mods.get(mod.imports.get(q) ?? q); d = t?.defs.get(nm.slice(nm.lastIndexOf(".") + 1)); }
        if (d && d.body && !seen.has(d)) { seen.add(d); go(d.body, d.mod); }
      }
      for (const c of kids(e)) go(c, mod);
    };
    for (const r of roots) go(r, prog.mod);
    return nodes;
  };
  const used = (nodes) => new Set(nodes.filter((n) => n.k === "ctor").map((n) => n.xs[0].slice(n.xs[0].lastIndexOf(".") + 1)));
  const inView = used(reach([prog.fs.get("view")]));
  const other = used(reach([prog.fs.get("update"), prog.fs.get("init"), prog.fs.get("subscriptions")].filter(Boolean)));
  // Tea.application's onUrlRequest/onUrlChange: the host sends these.
  const host = used(reach([...prog.fs].filter(([k]) => !["update", "init", "subscriptions", "view"].includes(k)).map(([, v]) => v)));
  const res = new Map();
  for (const c of ctors) res.set(c, [inView.has(c) ? "event" : null, other.has(c) ? "async" : null, host.has(c) ? "host" : null].filter(Boolean).join("+") || "unsent");
  return res;
}

function analyse(target) {
  const mods = loadModules(target);
  const progs = findPrograms(mods);
  const results = [];
  for (const prog of progs) {
    const ev = new Ev(mods, prog.mod);
    const updV = ev.eval(prog.fs.get("update"), new Map(), prog.mod);
    let ctors = msgCtors(ev, prog, updV, mods);
    // The message type has no constructors of the program's own (a String, a
    // Browser.UrlRequest): one pseudo-constructor stands for every message.
    const pseudo = ctors.length === 0;
    if (pseudo) ctors = ["(any message)"];
    // The model's type: the annotation's second parameter when there is one,
    // else the module's own `Model` alias.
    let modelType = null;
    let modelMod = null;
    const uf = prog.fs.get("update");
    if (uf.k === "ident") {
      const d = ev.resolve(uf.xs[0], prog.mod);
      const an = d && d.mod.annots.get(d.name);
      if (an && an.k === "type_fn") { modelType = kids(an)[1]; modelMod = d.mod; }
    }
    if (!modelType && prog.mod.aliases.has("Model")) modelType = { k: "type_con", xs: ["Model"] };
    const initE = initAt(ev, prog.fs.get("init"), prog.mod, []);
    const ctx = { mods, modelType, modelMod, initKind: initE && initE.k === "list" ? "list" : null };
    const origins = ctorOrigins(mods, prog, ctors);
    const cons = [];
    const allWrites = [];
    for (const c of ctors) {
      let r = ev.apply(updV, [pseudo ? F(new Set()) : { t: "msg", c }, O([])], prog.mod);
      r = force(r);
      // Tea.element: the model is the first of the pair.
      const modelPart = (v) => {
        v = force(v);
        if (v.t === "tup" && v.items.length === 2) return v.items[0];
        if (v.t === "join") return Join(v.alts.map(modelPart));
        return v;
      };
      const isElement = /element|application/.test(prog.callee ?? "") || containsTuple(r);
      const m = isElement ? modelPart(r) : r;
      const raw = [];
      writes(m, [], ctx, raw);
      const ws = [...new Map(raw.map((w) => [`${w.path}|${w.cls}|${w.why}`, w])).values()];
      let cls = "none";
      for (const w of ws) if (RANK[w.cls] > RANK[cls]) cls = w.cls;
      const shown = cls === "none" ? "exact" : cls;
      cons.push({ ctor: c, cls: shown, empty: ws.length === 0, flags: [...new Set(ws.filter((w) => w.flag).map((w) => w.flag))], origin: pseudo ? "n/a" : origins.get(c), writes: ws });
      allWrites.push(...ws);
    }
    // Holes.
    const viewV = ev.eval(prog.fs.get("view"), new Map(), prog.mod);
    const hctx = { holes: [], events: 0 };
    if (viewV.t === "fn") {
      const en = new Map(viewV.env ?? []);
      let body = viewV.body, mod = viewV.mod;
      if (!body && viewV.callee) { const d = ev.resolve(viewV.callee, viewV.mod); body = d.body; mod = d.mod; ev.bind(d.params[0], O([]), en); }
      else ev.bind(viewV.params[0], O([]), en);
      walkChild(ev, body, en, mod, hctx, null);
    }
    const holes = hctx.holes.map((h) => {
      const dyn = h.reads.some((r) => allWrites.some((w) => conflicts(r, w, h.row)));
      let cls = dyn ? "dynamic" : "static";
      if (dyn && h.row && h.row.key && h.row.elemPath && h.reads.length > 0 && h.reads.every((r) => r === `${h.row.elemPath}.${h.row.key}`)) cls = "static-key";
      if (cls === "static") {
        const lit = h.reads.every((r) => {
          const p = r === "" ? [] : r.split(".");
          const v = initAt(ev, prog.fs.get("init"), prog.mod, p);
          return v && isLiteral(v);
        });
        if (lit) cls = "literal-init";
      }
      return { ...h, cls };
    });
    // W3: the holes each constructor can reach (a key-only row hole never changes).
    for (const c of cons) c.touched = holes.filter((h) => h.cls !== "static-key" && h.reads.some((r) => c.writes.some((w) => conflicts(r, w, h.row)))).length;
    results.push({ where: prog.where, excluded: pseudo && cons.every((c) => c.empty) ? "no real update: no Msg constructors and the model is never written" : null, ctors: cons, holes, events: hctx.events, notes: [...ev.notes] });
  }
  return results;
}
function containsTuple(v, depth = 0) {
  v = force(v);
  if (depth > 10 || !v) return false;
  if (v.t === "tup") return true;
  if (v.t === "join") return v.alts.some((a) => containsTuple(a, depth + 1));
  return false;
}

// ---- Corpus and output ----------------------------------------------------------

function corpus() {
  if (set === "dom") {
    // The renderer's own fixtures (Browser.program pages) and the two top-level pages.
    const items = [];
    for (const dir of ["tests/corpus/browser/dom", "tests/corpus/browser"]) {
      for (const f of readdirSync(path.join(repo, dir)).sort()) {
        const p = path.join(repo, dir, f);
        // LetChain is a generated 4 341-line stress test of one `let` chain, not a page.
        if (f === "LetChain.beni") continue;
        if (f.endsWith(".beni") || (dir.endsWith("dom") && statSync(p).isDirectory())) items.push(p);
      }
    }
    return items;
  }
  const tea = path.join(repo, "tests/corpus/browser/tea");
  const items = [];
  for (const f of readdirSync(tea).sort()) {
    const p = path.join(tea, f);
    if (f.endsWith(".beni") || statSync(p).isDirectory()) items.push(p);
  }
  items.push(path.join(repo, "bench/ui/apps/beni/Main.beni"));
  for (const f of readdirSync(path.join(repo, "bench/todomvc/apps/beni")).sort()) if (f.endsWith(".beni")) items.push(path.join(repo, "bench/todomvc/apps/beni", f));
  return items;
}

const targets = programArgs.length ? programArgs : corpus();
const all = [];
for (const t of targets) {
  const name = t.split("+").map((p) => path.relative(repo, p)).join("+");
  try {
    all.push({ program: name, programs: analyse(t) });
  } catch (err) {
    all.push({ program: name, error: String(err.stack).split("\n").slice(0, 3).join(" | ") });
  }
}
const isRoot = (c) => c.cls !== "star" && c.writes.some((w) => w.path === "(model)");
if (asRoot) {
  for (const p of all) if (!p.error) p.programs = p.programs.filter((q) => !skip.has(q.where));
}
if (asRoot && asTable) {
  const pct = (a, b) => (b ? `${Math.round((100 * a) / b)}%` : "–");
  const zero = () => ({ ctors: 0, exact: 0, nothing: 0, indexed: 0, structural: 0, star: 0, root: 0, replaced: 0, precise: 0 });
  const tot = zero();
  console.log("| program | ctors | exact (of which writes nothing) | indexed | structural | * | root | with a list replaced | bounded | bounded, root as unbounded | exact+indexed | exact+indexed, root as unbounded | exact+indexed, no list replaced |");
  console.log("|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|");
  const row = (name, s) =>
    console.log(`| ${name} | ${s.ctors} | ${s.exact} (${s.nothing}) | ${s.indexed} | ${s.structural} | ${s.star} | ${s.root} | ${s.replaced} | ${s.ctors - s.star} (${pct(s.ctors - s.star, s.ctors)}) | ${s.ctors - s.star - s.root} (${pct(s.ctors - s.star - s.root, s.ctors)}) | ${s.exact + s.indexed} (${pct(s.exact + s.indexed, s.ctors)}) | ${s.exact + s.indexed - s.root} (${pct(s.exact + s.indexed - s.root, s.ctors)}) | ${s.precise} (${pct(s.precise, s.ctors)}) |`);
  for (const p of all) {
    if (p.error) { console.log(`| ${p.program} | ERROR ${p.error} |`); continue; }
    for (const q of p.programs) {
      if (q.excluded) continue;
      const s = zero();
      for (const c of q.ctors) {
        s.ctors++;
        s[c.cls]++;
        if (c.empty) s.nothing++;
        if (isRoot(c)) s.root++;
        if (c.flags.includes("list-replaced")) s.replaced++;
        if ((c.cls === "exact" || c.cls === "indexed") && !c.flags.includes("list-replaced")) s.precise++;
      }
      for (const k of Object.keys(tot)) tot[k] += s[k];
      row(`${p.program} (${q.where})`, s);
    }
  }
  row("**total**", tot);
} else if (asJson) {
  if (asRoot) for (const p of all) for (const q of p.programs ?? []) for (const c of q.ctors) c.root = isRoot(c);
  console.log(JSON.stringify(all, null, 1));
} else if (asList) {
  // One line per program: each constructor and its class. E exact, I indexed,
  // S structural, * unbounded; ∅ writes nothing, ʳ replaces a list, ᵃ sent
  // by a fiber, a subscription or the host rather than a view event.
  const ab = { exact: "E", indexed: "I", structural: "S", star: "*" };
  for (const p of all) {
    if (p.error) { console.log(`- ${p.program}: ERROR`); continue; }
    for (const q of p.programs) {
      if (q.excluded) continue;
      const name = p.program.replace(/^tests\/corpus\/browser\/(tea\/)?/, "").replace(/\.beni$/, "") + (p.programs.length > 1 ? ` (${q.where})` : "");
      console.log(`- **${name}**: ${q.ctors.map((c) => `${c.ctor} ${ab[c.cls]}${c.empty ? "∅" : ""}${c.flags.includes("list-replaced") ? "ʳ" : ""}${/async|host/.test(c.origin) ? "ᵃ" : ""}`).join(", ")}`);
    }
  }
} else if (asTable) {
  // One row per program (a directory or a file; several mounted programs in
  // one file are summed), then the totals.
  const H = ["static", "literal-init", "static-key", "dynamic"];
  const zero = () => ({ ctors: 0, exact: 0, nothing: 0, replaced: 0, precise: 0, indexed: 0, structural: 0, star: 0, holes: 0, static: 0, "literal-init": 0, "static-key": 0, dynamic: 0, events: 0, async: 0, touchSum: 0, touchN: 0 });
  const tot = zero();
  const app = zero();
  const pct = (a, b) => (b ? `${Math.round((100 * a) / b)}%` : "–");
  const rows = [];
  const excluded = [];
  for (const p of all) {
    if (p.error) { rows.push(`| ${p.program} | ERROR ${p.error} |`); continue; }
    const s = zero();
    const units = p.programs.filter((q) => !q.excluded);
    for (const q of p.programs) if (q.excluded) excluded.push(`${p.program} (${q.where}): ${q.excluded}`);
    if (units.length === 0) continue;
    for (const q of units) {
      for (const c of q.ctors) {
        s.ctors++;
        s[c.cls]++;
        if (c.empty) s.nothing++;
        if (c.flags.includes("list-replaced")) s.replaced++;
        if ((c.cls === "exact" || c.cls === "indexed") && !c.flags.includes("list-replaced")) s.precise++;
        if (/async|host/.test(c.origin)) s.async++;
        if (q.holes.length) { s.touchSum += c.touched / q.holes.length; s.touchN++; }
      }
      for (const h of q.holes) { s.holes++; s[h.cls]++; }
      s.events += q.events;
    }
    for (const k of Object.keys(tot)) tot[k] += s[k];
    const name = p.program.replace(/^tests\/corpus\/browser\/tea\//, "").replace(/\.beni$/, "");
    if (/TodoMVC|^bench\//.test(p.program)) for (const k of Object.keys(app)) app[k] += s[k];
    rows.push(`| ${name} | ${s.ctors} | ${s.exact} (${s.nothing}) | ${s.indexed} | ${s.structural} | ${s.star} | ${s.replaced} | ${s.precise} | ${s.async} | ${H.map((k) => s[k]).join(" | ")} |`);
  }
  console.log("| program | ctors | exact (of which writes nothing) | indexed | structural | * | with a list replaced | exact+indexed, no list replaced | sent by fiber/sub/host | static | literal-init | static (key) | dynamic |");
  console.log("|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|");
  for (const r of rows) console.log(r);
  console.log(`| **total** | ${tot.ctors} | ${tot.exact} (${tot.nothing}) | ${tot.indexed} | ${tot.structural} | ${tot.star} | ${tot.replaced} | ${tot.precise} | ${tot.async} | ${H.map((k) => tot[k]).join(" | ")} |`);
  for (const [label, t] of [["all", tot], ["applications (TodoMVC, bench/)", app]]) {
    console.log(`\n${label}: ${t.ctors} constructors: exact ${pct(t.exact, t.ctors)} (writes nothing ${pct(t.nothing, t.ctors)}), indexed ${pct(t.indexed, t.ctors)}, structural ${pct(t.structural, t.ctors)}, * ${pct(t.star, t.ctors)}; bounded ${pct(t.ctors - t.star, t.ctors)}; exact+indexed ${pct(t.exact + t.indexed, t.ctors)}; exact+indexed with no list replaced ${pct(t.precise, t.ctors)}; a list replaced ${pct(t.replaced, t.ctors)}`);
    console.log(`${label}: holes: ${H.map((k) => `${k} ${t[k]} (${pct(t[k], t.holes)})`).join(", ")} of ${t.holes}; event attributes (not holes) ${t.events}; a constructor reaches on average ${pct(t.touchSum, t.touchN)} of its view's holes`);
  }
  if (excluded.length) console.log(`\nexcluded:\n${excluded.map((x) => "- " + x).join("\n")}`);
} else {
  for (const p of all) {
    if (p.error) { console.log(`## ${p.program}\nERROR ${p.error}\n`); continue; }
    for (const q of p.programs) {
      console.log(`## ${p.program} :: ${q.where}`);
      for (const c of q.ctors) console.log(`  ${c.ctor.padEnd(18)} ${(asRoot && isRoot(c) ? c.cls + " (root)" : c.cls).padEnd(10)} ${c.origin.padEnd(11)} ${c.writes.map((w) => `${w.path} [${w.cls}${w.flag ? "," + w.flag : ""}: ${w.why}]`).join("; ") || "(writes nothing)"}`);
      const hc = {};
      for (const h of q.holes) hc[h.cls] = (hc[h.cls] ?? 0) + 1;
      console.log(`  holes ${JSON.stringify(hc)} events ${q.events}`);
      for (const h of q.holes) console.log(`    ${h.cls.padEnd(12)} ${h.kind.padEnd(14)} ${h.row ? "row " : ""}${h.reads.map((r) => r || "(model)").join(" ") || "-"}`);
      if (q.notes.length) console.log(`  notes ${q.notes.join("; ")}`);
    }
  }
}
