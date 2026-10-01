// The sibling JavaScript of `Schema.beni` (docs/design/boundary.md §4): the
// schema library's engine (docs/design/schema.md §5, *The builder API*).
//
// **Why JavaScript.** Core is checked whole by every compilation, and the
// engine written in beni added about 33 ms to every `beni` process; as
// `foreign`s the same surface costs 2.7 ms (schema.md §16, S3's *As built*).
//
// **The beni values this file makes and reads** follow backend.md §4, and
// every type they belong to is named in a `foreign` annotation of
// `Schema.beni`, so `--release` keeps their field names and string tags
// (boundary.md §4, *What JavaScript may read of a beni value*): a type with
// a constructor that takes arguments pads every constructor to one shape
// (`{$: "Missing", a: null}`); an all-nullary type is its bare tag; a record
// is an object with its source field names; a tuple is `{a, b}`; `()` is
// `null`; a `List` is read by the protocol (`Array.isArray`, `$plain()`)
// and made as a fresh array. A value at a type variable — a user's record,
// an `Encoded` or `Type` value — is only handed to the functions the
// builders were given, never read.
//
// **The context is the engine's** (schema.md §5): one root operation makes
// one context, and every step reads its options, path and depth from it; a
// user's function is given a value and answers a `Result`, and its issues
// are moved to where the value is.

// ---- Beni values shared with the program ----------------------------------

const ok = (a) => ({ $: "Ok", a });
const err = (a) => ({ $: "Err", a });
const nothing = { $: "Nothing", a: null };
const just = (a) => ({ $: "Just", a });
const missing = { $: "Missing", a: null };
const present = (a) => ({ $: "Present", a });
const nul = { $: "Null", a: null };
const nonNull = (a) => ({ $: "NonNull", a });
const plain = (xs) => (Array.isArray(xs) ? xs : xs.$plain());
const endpoints = ["Encoded", "Type"];

// An `Issue`, its keys in the record's canonical order.
const issueOf = (code, direction, endpoint, input, message, path) => ({ code, direction, endpoint, input, message, path });

// ---- The nodes -------------------------------------------------------------

// `t` is the kind; `a` and `b` its parts; `z` the analysis a root operation
// on this node made, once.
const PRIM = 0;
const LIST = 1;
const NULLABLE = 2;
const RECORD = 3;
const TAGGED = 4;
const CONVERTED = 5;
const FLIPPED = 6;
const PROJECTED = 7;
const REF = 8;
const BROKEN = 9;
const ENCODED = 0;
const TYPE = 1;
const node = (t, a, b) => ({ t, a, b, z: null });
const kinds = ["StringKind", "BoolKind", "IntKind", "FloatKind", "FiniteFloatKind", "NullKind", "ValueKind"];

// The deepest `maxDepth` a root accepts: one level of a value is one frame
// of `run` and one of a record's or list's loop, and the ceiling keeps a
// whole operation well inside the stack (schema.md §16, S3's *As built*).
export const maxDepthCeiling = 1024;

// ---- Builders --------------------------------------------------------------

export const string = node(PRIM, 0);
export const bool = node(PRIM, 1);
export const int = node(PRIM, 2);
export const float = node(PRIM, 3);
export const finiteFloat = node(PRIM, 4);
const null_ = node(PRIM, 5);
export { null_ as null };
export const value = node(PRIM, 6);
export const list = (child) => node(LIST, child);
export const nullable = (child) => node(NULLABLE, child);

// A record being built: its fields, `{n: name, k: key, r: renamed, o:
// optional, s: node}`, and its first construction failure, if any.
export const fields = { f: [], x: null };
const withField = (fs, name, s, optional) => ({ f: [...fs.f, { n: name, k: name, r: false, o: optional, s }], x: fs.x });
export const field = (fs, name, s) => withField(fs, name, s, false);
export const optional = (fs, name, s) => withField(fs, name, s, true);
export const key = (fs, external) => {
  const last = fs.f[fs.f.length - 1];
  if (last === undefined) return { f: fs.f, x: fs.x ?? "Schema.key renames the field added before it, and there is none" };
  if (last.r) return { f: fs.f, x: fs.x ?? `the field ${last.n} already has the key "${last.k}"` };
  return { f: [...fs.f.slice(0, -1), { ...last, k: external, r: true }], x: fs.x };
};
export const mapping = (to, from) => ({ to, from });

// The first name of `names` that occurs again after it.
const duplicate = (names) => names.find((n, i) => names.indexOf(n, i + 1) !== -1);

export const record = (fs, encoded, typed) => {
  if (fs.x !== null) return node(BROKEN, fs.x);
  const name = duplicate(fs.f.map((f) => f.n));
  if (name !== undefined) return node(BROKEN, `two fields are named ${name}`);
  const k = duplicate(fs.f.map((f) => f.k));
  if (k !== undefined) return node(BROKEN, `two fields read and write the key "${k}"`);
  return node(RECORD, fs.f, { te: encoded.to, fe: encoded.from, ta: typed.to, fa: typed.from });
};

export const injection = (inject, project) => ({ i: inject, p: project });
// A variant: `n` its name, `g` its tag, `p` its payload's record node or
// null, `e` and `a` its injections at each endpoint; or `x`, why it is not.
export const variant = (name, tag, payload, e, a) =>
  payload.t === RECORD ? { n: name, g: tag, p: payload, e, a, x: null } : { x: `the payload of the variant ${name} is not a record schema` };
export const nullary = (name, tag, e, a) => ({ n: name, g: tag, p: null, e, a, x: null });

export const tagged = (discriminator, variants) => {
  const vs = plain(variants);
  const broken = vs.find((v) => v.x !== null);
  if (broken !== undefined) return node(BROKEN, broken.x);
  if (vs.length === 0) return node(BROKEN, "a tagged schema needs a variant");
  const tag = duplicate(vs.map((v) => v.g));
  if (tag !== undefined) return node(BROKEN, `two variants have the tag "${tag}"`);
  const name = duplicate(vs.map((v) => v.n));
  if (name !== undefined) return node(BROKEN, `two variants are named ${name}`);
  const clash = vs.find((v) => v.p !== null && v.p.a.some((f) => f.k === discriminator || f.n === discriminator));
  if (clash !== undefined) return node(BROKEN, `the variant ${clash.n} has a field on the discriminator "${discriminator}"`);
  return node(TAGGED, discriminator, vs);
};

export const conversion = (forward, backward) => ({ f: forward, b: backward });
export const converted = (source, c) => node(CONVERTED, source, c);

// A recursive schema is a reference to its definition: `n` its name, `f`
// the function that builds its body, `s` 0 unbuilt, 1 building, 2 built,
// `b` the body. The function is given this very node, so a reference is
// resolved by identity.
export const recursive = (name, body) => node(REF, { n: name, f: body, s: 0, b: null });

export const flip = (s) => (s.t === FLIPPED ? s.a : node(FLIPPED, s));
export const typeOnly = (s) => node(PROJECTED, TYPE, s);
export const encodedOnly = (s) => node(PROJECTED, ENCODED, s);

// A reference's body, built the first time it is needed; null while it is
// being built, the one way a reference can dangle.
const resolve = (ref) => {
  const d = ref.a;
  if (d.s === 2) return d.b;
  if (d.s === 1) return null;
  d.s = 1;
  d.b = d.f(ref);
  d.s = 2;
  return d.b;
};
const dangling = (d) => `the recursive schema ${d.n} is used before its body is built`;

// ---- What a root operation checks before it reads anything ----------------

// The first construction failure the schema reaches.
const problemIn = (n, seen) => {
  switch (n.t) {
    case LIST:
    case NULLABLE:
    case FLIPPED:
    case CONVERTED:
      return problemIn(n.a, seen);
    case PROJECTED:
      return problemIn(n.b, seen);
    case RECORD:
      for (const f of n.a) {
        const p = problemIn(f.s, seen);
        if (p !== null) return p;
      }
      return null;
    case TAGGED:
      for (const v of n.b) {
        const p = v.p === null ? null : problemIn(v.p, seen);
        if (p !== null) return p;
      }
      return null;
    case REF: {
      if (seen.has(n.a)) return null;
      seen.add(n.a);
      const body = resolve(n);
      return body === null ? dangling(n.a) : problemIn(body, seen);
    }
    case BROKEN:
      return n.a;
    default:
      return null;
  }
};

// Whether the `side` endpoint holds a conversion's target, which has no
// external form: a reachability walk over (node, side), so a flip inside a
// recursive schema is followed exactly.
const opaqueIn = (n, side, seen) => {
  switch (n.t) {
    case LIST:
    case NULLABLE:
      return opaqueIn(n.a, side, seen);
    case RECORD:
      return n.a.some((f) => opaqueIn(f.s, side, seen));
    case TAGGED:
      return n.b.some((v) => v.p !== null && opaqueIn(v.p, side, seen));
    case CONVERTED:
      return side === TYPE || opaqueIn(n.a, ENCODED, seen);
    case FLIPPED:
      return opaqueIn(n.a, 1 - side, seen);
    case PROJECTED:
      return opaqueIn(n.b, n.a, seen);
    case REF: {
      const mask = seen.get(n.a) ?? 0;
      if (mask & (1 << side)) return false;
      seen.set(n.a, mask | (1 << side));
      const body = resolve(n);
      return body !== null && opaqueIn(body, side, seen);
    }
    default:
      return false;
  }
};

const analyse = (s) => {
  if (s.z === null) {
    const seen = new Map();
    s.z = { problem: problemIn(s, new Set()), opaque: [opaqueIn(s, ENCODED, seen), opaqueIn(s, TYPE, seen)] };
  }
  return s.z;
};

// ---- One operation's context ----------------------------------------------

// What a step answers when it failed: its issues are in the context's list.
const FAIL = {};

// The path to a value, innermost step first: `i` the step as the input
// names it, `o` as the output does — a key, or an index.
const pathList = (path, output) => {
  const out = [];
  for (let p = path; p !== null; p = p.p) {
    const s = output ? p.o : p.i;
    out.push(typeof s === "number" ? { $: "Index", a: s } : { $: "Field", a: s });
  }
  return out.reverse();
};

// An issue at `path`, in the context's list. `output` says the failure is
// in what the operation writes.
const failAt = (c, path, code, message, input, output) => {
  c.issues.push(issueOf(code, c.dir, output || c.cv ? c.outE : c.inE, c.report ? just(input) : nothing, message, pathList(path, output)));
  return FAIL;
};

const rootErr = (c, endpoint, code, message) => err([issueOf(code, c.dir, endpoint, nothing, message, [])]);

// The context of one root operation, or the `Err` that ends it before
// anything is read: bad options, a construction failure, an endpoint with
// no external form read or written outside.
const start = (s, o, dir, src, sh, dst, dh, json) => {
  const c = {
    all: o.errors === "AllErrors",
    reject: o.unknownKeys === "Reject",
    max: o.maxDepth,
    report: o.reportInput,
    dir,
    json,
    src,
    sh,
    dst,
    dh,
    inE: endpoints[src],
    outE: endpoints[dst],
    cv: false,
    issues: [],
    payload: null,
  };
  if (!(Number.isInteger(o.maxDepth) && o.maxDepth >= 0 && o.maxDepth <= maxDepthCeiling)) {
    return rootErr(c, c.inE, "InvalidOptions", `maxDepth must be from 0 to ${maxDepthCeiling}, not ${o.maxDepth}`);
  }
  const z = analyse(s);
  if (z.problem !== null) return rootErr(c, c.inE, "InvalidSchema", z.problem);
  for (const [host, side] of [[sh, src], [dh, dst]]) {
    if (host && z.opaque[side]) {
      return rootErr(c, endpoints[side], "InvalidSchema", `the ${endpoints[side]} endpoint holds a conversion's target, which has no external form to read or write`);
    }
  }
  return c;
};

const finish = (c, x) => (x === FAIL ? err(c.issues) : ok(x));

// ---- The traversal ---------------------------------------------------------

// Run node `n` on value `v` at `depth` and `path`. `active` lists the
// recursive schemas entered at this position since the last descent:
// entering one again would read nothing, so it is refused there (§5).
// A flip, a projection, a reference and the last step of a conversion loop
// here; a level of the value costs this frame and its record's or list's.
const run = (c, n, depth, path, active, v) => {
  for (;;) {
    switch (n.t) {
      case PRIM:
        return prim(c, n.a, depth, path, v);
      case LIST:
        return listOf(c, n.a, depth, path, v);
      case NULLABLE: {
        if (c.sh ? v === null : v.$ === "Null") return c.dh ? null : nul;
        const x = run(c, n.a, depth, path, active, c.sh ? v : v.a);
        return x === FAIL ? FAIL : c.dh ? x : nonNull(x);
      }
      case RECORD:
        if (c.sh && !isObject(v)) return failAt(c, path, "WrongShape", "expected an object", v, false);
        return recordOf(c, n, null, depth, path, v);
      case TAGGED: {
        const x = variantOf(c, n, path, v);
        if (x === FAIL) return FAIL;
        if (x.p === null) return nullaryOf(c, n.a, x, path, v);
        if (depth >= c.max) return failAt(c, path, "DepthExceeded", "the depth limit is reached", c.payload, false);
        return recordOf(c, x.p, { d: n.a, v: x }, depth + 1, path, c.payload);
      }
      case CONVERTED:
        if (c.src === ENCODED && c.dst === TYPE) {
          const b = run(c, n.a, depth, path, active, v);
          return b === FAIL ? FAIL : call(c, path, n.b.f, b);
        }
        if (c.src === TYPE && c.dst === ENCODED) {
          const b = call(c, path, n.b.b, v);
          if (b === FAIL) return FAIL;
          if (!c.cv) c = { ...c, cv: true };
          n = n.a;
          v = b;
          continue;
        }
        if (c.src === TYPE) return v;
        n = n.a;
        continue;
      case FLIPPED:
        c = { ...c, src: 1 - c.src, dst: 1 - c.dst };
        n = n.a;
        continue;
      case PROJECTED:
        c = { ...c, src: n.a, dst: n.a };
        n = n.b;
        continue;
      case REF: {
        for (let a = active; a !== null; a = a.next) {
          if (a.d === n.a) return failAt(c, path, "InvalidSchema", `the recursive schema ${n.a.n} refers to itself without reading into the value`, v, false);
        }
        const body = resolve(n);
        if (body === null) return failAt(c, path, "InvalidSchema", dangling(n.a), v, false);
        active = { d: n.a, next: active };
        n = body;
        continue;
      }
      default:
        return failAt(c, path, "InvalidSchema", n.a, v, false);
    }
  }
};

const isObject = (v) => typeof v === "object" && v !== null && !Array.isArray(v);

const prim = (c, p, depth, path, v) => {
  switch (p) {
    case 0:
      return typeof v === "string" ? v : failAt(c, path, "WrongShape", "expected a string", v, false);
    case 1:
      return typeof v === "boolean" ? v : failAt(c, path, "WrongShape", "expected a boolean", v, false);
    case 2:
      if (typeof v !== "number") return failAt(c, path, "WrongShape", "expected a number", v, false);
      return Number.isSafeInteger(v) ? v : failAt(c, path, "InvalidValue", "expected a safe integer", v, false);
    case 3:
      if (typeof v !== "number") return failAt(c, path, "WrongShape", "expected a number", v, false);
      if (c.json && c.dh && !Number.isFinite(v)) return failAt(c, path, "PrintFailed", "JSON has no number for NaN or an infinity", v, true);
      return v;
    case 4:
      if (typeof v !== "number") return failAt(c, path, "WrongShape", "expected a number", v, false);
      return Number.isFinite(v) ? v : failAt(c, path, "InvalidValue", "expected a finite number", v, false);
    case 5:
      if (c.sh && v !== null) return failAt(c, path, "WrongShape", "expected null", v, false);
      return c.dh ? null : nul;
    default:
      if (c.json && c.dh) {
        const r = printable(v, c.max - depth);
        if (r === 1) return failAt(c, path, "DepthExceeded", "the value nests deeper than the depth limit", v, true);
        if (r === 2) return failAt(c, path, "PrintFailed", "the value holds NaN or an infinity, which JSON has no number for", v, true);
      }
      return v;
  }
};

// Whether a host value prints as JSON as it is: 0 when it does, 1 when it
// nests deeper than `budget` more levels, 2 when it holds a number JSON
// has no form for.
const printable = (v, budget) => {
  if (typeof v === "number") return Number.isFinite(v) ? 0 : 2;
  if (typeof v !== "object" || v === null) return 0;
  const items = Array.isArray(v) ? v : Object.keys(v).map((k) => v[k]);
  for (const x of items) {
    if (budget < 1) return 1;
    const r = printable(x, budget - 1);
    if (r !== 0) return r;
  }
  return 0;
};


// A list's elements, each one level down: the depth bound is tested before
// the descent (§5), and the references entered at the list's own position
// are left behind. A failure is an issue added since `before`.
const listOf = (c, child, depth, path, v) => {
  if (c.sh && !Array.isArray(v)) return failAt(c, path, "WrongShape", "expected an array", v, false);
  const before = c.issues.length;
  const xs = plain(v);
  const out = [];
  for (let i = 0; i < xs.length; i++) {
    const x = depth >= c.max ? failAt(c, { p: path, i, o: i }, "DepthExceeded", "the depth limit is reached", xs[i], false) : run(c, child, depth + 1, { p: path, i, o: i }, null, xs[i]);
    if (x === FAIL) {
      if (!c.all) return FAIL;
    } else out.push(x);
  }
  return c.issues.length > before ? FAIL : out;
};

// Under `Reject`, each own key of a host object the record does not claim,
// in the object's own key order, at its own path. True when one was found.
const unknownKeys = (c, fs, claimed, path, v) => {
  let found = false;
  for (const k of Object.keys(v)) {
    if (k === claimed || fs.some((f) => (c.src === ENCODED ? f.k : f.n) === k)) continue;
    failAt(c, { p: path, i: k, o: k }, "UnknownKey", `unexpected key "${k}"`, v[k], false);
    if (!c.all) return true;
    found = true;
  }
  return found;
};

// A fresh host object with no prototype, so that writing `__proto__` or
// `constructor` makes an own key and changes nothing else (§5); a variant's
// discriminator is its first key.
const newObject = (owner) => {
  const o = Object.create(null);
  if (owner !== null) o[owner.d] = owner.v.g;
  return o;
};

// A typed record's field values, first field first, from the product its
// mapping takes it apart into: `( ( ( (), a ), b ), c )` is `[a, b, c]`.
const valuesOf = (c, n, v) => {
  const values = new Array(n.a.length);
  let p = (c.src === ENCODED ? n.b.fe : n.b.fa)(v);
  for (let i = values.length - 1; i >= 0; i--) {
    values[i] = p.b;
    p = p.a;
  }
  return values;
};

// The typed value a record's fields make: the record its mapping builds
// from their product — in its variant's constructor, for a payload.
const made = (c, n, owner, out) => {
  let product = null;
  for (const x of out) product = { a: product, b: x };
  const record = (c.dst === ENCODED ? n.b.te : n.b.ta)(product);
  return owner === null ? record : (c.dst === ENCODED ? owner.v.e : owner.v.a).i(record);
};

// What a host object does not have.
const ABSENT = {};

// A record's fields, in order, each one level down from the record at
// `depth`, then the value they make. `owner` is a payload's discriminator
// and variant, `{d, v}`. This frame and `run`'s are what one level of a
// value costs the stack, so it keeps few locals.
const recordOf = (c, n, owner, depth, path, v) => {
  const before = c.issues.length;
  if (c.sh && c.reject && unknownKeys(c, n.a, owner === null ? null : owner.d, path, v) && !c.all) return FAIL;
  const values = c.sh ? v : valuesOf(c, n, v);
  const out = c.dh ? newObject(owner) : [];
  for (let i = 0; i < n.a.length; i++) {
    const f = n.a[i];
    const here = { p: path, i: c.src === ENCODED ? f.k : f.n, o: c.dst === ENCODED ? f.k : f.n };
    let x = !c.sh ? values[i] : Object.hasOwn(v, here.i) ? v[here.i] : ABSENT;
    if (x === ABSENT) x = f.o ? missing : failAt(c, here, "MissingKey", `missing key "${here.i}"`, v, false);
    else if (!(f.o && !c.sh && x.$ === "Missing")) {
      if (f.o && !c.sh) x = x.a;
      x = depth >= c.max ? failAt(c, here, "DepthExceeded", "the depth limit is reached", x, false) : run(c, f.s, depth + 1, here, null, x);
      if (f.o && x !== FAIL) x = present(x);
    }
    if (x === FAIL) {
      if (!c.all) return FAIL;
    } else if (!c.dh) out.push(x);
    else if (!f.o) out[here.o] = x;
    else if (x.$ === "Present") out[here.o] = x.a;
  }
  return c.issues.length > before ? FAIL : c.dh ? out : made(c, n, owner, out);
};

// The variant a tagged value is: the discriminator is read first. Its
// payload is read from the host object itself, or from what a typed value's
// constructor holds, left in `c.payload`.
const variantOf = (c, n, path, v) => {
  const d = n.a;
  c.payload = v;
  if (c.sh) {
    if (!isObject(v)) return failAt(c, path, "WrongShape", "expected an object", v, false);
    const here = { p: path, i: d, o: d };
    if (!Object.hasOwn(v, d)) return failAt(c, here, "MissingKey", `missing key "${d}"`, v, false);
    const tag = v[d];
    const variant = typeof tag === "string" ? n.b.find((x) => x.g === tag) : undefined;
    return variant ?? failAt(c, here, "UnknownTag", "unknown tag; expected " + n.b.map((x) => `"${x.g}"`).join(", "), tag, false);
  }
  for (const x of n.b) {
    const p = (c.src === ENCODED ? x.e : x.a).p(v);
    if (p.$ === "Just") {
      c.payload = p.a;
      return x;
    }
  }
  return failAt(c, path, "InvalidSchema", "no variant of this tagged schema takes the value", v, false);
};

// A variant with no payload: its discriminator alone outside, its
// constructor inside.
const nullaryOf = (c, d, variant, path, v) => {
  if (c.sh && c.reject && unknownKeys(c, [], d, path, v)) return FAIL;
  return c.dh ? newObject({ d, v: variant }) : (c.dst === ENCODED ? variant.e : variant.a).i(null);
};

// A conversion's own answer. Its issues are moved to where the value is:
// the engine's path in front of theirs, and its direction and endpoint; an
// `Err` with none is one of the engine's.
const call = (c, path, fn, v) => {
  const r = fn(v);
  if (r.$ === "Ok") return r.a;
  const prefix = pathList(path, false);
  const given = plain(r.a);
  const own = given.length === 0 ? [{ code: "ConversionFailed", message: "the conversion failed without an issue", path: [] }] : given;
  for (const i of own) {
    c.issues.push(issueOf(i.code, c.dir, c.outE, c.report ? just(v) : nothing, i.message, prefix.concat(plain(i.path))));
  }
  return FAIL;
};

// ---- Running -----------------------------------------------------------------

export const decodeWith = (s, o, v) => {
  const c = start(s, o, "Decoding", ENCODED, false, TYPE, false, false);
  return c.$ !== undefined ? c : finish(c, run(c, s, 0, null, null, v));
};

export const encodeWith = (s, o, v) => {
  const c = start(s, o, "Encoding", TYPE, false, ENCODED, false, false);
  return c.$ !== undefined ? c : finish(c, run(c, s, 0, null, null, v));
};

export const readWith = (s, o, v) => {
  const c = start(s, o, "Decoding", ENCODED, true, TYPE, false, false);
  return c.$ !== undefined ? c : finish(c, run(c, s, 0, null, null, v));
};

export const writeWith = (s, o, v) => {
  const c = start(s, o, "Encoding", TYPE, false, ENCODED, true, false);
  return c.$ !== undefined ? c : finish(c, run(c, s, 0, null, null, v));
};

// `JSON.parse` reports malformed text by throwing a `SyntaxError`, and only
// that is an answer; anything else it throws goes on as it came (CLAUDE.md
// rule 9).
export const parseWith = (s, o, text) => {
  const c = start(s, o, "Decoding", ENCODED, true, TYPE, false, true);
  if (c.$ !== undefined) return c;
  let v;
  try {
    v = JSON.parse(text);
  } catch (e) {
    if (!(e instanceof SyntaxError)) throw e;
    return rootErr(c, c.inE, "ParseFailed", `invalid JSON: ${e.message}`);
  }
  return finish(c, run(c, s, 0, null, null, v));
};

export const printWith = (s, o, v) => {
  const c = start(s, o, "Encoding", TYPE, false, ENCODED, true, true);
  if (c.$ !== undefined) return c;
  const x = run(c, s, 0, null, null, v);
  return x === FAIL ? err(c.issues) : ok(JSON.stringify(x));
};

// ---- Descriptions ------------------------------------------------------------

// `Shape`'s constructors take up to two arguments, so each is `{$, a, b}`.
const shapeOf = (tag, a, b) => ({ $: tag, a, b: b ?? null });

export const describe = (s) => {
  const ids = new Map();
  const definitions = [];
  const shape = (n) => {
    switch (n.t) {
      case PRIM:
        return shapeOf("Primitive", kinds[n.a]);
      case LIST:
        return shapeOf("ListOf", shape(n.a));
      case NULLABLE:
        return shapeOf("NullableOf", shape(n.a));
      case RECORD:
        return shapeOf("RecordOf", n.a.map((f) => ({ key: f.k, name: f.n, optional: f.o, shape: shape(f.s) })));
      case TAGGED:
        return shapeOf("TaggedOf", n.a, n.b.map((v) => ({ name: v.n, payload: v.p === null ? nothing : just(shape(v.p)), tag: v.g })));
      case CONVERTED:
        return shapeOf("Converted", shape(n.a));
      case FLIPPED:
        return shapeOf("Flipped", shape(n.a));
      case PROJECTED:
        return shapeOf(n.a === TYPE ? "TypeOnly" : "EncodedOnly", shape(n.b));
      case REF: {
        if (ids.has(n.a)) return shapeOf("Reference", ids.get(n.a));
        const id = ids.size;
        ids.set(n.a, id);
        const body = resolve(n);
        definitions.push({ id, name: n.a.n, shape: body === null ? shapeOf("Invalid", dangling(n.a)) : shape(body) });
        return shapeOf("Reference", id);
      }
      default:
        return shapeOf("Invalid", n.a);
    }
  };
  const root = shape(s);
  definitions.sort((x, y) => x.id - y.id);
  return { definitions, root };
};
