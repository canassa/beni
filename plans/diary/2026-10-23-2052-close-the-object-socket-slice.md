## 2026-10-23 20:52 UTC — close the object socket slice

**What I did.** The last item of #724's done-when, the attachment read back after a restart, is in `workers/ObjectHibernate` since the hibernation fixture, so this slice closes the issue: a third socket on the unheld room, accepted with the subprotocol `v1`, attaches its own id before the idle and after the wake answers `id kept, protocol v1`; `restore` sees both sockets; its close after the wake reaches `closed` with the tag. §9.12 (g)'s as-built note gets the dated *After hibernation* bullet and says the done-when is complete, and the skill's `websocket.md` says what a hibernation keeps and loses, and that a waiting fiber keeps the object in memory.

**What I learned.** The envelope the platform writes at `accept` is the whole per-socket state, and the host keeps it: nothing of a socket needs the object's memory. A fixture can compare a uuid without printing it, by attaching it and comparing after the wake.
