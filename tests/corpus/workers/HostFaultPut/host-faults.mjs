// The host fault of this fixture (tests/corpus/README.md, *A Worker*, *A
// host fault*): `kv.put` throws a plain `Error` for the key `fault`.
import * as built from "./_worker.mjs";

export default built.default;

let replaced = false;
export class Store extends built.Store {
  constructor(state, env) {
    if (!replaced) {
      replaced = true;
      const kv = Object.getPrototypeOf(state.storage.kv);
      const put = kv.put;
      kv.put = function (key, value) {
        if (key === "fault") throw new Error("the fixture's host fault");
        return put.call(this, key, value);
      };
    }
    super(state, env);
  }
}
