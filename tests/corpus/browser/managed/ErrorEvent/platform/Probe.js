export const defect = handle => {
  handle.native.dispatchEvent(new globalThis.ErrorEvent("error", {message: "post-ready worker defect"}));
};
