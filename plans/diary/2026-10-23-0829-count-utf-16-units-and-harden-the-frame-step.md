## 2026-10-23 08:29 UTC — count UTF-16 units, and harden the frame step

**What I did**

- #858: `WebSocket.attach` and `Worker.Storage.put` counted `String.length`, code points, as two
  bytes each, where V8 writes two bytes per UTF-16 unit: an emoji counted 2 and cost 4, so 5 000
  emoji passed in beni and the host refused the attachment inside the handler, a defect. Both
  count the JavaScript string's `length` now; the fixtures hold `attach-emoji` and `/big-emoji`,
  which crashed the object before and are `Err TooLarge` after.
- #841: the driver's hand-made close frame uses a random mask key, refuses a payload over
  125 bytes and one that is not an even count of hex digits as a script error (exit 2, the step
  named), and says that it writes to the `ws` library's private `_socket`.

**What I learned**

- `String.length` is the one count in beni, and it is code points; every host limit on a
  serialized string is UTF-16 units. `Js.get (Js.from text) "length"` is the host's count.
