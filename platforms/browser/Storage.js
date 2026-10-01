// The sibling JavaScript of `Storage.beni` (docs/design/boundary.md §4,
// §9.8.10 (b)): one export per `foreign` value, under the same name.
//
// The Web Storage standard documents two failures, and each is caught by
// its name and nothing broader (CLAUDE.md rule 9): reading
// `localStorage` or `sessionStorage` may throw a `SecurityError` (storage
// disabled, a sandboxed frame) — the area is then unavailable, as it is
// when the host gives `null` — and `setItem` may throw a
// `QuotaExceededError`. Every other exception is thrown on: a defect.
// `getItem`, `removeItem`, `key` and `length` document none.

const area = (local) => {
  try {
    return local ? globalThis.localStorage : globalThis.sessionStorage;
  } catch (e) {
    if (e instanceof globalThis.DOMException && e.name === "SecurityError") return null;
    throw e;
  }
};

// The text, or null: nothing stored, or no storage.
export const getItem = (local, key) => {
  const s = area(local);
  return s == null ? null : s.getItem(key);
};

// 0 stored, 1 over the quota, 2 no storage.
export const setItem = (local, key, value) => {
  const s = area(local);
  if (s == null) return 2;
  try {
    s.setItem(key, value);
    return 0;
  } catch (e) {
    if (e instanceof globalThis.DOMException && e.name === "QuotaExceededError") return 1;
    throw e;
  }
};

export const removeItem = (local, key) => {
  const s = area(local);
  if (s != null) s.removeItem(key);
  return null;
};

export const allKeys = (local) => {
  const s = area(local);
  const keys = [];
  if (s == null) return keys;
  for (let i = 0; i < s.length; i++) keys.push(s.key(i));
  return keys;
};
