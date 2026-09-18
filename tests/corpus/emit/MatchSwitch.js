import { Basics$mul } from "./core/Basics.mjs";
import { Node$printLines } from "./platform/Node.mjs";
const MatchSwitch$Colour$$order = { Red: 0, Green: 1, Blue: 2 };
const MatchSwitch$Size$$order = { Small: 0, Medium: 1, Large: 2 };
const MatchSwitch$Colour$$compare = ($x, $y) => {
  const $a = MatchSwitch$Colour$$order[$x];
  const $b = MatchSwitch$Colour$$order[$y];
  return $a === $b ? "EQ" : $a < $b ? "LT" : "GT";
};
const MatchSwitch$Colour$$eq = ($x, $y) => $x === $y;
const MatchSwitch$Size$$compare = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return MatchSwitch$Size$$order[$x.$] < MatchSwitch$Size$$order[$y.$] ? "LT" : "GT";
  }
  switch ($x.$) {
    case "Small":
      return $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
    case "Medium":
      return $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
    default:
      return $x.a < $y.a ? "LT" : $x.a > $y.a ? "GT" : "EQ";
  }
};
const MatchSwitch$Size$$eq = ($x, $y) => {
  if ($x.$ !== $y.$) {
    return false;
  }
  switch ($x.$) {
    case "Small":
      return $x.a === $y.a;
    case "Medium":
      return $x.a === $y.a;
    default:
      return $x.a === $y.a;
  }
};
const MatchSwitch$name = (colour$1) => {
  switch (colour$1) {
    case "Red":
      {
        return "red";
      }
    case "Green":
      {
        return "green";
      }
    default:
      {
        return "blue";
      }
  }
};
const MatchSwitch$toggle = (flag$1) => flag$1 ? "on" : "off";
const MatchSwitch$measure = (size$1) => {
  switch (size$1.$) {
    case "Small":
      {
        const n$2 = size$1.a;
        return n$2;
      }
    case "Medium":
      {
        const n$3 = size$1.a;
        return Basics$mul(n$3, 2);
      }
    default:
      {
        const n$4 = size$1.a;
        return Basics$mul(n$4, 3);
      }
  }
};
const MatchSwitch$weekday = (n$1) => {
  switch (n$1) {
    case 0:
      {
        return "Sun";
      }
    case 1:
      {
        return "Mon";
      }
    case 2:
      {
        return "Tue";
      }
    default:
      {
        return "later";
      }
  }
};
const MatchSwitch$main = Node$printLines({ $: 0, a: null, b: null });
export { MatchSwitch$Colour$$compare, MatchSwitch$Colour$$eq, MatchSwitch$Size$$compare, MatchSwitch$Size$$eq, MatchSwitch$main, MatchSwitch$name, MatchSwitch$toggle, MatchSwitch$measure, MatchSwitch$weekday };
