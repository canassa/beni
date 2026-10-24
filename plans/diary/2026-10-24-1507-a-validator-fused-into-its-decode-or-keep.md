## 2026-10-24 15:07 CEST — a validator fused into its decode-or-keep

**What I did.** #934 item 1, in the hand-minify pass's S2 form, which replaces the row-kind marker
of #930. A route's `replace` was `(a,b)=>{let c=u(),d=w(c,a);return d===c.a?b:d}` around its
worker. `Spec`'s *Slice 9 across a call* already writes a worker at a site that cases on what it
returns, so I widened that rule rather than add a new one (`backend.md` §9, amended). There are
four extensions: `x` may be read whole as what a `return` gives; an alias `const z = x` is held
to `x`'s rules; a stable chain may start at a call of a function that makes a fresh object
(`makesFreshAt`); and a parameter passed to a function that only inspects it is still only
inspected. The worker now ends in `return b`, the context goes, and the route row holds the fused
function. Unit tests pin the refusals of the two folds. `emit/release/app/ValidatorFused` and
`run/ValidatorFused` pin a fused and a kept site. Thirteen `emit/release` goldens are red with
the change taken out. S1 one file: N = 1 1 482 / 1 424 / 1 655 → 1 461 / 1 410 / 1 643, N = 16
−65 / −86 / −59. `./rr check` 24/24.

**What I learned.** The `case`-shaped `replace` reached the fuse only after slice 9 had folded its
`Result`, and what it leaves is `const new = x`: an alias, not a property read. Step B, fusing the
event decoder into the push's dispatcher, is still refused, because the dispatcher's rest makes a
closure, `a=>g[a[2]]`, and the rule copies no function. `inline/NestedStableLoad` grows by 10 B
after brotli while its raw bytes shrink by 96, which is the same compression-context effect the
section already records for `direct/ListScripts`.
