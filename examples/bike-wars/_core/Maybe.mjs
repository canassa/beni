import { deep as _derived$deep } from "../_core/_derived.mjs";
const Maybe$Nothing = { $: "Nothing", a: null };
const Maybe$Maybe$$eq = ($m$0, $x, $y, $d = 0) => {
  if ($x.$ !== $y.$) {
    return false;
  }
  switch ($x.$) {
    case "Just":
      return $d > 400 ? _derived$deep([$m$0, $x.a, $y.a], $d) : $m$0($x.a, $y.a, $d + 1);
    default:
      return true;
  }
};
const Maybe$withDefault = (maybe$1, $default$2) => {
  if (maybe$1.$ === "Just") {
    const value$3 = maybe$1.a;
    return value$3;
  } else {
    return $default$2;
  }
};
const Maybe$map = (maybe$1, func$2) => {
  if (maybe$1.$ === "Just") {
    const value$3 = maybe$1.a;
    return { $: "Just", a: func$2(value$3) };
  } else {
    return Maybe$Nothing;
  }
};
export { Maybe$Maybe$$eq, Maybe$withDefault, Maybe$map };
//# sourceMappingURL=Maybe.mjs.map
