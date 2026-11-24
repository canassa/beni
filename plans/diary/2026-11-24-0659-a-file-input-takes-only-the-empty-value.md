## 2026-11-24 06:59 CET — A file input takes only the empty value

**What I did.** Fixed #2020: `<input type="file" value={n} />` with a `n` that is not empty threw
`InvalidStateError` in a render, on `browser` and `browser-inline`. A script can give a file
input one `value` only, the empty string. `writeProp` in `platforms/browser/Rt.beni` and in
`platforms/browser-inline/Inline.beni` now does not write a `value` that is not empty to an
element whose live `type` is `file` (`refused`). It writes `""` as before, which removes the
chosen files. Such a value is a model no page can show (`backend.md` §15.3, amended;
`browser-inline.md` §8.3, amended). Pages: `browser/dom/FileInputValue` (a `type` in the
markup, a `type` from the model before and after the value, a second value, the empty value, a
change to `text` and back), `browser/dom/FileInputLiteral` (both written in the markup) and
`browser/inline/FileInputValue`. All three fail on the unchanged runtime and pass with the
fix, in happy-dom and in Chrome, with transcripts written before the fix. 22 goldens of
`emit/release/inline` embed the write step and change by the guard alone. A release page with
a controlled input grows by 27 B raw and by 16 to 23 B brotli. A page with no control does not
change. I asked the owner one question: whether a compile-time warning for a literal
`value` on a literal `type="file"` is also wanted. I recommended the guard alone.

**What I learned.** Each write of a control's property on `browser` goes through one step,
`writeProp`: the mount, the patch and the reconcile. So one test there covers the three, and a
`type` that comes from the model too. A static check cannot make this failure impossible,
because the `type` can be a value of the model. `browser-inline` does not write a control's
value again after a write of its `type`, and `browser` does (the write marks the control):
that is #2667, which I opened. `skills/beni/references/markup.md` has 299 lines and its limit
is under 300, so a new sentence there must go on a line that exists.
