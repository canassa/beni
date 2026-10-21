// The sibling JavaScript of `node`'s `WebSocket.beni` (docs/design/boundary.md
// §4, §9.11): one export per `foreign` value, under the same name, and
// nothing else. It reads and writes RFC 6455 frames on a socket that
// `Http/Server.js` upgraded, with `node:crypto` for the handshake and no
// package.
//
// A socket is `{ raw, state, queue, queued, readers, end, drainers,
// sizes, chunks, bytes, frame, parts, partBytes, max, protocol, timer,
// paused, done, path }`: the `net.Socket`; `open`, `closing` (this side sent
// a close frame) or `closed`; the text messages no one has read and their
// bytes; the fibers waiting in `read`; why the connection ended, once it
// has; the fibers waiting in `drain`; the bytes received and not yet
// parsed; the frame whose header is read; the fragments of a message and
// their bytes; the largest message accepted; the subprotocol; the timer
// that destroys a connection that does not close; whether reading is
// paused; whether the session has returned; and the request's path, for
// the lines on standard error.
//
// Every failure Node documents for a socket is caught by its code, and
// nothing else is caught (CLAUDE.md rule 9): anything else is thrown
// again, and Node reports it and exits 1.

import { Buffer, isUtf8 } from "node:buffer";
import crypto from "node:crypto";
import os from "node:os";
import process from "node:process";

// RFC 6455 §1.3: the GUID the accept key is hashed with.
const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
// §9.11 (h): reading stops while the unread messages hold more than this.
const highWater = 64 * 1024;
// §9.11 (f): how long this side waits for the peer's close frame.
const closingTime = 5000;
// The codes of `error` on a socket that mean one client's connection is
// gone (§9.11, amendment item 15): a reset, a write to a closed peer, a
// timeout, the errors of ICMP messages that Linux keeps until the
// retransmissions give up (`icmp_err_convert`, `icmpv6_err_convert`; errno
// 95 is libuv's `ENOTSUP`), an aborted connection, and an interface that
// went down; `isGone` adds a network reset.
const gone = new Set([
  "ECONNRESET",
  "EPIPE",
  "ETIMEDOUT",
  "ENETUNREACH",
  "EHOSTUNREACH",
  "EHOSTDOWN",
  "ENONET",
  "ENOPROTOOPT",
  "ECONNREFUSED",
  "ENOTSUP",
  "EPROTO",
  "EACCES",
  "ECONNABORTED",
  "ENETDOWN",
]);

// One client's connection is gone: an `error` whose `code` is in `gone`,
// or whose number is `ENETRESET` (macOS and the BSDs), which libuv does not
// name, so its `code` is not `ENETRESET` (§9.11, amendment item 15).
const isGone = (error) => error instanceof Error && (gone.has(error.code) || error.errno === -os.constants.errno.ENETRESET);

const OPEN = 0;
const CLOSING = 1;
const CLOSED = 2;

// A close code RFC 6455 §7.4 and the IANA registry allow on the wire.
const wireCode = (code) => (code >= 1000 && code <= 1014 && code !== 1004 && code !== 1005 && code !== 1006) || (code >= 3000 && code <= 4999);

// One frame, unmasked, as a server sends it: `fin`, the opcode, and the
// payload. The header is 2, 4 or 10 bytes.
const frame = (opcode, payload) => {
  const n = payload.length;
  const head = n < 126 ? 2 : n < 65536 ? 4 : 10;
  const out = Buffer.allocUnsafe(head + n);
  out[0] = 0x80 | opcode;
  if (n < 126) out[1] = n;
  else if (n < 65536) {
    out[1] = 126;
    out.writeUInt16BE(n, 2);
  } else {
    out[1] = 127;
    out.writeUInt32BE(Math.floor(n / 0x100000000), 2);
    out.writeUInt32BE(n >>> 0, 6);
  }
  payload.copy(out, head);
  return out;
};

// A text frame, encoded straight into the frame's buffer: one allocation
// and one write per message.
const textFrame = (text) => {
  const n = Buffer.byteLength(text, "utf8");
  const head = n < 126 ? 2 : n < 65536 ? 4 : 10;
  const out = Buffer.allocUnsafe(head + n);
  out[0] = 0x81;
  if (n < 126) out[1] = n;
  else if (n < 65536) {
    out[1] = 126;
    out.writeUInt16BE(n, 2);
  } else {
    out[1] = 127;
    out.writeUInt32BE(Math.floor(n / 0x100000000), 2);
    out.writeUInt32BE(n >>> 0, 6);
  }
  out.write(text, head, "utf8");
  return out;
};

// The last text `send` framed, and its frame: a state sent to every player
// is encoded once (§9.11, amendment item 27). A frame is never changed
// once made, so one buffer can be written to many sockets.
let lastText = null;
let lastFrame = null;

// Write `frame` and count it, so `drain` can wait for the callback of the
// last write (amendment item 14). A callback's error — `ECANCELED` for a
// write pending at `destroy()`, `ERR_STREAM_DESTROYED` — ends nothing
// here: the socket's `close` ends the connection, and any other failure
// is the socket's `error`, handled where it is emitted.
const put = (ws, frame) => {
  const n = ++ws.writes;
  ws.raw.write(frame, () => {
    ws.flushed = n;
    drained(ws);
  });
};

const closeFrame = (code, reason) => {
  if (code === 1005) return frame(0x8, Buffer.alloc(0));
  const text = Buffer.from(reason, "utf8");
  const payload = Buffer.allocUnsafe(2 + text.length);
  payload.writeUInt16BE(code, 0);
  text.copy(payload, 2);
  return frame(0x8, payload);
};

// The first `n` bytes received, taken out of the list of chunks.
const take = (ws, n) => {
  ws.bytes -= n;
  const first = ws.chunks[0];
  if (first.length === n) return ws.chunks.shift();
  if (first.length > n) {
    ws.chunks[0] = first.subarray(n);
    return first.subarray(0, n);
  }
  const out = Buffer.allocUnsafe(n);
  let at = 0;
  while (at < n) {
    const chunk = ws.chunks[0];
    const k = Math.min(chunk.length, n - at);
    chunk.copy(out, at, 0, k);
    at += k;
    if (k === chunk.length) ws.chunks.shift();
    else ws.chunks[0] = chunk.subarray(k);
  }
  return out;
};

// The byte at `i` of what is received, not taken.
const byteAt = (ws, i) => {
  for (const chunk of ws.chunks) {
    if (i < chunk.length) return chunk[i];
    i -= chunk.length;
  }
  return -1;
};

// Answer the oldest reader with `value`, or keep it.
const deliver = (ws, text, size) => {
  if (ws.readers.length !== 0) {
    ws.readers.shift()({ $: "Ok", a: text });
    return;
  }
  ws.queue.push(text);
  ws.sizes.push(size);
  ws.queued += size;
  if (!ws.paused && ws.queued > highWater) {
    ws.paused = true;
    ws.raw.pause();
  }
};

// The connection ended: why is kept, and every fiber that waits in `read`
// or `drain` is answered.
const ended = (ws, code, reason) => {
  if (ws.end !== null) return;
  ws.end = { code, reason };
  ws.state = CLOSED;
  const readers = ws.readers;
  ws.readers = [];
  for (const resume of readers) resume({ $: "Err", a: ws.end });
  drained(ws);
};

// Answer each fiber in `drain` whose last write is flushed, or every one
// once the connection has ended.
const drained = (ws) => {
  if (ws.drainers.length === 0) return;
  const waiting = [];
  for (const d of ws.drainers) {
    if (ws.end !== null || ws.flushed >= d.target) d.resume(null);
    else waiting.push(d);
  }
  ws.drainers = waiting;
};

// The TCP connection is destroyed when it has not closed within
// `closingTime`: a peer that never answers a close frame, or never reads
// the last bytes, cannot keep it, or the process, alive. The socket's
// `close` clears the timer.
const deadline = (ws) => {
  if (ws.timer !== null) return;
  ws.timer = setTimeout(() => {
    ws.timer = null;
    ws.raw.destroy();
  }, closingTime);
  ws.timer.unref();
};

// Once a close frame is sent or received, reading goes on, so the peer's
// close frame, FIN or RST is seen; data frames are dropped from then on
// (amendment item 18).
const reading = (ws) => {
  if (!ws.paused) return;
  ws.paused = false;
  ws.raw.resume();
};

// This side starts the closing handshake: the close frame, then a wait
// for the peer's.
const sendClose = (ws, code, reason) => {
  if (ws.state !== OPEN) return;
  ws.state = CLOSING;
  put(ws, closeFrame(code, reason));
  reading(ws);
  deadline(ws);
};

// Fail the connection (RFC 6455 §7.1.7) for a fault of the peer: the close
// frame with `code`, then the end of the TCP connection, with nothing more
// read. `read` reports `code` (§9.11 (a), rule 3).
const fail = (ws, code, why) => {
  process.stderr.write(`beni: WebSocket: the connection to ${ws.path} failed with ${code}: ${why}\n`);
  if (ws.state === OPEN) put(ws, closeFrame(code, ""));
  ws.state = CLOSED;
  ws.chunks = [];
  ws.bytes = 0;
  ws.raw.destroySoon();
  deadline(ws);
  ended(ws, code, "");
};

// Answer a ping. While more than `highWater` bytes wait to be sent, only
// the latest ping is answered, when the socket drains (RFC 6455 §5.5.3;
// amendment item 25): a client that pings and never reads cannot grow
// the server's buffer.
const pong = (ws, payload) => {
  if (ws.state !== OPEN) return;
  if (ws.raw.writableLength > highWater) {
    ws.pendingPong = Buffer.from(payload);
    return;
  }
  put(ws, frame(0xa, payload));
};

// Read every whole frame received. A frame's header is checked as soon as
// it is whole, so a message over the limit is refused before its bytes
// are kept.
const parse = (ws) => {
  while (ws.end === null) {
    if (ws.frame === null) {
      if (ws.bytes < 2) return;
      const b1 = byteAt(ws, 1);
      const short = b1 & 0x7f;
      const size = 2 + (short === 126 ? 2 : short === 127 ? 8 : 0) + 4;
      if ((b1 & 0x80) === 0) return fail(ws, 1002, "a frame from the client is not masked");
      if (ws.bytes < size) return;
      const head = take(ws, size);
      const fin = (head[0] & 0x80) !== 0;
      const opcode = head[0] & 0x0f;
      if ((head[0] & 0x70) !== 0) return fail(ws, 1002, "a frame sets a reserved bit");
      let length = short;
      if (short === 126) length = head.readUInt16BE(2);
      else if (short === 127) {
        const high = head.readUInt32BE(2);
        if ((high & 0x80000000) !== 0) return fail(ws, 1002, "a frame's length sets its highest bit");
        // A length past 2³² is over any `maxMessage` a session uses; the
        // sum below is exact up to 2⁵³ (amendment item 24).
        length = high * 0x100000000 + head.readUInt32BE(6);
      }
      if (opcode >= 0x8) {
        if (opcode > 0xa) return fail(ws, 1002, `a frame has the reserved opcode ${opcode}`);
        if (!fin) return fail(ws, 1002, "a control frame is fragmented");
        if (length > 125) return fail(ws, 1002, "a control frame is longer than 125 bytes");
      } else if (opcode === 0x0) {
        if (ws.parts === null) return fail(ws, 1002, "a continuation frame has no message to continue");
      } else if (opcode === 0x1 || opcode === 0x2) {
        if (ws.parts !== null) return fail(ws, 1002, "a new message starts before the last one is whole");
        if (opcode === 0x2) return fail(ws, 1003, "a binary message, which this version cannot read");
      } else return fail(ws, 1002, `a frame has the reserved opcode ${opcode}`);
      if (opcode < 0x8 && (ws.parts === null ? 0 : ws.partBytes) + length > ws.max) {
        return fail(ws, 1009, `a message is longer than ${ws.max} bytes`);
      }
      ws.frame = { fin, opcode, length, mask: head.subarray(size - 4) };
    }
    const { fin, opcode, length, mask } = ws.frame;
    if (ws.bytes < length) return;
    ws.frame = null;
    const payload = length === 0 ? Buffer.alloc(0) : take(ws, length);
    for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i & 3];
    if (opcode === 0x8) closed(ws, payload);
    else if (opcode === 0x9) pong(ws, payload); else if (opcode === 0xa) {
      // A pong answers nothing this side asked: it is ignored.
    } else {
      if (ws.parts === null) {
        ws.parts = [];
        ws.partBytes = 0;
      }
      ws.parts.push(payload);
      ws.partBytes += payload.length;
      if (fin) {
        const whole = ws.parts.length === 1 ? ws.parts[0] : Buffer.concat(ws.parts, ws.partBytes);
        ws.parts = null;
        ws.partBytes = 0;
        if (!isUtf8(whole)) return fail(ws, 1007, "a text message is not valid UTF-8");
        // After the session returned, or while this side closes, no one
        // reads: the message is dropped.
        if (ws.state === OPEN && !ws.done) deliver(ws, whole.toString("utf8"), whole.length);
      }
    }
  }
};

// The peer's close frame: its code and reason are the end. When the peer
// closed first, the same code is sent back; then this side ends the TCP
// connection, as a server does (RFC 6455 §7.1.1).
const closed = (ws, payload) => {
  if (payload.length === 1) return fail(ws, 1002, "a close frame holds one byte");
  let code = 1005;
  let reason = "";
  if (payload.length >= 2) {
    code = payload.readUInt16BE(0);
    if (!wireCode(code)) return fail(ws, 1002, `a close frame holds the code ${code}`);
    const text = payload.subarray(2);
    if (!isUtf8(text)) return fail(ws, 1007, "a close frame's reason is not valid UTF-8");
    reason = text.toString("utf8");
  }
  if (ws.state === OPEN) put(ws, closeFrame(code, ""));
  ws.state = CLOSED;
  reading(ws);
  ws.raw.destroySoon();
  deadline(ws);
  ended(ws, code, reason);
};

// --- The foreign values -----------------------------------------------------

export const fromUpgrade = (incoming, protocol, max) => {
  const { req, socket: raw, head, handle } = incoming;
  // The client went away while the program decided: no session starts,
  // and the socket keeps `Server.js`'s listener, which names the codes of a
  // client that is gone, until it closes.
  if (raw.destroyed || !raw.writable) return null;
  raw.off("error", incoming.waiting);
  const key = req.headers["sec-websocket-key"];
  const accept = crypto.createHash("sha1").update(key + guid).digest("base64");
  const lines = ["HTTP/1.1 101 Switching Protocols", "upgrade: websocket", "connection: Upgrade", `sec-websocket-accept: ${accept}`];
  if (protocol !== "") lines.push(`sec-websocket-protocol: ${protocol}`);
  raw.write(`${lines.join("\r\n")}\r\n\r\n`);
  raw.setNoDelay(true);
  // A client that vanishes is found in about a minute (amendment item 20).
  raw.setKeepAlive(true, 30000, 10000, 3);
  const ws = {
    raw,
    state: OPEN,
    queue: [],
    sizes: [],
    queued: 0,
    readers: [],
    end: null,
    drainers: [],
    chunks: [],
    bytes: 0,
    frame: null,
    parts: null,
    partBytes: 0,
    max,
    protocol,
    timer: null,
    paused: false,
    done: false,
    writes: 0,
    flushed: 0,
    pendingPong: null,
    path: req.url,
  };
  raw.on("data", (chunk) => {
    if (ws.end !== null) return;
    ws.chunks.push(chunk);
    ws.bytes += chunk.length;
    parse(ws);
  });
  raw.on("drain", () => {
    if (ws.pendingPong !== null && ws.state === OPEN) {
      const payload = ws.pendingPong;
      ws.pendingPong = null;
      put(ws, frame(0xa, payload));
    }
  });
  raw.on("error", (error) => {
    // The connection is gone: `close` follows, and ends it with 1006.
    if (isGone(error)) return;
    throw error;
  });
  // Node's HTTP server keeps a socket half open when its peer ends it, so a
  // peer that ends the TCP connection without a close frame would leave
  // this one open: it is ended here too, with 1006 unless a close frame
  // arrived first, and `destroySoon` flushes a close frame still being
  // written (amendment item 17).
  raw.on("end", () => {
    ended(ws, 1006, "");
    raw.destroySoon();
    deadline(ws);
  });
  raw.on("close", () => {
    if (ws.timer !== null) {
      clearTimeout(ws.timer);
      ws.timer = null;
    }
    ended(ws, 1006, "");
  });
  // `Server.close` closes every connection with 1001, this one too, even
  // when it opened after the close.
  incoming.goAway = () => sendClose(ws, 1001, "");
  if (handle.closing) incoming.goAway();
  if (head.length !== 0) {
    ws.chunks.push(head);
    ws.bytes += head.length;
    parse(ws);
  }
  return ws;
};

export const next = (ws, resume) => {
  if (ws.queue.length !== 0) {
    const text = ws.queue.shift();
    ws.queued -= ws.sizes.shift();
    if (ws.paused && ws.queued <= highWater && ws.end === null) {
      ws.paused = false;
      ws.raw.resume();
    }
    resume({ $: "Ok", a: text });
    return (unit) => unit;
  }
  if (ws.end !== null) {
    resume({ $: "Err", a: ws.end });
    return (unit) => unit;
  }
  ws.readers.push(resume);
  return (unit) => {
    const i = ws.readers.indexOf(resume);
    if (i >= 0) ws.readers.splice(i, 1);
    return unit;
  };
};

export const send = (ws, text) => {
  if (ws.state !== OPEN || !ws.raw.writable) return false;
  if (text !== lastText) {
    lastFrame = textFrame(text);
    lastText = text;
  }
  put(ws, lastFrame);
  return true;
};

export const begin = (ws, code, reason) => {
  sendClose(ws, code, reason);
  return null;
};

// The session returned: nothing reads from now on, and an open connection
// is closed with 1000.
export const finish = (ws) => {
  ws.done = true;
  ws.queue = [];
  ws.sizes = [];
  ws.queued = 0;
  reading(ws);
  sendClose(ws, 1000, "");
  return null;
};

export const unsent = (ws) => (ws.end !== null || ws.raw.destroyed ? 0 : ws.raw.writableLength);

export const chosen = (ws) => ws.protocol;

// `drain` (amendment item 14): at once when nothing waits to be sent or
// the connection has ended; otherwise when the callback of the last write
// made so far is called. Node's `drain` event comes only after a write
// that returned `false`, so waiting for it could wait forever.
export const awaitDrain = (ws, resume) => {
  if (ws.end !== null || ws.raw.writableLength === 0 || ws.flushed >= ws.writes) {
    resume(null);
    return (unit) => unit;
  }
  const waiter = { resume, target: ws.writes };
  ws.drainers.push(waiter);
  return (unit) => {
    const i = ws.drainers.indexOf(waiter);
    if (i >= 0) ws.drainers.splice(i, 1);
    return unit;
  };
};
