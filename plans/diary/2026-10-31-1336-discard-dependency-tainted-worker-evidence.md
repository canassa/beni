## 2026-10-31 13:36 CET — discard dependency-tainted worker evidence

**What I did**

Extended the nominal-layout review's dependency-error probe to the accepted
selected Program and symbolic continuation evidence. Accepted7eca adds a Main
internal MissingEvidence or BadScope beside Library's ordinary unknown-type error
when a selected generic Program or an unused suspending function contains that
erroneous imported type. Tracked as #1474. The permanent selected-root regression
fails before the correction (expected one diagnostic, found two).

Specified the shared clean-dependency boundary before code. Declaration heads,
continuations and typed roots now require clean transitive dependencies. Prior
worker evidence is cleared before fallible setup and on escaping allocation
failure; dependency/own errors retain absent evidence. No inference, diagnostic
or cache-key policy is broadened. The same source regression passes for both
selected roots and symbolic continuations through repeated cached checks,
development/release refusal with no output, and restoration of the original
inspection graph with zero-source-check warm reuse.

**What I learned**

A locally clean report does not mean dependency-tainted terms are valid input to
a clean metadata verifier. Error nodes can remain without a local diagnostic by
design. That path needs absent evidence, not an internal error or a usable empty
proof. The unaccepted nominal-layout correction and this accepted-foundation
correction share the boundary but retain separate review/validation provenance.
Full exact-tree gates are required before this correction is pushed.
