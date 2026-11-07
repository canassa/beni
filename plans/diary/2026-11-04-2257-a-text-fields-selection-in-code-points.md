## 2026-11-04 22:57 CET — A text field's selection, in code points

**What I did**

#1900, a gap of #142: the beni editor must read the selection to indent the selected lines, and set it to select a diagnostic's span. `Html` gets `Selection` and `targetSelection : Event → Maybe Selection`, and `Dom` gets `select : String, Html.Selection → Result SelectError ⊤`. Both count code points, as `String` does, and convert to and from the host's UTF-16 units with the field's value. `boundary.md` §9.8.6 has the amendment, `skills/beni/` names both, and `tests/corpus/browser/tea/TextFieldSelection` pins them with "a😀bcd".

**What I learned**

- The browser driver's `select` step takes UTF-16 units, so a fixture with a character past U+FFFF shows the conversion: units 1 to 3 read back as code points 1 to 2.
- `setSelectionRange` throws `InvalidStateError` on an input of a type with no selection. Its `selectionStart` is `null`, so the wrapper tests it first and never reaches the throw.
- A new error type keeps existing code exhaustive. Two more constructors in `Dom.Error` would have broken every `case` over it, the corpus's `DomCapabilities` among them.
- Two pull requests that amend the same section conflict when both add text at its end. This one adds its text after the section's first paragraph, and #1910 adds at the end.
