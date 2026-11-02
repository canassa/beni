export const done = (result) => { return result.done; };
export const value = (result) => { return result.value === undefined ? { $: "Nothing", a: null } : { $: "Just", a: result.value }; };
