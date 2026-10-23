## 2026-10-24 01:02 CEST — the end tags a popping end tag supplies

**What I did.** One item of #916: the closing tags before `</section>` that the HTML parser
supplies. The end tag of a `section`, a `div` and the rest of §13.2.6.4.7's list pops every
element open above it, so `serialise` leaves out the end tags of its last child's open chain when
each element is one a pop closes exactly (not a formatting element, a `form`, a table part, or
an element of the parent's name). `<section><header><aside><p>x</section>`. New page and golden:
`PoppedEndTags` (the omitted chain, and each case that keeps its end tag); the page's
transcript did not change, which parse5 checks. Spec: `browser-inline.md` §8.2, amended.
S1 seed 1 (one-file brotli, my build): N = 1 −11 B; −1.9 B/widget from 16 to 64; −0.5 from 64 to
256. The release goldens it moved fell by 73 B in total over 28.

**What I learned.** A pop is exact only for elements with no parser state: a formatting element
is opened again by the list of active formatting elements after the pop, and a `form`'s end tag
also clears the form element pointer. An element of the parent's own name in the chain makes the
parent's end tag match it first, so the chain check must look at every element it leaves open.
