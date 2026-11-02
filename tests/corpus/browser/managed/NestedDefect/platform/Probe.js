const signal = text => {
  const channel = new globalThis.BroadcastChannel("beni-nested-defect");
  channel.postMessage(text);
  channel.close();
};
export const watch = () => {
  const channel = new globalThis.BroadcastChannel("beni-nested-defect");
  let closed = false;
  let cleaned = false;
  let observing = false;
  const render = () => {
    if (!observing) return;
    const observed = globalThis.document.querySelector("aside");
    if (closed) observed.dataset.closed = "yes";
    if (cleaned) observed.textContent = "nested cleaned";
  };
  channel.onmessage = event => {
    if (event.data === "Close") closed = true;
    if (event.data === "Cleaned") cleaned = true;
    render();
  };
  // Observe after the fault snapshot, independently of the stopped beni page.
  globalThis.document.querySelector("button").addEventListener("click", () => {
    observing = true;
    render();
  });
};
export const observeChild = () => {
  const post = globalThis.Worker.prototype.postMessage;
  globalThis.Worker.prototype.postMessage = function(frame) {
    if ((frame.kind === "Close" || frame.kind === 4)) signal("Close");
    return post.call(this, frame);
  };
};
export const cleaned = () => signal("Cleaned");
export const defect = () => { throw new Error("nested parent defect"); };
