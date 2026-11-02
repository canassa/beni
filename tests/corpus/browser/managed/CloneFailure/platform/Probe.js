export const install = () => {
  const post = globalThis.Worker.prototype.postMessage;
  globalThis.Worker.prototype.postMessage = function (frame) {
    if (frame.kind === "Request") post.call(this, {...frame, payload: () => null});
    else post.call(this, frame);
  };
};
