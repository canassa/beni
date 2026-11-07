// Prints src/js/WorkerGlobals.zig's table: every name on the global object of a
// dedicated, shared and service worker, from the pinned Webref IDL
// (docs/design/research/workers/webref-idl-3.86.0.tgz) and ECMA-262/402
// (docs/design/workers.md §4, *The worker global allow-list*).
//
//   mkdir idl && tar xzf docs/design/research/workers/webref-idl-3.86.0.tgz -C idl
//   npm pack webidl2@24.5.0 && mkdir wi && tar xzf webidl2-24.5.0.tgz -C wi
//   node scripts/worker-globals.mjs idl/package wi/package > src/js/WorkerGlobals.zig
//   zig fmt src/js/WorkerGlobals.zig
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { createRequire } from "node:module";

const [idlDir, webidlDir] = process.argv.slice(2);
const { parse } = createRequire(import.meta.url)(join(process.cwd(), webidlDir, "dist", "webidl2.js"));

// The realms, their bit in the table and the global names their global
// interface declares ([Global=(Worker,DedicatedWorker)] and so on).
const realms = [
  { tag: "dedicatedWorker", bit: 1, scope: "DedicatedWorkerGlobalScope" },
  { tag: "sharedWorker", bit: 2, scope: "SharedWorkerGlobalScope" },
  { tag: "serviceWorker", bit: 4, scope: "ServiceWorkerGlobalScope" },
];

// ECMA-262 (2025) §19 and Annex B.2.1, and ECMA-402's `Intl`: the global
// object's own properties in every realm.
const ecmascript = [
  "globalThis", "Infinity", "NaN", "undefined", "eval", "isFinite", "isNaN", "parseFloat", "parseInt",
  "decodeURI", "decodeURIComponent", "encodeURI", "encodeURIComponent", "escape", "unescape",
  "AggregateError", "Array", "ArrayBuffer", "Atomics", "BigInt", "BigInt64Array", "BigUint64Array",
  "Boolean", "DataView", "Date", "Error", "EvalError", "FinalizationRegistry", "Float16Array",
  "Float32Array", "Float64Array", "Function", "Int8Array", "Int16Array", "Int32Array", "Iterator",
  "JSON", "Map", "Math", "Number", "Object", "Promise", "Proxy", "RangeError", "ReferenceError",
  "Reflect", "RegExp", "Set", "SharedArrayBuffer", "String", "Symbol", "SyntaxError", "TypeError",
  "Uint8Array", "Uint8ClampedArray", "Uint16Array", "Uint32Array", "URIError", "WeakMap", "WeakRef",
  "WeakSet", "Intl",
];

const defs = [];
for (const file of readdirSync(idlDir).filter((f) => f.endsWith(".idl")).sort()) {
  defs.push(...parse(readFileSync(join(idlDir, file), "utf8")));
}

function attr(node, name) {
  return node.extAttrs?.find((a) => a.name === name);
}
function names(a) {
  if (!a) return null;
  if (a.rhs?.type === "identifier") return [a.rhs.value];
  if (a.rhs?.type === "*") return ["*"];
  if (Array.isArray(a.rhs?.value)) return a.rhs.value.map((v) => v.value);
  return [];
}

// Each global interface's global names.
const globals = new Map();
for (const d of defs) {
  const g = attr(d, "Global");
  if (g && !d.partial) globals.set(d.name, names(g));
}
const realmNames = new Map(realms.map((r) => [r.tag, globals.get(r.scope)]));
function exposedIn(set, realm) {
  if (!set) return false;
  return set.includes("*") || set.some((n) => realmNames.get(realm).includes(n));
}

// Interfaces, mixins and their members, partials merged with their own
// [Exposed] (a partial without one takes the original's).
const byName = new Map();
for (const d of defs) {
  if (!["interface", "interface mixin", "namespace", "callback interface"].includes(d.type)) continue;
  let e = byName.get(d.name);
  if (!e) byName.set(d.name, (e = { type: d.type, exposed: null, inherits: null, legacyNoObject: false, parts: [] }));
  if (!d.partial) {
    e.exposed = names(attr(d, "Exposed"));
    e.inherits = d.inheritance ?? null;
    e.legacyNoObject = !!attr(d, "LegacyNoInterfaceObject");
    e.hasConstants = d.members.some((m) => m.type === "const");
  }
  e.parts.push({ exposed: names(attr(d, "Exposed")), members: d.members });
}
const includes = new Map();
for (const d of defs) {
  if (d.type !== "includes") continue;
  if (!includes.has(d.target)) includes.set(d.target, []);
  includes.get(d.target).push(d.includes);
}

const table = new Map();
function add(name, bit) {
  table.set(name, (table.get(name) ?? 0) | bit);
}

for (const realm of realms) {
  for (const n of ecmascript) add(n, realm.bit);
  // The interface objects and namespaces exposed in the realm.
  for (const [name, e] of byName) {
    if (e.type === "interface mixin") continue;
    if (e.type === "callback interface" && !e.hasConstants) continue;
    if (e.legacyNoObject) continue;
    if (exposedIn(e.exposed, realm.tag)) add(name, realm.bit);
  }
  // The members of the global interface, its ancestors and their mixins.
  function members(iface, ownerExposed) {
    const e = byName.get(iface);
    if (!e) return;
    for (const part of e.parts) {
      const partExposed = part.exposed ?? ownerExposed ?? e.exposed;
      for (const m of part.members) {
        if (!m.name || m.special === "static") continue;
        if (!["attribute", "operation", "const"].includes(m.type)) continue;
        const own = names(attr(m, "Exposed")) ?? partExposed;
        if (own && !exposedIn(own, realm.tag)) continue;
        add(m.name, realm.bit);
      }
    }
  }
  for (let at = realm.scope; at; at = byName.get(at)?.inherits) {
    const e = byName.get(at);
    members(at, null);
    for (const mixin of includes.get(at) ?? []) members(mixin, e.exposed);
  }
}

const rows = [...table.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
const out = [];
out.push("//! The names on a browser worker's global object, by realm (`workers.md` §4,");
out.push("//! *The worker global allow-list*). Generated by `scripts/worker-globals.mjs`");
out.push("//! from the pinned Webref IDL 3.86.0");
out.push("//! (`docs/design/research/workers/webref-idl-3.86.0.tgz`) and ECMA-262/402's");
out.push("//! global object; do not edit by hand.");
out.push("//!");
out.push("//! A name is on a realm's global object when it is an interface object or a");
out.push("//! namespace exposed there, or a member of the realm's global interface, its");
out.push("//! ancestors and their included mixins exposed there. Bits: 1 dedicated, 2");
out.push("//! shared, 4 service.");
out.push('const std = @import("std");');
out.push("");
out.push(`pub const dedicated: u8 = 1;`);
out.push(`pub const shared: u8 = 2;`);
out.push(`pub const service: u8 = 4;`);
out.push("");
out.push("pub const table = std.StaticStringMap(u8).initComptime(.{");
for (const [name, bits] of rows) out.push(`    .{ "${name}", ${bits} },`);
out.push("});");
console.log(out.join("\n"));
console.error(`${rows.length} names; dedicated ${rows.filter(([, b]) => b & 1).length}, shared ${rows.filter(([, b]) => b & 2).length}, service ${rows.filter(([, b]) => b & 4).length}`);
