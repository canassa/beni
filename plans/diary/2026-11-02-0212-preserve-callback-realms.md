## 2026-11-02 02:12 CET — Preserve callback realms

**What I did**

Closed the foreign-callback and Task.start realm holes from the native-realm review. Realm-only dependencies now survive ordinary summaries and interfaces without changing purity or suspension inference. Platforms without entryHost use an unknown realm. Added refusal fixtures, the nominal-versus-record callback case, and a generator regression for encode versus encodeInto. Documented the HostFree rollout and recorded its remaining black-box coverage on #1636.

**What I learned**

Entry runtime validation also reads summary dependencies, so it must distinguish realm dependencies from suspension dependencies. The two unsafe worker programs built before the fixes; the unknown-platform diagnostic previously claimed Node, and the member-span test selected encodeInto when the catalogue order was reversed.
