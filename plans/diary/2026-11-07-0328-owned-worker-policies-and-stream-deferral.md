## 2026-11-07 03:28 CET — Owned worker policies and stream deferral

**What I did.** Implemented owned Trusted Types policy names, policies, script
URLs and trust, and made Worker.open honour policy without invoking foreign
default callbacks. User allow callbacks run outside native guards. Added real
Chrome cases for named/owned-default success, foreign null/empty refusal and an
allow callback defect. Removed the unused Definition.stream/noStream/Sink
surface and its dummy fixture fields; updated generic constructor rows, docs,
skill and generated API. Response streaming and its saved prototype belong to
#2186; the existing Worker.events reader stays unchanged.

All 23 ordinary size rows are unchanged. Worker page: 7243→7401 B brotli;
download: 3649→3630 B. Full Chrome and Workers passed. Full gates passed in an
isolated namespace supplying the POSIX tools missing from Nix sh's default
/no-such-path, with UID 1000 and all capabilities dropped. Permission negatives
were checked first; no child-process fixtures or host filesystem were changed.
The final gate run executed 3699 uncached programs under Node. CI and review
are read after opening the PR.

**What I learned.** Public createScriptURL maps null to a branded empty string,
so it cannot preserve a foreign default policy's refusal. Owned policy identity
is the closed boundary. An unused required callback should be removed while its
ownership prerequisite is deferred, rather than published as working. The
fixture migration changed only diagnostic positions and audited worker
fingerprints/inert callback output; it needed no checker exemption or cap move.
