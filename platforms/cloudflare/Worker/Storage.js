// The sibling JavaScript of `Worker/Storage.beni` (docs/design/boundary.md
// §4): one export per `foreign` value, under the same name, and nothing
// else. The one failure the host documents for `kv.put` on ordinary input
// is caught by its text; anything else is thrown again (CLAUDE.md rule 9).

export const kvPut = (kv, key, text) => {
  try {
    kv.put(key, text);
    return true;
  } catch (e) {
    if (!(e instanceof Error) || !String(e.message).includes("SQLITE_FULL")) throw e;
    return false;
  }
};
