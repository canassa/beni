import { Task$chain, Task$isWaiting } from "./_core/Task.mjs";
import { Js$suspending } from "./_core/Js.mjs";
const JsSuspending$park = (v$1) => v$1;
function JsSuspending$inValue$resume1$1($t$1) {
  const n$2 = $t$1;
  return n$2 + 1;
}
const JsSuspending$inValue = (v$1) => {
  const $t$1 = v$1;
  if (Task$isWaiting($t$1)) {
    return Task$chain($t$1, JsSuspending$inValue$resume1$1.bind(null));
  }
  return JsSuspending$inValue$resume1$1($t$1);
};
function JsSuspending$discarded$resume1$1($t$1) {
  return 4;
}
const JsSuspending$discarded = (v$1) => {
  const $t$1 = v$1;
  if (Task$isWaiting($t$1)) {
    return Task$chain($t$1, JsSuspending$discarded$resume1$1.bind(null));
  }
  return JsSuspending$discarded$resume1$1($t$1);
};
const JsSuspending$passed = () => Js$suspending;
export { JsSuspending$park, JsSuspending$inValue, JsSuspending$discarded, JsSuspending$passed };
//# sourceMappingURL=JsSuspending.mjs.map
