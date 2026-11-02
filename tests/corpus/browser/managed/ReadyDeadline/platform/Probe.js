let worker;
let encoded = false;
let hold;
let nativePost;
export const install = () => {
  const NativeWorker = globalThis.Worker;
  nativePost = NativeWorker.prototype.postMessage;
  globalThis.Worker = function (url, options) {
    worker = new NativeWorker(url, options);
    hold = event => {
      if ((event.data.kind === "Ready" || event.data.kind === 1)) {
        event.stopImmediatePropagation();
        globalThis.document.querySelector("#stage").textContent = "ready withheld";
      }
    };
    worker.addEventListener("message", hold);
    worker.postMessage = frame => {
      encoded = Object.hasOwn(frame, "a");
      if ((frame.kind !== "Close" && frame.kind !== 4)) nativePost.call(worker, frame);
    };
    return worker;
  };
};
export const release = () => {
  worker.removeEventListener("message", hold);
  nativePost.call(worker, encoded ? {a: 1, kind: 4, c: 1} : {worker: 1, kind: "Close", generation: 1});
};
