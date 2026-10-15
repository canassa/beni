import { Helpers$sortPoints, Helpers$isBetween, Helpers$linesToTrail, Helpers$trailToLines } from "./Helpers.mjs";
import { Math$Vector2$Vec2$$eq, Math$Vector2$getY, Math$Vector2$getX, Math$Vector2$setX, Math$Vector2$setY } from "./Math/Vector2.mjs";
import { Tuple$mapSecond, Tuple$mapFirst } from "./Tuple.mjs";
import { Explosion$toObstacle } from "./Explosion.mjs";
import { List$map, List$concatMap, List$base, List$offset } from "./_core/List.mjs";
const Trail$horizontalPairs = ($p$1, $p$2) => {
  const n$1 = $p$1.n;
  const w$2 = $p$1.w;
  const s$3 = $p$1.s;
  const bounds$4 = $p$1;
  const end$5 = $p$2.a;
  const start$6 = $p$2.b;
  const points$7 = $p$2;
  const $t$3 = Helpers$sortPoints(points$7);
  const small$8 = $t$3.a;
  const large$9 = $t$3.b;
  const smallIsStart$10 = Math$Vector2$Vec2$$eq(small$8, start$6);
  const mapSmall$11 = smallIsStart$10 ? Tuple$mapSecond : Tuple$mapFirst;
  const mapLarge$12 = smallIsStart$10 ? Tuple$mapFirst : Tuple$mapSecond;
  if (Helpers$isBetween({ a: n$1, b: s$3 }, Math$Vector2$getY(small$8))) {
    const smallIsBetween$13 = Helpers$isBetween({ a: w$2, b: bounds$4.e }, Math$Vector2$getX(small$8));
    const largeIsBetween$14 = Helpers$isBetween({ a: w$2, b: bounds$4.e }, Math$Vector2$getX(large$9));
    const explosionIsBetween$15 = Math$Vector2$getX(small$8) < w$2 && bounds$4.e < Math$Vector2$getX(large$9);
    const y$16 = Math$Vector2$getY(small$8);
    if (smallIsBetween$13) {
      if (largeIsBetween$14) {
        return [];
      } else {
        return [mapSmall$11(($p$4) => Math$Vector2$setX(bounds$4.e, $p$4), points$7)];
      }
    } else {
      if (largeIsBetween$14) {
        return [mapLarge$12(($p$5) => Math$Vector2$setX(w$2, $p$5), points$7)];
      } else {
        if (explosionIsBetween$15) {
          return smallIsStart$10 ? [mapSmall$11(($p$6) => Math$Vector2$setX(bounds$4.e, $p$6), points$7), mapLarge$12(($p$7) => Math$Vector2$setX(w$2, $p$7), points$7)] : [mapLarge$12(($p$8) => Math$Vector2$setX(w$2, $p$8), points$7), mapSmall$11(($p$9) => Math$Vector2$setX(bounds$4.e, $p$9), points$7)];
        } else {
          return [points$7];
        }
      }
    }
  } else {
    return [points$7];
  }
};
const Trail$verticalPairs = ($p$10, $p$11) => {
  const n$1 = $p$10.n;
  const w$2 = $p$10.w;
  const s$3 = $p$10.s;
  const bounds$4 = $p$10;
  const end$5 = $p$11.a;
  const start$6 = $p$11.b;
  const points$7 = $p$11;
  const $t$12 = Helpers$sortPoints(points$7);
  const small$8 = $t$12.a;
  const large$9 = $t$12.b;
  const smallIsStart$10 = Math$Vector2$Vec2$$eq(small$8, start$6);
  const mapSmall$11 = smallIsStart$10 ? Tuple$mapSecond : Tuple$mapFirst;
  const mapLarge$12 = smallIsStart$10 ? Tuple$mapFirst : Tuple$mapSecond;
  if (Helpers$isBetween({ a: w$2, b: bounds$4.e }, Math$Vector2$getX(small$8))) {
    const smallIsBetween$13 = Helpers$isBetween({ a: n$1, b: s$3 }, Math$Vector2$getY(small$8));
    const largeIsBetween$14 = Helpers$isBetween({ a: n$1, b: s$3 }, Math$Vector2$getY(large$9));
    const explosionIsBetween$15 = Math$Vector2$getY(small$8) < n$1 && s$3 < Math$Vector2$getY(large$9);
    if (smallIsBetween$13) {
      if (largeIsBetween$14) {
        return [];
      } else {
        return [mapSmall$11(($p$13) => Math$Vector2$setY(s$3, $p$13), points$7)];
      }
    } else {
      if (largeIsBetween$14) {
        return [mapLarge$12(($p$14) => Math$Vector2$setY(n$1, $p$14), points$7)];
      } else {
        if (!explosionIsBetween$15) {
          return [points$7];
        } else {
          return smallIsStart$10 ? [mapSmall$11(($p$15) => Math$Vector2$setY(s$3, $p$15), points$7), mapLarge$12(($p$16) => Math$Vector2$setY(n$1, $p$16), points$7)] : [mapLarge$12(($p$17) => Math$Vector2$setY(n$1, $p$17), points$7), mapSmall$11(($p$18) => Math$Vector2$setY(s$3, $p$18), points$7)];
        }
      }
    }
  } else {
    return [points$7];
  }
};
const Trail$cutWith = (explosion$1, line$2) => {
  const bounds$3 = Explosion$toObstacle(explosion$1);
  if (line$2.$ === "Horizontal") {
    const points$4 = line$2.a;
    return List$map(Trail$horizontalPairs(bounds$3, points$4), ($x$19) => ({ $: "Horizontal", a: $x$19 }));
  } else {
    const points$5 = line$2.a;
    return List$map(Trail$verticalPairs(bounds$3, points$5), ($x$20) => ({ $: "Vertical", a: $x$20 }));
  }
};
const Trail$breakLines = (explosion$1, lines$2) => List$concatMap(lines$2, ($p$21) => Trail$cutWith(explosion$1, $p$21));
const Trail$breakTrail = (explosion$1, trail$2) => Helpers$linesToTrail(Trail$breakLines(explosion$1, Helpers$trailToLines(trail$2)));
const Trail$breakIfNecessary = (explosions$1, trail$2) => {
  const $t$22 = List$base(explosions$1);
  explosions$1 = List$offset(explosions$1);
  while ($t$22.length !== explosions$1) {
    const a$3 = $t$22[explosions$1];
    const rest$4 = explosions$1 + 1;
    explosions$1 = rest$4;
    trail$2 = Trail$breakTrail(a$3, trail$2);
  }
  return trail$2;
};
export { Trail$breakIfNecessary, Trail$breakTrail, Trail$breakLines, Trail$cutWith, Trail$horizontalPairs, Trail$verticalPairs };
//# sourceMappingURL=Trail.mjs.map
