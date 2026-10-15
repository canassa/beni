import { Math$Vector2$toRecord, Math$Vector2$vec2 } from "./Math/Vector2.mjs";
import { Constants$w, Constants$h } from "./Constants.mjs";
import { Maybe$withDefault } from "./_core/Maybe.mjs";
import { BikePhysics$collision } from "./BikePhysics.mjs";
const Weapon$Maybe$Nothing = { $: "Nothing", a: null };
const Weapon$initMegaBlaster = { $: "MegaBlaster", a: { used: false } };
const Weapon$initAssaultBazooka = { $: "AssaultBazooka", a: { shotsLeft: 3 } };
const Weapon$findArenaBorder = (direction$1, position$2) => {
  const $t$1 = Math$Vector2$toRecord(position$2);
  const x$3 = $t$1.x;
  const y$4 = $t$1.y;
  switch (direction$1) {
    case "North":
      {
        return Math$Vector2$vec2(x$3, 0);
      }
    case "East":
      {
        return Math$Vector2$vec2(Constants$w, y$4);
      }
    case "South":
      {
        return Math$Vector2$vec2(x$3, Constants$h);
      }
    default:
      {
        return Math$Vector2$vec2(0, y$4);
      }
  }
};
const Weapon$projectExplosionForwards = (direction$1, position$2, trail$3, explosion$4) => {
  const move$5 = { nextPosition: Weapon$findArenaBorder(direction$1, position$2), position: position$2 };
  const collisionPoint$6 = Maybe$withDefault(BikePhysics$collision(move$5, trail$3, []), move$5.nextPosition);
  return { ...explosion$4, center: collisionPoint$6 };
};
const Weapon$shootMegaBlaster = (direction$1, position$2, trail$3, state$4) => ({ a: { $: "MegaBlaster", a: { used: true } }, b: state$4.used ? Weapon$Maybe$Nothing : { $: "Just", a: Weapon$projectExplosionForwards(direction$1, position$2, trail$3, { center: Math$Vector2$vec2(0, 0), size: 50, ticksLeft: 10 }) } });
const Weapon$shootAssaultBazooka = (direction$1, position$2, trail$3, state$4) => state$4.shotsLeft <= 0 ? { a: { $: "AssaultBazooka", a: state$4 }, b: Weapon$Maybe$Nothing } : { a: { $: "AssaultBazooka", a: { shotsLeft: state$4.shotsLeft - 1 } }, b: { $: "Just", a: Weapon$projectExplosionForwards(direction$1, position$2, trail$3, { center: Math$Vector2$vec2(0, 0), size: 20, ticksLeft: 10 }) } };
const Weapon$shoot = ($p$2, trail$4) => {
  const weapon$1 = $p$2.weapon;
  const direction$2 = $p$2.direction;
  const position$3 = $p$2.position;
  switch (weapon$1.$) {
    case "MegaBlaster":
      {
        const state$5 = weapon$1.a;
        return Weapon$shootMegaBlaster(direction$2, position$3, trail$4, state$5);
      }
    case "AssaultBazooka":
      {
        const state$6 = weapon$1.a;
        return Weapon$shootAssaultBazooka(direction$2, position$3, trail$4, state$6);
      }
    default:
      {
        const other$7 = weapon$1;
        return { a: other$7, b: Weapon$Maybe$Nothing };
      }
  }
};
export { Weapon$initMegaBlaster, Weapon$initAssaultBazooka, Weapon$shoot, Weapon$shootMegaBlaster, Weapon$shootAssaultBazooka };
//# sourceMappingURL=Weapon.mjs.map
