## 2026-11-02 01:17 CET — Check native availability per worker entry

**What I did**

Added a first callable native subset from the pinned catalogue: DOM selection and text, Element upcasts, TextEncoder, timers and worker self. Typed effect dependencies now carry realm masks through imports, callbacks, records, evidence and recursive calls. Each emitted entry checks its own projection and explains a refusal with the native identity, allowed realms and shortest chain. EntryHost replaces the obsolete platform-wide host promise.

Migrated the worker test platform's touched DOM access and the browser's UTF-8 helpers. Added diagnostic fixtures and a Chrome page that uses the DOM while its worker encodes text. Built HostFree behind a default-off internal option, including immutable representation facts for opaque and recursive types and published generic obligations. Remaining migration is tracked in #1636; Task is untouched.

**What I learned**

An opaque Program must retain a shared pure callback effect class: dropping it loses realm dependencies even though ordinary effects remain pure (#1638). The before-fix build accepted a DOM worker and the fixed build rejects it. Native unit operands must still evaluate their effects. Native lowering also needs its temporary state outside the recursive ordinary-call frame so the existing widest operator-chain programs keep building.

Ordinary Node and browser development/release output trees match origin/workers byte for byte. Performance and size work remain deferred under the delivery directive.

The first full run-hash pass found eight existing inline/prerender programs refused after retaining the pure callback relationship. A fresh master fetch showed that PR #1634 had already fixed this publication defect and specialized inline command checking with its real synchronous sender, including captured-callback hardening. At the manager's request I merged master into workers as 48ba8c448c, resolved the resident-session and run-hash conflicts, passed the locked gates and pushed workers. The realm work is rebased onto that merge, retaining upstream's publication implementation and the new realm masks.
