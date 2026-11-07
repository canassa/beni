## 2026-11-06 00:00 CET — srcdoc on iframe, only with a safe sandbox

**What I did** (#2016, branch `html-iframe-srcdoc`)

- Declared `pub attribute "srcdoc" on "iframe" : String` in `platforms/html/Html.beni`. `sandbox` stays a `String` (#1913).
- Asked the owner two questions on the dashboard. Cesar answered on 2026-11-05 at 22:39 UTC:
  - `html-iframe-srcdoc-q1`: option A. A typed `srcdoc` comes only with a constant `sandbox` without `allow-same-origin`.
  - `q2`: keep `String`.
- Wrote the spec first, as dated amendments: `language.md` §11.5, §11.16, §11.17 and §10; `checker-v2.md` §25.9; `boundary.md` §9.13. No section moved.
- Built the checker rule `srcdoc_without_sandbox` in `src/check/constrain/Markup.zig` (`Walker.srcdocSandbox`). There are three fault kinds and one code: no `sandbox`, a `sandbox` from a value, and a `sandbox` with `allow-same-origin`. The `untyped_srcdoc_attribute` message now names the typed attribute as the first fix.
- Added a `posted` step to the page driver. It logs the messages that `iframe[srcdoc]` frames post to the page. `browser/dom/IframeSrcdoc` uses it. In Chrome, only the `allow-scripts` frames post. In happy-dom, no frame posts, because happy-dom runs no frame script.
- Added fixtures: `check/bad/markup/SrcdocWithoutSandbox` (red on the old binary: exit 0, no diagnostic), `check/good/markup/SrcdocWithSandbox`, `run/MarkupSrcdoc` and `emit/dom/DomIframeSrcdoc`.

**What I learned**

- A markup item's constant is the text that the lowering writes. A quoted value has its character references decoded, and a hole's string literal keeps them. So a check on `constant_offset`/`constant_len` sees the same tokens that the browser sees. `sandbox="allow-same&#45;origin"` is refused, and `{"allow-same&#45;origin"}` is not, because the browser reads `&#45;` there as text.
- A quoted attribute name needs `=`: `<iframe "sandbox" />` is `expected_token`. A bare `sandbox` is only the typed form, and that form is already `bare_value` for a `String`. So the rule skips bare and number constants, and each mistake gives one message.
- The `language.md` §10 code list does not have `invalid_js_module`, `unknown_exports_mode` or `impure_polymorphic_value`, but `src/diagnostic.zig` has them. No test compares the two lists.
- happy-dom fires `load` only for frames that have a `srcdoc`. So a driver step that waits for frames must wait only for those frames.
