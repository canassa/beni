// The accepted export form: an arrow. A sibling may not name `arguments`
// (the free-name check), so the alias cases pin behaviour only; the shape is
// `emit/release/core/EtaReduce`'s `aliasOnce` and `aliasTwice`.
export const counted = (a) => a + 1000;
