export const ack = (peer) => peer.native.postMessage({
  worker: 1, entry: peer.entry, fingerprint: peer.fingerprint,
  generation: peer.generation, requestId: 0, kind: "EventAck", payload: 0
});
