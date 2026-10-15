import { Math$Vector2$getX, Math$Vector2$getY, Math$Vector2$Vec2$$eq, Math$Vector2$toRecord, Math$Vector2$vec2 } from "./Math/Vector2.mjs";
import { List$foldr, List$unsafeGet, List$view, List$head, List$cons, List$base, List$offset, List$filterMap, List$concat, List$map, List$reverse } from "./_core/List.mjs";
import { Maybe$Maybe$$eq } from "./_core/Maybe.mjs";
import { Debug$logAs } from "./_core/Debug.mjs";
import { Basics$identity } from "./_core/Basics.mjs";
const Helpers$Maybe$Nothing = { $: "Nothing", a: null };
const Helpers$eq$prim = ($x, $y) => $x === $y;
const Helpers$eq$r$x$y = ($m$0, $m$1, $x, $y) => $m$0($x.x, $y.x) && $m$1($x.y, $y.y);
const Helpers$sortPoints = ($p$1) => {
  const a$1 = $p$1.a;
  const b$2 = $p$1.b;
  return Math$Vector2$getX(a$1) === Math$Vector2$getX(b$2) && Math$Vector2$getY(a$1) < Math$Vector2$getY(b$2) || Math$Vector2$getY(a$1) === Math$Vector2$getY(b$2) && Math$Vector2$getX(a$1) < Math$Vector2$getX(b$2) ? { a: a$1, b: b$2 } : { a: b$2, b: a$1 };
};
const Helpers$linesToTrail = (lines$1) => List$foldr(lines$1, [], (line$2, acc$3) => {
  let $t$2;
  if (line$2.$ === "Horizontal") {
    const points$6 = line$2.a;
    $t$2 = points$6;
  } else {
    const points$7 = line$2.a;
    $t$2 = points$7;
  }
  const start$4 = $t$2.a;
  const end$5 = $t$2.b;
  if (acc$3.length === 0) {
    return [[start$4, end$5]];
  } else {
    const accHead$8 = List$unsafeGet(acc$3, 0);
    const accTail$9 = List$view(acc$3, 1);
    return Maybe$Maybe$$eq(Math$Vector2$Vec2$$eq, List$head(accHead$8), { $: "Just", a: end$5 }) ? List$cons(List$cons(start$4, accHead$8), accTail$9) : List$cons([start$4, end$5], acc$3);
  }
});
const Helpers$toLine = (vecA$1, vecB$2) => {
  const a$3 = Math$Vector2$toRecord(vecA$1);
  const b$4 = Math$Vector2$toRecord(vecB$2);
  if (Helpers$eq$r$x$y(Helpers$eq$prim, Helpers$eq$prim, a$3, b$4)) {
    return Helpers$Maybe$Nothing;
  } else {
    if (a$3.x === b$4.x) {
      return { $: "Just", a: { $: "Vertical", a: { a: vecA$1, b: vecB$2 } } };
    } else {
      if (a$3.y === b$4.y) {
        return { $: "Just", a: { $: "Horizontal", a: { a: vecA$1, b: vecB$2 } } };
      } else {
        Debug$logAs("[[\"t\",{\"x\":\"f\",\"y\":\"f\"},{\"x\":\"f\",\"y\":\"f\"}],[]]", "Line invalid", { a: a$3, b: b$4 });
        return Helpers$Maybe$Nothing;
      }
    }
  }
};
const Helpers$trailToLines = (trail$1) => {
  function recurse$2(acc$3, list$4) {
    const $t$3 = List$base(list$4);
    list$4 = List$offset(list$4);
    while ($t$3.length !== list$4) {
      if ($t$3.length === list$4 + 1) {
        return acc$3;
      } else {
        const a$5 = $t$3[list$4];
        const b$6 = $t$3[list$4 + 1];
        const tail$7 = list$4 + 2;
        acc$3 = List$cons(Helpers$toLine(a$5, b$6), acc$3);
        list$4 = tail$7 - 1;
      }
    }
    return acc$3;
  }
  return List$filterMap(List$concat(List$map(trail$1, (l$8) => List$reverse(recurse$2([], l$8)))), Basics$identity);
};
const Helpers$tryCollision = (method$1, linePoints$2) => List$head(List$reverse(List$filterMap(linePoints$2, method$1)));
const Helpers$isBetween = ($p$5, point$3) => {
  const small$1 = $p$5.a;
  const large$2 = $p$5.b;
  return small$1 <= point$3 && large$2 >= point$3;
};
const Helpers$tryObstacleCollision = ($p$6, $p$7) => {
  const a$1 = $p$6.a;
  const b$2 = $p$6.b;
  const n$3 = $p$7.n;
  const s$4 = $p$7.s;
  const w$5 = $p$7.w;
  const obstacle$6 = $p$7;
  function diff$7(point$8) {
    return Helpers$isBetween({ a: w$5, b: obstacle$6.e }, Math$Vector2$getX(point$8)) && Helpers$isBetween({ a: n$3, b: s$4 }, Math$Vector2$getY(point$8));
  }
  if (diff$7(a$1)) {
    return { $: "Just", a: a$1 };
  } else {
    return diff$7(b$2) ? { $: "Just", a: b$2 } : Helpers$Maybe$Nothing;
  }
};
const Helpers$isBetweenWith = (getN$1, $p$8, point$4) => {
  const small$2 = $p$8.a;
  const large$3 = $p$8.b;
  return getN$1(small$2) <= getN$1(point$4) && getN$1(large$3) >= getN$1(point$4);
};
const Helpers$horizontalOrthogonal = (move$1, trail$2) => {
  const $t$9 = Helpers$sortPoints(move$1);
  const a$3 = $t$9.a;
  const b$4 = $t$9.b;
  const $t$10 = Helpers$sortPoints(trail$2);
  const trailA$5 = $t$10.a;
  const trailB$6 = $t$10.b;
  return Helpers$isBetweenWith(Math$Vector2$getX, { a: a$3, b: b$4 }, trailA$5) && Helpers$isBetweenWith(Math$Vector2$getY, { a: trailA$5, b: trailB$6 }, a$3) ? { $: "Just", a: Math$Vector2$vec2(Math$Vector2$getX(trailA$5), Math$Vector2$getY(a$3)) } : Helpers$Maybe$Nothing;
};
const Helpers$verticalOrthogonal = (move$1, trail$2) => {
  const $t$11 = Helpers$sortPoints(move$1);
  const a$3 = $t$11.a;
  const b$4 = $t$11.b;
  const $t$12 = Helpers$sortPoints(trail$2);
  const trailA$5 = $t$12.a;
  const trailB$6 = $t$12.b;
  return Helpers$isBetweenWith(Math$Vector2$getY, { a: a$3, b: b$4 }, trailA$5) && Helpers$isBetweenWith(Math$Vector2$getX, { a: trailA$5, b: trailB$6 }, a$3) ? { $: "Just", a: Math$Vector2$vec2(Math$Vector2$getX(a$3), Math$Vector2$getY(trailA$5)) } : Helpers$Maybe$Nothing;
};
const Helpers$onlyVertical = (line$1) => {
  if (line$1.$ === "Horizontal") {
    return Helpers$Maybe$Nothing;
  } else {
    const points$2 = line$1.a;
    return { $: "Just", a: points$2 };
  }
};
const Helpers$onlyHorizontal = (line$1) => {
  if (line$1.$ === "Horizontal") {
    const points$2 = line$1.a;
    return { $: "Just", a: points$2 };
  } else {
    return Helpers$Maybe$Nothing;
  }
};
export { Helpers$sortPoints, Helpers$linesToTrail, Helpers$trailToLines, Helpers$toLine, Helpers$tryCollision, Helpers$tryObstacleCollision, Helpers$horizontalOrthogonal, Helpers$verticalOrthogonal, Helpers$isBetween, Helpers$isBetweenWith, Helpers$onlyVertical, Helpers$onlyHorizontal };
//# sourceMappingURL=Helpers.mjs.map
