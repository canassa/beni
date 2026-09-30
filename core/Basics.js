// The sibling JavaScript of `Basics.beni` (docs/design/boundary.md §4): one
// export per `foreign` value, under the same name, and nothing else.
//
// Every function here is n-ary, with n the number of parameters its beni
// annotation lists before the `->`. That is the calling convention of
// fast-compiler.md §9.3: a saturated call at statically known arity is a
// DIRECT call, so `a + b` reaches `add(a, b)` with no adapter. Function
// types are n-ary throughout, so a function passed as a value is the same
// n-ary function and nothing here has to know about currying.
//
// Representation (backend.md §4, §9.4), which this file and the emitter
// agree on by contract:
//   Int, Float   a number            Bool          true / false
//   Char         a one-scalar string String        a native string
//   ()           null                tuple         { a, b, … }
//   record       a plain object      List          an array, a view or a trie,
//                                                    read by backend.md §4's protocol
//   constructor  { $: "Tag", a, … }, or the bare tag string when every
//                constructor of the type is nullary (`Order` is "LT").
//
// §4.1's recipe: address by value, marshal to plain data, every
// specification-defined failure is a constructor, and no privileged entry
// point may throw. Nothing here reaches outside the language runtime, so
// there is no `try`/`catch` to write: the one operation that can throw on
// its own is arithmetic on a value of the wrong type, which the type
// checker has already ruled out.

export const add = (a, b) => a + b;
export const sub = (a, b) => a - b;
export const mul = (a, b) => a * b;
export const fdiv = (a, b) => a / b;

// Truncated towards zero, and 0 for a zero divisor rather than Infinity:
// `Int` has no infinity, so returning one would put a value in the type
// that the type does not contain.
export const idiv = (a, b) => (b === 0 ? 0 : Math.trunc(a / b));
export const pow = (a, b) => a ** b;

export const lt = (a, b) => a < b;
export const gt = (a, b) => a > b;
export const le = (a, b) => a <= b;
export const ge = (a, b) => a >= b;

// Short-circuiting is the reason these are `foreign` at all (Basics.beni's
// header): a beni definition would take both sides as arguments. The
// emitter recognises a saturated call of either and emits `&&` / `||`
// directly, so these two are reached only when the function is passed as a
// value — where both arguments already exist and eagerness costs nothing.
export const and = (a, b) => a && b;
export const or = (a, b) => a || b;

// `++` over the two appendable representations. One definition over both is
// the other reason Basics.beni lists it as foreign. A `++` the checker
// knows to be on lists calls `List.append` instead (backend.md §4), so
// this list half serves the code that is generic over `appendable`: read
// by the protocol of backend.md §4 — `length`, `Array.isArray`,
// `$plain()` — since a sibling cannot reach core/List.js, and a fresh
// plain array unless one side is empty, which returns the other itself.
export const append = (a, b) => {
  if (typeof a === "string") return a + b;
  if (b.length === 0) return a;
  if (a.length === 0) return b;
  return (Array.isArray(a) ? a : a.$plain()).concat(Array.isArray(b) ? b : b.$plain());
};

export const toFloat = (a) => a;
export const round = (a) => Math.round(a);
export const floor = (a) => Math.floor(a);
export const ceiling = (a) => Math.ceil(a);
export const truncate = (a) => Math.trunc(a);

// Subject first, then the modulus. The result takes the sign of the MODULUS
// (Basics.beni: `modBy (-1) 4 == 3`), which JavaScript's `%` does not do.
export const modBy = (n, k) => (k === 0 ? 0 : ((n % k) + k) % k);
export const remainderBy = (n, k) => (k === 0 ? 0 : n % k);

export const sqrt = (a) => Math.sqrt(a);
export const logBase = (a, base) => Math.log(a) / Math.log(base);
export const e = Math.E;
export const pi = Math.PI;
export const cos = (a) => Math.cos(a);
export const sin = (a) => Math.sin(a);
export const tan = (a) => Math.tan(a);
export const acos = (a) => Math.acos(a);
export const asin = (a) => Math.asin(a);
export const atan = (a) => Math.atan(a);
export const atan2 = (y, x) => Math.atan2(y, x);
export const isNaN = (a) => Number.isNaN(a);
export const isInfinite = (a) => a === Infinity || a === -Infinity;

// Structural equality, iterative so a long list cannot exhaust the stack.
// The checker has already proved both sides equatable (checker.md
// Appendix B), so there is no function to meet here and no case to refuse.
const structuralEq = (x, y) => {
  const work = [x, y];
  while (work.length !== 0) {
    const b = work.pop();
    const a = work.pop();
    if (a === b) continue;
    if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false;
    const keys = Object.keys(a);
    if (keys.length !== Object.keys(b).length) return false;
    for (const key of keys) {
      if (!Object.prototype.hasOwnProperty.call(b, key)) return false;
      work.push(a[key], b[key]);
    }
  }
  return true;
};

export const eq = (a, b) => structuralEq(a, b);
export const neq = (a, b) => !structuralEq(a, b);
