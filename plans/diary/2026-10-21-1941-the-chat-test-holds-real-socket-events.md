## 2026-10-21 19:41 CEST — The chat test holds real socket events, and its drivers always end

**What I did**

- Fixed the ten findings of ws-review's review of #598 (R1–R10), each in a new commit.
  - R1: the page driver's real socket now holds what the host's socket does, in order, and gives
    it to the page only in a `socket <n> wait` step. Before, the load snapshot showed
    `"connected"` when the server's 101 arrived before the step settled. The new option
    `--wait-handshakes` makes that order certain: after each step, the driver waits until the
    host has answered every handshake, and lets the page settle again before the snapshot. The
    chat test runs with it, so a driver without the hold fails the test every time, not by chance.
  - R2, R6, R9: the serve driver stops a `page-wait` when it gives up or when the page ends,
    stops a page that does not end in 20 s, waits for a page the script left running, and says
    so in a line when a script waits for a page that is not there. A wait uses the lines up to
    the one it found. A second script in the chat test pins all three.
  - R3, R4: the page now keeps a count of the failures in a row in `Connecting Int`, so its wait
    grows by one second after each failure, 30 s at most. The test keeps the page across the
    shutdown and steps its virtual clock, so it proves the reconnect and the growth.
  - R5: `skills/beni/references/websocket.md`, with a checked server block and a checked page
    block. R7: the test asks for `/` and `/.env`. R8, R10: two comments.
- Found on the way: the serve driver kept running 5 s after every script, because the timer of
  its race with the program's exit was never cleared. A chat run went from 5.6 s to 0.65 s.

**What I learned**

- When a caller closes file descriptor 3, Node's event loop takes that number for its epoll
  descriptor. `fstatSync(3)` then succeeds, and a write fails with `EINVAL`. To know if the
  caller opened it, check that it is a pipe, a socket, a file or a terminal.
- A test that pins a race must make the bad order certain, not likely. A real wait of 20 ms gives
  the server's answer time to arrive on a quiet host. A wait for the answer itself works on any
  host.
- A Node script that ends without `process.exit` ends only when its event loop is empty. A
  `Promise.race` with a timer leaves the timer pending after the other side wins.
