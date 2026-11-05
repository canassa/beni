// Calls `init`, then `settle` on its state, then `view` on both states.
export function run(main) {
  const s0 = main.init(undefined);
  const s1 = main.settle(s0);
  console.log(String(main.view(s0)) + " " + String(main.view(s1)));
}
