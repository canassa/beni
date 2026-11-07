## 2026-11-04 06:51 UTC — The wake keeps a waiting object in memory

**What I did**

- I ran the third probe session for #864 at the edge, with Jayson's go. The Worker was `beni-probe-864c`, plain JavaScript on the account's `workers.dev`. It was deployed at 06:29 UTC and deleted at 06:39 UTC, and after the delete the URL answered 404, error 1042.
  - With the platform's hold (one pending `setTimeout`) plus a storage alarm that `alarm()` arms again 60 s ahead, two objects were the same instance after 3 and after 10 minutes.
  - Each of the two objects ran its 9 alarms in that one instance.
  - With the timer alone, the object was new after 3 minutes.
- I recorded the second and third probe sessions in §9.12 (e.5). I also specified the wake, which is q15's option A.
  - While a fiber lives, the platform keeps the object's one host alarm at most 60 s ahead.
  - The program's alarm time is in the platform's own SQLite table, `beni_alarm`.
  - The program's `alarm` handler runs only at the program's own time.
- I built the wake in `platforms/cloudflare/Worker/Object.beni`, with two new test hooks: `/__beni/host-alarm` and `/__beni/alarms`.
- I added the fixture `workers/ObjectWake`. It ends with a hibernation, after which a new instance finds the program's time in the table.
- I updated the skill's hibernation sentence (`websocket.md`) and added a line on the alarm (`platforms.md`).

**What I learned**

- The second probe session left out the pair that the design needs (the timer and the alarm together), so it answered a different question. Before I deploy a probe, I compare its classes with the design it must test.
- If the platform clears the program's time before the `alarm` handler runs, a defect in the handler loses the alarm. The host retries the alarm, but the time is already gone. So the platform clears the time only after the handler returns, and while the handler is pending, the platform does not set the host alarm to that due time (`firing`).
- Under the pinned Miniflare, a table that `ctx.storage.sql` makes stands beside `_cf_KV`, and `ctx.storage.kv.list()` does not list it. Thus the platform can keep a durable value of its own that `Worker.Storage` never sees.
- The answer to q15 asked for a read after 16 minutes, and the probe read after 10. A read past the 15-minute mark is still owed. The wake arms a new hold timer each minute, so no single timer gets near 15 minutes.
