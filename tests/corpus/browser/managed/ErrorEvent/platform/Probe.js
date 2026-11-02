export const defect = handle => {
  (handle.native ?? handle.t).dispatchEvent(new globalThis.ErrorEvent("error", {message: "post-ready worker defect"}));
};
