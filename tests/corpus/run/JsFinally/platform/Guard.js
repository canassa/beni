// The sibling JavaScript of `Guard.beni`: a test platform's catch, which
// is how the program sees a throw go past a cleanup.

export const attempt = (f) => {
  try {
    return f();
  } catch (e) {
    return `threw ${e.message}`;
  }
};
