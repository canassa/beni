// The host fault of this fixture (tests/corpus/README.md, *A Worker*, *A
// host fault*): `new URL` throws a `RangeError` for the target `/fault`.
import * as built from "./_worker.mjs";

const HostURL = globalThis.URL;
globalThis.URL = class URL extends HostURL {
  constructor(target, base) {
    if (target === "/fault") throw new RangeError("the fixture's host fault");
    super(target, base);
  }
};

export default built.default;
