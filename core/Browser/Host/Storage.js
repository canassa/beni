export const local = (_) => { try { const area = globalThis.localStorage; return area == null ? { $: "Nothing", a: null } : { $: "Just", a: area }; } catch (error) { if (!(error instanceof globalThis.DOMException) || error.name !== "SecurityError") throw error; return { $: "Nothing", a: null }; } };
export const session = (_) => { try { const area = globalThis.sessionStorage; return area == null ? { $: "Nothing", a: null } : { $: "Just", a: area }; } catch (error) { if (!(error instanceof globalThis.DOMException) || error.name !== "SecurityError") throw error; return { $: "Nothing", a: null }; } };
export const get = (area, key) => { const value = area.getItem(key); return value === null ? { $: "Nothing", a: null } : { $: "Just", a: value }; };
export const set = (area, key, value) => { try { area.setItem(key, value); return { $: "Ok", a: null }; } catch (error) { if (!(error instanceof globalThis.DOMException) || error.name !== "QuotaExceededError") throw error; return { $: "Err", a: "QuotaExceeded" }; } };
export const remove = (area, key) => { area.removeItem(key); return null; };
export const length = (area) => { return area.length; };
export const key = (area, index) => { const key = area.key(index); return key === null ? { $: "Nothing", a: null } : { $: "Just", a: key }; };
