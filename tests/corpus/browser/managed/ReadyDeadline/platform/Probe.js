let worker;
let hold;
let nativePost;
export const install = () => {
  const NativeWorker = globalThis.Worker;
  nativePost = NativeWorker.prototype.postMessage;
  globalThis.Worker = function (url, options) {
    worker = new NativeWorker(url, options);
    hold = event => {
      if (event.data.kind === "Ready") {
        event.stopImmediatePropagation();
        globalThis.document.querySelector("#stage").textContent = "ready withheld";
      }
    };
    worker.addEventListener("message", hold);
    worker.postMessage = frame => {
      if (frame.kind !== "Close") nativePost.call(worker, frame);
    };
    return worker;
  };
};
export const release = () => {
  worker.removeEventListener("message", hold);
  nativePost.call(worker, {worker: 1, kind: "Close", generation: 1});
};
