const NativeWorker = globalThis.Worker;
export const configure = mode => {
  if (mode === "restore") globalThis.Worker = NativeWorker;
  else if (mode === "missing") globalThis.Worker = undefined;
  else globalThis.Worker = function () {
    if (mode === "syntax") throw new globalThis.DOMException("bad URL", "SyntaxError");
    if (mode === "security") throw new globalThis.DOMException("denied", "SecurityError");
    if (mode === "trusted") throw new globalThis.TypeError("Trusted Types sink rejected URL");
    throw new globalThis.RangeError("constructor must not run before option validation");
  };
};
