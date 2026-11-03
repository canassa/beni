let stable;
let nestedStable;
let reads;
let observed = false;
let installed = false;
let stableInstalled = false;
let outgoingView;
let shapedRecord;
let outgoingTree;
let viewObserved = false;
export const watchView = (view, record, tree) => { outgoingView = view; shapedRecord = record; outgoingTree = tree; install(); };
const install = () => {
  if (installed) return;
  installed = true;
  const post = globalThis.Worker.prototype.postMessage;
  globalThis.Worker.prototype.postMessage = function(frame) {
    if ((frame.kind === "Request" || frame.kind === 5) && outgoingView) {
      const fields = Object.values(frame.payload);
      viewObserved = !fields.includes(outgoingView) && fields.includes(shapedRecord) && fields.some(value =>
        Array.isArray(value) && value.length === 2 && value[0] === 1 && value[1] === 2) &&
        typeof outgoingTree.$plain === "function" && !fields.includes(outgoingTree) && fields.some(value =>
          Array.isArray(value) && value.length === 100 && value[0] === 1 && value[99] === 100);
      outgoingView = null;
    }
    return post.call(this, frame);
  };
};
export const watch = (value, nested) => {
  nestedStable = nested;
  stable = value;
  const key = Object.keys(value)[0];
  const text = value[key];
  reads = 0;
  Object.defineProperty(value, key, {enumerable: true, configurable: true,
    get() { reads++; return text; }});
  if (stableInstalled) return;
  stableInstalled = true;
  const post = globalThis.Worker.prototype.postMessage;
  globalThis.Worker.prototype.postMessage = function(frame) {
    if ((frame.kind === "Request" || frame.kind === 5) && stable) {
      // The existing byte-accounting walk reads it once. Normalization
      // must preserve the object and add no property reads of this branch.
      const readsBefore = reads;
      const fields = Object.values(frame.payload);
      observed = fields.includes(stable) && readsBefore === 1 && fields.some(part =>
        part !== null && typeof part === "object" && Object.values(part).includes(nestedStable));
      stable = null;
    }
    return post.call(this, frame);
  };
};
export const passed = () => observed && viewObserved;
