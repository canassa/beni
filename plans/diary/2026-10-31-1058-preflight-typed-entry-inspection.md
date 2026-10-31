## 2026-10-31 10:58 CET — preflight typed entry inspection

**What I did**

Specified and implemented the entries consumer availability boundary before its
compact output. A checked selected generic Plan now preflights retained typed
roots before discovery; unavailable evidence becomes the existing internal
compiler diagnostic at the actual entry declaration. The direct entries writer
also validates before its first byte. Validated legacy Plans with no selected
kind keep their ordinary partial inspection output.

The direct writer regression failed before the fix because a compact prefix had
already escaped, then passed afterward. The focused hermetic run executed both
new boundary tests successfully (11 total including nine harness infrastructure
tests), including the complete diagnostic object and legacy output. The actual
typed CLI matrix now passes 14/14, including the legacy check/dump comparison.
No source or emission rerun, product test flag, handwritten JavaScript, or proof
exception was introduced. Parent owns full integration gates and cost validation.

**What I learned**

The retained type writer's own preflight was too late to protect the surrounding
compact writer. Availability must be checked at the first output boundary as well
as the typed serializer. Diagnostic message/list growth retains the existing
owned messages until successful transfer, with failure cleanup for both old and
new allocations. Legacy selected=none is a valid contract state and must skip
this typed requirement.
