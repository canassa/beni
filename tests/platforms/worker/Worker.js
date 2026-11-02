// Only nodes with a List descendant are visited. Stable subgraphs go directly
// to structured clone; materialized arrays are already the receiver's List.
const normalize = (plan, role, value) => {
  if (plan === null) return value;
  const [roles, nodes] = plan;
  const visit = (index, value) => {
    const node = nodes[index];
    if (node === 0) return value;
    const [kind, edges] = node;
    if (kind === 1) {
      const array = Array.isArray(value) ? value : value.$plain();
      return nodes[edges[0][1]] === 0 ? array : array.map(item => visit(edges[0][1], item));
    }
    if (kind === 4) {
      const variant = edges.find(edge => edge[0] === value.$);
      return visit(variant[1], value);
    }
    let result = value;
    for (const [field, child] of edges) {
      if (nodes[child] === 0) continue;
      const next = visit(child, value[field]);
      if (next === value[field]) continue;
      if (result === value) result = {...value};
      result[field] = next;
    }
    return result;
  };
  const atPath = (value, path, node, offset = 0) => {
    if (offset === path.length) return visit(node, value);
    const field = path[offset];
    const next = atPath(value[field], path, node, offset + 1);
    return next === value[field] ? value : {...value, [field]: next};
  };
  for (const [index, node, path] of roles) {
    if (index === role) value = atPath(value, path, node);
  }
  return value;
};
let workerPlan = null;
let listener = null;
const pending = [];
export const configure = (program) => {
  workerPlan = program.$wire;
  globalThis.addEventListener("message", event => {
    if (listener === null) pending.push(event.data);
    else listener(event.data);
  });
};
export const nativeOpen = (descriptor) => {
  try {
    const worker = new globalThis.Worker(descriptor.url, {type: "module"});
    worker.addEventListener("error", event => { throw new globalThis.Error(event.message); });
    return {$: "Ok", a: {worker, wire: descriptor.$wire}};
  } catch (error) {
    if (error instanceof globalThis.DOMException && error.name === "SyntaxError") return {$: "Err", a: {$: "BadUrl"}};
    if (error instanceof globalThis.DOMException && error.name === "SecurityError") return {$: "Err", a: {$: "SecurityError"}};
    throw error;
  }
};
export const send = (handle, message) => { handle.worker.postMessage(normalize(handle.wire, 0, message)); };
export const receive = (handle, callback) => { handle.worker.addEventListener("message", event => callback(event.data)); };
export const listen = (callback) => {
  listener = callback;
  for (const message of pending) callback(message);
  pending.length = 0;
};
export const reply = (message) => { globalThis.postMessage(normalize(workerPlan, 1, message)); };
export const initializer = (value) => {
  if (globalThis.document !== undefined) throw new globalThis.Error("worker initializer ran in page");
  return value;
};
