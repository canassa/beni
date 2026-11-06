export const defect = handle => {
  (handle.native ?? handle.t).dispatchEvent(new globalThis.ErrorEvent("error", {message: "MyError2: post-ready worker defect"}));
};
