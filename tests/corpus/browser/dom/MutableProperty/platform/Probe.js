export const makeNode = () => {
  const node = globalThis.document.createElement("div");
  node.trace = [];
  return node;
};
export const descriptor = () => ({
  name: "aggregate",
  immutable: false,
  get: node => node.aggregate,
  set: (node, value) => {
    node.aggregate = value;
    node.trace.push(value.count);
    return null;
  }
});
export const payload = () => ({ count: 1 });
export const mutate = value => { value.count = 2; return null; };
export const result = node => node.trace.join(",");
