export const run = (program) => {
  document.body.querySelector = () => { throw new Error("unrelated host failure"); };
  program.init(null);
};
