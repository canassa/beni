## Cover the worker-hoisting review findings

**What I did**

Added a page without any worker whose Result-valued initialization must run even
when specialisation removes its state. A listener captures that state before
specialisation proves its callback ignores it. Moved the nested descriptor's
referring module to Deep/Child.beni so relocation changes its relative URL.
Refused worker hoists with entry exports, including flush/stop footer exports.
Corrected #1699's scope and the PR's ordinary-output claim.

**What I learned**

The case-subject defect also affects release builds without workers on the
workers branch. A trivial case can preserve the initialization through a
different path; the regression must exercise the temporary whose reads disappear.
The nested fixture also needs its directory structure copied into the test
project, using the existing sources manifest rather than a flattened module.
