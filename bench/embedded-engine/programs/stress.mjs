// Engine-level fidelity sweep, independent of beni: prints one line per
// finding so two engines' outputs can be diffed. Deterministic, no Date.
const out = [];
const p = (s) => out.push(s);

// 1. Number::toString over 2^20 doubles from random bit patterns, plus
// round trip through Number(), plus toFixed/toPrecision/toExponential
// on a subset (core does not call them, but a platform might).
const buf = new DataView(new ArrayBuffer(8));
let s = 0x9e3779b9 | 0, t = 0x85ebca6b | 0;
const next = () => { s ^= s << 13; s ^= s >>> 17; s ^= s << 5; t = (Math.imul(t, 1664525) + 1013904223) | 0; return (s ^ t) >>> 0; };
let h = 0x811c9dc5;
const mix = (str) => { for (let i = 0; i < str.length; i++) h = Math.imul(h ^ str.charCodeAt(i), 0x01000193); };
let bad = 0;
for (let i = 0; i < 1 << 20; i++) {
  buf.setUint32(0, next()); buf.setUint32(4, next());
  const x = buf.getFloat64(0);
  const str = String(x);
  mix(str);
  if (!Object.is(Number(str), x) && x === x) { if (bad++ < 5) p(`roundtrip ${str}`); }
  if (i % 64 === 0) mix(`${x.toFixed(3)}|${x.toPrecision(7)}|${x.toExponential(4)}`);
}
// integers and near-integers, and decimals k/10^d
for (let i = 0; i < 200000; i++) { mix(String(i * 1e15 + 0.5)); mix(String(i / 1000)); mix(String(2 ** 53 + i)); }
for (let e = -330; e <= 310; e++) mix(String(Number(`1e${e}`)) + String(Number(`4.9e${e}`)));
p(`numbers fnv ${(h >>> 0).toString(16)} roundtrip-bad ${bad}`);

// 2. Unicode, every code point: case mapping, \s, trim, \d, \w with u, isWellFormed.
const ranges = { upper: [], lower: [], ws: [], trim: [], d: [], wu: [] };
for (let cp = 0; cp <= 0x10ffff; cp++) {
  if (cp >= 0xd800 && cp <= 0xdfff) continue;
  const c = String.fromCodePoint(cp);
  const u = c.toUpperCase(), l = c.toLowerCase();
  if (u !== c) p(`U ${cp.toString(16)} ${[...u].map((x) => x.codePointAt(0).toString(16)).join(",")}`);
  if (l !== c) p(`L ${cp.toString(16)} ${[...l].map((x) => x.codePointAt(0).toString(16)).join(",")}`);
  if (/\s/.test(c)) p(`S ${cp.toString(16)}`);
  if (c.trim() === "") p(`T ${cp.toString(16)}`);
  if (/^\d$/u.test(c)) p(`D ${cp.toString(16)}`);
  if (/^\w$/iu.test(c)) p(`W ${cp.toString(16)}`);
  if (/^\p{L}$/u.test(c) !== /^\p{Alphabetic}$/u.test(c)) p(`P ${cp.toString(16)}`);
}
p(`final-sigma ${"ΑΣ ΑΣΑ Σ".toLowerCase()}`);
p(`lone ${"\ud800x".isWellFormed()} ${"\ud800x".toWellFormed().codePointAt(0).toString(16)}`);

// 3. Strings and regexps the way core and platforms use them.
p("a,b,,c,".split(",").join("|"));
p("a.b.c".replaceAll(".", "$&"));
p("x".padStart(5, "ab") + "x".repeat(3));
p(JSON.stringify({ s: "\u0000\u001f\"\\</script>\u2028\u2029\ud800\ud83d\ude00", n: [1e21, 5e-324, -0, 0.1, NaN, Infinity] }));
p(JSON.stringify(JSON.parse('{"a":1e400,"b":-0,"__proto__":1,"c":"\\u00e9"}')));
p(JSON.stringify({ b: 1, a: 2, 1: 3, 0: 4 }));
p(String([1, [2, [3]]]) + String({}) + String(null) + String(undefined) + String(Symbol("q")));
p((123.456).toString(16) + " " + (255).toString(36) + " " + (-0).toString() + " " + (0.000001).toString() + " " + (1e-7).toString());
p(encodeURIComponent("a b&ü😀") + " " + decodeURIComponent("%E2%82%AC"));
p(/(?<y>\d{4})-(?<m>\d\d)/u.exec("2026-10").groups.y);
p("ǅ".normalize("NFD").length + " " + "é".normalize("NFD").length);

// 4. Sort stability and comparator order, Array and Map/Set iteration order.
const arr = Array.from({ length: 2000 }, (_, i) => ({ k: (i * 7919) % 13, i }));
p(arr.slice().sort((a, b) => a.k - b.k).map((x) => x.i).join(",").length + " " + arr.slice().sort((a, b) => a.k - b.k).slice(0, 20).map((x) => x.i).join(","));
p(["b", "a", "B", "é", "e", "😀", "\uffff"].sort().join(","));
const m = new Map(); for (let i = 0; i < 100; i++) m.set((i * 37) % 101, i); p([...m.keys()].slice(0, 10).join(","));
p(Object.keys({ z: 1, 10: 1, 2: 1, a: 1, [-1]: 1 }).join(","));

// 5. Errors as a page might print them.
try { null.x; } catch (e) { p(`${e.name}`); }
try { (function f() { f(); })(); } catch (e) { p(`${e.name}: ${e instanceof RangeError}`); }

console.log(out.join("\n"));
