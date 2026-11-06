export const nativeOpen = (descriptor) => {
  try {
    const worker = new globalThis.Worker(descriptor.url, {type: "module"});
    worker.addEventListener("error", event => { throw new globalThis.Error(event.message); });
    return {$: "Ok", a: worker};
  } catch (error) {
    if (error instanceof globalThis.DOMException && error.name === "SyntaxError") return {$: "Err", a: {$: "BadUrl"}};
    if (error instanceof globalThis.DOMException && error.name === "SecurityError") return {$: "Err", a: {$: "SecurityError"}};
    throw error;
  }
};
export const send = (worker, message) => { worker.postMessage(message); };
export const receive = (worker, callback) => { worker.addEventListener("message", event => callback(event.data)); };
export const listen = (callback) => { globalThis.addEventListener("message", event => callback(event.data)); };
export const reply = (message) => { globalThis.postMessage(message); };
export const initializer = (value) => {
  if (globalThis.document !== undefined) throw new globalThis.Error("worker initializer ran in page");
  return value;
};
