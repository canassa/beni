export const attributes = x => {
  const on = x.classes[0].a === "before";
  x.classes[0] = { a: on ? "after" : "before", b: true };
  x.styles[0] = { a: on ? "color" : "background-color", b: on ? "blue" : "red" };
  return x;
};
