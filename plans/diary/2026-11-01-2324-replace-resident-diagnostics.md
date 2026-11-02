## 2026-11-01 23:24 CET — Replace resident diagnostics

**What I did**

Cleared the borrowed diagnostic aggregate before freeing previous worker
messages at run start. Added an external public Session API driver and a
source-on-disk regression for warning, cached warning, error and repair.

**What I learned**

With only the lifetime fix stashed, the second run reports the warning twice;
subsequent runs retain stale messages too. The fixed diagnostic transcript has
one current document per run. No production CLI flag is needed for this API.
