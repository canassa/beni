# 2026-10-16 — Use idle CPU slots for independent byte accounts

The owner asked whether the sweep uses all cores. Three queues share six CPU
slots on azathoth's six-core/twelve-thread host, with 26,000 MiB of estimated
memory reservations. Large minifier trees leave CPU capacity idle. Independent
brotli/gzip accounts can now borrow one extra CPU slot and 1 GiB and compress
two strings concurrently while their parent waits. Admission is nonblocking;
when no slot is available, the original serial account runs. Existing source,
minifier and compression options do not change.

Re-accounting the actual mixed N3,888 TEA bundle preserved all seven complete
account fields, including 9,344,577 raw, 579,185 brotli and 1,179,325 gzip
rendering bytes. A full-pool check returned immediately without starting its
child. New remote jobs were observed using two compression threads. This is
measurement throughput work, not application speed benchmarking.

This checkpoint retains 2,260 sizes, including 838 stress measurements, thirteen
actual crossings and thirteen compiler-limited curves. Audits checked every
one of those 838 normalized artifacts and their original native outputs. The
modal TEA build reached the 16 GiB cap at N4,112; its other curves continued.
Family slopes now use common windows through N1,728, except direct and Solid's
explicitly labeled windows. The full family sweep is still in progress.

No repository gates or suites and no new application timing measurements ran.
