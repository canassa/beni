export const run = (program) => {
  // happy-dom 20.14.5 throws DOMException with name "DOMException" for an
  // invalid selector. Script the standard's named failure, without catching
  // or broadening the generated adapter; found/missing use the real DOM.
  const querySelector = document.querySelector.bind(document);
  document.querySelector = (selector) => {
    if (selector === "[") throw new DOMException("invalid selector", "SyntaxError");
    return querySelector(selector);
  };
  const target = document.createElement("div");
  target.id = "found";
  document.body.appendChild(target);
  // Precisely scripted host failures; no worker network or storage capacity
  // assumptions enter this test of the generated native adapters.
  // DOMException is not required to inherit Error. Install that valid shape
  // when the worker cases begin, after the real document cases have run.
  class NativeDOMException {
    constructor(message, name) { this.message = message; this.name = name; }
  }
  globalThis.Worker = class {
    constructor(url) {
      globalThis.DOMException = NativeDOMException;
      if (url === "syntax") throw new DOMException("invalid worker URL", "SyntaxError");
      if (url === "security") throw new DOMException("worker blocked", "SecurityError");
      if (url === "type") throw new TypeError("invalid worker options");
    }
  };
  const storage = globalThis.localStorage;
  const setItem = storage.setItem.bind(storage);
  Object.defineProperty(globalThis, "localStorage", { configurable: true, value: {
    getItem: storage.getItem.bind(storage),
    setItem(key, value) {
      if (key === "quota") throw new DOMException("storage full", "QuotaExceededError");
      return setItem(key, value);
    }
  } });
  const output = document.createElement("output");
  output.textContent = program.init(null);
  document.body.appendChild(output);
};
