export const fail = handle => { handle.native.dispatchEvent(new globalThis.MessageEvent("messageerror")); };
