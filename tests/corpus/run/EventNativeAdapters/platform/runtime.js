import assert from "node:assert/strict";
export const run = (main) => {
  const rect = {};
  const oldNode = globalThis.Node;
  globalThis.Node = class {};
  const node = Object.assign(new globalThis.Node(), { getBoundingClientRect: () => rect });
  const event = new Event("click", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "target", { value: node });
  assert.equal(main.a(event, node), "click");
  if (oldNode === undefined) delete globalThis.Node; else globalThis.Node = oldNode;
  assert.equal(Object.hasOwn(event, "currentTarget"), false);
  assert.equal(event.currentTarget, null);
  assert.equal(main.b(node), true);
  assert.equal(node.value, "model");
  assert.equal(node.checked, true);
  assert.equal(node.selected, false);
  assert.equal(node.selectedIndex, 2);
  console.log("event identity, propagation and controls: ok");

  const target = { value: "takeover", checked: true, selectedIndex: 7 };
  const captured = new Event("input");
  Object.defineProperty(captured, "target", { value: target });
  const record = [captured, "captured", false, 2];
  const stray = new Event("change");
  Object.defineProperty(stray, "target", { value: {} });
  const missing = [stray, undefined, undefined, undefined];
  let taken = 0;
  globalThis.$beni = () => { taken++; return [record, missing]; };
  assert.equal(main.c(null), "input:captured:false:2:takeover;change:none:none:none:none;");
  assert.equal(taken, 1);
  assert.equal(globalThis.$beni, undefined);
  assert.deepEqual(record, [captured, "captured", false, 2, "takeover", true, 7]);
  assert.equal(main.c(null), "");
  console.log("early tuple identity, takeover and NONE: ok");

  assert.equal(main.d({}), "ok");
  const invalid = new DOMException("file", "InvalidStateError");
  assert.equal(main.d({ set value(_) { throw invalid; } }), "invalid state");
  const wrongClass = Object.assign(new Error("wrong class"), { name: "InvalidStateError" });
  for (const reason of [wrongClass, new DOMException("unknown", "NotFoundError"), new TypeError("unknown"), { marker: true }]) {
    assert.throws(() => main.d({ set value(_) { throw reason; } }), error => error === reason);
  }
  console.log("named control failure and unknown throws: ok");

  let handler;
  const calls = [];
  const host = {
    addEventListener(name, f, capture) { handler = f; calls.push(["add", name, capture]); },
    removeEventListener(name, f, capture) { assert.equal(f, handler); calls.push(["remove", name, capture]); },
  };
  const remove = main.e(host);
  const click = new Event("click", { cancelable: true });
  handler(click);
  assert.equal(click.defaultPrevented, true);
  remove(null);
  assert.deepEqual(calls, [["add", "click", true], ["remove", "click", true]]);
  console.log("capture listener identity and removal: ok");

  const noted = main.f(null);
  assert.deepEqual(noted, []);
  assert.equal(main.g(noted, new Event("input")), "first;second;");
  assert.equal(noted.length, 6);
  assert.deepEqual([noted[0], noted[2], noted[4]], ["input", "change", "input"]);
  assert.equal(main.h(noted, 1), "change");
  assert.equal(main.i(noted, 0), noted[1]);
  for (const index of [-1, 0.5, 3, 4, NaN, Infinity, 2 ** 32]) {
    for (const read of [main.h, main.i]) {
      assert.throws(() => read(noted, index), error => error instanceof RangeError && error.message === "beni: early listener index out of bounds");
    }
  }
  console.log("typed early listeners keep raw pairs, order and bounds: ok");
};
