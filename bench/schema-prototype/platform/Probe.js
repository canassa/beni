const MAX_RESULTS = 10000;

const failure = (message) => ({
  kind: "schema-prototype",
  passed: false,
  count: 0,
  results: [],
  fatal: message,
});

export const finish = (list) => {
  try {
    const results = [];
    let at = list;
    while (at !== null && typeof at === "object" && at.$ === 1) {
      if (results.length >= MAX_RESULTS) return failure(`probe exceeds ${MAX_RESULTS} results`);
      const pair = at.a;
      if (pair === null || typeof pair !== "object" || typeof pair.a !== "string" || typeof pair.b !== "boolean") {
        return failure("probe result is not a ( String, Bool ) tuple");
      }
      results.push({ label: pair.a, passed: pair.b });
      at = at.b;
    }
    if (at === null || typeof at !== "object" || at.$ !== 0) {
      return failure("probe results are not a well-formed List");
    }
    return {
      kind: "schema-prototype",
      passed: results.every((result) => result.passed),
      count: results.length,
      results,
      fatal: null,
    };
  } catch (caught) {
    return failure(caught instanceof Error ? caught.message : String(caught));
  }
};
