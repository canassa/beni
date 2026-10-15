import { Keyboard$rawValue } from "../Keyboard.mjs";
import { String$toLower } from "../_core/String.mjs";
const Keyboard$Arrows$Keyboard$ArrowDown = { $: "ArrowDown", a: null };
const Keyboard$Arrows$Keyboard$ArrowLeft = { $: "ArrowLeft", a: null };
const Keyboard$Arrows$Keyboard$ArrowRight = { $: "ArrowRight", a: null };
const Keyboard$Arrows$Keyboard$ArrowUp = { $: "ArrowUp", a: null };
const Keyboard$Arrows$Maybe$Nothing = { $: "Nothing", a: null };
const Keyboard$Arrows$arrowKey = (rawKey$1) => {
  const $t$1 = Keyboard$rawValue(rawKey$1);
  switch ($t$1) {
    case "ArrowDown":
      {
        return { $: "Just", a: Keyboard$Arrows$Keyboard$ArrowDown };
      }
    case "ArrowLeft":
      {
        return { $: "Just", a: Keyboard$Arrows$Keyboard$ArrowLeft };
      }
    case "ArrowRight":
      {
        return { $: "Just", a: Keyboard$Arrows$Keyboard$ArrowRight };
      }
    case "ArrowUp":
      {
        return { $: "Just", a: Keyboard$Arrows$Keyboard$ArrowUp };
      }
    case "Down":
      {
        return { $: "Just", a: Keyboard$Arrows$Keyboard$ArrowDown };
      }
    case "Left":
      {
        return { $: "Just", a: Keyboard$Arrows$Keyboard$ArrowLeft };
      }
    case "Right":
      {
        return { $: "Just", a: Keyboard$Arrows$Keyboard$ArrowRight };
      }
    case "Up":
      {
        return { $: "Just", a: Keyboard$Arrows$Keyboard$ArrowUp };
      }
    default:
      {
        const other$2 = $t$1;
        const lower$3 = String$toLower(other$2);
        return lower$3 === "w" || lower$3 === "a" || lower$3 === "s" || lower$3 === "d" ? { $: "Just", a: { $: "Character", a: other$2 } } : Keyboard$Arrows$Maybe$Nothing;
      }
  }
};
export { Keyboard$Arrows$arrowKey };
//# sourceMappingURL=Arrows.mjs.map
