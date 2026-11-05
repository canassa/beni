let last, cups, length;
globalThis.window.addEventListener("mutate", () => {
  last.state.cups = 99;
  last.state.items.push(9);
});
// The driver reuses scripted detail objects across dev/release runs. Restore
// its input after the assertion, so each variant receives the same payload.
globalThis.window.addEventListener("restore", () => {
  last.state.cups = cups;
  last.state.items.length = length;
});
export const detail = (event) => {
  last = event.detail;
  cups = last.state.cups;
  length = last.state.items.length;
  return last;
};
