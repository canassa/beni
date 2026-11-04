import { Js$Any$pack, Js$Any$unpackOpt } from "./_core/Js/Any.mjs";
import { Js$optNone, Js$some } from "./_core/Js.mjs";
const AnyUnpackOpt$integer = (value$1) => {
  const $t$1 = value$1[Js$Any$pack.$packet.key];
  return ($t$1 !== undefined ? $t$1 === "core:Basics.Int" : value$1.type === "core:Basics.Int") ? $t$1 !== undefined ? value$1 : value$1.value : Js$optNone;
};
const AnyUnpackOpt$generic = ($m$0, value$1) => {
  const $t$1 = value$1[Js$Any$pack.$packet.key];
  return ($t$1 !== undefined ? $t$1 === $m$0 : value$1.type === $m$0) ? Js$some($t$1 !== undefined ? value$1 : value$1.value) : Js$optNone;
};
const AnyUnpackOpt$nested = (value$1) => {
  const $t$1 = value$1[Js$Any$pack.$packet.key];
  return ($t$1 !== undefined ? $t$1 === "core:Js.Opt(core:Basics.Int)" : value$1.type === "core:Js.Opt(core:Basics.Int)") ? Js$some($t$1 !== undefined ? value$1 : value$1.value) : Js$optNone;
};
const AnyUnpackOpt$firstClass = ($p$1) => Js$Any$unpackOpt("core:Basics.Int", $p$1);
const AnyUnpackOpt$packet$$packet$1 = { [Js$Any$pack.$packet.key]: "{value=core:Basics.Int}", value: undefined };
const AnyUnpackOpt$packet = (number$1) => {
  const $t$1 = { ...AnyUnpackOpt$packet$$packet$1, value: number$1 };
  const $t$2 = $t$1[Js$Any$pack.$packet.key];
  return ($t$2 !== undefined ? $t$2 === "{value=core:Basics.Int}" : $t$1.type === "{value=core:Basics.Int}") ? $t$2 !== undefined ? $t$1 : $t$1.value : Js$optNone;
};
export { AnyUnpackOpt$integer, AnyUnpackOpt$generic, AnyUnpackOpt$nested, AnyUnpackOpt$firstClass, AnyUnpackOpt$packet };
//# sourceMappingURL=AnyUnpackOpt.mjs.map
