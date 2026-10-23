## 2026-10-23 08:17 UTC — measure hibernation and the disconnect at the edge

**What I did**

- Measured #593 and #600 at the edge with a plain-JavaScript probe Worker deployed to the owner's
  account and deleted after each session (five sessions; `wrangler dev --remote` refuses Durable
  Objects, and a fresh deployment answers a placeholder page on its object paths for its first
  seconds). Recorded in §9.12 (e.5), (d) and (k) as *measured*.
- #593: an idle object with a hibernatable socket is a new instance after 15 s with its attachment
  intact; with the platform's hold timer armed it is the same instance; after the release it
  hibernates.
- #600: with `enable_request_signal` a client's disconnect fires `request.signal`, work held in
  `waitUntil` lands after the client is gone, the handler's own continuation is dropped; a hold of
  26 s after the response lands and one of 35 s does not, so the 25 s deadline is inside the cap.

**What I learned**

- Local workerd never hibernates an idle object and never fires `request.signal`, so these facts
  cannot be fixtures; a deploy of a probe, deleted after, is the way, and the deploy needs a wait
  for the name to serve.
- `wrangler delete` says success before the name stops answering: verify by a later 404.
