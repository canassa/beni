// Each replaces the page's storage with one that throws: a stand-in object
// for `localStorage` whose `setItem` throws, or a `sessionStorage` that
// cannot be read. The page's own storage object is left alone — a property
// written on it would be stored as an item.
const local = (fail) => {
  Object.defineProperty(globalThis, "localStorage", {
    configurable: true,
    value: { length: 0, key: () => null, getItem: () => null, removeItem: () => undefined, setItem: fail },
  });
};

export const fillQuota = (unit) => {
  local(() => {
    throw new globalThis.DOMException("the quota is full", "QuotaExceededError");
  });
  return unit;
};

export const blockSession = (unit) => {
  Object.defineProperty(globalThis, "sessionStorage", {
    configurable: true,
    get: () => {
      throw new globalThis.DOMException("storage is disabled", "SecurityError");
    },
  });
  return unit;
};

export const breakStorage = (unit) => {
  local(() => {
    throw new TypeError("storage broke");
  });
  return unit;
};
