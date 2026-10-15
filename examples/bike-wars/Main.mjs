import { Tea$document } from "./_platform/Tea.mjs";
import { Game$init, Game$update, Game$view, Game$subscriptions } from "./Game.mjs";
const Main$main = (() => {
  const $t$1 = () => Game$init;
  const $t$2 = (model$1) => ({ body: Game$view(model$1), title: "Bike Wars" });
  return Tea$document({ init: $t$1, subscriptions: Game$subscriptions, update: Game$update, view: $t$2 });
})();
export { Main$main };
//# sourceMappingURL=Main.mjs.map
