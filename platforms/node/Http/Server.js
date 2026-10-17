// The sibling JavaScript of `Http/Server.beni` (docs/design/boundary.md §4,
// §9.10): one export per `foreign` value, under the same name, and nothing
// else.
//
// A handle is `{ server, address, queue, waiter, closing, closed, waiters }`:
// the `http.Server`, the address it bound, the requests that arrived whole
// and wait for the accept loop, the loop's `Resume` while it waits, and
// the fibers waiting in `Http.Server.wait`. Each primitive starts one host
// operation, resumes the waiting fiber once, and returns what cancels it.
//
// Every failure Node documents is caught by its code, and nothing else is
// caught (CLAUDE.md rule 9): anything else is thrown again, and Node
// reports it and exits 1 (transparent-effects-proposal.md §16.5).

import { Buffer } from "node:buffer";
import http from "node:http";
import process from "node:process";

// `ListenError`'s constructor for each failure Node documents for
// `server.listen`, by the error's `code`. All nullary, so a constructor
// is its tag, the same string in a release build (boundary.md §4).
const listenErrors = {
  EADDRINUSE: "AddressInUse",
  EACCES: "PermissionDenied",
  EADDRNOTAVAIL: "AddressNotAvailable",
  // The address's family (IPv6, say) is off on this machine.
  EAFNOSUPPORT: "AddressNotAvailable",
  // `getaddrinfo` could not answer the host's name, or not now.
  ENOTFOUND: "HostNotFound",
  EAI_AGAIN: "HostNotFound",
  EAI_FAIL: "HostNotFound",
  EMFILE: "TooManyOpenFiles",
  ENFILE: "TooManyOpenFiles",
};

export const startListen = (address, resume) => {
  const server = http.createServer();
  const handle = { server, address: null, queue: [], waiter: null, closing: false, closed: false, waiters: [] };
  // Set once the wait is over, or cancelled: the fiber is answered at most
  // once, and a cancelled one not at all.
  let settled = false;
  const refused = (error) => {
    // An unnamed code is a defect whether or not anyone still waits.
    const code = error instanceof Error ? error.code : undefined;
    if (typeof code !== "string" || !Object.hasOwn(listenErrors, code)) throw error;
    // Cancelled while binding: no one waits for the answer.
    if (settled) return;
    settled = true;
    resume({ $: "Err", a: listenErrors[code] });
  };
  server.once("error", refused);
  server.once("listening", () => {
    server.off("error", refused);
    const bound = server.address();
    handle.address = { host: bound.address, port: bound.port };
    if (settled) {
      // Cancelled while binding: nothing waits, so the server closes now.
      server.close();
      return;
    }
    settled = true;
    server.on("request", (req, res) => receive(handle, req, res));
    server.on("close", () => {
      handle.closed = true;
      deliver(handle);
      const waiters = handle.waiters;
      handle.waiters = [];
      for (const waiter of waiters) waiter(null);
    });
    resume({ $: "Ok", a: handle });
  });
  server.listen({ host: address.host, port: address.port });
  return (unit) => {
    settled = true;
    return unit;
  };
};

// A request as it arrives: its body collected whole, then queued for the
// accept loop. A client that closes the connection before the body is whole
// is `req`'s `error` with `ECONNRESET`, and the request is dropped: there is
// no one to answer.
const receive = (handle, req, res) => {
  const chunks = [];
  req.on("data", (chunk) => chunks.push(chunk));
  req.on("error", (error) => {
    if (error instanceof Error && error.code === "ECONNRESET") return;
    throw error;
  });
  // A connection that fails while the response is written is the socket's
  // error, which Node routes to `clientError` and handles by default, and
  // `res` emits none (measured): no listener is needed on it.
  req.on("end", () => {
    const headers = [];
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      headers.push({ a: req.rawHeaders[i].toLowerCase(), b: req.rawHeaders[i + 1] });
    }
    const request = { method: req.method, path: req.url, headers, body: new TextDecoder().decode(Buffer.concat(chunks)) };
    handle.queue.push({ handle, req, res, request });
    deliver(handle);
  });
};

// Hand the accept loop the next request, or null once the server has
// closed, when it waits for one.
const deliver = (handle) => {
  if (handle.waiter === null) return;
  if (handle.queue.length !== 0) {
    const resume = handle.waiter;
    handle.waiter = null;
    resume(handle.queue.shift());
  } else if (handle.closed) {
    const resume = handle.waiter;
    handle.waiter = null;
    resume(null);
  }
};

export const nextRequest = (handle, resume) => {
  handle.waiter = resume;
  deliver(handle);
  return (unit) => {
    // The loop's fiber was cancelled, with the fiber that owns the server:
    // every connection is destroyed and the server closes at once.
    handle.waiter = null;
    handle.closing = true;
    handle.server.closeAllConnections();
    handle.server.close();
    return unit;
  };
};

export const requestOf = (incoming) => incoming.request;

// Why a `Response` cannot be written as it is, or null. The checks are
// Node's own, run before any header is set and before the first byte is
// sent, so a fault leaves nothing behind: the status rule of `writeHead`
// less the interim statuses (a handler answers once, and Node resets the
// connection on a final 100), the two statuses that carry no body,
// `validateHeaderName` and `validateHeaderValue` — caught from those two
// calls alone — and the two headers the transport owns.
const invalid = (response) => {
  const status = response.status;
  if (!Number.isInteger(status) || status < 200 || status > 999) {
    return `status ${status} is not an integer from 200 to 999`;
  }
  if ((status === 204 || status === 205 || status === 304) && response.body !== "") {
    return `status ${status} carries no body, and the body is not empty`;
  }
  const headers = Array.isArray(response.headers) ? response.headers : response.headers.$b.slice(response.headers.$o);
  for (const header of headers) {
    const name = header.a;
    const value = header.b;
    try {
      http.validateHeaderName(name);
    } catch (error) {
      if (error instanceof TypeError && error.code === "ERR_INVALID_HTTP_TOKEN") return `the header name ${JSON.stringify(name)} is not a token`;
      throw error;
    }
    try {
      http.validateHeaderValue(name, value);
    } catch (error) {
      if (error instanceof TypeError && error.code === "ERR_INVALID_CHAR") return `the header ${JSON.stringify(name)} has a character its value cannot hold`;
      if (error instanceof TypeError && error.code === "ERR_HTTP_INVALID_HEADER_VALUE") return `the header ${JSON.stringify(name)} has no value`;
      throw error;
    }
    const lower = name.toLowerCase();
    if (lower === "content-length" || lower === "transfer-encoding") return `the header ${JSON.stringify(name)} belongs to the platform`;
  }
  return null;
};

export const write = (incoming, response) => {
  const { handle, req, res } = incoming;
  // The client is gone: Node drops the write, and so does the platform.
  if (res.destroyed) return null;
  const fault = invalid(response);
  if (fault !== null) {
    process.stderr.write(`beni: Http.Server: the response to ${req.method} ${req.url} is invalid: ${fault}\n`);
    // After `close`, the 500 ends its connection as every response does.
    res.writeHead(500, handle.closing ? ["content-length", "0", "connection", "close"] : ["content-length", "0"]);
    res.end();
    return null;
  }
  const headers = Array.isArray(response.headers) ? response.headers : response.headers.$b.slice(response.headers.$o);
  const raw = [];
  for (const header of headers) {
    // After `close`, the connection ends with this response, whatever the
    // program said: Node leaves a busy keep-alive connection open otherwise.
    if (handle.closing && header.a.toLowerCase() === "connection") continue;
    raw.push(header.a, header.b);
  }
  if (handle.closing) raw.push("connection", "close");
  const body = Buffer.from(response.body, "utf8");
  // 204, 205 and 304 carry no body: Node drops one for 204 and 304 and
  // writes it for 205 (measured), so the body is empty here. 204 and 304
  // get no `content-length`; 205 gets `content-length: 0`, since Node
  // would otherwise send a chunked empty body. The headers go as one flat
  // array, so a name given twice is written twice, in order (`setHeader`
  // would keep one value per name).
  if (response.status !== 204 && response.status !== 304) raw.push("content-length", String(body.length));
  res.writeHead(response.status, raw);
  res.end(body);
  return null;
};

export const awaitClosed = (handle, resume) => {
  if (handle.closed) {
    resume(null);
    return (unit) => unit;
  }
  handle.waiters.push(resume);
  return (unit) => {
    const i = handle.waiters.indexOf(resume);
    if (i >= 0) handle.waiters.splice(i, 1);
    return unit;
  };
};

export const beginClose = (handle) => {
  if (handle.closing) return null;
  handle.closing = true;
  handle.server.close();
  handle.server.closeIdleConnections();
  return null;
};

export const boundAddress = (handle) => handle.address;
