## 2026-10-23 10:21 CEST — close three gaps in the happy-dom box allow list

**What I did**

- Answered round 3 of the review of #817 with the reviewer's option 1.
  The allow list now reads the property names from the text of the
  `style` attribute, and marks an element when its text or a
  `setProperty` names a property outside the list. Ancestors must be an
  `html`, `body`, `main`, `div` or `span`. A negative `width` or
  `height` is refused. The README and the amendment say all three.
- Ran the reviewer's two round-3 probes (47 and 58 log lines) in both
  DOMs: each happy-dom box is Chrome's box or 0.

**What I learned**

- happy-dom's `element.style` is a proxy, and the `this` of
  `setProperty` is the declaration behind it. A method on
  `CSSStyleDeclaration.prototype` that returns `this` reaches the same
  object through the proxy.
- happy-dom keeps the `style` attribute as written until a write through
  `element.style`, which writes the text again without the names that
  it does not know. Every such write reads `element.style` first, so a
  wrapper of that getter sees the text before the write.
