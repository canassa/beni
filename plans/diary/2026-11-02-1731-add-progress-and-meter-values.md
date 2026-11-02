## 2026-11-02 17:31 CET — Add progress and meter values

**What I did**

Added progress and meter to the HTML platform's string-valued value attribute
row. Output was already present. The compiler needed no change. Updated the
markup skill and regenerated the HTML API reference.

Added a TEA fixture that renders all three values at 30 and updates them to 50.
It passed in happy-dom and Chrome in development and release. With the vocabulary
fix stashed, both build modes reported unknown_attribute for progress and meter.

**What I learned**

The HTML vocabulary separates ordinary string attributes from stateful value
properties on input, select and textarea. Progress and meter belong to the
ordinary attribute row; this change does not need input-control machinery.
