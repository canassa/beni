let nativeGood = false;
let launches = 0;
let plainRequests = 0;
let encodedRequests = 0;
export const inspect = packet =>
  Object.keys(packet).sort().join(",") === "entry,fingerprint,generation,kind,payload,requestId,worker" &&
  packet.worker === "Ready" && packet.entry === "Request" && packet.generation === 41 && packet.requestId === 42 &&
  packet.kind === "Transport" && packet.fingerprint === "Defect" &&
  Object.keys(packet.payload).sort().join(",") === "eventCount,native,phase" &&
  packet.payload.phase === "Closed" && packet.payload.native === "Event" && packet.payload.eventCount === 43;
export const arm = () => {
  nativeGood = true;
  launches = 0;
  plainRequests = encodedRequests = 0;
  const Native = globalThis.Worker;
  globalThis.Worker = function(url, options) {
    launches++;
    nativeGood = nativeGood && typeof url === "string" && options.type === "module" && options.name === "Ready" && options.credentials === "same-origin";
    const worker = new Native(url, options);
    const post = worker.postMessage.bind(worker);
    worker.postMessage = frame => {
      if (frame.kind === "Request") plainRequests++;
      if (frame.kind === 5) encodedRequests++;
      return post(frame);
    };
    return worker;
  };
};
export const nativeFor = development => nativeGood && launches === 2 &&
  (development ? plainRequests === 2 && encodedRequests === 0 : encodedRequests === 2 && plainRequests === 0);
