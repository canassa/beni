// The sibling JavaScript of `Dom.beni` (docs/design/boundary.md §4): one
// export per `foreign` value, under the same name. A node is found by id
// when the call is made; one that is not in the page is `NotFound`.

const found = (id, use) => {
  const node = globalThis.document.getElementById(id);
  if (node === null) return { $: "Err", a: { $: "NotFound", a: id } };
  return { $: "Ok", a: use(node) };
};

export const focus = (id) =>
  found(id, (node) => {
    node.focus();
    return null;
  });

export const blur = (id) =>
  found(id, (node) => {
    node.blur();
    return null;
  });

export const box = (id) =>
  found(id, (node) => {
    const r = node.getBoundingClientRect();
    return { height: r.height, width: r.width, x: r.x, y: r.y };
  });

export const scrollTo = (id, x, y) =>
  found(id, (node) => {
    node.scrollTo(x, y);
    return null;
  });

export const scrollIntoView = (id) =>
  found(id, (node) => {
    node.scrollIntoView();
    return null;
  });

export const viewport = (unit) => ({
  height: globalThis.innerHeight,
  width: globalThis.innerWidth,
  x: globalThis.scrollX,
  y: globalThis.scrollY,
});
