// The sibling of `Host.beni`: the host's own JSON reader. A text that is not
// JSON is `null`, which no schema accepts.

export const parse = (text) => {
  try {
    return JSON.parse(text);
  } catch (e) {
    if (e instanceof SyntaxError) return null;
    throw e;
  }
};
