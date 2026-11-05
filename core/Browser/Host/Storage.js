export const host_local = (_) => { try { return globalThis.localStorage; } catch (error) { if (!(error instanceof globalThis.DOMException) || error.name !== "SecurityError") throw error; return undefined; } };
export const host_session = (_) => { try { return globalThis.sessionStorage; } catch (error) { if (!(error instanceof globalThis.DOMException) || error.name !== "SecurityError") throw error; return undefined; } };
export const host_get = (area, key) => { return area.getItem(key); };
export const host_set = (area, key, value) => { try { area.setItem(key, value); return null; } catch (error) { if (!(error instanceof globalThis.DOMException) || error.name !== "QuotaExceededError") throw error; return error; } };
export const remove = (area, key) => { area.removeItem(key); return null; };
export const length = (area) => { return area.length; };
export const host_key = (area, index) => { return area.key(index); };
