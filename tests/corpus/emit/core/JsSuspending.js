import { Task$andThen } from "./_core/Task.mjs";
import { Js$suspending } from "./_core/Js.mjs";
const JsSuspending$park = (v$1) => v$1;
const JsSuspending$inValue = (v$1) => Task$andThen(v$1, ($t$1) => {
  const n$2 = $t$1;
  return n$2 + 1;
});
const JsSuspending$discarded = (v$1) => Task$andThen(v$1, ($t$2) => 4);
const JsSuspending$passed = () => Js$suspending;
export { JsSuspending$park, JsSuspending$inValue, JsSuspending$discarded, JsSuspending$passed };
//# sourceMappingURL=JsSuspending.mjs.map
