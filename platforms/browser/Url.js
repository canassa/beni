// The sibling JavaScript of `Url.beni` (docs/design/boundary.md §4): one
// export per `foreign` value, under the same name.
//
// `decodeURIComponent` documents one failure, a `URIError` for text that is
// not percent-encoded UTF-8; that is `False` here, and anything else is
// thrown on (CLAUDE.md rule 9).
export const decodes = (text) => {
  try {
    decodeURIComponent(text);
    return true;
  } catch (e) {
    if (e instanceof URIError) return false;
    throw e;
  }
};
