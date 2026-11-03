// Capture the real endpoint and its Hello, preserving private Handle opacity.
let native, hello;
export const install = ignored => {
  const Original = globalThis.Worker;
  globalThis.Worker = function(url, options) {
    const worker = new Original(url, options);
    native = worker;
    const post = worker.postMessage.bind(worker);
    worker.postMessage = frame => { if (frame.kind === "Hello") hello = frame; post(frame); };
    return worker;
  };
  return null;
};
export const inject = development => { native.postMessage({...hello, requestId: 0, kind: development ? "EventAck" : 7, payload: 0}); return null; };
