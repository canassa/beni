export const withoutImmediate = () => {
  delete globalThis.setImmediate;
  const Channel = globalThis.MessageChannel;
  // A Node port that listens keeps Node running for good, and a page's
  // keeps nothing open: this one keeps Node running while a message it
  // was sent has not been delivered, as a page's pending task would.
  globalThis.MessageChannel = function () {
    const channel = new Channel();
    const { port1, port2 } = channel;
    const post = port2.postMessage.bind(port2);
    let pending = 0;
    port2.postMessage = (message) => {
      pending += 1;
      port1.ref();
      post(message);
    };
    Object.defineProperty(port1, "onmessage", {
      set: (listen) => {
        port1.addEventListener("message", (event) => {
          pending -= 1;
          if (pending === 0) port1.unref();
          listen(event);
        });
        port1.start();
      },
    });
    return channel;
  };
};
