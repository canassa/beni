export const install = () => {
  const NativeWorker = globalThis.Worker;
  globalThis.Worker = function (url, options) {
    const worker = new NativeWorker(new globalThis.URL("/_missing-worker.mjs", globalThis.location.href), options);
    worker.addEventListener("error", () => {
      globalThis.document.querySelector("#stage").textContent = "load failed";
    });
    return worker;
  };
};
