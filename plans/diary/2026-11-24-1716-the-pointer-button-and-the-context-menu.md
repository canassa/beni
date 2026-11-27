## 2026-11-24 17:16 CET — The pointer button and the context menu

**What I did.** Issue #2087: a page could not tell a right-click from a left-click, and could not
open a menu of its own. `Html` now has `button` and `buttons : Pointer → Int`, and the event
`onContextMenu`, `delegated via pointer : Pointer`. The contract is `boundary.md` §9.8.20 (h),
written before the code. The vocabulary is one module, so `browser`, `browser-tea` and
`browser-inline` have the API with no change to a lowering's listener code. One lowering change:
the capture script of a prerendered page does not record `contextmenu` (`prerender.md` §6.5),
because its extractor reads `currentTarget`. `pointerId` gives -1 when the event has no
`pointerId`. The test driver's `pointer` step has `button:<n>`, `buttons:<n>` and the name
`contextmenu`; its `mouse` step sends the `MouseEvent` form. Pages: `PointerButtons` under
`browser/tea`, `browser/dom` and `browser/inline`, and `EarlyMenu` and `EarlyMenuOnly` under
`browser/prerender`. The skill has a new topic file, `references/pointer.md`.

**What I learned.** The standard and the browser disagree, and only a measurement shows it. Pointer
Events level 3 gives a menu from the keyboard `pointerId` -1 and `pointerType` `""`. Headless
Chrome 153 gives it the mouse's `pointerId`, `"mouse"`, and a `button` of -1 at the centre of the
focused element. Chrome also gives each `contextmenu` `isPrimary` false, for the mouse too, which
is what the standard's "default values" rule says. The text of the standards that I read does not
say that `contextmenu` bubbles or can be cancelled; the Chrome measurement does. A `Pointer` made
from a `contextmenu` is a `MouseEvent` in a browser before Chrome 92, Firefox 129 and Safari 18.2,
so a reader that was true of every `Pointer` (`pointerId`) was not true of the new event: a new
event that reuses a payload type must check each reader of that type again. The prerender capture
script chose its events by the text `pointer` in the DOM name, so an event that reuses the
pointer extractor under another name was recorded; the filter is by name still, and the next such
event needs the same line. `markup.md` of the skill was at 299 of its 300 lines and `SKILL.md` at
7 990 of its 8 000 bytes, so each addition there is a move: pointer input went to its own file,
and two lines of `SKILL.md` became one.
