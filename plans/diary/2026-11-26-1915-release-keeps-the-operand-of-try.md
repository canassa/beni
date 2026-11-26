## 2026-11-26 19:15 CET — Release keeps the operand of `?`

**What I did.** Issue #2699: `--release` dropped an impure call that was the operand of `?`, so
a program printed `1,2` where the development build printed `27,2`. `Lower.tryExpr` binds the
operand to a `const $t` and did not list it in `effect_keep`. Specialisation knows from the
callee's return fact which constructor the call gives, so it folds the failure test, nothing reads
`$t`, and `Opt` drops the unread binding with the call and its `Ref.modify` or `Log.info`.
`Lower` has a new helper, `bindSubjectOf`, that keeps the binding when the checker says its source
may be impure or suspend. `?`, the two case-subject paths and the `let` pattern use it now; the
case paths and the `let` path had the same check written out by hand. The same hole was in two
more places, and they are fixed too: the operand temporaries of a `==` against a constructor
(`ctorEquality`), and the arguments of a message constructor in a markup event handler, in four
functions (`innerMessage`, `composeMaps`, `directMessageInto`, `ctorLayers`). The reviewer found the
second one: an `update` arm that ignores the field let the release page drop the call. Fixtures:
`run/ReleaseKeepsTryEffect` (`?` on `Maybe` and `Result`, `Ref.modify`, `Ref.set`, `Ref.update`
and `Log.info`, one call and two calls, the payload read and not read, and the `==` case) and
`browser/inline/ReleaseKeepsMessageArgEffect`. Both fail on master in their release run.

**What I learned.** The guarantee "release keeps an unread binding that may have an effect"
depends on one list, `effect_keep`, and every `const` that `Lower` writes must be put on it when it
holds an effect. A binding that something reads at the time `Lower` writes it is not safe because
of that read: specialisation can remove the read later. The gap shows only where a callee is
called from two or more places. With one call, the callee is written into its caller and its own
statements stay. A new `run/` fixture that uses a `Ref` of any type needs lines in
`tests/blackbox/ownership-v2-known.txt`, because v2 makes a demand at each cell operation and v1
makes none.
