export const defect = handle => { (handle.native ?? handle.t).dispatchEvent(new globalThis.MessageEvent("message", { data: null })); return null; };
