export const run = (main) => {
  const payload = main.a(null);
  console.log(`${main.$}/${payload.$}: ${payload.a.runtimeResult}`);
};
