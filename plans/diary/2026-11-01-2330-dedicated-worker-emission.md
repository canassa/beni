## 2026-11-01 23:30 CET — Dedicated worker emission

**What I did**

Added finite launch discovery, stable worker roots in the session entry plan,
independent emitter projections, relative descriptors and listener-first module
bootstrap. Added a test-only platform and Chrome round trip, initializer
isolation, cycle/determinism checks, atomic factory diagnostics and output
layout goldens. Public browser platforms expose no worker API.

**What I learned**

References to deferred Program definitions must also be descriptor edges in
value-cycle analysis; their manifest selectors belong in checker cache keys.
Bootstrap must retain messages during module loading, and the runtime must
install its listener synchronously before scheduling user initialization.
