## 2026-10-24 13:57 CEST — a validator's Value field is a presence test

**What I did.** #934 item 2. A validator worker's required `Value` field was written as the
general field read: a slot, `if (x !== undefined) slot = x; else slot = c.fail`, then
`if (slot === c.fail) return c.fail`. It now takes the primitive fields' one-condition form,
with the presence test as its test: `let d=b.w1;if(d===undefined)return a.a;`. After the manager's
hand-minify pass (its S1), a field whose own read fails for `undefined` — a record, a list, a
tagged union, a tuple, a declaration of the same module — has no presence test at all. Spec first:
`schema.md` §6, *One failure, so fewer tests*, amended. Nine `emit/release` goldens moved
(red with the fix stashed); `run/SchemaValidatorValueField` pins what such a field accepts
(`null`, `false`, `""`, objects; a record, a list) and refuses (an absent key), the same in both builds and before
the change. S1 seed 1, one file: N = 1 1 522 → 1 482, N = 16 6 266 → 6 107; N = 64 and 256 are on
the shapes side and do not move. `./rr check` 24/24.

I also dropped #934 item 1 (#930) after measuring it: a row that holds the validator worker makes
the worker escape, so `Spec` gives every parameter ⊤ (`backend.md` §9, fact 1) and the context
object escapes too. The worker keeps its depth, unknown-key and `c.all` code: N = 1 grows by
70 B at best and 113 B with the context object, against the 45-raw-byte wrapper it removes.

**What I learned.** The release worker is small only because every call of it is direct: its
`c`, depth and path parameters are constants of its callers, and Spec folds them. Anything that
stores a worker as data loses that. Removing the wrapper therefore needs `Spec` to follow function
values through data first; it is not a change to the loader.
