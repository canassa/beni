import { Basics$append } from "./_core/Basics.mjs";
const NestingShapes$short = { $: 1, a: 1, b: { $: 1, a: 2, b: { $: 1, a: 3, b: { $: 1, a: 4, b: { $: 1, a: 5, b: { $: 1, a: 6, b: { $: 1, a: 7, b: { $: 1, a: 8, b: { $: 1, a: 9, b: { $: 1, a: 10, b: { $: 1, a: 11, b: { $: 1, a: 12, b: { $: 1, a: 13, b: { $: 1, a: 14, b: { $: 1, a: 15, b: { $: 1, a: 16, b: { $: 1, a: 17, b: { $: 1, a: 18, b: { $: 1, a: 19, b: { $: 1, a: 20, b: { $: 1, a: 21, b: { $: 1, a: 22, b: { $: 1, a: 23, b: { $: 1, a: 24, b: { $: 1, a: 25, b: { $: 1, a: 26, b: { $: 1, a: 27, b: { $: 1, a: 28, b: { $: 1, a: 29, b: { $: 1, a: 30, b: { $: 1, a: 31, b: { $: 1, a: 32, b: { $: 0, a: null, b: null } } } } } } } } } } } } } } } } } } } } } } } } } } } } } } } } };
const NestingShapes$long = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33].reduceRight(($l$1, $h$2) => ({ $: 1, a: $h$2, b: $l$1 }), { $: 0, a: null, b: null });
const NestingShapes$every = (a$1, b$2, c$3, d$4) => a$1 && b$2 && c$3 && d$4;
const NestingShapes$pick = (k$1) => {
  let $t$3;
  $c$0: {
    if (k$1 === 1) {
      $t$3 = "1";
      break $c$0;
    }
    if (k$1 === 2) {
      $t$3 = "2";
      break $c$0;
    }
    if (k$1 === 3) {
      $t$3 = "3";
      break $c$0;
    }
    if (k$1 === 4) {
      $t$3 = "4";
      break $c$0;
    }
    if (k$1 === 5) {
      $t$3 = "5";
      break $c$0;
    }
    if (k$1 === 6) {
      $t$3 = "6";
      break $c$0;
    }
    if (k$1 === 7) {
      $t$3 = "7";
      break $c$0;
    }
    if (k$1 === 8) {
      $t$3 = "8";
      break $c$0;
    }
    if (k$1 === 9) {
      $t$3 = "9";
      break $c$0;
    }
    if (k$1 === 10) {
      $t$3 = "10";
      break $c$0;
    }
    if (k$1 === 11) {
      $t$3 = "11";
      break $c$0;
    }
    if (k$1 === 12) {
      $t$3 = "12";
      break $c$0;
    }
    if (k$1 === 13) {
      $t$3 = "13";
      break $c$0;
    }
    if (k$1 === 14) {
      $t$3 = "14";
      break $c$0;
    }
    if (k$1 === 15) {
      $t$3 = "15";
      break $c$0;
    }
    $t$3 = k$1 === 16 ? "16" : "many";
  }
  const name$2 = $t$3;
  return Basics$append(name$2, "!");
};
export { NestingShapes$short, NestingShapes$long, NestingShapes$every, NestingShapes$pick };
