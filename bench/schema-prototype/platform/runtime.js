// Host-neutral runtime: the same emitted entry module runs under Node and in
// a browser. Consumers get the whole structured record, and stdout receives
// exactly one JSON line for the black-box runner.

export const run = (program) => {
  let result = program;
  try {
    if (program === null || typeof program !== "object") {
      result = {
        kind: "schema-prototype",
        passed: false,
        count: 0,
        results: [],
        fatal: "Probe.Program has an invalid representation",
      };
    }
    globalThis.__schemaPrototype = result;
    console.log(JSON.stringify(result));
  } catch (caught) {
    const message = caught instanceof Error ? caught.message : String(caught);
    result = { kind: "schema-prototype", passed: false, count: 0, results: [], fatal: message };
    globalThis.__schemaPrototype = result;
    console.log(JSON.stringify(result));
  }
};
