// The host fault of this fixture (tests/corpus/README.md, *A Worker*, *A
// host fault*): the namespace's `idFromString` throws a `RangeError` for
// the text `fault`.
import * as built from "./_worker.mjs";

export const Room = built.Room;

let replaced = false;
export default {
  ...built.default,
  fetch(request, env, ctx) {
    if (!replaced) {
      replaced = true;
      const namespace = Object.getPrototypeOf(env.ROOMS);
      const idFromString = namespace.idFromString;
      namespace.idFromString = function (text) {
        if (text === "fault") throw new RangeError("the fixture's host fault");
        return idFromString.call(this, text);
      };
    }
    return built.default.fetch(request, env, ctx);
  },
};
