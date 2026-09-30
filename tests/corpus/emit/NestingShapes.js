import { Basics$append } from "./_core/Basics.mjs";
const NestingShapes$short = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32];
const NestingShapes$long = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33];
const NestingShapes$every = (a$1, b$2, c$3, d$4) => a$1 && b$2 && c$3 && d$4;
const NestingShapes$pick = (k$1) => {
  let $t$1;
  $c$0: {
    if (k$1 === 1) {
      $t$1 = "1";
      break $c$0;
    }
    if (k$1 === 2) {
      $t$1 = "2";
      break $c$0;
    }
    if (k$1 === 3) {
      $t$1 = "3";
      break $c$0;
    }
    if (k$1 === 4) {
      $t$1 = "4";
      break $c$0;
    }
    if (k$1 === 5) {
      $t$1 = "5";
      break $c$0;
    }
    if (k$1 === 6) {
      $t$1 = "6";
      break $c$0;
    }
    if (k$1 === 7) {
      $t$1 = "7";
      break $c$0;
    }
    if (k$1 === 8) {
      $t$1 = "8";
      break $c$0;
    }
    if (k$1 === 9) {
      $t$1 = "9";
      break $c$0;
    }
    if (k$1 === 10) {
      $t$1 = "10";
      break $c$0;
    }
    if (k$1 === 11) {
      $t$1 = "11";
      break $c$0;
    }
    if (k$1 === 12) {
      $t$1 = "12";
      break $c$0;
    }
    if (k$1 === 13) {
      $t$1 = "13";
      break $c$0;
    }
    if (k$1 === 14) {
      $t$1 = "14";
      break $c$0;
    }
    if (k$1 === 15) {
      $t$1 = "15";
      break $c$0;
    }
    $t$1 = k$1 === 16 ? "16" : "many";
  }
  const name$2 = $t$1;
  return Basics$append(name$2, "!");
};
export { NestingShapes$short, NestingShapes$long, NestingShapes$every, NestingShapes$pick };
