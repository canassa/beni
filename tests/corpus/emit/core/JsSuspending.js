import { Task$chain, Task$continueWith } from "./_core/Task.mjs";
import { Js$suspending } from "./_core/Js.mjs";
const JsSuspending$park = (v$1, $resume$1) => v$1;
const JsSuspending$inValue = (v$1, $resume$1) => {
  const $resume$2 = ($t$1) => {
    const n$2 = $t$1;
    return n$2 + 1;
  };
  return Task$chain((() => v$1)(($t$1) => Task$continueWith($resume$2, $t$1, $resume$1)), $resume$2, $resume$1);
};
const JsSuspending$discarded = (v$1, $resume$1) => {
  const $resume$2 = ($t$1) => 4;
  return Task$chain((() => v$1)(($t$1) => Task$continueWith($resume$2, $t$1, $resume$1)), $resume$2, $resume$1);
};
const JsSuspending$passed = () => Js$suspending;
export { JsSuspending$park, JsSuspending$inValue, JsSuspending$discarded, JsSuspending$passed };
//# sourceMappingURL=JsSuspending.mjs.map
