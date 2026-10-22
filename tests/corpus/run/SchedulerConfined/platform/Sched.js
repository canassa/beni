// The sibling JavaScript of `Sched.beni` (docs/design/boundary.md §4): one
// export per `foreign` value, under the same name, and nothing else.

// The one error the fixture throws is named; anything else is thrown again
// (CLAUDE.md rule 9).
export const later = (name, drain) => {
  Promise.resolve()
    .then(drain)
    .then(null, (e) => {
      if (!(e instanceof Error) || e.message !== "TODO: the fiber threw") throw e;
      console.log(`${name}: the drain threw ${JSON.stringify(e.message)}`);
    });
  return null;
};
