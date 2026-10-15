import { Math$Vector2$toRecord, Math$Vector2$getX, Math$Vector2$getY } from "./Math/Vector2.mjs";
import { Basics$toFloat } from "./_core/Basics.mjs";
import { Int$mod } from "./_core/Int.mjs";
import { String$fromFloat } from "./_core/String.mjs";
import { Constants$colors } from "./Constants.mjs";
import { Rt$template } from "./_platform/_browser/Rt.mjs";
import { List$map, List$reverse, List$filter } from "./_core/List.mjs";
const Explosion$p161 = (i$7, v$8) => {
  const $in$9 = v$8[0];
  const $in$10 = v$8[1];
  const $in$11 = v$8[2];
  if ($in$9 !== i$7.l0_0 || $in$10 !== i$7.l0_1) {
    i$7.l0_0 = $in$9;
    i$7.l0_1 = $in$10;
    const $t$12 = Basics$toFloat(Int$mod($in$9, 10)) * 0.05 * $in$10;
    i$7.d0 = $t$12;
  }
  const $let$13 = i$7.d0;
  if ($in$9 !== i$7.g0_0 || $in$10 !== i$7.g0_1) {
    i$7.g0_0 = $in$9;
    i$7.g0_1 = $in$10;
    const $t$14 = String$fromFloat($let$13);
    const $t$15 = Constants$colors.red;
    const $t$16 = Constants$colors.yellow;
    const $t$17 = String$fromFloat($in$10 - $let$13);
    const $t$18 = String$fromFloat($in$10 - $let$13);
    if ($t$14 !== i$7.a0) {
      i$7.w0.setAttribute("stroke-width", $t$14);
      i$7.a0 = $t$14;
    }
    if ($t$15 !== i$7.a1) {
      i$7.w0.setAttribute("stroke", $t$15);
      i$7.a1 = $t$15;
    }
    if ($t$16 !== i$7.a2) {
      i$7.w0.setAttribute("fill", $t$16);
      i$7.a2 = $t$16;
    }
    if ($t$17 !== i$7.a3) {
      i$7.w0.setAttribute("height", $t$17);
      i$7.a3 = $t$17;
    }
    if ($t$18 !== i$7.a4) {
      i$7.w0.setAttribute("width", $t$18);
      i$7.a4 = $t$18;
    }
  }
  if ($in$9 !== i$7.g1_0 || $in$10 !== i$7.g1_1 || $in$11 !== i$7.g1_2) {
    i$7.g1_0 = $in$9;
    i$7.g1_1 = $in$10;
    i$7.g1_2 = $in$11;
    const $t$19 = String$fromFloat(Math$Vector2$getX($in$11) - $in$10 / 2 + $let$13 / 2);
    const $t$20 = String$fromFloat(Math$Vector2$getY($in$11) - $in$10 / 2 + $let$13 / 2);
    if ($t$19 !== i$7.a5) {
      i$7.w0.setAttribute("x", $t$19);
      i$7.a5 = $t$19;
    }
    if ($t$20 !== i$7.a6) {
      i$7.w0.setAttribute("y", $t$20);
      i$7.a6 = $t$20;
    }
  }
};
const Explosion$t161 = Rt$template("<svg><rect></svg>", 2);
const Explosion$k161 = { m: (v$21, cx$22) => {
  const r$23 = Explosion$t161();
  const i$24 = { s: r$23, q: null, e: r$23, w0: r$23, a0: undefined, a1: undefined, a2: undefined, a3: undefined, a4: undefined, a5: undefined, a6: undefined, l0_0: NaN, l0_1: NaN, d0: undefined, g0_0: NaN, g0_1: NaN, g1_0: NaN, g1_1: NaN, g1_2: NaN };
  Explosion$p161(i$24, v$21);
  return i$24;
}, p: Explosion$p161 };
const Explosion$forBike = (center$1) => ({ center: center$1, size: 30.0, ticksLeft: 15 });
const Explosion$toObstacle = (explosion$1) => {
  const $t$1 = Math$Vector2$toRecord(explosion$1.center);
  const x$2 = $t$1.x;
  const y$3 = $t$1.y;
  const r$4 = explosion$1.size / 2;
  const $t$2 = x$2 - r$4;
  const $t$3 = x$2 + r$4;
  const $t$4 = y$3 - r$4;
  const $t$5 = y$3 + r$4;
  return { e: $t$3, n: $t$4, s: $t$5, w: $t$2 };
};
const Explosion$explosionForm = ($p$6) => {
  const size$1 = $p$6.size;
  const ticksLeft$2 = $p$6.ticksLeft;
  const center$3 = $p$6.center;
  return { t: Explosion$k161, v: [ticksLeft$2, size$1, center$3] };
};
const Explosion$view = (explosions$1) => List$map(List$reverse(explosions$1), Explosion$explosionForm);
const Explosion$updateOne = (explosion$1) => ({ ...explosion$1, ticksLeft: explosion$1.ticksLeft - 1 });
const Explosion$update = (explosions$1) => List$filter(List$map(explosions$1, Explosion$updateOne), (explosion$2) => 0 !== explosion$2.ticksLeft);
export { Explosion$forBike, Explosion$toObstacle, Explosion$view, Explosion$update, Explosion$updateOne, Explosion$explosionForm };
//# sourceMappingURL=Explosion.mjs.map
