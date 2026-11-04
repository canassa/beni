import assert from "node:assert/strict";
export const run = (main) => {
  console.log(main.e);
  const attributes = [];
  const child = { setAttribute(name, value) { attributes.push({ name, value }); } };
  let appended;
  console.log(main.a({ appendChild(value) { appended = value; } }, child));
  assert.strictEqual(appended, child);
  console.log(main.a({ appendChild() { throw new DOMException("cycle", "HierarchyRequestError"); } }, child));
  const wrongClass = new Error("wrong class");
  wrongClass.name = "HierarchyRequestError";
  const unknown = [wrongClass, new DOMException("missing", "NotFoundError"), new TypeError("unmatched"), { marker: true }, "thrown string"];
  for (const reason of unknown) {
    assert.throws(() => main.a({ appendChild() { throw reason; } }, child), error => error === reason);
  }
  console.log("unknown throws preserved: " + unknown.length);

  const hadDocument = Object.hasOwn(globalThis, "document");
  const previousDocument = globalThis.document;
  try {
    globalThis.document = {
      body: null,
      createElement(tag) { assert.strictEqual(tag, "div"); return child; },
    };
    console.log(main.b(child));
    globalThis.document.body = child;
    console.log(main.b(child));
    console.log(main.c(child));
    assert.deepEqual(attributes, [{ name: "style", value: "white-space:pre-wrap" }]);
  } finally {
    if (hadDocument) globalThis.document = previousDocument;
    else delete globalThis.document;
  }

  const event = (error, message) => {
    const value = new Event("error");
    Object.defineProperties(value, { error: { value: error }, message: { value: message } });
    return value;
  };
  const cases = [
    [undefined, "plain", "plain"],
    [null, "fallback", "fallback"],
    [new TypeError("native"), "fallback", "TypeError: native"],
    ["thrown", "fallback", "thrown"],
  ];
  for (const [error, message, expected] of cases) {
    const text = main.d(event(error, message));
    assert.strictEqual(text, expected);
    console.log(text);
  }
  const reason = { marker: "display" };
  assert.throws(() => main.d(event({ toString() { throw reason; } }, "fallback")), error => error === reason);
  console.log("unknown display throw preserved");
};
