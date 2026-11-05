const NativeWorker = globalThis.Worker;
export const install = mode => {
  globalThis.Worker = function(url, options) {
    if (mode === "syntax") throw new globalThis.DOMException("invalid URL", "SyntaxError");
    if (mode === "security") throw new globalThis.DOMException("denied", "SecurityError");
    if (mode === "type") throw new globalThis.TypeError("invalid options");
    if (mode === "renamed-type") {
      const error = new globalThis.TypeError("still a type error");
      error.name = "SyntaxError";
      throw error;
    }
    const workerUrl = globalThis.URL.createObjectURL(new globalThis.Blob([""], { type: "text/javascript" }));
    const worker = new NativeWorker(workerUrl, options);
    globalThis.URL.revokeObjectURL(workerUrl);
    return worker;
  };
};
