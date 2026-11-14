// The host faults of this fixture (tests/corpus/README.md, *A Worker*, *A
// host fault*): `kv.put` throws the host's `Error` of a full disk for the
// key `full`, and a value that is no `Error`, with the same message, for
// the key `not-an-error`.
import * as built from "./_worker.mjs";

export default built.default;

const full = "database or disk is full: SQLITE_FULL";

let replaced = false;
export class Store extends built.Store {
  constructor(state, env) {
    if (!replaced) {
      replaced = true;
      const kv = Object.getPrototypeOf(state.storage.kv);
      const put = kv.put;
      kv.put = function (key, value) {
        if (key === "full") throw new Error(full);
        if (key === "not-an-error") throw { message: full };
        return put.call(this, key, value);
      };
    }
    super(state, env);
  }
}
