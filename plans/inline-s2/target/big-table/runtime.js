
let dead = false, busy = false, queue = null;
export function guard(f, a) {
  if (dead) return;
  if (busy) { (queue ||= []).push(f, a); return; }
  busy = true;
  let ok = false;
  try {
    f(a);
    while (queue !== null) { const q = queue; queue = null; for (let i = 0; i < q.length && !dead; i += 2) q[i](q[i + 1]); }
    ok = true;
  } finally { busy = false; if (!ok) { dead = true; queue = null; } }
}
export function stopAll() { dead = true; queue = null; }
export function revive() { dead = false; }
export function text(node, value) { value = String(value); if (node.textContent !== value) node.textContent = value; }
export function prop(node, value, key = "value") { if (node[key] !== value) node[key] = value; }
export function on(node, f, type = "click") { node.addEventListener(type, (e) => guard(f, e)); }
// The adapter's (excluded from the size): every pass is synchronous.
export const settled = () => Promise.resolve();
