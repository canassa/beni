let nativeGood = false;
let launches = 0;
export const inspect = packet =>
  Object.keys(packet).sort().join(",") === "entry,fingerprint,generation,kind,payload,requestId,worker" &&
  packet.worker === "Ready" && packet.entry === "Request" && packet.generation === 41 && packet.requestId === 42 &&
  packet.kind === "Transport" && packet.fingerprint === "Defect" &&
  Object.keys(packet.payload).sort().join(",") === "eventCount,native,phase" &&
  packet.payload.phase === "Closed" && packet.payload.native === "Event" && packet.payload.eventCount === 43;
export const arm = () => {
  nativeGood = true;
  launches = 0;
  const Native = globalThis.Worker;
  globalThis.Worker = function(url, options) {
    launches++;
    nativeGood = nativeGood && typeof url === "string" && options.type === "module" && options.name === "Ready" && options.credentials === "same-origin";
    return new Native(url, options);
  };
};
export const nativePassed = () => nativeGood && launches === 2;
