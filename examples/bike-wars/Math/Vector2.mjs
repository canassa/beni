const Math$Vector2$Vec2$$eq = ($x, $y) => $x.a === $y.a && $x.b === $y.b;
const Math$Vector2$vec2 = (x$1, y$2) => ({ $: "Vec2", a: x$1, b: y$2 });
const Math$Vector2$getX = ($p$1) => {
  const x$1 = $p$1.a;
  return x$1;
};
const Math$Vector2$getY = ($p$2) => {
  const y$1 = $p$2.b;
  return y$1;
};
const Math$Vector2$setX = (x$1, $p$3) => {
  const y$2 = $p$3.b;
  return { $: "Vec2", a: x$1, b: y$2 };
};
const Math$Vector2$setY = (y$1, $p$4) => {
  const x$2 = $p$4.a;
  return { $: "Vec2", a: x$2, b: y$1 };
};
const Math$Vector2$toRecord = ($p$5) => {
  const x$1 = $p$5.a;
  const y$2 = $p$5.b;
  return { x: x$1, y: y$2 };
};
const Math$Vector2$add = ($p$6, $p$7) => {
  const ax$1 = $p$6.a;
  const ay$2 = $p$6.b;
  const bx$3 = $p$7.a;
  const by$4 = $p$7.b;
  return { $: "Vec2", a: ax$1 + bx$3, b: ay$2 + by$4 };
};
export { Math$Vector2$Vec2$$eq, Math$Vector2$vec2, Math$Vector2$getX, Math$Vector2$getY, Math$Vector2$setX, Math$Vector2$setY, Math$Vector2$toRecord, Math$Vector2$add };
//# sourceMappingURL=Vector2.mjs.map
