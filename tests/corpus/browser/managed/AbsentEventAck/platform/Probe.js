export const ack = (peer) => {
  if (Object.hasOwn(peer, "t")) peer.t.postMessage({
    a: 1, b: peer.b, fingerprint: peer.fingerprint,
    c: peer.c, d: 0, kind: 7, f: 0
  });
  else peer.native.postMessage({
    worker: 1, entry: peer.entry, fingerprint: peer.fingerprint,
    generation: peer.generation, requestId: 0, kind: "EventAck", payload: 0
  });
};
