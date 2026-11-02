let messages = false;
let errors = false;
export const inject = value => {
  const channel = new globalThis.MessageChannel();
  const inspect = event => {
    if (event.data?.probe !== true) return;
    const valid = event.origin === "https://worker.example" && event.lastEventId === "startup" && event.source === null;
    if (event.type === "message") {
      messages = valid && event.ports.length === 1 && event.ports[0] === channel.port1;
      event.ports[0].close();
    } else {
      errors = valid && event.ports.length === 0;
    }
    event.stopImmediatePropagation();
  };
  globalThis.addEventListener("message", inspect);
  globalThis.addEventListener("messageerror", inspect);
  globalThis.dispatchEvent(new globalThis.MessageEvent("message", {
    data: {probe: true}, origin: "https://worker.example", lastEventId: "startup", ports: [channel.port1]
  }));
  globalThis.dispatchEvent(new globalThis.MessageEvent("messageerror", {
    data: {probe: true}, origin: "https://worker.example", lastEventId: "startup"
  }));
  channel.port2.close();
  return value;
};
export const observed = () => messages && errors ? "metadata held" : "metadata lost";
