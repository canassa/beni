// The sibling JavaScript of `Browser/Events.beni` (docs/design/boundary.md
// §4): one export per `foreign` value, under the same name. A listener
// counts the events of one name on the window or the document until a
// fiber takes them; a fiber that finds none waits for the next.

export const size = (unit) => ({ height: globalThis.innerHeight, width: globalThis.innerWidth });

export const hidden = (unit) => globalThis.document.visibilityState === "hidden";

export const listen = (target, name) => {
  const on = target === "document" ? globalThis.document : globalThis;
  const l = { on, name, count: 0, resume: null, handler: null };
  l.handler = () => {
    const resume = l.resume;
    if (resume === null) {
      l.count += 1;
      return;
    }
    l.resume = null;
    resume(null);
  };
  on.addEventListener(name, l.handler);
  return l;
};

export const unlisten = (l) => {
  l.on.removeEventListener(l.name, l.handler);
  return null;
};

export const onEvent = (l, resume) => {
  if (l.count !== 0) {
    l.count = 0;
    resume(null);
    return null;
  }
  l.resume = resume;
  return (unit) => {
    l.resume = null;
    return unit;
  };
};
