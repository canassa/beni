## 2026-11-05 10:58 CET — `dx`/`dy` on `feOffset`, and the `feDropShadow` element

**What I did**

- Issue #1074. `Html.beni` declared `<feOffset>`, but `dx` and `dy` only on
  `text` and `tspan`. A drop shadow needed the quoted escape `"dy"="3"`,
  which the build never checks. `<feDropShadow>` was not declared.
- `boundary.md` §9.9 (g) has an amendment with the facts and the Filter
  Effects 1 sections (§9.2, §9.12, §9.13.1–§9.13.2, §9.14, §9.18).
- `Html.beni`: `feDropShadow` is an element `svg`. It is in the `on` lists of
  `x`, `y`, `width`, `height`, `result`, `in` and `stdDeviation`. `dx` and `dy`
  are on `feOffset` and `feDropShadow`. Every value is a `String`, the type of
  the declaration that each name joins. `flood-color` and `flood-opacity` are
  presentation attributes of every element, so they needed no change.
- `tests/corpus/run/MarkupSvgFilter.beni` renders both shadow forms through
  `ssr`. On master it fails with `unknown_attribute` (`dx`, `dy`) and
  `unknown_element` (`feDropShadow`).
- `BallMachine/View.beni` writes `dy=` where it wrote `"dy"=`. The page
  transcript did not change. `api-html.md` is generated again.

**What I learned**

- The vocabulary is data: no change to `src/`, to a lowering or to a runtime.
  happy-dom and the HTML parser already restore the case of `feDropShadow`.
- The specification types (`<number-optional-number>` for `stdDeviation`,
  `<alpha-value>` for `flood-opacity`) take forms that a `Float` would refuse
  (`"1.5 3"`, `"50%"`). §9.9 (b)'s "every SVG attribute is a `String`" is the
  right rule here, not only the easy one.
- Master moved 255 commits during the checks. On the new master the
  ownership checker v2 checks markup, so the fixture has no `.v2.unchecked`.
  Bless again after each rebase.
