// Observe the native constructor boundary; the opaque Handle stays in beni.
let native;
export const install = ignored => {
  const Original = globalThis.Worker;
  globalThis.Worker = function(url, options) {
    native = new Original(url, options);
    return native;
  };
  return null;
};
export const fail = ignored => { native.dispatchEvent(new globalThis.MessageEvent("messageerror")); };
