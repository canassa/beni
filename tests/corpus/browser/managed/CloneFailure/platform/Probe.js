export const install = () => {
  const post = globalThis.Worker.prototype.postMessage;
  globalThis.Worker.prototype.postMessage = function (frame) {
    if ((frame.kind === "Request" || frame.kind === 5)) post.call(this, {...frame, [Object.hasOwn(frame, "a") ? "f" : "payload"]: () => null});
    else post.call(this, frame);
  };
};
