import { Constants$speedC } from "./Constants.mjs";
import { Math$Vector2$vec2, Math$Vector2$add } from "./Math/Vector2.mjs";
import { Keyboard$Key$$eq } from "./Keyboard.mjs";
import { Direction$turnLeft, Direction$turnRight } from "./Direction.mjs";
import { Helpers$trailToLines, Helpers$toLine, Helpers$tryObstacleCollision, Helpers$tryCollision, Helpers$horizontalOrthogonal, Helpers$onlyVertical, Helpers$verticalOrthogonal, Helpers$onlyHorizontal } from "./Helpers.mjs";
import { List$head, List$filterMap } from "./_core/List.mjs";
const BikePhysics$Maybe$Nothing = { $: "Nothing", a: null };
const BikePhysics$computePosition = (direction$1, position$2, diff$3) => {
  const c$4 = Constants$speedC * diff$3;
  let $t$1;
  $c$0: {
    switch (direction$1) {
      case "North":
        {
          $t$1 = Math$Vector2$vec2(0, 0 - c$4);
          break $c$0;
        }
      case "East":
        {
          $t$1 = Math$Vector2$vec2(c$4, 0);
          break $c$0;
        }
      case "South":
        {
          $t$1 = Math$Vector2$vec2(0, c$4);
          break $c$0;
        }
      default:
        {
          $t$1 = Math$Vector2$vec2(0 - c$4, 0);
          break $c$0;
        }
    }
  }
  const change$5 = $t$1;
  return Math$Vector2$add(position$2, change$5);
};
const BikePhysics$computeDirection = (controls$1, direction$2, key$3) => {
  if (Keyboard$Key$$eq(key$3, controls$1.left)) {
    return Direction$turnLeft(direction$2);
  } else {
    return Keyboard$Key$$eq(key$3, controls$1.right) ? Direction$turnRight(direction$2) : direction$2;
  }
};
const BikePhysics$collision = ($p$2, trail$3, obstacles$4) => {
  const position$1 = $p$2.position;
  const nextPosition$2 = $p$2.nextPosition;
  const lines$5 = Helpers$trailToLines(trail$3);
  const moveLine$6 = Helpers$toLine(position$1, nextPosition$2);
  function $try$7(maybeOne$8, maybeTwo$9) {
    if (maybeOne$8.$ === "Just") {
      const collision_$10 = maybeOne$8.a;
      return { $: "Just", a: collision_$10 };
    } else {
      return maybeTwo$9;
    }
  }
  if (moveLine$6.$ === "Just") {
    if (moveLine$6.a.$ === "Horizontal") {
      const points$11 = moveLine$6.a.a;
      return $try$7(List$head(List$filterMap(obstacles$4, ($p$3) => Helpers$tryObstacleCollision(points$11, $p$3))), Helpers$tryCollision(($p$4) => Helpers$horizontalOrthogonal(points$11, $p$4), List$filterMap(lines$5, Helpers$onlyVertical)));
    } else {
      const points$14 = moveLine$6.a.a;
      return $try$7(List$head(List$filterMap(obstacles$4, ($p$5) => Helpers$tryObstacleCollision(points$14, $p$5))), Helpers$tryCollision(($p$6) => Helpers$verticalOrthogonal(points$14, $p$6), List$filterMap(lines$5, Helpers$onlyHorizontal)));
    }
  } else {
    return BikePhysics$Maybe$Nothing;
  }
};
export { BikePhysics$computePosition, BikePhysics$computeDirection, BikePhysics$collision };
//# sourceMappingURL=BikePhysics.mjs.map
