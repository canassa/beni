let messages = 0;
let errors = 0;
export const inject = value => {
  const channel = new globalThis.MessageChannel();
  const inspect = event => {
    if (event.data?.probe !== true) return;
    const valid = event.origin === "https://worker.example" && event.lastEventId === "startup" && event.source === null;
    if (event.type === "message") {
      if(valid && event.ports.length===1 && event.ports[0]===channel.port1)messages++;
      event.ports[0].close();
    } else {
      if(valid && event.ports.length===0)errors++;
    }
    event.stopImmediatePropagation();
  };
  globalThis.addEventListener("message", inspect);
  globalThis.addEventListener("messageerror", inspect);
  for(let index=0;index<32;index++){
  globalThis.dispatchEvent(new globalThis.MessageEvent("message", {
    data: {probe: true}, origin: "https://worker.example", lastEventId: "startup", ports: [channel.port1]
  }));
  if(index<31) globalThis.dispatchEvent(new globalThis.MessageEvent("messageerror", {
    data: {probe: true}, origin: "https://worker.example", lastEventId: "startup"
  }));
  }
  channel.port2.close();
  return value;
};
export const observed = () => messages===32 && errors===31 ? "metadata held" : "metadata lost";
