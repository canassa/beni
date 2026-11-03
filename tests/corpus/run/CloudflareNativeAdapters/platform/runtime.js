export const run = async (program) => {
  console.log(program.e);
  const store = { put(key, value) { if (key !== "key" || value !== "value") throw new Error("KV arguments changed"); } };
  console.log(`put ${program.a(store)}`);
  store.put = () => { throw new Error("database or disk is full: SQLITE_FULL"); };
  console.log(`full ${program.a(store)}`);
  const unchanged = (label, action, reason) => {
    let caught = false;
    try { action(); } catch (error) { if (error !== reason) throw error; caught = true; }
    if (!caught) throw new Error(`${label} was swallowed`);
    console.log(`${label} unchanged`);
  };
  const unknown = new Error("unknown storage failure");
  store.put = () => { throw unknown; };
  unchanged("unknown error", () => program.a(store), unknown);
  const named = { message: "SQLITE_FULL" };
  store.put = () => { throw named; };
  unchanged("named full object", () => program.a(store), named);
  const namespace = { idFromString() { throw new TypeError("Invalid Durable Object ID"); } };
  console.log(`id invalid ${program.b(namespace)}`);
  namespace.idFromString = () => { throw unknown; };
  unchanged("unknown id", () => program.b(namespace), unknown);
  console.log(`promise ${await program.c(null)}`);
  let rejected = false;
  try { await program.d(unknown); } catch (error) { if (error !== unknown) throw error; rejected = true; }
  if (!rejected) throw new Error("promise rejection was swallowed");
  console.log("rejection unchanged");
};
