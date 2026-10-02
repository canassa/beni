import { Task$andThen } from "./_core/Task.mjs";
import { Js$suspending } from "./_core/Js.mjs";
const JsSuspending$park = () => 1;
const JsSuspending$inValue = () => Task$andThen(2, ($t$1) => {
  const n$1 = $t$1;
  return n$1 + 1;
});
const JsSuspending$discarded = () => Task$andThen(3, ($t$2) => 4);
const JsSuspending$passed = () => Js$suspending;
export { JsSuspending$park, JsSuspending$inValue, JsSuspending$discarded, JsSuspending$passed };
//# sourceMappingURL=JsSuspending.mjs.map
