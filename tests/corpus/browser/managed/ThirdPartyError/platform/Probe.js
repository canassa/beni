export const thirdParty = () => {
  globalThis.setTimeout(() => { throw new Error("third party timer"); }, 0);
};
