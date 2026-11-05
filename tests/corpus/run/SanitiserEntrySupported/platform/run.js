// Calls `init`, then `update` twice, each on the state the last call answered.
export function run(main) {
  const s0 = main.init(undefined);
  const s2 = main.update(2, main.update(1, s0));
  console.log(String(main.view(s2)));
}
