let current = null;
let removed = 0;
export const listen = (send) => {
  current = send;
  globalThis.document.body.setAttribute("data-listeners", "1");
  send(1);
  send(2);
  return () => {
    if (current === send) current = null;
    removed++;
    globalThis.document.body.setAttribute("data-listeners", "0");
    globalThis.document.body.setAttribute("data-removes", String(removed));
    return null;
  };
};
export const burst = () => {
  if (current !== null) {
    current(3);
    current(4);
  }
  return null;
};
export const fail = () => {
  if (current !== null) current(5);
  return null;
};
