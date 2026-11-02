export const ack = peer => (peer.native ?? peer.t).postMessage({
  worker: 1, entry: peer.entry, fingerprint: peer.fingerprint,
  generation: peer.generation, requestId: 0,
  kind: Object.hasOwn(peer, "t") ? 7 : "EventAck", payload: 0
});
