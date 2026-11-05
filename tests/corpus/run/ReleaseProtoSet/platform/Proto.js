// Retain native __defineSetter__ behavior, with a typed beni callback parameter.
export const defineSetter = (prototype, setter) => { prototype.__defineSetter__("n", setter); return null; };
export const seven = () => () => 7;
