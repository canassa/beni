import { deep as _derived$deep } from "./_core/_derived.mjs";
import { Bike$initBike, Bike$update, Bike$shoot, Bike$turn, Bike$view } from "./Bike.mjs";
import { Constants$colors, Constants$h, Constants$w, Constants$bikeSize } from "./Constants.mjs";
import { Math$Vector2$vec2, Math$Vector2$Vec2$$eq } from "./Math/Vector2.mjs";
import { Weapon$initMegaBlaster, Weapon$initAssaultBazooka } from "./Weapon.mjs";
import { Cmd$none } from "./_platform/_browser/Cmd.mjs";
import { List$eq, List$append, List$filterMap, List$map } from "./_core/List.mjs";
import { Browser$Events$onAnimationFrameDelta } from "./_platform/_browser/Browser/Events.mjs";
import { Keyboard$oneOf, Keyboard$whitespaceKey, Keyboard$downs } from "./Keyboard.mjs";
import { Keyboard$Arrows$arrowKey } from "./Keyboard/Arrows.mjs";
import { Sub$batch } from "./_platform/_browser/Sub.mjs";
import { Explosion$update, Explosion$view } from "./Explosion.mjs";
import { Basics$identity, Basics$append } from "./_core/Basics.mjs";
import { Maybe$withDefault, Maybe$map } from "./_core/Maybe.mjs";
import { String$fromFloat, String$join } from "./_core/String.mjs";
import { Rt$template, Rt$text, Rt$childHtml, Rt$restate, Rt$slot, Rt$childList } from "./_platform/_browser/Rt.mjs";
const Game$Draw = { $: "Draw", a: null };
const Game$Keyboard$ArrowLeft = { $: "ArrowLeft", a: null };
const Game$Keyboard$ArrowRight = { $: "ArrowRight", a: null };
const Game$Keyboard$ArrowUp = { $: "ArrowUp", a: null };
const Game$NewGame = { $: "NewGame", a: null };
const Game$Running = { $: "Running", a: null };
const Game$p433 = (i$21, v$22) => {
  if (i$21.g0 === undefined) {
    i$21.g0 = true;
    const $t$23 = String$fromFloat(Constants$w);
    const $t$24 = String$fromFloat(Constants$h);
    if ($t$23 !== i$21.a0) {
      i$21.w0.setAttribute("width", $t$23);
      i$21.a0 = $t$23;
    }
    if ($t$24 !== i$21.a1) {
      i$21.w0.setAttribute("height", $t$24);
      i$21.a1 = $t$24;
    }
  }
};
const Game$t433 = Rt$template("<svg><rect fill=rgba(0,0,0,0.5)></svg>", 2);
const Game$k433 = { m: (v$25, cx$26) => {
  const r$27 = Game$t433();
  const i$28 = { s: r$27, q: null, e: r$27, w0: r$27, a0: undefined, a1: undefined, g0: undefined };
  Game$p433(i$28, v$25);
  return i$28;
}, p: Game$p433 };
const Game$b433 = { t: Game$k433, v: null };
const Game$p463 = (i$29, v$30) => {
  const $in$31 = v$30[0];
  const $in$32 = v$30[1];
  if (i$29.g0 === undefined) {
    i$29.g0 = true;
    const $t$33 = String$fromFloat(Constants$w / 2);
    const $t$34 = String$fromFloat(Constants$h / 2);
    const $t$35 = Constants$colors.white;
    if ($t$33 !== i$29.a0) {
      i$29.w0.setAttribute("x", $t$33);
      i$29.a0 = $t$33;
    }
    if ($t$34 !== i$29.a1) {
      i$29.w0.setAttribute("y", $t$34);
      i$29.a1 = $t$34;
    }
    if ($t$35 !== i$29.a2) {
      i$29.w0.setAttribute("fill", $t$35);
      i$29.a2 = $t$35;
    }
  }
  const x$36 = $in$31;
  if (x$36 !== i$29.g1_0) {
    i$29.g1_0 = x$36;
    const $t$37 = Basics$append("translate(", Basics$append(String$fromFloat($in$31), ", -10)"));
    if ($t$37 !== i$29.a3) {
      i$29.w0.setAttribute("transform", $t$37);
      i$29.a3 = $t$37;
    }
  }
  const x$38 = $in$32;
  if (x$38 !== i$29.g2_0) {
    i$29.g2_0 = x$38;
    const $t$39 = Rt$text($in$32);
    Rt$childHtml(i$29.c4, $t$39);
  } else {
    Rt$restate(i$29.c4);
  }
  i$29.l = i$29.c4.l;
};
const Game$t463 = Rt$template("<svg><text font-size=20 font-family=monospace></svg>", 2);
const Game$k463 = { m: (v$40, cx$41) => {
  const r$42 = Game$t463();
  const c$43 = Rt$slot(r$42, null, cx$41);
  const i$44 = { s: r$42, q: null, e: r$42, w0: r$42, c4: c$43, a0: undefined, a1: undefined, a2: undefined, a3: undefined, g0: undefined, g1_0: NaN, g2_0: NaN };
  Game$p463(i$44, v$40);
  return i$44;
}, p: Game$p463, l: true };
const Game$p535 = (i$45, v$46) => {
  if (i$45.g0 === undefined) {
    i$45.g0 = true;
    const $t$47 = String$fromFloat(Constants$w);
    const $t$48 = String$fromFloat(Constants$h);
    const $t$49 = Constants$colors.grey;
    const $t$50 = String$fromFloat(Constants$bikeSize);
    const $t$51 = Constants$colors.blue;
    if ($t$47 !== i$45.a0) {
      i$45.w0.setAttribute("width", $t$47);
      i$45.a0 = $t$47;
    }
    if ($t$48 !== i$45.a1) {
      i$45.w0.setAttribute("height", $t$48);
      i$45.a1 = $t$48;
    }
    if ($t$49 !== i$45.a2) {
      i$45.w0.setAttribute("stroke", $t$49);
      i$45.a2 = $t$49;
    }
    if ($t$50 !== i$45.a3) {
      i$45.w0.setAttribute("stroke-width", $t$50);
      i$45.a3 = $t$50;
    }
    if ($t$51 !== i$45.a4) {
      i$45.w0.setAttribute("fill", $t$51);
      i$45.a4 = $t$51;
    }
  }
};
const Game$t535 = Rt$template("<svg><rect></svg>", 2);
const Game$k535 = { m: (v$52, cx$53) => {
  const r$54 = Game$t535();
  const i$55 = { s: r$54, q: null, e: r$54, w0: r$54, a0: undefined, a1: undefined, a2: undefined, a3: undefined, a4: undefined, g0: undefined };
  Game$p535(i$55, v$52);
  return i$55;
}, p: Game$p535 };
const Game$b535 = { t: Game$k535, v: null };
const Game$p538 = (i$56, v$57) => {
  if (i$56.g0 === undefined) {
    i$56.g0 = true;
    const $t$58 = Constants$colors.white;
    if ($t$58 !== i$56.a0) {
      i$56.w0.setAttribute("fill", $t$58);
      i$56.a0 = $t$58;
    }
  }
};
const Game$t538 = Rt$template("<svg><text x=10 y=30 font-size=20 font-family=monospace>Bike Wars</svg>", 2);
const Game$k538 = { m: (v$59, cx$60) => {
  const r$61 = Game$t538();
  const i$62 = { s: r$61, q: null, e: r$61, w0: r$61, a0: undefined, g0: undefined };
  Game$p538(i$62, v$59);
  return i$62;
}, p: Game$p538 };
const Game$b538 = { t: Game$k538, v: null };
const Game$p414 = (i$63, v$64) => {
  const $in$65 = v$64[0];
  if (i$63.g0 === undefined) {
    i$63.g0 = true;
    const $t$66 = Constants$colors.grey;
    const $t$67 = String$join(List$map([0, 0, Constants$w, Constants$h], String$fromFloat), " ");
    if ($t$66 !== i$63.a0) {
      i$63.a0 = $t$66;
      i$63.w0.style.setProperty("background-color", $t$66);
    }
    if ($t$67 !== i$63.a1) {
      i$63.w1.setAttribute("viewBox", $t$67);
      i$63.a1 = $t$67;
    }
  }
  if ($in$65.bikes.red !== i$63.g1_0 || $in$65.bikes.green !== i$63.g1_1 || $in$65.explosions !== i$63.g1_2 || $in$65.status !== i$63.g1_3) {
    i$63.g1_0 = $in$65.bikes.red;
    i$63.g1_1 = $in$65.bikes.green;
    i$63.g1_2 = $in$65.explosions;
    i$63.g1_3 = $in$65.status;
    const $t$68 = Game$svgView($in$65);
    Rt$childList(i$63.c2, $t$68);
  } else {
    Rt$restate(i$63.c2);
  }
  i$63.l = i$63.c2.w;
};
const Game$t414 = Rt$template("<div><svg style=\"height:100vh;display:block;margin:0 auto\">", 0);
const Game$k414 = { m: (v$69, cx$70) => {
  const r$71 = Game$t414();
  const w$72 = r$71.firstChild;
  const c$73 = Rt$slot(w$72, null, cx$70);
  const i$74 = { s: r$71, q: null, e: r$71, w0: r$71, w1: w$72, c2: c$73, a0: undefined, a1: undefined, g0: undefined, g1_0: NaN, g1_1: NaN, g1_2: NaN, g1_3: NaN };
  Game$p414(i$74, v$69);
  return i$74;
}, p: Game$p414, l: true };
const Game$eq$prim = ($x, $y) => $x === $y;
const Game$eq$r$center$size$ticksLeft = ($m$0, $m$1, $m$2, $x, $y, $d = 0) => {
  if ($d > 400) {
    return _derived$deep(Game$eq$r$center$size$ticksLeft$$steps($m$0, $m$1, $m$2, $x, $y), $d);
  }
  return $m$0($x.center, $y.center, $d + 1) && $m$1($x.size, $y.size, $d + 1) && $m$2($x.ticksLeft, $y.ticksLeft, $d + 1);
};
function* Game$eq$r$center$size$ticksLeft$$steps($m$0, $m$1, $m$2, $x, $y) {
  let $e;
  $e = $m$0($x.center, $y.center, 2**30);
  if (typeof $e === "object") {
    $e = yield $e;
  }
  if (!$e) {
    return false;
  }
  $e = $m$1($x.size, $y.size, 2**30);
  if (typeof $e === "object") {
    $e = yield $e;
  }
  if (!$e) {
    return false;
  }
  return $m$2($x.ticksLeft, $y.ticksLeft, 2**30);
}
const Game$initBikes = (() => {
  const $t$1 = Bike$initBike({ left: { $: "Character", a: "a" }, right: { $: "Character", a: "d" }, up: { $: "Character", a: "w" } }, Constants$colors.red, Math$Vector2$vec2(20, Constants$h / 5 * 2), "East", Weapon$initMegaBlaster);
  const $t$2 = Bike$initBike({ left: Game$Keyboard$ArrowLeft, right: Game$Keyboard$ArrowRight, up: Game$Keyboard$ArrowUp }, Constants$colors.green, Math$Vector2$vec2(Constants$w - 20, Constants$h / 5 * 3), "West", Weapon$initAssaultBazooka);
  return { green: $t$2, red: $t$1 };
})();
const Game$initModel = { bikes: Game$initBikes, explosions: [], status: Game$NewGame };
const Game$init = { a: Game$initModel, b: Cmd$none };
const Game$subscriptions = (model$1) => {
  const $t$3 = model$1.status;
  const $t$7 = List$eq(($p$4, $p$5, $p$6) => Game$eq$r$center$size$ticksLeft(Math$Vector2$Vec2$$eq, Game$eq$prim, Game$eq$prim, $p$4, $p$5, $p$6), model$1.explosions, []);
  let $t$8;
  $c$0: {
    $j$0$2: {
      switch ($t$3.$) {
        case "Running":
          {
            $t$8 = true;
            break $c$0;
          }
        case "GameOver":
          {
            if (!$t$7) {
              $t$8 = true;
              break $c$0;
            } else {
              break $j$0$2;
            }
          }
        default:
          {
            break $j$0$2;
          }
      }
    }
    $t$8 = false;
  }
  const needsToAnimate$2 = $t$8;
  const ticks$3 = needsToAnimate$2 ? [Browser$Events$onAnimationFrameDelta(($x$9) => ({ $: "TimeDiff", a: $x$9 }))] : [];
  const keyParser$4 = ($p$10) => Keyboard$oneOf([Keyboard$Arrows$arrowKey, Keyboard$whitespaceKey], $p$10);
  return Sub$batch(List$append([Keyboard$downs((rawKey$6) => ({ $: "KeyDown", a: keyParser$4(rawKey$6) }))], ticks$3));
};
const Game$stepGame = ($p$11, diff$3) => {
  const bikes$1 = $p$11.bikes;
  const model$2 = $p$11;
  const explosions$4 = Explosion$update(model$2.explosions);
  const $t$12 = { a: Bike$update(diff$3, explosions$4, { current: bikes$1.red, other: bikes$1.green }), b: Bike$update(diff$3, explosions$4, { current: bikes$1.green, other: bikes$1.red }) };
  const nextRed$5 = $t$12.a.a;
  const expRed$6 = $t$12.a.b;
  const nextGreen$7 = $t$12.b.a;
  const expGreen$8 = $t$12.b.b;
  const nextExplosions$9 = List$append(List$filterMap([expRed$6, expGreen$8], Basics$identity), explosions$4);
  const allCollided$10 = nextRed$5.collided && nextGreen$7.collided;
  let $t$13;
  if (allCollided$10) {
    $t$13 = { $: "GameOver", a: Game$Draw };
  } else {
    let $t$14;
    if (nextRed$5.collided) {
      $t$14 = { $: "GameOver", a: { $: "GameWon", a: "PlayerGreen" } };
    } else {
      $t$14 = nextGreen$7.collided ? { $: "GameOver", a: { $: "GameWon", a: "PlayerRed" } } : Game$Running;
    }
    $t$13 = $t$14;
  }
  const status$11 = $t$13;
  return { ...model$2, bikes: { green: nextGreen$7, red: nextRed$5 }, status: status$11, explosions: nextExplosions$9 };
};
const Game$handleInput = (model$1, key$2) => {
  if (model$1.status.$ === "Running") {
    const $t$15 = model$1.bikes;
    const red$3 = $t$15.red;
    const green$4 = $t$15.green;
    const $t$16 = Bike$shoot(key$2, { current: red$3, other: green$4 });
    const redUpdated$5 = $t$16.a;
    const redShot$6 = $t$16.b;
    const $t$17 = Bike$shoot(key$2, { current: green$4, other: red$3 });
    const greenUpdated$7 = $t$17.a;
    const greenShot$8 = $t$17.b;
    const shots$9 = List$filterMap([redShot$6, greenShot$8], Basics$identity);
    const $t$18 = Bike$turn(key$2, redUpdated$5);
    const $t$19 = Bike$turn(key$2, greenUpdated$7);
    return { ...model$1, bikes: { green: $t$19, red: $t$18 }, explosions: List$append(shots$9, model$1.explosions) };
  } else {
    return key$2.$ === "Spacebar" ? { ...Game$initModel, status: Game$Running } : model$1;
  }
};
const Game$pureUpdate = (msg$1, model$2) => {
  if (msg$1.$ === "TimeDiff") {
    const diff$3 = msg$1.a;
    return Game$stepGame(model$2, diff$3);
  } else {
    const maybeKey$4 = msg$1.a;
    return Maybe$withDefault(Maybe$map(maybeKey$4, ($p$20) => Game$handleInput(model$2, $p$20)), model$2);
  }
};
const Game$update = (msg$1, model$2) => ({ a: Game$pureUpdate(msg$1, model$2), b: Cmd$none });
const Game$svgView = (model$1) => {
  const translucentRect$2 = Game$b433;
  function makeOverlay$3(string$6, xOffset$7) {
    return [translucentRect$2, { t: Game$k463, v: [xOffset$7, string$6] }];
  }
  function endOverlay$4(state$8) {
    return state$8.$ === "GameWon" ? state$8.a === "PlayerRed" ? makeOverlay$3("Red wins!", 0 - 50) : makeOverlay$3("Green wins!", 0 - 70) : makeOverlay$3("It's a draw.", 0 - 70);
  }
  function overlay$5(status$9) {
    switch (status$9.$) {
      case "NewGame":
        {
          return makeOverlay$3("[SPACE], [⇦][⇨]", 0 - 90);
        }
      case "Running":
        {
          return [];
        }
      default:
        {
          const endState$10 = status$9.a;
          return endOverlay$4(endState$10);
        }
    }
  }
  return List$append([Game$b535, Game$b538], List$append(Bike$view(model$1.bikes.red), List$append(Bike$view(model$1.bikes.green), List$append(Explosion$view(model$1.explosions), overlay$5(model$1.status)))));
};
const Game$view = (model$1) => ({ t: Game$k414, v: [model$1] });
export { Game$initBikes, Game$initModel, Game$init, Game$subscriptions, Game$update, Game$pureUpdate, Game$stepGame, Game$view, Game$svgView };
//# sourceMappingURL=Game.mjs.map
