let stable;
let nestedStable;
let reads;
let observed = false;
let installed = false;
export const watch = (value, nested) => {
  nestedStable = nested;
  stable = value;
  const key = Object.keys(value)[0];
  const text = value[key];
  reads = 0;
  Object.defineProperty(value, key, {enumerable: true, configurable: true,
    get() { reads++; return text; }});
  if (installed) return;
  installed = true;
  const post = globalThis.Worker.prototype.postMessage;
  globalThis.Worker.prototype.postMessage = function(frame) {
    if (frame.kind === "Request" && stable) {
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
export const passed = () => observed;
