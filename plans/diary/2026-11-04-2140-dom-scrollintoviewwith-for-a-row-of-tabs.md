## 2026-11-04 21:40 CET — Dom.scrollIntoViewWith, for a row of tabs

**What I did**

#1896, a gap of #142: `Dom.scrollIntoView` gives the host no options, so a tab that it scrolls into a row of tabs also moves the whole page. `Dom` gets `scrollIntoViewWith : String, Alignment → Result Error ⊤`, with `Align = Start | Center | End | Nearest` for `block` and `inline`, as CSSOM View's `ScrollIntoViewOptions` has them. `boundary.md` §9.8.6 has the amendment, `skills/beni/` the new function, and `tests/corpus/browser/tea/DomScrollIntoViewWith` the fixture.

**What I learned**

- happy-dom lays nothing out, so a fixture about where a node scrolls pins only the calls there. Chrome shows the behaviour, so the fixture has a `.chrome-expected`. `test-browser` compares it instead of `.expected`.
- Logging what moved, not pixel numbers, keeps the Chrome golden free of rounding and of the window size.
- The fixture fails in Chrome when the wrapper drops the options: `nearest: page moved: True`.
