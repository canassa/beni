// The page platform's runtime: `run` mounts a program into
// `document.body` and keeps it rendered.
//
// A render patches the nodes the previous one made, position by position:
// a node whose tag (or text-ness) is unchanged is kept and updated in place,
// anything else is replaced, and surplus nodes are removed. So a node that
// did not change keeps its identity across renders, which is what lets a
// test observe a controlled input or a focused element surviving a message.
//
// A message runs `update` at once and queues one microtask flush, which
// renders the latest model; five messages in one task render once.
//
// The page is reached through `globalThis`, as a host capability rather
// than a name the sibling check would have to trust.

const renderAttributes = (el, attributes, send) => {
  const before = el.$attributes ?? [];
  const handlers = {};
  const names = new Set();
  for (const a of attributes) {
    if (a.kind === "attribute") {
      names.add(a.name);
      if (el.getAttribute(a.name) !== a.value) el.setAttribute(a.name, a.value);
    } else if (a.kind === "value") {
      if (el.value !== a.value) el.value = a.value;
    } else {
      handlers[a.name] = a.handler;
      if (!el.$handlers?.[a.name]) el.addEventListener(a.name, (event) => el.$dispatch(event));
    }
  }
  for (const name of before) if (!names.has(name)) el.removeAttribute(name);
  el.$attributes = [...names];
  el.$handlers = handlers;
  el.$dispatch = (event) => {
    const handler = el.$handlers[event.type];
    if (handler) send(handler(event));
  };
};

const create = (document, node, send) => {
  if (node.tag === null) return document.createTextNode(node.data);
  const el = document.createElement(node.tag);
  renderAttributes(el, node.attributes, send);
  for (const child of node.children) el.appendChild(create(document, child, send));
  return el;
};

const patch = (document, parent, nodes, send) => {
  const existing = [...parent.childNodes];
  nodes.forEach((node, i) => {
    const old = existing[i];
    const same =
      old !== undefined &&
      (node.tag === null ? old.nodeType === 3 : old.nodeType === 1 && old.localName === node.tag);
    if (!same) {
      const fresh = create(document, node, send);
      if (old === undefined) parent.appendChild(fresh);
      else parent.replaceChild(fresh, old);
    } else if (node.tag === null) {
      if (old.data !== node.data) old.data = node.data;
    } else {
      renderAttributes(old, node.attributes, send);
      patch(document, old, node.children, send);
    }
  });
  for (const extra of existing.slice(nodes.length)) parent.removeChild(extra);
};

export const run = (program) => {
  const document = globalThis.document;
  const root = document.body;
  let model = program.init;
  let queued = false;
  const render = () => patch(document, root, [program.view(model)], send);
  const send = (msg) => {
    model = program.update(msg, model);
    if (queued) return;
    queued = true;
    queueMicrotask(() => {
      queued = false;
      render();
    });
  };
  render();
};
