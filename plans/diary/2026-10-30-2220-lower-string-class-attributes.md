## 2026-10-30 22:20 CET — Lower String class attributes

**What I did**

Implemented existing scalar String class semantics on browser-inline for #1378.
Constants retain normal escaping; changing classes compare the native attribute
before writing, evaluating target and desired value once. The typed class-list,
raw/style and SVG namespace limits remain explicit. Native control state survives
class updates. Agent happy-dom, Chromium and prerender tests pass; the manager
also validated the integrated queue candidate's ordinary browser transcript.

**What I learned**

The classes vocabulary flag permits both scalar Strings and separate class lists;
rejecting the flag outright withheld valid constant and dynamic String programs.
Using a generic DOM property setter for class would conflate attribute writes
with textarea/select values. The existing String-class fixture now exercises
empty attributes, exact-once effects and retained textarea focus/value.
