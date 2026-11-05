// Minimal host upgrade records: the ordinary handshake body runs unchanged.
export const incoming = gone => ({
  req: { headers: { "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==" }, url: "/" },
  socket: { destroyed: gone, writable: true, off: () => {}, on: () => {}, write: () => {}, setNoDelay: () => {}, setKeepAlive: () => {} },
  head: [], handle: { closing: false }, waiting: () => {}
});
