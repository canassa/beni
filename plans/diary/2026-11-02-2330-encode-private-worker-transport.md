## Encode private worker transport and storage

**What I did**

Added one versioned compiler table shared by the browser-worker projections and
startup reporter. Private connection/ticket keys get prescribed short names;
control labels and phases become integers. The known embedded runtime is the
boundary: user payloads, constructors, native properties, Options and diagnostics
keep their representation. Worker.beni did not change. Added record/scalar,
public-tag and native-option boundary coverage across two entries, and replaced
an EventAck text assertion with direct acceptance/rejection behavior while
retaining the capability/counter shape checks.

**What I learned**

Prescribed private keys must be plain names, or an entry can rename them again.
The abandonment diagnostic also owns a kind field, so that spelling stays long.
On the pair, field keys alone saved 122 bytes brotli, numeric controls another 93,
single-letter keys another 83, and the remaining storage choices another 41.
The final pair saves 339 bytes (210 page, 129 worker); the ordinary page is
byte-identical. These are actual shipped artifacts, including worker core.
