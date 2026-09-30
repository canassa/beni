base (src/runtime.js through Minify.zig): raw 2262, gz 1106, br 978

| source edit, alone | Δ raw | Δ gz | Δ br |
|---|--:|--:|--:|
| `parent` locals (a host global, never renamed) named `into` | -17 | 0 | +1 |
| `cx` locals (a shorthand key, never renamed) named `context` | 0 | +4 | +9 |
| `const document = globalThis.document` locals named `doc` | -39 | -2 | +4 |
| `document` read bare, no `globalThis.` and no local | n/a (build failed) | | |
| `x !== null ? x : y` → `x ?? y` in first, last, parentOf | -30 | -7 | -6 |
| `s.u !== null && s.u.length !== 0` → `s.u?.length` in head, tail | -30 | -7 | +2 |
| `patch`'s `const n` named `fresh`, so the kept units assign no `const` name | +3 | +2 | +8 |
| `childHtml` puts its first instance itself (`place`'s other arm is dead there) | -43 | -17 | -17 |
| `mount`'s first render is `render()` | -11 | +1 | 0 |
| `mount`, called once, written in `run`'s loop | -14 | -6 | +1 |
| `head` and `tail` written as one conditional expression each | -44 | -11 | -8 |
| `root.$$root !== undefined` → `root.$$root` | -12 | -8 | -3 |
