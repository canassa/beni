// The sibling JavaScript of `Int32.beni` (docs/design/boundary.md §4): one
// export per `foreign` value, under the same name, and nothing else.
//
// Representation (backend.md §4): an `Int32` is an ordinary JavaScript
// number, held in signed 32-bit range by every operation that produces one.
// There is no box and no tag — the type exists in beni, not at run time —
// so `toInt` is the identity function and the cost of the whole module is
// the `| 0` that keeps the invariant true.
//
// `| 0` is ToInt32 (ECMA-262 7.1.6) spelled as an operator: it truncates
// towards zero, takes the low 32 bits, and reads the top one as the sign.
// It is also TOTAL — a NaN or an infinity is 0 — which is what lets
// `fromInt` promise an answer for every `Int` without a guard.
//
// §4.1's recipe: nothing here holds a foreign reference, everything is a
// number in and a number out, and no operation below can throw, so there is
// no `try`/`catch` to write. Division by zero is the one case JavaScript
// would answer with an infinity or a NaN, and each of the three guards it.

export const fromInt = (n) => n | 0;

// Both directions of the boundary. `toInt` is the identity because the
// representation already IS a number in range; `toUnsignedInt` reads the
// same 32 bits without the sign, which is the form hash and checksum
// vectors are published in. `>>> 0` is ToUint32 and its result is
// 0…4294967295, so it is an `Int` and deliberately not an `Int32`.
export const toInt = (x) => x;
export const toUnsignedInt = (x) => x >>> 0;

// The sum and difference of two int32s fit a double exactly (they need at
// most 33 bits), so `| 0` afterwards is the whole of the wrap.
export const add = (a, b) => (a + b) | 0;
export const sub = (a, b) => (a - b) | 0;

// The product does NOT fit: 0x7fffffff * 0x7fffffff is 4611686014132420609,
// past 2^53, so the double has already lost the low bits that the wrapped
// answer is made of and `(a * b) | 0` would be 0 where the answer is 1.
// `Math.imul` is specified as the 32-bit multiply and is the reason this
// module exists at all (fast-compiler.md §3.1).
export const mul = (a, b) => Math.imul(a, b);

// Truncated towards zero, and `zero` for a zero divisor rather than an
// infinity or a NaN, exactly as `Basics.idiv` is: `Int32` holds neither.
// `| 0` also settles the one true overflow of 32-bit division —
// minValue / -1 is 2147483648, which wraps back to minValue.
export const div = (a, b) => (b === 0 ? 0 : (a / b) | 0);

// The sign of the DIVIDEND, like `Basics.remainderBy` and like `%` itself.
// `| 0` is not decoration here: minValue % -1 is -0 in JavaScript, and -0
// is not a value an `Int32` may hold.
export const rem = (a, b) => (b === 0 ? 0 : (a % b) | 0);

// The sign of the DIVISOR, like `Basics.modBy`, which JavaScript's `%` does
// not do.
export const mod = (a, b) => (b === 0 ? 0 : (((a % b) + b) % b) | 0);

// The bit operators are already exactly ToInt32-in, ToInt32-out, so they
// need no truncation. `>>>` is the exception: its result is UNSIGNED, so a
// shift of 0 on a negative number would leave 4294967295 in a slot the type
// says holds -1. `| 0` brings it back, and makes a zero shift the identity.
export const and = (a, b) => a & b;
export const or = (a, b) => a | b;
export const xor = (a, b) => a ^ b;
export const shiftLeft = (x, count) => x << count;
export const shiftRight = (x, count) => x >> count;
export const shiftRightZero = (x, count) => (x >>> count) | 0;
