// Borrowed inspection views. Data descriptors ensure a getter is never invoked.
const view = (value, parent) => ({ value, parent });
const data = (value, key) => {
  if (value === null || value === undefined) return undefined;
  const descriptor = Object.getOwnPropertyDescriptor(Object(value), key);
  return descriptor && Object.hasOwn(descriptor, "value") ? descriptor.value : undefined;
};
const list = (value) => Array.isArray(value) || typeof data(data(value, "$h"), "treeCount") === "number" || Array.isArray(data(value, "b")) && typeof data(value, "o") === "number";
export const inspect = (value) => view(value, null);
export const kind = (raw) => {
  const value = raw.value;
  if (value === null) return "null";
  const type = typeof value;
  if (type === "object") {
    for (let parent = raw.parent; parent !== null; parent = parent.parent) {
      if (parent.value === value) return "cycle";
    }
    if (list(value)) return "array";
  }
  return type;
};
export const tag = (raw) => { const tag = data(raw.value, "$"); return typeof tag === "string" ? tag : ""; };
export const keys = (raw) => raw.value === null || raw.value === undefined ? [] : Object.keys(Object(raw.value));
export const field = (raw, key) => view(data(raw.value, key), raw);
export const element = (raw, index) => {
  const value = raw.value;
  const header = data(value, "$h");
  if (header !== undefined) {
    const treeCount = data(header, "treeCount");
    if (index >= treeCount) return view(data(data(data(header, "tail"), "values"), index - treeCount), raw);
    let node = data(header, "root");
    for (let level = data(header, "shift"); level > 0; level -= 5) node = data(data(node, "a"), index >>> level & 31);
    return view(data(data(node, "a"), index & 31), raw);
  }
  return view(Array.isArray(value) ? data(value, index) : data(data(value, "b"), data(value, "o") + index), raw);

};
export const length = (raw) => { const size = data(raw.value, "length"); return typeof size === "number" ? size : 0; };
export const string = (raw) => typeof raw.value === "string" ? raw.value : "";
export const number = (raw) => typeof raw.value === "number" ? raw.value : 0;
export const boolean = (raw) => raw.value === true;
