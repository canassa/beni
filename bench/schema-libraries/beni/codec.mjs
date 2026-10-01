// The beni rows' adapter (`adapters/beni.mjs`, `adapters/beni-library.mjs`):
// `Bench.beni`'s exported runners, as built by `build.mjs`, behind the
// harness's codec contract. A beni `Type` value differs from the harness's
// program shape in two places — an optional field is `Present`/`Missing`,
// and a union item is a constructor — so each direction maps between them
// here, as `common.mjs`'s `toProgram`/`toWire` map for the other rows.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = process.env.BENI_SCHEMA_OUT ?? fileURLToPath(new URL(".", import.meta.url));

const exportsOf = (file) => readFileSync(file, "utf8").match(/export\s*\{([^}]*)\}/)[1].split(",").map((s) => s.trim());

export async function load(mode) {
  const names = exportsOf(join(root, `names-${mode}`, "Bench.mjs"));
  const short = exportsOf(join(root, `out-${mode}`, "Bench.mjs"));
  const m = await import(pathToFileURL(join(root, `out-${mode}`, "Bench.mjs")).href);
  const fn = (name) => {
    const f = m[short[names.indexOf(`Bench$${name}`)]];
    if (typeof f !== "function") throw new Error(`Bench.beni exports no ${name}`);
    return f;
  };
  return {
    flat: [fn("parseFlat"), fn("printFlat")],
    list: [fn("parseList"), fn("printList")],
    union: [fn("parseUnion"), fn("printUnion")],
    typeahead: [fn("parseTypeahead"), fn("printTypeahead")],
  };
}

// The tags of `core/Schema`'s `Presence` and of the union's constructors,
// as a `--library` build writes them: strings.
const MISSING = { $: "Missing", a: null };

const userOut = (u) => {
  const out = { userId: u.userId, displayName: u.displayName, email: u.email, age: u.age, active: u.active, score: u.score, role: u.role };
  if (u.nickname.$ === "Present") out.nickname = u.nickname.a;
  return out;
};
const userIn = (u) => ({
  userId: u.userId,
  displayName: u.displayName,
  email: u.email,
  age: u.age,
  active: u.active,
  score: u.score,
  role: u.role,
  nickname: Object.hasOwn(u, "nickname") ? { $: "Present", a: u.nickname } : MISSING,
});
const itemOut = (i) => {
  switch (i.$) {
    case "UserItem": return { kind: "user", user: userOut(i.a.user) };
    case "CountItem": return { kind: "count", count: i.a.count };
    case "TextItem": return { kind: "text", text: i.a.text };
    default: return { kind: "point", x: i.a.x, y: i.a.y };
  }
};
const itemIn = (i) => {
  switch (i.kind) {
    case "user": return { $: "UserItem", a: { user: userIn(i.user) } };
    case "count": return { $: "CountItem", a: { count: i.count } };
    case "text": return { $: "TextItem", a: { text: i.text } };
    default: return { $: "PointItem", a: { x: i.x, y: i.y } };
  }
};

const toProgram = { flat: userOut, list: (xs) => xs.map(userOut), union: (xs) => xs.map(itemOut), typeahead: (t) => t };
const toType = { flat: userIn, list: (xs) => xs.map(userIn), union: (xs) => xs.map(itemIn), typeahead: (t) => t };

const issues = (found) => found.map((i) => ({ path: i.path.map((s) => s.a), code: i.code }));

export function codec(runners, workload, direction) {
  const pair = runners[workload];
  if (!pair) throw new Error(`no beni row for ${workload}: a recursive record is not a v1 declaration`);
  if (direction === "decode") {
    const parse = pair[0];
    const out = toProgram[workload];
    return (text) => {
      const r = parse(text);
      return r.$ === "Ok" ? { ok: true, value: out(r.a) } : { ok: false, issues: issues(r.a) };
    };
  }
  const print = pair[1];
  const into = toType[workload];
  return (value) => {
    const r = print(into(value));
    return r.$ === "Ok" ? { ok: true, value: r.a } : { ok: false, issues: issues(r.a) };
  };
}
