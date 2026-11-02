# Keep prepared worker payloads typed

Prepared is an opaque generic beni carrier with a typed payload and live bit.
Discarding changes only that bit. The private page-stop bridge also keeps its
unit stop job and integer completion job typed, including their effect bits.

The callback-payload run fixture passes in development and release without
invoking its payload. The managed-worker corpus passes in Chromium. Chromium
uses a short symlink to this worktree's disk scratch directory because the
full path exceeds the Unix socket path limit.
