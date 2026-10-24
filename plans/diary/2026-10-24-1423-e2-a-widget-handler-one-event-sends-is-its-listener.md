## 2026-10-24 14:23 CEST — E2: a widget handler one event sends is its listener

**What I did.** #936's E2 (`plans/s1-hand-minify-2026-10-24.md`). A root factory's moved key's
handler that exactly one event sends, with the fields that event gives, is now written inside that
event's listener (`platforms/browser-inline/zig/inline.zig`, `piece`): the listener reads the
payload through the extractor, binds it as the key's field, then runs the arm and its write pass.
A key two events send keeps one named handler. `browser-inline.md` §8.4 has the dated amendment.
New fixture `WidgetListeners` (emit/release and browser/inline): a payload read twice, a key two
inputs send, a click; the emit golden fails on master, the page transcript is the same before and
after. 17 release goldens moved, no development golden, no page transcript. `./rr check` on
unique-components and big-component, sizes 1/16/64/256, seeds 1–3, `--lists none`: all 24 ok.
One-file brotli of unique-components N = 16 seed 1: 6 266 → 6 224.

**What I learned.** The program site already wrote each listener with its arm (`let b=u(a);e.d=b`);
only the piece path called a named handler. The single-use form still prints `let c=s(a);b.a=c`:
folding a call into the next statement's assignment is E1's rule (`Opt.zig`, owned by #934), not
this item's, so E2 needs no rebinding of the parameter — `let d=J(a),e=U(d,46)` is as short as
`a=J(a);let e=U(a,46)`, and the `const` form is what E1 folds.
