export const fail = handle => { (handle.native ?? handle.t).dispatchEvent(new globalThis.MessageEvent("messageerror")); };
