import { Math$Vector2$vec2, Math$Vector2$getX, Math$Vector2$getY, Math$Vector2$toRecord } from "./Math/Vector2.mjs";
import { Constants$bikeSize, Constants$gameBounds } from "./Constants.mjs";
import { List$unsafeGet, List$view, List$cons, List$drop, List$append, List$map } from "./_core/List.mjs";
import { BikePhysics$computePosition, BikePhysics$collision, BikePhysics$computeDirection } from "./BikePhysics.mjs";
import { Explosion$toObstacle, Explosion$forBike } from "./Explosion.mjs";
import { Trail$breakIfNecessary } from "./Trail.mjs";
import { Maybe$map } from "./_core/Maybe.mjs";
import { Keyboard$Key$$eq } from "./Keyboard.mjs";
import { Weapon$shoot } from "./Weapon.mjs";
import { String$fromFloat, String$join } from "./_core/String.mjs";
import { Basics$append } from "./_core/Basics.mjs";
import { Rt$template, Rt$childHtml, Rt$restate, Rt$slot } from "./_platform/_browser/Rt.mjs";
const Bike$Maybe$Nothing = { $: "Nothing", a: null };
const Bike$p522 = (i$11, v$12) => {
  const $in$13 = v$12[0];
  const $in$14 = v$12[1];
  const x$15 = $in$13;
  if (x$15 !== i$11.g0_0) {
    i$11.g0_0 = x$15;
    const $t$16 = String$fromFloat(2 * $in$13);
    const $t$17 = String$fromFloat(2 * $in$13);
    if ($t$16 !== i$11.a0) {
      i$11.w0.setAttribute("width", $t$16);
      i$11.a0 = $t$16;
    }
    if ($t$17 !== i$11.a1) {
      i$11.w0.setAttribute("height", $t$17);
      i$11.a1 = $t$17;
    }
  }
  const x$18 = $in$14;
  if (x$18 !== i$11.g1_0) {
    i$11.g1_0 = x$18;
    const $t$19 = Basics$append("fill:", $in$14);
    if ($t$19 !== i$11.a2) {
      i$11.w2.setAttribute("style", $t$19);
      i$11.a2 = $t$19;
    }
  }
};
const Bike$t522 = Rt$template("<svg viewBox=\"0 0 210 297\"><g><path d=\"m 185.20834,126.15476 -66.86084,92.02605 -108.183103,-35.15082 0,-113.750451 L 118.3475,34.128718 Z\"transform=matrix(0,-1.690983,1.1396473,0,-39.07253,313.47282)>", 0);
const Bike$k522 = { m: (v$20, cx$21) => {
  const r$22 = Bike$t522();
  const w$23 = r$22.firstChild;
  const w$24 = w$23.firstChild;
  const i$25 = { s: r$22, q: null, e: r$22, w0: r$22, w2: w$24, a0: undefined, a1: undefined, a2: undefined, g0_0: NaN, g1_0: NaN };
  Bike$p522(i$25, v$20);
  return i$25;
}, p: Bike$p522 };
const Bike$p471 = (i$26, v$27) => {
  const $in$28 = v$27[0];
  const $in$29 = v$27[1];
  if ($in$28 !== i$26.l0_0) {
    i$26.l0_0 = $in$28;
    const $t$30 = String$join(List$map($in$28, (vec$10) => Basics$append(String$fromFloat(Math$Vector2$getX(vec$10)), Basics$append(",", String$fromFloat(Math$Vector2$getY(vec$10))))), " ");
    i$26.d0 = $t$30;
  }
  const $let$31 = i$26.d0;
  const x$32 = $in$29.color;
  if (x$32 !== i$26.g0_0) {
    i$26.g0_0 = x$32;
    i$26.w0.setAttribute("stroke", x$32);
  }
  if (i$26.g1 === undefined) {
    i$26.g1 = true;
    const $t$33 = String$fromFloat(Constants$bikeSize / 2);
    if ($t$33 !== i$26.a1) {
      i$26.w0.setAttribute("stroke-width", $t$33);
      i$26.a1 = $t$33;
    }
  }
  const x$34 = $in$28;
  if (x$34 !== i$26.g2_0) {
    i$26.g2_0 = x$34;
    if ($let$31 !== i$26.a2) {
      i$26.w0.setAttribute("points", $let$31);
      i$26.a2 = $let$31;
    }
  }
};
const Bike$t471 = Rt$template("<svg><polyline fill=none stroke-linecap=square></svg>", 2);
const Bike$k471 = { m: (v$35, cx$36) => {
  const r$37 = Bike$t471();
  const i$38 = { s: r$37, q: null, e: r$37, w0: r$37, a1: undefined, a2: undefined, l0_0: NaN, d0: undefined, g0_0: NaN, g1: undefined, g2_0: NaN };
  Bike$p471(i$38, v$35);
  return i$38;
}, p: Bike$p471 };
const Bike$p489 = (i$39, v$40) => {
  const $in$41 = v$40[0];
  if ($in$41.position !== i$39.l0_0) {
    i$39.l0_0 = $in$41.position;
    const $t$42 = Math$Vector2$getX($in$41.position);
    i$39.d0 = $t$42;
  }
  const $let$43 = i$39.d0;
  if ($in$41.position !== i$39.l1_0) {
    i$39.l1_0 = $in$41.position;
    const $t$44 = Math$Vector2$getY($in$41.position);
    i$39.d1 = $t$44;
  }
  const $let$45 = i$39.d1;
  if ($in$41.direction !== i$39.l2_0) {
    i$39.l2_0 = $in$41.direction;
    let $t$46;
    $c$0: {
      switch ($in$41.direction) {
        case "North":
          {
            $t$46 = "0";
            break $c$0;
          }
        case "East":
          {
            $t$46 = "90";
            break $c$0;
          }
        case "South":
          {
            $t$46 = "180";
            break $c$0;
          }
        default:
          {
            $t$46 = "270";
            break $c$0;
          }
      }
    }
    i$39.d2 = $t$46;
  }
  const $let$47 = i$39.d2;
  if ($in$41.position !== i$39.l3_0 || $in$41.direction !== i$39.l3_1) {
    i$39.l3_0 = $in$41.position;
    i$39.l3_1 = $in$41.direction;
    const $t$48 = String$join(["translate(", String$fromFloat($let$43 - Constants$bikeSize), " ", String$fromFloat($let$45 - Constants$bikeSize), ") rotate(", $let$47, " ", String$fromFloat(Constants$bikeSize), " ", String$fromFloat(Constants$bikeSize), ")"], "");
    i$39.d3 = $t$48;
  }
  const $let$49 = i$39.d3;
  if ($in$41.position !== i$39.g0_0 || $in$41.direction !== i$39.g0_1) {
    i$39.g0_0 = $in$41.position;
    i$39.g0_1 = $in$41.direction;
    if ($let$49 !== i$39.a0) {
      i$39.w0.setAttribute("transform", $let$49);
      i$39.a0 = $let$49;
    }
  }
  const x$50 = $in$41.color;
  if (x$50 !== i$39.g1_0) {
    i$39.g1_0 = x$50;
    const $t$51 = $in$41.color;
    if ($t$51 !== i$39.a1_1) {
      i$39.a1_1 = $t$51;
      Rt$childHtml(i$39.c1, Bike$bikeForm(Constants$bikeSize, $t$51));
    } else {
      Rt$restate(i$39.c1);
    }
  } else {
    Rt$restate(i$39.c1);
  }
  i$39.l = i$39.c1.l;
};
const Bike$t489 = Rt$template("<svg><g></svg>", 2);
const Bike$k489 = { m: (v$52, cx$53) => {
  const r$54 = Bike$t489();
  const c$55 = Rt$slot(r$54, null, cx$53);
  const i$56 = { s: r$54, q: null, e: r$54, w0: r$54, c1: c$55, a0: undefined, a1_1: undefined, l0_0: NaN, d0: undefined, l1_0: NaN, d1: undefined, l2_0: NaN, d2: undefined, l3_0: NaN, l3_1: NaN, d3: undefined, g0_0: NaN, g0_1: NaN, g1_0: NaN };
  Bike$p489(i$56, v$52);
  return i$56;
}, p: Bike$p489, l: true };
const Bike$initBike = (controls$1, color$2, pos$3, direction$4, weapon$5) => ({ collided: false, color: color$2, controls: controls$1, direction: direction$4, position: pos$3, trail: [[pos$3, pos$3]], weapon: weapon$5 });
const Bike$frontWall = (bike$1) => {
  const vertical$2 = [Math$Vector2$vec2(Math$Vector2$getX(bike$1.position), Math$Vector2$getY(bike$1.position) - Constants$bikeSize), Math$Vector2$vec2(Math$Vector2$getX(bike$1.position), Math$Vector2$getY(bike$1.position) + Constants$bikeSize)];
  const horizontal$3 = [Math$Vector2$vec2(Math$Vector2$getX(bike$1.position) - Constants$bikeSize, Math$Vector2$getY(bike$1.position)), Math$Vector2$vec2(Math$Vector2$getX(bike$1.position) + Constants$bikeSize, Math$Vector2$getY(bike$1.position))];
  switch (bike$1.direction) {
    case "North":
      {
        return horizontal$3;
      }
    case "East":
      {
        return vertical$2;
      }
    case "South":
      {
        return horizontal$3;
      }
    default:
      {
        return vertical$2;
      }
  }
};
const Bike$omitLastSections = (trail$1) => {
  if (trail$1.length > 0) {
    const first$2 = List$unsafeGet(trail$1, 0);
    const rest$3 = List$view(trail$1, 1);
    return List$cons(List$drop(first$2, 2), rest$3);
  } else {
    const other$4 = trail$1;
    return other$4;
  }
};
const Bike$toObstacle = (bike$1) => {
  const $t$1 = Math$Vector2$toRecord(bike$1.position);
  const x$2 = $t$1.x;
  const y$3 = $t$1.y;
  const r$4 = Constants$bikeSize / 2;
  const $t$2 = x$2 - r$4;
  const $t$3 = x$2 + r$4;
  const $t$4 = y$3 - r$4;
  const $t$5 = y$3 + r$4;
  return { e: $t$3, n: $t$4, s: $t$5, w: $t$2 };
};
const Bike$swapPosition = (point$1, trail$2) => {
  $j$0$1: {
    if (trail$2.length > 0) {
      if (List$unsafeGet(trail$2, 0).length > 0) {
        const head$3 = List$unsafeGet(List$unsafeGet(trail$2, 0), 0);
        const tail$4 = List$view(List$unsafeGet(trail$2, 0), 1);
        const rest$5 = List$view(trail$2, 1);
        return List$cons(List$cons(point$1, tail$4), rest$5);
      } else {
        break $j$0$1;
      }
    } else {
      break $j$0$1;
    }
  }
  return trail$2;
};
const Bike$update = (diff$1, explosions$2, $p$6) => {
  const current$3 = $p$6.current;
  const other$4 = $p$6.other;
  const walls$5 = List$append(List$cons(Bike$frontWall(other$4), Bike$omitLastSections(current$3.trail)), List$append(other$4.trail, Constants$gameBounds));
  const nextPosition$6 = BikePhysics$computePosition(current$3.direction, current$3.position, diff$1);
  const collisionPoint$7 = BikePhysics$collision({ nextPosition: nextPosition$6, position: current$3.position }, walls$5, List$cons(Bike$toObstacle(other$4), List$map(explosions$2, Explosion$toObstacle)));
  const $t$7 = current$3.collided;
  let $t$8;
  if ($t$7) {
    $t$8 = { a: true, b: current$3.position, c: Bike$Maybe$Nothing };
  } else {
    if (collisionPoint$7.$ === "Just") {
      const point$12 = collisionPoint$7.a;
      $t$8 = { a: true, b: point$12, c: { $: "Just", a: point$12 } };
    } else {
      $t$8 = { a: false, b: nextPosition$6, c: Bike$Maybe$Nothing };
    }
  }
  const collided$8 = $t$8.a;
  const position$9 = $t$8.b;
  const explosionPoint$10 = $t$8.c;
  const trail$11 = collided$8 ? Trail$breakIfNecessary(explosions$2, current$3.trail) : Trail$breakIfNecessary(explosions$2, Bike$swapPosition(current$3.position, current$3.trail));
  return { a: { ...current$3, position: position$9, collided: collided$8, trail: trail$11 }, b: Maybe$map(explosionPoint$10, Explosion$forBike) };
};
const Bike$shoot = (key$1, $p$9) => {
  const current$2 = $p$9.current;
  const other$3 = $p$9.other;
  if (Keyboard$Key$$eq(key$1, current$2.controls.up)) {
    const $t$10 = Weapon$shoot(current$2, List$append(current$2.trail, other$3.trail));
    const weapon$4 = $t$10.a;
    const explosion$5 = $t$10.b;
    return { a: { ...current$2, weapon: weapon$4 }, b: explosion$5 };
  } else {
    return { a: current$2, b: Bike$Maybe$Nothing };
  }
};
const Bike$cons = (point$1, trail$2) => {
  if (trail$2.length === 0) {
    return [[point$1]];
  } else {
    const first$3 = List$unsafeGet(trail$2, 0);
    const rest$4 = List$view(trail$2, 1);
    return List$cons(List$cons(point$1, first$3), rest$4);
  }
};
const Bike$turn = (key$1, bike$2) => Keyboard$Key$$eq(bike$2.controls.left, key$1) || Keyboard$Key$$eq(bike$2.controls.right, key$1) ? { ...bike$2, direction: BikePhysics$computeDirection(bike$2.controls, bike$2.direction, key$1), trail: Bike$cons(bike$2.position, Bike$swapPosition(bike$2.position, bike$2.trail)) } : bike$2;
const Bike$bikeForm = (bikeSize_$1, color$2) => ({ t: Bike$k522, v: [bikeSize_$1, color$2] });
const Bike$view = (bike$1) => {
  const trail$6 = List$map(bike$1.trail, (section$8) => ({ t: Bike$k471, v: [section$8, bike$1] }));
  const bikeView$7 = bike$1.collided ? [] : [{ t: Bike$k489, v: [bike$1] }];
  return List$append(trail$6, bikeView$7);
};
export { Bike$initBike, Bike$frontWall, Bike$update, Bike$shoot, Bike$turn, Bike$toObstacle, Bike$view, Bike$bikeForm, Bike$cons, Bike$swapPosition, Bike$omitLastSections };
//# sourceMappingURL=Bike.mjs.map
