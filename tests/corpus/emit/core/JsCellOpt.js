import { Js$optNone } from "./_core/Js.mjs";
const JsCellOpt$make = (value$1) => ({ next: Js$optNone, state: value$1 });
const JsCellOpt$store = (cell$1, value$2) => {
  cell$1.state = value$2;
  cell$1.next = value$2;
  const $t$1 = cell$1.next;
  const $t$2 = cell$1.state;
  return $t$1 !== Js$optNone ? $t$1 : $t$2;
};
export { JsCellOpt$make, JsCellOpt$store };
//# sourceMappingURL=JsCellOpt.mjs.map
