export const create = (_) => { return new globalThis.FormData(); };
export const append = (form, name, value) => { form.append(name, value); return null; };
