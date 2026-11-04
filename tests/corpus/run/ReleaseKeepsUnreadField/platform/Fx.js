// The sibling of `Fx.beni`. Every call and every getter writes a line to
// standard output when it runs.

export const say = (text) => {
  console.log(text);
  return text.length;
};

const getter = (name, value) => ({
  get: () => {
    console.log("get " + name + " ran");
    return value;
  },
});

export const target = (_unit) => {
  const o = {
    zz: () => {
      console.log("call zz ran");
      return 26;
    },
    aa: () => {
      console.log("call aa ran");
      return 1;
    },
  };
  Object.defineProperty(o, "z", getter("z", 26));
  Object.defineProperty(o, "a", getter("a", 1));
  return o;
};
