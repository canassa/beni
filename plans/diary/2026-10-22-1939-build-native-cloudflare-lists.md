## 2026-10-22 19:39 CEST — Build native Cloudflare lists

**What I did**

Replaced four host-array conversions that accumulated native lists through
opaque Js.Ref reads with List.initialize over the host array. Headers, socket
tags, socket enumeration and storage keys keep their order and empty results.
The ownership checker and Js.read contract are unchanged; the producers now
show their fresh native list construction directly. No List.copy was added.

Added header empty/order checks and verified them against the original
implementation first. HelloWorker, ObjectSocket and ObjectStorage pass their
worker transcripts in both builds, with refreshed run hashes. The Cloudflare
platform ownership dump has zero LIST demands, pending lines and rejections.
The locked self-hosted full gate passes. The final O1 audit will also include
the workers corpus added with this platform.

**What I learned**

An opaque JavaScript ref read cannot establish ownership of the value it
returns. Native construction preserves the producer's fresh-array fact
without changing that conservative boundary or asserting ownership by hand.
