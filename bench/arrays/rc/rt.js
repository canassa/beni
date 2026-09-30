// The run-time half of research/42's counted variants: what the hand-transformed beni code
// (rc/src/r1/*.mjs, and r2 derived from it) calls. `RC_MODE` is fixed at bundle time:
//
//   'r1'  full counts. `rc` is a count: 1 unique, >1 shared. dup is `rc++`, drop is `rc--`.
//         A value JavaScript may keep is pinned at 2^29, far out of reach of the drops (Koka's
//         sticky range, Perceus §2.7.2).
//   'r2'  a sticky shared bit. `rc` is 1 while the value has had one holder and 2 forever after
//         the first dup. There are no drops: rc/rc.mjs strips every line marked `// R1` from
//         the r1 source to make the r2 source, which is exactly Perceus minus drop.
//
// The counted kinds are beni arrays (plain JS arrays and the adaptive port's trie objects) and
// records whose type holds an Array field (research/42 §3, rule O5). Everything else is
// uncounted, and the compiler knows which at every monomorphic site. At a site whose type is a
// type variable it cannot know, and emits the `…A` forms, which test for the field.
const R1 = RC_MODE === 'r1';
export const PIN = R1 ? 1 << 29 : 2;

// dup of a value the compiler knows is counted: it gains a holder
export const $dup = R1 ? (x) => { x.rc++; return x; } : (x) => { x.rc = 2; return x; };
// drop of a counted value that loses its holder without being consumed (r1 only)
export const $drop = (x) => { x.rc--; };
// the same, for a value of a type variable: a number, a string, an uncounted record or cons cell
// fails the test and costs only the test
export const $dupA = R1
  ? (x) => { if (typeof x === 'object' && x !== null && x.rc !== undefined) x.rc++; return x; }
  : (x) => { if (typeof x === 'object' && x !== null && x.rc !== undefined) x.rc = 2; return x; };
export const $dropA = (x) => { if (typeof x === 'object' && x !== null && x.rc !== undefined) x.rc--; };
// a value JavaScript keeps (rule O7): shared forever
export const $pin = (x) => { if (typeof x === 'object' && x !== null && x.rc !== undefined) x.rc = PIN; return x; };
